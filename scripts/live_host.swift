//
//  live_host.swift — TZ-7 LIVE headless evidence: the living map, no window, no synthetic input.
//  Module maturity: PROTOTYPE (slice TZ-7 — the living map)
//
//  Compiled by scripts/live.sh together with Sources/ScanFS + Sources/ScanCore into one swiftc
//  module (same monolith arrangement as scan_host — no imports, same-module resolution). It
//  exercises the REAL revalidation + FSEvents path against a fixture directory it mutates (FS
//  mutations in a fixture dir are the ratified evidence source; NO synthetic input, NO window —
//  CLAUDE.md builder conduct):
//
//    TIER 1 (focus revalidation by mtime): scan a fixture, then delete / grow / add entries while
//      "holding focus" on the root, and revalidate it — printing the diff events (TZTRACE) and the
//      detection latency (a focus-change poke = one `revalidationRead` + diff). Also proves the
//      one-syscall fast path returns `.unchanged` for an untouched directory.
//
//    TIER 2 (FSEvents): put a real `FSEventsWatcher` on the scan root, mutate a child, and measure
//      the latency from mutation to the kernel-coalesced callback (expected ≤ ~2 s), then run the
//      same revalidation for the flagged directory — the tile updates with NO rescan.
//
//    HOME run: create a real folder under $HOME, scan its parent, delete it, and show its tile
//      retire (the founding field report, on a real home path).
//
//  Every "tree updates" claim is proven by the reducer's node set / totals BEFORE vs AFTER — the
//  same pure state the App renders. Exit non-zero if any expected update fails to land.
//

import Foundation
import Darwin

private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }
private func trace(_ s: String) { print("TZTRACE \(s)"); fflush(stdout) }
private func die(_ m: String) -> Never {
    FileHandle.standardError.write(Data("LIVE_HOST FAILED: \(m)\n".utf8)); exit(1)
}

/// Canonicalize (resolve /var → /private/var etc.) so FSEvents' delivered paths match our node-id
/// prefix — otherwise a temp-dir firmlink alias would be dropped by the in-scope check.
private func canonical(_ url: URL) -> URL {
    URL(fileURLWithPath: (url.path as NSString).resolvingSymlinksInPath, isDirectory: true)
}

