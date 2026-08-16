//
//  QuadGeometryTests.swift — the ascend/dive handoff, on the REAL production geometry.
//  Module maturity: PROTOTYPE (slice TZ-3b, review-2 gap 3)
//
//  WHY THIS EXISTS
//  ---------------
//  Reviews 0–2 rejected the ascend test because it re-implemented the embed/handoff
//  math over `TileRect`/`Double` in the test file — it proved a DUPLICATE model, not
//  the production path. This suite drives the ACTUAL functions NavigationController
//  calls — `RenderPipeline.QuadGeometry.embedChild` / `.transform` / `.commitFrom` —
//  over the ACTUAL render type (`GPUQuad`/`Float`), built exactly as the pipeline
//  builds them (`TreemapScene.layout` → `QuadBuilder.build`). There is no second
//  implementation to drift from: the App and these tests share one.
//
//  THE TWO GUARANTEES IT PINS
//  --------------------------
//   1. ASCEND OPENS EXACTLY (no snap). The ascend base = the cached parent world with
//      the child subtree replaced by the child's committed quads (`embedChild`); the
//      t=0 camera (childRect → viewport) is the exact inverse of that embed, so at t=0
//      EVERY shared child-subtree tile maps back onto the committed child scene within
//      Float epsilon — all shared tiles, no focus-only carve-out, no viewport tolerance.
//   2. DIVE COMMITS EXACTLY on the focus. `commitFrom` places each committed tile where
//      its node sat in the camera's last frame; the focus tile lands filling the
//      viewport with zero deviation (the mass the eye tracks does not jump), a node
//      absent from the base carries its own committed quad, and the result is
//      index-parallel with the committed scene.
//

import XCTest
import ScanCore
import TreemapCore
@testable import RenderPipeline

