//
//  ScanEvents.swift — the streaming scan event model + the pure reducer.
//  Module maturity: PROTOTYPE (slice TZ-2 — contracts still moving)
//
//  This is the concurrency boundary (ratified decision 5). The walker in ScanFS
//  runs ONE worker per top-level folder; every worker emits SUBTREE-TAGGED
//  `ScanEvent` batches into this SINGLE, PURE, SINGLE-THREADED reducer. No locks,
//  no shared mutable tree across threads — the events ARE the synchronization.
//
//  The reducer's defining property (tested in ScanCoreTests): it produces an
//  IDENTICAL SizeTree for ANY interleaving of subtree batches. That is achieved
//  structurally, not by luck:
//
//    1. A node is a RECORD keyed by its id. Every field is written AT MOST ONCE
//       by the walker (one `sizeUpdated` per node, one `childrenDiscovered` per
//       directory), OR is a monotonic flag (`denied`, `completed`) set by OR.
//       Field-wise merge of write-once/flag data COMMUTES → order cannot change
//       the accumulated state.
//    2. `makeTree` is a PURE function of that state. Children are emitted sorted
//       by (name, id), so directory-enumeration order (nondeterministic across
//       runs) never leaks into the tree. The output is canonical.
//
//  Because the accumulated state is order-independent and the projection is pure,
//  the tree is order-independent. QED — and the shuffle property test checks it.
//
//  RESOLVING THE TZ-1 OPEN QUESTION (NodeKind.pending vs ScanState.pending):
//  `NodeKind` is WHAT a node intrinsically IS (dir/file/bundleLeaf/denied).
//  `ScanState` is HOW FAR the scan has gotten (pending/partial/complete). The
//  live walker sets `kind` to the real kind and expresses progress ONLY through
//  `scanState`; it NEVER emits `NodeKind.pending`. `NodeKind.pending` is retained
//  in the DTO for synthetic placeholders (the TZ-1 fixture; future unaccounted
//  work) but is not produced by scanning. Rendering styles a tile as "pending"
//  from `scanState != .complete`, and "denied" from `kind == .denied` — name
//  honest, no conflation. (VISION §"invisible space is first-class".)
//
//  SIZE SEMANTICS: `sizeUpdated` carries a node's OWN (intrinsic) on-disk size —
//  a file's allocation, a directory's own entry allocation, or a bundle-leaf's
//  precomputed recursive total. The tree's `allocatedBytes` for any node is the
//  AGGREGATE = own + Σ children (recursively), computed bottom-up in `makeTree`.
//  Aggregation in the pure reducer (not the walker) is what keeps "allocated
//  sums" testable without a disk (PLAN abstraction ledger).
//

import Foundation

/// A newly discovered child, structure only — no sizes (those arrive via
/// `sizeUpdated`). Keeping discovery and sizing orthogonal is deliberate: each
/// becomes a single write per node, which is what makes the reducer's merge
/// commute (see file header).
public struct ChildStub: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: NodeKind
    /// Whether the walker judged this child HIDDEN at enumeration (leading-dot name OR
    /// `UF_HIDDEN`; see `SizeTree.isHidden`). Carried on the STUB — the same single
    /// write-once channel as `name`/`kind` — so it folds order-independently like the
    /// rest of the reducer (a size event that created a bare record before its stub just
    /// gets `isHidden` filled when the stub arrives). Additive (default `false`) so every
    /// existing `ChildStub(id:name:kind:)` call site (tests, harnesses) compiles unchanged.
    public let isHidden: Bool
    /// The child DIRECTORY's mtime (nanoseconds since the epoch) as the parent's enumeration
    /// observed it — the TZ-7 scan-time staleness key (`SizeTree.mtime`). Set only for directory
    /// kinds (`.dir`/`.bundleLeaf`), `nil` for files/symlinks (never re-listed, so no revalidation
    /// mtime is meaningful). Carried on the STUB — the same write-once channel as `name`/`kind`/
    /// `isHidden` — so it folds order-independently: a size event that created a bare record before
    /// its stub just gets `mtime` filled when the stub arrives. Additive (default `nil`) so every
    /// existing `ChildStub(id:name:kind:)`/`(…isHidden:)` call site compiles unchanged.
    public let mtime: Int64?

    public init(id: String, name: String, kind: NodeKind, isHidden: Bool = false, mtime: Int64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isHidden = isHidden
        self.mtime = mtime
    }
}

/// One fact the walker learned about the filesystem, tagged with the subtree
/// (node id) it concerns. Batched into `[ScanEvent]` for throughput. A sum type,
/// not a struct-with-flags: the four facts are mutually exclusive shapes and an
/// exhaustive `switch` in the reducer is the deterministic list of every place a
/// new fact kind would change folding behavior.
public enum ScanEvent: Equatable, Sendable {
    /// A directory's immediate children were enumerated (structure only).
    case childrenDiscovered(parentId: String, children: [ChildStub])
    /// A node's OWN on-disk size (allocated + logical). Emitted once per node.
    case sizeUpdated(nodeId: String, allocated: Int64, logical: Int64)
    /// A directory could not be entered (EPERM/EACCES). Never a silent skip.
    case accessDenied(nodeId: String)
    /// The subtree rooted at `nodeId` is fully scanned.
    case subtreeCompleted(nodeId: String)
    /// TZ-7 (the living map): a child that WAS present under `parentId` is gone from disk — the
    /// reducer PRUNES the whole subtree rooted at `childId` and RIPPLES the freed bytes up every
    /// ancestor's retained total (so a deleted folder's tile retires without a rescan; VISION §"the
    /// living map"). Additive vocabulary, ratified in PLAN §TZ-7. Idempotent: a `childRemoved` for
    /// a `childId` no longer linked under `parentId` is a no-op (the edge is already gone).
    case childRemoved(parentId: String, childId: String)
    /// TZ-7: a directory's own modification time, learned DIRECTLY (not via a parent stub) — the
    /// revalidation walk emits it after re-listing a directory, and it seeds the scan root's mtime
    /// (which has no parent stub to carry it). Sets `Node.mtime`; a write of a MORE RECENT mtime is
    /// what a subsequent revalidation compares against so an unchanged directory costs one `stat`.
    case directoryMtime(nodeId: String, mtime: Int64)
}

/// One freshly-enumerated child of a directory being REVALIDATED (TZ-7), as a raw value crossing
/// from the I/O layer (`ScanFS.FileSystemWalker.revalidationRead`) into the pure diff below. It is
/// `ChildStub` PLUS the own size the enumeration already read — the reducer needs both to decide
/// what changed. `kind` is already policy-classified by the enumerator (`.dir`/`.bundleLeaf`/
/// `.file`; a symlink is a `.file` leaf), so the diff stays policy-agnostic.
///
/// ABSTRACTION LEDGER — FreshChild: a boundary DTO (raw value crossing ScanFS→ScanCore-diff).
/// Concrete users: `FileSystemWalker.revalidationRead` (producer) + `ScanReducer.revalidationDiff`
/// (consumer). Axis: none (a fixed value shape). Rejected simpler alternative: reuse `ChildStub` —
/// it deliberately omits size (discovery/sizing orthogonality), which the diff needs, so a distinct
/// DTO is the honest carrier.
public struct FreshChild: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: NodeKind
    public let allocated: Int64
    public let logical: Int64
    public let isHidden: Bool
    public let mtime: Int64?
    public init(id: String, name: String, kind: NodeKind, allocated: Int64, logical: Int64,
                isHidden: Bool = false, mtime: Int64? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.allocated = allocated; self.logical = logical
        self.isHidden = isHidden; self.mtime = mtime
    }
}