private let fm = FileManager.default
private func mkdir(_ u: URL) { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
private func write(_ u: URL, _ n: Int) { try? Data(String(repeating: "x", count: n).utf8).write(to: u) }

/// One full revalidation cycle for a directory (Tier-1 & Tier-2 share it): read → diff → apply →
/// sub-scan new children. Returns the applied diff + the elapsed time, and TRACES every event.
@discardableResult
private func revalidate(_ reducer: inout ScanReducer, dirId: String, label: String) async -> (RevalidationDiff, Double) {
    let t0 = nowNs()
    let read = FileSystemWalker.revalidationRead(dirId: dirId, ifUnchangedFrom: nil)
    guard case let .changed(mtime, ownA, ownL, fresh, complete) = read else {
        let t1 = nowNs()
        trace("\(label): revalidate \(dirId) -> \(read == .unchanged ? "UNCHANGED (1 stat)" : "UNREADABLE") in \(String(format: "%.2f", ms(t0, t1))) ms")
        return (RevalidationDiff(events: [], newChildIds: [], changed: false), ms(t0, t1))
    }
    let diff = reducer.revalidationDiff(dirId: dirId, mtime: mtime, ownAllocated: ownA, ownLogical: ownL,
                                        fresh: fresh, complete: complete)
    reducer.apply(diff.events)
    for e in diff.events {
        switch e {
        case let .childRemoved(_, c): trace("\(label): childRemoved \(c)")
        case let .sizeUpdated(n, a, _): trace("\(label): sizeUpdated \(n) = \(a) bytes")
        case let .childrenDiscovered(_, kids): trace("\(label): childrenDiscovered +\(kids.map(\.name))")
        default: break
        }
    }
    // Stream in any new subdirectories (their own size + descent).
    for childId in diff.newChildIds {
        let stream = FileSystemWalker.scanNewChild(url: URL(fileURLWithPath: childId), id: childId,
                                                   scanRootPath: dirId)
        for await batch in stream { reducer.apply(batch) }
        trace("\(label): sub-scanned new child \(childId)")
    }
    let t1 = nowNs()
    trace("\(label): detected + applied in \(String(format: "%.2f", ms(t0, t1))) ms (changed=\(diff.changed))")
    return (diff, ms(t0, t1))
}

/// Result sink for the FSEvents callback (crosses the watcher's serial queue → main). Only records
/// callbacks AT OR AFTER the mutation (`arm`), so a spurious event during the stream's arming window
/// cannot poison the measured latency.
private final class FSResult: @unchecked Sendable {
    let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _dirs: [String] = []
    private var _detectNs: UInt64 = 0
    private var _startNs: UInt64 = .max
    func arm(_ ns: UInt64) { lock.lock(); _startNs = ns; lock.unlock() }
    func record(_ dirs: [String], _ ns: UInt64) {
        lock.lock(); let armed = ns >= _startNs
        if armed { _dirs = dirs; _detectNs = ns }
        lock.unlock()
        if armed { sem.signal() }
    }
    var dirs: [String] { lock.lock(); defer { lock.unlock() }; return _dirs }
    var detectNs: UInt64 { lock.lock(); defer { lock.unlock() }; return _detectNs }
}

@main
struct LiveHost {
    static func scan(_ root: URL) async -> ScanReducer {
        var r = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
        for await batch in FileSystemWalker.scan(root: root) { r.apply(batch) }
        return r
    }

    static func main() async {
        await tier1()
        await focusDeletion()
        await bundleRun()
        await orphanDropRun()
        await tier2()
        await homeRun()
        print("LIVE_HOST OK")
    }

    // MARK: - Deleted-while-subscanning race: the reducer drops orphan events (OPERATOR_NOTE #2)

    /// The founding race for OPERATOR_NOTE #2, on real FS. A revalidation discovers a NEW directory
    /// child; the App launches an ASYNCHRONOUS streamed sub-scan of it. If that child is DELETED before
    /// the sub-scan's late batches are folded, those batches address a now-pruned subtree — the reducer,
    /// the single-threaded ordering authority, must DROP and COUNT them (never fabricate an orphan that
    /// inflates the scan-root totals). We reproduce the interleave deterministically: collect the
    /// sub-scan's batches WITHOUT folding, delete the child + prune it, THEN fold the stale batches.
    static func orphanDropRun() async {
        let root = canonical(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tz7-live-orphan-\(UUID().uuidString)", isDirectory: true))
        mkdir(root)
        write(root.appendingPathComponent("keep.txt"), 4096)
        defer { try? fm.removeItem(at: root) }

        var reducer = await scan(root)
        let total0 = reducer.rootAllocatedBytes
        let processed0 = reducer.processedCount
        let drops0 = reducer.droppedOrphanEvents

        // A new directory-with-content appears on disk; revalidate the root to DISCOVER it (its stub is
        // linked, its own size + descent will arrive from the sub-scan the App would launch).
        let nd = root.appendingPathComponent("newdir", isDirectory: true)
        mkdir(nd)
        write(nd.appendingPathComponent("a.bin"), 100_000)
        write(nd.appendingPathComponent("b.bin"), 200_000)
        let ndId = FileSystemWalker.joinId(root.path, "newdir")
        let read = FileSystemWalker.revalidationRead(dirId: root.path, ifUnchangedFrom: nil)
        guard case let .changed(m, oa, ol, fresh, complete) = read else { die("orphan: root revalidation must enumerate") }
        let diff = reducer.revalidationDiff(dirId: root.path, mtime: m, ownAllocated: oa, ownLogical: ol,
                                            fresh: fresh, complete: complete)
        reducer.apply(diff.events)
        guard reducer.contains(ndId), diff.newChildIds.contains(ndId) else { die("orphan: newdir not discovered for sub-scan") }

        // COLLECT the sub-scan's batches WITHOUT folding them yet (the App would fold these asynchronously).
        var lateBatches: [[ScanEvent]] = []
        for await batch in FileSystemWalker.scanNewChild(url: nd, id: ndId, scanRootPath: root.path) {
            lateBatches.append(batch)
        }
        let lateEventCount = lateBatches.reduce(0) { $0 + $1.count }
        trace("orphan: newdir discovered + its sub-scan of \(lateEventCount) events captured (not yet folded)")

        // DELETE the child and prune it BEFORE its sub-scan folds — exactly the deleted-while-subscanning race.
        try? fm.removeItem(at: nd)
        let read2 = FileSystemWalker.revalidationRead(dirId: root.path, ifUnchangedFrom: nil)
        guard case let .changed(m2, oa2, ol2, fresh2, complete2) = read2 else { die("orphan: prune revalidation must enumerate") }
        let prune = reducer.revalidationDiff(dirId: root.path, mtime: m2, ownAllocated: oa2, ownLogical: ol2,
                                             fresh: fresh2, complete: complete2)
        reducer.apply(prune.events)
        guard !reducer.contains(ndId) else { die("orphan: newdir not pruned") }

        // NOW fold the STALE sub-scan batches — every event addresses the pruned subtree, so the reducer
        // drops + counts them. Totals must return to the pruned-tree truth EXACTLY (no orphan inflation).
        for batch in lateBatches { reducer.apply(batch) }

        let droppedHere = reducer.droppedOrphanEvents - drops0
        trace("orphan: reducer dropped \(droppedHere) late sub-scan events under the pruned newdir (droppedOrphanEvents total \(reducer.droppedOrphanEvents))")
        guard droppedHere == lateEventCount else { die("orphan: expected all \(lateEventCount) stale sub-scan events dropped, got \(droppedHere)") }
        guard reducer.rootAllocatedBytes == total0, reducer.processedCount == processed0 else {
            die("orphan: totals inflated by orphan events — Scanned \(reducer.rootAllocatedBytes) vs \(total0), processed \(reducer.processedCount) vs \(processed0)")
        }
        guard !reducer.contains(ndId), !reducer.contains(FileSystemWalker.joinId(ndId, "a.bin")) else {
            die("orphan: pruned subtree re-materialized as an orphan")
        }
        trace("orphan: totals equal the pruned-tree truth exactly (Scanned \(reducer.rootAllocatedBytes) B, processed \(reducer.processedCount)) — no orphan inflation")
    }

    // MARK: - Opaque `.app` bundle stays opaque on a live re-size (review-1 change 3)

    /// Scan a `.app` bundle (an opaque leaf), grow a file DEEP inside it, then re-measure via the
    /// bundle path (`revalidationBundleRead`). The opaque recursive total grows while the bundle NEVER
    /// exposes its descendants — the contract a Tier-2 flag inside a bundle must preserve.
    static func bundleRun() async {
        let root = canonical(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tz7-live-bundle-\(UUID().uuidString)", isDirectory: true))
        mkdir(root)
        let app = root.appendingPathComponent("Thing.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        mkdir(contents); write(contents.appendingPathComponent("small.bin"), 4096)
        defer { try? fm.removeItem(at: root) }

        var reducer = await scan(root)
        let appId = FileSystemWalker.joinId(root.path, "Thing.app")
        let before = reducer.makeTree(depthWindow: 20).children.first { $0.id == appId }
        guard before?.kind == .bundleLeaf, before?.children.isEmpty == true else {
            die("bundle: Thing.app not scanned as an opaque leaf")
        }
        let sizeBefore = before?.allocatedBytes ?? 0

        // Grow a file DEEP inside the bundle, then re-measure OPAQUELY.
        write(contents.appendingPathComponent("big.bin"), 300_000)
        let t0 = nowNs()
        guard case let .sized(mtime, a, l) = FileSystemWalker.revalidationBundleRead(bundleId: appId) else {
            die("bundle: revalidationBundleRead must return .sized")
        }
        reducer.apply([.directoryMtime(nodeId: appId, mtime: mtime),
                       .sizeUpdated(nodeId: appId, allocated: a, logical: l)])
        let lat = ms(t0, nowNs())
        let after = reducer.makeTree(depthWindow: 20).children.first { $0.id == appId }
        guard after?.children.isEmpty == true, (after?.allocatedBytes ?? 0) > sizeBefore else {
            die("bundle: bundle did not re-size opaquely (or exposed descendants)")
        }
        trace("bundle: .app opaque total \(sizeBefore) -> \(after!.allocatedBytes) bytes in \(String(format: "%.2f", lat)) ms; descendants never exposed")
    }

    // MARK: - Deleted FOCUS directory (review-0 change 2): parent revalidation prunes it, no ghost

    static func focusDeletion() async {
        let root = canonical(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tz7-live-focusdel-\(UUID().uuidString)", isDirectory: true))
        mkdir(root)
        write(root.appendingPathComponent("keep.txt"), 2048)
        let focus = root.appendingPathComponent("focusdir", isDirectory: true)
        mkdir(focus); write(focus.appendingPathComponent("inner.bin"), 32_768)
        defer { try? fm.removeItem(at: root) }

        var reducer = await scan(root)
        let focusId = FileSystemWalker.joinId(root.path, "focusdir")
        guard reducer.contains(focusId) else { die("focusdel: focus directory not scanned") }

        // Delete the FOCUSED directory itself. A direct revalidation of it now reads .unreadable —
        // the App re-targets the nearest surviving ancestor of its parent (here the root).
        let t0 = nowNs()
        try? fm.removeItem(at: focus)
        let direct = FileSystemWalker.revalidationRead(dirId: focusId, ifUnchangedFrom: nil)
        guard direct == .unreadable else { die("focusdel: deleted focus must read .unreadable") }
        let parent = (focusId as NSString).deletingLastPathComponent
        guard let anc = reducer.nearestRetainedAncestor(of: parent) else { die("focusdel: no surviving ancestor") }
        _ = await revalidate(&reducer, dirId: anc, label: "focusdel")
        let lat = ms(t0, nowNs())
        guard !reducer.contains(focusId) else { die("focusdel: deleted focus still in the tree (ghost)") }
        guard reducer.nearestRetainedAncestor(of: focusId) == root.path else { die("focusdel: focus did not fall back to the root") }
        trace("focusdel: deleted the FOCUS dir; parent revalidation pruned it + focus fell back to root in \(String(format: "%.2f", lat)) ms — no ghost")
    }

    // MARK: - Tier 1 (focus revalidation by mtime)

    static func tier1() async {
        let root = canonical(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tz7-live-tier1-\(UUID().uuidString)", isDirectory: true))
        mkdir(root)
        write(root.appendingPathComponent("keep.txt"), 1024)
        write(root.appendingPathComponent("victim.txt"), 8192)
        write(root.appendingPathComponent("grow.txt"), 1024)
        defer { try? fm.removeItem(at: root) }

        var reducer = await scan(root)
        let victimId = FileSystemWalker.joinId(root.path, "victim.txt")
        guard reducer.contains(victimId) else { die("tier1: victim not scanned") }
        let total0 = reducer.rootAllocatedBytes
        trace("tier1: scanned \(reducer.makeTree(depthWindow: 20).nodeCount) nodes, \(total0) bytes")

        // Fast path: an untouched directory revalidates in one stat.
        let m0read = FileSystemWalker.revalidationRead(dirId: root.path, ifUnchangedFrom: nil)
        guard case let .changed(m0, _, _, _, _) = m0read else { die("tier1: initial read must enumerate") }
        let fp0 = nowNs()
        let fast = FileSystemWalker.revalidationRead(dirId: root.path, ifUnchangedFrom: m0)
        trace("tier1: unchanged fast-path = \(fast == .unchanged ? "UNCHANGED" : "??") in \(String(format: "%.3f", ms(fp0, nowNs()))) ms (one lstat)")
        guard fast == .unchanged else { die("tier1: untouched dir must return .unchanged") }

        // DELETE — the founding case (a deleted folder's tile must retire without a rescan).
        try? fm.removeItem(at: root.appendingPathComponent("victim.txt"))
        let (dDel, latDel) = await revalidate(&reducer, dirId: root.path, label: "tier1")
        guard !reducer.contains(victimId) else { die("tier1: deleted victim still in the tree") }
        guard dDel.changed, reducer.rootAllocatedBytes < total0 else { die("tier1: delete did not ripple totals") }
        trace("tier1: DELETE detection latency (focus poke) = \(String(format: "%.2f", latDel)) ms; tile retired, total \(total0) -> \(reducer.rootAllocatedBytes)")

        // GROW — a file that changed size in place.
        write(root.appendingPathComponent("grow.txt"), 200_000)
        let growId = FileSystemWalker.joinId(root.path, "grow.txt")
        let before = reducer.makeTree(depthWindow: 20).children.first { $0.id == growId }?.allocatedBytes ?? 0
        _ = await revalidate(&reducer, dirId: root.path, label: "tier1")
        let after = reducer.makeTree(depthWindow: 20).children.first { $0.id == growId }?.allocatedBytes ?? 0
        guard after > before else { die("tier1: grow.txt did not grow in the tree") }
        trace("tier1: GROW grow.txt \(before) -> \(after) bytes (no rescan)")

        // ADD a new directory-with-content — streamed sub-scan.
        let nd = root.appendingPathComponent("newdir", isDirectory: true)
        mkdir(nd); write(nd.appendingPathComponent("inner.bin"), 50_000)
        _ = await revalidate(&reducer, dirId: root.path, label: "tier1")
        let ndId = FileSystemWalker.joinId(root.path, "newdir")
        let ndNode = reducer.makeTree(depthWindow: 20).children.first { $0.id == ndId }
        guard ndNode?.children.map(\.name) == ["inner.bin"], (ndNode?.allocatedBytes ?? 0) > 40_000 else {
            die("tier1: new directory subtree did not stream in")
        }
        trace("tier1: ADD newdir/ streamed in (\(ndNode!.allocatedBytes) bytes)")
    }

    // MARK: - Tier 2 (FSEvents)

    static func tier2() async {
        let root = canonical(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tz7-live-tier2-\(UUID().uuidString)", isDirectory: true))
        mkdir(root)
        write(root.appendingPathComponent("a.txt"), 4096)
        write(root.appendingPathComponent("doomed.txt"), 16_384)
        defer { try? fm.removeItem(at: root) }

        var reducer = await scan(root)
        let doomedId = FileSystemWalker.joinId(root.path, "doomed.txt")

        let result = FSResult()
        guard let watcher = FSEventsWatcher(rootPath: root.path, onDirs: { ids in
            result.record(ids, nowNs())
        }) else { die("tier2: FSEventsWatcher could not be created — Tier-2 unavailable") }
        defer { watcher.stop() }
        try? await Task.sleep(nanoseconds: 500_000_000) // let the stream arm

        let t0 = nowNs()
        result.arm(t0)
        try? fm.removeItem(at: root.appendingPathComponent("doomed.txt"))
        trace("tier2: mutated (deleted doomed.txt), waiting for FSEvents…")
        let waited = result.sem.wait(timeout: .now() + 8.0)
        guard waited == .success else { die("tier2: no FSEvents callback within 8 s") }
        let lat = ms(t0, result.detectNs)
        trace("tier2: FSEvents flagged \(result.dirs.count) dir(s) in \(String(format: "%.0f", lat)) ms (coalesced; expected ≤ ~2 s)")

        // Drive the same revalidation the App wires FSEvents onDirs to.
        for dirId in result.dirs {
            _ = await revalidate(&reducer, dirId: dirId, label: "tier2")
        }
        guard !reducer.contains(doomedId) else { die("tier2: FSEvents-driven revalidation did not retire the tile") }
        trace("tier2: tile retired via FSEvents, no rescan")
    }

    // MARK: - HOME run (a real folder under $HOME retires on delete)

    static func homeRun() async {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let wrapper = canonical(home.appendingPathComponent("tz7-live-test-\(UUID().uuidString)", isDirectory: true))
        mkdir(wrapper)
        let keep = wrapper.appendingPathComponent("keep", isDirectory: true)
        let doomed = wrapper.appendingPathComponent("doomed", isDirectory: true)
        mkdir(keep); write(keep.appendingPathComponent("k.bin"), 4096)
        mkdir(doomed); write(doomed.appendingPathComponent("d.bin"), 65_536)
        defer { try? fm.removeItem(at: wrapper) }

        var reducer = await scan(wrapper)
        let doomedId = FileSystemWalker.joinId(wrapper.path, "doomed")
        guard reducer.contains(doomedId) else { die("home: doomed folder not scanned") }
        trace("home: scanned \(wrapper.path) — \(reducer.makeTree(depthWindow: 20).nodeCount) nodes")

        try? fm.removeItem(at: doomed)
        let (d, lat) = await revalidate(&reducer, dirId: wrapper.path, label: "home")
        guard d.changed, !reducer.contains(doomedId) else { die("home: deleted folder's tile did not retire") }
        trace("home: deleted ~/\(wrapper.lastPathComponent)/doomed — tile retired in \(String(format: "%.2f", lat)) ms")
    }
}
