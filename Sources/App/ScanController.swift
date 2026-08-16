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
    private var sceneTask: Task<Void, Never>?
    private var cadenceTimer: Timer?
    private let hitch = HitchMonitor()
    private var running = false

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

        let pipe = ScenePipeline(rootId: root.path, rootName: root.lastPathComponent)
        pipeline = pipe

        // NOTE (TZ-4b, HUMAN FIELD RULING #1): the pipeline is no longer told the volume
        // accounting — the synthetic UNACCOUNTED tile it fed was retracted. The
        // "Unaccounted" figure is now a STATUS-BAR field the App composes from `volume`
        // (VolumeProbe) + the scene's `scannedBytes` via the pure `UnaccountedSpace`
        // math (see StatusBar.fields). The pipeline composes tiles from the SizeTree only.

        // Feed the real walker's event stream into the pipeline. The fold + all the
        // node-count-scaling projection/layout run inside the actor, off main.
        let walker = FileSystemWalker.scan(root: root, policy: policy)
        walkTasks = [Task { await pipe.ingest(walker) }]

        // Consume finished scenes on the MAIN actor. O(scene), not O(node count).
        sceneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await scene in pipe.scenes {
                self.onScene(scene)
                self.onStatus(ScanStatus(volume: self.volume,
                                         scannedBytes: scene.scannedBytes,
                                         belowPixelCount: scene.belowPixelCount,
                                         running: scene.running,
                                         filesProcessed: scene.filesProcessed,
                                         totalInodes: self.totalInodes,
                                         isVolumeRoot: self.isVolumeRoot))
                if !scene.running && self.running {
                    self.running = false
                    self.stopCadence()
                    self.hitch.stop(reason: "scan complete")
                }
            }
        }

        startCadence()
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
        Task {
            let t0 = DispatchTime.now().uptimeNanoseconds
            await pipe.setFocus(id)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
            worstFocusEmitMs = max(worstFocusEmitMs, ms)
            focusEmitSamples += 1
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
        sceneTask?.cancel(); sceneTask = nil
        stopCadence()
        pipeline = nil
        if running { hitch.stop(reason: "cancelled") }
        running = false
    }

    private func stopCadence() {
        cadenceTimer?.invalidate()
        cadenceTimer = nil
    }
}