/// The result of diffing a directory's retained children against a fresh listing (TZ-7). The
/// composition layer applies `events`, launches streamed sub-scans for `newChildIds`, and re-emits
/// only when `changed`. A struct (not a tuple) because it has three fields and two callers (pipeline
/// + the dry reducer test).
public struct RevalidationDiff: Equatable, Sendable {
    /// The fold to apply: a `directoryMtime` refresh, `childRemoved` for vanished children, a
    /// single `childrenDiscovered` for the new ones, and `sizeUpdated` for new/changed LEAVES.
    public var events: [ScanEvent]
    /// New child DIRECTORIES/bundles (absolute-path ids) needing a normal streamed sub-scan — their
    /// own size + descent (dir) or recursive total (bundle) arrive via that sub-scan, not here.
    public var newChildIds: [String]
    /// Any structural change (a removal, addition, or leaf-size change). `false` ⇒ only the mtime was
    /// refreshed, so the caller can apply the events (to cache the mtime) WITHOUT re-emitting a scene.
    public var changed: Bool
    public init(events: [ScanEvent], newChildIds: [String], changed: Bool) {
        self.events = events; self.newChildIds = newChildIds; self.changed = changed
    }
}

/// Pure, single-threaded fold of `ScanEvent` batches into a `SizeTree`.
///
/// Value type: `apply` mutates in place, `makeTree` snapshots. Constructed with
/// the scan root's identity (which the walker and the App agree on — both derive
/// it from the same root URL). NOT thread-safe by design — it is meant to be fed
/// from exactly one thread (the App's main actor); concurrency is upstream, in
/// the walker, and is dissolved into ordered event delivery before it reaches
/// here (ratified decision 5).
public struct ScanReducer {
    /// The DEFAULT area-weight transform for the projection: linear (weight == bytes,
    /// clamped ≥ 0). ScanCore stays independent of visualization POLICY — it takes a bare
    /// `(bytes) -> weight` function and never learns whether the caller means linear or log
    /// (that named enum, `AreaScale`, lives in TreemapCore; review-1 change 3). The
    /// composition layer passes the SAME transform the treemap's Squarify uses, so the
    /// pruned set matches the rendered partition; when no transform is supplied (the reducer's
    /// own tests, the full non-area-bounded path) this identity-on-non-negative default applies.
    public static let linearWeight: (Int64) -> Double = { Double(max(0, $0)) }

    /// A node under construction. Fields are filled as facts arrive, in any
    /// order. `kind`/`scanState` are DERIVED (see `outputKind`/`outputState`),
    /// never stored, so they cannot depend on write order.
    private struct Node {
        var name: String
        /// The kind reported by the parent's `childrenDiscovered` stub. `nil`
        /// until the stub arrives (a node can be referenced by a size event
        /// before its stub under interleaving). `denied` overrides this at
        /// projection time.
        var stubKind: NodeKind?
        var ownAllocated: Int64 = 0
        var ownLogical: Int64 = 0
        /// Child ids as a set — arrival order is discarded; `makeTree` sorts.
        var childIds: Set<String> = []
        /// This node's id in its parent's `childIds` — set EXACTLY ONCE, when the
        /// incoming edge is added (the parent's `childrenDiscovered`, or `reRoot`'s
        /// graft). `nil` for the current scan root (no parent) and for a node whose
        /// parent edge has not arrived yet. Used only to propagate retained-total
        /// deltas upward (`bumpSubtree`); a node has exactly one parent by
        /// filesystem structure (ids are absolute paths).
        var parentId: String?
        /// RETAINED EXACT subtree totals = own + Σ (linked children's retained
        /// totals), maintained INCREMENTALLY by `bumpSubtree` on every own-size
        /// write and every edge addition. Order-independent because the only
        /// mutations are additive deltas pushed up the parent chain, and addition
        /// commutes — so the invariant `subtree == own + Σ children.subtree` holds
        /// after ANY interleaving, at EVERY snapshot (partial totals included).
        /// This is what lets `build` read a beyond-window total in O(1) instead of
        /// traversing every hidden descendant (the focus-rooted-projection bound the
        /// operator ratified: work is O(focus subtree ∩ window), not O(retained)).
        var subtreeAllocated: Int64 = 0
        var subtreeLogical: Int64 = 0
        var hasSize = false
        var discoveredChildren = false
        var denied = false
        var completed = false
        /// Walker's hidden judgment (leading-dot OR UF_HIDDEN), written ONCE from the
        /// child's stub — a write-once field like `name`/`stubKind`, so it is
        /// order-independent (the reducer's defining property). The visualization
        /// "Show hidden" filter reads it during projection; `false` until the stub arrives.
        var isHidden = false
        /// Directory mtime (nanoseconds) — the TZ-7 staleness key. `nil` until learned, then set
        /// by the parent's stub (scan-time capture) OR by a `directoryMtime` event (revalidation /
        /// scan-root seed). NOT order-sensitive in a way that corrupts state: whichever write lands
        /// last wins, and revalidation always re-stats to establish truth, so a transient stale
        /// value only ever causes one extra (idempotent) re-enumeration, never a wrong tree.
        var mtime: Int64?
    }

    private var nodes: [String: Node]
    /// The scan root's id. MUTABLE since TZ-4b: root promotion re-roots the reducer
    /// in place (`reRoot`) — the whole node map is preserved and a new parent is
    /// grafted above the old root. Everywhere else this is written once at init.
    private var rootId: String

