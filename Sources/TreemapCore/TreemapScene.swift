//
//  TreemapScene.swift — SizeTree → flat list of positioned, dimmed tiles.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  The visualization core's top-level operation: take a SizeTree (the crossing
//  DTO), a focus node, a depth window, and a viewport rectangle, and produce a
//  FLAT list of tile DTOs the renderer can draw with zero tree knowledge. This
//  is the seam the headless tests drive and the App's QuadRenderer consumes —
//  the renderer never walks the tree; it draws whatever tiles it is handed.
//
//  Layout model (VISION §Experience 2, "nested, depth-dimmed squarified"):
//    - The focus node fills the viewport at dimLevel 0. It is mostly covered by
//      its children and shows through only as the border frame.
//    - Its children tile the focus rect INSET by a small named border
//      (`Layout.borderInset`), at dimLevel 1; their children tile THEM inset, at
//      dimLevel 2; and so on. Deeper level ⇒ higher dimLevel ⇒ the renderer
//      draws it dimmer. "children tile their parent inset by a small border;
//      deeper level = higher dimLevel" (TZ-1 deliverable 3).
//    - Recursion stops at `depthWindow` (default 5): no tile has dimLevel >
//      depthWindow. This is the visible/scanned depth window from VISION.
//
//  Emission order is PRE-ORDER (parent before its children). The renderer relies
//  on this for painter's-algorithm compositing: a parent is drawn first, then
//  its children paint over it, leaving the inset border showing. Documented
//  contract, not an accident.
//
//  Layout weight = allocatedBytes (PLAN open decision 1's recommendation; the
//  metric that explains free space). TZ-1 does not render per-node UNACCOUNTED
//  space (children are scaled to fill the parent's inner rect); surfacing
//  within-node unaccounted area is TZ-2/TZ-4 work (noted, not silently dropped).
//

import Foundation
// ScanCore is a SEPARATE module under SPM (`swift test`) and must be imported;
// under the swiftc monolith build (build.sh / verify.sh) ScanCore's sources are
// compiled into the SAME module, so there is no module to import — canImport is
// false there and the types resolve same-module. This one guard lets the single
// cross-module file compile in both worlds. (App-layer files never import the
// cores — like glyph-saver's ZapRenderer — because they are monolith-only.)
#if canImport(ScanCore)
import ScanCore
#endif

/// One positioned tile the renderer draws. Flat: carries everything needed to
/// draw AND to read out WITHOUT the tree — its rect, how deep it is (dim), its
/// identity/kind for hit-testing and denied/pending styling, and (TZ-3b) the
/// display metadata (name + allocated/logical bytes) the hover readout and
/// right-click menu show. Carrying that metadata on the tile is what lets the App
/// resolve a hovered tile to its name+sizes over the VIEWPORT-BOUNDED rendered-tile
/// list, instead of a `SizeTree.node(withId:)` traversal on the main actor — the
/// ratified law forbids main work that scales with node count (review-3 item 1).
public struct TileRect: Equatable, Sendable {
    public let rect: Rect
    /// 0 at the focus node, +1 per level of nesting, capped at the depth window.
    /// The renderer maps this to brightness (higher = dimmer).
    public let dimLevel: Int
    public let nodeId: String
    public let kind: NodeKind
    /// Scan progress of the underlying node. Added in TZ-2 (resolving the TZ-1
    /// open question): `NodeKind` stays "what it is", `ScanState` carries "how far
    /// scanned", and the renderer styles a not-yet-`.complete` tile outlined-dim
    /// WITHOUT conflating kind and state. Concrete current user: QuadRenderer.
    public let scanState: ScanState
    /// Subtree hue in [0,1) (TZ-3, PLAN §"Visual language"): the hue of this
    /// tile's TOP-LEVEL ancestor under the current focus, derived from that
    /// ancestor's NAME (`TileColor.hue`) and INHERITED by every descendant, so a
    /// whole subtree shares one hue and the dim ladder becomes brightness within
    /// it. The focus tile (dimLevel 0) and each top-level tile (dimLevel 1) are
    /// their own hue roots. The renderer turns (hue, dimLevel) into an HSB colour;
    /// `denied`/`pending` tiles ignore hue and keep their reserved colours.
    public let hue: Double
    /// Display name (the node's last path component) for the hover readout / menu
    /// title. Denormalized from the SizeTree node at layout time so the App never
    /// re-walks the tree on main to get it (TZ-3b, review-3 item 1).
    public let name: String
    /// Bytes on disk for this node — the hover readout's "allocated". Denormalized
    /// here for the same reason as `name`.
    public let allocatedBytes: Int64
    /// Apparent size for this node — the hover readout's "logical".
    public let logicalBytes: Int64
    /// 0 for an ordinary tile. > 0 marks this tile as a DENIED-OVERFLOW AGGREGATE badge
    /// (TZ-4b OPERATOR_NOTE #3.2, DECISION denied_visibility_vs_render_bound): a single
    /// synthesized badge standing in for `deniedAggregateCount` denied siblings that could
    /// not each receive their own minimum badge area under the parent's render-bound cap.
    /// `kind` stays `.denied` (it IS denied space); `name` reads "N denied items"; `nodeId`
    /// is the parent id + `deniedAggregateSuffix` (a synthetic, collision-proof id). The
    /// renderer styles it distinctly (hatched) and the App resolves the parent from the id
    /// to disclose the list on demand. This keeps every denied node REPRESENTED (VISION:
    /// never silently dropped) while the rendered-tile count stays viewport-bounded —
    /// visibility is per-fact, not per-rectangle.
    public let deniedAggregateCount: Int

