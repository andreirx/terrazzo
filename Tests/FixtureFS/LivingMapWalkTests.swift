//
//  LivingMapWalkTests.swift — TZ-7 revalidation + FSEvents coalescing against a REAL temp tree.
//  Module maturity: PROTOTYPE (slice TZ-7 — the living map)
//
//  Integration for the living map's I/O side (packet deliverables 1–3):
//    - the mtime FAST PATH (`revalidationRead` returns `.unchanged` for an untouched directory —
//      one `lstat`, no enumeration);
//    - DELETE detection: re-list after removing a child → the reducer PRUNES it and totals ripple;
//    - ADD detection: a new file lands with its size inline; a new directory is sub-scanned via
//      `scanNewChild` and its subtree streams into the live tree;
//    - the FSEvents STORM COALESCER (`FSEventCoalescer`) dedup + cap + carry-overflow — dry.
//

import XCTest
import Darwin
import CoreServices
import ScanCore
@testable import ScanFS

final class LivingMapWalkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terrazzo-tz7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ name: String, _ s: String) throws {
        try Data(s.utf8).write(to: root.appendingPathComponent(name))
    }

    private func scanToReducer() async -> ScanReducer {
        var r = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
        for await batch in FileSystemWalker.scan(root: root) { r.apply(batch) }
        return r
    }

    // MARK: - Tier-1 mtime fast path

    func testUnchangedDirectoryRevalidatesInOneStat() throws {
        try write("a.txt", "aaaa")
        // First read (no known mtime) captures the directory's current mtime.
        guard case let .changed(m0, _, _, fresh0, complete0) = FileSystemWalker.revalidationRead(
            dirId: root.path, ifUnchangedFrom: nil) else {
            return XCTFail("first revalidation read must enumerate")
        }
        XCTAssertTrue(complete0)
        XCTAssertTrue(fresh0.contains { $0.name == "a.txt" })
        // A second read with that mtime, nothing changed on disk → the fast path returns .unchanged.
        XCTAssertEqual(FileSystemWalker.revalidationRead(dirId: root.path, ifUnchangedFrom: m0), .unchanged,
                       "an untouched directory revalidates in one lstat (no enumeration)")
    }

    // MARK: - Root mtime captured at scan time (review-0 change 1)

    /// After a FULL scan the root's mtime is projected onto `SizeTree.mtime`, so the FIRST focus
    /// revalidation of the root takes the one-`lstat` unchanged fast path instead of re-enumerating —
    /// the Tier-1 contract for the initial focus (which IS the scan root).
    func testScannedRootCarriesMtimeSoFocusRevalidationShortCircuits() async throws {
        try write("a.txt", "aaaa")
        let r = await scanToReducer()
        let rootMtime = r.makeTree(depthWindow: 1).mtime
        XCTAssertNotNil(rootMtime, "the scan captured the root's mtime (no parent stub carries it)")
        // The scan-time mtime must match a fresh stat of an untouched root ⇒ the fast path.
        XCTAssertEqual(FileSystemWalker.revalidationRead(dirId: root.path, ifUnchangedFrom: rootMtime),
                       .unchanged,
                       "the initial root focus revalidates in one lstat — no first-time re-enumeration")
    }

    // MARK: - Deleted FOCUS directory → parent revalidation prunes it (review-0 change 2)

    /// When the FOCUSED directory itself is deleted, revalidating it returns `.unreadable`. The living
    /// map must not leave a ghost: revalidating the nearest surviving ancestor of its parent
    /// `childRemoved`s the vanished subtree, and `nearestRetainedAncestor` names where the focus falls
    /// back to. Drives the exact I/O logic the App's `.unreadable` handling performs.
    func testDeletedFocusDirectoryIsPrunedViaParentRevalidation() async throws {
        try write("keep.txt", "keep")
        let sub = root.appendingPathComponent("focusdir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(String(repeating: "z", count: 4096).utf8).write(to: sub.appendingPathComponent("inner.txt"))
        var r = await scanToReducer()
        let focusId = FileSystemWalker.joinId(root.path, "focusdir")
        XCTAssertTrue(r.contains(focusId), "the focus directory is scanned")

        // Delete the focused directory. A direct revalidation of it is now .unreadable (it is gone).
        try FileManager.default.removeItem(at: sub)
        XCTAssertEqual(FileSystemWalker.revalidationRead(dirId: focusId, ifUnchangedFrom: nil), .unreadable,
                       "the deleted focus directory reads .unreadable")

        // The App's fallback: revalidate the nearest surviving ancestor of the focus's PARENT (here the
        // root) and apply — the vanished child is pruned.
        let parent = (focusId as NSString).deletingLastPathComponent
        let anc = r.nearestRetainedAncestor(of: parent)
        XCTAssertEqual(anc, root.path, "the parent survives, so it is the revalidation target")
        guard case let .changed(mtime, ownA, ownL, fresh, complete) = FileSystemWalker.revalidationRead(
            dirId: anc!, ifUnchangedFrom: nil) else { return XCTFail("the surviving parent must enumerate") }
        let diff = r.revalidationDiff(dirId: anc!, mtime: mtime, ownAllocated: ownA, ownLogical: ownL,
                                      fresh: fresh, complete: complete)
        r.apply(diff.events)
        XCTAssertFalse(r.contains(focusId), "the deleted focus directory's subtree is pruned — no ghost")
        XCTAssertTrue(r.contains(FileSystemWalker.joinId(root.path, "keep.txt")), "the sibling survives")
        // The focus falls back to the surviving ancestor (root) — the map never points at the ghost.
        XCTAssertEqual(r.nearestRetainedAncestor(of: focusId), root.path)
    }

    // MARK: - Deleted FSEvents path maps to the surviving parent (review-1 change 2)

    /// A DELETED flagged directory must resolve to its nearest SURVIVING, on-device parent (whose
    /// re-enumeration `childRemoved`s it) — NOT be dropped, which would leave a ghost. Drives the pure
    /// `FSEventsWatcher.resolve` the callback uses, against a real temp tree, without a live stream (a
    /// kernel deleted-directory event cannot be forced deterministically — the reviewer's exact gap).
    func testDeletedFlaggedDirectoryMapsToSurvivingParent() throws {
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // Canonicalize via realpath — the SAME resolution `FSEventsWatcher.resolve` uses internally
        // (resolvingSymlinksInPath disagrees with realpath on /var → /private/var).
        func rp(_ p: String) -> String {
            guard let c = Darwin.realpath(p, nil) else { return p }
            defer { free(c) }
            return String(cString: c)
        }
        let canonicalRoot = rp(root.path)
        var st = stat()
        XCTAssertEqual(lstat(canonicalRoot, &st), 0)
        let dev = st.st_dev
        let subCanonical = rp(sub.path) // captured while it still exists

        // A LIVE subdirectory maps to its own node id.
        XCTAssertEqual(
            FSEventsWatcher.resolveForTesting(path: subCanonical, canonicalRoot: canonicalRoot,
                                              rootPath: root.path, rootDevice: dev),
            FileSystemWalker.joinId(root.path, "sub"), "a live subdirectory maps to its own id")

        // Delete it: the SAME flagged path (now gone) resolves to the surviving parent — the root —
        // instead of being dropped. The device is validated on the survivor (change 2).
        try FileManager.default.removeItem(at: sub)
        XCTAssertEqual(
            FSEventsWatcher.resolveForTesting(path: subCanonical, canonicalRoot: canonicalRoot,
                                              rootPath: root.path, rootDevice: dev),
            root.path, "a DELETED flagged directory resolves to its surviving parent, not dropped")

        // A path genuinely outside the scan root is dropped (the in-scope rule).
        XCTAssertNil(
            FSEventsWatcher.resolveForTesting(path: "/nowhere-\(UUID().uuidString)", canonicalRoot: canonicalRoot,
                                              rootPath: root.path, rootDevice: dev),
            "an out-of-scope path is dropped")
    }

    // MARK: - Delete detection → prune + ripple

    func testDeletedChildIsPrunedAndTotalsRipple() async throws {
        try write("keep.txt", "keep")
        try write("gone.txt", String(repeating: "x", count: 4096))
        var r = await scanToReducer()
        let goneId = FileSystemWalker.joinId(root.path, "gone.txt")
        XCTAssertTrue(r.contains(goneId), "the file is in the scanned tree")
        let totalBefore = r.rootAllocatedBytes

        // Delete it, re-list, diff, apply — the living map's core loop.
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        guard case let .changed(mtime, ownA, ownL, fresh, complete) = FileSystemWalker.revalidationRead(
            dirId: root.path, ifUnchangedFrom: nil) else {
            return XCTFail("a changed directory must enumerate")
        }
        XCTAssertFalse(fresh.contains { $0.name == "gone.txt" }, "the deleted file is absent from the fresh listing")
        let diff = r.revalidationDiff(dirId: root.path, mtime: mtime, ownAllocated: ownA, ownLogical: ownL,
                                      fresh: fresh, complete: complete)
        r.apply(diff.events)

        XCTAssertFalse(r.contains(goneId), "the deleted file's node is pruned — its tile retires")
        XCTAssertTrue(r.contains(FileSystemWalker.joinId(root.path, "keep.txt")), "the sibling survives")
        XCTAssertLessThan(r.rootAllocatedBytes, totalBefore, "the freed bytes ripple out of the Scanned total")
    }

    // MARK: - Add detection → new file inline, new dir sub-scanned

    func testNewFileAndNewDirectoryStreamIntoTheLiveTree() async throws {
        try write("first.txt", "1")
        var r = await scanToReducer()

        // Add a file AND a directory-with-content, then revalidate the root.
        try write("added.txt", String(repeating: "y", count: 2048))
        let newDir = root.appendingPathComponent("newdir", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data(String(repeating: "z", count: 3072).utf8).write(to: newDir.appendingPathComponent("inner.txt"))

        guard case let .changed(mtime, ownA, ownL, fresh, complete) = FileSystemWalker.revalidationRead(
            dirId: root.path, ifUnchangedFrom: nil) else { return XCTFail("changed dir must enumerate") }
        let diff = r.revalidationDiff(dirId: root.path, mtime: mtime, ownAllocated: ownA, ownLogical: ownL,
                                      fresh: fresh, complete: complete)
        r.apply(diff.events)

        // The new file is present immediately with its size (inline from the enumeration).
        let addedId = FileSystemWalker.joinId(root.path, "added.txt")
        XCTAssertTrue(r.contains(addedId))
        XCTAssertGreaterThan(r.makeTree(depthWindow: 10).children.first { $0.id == addedId }?.allocatedBytes ?? 0, 0)

        // The new DIRECTORY needs a streamed sub-scan (its own size + descent).
        let newDirId = FileSystemWalker.joinId(root.path, "newdir")
        XCTAssertEqual(diff.newChildIds, [newDirId], "a new directory is flagged for a sub-scan")
        for await batch in FileSystemWalker.scanNewChild(url: newDir, id: newDirId, scanRootPath: root.path) {
            r.apply(batch)
        }
        let tree = r.makeTree(depthWindow: 10)
        let dirNode = tree.children.first { $0.id == newDirId }
        XCTAssertEqual(dirNode?.kind, .dir)
        XCTAssertEqual(dirNode?.children.map(\.name), ["inner.txt"], "the sub-scan streamed the new subtree in")
        XCTAssertGreaterThan(dirNode?.allocatedBytes ?? 0, 3000, "and its recursive total is counted")
    }

    // MARK: - Opaque `.app` bundle stays opaque on a live re-size (review-1 change 3)

    /// A change INSIDE an `.app` bundle must refresh only its opaque recursive TOTAL — never expose its
    /// descendants. Drives the REAL bundle path: scan a `.app` (opaque leaf), grow a file deep inside,
    /// re-measure via `revalidationBundleRead` (NOT `revalidationRead`, which would enumerate it as a
    /// directory), and apply the single opaque `sizeUpdated` — asserting the leaf grows but exposes no
    /// children.
    func testBundleRevalidationStaysOpaqueAndRefreshesTotal() async throws {
        let app = root.appendingPathComponent("Thing.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 4096).utf8).write(to: contents.appendingPathComponent("small.bin"))
        var r = await scanToReducer()
        let appId = FileSystemWalker.joinId(root.path, "Thing.app")
        let before = r.makeTree(depthWindow: 10).children.first { $0.id == appId }
        XCTAssertEqual(before?.kind, .bundleLeaf, "a .app is scanned as an opaque bundle leaf")
        XCTAssertTrue(before?.children.isEmpty ?? false, "the bundle exposes NO descendants")
        let sizeBefore = before?.allocatedBytes ?? 0
        XCTAssertGreaterThan(sizeBefore, 0)

        // Grow a file DEEP inside the bundle, then re-measure via the OPAQUE bundle path.
        try Data(String(repeating: "b", count: 300_000).utf8).write(to: contents.appendingPathComponent("big.bin"))
        guard case let .sized(mtime, a, l) = FileSystemWalker.revalidationBundleRead(bundleId: appId) else {
            return XCTFail("the bundle must re-measure to .sized")
        }
        r.apply([.directoryMtime(nodeId: appId, mtime: mtime), .sizeUpdated(nodeId: appId, allocated: a, logical: l)])
        let after = r.makeTree(depthWindow: 10).children.first { $0.id == appId }
        XCTAssertEqual(after?.kind, .bundleLeaf)
        XCTAssertTrue(after?.children.isEmpty ?? false, "still opaque after the live re-size — descendants never exposed")
        XCTAssertGreaterThan(after?.allocatedBytes ?? 0, sizeBefore, "the opaque recursive total grew")
    }

    // MARK: - Live-update delivery THROUGH the existing EventBatcher (OPERATOR_NOTE #1)

    /// The single live delivery path the App uses (`ScanController.deliverAndFold`): computed diff
    /// `ScanEvent`s are routed through the SAME `EventBatcher` scan data uses, then folded from its
    /// coalesced FIFO batches. This pins that path DRY — no window, no pipeline (the App layer that wires
    /// them is AppKit-only) — at the ScanFS+ScanCore level both live here:
    ///   (a) STORM-SAFE CHUNKING: a mass-delete diff far larger than `maxEventsPerBatch` is delivered as
    ///       multiple batches, NONE exceeding the cap — so a flood never spikes into one unbounded fold;
    ///   (b) FIFO / LOSSLESS: the delivered batches concatenated equal the diff events, in order;
    ///   (c) EQUIVALENCE: folding the batcher-delivered batches yields the IDENTICAL reducer state as a
    ///       direct fold — the batcher is transport, not transform.
    func testLiveDiffDeliveredThroughEventBatcherFoldsToCorrectTree() async throws {
        // A directory with many children so the delete diff exceeds one batch (cap is 1000).
        let n = 2500
        for i in 0..<n { try write("f\(i).bin", "x") }
        try write("keep.bin", "keepkeep")
        var reducer = await scanToReducer()
        let before = reducer.rootAllocatedBytes
        XCTAssertGreaterThan(before, 0)

        // Delete every f*.bin on disk (only keep.bin survives), then compute the diff for the fresh
        // listing — a mass delete: n childRemoved + the directory's own-size/mtime refresh.
        for i in 0..<n { try FileManager.default.removeItem(at: root.appendingPathComponent("f\(i).bin")) }
        guard case let .changed(m2, oa2, ol2, fresh2, complete2) = FileSystemWalker.revalidationRead(
            dirId: root.path, ifUnchangedFrom: nil) else { return XCTFail("post-delete read must enumerate") }
        let diff = reducer.revalidationDiff(dirId: root.path, mtime: m2, ownAllocated: oa2, ownLogical: ol2,
                                            fresh: fresh2, complete: complete2)
        XCTAssertGreaterThan(diff.events.count, BatchLimits.maxEventsPerBatch,
                             "the mass-delete diff is larger than one batch — the chunking is real")

        // ROUTE the diff through a real EventBatcher (the App's `liveBatcher`), collecting its sink output.
        final class Collector: @unchecked Sendable {
            private let lock = NSLock(); private var _b: [[ScanEvent]] = []
            func add(_ b: [ScanEvent]) { lock.lock(); _b.append(b); lock.unlock() }
            var batches: [[ScanEvent]] { lock.lock(); defer { lock.unlock() }; return _b }
        }
        // A value-type COPY of the reducer BEFORE either fold — the direct-fold reference (equivalence).
        var directRef = reducer
        let collector = Collector()
        let batcher = EventBatcher { collector.add($0) }
        await batcher.add(diff.events)
        await batcher.flush()
        let delivered = collector.batches

        // (a) storm-safe: every delivered batch is within the cap.
        XCTAssertGreaterThan(delivered.count, 1, "a mass change is delivered as multiple capped batches, not one unbounded fold")
        for b in delivered { XCTAssertLessThanOrEqual(b.count, BatchLimits.maxEventsPerBatch, "no batch exceeds the cap") }
        // (b) FIFO / lossless: concatenation equals the diff events, in order.
        XCTAssertEqual(delivered.flatMap { $0 }, diff.events, "batcher delivery is FIFO and lossless")

        // (c) equivalence: fold the batcher-delivered batches; compare to a direct fold of the same diff
        // on the pre-fold value-type copy.
        for b in delivered { reducer.apply(b) }
        directRef.apply(diff.events)
        XCTAssertEqual(reducer.rootAllocatedBytes, directRef.rootAllocatedBytes,
                       "batcher-delivered fold equals a direct fold — the batcher is transport, not transform")
        XCTAssertEqual(reducer.processedCount, directRef.processedCount)
        XCTAssertFalse(reducer.contains(FileSystemWalker.joinId(root.path, "f0.bin")), "the mass delete retired every tile")
        XCTAssertTrue(reducer.contains(FileSystemWalker.joinId(root.path, "keep.bin")), "the survivor remains")
        XCTAssertLessThan(reducer.rootAllocatedBytes, before, "freed bytes rippled out of the Scanned total")
    }

    // MARK: - FSEvents flag policy (dry — the loss-recovery classification, review-1 change 4)

    /// The PURE flag→action policy the callback consults, pinned WITHOUT forcing a real kernel drop
    /// (unforceable from userspace). An ordinary change is a one-level reconcile; `MustScanSubDirs`
    /// forces a subtree rescan; a user/kernel queue overflow is a completeness loss (degrades "Live").
    func testFSEventFlagPolicyClassifiesLossFlags() {
        let ordinary = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(FSEventFlagPolicy.action(for: ordinary), .reconcile, "an ordinary change is a one-level reconcile")
        XCTAssertFalse(FSEventFlagPolicy.isHistoryDropped(ordinary), "an ordinary change is not a loss")

        let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertEqual(FSEventFlagPolicy.action(for: mustScan), .rescanSubtree,
                       "MustScanSubDirs forces a subtree rescan — a one-level check cannot recover deep changes")

        XCTAssertTrue(FSEventFlagPolicy.isHistoryDropped(FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)),
                      "a user-space queue overflow is a completeness loss")
        XCTAssertTrue(FSEventFlagPolicy.isHistoryDropped(FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)),
                      "a kernel-space queue overflow is a completeness loss")
        XCTAssertEqual(FSEventFlagPolicy.action(for: FSEventStreamEventFlags(kFSEventStreamEventFlagNone)), .reconcile,
                       "no flags → an ordinary reconcile")
    }

    // MARK: - FSEvents storm coalescer (dry — no real flood)

    func testFSEventCoalescerDedupsCapsAndCarriesOverflow() {
        var c = FSEventCoalescer()
        c.add(["/a", "/b", "/a"]) // duplicate /a folds away
        XCTAssertEqual(c.count, 2, "the same directory flagged twice is coalesced to one")

        // Cap: a 100-directory storm drains at most `maxDirsPerDrain`, carrying the rest.
        c = FSEventCoalescer()
        c.add((0..<100).map { "/d\($0)" })
        XCTAssertEqual(c.count, 100)
        let first = c.drain(max: FSEventTuning.maxDirsPerDrain)
        XCTAssertEqual(first.count, FSEventTuning.maxDirsPerDrain, "a drain never exceeds the per-drain cap")
        XCTAssertEqual(c.count, 100 - FSEventTuning.maxDirsPerDrain, "the overflow carries to the next drain")
        XCTAssertFalse(c.isEmpty)
        // Draining the remainder empties it; drained ids are disjoint from the first batch.
        let second = c.drain(max: FSEventTuning.maxDirsPerDrain)
        XCTAssertEqual(second.count, 100 - FSEventTuning.maxDirsPerDrain)
        XCTAssertTrue(c.isEmpty, "everything drains eventually")
        XCTAssertTrue(Set(first).isDisjoint(with: Set(second)), "no directory is re-enumerated across drains")
        XCTAssertEqual(c.drain(max: 8), [], "draining an empty coalescer yields nothing")
    }

    // MARK: - Scheduled-drain: N callbacks coalesce into ONE capped delivery (review-2 change 1)

    /// The watcher no longer drains inline per callback; it ACCUMULATES and schedules ONE drain per
    /// window. This pins that state machine dry: multiple callback-equivalent adds before the drain
    /// arm exactly one scheduled drain, and that single drain delivers one deduplicated capped batch —
    /// so a burst of small callbacks becomes ONE `onDirs`, not one per callback.
    func testScheduledDrainCoalescesManyAddsIntoOneCappedDelivery() {
        var c = FSEventCoalescer()
        XCTAssertTrue(c.addAndClaimSchedule(["/a", "/b"]), "the FIRST add of a window schedules the one drain")
        XCTAssertFalse(c.addAndClaimSchedule(["/b", "/c"]), "a second add in the same window does NOT re-arm")
        XCTAssertFalse(c.addAndClaimSchedule(["/a", "/d"]), "nor a third — N callbacks arm exactly ONE drain")
        XCTAssertEqual(c.count, 4, "/a /b /c /d — duplicates coalesced across the burst of adds")

        // The single scheduled drain delivers ONE deduplicated batch (here under the cap).
        let batch = c.drain(max: FSEventTuning.maxDirsPerDrain)
        XCTAssertEqual(Set(batch), ["/a", "/b", "/c", "/d"], "one delivery covers every coalesced dir")
        XCTAssertFalse(c.finishDrain(), "nothing carried → no further drain scheduled")
        XCTAssertTrue(c.addAndClaimSchedule(["/e"]), "a change after the drain completed arms a FRESH window")
    }

    /// A storm: the single scheduled drain caps at `maxDirsPerDrain` and RE-schedules ONLY for the
    /// carried overflow, so a mass delete never spikes into one unbounded delivery nor one drain per
    /// callback — it drains cap-at-a-time across windows until empty.
    func testScheduledDrainReschedulesOnlyForCarriedOverflow() {
        var c = FSEventCoalescer()
        XCTAssertTrue(c.addAndClaimSchedule((0..<100).map { "/d\($0)" }), "the storm arms one drain")
        let b1 = c.drain(max: FSEventTuning.maxDirsPerDrain)
        XCTAssertEqual(b1.count, FSEventTuning.maxDirsPerDrain, "a drain never exceeds the per-drain cap")
        XCTAssertTrue(c.finishDrain(), "overflow remains → the drain re-schedules itself")
        let b2 = c.drain(max: FSEventTuning.maxDirsPerDrain)
        XCTAssertFalse(c.finishDrain(), "everything drained → no further drain scheduled")
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(Set(b1).union(b2).count, 100, "every flagged dir is delivered exactly once across the drains")
        XCTAssertTrue(Set(b1).isDisjoint(with: Set(b2)))
    }

    // MARK: - Loss recovery drains EVERY retained dir across bounded batches (review-2 change 2)

    /// A `MustScanSubDirs`/dropped-queue loss must re-validate EVERY retained directory under the
    /// flagged subtree, degraded until done — never a subset with the status resuming "Live". This
    /// drives the real recovery mechanism dry: the reducer's (now uncapped) enumeration feeds the
    /// same `FSEventCoalescer` the App drains in `maxRecoveryDirs`-sized batches. With MORE retained
    /// directories than one batch, (a) enumeration drops NONE, (b) the set is NOT empty after the
    /// first bounded drain (so `drainRecovery` would stay degraded — recovery is not reported complete
    /// early), and (c) every directory is drained exactly once by the time it empties.
    func testLossRecoveryEnumeratesAndDrainsEveryRetainedDirectory() async throws {
        // Build a fixture with more subdirectories than a modest recovery batch cap.
        let batchCap = 10                              // stand-in for ScanController.maxRecoveryDirs (private)
        let dirCount = batchCap * 2 + 3                // > cap ⇒ must span multiple bounded drains
        for i in 0..<dirCount {
            let d = root.appendingPathComponent("d\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: d.appendingPathComponent("f.txt"))
        }
        let r = await scanToReducer()

        // (a) Enumeration is COMPLETE: root + every dN (the fN files are not directory-like).
        let allDirs = r.retainedDirIds(under: root.path)
        XCTAssertEqual(allDirs.count, dirCount + 1, "every retained directory is enumerated — none dropped by a cap")
        XCTAssertTrue(allDirs.contains(root.path))

        // (b)+(c) Drain in bounded batches exactly as `drainRecovery` does; degraded stays true while
        // the set is non-empty, and every dir is drained once.
        var recovery = FSEventCoalescer()
        recovery.add(allDirs)
        var drained: [String] = []
        var drains = 0
        XCTAssertFalse(recovery.isEmpty, "recovery has work ⇒ status is degraded")
        while !recovery.isEmpty {
            let batch = recovery.drain(max: batchCap)
            XCTAssertLessThanOrEqual(batch.count, batchCap, "each drain honors the per-drain cap")
            drained.append(contentsOf: batch)
            drains += 1
            if drains == 1 {
                XCTAssertFalse(recovery.isEmpty,
                               "after the first bounded drain work REMAINS — recovery is not reported complete early")
            }
        }
        XCTAssertGreaterThan(drains, 1, "a subtree larger than the cap spans multiple bounded drains")
        XCTAssertEqual(Set(drained), Set(allDirs), "every retained directory is recovered exactly once — no ghost left stale")
        XCTAssertEqual(drained.count, allDirs.count)
    }
}