    /// TZ-7 (OPERATOR_NOTE 2026-08-17 #2) — TOMBSTONES: the subtree ROOTS a live `childRemoved` pruned.
    /// The reducer is "the single-threaded ordering authority"; it is where the deleted-while-subscanning
    /// race is fixed. When a directory `D` is revalidated and a new child `C` is discovered, the App
    /// launches an ASYNCHRONOUS streamed sub-scan of `C` (its own size + descent). If `C` (or an ancestor
    /// of it) is then DELETED before that sub-scan drains, the sub-scan's late events (`sizeUpdated(C…)`,
    /// `childrenDiscovered(C,…)`, …) still arrive — addressed to a node the prune already removed. Folding
    /// them via `nodes[id] ?? Node()` would FABRICATE an ORPHAN: it never renders (no parent edge, so
    /// `bumpSubtree` cannot reach the root and no tile is projected), but the flat scan-root accumulators
    /// `rootAllocatedBytes`/`processedCount` — incremented on the first own-size write regardless of
    /// linkage — would INFLATE (the reviewer's finding). So: a `childRemoved` that actually removes an edge
    /// records the removed child id here, and `apply` DROPS any fabricating event whose target lies at or
    /// under a tombstoned root (counting the drop in `droppedOrphanEvents`). A legitimate re-appearance — a
    /// RETAINED parent re-linking the id via `childrenDiscovered` — CLEARS the tombstone, so a
    /// delete+recreate re-admits the child. Empty during the initial scan (prunes are live-only), so the
    /// reducer's order-independence property (shuffle test) is untouched: the gate is inert until a live
    /// prune records the first tombstone.
    ///
    /// DEFERRED (documented tech debt): a tombstone is cleared only on re-appearance, so over a long
    /// session `prunedRoots` grows with distinct deleted-and-never-recreated subtree roots (one string
    /// each — bounded by real filesystem churn, not node count). Time/task-scoped eviction (drop a
    /// tombstone once the subtree's in-flight sub-scan has provably drained) is the named extension point;
    /// v1 keeps the simple self-healing set because correctness never depends on eviction — only memory.
    private var prunedRoots: Set<String> = []

    /// Count of events DROPPED because they addressed a pruned/unknown (tombstoned) subtree — surfaced in
    /// TZTRACE (OPERATOR_NOTE #2: "honesty over silence"). A late sub-scan of a since-deleted child
    /// contributes its dropped events here rather than silently inflating totals. Monotonic; 0 whenever no
    /// live prune has orphaned any in-flight sub-scan.
    public private(set) var droppedOrphanEvents: Int = 0

    /// Count of filesystem entries the walker has STAT'd so far — the numerator of the
    /// file-count progress bar (TZ-4, PLAN ratified). Incremented exactly once per node
    /// the first time it receives its OWN size (`sizeUpdated`), which the walker emits
    /// once per stat'd entry: files, symlinks, directories' own entries, and sized
    /// bundles. This counts BOTH files AND directories (each is one `stat`, one inode),
    /// so the numerator and the statfs used-inode denominator (`f_files − f_ffree`)
    /// count the same population — the consistency argument the progress ratio needs.
    /// Derived from a monotonic first-write flag, so it stays order-independent like the
    /// rest of the reducer (a size event arrives at most once per node by walker
    /// contract). A denied directory is still counted (its parent stat'd its own entry
    /// before the denial), matching an inode that exists but could not be enumerated.
    public private(set) var processedCount: Int = 0

    /// The SCAN ROOT's full recursive allocated/logical totals — the status bar's "Scanned",
    /// maintained INCREMENTALLY (O(1) per event) so it does not re-sum the whole map on every
    /// emit. A node's own size is written at most once (walker contract + the `hasSize`
    /// false→true guard), and the root's recursive total is exactly Σ of every node's OWN
    /// size, so accumulating each first own-size write yields the root total directly. This is
    /// the same monotonic first-write accounting `processedCount` uses, and it is
    /// root-AGNOSTIC: `reRoot` only re-parents nodes (it never changes any own size), so the
    /// accumulator stays correct across promotion — it is Σ over ALL retained nodes, which is
    /// always the current root's full recursive total. Decoupled from the projected tree,
    /// which since focus-rooted projection is rooted at the FOCUS, not the scan root.
    /// (Only the allocated total is accumulated — the status bar's "Scanned" is allocated;
    /// logical is shown per-node in hover detail, not as a scan-root aggregate.)
    public private(set) var rootAllocatedBytes: Int64 = 0

    /// - Parameters:
    ///   - rootId: the scan root's stable id (its absolute path). The walker emits
    ///     events tagged with ids derived from the same root, so they match.
    ///   - rootName: display name for the root tile.
    public init(rootId: String, rootName: String) {
        self.rootId = rootId
        self.nodes = [rootId: Node(name: rootName, stubKind: .dir)]
    }

    // MARK: - Root promotion (TZ-4b — "root promotion", ratified)

    /// FULL-STATE RE-ROOT GRAFT (layer a of root promotion). Promote the scan one
    /// level up: the current root becomes an ordinary CHILD of `newRootId`, and the
    /// reducer's root id moves to `newRootId`. The ENTIRE existing node map is kept
    /// verbatim — nothing is discarded, nothing is replayed. The only mutations are:
    ///   1. create/merge the new root node (name + `.dir` stub) and add the OLD root
    ///      id to its children, and
    ///   2. move `rootId` to `newRootId`.
    /// Every previously-scanned node keeps its id, sizes, child set, and flags, so the
    /// grafted subtree projects byte-identically under the new root (the graft test
    /// pins subtree identity/sizes/scanStates exactly). `processedCount` is untouched:
    /// nothing was re-stat'd. The new root's OWN size and its NEW siblings arrive later
    /// via the ScanFS sibling-exclusion walk (`FileSystemWalker.scanSiblings`), folded
    /// through the normal `apply` path — a size event for the already-grafted child
    /// would be a no-op on `processedCount` (its `hasSize` is already true), so a
    /// re-emission (there is none by contract) could not double-count either.
    ///
    /// Idempotent-safe merge: `newRootId` may already exist as a node (e.g. it was
    /// discovered as an ancestor stub); we merge onto it rather than overwrite, so no
    /// prior state under that id is lost.
    public mutating func reRoot(to newRootId: String, newRootName: String) {
        guard newRootId != rootId else { return } // already there — nothing to promote
        let oldRootId = rootId
        var newRoot = nodes[newRootId] ?? Node(name: newRootName, stubKind: .dir)
        newRoot.name = newRootName
        newRoot.stubKind = .dir
        let grafted = newRoot.childIds.insert(oldRootId).inserted // graft the old root as a child
        nodes[newRootId] = newRoot
        // Graft is an edge addition, so it uses the SAME retained-total propagation as any
        // other edge (see `bumpSubtree`): the old root's full retained subtree total folds
        // into the new root exactly once. Guarded by `.inserted` so a repeated promotion to
        // an already-grafted parent (idempotent) cannot double-count. `parentId` is set on the
        // old root here — it had none (it was the root) — completing the upward chain the new
        // siblings' size events will later climb.
        if grafted {
            nodes[oldRootId]?.parentId = newRootId
            let old = nodes[oldRootId]
            bumpSubtree(from: newRootId,
                        allocated: old?.subtreeAllocated ?? 0,
                        logical: old?.subtreeLogical ?? 0)
        }
        rootId = newRootId
    }

    // MARK: - Fold

    public mutating func apply(_ batch: [ScanEvent]) {
        for event in batch { apply(event) }
    }

