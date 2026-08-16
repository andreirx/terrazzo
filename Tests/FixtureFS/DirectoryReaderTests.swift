//
//  DirectoryReaderTests.swift — the getattrlistbulk reader + hierarchical-spawn disjointness.
//  Module maturity: PROTOTYPE (slice TZ-6)
//
//  Two TZ-6 gates the FixtureWalk golden does not isolate:
//
//   1. READER SIZE FIDELITY. `DirectoryReader` (getattrlistbulk) is the new per-entry
//      path; the whole rewrite's correctness rests on it reproducing
//      `FileSystemWalker.measure`'s numbers (the golden's oracle). This drives the reader
//      DIRECTLY over a temp tree and asserts, entry-by-entry, that its (allocated, logical)
//      and kind match `measure` + a stat — so a reader regression fails HERE, precisely,
//      not as a mysterious byte mismatch three layers up. Also pins the structural
//      invariants the reader must uphold: hidden entries included, "." / ".." excluded,
//      symlinks reported without being followed.
//
//   2. HIERARCHICAL-SPAWN DISJOINTNESS (PLAN §TZ-6 invariants 1–2). The parallel descent
//      delegates directories to subtasks for the top `WalkTuning.spawnDepth` levels and
//      recurses sequentially below. This walks a tree DEEPER than that boundary and asserts
//      the disjointness contract at the EVENT level: every node is sized exactly once (no
//      entry stat'd twice), every directory is enumerated exactly once, and the reducer's
//      `processedCount` equals the real entry count — "nothing is ever walked twice",
//      proven by counting, across the spawn/sequential boundary.
//

import XCTest
import Darwin
import os
import ScanCore
@testable import ScanFS

