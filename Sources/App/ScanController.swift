//
//  ScanController.swift — the App's scan/render coordinator (main-actor side).
//  Module maturity: PROTOTYPE (slice TZ-3b — the threading model)
//
//  REWRITTEN IN TZ-3b to enforce the ratified threading law (PLAN §"Threading
//  model"): "nothing on the main thread may scale with node count." Before, this
//  controller folded the walker stream AND projected the tree ON THE MAIN ACTOR,
//  and NavigationController squarified ON THE MAIN ACTOR — at home-scan scale the
//  main thread stalled for seconds (the field-reported beachball).
//
//  NOW it owns a background `ScenePipeline` actor and does only glue:
//    - probe the volume once (a one-time syscall, not node-count work);
//    - construct the pipeline and FEED it the real walker's event stream (the fold
//      runs on the actor, in its own Task — never on main);
//    - CONSUME finished `RenderScene` values on the main actor and hand them up.
//      This is the only main-side scan work and it is O(scene): the tiles are
//      already positioned and the labels already composed by the pipeline;
//    - drive the batched cadence with a lightweight main Timer that only TRIGGERS
//      the pipeline's `tick()` (the O(n) makeTree→squarify it triggers runs on the
//      actor);
//    - forward focus/viewport changes to the pipeline (dive/ascend/resize);
//    - run the debug HitchMonitor so the law is measurable, not merely asserted.
//
//  WHAT CROSSES THE ACTOR→MAIN BOUNDARY: exactly one type, `RenderScene` (a raw
//  value DTO — positioned tiles carrying their own display metadata + prebuilt GPU
//  quads + composed labels + the below-pixel cull count + the projected SizeTree for
//  the O(1) scanned total + running flag), delivered via one `AsyncStream`.
//
//  This is App-layer glue (the Main assembly wires the two engines), instantiated
//  by AppDelegate. Not a core abstraction — one concrete coordinator, one caller.
//

import AppKit
// Monolith-only App layer: RenderScene / ScenePipeline / SizeTree / ScanPolicy /
// VolumeProbe / FileSystemWalker / Rect resolve same-module (no core imports).

@MainActor
final class ScanController {
    /// The volume/directory currently being scanned. Mutable in TZ-4: the VolumePicker
    /// and the Rescan button re-run the scan for a (possibly different) root.
    private(set) var root: URL
    private let policy: ScanPolicy
    /// One value handoff up to NavigationController (positioned tiles + labels).
    private let onScene: (RenderScene) -> Void
    private let onStatus: (ScanStatus) -> Void

    private var pipeline: ScenePipeline?
    private var volume: VolumeProbe.VolumeInfo?
    /// Volume used-inode count at scan start (`f_files − f_ffree`) — the file-count
    /// progress-bar denominator (TZ-4). Read ONCE per scan by ScanFS; 0 if unavailable.
    private var totalInodes: Int64 = 0
    /// Whether the current scan root IS a selectable volume's root, read once per
    /// scan/promotion via the SAME tested judgment the FDA banner uses
    /// (`VolumeSkipPolicy.isVolumeRoot`, AppDelegate) — one notion of "volume root" in the
    /// app, not two. Gates the percentage/ETA honesty rule (OPERATOR_NOTE #2 item 2): a
    /// subtree scan shows files/sec + a count, never a fraction against the volume-wide
    /// inode denominator. Promotion moves the root toward the volume root, so this flips to
    /// `true` once a promotion reaches it.
    private var isVolumeRoot = false
    /// The active walker fold tasks. Usually one (the primary scan); root promotion
    /// appends a second — the sibling-exclusion walk of the promoted parent — which
    /// folds into the SAME pipeline concurrently with the primary walk that may still be
    /// draining the grafted subtree. All are cancelled together on teardown.
    private var walkTasks: [Task<Void, Never>] = []
    /// The anticipatory volume-root warm (TZ-6 PLAN deliverable 5), started for a SUBTREE
    /// scan so a later zoom-out promotion finds siblings warm. `.utility` priority, emits
    /// nothing, excludes the active scan root — see `FileSystemWalker.anticipateVolumeRoot`.
    /// Cancelled on teardown and superseded when a promotion begins.
    private var anticipateTask: Task<Void, Never>?
    private var sceneTask: Task<Void, Never>?
    private var cadenceTimer: Timer?
    private let hitch = HitchMonitor()
    private var running = false

