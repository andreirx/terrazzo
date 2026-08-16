//
//  FileSystemWalker.swift — the streaming, parallel filesystem walker.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  THE I/O ADAPTER. Every filesystem syscall in Terrazzo lives in ScanFS, and
//  the descent lives here (CLAUDE.md constraint 1; PLAN abstraction ledger:
//  "APFS quirks isolated from domain logic"). It turns a directory tree into an
//  `AsyncStream<[ScanEvent]>` that the pure `ScanReducer` folds — the walker
//  knows the disk, the reducer knows the tree, and they meet only at events.
//
//  CONCURRENCY (ratified decision 5): the root's enumeration (child STRUCTURE) is
//  emitted FIRST — before any sizing that could take time — so ALL top-level tiles
//  appear at once. THEN one concurrent task is spawned per top-level entry that
//  needs work: a sequential depth-first descent for each top-level DIRECTORY, and
//  an independent SIZING task for each top-level `.app` BUNDLE. No single folder —
//  and, critically, no large top-level bundle — can monopolize or blank the map
//  (review-2 item 1): a `.app`'s recursive sizing runs in its own task while every
//  other top-level tile streams in parallel. Workers emit into the shared
//  `EventBatcher` actor, which serializes them into ordered batches — the only
//  synchronization needed, because the reducer is order-independent by design.
//
//  POLICY (ScanPolicy): hidden always included; symlinks never followed (recorded
//  as leaves sized by the link); `.app` bundles are opaque leaves whose recursive
//  total is measured in a SEPARATE task (they stay opaque leaves in the output —
//  no child tiles — but their sizing never delays sibling discovery); the walker
//  descends FULLY (sizes true, decision 4) — the depth window is applied later,
//  in the reducer's projection. A bundle emits EXACTLY ONE `sizeUpdated` (its
//  final total, or its own entry on denial): the reducer requires at most one size
//  write per node to stay order-independent, so a bundle stays `pending` until its
//  sizing task delivers that single number — never a provisional-then-corrected
//  size that would break the commutativity invariant.
//
//  DENIAL: a directory we cannot enumerate (EPERM/EACCES) emits `accessDenied`
//  and stops there — never a silent skip (VISION §"invisible space is
//  first-class"). This extends INTO opaque bundles: if a permission failure hits
//  anywhere inside a `.app` while summing its recursive total, the bundle cannot
//  be honestly sized, so it too emits `accessDenied` (sized by its own entry) and
//  renders denied rather than reporting a silently-truncated total.
//
//  SIZING: `measure(_:)` is PUBLIC and is the single source of the allocated /
//  logical numbers, so the golden tests can recompute expected sizes with the
//  EXACT same syscalls the walker used (packet deliverable 5: "sizes by the same
//  syscalls the assertion uses").
//

import Foundation
import Darwin
#if canImport(ScanCore)
import ScanCore
#endif

public enum FileSystemWalker {

    // MARK: - Public API

