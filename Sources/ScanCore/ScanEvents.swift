//
//  ScanEvents.swift — the streaming scan event model + the pure reducer.
//  Module maturity: PROTOTYPE (slice TZ-2 — contracts still moving)
//
//  TZ-9 (THE MEMORY LAW) — LEAN NODE STORE, Phase A + B. The field report named three ways the
//  pre-TZ-9 `[String: Node]` retained every node's absolute path — as the dict KEY, inside its
//  parent's CHILD SET, and as each child's `parentId` (~264 B of path strings/node, the bulk of
//  the pre-TZ-9 ~624 B/node measured on the home scan, growing O(depth)). Phase A removed two of
//  the three copies with an index-addressed store:
//    • `store: [Node]`   — one contiguous slot per node.
//    • `index: [PathKey: Int32]` — id → slot, keyed by a 128-bit HASH of the id (16 bytes), NOT
//                          the id string — so the map holds NO path copy.
//    • parent / children are SLOT INDICES (`Int32`), not strings — so no parent or child holds
//                          another node's path.
//  Phase B removes the LAST retained copy (`Node.id` — the ~200 B/node whale of the Phase A
//  measurement): a node retains NO id string at all. Its id is DERIVED on demand by walking
//  `parent` links and joining `name`s (`joinId` — the walker's ratified id contract: the root's
//  id is `rootId`, a descendant's id is `parentId + "/" + name`; see `FileSystemWalker.joinId`
//  and the `SizeTree.id` contract). The ONLY id strings the store retains are `rootId` (one per
//  reducer) and the `retainedIds` side map, which holds an id for EXACTLY the slots whose id is
//  NOT derivable:
//    (a) a slot not yet LINKED to its parent (created by a size/denied/completed/mtime event
//        arriving before its discovery stub) — TRANSIENT: the entry drops the moment the stub
//        links it and the path contract holds, so a production scan's steady-state entry count
//        is ZERO (the drain is pinned by test);
//    (b) a linked slot whose id VIOLATES the path contract — SYNTHETIC ids (the verify harness
//        replays the fixture tree, ids like "n028:System", through this reducer:
//        `scripts/verify_host.swift buildReducer(from:)`) — retained for the node's lifetime,
//        so opaque ids still round-trip VERBATIM. Only contract-violating callers pay this
//        memory; the walker never does. (This SETTLES the Phase B synthetic-id question: the
//        fixture gate is REAL — verify_host feeds synthetic ids through the reducer — and the
//        documented side map is the behavior-preserving resolution.)
//  The public API is UNCHANGED: events carry path-string ids; makeTree/graft/prune/diff produce
//  byte-identical trees (the pre-Phase-B 214-test suite + the fixture goldens are the ratchet;
//  DerivedIdTests adds the Phase B pins — the drain to zero retained ids, and synthetic-id
//  round-trip). See `PathKey` for the collision argument (an exact parent-chain compare,
//  `slotMatches`).
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