    public init(rect: Rect, dimLevel: Int, nodeId: String, kind: NodeKind,
                scanState: ScanState = .complete, hue: Double = 0,
                name: String = "", allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0,
                deniedAggregateCount: Int = 0) {
        self.rect = rect
        self.dimLevel = dimLevel
        self.nodeId = nodeId
        self.kind = kind
        self.scanState = scanState
        self.hue = hue
        self.name = name
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.deniedAggregateCount = deniedAggregateCount
    }
}

/// What a clicked denied-overflow AGGREGATE badge discloses: the display names of the
/// collapsed denied children (sorted, deterministic) and their IMPLIED size — a lower bound
/// (their contents are unreadable). A raw value DTO: it is produced by the PURE
/// `TreemapScene.deniedDisclosure` AND returned by `ScenePipeline.deniedDisclosure` ACROSS the
/// actor→main boundary (review-5: the resolution must run on the pipeline actor, not on main),
/// so it must be `Sendable` and carry only primitives. `Equatable` so tests can pin it.
///
/// ABSTRACTION LEDGER: a DTO, not an abstraction — no protocol, no variation axis. Concrete
/// users: `TreemapScene.deniedDisclosure` (producer), `ScenePipeline.deniedDisclosure` (actor
/// op crossing the boundary), `NavigationController` (presents it). Rejected simpler
/// alternative: a bare `(names:, impliedBytes:)` tuple — a tuple is not a nameable, documented
/// boundary type and reads poorly as an actor method's return; the boundary rule (CLAUDE.md:
/// data crossing a boundary is a simple named value) wants a struct.
public struct DeniedDisclosure: Equatable, Sendable {
    /// Denied child display names, sorted deterministically.
    public let names: [String]
    /// Sum of the denied children's KNOWN bytes (each dir's own entry) — a LOWER bound on the
    /// true size, since their contents are unreadable. The App qualifies it with "≥".
    public let impliedBytes: Int64
    public init(names: [String], impliedBytes: Int64) {
        self.names = names
        self.impliedBytes = impliedBytes
    }
}

public enum TreemapScene {
    /// Default number of nesting levels rendered below (and including) the focus.
    /// dimLevel ranges 0...depthWindow, i.e. the focus plus 5 levels of children
    /// (VISION §Experience 2 "default depth 5 visible").
    public static let defaultDepthWindow = 5

    /// Small border, in viewport units, by which each parent is inset before its
    /// children tile it — the visible nesting frame. Named so the tests and the
    /// renderer agree on the exact value.
    public static let defaultBorderInset: Double = 2.0

