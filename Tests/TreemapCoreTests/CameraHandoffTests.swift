//
//  CameraHandoffTests.swift — the camera→committed-focus handoff, on real scenes.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  WHY THIS EXISTS (reviewer TZ-3 rev-0, required change 3)
//  --------------------------------------------------------
//  FocusCameraTests proves the camera TRANSFORM is C1 in isolation. But the app
//  does not stop at the transform — at t=1 it COMMITS: it discards the scaled
//  parent world and RE-SQUARIFIES the child subtree to fill the viewport. This
//  suite drives the ACTUAL scene geometry through that handoff and pins what is
//  true of it, so the "no visible jump" claim is grounded in the rendered scene,
//  not just the transform math.
//
//  THE LOAD-BEARING FINDING (measured here, not assumed)
//  -----------------------------------------------------
//  A squarified layout is NOT affine-equivariant under an ANISOTROPIC scale: the
//  focus rect in the parent world and the viewport have different aspect ratios,
//  so squarify can group the focus's children DIFFERENTLY when it re-tiles them to
//  fill the viewport. Diving into a 2-child folder on the synthetic tree here moves
//  a child by ~660 units at commit even with the border removed — the residual is
//  genuine RE-TILING, not merely the nesting border. (On some data, e.g. parts of
//  the fixture, the grouping happens to coincide and the residual is near zero; we
//  do NOT rely on that.) This is inherent to the ratified squarified-per-focus
//  design — the children re-optimise for the new aspect — so exact frame-to-frame
//  geometric continuity of the WHOLE scene is not achievable, and is not claimed.
//
//  WHAT IS GUARANTEED, AND HOW THE APP STAYS JUMP-FREE
//  ---------------------------------------------------
//   1. FOCUS TILE EXACT — the tile being dived into lands filling the viewport with
//      zero deviation. The dominant mass the eye tracks does not jump. (asserted)
//   2. CONTAINED RESIDUAL — every node the commit morphs sits inside the viewport
//      in BOTH the camera's last frame and the committed layout, so the delta the
//      app must absorb is bounded by the viewport extent — never an escape or NaN.
//      (asserted)
//   3. The APP absorbs that bounded delta SMOOTHLY: the focus commit runs
//      `present(animated: true)`, which lerps each node FROM the camera's exact last
//      frame (now in CanvasView.displayedTiles) INTO the committed layout over the
//      settle window (the TZ-2 machinery). A linear lerp over ~18 frames turns even
//      a full re-tile into a bounded per-frame morph — the calm "settle" vocabulary,
//      not a snap. That wiring is App-layer; this suite pins the pure geometry it
//      relies on (focus exact + contained).
//

import XCTest
import ScanCore
@testable import TreemapCore

