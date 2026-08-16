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
    private let root: URL
    private let policy: ScanPolicy
    /// One value handoff up to NavigationController (positioned tiles + labels).
    private let onScene: (RenderScene) -> Void
    private let onStatus: (ScanStatus) -> Void

    private var pipeline: ScenePipeline?
    private var volume: VolumeProbe.VolumeInfo?
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

    func start() {
        volume = VolumeProbe.volumeInfo(for: root)
        running = true
        hitch.setPhase("scanning")
        hitch.start()

        let pipe = ScenePipeline(rootId: root.path, rootName: root.lastPathComponent,
                                 projectionDepth: policy.depthDetailWindow)
        pipeline = pipe

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
                                         running: scene.running))
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

    func cancel() {
        walkTask?.cancel()
        sceneTask?.cancel()
        stopCadence()
        hitch.stop(reason: "cancelled")
    }

    private func stopCadence() {
        cadenceTimer?.invalidate()
        cadenceTimer = nil
    }
}