    // MARK: - TZ-7 live-map state (the living map: revalidation + FSEvents)
    //
    /// The directory the user is focused on — the Tier-1 revalidation target. Tracked from
    /// `setFocus`; a change re-arms `pendingFocusRevalidation` so the new focus gets a fresh look
    /// once its scene (carrying its retained mtime) arrives.
    private var currentFocusId: String?
    /// The focus directory's mtime as the retained tree knows it (read off each focus scene's
    /// projection root — O(1) on main). The Tier-1 fast path: a fresh `stat` equal to this means the
    /// listing is current and revalidation stops after one syscall. `nil` ⇒ unknown (re-enumerate).
    private var knownFocusMtime: Int64?
    /// Set when the focus changed; consumed when the new focus's scene arrives to trigger one
    /// mtime-compared revalidation of it (catches deletions since scan without re-enumerating on
    /// every idle tick).
    private var pendingFocusRevalidation = false
    /// The Tier-2 kernel change stream on the scan root. `nil` when creation failed (degraded to
    /// Tier-1 — SAID SO in the status tooltip, never silent). Rebuilt on rescan/volume-switch/promote.
    private var fsWatcher: FSEventsWatcher?
    /// LIVE-UPDATE DELIVERY THROUGH THE EXISTING EventBatcher (OPERATOR_NOTE 2026-08-17 #1). ALL live
    /// updates — Tier-1 focus pokes, Tier-2 FSEvents drains, and loss recovery — flow through ONE
    /// `EventBatcher` (`liveBatcher`), the SAME batched-delivery funnel scan data uses. Each revalidation
    /// COMPUTES its diff atomically against retained state (`ScenePipeline.computeLiveDiff`, the reviewer's
    /// "keep atomic reconcile" guards), then routes the resulting `ScanEvent`s through the batcher, which
    /// deposits coalesced FIFO batches into `liveDelivery`; the serial `liveWorkTask` drains and folds
    /// them via `ScenePipeline.applyLiveBatch`. There is NO parallel delivery path: the FSEvents watcher no
    /// longer folds anything itself. Serial correctness (review-1 change 1) holds because a single work
    /// loop serializes compute→deliver→fold per revalidation group (a directory's fold lands before its
    /// next compute — the delete/recreate ordering), and the reducer drops orphan events from a pruned
    /// subtree (OPERATOR_NOTE #2). The flagged-directory I/O storm bound (dedup + per-drain cap + carry)
    /// stays in `FSEventsWatcher`'s coalescer as the INPUT stage feeding this loop, and one `liveEmit` per
    /// group coalesces the emit — so a mass change still yields a few scenes.
    ///
    /// Whether the live capability is DEGRADED — the FSEvents stream dropped events wholesale
    /// (`MustScanSubDirs` / kernel queue overflow) and a recovery subtree-rescan is in flight
    /// (review-1 change 4). Shown honestly in the status ("Live · recovering") for the duration, then
    /// cleared — never a silent claim of full "Live" after a completeness loss.
    private var fsDegraded = false
    /// Consumes the pipeline's `focusFallbacks` stream: a live prune of the focused subtree re-roots the
    /// pipeline focus at the surviving ancestor and yields it here → the App re-seeds navigation (the map
    /// never points at a ghost). Cancelled on teardown.
    private var liveFallbackTask: Task<Void, Never>?
    /// Whether the FSEvents stream is live (drives the status "live" indicator, deliverable 5).
    private var fsLive = false
    /// The lazy idle-revalidation timer (~10 s) — a cheap periodic focus mtime check while the user
    /// sits still, so a background deletion in the focused directory retires its tile without a poke.
    private var idleTimer: Timer?
    private static let idleRevalidationSeconds: TimeInterval = 10
    /// The last scene, cached so a `live`/`degraded` capability change (which arrives WITHOUT a new
    /// scene) can re-push the status honestly (`refreshStatus`).
    private var lastScene: RenderScene?
    /// PER-DRAIN batch cap for FSEvents-loss recovery (review-1 change 4; semantics corrected review-2
    /// change 2). This is NO LONGER a cap on the TOTAL directories recovered — that truncation silently
    /// left retained directories un-revalidated while the status resumed claiming full "Live". It now
    /// bounds only how many directories one recovery DRAIN re-validates before yielding; the remainder
    /// carries to the next drain, and the capability stays `.degraded` until every retained directory
    /// under the flagged subtree is processed (see `recoverSubtrees`). So a huge-subtree loss recovers
    /// COMPLETELY, a bounded batch at a time — never a silent claim of completeness.
    private static let maxRecoveryDirs = 512
    /// Pending FSEvents-loss recovery work (review-2 change 2): the retained directories still to be
    /// re-validated after a `MustScanSubDirs`/dropped-queue loss. REUSES `FSEventCoalescer` (the same
    /// dedup-set + capped-drain + carry policy the Tier-2 storm coalescer uses — now a two-user
    /// abstraction), drained by `recoverSubtrees` in `maxRecoveryDirs`-sized batches. New work from a
    /// later loss folds into the SAME set (dedup), so overlapping recoveries never double-process.
    private var recovery = FSEventCoalescer()
    /// Whether the single recovery drain loop is running. `recoverSubtrees` runs inside the SERIAL live
    /// loop, so only one drains at a time; a loss arriving mid-recovery is a fresh queued work item. `fsDegraded`
    /// tracks this — the loop clears both only when the recovery set is genuinely empty.
    private var recoveryDraining = false
    /// Called (on main) when a prune removed the focus subtree, with the surviving ancestor to fall
    /// back to — the App re-seeds navigation so the map never points at a ghost (deliverable 1).
    var onFocusFallback: ((String) -> Void)?

    // MARK: - TZ-7 live delivery through the EventBatcher (OPERATOR_NOTE #1)
    //
    /// The single live-update delivery funnel (OPERATOR_NOTE #1): computed diff `ScanEvent`s are `add`ed
    /// here; it coalesces them into ≤`maxEventsPerBatch` FIFO batches and deposits each into
    /// `liveDelivery` (its sink), exactly as the walker's batcher delivers scan data. `nil` between scans.
    private var liveBatcher: EventBatcher?
    /// The batcher's sink target: a serial hand-off the `liveWorkTask` drains after each flush and folds
    /// via `ScenePipeline.applyLiveBatch`. A tiny `@unchecked Sendable` box (lock-guarded) because the
    /// `EventBatcher` sink is `@Sendable` and runs on the batcher's executor; the App drains it on main.
    /// PER-SCAN (created with its batcher in `startLiveUpdates`, dropped in `stopLiveUpdates`) and THREADED
    /// through the live methods bound to its batcher — so a rescan mid-fold can never let one scan's drain
    /// consume another scan's batches (the two are always a consistent pair for one revalidation group).
    private var liveDelivery: LiveDelivery?
    /// The SINGLE serial consumer of `liveWork`: it processes one revalidation group at a time
    /// (compute→deliver→fold, then one `liveEmit`), which is what serializes fold-before-next-compute and
    /// preserves the review-1 delete/recreate ordering. Cancelled on teardown.
    private var liveWorkTask: Task<Void, Never>?
    /// Enqueues live work (focus pokes, Tier-2 drains, recovery) for the serial `liveWorkTask`. Buffered
    /// (not newest-1) so a rare burst of triggers is not coalesced away before it is processed.
    private var liveWorkCont: AsyncStream<LiveWork>.Continuation?
    /// Last `droppedOrphanEvents` value traced, so the TZTRACE line fires only on a change (honesty
    /// without spam) — OPERATOR_NOTE #2 ("expose the drop counter in TZTRACE").
    private var lastTracedDrops = 0
    private static let traceEnabled = ProcessInfo.processInfo.environment["TERRAZZO_TRACE"] != nil

