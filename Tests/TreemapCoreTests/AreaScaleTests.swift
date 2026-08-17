//
//  AreaScaleTests.swift — the pure area-weight transform (linear vs sqrt).
//  Module maturity: PROTOTYPE (slice TZ-8 OPERATOR_NOTE #2 — sqrt swap, 2026-08-17)
//
//  Pins the CONTRACT of `AreaScale.weight` directly (LensTests only exercise it through a full
//  Squarify layout). These are the "endpoint/monotonicity tests updated for sqrt" the operator
//  note requires, plus the SCALE-INVARIANCE property that motivated the swap from log:
//    (a) ENDPOINT: weight(0) == 0 in both modes — an empty sibling claims no area (no `+1` offset
//        needed for sqrt, unlike log);
//    (b) MONOTONICITY: strictly increasing in bytes, so Squarify's descending sort is identical
//        across scales (tiling exactness + sibling ordering reuse — proven end-to-end in LensTests);
//    (c) SQRT IDENTITY: the compressed weight is exactly bytes^½;
//    (d) SCALE INVARIANCE: scaling every sibling's bytes by k scales every weight by the SAME
//        factor (k^½), so it CANCELS in the per-sibling-set area ratio — equal byte ratios render
//        as equal AREA ratios at every magnitude. This is the property log LACKED (its distortion
//        was magnitude-dependent — the field bug where a 4 KB file outsized a nested 7 GB one).
//

import XCTest
import Foundation
@testable import TreemapCore

final class AreaScaleTests: XCTestCase {

    /// ENDPOINT: a zero-byte node has zero weight in BOTH modes (so it vanishes rather than
    /// claiming area). Sqrt needs no `+1` offset to achieve this — sqrt(0) == 0 already.
    func testZeroBytesMapsToZeroWeight() {
        XCTAssertEqual(AreaScale.linear.weight(0), 0, accuracy: 0)
        XCTAssertEqual(AreaScale.sqrt.weight(0), 0, accuracy: 0)
    }

    /// SQRT IDENTITY: the compressed weight is exactly bytes^½ across many magnitudes.
    func testSqrtWeightIsSquareRootOfBytes() {
        for b: Int64 in [1, 1_000, 4_096, 1_000_000, 7_000_000_000, 1_000_000_000_000] {
            XCTAssertEqual(AreaScale.sqrt.weight(b), Double(b).squareRoot(),
                           accuracy: Double(b).squareRoot() * 1e-12 + 1e-9,
                           "sqrt weight must equal bytes^½ (b=\(b))")
        }
    }

    /// MONOTONICITY: both scales are STRICTLY increasing in bytes across 8 orders of magnitude, so
    /// the descending sort Squarify relies on is identical under either scale (no reordering).
    func testWeightIsStrictlyMonotone() {
        let samples: [Int64] = [0, 1, 10, 100, 1_000, 4_096, 1_000_000,
                                50_000_000, 7_000_000_000, 1_000_000_000_000]
        for scale in [AreaScale.linear, .sqrt] {
            for i in 1..<samples.count {
                XCTAssertGreaterThan(scale.weight(samples[i]), scale.weight(samples[i - 1]),
                                     "\(scale) must be strictly increasing (\(samples[i-1]) → \(samples[i]))")
            }
        }
    }

    /// SCALE INVARIANCE (the ratified reason for the swap). For a pair of siblings, the RATIO of
    /// their sqrt weights depends ONLY on their byte ratio, NOT on the absolute magnitude — so a
    /// 1:1000 pair renders with the same area ratio whether the pair is kilobytes or terabytes.
    /// This is exactly what log FAILED (its weight ratio drifted with magnitude, the field bug).
    func testSqrtAreaRatioIsScaleInvariant() {
        func sqrtRatio(_ small: Int64, _ big: Int64) -> Double {
            AreaScale.sqrt.weight(big) / AreaScale.sqrt.weight(small)
        }
        // Same 1:1000 byte ratio at three magnitudes 10⁶ apart → identical weight ratio (√1000).
        let expected = 1000.0.squareRoot()
        let atKB = sqrtRatio(4, 4_000)
        let atMB = sqrtRatio(4_000_000, 4_000_000_000)
        XCTAssertEqual(atKB, expected, accuracy: 1e-9, "√ ratio of a 1:1000 pair is √1000 at KB scale")
        XCTAssertEqual(atMB, expected, accuracy: 1e-6, "…and the SAME at MB scale — magnitude-independent")

        // Contrast: log's ratio for the SAME byte ratio DRIFTS with magnitude (the defect sqrt cures).
        // log(1+4000)/log(1+4) ≠ log(1+4e9)/log(1+4e6) — asserted so the rationale is pinned, not just
        // asserted in prose. (Uses Foundation.log locally; AreaScale no longer carries a log mode.)
        let logKB = Foundation.log(1 + 4_000.0) / Foundation.log(1 + 4.0)
        let logMB = Foundation.log(1 + 4_000_000_000.0) / Foundation.log(1 + 4_000_000.0)
        XCTAssertGreaterThan(abs(logKB - logMB), 0.1,
                             "log's area ratio for a fixed byte ratio is magnitude-DEPENDENT — the field bug sqrt fixes")
    }
}