    /// Walk `root` and stream `ScanEvent` batches until the whole tree is scanned,
    /// then finish the stream. Cancelling the consuming task (or terminating the
    /// stream) cancels the walk.
    ///
    /// The node id of every node is an absolute path rooted at the scan root: the
    /// root's id is `root.path`, and every descendant is `parentId + "/" + name`
    /// (see `joinId` / `classifyChildren`) — NOT the firmlink-canonicalized
    /// `entry.path`, so the whole tree shares ONE identity prefix and the focus
    /// path never jumps (review-2 item 1). Stable, path-derived — the contract
    /// `SizeTree.id` documents. Construct a `ScanReducer(rootId: root.path,
    /// rootName: root.lastPathComponent)` to fold this stream.
    public static func scan(root: URL, policy: ScanPolicy = .default) -> AsyncStream<[ScanEvent]> {
        AsyncStream { continuation in
            let work = Task {
                let batcher = EventBatcher { continuation.yield($0) }
                // Latency bound: flush accumulated events on a cadence even if the
                // size cap is not reached (packet: "~100ms or ~1000 events").
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: BatchLimits.flushIntervalNanos)
                        await batcher.flush()
                    }
                }
                await walkRoot(root, policy: policy, batcher: batcher)
                ticker.cancel()
                await batcher.flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Join a parent node id and a child name into the child's node id. A plain
    /// path join with exactly one separator — handles a root id of "/" (root scan,
    /// TZ-4) without producing "//child". This is the ONE place descendant ids are
    /// built, so the whole tree shares the scan root's identity prefix (review-2
    /// item 1). Not filesystem access — pure string composition.
    static func joinId(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// Measure a single filesystem entry's OWN size. NEVER follows symlinks
    /// (uses `lstat`): a symlink is sized by the link, its target untouched.
    ///
    /// `allocated` = on-disk allocation. Primary source is Foundation's
    /// `totalFileAllocatedSize` (a directory reports its own entry, not its
    /// subtree); fallback is `st_blocks * 512` (the classic block count). For a
    /// symlink we always use `st_blocks` (Foundation would resolve the target).
    /// `logical` = `st_size` (apparent bytes). Returns (0,0) if the entry vanished
    /// (a scan/FS race) — honest zero, not a crash.
    public static func measure(_ url: URL) -> (allocated: Int64, logical: Int64) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return (0, 0) }
        let logical = Int64(st.st_size)
        let blockBytes = Int64(st.st_blocks) * 512