    /// One unit of live work for the serial loop. A sum type: the three trigger shapes fold to distinct
    /// processing (one dir with a known mtime; a coalesced Tier-2 drain; a loss recovery).
    private enum LiveWork {
        /// Tier-1: revalidate ONE directory (the focus, or the pending-focus check), comparing `known`.
        case dir(id: String, known: Int64?)
        /// Tier-2: a coalesced drain of flagged directories (each revalidated, no known mtime).
        case dirs([String])
        /// FSEvents loss: recover the retained subtrees under these ids (bounded, degraded meanwhile).
        case recover([String])
    }

    /// Serial hand-off from the `EventBatcher`'s sink (batcher executor) to the main-actor drain. The
    /// batcher deposits coalesced FIFO batches; the live loop drains them in order and folds each.
    private final class LiveDelivery: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[ScanEvent]] = []
        func deposit(_ b: [ScanEvent]) { lock.lock(); batches.append(b); lock.unlock() }
        func drain() -> [[ScanEvent]] { lock.lock(); defer { batches.removeAll(); lock.unlock() }; return batches }
    }

    // MARK: - TZ-5 lens state (persists across a rescan; re-applied to each new pipeline)
    //
    // The scale/hidden/depth lens choices are the App's source of truth (updated by the
    // control-bar callbacks) and are RE-APPLIED to every freshly-built pipeline in `scan`, so a
    // user's choice survives a rescan/volume switch (the new pipeline defaults would otherwise
    // reset them). The IGNORE set is owned by NavigationController (it drives the panel + status)
    // and cleared on a new scan (a fresh pipeline starts with none), so it is NOT stored here.
    private(set) var currentScale: AreaScale = .sqrt
    private(set) var currentIncludeHidden = true
    private(set) var currentDepthWindow = ScanPolicy.default.depthDetailWindow

    init(root: URL, policy: ScanPolicy,
         onScene: @escaping (RenderScene) -> Void,
         onStatus: @escaping (ScanStatus) -> Void) {
        self.root = root
        self.policy = policy
        self.onScene = onScene
        self.onStatus = onStatus
    }

    /// Whether `root` is a selectable volume's root — REUSES the tested pure judgment the
    /// FDA banner uses (`VolumeSkipPolicy.isVolumeRoot`, AppDelegate), so the two are one
    /// notion, not two divergent ones. One-time syscall to enumerate the selectable volume
    /// mount paths (same category as the per-scan volume probe above; ScanFS owns it —
    /// CLAUDE.md constraint 1). Two callers: `scan(root:)` and `promoteRoot()`.
    private static func rootIsVolumeRoot(_ root: URL) -> Bool {
        let volumePaths = Set(VolumeEnumerator.selectableVolumes().map { $0.url.path })
        return VolumeSkipPolicy.isVolumeRoot(path: root.path, volumePaths: volumePaths)
    }

    /// Initial scan of the construction root.
    func start() { scan(root: root) }

    /// Rescan the CURRENT volume (TZ-4 Rescan button, human directive 2026-08-16 — the
    /// map is a snapshot of scan time; rescan re-runs the same volume, streaming as
    /// usual). Cancels any running scan first.
    func rescan() { scan(root: root) }

    /// (Re)start a streaming scan for `root` — the single entry the initial launch, the
    /// Rescan button, and the VolumePicker all funnel through (TZ-4). Cancels any
    /// in-flight scan, re-probes the volume accounting + inode denominator for the new
    /// root, builds a fresh pipeline, and streams as always.
    func scan(root: URL) {
        cancelScan()
        self.root = root
        running = true
        hitch.setPhase("scanning")
        hitch.start()

        // One-time syscalls per scan (not node-count work): volume accounting + the
        // inode denominator. Both live in ScanFS (CLAUDE.md constraint 1).
        volume = VolumeProbe.volumeInfo(for: root)
        totalInodes = VolumeProbe.usedInodes(for: root) ?? 0
        isVolumeRoot = Self.rootIsVolumeRoot(root)

        // TZ-7: the initial focus IS the scan root (NavigationController seeds it from the first
        // scene), so track it here — the idle timer + FSEvents revalidate the root focus from t=0.
        // A just-scanned root needs no immediate focus poke (pendingFocusRevalidation stays false).
        currentFocusId = root.path
        knownFocusMtime = nil
        pendingFocusRevalidation = false

        let pipe = ScenePipeline(rootId: root.path, rootName: root.lastPathComponent)
        pipeline = pipe
        // TZ-5: re-apply the current lens choices so a rescan/volume-switch keeps the user's
        // scale/hidden/depth (a new pipeline defaults to sqrt/shown/5). The ignore set is not
        // re-applied — a new scan starts with none (NavigationController.resetForNewScan clears it).
        Task {
            await pipe.setScale(currentScale)
            await pipe.setIncludeHidden(currentIncludeHidden)
            await pipe.setDepthWindow(currentDepthWindow)
        }

        // NOTE (TZ-4b, HUMAN FIELD RULING #1): the pipeline is no longer told the volume
        // accounting — the synthetic UNACCOUNTED tile it fed was retracted. The
        // "Unaccounted" figure is now a STATUS-BAR field the App composes from `volume`
        // (VolumeProbe) + the scene's `scannedBytes` via the pure `UnaccountedSpace`
        // math (see StatusBar.fields). The pipeline composes tiles from the SizeTree only.

        // Feed the real walker's event stream into the pipeline. The fold + all the
        // node-count-scaling projection/layout run inside the actor, off main.
        let walker = FileSystemWalker.scan(root: root, policy: policy)
        walkTasks = [Task { await pipe.ingest(walker) }]

        // TZ-6 deliverable 5: for a SUBTREE scan (not already the volume root), warm the
        // volume root's metadata cache off the primary path at .utility QoS (the measured
        // FileSystemWalker.defaultAnticipatoryPriority) — excluding this scan's subtree — so a
        // zoom-out promotion finds its new siblings warm. A volume-root scan needs no
        // anticipation (it already covers the volume).
        if !isVolumeRoot {
            anticipateTask = FileSystemWalker.anticipateVolumeRoot(excluding: root)
        }

        // Consume finished scenes on the MAIN actor. O(scene), not O(node count).
        sceneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await scene in pipe.scenes {
                self.onScene(scene)
                self.lastScene = scene
                self.onStatus(self.makeStatus(scene))
                // TZ-7 Tier-1: cache the FOCUS directory's retained mtime off the focus-rooted
                // projection root (O(1) on main) and, on a fresh focus, trigger one mtime-compared
                // revalidation once its scene has arrived — a fresh look that catches any deletion
                // since scan time without re-enumerating on every idle tick.
                if scene.focusId == self.currentFocusId {
                    self.knownFocusMtime = scene.tree.mtime
                    if self.pendingFocusRevalidation {
                        self.pendingFocusRevalidation = false
                        self.revalidateDir(scene.focusId, comparingMtime: scene.tree.mtime)
                    }
                }
                if !scene.running && self.running {
                    self.running = false
                    self.stopCadence()
                    self.hitch.stop(reason: "scan complete")
                }
            }
        }

        // Consume focus fallbacks (a live prune of the focused subtree) → re-seed navigation. The
        // stream finishes when the pipeline is released (its deinit); the task is also cancelled on
        // teardown. Reading `pipe.focusFallbacks` (a nonisolated let) here keeps the actor un-retained.
        let fallbacks = pipe.focusFallbacks
        liveFallbackTask = Task { @MainActor [weak self] in
            for await ancestorId in fallbacks {
                guard let self else { return }
                self.currentFocusId = ancestorId
                self.knownFocusMtime = nil
                self.onFocusFallback?(ancestorId)
            }
        }

        startCadence()
        startLiveUpdates(root: root)
    }

    /// Start the batched relayout cadence (ratified decision 3): a lightweight main Timer
    /// that only fires `tick()` at the actor — the work stays off main. Idempotent: a
    /// no-op if one is already running (root promotion re-uses this to resume the cadence
    /// when the primary scan had already completed and stopped it).
    private func startCadence() {
        guard cadenceTimer == nil else { return }
        let timer = Timer(timeInterval: ScenePipeline.cadenceSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let pipe = self?.pipeline else { return }
                Task { await pipe.tick() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cadenceTimer = timer
    }

    // MARK: - Root promotion (TZ-4b — "root promotion", ratified)

    /// Promote the scan root one level up (zoom-out AT the scan root). Returns the NEW
    /// root's id (its absolute path) for the navigation camera, or `nil` when already at
    /// the volume root (a path whose parent is itself, i.e. "/") — the caller then does
    /// nothing. This orchestrates all four layers' App-side wiring:
    ///   - re-read the statfs progress DENOMINATOR + volume accounting for the promoted
    ///     root (packet: "statfs progress denominator re-read on promotion");
    ///   - `pipeline.promote` grafts the reducer up a level, resets focus to the new root,
    ///     re-applies volume accounting, and FORCE-EMITS the promoted frame (old map as one
    ///     child among new siblings) — the scene the navigation camera flies over — then
    ///     folds the promoted parent's NEW siblings (sibling-exclusion walk) into the SAME
    ///     pipeline (same reducer → graft and new siblings merge). It is ONE atomic actor
    ///     op: the successor walk is registered (running == true) BEFORE the promoted
    ///     force-emit, so an idle-time promotion (primary already drained) does not report
    ///     the scan finished and tear down the cadence before siblings stream (finding 1).
    func promoteRoot() -> String? {
        let oldRoot = root
        let newRoot = oldRoot.deletingLastPathComponent()
        guard newRoot.path != oldRoot.path else { return nil } // already at the volume root

        self.root = newRoot
        running = true
        hitch.setPhase("promote")
        // Promotion supersedes anticipation: we are now scanning the parent's new siblings
        // ourselves, so stop warming (avoids redundant I/O overlapping the sibling walk).
        anticipateTask?.cancel(); anticipateTask = nil

        // Re-read the progress denominator + volume accounting for the promoted root, and
        // whether the promoted root IS the volume root — promotion is how a `~` scan
        // reaches the volume root, at which point the percentage/ETA become honest again
        // (OPERATOR_NOTE #2 item 2). The volume accounting feeds only the status-bar
        // "Unaccounted" figure now (not the pipeline).
        totalInodes = VolumeProbe.usedInodes(for: newRoot) ?? totalInodes
        volume = VolumeProbe.volumeInfo(for: newRoot) ?? volume
        isVolumeRoot = Self.rootIsVolumeRoot(newRoot)

        let newRootId = newRoot.path
        let oldRootId = oldRoot.path

        // TZ-7: the scan root moved up — re-point the living map (FSEvents watches the new, larger
        // root; the focus lands on it). The grafted subtree keeps its retained mtimes.
        currentFocusId = newRootId
        knownFocusMtime = nil
        pendingFocusRevalidation = false
        startLiveUpdates(root: newRoot)

        guard let pipe = pipeline else { return newRootId }
        startCadence() // resume batched relayout if the primary scan had finished

        let sibling = FileSystemWalker.scanSiblings(newRoot: newRoot, newRootId: newRootId,
                                                    excludingChildId: oldRootId, policy: policy)
        let task = Task {
            // ONE atomic actor op: graft + promoted force-emit (running=true) + fold the
            // siblings. Registering the successor walk before the force-emit is what
            // prevents an idle-time promotion from falsely reporting the scan done
            // (finding 1). No volume accounting is threaded through — the "Unaccounted"
            // figure is a status-bar field, re-read above.
            await pipe.promote(newRootId: newRootId, newRootName: newRoot.lastPathComponent,
                               sibling: sibling)
        }
        walkTasks.append(task)
        return newRootId
    }

    /// New focus (dive/ascend). Posted to the pipeline, which emits the target scene
    /// immediately so the camera commit does not wait.
    ///
    /// COMMIT→SCENE LATENCY (TZ-4b rider 2b, packet ≤ ~200 ms). `pipe.setFocus` force-emits
    /// the target scene SYNCHRONOUSLY on the actor, so the wall time of this `await` — the
    /// actor-QUEUE wait behind any in-progress fold/emit PLUS the makeTree→layout→cull→quad
    /// build — IS the end-to-end commit-to-scene latency, measured HERE on the live scan (not
    /// the lossy time a coalesced scene reaches main: the newest-1 stream drops stale scenes
    /// by design, so delivery timing ≠ this). `worstFocusEmitMs` exposes the worst. Since
    /// TZ-4b's focus-rooted projection (OPERATOR_NOTE #2), `ScanReducer.makeTree` walks only
    /// the focus subtree ∩ render window, so a dive is O(focus subtree) — the seconds-long
    /// full-volume dive latency (the O(retained-nodes)-from-root cost) is gone.
    func setFocus(_ id: String) {
        guard let pipe = pipeline else { return }
        // TZ-7 Tier-1: a focus CHANGE arms one mtime-compared revalidation of the new focus, fired
        // when its scene arrives (so we have its retained mtime to compare). The previous focus's
        // mtime is meaningless for the new one, so forget it until the new scene lands.
        if id != currentFocusId {
            currentFocusId = id
            knownFocusMtime = nil
            pendingFocusRevalidation = true
        }
        Task {
            let t0 = DispatchTime.now().uptimeNanoseconds
            await pipe.setFocus(id)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
            worstFocusEmitMs = max(worstFocusEmitMs, ms)
            focusEmitSamples += 1
        }
    }

    // MARK: - TZ-7 live updates (revalidation + FSEvents) — all background, main-thread law untouched

    /// Start the living map for `root`: the FSEvents Tier-2 stream (its callback revalidates each
    /// flagged directory) and the lazy Tier-1 idle timer (a periodic focus mtime check). The stream
    /// watches the PRIMARY scan root only (the anticipatory tree is deliberately unwatched in v1,
    /// PLAN §TZ-7 out-of-scope). `fsLive` reflects whether the stream came up; a failure degrades to
    /// Tier-1 and the status tooltip SAYS so (never silent — deliverable 5).
    private func startLiveUpdates(root: URL) {
        stopLiveUpdates()
        let rootPath = root.path

        // The single live delivery funnel (OPERATOR_NOTE #1). The batcher's sink deposits coalesced FIFO
        // batches into a FRESH per-scan `liveDelivery`; the serial `liveWorkTask` drains and folds them.
        // Constructed BEFORE the work loop and the watcher so the very first flagged directory has a
        // funnel to flow through. Batcher and delivery are a matched pair, threaded together below.
        let delivery = LiveDelivery()
        liveDelivery = delivery
        liveBatcher = EventBatcher { batch in delivery.deposit(batch) }

        // The SINGLE serial consumer: one revalidation group at a time (compute→deliver→fold, one emit).
        let (workStream, workCont) = AsyncStream<LiveWork>.makeStream(bufferingPolicy: .unbounded)
        liveWorkCont = workCont
        liveWorkTask = Task { @MainActor [weak self] in
            for await work in workStream {
                guard let self else { return }
                await self.processLiveWork(work)
            }
        }

        fsWatcher = FSEventsWatcher(rootPath: rootPath, onDirs: { [weak self] flaggedDirIds in
            // Runs on the watcher's background queue. Enqueue the coalesced drain for the serial loop; the
            // blocking enumeration + the batcher-routed fold happen there, off the watcher queue.
            Task { @MainActor [weak self] in self?.liveWorkCont?.yield(.dirs(flaggedDirIds)) }
        }, onRescan: { [weak self] rescanIds in
            // review-1 change 4: the kernel lost events for these subtrees — enqueue a recovery.
            Task { @MainActor [weak self] in self?.liveWorkCont?.yield(.recover(rescanIds)) }
        })
        fsLive = (fsWatcher != nil)
        refreshStatus() // reflect the live/degraded capability the moment it is known (deliverable 5)

        let timer = Timer(timeInterval: Self.idleRevalidationSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidateFocus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopLiveUpdates() {
        fsWatcher?.stop(); fsWatcher = nil
        fsLive = false
        fsDegraded = false
        // Tear down the live delivery funnel + serial loop. Finishing the continuation ends the loop's
        // `for await`; any in-flight iteration bails at its next `self.pipeline === pipe` guard (the
        // pipeline is being replaced). Draining `liveDelivery` prevents stale batches leaking across scans.
        liveWorkCont?.finish(); liveWorkCont = nil
        liveWorkTask?.cancel(); liveWorkTask = nil
        liveBatcher = nil
        liveDelivery = nil // dropped whole — a fresh per-scan delivery is made in startLiveUpdates
        // Drop any in-flight recovery work — a new scan/promotion starts with a clean slate.
        recovery = FSEventCoalescer()
        recoveryDraining = false
        idleTimer?.invalidate(); idleTimer = nil
    }

    // MARK: - Live status (the live/degraded indicator — deliverable 5, review-1 change 4)

    /// The current live-monitoring capability, honestly: `.off` when the FSEvents stream is unavailable
    /// (Tier-1 only), `.degraded` while recovering from a dropped-events burst, else `.live`.
    private var liveStatus: LiveStatus {
        guard fsLive else { return .off }
        return fsDegraded ? .degraded : .live
    }

    /// Build the status DTO for a scene, carrying the current live capability.
    private func makeStatus(_ scene: RenderScene) -> ScanStatus {
        ScanStatus(volume: volume, scannedBytes: scene.scannedBytes,
                   belowPixelCount: scene.belowPixelCount, running: scene.running,
                   filesProcessed: scene.filesProcessed, totalInodes: totalInodes,
                   isVolumeRoot: isVolumeRoot, scaleMode: scene.scaleMode,
                   hiddenFilteredBytes: scene.hiddenFilteredBytes, live: liveStatus)
    }

    /// Re-push the status with the current live capability when it changes WITHOUT a new scene (stream
    /// came up / degraded / recovered). No-op before the first scene arrives.
    private func refreshStatus() {
        if let scene = lastScene { onStatus(makeStatus(scene)) }
    }

    /// Tier-1 trigger for app activation (NSApplication.didBecomeActive) and the idle timer:
    /// revalidate the CURRENT focus, comparing against its cached mtime (one syscall if unchanged).
    /// Enqueued on the serial live loop (OPERATOR_NOTE #1) so it is delivered through the same batcher.
    func revalidateFocus() {
        guard let id = currentFocusId else { return }
        liveWorkCont?.yield(.dir(id: id, known: knownFocusMtime))
    }

    /// Revalidate ONE directory (Tier-1 focus poke, or the pending-focus check when a fresh focus's
    /// scene arrives). Enqueued on the serial live loop; the read + batcher-routed fold happen there.
    func revalidateDir(_ dirId: String, comparingMtime known: Int64?) {
        liveWorkCont?.yield(.dir(id: dirId, known: known))
    }

    // MARK: - The serial live loop (OPERATOR_NOTE #1 — one delivery path through the EventBatcher)

    /// Process one live-work group serially: revalidate its directories (compute→deliver→fold through the
    /// batcher), then emit ONCE for the group so a mass change coalesces into a scene. Because the loop
    /// awaits each group to completion before the next, a directory's fold lands before its next compute —
    /// the delete/recreate ordering review-1 change 1 requires, now preserved WITHOUT an atomic fold.
    private func processLiveWork(_ work: LiveWork) async {
        // Capture the scan's (pipeline, batcher, delivery) as a consistent trio for this group.
        guard let pipe = pipeline, let batcher = liveBatcher, let delivery = liveDelivery else { return }
        switch work {
        case let .dir(id, known):
            await revalidateOne(id, comparingMtime: known, pipe: pipe, batcher: batcher, delivery: delivery)
            guard self.pipeline === pipe else { return }
            await pipe.liveEmit()
            await traceDrops(pipe)
        case let .dirs(ids):
            for dirId in ids {
                await revalidateOne(dirId, comparingMtime: nil, pipe: pipe, batcher: batcher, delivery: delivery)
                guard self.pipeline === pipe else { return }
            }
            await pipe.liveEmit() // one scene per coalesced drain (storm-safe emit)
            await traceDrops(pipe)
        case let .recover(ids):
            await recoverSubtrees(ids, pipe: pipe, batcher: batcher, delivery: delivery)
        }
    }

    /// The shared revalidation core (Tier-1 focus poke + Tier-2 FSEvents dir + recovery). It (1) asks
    /// the actor what a flagged path IS — an ordinary directory, an opaque bundle leaf, or a skip
    /// (review-1 change 3); (2) does the matching BLOCKING read OFF the main actor (a detached task, so
    /// the syscalls never touch the suspended main actor — the threading law); (3) COMPUTES the diff
    /// atomically against retained state (`computeLiveDiff`/`computeBundleDiff` — the review-1 stale/
    /// contains guards) and routes the events THROUGH the batcher to `applyLiveBatch` (`deliverAndFold`).
    /// Only the sub-scan launch and the emit return to the caller. Does NOT emit — the caller emits once
    /// per logical group (`liveEmit`) so a storm coalesces.
    ///
    /// A `.unreadable` directory/bundle (deleted) re-targets the nearest surviving ancestor of its
    /// PARENT, whose fresh listing `childRemoved`s the vanished subtree and triggers the focus fallback
    /// (review-0 change 2 — a deleted focus never leaves a ghost). Self-correcting for a merely-DENIED
    /// (still-present) directory: the parent's listing still contains it, so no removal is emitted.
    private func revalidateOne(_ dirId: String, comparingMtime known: Int64?,
                               pipe: ScenePipeline, batcher: EventBatcher, delivery: LiveDelivery) async {
        let policy = self.policy
        let target = await pipe.revalidationTarget(for: dirId)
        guard self.pipeline === pipe else { return }
        switch target {
        case .skip:
            return
        case .directory(let id):
            // OFF MAIN: stat + (if changed) enumerate.
            let read = await Task.detached(priority: .utility) {
                FileSystemWalker.revalidationRead(dirId: id, ifUnchangedFrom: known, policy: policy)
            }.value
            guard self.pipeline === pipe else { return } // a rescan replaced the pipeline during the await
            switch read {
            case .unchanged:
                return
            case .unreadable:
                await revalidateSurvivingParent(of: id, pipe: pipe, batcher: batcher, delivery: delivery)
            case let .changed(mtime, ownAllocated, ownLogical, fresh, complete):
                // Compute the diff atomically (guards), then DELIVER it through the batcher (fold happens
                // in `deliverAndFold` via `applyLiveBatch`) — one delivery path, OPERATOR_NOTE #1.
                let (events, newChildIds) = await pipe.computeLiveDiff(
                    dirId: id, readMtime: mtime, ownAllocated: ownAllocated, ownLogical: ownLogical,
                    fresh: fresh, complete: complete)
                guard self.pipeline === pipe else { return }
                await deliverAndFold(events, pipe: pipe, batcher: batcher, delivery: delivery)
                guard self.pipeline === pipe else { return }
                self.launchSubScans(newChildIds, rootPath: self.root.path, pipe: pipe)
            }
        case .bundle(let id):
            // OFF MAIN: opaque re-measure of the bundle's recursive total (never exposes descendants).
            let read = await Task.detached(priority: .utility) {
                FileSystemWalker.revalidationBundleRead(bundleId: id)
            }.value
            guard self.pipeline === pipe else { return }
            switch read {
            case .incomplete:
                return // present but not fully readable — leave the retained total (never a false shrink)
            case .unreadable:
                await revalidateSurvivingParent(of: id, pipe: pipe, batcher: batcher, delivery: delivery)
            case let .sized(mtime, allocated, logical):
                let events = await pipe.computeBundleDiff(bundleId: id, readMtime: mtime,
                                                          allocated: allocated, logical: logical)
                guard self.pipeline === pipe else { return }
                await deliverAndFold(events, pipe: pipe, batcher: batcher, delivery: delivery)
            }
        }
    }

    /// Route the computed live events THROUGH the `EventBatcher` (the single live delivery funnel,
    /// OPERATOR_NOTE #1), then fold the coalesced FIFO batches. `add` chunks a huge single-directory diff
    /// (a mass delete's thousands of `childRemoved`) into ≤`maxEventsPerBatch` batches; `flush` drains the
    /// remainder; each deposited batch is folded via `applyLiveBatch` IN ORDER. Awaiting the fold here —
    /// inside the serial loop — is what makes fold land before the next compute (the delete/recreate
    /// ordering). Empty diff (unchanged / guarded-stale) is a no-op.
    private func deliverAndFold(_ events: [ScanEvent], pipe: ScenePipeline,
                                batcher: EventBatcher, delivery: LiveDelivery) async {
        guard !events.isEmpty else { return }
        await batcher.add(events)
        await batcher.flush()
        for batch in delivery.drain() {
            guard self.pipeline === pipe else { return }
            await pipe.applyLiveBatch(batch)
        }
    }

    /// Emit a TZTRACE line when the reducer's orphan-drop counter changes (OPERATOR_NOTE #2 — "expose the
    /// drop counter in TZTRACE, honesty over silence"). Fires only on a change so a quiet map is quiet.
    private func traceDrops(_ pipe: ScenePipeline) async {
        guard Self.traceEnabled else { return }
        let n = await pipe.droppedOrphanEvents
        guard n != lastTracedDrops else { return }
        lastTracedDrops = n
        print("TZTRACE live droppedOrphanEvents=\(n) (late sub-scan events under a pruned subtree, dropped by the reducer)")
        fflush(stdout)
    }

    /// A deleted directory/bundle re-targets the nearest surviving ancestor of its PARENT, whose fresh
    /// listing `childRemoved`s the vanished subtree (review-0 change 2). Bounded: `parentPath` never
    /// climbs past "/", and each hop strictly shortens the path, so the recursion terminates.
    private func revalidateSurvivingParent(of id: String, pipe: ScenePipeline,
                                           batcher: EventBatcher, delivery: LiveDelivery) async {
        let parent = Self.parentPath(of: id)
        guard parent != id, let anc = await pipe.nearestRetainedAncestor(of: parent) else { return }
        guard self.pipeline === pipe else { return }
        await revalidateOne(anc, comparingMtime: nil, pipe: pipe, batcher: batcher, delivery: delivery)
    }

    /// Recover from an FSEvents event LOSS (`MustScanSubDirs` / dropped kernel queue — review-1
    /// change 4). The kernel could not tell us WHAT changed under each flagged subtree, so a one-level
    /// re-list is insufficient: re-validate every RETAINED directory under it (each diffed against
    /// disk — catching adds, removes, and in-place size changes at every level; newly-appeared subtrees
    /// arrive via their retained parent's `childrenDiscovered` + sub-scan). All folds route through the
    /// batcher like every other live update (OPERATOR_NOTE #1).
    ///
    /// COMPLETENESS + HONEST STATUS (review-2 change 2). The flagged subtree's EVERY retained directory
    /// is enqueued (`retainedDirIds(under:)` is uncapped) and drained in `maxRecoveryDirs`-sized batches
    /// that CARRY across drains; the live capability is stated `.degraded` from the first loss until the
    /// recovery set is genuinely EMPTY. Runs inside the serial live loop (one recovery at a time), so a
    /// loss arriving mid-recovery is processed as a fresh recovery afterwards — still complete.
    private func recoverSubtrees(_ ids: [String], pipe: ScenePipeline,
                                 batcher: EventBatcher, delivery: LiveDelivery) async {
        guard !ids.isEmpty else { return }
        // Enqueue EVERY retained directory under each flagged subtree (complete — dedup folds overlaps).
        for id in ids {
            recovery.add(await pipe.retainedDirIds(under: id))
            guard self.pipeline === pipe else { return }
        }
        recoveryDraining = true
        fsDegraded = true
        refreshStatus()
        while !recovery.isEmpty {
            for d in recovery.drain(max: Self.maxRecoveryDirs) {
                await revalidateOne(d, comparingMtime: nil, pipe: pipe, batcher: batcher, delivery: delivery)
                guard self.pipeline === pipe else { recoveryDraining = false; return }
            }
            await pipe.liveEmit() // one scene per bounded drain (storm-safe emit)
            await traceDrops(pipe)
            guard self.pipeline === pipe else { recoveryDraining = false; return }
            await Task.yield()    // let other main work interleave between bounded drains
        }
        recoveryDraining = false
        fsDegraded = false
        refreshStatus()
    }

    /// The parent directory id (absolute path) of `id`. Returns "/" for a top-level id and "/" for the
    /// volume root itself, so the deleted-focus fallback can never climb past the volume root.
    private static func parentPath(of id: String) -> String {
        guard let slash = id.lastIndex(of: "/") else { return id }
        if slash == id.startIndex { return "/" } // e.g. "/Users" -> "/", and "/" -> "/"
        return String(id[id.startIndex..<slash])
    }

    /// Launch a streamed sub-scan for each new child a revalidation surfaced, folded into the SAME
    /// pipeline. Flips `running`/cadence on so intermediate frames of a large new subtree stream in;
    /// the scene consumer turns them off again when every walk drains.
    private func launchSubScans(_ ids: [String], rootPath: String, pipe: ScenePipeline) {
        guard !ids.isEmpty else { return }
        running = true
        startCadence()
        let policy = self.policy
        for childId in ids {
            let stream = FileSystemWalker.scanNewChild(url: URL(fileURLWithPath: childId), id: childId,
                                                       scanRootPath: rootPath, policy: policy)
            walkTasks.append(Task { await pipe.ingest(stream) })
        }
    }

    /// Worst focus commit→scene latency seen (ms) = actor-queue wait + emit build, and the
    /// sample count — the headless threading harness reports these as the rider-2b number
    /// (target ≤ ~200 ms; met since focus-rooted projection scopes the emit to the focus
    /// subtree, TZ-4b OPERATOR_NOTE #2).
    private(set) var worstFocusEmitMs: Double = 0
    private(set) var focusEmitSamples = 0

    /// Resolve a clicked denied-overflow aggregate's disclosure ON THE PIPELINE ACTOR (off main,
    /// review-5) and deliver it back to the main actor for presentation. The names/implied-size
    /// lookup scales with the parent folder's fanout, so it must not run on main
    /// (`SizeTree.node(withId:)` is documented "never on the main actor"); this hops to the actor
    /// and back. User-driven and once-per-click — never the frame hot path. `present` runs on the
    /// main actor with the raw DTO (or `nil` when there is no pipeline / the parent is no longer
    /// retained), so the caller can fall back to a count-only disclosure from the clicked tile.
    func deniedDisclosure(aggregateNodeId: String,
                          then present: @escaping @MainActor (DeniedDisclosure?) -> Void) {
        guard let pipe = pipeline else { present(nil); return }
        Task { @MainActor in
            let disclosure = await pipe.deniedDisclosure(aggregateNodeId: aggregateNodeId)
            present(disclosure)
        }
    }

    /// New viewport (resize). The pipeline re-fits and emits immediately.
    func setViewport(_ vp: Rect) {
        guard let pipe = pipeline else { return }
        Task { await pipe.setViewport(vp) }
    }

    // MARK: - TZ-5 lens controls (control bar → pipeline; off main)

    /// Set the area scale (control-bar toggle, deliverable 2). Stores the choice (so a rescan
    /// keeps it) and posts it to the live pipeline, which re-projects immediately off main.
    func setScale(_ s: AreaScale) {
        currentScale = s
        if let pipe = pipeline { Task { await pipe.setScale(s) } }
    }

    /// Set the show-hidden lens (control-bar checkbox, deliverable 3).
    func setIncludeHidden(_ include: Bool) {
        currentIncludeHidden = include
        if let pipe = pipeline { Task { await pipe.setIncludeHidden(include) } }
    }

    /// Set the render depth window (control-bar stepper, deliverable 4). No rescan — the reducer
    /// retains every node, so the pipeline re-projects deeper/shallower over retained state.
    func setDepthWindow(_ n: Int) {
        currentDepthWindow = max(1, n)
        if let pipe = pipeline { Task { await pipe.setDepthWindow(currentDepthWindow) } }
    }

    /// Post the IGNORE set (deliverable 1). NavigationController owns the authoritative set; this
    /// forwards it to the pipeline so the ignored nodes are excluded from layout (siblings
    /// renormalize) off main. Not stored here — a new scan starts with an empty ignore set.
    func setIgnored(_ ids: Set<String>) {
        if let pipe = pipeline { Task { await pipe.setIgnored(ids) } }
    }

    /// Coarse phase label for the hitch monitor (what main is doing).
    func setPhase(_ p: String) { hitch.setPhase(p) }

    /// The worst inter-beat main-thread gap the hitch monitor has seen (ms) — the
    /// headless threading harness reports this as the acceptance number (target
    /// < 100 ms). 0 when the monitor is disabled (`TERRAZZO_HITCH` unset).
    var worstMainGapMs: Double { hitch.worstGapMs }

    /// Cancel the current scan (app terminate, or before a rescan/volume switch). Tears
    /// down the walker + scene tasks + cadence and stops the hitch monitor; the old
    /// pipeline is released, so its `bufferingNewest(1)` scene stream drops on the floor.
    func cancel() { cancelScan() }

    /// Internal teardown shared by `cancel()` and the start of every `scan(root:)`.
    private func cancelScan() {
        for t in walkTasks { t.cancel() }; walkTasks = []
        anticipateTask?.cancel(); anticipateTask = nil
        sceneTask?.cancel(); sceneTask = nil
        liveFallbackTask?.cancel(); liveFallbackTask = nil
        stopCadence()
        stopLiveUpdates() // TZ-7: tear down the FSEvents stream + idle timer before the pipeline goes
        lastScene = nil
        pipeline = nil
        if running { hitch.stop(reason: "cancelled") }
        running = false
    }

    private func stopCadence() {
        cadenceTimer?.invalidate()
        cadenceTimer = nil
    }
}
