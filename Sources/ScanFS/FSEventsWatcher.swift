//
//  FSEventsWatcher.swift — the TZ-7 Tier-2 kernel change stream + storm coalescer.
//  Module maturity: PROTOTYPE (slice TZ-7 — the living map)
//
//  THE REAL MECHANISM (PLAN §TZ-7 Tier 2). An `FSEventStream` on the scan root delivers
//  kernel-COALESCED, per-directory change notifications: when anything under a watched
//  directory changes, the kernel eventually hands us that directory's path (batched within a
//  `latencySeconds` window). Each flagged directory then gets the SAME re-enumerate-and-diff
//  treatment as Tier-1 (the App wires `onDirs` to its revalidation routine) — so the map updates
//  live, no rescan (VISION §"the living map").
//
//  STORM SAFETY (packet deliverable 3). A mass delete floods FSEvents. Three bounds keep it safe,
//  all named constants:
//    - COALESCE + DEDUP: flagged directory ids fold into a `Set` (`FSEventCoalescer`), so the same
//      directory touched N times in a storm is re-enumerated ONCE.
//    - ONE SCHEDULED DRAIN PER WINDOW (review-2 change 1): a callback does NOT drain inline — it only
//      ADDS its flagged ids to the coalescer and, iff no drain is already pending, schedules ONE drain
//      `coalesceDrainSeconds` later. So many small callbacks in a burst fold into a SINGLE deduplicated
//      delivery, not one `onDirs` (and one App revalidation task) per callback. Without this the
//      per-drain cap below applied PER CALLBACK, not per coalescing window — the reviewer's gap.
//    - CAP PER DRAIN + CARRY OVERFLOW: at most `maxDirsPerDrain` directories are handed to the App
//      per drain; the remainder stays pending and the drain RE-schedules itself one window later. So a
//      100k-file delete never spikes into 100k concurrent re-enumerations, and never into one
//      unbounded delivery either.
//
//  ONE DEVICE / IN SCOPE (deliverable 4). An event path is mapped onto our node-id scheme only if
//  it is the scan root or lives UNDER it (our ids ARE `rootPath`-prefixed, `FileSystemWalker.joinId`)
//  AND is on the scan root's device; a firmlink alias, a path outside the root, or a cross-device
//  mount is DROPPED (the one-device rule — never fabricate a node id the reducer would not recognize).
//
//  ALL BACKGROUND (main-thread law untouched). The stream runs on a private serial dispatch queue;
//  the callback, coalescer, and drain all execute there. `onDirs` is invoked on that queue; the App's
//  closure hops to its own async revalidation. Nothing here touches the main actor.
//

import Foundation
import CoreServices
import Darwin
#if canImport(ScanCore)
import ScanCore
#endif

/// Named Tier-2 bounds (one home for the storm-safety knobs).
public enum FSEventTuning {
    /// The KERNEL coalescing window (seconds), passed to `FSEventStreamCreate`. A larger value batches
    /// more per callback (fewer, larger drains); 1 s matches the ratified relayout cadence, so live
    /// updates land on roughly the same beat as streamed scan data.
    public static let latencySeconds: CFTimeInterval = 1.0
    /// OUR second-stage coalescing window (seconds) — distinct from `latencySeconds` (the kernel's).
    /// A callback only ACCUMULATES flagged ids; the first accumulation of an idle window schedules ONE
    /// drain this long later, so a burst of callbacks collapses to a single deduplicated delivery
    /// (review-2 change 1). Equal to `latencySeconds`, so worst-case ordinary detection latency is the
    /// kernel window + this ≈ 2 s — the ratified Tier-2 bound.
    public static let coalesceDrainSeconds: CFTimeInterval = 1.0
    /// Hard cap on directories re-enumerated per drain (storm bound). Overflow carries to the next
    /// drain. 64 keeps a burst responsive without letting a mass delete fan out unboundedly.
    public static let maxDirsPerDrain = 64
}

/// PURE classification of one FSEvents per-event flag word into the action the living map must take
/// (review-1 change 4). Dry-testable (no live stream): feed a flag word, assert the action — so the
/// loss-recovery policy is pinned WITHOUT forcing a real kernel event drop (unforceable from
/// userspace). The callback consults it per event.
///
/// ABSTRACTION LEDGER — FSEventFlagPolicy: concrete users = `FSEventsWatcher.callback` (production) +
/// `LivingMapWalkTests` (the dry policy test). Axis: none (a fixed flag→action mapping). Rejected
/// simpler alternative: inline the bit tests in the callback — then the loss policy could not be
/// unit-tested at all (a real kernel drop cannot be forced), which review-1 change 4 requires.
public enum FSEventAction: Equatable {
    /// Ordinary per-directory change → one-level re-enumerate-and-diff (the common path).
    case reconcile
    /// `kFSEventStreamEventFlagMustScanSubDirs`: the kernel COALESCED/DROPPED events for this
    /// subtree, so a one-level re-list cannot recover deep changes — the WHOLE retained subtree must
    /// be re-validated (the honest recovery, never a silent claim that a one-level check sufficed).
    case rescanSubtree
}

