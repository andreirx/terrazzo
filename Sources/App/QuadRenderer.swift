//
//  QuadRenderer.swift — Metal instanced-quad renderer for treemap tiles.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  PROVENANCE: CAMetalLayer setup, runtime shader compile
//  (`makeLibrary(source:)`), and the single-draw-call instanced-quad pattern are
//  adapted from glyph-saver's ZapRenderer (../glyph-saver/Sources/Saver/
//  ZapRenderer.swift) and its ZapZap heritage. Dropped: the two-pass
//  scene/lighting pipeline, textures, particles — TZ-1 is flat filled rects.
//
//  This is the App-side half of the crossing point: it consumes a flat
//  [TileRect] (TreemapCore output) and knows nothing about SizeTree, scanning,
//  or the treemap algorithm. It maps each tile's viewport-space rect (top-left
//  origin, y-down, in DEVICE PIXELS) to Metal NDC, its dimLevel to a brightness,
//  and draws all tiles in ONE instanced draw call.
//
//  Two entry points share one encode path:
//    - render(tiles:to:)              live path → the CAMetalLayer's drawable
//    - renderSynchronously(tiles:into:) offscreen seam → an arbitrary texture,
//                                       blocking until the GPU finishes
//                                       (scripts/verify.sh determinism gate).
//
//  ABSTRACTION LEDGER: adds none. One concrete renderer; its only collaborators
//  are TreemapCore's TileRect (in) and a Metal drawable/texture (out). No
//  renderer protocol — there is exactly one renderer and no demonstrated second.
//

import Metal
import QuartzCore
import simd
// NOTE: no `import TreemapCore` / `import ScanCore` — the App layer is built ONLY
// by the swiftc monolith (build.sh / verify.sh), where the core sources are part
// of the same module (glyph-saver ZapRenderer pattern). TileRect/Rect/NodeKind
// resolve same-module.

final class QuadRenderer {
    /// CPU mirror of MSL `QuadInstance` — 11 contiguous Floats (44-byte stride).
    /// All-Float on purpose (no SIMD3) so there is no hidden 16-byte alignment
    /// padding between CPU and GPU layouts (the trap ZapRenderer's PointLightGPU
    /// avoids the same way). Field order + count MUST match Shaders.metal's
    /// `QuadInstance`. (Corrected in TZ-3: the prior comment said "9 Floats/36
    /// bytes", stale since TZ-2 added `kd` — the struct was already 10 Floats/40
    /// bytes; TZ-3 adds `hl` → 11/44. Comment now matches the actual layout.)
    private struct QuadInstance {
        var ox: Float = 0, oy: Float = 0, sx: Float = 0, sy: Float = 0
        var r: Float = 0, g: Float = 0, b: Float = 0
        var pw: Float = 0, ph: Float = 0
        /// Style code the fragment shader branches on: 0 = normal (data tile,
        /// darkened border), 1 = pending (outlined-dim: dark fill, bright edge),
        /// 2 = denied (its own color, normal border). Kept as a Float so the CPU
        /// mirror stays all-Float (no hidden alignment padding — see header note).
        var kd: Float = 0
        /// Hover-highlight flag (TZ-3): 1 = this tile is the top-level ancestor
        /// under the cursor → the fragment shader lifts its fill and draws a thin
        /// bright outline (VISION §Experience 3). Orthogonal to `kd` on purpose —
        /// a denied or pending tile can also be highlighted (name honesty: kind,
        /// scan-state, and hover are three independent facts, not one code).
        var hl: Float = 0
    }

