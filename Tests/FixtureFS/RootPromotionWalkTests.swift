//
//  RootPromotionWalkTests.swift — the sibling-exclusion promotion walk (TZ-4b layer b).
//  Module maturity: PROTOTYPE (slice TZ-4b)
//
//  The end-to-end gate for root promotion's I/O layer over a REAL temp tree. It proves
//  the disjointness contract the packet demands ("no re-scan of the grafted subtree —
//  assert by event counts"):
//
//    parent/
//      home/            ← the ALREADY-SCANNED child (deep contents) — grafted, NOT re-walked
//        Docs/a.txt
//        b.txt
//      sibling/c.txt    ← a NEW sibling directory the promotion walk scans
//      loose.txt        ← a NEW sibling file
//
//  Steps: (1) scan `home` to completion into a reducer (the original scan); (2)
//  `reRoot` the reducer to `parent`; (3) run `FileSystemWalker.scanSiblings(parent,
//  excludingChildId: home)`, collecting EVERY emitted event AND folding it. Then assert
//  the sibling stream NEVER re-stats any node inside `home` (invariant 5), that the
//  grafted `home` subtree is byte-identical to the original scan, and that the new
//  siblings scanned in.
//

import XCTest
import Darwin
import ScanCore
@testable import ScanFS

final class RootPromotionWalkTests: XCTestCase {
    private static let window = 10
    private var parent: URL!
    private var home: URL!

