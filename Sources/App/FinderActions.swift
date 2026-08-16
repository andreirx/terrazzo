//
//  FinderActions.swift — the one escape hatch: reveal a tile in Finder.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  VISION §"What it is NOT": Terrazzo is not a cleaner — "Open in Finder is the
//  action escape hatch". Every tile can be revealed, INCLUDING `.app` leaves and
//  DENIED tiles (a denied directory still has a path; revealing it in Finder is
//  exactly how the user goes to grant access or inspect it). So this takes a raw
//  path string and never inspects kind.
//
//  WHY A PATH IS ENOUGH: the walker sets every node's id to its ABSOLUTE PATH
//  (FileSystemWalker header contract; live-scan ids are the scan-root path joined
//  with each node's name — an absolute path that Finder resolves even when a
//  firmlink alias is in play). So the App reveals `URL(fileURLWithPath:
//  tile.nodeId)` directly — no path reconstruction, no tree walk. (Under the JSON
//  fixture, ids are synthetic and
//  not real paths; reveal is a live-app action, not exercised by the fixture
//  gates — noted, not silently assumed.)
//
//  ABSTRACTION LEDGER: a namespace of one pure-ish function wrapping one
//  NSWorkspace call. One concrete user (NavigationController's right-click / ⌘R).
//  No protocol — there is one Finder, one reveal verb.
//
//  BOUNDARY (CLAUDE.md constraint 1, reviewer TZ-3 rev-0): the App layer does NO
//  filesystem probing — all syscalls live in ScanFS. So this does NOT call
//  FileManager to pre-check existence; it hands the URL straight to NSWorkspace,
//  which is itself the OS actor that resolves (or harmlessly no-ops on) a path.
//  A path that vanished between scan and reveal simply reveals nothing — Finder,
//  not this App, owns that outcome. No App-side stat, no boundary violation.
//

import AppKit

enum FinderActions {
    /// Reveal `path` in Finder (selecting it in its enclosing folder). Delegates
    /// entirely to `NSWorkspace` — the OS file-viewer actor — with no App-layer
    /// filesystem access (the ScanFS/App boundary; reviewer TZ-3 rev-0).
    @MainActor
    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
