//
//  UnaccountedSpace.swift — the per-volume "Unaccounted" figure, as STATUS-BAR MATH.
//  Module maturity: PROTOTYPE (slice TZ-4; retargeted TZ-4b)
//
//  RENAMED FROM `SyntheticTile` (TZ-4b, HUMAN FIELD RULING 2026-08-16 #1, binding).
//  The earlier design injected a SYNTHETIC MAP TILE sized `capacity − free − scanned`
//  into the root's children. The human field ruling REVERSED that: the residual is a
//  VOLUME-LEVEL quantity (outside-~ + not-yet-scanned + purgeable), so drawing it as a
//  rectangle INSIDE a `~` map was a category error — it rendered a jarring ~700 GB
//  "monster" that deflated as the scan proceeded. The accounting stays HONEST via the
//  STATUS BAR ONLY: an "Unaccounted: X (purgeable Y + other/unknown Z)" text field.
//  So this namespace no longer BUILDS A TILE — it is pure accounting math for that
//  status field, and its name now says exactly that (the old `SyntheticTile` name was a
//  name-honesty defect the moment `augment` was deleted: a "tile" type that makes no
//  tile — CLAUDE.md constraint 5). `augment`, the synthetic `id`, and the injected
//  `.synthetic` child are GONE; `NodeKind.synthetic` remains a reserved-but-unused core
//  case (its removal is a boundary-shape change deferred, see SizeTree.swift).
//
//  WHERE IT LIVES — ScanCore (TZ-4b review-4 change 1). It reconciles the SCAN's
//  `scanned` total against the VOLUME's `capacity`/`free`/`purgeable` (raw Int64 bytes
//  from ScanFS's VolumeProbe DTO): pure scan/volume accounting arithmetic, the SAME
//  family as `ScanProgress` (the pure inode-progress math beside it here). It has NO
//  `SizeTree` dependency and composes neither engine, so it is NOT the RenderPipeline's
//  business — RenderPipeline is the pure COMPOSITION of the two engines through
//  `SizeTree` (CLAUDE.md charter), and status-accounting policy is not composition. Cores
//  are Foundation-only value math, which this is; ScanCore is its honest home. The App's
//  `DetailsReport` (the Details dialog's pure line builder) composes the displayed figure
//  from this; the pipeline no longer touches volume accounting at all.
//
//  ABSTRACTION LEDGER: a namespace of pure functions over Int64 byte counts, no protocol,
//  no state, no SizeTree dependency. Concrete users: the App's `DetailsReport` (formats
//  the figure for the Details dialog) and `UnaccountedSpaceTests` (pins residual + clamp + the ADDITIVE decompose
//  + the composed status triple). Axis of variation: none — fixed arithmetic. Rejected
//  simpler alternative — inline the subtraction in the AppKit view — would put the
//  load-bearing clamps (the honest-zero rule + the additive-decomposition rule below) in
//  an untestable UI layer.
//

import Foundation

public enum UnaccountedSpace {
    /// The unaccounted residual: `max(0, capacity − free − scanned)`. Clamped ≥ 0 — a
    /// scanned total momentarily exceeding `capacity − free` (e.g. naive hard-link/clone
    /// double-counting) yields an honest zero, not a negative figure; that going-negative
    /// signal is the ratified trigger for a future dedup pass (PLAN decision 2).
    public static func residual(capacity: Int64, free: Int64, scanned: Int64) -> Int64 {
        max(0, capacity - free - scanned)
    }

    /// DECOMPOSE the residual for the status readout (human directive 2026-08-16):
    /// "purgeable X + other users / unknown Y". `purgeable` is the volume's reclaimable
    /// bytes; the `unknown` remainder is the closest non-root estimate of space no scan
    /// from this POSIX account can see (other users' 700 homes, snapshots) — FDA never
    /// crosses user boundaries (VISION §"Root-privileged scan mode").
    ///
    /// ADDITIVE BY CONSTRUCTION (TZ-4b review-4 change 2). The status bar renders this as
    /// "Unaccounted total (purgeable Y + other/unknown Z)", so the two parts MUST sum to
    /// the residual — otherwise the readout claims a false decomposition. The reclaimable
    /// figure the volume reports can EXCEED the residual (reclaimable overlaps scanned
    /// bytes); showing it verbatim would make Y alone larger than the "Unaccounted" total,
    /// an incoherent readout. So the DISPLAYED purgeable is CAPPED at the residual it
    /// decomposes: `Y = max(0, min(purgeable, residual))`, and `Z = residual − Y`. Then
    /// `Y + Z == residual` exactly, for every input. (The volume's own uncapped
    /// reclaimable figure is still shown separately as the "Reclaimable" field; this cap
    /// governs only the Unaccounted DECOMPOSITION, which must add up.)
    public static func decompose(residual: Int64, purgeable: Int64)
        -> (purgeable: Int64, unknown: Int64) {
        let shown = max(0, min(purgeable, residual))
        return (shown, residual - shown)
    }

    /// The complete status-bar figure the App renders: the residual and its (additive)
    /// decomposition in one call, so the three values StatusBar shows ("Unaccounted X
    /// (purgeable Y + other/unknown Z)") are computed and TESTED together as one unit
    /// rather than the App re-composing two pure halves untested. `purgeable + unknown ==
    /// total` for every input (see `decompose`). `total == 0` is a fully-reconciled or
    /// unknown-capacity volume; per VISION the field is STILL shown (the number is always
    /// shown), so this is no longer a signal to omit it.
    public static func figure(capacity: Int64, free: Int64, scanned: Int64, purgeable: Int64)
        -> (total: Int64, purgeable: Int64, unknown: Int64) {
        let total = residual(capacity: capacity, free: free, scanned: scanned)
        let (p, unknown) = decompose(residual: total, purgeable: purgeable)
        return (total, p, unknown)
    }
}
