//
//  GPUQuad.swift — the prebuilt, render-ready instance DTO (built off main).
//  Module maturity: PROTOTYPE (slice TZ-3b)
//
//  THE MAIN-THREAD LAW, MADE STRUCTURAL (PLAN §"Threading model": "nothing on the
//  main thread may scale with node count"). Before TZ-3b's second pass the App's
//  QuadRenderer rebuilt the per-tile GPU instance array — colour ramp, HSB→RGB,
//  viewport→NDC — ON THE MAIN THREAD, every draw. This moves that whole per-tile
//  conversion OFF main: the background `ScenePipeline` calls `QuadBuilder.build`
//  once per scene and the finished `[GPUQuad]` rides in the `RenderScene`. The App
//  then only memcpy's the prebuilt array into an MTLBuffer (O(memcpy), explicitly
//  blessed to stay on main) and draws it. No per-tile work survives on the frame
//  path (OPERATOR_NOTE gap 1).
//
//  WHY IT LIVES IN RenderPipeline (charter-compliant). The RenderPipeline charter
//  (CLAUDE.md constraint 1) is PURE COMPOSITION with ZERO Metal/AppKit imports.
//  `GPUQuad` is plain value data — eleven `Float`s, no Metal type (TZ-8 added the
//  second endpoint colour: rest/paned + own/dived) — and `QuadBuilder` is pure
//  arithmetic (the colour ramp + a textbook HSB→RGB + the pane composite). The
//  OPERATOR_NOTE authorises exactly this: "RenderPipeline may define the instance
//  STRUCT as plain value data." The GPU-side mirror of this layout lives in
//  Sources/App/Shaders.metal (`GPUQuad`); the two field lists MUST stay in lock-step
//  (same contract QuadRenderer kept with its old CPU mirror).
//
//  GEOMETRY IS WORLD-PIXEL SPACE, NOT NDC. `x/y/w/h` are the tile's layout rect in
//  DEVICE PIXELS (top-left origin, y-down) — the exact `TileRect.rect`. The camera
//  transform (dive/ascend zoom) and the world→NDC map are applied in the VERTEX
//  SHADER from uniforms, so a single prebuilt buffer serves every animation frame
//  unchanged — the per-frame cost on main collapses to updating a handful of uniform
//  scalars. BOTH dissolve-endpoint colours (`r/g/b` rest/paned + `ownR/ownG/ownB`
//  own/dived) and `style` are fully resolved here; the only things the shader still
//  varies per frame are the camera transform, the settle parameter, the TZ-8 dissolve
//  parameter (which endpoint colour to show), and the hover highlight (all uniforms, O(1)).
//
//  1:1 WITH THE SCENE'S TILES. `build` emits ONE quad per input tile, in the SAME
//  order (degenerate/zero-area tiles included as zero-size quads that draw no
//  fragments). That parallelism is load-bearing: the App aligns the settle-lerp and
//  resolves the hover-highlight index by position between `RenderScene.tiles` and
//  `RenderScene.quads`.
//
//  ABSTRACTION LEDGER: `GPUQuad` is a DTO, not an abstraction — concrete users are
//  `ScenePipeline`/verify hosts (producers via `QuadBuilder`) and QuadRenderer
//  (consumer). No protocol, no variation axis. `QuadBuilder` is a namespace of pure
//  functions with one concrete algorithm; rejected alternative — leaving the colour
//  math in QuadRenderer — is the per-tile main-thread conversion this slice removes,
//  and would force the colour ramp to be duplicated across the live and offscreen
//  render paths.
//

import Foundation
#if canImport(ScanCore)
import ScanCore
#endif
#if canImport(TreemapCore)
import TreemapCore
#endif

