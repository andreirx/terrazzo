//
//  ScanPolicyTests.swift — the ratified policy constants + bundle-leaf rule.
//  Module maturity: PROTOTYPE (slice TZ-2)
//

import XCTest
@testable import ScanCore

final class ScanPolicyTests: XCTestCase {
    func testDefaultsMatchRatifiedDecisions() {
        let p = ScanPolicy.default
        XCTAssertEqual(p.depthDetailWindow, 5, "default depth window is 5 (VISION §Experience 2)")
        // "hidden always included" and "symlinks never followed" are NOT policy
        // fields — they are structural walker invariants (review-1 point 2), so
        // there is no configurable boolean to assert here. Their enforcement is
        // proven end-to-end in FixtureFS (`.hidden` present; `link` a leaf).
    }

    func testOnlyDotAppIsABundleLeafInV1() {
        let p = ScanPolicy.default
        XCTAssertTrue(p.isBundleLeaf(name: "Safari.app"))
        // Other bundle types scan through as ordinary dirs in v1 (recorded TD).
        XCTAssertFalse(p.isBundleLeaf(name: "Foo.framework"))
        XCTAssertFalse(p.isBundleLeaf(name: "Photos.photoslibrary"))
        XCTAssertFalse(p.isBundleLeaf(name: "notes.rtfd"))
        XCTAssertFalse(p.isBundleLeaf(name: "plain-dir"))
    }
}
