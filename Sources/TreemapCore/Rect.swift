//
//  Rect.swift — a pure value rectangle for the visualization core.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  TreemapCore is pure Swift (CLAUDE.md constraint 1: Foundation value types
//  only — no CoreGraphics, no AppKit). CGRect lives in CoreGraphics/Metal land,
//  so the core owns a tiny axis-aligned rectangle instead. Origin is top-left,
//  y grows DOWNWARD — the same convention the fixture viewport uses (0,0 at the
//  top-left of the canvas); the App layer flips to Metal NDC at the boundary.
//
//  Concrete users (why this type is earned, not speculative): Squarify (produces
//  child rects) and TreemapScene (insets parents, holds tile rects). Two current
//  callers in this same slice → a shared value type, not duplicated structs. The
//  rejected simpler alternative — a bare (Double,Double,Double,Double) tuple —
//  loses `area`/`inset` naming and invites index bugs across the two callers.
//

/// Axis-aligned rectangle, top-left origin, y-down. All-Double for exact area
/// arithmetic during tiling-exactness checks.
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
    public var shorterSide: Double { min(width, height) }

    /// Shrink on all four sides by `d`. Clamped so the result never inverts:
    /// if the rect is thinner than `2·d` in a dimension, that dimension collapses
    /// to 0 (a degenerate rect) rather than going negative. Used by TreemapScene
    /// to inset a parent before tiling its children (the visible border frame).
    public func inset(by d: Double) -> Rect {
        let iw = max(0, width - 2 * d)
        let ih = max(0, height - 2 * d)
        // Keep the inset rect centered even when a dimension collapses.
        let nx = x + (width - iw) / 2
        let ny = y + (height - ih) / 2
        return Rect(x: nx, y: ny, width: iw, height: ih)
    }

    /// Area of the axis-aligned overlap with `other` (0 if disjoint). Used by the
    /// tiling-exactness tests to assert no two child tiles overlap.
    public func intersectionArea(_ other: Rect) -> Double {
        let ix = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let iy = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return ix * iy
    }

    /// HALF-OPEN containment: `[x, x+width) × [y, y+height)`. Added in TZ-3 for
    /// hit-testing. Half-open is deliberate and load-bearing: adjacent tiles share
    /// an edge, and half-open makes a point on that seam belong to EXACTLY ONE
    /// tile — the property `HitTest` relies on to return a single unambiguous
    /// root→leaf chain rather than a fork. The trade-off: a point exactly on the
    /// viewport's far (right/bottom) outer edge is NOT contained; the App clamps
    /// cursor coordinates strictly inside the drawable before hit-testing, so that
    /// boundary is never queried in practice. Concrete users: HitTest (this slice).
    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.x < x + width && p.y >= y && p.y < y + height
    }
}

/// A point in the SAME space as `Rect` (top-left origin, y-down; pixels in the
/// App, any units in tests). A tiny value type — earned by two concrete current
/// users, `HitTest` (cursor → tile) and `FocusCamera` (transforming a probe
/// point); the rejected alternative, a bare `(Double, Double)` tuple, loses the
/// `.x/.y` naming both callers read and invites axis-swap bugs across them.
public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
