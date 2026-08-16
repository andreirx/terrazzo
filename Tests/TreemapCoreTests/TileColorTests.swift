//
//  TileColorTests.swift — deterministic, well-spread per-folder hues (packet 5b).
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  Pins the two ratified properties: SAME name → SAME hue (stable across
//  processes — the whole point of not using Swift's seeded Hasher), and DISTINCT
//  common folder names → WELL-SPREAD hues (no clustering).
//

import XCTest
@testable import TreemapCore

final class TileColorTests: XCTestCase {
    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    func testSameNameSameHue() {
        XCTAssertEqual(TileColor.hue(for: "Library"), TileColor.hue(for: "Library"))
        XCTAssertEqual(TileColor.hue(for: "Documents"), TileColor.hue(for: "Documents"))
    }

    func testHueInUnitInterval() {
        for name in ["Library", "Documents", "Downloads", "Movies", "Music", "a", "", "🙂dir"] {
            let h = TileColor.hue(for: name)
            XCTAssertGreaterThanOrEqual(h, 0)
            XCTAssertLessThan(h, 1)
        }
    }

    func testDistinctNamesDistinctHues() {
        let names = ["Library", "Documents", "Downloads", "Movies", "Music",
                     "Pictures", "Desktop", "Applications", "Public", "Developer"]
        let hues = names.map(TileColor.hue(for:))
        XCTAssertEqual(Set(hues).count, hues.count, "distinct names must not collide to the same hue")
    }

    func testCommonNamesAreWellSpread() {
        // The five names a home directory actually shows side by side. Their hues
        // must not cluster — every pair separated by a visible amount on the wheel.
        let names = ["Library", "Documents", "Downloads", "Movies", "Music"]
        let hues = names.map(TileColor.hue(for:))
        for i in 0..<hues.count {
            for j in (i + 1)..<hues.count {
                XCTAssertGreaterThan(circularDistance(hues[i], hues[j]), 0.02,
                                     "\(names[i]) and \(names[j]) hues cluster (\(hues[i]) vs \(hues[j]))")
            }
        }
    }

    func testNamesSpanTheWheel() {
        // A larger set should not all fall on one arc — assert the hues cover a
        // wide range (not clustered), evidence the hash distributes.
        let names = (0..<40).map { "folder-\($0)" }
        let hues = names.map(TileColor.hue(for:)).sorted()
        XCTAssertLessThan(hues.first!, 0.25, "some hues near the low end of the wheel")
        XCTAssertGreaterThan(hues.last!, 0.75, "some hues near the high end of the wheel")
    }

    func testEmptyNameIsStableAndValid() {
        let h = TileColor.hue(for: "")
        XCTAssertEqual(h, TileColor.hue(for: ""))
        XCTAssertTrue(h >= 0 && h < 1)
    }
}
