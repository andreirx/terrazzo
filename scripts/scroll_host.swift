//
//  scroll_host.swift — scroll-to-zoom regression check (TZ-10 OPERATOR_NOTE 2026-08-17 C).
//  Module maturity: PROTOTYPE (slice TZ-10)
//
//  THE FIELD BUG (OPERATOR_NOTE C, verified-failing on 10f83b4): "scrolling no longer zooms."
//  This host is the "headless scroll-accumulation path" the note asks for: it drives the REAL
//  NavigationController.canvasDidScroll — with NOTCH (non-precise) and TRACKPAD (precise) deltas —
//  over a REAL directory scan, WITHOUT a window and WITHOUT synthetic OS input (CLAUDE.md builder
//  conduct rule). It asserts, from the focus-path state alone, that:
//    • a scroll-IN (positive delta ≥ the step) DIVES  — the focus path grows one level deeper;
//    • a scroll-OUT (negative delta ≤ −step) ASCENDS  — the focus path shrinks one level.
//  Both the one-notch case (wheelStepUnits = 1) and the accumulate-past-threshold trackpad case
//  (trackpadStepUnits = 40, reached by several sub-threshold precise deltas) are exercised, so a
//  regression in the accumulator, the delta sign, or the dive/ascend post is caught deterministically.
//
//  WHY THIS IS the reproduction path AND the permanent guard: the scroll→dive→ascend logic lives
//  entirely in NavigationController (accumulate deltaY, threshold, HitTest.topLevelUnderFocus →
//  dive / ascend). Driving canvasDidScroll directly exercises exactly that logic without needing the
//  AppKit event-delivery layer (which the conduct rule forbids us to synthesize). If the accumulation
//  or the posts ever break, TZSCROLL verdict flips to FAIL.
//
//  Compiled by scripts/scroll.sh with the same App-navigation monolith as thread_host.
//  Usage: scroll_host [rootDir] [maxSeconds]   (defaults: repo Sources, 30)
//

import AppKit

@MainActor
final class ScrollHarness {
    private let root: URL
    private let maxSeconds: Double

    private let canvas: CanvasView
    private let statusBar: StatusBar
    private let navigation: NavigationController
    private var controller: ScanController!

    private var lastScene: RenderScene?
    private var scenes = 0
    private let startNanos = DispatchTime.now().uptimeNanoseconds
    private var pollTimer: Timer?
    private var finished = false

    // The step machine. Each step drives one scroll gesture then waits out the camera flight
    // (≈0.35 s) before reading the resulting focus path.
    private enum Step { case settle, notchIn, notchOut, preciseIn, preciseOut, done }
    private var step: Step = .settle
    private var stepStart = 0.0

    // Recorded focus paths across the gestures — the evidence.
    private var focusBeforeNotchIn = ""
    private var focusAfterNotchIn = ""
    private var focusAfterNotchOut = ""
    private var focusBeforePreciseIn = ""
    private var focusAfterPreciseIn = ""
    private var focusAfterPreciseOut = ""
    private var notchInDived: Bool?
    private var notchOutAscended: Bool?
    private var preciseInDived: Bool?
    private var preciseOutAscended: Bool?
    private var probeFailure: String?

