//
//  TreemapSceneTests.swift — dim ladder, depth window, border inset, ordering.
//  Module maturity: PROTOTYPE (slice TZ-1)
//

import XCTest
import ScanCore
@testable import TreemapCore

final class TreemapSceneTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 800, height: 600)

    // A small, explicit tree: root → 2 dirs → each 2 children (a dir + a file) →
    // the nested dir has 2 files. Deterministic sizes.
    private func sampleTree() -> SizeTree {
        func file(_ id: String, _ b: Int64) -> SizeTree {
            SizeTree(id: id, name: id, kind: .file, allocatedBytes: b, logicalBytes: b)
        }
        let a1 = file("a/x1", 100)
        let a2 = file("a/x2", 300)
        let aDir = SizeTree(id: "a/sub", name: "a/sub", kind: .dir,
                            allocatedBytes: 400, logicalBytes: 400, children: [a1, a2])
        let aFile = file("a/f", 600)
        let a = SizeTree(id: "A", name: "A", kind: .dir,
                         allocatedBytes: 1000, logicalBytes: 1000, children: [aDir, aFile])
        let b = SizeTree(id: "B", name: "B", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [file("b/1", 500), file("b/2", 500)])
        return SizeTree(id: "root", name: "root", kind: .dir,
                        allocatedBytes: 2000, logicalBytes: 2000, children: [a, b])
    }

    func testFocusIsLevelZeroAndFillsViewport() {
        let tiles = TreemapScene.layout(tree: sampleTree(), viewport: viewport)
        let first = tiles.first!
        XCTAssertEqual(first.nodeId, "root")
        XCTAssertEqual(first.dimLevel, 0)
        XCTAssertEqual(first.rect, viewport, "focus tile fills the viewport")
    }

    func testDimLadderIncrementsWithDepth() {
        let tiles = TreemapScene.layout(tree: sampleTree(), viewport: viewport)
        func level(_ id: String) -> Int { tiles.first { $0.nodeId == id }!.dimLevel }
        XCTAssertEqual(level("root"), 0)
        XCTAssertEqual(level("A"), 1)
        XCTAssertEqual(level("B"), 1)
        XCTAssertEqual(level("a/sub"), 2)
        XCTAssertEqual(level("a/f"), 2)
        XCTAssertEqual(level("a/x1"), 3) // grandchild of A
        XCTAssertEqual(level("a/x2"), 3)
    }

    func testPreOrderEmissionParentBeforeChildren() {
        let tiles = TreemapScene.layout(tree: sampleTree(), viewport: viewport)
        let ids = tiles.map(\.nodeId)
        func idx(_ id: String) -> Int { ids.firstIndex(of: id)! }
        XCTAssertLessThan(idx("root"), idx("A"))
        XCTAssertLessThan(idx("A"), idx("a/sub"))
        XCTAssertLessThan(idx("a/sub"), idx("a/x1"))
        // A's whole subtree precedes B (depth-first pre-order).
        XCTAssertLessThan(idx("a/f"), idx("B"))
    }

    func testDepthWindowCapsNesting() {
        let tiles = TreemapScene.layout(tree: sampleTree(), depthWindow: 1, viewport: viewport)
        let maxLevel = tiles.map(\.dimLevel).max()!
        XCTAssertEqual(maxLevel, 1, "no tile may exceed the depth window")
        // Level-2 nodes must be absent.
        XCTAssertNil(tiles.first { $0.nodeId == "a/sub" })
        XCTAssertFalse(tiles.contains { $0.dimLevel > 1 })
    }

    func testChildrenTileParentInsetByBorder() {
        let border = TreemapScene.defaultBorderInset
        let tiles = TreemapScene.layout(tree: sampleTree(), viewport: viewport)
        let rootRect = tiles.first { $0.nodeId == "root" }!.rect
        let inner = rootRect.inset(by: border)
        let childSum = tiles.filter { $0.dimLevel == 1 }.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(childSum, inner.area, accuracy: inner.area * 1e-9 + 1e-6,
                       "level-1 children tile the border-inset root exactly")
        // Each level-1 child sits within the inset rect.
        for t in tiles where t.dimLevel == 1 {
            XCTAssertGreaterThanOrEqual(t.rect.x, inner.x - 1e-6)
            XCTAssertGreaterThanOrEqual(t.rect.y, inner.y - 1e-6)
            XCTAssertLessThanOrEqual(t.rect.x + t.rect.width, inner.x + inner.width + 1e-6)
            XCTAssertLessThanOrEqual(t.rect.y + t.rect.height, inner.y + inner.height + 1e-6)
        }
    }

    func testUnknownFocusReturnsEmpty() {
        XCTAssertEqual(TreemapScene.layout(tree: sampleTree(), focusId: "nope", viewport: viewport), [])
    }

    func testSingleNodeTree() {
        let leaf = SizeTree(id: "only", name: "only", kind: .file,
                            allocatedBytes: 10, logicalBytes: 10)
        let tiles = TreemapScene.layout(tree: leaf, viewport: viewport)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].nodeId, "only")
        XCTAssertEqual(tiles[0].rect, viewport)
    }

    func testFocusOnSubtree() {
        let tiles = TreemapScene.layout(tree: sampleTree(), focusId: "A", viewport: viewport)
        XCTAssertEqual(tiles.first!.nodeId, "A")
        XCTAssertEqual(tiles.first!.dimLevel, 0)
        XCTAssertEqual(tiles.first!.rect, viewport, "focused subtree fills the viewport")
        XCTAssertNil(tiles.first { $0.nodeId == "B" }, "siblings of the focus are not rendered")
    }

    // TZ-3b (review-3 item 1): the layout DENORMALIZES each node's display metadata
    // (name + allocated + logical bytes) onto its TileRect, so the App's hover readout
    // and menu resolve a hit tile to its name/sizes WITHOUT a `SizeTree.node(withId:)`
    // traversal on the main actor. Names distinct from ids here prove `name` is read
    // from the node, not the id.
    func testTilesCarryNodeDisplayMetadata() {
        let child = SizeTree(id: "root/kid", name: "Kid", kind: .file,
                             allocatedBytes: 4096, logicalBytes: 3000)
        let root = SizeTree(id: "root", name: "Root", kind: .dir,
                            allocatedBytes: 4096, logicalBytes: 3000, children: [child])
        let tiles = TreemapScene.layout(tree: root, viewport: viewport)
        let rootTile = tiles.first { $0.nodeId == "root" }!
        XCTAssertEqual(rootTile.name, "Root")
        XCTAssertEqual(rootTile.allocatedBytes, 4096)
        XCTAssertEqual(rootTile.logicalBytes, 3000)
        let kidTile = tiles.first { $0.nodeId == "root/kid" }!
        XCTAssertEqual(kidTile.name, "Kid", "name comes from the node, not the id")
        XCTAssertEqual(kidTile.allocatedBytes, 4096)
        XCTAssertEqual(kidTile.logicalBytes, 3000)
    }

    // The real fixture must flatten to a sane, non-degenerate scene at depth 5.
    func testFixtureRendersToTiles() throws {
        let tree = try FixtureLoader.load()
        let tiles = TreemapScene.layout(tree: tree, viewport: viewport)
        XCTAssertGreaterThan(tiles.count, 50, "fixture should yield many tiles")
        // At least one tile at each of a few depth levels (nesting is visible).
        for level in 0...3 {
            XCTAssertTrue(tiles.contains { $0.dimLevel == level }, "missing tiles at level \(level)")
        }
        // No tile escapes the viewport.
        for t in tiles {
            XCTAssertGreaterThanOrEqual(t.rect.x, -1e-6)
            XCTAssertLessThanOrEqual(t.rect.x + t.rect.width, viewport.width + 1e-6)
        }
    }
}
