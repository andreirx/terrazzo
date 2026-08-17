//
//  LivingMapTests.swift — TZ-7 reducer vocabulary: prune, mtime, revalidation diff.
//  Module maturity: PROTOTYPE (slice TZ-7 — the living map)
//
//  Dry, reducer-level pins for the additive TZ-7 mechanics (PLAN §TZ-7):
//    1. `childRemoved` PRUNES the subtree and RIPPLES freed bytes up ancestors + out of the
//       scan-root accumulators (Scanned total, processed count) — the deleted-folder tile retires.
//    2. FOCUS FALLBACK: `nearestRetainedAncestor` finds the surviving ancestor a pruned focus falls
//       back to ("the map never points at a ghost").
//    3. `directoryMtime` + `ChildStub.mtime` set and project the staleness key (`SizeTree.mtime`).
//    4. `revalidationDiff` turns a fresh listing into the right childRemoved/childrenDiscovered/
//       sizeUpdated/directoryMtime events + the new children to sub-scan — the "diff-emission" the
//       packet requires, tested DRY (no filesystem).
//

import XCTest
@testable import ScanCore

final class LivingMapTests: XCTestCase {

    /// A reducer with /r (own 10) → a (own 4 → f1 100, f2 200), b (own 4 → g1 50).
    private func seeded() -> ScanReducer {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            .sizeUpdated(nodeId: "/r", allocated: 10, logical: 10),
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir),
                ChildStub(id: "/r/b", name: "b", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4),
            .sizeUpdated(nodeId: "/r/b", allocated: 4, logical: 4),
            .childrenDiscovered(parentId: "/r/a", children: [
                ChildStub(id: "/r/a/f1", name: "f1", kind: .file),
                ChildStub(id: "/r/a/f2", name: "f2", kind: .file)]),
            .sizeUpdated(nodeId: "/r/a/f1", allocated: 100, logical: 90),
            .sizeUpdated(nodeId: "/r/a/f2", allocated: 200, logical: 190),
            .childrenDiscovered(parentId: "/r/b", children: [
                ChildStub(id: "/r/b/g1", name: "g1", kind: .file)]),
            .sizeUpdated(nodeId: "/r/b/g1", allocated: 50, logical: 40),
            .subtreeCompleted(nodeId: "/r"),
        ])
        return r
    }

    // MARK: 1. childRemoved — prune + totals ripple

    func testChildRemovedPrunesSubtreeAndRipplesTotals() {
        var r = seeded()
        // Before: root = 10 + a(304) + b(54) = 368; 6 sized entries.
        XCTAssertEqual(r.makeTree(depthWindow: 10).allocatedBytes, 368)
        XCTAssertEqual(r.rootAllocatedBytes, 368)
        XCTAssertEqual(r.processedCount, 6)

        r.apply([.childRemoved(parentId: "/r", childId: "/r/a")])
        let t = r.makeTree(depthWindow: 10)

        // a and its whole subtree are gone; b and its total survive.
        XCTAssertEqual(t.children.map(\.name), ["b"], "the deleted folder's tile retires")
        XCTAssertFalse(r.contains("/r/a"), "the pruned node is gone")
        XCTAssertFalse(r.contains("/r/a/f1"), "and its descendants are gone")
        XCTAssertTrue(r.contains("/r/b/g1"), "a sibling subtree is untouched")
        // Totals ripple up: root loses a's whole retained total (304).
        XCTAssertEqual(t.allocatedBytes, 64, "root total ripples down to 10 + b(54)")
        XCTAssertEqual(r.rootAllocatedBytes, 64, "Scanned total tracks the live tree")
        XCTAssertEqual(r.processedCount, 3, "processed count drops by the 3 pruned stat'd entries")
    }

    func testChildRemovedIsIdempotentForUnlinkedChild() {
        var r = seeded()
        let before = r.makeTree(depthWindow: 10)
        // A childRemoved for an id not linked under the parent is a no-op (already gone / never there).
        r.apply([.childRemoved(parentId: "/r", childId: "/r/ghost")])
        r.apply([.childRemoved(parentId: "/r/a", childId: "/r/a")]) // wrong parent — also a no-op
        XCTAssertEqual(r.makeTree(depthWindow: 10), before, "an unlinked removal cannot corrupt totals")
        XCTAssertEqual(r.rootAllocatedBytes, 368)
        XCTAssertEqual(r.processedCount, 6)
    }

    // MARK: 2. Focus fallback

    func testNearestRetainedAncestorAfterFocusPrune() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            .childrenDiscovered(parentId: "/r", children: [ChildStub(id: "/r/a", name: "a", kind: .dir)]),
            .childrenDiscovered(parentId: "/r/a", children: [ChildStub(id: "/r/a/b", name: "b", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/a/b", allocated: 5, logical: 5)])
        XCTAssertEqual(r.nearestRetainedAncestor(of: "/r/a/b"), "/r/a/b", "a live id is its own nearest ancestor")
        r.apply([.childRemoved(parentId: "/r", childId: "/r/a")]) // prunes a AND its focus child b
        XCTAssertFalse(r.contains("/r/a/b"))
        XCTAssertEqual(r.nearestRetainedAncestor(of: "/r/a/b"), "/r",
                       "a pruned focus falls back to the nearest surviving ancestor (the root)")
        XCTAssertEqual(r.nearestRetainedAncestor(of: "/r/a"), "/r")
    }

    // MARK: 3. mtime capture + projection

    func testDirectoryMtimeSetsAndProjectsOntoSizeTree() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        // The scan root has no parent stub — directoryMtime seeds its mtime (revalidation path).
        XCTAssertNil(r.makeTree().mtime, "root mtime is unknown until a revalidation sets it")
        r.apply([.directoryMtime(nodeId: "/r", mtime: 12_345)])
        XCTAssertEqual(r.makeTree().mtime, 12_345, "directoryMtime projects onto SizeTree.mtime")
        // A dir child carries its scan-time mtime on the stub.
        r.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/d", name: "d", kind: .dir, isHidden: false, mtime: 999)])])
        XCTAssertEqual(r.makeTree(depthWindow: 10).children.first { $0.id == "/r/d" }?.mtime, 999,
                       "a dir child's scan-time mtime rides on the stub and projects")
    }

    // MARK: 3b. retainedDirIds enumerates EVERY retained directory (review-2 change 2)

    /// The FSEvents-loss recovery re-validates every retained directory under a flagged subtree. The
    /// enumeration must be COMPLETE — the earlier `cap` truncated it, silently leaving directories
    /// un-revalidated while the status resumed claiming full "Live". Build a wide subtree and assert
    /// every directory-like node (and only those) is returned, files excluded.
    func testRetainedDirIdsEnumeratesEveryRetainedDirectory() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        let n = 200 // comfortably beyond any per-drain batch cap
        var stubs: [ChildStub] = []
        for i in 0..<n { stubs.append(ChildStub(id: "/r/d\(i)", name: "d\(i)", kind: .dir)) }
        stubs.append(ChildStub(id: "/r/plain.txt", name: "plain.txt", kind: .file))
        r.apply([.childrenDiscovered(parentId: "/r", children: stubs)])
        for i in 0..<n { r.apply([.sizeUpdated(nodeId: "/r/d\(i)", allocated: 1, logical: 1)]) }

        let dirs = r.retainedDirIds(under: "/r")
        XCTAssertEqual(dirs.count, n + 1, "root + all \(n) subdirectories — none dropped, the file excluded")
        XCTAssertEqual(Set(dirs), Set(["/r"] + (0..<n).map { "/r/d\($0)" }))
        XCTAssertFalse(dirs.contains("/r/plain.txt"), "a plain file is not a directory-like recovery target")
        XCTAssertTrue(r.retainedDirIds(under: "/r/unknown").isEmpty, "an unretained id enumerates to nothing")
    }

    // MARK: 1b. Deleted-while-subscanning race — the reducer drops orphan events (OPERATOR_NOTE #2)

    /// The reducer is the single-threaded ordering authority: after a prune, late events from an
    /// in-flight sub-scan of the deleted subtree are DROPPED and COUNTED, never fabricated into orphan
    /// nodes that inflate the flat scan-root accumulators. We interleave the prune with the late
    /// sub-scan batch in EVERY order; the final totals must equal the pruned-tree truth EXACTLY, and the
    /// drop counter must be honest.
    ///
    /// Scenario: `/r` (seeded: 368 bytes, 6 stat'd entries, children [a, b]) revalidates and discovers a
    /// NEW directory child `c`; the App launches a streamed sub-scan of `c` (own size + two files). Then
    /// `c` is deleted (a later revalidation of `/r` emits `childRemoved(/r, c)`). Whatever the arrival
    /// order of the sub-scan batch vs the prune, `/r` must end at the seeded truth — `c` never lingers,
    /// never double-counts, never inflates `rootAllocatedBytes`/`processedCount`.
    func testDeletedWhileSubscanningDropsOrphanEventsAndTotalsMatchPrunedTruth() {
        // The discovery of `c` (structure only — its sizes arrive from the sub-scan) and the sub-scan's
        // own late batch, and the prune, as separable batches we can interleave.
        let discoverC: [ScanEvent] = [.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/c", name: "c", kind: .dir, mtime: 1)])]
        let subscanC: [ScanEvent] = [
            .sizeUpdated(nodeId: "/r/c", allocated: 4, logical: 4),
            .childrenDiscovered(parentId: "/r/c", children: [
                ChildStub(id: "/r/c/c1", name: "c1", kind: .file),
                ChildStub(id: "/r/c/c2", name: "c2", kind: .file)]),
            .sizeUpdated(nodeId: "/r/c/c1", allocated: 100, logical: 90),
            .sizeUpdated(nodeId: "/r/c/c2", allocated: 200, logical: 190),
            .subtreeCompleted(nodeId: "/r/c"),
        ]
        let prune: [ScanEvent] = [.childRemoved(parentId: "/r", childId: "/r/c")]

        // Every interleaving of {discover, sub-scan, prune} that keeps discover before the sub-scan
        // (a child is discovered before its own sub-scan streams) — the prune may land anywhere.
        let orderings: [[[ScanEvent]]] = [
            [discoverC, subscanC, prune],  // sub-scan fully folds, THEN prune backs it out
            [discoverC, prune, subscanC],  // prune first, THEN late sub-scan is dropped wholesale
            [prune, discoverC, subscanC],  // prune of a not-yet-discovered child (idempotent), then discover+subscan re-live it… see note
        ]

        for (i, ordering) in orderings.enumerated() {
            var r = seeded()
            for batch in ordering { r.apply(batch) }
            let t = r.makeTree(depthWindow: 10)

            if i == 2 {
                // Ordering 3: the prune lands BEFORE `c` exists as an edge, so it is a no-op (idempotent)
                // and records NO tombstone; the subsequent discover+sub-scan then legitimately live `c`.
                // This is the delete-before-create / re-create case — `c` IS present here, by design, and
                // the reducer must not have inflated or corrupted anything.
                XCTAssertTrue(r.contains("/r/c"), "a prune before the edge exists is a no-op; a later discover lives the child")
                XCTAssertEqual(r.rootAllocatedBytes, 368 + 304, "c(304) is legitimately present in this ordering")
                XCTAssertEqual(r.processedCount, 6 + 3)
                continue
            }

            // Orderings 1 & 2: `c` is discovered, then pruned — it must be GONE and the totals must equal
            // the seeded pruned-tree truth EXACTLY, regardless of when the sub-scan batch arrived.
            XCTAssertFalse(r.contains("/r/c"), "ordering \(i): the deleted subtree is gone")
            XCTAssertFalse(r.contains("/r/c/c1"), "ordering \(i): and its descendants")
            XCTAssertEqual(t.children.map(\.name).sorted(), ["a", "b"], "ordering \(i): only the surviving children remain")
            XCTAssertEqual(r.rootAllocatedBytes, 368, "ordering \(i): Scanned total equals the pruned-tree truth exactly — no orphan inflation")
            XCTAssertEqual(r.processedCount, 6, "ordering \(i): processed count equals the pruned-tree truth exactly")
            XCTAssertEqual(t.allocatedBytes, 368, "ordering \(i): the projected root total matches")
        }

        // The drop counter is HONEST: in the prune-before-subscan ordering, every one of the sub-scan's
        // events addressed the tombstoned `/r/c` subtree and was dropped + counted (never silent).
        var rDrop = seeded()
        for batch in [discoverC, prune, subscanC] { rDrop.apply(batch) }
        XCTAssertEqual(rDrop.droppedOrphanEvents, subscanC.count,
                       "every late sub-scan event under the pruned root is dropped AND counted (TZTRACE honesty)")
    }

    /// A pruned subtree that is later RE-CREATED (delete + recreate) must re-admit cleanly: the retained
    /// parent re-discovering the child CLEARS its tombstone, so the fresh sub-scan folds normally — the
    /// tombstone is self-healing, not a permanent blacklist.
    func testTombstoneClearsOnLegitimateReappearance() {
        var r = seeded()
        r.apply([.childrenDiscovered(parentId: "/r", children: [ChildStub(id: "/r/c", name: "c", kind: .dir, mtime: 1)])])
        r.apply([.sizeUpdated(nodeId: "/r/c", allocated: 4, logical: 4)])
        r.apply([.childRemoved(parentId: "/r", childId: "/r/c")]) // delete → tombstone /r/c
        XCTAssertFalse(r.contains("/r/c"))

        // A stale late event for the deleted incarnation is still dropped…
        let dropsBefore = r.droppedOrphanEvents
        r.apply([.sizeUpdated(nodeId: "/r/c", allocated: 999, logical: 999)])
        XCTAssertEqual(r.droppedOrphanEvents, dropsBefore + 1, "a late event for the deleted incarnation is dropped")
        XCTAssertFalse(r.contains("/r/c"), "and does not resurrect the node")

        // …but a legitimate re-creation (parent re-discovers c) clears the tombstone and lives it fresh.
        r.apply([.childrenDiscovered(parentId: "/r", children: [ChildStub(id: "/r/c", name: "c", kind: .dir, mtime: 2)])])
        r.apply([.sizeUpdated(nodeId: "/r/c", allocated: 7, logical: 7)])
        XCTAssertTrue(r.contains("/r/c"), "the re-created child is admitted after its tombstone clears")
        XCTAssertEqual(r.makeTree(depthWindow: 10).children.first { $0.id == "/r/c" }?.allocatedBytes, 7,
                       "the re-created child carries its fresh size")
    }

    // MARK: 4. revalidationDiff — the diff emission (dry)

    /// A complete re-listing that REMOVES one child, RESIZES a file, ADDS a file (inline size) and a
    /// directory (sub-scan). Pins every arm plus the `changed` flag and `newChildIds`.
    func testRevalidationDiffRemovesResizesAddsAndFlagsNewDirs() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir),
                ChildStub(id: "/r/f", name: "f", kind: .file)]),
            .sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4),
            .sizeUpdated(nodeId: "/r/f", allocated: 10, logical: 10)])

        let fresh = [
            FreshChild(id: "/r/f", name: "f", kind: .file, allocated: 20, logical: 20),   // grew 10→20
            FreshChild(id: "/r/g", name: "g", kind: .file, allocated: 5, logical: 5),     // new file
            FreshChild(id: "/r/d", name: "d", kind: .dir, allocated: 0, logical: 0, mtime: 42), // new dir
        ]                                                                                  // (a vanished)
        let diff = r.revalidationDiff(dirId: "/r", mtime: 777, ownAllocated: 0, ownLogical: 0,
                                      fresh: fresh, complete: true)

        XCTAssertTrue(diff.changed)
        XCTAssertEqual(diff.newChildIds, ["/r/d"], "a new directory needs a streamed sub-scan; files do not")
        // The events assert the four kinds of fact.
        func has(_ pred: (ScanEvent) -> Bool) -> Bool { diff.events.contains(where: pred) }
        XCTAssertTrue(has { if case .directoryMtime(let n, let m) = $0 { return n == "/r" && m == 777 }; return false })
        XCTAssertTrue(has { if case .childRemoved(let p, let c) = $0 { return p == "/r" && c == "/r/a" }; return false },
                      "the vanished child is pruned")
        XCTAssertTrue(has { if case .sizeUpdated(let n, let a, _) = $0 { return n == "/r/f" && a == 20 }; return false },
                      "an in-place file resize emits a fresh size")
        XCTAssertTrue(has { if case .sizeUpdated(let n, let a, _) = $0 { return n == "/r/g" && a == 5 }; return false },
                      "a new file carries its size inline")
        XCTAssertFalse(has { if case .sizeUpdated(let n, _, _) = $0 { return n == "/r/d" }; return false },
                       "a new directory's size arrives from its sub-scan, not the diff")
        // Applying the diff produces the expected live tree.
        r.apply(diff.events)
        let t = r.makeTree(depthWindow: 10)
        XCTAssertEqual(t.children.map(\.name).sorted(), ["d", "f", "g"], "a removed, f/g present, d pending")
        XCTAssertFalse(r.contains("/r/a"))
        XCTAssertEqual(t.children.first { $0.id == "/r/f" }?.allocatedBytes, 20)
    }

    func testRevalidationDiffPartialReadSuppressesRemovals() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/a", name: "a", kind: .dir),
            ChildStub(id: "/r/b", name: "b", kind: .dir)]),
            .sizeUpdated(nodeId: "/r/a", allocated: 1, logical: 1),
            .sizeUpdated(nodeId: "/r/b", allocated: 1, logical: 1)])
        // A PARTIAL read that happens to only see `a`: b must NOT be pruned (it may just be unread).
        let diff = r.revalidationDiff(dirId: "/r", mtime: 5, ownAllocated: 0, ownLogical: 0,
            fresh: [FreshChild(id: "/r/a", name: "a", kind: .dir, allocated: 1, logical: 1, mtime: 0)],
            complete: false)
        XCTAssertFalse(diff.changed, "an incomplete read with no additions is not a change")
        XCTAssertFalse(diff.events.contains { if case .childRemoved = $0 { return true }; return false },
                       "removals are SUPPRESSED on a partial read — never drop a tile we merely failed to re-read")
        // Only the mtime refresh rides along.
        XCTAssertEqual(diff.events.count, 1)
        XCTAssertTrue(diff.events.contains { if case .directoryMtime = $0 { return true }; return false })
    }

    func testRevalidationDiffUnchangedListingIsNotAChange() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/f", name: "f", kind: .file)]),
            .sizeUpdated(nodeId: "/r/f", allocated: 10, logical: 10)])
        let diff = r.revalidationDiff(dirId: "/r", mtime: 9, ownAllocated: 0, ownLogical: 0,
            fresh: [FreshChild(id: "/r/f", name: "f", kind: .file, allocated: 10, logical: 10)],
            complete: true)
        XCTAssertFalse(diff.changed, "same children, same sizes ⇒ no structural change")
        XCTAssertTrue(diff.newChildIds.isEmpty)
        XCTAssertEqual(diff.events.count, 1, "only the mtime refresh (cached so the next check short-circuits)")
    }

    // MARK: 5. revalidation refreshes the directory's OWN entry size (review-0 change 5)

    /// A directory's own allocation grows as it gains entries; revalidation must refresh it so the
    /// rectangle total is not left stale by the directory's own-entry allocation — and stay calm when
    /// it is unchanged.
    func testRevalidationRefreshesDirectoryOwnSize() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.sizeUpdated(nodeId: "/r", allocated: 4096, logical: 100),
                 .childrenDiscovered(parentId: "/r", children: [ChildStub(id: "/r/f", name: "f", kind: .file)]),
                 .sizeUpdated(nodeId: "/r/f", allocated: 10, logical: 10)])
        XCTAssertEqual(r.makeTree(depthWindow: 10).allocatedBytes, 4106)

        // Same children/sizes, but the directory's OWN allocation grew (more entries → bigger dir file).
        let diff = r.revalidationDiff(dirId: "/r", mtime: 5, ownAllocated: 8192, ownLogical: 200,
            fresh: [FreshChild(id: "/r/f", name: "f", kind: .file, allocated: 10, logical: 10)],
            complete: true)
        XCTAssertTrue(diff.changed, "the directory's own-entry size grew — a real change")
        XCTAssertTrue(diff.events.contains { if case let .sizeUpdated(n, a, _) = $0 { return n == "/r" && a == 8192 }; return false },
                      "the diff emits a fresh own-size for the directory")
        r.apply(diff.events)
        XCTAssertEqual(r.makeTree(depthWindow: 10).allocatedBytes, 8202, "own-size refresh ripples into the total")

        // A second identical re-list is calm — the own size is unchanged, so no event, no change.
        let diff2 = r.revalidationDiff(dirId: "/r", mtime: 6, ownAllocated: 8192, ownLogical: 200,
            fresh: [FreshChild(id: "/r/f", name: "f", kind: .file, allocated: 10, logical: 10)],
            complete: true)
        XCTAssertFalse(diff2.changed, "an unchanged own size does not spuriously churn")
        XCTAssertFalse(diff2.events.contains { if case let .sizeUpdated(n, _, _) = $0 { return n == "/r" }; return false })
    }
}
