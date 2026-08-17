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
    /// A SYNTHETIC accounting node NOT produced by scanning. RESERVED, CURRENTLY UNUSED
    /// (TZ-4b, HUMAN FIELD RULING #1): the sole former instance — the per-volume
    /// "Unaccounted" tile — was RETRACTED (it drew a volume-level residual inside a
    /// subtree map, a category error), and the figure moved to a status-bar field
    /// (`ScanCore.UnaccountedSpace`). Nothing produces `.synthetic` now: the walker
    /// never emits it, the reducer never derives it, and no layout/render path lays it
    /// out. The case is KEPT rather than deleted because removing a variant from this
    /// core sum type is a boundary-shape change across the `SizeTree` DTO (CLAUDE.md:
    /// stop-and-ask on a data shape crossing a boundary) — deferred, not done here. It
    /// remains covered by exhaustive `switch`es so any future re-introduction is a
    /// deliberate, compiler-surfaced decision.
    case synthetic
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
    /// The directory's modification time (nanoseconds since the epoch) captured AT SCAN TIME —
    /// the near-free staleness key for TZ-7 Tier-1 revalidation. Present only for directory nodes
    /// whose mtime a parent enumeration observed (via `ChildStub.mtime`) or a revalidation set
    /// (via `ScanEvent.directoryMtime`); `nil` for files, symlinks, and any directory whose mtime
    /// is not yet known (notably the scan root before its first revalidation — a `nil` here just
    /// means "no cheap comparison possible, always re-enumerate", never a fabricated value). A
    /// directory listing is CURRENT iff a fresh `stat` of the directory yields this same mtime; a
    /// change means an entry was added/removed/renamed there and the directory must be re-listed
    /// and diffed. Additive DTO field (default `nil`) — pre-TZ-7 fixtures/JSON and every existing
    /// call site are source- and JSON-compatible (see `init(from:)`). Never used for layout; the
    /// App reads only the FOCUS node's value off the focus-rooted projection root (O(1), on main).
    public let mtime: Int64?
    /// Whether the walker judged this node HIDDEN at scan time (TZ-5 deliverable 3;
    /// PLAN "requires an `isHidden` flag on SizeTree nodes captured by the walker").
    /// The RULE (see `DirectoryReader`/`FileSystemWalker`): a leading-dot name OR the
    /// `UF_HIDDEN` file flag. The scan ALWAYS includes hidden items (a fixed walker
    /// invariant — surfacing hidden paths IS the product, VISION); this flag is a pure
    /// VISUALIZATION lens input: the "Show hidden files" filter (on by default) uses it
    /// to exclude dotfiles/UF_HIDDEN nodes from LAYOUT only, with status-bar accounting —
    /// the scan tree is never changed. Additive DTO field (the one permitted scan-side
    /// touch this slice makes); defaults `false` so pre-TZ-5 fixtures and call sites are
    /// source- and JSON-compatible (see `init(from:)`).
    public let isHidden: Bool

    public init(
        id: String,
        name: String,
        kind: NodeKind,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        children: [SizeTree] = [],
        scanState: ScanState = .complete,
        isHidden: Bool = false,
        mtime: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.children = children
        self.scanState = scanState
        self.isHidden = isHidden
        self.mtime = mtime
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, allocatedBytes, logicalBytes, children, scanState, isHidden, mtime
    }

    /// Custom decoder so `isHidden` (added in TZ-5) is BACKWARD-COMPATIBLE with the
    /// pre-TZ-5 `fixture-tree.json` (which has no `isHidden` key) and any other legacy
    /// JSON: a missing key defaults to `false` rather than throwing. `children`/`scanState`
    /// are decoded leniently too (they already carry defaults in the memberwise init), so a
    /// leaf fixture node may omit them. `encode(to:)` stays synthesized (it writes every
    /// key, including `isHidden`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(NodeKind.self, forKey: .kind)
        self.allocatedBytes = try c.decode(Int64.self, forKey: .allocatedBytes)
        self.logicalBytes = try c.decode(Int64.self, forKey: .logicalBytes)
        self.children = try c.decodeIfPresent([SizeTree].self, forKey: .children) ?? []
        self.scanState = try c.decodeIfPresent(ScanState.self, forKey: .scanState) ?? .complete
        self.isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        self.mtime = try c.decodeIfPresent(Int64.self, forKey: .mtime) // nil when absent (pre-TZ-7)
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

/// Path-ancestry over node ids, used by the WATCHLIST to keep its set an ANTICHAIN.
///
/// WHY IT EXISTS (TZ-5 review-2, nested-watchlist restore). The watchlist excludes each id’s
/// WHOLE subtree from layout (`ScanReducer.makeRenderTree(excluding:)`). If both an ancestor
/// and one of its descendants were listed at once, the descendant’s Watchlist row could
/// never restore its tile — its ancestor still excludes the whole subtree — so a one-click
/// "restore" would silently do nothing, a name-honesty defect. The App therefore keeps its
/// watchlist an antichain (no id is an ancestor of another): watchlisting an ancestor DROPS any
/// already-listed descendants (subsumed), so every remaining row is an independent, restorable
/// exclusion.
///
/// It relies ONLY on the documented `SizeTree.id` contract — a node id is an absolute path and
/// a descendant's id is `ancestor + "/" + name` (`FileSystemWalker.joinId`). So ancestry is
/// pure string logic with NO reducer state: it holds even before a node's stub has arrived, and
/// it lives here (ScanCore, which owns the id contract) rather than in the App so `swift test`
/// can pin it (the App layer is not an SPM target).
///
/// ABSTRACTION LEDGER: a namespace of pure static funcs (not a type — no state). Concrete
/// users: `NavigationController.addToWatchlist(tile:)` (production) + `ScanReducerTests` (the regression
/// test). Axis: none — fixed path-string relation. Rejected simpler alternative: inline the
/// prefix check in the App — but the App is SPM-invisible, so the rule could not be unit-tested,
/// which the reviewer requires.
public enum WatchlistPath {
    /// Is `descendant` strictly inside the directory `ancestor`? Boundary-checked on the path
    /// separator so `/Users` is NOT reported an ancestor of `/UsersFoo`, and an id is never its
    /// own ancestor. Handles a root whose id already ends in "/" (the volume root, `"/"`).
    public static func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        guard descendant != ancestor else { return false }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return descendant.hasPrefix(prefix)
    }
}