    init(root: URL, maxSeconds: Double) {
        self.root = root
        self.maxSeconds = maxSeconds
        // Off-window surfaces sized so drawableSize > 0 (nothing is shown or activated — conduct rule).
        self.canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        self.statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: 1400, height: StatusBar.height))
        self.navigation = NavigationController(canvas: canvas, bottomBar: statusBar,
                                               watchlistPanel: WatchlistPanel())
    }

    private func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1e9 }

    func start() {
        controller = ScanController(
            root: root, policy: .default,
            onScene: { [weak self] scene in
                guard let self else { return }
                self.scenes += 1
                self.lastScene = scene
                self.navigation.onScene(scene)
            },
            onStatus: { _ in })
        navigation.scanController = controller
        controller.start()
        // Off-window there is no window event to size the drawable; force it so the pipeline emits.
        canvas.setFrameSize(NSSize(width: 1400, height: 900))
        navigation.pushViewport()

        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
    }

    /// The largest dimLevel-1 DIRECTORY tile in the current scene — the dive target under the cursor.
    /// A dir (not a file/denied) so the dive has children to reveal; the largest so its center is a
    /// safe interior hit point.
    private func probeTile() -> TileRect? {
        lastScene?.tiles
            .filter { $0.dimLevel == 1 && $0.kind == .dir }
            .max { $0.rect.area < $1.rect.area }
    }

    private func center(of t: TileRect) -> Point {
        Point(x: t.rect.x + t.rect.width / 2, y: t.rect.y + t.rect.height / 2)
    }

    /// Space each gesture so the ≈0.35 s camera flight completes before the next read.
    private static let stepGap = 0.7

    private func tick() {
        if elapsed() > maxSeconds {
            probeFailure = probeFailure ?? "timed out before the scroll sequence completed (step \(step))"
            finish(); return
        }
        // The poll only kicks off the sequence once a stable root scene with a dimLevel-1 dir tile
        // exists; every gesture after that is driven by the scheduled per-step timers.
        if step == .settle, scenes >= 1, elapsed() > 1.0, probeTile() != nil {
            advance(.notchIn)
        }
    }

    /// Move to a step, firing its gesture on entry, and schedule the follow-up read.
    private func advance(_ next: Step) {
        step = next
        stepStart = elapsed()
        switch next {
        case .settle: break
        case .notchIn:
            guard let t = probeTile() else { probeFailure = "no dimLevel-1 dir tile to scroll into"; finish(); return }
            focusBeforeNotchIn = navigation.currentFocusPath
            // ONE notch: non-precise, |delta| ≥ wheelStepUnits (1) → one dive step.
            navigation.canvasDidScroll(deltaY: 2, precise: false, atPx: center(of: t))
            schedule { self.readNotchIn() }
        case .notchOut:
            // ONE notch out: non-precise negative → ascend.
            navigation.canvasDidScroll(deltaY: -2, precise: false, atPx: Point(x: 10, y: 10))
            schedule { self.readNotchOut() }
        case .preciseIn:
            guard let t = probeTile() else { probeFailure = "no dimLevel-1 dir tile for the precise probe"; finish(); return }
            focusBeforePreciseIn = navigation.currentFocusPath
            let c = center(of: t)
            // TRACKPAD: several sub-threshold precise deltas accumulate past trackpadStepUnits (40).
            // 9 × 5 = 45 ≥ 40 → exactly one dive (the accumulator must sum, not reset, between events).
            for _ in 0..<5 { navigation.canvasDidScroll(deltaY: 9, precise: true, atPx: c) }
            schedule { self.readPreciseIn() }
        case .preciseOut:
            // TRACKPAD out: one precise delta past −threshold → ascend.
            navigation.canvasDidScroll(deltaY: -45, precise: true, atPx: Point(x: 10, y: 10))
            schedule { self.readPreciseOut() }
        case .done:
            finish()
        }
    }

    private func sinceStep() -> Double { elapsed() - stepStart }

    /// Run `body` after the camera flight settles (one-shot timer).
    private func schedule(_ body: @escaping () -> Void) {
        let t = Timer(timeInterval: Self.stepGap, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func readNotchIn() {
        focusAfterNotchIn = navigation.currentFocusPath
        notchInDived = deeper(focusAfterNotchIn, than: focusBeforeNotchIn)
        advance(.notchOut)
    }
    private func readNotchOut() {
        focusAfterNotchOut = navigation.currentFocusPath
        notchOutAscended = shallower(focusAfterNotchOut, than: focusAfterNotchIn)
        advance(.preciseIn)
    }
    private func readPreciseIn() {
        focusAfterPreciseIn = navigation.currentFocusPath
        preciseInDived = deeper(focusAfterPreciseIn, than: focusBeforePreciseIn)
        advance(.preciseOut)
    }
    private func readPreciseOut() {
        focusAfterPreciseOut = navigation.currentFocusPath
        preciseOutAscended = shallower(focusAfterPreciseOut, than: focusAfterPreciseIn)
        advance(.done)
    }

    /// A dive grows the focus path one level: `child` is strictly under `parent` (id-is-a-path).
    private func deeper(_ child: String, than parent: String) -> Bool {
        child != parent && child.hasPrefix(parent) && child.count > parent.count
    }
    /// An ascend shrinks the focus path: the new focus is a strict prefix (ancestor) of the old.
    private func shallower(_ parent: String, than child: String) -> Bool {
        parent != child && child.hasPrefix(parent) && parent.count < child.count
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        controller?.cancel()
        report()
        exit(passed() ? 0 : 1)
    }

    private func passed() -> Bool {
        probeFailure == nil
            && notchInDived == true && notchOutAscended == true
            && preciseInDived == true && preciseOutAscended == true
    }

    private func report() {
        print("TZSCROLL ==== scroll-to-zoom regression check (real NavigationController, no window) ====")
        print("TZSCROLL root: \(root.path)   scenes: \(scenes)   elapsed: \(String(format: "%.1f", elapsed())) s")
        if let f = probeFailure { print("TZSCROLL PROBE FAILURE: \(f)") }
        func line(_ name: String, _ ok: Bool?, _ from: String, _ to: String) {
            let mark = ok == true ? "PASS" : (ok == nil ? "n/a " : "FAIL")
            print("TZSCROLL [\(mark)] \(name): '\(short(from))' -> '\(short(to))'")
        }
        line("scroll-IN dives   (notch,    step 1) ", notchInDived, focusBeforeNotchIn, focusAfterNotchIn)
        line("scroll-OUT ascends (notch,    step 1) ", notchOutAscended, focusAfterNotchIn, focusAfterNotchOut)
        line("scroll-IN dives   (trackpad, sum≥40) ", preciseInDived, focusBeforePreciseIn, focusAfterPreciseIn)
        line("scroll-OUT ascends (trackpad, ≤−40)  ", preciseOutAscended, focusAfterPreciseIn, focusAfterPreciseOut)
        print("TZSCROLL verdict: \(passed() ? "PASS — scroll-in dives, scroll-out ascends" : "FAIL")")
        fflush(stdout)
    }

    private func short(_ p: String) -> String { p.isEmpty ? "<root>" : (p as NSString).lastPathComponent }
}

// Explicit @main type (the app's real main.swift owns the top-level slot in the monolith).
@main
struct ScrollHost {
    static func main() {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            let rootPath = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath + "/Sources"
            let maxSeconds = args.count > 2 ? (Double(args[2]) ?? 30) : 30
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)

            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited) // event loop, no dock icon, no activation (conduct rule)

            let harness = ScrollHarness(root: root, maxSeconds: maxSeconds)
            harness.start()
            app.run()
        }
    }
}
