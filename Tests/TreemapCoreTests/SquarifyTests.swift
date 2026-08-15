//
//  SquarifyTests.swift — the tiling-exactness gate for the squarified layout.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  These are the numerical proofs the slice demands: children areas sum to the
//  parent (epsilon), NO overlaps, NO gaps, areas proportional to weights, and a
//  worst-aspect-ratio bound better than naive slicing. Plus the edge cases
//  (empty / one child / zero-size / all-zero).
//

import XCTest
@testable import TreemapCore

final class SquarifyTests: XCTestCase {
    // Absolute area epsilon scaled to the parent area — snapped edges introduce
    // only floating rounding, so this is generous but still tight (< 1e-6 of area).
    private func eps(_ parent: Rect) -> Double { parent.area * 1e-9 + 1e-6 }

    /// Worst (largest) aspect ratio across a set of rects (>= 1; a square is 1).
    private func worstAspect(_ rects: [Rect]) -> Double {
        rects.reduce(1.0) { acc, r in
            guard r.width > 0, r.height > 0 else { return acc }
            return max(acc, max(r.width / r.height, r.height / r.width))
        }
    }

    private let parent = Rect(x: 10, y: 20, width: 640, height: 400)

    private let weights: [Double] = [
        6, 6, 4, 3, 2, 2, 1, 1, 0.5, 0.25, 100, 0.1, 40, 40, 12, 7,
    ]

    func testAreasSumToParent() {
        let rects = Squarify.layout(weights: weights, in: parent)
        let sum = rects.reduce(0) { $0 + $1.area }
        XCTAssertEqual(sum, parent.area, accuracy: eps(parent),
                       "child areas must sum to the parent area (no gaps, no spill)")
    }

    func testNoOverlaps() {
        let rects = Squarify.layout(weights: weights, in: parent)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let overlap = rects[i].intersectionArea(rects[j])
                XCTAssertLessThanOrEqual(overlap, eps(parent),
                                         "tiles \(i) and \(j) overlap by \(overlap)")
            }
        }
    }

    func testNoGaps() {
        // With every rect inside the parent, pairwise non-overlapping, AND total
        // area equal to the parent area, coverage is complete — a gap would force
        // the sum below the parent area. Assert all three legs.
        let rects = Squarify.layout(weights: weights, in: parent)
        for (k, r) in rects.enumerated() {
            XCTAssertGreaterThanOrEqual(r.x, parent.x - eps(parent), "tile \(k) left of parent")
            XCTAssertGreaterThanOrEqual(r.y, parent.y - eps(parent), "tile \(k) above parent")
            XCTAssertLessThanOrEqual(r.x + r.width, parent.x + parent.width + eps(parent),
                                     "tile \(k) right of parent")
            XCTAssertLessThanOrEqual(r.y + r.height, parent.y + parent.height + eps(parent),
                                     "tile \(k) below parent")
        }
        let sum = rects.reduce(0) { $0 + $1.area }
        XCTAssertEqual(sum, parent.area, accuracy: eps(parent))
    }

    func testAreaProportionality() {
        let rects = Squarify.layout(weights: weights, in: parent)
        let total = weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            let expected = parent.area * w / total
            XCTAssertEqual(rects[i].area, expected, accuracy: eps(parent),
                           "tile \(i) area must be proportional to its weight")
        }
    }

    func testAspectRatioBeatsNaiveSlicing() {
        // Naive slice-and-dice: one row spanning the full height, widths ∝ weight.
        // Squarified must not be worse, and for this skewed set is strictly better.
        let squar = Squarify.layout(weights: weights, in: parent)
        let total = weights.reduce(0, +)
        var naive: [Rect] = []
        var cx = parent.x
        for w in weights {
            let width = parent.width * w / total
            naive.append(Rect(x: cx, y: parent.y, width: width, height: parent.height))
            cx += width
        }
        let squarWorst = worstAspect(squar)
        let naiveWorst = worstAspect(naive)
        XCTAssertLessThanOrEqual(squarWorst, naiveWorst,
                                 "squarified worst aspect \(squarWorst) must be ≤ naive \(naiveWorst)")
        XCTAssertLessThan(squarWorst, naiveWorst,
                          "for a skewed weight set squarified should be strictly better")
        // Sanity: squarified keeps tiles reasonably square (loose absolute bound).
        XCTAssertLessThan(squarWorst, 12.0, "squarified worst aspect unexpectedly large")
    }

    // MARK: - Edge cases

    func testEmpty() {
        XCTAssertEqual(Squarify.layout(weights: [], in: parent), [])
    }

    func testOneChildFillsParent() {
        let rects = Squarify.layout(weights: [42], in: parent)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0], parent)
    }

    func testZeroSizeChildMixedWithPositive() {
        let w: [Double] = [5, 0, 3, 0, 2]
        let rects = Squarify.layout(weights: w, in: parent)
        // Zero-weight children get zero-area rects; positive children tile the whole parent.
        XCTAssertEqual(rects[1].area, 0, accuracy: eps(parent))
        XCTAssertEqual(rects[3].area, 0, accuracy: eps(parent))
        let sum = rects.reduce(0) { $0 + $1.area }
        XCTAssertEqual(sum, parent.area, accuracy: eps(parent),
                       "positive children must still tile the whole parent")
        // No overlaps even with the degenerate members.
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                XCTAssertLessThanOrEqual(rects[i].intersectionArea(rects[j]), eps(parent))
            }
        }
    }

    func testAllZeroWeights() {
        let rects = Squarify.layout(weights: [0, 0, 0], in: parent)
        XCTAssertEqual(rects.count, 3)
        for r in rects { XCTAssertEqual(r.area, 0, accuracy: eps(parent)) }
    }

    func testDegenerateParent() {
        let flat = Rect(x: 0, y: 0, width: 100, height: 0)
        let rects = Squarify.layout(weights: [1, 2, 3], in: flat)
        XCTAssertEqual(rects.count, 3)
        for r in rects { XCTAssertEqual(r.area, 0, accuracy: 1e-9) }
    }

    func testManyRandomWeightsStayExact() {
        // Deterministic pseudo-random stress: exactness must hold at scale.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) & 0xFFFFF) / Double(0x100000) + 0.001
        }
        let ws = (0..<200).map { _ in next() * (next() > 0.9 ? 500 : 1) }
        let p = Rect(x: -5, y: 7, width: 1234.5, height: 987.25)
        let rects = Squarify.layout(weights: ws, in: p)
        let sum = rects.reduce(0) { $0 + $1.area }
        XCTAssertEqual(sum, p.area, accuracy: p.area * 1e-9 + 1e-6)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where rects[i].area > 0 && rects[j].area > 0 {
                XCTAssertLessThanOrEqual(rects[i].intersectionArea(rects[j]), p.area * 1e-9 + 1e-6)
            }
        }
    }
}