/// One render-ready tile instance: world-pixel geometry + TWO resolved colours + style.
/// Plain value data (eleven `Float`s, 44-byte stride, no padding) so it crosses the
/// pipeline→main boundary by value and memcpy's straight into an MTLBuffer. The GPU
/// mirror is `GPUQuad` in Sources/App/Shaders.metal — field order MUST match.
///
/// TZ-8 GLASS-PANE DEPTH TINT (PLAN §"TZ-8", ratified 2026-08-17). A tile carries its
/// colour at BOTH ends of the dive dissolve, precomputed off main; the shader blends between
/// them by ONE `dissolveT` uniform driven by the camera flight (O(1)/frame, nothing per-tile
/// on main — the ratified mechanism).
///
/// THE LOAD-BEARING CONTRACT IS POSITIONAL, NOT SEMANTIC (name-honesty, review-1 finding).
/// `r/g/b` is whatever colour the tile shows at dissolveT = 0; `ownR/ownG/ownB` is whatever it
/// shows at dissolveT = 1. The shader and `displayedColor` only ever `mix(rgb, ownRGB,
/// dissolveT)` — they NEVER assume what those colours mean. TWO producers fill the two slots
/// with DIFFERENT semantics, so the field names below describe only the first:
///
///   • `QuadBuilder.quad` — PIPELINE-SCENE quads (the steady-state render). Here the slots
///     carry the ratified PANED / OWN endpoints:
///       - `r/g/b`          = REST (paned): the tile's own hue composited under the level-1
///         ancestor's translucent pane at `paneRestAlpha` (0.72). FOCUS-RELATIVE — its pane hue
///         is the inherited ancestor hue, which changes when the tile becomes a hue root under
///         a new focus; QuadGeometry.commitFrom carries it. Equals own for hue roots (focus +
///         level-1 tiles), where own == pane.
///       - `ownR/ownG/ownB` = DIVED (own hue): the tile's own name-derived hue through the dim
///         ladder. Its HUE (chromaticity) is name-derived and focus-invariant; its RGB VALUE is
///         NOT — brightness = base·falloff^dimLevel and `dimLevel` is focus-relative, so the
///         SAME node's own RGB darkens by one ladder step when a dive makes it a deeper
///         descendant. "Own hue is focus-invariant" is true of the HUE, not the RGB.
///     Reserved-colour tiles (denied/pending) set BOTH triples to the SAME reserved colour, so
///     the dissolve is a no-op — reserved colours never participate in panes (TZ-8 deliverable
///     4; VISION invisible-space colours stay reserved).
///
///   • `QuadGeometry.embedChild` — CAMERA-HANDOFF quads (the ascend flight base ONLY). Here the
///     two slots are REPURPOSED as the flight's START / END DISPLAYED endpoints, NOT paned/own:
///       - `ownR/ownG/ownB` (shown at dissolveT = 1, flight START) = the CHILD scene's DISPLAYED
///         colour (so the ascend opens exactly on what is on screen — no snap);
///       - `r/g/b`          (shown at dissolveT = 0, flight END)   = the PARENT scene's PANED
///         colour for that node (so the pane re-condenses before the commit).
///     On these quads `ownR/ownG/ownB` is therefore NOT "the own hue" — it is the child's
///     displayed rest colour; only the POSITIONAL contract above holds. Renaming the fields to
///     drop the "own" semantics would touch the Metal mirror + every call site (a boundary
///     change, deferred); documented here instead. See `QuadGeometry.embedChild`.
public struct GPUQuad: Equatable, Sendable {
    /// World-pixel rect (device px, top-left origin, y-down) — the tile's layout rect.
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float
    /// dissolveT = 0 endpoint (the POSITIONAL contract; see the struct doc). On PIPELINE-SCENE
    /// quads (`QuadBuilder.quad`) this is the REST (paned) colour — own hue under the ancestor
    /// pane at `QuadBuilder.paneRestAlpha`, focus-relative, or a reserved denied·pending colour.
    /// On CAMERA-HANDOFF quads (`QuadGeometry.embedChild`) it is the flight-END displayed colour
    /// (the parent scene's paned colour). Kept named `r/g/b` since TZ-3b (QuadGeometry threads
    /// it through the dive/ascend geometry); the "rest" meaning is the scene-quad case only.
    public var r: Float
    public var g: Float
    public var b: Float
    /// dissolveT = 1 endpoint (the POSITIONAL contract; see the struct doc). On PIPELINE-SCENE
    /// quads (`QuadBuilder.quad`) this is the DIVED (own-hue) colour — the tile's own name hue
    /// through the dim ladder; its HUE is focus-invariant, its RGB VALUE is not (dimLevel, hence
    /// brightness, is focus-relative). Equals `r/g/b` for hue roots and reserved tiles. On
    /// CAMERA-HANDOFF quads (`QuadGeometry.embedChild`) it is the flight-START displayed colour
    /// (the child scene's displayed colour), NOT an own hue.
    public var ownR: Float
    public var ownG: Float
    public var ownB: Float
    /// Fragment-shader style branch: 0 = normal data tile (darkened border),
    /// 1 = pending (outlined-dim), 2 = denied (reserved colour), 3 = denied-overflow
    /// AGGREGATE ("N denied items" — a hatched denied badge, TZ-4b OPERATOR_NOTE #3.2).
    /// A Float so the CPU mirror stays all-Float (no hidden alignment padding).
    public var style: Float

