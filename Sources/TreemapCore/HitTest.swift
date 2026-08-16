//
//  HitTest.swift — cursor point → the deepest tile under it + its ancestor chain.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  The visualization core's pointer query. It operates on the SAME flat
//  `[TileRect]` list that `TreemapScene.layout` produces and `QuadRenderer` draws
//  — no tree, no re-derived geometry, no parent pointers. The renderer and the
//  hit-tester therefore agree by construction: whatever pixels you see are what
//  you can click, because both read the one tile list.
//
//  WHY A FLAT LIST SUFFICES (the load-bearing invariant)
//  -----------------------------------------------------
//  A TreemapScene layout is NESTED and PRE-ORDER: a child's rect lies strictly
//  inside its parent's border-inset rect, and siblings PARTITION their parent's
//  inner rect under half-open containment (`Rect.contains`). Two consequences
//  make the flat query exact:
//
//    1. At most ONE tile per dimLevel contains a given point. (Base: the focus
//       tile at level 0 covers the viewport. Step: if exactly one level-k tile
//       contains p, its children partition its inner rect half-open, so ≤1 of
//       them contains p; tiles under a NON-containing level-k tile cannot contain
//       p either, being inside it.) So the containing tiles have distinct levels.
//    2. The containing set is CONTIGUOUS from level 0 down to some deepest level:
//       a level-(k+1) tile containing p implies its level-k parent contains p
//       (child ⊂ parent). No gaps.
//
//  Therefore the tiles containing p, sorted by dimLevel, ARE exactly the deepest
//  tile plus its ancestor chain up to the focus — obtained by a filter + sort, no
//  tree walk. A point landing in a parent's inset BORDER (between its children)
//  yields a chain that stops at that parent: an honest "you are on folder X, not
//  in any of its children."
//
//  PRECONDITION: `tiles` must be a `TreemapScene.layout` output (nested,
//  pre-order). The invariants above are properties of THAT producer; this
//  function is not a general polygon locator and does not defend against
//  arbitrary overlapping input (there is one concrete producer — no speculative
//  generality).
//
//  ABSTRACTION LEDGER: adds none. `HitChain` is a raw DTO returned to the App's
//  NavigationController (its one concrete user); `HitTest` is a namespace of pure
//  functions. Rejected simpler alternative — returning just the deepest TileRect
//  — loses the ancestor chain the App needs for the hover highlight (top-level
//  ancestor) and the dive target, which would then be re-derived by a second walk.
//

/// The tiles containing a queried point, ordered shallow→deep by `dimLevel`.
/// Non-empty whenever returned (a `nil` HitChain is never constructed — the
/// caller gets `Optional<HitChain>`).
public struct HitChain: Equatable, Sendable {
    /// index 0 = the focus tile (dimLevel 0); last = the deepest tile under the
    /// point. Guaranteed non-empty and strictly increasing in dimLevel.
    public let chain: [TileRect]

    public init(chain: [TileRect]) {
        self.chain = chain
    }

    /// The deepest tile under the point — the readout subject (its full path +
    /// sizes) and the Finder-reveal target.
    public var deepest: TileRect { chain[chain.count - 1] }

    /// The BRIGHT top-level tile (dimLevel 1) under the point: the hover-highlight
    /// subject and the one-level-down dive/scroll-in target (VISION §Experience
    /// 3–4). `nil` only when the point is on the focus tile's own border with no
    /// child beneath it (`chain == [focus]`).
    public var topLevelUnderFocus: TileRect? { chain.first { $0.dimLevel == 1 } }
}

public enum HitTest {
    /// The deepest tile at `p` plus its ancestor chain, or `nil` if no tile
    /// contains `p`. See the file header for why filter-then-sort is exact on a
    /// TreemapScene layout.
    public static func hit(tiles: [TileRect], at p: Point) -> HitChain? {
        let containing = tiles.filter { $0.rect.contains(p) }
        guard !containing.isEmpty else { return nil }
        let ordered = containing.sorted { $0.dimLevel < $1.dimLevel }
        return HitChain(chain: ordered)
    }
}
