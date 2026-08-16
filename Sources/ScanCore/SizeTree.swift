//
//  SizeTree.swift — the single crossing-point DTO between the two engines.
//  Module maturity: PROTOTYPE (slice TZ-1 — contracts still moving)
//
//  CLAUDE.md hard constraint 1: ScanCore+ScanFS (scanning) and TreemapCore+App
//  (visualization) meet ONLY here. This type is pure Foundation value data — no
//  FileManager, no AppKit, no Metal. The scan engine PRODUCES SizeTree values;
//  the visualization engine CONSUMES them and knows nothing else about the
//  filesystem. Either engine must be replaceable without the other noticing
//  (VISION §"The two engines").
//
//  In TZ-1 this is the ONLY file in ScanCore. There is no reducer, no event
//  stream, no policy yet — those are TZ-2. TZ-1 only needs the shape of the data
//  the treemap draws, plus Codable so a hardcoded fixture tree can be loaded
//  from JSON (TZ-1 deliverable 5) with zero filesystem access.
//
//  DTO shape is FROZEN to exactly the TZ-1 slice's field list (id, name, kind,
//  allocatedBytes, logicalBytes, children, scanState). It is a recursive value
//  tree — the scanner will build these incrementally in TZ-2; here they are
//  decoded whole from the fixture.
//

import Foundation

/// What a node fundamentally IS. Mutually-exclusive kinds → a sum type, not a
/// bag of booleans (a `file` never has children; a `denied` placeholder is not
/// a real directory we could enter). Exhaustive `switch` sites over this enum
/// are the deterministic list of every place a new kind would change behavior.
///
/// `denied` and `pending` are first-class kinds because invisible space is
/// first-class (VISION §"invisible space is first-class"): a tile that means
/// "we could not enter this" or "we have not scanned this yet" SAYS so, it is
/// never approximated into ordinary `dir`/`file` data. In TZ-1 these appear in
/// the fixture to prove the DTO and renderer carry them end-to-end; distinct
/// *rendering* of denied/pending tiles is TZ-2's job.
public enum NodeKind: String, Codable, Sendable {
    case dir
    case file
    /// A `.app`/`.framework`-style bundle treated as an opaque leaf (size only),
    /// per the ratified 2026-08-12 decision (VISION §Experience 5).
    case bundleLeaf
    /// A directory the scan is not permitted to enter (TCC / other users' homes).
    case denied
    /// A node discovered but not yet sized/expanded by the streaming scan.
    case pending
}

/// How complete our accounting of a node is. Distinct from `NodeKind`: kind is
/// *what the node is*, scanState is *how far the scan has gotten with it*. A
/// `dir` can be `.pending` (just discovered), `.partial` (some children in,
/// more coming — the streaming contract, VISION §3), or `.complete`.
///
/// NOTE (PROTOTYPE / open question for TZ-2): `NodeKind.pending`/`.denied` and
/// `ScanState.pending` overlap in meaning. TZ-1 does not resolve this — it
/// carries both fields verbatim as the slice specifies. The scanner in TZ-2 is
/// the concrete second user that will decide the precise contract (see the
/// build report's DECISION block). Kept minimal here on purpose.
public enum ScanState: String, Codable, Sendable {
    case pending
    case partial
    case complete
}

/// A node in the sized filesystem tree. Value type; recursively owns its
/// children. Comparable/Hashable are intentionally NOT derived — identity is the
/// `id` string; equality of whole subtrees (for tests) is via `Equatable`.
public struct SizeTree: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity of this node. In TZ-1 an arbitrary fixture string; in
    /// TZ-2+ the scanner assigns it path-derived: the root's id is the scan root's
    /// path and each descendant is `parentId + "/" + name`, so the whole tree
    /// shares one absolute-path identity prefix (FileSystemWalker contract). Doubles
    /// as the Finder-reveal path and the focus-path readout under the live scan.
    public let id: String
    /// Display name (the last path component, or a synthetic label for
    /// denied/unaccounted placeholders).
    public let name: String
    public let kind: NodeKind
    /// Bytes actually occupied on disk (allocation-rounded). The metric that
    /// explains free space — the founding mystery (VISION). Used as the treemap
    /// layout weight in TZ-1. (allocated-vs-logical primary metric is PLAN open
    /// decision 1, ratified in TZ-2; TZ-1 lays out by allocated.)
    public let allocatedBytes: Int64
    /// Apparent size (sum of file lengths), shown in hover/detail later.
    public let logicalBytes: Int64
    /// Child nodes. Empty for leaves (`file`, `bundleLeaf`, `denied`, and
    /// not-yet-expanded `pending`).
    public let children: [SizeTree]
    public let scanState: ScanState

    public init(
        id: String,
        name: String,
        kind: NodeKind,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        children: [SizeTree] = [],
        scanState: ScanState = .complete
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.children = children
        self.scanState = scanState
    }
}

public extension SizeTree {
    /// Total node count in this subtree (self + all descendants). Test/diagnostic
    /// helper; O(n).
    var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }

    /// Depth of the subtree rooted here: a leaf is depth 1.
    var depth: Int {
        1 + (children.map(\.depth).max() ?? 0)
    }

    /// Depth-first lookup of a node by its `id`. O(n); TZ-3 keeps no index (files
    /// are the system of record, no caches — CLAUDE.md constraint 4). Because it is
    /// O(n) it must NEVER run on the main actor per the ratified threading law. Concrete
    /// current users (verified by `grep node(withId:` under Sources): only
    /// `ScenePipeline.buildLabels`, which calls it ONCE per scene for the FOCUS node
    /// (then indexes that node's children by id) — on the background pipeline actor, off
    /// main. The App's hover readout, per-tile labels, and right-click menu title read
    /// the name/allocated/logical the layout DENORMALIZED onto each TileRect (TZ-3b),
    /// so they no longer traverse the tree on main. The focus-path label and ascend use
    /// the `focusStack` of ids directly — they do NOT call this.
    func node(withId id: String) -> SizeTree? {
        if self.id == id { return self }
        for child in children {
            if let found = child.node(withId: id) { return found }
        }
        return nil
    }
}
