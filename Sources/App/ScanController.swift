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
    private var walkTask: Task<Void, Never>?
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

        let pipe = ScenePipeline(rootId: root.path, rootName: root.lastPathComponent,
                                 projectionDepth: policy.depthDetailWindow)
        pipeline = pipe

        // Hand the pipeline the volume accounting so it can inject the synthetic
        // UNACCOUNTED tile (capacity − free − scanned) and carry purgeable for the
        // tile's decomposed readout (TZ-4 deliverable 7). `free` is the STRICT
        // availableBytes, so unaccounted counts purgeable + other-user/unknown mass,
        // and the readout's Y = unaccounted − purgeable.
        if let v = volume {
            Task { await pipe.setVolumeAccounting(capacity: v.capacityBytes,
                                                  free: v.availableBytes,
                                                  purgeable: v.purgeableBytes) }
        }

        // Feed the real walker's event stream into the pipeline. The fold + all the
        // node-count-scaling projection/layout run inside the actor, off main.
        let walker = FileSystemWalker.scan(root: root, policy: policy)
        walkTask = Task { await pipe.ingest(walker) }

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
                                         totalInodes: self.totalInodes))
                if !scene.running && self.running {
                    self.running = false
                    self.stopCadence()
                    self.hitch.stop(reason: "scan complete")
                }
            }
        }

        // Batched relayout cadence (ratified decision 3): a lightweight main Timer
        // that only fires `tick()` at the actor — the work stays off main.
        let timer = Timer(timeInterval: ScenePipeline.cadenceSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let pipe = self?.pipeline else { return }
                Task { await pipe.tick() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cadenceTimer = timer
    }

    /// New focus + projection depth (dive/ascend). Posted to the pipeline, which
    /// emits the target scene immediately so the camera commit does not wait.
    func setFocus(_ id: String, projectionDepth depth: Int) {
        guard let pipe = pipeline else { return }
        Task { await pipe.setFocus(id, projectionDepth: depth) }
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
        walkTask?.cancel(); walkTask = nil
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