public enum FSEventFlagPolicy {
    /// The action for one event's flag word: a subtree rescan when the kernel says it must scan
    /// sub-directories (its own queue coalesced events away), else an ordinary reconcile.
    public static func action(for flags: FSEventStreamEventFlags) -> FSEventAction {
        (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0
            ? .rescanSubtree : .reconcile
    }
    /// Whether the kernel dropped events wholesale (user- or kernel-space queue overflow) — a
    /// completeness loss that ALSO forces a subtree rescan and DEGRADES the live capability until the
    /// recovery catches up. Distinguished so the status can state the degradation (deliverable 5:
    /// never keep silently claiming full "Live" after events were lost).
    public static func isHistoryDropped(_ flags: FSEventStreamEventFlags) -> Bool {
        (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                                         | kFSEventStreamEventFlagKernelDropped)) != 0
    }
}

/// PURE coalescing state (dry-tested in FixtureFS): a dedup set of directory ids drained in
/// bounded, carried batches. No I/O, no concurrency — the owner confines it to one serial context.
/// It carries an optional SCHEDULED-DRAIN flag so a burst of adds arms exactly ONE drain (the
/// cadence-coalescing the FSEvents watcher needs); a consumer that drives its own drain loop (the
/// App's loss-recovery) simply ignores the flag and uses the plain `add`/`drain`/`isEmpty` core.
///
/// ABSTRACTION LEDGER — FSEventCoalescer: concrete users (now TWO, so the abstraction is earned by
/// real reuse, not imagined variation) = (1) `FSEventsWatcher` — the Tier-2 storm bound, using the
/// scheduled-drain flag to coalesce callbacks into one delivery per window; (2) `ScanController`'s
/// FSEvents-loss recovery — the same dedup-set + capped-drain + carry policy for the retained
/// directories a `MustScanSubDirs`/dropped-queue loss must re-validate (review-2 change 2), draining
/// across bounded passes until empty. Plus the dry tests in `LivingMapWalkTests`. Axis: none (a fixed
/// policy). Rejected simpler alternative: inline the set/cap/flag in each caller — then neither the
/// storm bound nor the recovery completeness could be unit-tested without a real FSEvents flood /
/// running App, which the packet requires as DRY tests, and the identical policy would be duplicated.
public struct FSEventCoalescer: Equatable {
    private var pending: Set<String> = []
    /// Whether a drain is already scheduled for the current window (the scheduled-drain state, review-2
    /// change 1). Managed only by `addAndClaimSchedule`/`finishDrain`; inert for the plain-`drain`
    /// recovery consumer, which loops on `isEmpty` instead.
    private var drainScheduled = false
    public init() {}
    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }
    /// Fold flagged directory ids in (dedup by set). The plain primitive — recovery uses this and
    /// drives its own bounded drain loop off `isEmpty`.
    public mutating func add<S: Sequence>(_ ids: S) where S.Element == String { pending.formUnion(ids) }
    /// Take up to `max` ids to process now; the rest STAY pending for the next drain (the cap that
    /// makes a mass-delete storm safe). Order is unspecified (a set) — every id is drained eventually.
    public mutating func drain(max: Int) -> [String] {
        guard max > 0, !pending.isEmpty else { return [] }
        let take = Array(pending.prefix(max))
        pending.subtract(take)
        return take
    }
    /// Fold ids in AND report whether the caller must SCHEDULE a drain now — `true` ONLY for the first
    /// add while no drain is pending, so N callbacks within one window arm exactly ONE drain, not one
    /// per callback (review-2 change 1: coalesce at a cadence). Pair each scheduled drain's `drain(max:)`
    /// with `finishDrain()`.
    public mutating func addAndClaimSchedule<S: Sequence>(_ ids: S) -> Bool where S.Element == String {
        pending.formUnion(ids)
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }
    /// Close out a scheduled drain (call AFTER its `drain(max:)`) and report whether ANOTHER drain must
    /// be scheduled: `true` iff overflow carried past the cap (the flag stays set so the cadence
    /// continues), `false` once the set is empty (the flag clears, so the next add re-arms a fresh
    /// window). This is what keeps the per-drain cap a PER-WINDOW bound with carry, not a per-callback one.
    public mutating func finishDrain() -> Bool {
        if pending.isEmpty { drainScheduled = false; return false }
        return true // overflow carries → stay scheduled
    }
}

