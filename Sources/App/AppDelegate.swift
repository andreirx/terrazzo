//
//  AppDelegate.swift — window + menu shell for Terrazzo.app.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  A normal AppKit app (NOT a screensaver): a dark resizable window titled
//  "Terrazzo" hosting the CanvasView (the live navigable map, with on-canvas tile
//  labels + hover readout) above the StatusBar (focus path + volume accounting).
//  On launch it starts a live scan of the home directory; the map fills
//  progressively and — new in TZ-3 — is NAVIGABLE: hover tells, click/scroll
//  dives, Esc/⌘↑/scroll-out surfaces, ⌘R and right-click reveal in Finder.
//
//  This is the Main assembly: the ONLY place concrete volatile classes (NSWindow,
//  CanvasView, StatusBar, NavigationController, ScanController) are instantiated
//  and wired. The wiring is a straight line: ScanController owns the background
//  ScenePipeline and streams finished RenderScenes (onScene) → NavigationController
//  presents the pre-positioned tiles for the current focus → CanvasView renders;
//  CanvasView input → NavigationController → dive/ascend/reveal. NavigationController
//  posts focus/viewport back to ScanController → the pipeline (detail-on-demand and
//  off-main layout — TZ-3b threading model).
//

import AppKit
// Monolith-only App layer: SizeTree / ScanPolicy / VolumeProbe / FileSystemWalker
// resolve same-module (no core import).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var statusBar: StatusBar!
    private var controlBar: ControlBar!
    private var banner: FDABanner!
    private var ignorePanel: IgnorePanel!
    private var container: ChromeContainer!
    private var navigation: NavigationController!
    private var controller: ScanController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terrazzo"
        window.backgroundColor = .black
        // TZ-5 deliverable 5 (chrome color audit, DURABLE RULE). Force the window to the DARK
        // appearance so every AppKit control and semantic colour (labelColor, secondaryLabelColor,
        // standard buttons/steppers/segmented controls/popovers) resolves to its LIGHT-on-dark
        // variant. This is the root fix for the "near-black text on the dark bar" defect: on the
        // default (light) appearance an unstyled NSTextField's labelColor is near-black, invisible
        // on our custom dark chrome. Under .darkAqua the app-palette explicit colours still apply,
        // AND any semantic-coloured control is correct by construction — no per-control hardcoding.
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("TerrazzoMainWindow")
        window.center()

        // Chrome (top→bottom): ControlBar (volume picker + rescan + progress/ETA),
        // an optional FDA banner, the canvas, and the volume StatusBar. The
        // ChromeContainer lays these out explicitly because the banner appears/vanishes
        // and must re-flow the canvas — a dynamic vertical stack autoresizing masks
        // cannot express (see ChromeContainer).
        controlBar = ControlBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: ControlBar.height))
        banner = FDABanner(frame: NSRect(x: 0, y: 0, width: frame.width, height: FDABanner.height))
        statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: StatusBar.height))
        canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        ignorePanel = IgnorePanel()
        container = ChromeContainer(controlBar: controlBar, banner: banner, canvas: canvas,
                                    statusBar: statusBar, ignorePanel: ignorePanel)
        container.frame = frame
        container.autoresizingMask = [.width, .height]
        window.contentView = container

        // Navigation owns focus/camera/hover; wired to canvas + status bar + the Ignore panel.
        navigation = NavigationController(canvas: canvas, bottomBar: statusBar, ignorePanel: ignorePanel)
        canvas.escapeHandler = { [weak navigation] in navigation?.ascend() } // Esc → zoom out
        // Show/hide the (only-while-non-empty) Ignore panel as the set changes.
        navigation.onIgnoreChanged = { [weak self] in
            guard let self else { return }
            self.container.showsIgnorePanel = !self.ignorePanel.isEmpty
        }

        // TZ-4 chrome actions (Main-assembly wiring): rescan (toolbar + FDA banner) and
        // volume selection both funnel to the scan helpers below.
        controlBar.onRescan = { [weak self] in self?.rescanCurrentVolume() }
        banner.onRescan = { [weak self] in self?.rescanCurrentVolume() }
        controlBar.volumePicker.onSelect = { [weak self] descriptor in self?.scanVolume(descriptor.url) }
        // TZ-5 lens controls → ScanController → the background pipeline (off main).
        controlBar.onScaleChange = { [weak self] scale in self?.controller.setScale(scale) }
        controlBar.onHiddenChange = { [weak self] include in self?.controller.setIncludeHidden(include) }
        controlBar.onDepthChange = { [weak self] depth in self?.controller.setDepthWindow(depth) }

        // Menu is built AFTER `navigation` exists: buildMenu() bakes `navigation`
        // as the explicit target of the ⌘R / ⌘↑ items at install time, so it must
        // run once the object is non-nil (review-1 fix — nil target = dead menu
        // items that AppKit routes to a responder chain NavigationController is not
        // in).
        buildMenu()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas) // so keyDown (Esc) routes to the canvas
        NSApp.activate(ignoringOtherApps: true)

        startScan()
    }

    /// Start the live scan of the home directory. All filesystem access is inside
    /// ScanFS (VolumeProbe.homeDirectory / FileSystemWalker) — the App never
    /// touches the filesystem directly. Snapshots flow to NavigationController;
    /// status flows to the volume StatusBar; NavigationController holds the
    /// projection-depth knob back for detail-on-demand.
    ///
    /// TEST SEAM (TZ-3): if the env var `TERRAZZO_SCAN_ROOT` names a directory, scan
    /// THAT instead of the home directory. This is a Main-assembly override of ONE
    /// value — WHICH root URL to hand the walker — not a new abstraction and not a
    /// filesystem access (reading a process-env string is a value read; the URL is a
    /// value; every syscall still happens inside ScanFS's walker). It exists because
    /// end-to-end interaction evidence (hover → dive → ascend → reveal) needs a scan
    /// that COMPLETES to a stable map, and a live ~1 TB home scan does not settle in
    /// a screenshot-able window (it saturates the main-actor reducer). Unset in
    /// normal use → unchanged home-scan behavior. Rejected simpler alternative:
    /// none — there is no cheaper way to drive the real AppKit input path against a
    /// stable scan without either this override or waiting out a full disk walk.
    private func startScan() {
        let env = ProcessInfo.processInfo.environment["TERRAZZO_SCAN_ROOT"]
        let root: URL = (env?.isEmpty == false)
            ? URL(fileURLWithPath: env!, isDirectory: true)
            : VolumeProbe.homeDirectory()
        controller = ScanController(
            root: root, policy: .default,
            onScene: { [weak self] scene in self?.navigation.onScene(scene) },
            onStatus: { [weak self] status in
                self?.statusBar.update(status)
                self?.controlBar.update(status.progress) // progress bar + ETA (TZ-4 D4)
            }
        )
        navigation.scanController = controller
        controller.start()
        // The pipeline cannot lay out until it knows the viewport. The initial
        // viewport-change (viewDidMoveToWindow) fired BEFORE `scanController` was
        // wired, so post the current viewport now that the wiring exists — otherwise
        // no scene is ever emitted and the canvas stays black.
        navigation.pushViewport()
        updateChromeForScan(root: root)
    }

    // MARK: - TZ-4 scan actions (VolumePicker / Rescan)

    /// Scan a chosen volume's root (VolumePicker, D2). Resets the map + progress sampling
    /// so the new volume starts clean, then streams as always.
    private func scanVolume(_ url: URL) {
        controlBar.resetProgressSampling()
        navigation.resetForNewScan()
        controller.scan(root: url)
        navigation.pushViewport()
        updateChromeForScan(root: url)
    }

    /// Rescan the CURRENT volume (Rescan button / FDA banner, D3). The map is a snapshot
    /// of scan time; rescan re-runs it (e.g. after granting Full Disk Access).
    private func rescanCurrentVolume() {
        let root = controller.root
        controlBar.resetProgressSampling()
        navigation.resetForNewScan()
        controller.rescan()
        navigation.pushViewport()
        updateChromeForScan(root: root)
    }

    /// Refresh the volume picker selection and decide whether the FDA banner is warranted
    /// for `root` (D2/D5). All volume enumeration + the FDA probe live in ScanFS
    /// (CLAUDE.md constraint 1); this is one-time work at scan start, not node-count work.
    private func updateChromeForScan(root: URL) {
        let volumes = VolumeEnumerator.selectableVolumes()
        let volumePaths = Set(volumes.map { $0.url.path })
        // If the scan root is a volume root, select it; otherwise (e.g. the ~ first-paint
        // scan) select the boot volume the home directory lives on.
        let selected = volumePaths.contains(root.path) ? root.path : "/"
        controlBar.volumePicker.setVolumes(volumes, selectedPath: selected)
        // FDA banner ONLY when mapping a whole volume AND a protected probe path is denied
        // — never for a sub-folder scan, and never blocking (D5).
        let isVolumeRoot = VolumeSkipPolicy.isVolumeRoot(path: root.path, volumePaths: volumePaths)
        container.showsBanner = isVolumeRoot && FDAProbe.probe() == .denied
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.cancel()
    }

    /// App menu (Quit) + a Navigate menu carrying the two keyboard actions that
    /// target NavigationController directly: ⌘R reveal-hovered, ⌘↑ zoom out. Esc
    /// (zoom out) is handled directly in CanvasView.keyDown → escapeHandler.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Terrazzo", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let navItem = NSMenuItem()
        mainMenu.addItem(navItem)
        let navMenu = NSMenu(title: "Navigate")
        navItem.submenu = navMenu

        let reveal = navMenu.addItem(withTitle: "Reveal Hovered in Finder",
                                     action: #selector(NavigationController.revealHovered),
                                     keyEquivalent: "r")
        reveal.target = navigation

        let zoomOut = navMenu.addItem(withTitle: "Zoom Out",
                                      action: #selector(NavigationController.zoomOut),
                                      keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        zoomOut.keyEquivalentModifierMask = .command
        zoomOut.target = navigation

        NSApp.mainMenu = mainMenu
    }
}

