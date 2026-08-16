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

    // TZ-4b rider 1: a denied tile's size is UNKNOWN, so its area is a readability BADGE,
    // floored to `minBadgeArea` — never sub-pixel, even when a huge sibling would squeeze
    // its proportional area to nothing. The floor changes only WEIGHTS, so the children
    // still tile the inset parent EXACTLY (tiling exactness is untouched).
    func testDeniedTileGetsMinimumBadgeAreaAndTilingStaysExact() {
        let huge = SizeTree(id: "root/huge", name: "huge", kind: .dir,
                            allocatedBytes: 1_000_000_000, logicalBytes: 1_000_000_000)
        let denied = SizeTree(id: "root/denied", name: "denied", kind: .denied,
                              allocatedBytes: 1, logicalBytes: 1, scanState: .complete)
        let root = SizeTree(id: "root", name: "root", kind: .dir,
                            allocatedBytes: 1_000_000_001, logicalBytes: 1_000_000_001,
                            children: [huge, denied])
        let tiles = TreemapScene.layout(tree: root, viewport: viewport)

        let deniedTile = tiles.first { $0.nodeId == "root/denied" }!
        // Proportional area would be ~(1/1e9)·inner ≈ 0; the floor reserves EXACTLY
        // minBadgeArea (review-0 finding 3 — assert the TRUE floor, not half of it).
        XCTAssertEqual(deniedTile.rect.area, TreemapScene.minBadgeArea,
                       accuracy: TreemapScene.minBadgeArea * 1e-6,
                       "denied badge realizes exactly the minimum badge area")

        // Tiling exactness holds — the two children still fill the inset root.
        let inner = viewport.inset(by: TreemapScene.defaultBorderInset)
        let sum = tiles.filter { $0.dimLevel == 1 }.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(sum, inner.area, accuracy: inner.area * 1e-9 + 1e-6,
                       "badge weight flooring changes proportions, never the exact partition")
    }

    // TZ-4b rider 1 / review-0 finding 3a: MULTIPLE floored badges each realize the FULL
    // minimum (the earlier version realized *less* than the floor, and worse with more
    // badges). A huge folder plus three 1-byte denied dirs: every denied tile must hit
    // exactly minBadgeArea, and the tiling stays exact.
    func testMultipleBadgesEachRealizeTheFullMinimumArea() {
        let huge = SizeTree(id: "root/huge", name: "huge", kind: .dir,
                            allocatedBytes: 1_000_000_000, logicalBytes: 1_000_000_000)
        let denied = (1...3).map {
            SizeTree(id: "root/d\($0)", name: "d\($0)", kind: .denied,
                     allocatedBytes: 1, logicalBytes: 1, scanState: .complete)
        }
        let root = SizeTree(id: "root", name: "root", kind: .dir,
                            allocatedBytes: 1_000_000_003, logicalBytes: 1_000_000_003,
                            children: [huge] + denied)
        let tiles = TreemapScene.layout(tree: root, viewport: viewport)

        for d in denied {
            let t = tiles.first { $0.nodeId == d.id }!
            XCTAssertEqual(t.rect.area, TreemapScene.minBadgeArea,
                           accuracy: TreemapScene.minBadgeArea * 1e-6,
                           "each of the \(denied.count) floored badges realizes the full minimum")
        }
        let inner = viewport.inset(by: TreemapScene.defaultBorderInset)
        let sum = tiles.filter { $0.dimLevel == 1 }.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(sum, inner.area, accuracy: inner.area * 1e-9 + 1e-6,
                       "multi-badge flooring keeps the exact partition")
    }

    // review-0 finding 3c + OPERATOR_NOTE #3.2 (DECISION denied_visibility_vs_render_bound):
    // FINITE PARENT CAPACITY preserves the render bound WITHOUT silently dropping any denied
    // node. Many denied siblings cannot each claim minBadgeArea in a small parent; at most
    // `maxFloored` badge slots exist, and the OVERFLOW collapses into ONE aggregate badge —
    // so the rendered badge count stays viewport-bounded while every denied node stays
    // REPRESENTED (per-fact visibility, not per-rectangle).
    func testDeniedOverflowCollapsesToSingleAggregateBadgePreservingRenderBound() {
        let small = Rect(x: 0, y: 0, width: 120, height: 120) // inner ≈ 116² ≈ 13 456
        let n = 200
        let denied = (0..<n).map {
            SizeTree(id: "root/d\($0)", name: "d\($0)", kind: .denied,
                     allocatedBytes: 1, logicalBytes: 1, scanState: .complete)
        }
        let root = SizeTree(id: "root", name: "root", kind: .dir,
                            allocatedBytes: Int64(n), logicalBytes: Int64(n), children: denied)
        let tiles = TreemapScene.layout(tree: root, focusId: "root",
                                        depthWindow: 5, viewport: small)
        let inner = small.inset(by: TreemapScene.defaultBorderInset)
        let maxFloored = Int((0.5 * inner.area / TreemapScene.minBadgeArea).rounded(.down))

        let denials = tiles.filter { $0.dimLevel == 1 && $0.kind == .denied }
        let aggregates = denials.filter { $0.deniedAggregateCount > 0 }
        let singles = denials.filter { $0.deniedAggregateCount == 0 }

        // EXACTLY ONE aggregate badge (the ratified representation).
        XCTAssertEqual(aggregates.count, 1, "overflow collapses to exactly one aggregate badge")
        // The render bound holds: badge tiles ≤ the capacity, NOT the 200 children.
        XCTAssertLessThanOrEqual(denials.count, maxFloored,
                                 "rendered denied badges are viewport-capacity-bounded (≤ \(maxFloored)), not \(n)")
        // NO denied node is silently culled: singles + the aggregate's count == every denial.
        XCTAssertEqual(singles.count + aggregates[0].deniedAggregateCount, n,
                       "every one of the \(n) denied nodes is represented (individually or in the aggregate)")
        // The aggregate is itself a readable badge, never sub-pixel.
        XCTAssertGreaterThanOrEqual(aggregates[0].rect.area, TreemapScene.minBadgeArea * 0.999,
                                    "the aggregate badge realizes at least the minimum badge area")
        // Tiling stays EXACT across the placed tiles (individual badges + the aggregate).
        let sum = tiles.filter { $0.dimLevel == 1 }.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(sum, inner.area, accuracy: inner.area * 1e-9 + 1e-6,
                       "exact partition holds even at capacity with an aggregate")
    }

    // OPERATOR_NOTE #3.2: overflow behind a HUGE sibling. The aggregate must be a FLOORED badge
    // (area == minBadgeArea), never sub-pixel — so it survives the downstream cull even when a
    // giant real folder would squeeze its proportional area to nothing. And the individually
    // floored denied badges each still realize exactly the minimum (rider 1 unbroken).
    func testDeniedOverflowAggregateIsFlooredEvenBehindAHugeSibling() {
        let small = Rect(x: 0, y: 0, width: 60, height: 60) // inner = 56² = 3136 → maxFloored = 4
        let huge = SizeTree(id: "root/huge", name: "huge", kind: .dir,
                            allocatedBytes: 1_000_000_000, logicalBytes: 1_000_000_000)
        let denied = (0..<10).map {
            SizeTree(id: "root/d\($0)", name: "d\($0)", kind: .denied,
                     allocatedBytes: 1, logicalBytes: 1, scanState: .complete)
        }
        let root = SizeTree(id: "root", name: "root", kind: .dir,
                            allocatedBytes: 1_000_000_010, logicalBytes: 1_000_000_010,
                            children: [huge] + denied)
        let tiles = TreemapScene.layout(tree: root, focusId: "root", depthWindow: 5, viewport: small)
        let inner = small.inset(by: TreemapScene.defaultBorderInset)
        let maxFloored = Int((0.5 * inner.area / TreemapScene.minBadgeArea).rounded(.down))

        let aggregate = tiles.first { $0.deniedAggregateCount > 0 }
        XCTAssertNotNil(aggregate, "overflow of 10 denied past capacity \(maxFloored) yields an aggregate")
        XCTAssertEqual(aggregate?.rect.area ?? 0, TreemapScene.minBadgeArea,
                       accuracy: TreemapScene.minBadgeArea * 1e-6,
                       "the aggregate is a floored badge (exactly minBadgeArea) even behind a 1 GB sibling")
        let singles = tiles.filter { $0.dimLevel == 1 && $0.kind == .denied && $0.deniedAggregateCount == 0 }
        for s in singles {
            XCTAssertEqual(s.rect.area, TreemapScene.minBadgeArea, accuracy: TreemapScene.minBadgeArea * 1e-6,
                           "each individually floored denied badge still realizes the minimum (rider 1)")
        }
        XCTAssertEqual(singles.count + (aggregate?.deniedAggregateCount ?? 0), 10,
                       "all 10 denied nodes represented (no silent cull)")
        // The aggregate's synthetic id resolves back to the parent for the App's click disclosure.
        XCTAssertEqual(TreemapScene.deniedAggregateParentId(from: aggregate!.nodeId), "root",
                       "the aggregate id round-trips to its parent id")
        XCTAssertNil(TreemapScene.deniedAggregateParentId(from: "root/huge"),
                     "a real node id is not mistaken for an aggregate")
    }

    // review-1 finding 1: SMALL-PARENT boundary. When the inner area is below what the badge
    // floor can grant under the fraction cap (here innerArea ≈ 324 < minBadgeArea = 384), the
    // floor CANNOT be applied without either exceeding the 50 % cap or driving the weight
    // denominator negative — the old `max(1, …)` did the latter, producing a negative weight
    // Squarify clamped to ZERO, so the denied badge VANISHED. The fix floors nothing here: the
    // denied child keeps its raw (small but POSITIVE) proportional area, and tiling stays exact.
    func testDeniedBadgeInTinyParentKeepsPositiveAreaNeverVanishes() {
        let tiny = Rect(x: 0, y: 0, width: 22, height: 22) // inner = 18×18 = 324 < minBadgeArea
        let inner = tiny.inset(by: TreemapScene.defaultBorderInset)
        XCTAssertLessThan(inner.area, TreemapScene.minBadgeArea,
                          "precondition: inner area is below the badge floor (the negative-denom regime)")

        let ordinary = SizeTree(id: "root/data", name: "data", kind: .dir,
                                allocatedBytes: 3, logicalBytes: 3)
        let denied = SizeTree(id: "root/denied", name: "denied", kind: .denied,
                              allocatedBytes: 1, logicalBytes: 1, scanState: .complete)
        let root = SizeTree(id: "root", name: "root", kind: .dir,
                            allocatedBytes: 4, logicalBytes: 4, children: [ordinary, denied])
        let tiles = TreemapScene.layout(tree: root, focusId: "root", depthWindow: 5, viewport: tiny)

        let deniedTile = tiles.first { $0.nodeId == "root/denied" }!
        // The badge is NOT floored (the parent is too small); it keeps its raw proportional
        // share of 1/(3+1) of the inner area. The regression: it is POSITIVE and present,
        // never clamped to zero by a negative weight.
        XCTAssertGreaterThan(deniedTile.rect.area, 0,
                             "the denied badge keeps a positive area — never vanishes via a negative weight (finding 1)")
        XCTAssertEqual(deniedTile.rect.area, inner.area / 4, accuracy: inner.area * 1e-6,
                       "un-floored, the badge holds its raw proportional (1/4) share")
        XCTAssertLessThanOrEqual(deniedTile.rect.area, TreemapScene.minBadgeArea,
                                 "no floor is applied in a parent too small to grant one under the cap")

        // Tiling stays exact — no negative weight perturbed the partition.
        let sum = tiles.filter { $0.dimLevel == 1 }.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(sum, inner.area, accuracy: inner.area * 1e-9 + 1e-6,
                       "the two children still tile the inset parent exactly")
    }

    // review-0 finding 4, regression 2: FOCUS-RELATIVE RE-TINT. A node's hue depends on
    // its LEVEL RELATIVE TO THE CURRENT FOCUS: focused deep, the focus's children are hue
    // ROOTS (their own name → hue); the SAME node inherits its ancestor's hue when it is
    // instead a deep descendant of the root focus. So diving re-tints (PLAN §Visual
    // language "subfolders get THEIR OWN tints").
    func testFocusRelativeReTintAtDepth() {
        let tree = sampleTree()
        // Focused at the ROOT: "a/sub" is a level-2 descendant of A → it INHERITS A's hue.
        let atRoot = TreemapScene.layout(tree: tree, focusId: "root", viewport: viewport)
        let subAtRoot = atRoot.first { $0.nodeId == "a/sub" }!
        XCTAssertEqual(subAtRoot.dimLevel, 2)
        XCTAssertEqual(subAtRoot.hue, TileColor.hue(for: "A"), accuracy: 1e-12,
                       "deep under the root focus, a/sub inherits its top-level ancestor A's hue")

        // Focused at A: "a/sub" is now a top-level (level-1) tile → its OWN name drives hue.
        let atA = TreemapScene.layout(tree: tree, focusId: "A", viewport: viewport)
        let subAtA = atA.first { $0.nodeId == "a/sub" }!
        XCTAssertEqual(subAtA.dimLevel, 1)
        XCTAssertEqual(subAtA.hue, TileColor.hue(for: "a/sub"), accuracy: 1e-12,
                       "focused into A, a/sub is a hue root — re-tinted to its own name's hue")
        XCTAssertNotEqual(subAtA.hue, subAtRoot.hue, accuracy: 1e-12,
                          "the same node shows a DIFFERENT hue at a different focus (re-tint)")
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

    // TZ-4b review-4 change 3: the denied-overflow disclosure CONTENT (what the aggregate's click
    // popover shows) is resolved by the PURE `deniedInventory` (contract v2: FULL denied
    // inventory of the parent, floored badges included), so it is pinned here rather than
    // in the untestable AppKit popover. Names are the denied children's, sorted; the implied size
    // is the SUM of those denied nodes' known bytes (a lower bound — contents unreadable); real
    // (non-denied) children contribute NEITHER a name NOR bytes.
    func testDeniedDisclosureListsDeniedNamesAndImpliedLowerBoundSize() {
        let parent = SizeTree(
            id: "root/locked", name: "locked", kind: .dir,
            allocatedBytes: 999, logicalBytes: 999,
            children: [
                SizeTree(id: "root/locked/z", name: "z", kind: .denied, allocatedBytes: 30, logicalBytes: 30, scanState: .complete),
                SizeTree(id: "root/locked/a", name: "a", kind: .denied, allocatedBytes: 20, logicalBytes: 20, scanState: .complete),
                SizeTree(id: "root/locked/open", name: "open", kind: .dir, allocatedBytes: 500, logicalBytes: 500),
                SizeTree(id: "root/locked/m", name: "m", kind: .denied, allocatedBytes: 10, logicalBytes: 10, scanState: .complete),
            ])
        let d = TreemapScene.deniedInventory(under: parent)
        XCTAssertEqual(d.names, ["a", "m", "z"], "denied child names only, sorted; the real 'open' dir excluded")
        XCTAssertEqual(d.impliedBytes, 60,
                       "implied size is the sum of the denied dirs' KNOWN bytes (30+20+10) — a lower bound, real child excluded")
    }
}
