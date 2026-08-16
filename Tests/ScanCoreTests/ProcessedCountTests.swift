//
//  ProcessedCountTests.swift — the progress-bar numerator (TZ-4 D10).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  `ScanReducer.processedCount` is the numerator of the file-count progress bar. It
//  must:
//   1. count EACH stat'd entry — files AND directories — exactly once (a directory is
//      one inode, one `stat`, just like a file; this matches the statfs used-inode
//      denominator which counts all inodes), and
//   2. count from the FIRST own-size write only (idempotent under a replayed/duplicate
//      batch), staying order-independent like the rest of the reducer.
//  These pin the consistency argument the progress ratio depends on.
//

import XCTest
@testable import ScanCore

final class ProcessedCountTests: XCTestCase {

    func testCountsEachSizedEntryOnceFilesAndDirs() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            .sizeUpdated(nodeId: "/r", allocated: 10, logical: 10),           // the root dir
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir),
                ChildStub(id: "/r/f", name: "f", kind: .file),
            ]),
            .sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4),           // a dir
            .sizeUpdated(nodeId: "/r/f", allocated: 20, logical: 18),         // a file
        ])
        // 3 entries received their own size: /r, /r/a, /r/f — dirs and files alike.
        XCTAssertEqual(r.processedCount, 3)
    }

    func testDuplicateSizeEventDoesNotDoubleCount() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.sizeUpdated(nodeId: "/r/f", allocated: 20, logical: 18)])
        r.apply([.sizeUpdated(nodeId: "/r/f", allocated: 20, logical: 18)]) // replayed batch
        XCTAssertEqual(r.processedCount, 1, "counts the false→true size transition, once per node")
    }

    func testChildrenDiscoveredAloneDoesNotCount() {
        // Discovery (structure) is not a stat of the node's own size; only sizeUpdated is.
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/a", name: "a", kind: .dir)])])
        XCTAssertEqual(r.processedCount, 0, "a discovered-but-unsized stub is not yet counted")
        r.apply([.sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4)])
        XCTAssertEqual(r.processedCount, 1)
    }

    func testProcessedCountIsOrderIndependent() {
        // Size before stub vs stub before size — same final tally.
        var a = ScanReducer(rootId: "/r", rootName: "r")
        a.apply([.sizeUpdated(nodeId: "/r/a/f1", allocated: 100, logical: 90)])
        a.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/a", name: "a", kind: .dir)])])
        a.apply([.sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4)])

        var b = ScanReducer(rootId: "/r", rootName: "r")
        b.apply([.childrenDiscovered(parentId: "/r", children: [
            ChildStub(id: "/r/a", name: "a", kind: .dir)])])
        b.apply([.sizeUpdated(nodeId: "/r/a", allocated: 4, logical: 4)])
        b.apply([.sizeUpdated(nodeId: "/r/a/f1", allocated: 100, logical: 90)])

        XCTAssertEqual(a.processedCount, 2)
        XCTAssertEqual(b.processedCount, 2)
    }
}
