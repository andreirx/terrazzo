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

    public init(id: String, name: String, kind: NodeKind) {
        self.id = id
        self.name = name
        self.kind = kind
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
    }

    private var nodes: [String: Node]
    /// The scan root's id. MUTABLE since TZ-4b: root promotion re-roots the reducer
    /// in place (`reRoot`) — the whole node map is preserved and a new parent is
    /// grafted above the old root. Everywhere else this is written once at init.
    private var rootId: String

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
            // Create/merge each child record first (different ids), then write the
            // parent last. name/kind come ONLY from the stub → a single write; a
            // size event that created a bare record first just gets its identity
            // filled here. Creation order is irrelevant (write-once fields).
            for stub in children {
                var child = nodes[stub.id] ?? Node(name: stub.name)
                child.name = stub.name
                child.stubKind = stub.kind
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
            var node = nodes[nodeId] ?? Node(name: "")
            // Count this entry as "processed" exactly once (the first own-size write), and
            // accumulate its own size into the scan-root total on the SAME transition. The
            // walker emits one size event per stat'd node, but count/accumulate from the
            // false→true transition so both stay robust to a duplicate/replayed batch and a
            // pure function of the accumulated state.
            if !node.hasSize {
                processedCount += 1
                rootAllocatedBytes += allocated
            }
            // The retained-total delta is the CHANGE in own size (normally 0→size on the first
            // write; a re-stated same size is a no-op delta). Push it up the ancestor chain so
            // every ancestor's retained subtree total stays exact.
            let dAllocated = allocated - node.ownAllocated
            let dLogical = logical - node.ownLogical
            node.ownAllocated = allocated
            node.ownLogical = logical
            node.hasSize = true
            nodes[nodeId] = node
            bumpSubtree(from: nodeId, allocated: dAllocated, logical: dLogical)

        case let .accessDenied(nodeId):
            var node = nodes[nodeId] ?? Node(name: "")
            node.denied = true
            nodes[nodeId] = node

        case let .subtreeCompleted(nodeId):
            var node = nodes[nodeId] ?? Node(name: "")
            node.completed = true
            nodes[nodeId] = node
        }
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
    public func makeTree(focusId: String? = nil,
                         depthWindow: Int = ScanPolicy.default.depthDetailWindow) -> SizeTree {
        var pruned = 0
        return build(id: focusId ?? rootId, depth: 0, depthWindow: depthWindow,
                     area: 0, minRenderArea: 0, prunedBelowArea: &pruned)
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
    public func makeRenderTree(focusId: String, depthWindow: Int,
                               minRenderArea: Double, viewportArea: Double)
        -> (tree: SizeTree, prunedBelowArea: Int) {
        var pruned = 0
        let t = build(id: focusId, depth: 0, depthWindow: depthWindow,
                      area: viewportArea, minRenderArea: minRenderArea, prunedBelowArea: &pruned)
        return (t, pruned)
    }

    private func build(id: String, depth: Int, depthWindow: Int,
                       area: Double, minRenderArea: Double, prunedBelowArea: inout Int) -> SizeTree {
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
                var totalW = 0.0
                for cid in node.childIds { totalW += Double(max(0, nodes[cid]?.subtreeAllocated ?? 0)) }
                var kept: [(id: String, area: Double)] = []
                for cid in node.childIds {
                    let child = nodes[cid]
                    let w = Double(max(0, child?.subtreeAllocated ?? 0))
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
                          area: $0.area, minRenderArea: minRenderArea, prunedBelowArea: &prunedBelowArea)
                }
            } else {
                // Full projection: sort children canonically so enumeration order never leaks in.
                let sortedChildIds = node.childIds.sorted { a, b in
                    let na = nodes[a]?.name ?? a
                    let nb = nodes[b]?.name ?? b
                    return na == nb ? a < b : na < nb
                }
                retained = sortedChildIds.map {
                    build(id: $0, depth: depth + 1, depthWindow: depthWindow,
                          area: 0, minRenderArea: 0, prunedBelowArea: &prunedBelowArea)
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
            scanState: outputState(node, kind: kind)
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
