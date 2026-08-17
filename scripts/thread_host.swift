//
//  thread_host.swift — threading evidence via the REAL NavigationController, no window.
//  Module maturity: PROTOTYPE (slice TZ-3b, review-0 gap 2)
//
//  Proves the ratified law — "nothing on the main thread may scale with node count"
//  (PLAN §"Threading model") — on a REAL directory scan, driving the ACTUAL App
//  navigation stack, WITHOUT synthetic input and WITHOUT a window (CLAUDE.md builder
//  conduct rule + TZ-3b CONDUCT RULE). Unlike the first pass (which drove the pipeline
//  directly), this instantiates the real NavigationController + CanvasView +
//  ScanController and calls dive()/ascend() programmatically through the tiny
//  `driveNavigationStep` seam, so the exact main-thread paths the app runs — scene
//  intake, the camera timer, the settle timer, the hover/label plumbing — are
//  exercised and measured.
//
//  HOW IT STAYS CONDUCT-COMPLIANT:
//   - No NSWindow is created and none is raised/activated (only an NSApplication
//     event loop, activation policy .prohibited — no dock icon, no UI presence).
//   - No CGEvent / System Events. Navigation is driven by calling the controller's
//     methods directly (driveNavigationStep), never by posting input.
//   - The CanvasView lives off-window; if the off-window CAMetalLayer cannot vend a
//     drawable the Metal ENCODE is a no-op, but every main-thread CPU path the law
//     governs still runs — the heartbeat measures the thread regardless.
//
//  WHAT IT REPORTS: the HitchMonitor's worst MAIN-THREAD gap over the whole scan
//  (target < 100 ms), the number of scenes that flowed, that generations were
//  strictly monotonic, and the number of dive/ascend posts issued while the scan
//  streamed (scenes must keep flowing across them). It reads HitchMonitor's number
//  via ScanController.worstMainGapMs and also lets HitchMonitor print its own TZHITCH
//  line (both require TERRAZZO_HITCH; threads.sh sets it).
//
//  Compiled by scripts/threads.sh with the App sources (minus main.swift/AppDelegate)
//  + RenderPipeline + ScanFS + the two cores into one swiftc binary linking AppKit +
//  Metal. Usage: thread_host [rootDir] [maxSeconds]   (defaults: $HOME, 180)
//

import AppKit

@MainActor
final class ThreadHarness {
    private let root: URL
    private let maxSeconds: Double

    private let canvas: CanvasView
    private let statusBar: StatusBar
    private let navigation: NavigationController
    private var controller: ScanController!

    private var scenes = 0
    private var lastScene: RenderScene?
    private var lastGen = 0
    private var monotonic = true
    private var running = true
    private var focusPosts = 0
    private var scenesAtFirstNav = -1
    private var finished = false
    /// The largest RENDERED (post-cull) tile count in any scene, and the most tiles
    /// culled as sub-pixel in one scene — evidence that the sets main touches are
    /// bounded by the viewport, not the tree's node count.
    private var maxRenderedTiles = 0
    private var maxCulled = 0

    // TZ-4 acceptance evidence (all read from the VIEWPORT-BOUNDED scene, never a tree
    // walk — so this observability adds no node-count work to the measured main thread):
    //   - progress ratio advancing (filesProcessed / statfs used-inodes),
    //   - denied tiles from other users' homes at root scale (kind == .denied),
    //   - the unaccounted STATUS figure tracking capacity − free − scanned (never a tile).
    private var lastFraction: Double?
    private var lastFilesProcessed = 0
    private var lastTotalInodes: Int64 = 0
    private var lastScanned: Int64 = 0
    private var lastCapacity: Int64 = 0
    private var lastFree: Int64 = 0
    private var maxDeniedTiles = 0
    private var lastUnaccounted: Int64 = 0
    private var deniedSamples: [String] = []
    private var lastProgressPrint = 0.0

    // OPERATOR_NOTE 2026-08-17 #1 (focus-path label commit-time check): after every dive/ascend the
    // bottom-bar breadcrumb must equal the controller's focus path SYNCHRONOUSLY — sampled here right
    // after the nav call, i.e. BEFORE any pipeline scene can arrive (scenes hop the actor on a later
    // runloop turn). If the label ever lags the focus stack, `pathLabelLagFailures` is non-zero.
    private var pathLabelSamples = 0
    private var pathLabelLagFailures = 0
    private var pathLabelFirstFailure: String?

    private var navTimer: Timer?
    private var capTimer: Timer?
    private var diving = true
    private let startNanos = DispatchTime.now().uptimeNanoseconds

