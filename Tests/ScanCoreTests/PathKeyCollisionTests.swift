//
//  PathKeyCollisionTests.swift — TZ-9 review-0 change 2: EXACT hash-collision resolution.
//  Module maturity: PROTOTYPE (slice TZ-9)
//
//  The lean node store (TZ-9) keys its id→slot map by a 128-bit hash of the opaque id (PathKey),
//  NOT by the path string, to drop one of the three retained path copies the field report named
//  (THE MEMORY LAW). The public-API guarantee is unchanged from the pre-TZ-9 `[String: Node]` store:
//  TWO DISTINCT IDS MUST NEVER RESOLVE TO ONE NODE. A 128-bit hash cannot guarantee that alone, so the
//  reducer resolves collisions EXACTLY — a side table of same-key slots, and an `id`-verify on every
//  lookup (review-0 change 1).
//
//  A real FNV-128 collision is not constructible in a test, so these tests use the reducer's narrowly
//  scoped INTERNAL test seam (`init(rootId:rootName:rawHashForTesting:)`, reachable only via
//  `@testable import`) to FORCE two distinct ids ("/r/A" and "/r/B") onto one 128-bit key, and prove
//  they stay distinct through `apply`, `makeTree`, lookup, and prune. Production always uses the real
//  FNV-128 hash (the seam is nil), so this changes no shipping behavior — it only makes the
//  otherwise-unreachable collision branch deterministically testable.
//

import XCTest
@testable import ScanCore

final class PathKeyCollisionTests: XCTestCase {

    /// The two ids the test forces onto ONE key. Everything else hashes uniquely.
    private static let collidingA = "/r/A"
    private static let collidingB = "/r/B"

    /// A hasher that maps `collidingA` and `collidingB` to the SAME 128-bit key `(7, 7)` and every
    /// other id to a deterministic distinct key (a plain FNV-1a, split into two lanes). This is the
    /// forced collision the real 128-bit hash would (practically) never produce.
    private static func collidingHash(_ id: String) -> (UInt64, UInt64) {
        if id == collidingA || id == collidingB { return (7, 7) }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return (h, h &* 0x9e37_79b9_7f4a_7c15)
    }

    /// Build a reducer whose two children "/r/A" (own 100/90) and "/r/B" (own 200/190) share a key.
    private func makeCollidingReducer() -> ScanReducer {
        var r = ScanReducer(rootId: "/r", rootName: "r", rawHashForTesting: Self.collidingHash)
        r.apply([
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: Self.collidingA, name: "A", kind: .file),
                ChildStub(id: Self.collidingB, name: "B", kind: .file),
            ]),
            .sizeUpdated(nodeId: Self.collidingA, allocated: 100, logical: 90),
            .sizeUpdated(nodeId: Self.collidingB, allocated: 200, logical: 190),
            .subtreeCompleted(nodeId: "/r"),
        ])
        return r
    }

    /// Two distinct ids that collide on the map key remain two DISTINCT nodes through `apply`,
    /// lookup, and `makeTree`: distinct own sizes, distinct tree tiles, and both counted.
    func testCollidingIdsStayDistinct() {
        let r = makeCollidingReducer()

        // Lookup resolves each id to ITS OWN node (a merge would give both the same size).
        XCTAssertTrue(r.contains(Self.collidingA))
        XCTAssertTrue(r.contains(Self.collidingB))
        XCTAssertEqual(r.ownSize(of: Self.collidingA).map { [$0.allocated, $0.logical] }, [100, 90])
        XCTAssertEqual(r.ownSize(of: Self.collidingB).map { [$0.allocated, $0.logical] }, [200, 190])

        // Both nodes are counted (a merge would have collapsed the count to 1).
        XCTAssertEqual(r.processedCount, 2)

        // The tree carries BOTH tiles, each with its own id/name/size, and the root sums both.
        let tree = r.makeTree()
        XCTAssertEqual(tree.children.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: tree.children.map { ($0.id, $0) })
        XCTAssertEqual(byId[Self.collidingA]?.name, "A")
        XCTAssertEqual(byId[Self.collidingB]?.name, "B")
        XCTAssertEqual(byId[Self.collidingA]?.allocatedBytes, 100)
        XCTAssertEqual(byId[Self.collidingB]?.allocatedBytes, 200)
        XCTAssertEqual(tree.allocatedBytes, 300) // root own 0 + A 100 + B 200
    }

    /// Pruning the SIDE-TABLE colliding id ("/r/B" — second inserted) leaves the primary ("/r/A")
    /// intact, and the pruned id is genuinely gone (not aliased to the survivor via the shared key).
    func testPruneCollidingSideTableEntry() {
        var r = makeCollidingReducer()
        r.apply(.childRemoved(parentId: "/r", childId: Self.collidingB))

        XCTAssertFalse(r.contains(Self.collidingB), "pruned id must not alias the surviving colliding id")
        XCTAssertTrue(r.contains(Self.collidingA))
        XCTAssertEqual(r.ownSize(of: Self.collidingA).map { [$0.allocated, $0.logical] }, [100, 90])
        XCTAssertNil(r.ownSize(of: Self.collidingB))
        XCTAssertEqual(r.processedCount, 1)

        let tree = r.makeTree()
        XCTAssertEqual(tree.children.map(\.id), [Self.collidingA])
        XCTAssertEqual(tree.allocatedBytes, 100)
    }

    /// Pruning the PRIMARY colliding id ("/r/A" — first inserted, held in `index`) must PROMOTE the
    /// side-table entry ("/r/B") into the primary slot so it stays reachable — the removeSubtree
    /// promotion branch. This is the case a naive `index[key] = nil` would silently lose.
    func testPruneCollidingPrimaryPromotesSurvivor() {
        var r = makeCollidingReducer()
        r.apply(.childRemoved(parentId: "/r", childId: Self.collidingA))

        XCTAssertFalse(r.contains(Self.collidingA))
        XCTAssertTrue(r.contains(Self.collidingB), "survivor must be promoted out of the collision side table")
        XCTAssertEqual(r.ownSize(of: Self.collidingB).map { [$0.allocated, $0.logical] }, [200, 190])
        XCTAssertNil(r.ownSize(of: Self.collidingA))
        XCTAssertEqual(r.processedCount, 1)

        let tree = r.makeTree()
        XCTAssertEqual(tree.children.map(\.id), [Self.collidingB])
        XCTAssertEqual(tree.allocatedBytes, 200)
    }
}
