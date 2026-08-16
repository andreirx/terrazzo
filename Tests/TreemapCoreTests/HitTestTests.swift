//
//  HitTestTests.swift — point → deepest tile + ancestor chain, on real layouts.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  Drives HitTest against actual TreemapScene.layout output (its one contract),
//  including borders and shared edges (the half-open containment property).
//

import XCTest
import ScanCore
@testable import TreemapCore

final class HitTestTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 800, height: 600)

    // root → A(→A1,A2), B(→B1,B2). Deterministic weights.
    private func tree() -> SizeTree {
        func file(_ id: String, _ b: Int64) -> SizeTree {
            SizeTree(id: id, name: id, kind: .file, allocatedBytes: b, logicalBytes: b)
        }
        let a = SizeTree(id: "A", name: "A", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [file("A1", 600), file("A2", 400)])
        let b = SizeTree(id: "B", name: "B", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [file("B1", 500), file("B2", 500)])
        return SizeTree(id: "root", name: "root", kind: .dir, allocatedBytes: 2000,
                        logicalBytes: 2000, children: [a, b])
    }

    private func layout() -> [TileRect] { TreemapScene.layout(tree: tree(), viewport: viewport) }

    private func center(of id: String, in tiles: [TileRect]) -> Point {
        let r = tiles.first { $0.nodeId == id }!.rect
        return Point(x: r.x + r.width / 2, y: r.y + r.height / 2)
    }

    // MARK: - Basic hits

    func testDeepestLeafHitReturnsFullAncestorChain() {
        let tiles = layout()
        let chain = HitTest.hit(tiles: tiles, at: center(of: "A1", in: tiles))!
        XCTAssertEqual(chain.deepest.nodeId, "A1", "deepest tile at a leaf's center is that leaf")
        // Chain is shallow→deep and contiguous: root(0) → A(1) → A1(2).
        XCTAssertEqual(chain.chain.map(\.nodeId), ["root", "A", "A1"])
        XCTAssertEqual(chain.chain.map(\.dimLevel), [0, 1, 2])
    }

    func testChainDimLevelsStrictlyIncreasingAndContiguous() {
        let tiles = layout()
        for leaf in ["A1", "A2", "B1", "B2"] {
            let chain = HitTest.hit(tiles: tiles, at: center(of: leaf, in: tiles))!
            let levels = chain.chain.map(\.dimLevel)
            XCTAssertEqual(levels, Array(0...(chain.deepest.dimLevel)),
                           "chain to \(leaf) must be 0..deepest with no gaps or repeats")
        }
    }

    func testTopLevelUnderFocusIsTheDimLevelOneAncestor() {
        let tiles = layout()
        let chain = HitTest.hit(tiles: tiles, at: center(of: "B2", in: tiles))!
        XCTAssertEqual(chain.topLevelUnderFocus?.nodeId, "B",
                       "the bright top-level ancestor of B2 is B")
        XCTAssertEqual(chain.topLevelUnderFocus?.dimLevel, 1)
    }

    // MARK: - Misses and borders

    func testPointOutsideViewportReturnsNil() {
        let tiles = layout()
        XCTAssertNil(HitTest.hit(tiles: tiles, at: Point(x: -1, y: 10)))
        XCTAssertNil(HitTest.hit(tiles: tiles, at: Point(x: 10, y: 10_000)))
    }

    func testPointOnFocusBorderStopsAtFocus() {
        // The very corner of the viewport lies inside the focus rect but OUTSIDE
        // the border-inset region its children tile — an honest "on folder root,
        // not in any child".
        let tiles = layout()
        let corner = Point(x: 0.25, y: 0.25) // well within the 2px inset frame
        let chain = HitTest.hit(tiles: tiles, at: corner)!
        XCTAssertEqual(chain.chain.map(\.nodeId), ["root"], "corner is on the focus border only")
        XCTAssertNil(chain.topLevelUnderFocus, "no top-level tile beneath a focus-border point")
        XCTAssertEqual(chain.deepest.nodeId, "root")
    }

    func testFarOuterEdgeIsHalfOpenNotContained() {
        // Half-open containment: the exact far (right/bottom) outer edge is NOT
        // contained (Rect.contains uses [x, x+w)). The App clamps strictly inside
        // the drawable, so this boundary is never queried live — assert the
        // documented property holds.
        let tiles = layout()
        let farCorner = Point(x: viewport.width, y: viewport.height)
        XCTAssertNil(HitTest.hit(tiles: tiles, at: farCorner),
                     "far outer edge is excluded by half-open containment")
        // The top-left origin IS contained (closed lower bound).
        XCTAssertNotNil(HitTest.hit(tiles: tiles, at: Point(x: 0, y: 0)))
    }

    func testSharedEdgePointBelongsToExactlyOneChild() {
        // A point EXACTLY on the seam between siblings A1 and A2 must resolve to a
        // single unambiguous chain, and — by half-open containment — belong to the
        // sibling whose interval INCLUDES the seam coordinate (the one starting at
        // the seam). This asserts unconditionally: the seam is computed from the
        // actual laid-out sibling rects, so whichever orientation Squarify chose,
        // the seam is real and the expected owner is known (reviewer TZ-3 rev-0).
        let tiles = layout()
        let a1 = tiles.first { $0.nodeId == "A1" }!.rect
        let a2 = tiles.first { $0.nodeId == "A2" }!.rect
        let eps = 1e-9
        let seam: Point
        let expected: String // half-open owner: the tile whose min edge IS the seam
        if abs((a1.x + a1.width) - a2.x) < eps {          // A1 left of A2 (vertical seam)
            seam = Point(x: a2.x, y: max(a1.y, a2.y) + min(a1.height, a2.height) / 2)
            expected = "A2"
        } else if abs((a2.x + a2.width) - a1.x) < eps {   // A2 left of A1
            seam = Point(x: a1.x, y: max(a1.y, a2.y) + min(a1.height, a2.height) / 2)
            expected = "A1"
        } else if abs((a1.y + a1.height) - a2.y) < eps {  // A1 above A2 (horizontal seam)
            seam = Point(x: max(a1.x, a2.x) + min(a1.width, a2.width) / 2, y: a2.y)
            expected = "A2"
        } else {                                          // A2 above A1
            XCTAssertLessThan(abs((a2.y + a2.height) - a1.y), eps,
                              "A1 and A2 must share exactly one axis-aligned seam")
            seam = Point(x: max(a1.x, a2.x) + min(a1.width, a2.width) / 2, y: a1.y)
            expected = "A1"
        }
        let chain = HitTest.hit(tiles: tiles, at: seam)!
        XCTAssertEqual(chain.chain.map(\.nodeId), ["root", "A", expected],
                       "a point exactly on the A1|A2 seam resolves to exactly one child chain")
        // And exactly ONE child (level-2) tile contains the seam — no fork.
        let owners = tiles.filter { $0.dimLevel == 2 && $0.rect.contains(seam) }
        XCTAssertEqual(owners.map(\.nodeId), [expected],
                       "the seam belongs to exactly one sibling under half-open containment")
    }

    func testFocusHitAtSubtreeFocus() {
        // Hit-testing a layout focused on a subtree: chain roots at that focus.
        let tiles = TreemapScene.layout(tree: tree(), focusId: "A", viewport: viewport)
        let chain = HitTest.hit(tiles: tiles, at: center(of: "A2", in: tiles))!
        XCTAssertEqual(chain.chain.first?.nodeId, "A", "chain roots at the focus node")
        XCTAssertEqual(chain.chain.first?.dimLevel, 0)
        XCTAssertEqual(chain.deepest.nodeId, "A2")
    }
}