    public init(x: Float, y: Float, w: Float, h: Float,
                r: Float, g: Float, b: Float,
                ownR: Float, ownG: Float, ownB: Float, style: Float) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.r = r; self.g = g; self.b = b
        self.ownR = ownR; self.ownG = ownG; self.ownB = ownB
        self.style = style
    }
}

/// Pure builder: `TileRect` → `GPUQuad`. Owns the colour language that used to live
/// in QuadRenderer (VISION §Experience 2 dim ladder; PLAN §"Visual language" hue).
public enum QuadBuilder {
    // COLOR CASCADE v3 (PLAN §TZ-10 item 7, human field ruling 2026-08-17). The prior tuning
    // (paneRestAlpha 0.5, dimFalloff 0.74) read as a "flat confetti" look where every depth
    // competed at similar brightness. v3 RETUNES the CONSTANTS ONLY — the dissolve/continuity
    // MECHANISM (TZ-8) is untouched (packet: "replaces the pane PARAMETERS, not the pane
    // MECHANISM") — into a monotone DARKENING CASCADE into depth:
    //   • level-1 tiles TINT STRONGER: `paneRestAlpha` raised 0.5 → 0.72, so a level-1
    //     ancestor's hue dominates its descendants' rest colour far more (the pane presence
    //     the ruling asks for). Level-1 tiles are hue roots (pane == own there), so this
    //     strengthens the tint they CAST on their subtree, not their own colour.
    //   • each level below goes progressively DARKER AND DIMMER: `dimFalloff` steepened
    //     0.74 → 0.66 (a deeper per-level brightness drop). "Darker and dimmer" are ONE
    //     axis here — a darker medium-saturation colour reads as dimmer — realised through
    //     the SINGLE monotone brightness ladder. NAME HONESTY (CLAUDE.md 5): a second
    //     per-level SATURATION factor was deliberately NOT added — it would break the TZ-8
    //     dive-rebase continuity (a scalar `brightnessRebase` cannot restore a per-level
    //     saturation change), and naming two knobs that both drive brightness would be two
    //     names for one axis. Operator tunes the exact curve at checkpoint with the human.
    private static let baseBrightness: Float = 0.92
    private static let tileSaturation: Float = 0.55
    // Per-level brightness falloff (COLOR CASCADE v3: 0.74 → 0.66, steeper = darker with depth).
    // INTERNAL (not private) as an earned test seam: the dive REBASE handoff-continuity test
    // (QuadGeometryTests.testDiveRebaseRgbContinuityAtCommit, TZ-8 OPERATOR_NOTE #4) must pin the
    // OLD-scene dive endpoint against the NEW-scene rest to EXACTLY one dim-ladder step — that
    // identity IS this constant (rebase == 1/dimFalloff), so the test reads it rather than
    // duplicating the literal. The continuity holds by construction for ANY falloff value, so the
    // v3 retune leaves every GlassPane/QuadGeometry endpoint equality green.
    static let dimFalloff: Float = 0.66
    // Denied space: its OWN warm amber-red, deliberately off the data ramp (VISION
    // §"invisible space is first-class"; name honesty — never approximated as data).
    private static let deniedColor: (Float, Float, Float) = (0.86, 0.34, 0.24)
    // Denied-overflow AGGREGATE: a deeper, desaturated amber so the "N denied items" badge
    // reads as related-to-but-distinct-from a single denied tile; the shader adds a hatch.
    private static let deniedAggregateColor: (Float, Float, Float) = (0.62, 0.30, 0.26)
    // Pending fill: a very dim blue-grey; the shader adds a bright outline so a
    // not-yet-known region reads as an outlined placeholder, not empty canvas.
    private static let pendingColor: (Float, Float, Float) = (0.30, 0.36, 0.46)

