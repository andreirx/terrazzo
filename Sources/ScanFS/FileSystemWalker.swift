//
//  FileSystemWalker.swift — the streaming, parallel filesystem walker.
//  Module maturity: PROTOTYPE (slice TZ-2; hot loop rewritten TZ-6)
//
//  THE I/O ADAPTER. Every filesystem syscall in Terrazzo lives in ScanFS, and
//  the descent lives here (CLAUDE.md constraint 1; PLAN abstraction ledger:
//  "APFS quirks isolated from domain logic"). It turns a directory tree into an
//  `AsyncStream<[ScanEvent]>` that the pure `ScanReducer` folds — the walker
//  knows the disk, the reducer knows the tree, and they meet only at events.
//
//  TZ-6 (the 120× fix + scheduling). The per-entry path no longer touches
//  Foundation URL/URLResourceValues: `DirectoryReader` (getattrlistbulk) returns a
//  whole directory of attributes per syscall, and regular files carry their size
//  inline — ~9–13× the old `contentsOfDirectory`+`resourceValues`+`measure` path
//  (profiled 2026-08-16). Two more TZ-6 levers layer on top:
//    - HIERARCHICAL SPAWNING (PLAN c): `walkDirectory` delegates its child
//      directories to concurrent subtasks for the top `WalkTuning.spawnDepth`
//      levels — but only while a `SpawnGate` permit is free (a hard global bound on
//      outstanding subtasks); otherwise, and below the spawn depth, it descends
//      inline. So a giant subtree (~/Library) no longer grinds in a single task while
//      finished siblings' pool threads idle, and a high-fanout directory cannot
//      explode the task count. Task count stays bounded (see `WalkTuning`/`SpawnGate`).
//    - ANTICIPATORY ROOT SCAN (PLAN): `anticipateVolumeRoot` warms the volume
//      root's metadata cache (excluding the active scan root) at the measured
//      `defaultAnticipatoryPriority` QoS, so a later zoom-out promotion finds
//      siblings warm.
//
//  CONCURRENCY (ratified decision 5): the root's enumeration (child STRUCTURE) is
//  emitted FIRST — before any sizing that could take time — so ALL top-level tiles
//  appear at once. THEN the top-level entries are fanned out through the SAME gated
//  `fanOut` the whole descent uses (review-0 change 3 — the top level is not exempt
//  from the global task bound): for a typical root each top-level DIRECTORY still gets
//  its own concurrent depth-first descent and each `.app` BUNDLE its own sizing task
//  (decision 5), but a pathological high-fanout root stays within the `SpawnGate`
//  bound rather than spawning a task per entry (tiles already appeared up front, so
//  gating descent delays no tile). Workers emit into the shared `EventBatcher` actor,
//  which serializes them into ordered batches — the only synchronization needed,
//  because the reducer is order-independent by design.
//
//  DISJOINTNESS INVARIANTS (PLAN §TZ-6 — why nothing is ever walked twice), all
//  preserved by the TZ-6 rewrite:
//    1. ONE ENUMERATION POINT: `classifyChildren` is the single place a directory's
//       children are listed, called once by that directory's single owner.
//    2. EXCLUSIVE OWNERSHIP: each child directory is EITHER delegated to exactly one
//       subtask OR recursed sequentially by its owner — never both. Work-stealing
//       picks up an unstarted subtask whole; it never splits a directory.
//    3. SYMLINKS NEVER FOLLOWED: a symlink is a leaf sized by the link (`.symlink`
//       from `DirectoryReader`, never opened).
//    4. ONE SCAN = ONE DEVICE: a child whose `st_dev` differs from the scan root's
//       is a boundary stub (shown + sized by its own entry, never entered) — kills
//       the /System/Volumes/Data firmlink double-count, /Volumes + network mounts.
//    5. GRAFT-REFERENCE EXCLUSION: the sibling-exclusion promotion walk emits the
//       already-scanned child as a stub-only reference (`excluding:`), never
//       re-entered or re-sized.
//
//  POLICY (ScanPolicy): hidden always included; symlinks never followed; `.app`
//  bundles are opaque leaves whose recursive total is measured in a SEPARATE task;
//  the walker descends FULLY (sizes true, decision 4) — the depth window is applied
//  later, in the reducer's projection.
//
//  DENIAL: a directory we cannot enumerate (EPERM/EACCES) emits `accessDenied` and
//  stops there — never a silent skip (VISION §"invisible space is first-class").
//
//  SIZING: `measure(_:)` is PUBLIC and remains the size ORACLE the golden tests
//  recompute against. The TZ-6 fast path derives identical numbers WITHOUT calling
//  it per entry (see `DirectoryReader` header: a file's ATTR_FILE_ALLOCSIZE and a
//  dir/symlink's st_blocks*512 both equal `measure().allocated` — verified over
//  ~60k real nodes with zero divergence; the golden gate proves it on the fixture).
//

import Foundation
import Darwin
import os
#if canImport(ScanCore)
import ScanCore
#endif

/// A GLOBAL permit counter bounding how many recursive child-directory subtasks the
/// descent may have OUTSTANDING at once (revise finding 4: "cap concurrent spawned
/// subtasks with a counter/semaphore, not 'first three levels'"). Non-blocking by
/// design: `tryAcquire` returns a permit if one is free, else `false` and the caller
/// walks that child INLINE — never awaits, so the cooperative pool can never deadlock on
/// permits. Backed by `OSAllocatedUnfairLock` (macOS 13+, deployment target is 14) for a
/// synchronous, allocation-free critical section in the hot path — no actor hop per child.
///
/// Abstraction ledger — SpawnGate: concrete user = `walkDirectory`'s recursive fan-out;
/// axis = bounding concurrent spawned subtasks (the task-overhead guardrail the PLAN
/// names); rejected simpler alternative = ungated fan-out at `depth < spawnDepth`, which a
/// single high-fanout directory (a cache dir with tens of thousands of subdirs) turns into
/// tens of thousands of concurrent tasks — an unbounded task count, exactly what the
/// revise finding rejects.
final class SpawnGate: Sendable {
    private let permits: OSAllocatedUnfairLock<Int>
    init(max: Int) { permits = OSAllocatedUnfairLock(initialState: max) }
    /// Take a permit if one is free; `true` on success (a permit is now held), `false`
    /// if none remain (the caller must walk the child inline). Never blocks.
    func tryAcquire() -> Bool {
        permits.withLock { n in
            if n > 0 { n -= 1; return true }
            return false
        }
    }
    /// Return a permit (paired with each successful `tryAcquire`, in a `defer`).
    func release() { permits.withLock { $0 += 1 } }
}

