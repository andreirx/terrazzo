//
//  FixtureWalkTests.swift — walker + reducer against a REAL temp directory tree.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  The end-to-end integration gate for the scan engine (packet deliverable 5):
//  build a temp tree exercising every policy edge — a hidden file (must be
//  included), a symlink to a directory (must NOT be followed), a chmod-000
//  directory (must surface as denied, never a silent skip), a fully-readable
//  `.app` bundle (opaque leaf), and a `.app` bundle with a locked directory
//  inside (must surface as DENIED, not a silently-truncated size — review TZ-2
//  point 3) — then run the REAL FileSystemWalker into the REAL ScanReducer and
//  assert the resulting SizeTree matches a golden.
//
//  GOLDEN METHOD (review TZ-2 points 1 & 3): the golden is NOT hardcoded byte
//  counts (those depend on the APFS block/inline behavior of the test host).
//  Instead `expectedTree` recomputes the ENTIRE expected SizeTree — every node's
//  kind, allocated bytes, logical bytes, child set, and scanState — INDEPENDENTLY,
//  via the SAME `FileSystemWalker.measure` syscalls and the SAME `ScanPolicy`
//  rules the walker uses. Two independent computations of the whole tree that must
//  agree node-for-node (packet: "golden comparison; sizes by the same syscalls the
//  assertion uses"). `assertTreesEqual` walks both and pinpoints the first
//  divergence.
//
//  ASSUMPTION: the suite runs as a normal (non-root) user, so chmod-000 actually
//  denies enumeration. Recorded, not silently relied upon.
//

import XCTest
import Darwin
import ScanCore
@testable import ScanFS