/// The scan root's FSEvents stream. `init?` returns `nil` when the stream cannot be created or
/// started — the caller then runs Tier-1 only and SAYS SO in the status tooltip (degraded silently is
/// forbidden, deliverable 5). `@unchecked Sendable`: every mutable field is confined to `queue`
/// (`init` fully constructs the stream before returning; `stop()` synchronizes on `queue`).
public final class FSEventsWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "software.bijuterie.terrazzo.fsevents")
    /// The scan root as the REDUCER knows it (the node-id prefix) — event paths are mapped back onto
    /// this so a flagged directory's id matches the tree (`FileSystemWalker.joinId`).
    private let rootPath: String
    /// The scan root RESOLVED (`realpath`) — the form FSEvents actually delivers. A firmlink temp
    /// dir (`/var/folders/…`) or the data-volume alias resolves here so the delivered path (which is
    /// canonical) is recognized as in-scope; we then re-express it under `rootPath` (deliverable 4:
    /// map onto our node ids). `rootPath` when resolution fails.
    private let canonicalRoot: String
    private let rootDevice: dev_t?
    /// Invoked ON `queue` with a batch (≤ `maxDirsPerDrain`) of IN-SCOPE node ids to revalidate
    /// (ordinary per-directory changes).
    private let onDirs: @Sendable ([String]) -> Void
    /// Invoked ON `queue` with IN-SCOPE node ids whose SUBTREE must be re-validated after a kernel
    /// event loss (`MustScanSubDirs` / dropped queue — review-1 change 4). The caller expands each to
    /// its retained descendants and re-validates them, and states the degraded capability in the
    /// status meanwhile. Defaulted no-op so pre-change call sites (live_host tier2) compile unchanged.
    private let onRescan: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private var coalescer = FSEventCoalescer()

    public init?(rootPath: String,
                 onDirs: @escaping @Sendable ([String]) -> Void,
                 onRescan: @escaping @Sendable ([String]) -> Void = { _ in }) {
        self.rootPath = rootPath
        self.canonicalRoot = Self.realpath(rootPath) ?? rootPath
        self.onDirs = onDirs
        self.onRescan = onRescan
        var rootStat = stat()
        self.rootDevice = stat(rootPath, &rootStat) == 0 ? rootStat.st_dev : nil

        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        // UseCFTypes → the callback's `eventPaths` is a CFArray of CFStrings (clean NSArray bridge);
        // NoDefer → the first event in an idle→busy transition fires promptly, not after a full window.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, Self.callback, &ctx, [rootPath] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          FSEventTuning.latencySeconds, flags) else {
            return nil // stream could not be created → caller degrades to Tier-1 (states it)
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            return nil // could not start → degrade to Tier-1
        }
        stream = s
    }

    /// Stop and tear down the stream (scan teardown / rescan / promotion — the root changed).
    /// Synchronous on `queue` so no in-flight callback races the release. Idempotent.
    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    // MARK: - Callback (on `queue`)

    /// C trampoline: recover `self`, map each event path onto our id scheme (in-scope + one-device),
    /// CLASSIFY it by flags (`FSEventFlagPolicy`), then coalesce+drain ordinary changes and route
    /// loss/overflow paths to the subtree-recovery channel (review-1 change 4). Captures nothing (uses
    /// `info`), so it converts to a C function pointer.
    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self)
        var reconcileIds: [String] = []
        reconcileIds.reserveCapacity(numEvents)
        var rescanIds: Set<String> = [] // dedup: a burst can flag one subtree root many times
        for i in 0..<numEvents {
            guard let p = paths[i] as? String, let id = watcher.mapToNodeId(p) else { continue }
            let flags = eventFlags[i]
            if FSEventFlagPolicy.action(for: flags) == .rescanSubtree || FSEventFlagPolicy.isHistoryDropped(flags) {
                rescanIds.insert(id) // kernel lost events for this subtree → recover the whole retained subtree
            } else {
                reconcileIds.append(id)
            }
        }
        watcher.enqueue(reconcileIds)
        if !rescanIds.isEmpty { watcher.onRescan(Array(rescanIds)) }
    }

    /// `realpath(3)` — resolves symlinks/firmlinks to the canonical path FSEvents delivers. `nil` if
    /// the path no longer exists (a deleted leaf) — but FSEvents flags the surviving PARENT directory,
    /// whose realpath succeeds, so revalidation still fires.
    private static func realpath(_ path: String) -> String? {
        guard let c = Darwin.realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// Map an FSEvents path onto our node-id scheme, or `nil` to DROP it (deliverable 4 + review-1
    /// change 2). A thin instance wrapper over the pure `Self.resolve` so the mapping is testable
    /// without a live stream (see `resolveForTesting`).
    private func mapToNodeId(_ path: String) -> String? {
        Self.resolve(path: path, canonicalRoot: canonicalRoot, rootPath: rootPath, rootDevice: rootDevice)
    }

    /// The PURE path→node-id resolution (deliverable 4 + review-1 change 2). The delivered path is
    /// CANONICAL (firmlink-resolved). Resolve to the nearest EXISTING, in-scope, on-device ancestor
    /// (the path itself first, then upward):
    ///   • a live directory maps to its own id (the common case);
    ///   • a DELETED flagged directory (its own `stat` fails) maps to its nearest SURVIVING parent —
    ///     whose re-enumeration `childRemoved`s the vanished child. Without this the deleted-directory
    ///     event was dropped and the ghost tile never retired (review-1 change 2: "map such events to
    ///     a surviving, in-scope parent AFTER validating that parent's device").
    /// The one-device rule is enforced on the SURVIVING ancestor (a deleted path has no device to
    /// check); a path genuinely outside the root, or on another device, is dropped. Static + pure
    /// (its only effects are `realpath`/`stat` reads) so a test can drive it against a real temp tree.
    static func resolve(path: String, canonicalRoot: String, rootPath: String, rootDevice: dev_t?) -> String? {
        func inScope(_ cp: String) -> Bool {
            cp == canonicalRoot || cp.hasPrefix(canonicalRoot == "/" ? "/" : canonicalRoot + "/")
        }
        // Re-express an in-scope canonical path under the reducer's id prefix (`rootPath`): drop the
        // canonical-root prefix, graft `rootPath` — a firmlink alias of the scan root maps correctly.
        func reexpress(_ cp: String) -> String {
            cp == canonicalRoot ? rootPath : rootPath + String(cp.dropFirst(canonicalRoot.count))
        }
        let cp = Self.realpath(path) ?? path // deleted → realpath fails; the delivered path is already canonical
        guard inScope(cp) else { return nil }
        var cur = cp
        while inScope(cur) {
            var st = stat()
            if stat(cur, &st) == 0 {
                if let rootDevice, st.st_dev != rootDevice { return nil } // cross-device → drop
                return reexpress(cur)
            }
            // `cur` no longer exists (deleted) — climb to its parent and re-check.
            if cur == canonicalRoot { return reexpress(cur) } // even the root's stat failed — map it; the App handles it
            guard let slash = cur.lastIndex(of: "/"), slash != cur.startIndex else { return nil }
            cur = String(cur[cur.startIndex..<slash])
        }
        return nil
    }

    #if DEBUG
    /// TEST-ONLY (review-1 change 2): drive the pure path→node-id resolution against a real temp tree,
    /// proving a DELETED flagged directory resolves to its nearest SURVIVING, on-device parent (not
    /// dropped) — WITHOUT standing up a real FSEvents stream (a kernel deleted-directory event cannot
    /// be forced deterministically). Concrete user: `LivingMapWalkTests`. Compiled out of release.
    static func resolveForTesting(path: String, canonicalRoot: String, rootPath: String, rootDevice: dev_t?) -> String? {
        resolve(path: path, canonicalRoot: canonicalRoot, rootPath: rootPath, rootDevice: rootDevice)
    }
    #endif

    /// On `queue`: ACCUMULATE flagged ids and, iff no drain is already pending for this window, schedule
    /// ONE drain `coalesceDrainSeconds` later (review-2 change 1). A callback NEVER drains inline, so a
    /// burst of callbacks folds into a single deduplicated delivery instead of one `onDirs` per callback.
    private func enqueue(_ ids: [String]) {
        if coalescer.addAndClaimSchedule(ids) { scheduleDrain() }
    }

    /// Schedule the single pending drain one coalescing window out (always on `queue`).
    private func scheduleDrain() {
        queue.asyncAfter(deadline: .now() + FSEventTuning.coalesceDrainSeconds) { [weak self] in
            self?.drainScheduledBatch()
        }
    }

    /// On `queue`: hand at most `maxDirsPerDrain` coalesced ids to the App, then RE-schedule the next
    /// drain ONLY if a storm left overflow (`finishDrain`). So re-enumeration never exceeds the cap per
    /// drain, and the window's many adds became exactly this one capped delivery.
    private func drainScheduledBatch() {
        let batch = coalescer.drain(max: FSEventTuning.maxDirsPerDrain)
        if !batch.isEmpty { onDirs(batch) }
        if coalescer.finishDrain() { scheduleDrain() }
    }
}
