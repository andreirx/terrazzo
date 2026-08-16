//
//  AppDelegate.swift — window + menu shell for Terrazzo.app.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  A normal AppKit app (NOT a screensaver): a dark resizable window titled
//  "Terrazzo" hosting the CanvasView with a StatusBar strip along the bottom, a
//  minimal Quit menu, and — new in TZ-2 — a LIVE scan. On launch it starts a
//  ScanController over the user's home directory (VolumeProbe.homeDirectory);
//  the map fills progressively as the walker streams events (TZ-1's static
//  fixture is gone — the App no longer decodes fixture-tree.json).
//
//  This is the Main assembly: the ONLY place concrete volatile classes (NSWindow,
//  CanvasView, StatusBar, ScanController) are instantiated and wired.
//

import AppKit
// Monolith-only App layer: SizeTree / ScanPolicy / VolumeProbe / FileSystemWalker
// resolve same-module (no core import).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var statusBar: StatusBar!
    private var controller: ScanController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

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

        let h = StatusBar.height
        statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: h))
        statusBar.autoresizingMask = [.width]

        canvas = CanvasView(frame: NSRect(x: 0, y: h, width: frame.width, height: frame.height - h))
        canvas.autoresizingMask = [.width, .height]

        container.addSubview(canvas)
        container.addSubview(statusBar)
        window.contentView = container

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        startScan()
    }

    /// Start the live scan of the home directory. All filesystem access is inside
    /// ScanFS (VolumeProbe.homeDirectory / FileSystemWalker) — the App never
    /// touches the filesystem directly.
    private func startScan() {
        let root = VolumeProbe.homeDirectory()
        controller = ScanController(root: root, policy: .default, canvas: canvas) { [weak self] status in
            self?.statusBar.update(status)
        }
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.cancel()
    }

    /// Minimal menu: an app menu carrying the standard Quit item (⌘Q).
    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Terrazzo", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
    }
}