    // TZ-4b rider 2(b) / review-1 finding 3: FOCUS-COMMIT-TO-SCENE build latency is measured
    // at the actor boundary inside ScanController (the wall time of the synchronous focus
    // force-emit) — faithful to BUILD time, unlike the lossy time a newest-1-coalesced scene
    // reaches main. We just read `controller.worstFocusEmitMs` / `focusEmitSamples` at the end.

    // TZ-4b: after this many seconds the harness stops the dive/ascend toggle and enters a
    // PROMOTION pass — repeated ascends, which from the scan root PROMOTE a level (home →
    // /Users → /). This exercises the real promotion camera + reducer graft + sibling walk
    // so the HitchMonitor measures the main-thread gap ACROSS a promotion (packet gate).
    private let promoteAfterSeconds: Double
    private var promoteSteps = 0
    // TZ-4b: the FIRST seconds are a DIVE-ONLY burst — build depth on the live tree so deep-
    // dive continuity (regression #4) is exercised and focus commit→scene latency (rider 2b)
    // is sampled BEFORE the promotion pass (whose ascend-at-root promotes instead of diving).
    private let diveBurstSeconds: Double

    init(root: URL, maxSeconds: Double) {
        self.root = root
        self.maxSeconds = maxSeconds
        self.promoteAfterSeconds = min(maxSeconds * 0.4, 6)
        self.diveBurstSeconds = min(maxSeconds * 0.2, 2.5)
        // Off-window surfaces: a CanvasView + StatusBar sized so drawableSize > 0.
        // NOTHING is added to a window; nothing is shown or activated (conduct rule).
        self.canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        self.statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: 1400, height: StatusBar.height))
        // TZ-5: NavigationController now takes the Ignore panel (off-window; nothing is shown).
        self.navigation = NavigationController(canvas: canvas, bottomBar: statusBar, ignorePanel: IgnorePanel())
    }

    private func elapsedSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1e9
    }

    func start() {
        controller = ScanController(
            root: root, policy: .default,
            onScene: { [weak self] scene in self?.observe(scene); self?.navigation.onScene(scene) },
            onStatus: { [weak self] status in self?.observeStatus(status) })
        navigation.scanController = controller
        controller.start()
        // Off-window there is no window event to trigger the drawable sizing, so force
        // it: setFrameSize runs CanvasView.updateDrawableSize → a non-zero drawableSize
        // → canvasViewportChanged posts the viewport, which the pipeline needs to emit.
        canvas.setFrameSize(NSSize(width: 1400, height: 900))
        navigation.pushViewport()

        // Drive dive/ascend on the REAL controller while the scan streams. 400 ms so a
        // ~350 ms camera flight completes before the next step (mid-animation steps are
        // debounced away — harmless). No synthetic input; a direct method call.
        let nav = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                if self.scenesAtFirstNav < 0 { self.scenesAtFirstNav = self.scenes }
                if self.elapsedSeconds() > self.promoteAfterSeconds {
                    // Promotion pass: ascend AT the scan root promotes a level (TZ-4b). The
                    // TZTRACE "promote X -> Y" lines (TERRAZZO_TRACE) show home → /Users → /.
                    self.navigation.ascend()
                    self.promoteSteps += 1
                } else if self.elapsedSeconds() < self.diveBurstSeconds {
                    // DIVE-ONLY burst: descend into the largest subtree each step, going deeper
                    // level by level (regression #4: dive beyond level 2 continues deeper,
                    // never restarts at top) and sampling the focus commit→scene latency.
                    self.navigation.driveNavigationStep(dive: true)
                } else {
                    self.navigation.driveNavigationStep(dive: self.diving)
                    self.diving.toggle()
                }
                self.focusPosts += 1
                // OPERATOR_NOTE #1 check: sample the breadcrumb SYNCHRONOUSLY, before any scene
                // arrives for this navigation. It must equal the controller's current focus path.
                self.pathLabelSamples += 1
                let labelPath = self.statusBar.focusPathValue
                let focusPath = self.navigation.currentFocusPath
                if labelPath != focusPath {
                    self.pathLabelLagFailures += 1
                    if self.pathLabelFirstFailure == nil {
                        self.pathLabelFirstFailure = "label='\(labelPath)' focus='\(focusPath)'"
                    }
                }
            }
        }
        RunLoop.main.add(nav, forMode: .common); navTimer = nav

        // Safety cap: end the run if the scan never completes within maxSeconds.
        let cap = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.elapsedSeconds() > self.maxSeconds { self.finish(reason: "time cap") }
            }
        }
        RunLoop.main.add(cap, forMode: .common); capTimer = cap
    }

    /// The one value handoff the app's main actor consumes — count it, check ordering,
    /// detect scan completion. O(1); never scales with node count.
    private func observe(_ scene: RenderScene) {
        scenes += 1
        lastScene = scene
        if scene.generation <= lastGen { monotonic = false }
        lastGen = scene.generation
        maxRenderedTiles = max(maxRenderedTiles, scene.tiles.count)
        maxCulled = max(maxCulled, scene.belowPixelCount)

        // Denied evidence, read off the viewport-bounded tile list (NOT a tree walk —
        // stays O(rendered), the law's bound). (The former synthetic UNACCOUNTED tile was
        // retracted — HUMAN FIELD RULING #1; the figure is a status-bar quantity now,
        // computed below from capacity − free − scanned, never a tile.)
        var denied = 0
        for t in scene.tiles {
            if t.kind == .denied {
                denied += 1
                // Sample a few denied paths — at root scale these are other users' homes.
                if deniedSamples.count < 6, !deniedSamples.contains(t.nodeId) {
                    deniedSamples.append(t.nodeId)
                }
            }
        }
        maxDeniedTiles = max(maxDeniedTiles, denied)
        lastScanned = scene.scannedBytes
        // The status-bar "Unaccounted" figure (capacity − free − scanned, clamped ≥ 0).
        lastUnaccounted = max(0, lastCapacity - lastFree - lastScanned)

        // Periodic progress/unaccounted trace so "the ratio advancing / the unaccounted
        // figure tracking capacity − free − scanned" is visible during the scan. `pct` is
        // "—" for a SUBTREE scan (no percentage — OPERATOR_NOTE #2 item 2), a real % once a
        // promotion reaches the volume root.
        let now = elapsedSeconds()
        if now - lastProgressPrint >= 2.0 {
            lastProgressPrint = now
            let pct = lastFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
            print("TZTRACE progress \(lastFilesProcessed)/\(lastTotalInodes) inodes (\(pct))  denied-tiles \(denied)  unaccounted \(lastUnaccounted) B  scanned \(lastScanned) B")
            fflush(stdout)
        }
        if !scene.running { finish(reason: "scan complete") }
    }

    /// Post-scan denied-node collector (evidence only; not on the measured hot path).
    private func collectDenied(_ node: SizeTree, into out: inout [String], cap: Int) {
        if out.count >= cap { return }
        if node.kind == .denied { out.append(node.id) }
        for c in node.children { collectDenied(c, into: &out, cap: cap) }
    }

    /// Capture the progress + volume figures the App would show (O(1)).
    private func observeStatus(_ status: ScanStatus) {
        lastFilesProcessed = status.filesProcessed
        lastTotalInodes = status.totalInodes
        lastFraction = status.progress.fraction
        if let v = status.volume {
            lastCapacity = v.capacityBytes
            lastFree = v.availableBytes
        }
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        running = false
        navTimer?.invalidate(); capTimer?.invalidate()
        let worst = controller.worstMainGapMs
        controller.cancel() // stops the hitch monitor (prints its own TZHITCH line)
        report(reason: reason, worstGapMs: worst)
        exit(0)
    }

    private func report(reason: String, worstGapMs: Double) {
        let flowed = scenesAtFirstNav >= 0 && scenes > scenesAtFirstNav
        print("TZTHREAD ==== threading evidence (real NavigationController, no window) ====")
        print("TZTHREAD root: \(root.path)")
        print("TZTHREAD ended: \(reason)  elapsed: \(String(format: "%.1f", elapsedSeconds())) s (cap \(Int(maxSeconds)) s)")
        print("TZTHREAD scenes: \(scenes)  generations monotonic: \(monotonic)  last gen: \(lastGen)")
        print("TZTHREAD max rendered tiles/scene (post-cull): \(maxRenderedTiles)  max sub-pixel culled/scene: \(maxCulled)")
        print("TZTHREAD dive/ascend posts during scan: \(focusPosts)  (scenes kept flowing across them: \(flowed ? "yes" : "n/a"))")
        print("TZTHREAD promotion ascends issued (home → /Users → / …): \(promoteSteps)  (see TZTRACE 'promote' lines)")
        print("TZTHREAD WORST MAIN-THREAD GAP (HitchMonitor): \(String(format: "%.1f", worstGapMs)) ms  (target < 100 ms)")
        let samples = controller.focusEmitSamples
        let latStr = samples > 0 ? String(format: "%.1f", controller.worstFocusEmitMs) : "—"
        print("TZTHREAD WORST FOCUS COMMIT→SCENE latency (queue+build): \(latStr) ms over \(samples) dive/ascend focus emits")
        print("TZTHREAD   ^ INCLUDES the worst case: this harness dives into the LARGEST folder AND ascends to the VOLUME ROOT while the scan streams — a root/near-root emit plus actor-queue wait behind active folds. Both were addressed in cycle 6 (OPERATOR_NOTE #3.1): (a) AREA-BOUNDED projection (ScanReducer.makeRenderTree) prunes sub-pixel subtrees BEFORE the canonical child sort, so even a volume-root emit is O(visible tiles), not O(all-in-window) — this cut the measured worst from ~1100 ms (the ~900 ms root makeTree the earlier build caught) to the number above; (b) QUEUE PRIORITY (ScenePipeline.foldWithPreemption chunks folds and yields) lets a focus emit overtake ingest. The ratified ≤200 ms commit→scene target (rider 2b / OPERATOR_NOTE #2/#3) now covers this live-scan worst, not just a small retained dive.")

        // TZ-4 acceptance evidence summary.
        let pct = lastFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        print("TZTHREAD TZ-4 progress: \(lastFilesProcessed)/\(lastTotalInodes) inodes stat'd (\(pct))")
        print("TZTHREAD TZ-4 denied tiles at root (max RENDERED in a scene): \(maxDeniedTiles)")
        if !deniedSamples.isEmpty {
            print("TZTHREAD TZ-4 rendered denied samples:")
            for p in deniedSamples { print("TZTHREAD     denied: \(p)") }
        }
        // Denied NODES in the last projected tree — a post-scan O(n) walk (NOT on the
        // measured hot path), so denials that are sub-pixel/CULLED (e.g. an empty
        // other-user home) are still surfaced honestly, not silently dropped.
        if let tree = lastScene?.tree {
            var deniedIds: [String] = []
            collectDenied(tree, into: &deniedIds, cap: 12)
            print("TZTHREAD TZ-4 denied NODES in tree (incl. culled sub-pixel): \(deniedIds.count)\(deniedIds.count == 12 ? "+" : "")")
            for p in deniedIds { print("TZTHREAD     denied-node: \(p)") }
        }
        // Unaccounted STATUS figure (never a tile — HUMAN FIELD RULING #1): capacity −
        // free − scanned, clamped ≥ 0 — the same math `UnaccountedSpace.figure`/StatusBar show.
        let expectedUnaccounted = max(0, lastCapacity - lastFree - lastScanned)
        print("TZTHREAD TZ-4 unaccounted figure: \(lastUnaccounted) B  (capacity \(lastCapacity) − free \(lastFree) − scanned \(lastScanned) = \(expectedUnaccounted) B)")

        // OPERATOR_NOTE #1: the focus-path breadcrumb must never lag the focus stack (sampled at
        // every dive/ascend commit, before any scene arrived).
        let pathOK = pathLabelLagFailures == 0
        print("TZTHREAD OPERATOR_NOTE#1 focus-path label at commit: \(pathLabelSamples) samples, "
              + "\(pathLabelLagFailures) lag failures \(pathOK ? "(label tracked focus synchronously — no lag)" : "(LAGGED: \(pathLabelFirstFailure ?? "?"))")")

        let pass = worstGapMs < 100 && monotonic && scenes > 0 && pathOK
        print("TZTHREAD verdict: \(pass ? "PASS" : "REVIEW")")
        fflush(stdout)
    }
}

// A `@main` entry (not top-level code): under swiftc's multi-file module the
// top-level slot belongs to the app's real main.swift, which this host replaces —
// so the entry is an explicit type. `main()` runs on the main thread; entering the
// main actor is sound there (same pattern as the app's main.swift).
@main
struct ThreadHost {
    static func main() {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            let rootPath = args.count > 1 ? args[1] : NSHomeDirectory()
            let maxSeconds = args.count > 2 ? (Double(args[2]) ?? 180) : 180
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)

            let app = NSApplication.shared
            // .prohibited: run the event loop with NO dock icon and NO foreground
            // activation — an event loop is not a window; nothing is raised or
            // activated (conduct rule).
            app.setActivationPolicy(.prohibited)

            let harness = ThreadHarness(root: root, maxSeconds: maxSeconds)
            harness.start()
            app.run()
        }
    }
}
