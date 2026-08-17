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

    // MARK: - Root promotion: full-state re-root graft (TZ-4b layer a)

    /// The graft preserves the ENTIRE scanned subtree — identity, sizes, and scanStates —
    /// exactly, under a new parent root. Nothing discarded, nothing re-counted.
    func testReRootGraftsSubtreeExactly() {
        var r = ScanReducer(rootId: "/Users/apple", rootName: "apple")
        r.apply([
            .sizeUpdated(nodeId: "/Users/apple", allocated: 10, logical: 10),
            .childrenDiscovered(parentId: "/Users/apple", children: [
                ChildStub(id: "/Users/apple/Docs", name: "Docs", kind: .dir),
                ChildStub(id: "/Users/apple/secret", name: "secret", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "/Users/apple/Docs", allocated: 4, logical: 4),
            .childrenDiscovered(parentId: "/Users/apple/Docs", children: [
                ChildStub(id: "/Users/apple/Docs/a.txt", name: "a.txt", kind: .file),
            ]),
            .sizeUpdated(nodeId: "/Users/apple/Docs/a.txt", allocated: 100, logical: 90),
            .subtreeCompleted(nodeId: "/Users/apple/Docs"),
            .accessDenied(nodeId: "/Users/apple/secret"), // a denied child — scanState must survive
            .sizeUpdated(nodeId: "/Users/apple/secret", allocated: 4, logical: 4),
            .subtreeCompleted(nodeId: "/Users/apple"),
        ])
        let before = r.makeTree(depthWindow: 10)
        let beforeCount = r.processedCount

        r.reRoot(to: "/Users", newRootName: "Users")
        let after = r.makeTree(depthWindow: 10)

        XCTAssertEqual(after.id, "/Users", "the root is now the promoted parent")
        XCTAssertEqual(after.name, "Users")
        XCTAssertEqual(after.children.map(\.id), ["/Users/apple"],
                       "the only child so far is the grafted old root")
        // The grafted subtree is byte-identical (Equatable over id/name/kind/sizes/
        // children/scanState) — subtree identity, sizes, scan states all preserved.
        XCTAssertEqual(after.children[0], before,
                       "graft preserves the entire subtree exactly")
        // The denied child's kind + state survived the graft.
        let secret = after.children[0].children.first { $0.id == "/Users/apple/secret" }
        XCTAssertEqual(secret?.kind, .denied)
        XCTAssertEqual(secret?.scanState, .complete)
        // Nothing re-stat'd — the numerator is unchanged by a graft.
        XCTAssertEqual(r.processedCount, beforeCount,
                       "the graft transfers state; it does not re-stat anything")
        // Root total preserved (new root own size 0 until walked + grafted total).
        XCTAssertEqual(after.allocatedBytes, before.allocatedBytes)
    }

    /// After the graft, NEW siblings fold in normally and never disturb the grafted
    /// subtree — the reducer's order-independence holds across the re-root.
    func testReRootThenNewSiblingsMergeWithoutDisturbingGraft() {
        var r = ScanReducer(rootId: "/Users/apple", rootName: "apple")
        r.apply([
            .sizeUpdated(nodeId: "/Users/apple", allocated: 10, logical: 10),
            .childrenDiscovered(parentId: "/Users/apple", children: [
                ChildStub(id: "/Users/apple/Docs", name: "Docs", kind: .dir)]),
            .sizeUpdated(nodeId: "/Users/apple/Docs", allocated: 40, logical: 40),
            .subtreeCompleted(nodeId: "/Users/apple/Docs"),
            .subtreeCompleted(nodeId: "/Users/apple"),
        ])
        let appleBefore = r.makeTree(depthWindow: 10)

        r.reRoot(to: "/Users", newRootName: "Users")
        // The sibling-exclusion walk emits: new root own size, a childrenDiscovered that
        // RE-STATES the grafted child's stub (idempotent) + the new sibling, its size,
        // completion.
        r.apply([
            .sizeUpdated(nodeId: "/Users", allocated: 8, logical: 8),
            .childrenDiscovered(parentId: "/Users", children: [
                ChildStub(id: "/Users/apple", name: "apple", kind: .dir),  // graft reference
                ChildStub(id: "/Users/shared", name: "shared", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "/Users/shared", allocated: 50, logical: 50),
            .subtreeCompleted(nodeId: "/Users/shared"),
            .subtreeCompleted(nodeId: "/Users"),
        ])
        let after = r.makeTree(depthWindow: 10)

        XCTAssertEqual(after.children.map(\.id).sorted(), ["/Users/apple", "/Users/shared"])
        // The grafted apple subtree is STILL byte-identical after siblings folded.
        XCTAssertEqual(after.children.first { $0.id == "/Users/apple" }, appleBefore,
                       "re-stating the graft stub is idempotent — the subtree is untouched")
        // Root total = new root own 8 + apple(50) + shared(50) = 108.
        XCTAssertEqual(after.allocatedBytes, 8 + appleBefore.allocatedBytes + 50)
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

    // MARK: Focus-rooted projection equivalence (TZ-4b OPERATOR_NOTE 2026-08-16 #2)

    /// The focus-rooted projection is BYTE-IDENTICAL to the old behavior — build the whole
    /// tree from the scan root windowed to (focusDepth + window), then navigate to the focus
    /// — for the SAME focus. This is the equivalence the operator required when authorizing
    /// focus-rooted projection (the cycle-3 escalate resolution): only the WORK differs
    /// (O(focus subtree ∩ window) vs O(retained nodes)); the projected value is the same.
    /// Pinned across EVERY node and several windows, including window 0 and windows past the
    /// tree's depth, so the depth-window boundary-sum path (`subtreeTotals`) is exercised.
    func testFocusRootedProjectionEqualsWindowedFullBuild() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        // A deep spine /r/a/b/c/d/e/f PLUS sibling files carrying mass below various windows,
        // so a focus's total must count descendants folded beyond the window (sizes true).
        r.apply([
            .sizeUpdated(nodeId: "/r", allocated: 1, logical: 1),
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir),
                ChildStub(id: "/r/z", name: "z", kind: .file)]),
            .sizeUpdated(nodeId: "/r/z", allocated: 3000, logical: 3000),
            .sizeUpdated(nodeId: "/r/a", allocated: 2, logical: 2),
            .childrenDiscovered(parentId: "/r/a", children: [
                ChildStub(id: "/r/a/b", name: "b", kind: .dir),
                ChildStub(id: "/r/a/y", name: "y", kind: .file)]),
            .sizeUpdated(nodeId: "/r/a/y", allocated: 2000, logical: 2000),
            .sizeUpdated(nodeId: "/r/a/b", allocated: 3, logical: 3),
            .childrenDiscovered(parentId: "/r/a/b", children: [
                ChildStub(id: "/r/a/b/c", name: "c", kind: .dir),
                ChildStub(id: "/r/a/b/x", name: "x", kind: .file)]),
            .sizeUpdated(nodeId: "/r/a/b/x", allocated: 1000, logical: 1000),
            .sizeUpdated(nodeId: "/r/a/b/c", allocated: 4, logical: 4),
            .childrenDiscovered(parentId: "/r/a/b/c", children: [
                ChildStub(id: "/r/a/b/c/d", name: "d", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/a/b/c/d", allocated: 5, logical: 5),
            .childrenDiscovered(parentId: "/r/a/b/c/d", children: [
                ChildStub(id: "/r/a/b/c/d/e", name: "e", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/a/b/c/d/e", allocated: 6, logical: 6),
            .childrenDiscovered(parentId: "/r/a/b/c/d/e", children: [
                ChildStub(id: "/r/a/b/c/d/e/f", name: "f", kind: .file)]),
            .sizeUpdated(nodeId: "/r/a/b/c/d/e/f", allocated: 100, logical: 100),
            .subtreeCompleted(nodeId: "/r"),
        ])

        // depth of an id = separators beyond the root's.
        let rootSeps = "/r".filter { $0 == "/" }.count
        func depth(_ id: String) -> Int { id.filter { $0 == "/" }.count - rootSeps }
        let ids = ["/r", "/r/a", "/r/a/b", "/r/a/b/c", "/r/a/b/c/d",
                   "/r/a/b/c/d/e", "/r/a/b/c/d/e/f", "/r/z", "/r/a/y", "/r/a/b/x"]

        for id in ids {
            for window in [0, 1, 2, 3, 5, 10] {
                let full = r.makeTree(depthWindow: depth(id) + window)
                guard let navigated = full.node(withId: id) else {
                    return XCTFail("\(id) missing from the windowed full build")
                }
                let focusRooted = r.makeTree(focusId: id, depthWindow: window)
                XCTAssertEqual(focusRooted, navigated,
                    "focus-rooted(\(id), window=\(window)) must equal windowed full-build navigated to \(id)")
            }
        }

        // And the scan-root total the status bar reads is focus-independent.
        // /r own 1 + z 3000 + a(own 2 + y 2000 + b(own 3 + x 1000 + c/d/e/f chain 4+5+6+100)).
        let expectedRootTotal: Int64 = 1 + 3000 + 2 + 2000 + 3 + 1000 + 4 + 5 + 6 + 100
        XCTAssertEqual(r.rootAllocatedBytes, expectedRootTotal,
            "rootAllocatedBytes is the whole scan-root total regardless of focus")
        XCTAssertEqual(r.makeTree().allocatedBytes, expectedRootTotal,
            "the whole-tree projection's root total matches rootAllocatedBytes")
    }

    /// REVIEW-3 REGRESSION GUARD. A focus whose retained descendants extend FAR beyond the
    /// projection window: a depth-10 spine under `/r/a` with almost all the mass at the very
    /// bottom, plus sibling files at several depths. The earlier boundary code summed those
    /// hidden descendants with a recursive walk (`subtreeTotals`), so a small-window dive still
    /// paid O(whole subtree) — the flat-fill latency the operator ruling targeted. Retained
    /// subtree totals fix that: this test pins the two properties that together prove it.
    ///
    ///  (1) EXACTNESS — a window far shallower than the retained depth still reports the EXACT
    ///      full total (the deep bottom mass is counted), and equals the windowed full-build
    ///      navigated to the focus, for every window from 0 up.
    ///  (2) SCOPED MATERIALIZATION — the projected tree contains ONLY nodes within the window;
    ///      its materialized node count is a function of the window, NOT of the retained depth
    ///      below it. That is the observable signature of "did not traverse beyond the window":
    ///      a window-1 dive on this deep spine materializes the focus + its direct children and
    ///      nothing deeper, while still totaling the mass 9 levels down.
    func testFocusWithDescendantsFarBeyondWindow() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        var events: [ScanEvent] = [
            .sizeUpdated(nodeId: "/r", allocated: 1, logical: 1),
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/a", allocated: 2, logical: 2),
        ]
        // A depth-10 spine /r/a/d1/…/d10, each dir owning 10 bytes, plus a `leafN` file at each
        // level carrying 100·N bytes, and a big 1_000_000-byte file at the very bottom.
        var parent = "/r/a"
        var expectedFocusTotal: Int64 = 2 // /r/a own
        for depth in 1...10 {
            let dir = "\(parent)/d\(depth)"
            let leaf = "\(parent)/leaf\(depth)"
            events.append(.childrenDiscovered(parentId: parent, children: [
                ChildStub(id: dir, name: "d\(depth)", kind: .dir),
                ChildStub(id: leaf, name: "leaf\(depth)", kind: .file)]))
            events.append(.sizeUpdated(nodeId: dir, allocated: 10, logical: 10))
            let leafBytes = Int64(100 * depth)
            events.append(.sizeUpdated(nodeId: leaf, allocated: leafBytes, logical: leafBytes))
            expectedFocusTotal += 10 + leafBytes
            parent = dir
        }
        let bottomFile = "\(parent)/big"
        events.append(.childrenDiscovered(parentId: parent, children: [
            ChildStub(id: bottomFile, name: "big", kind: .file)]))
        events.append(.sizeUpdated(nodeId: bottomFile, allocated: 1_000_000, logical: 1_000_000))
        expectedFocusTotal += 1_000_000
        r.apply(events)

        // (1) EXACTNESS at every window, including windows FAR below the retained depth (10+).
        for window in [0, 1, 2, 5, 20] {
            let focusRooted = r.makeTree(focusId: "/r/a", depthWindow: window)
            XCTAssertEqual(focusRooted.allocatedBytes, expectedFocusTotal,
                "window=\(window): the focus total must count the mass 10 levels down, from " +
                "retained state — not from a beyond-window traversal")
            // Equivalence to the old full-build-then-navigate for the same focus.
            let full = r.makeTree(depthWindow: 1 + window) // /r/a sits at depth 1 under the root
            XCTAssertEqual(focusRooted, full.node(withId: "/r/a"),
                "window=\(window): focus-rooted must equal windowed full-build navigated to /r/a")
        }

        // (2) SCOPED MATERIALIZATION — node count is bounded by the window, not the retained depth.
        func materializedDepth(_ t: SizeTree) -> Int {
            (t.children.map(materializedDepth).max() ?? -1) + 1
        }
        let w1 = r.makeTree(focusId: "/r/a", depthWindow: 1)
        XCTAssertEqual(materializedDepth(w1), 1,
            "window=1 materializes the focus + its direct children only — nothing deeper")
        // The focus's direct children (d1, leaf1) are present; the deep spine is folded away.
        XCTAssertEqual(w1.children.map(\.id).sorted(), ["/r/a/d1", "/r/a/leaf1"])
        // …yet d1's total still carries everything below it (the folded deep mass).
        let d1 = w1.children.first { $0.id == "/r/a/d1" }
        XCTAssertEqual(d1?.children.isEmpty, true, "d1 is at the window boundary — no children materialized")
        XCTAssertGreaterThan(d1!.allocatedBytes, 1_000_000,
            "d1's retained total still counts the 1 MB file nine levels beneath it")
    }

    /// REVIEW-3 SCALE GUARD, the WIDE-AND-DEEP shape the pipeline's 120k test could not reach
    /// (its dive target had only leaf children, all in-window). Here the focus has 300 child
    /// DIRECTORIES, each holding 400 files — ~120k nodes — and we project at window=1. Under the
    /// old boundary code each of the 300 directories sat AT the window edge, so `subtreeTotals`
    /// traversed all 400 of its files: ~120k arithmetic visits per projection, scaling with the
    /// retained subtree. With retained totals the 300 boundary directories are read in O(1) each,
    /// so a window-1 projection visits ~300 nodes regardless of the mass beneath. This test pins
    /// exactness at that scale and reports the measured projection time (the observable win).
    func testWindowedProjectionDoesNotScaleWithBeyondWindowMass() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        var events: [ScanEvent] = [
            .sizeUpdated(nodeId: "/r", allocated: 0, logical: 0),
            .childrenDiscovered(parentId: "/r", children:
                (0..<300).map { ChildStub(id: "/r/d\($0)", name: "d\($0)", kind: .dir) }),
        ]
        var whole: Int64 = 0
        for a in 0..<300 {
            let dir = "/r/d\(a)"
            events.append(.childrenDiscovered(parentId: dir, children:
                (0..<400).map { ChildStub(id: "\(dir)/f\($0)", name: "f\($0)", kind: .file) }))
            for b in 0..<400 {
                let bytes = Int64((b + 1) * 1000)
                whole += bytes
                events.append(.sizeUpdated(nodeId: "\(dir)/f\(b)", allocated: bytes, logical: bytes))
            }
        }
        r.apply(events)

        // Window=1 materializes /r + its 300 direct children, and nothing below them.
        let t0 = DispatchTime.now().uptimeNanoseconds
        let w1 = r.makeTree(depthWindow: 1)
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6

        XCTAssertEqual(w1.allocatedBytes, whole,
            "window=1 still totals the whole ~120k-node retained mass, from retained state")
        XCTAssertEqual(w1.children.count, 300)
        XCTAssertTrue(w1.children.allSatisfy { $0.children.isEmpty },
            "each of the 300 directories is at the window boundary — no files materialized")
        // Each boundary directory's total is exact even though its files were never materialized.
        let d0Total: Int64 = (1...400).reduce(0) { $0 + Int64($1 * 1000) }
        XCTAssertEqual(w1.children.first { $0.id == "/r/d0" }?.allocatedBytes, d0Total)
        // Node count is bounded by the window (301), NOT by the ~120k retained nodes.
        XCTAssertEqual(w1.nodeCount, 301)
        print("TZLATENCY window=1 projection over ~120k retained nodes: " +
              "\(String(format: "%.3f", ms)) ms (old boundary-traversal path was O(retained subtree))")
        XCTAssertLessThan(ms, 100.0,
            "a window-1 projection must not scale with the beyond-window mass (review-3)")
    }

    func testContainsReflectsRecordedNodes() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        XCTAssertTrue(r.contains("/r"), "the root is present from construction")
        XCTAssertFalse(r.contains("/r/a"), "a never-seen id is absent")
        r.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/a", name: "a", kind: .dir)])])
        XCTAssertTrue(r.contains("/r/a"), "a discovered id is present")
    }

    // MARK: - Ignore accounting (review-0 change 2): union rule, streaming-current

    /// The excluded figure is computed from CURRENT reducer state, so it GROWS as an ignored
    /// directory keeps receiving size events — the property a size-at-ignore snapshot could not
    /// have (the ignored node is dropped from later scenes, so a snapshot froze). Structure:
    /// root → dir A (ignored). A's own size arrives first small, then a child inflates it.
    func testIgnoreAccountingTracksStreamingGrowth() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.sizeUpdated(nodeId: "/r", allocated: 0, logical: 0),
                 .childrenDiscovered(parentId: "/r", children: [
                    ChildStub(id: "/r/A", name: "A", kind: .dir)]),
                 .sizeUpdated(nodeId: "/r/A", allocated: 100, logical: 100)])
        XCTAssertEqual(r.ignoreAccounting(["/r/A"]).total, 100,
                       "the excluded figure reflects A's retained total so far")
        // A directory child of A arrives LATER and inflates A's subtree total.
        r.apply([.childrenDiscovered(parentId: "/r/A", children: [
                    ChildStub(id: "/r/A/big", name: "big", kind: .dir)]),
                 .sizeUpdated(nodeId: "/r/A/big", allocated: 9_000, logical: 9_000)])
        XCTAssertEqual(r.ignoreAccounting(["/r/A"]).total, 9_100,
                       "the excluded figure GREW with the streaming subtree (not a frozen snapshot)")
        XCTAssertEqual(r.ignoreAccounting(["/r/A"]).currentById["/r/A"], 9_100,
                       "the per-row size is the live retained total too")
    }

    /// The UNION rule: ignoring BOTH an ancestor and one of its descendants must NOT double-count
    /// the overlapping mass — only the ancestor's subtree total is added (the descendant is
    /// subsumed). Structure: root → A → {x, y}; ignore A AND A/x.
    func testIgnoreAccountingDeduplicatesAncestorDescendantOverlap() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.sizeUpdated(nodeId: "/r", allocated: 0, logical: 0),
                 .childrenDiscovered(parentId: "/r", children: [
                    ChildStub(id: "/r/A", name: "A", kind: .dir)]),
                 .childrenDiscovered(parentId: "/r/A", children: [
                    ChildStub(id: "/r/A/x", name: "x", kind: .dir),
                    ChildStub(id: "/r/A/y", name: "y", kind: .dir)]),
                 .sizeUpdated(nodeId: "/r/A/x", allocated: 300, logical: 300),
                 .sizeUpdated(nodeId: "/r/A/y", allocated: 700, logical: 700),
                 .subtreeCompleted(nodeId: "/r")])
        // A's subtree total is 1000 (x 300 + y 700).
        XCTAssertEqual(r.ignoreAccounting(["/r/A"]).total, 1_000, "ancestor alone = its subtree total")
        XCTAssertEqual(r.ignoreAccounting(["/r/A/x"]).total, 300, "descendant alone = its own total")
        // Ignoring BOTH must still be 1000 — x's 300 is already inside A's 1000, not added again.
        XCTAssertEqual(r.ignoreAccounting(["/r/A", "/r/A/x"]).total, 1_000,
                       "ancestor+descendant is the UNION (1000), not the sum of snapshots (1300)")
        // Two INDEPENDENT (non-overlapping) ignores DO add up.
        XCTAssertEqual(r.ignoreAccounting(["/r/A/x", "/r/A/y"]).total, 1_000,
                       "two disjoint ignored siblings add up (no overlap to dedup)")
        // An ignored id the scan has not produced yet contributes 0 and reports 0 current bytes.
        let acct = r.ignoreAccounting(["/r/ghost"])
        XCTAssertEqual(acct.total, 0, "an un-retained ignored id contributes nothing")
        XCTAssertEqual(acct.currentById["/r/ghost"], 0, "and reports 0 current bytes")
    }

    /// `IgnorePath.isAncestor` — the pure path primitive the App's antichain normalization uses to
    /// keep the ignore set free of ancestor/descendant overlap (review-2 change 2). Boundary-checked
    /// on the separator, no self-ancestry, and correct for the volume root whose id is "/".
    func testIgnorePathAncestryIsBoundaryChecked() {
        XCTAssertTrue(IgnorePath.isAncestor("/Users", of: "/Users/apple"))
        XCTAssertTrue(IgnorePath.isAncestor("/Users", of: "/Users/apple/Library"), "transitive descendant")
        XCTAssertFalse(IgnorePath.isAncestor("/Users/apple", of: "/Users"), "not reversed")
        XCTAssertFalse(IgnorePath.isAncestor("/Users", of: "/Users"), "a node is not its own ancestor")
        // The bug a naive `hasPrefix` would introduce: a sibling sharing a name prefix.
        XCTAssertFalse(IgnorePath.isAncestor("/Users", of: "/UsersFoo"),
                       "prefix without a path boundary is NOT ancestry")
        XCTAssertFalse(IgnorePath.isAncestor("/a/b", of: "/a/bc"), "boundary-checked mid-path too")
        // The volume root "/" ends in the separator — it is an ancestor of every absolute path.
        XCTAssertTrue(IgnorePath.isAncestor("/", of: "/Users"))
        XCTAssertFalse(IgnorePath.isAncestor("/", of: "/"), "root is not its own ancestor")
    }

    // TZ-4b cycle-6: AREA-BOUNDED PROJECTION (`makeRenderTree`). A root with one big child and
    // MANY sub-pixel children: the projection must SKIP the sub-pixel subtrees (they would be
    // culled anyway) so its cost is O(visible), NOT O(all-in-window) — while keeping the big
    // child, keeping all totals exact, keeping every DENIED node, and REPORTING the drop count
    // (no silent truncation). This is the fix for the ~900 ms volume-root `makeTree` the live
    // measurement caught.
    func testAreaBoundedProjectionPrunesSubPixelSubtreesButKeepsVisibleAndDeniedAndTotals() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        let n = 500
        var stubs = [ChildStub(id: "/r/big", name: "big", kind: .dir),
                     ChildStub(id: "/r/locked", name: "locked", kind: .dir)]
        for i in 0..<n { stubs.append(ChildStub(id: "/r/t\(i)", name: "t\(i)", kind: .file)) }
        r.apply([.childrenDiscovered(parentId: "/r", children: stubs)])
        r.apply([.sizeUpdated(nodeId: "/r/big", allocated: 1_000_000_000, logical: 1_000_000_000)])
        r.apply([.sizeUpdated(nodeId: "/r/locked", allocated: 1, logical: 1),
                 .accessDenied(nodeId: "/r/locked")])
        for i in 0..<n { r.apply([.sizeUpdated(nodeId: "/r/t\(i)", allocated: 1, logical: 1)]) }

        let viewportArea = 1000.0 * 700.0
        let (tree, pruned, _) = r.makeRenderTree(focusId: "/r", depthWindow: 5,
                                                 minRenderArea: 4.0, viewportArea: viewportArea)
        let ids = Set(tree.children.map(\.id))

        // The big child renders and is kept; the 500 sub-pixel files are pruned.
        XCTAssertTrue(ids.contains("/r/big"), "the one visible (huge) child is materialized")
        XCTAssertEqual(pruned, n, "all \(n) sub-pixel files are pruned and REPORTED (no silent drop)")
        XCTAssertEqual(tree.children.filter { $0.id.hasPrefix("/r/t") }.count, 0,
                       "no sub-pixel file subtree is materialized")
        // A DENIED child is ALWAYS kept even though its own size is sub-pixel (badge, not measured).
        XCTAssertTrue(ids.contains("/r/locked"), "denied child kept regardless of sub-pixel size")
        XCTAssertEqual(tree.children.first { $0.id == "/r/locked" }?.kind, .denied)
        // Totals stay EXACT: the root's recursive total counts the pruned mass too (sizes true).
        XCTAssertEqual(tree.allocatedBytes, r.makeTree(focusId: "/r").allocatedBytes,
                       "area-bounded projection keeps the root total exact (pruned bytes still counted)")
        // The area-bounded tree is far smaller than the full windowed one — the O(visible) bound.
        XCTAssertLessThan(tree.nodeCount, r.makeTree(focusId: "/r").nodeCount,
                          "area-bounded projection materializes fewer nodes than the full window")
    }
    /// Review-4 (TZ-7) regression: the scan-root accumulator must track LIVE re-sizes,
    /// not only each node's first own-size write. Before the fix, a file growing from
    /// 100 -> 250 updated ancestor subtree totals but left rootAllocatedBytes at the
    /// first-write value — scannedBytes/status drifted from the truth in the living map.
    func testRootAllocatedTracksLiveResizeAndReplayAndPrune() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            .sizeUpdated(nodeId: "/r", allocated: 10, logical: 10),
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/f", name: "f", kind: .file),
                ChildStub(id: "/r/d", name: "d", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "/r/f", allocated: 100, logical: 100),
            .sizeUpdated(nodeId: "/r/d", allocated: 5, logical: 5),
        ])
        XCTAssertEqual(r.rootAllocatedBytes, 115, "first writes accumulate")
        // Live re-size: the whole point of TZ-7.
        r.apply([.sizeUpdated(nodeId: "/r/f", allocated: 250, logical: 250)])
        XCTAssertEqual(r.rootAllocatedBytes, 265, "re-size moves the root accumulator by the delta")
        // Replayed same-size batch: a no-op delta, robust to duplicates.
        r.apply([.sizeUpdated(nodeId: "/r/f", allocated: 250, logical: 250)])
        XCTAssertEqual(r.rootAllocatedBytes, 265, "replay is a no-op")
        // Shrink is a negative delta.
        r.apply([.sizeUpdated(nodeId: "/r/f", allocated: 50, logical: 50)])
        XCTAssertEqual(r.rootAllocatedBytes, 65, "shrink subtracts")
        // Prune stays symmetric with the accumulator.
        r.apply([.childRemoved(parentId: "/r", childId: "/r/f")])
        XCTAssertEqual(r.rootAllocatedBytes, 15, "prune removes the pruned own sizes exactly")
    }

}
