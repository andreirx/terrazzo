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
//  and wired. The wiring is a straight line: ScanController streams SizeTree
//  snapshots (onSnapshot) → NavigationController lays out for the current focus →
//  CanvasView renders; CanvasView input → NavigationController → dive/ascend/
//  reveal. NavigationController holds the projection-depth knob back to
//  ScanController for detail-on-demand.
//

import AppKit
// Monolith-only App layer: SizeTree / ScanPolicy / VolumeProbe / FileSystemWalker
// resolve same-module (no core import).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var statusBar: StatusBar!
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
        window.setFrameAutosaveName("TerrazzoMainWindow")
        window.center()

        // Container: canvas fills above a fixed-height status strip at the bottom.
        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]

        let sh = StatusBar.height
        statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: sh))
        statusBar.autoresizingMask = [.width]

        canvas = CanvasView(frame: NSRect(x: 0, y: sh, width: frame.width, height: frame.height - sh))
        canvas.autoresizingMask = [.width, .height]

        container.addSubview(canvas)
        container.addSubview(statusBar)
        window.contentView = container

        // Navigation owns focus/camera/hover; wired to canvas + status bar.
        navigation = NavigationController(canvas: canvas, bottomBar: statusBar)
        canvas.escapeHandler = { [weak navigation] in navigation?.ascend() } // Esc → zoom out

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
            onSnapshot: { [weak self] tree in self?.navigation.onSnapshot(tree) },
            onStatus: { [weak self] status in self?.statusBar.update(status) }
        )
        navigation.scanController = controller
        controller.start()
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
