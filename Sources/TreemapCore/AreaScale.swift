//
//  AreaScale.swift — the treemap layout-weight transform (linear vs sqrt-compressed).
//  Module maturity: PROTOTYPE (slice TZ-5; sqrt swap TZ-8 OPERATOR_NOTE #2, 2026-08-17)
//
//  TZ-5 deliverable 2 (PLAN §TZ-5 "Scale toggle", VISION amended 2026-08-16; SQRT ratified
//  2026-08-17 superseding log): "tile weights pass through sqrt(bytes) before Squarify, per
//  sibling set — giant tiles otherwise eclipse the long tail." This is the pure value that
//  names the two modes and computes the per-node layout WEIGHT from its byte size. It is a
//  LENS over the untouched scan tree: it changes only how much AREA a node gets, never the
//  node's real bytes (the numbers on tiles and hover chips are always the true
//  `allocatedBytes` — the honesty guard: "areas may compress, numbers never lie").
//
//  WHY SQRT, NOT LOG (human decision 2026-08-17, PLAN §TZ-5 rationale — the ratified swap).
//  Log's compression is MAGNITUDE-DEPENDENT: log(1+b) maps a fixed byte ratio to a DIFFERENT
//  area ratio depending on where on the scale the pair sits, so in the field a 4 KB root file
//  outsized a nested 7 GB one — a category error for a size map. Power laws (here x^½) are the
//  UNIQUE scale-invariant monotone family: scaling every sibling's bytes by k scales every
//  weight by k^½, which CANCELS in the per-sibling-set area ratio — so equal byte ratios render
//  as equal area ratios at EVERY depth. Sqrt was chosen over a milder x^0.4 by the human for
//  gentler compression while keeping that scale-invariance. Like linear (and unlike log's `+1`
//  offset dance), sqrt(0) == 0, so an empty sibling still vanishes rather than claiming area —
//  no offset is needed.
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
//  defines the seam; it stays ignorant of linear vs sqrt), and the COMPOSITION layer
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
//  not a nameable value the status bar can label, and it would scatter the sqrt formula
//  across call sites instead of naming it once here. (ScanCore's projection DOES take
//  that bare closure — there the seam is deliberately policy-free; only the composition
//  layer and the treemap name the mode.)
//

import Foundation

public enum AreaScale: String, Sendable, Equatable, Codable {
    /// True-proportion: weight == bytes. Giant tiles dominate exactly (the "HUGE
    /// rectangles" mode).
    case linear
    /// Scale-invariant sqrt compression: weight == sqrt(bytes). Compresses the range so
    /// a giant cannot eclipse the long tail, WITHOUT reordering (sqrt is strictly
    /// increasing, so sibling ordering is identical to linear — the tiling-exactness
    /// and ordering tests reuse) and WITHOUT the magnitude-dependent distortion log had
    /// (a power law is scale-invariant: equal byte ratios ⇒ equal area ratios at every
    /// depth). This is the ratified DEFAULT (PLAN §TZ-5, 2026-08-17).
    case sqrt

    /// The Squarify layout WEIGHT for a node of `bytes` on-disk size, per this scale.
    /// Always ≥ 0 and monotone non-decreasing in `bytes` (so the descending sort
    /// Squarify uses is identical across scales).
    ///
    /// The `sqrt` case is `bytes^½`. Like linear it maps a 0-byte node to weight 0 (so an
    /// empty sibling vanishes rather than claiming area), and unlike log it needs no `+1`
    /// offset to do so. `.squareRoot()` (not the free `Foundation.sqrt`) keeps this
    /// unambiguous next to the `.sqrt` case name.
    public func weight(_ bytes: Int64) -> Double {
        let b = Double(max(0, bytes))
        switch self {
        case .linear: return b
        case .sqrt: return b.squareRoot()
        }
    }
}
