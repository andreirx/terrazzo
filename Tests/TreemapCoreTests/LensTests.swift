//
//  LensTests.swift — the TZ-5 visualization lenses (scale / ignore / show-hidden).
//  Module maturity: PROTOTYPE (slice TZ-5)
//
//  These pin the pure behavior of the three layout lenses end-to-end across BOTH cores that
//  implement them: `ScanReducer.makeRenderTree` (which nodes are projected + the hidden-mass
//  accounting) and `TreemapScene.layout` (the Squarify partition + the area-scale weight). The
//  test target sees both (it imports ScanCore and @testable TreemapCore), so it can drive the
//  reducer projection and lay it out exactly as `ScenePipeline` does — without the actor or AppKit.
//

import XCTest
import ScanCore
@testable import TreemapCore

final class LensTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 800, height: 600)
    private let vpArea = 800.0 * 600.0
    private let minArea = 4.0 // mirrors ScenePipeline.minRenderAreaPx (the sub-pixel cull threshold)

    // A flat reducer: root → children (each a sized dir, optionally hidden).
    private func flatReducer(_ kids: [(name: String, bytes: Int64, hidden: Bool)],
                             rootId: String = "/r") -> ScanReducer {
        var r = ScanReducer(rootId: rootId, rootName: "r")
        r.apply([.sizeUpdated(nodeId: rootId, allocated: 0, logical: 0)])
        let stubs = kids.map { ChildStub(id: "\(rootId)/\($0.name)", name: $0.name,
                                         kind: .dir, isHidden: $0.hidden) }
        r.apply([.childrenDiscovered(parentId: rootId, children: stubs)])
        for k in kids {
            r.apply([.sizeUpdated(nodeId: "\(rootId)/\(k.name)", allocated: k.bytes, logical: k.bytes)])
        }
        r.apply([.subtreeCompleted(nodeId: rootId)])
        return r
    }

    private func areaOf(_ tiles: [TileRect], _ id: String) -> Double {
        tiles.first { $0.nodeId == id }?.rect.area ?? -1
    }

    // MARK: - Scale (deliverable 2)

    /// LOG is a MONOTONE transform: the tiling stays EXACT (children fill the inset parent) and
    /// the sibling ORDERING is unchanged — only the areas compress. Assert on a mixed sibling set.
    func testLogScalePreservesTilingExactnessAndOrdering() {
        let r = flatReducer([("A", 1000), ("B", 300), ("C", 60)].map { ($0.0, $0.1, false) })
        // The reducer takes a bare weight transform (AreaScale lives in TreemapCore now, review-1
        // change 3); the layout takes the AreaScale enum. The composition passes both from ONE scale.
        let (tree, _, _) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
                                            minRenderArea: minArea, viewportArea: vpArea,
                                            weight: AreaScale.log.weight)
        let tiles = TreemapScene.layout(tree: tree, focusId: "/r", viewport: viewport, scale: .log)
        // Exact tiling: the three children fill the border-inset root.
        let inner = viewport.inset(by: TreemapScene.defaultBorderInset)
        let sum = tiles.filter { $0.dimLevel == 1 }.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(sum, inner.area, accuracy: inner.area * 1e-9 + 1e-6,
                       "log weights still partition the parent EXACTLY (monotone transform)")
        // Ordering preserved: A ≥ B ≥ C by area under log too (monotone ⇒ no reordering).
        XCTAssertGreaterThanOrEqual(areaOf(tiles, "/r/A"), areaOf(tiles, "/r/B"))
        XCTAssertGreaterThanOrEqual(areaOf(tiles, "/r/B"), areaOf(tiles, "/r/C"))
    }

    /// The founding point of the scale toggle: LOG EXPOSES the starved tail. On a giant-plus-many-
    /// small sibling set, the small tiles are SUB-PIXEL under linear (culled) but readable under
    /// log — so log's below-pixel-culled count is strictly lower. This is the PLAN evidence item,
    /// quantified deterministically (the giant cannot be exposed by scale — that needs zoom — but
    /// its siblings can).
    func testLogScaleExposesStarvedSiblingsFewerBelowPixelTiles() {
        var kids: [(String, Int64, Bool)] = [("giant", 1_000_000_000, false)]
        for i in 0..<50 { kids.append(("s\(i)", 1000, false)) }
        let r = flatReducer(kids)

        func belowPixelCount(_ scale: AreaScale) -> Int {
            // Lay out the SAME projected tree under each scale (no area-bounded pruning here — pass
            // minRenderArea 0 so every node is materialized and we count what the pixel cull WOULD
            // drop, isolating the scale's effect from the projection's own pruning).
            let (tree, _, _) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
                                                minRenderArea: 0, viewportArea: vpArea, weight: scale.weight)
            let tiles = TreemapScene.layout(tree: tree, focusId: "/r", viewport: viewport, scale: scale)
            return tiles.filter { $0.dimLevel == 1 && $0.rect.area < minArea }.count
        }

        let linearCulled = belowPixelCount(.linear)
        let logCulled = belowPixelCount(.log)
        XCTAssertEqual(linearCulled, 50, "under LINEAR the 50 starved siblings are all sub-pixel")
        XCTAssertEqual(logCulled, 0, "under LOG the starved siblings clear the pixel threshold — the tail is exposed")
        XCTAssertLessThan(logCulled, linearCulled,
                          "log reduces below-pixel culling (the sibling-starvation exposure, quantified)")
    }

    // MARK: - Ignore (deliverable 1)

    /// Ignoring a child EXCLUDES it, its SIBLINGS renormalize into the freed area (tiling stays
    /// exact), and every ANCESTOR keeps its area. Structure: root → {P, Q}; P → {A, B, C}. Ignore C.
    func testIgnoreRenormalizesSiblingsLocallyAndAncestorsUnchanged() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.sizeUpdated(nodeId: "/r", allocated: 0, logical: 0),
                 .childrenDiscovered(parentId: "/r", children: [
                    ChildStub(id: "/r/P", name: "P", kind: .dir),
                    ChildStub(id: "/r/Q", name: "Q", kind: .dir)]),
                 .childrenDiscovered(parentId: "/r/P", children: [
                    ChildStub(id: "/r/P/A", name: "A", kind: .dir),
                    ChildStub(id: "/r/P/B", name: "B", kind: .dir),
                    ChildStub(id: "/r/P/C", name: "C", kind: .dir)]),
                 .sizeUpdated(nodeId: "/r/P/A", allocated: 400, logical: 400),
                 .sizeUpdated(nodeId: "/r/P/B", allocated: 300, logical: 300),
                 .sizeUpdated(nodeId: "/r/P/C", allocated: 300, logical: 300),
                 .sizeUpdated(nodeId: "/r/Q", allocated: 1000, logical: 1000),
                 .subtreeCompleted(nodeId: "/r")])

        func layout(excluding ids: Set<String>) -> [TileRect] {
            let (tree, _, _) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
                                                minRenderArea: minArea, viewportArea: vpArea,
                                                excluding: ids, weight: AreaScale.linear.weight)
            return TreemapScene.layout(tree: tree, focusId: "/r", viewport: viewport, scale: .linear)
        }

        let before = layout(excluding: [])
        let after = layout(excluding: ["/r/P/C"])

        // C is gone; A and B remain.
        XCTAssertNil(after.first { $0.nodeId == "/r/P/C" }, "the ignored child is excluded from layout")
        XCTAssertNotNil(after.first { $0.nodeId == "/r/P/A" })

        // ANCESTORS keep their areas: P's and Q's rects are byte-identical before/after (P's weight
        // among root's children still includes C's bytes — only C's DIRECT siblings share its space).
        XCTAssertEqual(areaOf(after, "/r/P"), areaOf(before, "/r/P"), accuracy: 1e-6,
                       "the ancestor P keeps its area — ignoring a grandchild does not shrink it")
        XCTAssertEqual(areaOf(after, "/r/Q"), areaOf(before, "/r/Q"), accuracy: 1e-6,
                       "the sibling-of-ancestor Q is untouched")

        // SIBLINGS renormalize EXACTLY into P's inner area (A + B now tile all of P).
        let pRect = after.first { $0.nodeId == "/r/P" }!.rect
        let pInner = pRect.inset(by: TreemapScene.defaultBorderInset)
        let abSum = after.filter { $0.dimLevel == 2 && ($0.nodeId == "/r/P/A" || $0.nodeId == "/r/P/B") }
            .reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(abSum, pInner.area, accuracy: pInner.area * 1e-9 + 1e-6,
                       "A and B renormalize to tile P's inner area exactly after C is ignored")
        // And each grew (freed area is claimed, not left blank).
        XCTAssertGreaterThan(areaOf(after, "/r/P/A"), areaOf(before, "/r/P/A"))
    }

    /// Ignore → restore ROUND-TRIP restores the EXACT prior layout (a pure function of the excluded
    /// set, so removing an id then re-adding it reproduces the original tiles byte-for-byte).
    func testIgnoreRestoreRoundTripRestoresExactLayout() {
        let r = flatReducer([("A", 1000), ("B", 600), ("C", 300)].map { ($0.0, $0.1, false) })
        func layout(excluding ids: Set<String>) -> [TileRect] {
            let (tree, _, _) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
                                                minRenderArea: minArea, viewportArea: vpArea,
                                                excluding: ids, weight: AreaScale.log.weight)
            return TreemapScene.layout(tree: tree, focusId: "/r", viewport: viewport, scale: .log)
        }
        let original = layout(excluding: [])
        _ = layout(excluding: ["/r/B"])          // ignore B
        let restored = layout(excluding: [])     // restore B
        XCTAssertEqual(restored, original, "restoring an ignored tile reproduces the exact prior layout")
    }

    /// NESTED-IGNORE restore semantics (review-2 change 2). The App keeps its ignore set an
    /// ANTICHAIN so every panel row restores its own tile: ignoring an ANCESTOR drops any
    /// already-ignored DESCENDANTS (subsumed — the ancestor already excludes the whole subtree, so
    /// a descendant row could never restore its tile). This pins that normalization against the
    /// SAME production primitive the App uses (`ScanCore.IgnorePath.isAncestor`) AND the projection
    /// consequence: after normalization the excluded set is coherent, and restoring the surviving
    /// row brings its subtree — descendants included — back.
    func testNestedIgnoreNormalizesToAntichainAndRestores() {
        // root → {P, Q}; P → {A, B, C}. (Same shape as the sibling-renormalization test.)
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.sizeUpdated(nodeId: "/r", allocated: 0, logical: 0),
                 .childrenDiscovered(parentId: "/r", children: [
                    ChildStub(id: "/r/P", name: "P", kind: .dir),
                    ChildStub(id: "/r/Q", name: "Q", kind: .dir)]),
                 .childrenDiscovered(parentId: "/r/P", children: [
                    ChildStub(id: "/r/P/A", name: "A", kind: .dir),
                    ChildStub(id: "/r/P/B", name: "B", kind: .dir),
                    ChildStub(id: "/r/P/C", name: "C", kind: .dir)]),
                 .sizeUpdated(nodeId: "/r/P/A", allocated: 400, logical: 400),
                 .sizeUpdated(nodeId: "/r/P/B", allocated: 300, logical: 300),
                 .sizeUpdated(nodeId: "/r/P/C", allocated: 300, logical: 300),
                 .sizeUpdated(nodeId: "/r/Q", allocated: 1000, logical: 1000),
                 .subtreeCompleted(nodeId: "/r")])

        // The App's antichain normalization (NavigationController.ignore), using the SAME primitive.
        func insert(_ id: String, into set: [String]) -> [String] {
            if set.contains(id) { return set }
            // already excluded by an ignored ancestor → nothing to add
            if set.contains(where: { IgnorePath.isAncestor($0, of: id) }) { return set }
            var next = set.filter { !IgnorePath.isAncestor(id, of: $0) } // drop subsumed descendants
            next.append(id)
            return next
        }

        // Ignore grandchild C, THEN ancestor P — the exact case the reviewer flagged.
        var ig: [String] = []
        ig = insert("/r/P/C", into: ig)
        XCTAssertEqual(ig, ["/r/P/C"])
        ig = insert("/r/P", into: ig)
        XCTAssertEqual(ig, ["/r/P"],
                       "ignoring ancestor P subsumes descendant C — the set stays an antichain")
        // Defensive: re-ignoring the now-hidden descendant is a no-op (it has an ignored ancestor).
        XCTAssertEqual(insert("/r/P/C", into: ig), ["/r/P"],
                       "a descendant of an ignored ancestor is never added (it could not restore)")

        func present(_ ids: [String]) -> [TileRect] {
            let (tree, _, _) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
                                                minRenderArea: minArea, viewportArea: vpArea,
                                                excluding: Set(ids), weight: AreaScale.linear.weight)
            return TreemapScene.layout(tree: tree, focusId: "/r", viewport: viewport, scale: .linear)
        }

        // With the normalized set {P}: P's whole subtree is excluded, Q renormalizes to fill.
        let ignored = present(ig)
        XCTAssertNil(ignored.first { $0.nodeId == "/r/P" }, "the ignored ancestor is excluded")
        XCTAssertNil(ignored.first { $0.nodeId == "/r/P/C" }, "its descendant is excluded with it")
        XCTAssertNotNil(ignored.first { $0.nodeId == "/r/Q" })

        // Restore the ONE surviving row (P) → set empty → P AND its descendant C are back.
        let restored = present(ig.filter { $0 != "/r/P" })
        XCTAssertNotNil(restored.first { $0.nodeId == "/r/P" }, "restoring the row brings the tile back")
        XCTAssertNotNil(restored.first { $0.nodeId == "/r/P/C" },
                        "restoring the ancestor restores its subtree — the row's one click is honest")
    }

    // MARK: - Show hidden (deliverable 3)

    /// Show-hidden OFF excludes hidden nodes from layout and ACCOUNTS their mass; ON keeps them and
    /// reports zero filtered. Structure: visible V (700) + hidden H (300).
    func testHiddenFilterExcludesAndAccountsMass() {
        let r = flatReducer([("V", 700, false), (".H", 300, true)])

        let (shown, _, shownHidden) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
            minRenderArea: minArea, viewportArea: vpArea, includeHidden: true)
        XCTAssertNotNil(shown.children.first { $0.id == "/r/.H" }, "hidden node present when show-hidden is on")
        XCTAssertEqual(shownHidden, 0, "nothing is filtered when show-hidden is on")

        let (filtered, _, filteredHidden) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
            minRenderArea: minArea, viewportArea: vpArea, includeHidden: false)
        XCTAssertNil(filtered.children.first { $0.id == "/r/.H" }, "hidden node excluded when show-hidden is off")
        XCTAssertEqual(filteredHidden, 300, "the filtered hidden MASS is accounted (never silently dropped)")
    }

    /// Composition rule (packet): ignored ∩ hidden-filtered must NOT double-count. A node that is
    /// BOTH ignored AND hidden is excluded as IGNORED (the App accounts its bytes) and is NOT also
    /// counted in the hidden-filtered mass.
    func testIgnoredHiddenNodeIsNotDoubleCountedAsHiddenFiltered() {
        let r = flatReducer([("V", 700, false), (".H", 300, true)])
        // Ignore the hidden node AND turn show-hidden off.
        let (tree, _, hiddenBytes) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
            minRenderArea: minArea, viewportArea: vpArea,
            excluding: ["/r/.H"], includeHidden: false)
        XCTAssertNil(tree.children.first { $0.id == "/r/.H" }, "the node is excluded")
        XCTAssertEqual(hiddenBytes, 0,
                       "a node excluded for being IGNORED is not ALSO counted as hidden-filtered (no double-count)")
    }
}
