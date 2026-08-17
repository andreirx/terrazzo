//
//  AreaScale.swift — the treemap layout-weight transform (linear vs logarithmic).
//  Module maturity: PROTOTYPE (slice TZ-5)
//
//  TZ-5 deliverable 2 (PLAN §TZ-5 "Scale toggle", VISION amended 2026-08-16):
//  "tile weights pass through a monotone log transform (log(1+bytes)) before
//  Squarify, per sibling set — giant tiles otherwise eclipse the long tail."
//  This is the pure value that names the two modes and computes the per-node
//  layout WEIGHT from its byte size. It is a LENS over the untouched scan tree:
//  it changes only how much AREA a node gets, never the node's real bytes (the
//  numbers on tiles and hover chips are always the true `allocatedBytes` — the
//  honesty guard: "areas may compress, numbers never lie").
//
//  WHY IT LIVES IN TreemapCore, NOT ScanCore (review-1 change 3, the boundary fix).
//  Area weighting is a VISUALIZATION POLICY: it is the treemap's decision how to map
//  bytes to on-screen area. It belongs to the visualization engine. The earlier draft
//  put it in ScanCore so `ScanReducer`'s area-bounded projection could weight nodes the
//  same way `Squarify` does — but that gave ScanCore a hard dependency on a
//  visualization concept, violating CLAUDE.md constraint 1 (the two engines meet ONLY
//  at `SizeTree`). The projection does still need to weight nodes to prune coherently,
//  but it does not need to know WHICH scale — only HOW to weight. So `ScanReducer`
//  now takes a bare `weight: (Int64) -> Double` function (dependency inversion: ScanCore
//  defines the seam; it stays ignorant of linear vs log), and the COMPOSITION layer
//  (`ScenePipeline`, the one module that imports both cores) is where coherence is
//  enforced — it passes THIS enum's `weight` to the reducer AND this enum to
//  `TreemapScene.layout`, so the pruned set and the Squarify partition agree by
//  construction, at the single point that owns both. That is exactly the RenderPipeline
//  charter (a pure composition layer) doing its job.
//
//  ABSTRACTION LEDGER: a two-case sum type + one pure `weight(_:)` function.
//  Concrete users: `TreemapScene.badgePlan` (the Squarify weight) + `ScenePipeline`
//  (holds the active mode, echoes it on `RenderScene.scaleMode`, and hands
//  `scale.weight` to the reducer projection) + the App's scale toggle/status label.
//  Axis of variation: the FIXED set of area-weighting modes (VARIANTS fixed, operations
//  grow → a sum type with exhaustive `switch`, the ratified dispatch for a closed variant
//  set). Rejected simpler alternative: a bare `(Int64) -> Double` closure everywhere —
//  not `Equatable` (the pipeline needs to detect a real mode change to force a re-emit),
//  not a nameable value the status bar can label, and it would scatter the log formula
//  across call sites instead of naming it once here. (ScanCore's projection DOES take
//  that bare closure — there the seam is deliberately policy-free; only the composition
//  layer and the treemap name the mode.)
//

import Foundation

public enum AreaScale: String, Sendable, Equatable, Codable {
    /// True-proportion: weight == bytes. Giant tiles dominate exactly (the "HUGE
    /// rectangles" mode).
    case linear
    /// Monotone log compression: weight == log(1 + bytes). Compresses the range so
    /// a giant cannot eclipse the long tail, WITHOUT reordering (log is strictly
    /// increasing, so sibling ordering is identical to linear — the tiling-exactness
    /// and ordering tests reuse). This is the ratified DEFAULT (VISION: "logarithmically
    /// compressed by default").
    case log

    /// The RATIFIED log base (PLAN §TZ-5: "log(1+bytes), named constant base"). Named and
    /// USED in `weight` below via the change-of-base identity `log_b(x) = ln(x)/ln(b)`.
    ///
    /// WHICH base, and WHY it is `e` (the selection this constant records). Within one sibling
    /// set every child's weight is divided by the SAME sibling total, and changing the base
    /// multiplies EVERY weight by the same constant `1/ln(b)` — which cancels in that ratio. So
    /// the rendered AREAS are identical for any base > 1; the base is a free choice, and we
    /// record the natural log (`e`) as that choice. Naming it (rather than inlining a bare
    /// `log(1+b)`) satisfies the ratified requirement literally AND documents the decision at the
    /// one place the formula lives, so a future change of base is a one-line edit here.
    public static let logBase: Double = M_E

    /// The Squarify layout WEIGHT for a node of `bytes` on-disk size, per this scale.
    /// Always ≥ 0 and monotone non-decreasing in `bytes` (so the descending sort
    /// Squarify uses is identical across scales).
    ///
    /// The `log` case is `log_base(1 + bytes)` with the named `logBase` above. The `+1` offset
    /// is the load-bearing part: it maps a 0-byte node to weight 0 (exactly like linear, and
    /// exactly `log_base(1) = 0`), so an empty sibling still vanishes rather than claiming area.
    /// With `logBase == e` the `/ log(logBase)` divisor is 1, so the behavior is identical to a
    /// bare `log(1+b)` — the base is named and used without changing the rendered layout.
    public func weight(_ bytes: Int64) -> Double {
        let b = Double(max(0, bytes))
        switch self {
        case .linear: return b
        case .log: return Foundation.log(1.0 + b) / Foundation.log(Self.logBase)
        }
    }
}
