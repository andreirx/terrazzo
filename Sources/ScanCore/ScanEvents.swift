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
        var hasSize = false
        var discoveredChildren = false
        var denied = false
        var completed = false
    }

    private var nodes: [String: Node]
    private let rootId: String

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

    /// - Parameters:
    ///   - rootId: the scan root's stable id (its absolute path). The walker emits
    ///     events tagged with ids derived from the same root, so they match.
    ///   - rootName: display name for the root tile.
    public init(rootId: String, rootName: String) {
        self.rootId = rootId
        self.nodes = [rootId: Node(name: rootName, stubKind: .dir)]
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
            for stub in children { parent.childIds.insert(stub.id) }
            nodes[parentId] = parent

        case let .sizeUpdated(nodeId, allocated, logical):
            var node = nodes[nodeId] ?? Node(name: "")
            // Count this entry as "processed" exactly once (the first own-size write).
            // The walker emits one size event per stat'd node, but count from the
            // false→true transition so the tally is robust to a duplicate/replayed
            // batch and stays a pure function of the accumulated state.
            if !node.hasSize { processedCount += 1 }
            node.ownAllocated = allocated
            node.ownLogical = logical
            node.hasSize = true
            nodes[nodeId] = node

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

    /// Snapshot the accumulated state into a `SizeTree`.
    ///
    /// - `allocatedBytes`/`logicalBytes` are ALWAYS the full recursive totals
    ///   (sizes true — ratified decision 4), computed bottom-up.
    /// - Children are included only while `depth < depthWindow`; below that,
    ///   detail FOLDS INTO the ancestor's total (which already counts it) and the
    ///   `children` array is empty. Totals are unchanged by the window — that is
    ///   the invariant the depth-window test pins.
    ///
    /// - Parameter depthWindow: max retained child depth (root is depth 0).
    public func makeTree(depthWindow: Int = ScanPolicy.default.depthDetailWindow) -> SizeTree {
        build(id: rootId, depth: 0, depthWindow: depthWindow)
    }

    private func build(id: String, depth: Int, depthWindow: Int) -> SizeTree {
        let node = nodes[id] ?? Node(name: id)
        let kind = outputKind(node)

        // Sort children canonically so enumeration order never leaks in.
        let sortedChildIds = node.childIds.sorted { a, b in
            let na = nodes[a]?.name ?? a
            let nb = nodes[b]?.name ?? b
            return na == nb ? a < b : na < nb
        }
        let builtChildren = sortedChildIds.map {
            build(id: $0, depth: depth + 1, depthWindow: depthWindow)
        }

        // Full recursive totals — computed regardless of the window.
        let totalAllocated = builtChildren.reduce(node.ownAllocated) { $0 + $1.allocatedBytes }
        let totalLogical = builtChildren.reduce(node.ownLogical) { $0 + $1.logicalBytes }

        // Fold detail beyond the window: keep the total, drop the child tiles.
        let retained = depth < depthWindow ? builtChildren : []

        return SizeTree(
            id: id,
            name: node.name,
            kind: kind,
            allocatedBytes: totalAllocated,
            logicalBytes: totalLogical,
            children: retained,
            scanState: outputState(node, kind: kind)
        )
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
            // The reducer never derives a synthetic node (only the composition layer
            // injects one AFTER projection); this arm exists solely for exhaustiveness
            // so adding the kind deliberately surfaced this site. A synthetic tile's
            // accounting is final by construction.
            return .complete
        }
    }
}
