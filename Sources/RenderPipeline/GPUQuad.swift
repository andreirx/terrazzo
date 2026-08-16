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
//  `GPUQuad` is plain value data — eight `Float`s, no Metal type — and `QuadBuilder`
//  is pure arithmetic (the colour ramp + a textbook HSB→RGB). The OPERATOR_NOTE
//  authorises exactly this: "RenderPipeline may define the instance STRUCT as plain
//  value data." The GPU-side mirror of this layout lives in Sources/App/Shaders.metal
//  (`GPUQuad`); the two field lists MUST stay in lock-step (same contract QuadRenderer
//  kept with its old CPU mirror).
//
//  GEOMETRY IS WORLD-PIXEL SPACE, NOT NDC. `x/y/w/h` are the tile's layout rect in
//  DEVICE PIXELS (top-left origin, y-down) — the exact `TileRect.rect`. The camera
//  transform (dive/ascend zoom) and the world→NDC map are applied in the VERTEX
//  SHADER from uniforms, so a single prebuilt buffer serves every animation frame
//  unchanged — the per-frame cost on main collapses to updating a handful of uniform
//  scalars. Colour (`r/g/b`) and `style` are fully resolved here; the only things the
//  shader still varies per frame are the camera transform, the settle parameter, and
//  the hover highlight (all uniforms, O(1)).
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

/// One render-ready tile instance: world-pixel geometry + resolved colour + style.
/// Plain value data (eight `Float`s, 32-byte stride, no padding) so it crosses the
/// pipeline→main boundary by value and memcpy's straight into an MTLBuffer. The GPU
/// mirror is `GPUQuad` in Sources/App/Shaders.metal — field order MUST match.
public struct GPUQuad: Equatable, Sendable {
    /// World-pixel rect (device px, top-left origin, y-down) — the tile's layout rect.
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float
    /// Resolved colour (already ramped / HSB-converted / reserved for denied·pending).
    public var r: Float
    public var g: Float
    public var b: Float
    /// Fragment-shader style branch: 0 = normal data tile (darkened border),
    /// 1 = pending (outlined-dim), 2 = denied (reserved colour). A Float so the CPU
    /// mirror stays all-Float (no hidden alignment padding).
    public var style: Float

    public init(x: Float, y: Float, w: Float, h: Float,
                r: Float, g: Float, b: Float, style: Float) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.r = r; self.g = g; self.b = b; self.style = style
    }
}

/// Pure builder: `TileRect` → `GPUQuad`. Owns the colour language that used to live
/// in QuadRenderer (VISION §Experience 2 dim ladder; PLAN §"Visual language" hue).
public enum QuadBuilder {
    // Depth-dim ladder (VISION §Experience 2): brightness = base · falloff^dimLevel,
    // WITHIN each subtree's own hue (PLAN §"Visual language"). Medium saturation over
    // black. Verbatim the constants QuadRenderer carried — moved, not re-tuned.
    private static let baseBrightness: Float = 0.92
    private static let tileSaturation: Float = 0.55
    private static let dimFalloff: Float = 0.74
    // Denied space: its OWN warm amber-red, deliberately off the data ramp (VISION
    // §"invisible space is first-class"; name honesty — never approximated as data).
    private static let deniedColor: (Float, Float, Float) = (0.86, 0.34, 0.24)
    // Pending fill: a very dim blue-grey; the shader adds a bright outline so a
    // not-yet-known region reads as an outlined placeholder, not empty canvas.
    private static let pendingColor: (Float, Float, Float) = (0.30, 0.36, 0.46)
    // SYNTHETIC (unaccounted) tile: a desaturated steel grey, deliberately OFF the data
    // hue wheel AND distinct from denied amber / pending blue-grey, so a volume-accounting
    // residual is never mistaken for a folder (VISION §"invisible space is first-class";
    // packet 7: "must NEVER be confused with a real folder"). The shader (style 3) adds a
    // diagonal hatch to reinforce "not real data".
    private static let syntheticColor: (Float, Float, Float) = (0.34, 0.37, 0.42)

    /// Resolve every tile to a render-ready quad, 1:1 and in order.
    public static func build(tiles: [TileRect]) -> [GPUQuad] {
        var out = [GPUQuad]()
        out.reserveCapacity(tiles.count)
        for t in tiles { out.append(quad(for: t)) }
        return out
    }

    /// The colour precedence QuadRenderer used to compute per draw, now once per
    /// scene: synthetic (kind) → denied (kind) → pending (scanState) → normal data
    /// (hue · dim ladder). Synthetic and denied are KIND facts; pending is a STATE fact
    /// (not finished) — all first-class, never silent. Synthetic is checked FIRST: it is
    /// a reserved accounting tile whose reserved colour must win over any hue.
    public static func quad(for t: TileRect) -> GPUQuad {
        let color: (Float, Float, Float)
        let style: Float
        if t.kind == .synthetic {
            color = syntheticColor; style = 3
        } else if t.kind == .denied {
            color = deniedColor; style = 2
        } else if t.scanState != .complete {
            color = pendingColor; style = 1
        } else {
            let brightness = baseBrightness * pow(dimFalloff, Float(t.dimLevel))
            color = hsb(h: Float(t.hue), s: tileSaturation, b: brightness); style = 0
        }
        return GPUQuad(
            x: Float(t.rect.x), y: Float(t.rect.y),
            w: Float(t.rect.width), h: Float(t.rect.height),
            r: color.0, g: color.1, b: color.2, style: style)
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