    public mutating func apply(_ event: ScanEvent) {
        switch event {
        case let .childrenDiscovered(parentId, children):
            // TZ-7 drop (OPERATOR_NOTE #2): a discovery under a pruned/unknown (tombstoned) parent is a
            // late sub-scan of a since-deleted subtree — DROP the whole event (never re-materialize the
            // parent or attach orphan children) and count it. Inert during the initial scan (no tombstones).
            if isTombstoned(parentId) { droppedOrphanEvents += 1; return }
            // Create/merge each child record first (different ids), then write the
            // parent last. name/kind come ONLY from the stub → a single write; a
            // size event that created a bare record first just gets its identity
            // filled here. Creation order is irrelevant (write-once fields).
            for stub in children {
                // A RETAINED parent re-linking this child is a legitimate re-appearance (delete+recreate):
                // clear any tombstone so the child's fresh sub-scan folds normally. Idempotent for a child
                // that was never tombstoned (the common case).
                prunedRoots.remove(stub.id)
                var child = nodes[stub.id] ?? Node(name: stub.name)
                child.name = stub.name
                child.stubKind = stub.kind
                child.isHidden = stub.isHidden // write-once from the stub (order-independent)
                if let m = stub.mtime { child.mtime = m } // scan-time dir mtime (TZ-7); nil for leaves
                nodes[stub.id] = child
            }
            var parent = nodes[parentId] ?? Node(name: "")
            parent.discoveredChildren = true
            // Track which edges are GENUINELY NEW (Set.insert reports it): only a new edge
            // may fold a child's retained subtree total into the parent, so a re-stated stub
            // (the idempotent graft reference the sibling walk emits, or any duplicate batch)
            // cannot double-count.
            var newlyLinked: [String] = []
            for stub in children where parent.childIds.insert(stub.id).inserted {
                newlyLinked.append(stub.id)
            }
            nodes[parentId] = parent
            // Set the parent pointer on each newly-linked child and push its CURRENT retained
            // total up through the parent's ancestor chain. If the child's own/descendant sizes
            // arrive LATER, their deltas climb this same chain (the child's `parentId` now
            // points here) — so the order of "edge vs sizes" never changes the final totals.
            for cid in newlyLinked {
                nodes[cid]?.parentId = parentId
                let child = nodes[cid]
                bumpSubtree(from: parentId,
                            allocated: child?.subtreeAllocated ?? 0,
                            logical: child?.subtreeLogical ?? 0)
            }

        case let .sizeUpdated(nodeId, allocated, logical):
            // TZ-7 drop (OPERATOR_NOTE #2): an own-size for a tombstoned node is a late sub-scan of a
            // pruned subtree. Dropping it here is THE fix for the flat-accumulator inflation — this is the
            // one arm that would otherwise bump `rootAllocatedBytes`/`processedCount` for an orphan.
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return }
            var node = nodes[nodeId] ?? Node(name: "")
            // Count this entry as "processed" exactly once (the first own-size write), and
            // accumulate its own size into the scan-root total on the SAME transition. The
            // walker emits one size event per stat'd node, but count/accumulate from the
            // false→true transition so both stay robust to a duplicate/replayed batch and a
            // pure function of the accumulated state.
            if !node.hasSize { processedCount += 1 }
            // The retained-total delta is the CHANGE in own size (first write: 0→size, so the
            // delta equals the full size; a live re-size: old→new; a replayed same-size batch:
            // a no-op 0). Push it up the ancestor chain AND into the scan-root accumulator —
            // review-4 (TZ-7): the accumulator previously moved only on the FIRST write, so
            // live re-sizes updated subtree totals while `scannedBytes`/status drifted from
            // the truth. Delta-accumulation keeps root == Σ own sizes under first writes,
            // live changes, replays, and prunes (prune subtracts own sizes symmetrically).
            let dAllocated = allocated - node.ownAllocated
            let dLogical = logical - node.ownLogical
            rootAllocatedBytes += dAllocated
            node.ownAllocated = allocated
            node.ownLogical = logical
            node.hasSize = true
            nodes[nodeId] = node
            bumpSubtree(from: nodeId, allocated: dAllocated, logical: dLogical)

        case let .accessDenied(nodeId):
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return } // late event under a pruned root
            var node = nodes[nodeId] ?? Node(name: "")
            node.denied = true
            nodes[nodeId] = node

