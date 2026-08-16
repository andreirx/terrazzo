//
//  TileColor.swift — deterministic per-folder hue for the visualization core.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  VISUAL LANGUAGE (PLAN §"Visual language", ratified 2026-08-16): every
//  top-level folder under the current focus gets its OWN hue, derived
//  DETERMINISTICALLY from the folder NAME, so a folder keeps its color across
//  rescans, zooms, and app restarts (Library is always Library's color). All
//  descendants inherit the subtree hue; the depth-dim ladder becomes brightness
//  WITHIN the hue — applied by the renderer, not here. This file owns ONLY the
//  pure, testable name→hue mapping (packet 5b: same-name→same-hue; distinct
//  common names → well-spread hues). Saturation, the brightness ladder, and the
//  HSB→RGB conversion are rendering concerns (QuadRenderer): the core stays free
//  of colour-space detail.
//
//  STABLE HASH — the load-bearing correctness point. Swift's `Hasher` /
//  `String.hashValue` is SEEDED PER PROCESS (randomised for hash-flooding
//  resistance), so `name.hashValue` would yield a DIFFERENT colour on every
//  launch — the exact opposite of "same folder = same colour forever". We
//  therefore fold the name's UTF-8 bytes with FNV-1a, a fixed, deterministic,
//  well-avalanching function. FNV-1a is NOT cryptographic; it is chosen only for
//  cheap, stable, well-distributed folding of short strings. Because it
//  avalanches, visually similar names (Documents / Downloads) do not cluster —
//  their hashes, and thus hues, diverge. The 64-bit hash is folded to a hue in
//  [0,1) at fine resolution.
//
//  ABSTRACTION LEDGER: `TileColor` is a namespace of pure functions (no type, no
//  state — a folder name is the only input). Concrete users: `TreemapScene`
//  (assigns each tile's hue during layout) and `TileColorTests` (5b). Rejected
//  simpler alternative — carry no hue and let the renderer hash names itself —
//  would push string-hashing into the GPU-facing layer and make the "same-name→
//  same-hue / well-spread" property untestable in the pure core, which the slice
//  explicitly requires to be scene-level and headless-testable.
//

public enum TileColor {
    /// A deterministic hue in [0,1) for a folder `name`, stable across processes
    /// and launches. Same name ⇒ same hue, forever; distinct names ⇒ well-spread
    /// hues (FNV-1a avalanche). Used as the top-level subtree hue.
    public static func hue(for name: String) -> Double {
        // FNV-1a over UTF-8 bytes — deterministic (NOT Swift's seeded Hasher).
        var h: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        // Fold the well-mixed hash to a hue at fine resolution. `% hueResolution`
        // then normalise — the avalanche already spreads distinct names across
        // the wheel; no further sequence trick is needed (and claiming one would
        // be a false rationale — name honesty applies to comments too).
        let hueResolution: UInt64 = 360_000
        return Double(h % hueResolution) / Double(hueResolution)
    }
}