/// The window's content view: lays out the TZ-4 chrome top→bottom — ControlBar, an
/// optional FDA banner, the canvas (fills the remainder), and the StatusBar. Explicit
/// layout (not autoresizing masks) because the banner appears/disappears and must
/// re-flow the canvas height; a fixed autoresizing stack cannot express a member that
/// toggles between zero and its height.
///
/// ABSTRACTION LEDGER: one concrete view, one user (AppDelegate). Axis of variation: the
/// FDA banner's dynamic presence re-flows the canvas — a real layout need, not imagined.
/// Rejected simpler alternative — autoresizing masks on plain subviews — cannot collapse
/// the banner's row and re-give its height to the canvas without exactly this custom
/// layout; a stack view (NSStackView) is heavier machinery for a four-item fixed column.
@MainActor
final class ChromeContainer: NSView {
    private let controlBar: ControlBar
    private let banner: FDABanner
    private let canvas: CanvasView
    private let statusBar: StatusBar
    /// The Ignore list (TZ-5 deliverable 1) — FLOATS at the top-right of the canvas region, over
    /// the map (not re-flowing it), shown only while non-empty. Positioned here, filled by
    /// NavigationController.
    private let ignorePanel: IgnorePanel

    /// Whether the FDA banner is shown (D5). Toggling re-flows the canvas.
    var showsBanner = false {
        didSet {
            guard showsBanner != oldValue else { return }
            banner.isHidden = !showsBanner
            relayout()
        }
    }

