//
//  SyntheticTile.swift — the per-volume "Unaccounted" tile, injected as DATA.
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  VISION CORE PRINCIPLE ("invisible space is first-class"): a disk map that silently
//  omits what it cannot read cannot explain a free-space mystery. So per volume we show
//  ONE synthetic top-level tile sized `capacity − free − scanned`. If bytes invisible
//  even to enumeration (purgeable snapshots, other users' files, other-volume overlap)
//  hold space, the map SAYS so instead of lying by omission.
//
//  WHY IT LIVES HERE, AS DATA (packet directive 7: "Synthetic-tile support goes in
//  TreemapCore/RenderPipeline as data (kind: synthetic), never as renderer special-
//  casing"). The composition layer is the ONLY place both accountings meet: the scan's
//  `scanned` total (root `allocatedBytes`) and the volume's `capacity`/`free` (from
//  ScanFS's VolumeProbe, handed in by the App). So the pipeline appends a synthetic
//  CHILD to the projected root. Downstream — layout, hit-test, labels, the GPU quad —
//  treats it like any node keyed by its `kind`; nothing special-cases it in the renderer.
//
//  IT DOES NOT ALTER THE SCAN. The synthetic child is appended WITHOUT changing the
//  root's `allocatedBytes`, so `scannedBytes` (the status bar's "Scanned") stays the real
//  scanned total. The child participates only in the layout WEIGHTS of the root's tiling
//  (Squarify normalizes children to the inner rect), so the real folders shrink to make
//  room for the unaccounted tile — exactly the intended picture.
//
//  RECOMPUTED EVERY EMIT: `augment` runs on each scene build, and `scanned` grows as the
//  scan streams, so the unaccounted value shrinks toward its true residual over the scan
//  (clamped ≥ 0 — a scanned total momentarily exceeding capacity, e.g. from naive
//  hard-link/clone double-counting, yields an honest zero, not a negative tile; that
//  going-negative signal is the ratified trigger for a future dedup pass, PLAN decision 2).
//
//  ABSTRACTION LEDGER: a namespace of pure functions over `SizeTree`, no protocol, no
//  state. Concrete users: `ScenePipeline.emit` (injects) and `SyntheticTileTests` (pins
//  the sizing math + clamp + non-mutation of totals). Rejected simpler alternative —
//  synthesize the tile in the renderer/App — is exactly the "renderer special-casing"
//  the packet forbids and would put a volume-accounting residual outside the one layer
//  that legitimately sees both accountings.
//

import Foundation
#if canImport(ScanCore)
import ScanCore
#endif

public enum SyntheticTile {
    /// Stable id of the unaccounted tile. Deliberately NOT a filesystem path (angle
    /// brackets never appear in one), so it can never be confused with, dived into, or
    /// revealed as a real folder — the App gates dive/reveal on `kind == .synthetic`, and
    /// this id makes an accidental path use fail loudly rather than resolve somewhere.
    public static let unaccountedId = "⟨unaccounted⟩"
    public static let unaccountedName = "Unaccounted"

    /// The unaccounted residual: `max(0, capacity − free − scanned)`. Clamped ≥ 0.
    public static func unaccountedBytes(capacity: Int64, free: Int64, scanned: Int64) -> Int64 {
        max(0, capacity - free - scanned)
    }

    /// DECOMPOSE the unaccounted residual for the hover readout (human directive
    /// 2026-08-16): "purgeable X + other users / unknown Y", where Y = unaccounted −
    /// purgeable, clamped ≥ 0. `purgeable` is the volume's reclaimable bytes; the
    /// `unknown` remainder is the closest non-root estimate of space no scan from this
    /// POSIX account can see (other users' 700 homes, snapshots) — FDA never crosses
    /// user boundaries (VISION §"Root-privileged scan mode"). PURE so the phrasing math
    /// is pinned by `SyntheticTileTests`, not buried in the AppKit readout.
    ///
    /// Returns the two components as the readout shows them: `purgeable` verbatim (the
    /// literal ratified formula X = purgeable) and `unknown = max(0, unaccounted −
    /// purgeable)`. They need not sum to `unaccounted` when `purgeable > unaccounted`
    /// (the volume reports more reclaimable than the residual, e.g. reclaimable overlaps
    /// scanned bytes) — the clamp keeps `unknown` from going negative and the readout
    /// honest rather than forcing a false identity.
    public static func decompose(unaccounted: Int64, purgeable: Int64)
        -> (purgeable: Int64, unknown: Int64) {
        (max(0, purgeable), max(0, unaccounted - max(0, purgeable)))
    }

    /// Append the synthetic "Unaccounted" child to `root`, sized from the volume
    /// accounting. Returns `root` UNCHANGED when the accounting is unknown (`capacity
    /// <= 0`) or the residual is zero — no tile for nothing. The root's own totals are
    /// preserved (the synthetic bytes are NOT summed into `scanned`).
    public static func augment(root: SizeTree, capacity: Int64, free: Int64) -> SizeTree {
        guard capacity > 0 else { return root }
        let unaccounted = unaccountedBytes(capacity: capacity, free: free, scanned: root.allocatedBytes)
        guard unaccounted > 0 else { return root }
        let synth = SizeTree(
            id: unaccountedId, name: unaccountedName, kind: .synthetic,
            allocatedBytes: unaccounted, logicalBytes: unaccounted,
            children: [], scanState: .complete)
        return SizeTree(
            id: root.id, name: root.name, kind: root.kind,
            allocatedBytes: root.allocatedBytes, logicalBytes: root.logicalBytes,
            children: root.children + [synth], scanState: root.scanState)
    }
}