        case let .subtreeCompleted(nodeId):
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return } // late event under a pruned root
            var node = nodes[nodeId] ?? Node(name: "")
            node.completed = true
            nodes[nodeId] = node

        case let .childRemoved(parentId, childId):
            prune(parentId: parentId, childId: childId)

        case let .directoryMtime(nodeId, mtime):
            // TZ-7 drop (OPERATOR_NOTE #2 / review-1 change 1): a delayed `directoryMtime` for a
            // tombstoned node (e.g. an ancestor prune removed it while its own read was in flight) would
            // otherwise re-materialize an unlinked orphan via `nodes[id] ?? Node()`. Drop + count.
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return }
            var node = nodes[nodeId] ?? Node(name: "")
            node.mtime = mtime
            nodes[nodeId] = node
        }
    }

    /// Whether `id` lies at or under a pruned subtree root (TZ-7 tombstone check, OPERATOR_NOTE #2). Fast
    /// path: no tombstones ⇒ never (so the initial scan pays nothing and stays order-independent). Else
    /// the id itself, then each `/`-separated ANCESTOR, is checked against `prunedRoots` — O(path depth),
    /// a small bounded constant. A pruned subtree records only its ROOT (not every descendant), so a
    /// late `sizeUpdated` for a deep descendant of a pruned dir is caught by walking up to that root.
    private func isTombstoned(_ id: String) -> Bool {
        guard !prunedRoots.isEmpty else { return false }
        if prunedRoots.contains(id) { return true }
        var cur = id
        while let slash = cur.lastIndex(of: "/"), slash != cur.startIndex {
            cur = String(cur[cur.startIndex..<slash])
            if prunedRoots.contains(cur) { return true }
        }
        return false
    }

    // MARK: - Prune (TZ-7 — the living map)

    /// Remove `childId` (and its whole subtree) from under `parentId`, rippling the freed bytes up
    /// every ancestor's retained total and out of the scan-root accumulators. The inverse of an edge
    /// addition + a fold: exactly the mutations `apply` made to grow the subtree, reversed, so the
    /// reducer's invariants (`subtree == own + Σ linked children.subtree`, `rootAllocatedBytes ==
    /// Σ retained own sizes`, `processedCount == retained stat'd entries`) hold AFTER the prune too.
    ///
    /// Idempotent / honest: only prunes when the edge is actually present. A `childRemoved` for a
    /// child not currently linked under `parentId` (a duplicate, or a race with an ancestor prune
    /// that already took the whole subtree) removes NO edge and returns — it can neither double-
    /// subtract nor delete an unrelated node. No cycles: a `childIds` set is a tree by filesystem
    /// structure (ids are absolute paths), so the DFS deletion terminates.
    private mutating func prune(parentId: String, childId: String) {
        guard var parent = nodes[parentId], parent.childIds.remove(childId) != nil else {
            return // edge not present — nothing to remove (idempotent)
        }
        nodes[parentId] = parent
        // TOMBSTONE the removed subtree root (OPERATOR_NOTE #2): late events from an in-flight sub-scan of
        // this now-deleted child (or its descendants) are DROPPED by `apply` until a retained parent
        // legitimately re-links it. Only the root is recorded — `isTombstoned` catches descendants by
        // walking up their path — so a mass delete records one id per removed edge, not one per node.
        prunedRoots.insert(childId)
        // Ripple the pruned child's WHOLE retained total out of the parent and every ancestor —
        // one negative delta up the chain, the exact reverse of the edge-addition bump. (The child's
        // own subtree total already includes its descendants, so a single delta suffices.)
        let child = nodes[childId]
        bumpSubtree(from: parentId,
                    allocated: -(child?.subtreeAllocated ?? 0),
                    logical: -(child?.subtreeLogical ?? 0))
        // Delete the subtree node-by-node, backing out each node's own contribution to the
        // scan-root accumulators (so "Scanned" and the processed count track the LIVE tree, the
        // documented invariant of both — they are Σ/count over *retained* nodes).
        removeSubtree(childId)
    }

    /// DFS-delete the subtree rooted at `id` from the node map, decrementing `rootAllocatedBytes`
    /// and `processedCount` by each removed node's own contribution (only where it was counted — a
    /// node whose size never arrived contributed to neither). Reads children before deleting.
    private mutating func removeSubtree(_ id: String) {
        guard let node = nodes[id] else { return }
        if node.hasSize {
            processedCount -= 1
            rootAllocatedBytes -= node.ownAllocated
        }
        let children = node.childIds
        nodes[id] = nil
        for c in children { removeSubtree(c) }
    }

    // MARK: - Projection

    /// Snapshot the accumulated state into a `SizeTree`, ROOTED AT `focusId`.
    ///
    /// FOCUS-ROOTED PROJECTION (TZ-4b, OPERATOR_NOTE 2026-08-16 #2 — the resolution of
    /// the cycle-3 escalate). Before this slice `makeTree` always built from the SCAN
    /// ROOT and the visualization layer navigated down to the focus; projection cost
    /// therefore scaled with the WHOLE retained tree (measured 6.9 s on a full-volume
    /// live scan — the field regression: a dive showed a flat fill for seconds). Now the
    /// projection walks ONLY from the focus node down through the depth window, so a dive
    /// commits in O(focus subtree ∩ window), not O(retained nodes). Equivalence is exact:
    /// the focus-rooted result is byte-identical to the old full-build-then-navigate for
    /// the same focus (pinned by the projection-equivalence test) — only the WORK differs.
    ///
    /// - `allocatedBytes`/`logicalBytes` are ALWAYS the full recursive totals
    ///   (sizes true — ratified decision 4). They are READ from each node's RETAINED
    ///   subtree total (`Node.subtreeAllocated/Logical`), maintained incrementally during
    ///   the fold — NOT recomputed here. So `build` never traverses a node below the
    ///   window: the projection is O(focus subtree ∩ window), independent of how much mass
    ///   is retained beneath the boundary. (This is the review-3 correction: the earlier
    ///   boundary code summed hidden descendants via a recursive `subtreeTotals`, which
    ///   reintroduced O(whole subtree) cost and contradicted the ratified bound.)
    /// - Children are materialized only while `depth < depthWindow`; below that the
    ///   `children` array is empty but the node's total STILL counts every hidden
    ///   descendant (it is the retained total). Totals are unchanged by the window — the
    ///   invariant the depth-window test pins.
    ///
    /// - Parameters:
    ///   - focusId: the node to root the projection at. `nil` ⇒ the scan root (the
    ///     original whole-tree behavior; used by the root view and the reducer's own tests).
    ///   - depthWindow: max retained child depth (the focus is depth 0).
    ///   - excluding: node ids to EXCLUDE from the projection (the IGNORE lens, TZ-5): an
    ///     excluded child is dropped from its parent's child list so its SIBLINGS renormalize
    ///     into the freed area, while every ANCESTOR keeps its area (an ancestor's own weight
    ///     among ITS siblings is untouched — only the excluded node's direct siblings share out
    ///     its space). A pure projection parameter, NEUTRAL to the reducer (it never learns
    ///     WHY a node is excluded); the pipeline owns the ignore-lens meaning. Default `[]`.
    ///   - includeHidden: when `false`, HIDDEN nodes (`Node.isHidden`) are excluded from the
    ///     projection too (the "Show hidden files" lens, TZ-5). Default `true` (scan always
    ///     includes hidden; the DEFAULT view shows them).
    ///   - weight: the per-node area-weight transform `(bytes) -> weight` (TZ-5). Applied to the
    ///     area-bounded split so the projection materializes exactly the subtrees the
    ///     SAME-weighted Squarify will render. ScanCore is neutral to WHICH scale it is (linear
    ///     or log) — the composition layer supplies `AreaScale.weight` (TreemapCore). Ignored on
    ///     the full (`minRenderArea == 0`) path. Defaults to linear (`linearWeight`).
    public func makeTree(focusId: String? = nil,
                         depthWindow: Int = ScanPolicy.default.depthDetailWindow,
                         excluding: Set<String> = [],
                         includeHidden: Bool = true,
                         weight: (Int64) -> Double = ScanReducer.linearWeight) -> SizeTree {
        var pruned = 0
        var hidden: Int64 = 0
        return build(id: focusId ?? rootId, depth: 0, depthWindow: depthWindow,
                     area: 0, minRenderArea: 0, excluding: excluding,
                     includeHidden: includeHidden, weight: weight,
                     prunedBelowArea: &pruned, hiddenFilteredBytes: &hidden)
    }

    /// AREA-BOUNDED focus-rooted projection for the RENDER path (TZ-4b cycle-6 resolution).
    /// Identical to `makeTree` EXCEPT a child subtree whose ESTIMATED rendered area (the
    /// `viewportArea` split down by retained-total weight, level by level) falls below
    /// `minRenderArea` is NOT materialized — it would be sub-pixel-culled by the composition
    /// layer anyway, so omitting it leaves the RENDERED scene unchanged while bounding projection
    /// cost by what is VISIBLE, not by every node in the window. That is what makes even a
    /// VOLUME-ROOT emit O(visible tiles) rather than O(all-in-window): the ratified ≤200 ms held
    /// for a small dive since OPERATOR_NOTE #2, but the root/near-root projection still
    /// materialized tens of thousands of sub-pixel nodes (~900 ms measured live at -O), which
    /// this collapses to the visible set.
    ///
    /// Returns the tree AND `prunedBelowArea` — how many subtrees were dropped as sub-pixel — so
    /// the caller folds it into `belowPixelCount` and the drop is NEVER SILENT (the
    /// invisible-space / no-silent-truncation contract). It is a FLOOR on the true dropped node
    /// count: a pruned subtree is counted ONCE at its root, not per hidden descendant (the old
    /// layout cull likewise took a culled parent's children with it).
    ///
    /// TZ-5 LENSES ride along as pure projection parameters (see `makeTree`): `excluding`
    /// (the ignore set) and `includeHidden` drop nodes so siblings renormalize; `weight`
    /// weights the area split so log/linear pruning matches the layer's Squarify (the
    /// composition layer passes the same transform to both). It ALSO
    /// returns `hiddenFilteredBytes` — the summed retained total of the nodes dropped for
    /// being HIDDEN (not for being ignored: ignored subtrees are accounted by the App from
    /// the ignored tile's bytes, and are never descended, so their hidden descendants are
    /// subsumed there — the no-double-count rule the composition requires). This keeps the
    /// filtered-hidden MASS reportable in the status bar (never a silent drop — the
    /// invisible-space principle applied to user-hidden mass).
    public func makeRenderTree(focusId: String, depthWindow: Int,
                               minRenderArea: Double, viewportArea: Double,
                               excluding: Set<String> = [],
                               includeHidden: Bool = true,
                               weight: (Int64) -> Double = ScanReducer.linearWeight)
        -> (tree: SizeTree, prunedBelowArea: Int, hiddenFilteredBytes: Int64) {
        var pruned = 0
        var hidden: Int64 = 0
        let t = build(id: focusId, depth: 0, depthWindow: depthWindow,
                      area: viewportArea, minRenderArea: minRenderArea, excluding: excluding,
                      includeHidden: includeHidden, weight: weight,
                      prunedBelowArea: &pruned, hiddenFilteredBytes: &hidden)
        return (t, pruned, hidden)
    }

    private func build(id: String, depth: Int, depthWindow: Int,
                       area: Double, minRenderArea: Double,
                       excluding: Set<String>, includeHidden: Bool, weight: (Int64) -> Double,
                       prunedBelowArea: inout Int, hiddenFilteredBytes: inout Int64) -> SizeTree {
        let node = nodes[id] ?? Node(name: id)
        let kind = outputKind(node)

        // Children are MATERIALIZED only inside the window; below it the array is empty.
        // Either way the node's totals come from its RETAINED subtree total — read in O(1),
        // never recomputed — so `build` visits only nodes strictly inside the window. This
        // is the focus-rooted bound the operator ratified (review-3 correction).
        let retained: [SizeTree]
        if depth < depthWindow {
            if minRenderArea > 0 && area > 0 {
                // AREA-BOUNDED PROJECTION. Split this node's area among children in proportion
                // to their retained totals — the SAME weighting the layer's Squarify uses — and
                // recurse only into children that could render. The estimate is an UPPER bound
                // on the child's true rendered area (badge-flooring only STEALS area from
                // non-badge siblings, never grants more; the inset border only shrinks it), so a
                // pruned child is provably sub-pixel and would be culled — never a visible tile.
                // DENIED children are ALWAYS kept: their area is a floored badge, not
                // proportional to their (unknown) size, and the App discloses the full denied
                // list from the retained tree.
                //
                // PRUNE BEFORE SORTING (the O(visible) bound the ≤200 ms target needs). A
                // high-fanout directory (a cache dir with tens of thousands of entries in the
                // window) must NOT pay an O(K log K) canonical sort of children that all prune
                // away — that sort, with its per-comparison name lookups, was the dominant cost
                // of the volume-root emit (~900 ms live). So: one O(children) pass to total the
                // weights and drop the sub-pixel subtrees, THEN sort only the survivors (whose
                // count is viewport-bounded: a rect of area `area` holds at most `area/minArea`
                // children ≥ minArea).
                // TZ-5 LENSES first (one O(children) pass): SKIP ignored + hidden-filtered
                // children BEFORE weighting, so `totalW` excludes them and the survivors
                // RENORMALIZE into the freed area (the ratified ignore behavior). Hidden mass
                // is accounted HERE, exactly once; ignored children are skipped WITHOUT hidden
                // accounting (the App owns their mass) — the no-double-count rule. Weights use
                // the injected `weight` transform so a log/linear projection prunes exactly what
                // the same-weighted Squarify will render (the composition layer passes both).
                var totalW = 0.0
                for cid in node.childIds {
                    if excluding.contains(cid) { continue }
                    if !includeHidden, nodes[cid]?.isHidden == true {
                        hiddenFilteredBytes += nodes[cid]?.subtreeAllocated ?? 0
                        continue
                    }
                    totalW += weight(nodes[cid]?.subtreeAllocated ?? 0)
                }
                var kept: [(id: String, area: Double)] = []
                for cid in node.childIds {
                    if excluding.contains(cid) { continue }                       // ignored
                    if !includeHidden, nodes[cid]?.isHidden == true { continue }   // counted above
                    let child = nodes[cid]
                    let w = weight(child?.subtreeAllocated ?? 0)
                    let childArea = totalW > 0 ? area * w / totalW : 0
                    if !(child?.denied ?? false) && childArea < minRenderArea {
                        prunedBelowArea += 1 // count the dropped subtree (a floor — see makeRenderTree)
                    } else {
                        kept.append((cid, childArea))
                    }
                }
                kept.sort { a, b in
                    let na = nodes[a.id]?.name ?? a.id
                    let nb = nodes[b.id]?.name ?? b.id
                    return na == nb ? a.id < b.id : na < nb
                }
                retained = kept.map {
                    build(id: $0.id, depth: depth + 1, depthWindow: depthWindow,
                          area: $0.area, minRenderArea: minRenderArea, excluding: excluding,
                          includeHidden: includeHidden, weight: weight,
                          prunedBelowArea: &prunedBelowArea, hiddenFilteredBytes: &hiddenFilteredBytes)
                }
            } else {
                // Full projection: sort children canonically so enumeration order never leaks in.
                // The same TZ-5 lenses apply (ignored + hidden filtered), so a full-projection
                // consumer (e.g. a non-area-bounded view) sees the identical excluded set.
                var kids: [String] = []
                for cid in node.childIds {
                    if excluding.contains(cid) { continue }
                    if !includeHidden, nodes[cid]?.isHidden == true {
                        hiddenFilteredBytes += nodes[cid]?.subtreeAllocated ?? 0
                        continue
                    }
                    kids.append(cid)
                }
                let sortedChildIds = kids.sorted { a, b in
                    let na = nodes[a]?.name ?? a
                    let nb = nodes[b]?.name ?? b
                    return na == nb ? a < b : na < nb
                }
                retained = sortedChildIds.map {
                    build(id: $0, depth: depth + 1, depthWindow: depthWindow,
                          area: 0, minRenderArea: 0, excluding: excluding,
                          includeHidden: includeHidden, weight: weight,
                          prunedBelowArea: &prunedBelowArea, hiddenFilteredBytes: &hiddenFilteredBytes)
                }
            }
        } else {
            retained = []
        }

        return SizeTree(
            id: id,
            name: node.name,
            kind: kind,
            allocatedBytes: node.subtreeAllocated,
            logicalBytes: node.subtreeLogical,
            children: retained,
            scanState: outputState(node, kind: kind),
            isHidden: node.isHidden,
            mtime: node.mtime // TZ-7 staleness key; nil for leaves/until-known (root before first revalidation)
        )
    }

    /// Add `allocated`/`logical` to the RETAINED subtree total of `id` and of every ANCESTOR
    /// currently linked above it (inclusive of `id` itself). Walks the `parentId` chain — O(the
    /// node's current depth), a small bounded constant in a filesystem — and is the ONLY place
    /// retained totals change. Two callers push deltas here: a node's own-size write (delta =
    /// change in own size) and an edge addition (delta = the newly-linked child's whole retained
    /// total). Because every mutation is an additive delta and addition commutes, the invariant
    /// `subtree == own + Σ linked children.subtree` holds after any interleaving — the reducer's
    /// order-independence, preserved. No cycles: a `parentId` chain is strictly shallower each
    /// step (a child id is deeper than its parent), and each edge is added at most once.
    private mutating func bumpSubtree(from id: String, allocated: Int64, logical: Int64) {
        if allocated == 0 && logical == 0 { return } // no-op delta (e.g. a re-stated same size)
        var cursor: String? = id
        while let cid = cursor, var n = nodes[cid] {
            n.subtreeAllocated += allocated
            n.subtreeLogical += logical
            nodes[cid] = n
            cursor = n.parentId
        }
    }

    /// Whether the reducer has ever recorded `id` (via any event). The composition layer
    /// gates emission on this: a focus-rooted projection of an id the scan has never
    /// produced would fabricate a lone placeholder tile; the old root-rooted-then-navigate
    /// path returned an empty layout there and the pipeline kept the last good scene. This
    /// preserves that streaming behavior (never flash a bare fill for an unknown focus).
    public func contains(_ id: String) -> Bool { nodes[id] != nil }

    /// The retained KIND of `id` (denial-aware, derived exactly as the projection does — order-
    /// independent), or `nil` if the scan has never recorded `id`. TZ-7 (review-1 change 3): the
    /// composition layer reads this to decide whether a flagged path is a DIRECTORY to re-enumerate
    /// or an opaque BUNDLE LEAF to re-size — a bundle's descendants must never be exposed.
    public func kind(of id: String) -> NodeKind? {
        guard let n = nodes[id] else { return nil }
        return outputKind(n)
    }

    /// The directory mtime the reducer currently holds for `id` (the staleness key), or `nil` if not
    /// yet known. TZ-7 SERIAL CORRECTNESS (review-1 change 1): a live reconcile whose freshly-stat'd
    /// mtime is OLDER than this is a STALE snapshot — a newer revalidation already folded the
    /// directory's later state — and is dropped whole, so a slow read can never un-do a newer one
    /// (e.g. a stale `childRemoved` retiring a just-recreated child). A directory's mtime rises
    /// monotonically with every structural change to it, which is what makes the comparison sound.
    public func mtime(of id: String) -> Int64? { nodes[id]?.mtime }

    /// The retained OWN (intrinsic) size of `id`, or `nil` if unknown. TZ-7 (review-1 change 3): the
    /// bundle re-size path compares a freshly-measured recursive total against this to stay CALM —
    /// emit no `sizeUpdated` when the opaque total is unchanged — mirroring `revalidationDiff`'s
    /// own-size discipline for directories.
    public func ownSize(of id: String) -> (allocated: Int64, logical: Int64)? {
        guard let n = nodes[id] else { return nil }
        return (n.ownAllocated, n.ownLogical)
    }

    /// EVERY retained DIRECTORY-like node id (`.dir`/`.bundleLeaf`) in the subtree rooted at `id`,
    /// inclusive. TZ-7 (review-1 change 4 + review-2 change 2): a `MustScanSubDirs`/dropped-events
    /// recovery re-validates every retained directory under the flagged path (each diffed against
    /// disk). This enumeration is now COMPLETE — the earlier `cap` truncated it, so a loss over a
    /// subtree larger than the cap silently left retained directories un-revalidated while the status
    /// resumed claiming full "Live" (the reviewer's 513-dir gap). The bound that keeps a huge-subtree
    /// recovery safe now lives where it belongs — the caller's PER-DRAIN batch cap with carry-across-
    /// drains (`ScanController.drainRecovery`), which processes this full list a bounded batch at a
    /// time and stays `.degraded` until it is entirely drained. Producing the id list is O(subtree) in
    /// strings only (no I/O); the I/O — the actual re-validation — is what the caller bounds per drain.
    /// Pre-order; empty if `id` is not retained.
    public func retainedDirIds(under id: String) -> [String] {
        guard nodes[id] != nil else { return [] }
        var out: [String] = []
        var stack = [id]
        while let cur = stack.popLast() {
            guard let n = nodes[cur] else { continue }
            let k = outputKind(n)
            if k == .dir || k == .bundleLeaf { out.append(cur) }
            stack.append(contentsOf: n.childIds)
        }
        return out
    }

    /// The set of `dirId`'s current child ids — what the reducer BELIEVES is in a directory. The
    /// revalidation enumerator does not need it (the diff below reads it internally), but the FSEvents
    /// path uses `contains` to gate; kept `internal`-free (public) only if a future caller needs it.
    // (No standalone accessor is exported: `revalidationDiff` is the single entry that reads child state.)

    // MARK: - Revalidation diff (TZ-7 — the living map)

    /// Diff `dirId`'s RETAINED children against a `fresh` disk listing and produce the fold + the new
    /// children to sub-scan. PURE over the accumulated state (dry-tested in ScanCoreTests) — the I/O
    /// that produced `fresh` lives in ScanFS; applying the events + launching sub-scans is the
    /// composition layer's job. This is Tier-1/Tier-2's shared core: "re-enumerate that one directory,
    /// diff against the retained tree, emit childRemoved/childrenDiscovered/sizeUpdated accordingly"
    /// (PLAN §TZ-7).
    ///
    /// - `mtime`: the directory's freshly-stat'd mtime — always refreshed (so the next revalidation
    ///   can short-circuit on an unchanged directory).
    /// - `ownAllocated`/`ownLogical`: the directory's OWN entry size, freshly stat'd (TZ-7 review-0
    ///   change 5). A directory's own allocation grows/shrinks as entries are added/removed, so a
    ///   changed directory's rectangle total would otherwise stay stale by its own-entry allocation.
    ///   Emitted as a `sizeUpdated(dirId, …)` ONLY when it differs from the retained own size — the
    ///   fresh value is computed the SAME way the initial scan did (`st_blocks * 512`, the
    ///   `DirectoryReader` dir-own-size formula), so an unchanged directory yields NO event (calm).
    /// - `complete`: whether the enumeration read the WHOLE directory. On a PARTIAL read a child
    ///   missing from `fresh` may simply be unread, not deleted, so removals are SUPPRESSED — never
    ///   prune on incomplete data (the invisible-space / no-silent-loss discipline, inverted: do not
    ///   silently DROP a tile we merely failed to re-read). The own-size refresh is INDEPENDENT of
    ///   completeness (it comes from the directory's own `lstat`), so it still applies on a partial read.
    ///
    /// New DIRECTORIES/bundles get a stub here (so the tile appears immediately, pending) and their
    /// sizes arrive from the streamed sub-scan (`newChildIds`); new FILES/symlinks carry their size
    /// inline (the enumeration already read it). An existing file whose size changed in place emits a
    /// fresh `sizeUpdated`. Existing subdirectories are untouched — nested change is caught by THEIR
    /// own revalidation / FSEvents flag, not by a one-level focus revalidation.
    public func revalidationDiff(dirId: String, mtime: Int64,
                                 ownAllocated: Int64, ownLogical: Int64,
                                 fresh: [FreshChild], complete: Bool) -> RevalidationDiff {
        var events: [ScanEvent] = [.directoryMtime(nodeId: dirId, mtime: mtime)]
        var newChildIds: [String] = []
        var newStubs: [ChildStub] = []
        var changed = false

        let node = nodes[dirId]
        // Own-entry size refresh (review-0 change 5): emit only on a real change to the directory's
        // own allocation, so a stale own-size does not keep a changed directory's total short, while
        // an unchanged directory (same `st_blocks * 512`) stays calm — no event, no re-emit.
        if node?.ownAllocated != ownAllocated || node?.ownLogical != ownLogical {
            events.append(.sizeUpdated(nodeId: dirId, allocated: ownAllocated, logical: ownLogical))
            changed = true
        }

        let known = node?.childIds ?? []
        let freshIds = Set(fresh.map(\.id))

        // Removals (only on a COMPLETE read — see `complete` doc).
        if complete {
            for kid in known where !freshIds.contains(kid) {
                events.append(.childRemoved(parentId: dirId, childId: kid))
                changed = true
            }
        }

        // Additions + in-place leaf-size refresh.
        for f in fresh {
            let isLinked = known.contains(f.id)
            if !isLinked {
                newStubs.append(ChildStub(id: f.id, name: f.name, kind: f.kind,
                                          isHidden: f.isHidden, mtime: f.mtime))
                changed = true
                switch f.kind {
                case .dir, .bundleLeaf:
                    newChildIds.append(f.id) // own size + descent (dir) / recursive total (bundle) via sub-scan
                case .file, .denied, .pending, .synthetic:
                    events.append(.sizeUpdated(nodeId: f.id, allocated: f.allocated, logical: f.logical))
                }
            } else if f.kind == .file {
                let node = nodes[f.id]
                if node?.ownAllocated != f.allocated || node?.ownLogical != f.logical {
                    events.append(.sizeUpdated(nodeId: f.id, allocated: f.allocated, logical: f.logical))
                    changed = true
                }
            }
        }
        if !newStubs.isEmpty {
            events.append(.childrenDiscovered(parentId: dirId, children: newStubs))
        }
        return RevalidationDiff(events: events, newChildIds: newChildIds, changed: changed)
    }

    /// The nearest retained ANCESTOR of `id` (inclusive) — the TZ-7 focus fallback. When a prune
    /// removes the current focus subtree, "the map never points at a ghost": the focus falls back to
    /// the nearest surviving ancestor. PURE path logic over the id contract (`id` is an absolute
    /// path, a descendant's id is `ancestor + "/" + name`) plus `contains`, so it holds even before a
    /// node's stub arrives. Returns `id` itself if still retained; walks up the `/`-separated path
    /// otherwise; `nil` only if not even the volume root survives (the scan root was deleted — the App
    /// then has nothing to show and keeps its last scene). Used by the pipeline on the emit path.
    public func nearestRetainedAncestor(of id: String) -> String? {
        if nodes[id] != nil { return id }
        var cur = id
        while let slash = cur.lastIndex(of: "/") {
            let parent = slash == cur.startIndex ? "/" : String(cur[cur.startIndex..<slash])
            if nodes[parent] != nil { return parent }
            if parent == "/" { return nil }
            cur = parent
        }
        return nil
    }

    /// The EXACT excluded-mass accounting for the IGNORE lens (TZ-5 deliverable 1), computed
    /// from CURRENT reducer state — the single explicit rule the App renders (review-0 change 2,
    /// replacing the App's stale/double-counting snapshot sums). Two properties the snapshot sums
    /// could not give:
    ///
    ///   - STREAMING-CORRECT. An ignored directory is EXCLUDED from every later scene, so a
    ///     snapshot taken at ignore time froze its size. Here `subtreeAllocated` is the node's
    ///     current retained total (maintained incrementally by the fold), so re-calling this each
    ///     emit re-sums the growing subtree — the figure tracks the scan instead of lying low.
    ///   - OVERLAP-DEDUPLICATED (the UNION rule). If both an ancestor and one of its descendants
    ///     are ignored, their masses OVERLAP; summing both snapshots double-counts. The total here
    ///     adds `subtreeAllocated` only for ignored "ROOTS" — an ignored node with NO ignored
    ///     ancestor — so a descendant under an already-ignored ancestor contributes nothing extra
    ///     (its mass is already inside the ancestor's subtree total). This is the "one explicit
    ///     union/accounting rule from current reducer state" the review requires.
    ///
    /// `currentById` carries each ignored id's current retained total (for the panel rows), so a
    /// row's size is live too (0 for an id ignored before its stub arrived — retained as nil).
    /// Pure over the accumulated state; the pipeline calls it on its actor once per emit —
    /// O(ignored × ancestor-chain-depth), never node-count. A tuple, not a new type: one caller.
    public func ignoreAccounting(_ ids: Set<String>) -> (total: Int64, currentById: [String: Int64]) {
        var currentById = [String: Int64](minimumCapacity: ids.count)
        var total: Int64 = 0
        for id in ids {
            currentById[id] = nodes[id]?.subtreeAllocated ?? 0
            // Walk the retained parent chain; if any ancestor is ALSO ignored, this node's mass is
            // already subsumed by that ancestor's subtree total — do not add it again (union dedup).
            var subsumed = false
            var pid = nodes[id]?.parentId
            while let p = pid {
                if ids.contains(p) { subsumed = true; break }
                pid = nodes[p]?.parentId
            }
            if !subsumed { total += nodes[id]?.subtreeAllocated ?? 0 }
        }
        return (total, currentById)
    }

    /// Kind is DERIVED, order-independent: denial wins (we could not enter, so it
    /// is not an ordinary dir), else the stub's kind, else `.pending` for a node
    /// referenced only by a size event whose stub has not arrived yet.
    private func outputKind(_ node: Node) -> NodeKind {
        if node.denied { return .denied }
        return node.stubKind ?? .pending
    }

    /// Scan progress is DERIVED from flags, order-independent.
    private func outputState(_ node: Node, kind: NodeKind) -> ScanState {
        if node.denied || node.completed { return .complete }
        switch kind {
        case .file, .bundleLeaf:
            return node.hasSize ? .complete : .pending
        case .dir:
            return node.discoveredChildren ? .partial : .pending
        case .denied:
            return .complete
        case .pending:
            return .pending
        case .synthetic:
            // The reducer never derives a synthetic node, and nothing produces one anymore
            // (the unaccounted tile was retracted — HUMAN FIELD RULING #1; the case is a
            // reserved, currently-unused kind, see `NodeKind.synthetic`). This arm exists
            // solely for exhaustiveness so any future re-introduction is compiler-surfaced.
            return .complete
        }
    }
}
