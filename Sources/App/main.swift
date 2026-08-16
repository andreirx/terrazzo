//
//  main.swift — NSApplication entry point (no storyboard, no @NSApplicationMain).
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  Explicit top-level startup so the app is a plain swiftc-built executable
//  (build.sh), no NIB/storyboard machinery. `.regular` activation policy gives a
//  Dock icon + menu bar (a normal app window that survives input — unlike a
//  screensaver, PLAN.md).
//

import AppKit

// Top-level code is nonisolated, but it runs on the main thread — enter the main
// actor explicitly so we can construct the @MainActor AppDelegate (the UI object)
// without hopping. `assumeIsolated` is sound here precisely because startup IS on
// the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    // `delegate` is retained for the whole process: NSApp.delegate is weak, but
    // app.run() blocks inside this closure until termination, so this local frame
    // (and its strong `delegate`) lives for the process lifetime.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