    // Depth-dim ladder (VISION §Experience 2: each level progressively dimmer).
    // TZ-3 (PLAN §"Visual language"): the tile's COLOUR is now HSB(hue, sat,
    // brightness) where `hue` is the per-subtree hue TreemapScene assigned
    // (deterministic from the top-level folder name) and `brightness` is the
    // existing depth ladder — brightness = baseBrightness · falloff^dimLevel — so
    // "shallower = brighter" is preserved, now WITHIN each folder's own hue.
    // Medium saturation over black (PLAN "medium saturation on black"). dimLevel 0
    // (focus) is brightest but mostly hidden under its children, so the VISIBLE
    // gradient is "top-level folders bright → deeper dimmer", per colour.
    private static let baseBrightness: Float = 0.92
    private static let tileSaturation: Float = 0.55
    private static let dimFalloff: Float = 0.74
    // Denied space gets its OWN color, deliberately NOT on the blue data ramp
    // (VISION §"invisible space is first-class"; name honesty — a denied tile is
    // never approximated into ordinary data). A warm amber-red reads as "blocked".
    private static let deniedColor = SIMD3<Float>(0.86, 0.34, 0.24)
    // Pending fill: a very dim blue-grey; the shader adds a brighter outline so a
    // not-yet-known region reads as "outlined placeholder", not empty canvas.
    private static let pendingColor = SIMD3<Float>(0.30, 0.36, 0.46)
    private static let background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// - Parameters:
    ///   - pixelFormat: the target color format (the layer's / offscreen
    ///     texture's — both `.bgra8Unorm` in TZ-1).
    ///   - shaderSource: contents of Shaders.metal. Passed in (not read from a
    ///     Bundle) so the App reads it from its bundle Resources while
    ///     verify_host reads it straight from Sources/App — the renderer has NO
    ///     Bundle dependency. Returns nil if Metal setup fails.
    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, shaderSource: String) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            NSLog("QuadRenderer: shader compile failed: \(error)")
            return nil
        }
        guard let vfn = library.makeFunction(name: "quad_vertex"),
              let ffn = library.makeFunction(name: "quad_fragment") else {
            NSLog("QuadRenderer: missing shader function(s)")
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "TreemapQuadPass"
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            NSLog("QuadRenderer: pipeline creation failed: \(error)")
            return nil
        }
    }

    // MARK: - Entry points

    /// Live path: render `tiles` into the layer's next drawable. `tiles` must be
    /// laid out in the SAME pixel space as `layer.drawableSize`. `highlightedId`
    /// (TZ-3) is the nodeId of the tile to draw with the hover highlight, or nil.
    func render(tiles: [TileRect], highlightedId: String?, to layer: CAMetalLayer) {
        let ds = layer.drawableSize
        guard ds.width > 0, ds.height > 0,
              let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        encode(tiles: tiles, highlightedId: highlightedId, into: drawable.texture,
               pixelWidth: Double(ds.width), pixelHeight: Double(ds.height), cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Offscreen seam (verify.sh / tests): render into `target` and BLOCK until
    /// the GPU finishes. Deterministic — no time input, pure function of `tiles`.
    /// `tiles` must be laid out in `target`'s pixel space. No highlight (the
    /// deterministic gate renders unhighlighted committed focus states).
    func renderSynchronously(tiles: [TileRect], into target: MTLTexture) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        encode(tiles: tiles, highlightedId: nil, into: target,
               pixelWidth: Double(target.width), pixelHeight: Double(target.height), cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Encoding

    /// Build instances from tiles and draw them in one instanced call. Tiles are
    /// drawn in the order given — TreemapScene emits pre-order (parent before
    /// children), which is exactly the painter's-algorithm order that leaves each
    /// parent's inset border showing under its children.
    private func encode(tiles: [TileRect], highlightedId: String?, into target: MTLTexture,
                        pixelWidth W: Double, pixelHeight H: Double, cmd: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.background
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "TreemapQuadPass"
        enc.setRenderPipelineState(pipeline)

        var instances = [QuadInstance]()
        instances.reserveCapacity(tiles.count)
        for tile in tiles {
            guard tile.rect.width > 0, tile.rect.height > 0 else { continue } // skip degenerate

            // Style precedence: denied (kind) → pending (scanState) → normal data.
            // Denied is a KIND fact (we could not enter); pending is a STATE fact
            // (we have not finished). Both are first-class, never silent.
            let color: SIMD3<Float>
            let kd: Float
            if tile.kind == .denied {
                color = Self.deniedColor; kd = 2
            } else if tile.scanState != .complete {
                color = Self.pendingColor; kd = 1
            } else {
                let brightness = Self.baseBrightness * pow(Self.dimFalloff, Float(tile.dimLevel))
                color = Self.hsb(h: Float(tile.hue), s: Self.tileSaturation, b: brightness); kd = 0
            }

            var q = QuadInstance()
            // viewport (top-left origin, y-down, pixels) → NDC (y-up).
            q.ox = Float(2.0 * tile.rect.x / W - 1.0)
            q.oy = Float(1.0 - 2.0 * tile.rect.y / H)
            q.sx = Float(2.0 * tile.rect.width / W)
            q.sy = Float(-2.0 * tile.rect.height / H)
            q.r = color.x; q.g = color.y; q.b = color.z
            q.pw = Float(tile.rect.width)
            q.ph = Float(tile.rect.height)
            q.kd = kd
            q.hl = (highlightedId != nil && tile.nodeId == highlightedId) ? 1 : 0
            instances.append(q)
        }

        if !instances.isEmpty,
           let buf = device.makeBuffer(bytes: instances,
                                       length: instances.count * MemoryLayout<QuadInstance>.stride,
                                       options: .storageModeShared) {
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: instances.count)
        }
        enc.endEncoding()
    }

    /// HSB → RGB, all components in [0,1]. A tiny pure helper (NOT `NSColor` —
    /// this file is also compiled into the AppKit-free `verify_host` gate, which
    /// links CoreGraphics but not AppKit; using `NSColor` here would break that
    /// build). Standard 6-sector conversion. `h` wraps mod 1.
    private static func hsb(h: Float, s: Float, b: Float) -> SIMD3<Float> {
        let hh = (h - floor(h)) * 6.0
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = b * (1 - s)
        let q = b * (1 - s * f)
        let t = b * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(b, t, p)
        case 1: return SIMD3(q, b, p)
        case 2: return SIMD3(p, b, t)
        case 3: return SIMD3(p, q, b)
        case 4: return SIMD3(t, p, b)
        default: return SIMD3(b, p, q)
        }
    }
}