    override func setUpWithError() throws {
        parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terrazzo-promote-\(UUID().uuidString)", isDirectory: true)
        home = parent.appendingPathComponent("home", isDirectory: true)
        let fm = FileManager.default
        func mkdir(_ u: URL) throws { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        func write(_ u: URL, _ s: String) throws { try Data(s.utf8).write(to: u) }

        // The already-scanned child, with nested detail.
        let docs = home.appendingPathComponent("Docs", isDirectory: true)
        try mkdir(docs)
        try write(docs.appendingPathComponent("a.txt"), "alpha payload")
        try write(home.appendingPathComponent("b.txt"), "bravo")

        // New siblings under the parent.
        let sibling = parent.appendingPathComponent("sibling", isDirectory: true)
        try mkdir(sibling)
        try write(sibling.appendingPathComponent("c.txt"), "charlie content here")
        try write(parent.appendingPathComponent("loose.txt"), "loose file at parent")
    }

    override func tearDownWithError() throws {
        guard let parent else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    /// Walk `home` fully into a reducer, mirroring the primary scan the App runs first.
    private func scanHome() async -> ScanReducer {
        var reducer = ScanReducer(rootId: home.path, rootName: home.lastPathComponent)
        for await batch in FileSystemWalker.scan(root: home) { reducer.apply(batch) }
        return reducer
    }

    /// All node ids an event names (parent + children/target), for the "never re-stat the
    /// graft" assertion.
    private func referencedIds(_ e: ScanEvent) -> [String] {
        switch e {
        case let .childrenDiscovered(parentId, children): return [parentId] + children.map(\.id)
        case let .sizeUpdated(nodeId, _, _): return [nodeId]
        case let .accessDenied(nodeId): return [nodeId]
        case let .subtreeCompleted(nodeId): return [nodeId]
        // TZ-7 additive vocabulary — the walker's promotion path never emits these (they are the
        // living-map revalidation events), so they name no ids for this graft assertion.
        case let .childRemoved(parentId, childId): return [parentId, childId]
        case let .directoryMtime(nodeId, _): return [nodeId]
        }
    }

    func testPromotionWalkGraftsWithoutReScanningTheChild() async throws {
        // 1. Original scan of home.
        var reducer = await scanHome()
        let homeBefore = reducer.makeTree(depthWindow: Self.window)
        let countAfterHome = reducer.processedCount

        // 2. Graft home under parent.
        reducer.reRoot(to: parent.path, newRootName: parent.lastPathComponent)

        // 3. Sibling-exclusion walk of parent, EXCLUDING the already-scanned home.
        var siblingEvents: [ScanEvent] = []
        for await batch in FileSystemWalker.scanSiblings(
            newRoot: parent, newRootId: parent.path, excludingChildId: home.path) {
            siblingEvents.append(contentsOf: batch)
            reducer.apply(batch)
        }

        // --- Invariant 5: the grafted child is a graft REFERENCE, never re-stat'd. ---
        let homeDescendantPrefix = home.path + "/"
        for e in siblingEvents {
            for id in referencedIds(e) {
                XCTAssertFalse(id.hasPrefix(homeDescendantPrefix),
                    "the promotion walk must not touch any node inside the grafted child: \(id) via \(e)")
            }
            // home itself must NEVER be sized/entered/completed — only referenced as a stub.
            if case let .sizeUpdated(nodeId, _, _) = e {
                XCTAssertNotEqual(nodeId, home.path, "the grafted child must not be re-sized")
            }
            if case let .subtreeCompleted(nodeId) = e {
                XCTAssertNotEqual(nodeId, home.path, "the grafted child must not be re-completed")
            }
        }
        // home appears EXACTLY as a stub in parent's childrenDiscovered.
        let homeStubbed = siblingEvents.contains {
            if case let .childrenDiscovered(pid, kids) = $0 {
                return pid == parent.path && kids.contains { $0.id == home.path && $0.kind == .dir }
            }
            return false
        }
        XCTAssertTrue(homeStubbed, "the grafted child is referenced as a stub under the new root")

        // --- Assert-by-event-counts: only the NEW entries were stat'd. ---
        // New stat'd entries: parent (own), sibling (own), sibling/c.txt, loose.txt = 4.
        let sizeEventCount = siblingEvents.filter {
            if case .sizeUpdated = $0 { return true }; return false
        }.count
        XCTAssertEqual(sizeEventCount, 4,
            "exactly the 4 NEW entries are sized (parent, sibling, c.txt, loose.txt) — home's subtree is not re-stat'd")

        // 4. The grafted home subtree is byte-identical to the original scan.
        let promoted = reducer.makeTree(depthWindow: Self.window)
        XCTAssertEqual(promoted.id, parent.path)
        let graftedHome = try XCTUnwrap(promoted.children.first { $0.id == home.path })
        XCTAssertEqual(graftedHome, homeBefore,
                       "the grafted subtree is preserved exactly across the promotion walk")

        // The new siblings are present and scanned.
        let childNames = promoted.children.map(\.name).sorted()
        XCTAssertEqual(childNames, ["home", "loose.txt", "sibling"])
        let sibling = try XCTUnwrap(promoted.children.first { $0.name == "sibling" })
        XCTAssertEqual(sibling.children.map(\.name), ["c.txt"])

        // processedCount grew by exactly the 4 new entries — the graft added none.
        XCTAssertEqual(reducer.processedCount, countAfterHome + 4,
                       "the numerator counts only the newly-stat'd siblings, never the grafted subtree")
    }

    /// ONE SCAN = ONE DEVICE, enforced THROUGHOUT the descent, not only at the promoted
    /// root (review-0 finding 2, PLAN invariant 4). A real cross-device mount needs
    /// root/hdiutil, so we drive the enumeration point (`classifyChildren`) directly with a
    /// `boundaryDevice` that differs from the fixture's real device — proving the decision:
    /// a child dir whose device ≠ the boundary is a boundary STUB (shown, sized, completed)
    /// and is kept OUT of the recurse set, while the SAME dir with a matching boundary is
    /// descended normally. `walkDirectory` threads this device down every level, so the
    /// guard the top-level `walkNewRoot` applied now covers nested siblings too.
    func testDescendantCrossDeviceDirsBecomeBoundaryStubsNeverEntered() throws {
        // A nested directory under the sibling: sibling/nested (with a file), on the
        // fixture's single real device.
        let sib = parent.appendingPathComponent("sibling", isDirectory: true)
        let nested = sib.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("n".utf8).write(to: nested.appendingPathComponent("n.txt"))

        var st = stat()
        XCTAssertEqual(lstat(sib.path, &st), 0)
        let realDev = st.st_dev
        let nestedId = "/sib/nested"

        // SAME device: `nested` is an ordinary child dir → descended.
        let same = try XCTUnwrap(FileSystemWalker.classifyChildren(
            of: sib, parentId: "/sib", policy: .default, boundaryDevice: realDev))
        XCTAssertTrue(same.dirsToRecurse.contains { $0.1 == nestedId },
                      "a same-device child dir is entered normally")

        // DIFFERENT device: `nested` is a boundary stub — shown, sized, completed, NOT entered.
        let diff = try XCTUnwrap(FileSystemWalker.classifyChildren(
            of: sib, parentId: "/sib", policy: .default, boundaryDevice: realDev + 1))
        XCTAssertFalse(diff.dirsToRecurse.contains { $0.1 == nestedId },
                       "a cross-device child dir is NEVER entered (invariant 4)")
        XCTAssertTrue(diff.stubs.contains { $0.id == nestedId && $0.kind == .dir },
                      "the cross-device boundary is still SHOWN as a stub (never a silent skip)")
        let sized = diff.sizeEvents.contains {
            if case let .sizeUpdated(id, _, _) = $0 { return id == nestedId }; return false
        }
        let completed = diff.sizeEvents.contains {
            if case let .subtreeCompleted(id) = $0 { return id == nestedId }; return false
        }
        XCTAssertTrue(sized, "the boundary stub is sized by its own entry")
        XCTAssertTrue(completed, "the boundary stub renders complete, not forever-pending")
    }
}