    /// TZ-8 pane strength AT REST (named constant, PLAN §"TZ-8" deliverable 1). The level-1
    /// ancestor's hue acts as a translucent glass pane over its descendants; at rest the pane
    /// is at this alpha, so the REST (paned) colour is `alpha·pane + (1−alpha)·own` — the
    /// descendant's own hue shows through by `(1−alpha)`, the "rest glimmer" (deliverable 3).
    /// 0.72 (COLOR CASCADE v3, PLAN §TZ-10 item 7 — raised from 0.5): the pane dominates ~72%,
    /// own hue glimmers ~28%, so level-1 ancestors tint their descendants STRONGER. THE TUNING
    /// KNOB: if the map reads mushy (sibling identity at the focus level unclear), raise toward
    /// 1.0 (more pane, less glimmer); lower for more per-tile hue. Operator tunes at checkpoint.
    public static let paneRestAlpha: Float = 0.72

    /// TZ-8 OPERATOR_NOTE #5 (2026-08-17, DECISION tz8-rebase-raw-rgb-continuity — RESOLVED): the
    /// DIVE brightness-rebase ENDPOINT. A dive reuses the OUTGOING (parent-focus) scene's ALREADY
    /// -prebuilt quads (no per-tile rebuild on main — OPERATOR_NOTE gap 1), so at the dive endpoint a
    /// target-child shows its own hue at the OLD, one-step-too-DEEP brightness (`base·falloff^2` while
    /// the incoming scene renders it a hue root at `base·falloff^1`). To land on the incoming scene
    /// with NO brightness pop (the earlier ~35% jump review-5 flagged), the App ramps ONE
    /// `brightnessRebase` uniform 1 → this over the flight, brightening every NORMAL tile of the
    /// outgoing scene by EXACTLY one dim-ladder step (`1/dimFalloff`). HSB→RGB is linear in
    /// brightness, so a scalar factor is exactly one ladder step; then rendered old-`dissolveT=1`
    /// == rendered new-`dissolveT=0` per channel (QuadGeometryTests.testDiveRebaseRgbContinuityAtCommit).
    /// O(1) on main — a single scalar, nothing per-tile (the law holds). ASCEND needs no rebase (its
    /// base is rebuilt by `QuadGeometry.embedChild`, which already bakes the dim-correct parent
    /// colours into the flight-end slot), so its uniform stays 1 — see NavigationController.ascend.
    public static let diveRebaseEnd: Float = 1 / dimFalloff

    /// Resolve every tile to a render-ready quad, 1:1 and in order.
    public static func build(tiles: [TileRect]) -> [GPUQuad] {
        var out = [GPUQuad]()
        out.reserveCapacity(tiles.count)
        for t in tiles { out.append(quad(for: t)) }
        return out
    }

    /// Resolve a tile to a render-ready quad carrying BOTH dissolve-endpoint colours.
    ///
    /// ORDER OF OPERATIONS (TZ-8 deliverable 4 — composition rules, stated in code):
    ///  1. RESERVED COLOURS FIRST. denied-aggregate → denied (KIND) → pending (STATE). These
    ///     get a reserved colour in BOTH triples, so the dissolve is a no-op — reserved
    ///     colours NEVER participate in panes (VISION invisible-space colours stay reserved;
    ///     name honesty). They also keep their distinct fragment `style` branch (hatch/outline).
    ///  2. DIM LADDER (normal data tile). brightness = baseBrightness · dimFalloff^dimLevel —
    ///     applied WITHIN each hue, MULTIPLICATIVELY, and to BOTH endpoint colours equally, so
    ///     the ladder composes with the pane unchanged (a dived tile is dimmed by its depth
    ///     just as a paned one is).
    ///  3. PANE BLEND. ownColor = own name hue; paneColor = the level-1 ancestor's inherited
    ///     hue (`TileRect.hue`) at the SAME brightness; the REST colour = pane composited over
    ///     own at `paneRestAlpha`. For a HUE ROOT (focus/level-1 tile) own hue == inherited
    ///     hue, so paned == own and the dive dissolve is a visual no-op on it — exactly the
    ///     ratified rule that a tile's pane is dissolved to reveal ITS CHILDREN's hues.
    ///  4. (SHADER, per frame) DISSOLVE: displayed = mix(rest, own, dissolveT) — `displayedColor`
    ///     below mirrors it for headless tests.
    ///  5. (SHADER) HOVER HIGHLIGHT is applied LAST, over the dissolved colour (unchanged).
    ///
    /// Style 3 (once the retired `.synthetic` unaccounted hatch — HUMAN FIELD RULING #1) is
    /// the denied-overflow AGGREGATE badge (TZ-4b OPERATOR_NOTE #3.2), `deniedAggregateCount > 0`.
    public static func quad(for t: TileRect) -> GPUQuad {
        let rest: (Float, Float, Float)   // dissolveT = 0 (paned)
        let own: (Float, Float, Float)    // dissolveT = 1 (own hue)
        let style: Float
        if t.kind == .denied && t.deniedAggregateCount > 0 {
            rest = deniedAggregateColor; own = deniedAggregateColor; style = 3
        } else if t.kind == .denied {
            rest = deniedColor; own = deniedColor; style = 2
        } else if t.scanState != .complete {
            rest = pendingColor; own = pendingColor; style = 1
        } else {
            let brightness = baseBrightness * pow(dimFalloff, Float(t.dimLevel))
            // The tile's OWN hue = its name-derived hue (`TileColor.hue`, the ratified
            // name→hue identity). `TileRect.hue` is the INHERITED level-1 ancestor hue (the
            // pane): equal to this for hue roots, the ancestor's for deeper descendants.
            let ownColor = hsb(h: Float(TileColor.hue(for: t.name)), s: tileSaturation, b: brightness)
            let paneColor = hsb(h: Float(t.hue), s: tileSaturation, b: brightness)
            own = ownColor
            rest = mix3(ownColor, paneColor, paneRestAlpha) // pane over own at rest alpha
            style = 0
        }
        return GPUQuad(
            x: Float(t.rect.x), y: Float(t.rect.y),
            w: Float(t.rect.width), h: Float(t.rect.height),
            r: rest.0, g: rest.1, b: rest.2,
            ownR: own.0, ownG: own.1, ownB: own.2, style: style)
    }