    /// Minimum on-screen area (viewport units²; device px² in the App — ~24×16 px) a
    /// `denied` BADGE tile is FLOORED to when its proportional area would be
    /// smaller (TZ-4b rider 1, ratified). Rationale: a denied node's size is
    /// UNKNOWN, so its area is a readability BADGE ("we don't know"), never a measurement
    /// — at root scale a tiny denied subtree is otherwise sub-pixel and invisible on the
    /// map that exists to surface it. We honor this by reserving EXACTLY this area for
    /// each floored badge (`badgePlan` solves for the weight that maps to it
    /// under Squarify's area∝weight tiling); the tiling stays EXACT (only weights change,
    /// never the rect partition). Because the reserved area (≫ the App's sub-pixel cull
    /// threshold) lifts the badge above that cull, badges need NO cull exemption — the
    /// composition layer culls them like any other tile, and the render bound is
    /// preserved (see below + `ScenePipeline.minRenderAreaPx`).
    public static let minBadgeArea: Double = 384.0
    /// The MAXIMUM fraction of a parent's inner area that badge tiles may collectively
    /// occupy — a name-honest cap (review-0 finding 3b). It bounds the reservation two
    /// ways: total floored badge area ≤ `maxBadgeFraction · innerArea` (so a swarm of
    /// badges can never squeeze the real folders below half the parent), AND — since each
    /// floored badge takes `minBadgeArea` — the COUNT of floored badges is ≤
    /// `maxBadgeFraction · innerArea / minBadgeArea`. That count bound is what keeps the
    /// number of badges clearing the pipeline's sub-pixel cull VIEWPORT-bounded rather
    /// than child-count-bounded (finding 3c; the main-thread law). Badges beyond that
    /// capacity keep their raw (sub-pixel) weight and are culled like anything else.
    private static let maxBadgeFraction: Double = 0.5

    /// Suffix appended to a PARENT's id to form its denied-overflow AGGREGATE badge's synthetic
    /// nodeId (TZ-4b OPERATOR_NOTE #3.2). Contains a NUL, which cannot occur in a filesystem
    /// path — so the synthetic id can never collide with a real node id, and the App can strip
    /// it to recover the parent id and disclose the collapsed denied list from the tree.
    public static let deniedAggregateSuffix = "\u{0}denied-aggregate"

    /// A tile whose size is UNKNOWN, so its area is a badge, not a measurement. Only
    /// `denied` qualifies now — the `.synthetic` unaccounted tile was removed (HUMAN
    /// FIELD RULING #1: the figure is a status-bar field, never laid out as a tile).
    private static func isBadge(_ kind: NodeKind) -> Bool {
        kind == .denied
    }

    /// If `nodeId` is a denied-overflow aggregate's synthetic id, the PARENT node id it was
    /// synthesized under; else `nil`. Lets the App resolve an aggregate badge back to the folder
    /// whose denied children it collapsed, so a click can disclose that list from the scene tree
    /// — no id list is carried on the tile (TZ-4b OPERATOR_NOTE #3.2). Pure, so it is unit-tested.
    public static func deniedAggregateParentId(from nodeId: String) -> String? {
        guard nodeId.hasSuffix(deniedAggregateSuffix) else { return nil }
        return String(nodeId.dropLast(deniedAggregateSuffix.count))
    }

    /// The DISCLOSURE a clicked denied-overflow aggregate reveals: the display names of `parent`'s
    /// denied children (sorted, deterministic) and their IMPLIED size — the sum of those nodes'
    /// KNOWN bytes (each denied dir's own entry; its contents are unreadable, so the true size is
    /// at LEAST this — a lower bound the App qualifies with "≥"). Pure over the SizeTree (TZ-4b
    /// review-4 change 3) so the popover's CONTENT is unit-tested here, not buried in the
    /// untestable AppKit popover; the App only formats the bytes and presents the list. Concrete
    /// CONTRACT v2 (operator note #4, resolving review-6): this is the parent's FULL DENIED
    /// INVENTORY — every denied child, floored badges included — NOT only the aggregate's
    /// collapsed subset. The App labels both numbers (inventory count vs the badge's collapsed
    /// count) so the popover can never be mistaken for subset accounting. Rationale: the user
    /// cares about what is denied HERE; binding the popover to layout bookkeeping would thread
    /// viewport geometry through three layers to show strictly less information. Concrete
    /// users: `ScenePipeline.deniedDisclosure` (which projects `parent` off main from the reducer)
    /// + `TreemapSceneTests`. Rejected simpler alternative: leave the filter/sum inline in the App
    /// view — untestable under `swift test` AND, per review-5, it would run on the main actor.
    public static func deniedInventory(under parent: SizeTree) -> DeniedDisclosure {
        let denied = parent.children.filter { $0.kind == .denied }
        let names = denied
            .map { $0.name.isEmpty ? ($0.id as NSString).lastPathComponent : $0.name }
            .sorted()
        let impliedBytes = denied.reduce(Int64(0)) { $0 + max(0, $1.allocatedBytes) }
        return DeniedDisclosure(names: names, impliedBytes: impliedBytes)
    }

