//
//  FixtureLoader.swift — test helper: decode the tracked fixture SizeTree.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  The fixture (Tests/Fixtures/fixture-tree.json) is the system of record for
//  the render. Tests read it straight off disk (no bundled resources declared in
//  Package.swift) using #filePath to locate the repo — the same disk-read
//  convention glyph-saver's TestSupport uses.
//

import Foundation
import ScanCore

enum FixtureLoader {
    static var fixtureURL: URL {
        // .../Tests/TreemapCoreTests/FixtureLoader.swift → .../Tests/Fixtures/...
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // TreemapCoreTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("Fixtures/fixture-tree.json")
    }

    static func load() throws -> SizeTree {
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(SizeTree.self, from: data)
    }
}