/// A filesystem object's PHYSICAL identity — `(st_dev, st_ino)` — which uniquely names a
/// directory regardless of the PATH taken to reach it (review-0 change 1). The anticipatory
/// warm needs this because the active scan uses a directory's LOGICAL path (`/Users/apple`)
/// while the volume-root warm descends the PHYSICAL mount (`/System/Volumes/Data`), so the
/// SAME directory is reached as `/System/Volumes/Data/Users/apple` — an APFS firmlink alias.
/// A path-string compare misses it and the warm re-walks the active scan subtree (competing
/// I/O + a disjointness-invariant-5 violation). Device+inode compares equal across every
/// alias, so it is the honest exclusion key.
///
/// Abstraction ledger — FileID: concrete user = `warmDirectory`'s exclusion check; axis =
/// path-independent directory identity (the firmlink-alias case the reviewer found); rejected
/// simpler alternative = string-path exclusion (the shipped bug — a firmlink alias is a
/// different string for the same directory, so it fails to exclude).
private struct FileID: Equatable {
    let device: dev_t
    let inode: ino_t
    /// The identity of the object at `path` via `lstat` (never follows a final symlink — a
    /// symlink is its own object). `nil` if it cannot be stat'd.
    static func of(_ path: String) -> FileID? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileID(device: st.st_dev, inode: st.st_ino)
    }
}

/// Named tuning bounds for the TZ-6 parallel descent (one home for throughput knobs).
enum WalkTuning {
    /// Directories at descent depth < this DELEGATE their child directories to
    /// concurrent subtasks (the cooperative pool then work-steals); at or below it,
    /// descent is sequential within the owning task. Top-level directories are depth 1
    /// (the scan root is depth 0), so a value of 3 parallelizes the top three directory
    /// levels — the "~2-3 levels" the PLAN names.
    ///
    /// TASK-COUNT BOUND (packet: "the walker's task count must stay bounded"; revise
    /// finding 4, made global by review-0 change 3). Depth ALONE is not a bound: a single
    /// directory at depth < spawnDepth
    /// with tens of thousands of subdirectories would fan out tens of thousands of tasks.
    /// So delegation is ALSO gated by `SpawnGate` at `maxConcurrentSpawns` permits — a
    /// child directory is delegated only if a permit is free, else it is walked INLINE. The
    /// top-level fan-out is NO LONGER exempt (review-0 change 3): the roots delegate through
    /// the SAME shared gate (see `fanOut`), so the only concurrent tasks that ever exist are
    /// at most `maxConcurrentSpawns` OUTSTANDING delegated subtasks plus the single owning
    /// walk task. Total concurrent walker tasks ≤ maxConcurrentSpawns + 1, INDEPENDENT of the
    /// scan root's fanout or the tree's size — the genuinely global bound the finding demands
    /// (the earlier "topLevelEntries + maxConcurrentSpawns" claim was fanout-dependent and is
    /// retired). `spawnDepth` remains as a second guardrail so very deep chains do not churn
    /// permits far from the root where parallelism no longer helps.
    static let spawnDepth = 3

    /// The hard ceiling on concurrently-OUTSTANDING recursive subtasks (see `SpawnGate`
    /// and `spawnDepth`). Fixed rather than derived: it is a MEMORY/overhead ceiling, not
    /// a parallelism target — the cooperative pool only ever RUNS ~(cores) tasks at once,
    /// so 64 keeps a deep work-stealing backlog (≫ the ~10 cores here, so no core starves)
    /// while capping outstanding tasks far below the millions an ungated fan-out reaches.
    static let maxConcurrentSpawns = 64

    /// Per-directory throttle for the ANTICIPATORY warm scan (see `anticipateVolumeRoot`).
    /// Measured necessity (TZ-6, threads.sh): an UNthrottled concurrent `/`-volume warm —
    /// even at low QoS — added ~10–20 ms to the main thread's per-scene intake during the
    /// primary scan, tipping the ratified worst-main-gap over 100 ms (108–121 ms vs 98 ms
    /// without it). A short sleep after each directory keeps the warm genuinely out of the
    /// way (worst gap back to ~98 ms WITH it running); the warm is latency-tolerant by
    /// nature (it only needs to finish before the user zooms out), so slowing it costs
    /// nothing the feature cares about. The threading law outranks warm-ahead speed.
    static let anticipatoryThrottleNanos: UInt64 = 4_000_000 // 4 ms
}

public enum FileSystemWalker {

    /// QoS of the anticipatory volume-root warm (see `anticipateVolumeRoot`). RESOLVED BY
    /// MEASUREMENT (OPERATOR_NOTE tz6_anticipatory_qos), scan_rate_host `+anticipate`, home
    /// scan, 3 interleaved rounds on this machine:
    ///   primary alone      : ~210k files/s
    ///   primary + .utility : ~212k files/s (within run-to-run noise, ±2.5%) — warm ~41 dirs/s
    ///   primary + .background: ~212k files/s (within noise)                  — warm  ~7 dirs/s
    /// Both QoS keep primary degradation < 5% — the per-directory THROTTLE, not the QoS, is
    /// what protects the primary (an UNthrottled warm was what broke the main-gap; see
    /// `WalkTuning.anticipatoryThrottleNanos`). The decisive difference is warm THROUGHPUT:
    /// `.utility` warms ~6× faster (41 vs 7 dirs/s) because `.background`'s kernel I/O throttle
    /// starves the warm here — the flaw, not the feature. So the criterion "degradation < 5%
    /// WITH the faster anticipation" picks `.utility`. This constant IS that choice — the code
    /// and every comment naming it now agree (the name-honesty rider that retired the earlier
    /// `.background`-code / `.utility`-comment mismatch). Public so the default argument below
    /// (and App/harness callers) can name it across the module boundary; kept here rather than
    /// in internal `WalkTuning` for exactly that reason.
    public static let defaultAnticipatoryPriority: TaskPriority = .utility

    // MARK: - Public API