/// A 128-bit hash of a node's opaque id — the lean store's map KEY (TZ-9, THE MEMORY LAW).
///
/// WHY A HASH, NOT THE PATH: the pre-TZ-9 `[String: Node]` retained the full path string as the
/// dict key; at ~40–80 bytes each (plus String/heap overhead) that was one of the three retained
/// path copies the field report named. Keying by a fixed 16-byte hash retains no path in the map at
/// all — the id→slot map costs the same whether ids are 8 or 200 chars long. (Since Phase B the
/// node keeps NO id copy either — ids derive from the parent chain, or live in the `retainedIds`
/// side map when not derivable; see the file header.)
///
/// COLLISION RESOLUTION IS EXACT (review-0 change 1; mechanism updated in Phase B) — the hash is a
/// fast FIRST-LEVEL discriminator, NOT the correctness argument. The map (`index`) holds one slot
/// per key; a second DISTINCT id that hashes to the same key goes into the `collisions` side table;
/// and EVERY lookup (`slot(of:)` / `ensureSlot`) confirms the candidate slot against the QUERIED id
/// via `slotMatches` — a byte-exact PARENT-CHAIN comparison: strip the slot's `name` off the id's
/// tail, then the `joinId` separator, ascend, and compare the remaining prefix against the first
/// ancestor whose id IS a string in hand (`rootId`, or a `retainedIds` entry). No probabilistic
/// acceptance: two distinct ids can never resolve to the same node. Phase A documented parent-chain
/// verification as UNSOUND for two reasons; the Phase B store resolves both STRUCTURALLY:
///   1. LATE NAMING — a node created by `sizeUpdated` before its `childrenDiscovered` stub has no
///      name/parent yet. Phase B keeps such a slot's id STRING in `retainedIds` until the stub
///      links it; `slotMatches` compares against that string directly (no chain walk involved).
///   2. OPAQUE / DISPLAY-NAME IDS — the scan root's `name` is a display name (its id is compared
///      against the retained `rootId`, never name-derived), and a contract-violating synthetic id
///      keeps its `retainedIds` entry permanently — again a direct string compare.
/// EQUALITY GRANULARITY (review-1 change 1 — ONE relation): id identity is UTF-8 BYTE equality,
/// applied consistently everywhere an id is hashed, verified, or decided — `PathKey` hashes bytes;
/// `slotMatches` compares bytes (the chain walk, and the root/retained direct compares via
/// `sameIdBytes`); and DERIVABILITY (drop vs retain an id string at child-linking and `reRoot`) is
/// decided by the same `sameIdBytes`. Swift's canonical-equivalence `String ==` is deliberately
/// NOT used for ids: it calls a decomposed and a precomposed spelling "equal", which would drop
/// the retained verbatim string while byte-wise lookup and projection disagree — two distinct
/// byte ids collapsing or going unfindable (the review-1 blocking defect; pinned by the
/// canonical-equivalence regressions in DerivedIdTests). Byte identity is also the de-facto
/// walker identity: every production id derives from one enumeration byte source.
///
/// WHY 128 BITS ANYWAY: keeping the hash wide (two independent 64-bit passes) is what keeps the
/// `collisions` side table EMPTY in practice — across even a 60M-node forest the expected number of
/// colliding pairs is ≈ n²/2·2⁻¹²⁸ ≈ 1e-23 — so the exact-resolution machinery pays ~zero memory and
/// the verify compare almost always succeeds on the first slot. That is a MEMORY/throughput argument,
/// not a correctness one: even if a collision did occur, the side table + exact compare keep the two
/// nodes distinct. Keys are compared on the FULL 128 bits (Swift synthesizes `==` over both halves).
///
/// ABSTRACTION LEDGER — PathKey: a value type wrapping the map key. Concrete users: `ScanReducer.index`
/// + `collisions`. Axis: memory (drop the map's retained path copy — THE MEMORY LAW). Rejected simpler
/// alternative: key by the `String` id (the pre-TZ-9 design — one of the three path copies TZ-9
/// removed).
fileprivate struct PathKey: Hashable {
    let a: UInt64
    let b: UInt64
    init(a: UInt64, b: UInt64) { self.a = a; self.b = b }
    /// The production hasher: two independent hashes over the UTF-8 bytes (different bases + primes)
    /// → 128 bits combined. Kept a plain, inlinable `init` (not routed through the reducer's stored
    /// hasher) so the hot fold path pays a direct call, not an indirect one (the scan-rate law).
    init(_ s: String) {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325            // FNV-1a offset basis
        var b: UInt64 = 0x9e37_79b9_7f4a_7c15            // golden-ratio basis (independent seed)
        for byte in s.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01B3   // FNV-1a prime
            b = (b ^ UInt64(byte)) &* 0x8803_55f2_1e6d_1965   // a different odd prime
        }
        self.a = a
        self.b = b
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
    /// `(bytes) -> weight` function and never learns whether the caller means linear or sqrt
    /// (that named enum, `AreaScale`, lives in TreemapCore; review-1 change 3). The
    /// composition layer passes the SAME transform the treemap's Squarify uses, so the
    /// pruned set matches the rendered partition; when no transform is supplied (the reducer's
    /// own tests, the full non-area-bounded path) this identity-on-non-negative default applies.
    public static let linearWeight: (Int64) -> Double = { Double(max(0, $0)) }

    // MARK: - Lean node store (TZ-9 — THE MEMORY LAW)

    /// Sentinels. `noIndex` (`-1`) is not a valid `store` slot, so it marks "no parent" (the
    /// current root, or a not-yet-linked node). `unknownMtime` (`Int64.min`) cannot be a real
    /// nanosecond mtime (they are ≥ 0), so it marks "mtime not yet learned" — a sentinel instead
    /// of `Int64?` to spare the optional's 8-byte alignment tax under the memory law.
    private static let noIndex: Int32 = -1
    private static let unknownMtime: Int64 = .min

    /// Packed monotonic/flag bits. Every one is either write-once or an OR-set flag (see the file
    /// header's order-independence argument), so packing them changes NOTHING about folding — it
    /// only replaces five `Bool`s (which alignment would round up to 8 bytes/node) with one byte.
    ///
    /// ABSTRACTION LEDGER — Flags: a bitset over Node's boolean state. Concrete user: `Node`. Axis:
    /// memory (THE MEMORY LAW — 8 bytes/node saved). Rejected simpler alternative: five `Bool` fields.
    private struct Flags: OptionSet {
        let rawValue: UInt8
        static let hasSize            = Flags(rawValue: 1 << 0)
        static let discoveredChildren = Flags(rawValue: 1 << 1)
        static let denied             = Flags(rawValue: 1 << 2)
        static let completed          = Flags(rawValue: 1 << 3)
        static let isHidden           = Flags(rawValue: 1 << 4)
    }

    /// A node under construction in the LEAN STORE (TZ-9). The DERIVED semantics are unchanged from
    /// the pre-TZ-9 record — `kind`/`scanState` are computed (`outputKind`/`outputState`), never
    /// stored, so they cannot depend on write order — the change is ADDRESSING: a node is a SLOT in
    /// `store`, referenced by `Int32` index, and since Phase B retains NO path string at all.
    ///   • The node's id is NOT stored (Phase B — the ~200 B/node whale). It is DERIVED on demand:
    ///     `rootId` for the root slot, else `joinId(parentId, name)` up the `parent` chain — or read
    ///     from the `retainedIds` side map for the (unlinked / contract-violating) slots whose id
    ///     cannot be derived. Ids still round-trip verbatim through `SizeTree` (see the file header).
    ///   • `name` is the display name (usually ≤ 15 UTF-8 bytes → inline via Swift's small-string
    ///     optimization, no heap). For every LINKED contract-following node it is byte-identical to
    ///     the id's last path component — that is what makes derivation exact.
    ///   • `childIndices` are child SLOTS, not path strings — empty for leaves (Swift's shared
    ///     empty-array singleton, so a file node pays ZERO heap here, the common case).
    ///   • `parent` is the parent SLOT (`noIndex` for the root / a not-yet-linked node); it carries
    ///     exactly the write-once single-parent role the old `parentId` string did — and since
    ///     Phase B it is also the id-derivation chain.
    private struct Node {
        var name: String
        var ownAllocated: Int64 = 0
        var ownLogical: Int64 = 0
        /// RETAINED EXACT subtree totals = own + Σ (linked children's retained totals), maintained
        /// INCREMENTALLY by `bumpSubtree` on every own-size write and every edge addition. Order-
        /// independent because the only mutations are additive deltas pushed up the parent chain,
        /// and addition commutes — so `subtree == own + Σ children.subtree` holds after ANY
        /// interleaving, at EVERY snapshot. This is what lets `build` read a beyond-window total in
        /// O(1) instead of traversing hidden descendants (the ratified focus-rooted bound).
        var subtreeAllocated: Int64 = 0
        var subtreeLogical: Int64 = 0
        /// Directory mtime (ns) — the TZ-7 staleness key — or `unknownMtime` until learned (parent
        /// stub at scan time, or a `directoryMtime` event). Whichever write lands last wins;
        /// revalidation always re-stats to establish truth, so a transient stale value costs at most
        /// one extra (idempotent) re-enumeration, never a wrong tree.
        var mtimeRaw: Int64 = ScanReducer.unknownMtime
        /// Child SLOTS — arrival order is discarded; `makeTree` sorts by (name, id).
        var childIndices: [Int32] = []
        /// Parent SLOT (`noIndex` == none). Set EXACTLY ONCE when the incoming edge is added (the
        /// parent's `childrenDiscovered`, or `reRoot`'s graft); a node has one parent by filesystem
        /// structure. Used to propagate retained-total deltas upward (`bumpSubtree`).
        var parent: Int32 = ScanReducer.noIndex
        /// The kind reported by the parent's `childrenDiscovered` stub. `nil` until the stub arrives
        /// (a node can be referenced by a size event before its stub); `denied` overrides at
        /// projection time.
        var stubKind: NodeKind?
        var flags: Flags = []

        // Derived boolean views (so `outputKind`/`outputState`/`build` read unchanged).
        var hasSize: Bool { flags.contains(.hasSize) }
        var discoveredChildren: Bool { flags.contains(.discoveredChildren) }
        var denied: Bool { flags.contains(.denied) }
        var completed: Bool { flags.contains(.completed) }
        var isHidden: Bool { flags.contains(.isHidden) }
        /// Projection view of the mtime sentinel: `nil` when unknown.
        var projectedMtime: Int64? { mtimeRaw == ScanReducer.unknownMtime ? nil : mtimeRaw }
    }

    /// The node records, addressed by slot. Freed slots (from pruned subtrees) are recycled via
    /// `freeList`, so the array does not grow unboundedly under live churn — the prune/rescan half
    /// of THE MEMORY LAW.
    private var store: [Node]
    /// id → slot, keyed by a 128-bit path HASH (`PathKey`), NOT the path string. The memory win is
    /// that the MAP KEY retains no path copy (16 fixed bytes regardless of id length) — and since
    /// Phase B the reducer keeps NO per-node id string at all: ids DERIVE from the parent chain
    /// (`slotMatches` verifies, `childId` emits), with `retainedIds` covering exactly the
    /// non-derivable slots, so ids still round-trip verbatim (see the file header).
    /// This map holds exactly ONE slot per key: the FIRST id that claimed it. A second DISTINCT id
    /// that hashes to the same key (a 128-bit collision — see `PathKey`) does not overwrite it; it is
    /// recorded in `collisions` instead, and every lookup VERIFIES the candidate via `slotMatches`
    /// (exact parent-chain compare), so two distinct ids can never resolve to one node. Exact
    /// resolution, not probabilistic.
    private var index: [PathKey: Int32]
    /// Collision side table: for a `PathKey` shared by two or more retained ids, the EXTRA slots
    /// beyond the one in `index`. Absent (and the enclosing dictionary empty) in the overwhelming
    /// normal case — a real FNV-128 collision is not an operational event (see `PathKey`) — so it
    /// costs ZERO retained bytes per node under THE MEMORY LAW; it exists only so that IF two distinct
    /// ids ever share a key, they are still kept apart EXACTLY (verified by `slotMatches`' byte-exact
    /// parent-chain compare — Phase B; no per-node id is retained), never merged. Cleared as slots
    /// are freed (`removeSubtree`) so it cannot leak.
    ///
    /// ABSTRACTION LEDGER — collisions: a side table of same-key slots. Concrete users: `slot(of:)` +
    /// `ensureSlot` (readers/writer) and `removeSubtree` (cleanup). Axis: exact hash-collision
    /// resolution (the frozen public API guarantees distinct ids stay distinct; a 128-bit hash alone
    /// cannot). Rejected simpler alternative: none — a bare `[PathKey: Int32]` silently merges two
    /// distinct filesystem nodes on any collision (the review-0 finding).
    private var collisions: [PathKey: [Int32]] = [:]

    /// Phase B (THE MEMORY LAW) — id strings retained for EXACTLY the slots whose id cannot be
    /// DERIVED from the parent chain. INVARIANT, maintained at every mutation point: for every live
    /// slot `s`, `id(s) == (s == rootIndex ? rootId : retainedIds[s] ?? joinId(id(parent(s)), name(s)))`,
    /// and an entry exists IFF the `retainedIds[s]` arm is the one that applies — i.e.
    ///   (a) `s` is UNLINKED (`parent == noIndex`, not the root): stamped by `allocateSlot`, dropped
    ///       by the linking `childrenDiscovered`/`reRoot` once the derived id matches — so during a
    ///       real scan entries live only between a node's first out-of-order event and its stub
    ///       (steady state ZERO — the walker stubs every node before sizing it); or
    ///   (b) `s` is linked but its id VIOLATES the path contract (`id != joinId(parentId, name)`) —
    ///       the synthetic-id case (verify harness fixture replay); kept for the node's lifetime so
    ///       opaque ids round-trip verbatim. Only such callers pay the memory.
    /// Cleared by `removeSubtree` so a prune returns the footprint (the law's rescan half).
    ///
    /// ABSTRACTION LEDGER — retainedIds: a slot → id-string side map for NON-DERIVABLE ids only.
    /// Concrete users: `slotMatches`/`childId` (readers), `allocateSlot` (writer),
    /// `apply(.childrenDiscovered)` + `reRoot` (resolution: drop when the contract holds),
    /// `removeSubtree` (cleanup), and the `retainedIdCount` test seam. Axis: memory (THE MEMORY LAW
    /// Phase B — replace the ~200 B/node retained path with on-demand derivation; retain a string
    /// only where derivation is impossible). Rejected simpler alternatives: keep `Node.id` (Phase A —
    /// the whale this slice removes); or forbid non-contract ids (breaks the frozen opaque-id API and
    /// the verify harness's fixture replay — the settled synthetic-id question, see the file header).
    private var retainedIds: [Int32: String] = [:]
    /// Recycled slot indices from pruned subtrees, reused by the next `ensureSlot` before growing
    /// `store` (bounds live-churn memory; the initial scan never prunes, so it stays empty then).
    ///
    /// ABSTRACTION LEDGER — freeList: a slot recycler. Concrete users: `removeSubtree` (producer),
    /// `ensureSlot` (consumer). Axis: live-churn memory (prune must return footprint). Rejected
    /// simpler alternative: never reclaim slots — leaks one dead slot per pruned node over a long
    /// living-map session, which the memory law forbids.
    private var freeList: [Int32] = []
    /// The current scan root's slot — the default `makeTree` focus and the `reRoot` anchor.
    private var rootIndex: Int32
    /// The scan root's id. MUTABLE since TZ-4b: root promotion re-roots the reducer in place
    /// (`reRoot`) — the whole store is preserved and a new parent is grafted above the old root.
    private var rootId: String

    /// TEST SEAM (TZ-9 review-0 change 2) — an OPTIONAL override of the 128-bit path hash, `nil` in
    /// every production build (the public `init` leaves it nil). A real FNV-128 collision is not
    /// constructible in a test, so proving that two DISTINCT ids sharing one key stay distinct through
    /// `apply`/`makeTree`/lookup/prune requires FORCING the collision — the `internal` test init
    /// installs a hasher that maps chosen ids to one key. On the hot fold path this is a single
    /// optional-nil check that short-circuits to the inlinable `PathKey(id)` (see `key(_:)`), so the
    /// seam adds no measurable scan-rate cost and touches no per-node memory (one optional reference on
    /// the single reducer instance). Reviewer pre-ratified this narrowly scoped internal seam.
    private let testHasher: ((String) -> PathKey)?
    /// The path→key hash: the production `PathKey(id)` (inlinable direct call) unless a test installed
    /// `testHasher`. THE single place the reducer turns an id into a map key.
    private func key(_ id: String) -> PathKey { testHasher?(id) ?? PathKey(id) }

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
        self.init(rootId: rootId, rootName: rootName, testHasher: nil)
    }

    /// TEST-ONLY designated init (TZ-9 review-0 change 2): the same construction as the public init,
    /// plus an optional `testHasher` that forces chosen ids onto one 128-bit key so a test can drive a
    /// hash collision the FNV-128 hash would otherwise never produce. `internal` — reachable only via
    /// `@testable import ScanCore`; production always calls the public init (`testHasher == nil`).
    /// `rawHash` is a plain `(String) -> (UInt64, UInt64)` so the seam never exposes the fileprivate
    /// `PathKey` type across the module boundary.
    internal init(rootId: String, rootName: String, rawHashForTesting rawHash: @escaping (String) -> (UInt64, UInt64)) {
        self.init(rootId: rootId, rootName: rootName,
                  testHasher: { let (a, b) = rawHash($0); return PathKey(a: a, b: b) })
    }

    private init(rootId: String, rootName: String, testHasher: ((String) -> PathKey)?) {
        self.testHasher = testHasher
        self.rootId = rootId
        // The root slot retains NO id string (Phase B): its id IS `rootId`, the derivation base
        // case (`rootIndex` is special-cased in `slotMatches`/`childId`, so the root's display
        // name never participates in derivation).
        let root = Node(name: rootName, stubKind: .dir)
        self.store = [root]
        // Seed the root's key through the SAME hash the fold will use (test or production), else a
        // forced-collision test would key the root differently from every folded id.
        self.index = [testHasher?(rootId) ?? PathKey(rootId): 0]
        self.rootIndex = 0
    }

    // MARK: - Lean-store primitives (TZ-9)

    /// The slot for `id`, or `nil` if the reducer has never recorded it. EXACT (review-0 change 1;
    /// Phase B mechanism): the 128-bit hash picks a candidate, then `slotMatches` compares the
    /// QUERIED id against the slot's DERIVED id (parent-chain walk — or its retained string where
    /// derivation is impossible), so a hash collision resolves to the RIGHT node (or `nil`), never
    /// to a distinct id's node. The compare consumes the same O(|id|) bytes the pre-TZ-9 String
    /// key-compare did, so the hot path's asymptotic cost is unchanged.
    private func slot(of id: String) -> Int32? {
        let k = key(id)
        guard let first = index[k] else { return nil }
        if slotMatches(first, id) { return first }
        // Hash collision (astronomically rare — see `PathKey`): scan the side-table slots for this key.
        if let bucket = collisions[k] {
            for s in bucket where slotMatches(s, id) { return s }
        }
        return nil
    }

    /// Whether slot `s`'s id equals `id`, byte-for-byte — THE exact-verification primitive behind
    /// every lookup (Phase B, replacing the Phase A `store[s].id == id` compare). Three cases,
    /// mirroring the `retainedIds` invariant:
    ///   • the root slot: compare against `rootId` (the derivation base case — the root's `name`
    ///     is a display name and never participates);
    ///   • a slot with a `retainedIds` entry (unlinked, or contract-violating): compare against
    ///     that retained string;
    ///   • a linked derivable slot: REVERSE-WALK the parent chain, consuming `id` from the tail —
    ///     strip the node's `name` bytes, then the `joinId` separator, ascend, and finish by
    ///     comparing the remaining prefix against the first ancestor whose id IS a string in hand
    ///     (`rootId` or a retained entry). No id string is ever materialized: O(|id|) byte
    ///     compares + O(depth) link hops, the same total work as the old full-string `==`.
    private func slotMatches(_ s: Int32, _ id: String) -> Bool {
        if s == rootIndex { return Self.sameIdBytes(id, rootId) }
        if let kept = retainedIds[s] { return Self.sameIdBytes(kept, id) }
        let bytes = id.utf8
        var end = bytes.endIndex
        var cur = s
        while true {
            let node = store[Int(cur)]
            // Strip `node.name` off the id's tail (byte-wise, reverse).
            let name = node.name.utf8
            var ni = name.endIndex
            while ni > name.startIndex {
                guard end > bytes.startIndex else { return false }
                ni = name.index(before: ni)
                end = bytes.index(before: end)
                if bytes[end] != name[ni] { return false }
            }
            let parent = node.parent
            // An unlinked non-root slot always has a `retainedIds` entry (the invariant), so
            // reaching `noIndex` here means `s`'s chain is not rooted — no derivable id to match.
            guard parent != ScanReducer.noIndex else { return false }
            // Strip the `joinId` separator — present unless the parent's id itself ends in "/"
            // (the volume-root "/" case; decidable locally, see `parentIdEndsInSlash`).
            if !parentIdEndsInSlash(parent) {
                guard end > bytes.startIndex else { return false }
                end = bytes.index(before: end)
                guard bytes[end] == UInt8(ascii: "/") else { return false }
            }
            if parent == rootIndex {
                return bytes[bytes.startIndex..<end].elementsEqual(rootId.utf8)
            }
            if let kept = retainedIds[parent] {
                return bytes[bytes.startIndex..<end].elementsEqual(kept.utf8)
            }
            cur = parent
        }
    }

    /// Does the id of linked slot `p` end in "/"? Needed by `slotMatches` to know whether `joinId`
    /// inserted a separator below `p`. Decidable LOCALLY, without deriving the id: the root's id is
    /// `rootId` (in hand); a retained id is in hand; and a DERIVED id `joinId(parentId, name)` ends
    /// in "/" iff `name` is empty or itself ends in "/" (`joinId` places `name` last either way).
    private func parentIdEndsInSlash(_ p: Int32) -> Bool {
        let slash = UInt8(ascii: "/")
        if p == rootIndex { return rootId.utf8.last == slash }
        if let kept = retainedIds[p] { return kept.utf8.last == slash }
        let last = store[Int(p)].name.utf8.last
        return last == nil || last == slash
    }

    /// Join a parent id and a child name into the child's id — the SAME one-line rule as
    /// `FileSystemWalker.joinId` (the id contract's single composition rule; duplicated verbatim
    /// because ScanCore must not import ScanFS — the dependency points the other way — and a
    /// shared one-liner does not earn a module). Handles a parent id of "/" without producing
    /// "//name". Cited both ways (see FileSystemWalker.joinId).
    private static func joinId(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// THE id-equality relation (review-1 change 1): UTF-8 BYTE equality — the same granularity
    /// `PathKey` hashes and the `slotMatches` chain walk compares. Every site that verifies an id
    /// against a string in hand or DECIDES derivability (drop vs retain) routes through this ONE
    /// function: the root/retained arms of `slotMatches`, the child-linking resolution, `reRoot`'s
    /// derivability decision, and `reRoot`'s already-there guard. Swift's `String ==` (canonical
    /// equivalence) is prohibited for ids — it would call byte-distinct spellings equal and
    /// desynchronize derivability from byte-wise lookup/projection (the review-1 blocking defect).
    /// O(1) length short-circuit (`utf8.count` is stored for native strings) + O(min |bytes|) compare
    /// — the same asymptotic cost as the `==` it replaces.
    private static func sameIdBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
    }

    /// The id of child slot `c` whose PARENT's id is `parentId` — the boundary-emission derivation
    /// (Phase B): the retained string when derivation is impossible, else one `joinId` (O(1) join,
    /// no chain walk — the caller already holds the parent's id, so a projection derives each id
    /// exactly once, top-down). The `rootIndex` guard covers the exotic-but-reachable state where
    /// the CURRENT root is linked as someone's child (a pre-promotion `childrenDiscovered` naming
    /// the root — the `reRoot` merge case): its id is `rootId` regardless of the chain.
    private func childId(_ c: Int32, parentId: String) -> String {
        if c == rootIndex { return rootId }
        return retainedIds[c] ?? Self.joinId(parentId, store[Int(c)].name)
    }

    /// TEST SEAM (TZ-9 Phase B) — the count of retained (non-derivable) id strings. The memory
    /// claim "contract-following ids retain no string" is unobservable through the public API;
    /// tests read this to pin that entries DRAIN to zero after a contract-following fold and that
    /// synthetic ids are retained (not corrupted). Read-only; reachable only via `@testable import`.
    internal var retainedIdCount: Int { retainedIds.count }

    /// The slot for `id`, creating it from `make()` (recycling a freed slot if one is available,
    /// else appending) when absent. The single allocation point — every `apply` arm that folds a
    /// fact about a node routes through here, exactly as the old `nodes[id] ?? Node(…)` did.
    /// Collision-EXACT: an existing slot is returned only when `slotMatches` confirms the queried
    /// id; a genuine 128-bit collision with a DIFFERENT id allocates a fresh slot and records it in
    /// the `collisions` side table so both ids stay distinct.
    private mutating func ensureSlot(_ id: String, _ make: () -> Node) -> Int32 {
        let k = key(id)
        if let first = index[k] {
            if slotMatches(first, id) { return first }
            if let bucket = collisions[k] {
                for s in bucket where slotMatches(s, id) { return s }
            }
            // Distinct id sharing this key: new slot, recorded in the side table (never overwrites
            // `index[k]`, so the first id keeps its slot). Verified by `slotMatches` on every lookup.
            let i = allocateSlot(id, make)
            collisions[k, default: []].append(i)
            return i
        }
        let i = allocateSlot(id, make)
        index[k] = i
        return i
    }

    /// Place a fresh `Node` for `id` into a recycled or newly-appended slot and return its index. The
    /// slot's key registration (`index` vs `collisions`) is the caller's (`ensureSlot`) decision.
    /// A fresh slot is UNLINKED, so its id is not yet derivable: the string goes into `retainedIds`
    /// (the invariant's case (a)) until the linking edge resolves it — the one place an id string
    /// enters the store.
    private mutating func allocateSlot(_ id: String, _ make: () -> Node) -> Int32 {
        let node = make()
        let i: Int32
        if let reused = freeList.popLast() {
            store[Int(reused)] = node
            i = reused
        } else {
            i = Int32(store.count)
            store.append(node)
        }
        retainedIds[i] = id
        return i
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
        // Already there — nothing to promote. BYTE-exact (review-1 change 1, `sameIdBytes`): a
        // canonically-equivalent but byte-distinct id is a DIFFERENT id under the store's one
        // equality relation, so it gets a real promotion (a distinct node), never a silent no-op.
        guard !Self.sameIdBytes(newRootId, rootId) else { return }
        let oldIdx = rootIndex
        let oldRootId = rootId
        let newIdx = ensureSlot(newRootId) { Node(name: newRootName, stubKind: .dir) }
        store[Int(newIdx)].name = newRootName
        store[Int(newIdx)].stubKind = .dir
        // Graft the old root as a child of the new root, IFF that edge is new. The guard
        // `parent != newIdx` mirrors the old `Set.insert().inserted`: the old root normally has
        // no parent (`noIndex`) so it links; if `newRootId` had ALREADY discovered the old root as
        // a child during scanning (its parent is already `newIdx`), we skip so the retained-total
        // fold cannot double-count. Setting the old root's `parent` here completes the upward chain
        // the new siblings' size events will later climb (`bumpSubtree`).
        if store[Int(oldIdx)].parent != newIdx {
            store[Int(newIdx)].childIndices.append(oldIdx)
            store[Int(oldIdx)].parent = newIdx
            bumpSubtree(fromSlot: newIdx,
                        allocated: store[Int(oldIdx)].subtreeAllocated,
                        logical: store[Int(oldIdx)].subtreeLogical)
        }
        rootId = newRootId
        rootIndex = newIdx
        // Phase B id bookkeeping. The NEW root's id is now the derivation base case (`rootId`), so
        // any retained string it carried (it was created unlinked, or pre-existed as an ancestor
        // stub) is dropped. The OLD root loses its base-case status: its id is derivable iff the
        // path contract holds across the graft — BYTE-exact (`sameIdBytes`, review-1 change 1):
        // `oldRootId` must equal `joinId(newRootId, oldName)` byte-for-byte (always true in
        // production, where names are `lastPathComponent`s of the same byte source); otherwise the
        // string is retained (invariant case (b)) so the grafted subtree's ids stay verbatim.
        retainedIds.removeValue(forKey: newIdx)
        if Self.sameIdBytes(oldRootId, Self.joinId(newRootId, store[Int(oldIdx)].name)) {
            retainedIds.removeValue(forKey: oldIdx)
        } else {
            retainedIds[oldIdx] = oldRootId
        }
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
            var childSlots: [Int32] = []
            childSlots.reserveCapacity(children.count)
            for stub in children {
                // A RETAINED parent re-linking this child is a legitimate re-appearance (delete+recreate):
                // clear any tombstone so the child's fresh sub-scan folds normally. Idempotent for a child
                // that was never tombstoned (the common case).
                prunedRoots.remove(stub.id)
                let ci = ensureSlot(stub.id) { Node(name: stub.name) }
                store[Int(ci)].name = stub.name
                store[Int(ci)].stubKind = stub.kind
                // write-once from the stub (order-independent)
                if stub.isHidden { store[Int(ci)].flags.insert(.isHidden) }
                else { store[Int(ci)].flags.remove(.isHidden) }
                if let m = stub.mtime { store[Int(ci)].mtimeRaw = m } // scan-time dir mtime (TZ-7); leaves keep unknown
                childSlots.append(ci)
            }
            let pi = ensureSlot(parentId) { Node(name: "") }
            store[Int(pi)].flags.insert(.discoveredChildren)
            // Track which edges are GENUINELY NEW: only a new edge may fold a child's retained
            // subtree total into the parent, so a re-stated stub (the idempotent graft reference the
            // sibling walk emits, or any duplicate batch) cannot double-count. A child's `parent`
            // already equal to `pi` means the edge exists (one parent by filesystem structure), so
            // `parent != pi` is the exact test the old `Set.insert().inserted` gave. The child slots
            // are the ones just returned by `ensureSlot` (collision-exact), not a re-lookup.
            var newlyLinked: [Int32] = []
            for (offset, ci) in childSlots.enumerated() {
                if store[Int(ci)].parent != pi {
                    store[Int(pi)].childIndices.append(ci)
                    store[Int(ci)].parent = pi
                    // Phase B: the edge exists now, so RESOLVE the child's retained id (THE MEMORY
                    // LAW). Derivable — the walker's path contract holds BYTE-for-byte
                    // (`sameIdBytes`, review-1 change 1: canonical `==` would wrongly drop the
                    // verbatim string for a byte-distinct spelling, leaving the id unfindable by
                    // the byte-wise chain compare) — ⇒ drop the string (the production outcome;
                    // ids derive on demand from here on). Contract-violating (synthetic/opaque/
                    // byte-distinct) ⇒ keep the string (invariant case (b)) so the id still
                    // round-trips verbatim. `children[offset]` is the stub that produced `ci`
                    // (childSlots is built in `children` order), so id and name are the stub's own.
                    let stub = children[offset]
                    if Self.sameIdBytes(stub.id, Self.joinId(parentId, stub.name)) {
                        retainedIds.removeValue(forKey: ci)
                    } else {
                        retainedIds[ci] = stub.id
                    }
                    newlyLinked.append(ci)
                }
            }
            // Push each newly-linked child's CURRENT retained total up the parent's ancestor chain.
            // If the child's own/descendant sizes arrive LATER, their deltas climb this same chain
            // (the child's `parent` now points here) — so "edge vs sizes" order never changes totals.
            for ci in newlyLinked {
                bumpSubtree(fromSlot: pi,
                            allocated: store[Int(ci)].subtreeAllocated,
                            logical: store[Int(ci)].subtreeLogical)
            }

        case let .sizeUpdated(nodeId, allocated, logical):
            // TZ-7 drop (OPERATOR_NOTE #2): an own-size for a tombstoned node is a late sub-scan of a
            // pruned subtree. Dropping it here is THE fix for the flat-accumulator inflation — this is the
            // one arm that would otherwise bump `rootAllocatedBytes`/`processedCount` for an orphan.
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return }
            let n = Int(ensureSlot(nodeId) { Node(name: "") })
            // Count this entry as "processed" exactly once (the first own-size write), and
            // accumulate its own size into the scan-root total on the SAME transition. The
            // walker emits one size event per stat'd node, but count/accumulate from the
            // false→true transition so both stay robust to a duplicate/replayed batch and a
            // pure function of the accumulated state.
            if !store[n].hasSize { processedCount += 1 }
            // The retained-total delta is the CHANGE in own size (first write: 0→size, so the
            // delta equals the full size; a live re-size: old→new; a replayed same-size batch:
            // a no-op 0). Push it up the ancestor chain AND into the scan-root accumulator —
            // review-4 (TZ-7): the accumulator previously moved only on the FIRST write, so
            // live re-sizes updated subtree totals while `scannedBytes`/status drifted from
            // the truth. Delta-accumulation keeps root == Σ own sizes under first writes,
            // live changes, replays, and prunes (prune subtracts own sizes symmetrically).
            let dAllocated = allocated - store[n].ownAllocated
            let dLogical = logical - store[n].ownLogical
            rootAllocatedBytes += dAllocated
            store[n].ownAllocated = allocated
            store[n].ownLogical = logical
            store[n].flags.insert(.hasSize)
            bumpSubtree(fromSlot: Int32(n), allocated: dAllocated, logical: dLogical)

        case let .accessDenied(nodeId):
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return } // late event under a pruned root
            let i = ensureSlot(nodeId) { Node(name: "") }
            store[Int(i)].flags.insert(.denied)

        case let .subtreeCompleted(nodeId):
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return } // late event under a pruned root
            let i = ensureSlot(nodeId) { Node(name: "") }
            store[Int(i)].flags.insert(.completed)

        case let .childRemoved(parentId, childId):
            prune(parentId: parentId, childId: childId)

        case let .directoryMtime(nodeId, mtime):
            // TZ-7 drop (OPERATOR_NOTE #2 / review-1 change 1): a delayed `directoryMtime` for a
            // tombstoned node (e.g. an ancestor prune removed it while its own read was in flight) would
            // otherwise re-materialize an unlinked orphan via `ensureSlot`. Drop + count.
            if isTombstoned(nodeId) { droppedOrphanEvents += 1; return }
            let i = ensureSlot(nodeId) { Node(name: "") }
            store[Int(i)].mtimeRaw = mtime
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
    /// subtract nor delete an unrelated node. No cycles: `childIndices` is a tree by filesystem
    /// structure, so the DFS deletion terminates.
    private mutating func prune(parentId: String, childId: String) {
        guard let pi = slot(of: parentId), let ci = slot(of: childId),
              let pos = store[Int(pi)].childIndices.firstIndex(of: ci) else {
            return // edge not present under this parent — nothing to remove (idempotent)
        }
        store[Int(pi)].childIndices.remove(at: pos)
        // TOMBSTONE the removed subtree root (OPERATOR_NOTE #2): late events from an in-flight sub-scan of
        // this now-deleted child (or its descendants) are DROPPED by `apply` until a retained parent
        // legitimately re-links it. Only the root is recorded — `isTombstoned` catches descendants by
        // walking up their path — so a mass delete records one id per removed edge, not one per node.
        prunedRoots.insert(childId)
        // Ripple the pruned child's WHOLE retained total out of the parent and every ancestor —
        // one negative delta up the chain, the exact reverse of the edge-addition bump. (The child's
        // own subtree total already includes its descendants, so a single delta suffices.)
        bumpSubtree(fromSlot: pi,
                    allocated: -store[Int(ci)].subtreeAllocated,
                    logical: -store[Int(ci)].subtreeLogical)
        // Delete the subtree node-by-node, backing out each node's own contribution to the
        // scan-root accumulators (so "Scanned" and the processed count track the LIVE tree, the
        // documented invariant of both — they are Σ/count over *retained* nodes).
        removeSubtree(ci, id: childId)
    }

    /// DFS-delete the subtree rooted at slot `s` (whose id is `id` — Phase B: ids are DERIVED
    /// top-down as the DFS descends via `childId`, since no slot retains its own id string) from the
    /// store, decrementing `rootAllocatedBytes`/`processedCount` by each removed node's own
    /// contribution (only where it was counted). Drops each node's map key and its `retainedIds`
    /// entry, and recycles its slot onto `freeList` so the store does not leak dead slots under
    /// live churn (THE MEMORY LAW).
    private mutating func removeSubtree(_ s: Int32, id: String) {
        let node = store[Int(s)]
        if node.hasSize {
            processedCount -= 1
            rootAllocatedBytes -= node.ownAllocated
        }
        let children = node.childIndices
        // Free this slot: drop its map key and reset the record (releasing name + child array) so
        // the recycled slot carries no stale state; then make it available for reuse. Collision-aware:
        // if `s` was this key's PRIMARY (`index`), promote a side-table entry into its place (so the
        // remaining colliding id stays reachable), else drop the primary key; if `s` was a side-table
        // entry, just remove it from the bucket. Empty buckets are dropped so `collisions` cannot leak.
        let k = key(id)
        if index[k] == s {
            if var bucket = collisions[k], !bucket.isEmpty {
                index[k] = bucket.removeLast()
                if bucket.isEmpty { collisions.removeValue(forKey: k) } else { collisions[k] = bucket }
            } else {
                index.removeValue(forKey: k)
            }
        } else if var bucket = collisions[k] {
            bucket.removeAll { $0 == s }
            if bucket.isEmpty { collisions.removeValue(forKey: k) } else { collisions[k] = bucket }
        }
        retainedIds.removeValue(forKey: s)
        store[Int(s)] = Node(name: "")
        freeList.append(s)
        // Children's ids derive from THIS node's id (`childId` reads the child's name/retained
        // entry, both still intact — only slot `s` was reset above).
        for c in children { removeSubtree(c, id: childId(c, parentId: id)) }
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
    ///   - excluding: node ids to EXCLUDE from the projection (the WATCHLIST, TZ-5 lens renamed
    ///     TZ-10 item 1): an excluded child is dropped from its parent's child list so its SIBLINGS
    ///     renormalize into the freed area, while every ANCESTOR keeps its area (an ancestor's own
    ///     weight among ITS siblings is untouched — only the excluded node's direct siblings share
    ///     out its space). A pure projection parameter, NEUTRAL to the reducer (it never learns
    ///     WHY a node is excluded); the pipeline owns the watchlist meaning. Default `[]`.
    ///   - includeHidden: when `false`, HIDDEN nodes (`Node.isHidden`) are excluded from the
    ///     projection too (the "Show hidden files" lens, TZ-5). Default `true` (scan always
    ///     includes hidden; the DEFAULT view shows them).
    ///   - weight: the per-node area-weight transform `(bytes) -> weight` (TZ-5). Applied to the
    ///     area-bounded split so the projection materializes exactly the subtrees the
    ///     SAME-weighted Squarify will render. ScanCore is neutral to WHICH scale it is (linear
    ///     or sqrt) — the composition layer supplies `AreaScale.weight` (TreemapCore). Ignored on
    ///     the full (`minRenderArea == 0`) path. Defaults to linear (`linearWeight`).
    public func makeTree(focusId: String? = nil,
                         depthWindow: Int = ScanPolicy.default.depthDetailWindow,
                         excluding: Set<String> = [],
                         includeHidden: Bool = true,
                         weight: (Int64) -> Double = ScanReducer.linearWeight) -> SizeTree {
        var pruned = 0
        var hidden: Int64 = 0
        let fid = focusId ?? rootId
        return build(id: fid, slot: slot(of: fid), depth: 0, depthWindow: depthWindow,
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
    /// (the watchlist) and `includeHidden` drop nodes so siblings renormalize; `weight`
    /// weights the area split so sqrt/linear pruning matches the layer's Squarify (the
    /// composition layer passes the same transform to both). It ALSO
    /// returns `hiddenFilteredBytes` — the summed retained total of the nodes dropped for
    /// being HIDDEN (not for being watchlisted: watchlisted subtrees are accounted by the App from
    /// the watchlisted tile's bytes, and are never descended, so their hidden descendants are
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
        let t = build(id: focusId, slot: slot(of: focusId), depth: 0, depthWindow: depthWindow,
                      area: viewportArea, minRenderArea: minRenderArea, excluding: excluding,
                      includeHidden: includeHidden, weight: weight,
                      prunedBelowArea: &pruned, hiddenFilteredBytes: &hidden)
        return (t, pruned, hidden)
    }

    private func build(id: String, slot: Int32?, depth: Int, depthWindow: Int,
                       area: Double, minRenderArea: Double,
                       excluding: Set<String>, includeHidden: Bool, weight: (Int64) -> Double,
                       prunedBelowArea: inout Int, hiddenFilteredBytes: inout Int64) -> SizeTree {
        // Absent focus (an id the scan never recorded): the pre-TZ-9 fallback was
        // `nodes[id] ?? Node(name: id)` — a lone pending placeholder tile named by its id. The
        // `contains` gate normally prevents this; reproduced here so behavior is unchanged.
        guard let s = slot else {
            return SizeTree(id: id, name: id, kind: .pending, allocatedBytes: 0, logicalBytes: 0,
                            children: [], scanState: .pending, isHidden: false, mtime: nil)
        }
        let node = store[Int(s)]
        let kind = outputKind(node)

        // Children are MATERIALIZED only inside the window; below it the array is empty. Either way
        // the node's totals come from its RETAINED subtree total — read in O(1), never recomputed —
        // so `build` visits only nodes strictly inside the window (the ratified focus-rooted bound).
        // Each child slot is already in hand (no id→node dict lookup as the old path did), and its
        // id is DERIVED top-down (Phase B): the parent's id is the `id` parameter already in hand,
        // so each child costs ONE `joinId` string join (or a `retainedIds` read for synthetic ids)
        // — no chain walk, no hashing, on the projection path. Ids round-trip verbatim either way.
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
                // TZ-5 LENSES first (one O(children) pass): SKIP watchlisted + hidden-filtered
                // children BEFORE weighting, so `totalW` excludes them and the survivors
                // RENORMALIZE into the freed area (the ratified watchlist behavior). Hidden mass
                // is accounted HERE, exactly once; watchlisted children are skipped WITHOUT hidden
                // accounting (the App owns their mass) — the no-double-count rule. Weights use
                // the injected `weight` transform so a sqrt/linear projection prunes exactly what
                // the same-weighted Squarify will render (the composition layer passes both).
                // Phase B: the watchlist test needs child IDS; deriving one per child would tax the
                // high-fanout weighting pass for a lens that is usually OFF, so the derivation is
                // gated on `excluding` being non-empty (the common empty set costs zero joins here).
                let hasExclusions = !excluding.isEmpty
                var totalW = 0.0
                for c in node.childIndices {
                    if hasExclusions, excluding.contains(childId(c, parentId: id)) { continue }
                    if !includeHidden, store[Int(c)].isHidden {
                        hiddenFilteredBytes += store[Int(c)].subtreeAllocated
                        continue
                    }
                    totalW += weight(store[Int(c)].subtreeAllocated)
                }
                var kept: [(slot: Int32, id: String, area: Double)] = []
                for c in node.childIndices {
                    let cid = childId(c, parentId: id) // derived once; used by the lens test + the kept tuple
                    if hasExclusions, excluding.contains(cid) { continue }         // watchlisted
                    if !includeHidden, store[Int(c)].isHidden { continue }         // counted above
                    let w = weight(store[Int(c)].subtreeAllocated)
                    let childArea = totalW > 0 ? area * w / totalW : 0
                    if !store[Int(c)].denied && childArea < minRenderArea {
                        prunedBelowArea += 1 // count the dropped subtree (a floor — see makeRenderTree)
                    } else {
                        kept.append((c, cid, childArea))
                    }
                }
                kept.sort { a, b in
                    let na = store[Int(a.slot)].name
                    let nb = store[Int(b.slot)].name
                    return na == nb ? a.id < b.id : na < nb
                }
                retained = kept.map {
                    build(id: $0.id, slot: $0.slot, depth: depth + 1, depthWindow: depthWindow,
                          area: $0.area, minRenderArea: minRenderArea, excluding: excluding,
                          includeHidden: includeHidden, weight: weight,
                          prunedBelowArea: &prunedBelowArea, hiddenFilteredBytes: &hiddenFilteredBytes)
                }
            } else {
                // Full projection: sort children canonically so enumeration order never leaks in.
                // The same TZ-5 lenses apply (watchlisted + hidden filtered), so a full-projection
                // consumer (e.g. a non-area-bounded view) sees the identical excluded set.
                // Phase B: each child's id is derived once here (one `joinId` off the in-hand
                // parent id) and carried through the sort + recursion.
                var kids: [(slot: Int32, id: String)] = []
                for c in node.childIndices {
                    let cid = childId(c, parentId: id)
                    if excluding.contains(cid) { continue }
                    if !includeHidden, store[Int(c)].isHidden {
                        hiddenFilteredBytes += store[Int(c)].subtreeAllocated
                        continue
                    }
                    kids.append((c, cid))
                }
                kids.sort { a, b in
                    let na = store[Int(a.slot)].name
                    let nb = store[Int(b.slot)].name
                    return na == nb ? a.id < b.id : na < nb
                }
                retained = kids.map {
                    build(id: $0.id, slot: $0.slot, depth: depth + 1, depthWindow: depthWindow,
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
            mtime: node.projectedMtime // TZ-7 staleness key; nil for leaves/until-known (root before first revalidation)
        )
    }

    /// Add `allocated`/`logical` to the RETAINED subtree total of slot `s` and of every ANCESTOR
    /// currently linked above it (inclusive of `s` itself). Walks the `parent` slot chain — O(the
    /// node's current depth), a small bounded constant in a filesystem — and is the ONLY place
    /// retained totals change. Two callers push deltas here: a node's own-size write (delta =
    /// change in own size) and an edge addition (delta = the newly-linked child's whole retained
    /// total). Because every mutation is an additive delta and addition commutes, the invariant
    /// `subtree == own + Σ linked children.subtree` holds after any interleaving — the reducer's
    /// order-independence, preserved. No cycles: a `parent` chain is strictly shallower each step
    /// (a child slot is deeper than its parent), and each edge is added at most once.
    private mutating func bumpSubtree(fromSlot s: Int32, allocated: Int64, logical: Int64) {
        if allocated == 0 && logical == 0 { return } // no-op delta (e.g. a re-stated same size)
        var cursor = s
        while cursor != ScanReducer.noIndex {
            store[Int(cursor)].subtreeAllocated += allocated
            store[Int(cursor)].subtreeLogical += logical
            cursor = store[Int(cursor)].parent
        }
    }

    /// Whether the reducer has ever recorded `id` (via any event). The composition layer
    /// gates emission on this: a focus-rooted projection of an id the scan has never
    /// produced would fabricate a lone placeholder tile; the old root-rooted-then-navigate
    /// path returned an empty layout there and the pipeline kept the last good scene. This
    /// preserves that streaming behavior (never flash a bare fill for an unknown focus).
    public func contains(_ id: String) -> Bool { slot(of: id) != nil }

    /// The retained KIND of `id` (denial-aware, derived exactly as the projection does — order-
    /// independent), or `nil` if the scan has never recorded `id`. TZ-7 (review-1 change 3): the
    /// composition layer reads this to decide whether a flagged path is a DIRECTORY to re-enumerate
    /// or an opaque BUNDLE LEAF to re-size — a bundle's descendants must never be exposed.
    public func kind(of id: String) -> NodeKind? {
        guard let s = slot(of: id) else { return nil }
        return outputKind(store[Int(s)])
    }

    /// The directory mtime the reducer currently holds for `id` (the staleness key), or `nil` if not
    /// yet known. TZ-7 SERIAL CORRECTNESS (review-1 change 1): a live reconcile whose freshly-stat'd
    /// mtime is OLDER than this is a STALE snapshot — a newer revalidation already folded the
    /// directory's later state — and is dropped whole, so a slow read can never un-do a newer one
    /// (e.g. a stale `childRemoved` retiring a just-recreated child). A directory's mtime rises
    /// monotonically with every structural change to it, which is what makes the comparison sound.
    public func mtime(of id: String) -> Int64? {
        guard let s = slot(of: id) else { return nil }
        return store[Int(s)].projectedMtime
    }

    /// The retained OWN (intrinsic) size of `id`, or `nil` if unknown. TZ-7 (review-1 change 3): the
    /// bundle re-size path compares a freshly-measured recursive total against this to stay CALM —
    /// emit no `sizeUpdated` when the opaque total is unchanged — mirroring `revalidationDiff`'s
    /// own-size discipline for directories.
    public func ownSize(of id: String) -> (allocated: Int64, logical: Int64)? {
        guard let s = slot(of: id) else { return nil }
        return (store[Int(s)].ownAllocated, store[Int(s)].ownLogical)
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
        guard let root = slot(of: id) else { return [] }
        var out: [String] = []
        // Phase B: ids are derived top-down as the DFS descends — each stack entry carries its
        // already-derived id, so each node costs one `joinId` (still "O(subtree) in strings only").
        var stack: [(slot: Int32, id: String)] = [(root, id)]
        while let (cur, cid) = stack.popLast() {
            let n = store[Int(cur)]
            let k = outputKind(n)
            if k == .dir || k == .bundleLeaf { out.append(cid) }
            for c in n.childIndices { stack.append((c, childId(c, parentId: cid))) }
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

        let dirSlot = slot(of: dirId)
        let node = dirSlot.map { store[Int($0)] }
        // Own-entry size refresh (review-0 change 5): emit only on a real change to the directory's
        // own allocation, so a stale own-size does not keep a changed directory's total short, while
        // an unchanged directory (same `st_blocks * 512`) stays calm — no event, no re-emit.
        if node?.ownAllocated != ownAllocated || node?.ownLogical != ownLogical {
            events.append(.sizeUpdated(nodeId: dirId, allocated: ownAllocated, logical: ownLogical))
            changed = true
        }

        // The retained children's opaque ids — derived off the in-hand `dirId` (Phase B), or read
        // from `retainedIds` where non-derivable; verbatim either way.
        let known: Set<String> = Set((node?.childIndices ?? []).map { childId($0, parentId: dirId) })
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
                let fileNode = slot(of: f.id).map { store[Int($0)] }
                if fileNode?.ownAllocated != f.allocated || fileNode?.ownLogical != f.logical {
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
        if slot(of: id) != nil { return id }
        var cur = id
        while let slash = cur.lastIndex(of: "/") {
            let parent = slash == cur.startIndex ? "/" : String(cur[cur.startIndex..<slash])
            if slot(of: parent) != nil { return parent }
            if parent == "/" { return nil }
            cur = parent
        }
        return nil
    }

    /// The EXACT excluded-mass accounting for the WATCHLIST (TZ-10 item 1), computed
    /// from CURRENT reducer state — the single explicit rule the App renders (review-0 change 2,
    /// replacing the App's stale/double-counting snapshot sums). Two properties the snapshot sums
    /// could not give:
    ///
    ///   - STREAMING-CORRECT. A watchlisted directory is EXCLUDED from every later scene, so a
    ///     snapshot taken at add time froze its size. Here `subtreeAllocated` is the node's
    ///     current retained total (maintained incrementally by the fold), so re-calling this each
    ///     emit re-sums the growing subtree — the figure tracks the scan instead of lying low.
    ///   - OVERLAP-DEDUPLICATED (the UNION rule). If both an ancestor and one of its descendants
    ///     are watchlisted, their masses OVERLAP; summing both snapshots double-counts. The total here
    ///     adds `subtreeAllocated` only for watchlisted "ROOTS" — a watchlisted node with NO watchlisted
    ///     ancestor — so a descendant under an already-watchlisted ancestor contributes nothing extra
    ///     (its mass is already inside the ancestor's subtree total). This is the "one explicit
    ///     union/accounting rule from current reducer state" the review requires.
    ///
    /// `currentById` carries each watchlisted id's current retained total (for the panel rows), so a
    /// row's size is live too (0 for an id watchlisted before its stub arrived — retained as nil).
    /// Pure over the accumulated state; the pipeline calls it on its actor once per emit —
    /// O(watchlisted × ancestor-chain-depth), never node-count. A tuple, not a new type: one caller.
    public func watchlistAccounting(_ ids: Set<String>) -> (total: Int64, currentById: [String: Int64]) {
        // Resolve the watchlisted ids to slots once; the ancestor test then walks `parent` slots and
        // checks membership in this set (the lean store has no parent-id STRING to compare).
        var slotOf = [String: Int32](minimumCapacity: ids.count)
        var watchlistedSlots = Set<Int32>()
        for id in ids where slot(of: id) != nil {
            let s = slot(of: id)!
            slotOf[id] = s
            watchlistedSlots.insert(s)
        }
        var currentById = [String: Int64](minimumCapacity: ids.count)
        var total: Int64 = 0
        for id in ids {
            let s = slotOf[id]
            let subtree = s.map { store[Int($0)].subtreeAllocated } ?? 0
            currentById[id] = subtree
            // Walk the retained parent chain; if any ancestor is ALSO watchlisted, this node's mass is
            // already subsumed by that ancestor's subtree total — do not add it again (union dedup).
            var subsumed = false
            var pid: Int32 = s.map { store[Int($0)].parent } ?? ScanReducer.noIndex
            while pid != ScanReducer.noIndex {
                if watchlistedSlots.contains(pid) { subsumed = true; break }
                pid = store[Int(pid)].parent
            }
            if !subsumed { total += subtree }
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
