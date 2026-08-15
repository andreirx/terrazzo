//
//  Squarify.swift — squarified treemap layout (Bruls / Huizing / van Wijk 2000).
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  Provenance: the ALGORITHM is the published "Squarified Treemaps" method
//  (Bruls, Huizing, van Wijk — Data Visualization 2000, §3), not ported code.
//  Given a rectangle and a list of child weights, it tiles the rectangle with
//  one rect per child, area exactly proportional to weight, choosing row breaks
//  greedily to minimize the worst tile aspect ratio (tiles stay near-square,
//  which is what makes a treemap readable vs. naive slice-and-dice).
//
//  EXACT TILING BY CONSTRUCTION (TZ-1 tiling-exactness gate). Every partition is
//  a geometric subtraction or an edge-snap, never an accumulation of scaled
//  areas:
//    - a finalized "row" takes a band spanning the full short side of the
//      remaining rect; the band's thickness is `rowFraction · perpendicular`,
//      and `remaining` becomes exactly the complementary rect (subtraction);
//    - within a band, children are placed edge-to-edge and the LAST child is
//      snapped to the band's far edge (its extent computed by subtraction, not
//      by summing floats).
//  Therefore children exactly partition the parent: sum of areas == parent area,
//  no overlaps, no gaps — down to floating-point epsilon only at snapped edges.
//
//  The greedy row-break decision uses the classic closed-form worst-aspect-ratio
//  over SCALED areas (weights scaled so their sum equals the parent area); this
//  keeps the aspect math consistent with the geometry. Scaling drift never
//  affects tiling exactness (that is purely geometric) — only tile squareness.
//
//  This is core business logic (VISION: "reinvent only for core business
//  logic") — implemented directly, no external dependency.
//

import Foundation

public enum Squarify {
    /// Tile `rect` with one sub-rect per weight, area ∝ weight, worst aspect
    /// ratio minimized. Returns rects ALIGNED TO INPUT ORDER (result[i] is the
    /// rect for weights[i]); the descending sort the algorithm needs is internal.
    ///
    /// Edge cases (TZ-1 gate): empty → `[]`; one child → the whole rect;
    /// zero-area parent or all-zero weights → every child gets a zero rect at the
    /// rect origin; a zero weight mixed with positive ones → that child gets a
    /// zero-area rect and the positive children tile the whole rect.
    public static func layout(weights: [Double], in rect: Rect) -> [Rect] {
        let n = weights.count
        if n == 0 { return [] }

        let zero = Rect(x: rect.x, y: rect.y, width: 0, height: 0)
        var result = [Rect](repeating: zero, count: n)

        // Defensive: negative weights are meaningless as areas; clamp to 0.
        let clamped = weights.map { max(0, $0) }
        let total = clamped.reduce(0, +)
        guard total > 0, rect.area > 0 else {
            // Nothing to distribute (degenerate parent or all-zero weights):
            // every child is a zero rect at the origin. Honest, not a crash.
            return result
        }

        // Scale weights → areas whose sum equals the parent area, so the
        // worst-aspect math is in the same units as the geometry.
        let scale = rect.area / total
        let areas = clamped.map { $0 * scale }

        // Process largest-first (squarified quality). `order` maps row position
        // back to the original index so results stay input-aligned.
        let order = (0..<n).sorted { areas[$0] > areas[$1] }

        var remaining = rect
        var i = 0
        while i < n {
            // If the largest remaining item is zero-area, all the rest are too
            // (descending order): give each a zero rect at the current corner.
            if areas[order[i]] == 0 {
                while i < n {
                    result[order[i]] = Rect(x: remaining.x, y: remaining.y, width: 0, height: 0)
                    i += 1
                }
                break
            }

            let w = remaining.shorterSide
            let rowMax = areas[order[i]] // largest in this row (descending order)
            var rowSum = rowMax
            var rowCount = 1
            var worstCur = worstRatio(maxA: rowMax, minA: rowMax, sum: rowSum, side: w)

            // Greedily extend the row while it does not worsen the worst ratio.
            while i + rowCount < n {
                let a = areas[order[i + rowCount]] // <= current min (descending)
                let newSum = rowSum + a
                let newWorst = worstRatio(maxA: rowMax, minA: a, sum: newSum, side: w)
                if newWorst <= worstCur {
                    rowSum = newSum
                    worstCur = newWorst
                    rowCount += 1
                } else {
                    break
                }
            }

            layoutRow(order: order, start: i, count: rowCount, rowSum: rowSum,
                      areas: areas, into: &result, remaining: &remaining)
            i += rowCount
        }
        return result
    }

    /// Worst (largest) aspect ratio in a row of total area `sum` laid along a
    /// side of length `side`, given the row's max/min item areas. Closed form
    /// from the paper: max( side²·max / sum² , sum² / (side²·min) ). `min == 0`
    /// ⇒ +∞ (a zero item can never share a row) — the caller relies on that to
    /// push zero items into their own degenerate row.
    private static func worstRatio(maxA: Double, minA: Double, sum: Double, side: Double) -> Double {
        guard side > 0, sum > 0 else { return .infinity }
        let s2 = sum * sum
        let side2 = side * side
        let r1 = side2 * maxA / s2
        let r2 = minA > 0 ? s2 / (side2 * minA) : .infinity
        return max(r1, r2)
    }

    /// Place one finalized row as a band across the short side of `remaining`,
    /// then shrink `remaining` to the complementary rect. Exact by construction
    /// (see file header). `rowSum` is the row's scaled-area total.
    private static func layoutRow(order: [Int], start: Int, count: Int, rowSum: Double,
                                  areas: [Double], into result: inout [Rect],
                                  remaining: inout Rect) {
        // rowSum > 0 here (zero items are handled before this is called).
        let fraction = rowSum / remaining.area // ∈ (0, 1]; remaining.area is the invariant "unplaced area"

        if remaining.width <= remaining.height {
            // Horizontal band spanning full width, thickness downward.
            let bandH = remaining.height * fraction
            let bandY = remaining.y
            var cx = remaining.x
            for k in 0..<(count - 1) {
                let idx = order[start + k]
                let wdt = remaining.width * (areas[idx] / rowSum)
                result[idx] = Rect(x: cx, y: bandY, width: wdt, height: bandH)
                cx += wdt
            }
            // Last child snaps to the right edge (extent by subtraction → exact).
            let lastIdx = order[start + count - 1]
            result[lastIdx] = Rect(x: cx, y: bandY,
                                   width: remaining.x + remaining.width - cx, height: bandH)
            remaining = Rect(x: remaining.x, y: remaining.y + bandH,
                             width: remaining.width, height: remaining.height - bandH)
        } else {
            // Vertical band spanning full height, thickness rightward.
            let bandW = remaining.width * fraction
            let bandX = remaining.x
            var cy = remaining.y
            for k in 0..<(count - 1) {
                let idx = order[start + k]
                let ht = remaining.height * (areas[idx] / rowSum)
                result[idx] = Rect(x: bandX, y: cy, width: bandW, height: ht)
                cy += ht
            }
            let lastIdx = order[start + count - 1]
            result[lastIdx] = Rect(x: bandX, y: cy,
                                   width: bandW, height: remaining.y + remaining.height - cy)
            remaining = Rect(x: remaining.x + bandW, y: remaining.y,
                             width: remaining.width - bandW, height: remaining.height)
        }
    }
}