    /// Walk `root` and stream `ScanEvent` batches until the whole tree is scanned,
    /// then finish the stream. Cancelling the consuming task (or terminating the
    /// stream) cancels the walk.
    ///
    /// The node id of every node is an absolute path rooted at the scan root: the
    /// root's id is `root.path`, and every descendant is `parentId + "/" + name`
    /// (see `joinId` / `classifyChildren`). Stable, path-derived — the contract
    /// `SizeTree.id` documents. Construct a `ScanReducer(rootId: root.path,
    /// rootName: root.lastPathComponent)` to fold this stream.
    public static func scan(root: URL, policy: ScanPolicy = .default) -> AsyncStream<[ScanEvent]> {
        AsyncStream { continuation in
            let work = Task {
                let batcher = EventBatcher { continuation.yield($0) }
                // Latency bound: flush accumulated events on a cadence even if the
                // size cap is not reached (packet: "~100ms or ~1000 events").
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: BatchLimits.flushIntervalNanos)
                        await batcher.flush()
                    }
                }
                await walkRoot(root, policy: policy, batcher: batcher)
                ticker.cancel()
                await batcher.flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// SIBLING-EXCLUSION WALK (layer b of root promotion, TZ-4b). Walk `newRoot` and
    /// stream `ScanEvent`s for its NEW children only — the already-scanned child
    /// `excludingChildId` (the previous scan root, now grafted under `newRoot` in the
    /// reducer) is emitted as a GRAFT REFERENCE: its stub appears in `newRoot`'s
    /// `childrenDiscovered` so the parent links to it, but it is NEVER re-sized or
    /// re-entered (disjointness invariant 5). This is what makes promotion "nothing
    /// discarded, nothing re-scanned": the grafted subtree keeps its reducer state, and
    /// only the siblings do fresh I/O.
    ///
    /// ONE SCAN = ONE DEVICE (disjointness invariant 4). A child on a DIFFERENT st_dev
    /// than `newRoot` is a BOUNDARY STUB: shown and sized by its own directory entry, but
    /// never entered — the firmlink / mount guard the invariant names. CONSEQUENCE,
    /// documented and honest: promoting all the way to `/` shows firmlinked data dirs
    /// OTHER than the one you promoted from as un-entered boundary stubs (their bytes fall
    /// into the Unaccounted figure) rather than double-counting them. Full multi-volume
    /// scanning is a named extension point (VISION §"Root-privileged scan mode").
    ///
    /// `newRootId` is the id the reducer was re-rooted to (its absolute path); descendant
    /// ids are `joinId(newRootId, name)`. Symlinks are never followed (same policy).
    public static func scanSiblings(newRoot: URL, newRootId: String,
                                    excludingChildId excluded: String,
                                    policy: ScanPolicy = .default) -> AsyncStream<[ScanEvent]> {
        AsyncStream { continuation in
            let work = Task {
                let batcher = EventBatcher { continuation.yield($0) }
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: BatchLimits.flushIntervalNanos)
                        await batcher.flush()
                    }
                }
                await walkNewRoot(newRoot, newRootId: newRootId, excluding: excluded,
                                  policy: policy, batcher: batcher)
                ticker.cancel()
                await batcher.flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - Revalidation (TZ-7 — the living map)

    /// The outcome of re-reading a directory for staleness (Tier-1/Tier-2). A SUM TYPE because the
    /// three cases demand different handling and an exhaustive `switch` at the one call site is the
    /// deterministic list of what must be decided — never a tuple a caller could half-read.
    public enum RevalidationRead: Sendable, Equatable {
        /// The directory's mtime matched the `known` value — its listing is CURRENT. ONE `lstat`, no
        /// enumeration, nothing to diff (the near-free Tier-1 fast path, PLAN §TZ-7).
        case unchanged
        /// The directory changed (or `known` was nil). Its fresh children, own mtime, own-entry size
        /// (`st_blocks * 512` / `st_size` from the same `lstat` — matching the scan's dir own-size so
        /// an unchanged directory's own size does not spuriously churn; review-0 change 5), and whether
        /// the read was COMPLETE (a partial read must NOT drive removals — see `revalidationDiff`).
        case changed(mtime: Int64, ownAllocated: Int64, ownLogical: Int64, fresh: [FreshChild], complete: Bool)
        /// The directory is gone, is not a directory, or could not be opened — its own parent's
        /// revalidation will `childRemoved` it; here there is nothing to do.
        case unreadable
    }

    /// Re-read `dirId` (an absolute path == its node id) for TZ-7 revalidation: `lstat` its mtime and,
    /// if it differs from `known` (or `known` is nil), enumerate it into policy-classified `FreshChild`
    /// values the pure `ScanReducer.revalidationDiff` folds. The mtime SHORT-CIRCUIT is the near-free
    /// Tier-1 property: an unchanged directory costs exactly one `lstat`. All syscalls stay in ScanFS
    /// (CLAUDE.md constraint 1); the diff itself is pure and lives in ScanCore.
    public static func revalidationRead(dirId: String, ifUnchangedFrom known: Int64?,
                                        policy: ScanPolicy = .default) -> RevalidationRead {
        var st = stat()
        guard lstat(dirId, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return .unreadable }
        let m = DirectoryReader.mtimeNanos(st)
        if let known, known == m { return .unchanged }
        // The directory's OWN entry size, from the SAME lstat (review-0 change 5). `st_blocks * 512`
        // is exactly the `DirectoryReader` dir-own-size formula the initial scan used, so an unchanged
        // directory yields the identical value and the diff stays calm.
        let ownAllocated = Int64(st.st_blocks) * 512
        let ownLogical = Int64(st.st_size)
        let children: [DirectoryReader.Child]
        let complete: Bool
        switch DirectoryReader.read(dirId) {
        case .unreadable: return .unreadable
        case .complete(let c): children = c; complete = true
        case .partial(let c): children = c; complete = false
        }
        var fresh: [FreshChild] = []
        fresh.reserveCapacity(children.count)
        for child in children {
            let cid = joinId(dirId, child.name)
            // SAME classification the initial walk applies (symlink → leaf; `.app` dir → bundle leaf).
            let kind: NodeKind
            switch child.kind {
            case .symlink, .file: kind = .file
            case .dir: kind = policy.isBundleLeaf(name: child.name) ? .bundleLeaf : .dir
            }
            fresh.append(FreshChild(
                id: cid, name: child.name, kind: kind,
                allocated: child.allocated, logical: child.logical, isHidden: child.isHidden,
                mtime: (kind == .dir || kind == .bundleLeaf) ? child.mtime : nil))
        }
        return .changed(mtime: m, ownAllocated: ownAllocated, ownLogical: ownLogical,
                        fresh: fresh, complete: complete)
    }

    /// The outcome of re-measuring an opaque `.app` BUNDLE LEAF for a TZ-7 live update (review-1
    /// change 3). A bundle stays a SINGLE opaque tile — its descendants are NEVER exposed — so a
    /// change inside (or at) it refreshes only its recursive TOTAL, never a child diff. Three honest
    /// cases, like a directory read but with no child listing.
    public enum BundleRevalidationRead: Sendable, Equatable {
        /// Fully re-measured: the bundle's own mtime + fresh recursive (allocated, logical) total.
        case sized(mtime: Int64, allocated: Int64, logical: Int64)
        /// Present but not fully readable (a directory inside is denied), OR the read was torn down —
        /// the total is UNKNOWN, so the retained size is LEFT AS-IS (never a false shrink). The
        /// caller skips the update. Distinct from `unreadable`: the bundle is still there.
        case incomplete
        /// The bundle is gone / not a directory — its parent's revalidation `childRemoved`s it.
        case unreadable
    }

    /// Re-measure an opaque bundle leaf (`bundleId` == its path == node id) for a live update
    /// (review-1 change 3): `lstat` its mtime, then recompute its recursive total the SAME way the
    /// initial scan did (`bundleTotal` — sums own + descendants, emitting NO child events).
    /// Enumerating the bundle here is how a deep change inside it is caught, but NOTHING about its
    /// descendants crosses back into the reducer — the composition layer folds only a single
    /// `sizeUpdated`, so the opaque-leaf contract holds. All syscalls stay in ScanFS (constraint 1).
    /// A bundle lives on one volume by construction (the initial scan sized it within the scan root's
    /// device), so its OWN device is the boundary — a cross-device symlink inside is not followed
    /// (invariant 4), matching the initial `sizeBundle` measurement exactly.
    public static func revalidationBundleRead(bundleId: String) -> BundleRevalidationRead {
        var st = stat()
        guard lstat(bundleId, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return .unreadable }
        let mtime = DirectoryReader.mtimeNanos(st)
        // `bundleTotal` returns nil only on cancellation (teardown) — treat that as `incomplete` (a
        // safe no-op), never `unreadable` (which would wrongly retire a still-present bundle).
        guard let (a, l, fullyRead) = bundleTotal(bundleId, boundaryDevice: st.st_dev) else { return .incomplete }
        return fullyRead ? .sized(mtime: mtime, allocated: a, logical: l) : .incomplete
    }

