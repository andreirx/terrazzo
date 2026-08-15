// swift-tools-version:5.9
//
//  Package.swift — SPM manifest for the two PURE cores ONLY.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  Declares the two headless, Foundation-only cores that `swift test` exercises:
//    - ScanCore     — in TZ-1 this contains ONLY SizeTree.swift, the crossing
//                     DTO both engines meet at (CLAUDE.md hard constraint 1).
//                     The reducer / events / policy arrive in TZ-2.
//    - TreemapCore  — Squarify + TreemapScene (the visualization domain).
//
//  The App render layer (Sources/App: AppKit + Metal) is deliberately NOT an SPM
//  target: it touches AppKit/Metal/QuartzCore and is compiled by scripts/build.sh
//  via `swiftc`, which pulls in the same TreemapCore + ScanCore sources. SPM only
//  sees the declared target paths, so Sources/App is invisible here — the same
//  swiftc-builds-the-outer-layer arrangement proven in glyph-saver.
//

import PackageDescription

let package = Package(
    name: "Terrazzo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .library(name: "TreemapCore", targets: ["TreemapCore"]),
    ],
    targets: [
        .target(name: "ScanCore", path: "Sources/ScanCore"),
        .target(
            name: "TreemapCore",
            dependencies: ["ScanCore"],
            path: "Sources/TreemapCore"
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
    ]
)
