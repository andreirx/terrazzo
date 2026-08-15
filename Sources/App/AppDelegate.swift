//
//  AppDelegate.swift — window + menu shell for Terrazzo.app.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  A normal AppKit app (NOT a screensaver, NOT a .saver bundle): builds a dark,
//  resizable window titled "Terrazzo" hosting the CanvasView, a minimal menu
//  with Quit, loads the bundled fixture SizeTree, and hands it to the canvas.
//  This is the ONLY place concrete volatile classes (NSWindow, CanvasView) are
//  instantiated — the Main-assembly role.
//

import AppKit
// Monolith-only App layer: SizeTree resolves same-module (no core import).

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var canvas: CanvasView!

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

        canvas = CanvasView(frame: frame)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas

        if let tree = loadFixtureTree() {
            canvas.setTree(tree)
        } else {
            NSLog("AppDelegate: fixture tree failed to load — canvas will be blank")
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Load the bundled fixture SizeTree via ScanCore's Codable conformance. No
    /// filesystem SCANNING here — this is a static JSON resource decode, the only
    /// data source in TZ-1 (TZ-2 replaces it with the live scanner stream).
    private func loadFixtureTree() -> SizeTree? {
        guard let url = Bundle.main.url(forResource: "fixture-tree", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            NSLog("AppDelegate: fixture-tree.json missing from bundle Resources")
            return nil
        }
        do {
            return try JSONDecoder().decode(SizeTree.self, from: data)
        } catch {
            NSLog("AppDelegate: fixture decode failed: \(error)")
            return nil
        }
    }

    /// Minimal menu: an app menu carrying the standard Quit item (⌘Q). Without a
    /// storyboard/NIB we must build the menu bar in code.
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