    /// Stream a NORMAL sub-scan of a single new child discovered by revalidation (a new directory or
    /// bundle at a revalidated focus). Rooted at `id` (the child's node id == its path) so its
    /// descendants share the scan-root identity prefix; the SCAN ROOT's device is derived HERE from
    /// `scanRootPath` (the syscall stays in ScanFS — CLAUDE.md constraint 1) so the one-scan-one-device
    /// rule (invariant 4) holds for a live-added mount too. A `.app` is sized as an opaque leaf (never
    /// expanded); a plain directory emits its own size then descends fully. Folded into the SAME
    /// pipeline as the primary scan (`ScenePipeline.ingest`), so a new subtree streams into the live
    /// map exactly like first-scan data.
    public static func scanNewChild(url: URL, id: String, scanRootPath: String,
                                    policy: ScanPolicy = .default) -> AsyncStream<[ScanEvent]> {
        AsyncStream { continuation in
            let work = Task {
                var rootStat = stat()
                let boundaryDevice: dev_t? = stat(scanRootPath, &rootStat) == 0 ? rootStat.st_dev : nil
                let batcher = EventBatcher { continuation.yield($0) }
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: BatchLimits.flushIntervalNanos)
                        await batcher.flush()
                    }
                }
                await walkNewChild(url: url, id: id, boundaryDevice: boundaryDevice,
                                   policy: policy, batcher: batcher)
                ticker.cancel()
                await batcher.flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// One new child: opaque-bundle sizing, cross-device boundary stub, or ordinary directory descent.
    private static func walkNewChild(url: URL, id: String, boundaryDevice: dev_t?,
                                     policy: ScanPolicy, batcher: EventBatcher) async {
        if Task.isCancelled { return }
        let path = url.path
        let name = url.lastPathComponent
        var st = stat()
        let childDev: dev_t? = stat(path, &st) == 0 ? st.st_dev : nil
        // One device (invariant 4): a child on a different device than the scan root is a boundary
        // stub — sized by its own entry + completed, never entered (kills a live-mounted volume from
        // double-counting into the map).
        if let boundaryDevice, let childDev, childDev != boundaryDevice {
            let (a, l) = measure(url)
            await batcher.add([.sizeUpdated(nodeId: id, allocated: a, logical: l),
                               .subtreeCompleted(nodeId: id)])
            return
        }
        let dev = childDev ?? boundaryDevice
        if policy.isBundleLeaf(name: name) {
            // Opaque `.app`: one recursive total (bundleTotal includes own) + completed/denied.
            await sizeBundle(path, id: id, batcher: batcher, boundaryDevice: dev)
            return
        }
        // Ordinary directory: the revalidation diff emitted only its stub, so emit its OWN size here
        // (as the parent's classify would have), then descend fully through the shared gated fan-out.
        let (a, l) = measure(url)
        await batcher.add([.sizeUpdated(nodeId: id, allocated: a, logical: l)])
        let gate = SpawnGate(max: WalkTuning.maxConcurrentSpawns)
        await walkDirectory(path, id: id, policy: policy, batcher: batcher,
                            boundaryDevice: dev, depth: 0, gate: gate)
    }

    /// ANTICIPATORY ROOT SCAN (PLAN §TZ-6 deliverable 5). Warm the scan root's VOLUME
    /// metadata cache — every directory EXCEPT the active scan root's subtree — at the
    /// `priority` QoS (default `defaultAnticipatoryPriority`), so a later zoom-out promotion
    /// (`~` → `/Users` → `/`) finds its new siblings warm. Returns the `Task` so the App can
    /// cancel it when the scan is torn down.
    ///
    /// WHAT IT DOES (and does NOT). It enumerates directories with `DirectoryReader`
    /// (the same getattrlistbulk read the promotion walk will later use), which populates
    /// the kernel's vnode/attribute cache — then DISCARDS the results. It emits NO events
    /// and touches NO reducer: promotion warmth, not a second concurrent fold (that would
    /// need concurrent re-rooting — out of this slice; "warm" is the ratified floor,
    /// PLAN §TZ-6). It shares promotion's disjointness discipline: the active scan root's
    /// subtree is EXCLUDED at its enumeration point (invariant 5), so the two walks never
    /// overlap; it stays on ONE DEVICE (invariant 4) and never follows symlinks
    /// (invariant 3).
    ///
    /// WHY IT DOES NOT DISTURB THE PRIMARY SCAN. Two levers, both measured. (1) THROTTLE: a
    /// short sleep after every directory (`WalkTuning.anticipatoryThrottleNanos`) — a MEASURED
    /// requirement, not caution: an unthrottled warm added ~10–20 ms to the main thread's
    /// per-scene intake and pushed the ratified worst-main-gap over 100 ms; throttled, the
    /// worst gap stays ~98 ms with the warm running (threads.sh). (2) QoS: the warm runs at
    /// `defaultAnticipatoryPriority`, chosen BY MEASUREMENT per OPERATOR_NOTE
    /// tz6_anticipatory_qos — see that constant's doc and the TZ-6 report for the two primary
    /// rates and the two anticipation THROUGHPUTS (dirs/s) behind the choice. Whole-volume
    /// warm-to-COMPLETION is throttle-bounded (a 4 ms/dir floor ⇒ tens of minutes), so the
    /// decision rests on throughput + a time-bounded warm-only run, not a full-completion time
    /// (`scan_rate_host warmonly warmcap=…`). The threading law (the beachball invariant)
    /// outranks warm-ahead speed, and the warm is latency-tolerant, so the QoS is picked for
    /// lowest primary degradation first, fastest warm second.
    /// `onDir` fires once per warmed directory, passing that directory's PATH — nil in
    /// production (a per-dir optional test, no cost). It is BOTH the QoS measurement seam and
    /// the exclusion-observability seam: `scan_rate_host` ignores the path and counts warmed
    /// dirs for per-QoS THROUGHPUT (whole-volume warm-to-completion is throttle-dominated —
    /// tens of minutes — so dirs/s over a capped window is the honest signal), while a test
    /// records the paths to prove the active-root subtree (by identity, across a path alias)
    /// is never warmed (review-0 changes 1–2). Concrete users: `scan_rate_host`,
    /// `DirectoryReaderTests`; axis: observing which directories the warm actually touched;
    /// rejected alternative: reimplementing the throttled walk in each harness (duplication
    /// that would measure a DIFFERENT path than ships).
    public static func anticipateVolumeRoot(excluding scanRoot: URL,
                                            priority: TaskPriority = FileSystemWalker.defaultAnticipatoryPriority,
                                            onDir: (@Sendable (String) -> Void)? = nil)
        -> Task<Void, Never> {
        Task(priority: priority) {
            // IDENTITY-BASED exclusion (review-0 change 1). Capture the active scan root's
            // physical `(dev, ino)` — NOT its path string. The warm descends the physical
            // mount and reaches the scan root through a firmlink alias whose PATH differs from
            // `scanRoot.path`; only the identity matches across that alias. `nil` (root
            // vanished) → no exclusion, but the one-device rule still bounds the warm.
            let excluded = FileID.of(scanRoot.path)
            let mount = mountPoint(of: scanRoot.path) ?? "/"
            var st = stat()
            let dev: dev_t? = stat(mount, &st) == 0 ? st.st_dev : nil
            await warmDirectory(mount, excludingIdentity: excluded, boundaryDevice: dev, onDir: onDir)
        }
    }