    /// One thing to be tiled under a parent: either a REAL child (recursed into) or the
    /// synthesized denied-overflow AGGREGATE (a single leaf badge). See `badgePlan`.
    private enum Placement {
        case child(SizeTree)
        case aggregate(count: Int, allocated: Int64, logical: Int64)
    }

    /// Flatten `tree` into positioned tiles.
    ///
    /// - Parameters:
    ///   - tree: the whole SizeTree (root).
    ///   - focusId: node to fill the viewport; `nil` ⇒ the root.
    ///   - depthWindow: max dimLevel emitted (default 5).
    ///   - viewport: the rectangle the focus node fills (pixel space in the App;
    ///     any units in tests).
    ///   - borderInset: per-level inset (default `defaultBorderInset`).
    ///   - scale: per-sibling-set layout-weight transform (TZ-5 deliverable 2). `.linear`
    ///     (default) tiles by true bytes; `.log` compresses the range so giants cannot
    ///     eclipse the tail. Monotone, so tiling exactness and sibling ordering are
    ///     UNCHANGED — only the areas compress (the numbers on tiles are always real bytes).
    ///     The composition layer passes the SAME scale to `ScanReducer.makeRenderTree`, so
    ///     the materialized subtrees match this partition (see `AreaScale`).
    /// - Returns: pre-order tile list; `[]` if `focusId` is not found.
    public static func layout(
        tree: SizeTree,
        focusId: String? = nil,
        depthWindow: Int = defaultDepthWindow,
        viewport: Rect,
        borderInset: Double = defaultBorderInset,
        scale: AreaScale = .linear
    ) -> [TileRect] {
        let focus: SizeTree
        if let focusId {
            guard let found = node(withId: focusId, in: tree) else { return [] }
            focus = found
        } else {
            focus = tree
        }
        var tiles: [TileRect] = []
        place(node: focus, rect: viewport, level: 0, inheritedHue: 0,
              depthWindow: depthWindow, borderInset: borderInset, scale: scale, into: &tiles)
        return tiles
    }

    /// Pre-order recursive placement. Emits `node`, then (if within the depth
    /// window and there is room) tiles its children in the inset rect.
    ///
    /// Hue assignment (PLAN §"Visual language"): the focus (level 0) and each
    /// top-level tile (level 1) are HUE ROOTS — they derive their hue from their
    /// own name; deeper tiles INHERIT the hue passed down. `inheritedHue` is thus
    /// only consulted at level ≥ 2. Threading it down the recursion keeps the
    /// assignment a pure property of the layout, not a second tree walk.
    private static func place(
        node: SizeTree, rect: Rect, level: Int, inheritedHue: Double,
        depthWindow: Int, borderInset: Double, scale: AreaScale, into tiles: inout [TileRect]
    ) {
        let tileHue = level <= 1 ? TileColor.hue(for: node.name) : inheritedHue
        tiles.append(TileRect(rect: rect, dimLevel: level, nodeId: node.id,
                              kind: node.kind, scanState: node.scanState, hue: tileHue,
                              name: node.name, allocatedBytes: node.allocatedBytes,
                              logicalBytes: node.logicalBytes))

        guard level < depthWindow, !node.children.isEmpty else { return }
        let inner = rect.inset(by: borderInset)
        guard inner.area > 0 else { return } // no room to nest — stop honestly

        let (placements, weights) = badgePlan(children: node.children, innerArea: inner.area, scale: scale)
        let childRects = Squarify.layout(weights: weights, in: inner)
        for (placement, childRect) in zip(placements, childRects) {
            switch placement {
            case let .child(child):
                place(node: child, rect: childRect, level: level + 1, inheritedHue: tileHue,
                      depthWindow: depthWindow, borderInset: borderInset, scale: scale, into: &tiles)
            case let .aggregate(count, allocated, logical):
                // The synthesized denied-overflow badge: one leaf tile standing in for `count`
                // denied siblings. `.denied` kind + a distinct hatched render (QuadBuilder
                // style 3); no recursion (it has no real children).
                tiles.append(TileRect(
                    rect: childRect, dimLevel: level + 1,
                    nodeId: node.id + deniedAggregateSuffix, kind: .denied,
                    scanState: .complete, hue: tileHue,
                    name: "\(count) denied items", allocatedBytes: allocated,
                    logicalBytes: logical, deniedAggregateCount: count))
            }
        }
    }