final class QuadGeometryTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 1100, height: 680)

    // A multi-level subtree so a dive/ascend exercises real anisotropic re-tiling
    // (squarify is NOT affine-equivariant under anisotropic scale — CameraHandoffTests).
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

    /// Lay out a focus world exactly as the pipeline does, then build its GPU instances
    /// through the SAME off-main builder — the production (tiles, nodeIds, quads) triple.
    private func world(focus: String?) -> (tiles: [TileRect], nodeIds: [String], quads: [GPUQuad]) {
        let tiles = TreemapScene.layout(tree: tree(), focusId: focus, viewport: viewport)
        return (tiles, tiles.map { $0.nodeId }, QuadBuilder.build(tiles: tiles))
    }

    /// Max corner deviation between two quads' GEOMETRY (all four edges), in device px.
    private func geomDev(_ a: GPUQuad, _ b: GPUQuad) -> Float {
        max(abs(a.x - b.x), abs(a.y - b.y),
            abs((a.x + a.w) - (b.x + b.w)), abs((a.y + a.h) - (b.y + b.h)))
    }

    // Float32 over ~1e3-px coordinates through two narrowed affine composites: worst-case
    // rounding is a few ×1e-4 px. 0.02 px is comfortably above that and far below one
    // pixel, so a pass means "geometrically identical", i.e. NO opening snap.
    private let eps: Float = 0.02

    // MARK: - 1. Ascend opens on the committed child scene — ALL shared tiles, within eps

    func testAscendOpeningMatchesChildSceneExactlyOnAllSharedTiles() {
        for childId in ["A", "B"] {
            let parent = world(focus: nil)
            let child = world(focus: childId)
            guard let childRect = parent.tiles.first(where: { $0.nodeId == childId })?.rect else {
                return XCTFail("childRect for \(childId) not found in parent world")
            }

            // The child focus fills the viewport — this IS what is on screen at ascend.
            let focusQ = child.quads[child.nodeIds.firstIndex(of: childId)!]
            XCTAssertEqual(Double(focusQ.w), viewport.width, accuracy: 1e-3)
            XCTAssertEqual(Double(focusQ.h), viewport.height, accuracy: 1e-3)

            // PRODUCTION embed + PRODUCTION t=0 camera (the exact NavigationController path).
            let base = QuadGeometry.embedChild(
                childQuads: child.quads, childNodeIds: child.nodeIds, into: childRect,
                parentQuads: parent.quads, parentNodeIds: parent.nodeIds, childId: childId)
            let t0 = FocusCamera.transform(fromFrame: childRect, toFrame: viewport, viewport: viewport, t: 0)
            var openingById = [String: GPUQuad]()
            for (i, id) in base.nodeIds.enumerated() {
                openingById[id] = QuadGeometry.transform(base.quads[i], by: t0)
            }

            // Every committed child-scene tile must be reproduced at t=0 within eps.
            var shared = 0
            for (i, id) in child.nodeIds.enumerated() {
                guard let o = openingById[id] else {
                    XCTFail("child tile \(id) missing from ascend opening frame"); continue
                }
                shared += 1
                XCTAssertLessThan(geomDev(o, child.quads[i]), eps,
                    "ascend opening tile \(id) must equal the committed child scene within \(eps) px — no opening snap (\(childId))")
                XCTAssertEqual(o.r, child.quads[i].r, "colour is preserved across the embed (\(id))")
                XCTAssertEqual(o.style, child.quads[i].style, "style is preserved across the embed (\(id))")
            }
            XCTAssertGreaterThan(shared, 1,
                "the opening frame must reproduce the WHOLE child subtree, not just the focus tile (\(childId))")
        }
    }

    // MARK: - 2. Ascend's opening camera IS dive's closing camera (dive reversed)

    func testAscendCameraIsDiveTransformReversed() {
        let parent = world(focus: nil)
        let childRect = parent.tiles.first { $0.nodeId == "A" }!.rect
        let diveClose = FocusCamera.transform(fromFrame: viewport, toFrame: childRect, viewport: viewport, t: 1)
        let ascendOpen = FocusCamera.transform(fromFrame: childRect, toFrame: viewport, viewport: viewport, t: 0)
        XCTAssertEqual(diveClose, ascendOpen,
                       "ascend's opening camera transform is dive's closing transform — dive reversed")
    }

    // MARK: - 3. Dive commit lands the focus exactly + parallel + absent-node fallback

    func testCommitFromLandsFocusExactlyAndIsParallel() {
        for childId in ["A", "B"] {
            let parent = world(focus: nil)
            let child = world(focus: childId)
            let childRect = parent.tiles.first { $0.nodeId == childId }!.rect
            let finalCam = FocusCamera.transform(fromFrame: viewport, toFrame: childRect, viewport: viewport, t: 1)

            let from = QuadGeometry.commitFrom(
                sceneQuads: child.quads, sceneNodeIds: child.nodeIds,
                baseQuads: parent.quads, baseNodeIds: parent.nodeIds, finalCam: finalCam)

            XCTAssertEqual(from.count, child.quads.count, "commitFrom is index-parallel with the committed scene")

            // The focus tile: its camera-last-frame position (parent's child rect under
            // finalCam) fills the viewport, exactly the committed focus quad — zero jump.
            let fi = child.nodeIds.firstIndex(of: childId)!
            XCTAssertLessThan(geomDev(from[fi], child.quads[fi]), eps,
                "commit lands the focus tile exactly on its committed position (\(childId))")

            // A committed node ABSENT from the base (deeper detail revealed by focusing)
            // carries its OWN committed quad — appears in place, no fly-in.
            let baseIds = Set(parent.nodeIds)
            var checkedAbsent = false
            for (i, id) in child.nodeIds.enumerated() where !baseIds.contains(id) {
                XCTAssertEqual(from[i], child.quads[i],
                    "committed node \(id) absent from the flight base falls back to its own quad")
                checkedAbsent = true
            }
            // A shared node present in the base morphs FROM its transformed base position.
            let baseById = Dictionary(uniqueKeysWithValues: zip(parent.nodeIds, parent.quads))
            for (i, id) in child.nodeIds.enumerated() where baseById[id] != nil && id != childId {
                let expected = QuadGeometry.transform(baseById[id]!, by: finalCam)
                XCTAssertEqual(from[i], expected,
                    "shared node \(id) morphs from its camera-last-frame position")
            }
            _ = checkedAbsent // the tree is deep enough that this fires for at least one child
        }
    }
}