    /// The mount point of the volume containing `path` (statfs `f_mntonname`) — the volume
    /// root the anticipatory scan warms and that promotion climbs toward. `nil` on failure.
    private static func mountPoint(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: s.f_mntonname) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
    }

    /// Recursively touch `path`'s directories to warm the cache (see `anticipateVolumeRoot`).
    /// EXCLUDES the active scan-root subtree BY IDENTITY (`excludingIdentity` — device+inode,
    /// so a firmlink/path alias of the active root is still excluded; review-0 change 1), stays
    /// on one device, never follows symlinks, and THROTTLES (a short sleep after every
    /// directory) so it stays out of the primary scan's way — a measured necessity for the
    /// threading law (see `WalkTuning.anticipatoryThrottleNanos`).
    ///
    /// The exclusion is checked at ENTRY, BEFORE reading: if THIS directory is the active scan
    /// root by identity, the warm returns immediately — it never enumerates the excluded
    /// subtree (invariant 5), whatever path alias led here. The `lstat` that computes the
    /// entry identity is itself cache-warming, so it is not wasted work.
    private static func warmDirectory(_ path: String, excludingIdentity excluded: FileID?,
                                      boundaryDevice: dev_t?,
                                      onDir: (@Sendable (String) -> Void)? = nil) async {
        if Task.isCancelled { return }
        // Identity exclusion (review-0 change 1): the primary scan owns this subtree — stay
        // disjoint no matter which path alias (firmlink) reached it. Return BEFORE the read so
        // the excluded subtree is never enumerated.
        if let excluded, FileID.of(path) == excluded { return }
        // Reading warmed the cache — that is the whole point; a truncated (partial) read
        // still warmed what it reached, so warm those children too. Unreadable → nothing.
        let children: [DirectoryReader.Child]
        switch DirectoryReader.read(path) {
        case .unreadable: return
        case .complete(let c), .partial(let c): children = c
        }
        onDir?(path) // measurement + exclusion-observability seam — see anticipateVolumeRoot
        try? await Task.sleep(nanoseconds: WalkTuning.anticipatoryThrottleNanos) // stay out of the way
        for c in children where c.kind == .dir {
            if Task.isCancelled { return }
            if let boundaryDevice, c.device != boundaryDevice { continue } // one device
            let childPath = path + "/" + c.name
            // The child's own entry-check (by identity) handles exclusion — one place, one rule.
            await warmDirectory(childPath, excludingIdentity: excluded, boundaryDevice: boundaryDevice, onDir: onDir)
        }
    }

    #if DEBUG
    /// TEST-ONLY warm entry (review-0 change 2). Warm from an ARBITRARY start directory (not the
    /// volume mount `anticipateVolumeRoot` uses), excluding `scanRootPath` BY IDENTITY, recording
    /// every touched directory via `onDir`. Lets a unit test prove on a SMALL temp tree that the
    /// active-root subtree is excluded even when reached through a DIFFERENT path string than the
    /// one the identity was captured from (the firmlink-alias case in miniature) — the public
    /// `anticipateVolumeRoot` warms the whole volume mount, which is not unit-testable. Keeps
    /// `warmDirectory` and `FileID` private; compiled out of release (see `swiftc -O`, no
    /// `-DDEBUG`, in the build scripts). Concrete user: `DirectoryReaderTests`; axis: warming
    /// from a chosen start dir on a bounded tree; rejected alternative: driving the whole-volume
    /// public API (untestable at unit scale).
    static func warmTreeForTesting(start: String, excludingIdentityOf scanRootPath: String,
                                   boundaryDevice: dev_t?,
                                   onDir: @escaping @Sendable (String) -> Void) async {
        await warmDirectory(start, excludingIdentity: FileID.of(scanRootPath),
                            boundaryDevice: boundaryDevice, onDir: onDir)
    }
    #endif

    /// Join a parent node id and a child name into the child's node id. A plain path
    /// join with exactly one separator — handles a root id of "/" without producing
    /// "//child". This is the ONE place descendant ids are built, so the whole tree
    /// shares the scan root's identity prefix. Pure string composition, no FS access.
    static func joinId(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// Measure a single filesystem entry's OWN size. NEVER follows symlinks (uses
    /// `lstat`): a symlink is sized by the link, its target untouched.
    ///
    /// `allocated` = on-disk allocation. Primary source is Foundation's
    /// `totalFileAllocatedSize`; fallback is `st_blocks * 512`. For a symlink we always
    /// use `st_blocks`. `logical` = `st_size`. Returns (0,0) if the entry vanished.
    ///
    /// STILL PUBLIC, STILL THE ORACLE (TZ-6). The golden tests recompute every expected
    /// size with THIS function, and the reducer's own-size events must match it. The TZ-6
    /// fast path (`DirectoryReader`) reproduces these numbers without the per-entry
    /// Foundation cost; `measure` is retained for the root/bundle own-entry sizes (rare,
    /// once-per-node paths) and as the golden's independent oracle.
    public static func measure(_ url: URL) -> (allocated: Int64, logical: Int64) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return (0, 0) }
        let logical = Int64(st.st_size)
        let blockBytes = Int64(st.st_blocks) * 512

        if (st.st_mode & S_IFMT) == S_IFLNK {
            return (blockBytes, logical) // symlink: never resolve the target
        }
        if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let a = v.totalFileAllocatedSize {
            return (Int64(a), logical)
        }
        return (blockBytes, logical)
    }

    // MARK: - Descent

    /// Enumerate the root, emit its child STRUCTURE + immediate (non-bundle) sizes up
    /// front so every top-level tile appears at once, THEN fan out one concurrent task
    /// per top-level directory (DFS descent) AND one per top-level `.app` bundle
    /// (sizing). Root structure is emitted BEFORE any bundle sizing begins. Finish with
    /// the root's completion once every worker has drained.
    private static func walkRoot(_ root: URL, policy: ScanPolicy, batcher: EventBatcher) async {
        let rootId = root.path
        // ONE SCAN = ONE DEVICE on the PRIMARY path too (revise finding 2 — invariant 4 is
        // NOT promotion-only). Establish the scan root's device and thread it down the whole
        // descent, so a primary VOLUME-ROOT scan does not double-count firmlinked data dirs
        // (/System/Volumes/Data), /Volumes mounts, or network mounts. A same-device home
        // scan is unaffected — every descendant shares this device, so nothing is excluded.
        var rootStat = stat()
        let rootDev: dev_t? = stat(root.path, &rootStat) == 0 ? rootStat.st_dev : nil
        // TZ-7 review-0 change 1: capture the SCAN ROOT's mtime at scan time. The root has no parent
        // stub to carry its mtime (unlike every descendant dir, sized by `classifyChildren`), so it
        // would project as `nil` and its FIRST Tier-1 revalidation would re-enumerate instead of taking
        // the one-`stat` unchanged fast path. Seed it here from the same `stat` used for the device.
        let rootMtime: Int64? = rootDev != nil ? DirectoryReader.mtimeNanos(rootStat) : nil
        let (a, l) = measure(root)

        guard let classified = classifyChildren(of: root, parentId: rootId, policy: policy,
                                                boundaryDevice: rootDev) else {
            await batcher.add([.sizeUpdated(nodeId: rootId, allocated: a, logical: l),
                               .accessDenied(nodeId: rootId)])
            return
        }
        // ONE batched send for the root directory (revise finding 3: roots included). If the
        // enumeration was truncated, the root's own `accessDenied` rides in the SAME batch so
        // the unread remainder renders "we don't know", never a silent omission (finding 1).
        var batch: [ScanEvent] = [.sizeUpdated(nodeId: rootId, allocated: a, logical: l),
                                  .childrenDiscovered(parentId: rootId, children: classified.stubs)]
        if let m = rootMtime { batch.append(.directoryMtime(nodeId: rootId, mtime: m)) }
        batch.append(contentsOf: classified.sizeEvents)
        if classified.incomplete { batch.append(.accessDenied(nodeId: rootId)) }
        await batcher.add(batch)

        // The root is descent depth 0; its top-level entries are depth 1. Fan them out through
        // the SHARED `SpawnGate` (review-0 change 3): the top level is NO LONGER exempt from the
        // bound. All top-level tiles already appeared up front (the structure batch above), so
        // gating their DESCENT does not delay any tile; for a typical root (≤ maxConcurrentSpawns
        // top-level dirs) every one still gets its own concurrent worker (ratified decision 5),
        // and a pathological high-fanout root stays bounded instead of spawning a task per entry.
        let gate = SpawnGate(max: WalkTuning.maxConcurrentSpawns)
        await fanOut(dirs: classified.dirsToRecurse, bundles: classified.bundlesToSize,
                     parentDepth: 0, policy: policy, batcher: batcher,
                     boundaryDevice: rootDev, gate: gate)
        await batcher.add([.subtreeCompleted(nodeId: rootId)])
    }

    /// The promoted root's single enumeration point (invariant 1): emit the new root's own
    /// size + child STRUCTURE, then fan out one task per NEW top-level directory / bundle.
    /// The grafted child is a stub-only graft reference (`excluding:`); a cross-device child
    /// is a boundary stub (`boundaryDevice:`). The promoted-root device is threaded DOWN the
    /// whole sibling descent, so ONE SCAN = ONE DEVICE holds throughout, not only for direct
    /// children.
    private static func walkNewRoot(_ root: URL, newRootId: String, excluding excluded: String,
                                    policy: ScanPolicy, batcher: EventBatcher) async {
        let (a, l) = measure(root)

        var rootStat = stat()
        let rootDev: dev_t? = stat(root.path, &rootStat) == 0 ? rootStat.st_dev : nil
        // TZ-7 review-0 change 1: seed the PROMOTED root's mtime too (same reasoning as `walkRoot` —
        // the new root has no parent stub, so its focus revalidation needs a scan-time mtime to
        // short-circuit). The grafted child keeps its own (already-captured) mtimes.
        let rootMtime: Int64? = rootDev != nil ? DirectoryReader.mtimeNanos(rootStat) : nil

        guard let classified = classifyChildren(of: root, parentId: newRootId, policy: policy,
                                                boundaryDevice: rootDev, excluding: excluded) else {
            await batcher.add([.sizeUpdated(nodeId: newRootId, allocated: a, logical: l),
                               .accessDenied(nodeId: newRootId)])
            return
        }
        // ONE batched send for the promoted root directory (revise finding 3: roots
        // included); truncation rides its own `accessDenied` in the same batch (finding 1).
        var batch: [ScanEvent] = [.sizeUpdated(nodeId: newRootId, allocated: a, logical: l),
                                  .childrenDiscovered(parentId: newRootId, children: classified.stubs)]
        if let m = rootMtime { batch.append(.directoryMtime(nodeId: newRootId, mtime: m)) }
        batch.append(contentsOf: classified.sizeEvents)
        if classified.incomplete { batch.append(.accessDenied(nodeId: newRootId)) }
        await batcher.add(batch)

        // Same SHARED-gate fan-out as the primary root (review-0 change 3): the promoted root's
        // top-level siblings are bounded by the global `SpawnGate`, not spawned one-task-each.
        let gate = SpawnGate(max: WalkTuning.maxConcurrentSpawns)
        await fanOut(dirs: classified.dirsToRecurse, bundles: classified.bundlesToSize,
                     parentDepth: 0, policy: policy, batcher: batcher,
                     boundaryDevice: rootDev, gate: gate)
        await batcher.add([.subtreeCompleted(nodeId: newRootId)])
    }

    /// Depth-first descent of one subtree. Emits this directory's structure/sizes, then
    /// handles child directories + nested bundle leaves, then marks the subtree complete.
    ///
    /// HIERARCHICAL SPAWNING (TZ-6 PLAN c). At descent depth < `WalkTuning.spawnDepth`,
    /// child directories are DELEGATED to concurrent subtasks (the cooperative pool
    /// work-steals them); at or below that depth, descent is sequential within this task.
    /// Either way each child directory has exactly ONE owner (invariant 2) — it is
    /// delegated OR recursed, never both. Nested-bundle sizing is sequential within this
    /// task (it only delays THIS subtree, never other tiles).
    ///
    /// `boundaryDevice` is the scan root's `st_dev`, threaded DOWN the whole descent on BOTH
    /// the primary (`walkRoot`, OPERATOR_NOTE finding 2) and promotion (`walkNewRoot`) paths;
    /// `classifyChildren` uses it to enforce ONE SCAN = ONE DEVICE (invariant 4). It is `nil`
    /// only if the root `stat` itself failed (then the device rule cannot be applied).
    private static func walkDirectory(_ path: String, id: String,
                                      policy: ScanPolicy, batcher: EventBatcher,
                                      boundaryDevice: dev_t?, depth: Int, gate: SpawnGate) async {
        if Task.isCancelled { return }

        guard let classified = classifyChildren(of: URL(fileURLWithPath: path, isDirectory: true),
                                                parentId: id, policy: policy,
                                                boundaryDevice: boundaryDevice) else {
            await batcher.add([.accessDenied(nodeId: id)])
            return
        }
        // ONE batched send per directory (revise finding 3): structure + own-entry sizes,
        // plus — if the getattrlistbulk enumeration truncated — this directory's own
        // `accessDenied` in the SAME batch, so the unread remainder is a "we don't know"
        // tile, never a silently-short total (revise finding 1).
        var batch: [ScanEvent] = [.childrenDiscovered(parentId: id, children: classified.stubs)]
        batch.append(contentsOf: classified.sizeEvents)
        if classified.incomplete { batch.append(.accessDenied(nodeId: id)) }
        await batcher.add(batch)

        // HIERARCHICAL SPAWNING under a REAL, GLOBAL bound (revise finding 4, made global by
        // review-0 change 3) — the SAME gated fan-out the roots use (`fanOut`), no level exempt.
        await fanOut(dirs: classified.dirsToRecurse, bundles: classified.bundlesToSize,
                     parentDepth: depth, policy: policy, batcher: batcher,
                     boundaryDevice: boundaryDevice, gate: gate)
        await batcher.add([.subtreeCompleted(nodeId: id)])
    }

    /// The ONE gated delegate-or-inline fan-out, shared by `walkRoot`, `walkNewRoot`, and
    /// `walkDirectory` (revise finding 4, made global by review-0 change 3). A parent at
    /// `parentDepth` handles its child
    /// directories + nested bundle leaves: within the top `WalkTuning.spawnDepth` levels a
    /// child is DELEGATED to a concurrent subtask ONLY if a `SpawnGate` permit is free;
    /// otherwise (or below the spawn depth) it is walked/sized INLINE within the calling task.
    /// Delegated or inline, each child has EXACTLY ONE owner (invariant 2). Inline work never
    /// awaits a permit, so the cooperative pool cannot deadlock on the gate.
    ///
    /// THE BOUND (review-0 change 3 — "a real bound, including root fanout"). Because the roots
    /// call this with `parentDepth: 0` and share ONE `SpawnGate` with the whole descent, the
    /// only concurrent tasks that ever exist are the delegated subtasks — at most
    /// `WalkTuning.maxConcurrentSpawns` OUTSTANDING — plus the single owning walk task that
    /// spawned them. Total concurrent walker tasks ≤ `maxConcurrentSpawns + 1`, INDEPENDENT of
    /// the scan root's fanout or the tree's size. The prior top-level `group.addTask`-per-entry
    /// fan-out (one task per top-level dir, ungated) is exactly what escaped the bound; routing
    /// it here closes that gap.
    ///
    /// Abstraction ledger — fanOut: concrete users = `walkRoot`, `walkNewRoot`, `walkDirectory`
    /// (three); axis = the shared gated delegate-or-inline fan-out; rejected simpler alternative
    /// = three inline copies (the shipped state, where the two root copies omitted the gate and
    /// broke the global bound the packet requires).
    private static func fanOut(dirs: [(path: String, id: String)],
                               bundles: [(path: String, id: String)],
                               parentDepth: Int, policy: ScanPolicy, batcher: EventBatcher,
                               boundaryDevice: dev_t?, gate: SpawnGate) async {
        await withTaskGroup(of: Void.self) { group in
            for (childPath, childId) in dirs {
                if Task.isCancelled { break }
                if parentDepth < WalkTuning.spawnDepth, gate.tryAcquire() {
                    group.addTask {
                        defer { gate.release() }
                        await walkDirectory(childPath, id: childId, policy: policy, batcher: batcher,
                                            boundaryDevice: boundaryDevice, depth: parentDepth + 1, gate: gate)
                    }
                } else {
                    await walkDirectory(childPath, id: childId, policy: policy, batcher: batcher,
                                        boundaryDevice: boundaryDevice, depth: parentDepth + 1, gate: gate)
                }
            }
            for (bundlePath, bundleId) in bundles {
                if Task.isCancelled { break }
                if parentDepth < WalkTuning.spawnDepth, gate.tryAcquire() {
                    group.addTask {
                        defer { gate.release() }
                        await sizeBundle(bundlePath, id: bundleId, batcher: batcher,
                                         boundaryDevice: boundaryDevice)
                    }
                } else {
                    await sizeBundle(bundlePath, id: bundleId, batcher: batcher,
                                     boundaryDevice: boundaryDevice)
                }
            }
        }
    }

    /// Size one opaque `.app` bundle and emit its SINGLE result. A fully-readable bundle →
    /// one `sizeUpdated` (recursive total) + completion. A bundle with an unreadable
    /// directory inside cannot be honestly sized, so — exactly like any un-enterable
    /// directory — it is sized by its OWN entry and marked `accessDenied` (a "we don't
    /// know" tile, never a silently-truncated total). `bundleTotal` returns `nil` on
    /// cancellation, in which case nothing is emitted.
    private static func sizeBundle(_ path: String, id: String, batcher: EventBatcher,
                                   boundaryDevice: dev_t?) async {
        guard let (ba, bl, fullyRead) = bundleTotal(path, boundaryDevice: boundaryDevice) else { return }
        if fullyRead {
            await batcher.add([.sizeUpdated(nodeId: id, allocated: ba, logical: bl),
                               .subtreeCompleted(nodeId: id)])
        } else {
            let (ownA, ownL) = measure(URL(fileURLWithPath: path, isDirectory: true))
            await batcher.add([.sizeUpdated(nodeId: id, allocated: ownA, logical: ownL),
                               .accessDenied(nodeId: id)])
        }
    }

    // MARK: - Classification

    /// The classified result of enumerating one directory (test seam — see the
    /// `classifyChildren` doc and RootPromotionWalkTests).
    struct Classified {
        /// TRUE iff the underlying `getattrlistbulk` enumeration was TRUNCATED mid-directory
        /// (a `ReadResult.partial`): the stubs/sizes below are HONEST but INCOMPLETE, so the
        /// caller must ALSO mark this directory `accessDenied` — the unread remainder is a
        /// "we don't know" tile, never a silent omission (revise finding 1). A fully-read
        /// directory (`ReadResult.complete`) leaves this `false`.
        var incomplete = false
        var stubs: [ChildStub] = []
        /// Immediate own-entry sizes for everything sized during classification: files,
        /// symlinks, directories' own entries, and boundary-stub completions. Bundle
        /// leaves are NOT here — they are sized asynchronously (see `bundlesToSize`).
        var sizeEvents: [ScanEvent] = []
        /// Child directories to descend into, as (FS path, node id). The FS path is
        /// derived from the enumerated directory's real path; the id from `parentId`
        /// (they coincide in production and diverge only under a synthetic test parentId).
        var dirsToRecurse: [(path: String, id: String)] = []
        /// Opaque `.app` bundle leaves whose recursive total the caller measures via
        /// `sizeBundle`, as (FS path, node id).
        var bundlesToSize: [(path: String, id: String)] = []
    }

    /// Enumerate `dir`'s immediate children (via `DirectoryReader` — getattrlistbulk, no
    /// Foundation URL per entry) and classify each into a stub plus the work it needs.
    /// Returns `nil` iff the directory could not be enumerated (caller emits
    /// `accessDenied`). Performs NO bundle sizing itself.
    ///
    /// Children are sorted by name so a single worker's emission order is deterministic;
    /// the reducer re-sorts by name regardless, so this only aids stream reproducibility.
    ///
    /// `excluding` (non-nil only in the promotion walk): the already-scanned child id — a
    /// GRAFT REFERENCE. Its stub links the new root to the preserved subtree; it is
    /// emitted with NO size event and kept OUT of the recurse set, so it is never re-sized
    /// or re-entered (invariant 5).
    ///
    /// `boundaryDevice` (the scan root's `st_dev`, supplied on BOTH the primary and promotion
    /// descents; nil only when the root stat failed) enforces ONE SCAN = ONE DEVICE: a child
    /// directory whose device differs is a BOUNDARY STUB — shown, sized by its own entry,
    /// marked `subtreeCompleted`, and kept OUT of the recurse set (invariant 4). Internal so a
    /// test can drive both decisions.
    static func classifyChildren(of dir: URL, parentId: String,
                                 policy: ScanPolicy,
                                 boundaryDevice: dev_t? = nil,
                                 excluding: String? = nil) -> Classified? {
        let dirPath = dir.path
        // Three honest outcomes (see `DirectoryReader.ReadResult`): unreadable → nil (caller
        // emits accessDenied, no children); complete → classify all; partial → classify what
        // was read AND flag `incomplete` so the caller denies the unread remainder (finding 1).
        let children: [DirectoryReader.Child]
        var out = Classified()
        switch DirectoryReader.read(dirPath) {
        case .unreadable: return nil
        case .complete(let c): children = c
        case .partial(let c): children = c; out.incomplete = true
        }

        for child in children.sorted(by: { $0.name < $1.name }) {
            let name = child.name
            // Child id = parentId joined with the name (invariant: one identity prefix for
            // the whole tree). The child's FS path is the REAL enumerated dir's path + name
            // (used for descent I/O); id and path coincide in production and diverge only
            // under a synthetic test `parentId`.
            let cid = Self.joinId(parentId, name)
            let childPath = dirPath.hasSuffix("/") ? dirPath + name : dirPath + "/" + name

            // GRAFT REFERENCE (invariant 5): the already-scanned child — a stub only. It carries NO
            // mtime (like it carries no size): the graft preserves the existing subtree's reducer
            // state EXACTLY ("nothing re-counted"), and a mtime write is state the grafted node did
            // not have. A later revalidation of that child establishes its mtime via directoryMtime.
            if let excluding, cid == excluding {
                out.stubs.append(ChildStub(id: cid, name: name, kind: .dir, isHidden: child.isHidden))
                continue
            }

            switch child.kind {
            case .symlink:
                // Never followed: a leaf sized by the link itself.
                out.stubs.append(ChildStub(id: cid, name: name, kind: .file, isHidden: child.isHidden))
                out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))

            case .dir:
                if let boundaryDevice, child.device != boundaryDevice {
                    // One device (invariant 4): a cross-device dir is a boundary stub —
                    // shown + sized + completed, but NEVER entered.
                    out.stubs.append(ChildStub(id: cid, name: name, kind: .dir, isHidden: child.isHidden, mtime: child.mtime))
                    out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))
                    out.sizeEvents.append(.subtreeCompleted(nodeId: cid))
                } else if policy.isBundleLeaf(name: name) {
                    // Opaque leaf. Its stub appears NOW (rendered pending); its recursive
                    // sizing is DEFERRED to `sizeBundle`. No size event here — the bundle
                    // carries exactly one, delivered later.
                    out.stubs.append(ChildStub(id: cid, name: name, kind: .bundleLeaf, isHidden: child.isHidden, mtime: child.mtime))
                    out.bundlesToSize.append((childPath, cid))
                } else {
                    out.stubs.append(ChildStub(id: cid, name: name, kind: .dir, isHidden: child.isHidden, mtime: child.mtime))
                    out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))
                    out.dirsToRecurse.append((childPath, cid))
                }

            case .file:
                out.stubs.append(ChildStub(id: cid, name: name, kind: .file, isHidden: child.isHidden))
                out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))
            }
        }
        return out
    }

    /// Recursively sum a bundle-leaf's OWN size + all descendants' sizes, WITHOUT emitting
    /// any child events (the bundle is one opaque tile). Symlinks inside are still not
    /// followed. Enumerates via `DirectoryReader` (getattrlistbulk), the same primitive the
    /// ordinary descent uses.
    ///
    /// `fullyRead` is `false` if ANY directory inside the bundle could not be enumerated
    /// (EPERM/EACCES) — the caller then marks the bundle `denied` (a "we don't know" tile,
    /// not a wrong number). Propagates up via `&&`.
    ///
    /// CANCELLATION: a bundle can be arbitrarily deep, so this checks `Task.isCancelled` at
    /// each directory and before each entry, returning `nil` the moment the scan is torn
    /// down. `nil` (stop, emit nothing) is distinct from `fullyRead == false` (denied,
    /// emit the honest we-don't-know tile).
    private static func bundleTotal(_ path: String, boundaryDevice: dev_t?)
        -> (allocated: Int64, logical: Int64, fullyRead: Bool)? {
        if Task.isCancelled { return nil }
        // The bundle's OWN entry is sized by `measure` (once per bundle — matches the
        // golden's independent recompute exactly, which also uses `measure` for own+entries).
        let (selfA, selfL) = measure(URL(fileURLWithPath: path, isDirectory: true))
        var totalA = selfA, totalL = selfL
        // A bundle sized from a TRUNCATED enumeration is not fully known — treat partial
        // exactly like an un-enumerable dir: sum what was read but report `fullyRead=false`
        // so the caller marks the bundle denied (a "we don't know" tile), never a short
        // total (revise finding 1). Propagates up via the `&&` below.
        let children: [DirectoryReader.Child]
        var fullyRead = true
        switch DirectoryReader.read(path) {
        case .unreadable: return (totalA, totalL, false) // this directory itself is denied
        case .complete(let c): children = c
        case .partial(let c): children = c; fullyRead = false
        }
        for child in children {
            if Task.isCancelled { return nil }
            switch child.kind {
            case .symlink:
                totalA += child.allocated; totalL += child.logical
            case .dir:
                // One device (invariant 4): a cross-device dir inside a bundle belongs to
                // another volume — never summed, never entered.
                if let boundaryDevice, child.device != boundaryDevice { continue }
                let childPath = path.hasSuffix("/") ? path + child.name : path + "/" + child.name
                guard let (a, l, sub) = bundleTotal(childPath, boundaryDevice: boundaryDevice) else { return nil }
                totalA += a; totalL += l
                fullyRead = fullyRead && sub
            case .file:
                totalA += child.allocated; totalL += child.logical
            }
        }
        return (totalA, totalL, fullyRead)
    }
}