    /// Plan the tiling of `children`: the ordered `Placement`s (real children + at most one
    /// synthesized denied-overflow AGGREGATE) and their parallel Squarify weights.
    ///
    /// TWO forces, composed (TZ-4b rider 1 + OPERATOR_NOTE #3.2 DECISION):
    ///
    ///  1. BADGE FLOOR (rider 1; review-0 finding 3). A `denied` tile's size is UNKNOWN, so its
    ///     area is a readability BADGE, not a measurement. Sub-minimum denied badges are FLOORED
    ///     so each realizes EXACTLY `minBadgeArea` (A). Squarify gives a child of weight `w` in a
    ///     total `T` an area `w/T·innerArea`; to make `m` floored badges each realize `A` while
    ///     every other child keeps its raw weight (summing to `keepRaw`), solve
    ///     `f/(keepRaw + m·f)·innerArea = A` ⇒ `f = A·keepRaw / (innerArea − m·A)`. Only badges
    ///     whose *natural* area is below A are floored (a genuinely large denied dir keeps its
    ///     true area), smallest first, and at most `maxFloored = ⌊maxBadgeFraction·innerArea/A⌋`.
    ///
    ///  2. OVERFLOW → AGGREGATE (the ratified render-bound resolution). Denied badges BEYOND the
    ///     `maxFloored` capacity would otherwise stay at sub-pixel weight and be culled — a
    ///     SILENT drop the VISION forbids. Instead they collapse into ONE aggregate badge whose
    ///     weight is their COMBINED raw weight, so the partition of every OTHER tile (floored
    ///     badges + reals) is byte-identical to the un-collapsed layout — only the swarm of
    ///     sub-pixel overflow tiles becomes one readable "N denied items" badge. Every denied
    ///     node stays REPRESENTED while the rendered-tile count stays viewport-bounded:
    ///     visibility is per-fact, not per-rectangle. (The App discloses the collapsed list on
    ///     demand from the parent id encoded in the aggregate's synthetic nodeId.)
    ///
    /// THE CAP IS HONEST — IT CAN BE ZERO (review-1 finding 1). When the parent is too small to
    /// grant even ONE badge its minimum under the fraction cap — `innerArea < 2·minBadgeArea` —
    /// `maxFloored` is 0 and NOTHING is floored OR aggregated: every child keeps its raw weight
    /// (the denied badge holds its small-but-positive proportional area, never a negative weight
    /// that Squarify would clamp to zero — the finding-1 vanish). No aggregate is synthesized
    /// there because there is no capacity for even one badge. Otherwise `m ≤ maxFloored ≤
    /// 0.5·innerArea/A`, so `denom = innerArea − m·A > 0` and the readable-badge count (floored +
    /// the one aggregate) is viewport-bounded, not child-count-bounded (finding 3c).
    private static func badgePlan(children: [SizeTree], innerArea: Double, scale: AreaScale)
        -> (placements: [Placement], weights: [Double]) {
        // TZ-5: the per-sibling-set weight transform (linear bytes vs log(1+bytes)). Applied
        // HERE, at the single point Squarify weights are formed, so the scale governs the exact
        // partition. Everything downstream (badge floor, aggregate overflow, tiling exactness)
        // is weight-agnostic — it operates on areas and these weights, so it is unchanged.
        let raw = children.map { scale.weight($0.allocatedBytes) }
        func passthrough() -> ([Placement], [Double]) { (children.map(Placement.child), raw) }
        guard innerArea > 0 else { return passthrough() }
        let rawTotal = max(1, raw.reduce(0, +))

        let badgeIdx = children.indices.filter { isBadge(children[$0].kind) }
        guard !badgeIdx.isEmpty else { return passthrough() }

        let A = minBadgeArea
        let maxFloored = Int((maxBadgeFraction * innerArea / A).rounded(.down))
        // Honest zero: a parent too small for even one badge floors/aggregates nothing (finding 1).
        guard maxFloored > 0 else { return passthrough() }

        // Sub-minimum badges, smallest-first (deterministic by (area, id)). These are the
        // denied tiles that would render below A at natural scale — the ones that need help.
        let subMin = badgeIdx
            .filter { raw[$0] / rawTotal * innerArea < A }
            .sorted { (raw[$0], children[$0].id) < (raw[$1], children[$1].id) }
        guard !subMin.isEmpty else { return passthrough() } // all badges already large enough

        // Split the sub-min badges into individually-floored vs collapsed-into-the-aggregate.
        // When they fit the capacity, floor them all (no aggregate — the rider-1 layout). When
        // they overflow, reserve ONE of the `maxFloored` slots for the aggregate and floor the
        // rest (smallest first) individually — so the aggregate is itself a floored badge of
        // area exactly A, ALWAYS readable, never sub-pixel even behind a huge sibling.
        let individuallyFloored: [Int]
        let collapsed: [Int]
        if subMin.count <= maxFloored {
            individuallyFloored = subMin; collapsed = []
        } else {
            individuallyFloored = Array(subMin.prefix(maxFloored - 1)) // may be empty (maxFloored == 1)
            collapsed = Array(subMin.dropFirst(maxFloored - 1))
        }
        let flooredSet = Set(individuallyFloored)
        let collapsedSet = Set(collapsed)
        let m = individuallyFloored.count + (collapsed.isEmpty ? 0 : 1) // floored slots incl. the aggregate

        // f realizes area exactly A per floored slot. keepRaw counts children that are NEITHER
        // floored NOR collapsed (reals + genuinely-large denied); the collapsed badges are
        // represented by the floored aggregate, not by raw weight. m ≤ maxFloored ⇒ denom > 0.
        // keepRaw == 0 (a parent of only badges) ⇒ equal weights split the parent, each slot
        // ≥ inner/m ≥ 2A — still readable.
        let keepRaw = children.indices
            .filter { !flooredSet.contains($0) && !collapsedSet.contains($0) }
            .reduce(0.0) { $0 + raw[$1] }
        let denom = innerArea - Double(m) * A
        let f = keepRaw > 0 ? A * keepRaw / denom : 1.0

        // No overflow → the pure badge-floor layout (unchanged from rider 1), no aggregate.
        if collapsed.isEmpty {
            return (children.map(Placement.child),
                    children.indices.map { flooredSet.contains($0) ? f : raw[$0] })
        }

        // Overflow → every non-collapsed child in original order, then ONE aggregate badge.
        var placements: [Placement] = []; placements.reserveCapacity(children.count)
        var weights: [Double] = []; weights.reserveCapacity(children.count)
        for i in children.indices where !collapsedSet.contains(i) {
            placements.append(.child(children[i]))
            weights.append(flooredSet.contains(i) ? f : raw[i])
        }
        let alloc = collapsed.reduce(Int64(0)) { $0 + max(0, children[$1].allocatedBytes) }
        let logical = collapsed.reduce(Int64(0)) { $0 + max(0, children[$1].logicalBytes) }
        placements.append(.aggregate(count: collapsed.count, allocated: alloc, logical: logical))
        weights.append(f) // the aggregate is a floored badge → area exactly A (or the even split)
        return (placements, weights)
    }

    /// Depth-first search for a node by id. O(n); TZ-1 has no index (files are
    /// the system of record, no caches — CLAUDE.md constraint 4).
    private static func node(withId id: String, in tree: SizeTree) -> SizeTree? {
        if tree.id == id { return tree }
        for child in tree.children {
            if let found = node(withId: id, in: child) { return found }
        }
        return nil
    }
}
