// swift-tools-version:5.9
//
//  Package.swift — SPM manifest for the headless (testable) targets.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  Declares the targets `swift test` exercises. TWO are the pure, Foundation-only
//  cores (no AppKit/Metal/FileManager — CLAUDE.md hard constraint 1); ONE is the
//  I/O adapter that owns every syscall:
//    - ScanCore     — SizeTree (the crossing DTO both engines meet at) + the
//                     streaming event model, ScanReducer, and ScanPolicy (TZ-2).
//                     PURE.
//    - TreemapCore  — Squarify + TreemapScene (the visualization domain). PURE.
//    - ScanFS       — the parallel filesystem walker. NOT pure: ALL syscalls live
//                     here. Declared as a product so both `swift test` and the
//                     App's swiftc monolith compile the same walker sources.
//  Plus the test targets: ScanCoreTests, TreemapCoreTests (pure-core unit tests)
//  and FixtureFS (walker+reducer integration against a real temp directory tree).
//
//  The App render layer (Sources/App: AppKit + Metal) is deliberately NOT an SPM
//  target: it touches AppKit/Metal/QuartzCore and is compiled by scripts/build.sh
//  via `swiftc`, which pulls in the same TreemapCore + ScanCore + ScanFS sources.
//  SPM only sees the declared target paths, so Sources/App is invisible here — the
//  same swiftc-builds-the-outer-layer arrangement proven in glyph-saver.
//

import PackageDescription

let package = Package(
    name: "Terrazzo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .library(name: "TreemapCore", targets: ["TreemapCore"]),
        // ScanFS is the I/O adapter (not a pure core) — a product so the App's
        // swiftc monolith and `swift test` both compile the same walker sources.
        .library(name: "ScanFS", targets: ["ScanFS"]),
    ],
    targets: [
        .target(name: "ScanCore", path: "Sources/ScanCore"),
        .target(
            name: "TreemapCore",
            dependencies: ["ScanCore"],
            path: "Sources/TreemapCore"
        ),
        // The filesystem adapter: parallel walker + volume probe. ALL syscalls
        // live here (CLAUDE.md constraint 1). Depends on ScanCore for the event
        // model + policy it produces/reads.
        .target(
            name: "ScanFS",
            dependencies: ["ScanCore"],
            path: "Sources/ScanFS"
        ),
        .testTarget(
            name: "ScanCoreTests",
            dependencies: ["ScanCore"],
            path: "Tests/ScanCoreTests"
        ),
        .testTarget(
            name: "TreemapCoreTests",
            dependencies: ["TreemapCore", "ScanCore"],
            path: "Tests/TreemapCoreTests"
        ),
        // Integration: build a real temp directory tree and assert the
        // walker+reducer produce the golden SizeTree (packet deliverable 5).
        .testTarget(
            name: "FixtureFS",
            dependencies: ["ScanFS", "ScanCore"],
            path: "Tests/FixtureFS"
        ),
    ]
)
