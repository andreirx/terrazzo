//
//  SizeTreeTests.swift — the crossing DTO: Codable round-trip + fixture decode.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  ScanCore in TZ-1 is ONLY the SizeTree DTO. These tests pin its shape (so the
//  visualization engine can rely on it) and prove the tracked fixture decodes
//  into it — the exact path the App uses to load the map.
//

import XCTest
@testable import ScanCore

final class SizeTreeTests: XCTestCase {
    private func sample() -> SizeTree {
        SizeTree(
            id: "root", name: "Macintosh HD", kind: .dir,
            allocatedBytes: 3000, logicalBytes: 2900,
            children: [
                SizeTree(id: "f", name: "big.bin", kind: .file,
                         allocatedBytes: 2000, logicalBytes: 1990),
                SizeTree(id: "app", name: "Foo.app", kind: .bundleLeaf,
                         allocatedBytes: 900, logicalBytes: 880),
                SizeTree(id: "denied", name: "otheruser", kind: .denied,
                         allocatedBytes: 100, logicalBytes: 0, scanState: .complete),
                SizeTree(id: "pend", name: "Caches", kind: .pending,
                         allocatedBytes: 0, logicalBytes: 0, scanState: .pending),
            ],
            scanState: .complete
        )
    }

    func testCodableRoundTrip() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SizeTree.self, from: data)
        XCTAssertEqual(decoded, original, "SizeTree must survive an encode/decode round-trip")
    }

    func testKindsAndScanStatesDecodeFromRawStrings() throws {
        let json = """
        {"id":"x","name":"x","kind":"denied","allocatedBytes":5,"logicalBytes":0,
         "children":[],"scanState":"partial"}
        """
        let node = try JSONDecoder().decode(SizeTree.self, from: Data(json.utf8))
        XCTAssertEqual(node.kind, .denied)
        XCTAssertEqual(node.scanState, .partial)
    }

    func testNodeCountAndDepthHelpers() {
        let t = sample()
        XCTAssertEqual(t.nodeCount, 5) // root + 4 children
        XCTAssertEqual(t.depth, 2)
    }

    // The real fixture: decodes, is the right size, and carries the invisible
    // -space kinds end-to-end (denied + pending present — VISION first-class).
    func testFixtureDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScanCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/fixture-tree.json")
        let data = try Data(contentsOf: url)
        let tree = try JSONDecoder().decode(SizeTree.self, from: data)

        XCTAssertEqual(tree.name, "Macintosh HD")
        XCTAssertGreaterThan(tree.nodeCount, 150, "fixture should be ~200 nodes")
        XCTAssertGreaterThanOrEqual(tree.depth, 4, "fixture should be ~4-5 levels deep")

        var kinds = Set<NodeKind>()
        func walk(_ n: SizeTree) { kinds.insert(n.kind); n.children.forEach(walk) }
        walk(tree)
        XCTAssertTrue(kinds.contains(.denied), "fixture must exercise a denied tile")
        XCTAssertTrue(kinds.contains(.pending), "fixture must exercise a pending tile")
        XCTAssertTrue(kinds.contains(.bundleLeaf), "fixture must exercise a bundle leaf")
    }
}