        if (st.st_mode & S_IFMT) == S_IFLNK {
            return (blockBytes, logical) // symlink: never resolve the target
        }
        if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let a = v.totalFileAllocatedSize {
            return (Int64(a), logical)
        }
        return (blockBytes, logical)
    }

    // MARK: - Descent

    /// Enumerate the root, emit its child STRUCTURE + immediate (non-bundle) sizes
    /// up front so every top-level tile appears at once, THEN fan out one concurrent
    /// task per top-level directory (DFS descent) AND one per top-level `.app`
    /// bundle (sizing). Root structure is emitted BEFORE any bundle sizing begins,
    /// so a large top-level bundle can never hold the map blank (review-2 item 1).
    /// Finish with the root's completion once every worker has drained.
    private static func walkRoot(_ root: URL, policy: ScanPolicy, batcher: EventBatcher) async {
        let rootId = root.path
        let (a, l) = measure(root)
        await batcher.add([.sizeUpdated(nodeId: rootId, allocated: a, logical: l)])

        guard let classified = classifyChildren(of: root, parentId: rootId, policy: policy) else {
            await batcher.add([.accessDenied(nodeId: rootId)])
            return
        }
        // Structure first (every top-level tile now exists), then the sizes we
        // already have (dirs' own entries, files, symlinks). Bundles are NOT sized
        // here — they get their own task below and stay pending until it finishes.
        await batcher.add([.childrenDiscovered(parentId: rootId, children: classified.stubs)])
        await batcher.add(classified.sizeEvents)

        await withTaskGroup(of: Void.self) { group in
            for (url, id) in classified.dirsToRecurse {
                group.addTask { await walkDirectory(url, id: id, policy: policy, batcher: batcher) }
            }
            for (url, id) in classified.bundlesToSize {
                group.addTask { await sizeBundle(url, id: id, batcher: batcher) }
            }
        }
        await batcher.add([.subtreeCompleted(nodeId: rootId)])
    }

    /// Sequential depth-first descent of one subtree (runs inside a top-level
    /// worker task). Emits this directory's structure/sizes, recurses into child
    /// directories, sizes any nested bundle leaves, then marks the subtree complete.
    /// Nested-bundle sizing is sequential here (not its own task): it only delays
    /// THIS subtree's own worker, never the other top-level tiles, so the
    /// ratified per-top-level-folder concurrency still holds.
    private static func walkDirectory(_ url: URL, id: String,
                                      policy: ScanPolicy, batcher: EventBatcher) async {
        if Task.isCancelled { return }

        guard let classified = classifyChildren(of: url, parentId: id, policy: policy) else {
            await batcher.add([.accessDenied(nodeId: id)])
            return
        }
        var batch: [ScanEvent] = [.childrenDiscovered(parentId: id, children: classified.stubs)]
        batch.append(contentsOf: classified.sizeEvents)
        await batcher.add(batch)

        for (childURL, childId) in classified.dirsToRecurse {
            if Task.isCancelled { return }
            await walkDirectory(childURL, id: childId, policy: policy, batcher: batcher)
        }
        for (bundleURL, bundleId) in classified.bundlesToSize {
            if Task.isCancelled { return }
            await sizeBundle(bundleURL, id: bundleId, batcher: batcher)
        }
        await batcher.add([.subtreeCompleted(nodeId: id)])
    }

    /// Size one opaque `.app` bundle and emit its SINGLE result. Runs in its own
    /// task at the root (so it never blocks sibling discovery) or inline within a
    /// subtree worker. `bundleTotal` observes cancellation (returns nil), in which
    /// case we emit nothing — the walk is being torn down.
    ///
    /// A fully-readable bundle → one `sizeUpdated` (recursive total) + completion.
    /// A bundle with an unreadable directory inside cannot be honestly sized, so —
    /// exactly like any un-enterable directory — it is sized by its OWN entry and
    /// marked `accessDenied`: a "we don't know" tile, never a silently-truncated
    /// total (VISION §"invisible space is first-class").
    private static func sizeBundle(_ url: URL, id: String, batcher: EventBatcher) async {
        guard let (ba, bl, fullyRead) = bundleTotal(url) else { return } // cancelled
        if fullyRead {
            await batcher.add([.sizeUpdated(nodeId: id, allocated: ba, logical: bl),
                               .subtreeCompleted(nodeId: id)])
        } else {
            let (ownA, ownL) = measure(url)
            await batcher.add([.sizeUpdated(nodeId: id, allocated: ownA, logical: ownL),
                               .accessDenied(nodeId: id)])
        }
    }

    // MARK: - Classification

    private struct Classified {
        var stubs: [ChildStub] = []
        /// Immediate own-entry sizes for everything sized SYNCHRONOUSLY during
        /// classification: files, symlinks, and directories' own entries. Bundle
        /// leaves are NOT here — they are sized asynchronously (see `bundlesToSize`)
        /// so their recursive walk never blocks emitting the parent's structure.
        var sizeEvents: [ScanEvent] = []
        /// Child directories to descend into (regular dirs only).
        var dirsToRecurse: [(URL, String)] = []
        /// Opaque `.app` bundle leaves whose recursive total the caller must measure
        /// via `sizeBundle` — in its own task at the root, sequentially in a subtree.
        var bundlesToSize: [(URL, String)] = []
    }

    /// Enumerate `dir`'s immediate children and classify each into a stub, plus the
    /// work each kind still needs (an immediate size event, a directory to recurse,
    /// or a bundle to size). Returns `nil` iff the directory could not be enumerated
    /// (caller emits `accessDenied`). Performs NO bundle sizing itself — that is
    /// deferred so this returns promptly and the parent's structure emits at once.
    ///
    /// Entries are sorted by path so a single worker's emission order is
    /// deterministic; the reducer re-sorts by name regardless, so this only aids
    /// reproducibility of the stream itself.
    private static func classifyChildren(of dir: URL, parentId: String,
                                         policy: ScanPolicy) -> Classified? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        // Hidden entries are ALWAYS enumerated (never `.skipsHiddenFiles`):
        // surfacing "typically hidden" paths IS the product (VISION). This is a
        // structural invariant, not a configurable option (review-1 point 2).
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []) else {
            return nil
        }

        var out = Classified()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let name = entry.lastPathComponent
            // Child id = parentId joined with the child name — NOT `entry.path`.
            // `FileManager.contentsOfDirectory` canonicalizes enumerated URLs
            // through firmlinks/symlinks (`/tmp/x` → `/private/tmp/x`,
            // `/var/…` → `/private/var/…`), so `entry.path` would prefix children
            // with a DIFFERENT root than the scan root's own id and the focus path
            // would jump identity on the first dive (review-2 item 1). Deriving the
            // id from the parent keeps every descendant under the chosen scan-root
            // identity — still an absolute path that Finder resolves (the alias is a
            // symlink), and identical to `entry.path` when no aliasing occurs (e.g.
            // the `/Users/apple` home scan). The real (canonical) `entry` URL is
            // still used for all FS access below — only the id string is derived.
            let cid = Self.joinId(parentId, name)
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = vals?.isSymbolicLink ?? false
            let isDir = vals?.isDirectory ?? false
            let (alloc, logi) = measure(entry)

            if isSymlink {
                // Never followed: a leaf sized by the link itself.
                out.stubs.append(ChildStub(id: cid, name: name, kind: .file))
                out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: alloc, logical: logi))
            } else if isDir && policy.isBundleLeaf(name: name) {
                // Opaque leaf. Its stub appears NOW (so the tile shows immediately,
                // rendered pending), but its recursive sizing is DEFERRED to
                // `sizeBundle` — measuring a large bundle inline would block the
                // whole parent's structure emission (review-2 item 1). No size event
                // is emitted here: the bundle carries exactly one, delivered later.
                out.stubs.append(ChildStub(id: cid, name: name, kind: .bundleLeaf))
                out.bundlesToSize.append((entry, cid))
            } else if isDir {
                out.stubs.append(ChildStub(id: cid, name: name, kind: .dir))
                out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: alloc, logical: logi))
                out.dirsToRecurse.append((entry, cid))
            } else {
                out.stubs.append(ChildStub(id: cid, name: name, kind: .file))
                out.sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: alloc, logical: logi))
            }
        }
        return out
    }

    /// Recursively sum a bundle-leaf's OWN size + all descendants' sizes, WITHOUT
    /// emitting any child events (the bundle is one opaque tile). Symlinks inside
    /// are still not followed. This is the one place the walker reads inside a
    /// node it will not expand — the bytes are real, the detail is discarded
    /// (bundle-leaf rule, ratified decision 5 / VISION §Experience 5).
    ///
    /// `fullyRead` is `false` if ANY directory inside the bundle could not be
    /// enumerated (EPERM/EACCES). The caller must NOT trust the returned total in
    /// that case — a partial sum silently understates the bundle. Instead it marks
    /// the bundle `denied` (review TZ-2 point 3): a "we don't know" tile, not a
    /// wrong number. The flag propagates up via `&&` so one locked leaf taints the
    /// whole bundle's accounting.
    ///
    /// CANCELLATION (review-2 item 2): a bundle can be arbitrarily deep, so this
    /// otherwise-synchronous recursion checks `Task.isCancelled` at each directory
    /// and before each entry, returning `nil` the moment the scan is torn down. A
    /// `nil` propagates up unconditionally (`guard let … else { return nil }`), so a
    /// cancelled deep bundle stops promptly instead of walking to completion.
    /// `nil` is distinct from `fullyRead == false`: cancelled means "stop, emit
    /// nothing"; not-fully-read means "denied, emit the honest we-don't-know tile".
    private static func bundleTotal(_ url: URL) -> (allocated: Int64, logical: Int64, fullyRead: Bool)? {
        if Task.isCancelled { return nil }
        let (selfA, selfL) = measure(url)
        var totalA = selfA, totalL = selfL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else {
            return (totalA, totalL, false) // this directory itself is denied
        }
        var fullyRead = true
        for entry in entries {
            if Task.isCancelled { return nil }
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                let (a, l) = measure(entry)
                totalA += a; totalL += l
            } else if vals?.isDirectory == true {
                guard let (a, l, sub) = bundleTotal(entry) else { return nil }
                totalA += a; totalL += l
                fullyRead = fullyRead && sub
            } else {
                let (a, l) = measure(entry)
                totalA += a; totalL += l
            }
        }
        return (totalA, totalL, fullyRead)
    }
}