final class DirectoryReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terrazzo-reader-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - 1. Reader size fidelity vs measure()

    func testReaderReproducesMeasureAndClassifiesKinds() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hidden-bytes".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data("hello world here".utf8).write(to: root.appendingPathComponent("visible.txt"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: sub)

        guard case let .complete(children) = DirectoryReader.read(root.path) else {
            return XCTFail("a fully-readable directory must enumerate to .complete")
        }
        let byName = Dictionary(uniqueKeysWithValues: children.map { ($0.name, $0) })

        // Hidden included; "." / ".." never returned.
        XCTAssertNotNil(byName[".hidden"], "hidden entries are always enumerated (VISION)")
        XCTAssertNil(byName["."]); XCTAssertNil(byName[".."])
        XCTAssertEqual(Set(byName.keys), [".hidden", "visible.txt", "sub", "link"])

        // Kinds.
        XCTAssertEqual(byName["visible.txt"]?.kind, .file)
        XCTAssertEqual(byName[".hidden"]?.kind, .file)
        XCTAssertEqual(byName["sub"]?.kind, .dir)
        XCTAssertEqual(byName["link"]?.kind, .symlink, "a symlink is reported as such, never followed")

        // Sizes are byte-identical to measure() — the golden's oracle — for every kind.
        for (name, child) in byName {
            let m = FileSystemWalker.measure(root.appendingPathComponent(name))
            XCTAssertEqual(child.allocated, m.allocated, "allocated mismatch for \(name)")
            XCTAssertEqual(child.logical, m.logical, "logical mismatch for \(name)")
        }

        // The directory child carries its real device (the one-scan-one-device input).
        var st = stat()
        XCTAssertEqual(lstat(sub.path, &st), 0)
        XCTAssertEqual(byName["sub"]?.device, st.st_dev, "a dir child carries its st_dev")
    }

    func testReaderReturnsUnreadableMarkerForUnreadableDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        guard case .unreadable = DirectoryReader.read(locked.path) else {
            return XCTFail("an un-enumerable directory reads as .unreadable (caller emits accessDenied, never a silent skip)")
        }
    }

    /// TRUNCATION IS NOT COMPLETION (revise finding 1; test seam is review-0 change 4). A
    /// `ReadResult.partial` — a `getattrlistbulk` that failed mid-directory after returning some
    /// entries — must make the walker BOTH show the entries it read AND mark the directory
    /// `accessDenied` (the unread remainder is a "we don't know" tile, never a silently-short
    /// total). A mid-directory syscall failure cannot be forced from userspace without a
    /// fault-injecting filesystem, so this drives the REAL classify→walk→emit path through the
    /// `DirectoryReader.faultInjector` seam (DEBUG-only, compiled out of release) and OBSERVES the
    /// emitted events — replacing the prior flag-only tautology the reviewer struck.
    func testPartialReadIsDeniedNotSwallowed() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let truncated = root.appendingPathComponent("truncated", isDirectory: true)
        try fm.createDirectory(at: truncated, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: truncated.appendingPathComponent("a.txt"))
        try Data("bb".utf8).write(to: truncated.appendingPathComponent("b.txt"))

        // Read the directory for real to get honest Child values, then inject them AS a partial
        // read — simulating a mid-stream getattrlistbulk failure that had already handed these back.
        guard case let .complete(readChildren) = DirectoryReader.read(truncated.path) else {
            return XCTFail("precondition: the directory reads .complete before injection")
        }
        XCTAssertFalse(readChildren.isEmpty)
        DirectoryReader.faultInjector = { path in
            path == truncated.path ? .partial(readChildren) : nil
        }
        defer { DirectoryReader.faultInjector = nil }

        var deniedIds = Set<String>()
        var sizedIds = Set<String>()
        for await batch in FileSystemWalker.scan(root: root) {
            for e in batch {
                switch e {
                case let .accessDenied(nodeId): deniedIds.insert(nodeId)
                case let .sizeUpdated(nodeId, _, _): sizedIds.insert(nodeId)
                default: break
                }
            }
        }

        let truncatedId = FileSystemWalker.joinId(root.path, "truncated")
        // The unread remainder is surfaced: the directory is DENIED, never a silently-short total.
        XCTAssertTrue(deniedIds.contains(truncatedId),
                      "a partial (truncated) enumeration marks the directory accessDenied — the one sin this product ends")
        // AND the children read before truncation are still shown (partial ≠ silently dropped).
        XCTAssertTrue(sizedIds.contains(FileSystemWalker.joinId(truncatedId, "a.txt")),
                      "entries read before the truncation are still emitted")
        XCTAssertTrue(sizedIds.contains(FileSystemWalker.joinId(truncatedId, "b.txt")),
                      "entries read before the truncation are still emitted")
    }

    // MARK: - 1b. Anticipatory warm excludes the active scan root BY IDENTITY (review-0 changes 1–2)

    /// IDENTITY EXCLUSION ACROSS A PATH ALIAS (review-0 changes 1–2, disjointness invariant 5).
    /// The anticipatory warm descends the PHYSICAL volume mount while the active scan uses the
    /// LOGICAL path, so it reaches the active scan root through a firmlink alias whose path
    /// STRING differs. A string-path exclusion (the shipped bug) misses that alias and re-walks
    /// the active subtree; device+inode identity matches across it. Firmlinks cannot be minted in
    /// a temp dir, so this reproduces the essence: capture the excluded identity from ONE path
    /// string (`…/sibling/../active`) and warm-reach the same directory via a DIFFERENT string
    /// (`…/active`) — different strings, same `(dev, ino)`. The warm must never touch the active
    /// subtree, and must still warm the sibling.
    func testAnticipatoryWarmExcludesActiveRootByIdentityAcrossAlias() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let active = root.appendingPathComponent("active", isDirectory: true)
        let activeInner = active.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: activeInner, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        let siblingInner = sibling.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: siblingInner, withIntermediateDirectories: true)

        // A DIFFERENT path string that lstat resolves to the SAME object as `active` (no symlink).
        let aliasToActive = root.appendingPathComponent("sibling")
            .appendingPathComponent("..").appendingPathComponent("active")
        var s1 = stat(), s2 = stat()
        XCTAssertEqual(lstat(aliasToActive.path, &s1), 0)
        XCTAssertEqual(lstat(active.path, &s2), 0)
        XCTAssertTrue(s1.st_dev == s2.st_dev && s1.st_ino == s2.st_ino,
                      "the alias resolves to the active root's identity")
        XCTAssertNotEqual(aliasToActive.path, active.path, "the alias is a DIFFERENT path string")

        // Warm from `root` (a bounded tree), excluding the active root by the IDENTITY captured
        // from the alias path. onDir records every directory actually warmed.
        let warmed = OSAllocatedUnfairLock(initialState: Set<String>())
        await FileSystemWalker.warmTreeForTesting(
            start: root.path, excludingIdentityOf: aliasToActive.path, boundaryDevice: nil,
            onDir: { p in warmed.withLock { s in _ = s.insert(p) } })
        let touched = warmed.withLock { $0 }

        // The active subtree is EXCLUDED across the alias — never enumerated (invariant 5)…
        XCTAssertFalse(touched.contains(active.path),
                       "the active scan root is excluded by identity, even reached via a different path string")
        XCTAssertFalse(touched.contains(activeInner.path),
                       "no descendant of the excluded identity is warmed")
        // …while a genuine sibling IS warmed (the warm still does its job).
        XCTAssertTrue(touched.contains(sibling.path), "a non-excluded sibling is warmed")
        XCTAssertTrue(touched.contains(siblingInner.path), "and its descendants are warmed")
    }

    // MARK: - 2. Hierarchical-spawn disjointness across the spawn/sequential boundary

    func testDeepTreeWalkedExactlyOnceAcrossSpawnBoundary() async throws {
        let fm = FileManager.default
        // A chain DEEPER than WalkTuning.spawnDepth so both the delegating (top) and
        // sequential (deep) descent paths are exercised, plus a branch and files at
        // several levels.
        XCTAssertGreaterThanOrEqual(6, WalkTuning.spawnDepth,
                                    "this fixture must reach beyond the spawn depth")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Deep chain: L0a/L1a/L2a/L3a/L4a/deep.txt  (deep.txt is at descent depth 6)
        var chain = root!
        for level in 0..<5 { chain = chain.appendingPathComponent("L\(level)a", isDirectory: true) }
        try fm.createDirectory(at: chain, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: chain.appendingPathComponent("deep.txt"))
        // A shallow branch + a top-level file.
        let b = root.appendingPathComponent("L0b", isDirectory: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: b.appendingPathComponent("f1.txt"))
        try Data("two".utf8).write(to: b.appendingPathComponent("f2.txt"))
        try Data("top".utf8).write(to: root.appendingPathComponent("top.txt"))

        // Entries created (each is one inode / one stat): L0a,L1a,L2a,L3a,L4a,deep.txt,
        // L0b,f1.txt,f2.txt,top.txt = 10 descendants; +1 for the scan root itself.
        let expectedEntries = 11

        var reducer = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
        var sizeIds: [String] = []
        var discoveredParents: [String] = []
        for await batch in FileSystemWalker.scan(root: root) {
            for e in batch {
                switch e {
                case let .sizeUpdated(nodeId, _, _): sizeIds.append(nodeId)
                case let .childrenDiscovered(parentId, _): discoveredParents.append(parentId)
                default: break
                }
            }
            reducer.apply(batch)
        }

        // DISJOINTNESS: no node is sized twice (no entry stat'd twice), and no directory is
        // enumerated twice — across the spawn/sequential boundary. This is invariant 1–2
        // proven by counting.
        XCTAssertEqual(sizeIds.count, Set(sizeIds).count, "every entry is sized exactly once — nothing walked twice")
        XCTAssertEqual(discoveredParents.count, Set(discoveredParents).count,
                       "every directory is enumerated exactly once (single enumeration point)")
        XCTAssertEqual(sizeIds.count, expectedEntries, "exactly the created entries were sized")
        XCTAssertEqual(reducer.processedCount, expectedEntries,
                       "processedCount counts each entry once, spawn and sequential alike")

        // The deep leaf below the spawn boundary is present with the right size.
        let tree = reducer.makeTree(depthWindow: 20)
        func find(_ node: SizeTree, _ id: String) -> SizeTree? {
            if node.id == id { return node }
            for c in node.children { if let f = find(c, id) { return f } }
            return nil
        }
        let deepId = chain.path + "/deep.txt" // chain.path is the real (uncanonicalized-join) path
        // The walker's ids are joinId(root.path, names); reconstruct the same way.
        var expectId = root.path
        for level in 0..<5 { expectId = FileSystemWalker.joinId(expectId, "L\(level)a") }
        expectId = FileSystemWalker.joinId(expectId, "deep.txt")
        let deep = try XCTUnwrap(find(tree, expectId), "the deep leaf beyond the spawn depth is in the tree")
        XCTAssertEqual(deep.kind, .file)
        XCTAssertGreaterThan(deep.allocatedBytes, 0)
        _ = deepId
    }
}
