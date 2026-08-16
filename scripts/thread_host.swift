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
    //   - the unaccounted synthetic tile tracking capacity − free − scanned.
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

    private var navTimer: Timer?
    private var capTimer: Timer?
    private var diving = true
    private let startNanos = DispatchTime.now().uptimeNanoseconds

    init(root: URL, maxSeconds: Double) {
        self.root = root
        self.maxSeconds = maxSeconds
        // Off-window surfaces: a CanvasView + StatusBar sized so drawableSize > 0.
        // NOTHING is added to a window; nothing is shown or activated (conduct rule).
        self.canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        self.statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: 1400, height: StatusBar.height))
        self.navigation = NavigationController(canvas: canvas, bottomBar: statusBar)
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
                self.navigation.driveNavigationStep(dive: self.diving)
                self.focusPosts += 1
                self.diving.toggle()
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

        // Denied + synthetic evidence, read off the viewport-bounded tile list (NOT a
        // tree walk — stays O(rendered), the law's bound).
        var denied = 0
        for t in scene.tiles {
            if t.kind == .denied {
                denied += 1
                // Sample a few denied paths — at root scale these are other users' homes.
                if deniedSamples.count < 6, !deniedSamples.contains(t.nodeId) {
                    deniedSamples.append(t.nodeId)
                }
            } else if t.kind == .synthetic {
                lastUnaccounted = t.allocatedBytes
            }
        }
        maxDeniedTiles = max(maxDeniedTiles, denied)
        lastScanned = scene.scannedBytes

        // Periodic progress/unaccounted trace so "the ratio advancing / the unaccounted
        // tile tracking capacity − free − scanned" is visible during the scan.
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
        print("TZTHREAD WORST MAIN-THREAD GAP (HitchMonitor): \(String(format: "%.1f", worstGapMs)) ms  (target < 100 ms)")

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
        // Unaccounted should track capacity − free − scanned (clamped ≥ 0).
        let expectedUnaccounted = max(0, lastCapacity - lastFree - lastScanned)
        print("TZTHREAD TZ-4 unaccounted tile: \(lastUnaccounted) B  (capacity \(lastCapacity) − free \(lastFree) − scanned \(lastScanned) = \(expectedUnaccounted) B)")

        let pass = worstGapMs < 100 && monotonic && scenes > 0
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