    /// Whether the Ignore panel is shown (TZ-5) — set by AppDelegate from the panel's non-empty
    /// state. It FLOATS over the canvas, so toggling repositions it without re-flowing the map.
    var showsIgnorePanel = false {
        didSet {
            guard showsIgnorePanel != oldValue else { return }
            ignorePanel.isHidden = !showsIgnorePanel
            relayout()
        }
    }

    init(controlBar: ControlBar, banner: FDABanner, canvas: CanvasView, statusBar: StatusBar,
         ignorePanel: IgnorePanel) {
        self.controlBar = controlBar
        self.banner = banner
        self.canvas = canvas
        self.statusBar = statusBar
        self.ignorePanel = ignorePanel
        super.init(frame: .zero)
        wantsLayer = true
        banner.isHidden = true
        ignorePanel.isHidden = true
        addSubview(controlBar)
        addSubview(banner)
        addSubview(canvas)
        addSubview(statusBar)
        addSubview(ignorePanel) // on top of the canvas
    }

    required init?(coder: NSCoder) { fatalError("ChromeContainer is code-only") }

    /// Top-left origin so the vertical stack reads top→bottom in frame math.
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        let w = bounds.width, h = bounds.height
        let ctrlH = ControlBar.height, statusH = StatusBar.height, bannerH = FDABanner.height
        controlBar.frame = NSRect(x: 0, y: 0, width: w, height: ctrlH)
        var top = ctrlH
        if showsBanner {
            banner.frame = NSRect(x: 0, y: top, width: w, height: bannerH)
            top += bannerH
        }
        let canvasHeight = max(0, h - top - statusH)
        canvas.frame = NSRect(x: 0, y: top, width: w, height: canvasHeight)
        statusBar.frame = NSRect(x: 0, y: h - statusH, width: w, height: statusH)

        // Float the Ignore panel at the TOP-RIGHT of the canvas region, sized to its content
        // (clamped to the canvas height), so it covers as little of the map as possible.
        if showsIgnorePanel {
            let margin: CGFloat = 10
            let pw = IgnorePanel.width
            let ph = min(ignorePanel.contentHeight(), max(0, canvasHeight - 2 * margin))
            // isFlipped == true here (top-left origin), so y grows downward from the canvas top.
            ignorePanel.frame = NSRect(x: w - pw - margin, y: top + margin, width: pw, height: ph)
        }
    }
}
