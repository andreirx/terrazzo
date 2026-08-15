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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
