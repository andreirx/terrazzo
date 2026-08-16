//
//  ScanReducerTests.swift — the reducer's defining properties.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  The reducer is the concurrency boundary's safe side (ratified decision 5).
//  These tests pin the four properties the slice demands:
//    1. INTERLEAVING INVARIANCE — identical tree for ANY order of subtree batches
//       (shuffled many ways with a seeded PRNG).
//    2. AGGREGATION — a node's allocated/logical is the full recursive sum.
//    3. DENIED PROPAGATION — an accessDenied node is kind .denied, state .complete,
//       and does not corrupt ancestor totals.
//    4. DEPTH-WINDOW FOLDING — detail beyond the window is dropped from the tree
//       but its bytes still count in the ancestor totals (sizes true, decision 4).
//

import XCTest
@testable import ScanCore

final class ScanReducerTests: XCTestCase {

    // A fixed set of subtree-tagged batches describing this tree:
    //   /r (own 10)
    //     /r/a (own 4)   → f1 (100), f2 (200)          complete
    //     /r/b (own 4)   → g1 (50)                      complete
    //     /r/c (own 4)   → DENIED
    private func batches() -> [[ScanEvent]] {
        let rootBatch: [ScanEvent] = [
            .sizeUpdated(nodeId: "/r", allocated: 10, logical: 10),
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir),
                ChildStub(id: "/r/b", name: "b", kind: .dir),
                ChildStub(id: "/r/c", name: "c", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4),
            .sizeUpdated(nodeId: "/r/b", allocated: 4, logical: 4),
            .sizeUpdated(nodeId: "/r/c", allocated: 4, logical: 4),
        ]
        let aBatch: [ScanEvent] = [
            .childrenDiscovered(parentId: "/r/a", children: [
                ChildStub(id: "/r/a/f1", name: "f1", kind: .file),
                ChildStub(id: "/r/a/f2", name: "f2", kind: .file),
            ]),
            .sizeUpdated(nodeId: "/r/a/f1", allocated: 100, logical: 90),
            .sizeUpdated(nodeId: "/r/a/f2", allocated: 200, logical: 190),
            .subtreeCompleted(nodeId: "/r/a"),
        ]
        let bBatch: [ScanEvent] = [
            .childrenDiscovered(parentId: "/r/b", children: [
                ChildStub(id: "/r/b/g1", name: "g1", kind: .file),
            ]),
            .sizeUpdated(nodeId: "/r/b/g1", allocated: 50, logical: 40),
            .subtreeCompleted(nodeId: "/r/b"),
        ]
        let cBatch: [ScanEvent] = [.accessDenied(nodeId: "/r/c")]
        let rootDone: [ScanEvent] = [.subtreeCompleted(nodeId: "/r")]
        return [rootBatch, aBatch, bBatch, cBatch, rootDone]
    }

    private func reduce(_ order: [[ScanEvent]]) -> SizeTree {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        for batch in order { r.apply(batch) }
        return r.makeTree(depthWindow: 10)
    }

    private func child(_ tree: SizeTree, _ id: String) -> SizeTree? {
        if tree.id == id { return tree }
        for c in tree.children { if let f = child(c, id) { return f } }
        return nil
    }

    // MARK: 1. Interleaving invariance

    func testIdenticalTreeForAnyBatchInterleaving() {
        let reference = reduce(batches())
        // Deterministic PRNG (same style as SquarifyTests) → reproducible shuffles.
        var state: UInt64 = 0xD1B54A32D192ED03
        func rand(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        for _ in 0..<200 {
            var order = batches()
            // Fisher–Yates with the seeded PRNG.
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                order.swapAt(i, rand(i + 1))
            }
            XCTAssertEqual(reduce(order), reference,
                           "tree must be identical for any interleaving of subtree batches")
        }
    }

    // MARK: 2. Aggregation

    func testAllocatedAndLogicalAreFullRecursiveSums() {
        let t = reduce(batches())
        // /r/a = own 4 + 100 + 200 = 304 alloc; 4 + 90 + 190 = 284 logical
        XCTAssertEqual(child(t, "/r/a")!.allocatedBytes, 304)
        XCTAssertEqual(child(t, "/r/a")!.logicalBytes, 284)
        // /r/b = 4 + 50 = 54 alloc
        XCTAssertEqual(child(t, "/r/b")!.allocatedBytes, 54)
        // /r/c denied = own 4 only (contents unknown)
        XCTAssertEqual(child(t, "/r/c")!.allocatedBytes, 4)
        // root = 10 + 304 + 54 + 4 = 372
        XCTAssertEqual(t.allocatedBytes, 372)
    }

    // MARK: 3. Denied propagation

    func testDeniedNodeIsKindDeniedAndComplete() {
        let t = reduce(batches())
        let c = child(t, "/r/c")!
        XCTAssertEqual(c.kind, .denied, "an accessDenied node must render as denied, not ordinary dir")
        XCTAssertEqual(c.scanState, .complete, "we are done with a denied node — nothing more to scan")
        XCTAssertTrue(c.children.isEmpty)
        // Denial of one child does not corrupt sibling or ancestor totals.
        XCTAssertEqual(t.allocatedBytes, 372)
    }

    func testDeniedWinsRegardlessOfEventOrder() {
        // denied applied BEFORE the size/stub for the same node, and AFTER — both
        // must yield kind .denied (denial is a flag, order-independent).
        var before = ScanReducer(rootId: "/r", rootName: "r")
        before.apply([.accessDenied(nodeId: "/r/c")])
        before.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/c", name: "c", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/c", allocated: 4, logical: 4)])
        XCTAssertEqual(child(before.makeTree(depthWindow: 10), "/r/c")!.kind, .denied)
    }

    // MARK: 4. Depth-window folding

    func testDepthWindowFoldsDetailButKeepsTotals() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        for batch in batches() { r.apply(batch) }

        let deep = r.makeTree(depthWindow: 10)
        let shallow = r.makeTree(depthWindow: 1)

        // Window 1: root (depth 0) keeps its children; those children (depth 1)
        // are folded — their own children dropped.
        XCTAssertEqual(shallow.children.count, 3, "root's children retained at window 1")
        let aShallow = child(shallow, "/r/a")!
        XCTAssertTrue(aShallow.children.isEmpty, "detail below the window is folded away")

        // ...but totals are UNCHANGED by the window (sizes true, decision 4).
        XCTAssertEqual(shallow.allocatedBytes, deep.allocatedBytes)
        XCTAssertEqual(aShallow.allocatedBytes, child(deep, "/r/a")!.allocatedBytes) // still 304
        XCTAssertEqual(aShallow.allocatedBytes, 304)
    }

    // MARK: Out-of-order arrival (size before stub)

    func testSizeBeforeStubStillLinksAndAggregates() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        // A child's size arrives before its parent even discovers it.
        r.apply([.sizeUpdated(nodeId: "/r/a/f1", allocated: 100, logical: 90)])
        r.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/a", name: "a", kind: .dir)])])
        r.apply([.childrenDiscovered(parentId: "/r/a", children: [
            ChildStub(id: "/r/a/f1", name: "f1", kind: .file)])])
        let t = r.makeTree(depthWindow: 10)
        XCTAssertEqual(child(t, "/r/a/f1")!.allocatedBytes, 100)
        XCTAssertEqual(child(t, "/r/a")!.allocatedBytes, 100)
        XCTAssertEqual(child(t, "/r/a/f1")!.kind, .file)
    }
}