    /// The colour a tile DISPLAYS at a given `dissolveT`, mixing its two endpoint colours.
    /// This is the PURE MIRROR of the `mix(rest, own, dissolveT)` in the FRAGMENT stage of
    /// Shaders.metal (TZ-8 deliverable 2 — the blend is a fragment op; the endpoints ride
    /// through VOut) — the two MUST stay in lock-step, exactly as the GPUQuad field lists do. Exists so the dive dissolve (monotonicity, ascend-reverse,
    /// reserved-colour invariance) is unit-testable HEADLESS, with no GPU (QuadRenderer runs
    /// only under the Metal gates). `dissolveT` is clamped to [0,1] like the flight parameter.
    public static func displayedColor(_ q: GPUQuad, dissolveT: Float,
                                      brightnessRebase: Float = 1) -> (Float, Float, Float) {
        let d = min(1, max(0, dissolveT))
        let c = mix3((q.r, q.g, q.b), (q.ownR, q.ownG, q.ownB), d)
        // TZ-8 OPERATOR_NOTE #5 — the DIVE brightness REBASE, mirrored for headless tests. The
        // shader multiplies the dissolved colour of a NORMAL data tile by the `brightnessRebase`
        // uniform (Shaders.metal, `quad_fragment`). RESERVED colours (denied/pending — style != 0)
        // are NEVER rebased: they carry a depth-invariant reserved colour, so brightening them would
        // both violate deliverable 4/5e (reserved colours stay reserved) AND break their own handoff
        // continuity (old-t=1 reserved == new-t=0 reserved requires factor 1). Default 1 makes this a
        // no-op for every pre-note-#5 caller (all rest states, and the whole ascend path).
        guard q.style < 0.5 else { return c }
        return (c.0 * brightnessRebase, c.1 * brightnessRebase, c.2 * brightnessRebase)
    }

    /// Component-wise linear blend `(1−t)·a + t·b`. Used for the pane composite (rest colour)
    /// and, via `displayedColor`, for the dissolve — the same linear `mix` the shader uses.
    static func mix3(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ t: Float)
        -> (Float, Float, Float) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// HSB → RGB, all components in [0,1]; `h` wraps mod 1. Standard 6-sector
    /// conversion (moved verbatim from QuadRenderer, tuple-valued so RenderPipeline
    /// needs no `simd` import — it stays pure Foundation).
    static func hsb(h: Float, s: Float, b: Float) -> (Float, Float, Float) {
        let hh = (h - floor(h)) * 6.0
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = b * (1 - s)
        let q = b * (1 - s * f)
        let t = b * (1 - s * (1 - f))
        switch i {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }
}