final class FixtureWalkTests: XCTestCase {
    /// Deep enough that nothing in the fixture folds — the golden compares the
    /// full retained tree. (Fixture max depth is ~4.)
    private static let window = 10

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terrazzo-fixture-\(UUID().uuidString)", isDirectory: true)
        try buildFixture(at: root)
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        restorePermissions(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture construction
    //
    //   root/
    //     .hidden               (hidden file — must be scanned)
    //     visible.txt
    //     sub/inner.txt
    //     Foo.app/Contents/MacOS/bin        (bundle leaf — one opaque tile)
    //     Bar.app/Contents/Resources/r.bin  (bundle with...
    //     Bar.app/Contents/Locked/          (...a chmod-000 dir inside → DENIED)
    //     denied/secret.txt     (denied dir is chmod 000 — enumeration fails)
    //     target/real.txt       (real dir, scanned as itself)
    //     link -> target        (symlink — must NOT be followed)

    private func buildFixture(at root: URL) throws {
        let fm = FileManager.default
        func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        func write(_ url: URL, _ s: String) throws { try Data(s.utf8).write(to: url) }

        try mkdir(root)
        try write(root.appendingPathComponent(".hidden"), "hidden-bytes")
        try write(root.appendingPathComponent("visible.txt"), "hello world")

        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try mkdir(sub)
        try write(sub.appendingPathComponent("inner.txt"), "inner content here")

        // Fully readable bundle → an opaque bundleLeaf.
        let fooBin = root.appendingPathComponent("Foo.app/Contents/MacOS", isDirectory: true)
        try mkdir(fooBin)
        try write(fooBin.appendingPathComponent("bin"), "pretend-binary-content")

        // Bundle with a locked directory inside → must surface as DENIED (its full
        // size cannot be honestly measured). The locked dir is created LAST and
        // chmod-000'd so its parent can still be built.
        let barRes = root.appendingPathComponent("Bar.app/Contents/Resources", isDirectory: true)
        try mkdir(barRes)
        try write(barRes.appendingPathComponent("r.bin"), "bar-resource")
        let barLocked = root.appendingPathComponent("Bar.app/Contents/Locked", isDirectory: true)
        try mkdir(barLocked)
        try write(barLocked.appendingPathComponent("hidden.bin"), "cannot read me")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: barLocked.path)

        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try mkdir(denied)
        try write(denied.appendingPathComponent("secret.txt"), "top secret")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

        let target = root.appendingPathComponent("target", isDirectory: true)
        try mkdir(target)
        try write(target.appendingPathComponent("real.txt"), "target payload")

        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: target)
    }

    /// Restore write/exec on the chmod-000 dirs so `removeItem` can descend.
    private func restorePermissions(under root: URL) {
        let fm = FileManager.default
        for p in ["denied", "Bar.app/Contents/Locked"] {
            let u = root.appendingPathComponent(p, isDirectory: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
        }
    }

    // MARK: - Walk to completion

    private func walkToTree() async -> SizeTree {
        var reducer = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
        for await batch in FileSystemWalker.scan(root: root) {
            reducer.apply(batch)
        }
        return reducer.makeTree(depthWindow: Self.window)
    }

    private func childNamed(_ tree: SizeTree, _ name: String) -> SizeTree? {
        tree.children.first { $0.name == name }
    }

    // MARK: - Golden STRUCTURE (targeted, human-readable per-node assertions)

    func testGoldenStructure() async throws {
        let tree = await walkToTree()

        // Root's children, sorted by (name, id) — the reducer's canonical order.
        let names = tree.children.map(\.name)
        XCTAssertEqual(names,
                       [".hidden", "Bar.app", "Foo.app", "denied", "link", "sub", "target", "visible.txt"],
                       "hidden included, all eight entries present, canonically ordered")

        XCTAssertEqual(childNamed(tree, ".hidden")?.kind, .file)
        XCTAssertEqual(childNamed(tree, "visible.txt")?.kind, .file)

        // Fully-readable bundle: opaque, no child tiles, sized.
        let foo = try XCTUnwrap(childNamed(tree, "Foo.app"))
        XCTAssertEqual(foo.kind, .bundleLeaf)
        XCTAssertTrue(foo.children.isEmpty, "a readable .app is an opaque leaf — no child tiles")
        XCTAssertGreaterThan(foo.allocatedBytes, 0)

        // Denied dir: surfaced, never silently skipped.
        let denied = try XCTUnwrap(childNamed(tree, "denied"))
        XCTAssertEqual(denied.kind, .denied)
        XCTAssertEqual(denied.scanState, .complete)
        XCTAssertTrue(denied.children.isEmpty, "we could not enter — no children known")

        // Symlink: a leaf, NOT followed (no children, target not expanded here).
        let link = try XCTUnwrap(childNamed(tree, "link"))
        XCTAssertEqual(link.kind, .file, "an un-followed symlink is a leaf")
        XCTAssertTrue(link.children.isEmpty)

        // The real target IS scanned (as itself), exactly once.
        let target = try XCTUnwrap(childNamed(tree, "target"))
        XCTAssertEqual(target.kind, .dir)
        XCTAssertEqual(target.children.map(\.name), ["real.txt"])

        let sub = try XCTUnwrap(childNamed(tree, "sub"))
        XCTAssertEqual(sub.children.map(\.name), ["inner.txt"])
    }

    // MARK: - Bundle denial (review TZ-2 point 3)

    func testBundleWithLockedDirSurfacesDenied() async throws {
        let tree = await walkToTree()
        let bar = try XCTUnwrap(childNamed(tree, "Bar.app"),
                                "the bundle with a locked dir inside must be present, not dropped")

        // The EPERM inside the opaque bundle is NOT swallowed into a smaller total:
        // the whole bundle is marked denied and rendered as such.
        XCTAssertEqual(bar.kind, .denied,
                       "a bundle we cannot fully measure must say 'denied', not report a truncated size")
        XCTAssertEqual(bar.scanState, .complete)
        XCTAssertTrue(bar.children.isEmpty, "an opaque bundle never expands into child tiles")

        // Sized by its OWN entry only (same rule as any un-enterable directory),
        // NOT by the partial recursive sum of the readable parts.
        let ownEntry = FileSystemWalker.measure(root.appendingPathComponent("Bar.app"))
        XCTAssertEqual(bar.allocatedBytes, ownEntry.allocated,
                       "denied bundle is sized by its own directory entry, not a partial subtree sum")
        XCTAssertEqual(bar.logicalBytes, ownEntry.logical)
    }

    // MARK: - Golden TREE (full independent recompute; review TZ-2 points 1 & 3)

    func testGoldenTreeMatchesIndependentRecompute() async throws {
        let actual = await walkToTree()
        let expected = expectedTree(root, name: root.lastPathComponent, depth: 0)
        assertTreesEqual(actual, expected, path: root.lastPathComponent)
    }

    /// Root allocated total also equals the independent recompute (coarse invariant
    /// kept from the prior gate; the full-tree test above subsumes it).
    func testRootAllocatedMatchesIndependentRecompute() async throws {
        let tree = await walkToTree()
        let expected = expectedTree(root, name: root.lastPathComponent, depth: 0)
        XCTAssertEqual(tree.allocatedBytes, expected.allocatedBytes)
        XCTAssertGreaterThan(tree.allocatedBytes, 0)
    }

    // MARK: - Streaming contract (partial data is usable mid-scan)

    func testEventsArriveAsAStream() async throws {
        var batchCount = 0
        var sawChildrenDiscovered = false
        for await batch in FileSystemWalker.scan(root: root) {
            batchCount += 1
            if batch.contains(where: { if case .childrenDiscovered = $0 { return true }; return false }) {
                sawChildrenDiscovered = true
            }
        }
        XCTAssertGreaterThan(batchCount, 0, "the scan API is an event stream, not one final result")
        XCTAssertTrue(sawChildrenDiscovered)
    }

    // MARK: - Top-level bundle must not block root discovery (review-2 item 1)
    //
    // The fixture's top-level `Foo.app` is an opaque bundle whose recursive sizing
    // is deferred to its own task. This asserts the ORDER the walker emits into the
    // batcher (which is FIFO, so flattening batches in yield order is the true
    // emission order): the root's `childrenDiscovered` — every top-level tile now
    // exists — is emitted BEFORE the bundle's `subtreeCompleted`. A large top-level
    // `.app` therefore cannot hold the map blank while it is measured (ratified
    // decision 5; VISION §"progressive, truthful map").

    func testTopLevelBundleDiscoveryPrecedesBundleCompletion() async throws {
        var ordered: [ScanEvent] = []
        for await batch in FileSystemWalker.scan(root: root) {
            ordered.append(contentsOf: batch)
        }

        let rootId = root.path
        let rootDiscoveryIdx = ordered.firstIndex {
            if case let .childrenDiscovered(parentId, _) = $0 { return parentId == rootId }
            return false
        }
        let discovery = try XCTUnwrap(rootDiscoveryIdx,
            "the root's children must be discovered (structure emitted)")

        // Take the bundle's node id from the walker's OWN root discovery stub — the
        // ids are firmlink-resolved enumeration paths (/private/var/…), so we must
        // not reconstruct them from `root.appendingPathComponent` (which yields the
        // unresolved /var/… form). This also proves the bundle STUB is present in
        // the very first root discovery, before any sizing.
        guard case let .childrenDiscovered(_, rootStubs) = ordered[discovery] else {
            return XCTFail("root discovery event is not a childrenDiscovered")
        }
        let fooStub = try XCTUnwrap(rootStubs.first { $0.name == "Foo.app" },
            "the top-level .app must appear in the root's structure immediately")
        XCTAssertEqual(fooStub.kind, .bundleLeaf, "an .app is an opaque bundle leaf")
        let fooId = fooStub.id

        let bundleCompletionIdx = ordered.firstIndex {
            if case let .subtreeCompleted(nodeId) = $0 { return nodeId == fooId }
            return false
        }
        let completion = try XCTUnwrap(bundleCompletionIdx,
            "the readable top-level bundle must eventually complete")
        XCTAssertLessThan(discovery, completion,
            "root discovery must be emitted BEFORE a top-level .app finishes sizing — the bundle must not delay all top-level tiles (review-2 item 1)")

        // And the bundle's single size arrives no earlier than the root structure
        // (it stays pending until its own task delivers the one size event).
        let bundleSizeIdx = ordered.firstIndex {
            if case let .sizeUpdated(nodeId, _, _) = $0 { return nodeId == fooId }
            return false
        }
        let sized = try XCTUnwrap(bundleSizeIdx, "the bundle must be sized")
        XCTAssertLessThan(discovery, sized,
            "the bundle is sized after — never before — the root structure is emitted")
    }

    // MARK: - The golden: recompute the ENTIRE expected SizeTree
    //
    // Mirrors, independently, exactly what walker + reducer + policy produce for a
    // fully-completed walk. Uses the SAME `FileSystemWalker.measure` syscalls and
    // the SAME `ScanPolicy.default` rules; expresses the traversal/aggregation and
    // canonical (name, id) child ordering itself. On a completed walk EVERY node's
    // scanState is `.complete` (files/bundles via hasSize, dirs via subtreeCompleted,
    // denied via the denial flag), so the golden fixes `.complete` throughout.

    private func expectedTree(_ url: URL, name: String, depth: Int) -> SizeTree {
        let policy = ScanPolicy.default
        let id = url.path

        // Symlink → un-followed leaf, sized by the link (never the target).
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            let (a, l) = FileSystemWalker.measure(url)
            return leaf(id: id, name: name, kind: .file, a: a, l: l)
        }

        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let (ownA, ownL) = FileSystemWalker.measure(url)

        guard isDir else { return leaf(id: id, name: name, kind: .file, a: ownA, l: ownL) }

        if policy.isBundleLeaf(name: name) {
            let (ba, bl, fullyRead) = expectedBundleTotal(url)
            return fullyRead
                ? leaf(id: id, name: name, kind: .bundleLeaf, a: ba, l: bl)
                // Locked dir inside → denied, own entry only (matches the walker).
                : leaf(id: id, name: name, kind: .denied, a: ownA, l: ownL)
        }

        // A regular directory. Hidden entries are ALWAYS included (structural
        // walker invariant — mirror it). If we cannot enumerate it, it is denied.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []) else {
            return leaf(id: id, name: name, kind: .denied, a: ownA, l: ownL)
        }

        var kids = entries.map { expectedTree($0, name: $0.lastPathComponent, depth: depth + 1) }
        kids.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }

        let totalA = kids.reduce(ownA) { $0 + $1.allocatedBytes }
        let totalL = kids.reduce(ownL) { $0 + $1.logicalBytes }
        // Fold detail beyond the window, exactly like ScanReducer.makeTree.
        let retained = depth < Self.window ? kids : []

        return SizeTree(id: id, name: name, kind: .dir,
                        allocatedBytes: totalA, logicalBytes: totalL,
                        children: retained, scanState: .complete)
    }

    private func leaf(id: String, name: String, kind: NodeKind, a: Int64, l: Int64) -> SizeTree {
        SizeTree(id: id, name: name, kind: kind, allocatedBytes: a, logicalBytes: l,
                 children: [], scanState: .complete)
    }

    /// Recompute a bundle's opaque recursive total + whether it was fully readable
    /// (mirrors `FileSystemWalker.bundleTotal`).
    private func expectedBundleTotal(_ url: URL) -> (allocated: Int64, logical: Int64, fullyRead: Bool) {
        var totalA = FileSystemWalker.measure(url).allocated
        var totalL = FileSystemWalker.measure(url).logical
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else { return (totalA, totalL, false) }
        var fullyRead = true
        for e in entries {
            let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true {
                let (a, l) = FileSystemWalker.measure(e); totalA += a; totalL += l
            } else if v?.isDirectory == true {
                let (a, l, sub) = expectedBundleTotal(e); totalA += a; totalL += l
                fullyRead = fullyRead && sub
            } else {
                let (a, l) = FileSystemWalker.measure(e); totalA += a; totalL += l
            }
        }
        return (totalA, totalL, fullyRead)
    }

    /// Node-for-node comparison that pinpoints the first divergence by path.
    private func assertTreesEqual(_ actual: SizeTree, _ expected: SizeTree, path: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        // `id` is the path-derived node identity carried across the SizeTree DTO
        // boundary; it drives live rectangle interpolation, so the golden must
        // pin it too (review-1 point 3) — not just name/kind/size.
        XCTAssertEqual(actual.id, expected.id, "id @ \(path)", file: file, line: line)
        XCTAssertEqual(actual.name, expected.name, "name @ \(path)", file: file, line: line)
        XCTAssertEqual(actual.kind, expected.kind, "kind @ \(path)", file: file, line: line)
        XCTAssertEqual(actual.allocatedBytes, expected.allocatedBytes,
                       "allocatedBytes @ \(path)", file: file, line: line)
        XCTAssertEqual(actual.logicalBytes, expected.logicalBytes,
                       "logicalBytes @ \(path)", file: file, line: line)
        XCTAssertEqual(actual.scanState, expected.scanState, "scanState @ \(path)", file: file, line: line)
        XCTAssertEqual(actual.children.map(\.name), expected.children.map(\.name),
                       "child names @ \(path)", file: file, line: line)
        guard actual.children.count == expected.children.count else { return }
        for (a, e) in zip(actual.children, expected.children) {
            assertTreesEqual(a, e, path: "\(path)/\(a.name)", file: file, line: line)
        }
    }
}
