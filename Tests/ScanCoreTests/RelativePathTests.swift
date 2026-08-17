//
//  RelativePathTests.swift — the pure id-relative-to-base transform (TZ-10 items 1 + 4).
//  Module maturity: PROTOTYPE (slice TZ-10)
//

import XCTest
@testable import ScanCore

final class RelativePathTests: XCTestCase {
    /// Relative to the current viewport folder (item 4): a deep descendant yields the multi-
    /// component remainder; the topmost visible ancestor (a direct child of the focus) yields
    /// just its own name.
    func testRelativeToViewportFolder() {
        XCTAssertEqual(RelativePath.of("/Users/apple/Library/Caches", under: "/Users/apple"),
                       "Library/Caches")
        XCTAssertEqual(RelativePath.of("/Users/apple/Library", under: "/Users/apple"),
                       "Library", "the topmost visible ancestor is just its name")
    }

    /// Relative to the volume root (item 1). The boot volume's root is "/", so the single leading
    /// slash is dropped; a non-boot volume mounted at /Volumes/Data strips that mount prefix.
    func testRelativeToVolumeRoot() {
        XCTAssertEqual(RelativePath.of("/Users/apple/Movies", under: "/"), "Users/apple/Movies")
        XCTAssertEqual(RelativePath.of("/Volumes/Data/media/a.mov", under: "/Volumes/Data"),
                       "media/a.mov")
    }

    /// The base ITSELF maps to ".", and an id that is NOT under the base falls back to the id
    /// UNCHANGED — never a misleading relative path pretending the id lives under the base.
    func testBaseItselfAndNonDescendantFallback() {
        XCTAssertEqual(RelativePath.of("/Users/apple", under: "/Users/apple"), ".")
        XCTAssertEqual(RelativePath.of("/Applications/Foo.app", under: "/Users/apple"),
                       "/Applications/Foo.app", "not under the base → absolute fallback")
    }

    /// Boundary-checked on the separator: `/Users` is NOT a base of `/UsersFoo` (a sibling whose
    /// name merely shares a prefix), so it falls back to the unchanged id.
    func testBoundaryCheckedOnSeparator() {
        XCTAssertEqual(RelativePath.of("/UsersFoo/x", under: "/Users"), "/UsersFoo/x")
    }
}