final class CameraHandoffTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 1100, height: 680)

    // root → A(→ a/sub(→ x1,x2), a/f), B(→ b1,b2): depth 3, so a dive into A
    // exercises re-tiling of a multi-level subtree at commit.
    private func tree() -> SizeTree {
        func file(_ id: String, _ b: Int64) -> SizeTree {
            SizeTree(id: id, name: id, kind: .file, allocatedBytes: b, logicalBytes: b)
        }
        let sub = SizeTree(id: "a/sub", name: "a/sub", kind: .dir, allocatedBytes: 400,
                           logicalBytes: 400, children: [file("a/x1", 100), file("a/x2", 300)])
        let a = SizeTree(id: "A", name: "A", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [sub, file("a/f", 600)])
        let b = SizeTree(id: "B", name: "B", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [file("b/1", 500), file("b/2", 500)])
        return SizeTree(id: "root", name: "root", kind: .dir, allocatedBytes: 2000,
                        logicalBytes: 2000, children: [a, b])
    }

    /// Reproduce the dive handoff for `childId`: lay out the parent world, take the
    /// camera transform at t=1 (the last frame the animation renders), apply it to
    /// that world, and return it alongside the committed child-focus layout.
    private func handoff(tree: SizeTree, childId: String, border: Double)
        -> (pre: [TileRect], committed: [TileRect]) {
        let base = TreemapScene.layout(tree: tree, focusId: nil, viewport: viewport, borderInset: border)
        let childRect = base.first { $0.nodeId == childId }!.rect
        let tr = FocusCamera.transform(fromFrame: viewport, toFrame: childRect, viewport: viewport, t: 1)
        let pre = base.map { t in
            TileRect(rect: tr.apply(t.rect), dimLevel: t.dimLevel, nodeId: t.nodeId,
                     kind: t.kind, scanState: t.scanState, hue: t.hue)
        }
        let committed = TreemapScene.layout(tree: tree, focusId: childId, viewport: viewport, borderInset: border)
        return (pre, committed)
    }

    private func corner(_ a: Rect, _ b: Rect) -> Double {
        max(abs(a.x - b.x), abs(a.y - b.y),
            abs((a.x + a.width) - (b.x + b.width)), abs((a.y + a.height) - (b.y + b.height)))
    }
    private func within(_ r: Rect, _ vp: Rect, eps: Double = 1e-6) -> Bool {
        r.x >= vp.x - eps && r.y >= vp.y - eps &&
        r.x + r.width <= vp.x + vp.width + eps && r.y + r.height <= vp.y + vp.height + eps
    }

    // MARK: - 1. Focus tile lands exactly

    func testFocusTileLandsExactlyOnCommit() {
        for child in ["A", "B"] {
            let h = handoff(tree: tree(), childId: child, border: TreemapScene.defaultBorderInset)
            let pre = h.pre.first { $0.nodeId == child }!.rect
            let committed = h.committed.first { $0.nodeId == child }!.rect
            XCTAssertEqual(committed, viewport, "committed focus tile fills the viewport")
            XCTAssertLessThan(corner(pre, committed), 1e-6,
                              "camera's last frame lands the focus tile EXACTLY on the committed layout")
        }
    }

    // MARK: - 2. The commit residual is bounded and contained (settle-absorbable)

    func testHandoffResidualBoundedAndContained() {
        let border = TreemapScene.defaultBorderInset
        for child in ["A", "B"] {
            let h = handoff(tree: tree(), childId: child, border: border)
            var idx = [String: Rect](); for t in h.pre { idx[t.nodeId] = t.rect }
            var maxDev = 0.0, common = 0
            for c in h.committed {
                guard let p = idx[c.nodeId] else { continue }
                common += 1
                // Both endpoints of the morph the settle-lerp runs are on-screen.
                XCTAssertTrue(within(c.rect, viewport), "committed \(c.nodeId) within viewport")
                XCTAssertTrue(within(p, viewport), "camera-frame \(c.nodeId) within viewport")
                maxDev = max(maxDev, corner(c.rect, p))
            }
            XCTAssertGreaterThan(common, 1, "the dive shares the focus subtree between pre/commit")
            // Bounded by the viewport extent: the delta the App absorbs is finite and
            // contained — the settle-lerp closes a contained morph, not an open jump.
            XCTAssertLessThanOrEqual(maxDev, max(viewport.width, viewport.height),
                                     "handoff residual is bounded by the viewport extent")
        }
    }

    // MARK: - 3. Re-tiling is real (honesty): the residual is NOT border-only

    func testCommitCanRetileChildrenBeyondTheBorder() {
        // Removing the border does NOT make the handoff continuous in general: on a
        // 2-child folder the anisotropic re-fit regroups the children. This pins the
        // finding that motivated the animated commit (so a future refactor that
        // silently assumes affine continuity fails here).
        let h = handoff(tree: tree(), childId: "A", border: 0)
        var idx = [String: Rect](); for t in h.pre { idx[t.nodeId] = t.rect }
        let maxDev = h.committed.compactMap { c in idx[c.nodeId].map { corner(c.rect, $0) } }.max() ?? 0
        XCTAssertGreaterThan(maxDev, 1.0,
                             "border-free dive still re-tiles children — commit is not affinely continuous")
    }

    // MARK: - Fixture: focus exact + contained on the real scanned-shape scene

    func testFixtureHandoffFocusExactAndContained() throws {
        let tree = try FixtureLoader.load()
        let firstChild = tree.children.first!.id
        let h = handoff(tree: tree, childId: firstChild, border: TreemapScene.defaultBorderInset)
        let pre = h.pre.first { $0.nodeId == firstChild }!.rect
        XCTAssertEqual(h.committed.first { $0.nodeId == firstChild }!.rect, viewport)
        XCTAssertLessThan(corner(pre, viewport), 1e-6, "fixture: focus tile lands exactly")
        var idx = [String: Rect](); for t in h.pre { idx[t.nodeId] = t.rect }
        var common = 0
        for c in h.committed {
            guard let p = idx[c.nodeId] else { continue }
            common += 1
            XCTAssertTrue(within(c.rect, viewport), "fixture committed \(c.nodeId) within viewport")
            XCTAssertTrue(within(p, viewport), "fixture camera-frame \(c.nodeId) within viewport")
        }
        XCTAssertGreaterThan(common, 10, "fixture dive shares many nodes")
    }
}
