//
//  QuadRenderer.swift — Metal instanced-quad renderer for treemap tiles.
//  Module maturity: PROTOTYPE (slice TZ-1; TZ-3b consumes PREBUILT instances)
//
//  PROVENANCE: CAMetalLayer setup, runtime shader compile
//  (`makeLibrary(source:)`), and the single-draw-call instanced-quad pattern are
//  adapted from glyph-saver's ZapRenderer (../glyph-saver/Sources/Saver/
//  ZapRenderer.swift) and its ZapZap heritage. Dropped: the two-pass
//  scene/lighting pipeline, textures, particles — TZ-1 is flat filled rects.
//
//  TZ-3b — THIS IS NOW A PURE UPLOADER (main-thread law). The per-tile conversion
//  (colour ramp, HSB→RGB, viewport→NDC) that used to run HERE on the main thread
//  every draw has moved OFF main into RenderPipeline.QuadBuilder; the finished
//  `[GPUQuad]` rides in the RenderScene. This renderer now only: (1) memcpy's a
//  prebuilt `[GPUQuad]` into an MTLBuffer (`makeQuadBuffer`, O(memcpy) — explicitly
//  blessed to stay on main, OPERATOR_NOTE gap 1), and (2) draws one instanced call
//  with the camera/settle/highlight expressed as UNIFORMS the vertex shader applies.
//  It builds no per-tile data on the frame path.
//
//  Entry points:
//    - makeQuadBuffer(_:)                     prebuilt array → MTLBuffer (per scene)
//    - render(from:to:count:uniforms:to:)     live path → the CAMetalLayer drawable
//    - renderSynchronously(quads:into:)       offscreen seam → an arbitrary texture,
//                                             blocking until the GPU finishes
//    - renderSynchronously(tiles:into:)       convenience for the offscreen gates:
//                                             builds quads via QuadBuilder, then the
//                                             above (verify.sh / scan_host render the
//                                             COMMITTED, untransformed, unhighlighted
//                                             state ONCE — a per-tile build there is
//                                             not on any frame path).
//
//  ABSTRACTION LEDGER: adds none. One concrete renderer; its collaborators are
//  RenderPipeline's GPUQuad (in) and a Metal drawable/texture (out). No renderer
//  protocol — one renderer, no demonstrated second.
//

import Metal
import QuartzCore
import simd
// NOTE: no `import TreemapCore` / `import ScanCore` / `import RenderPipeline` — the
// App layer is built ONLY by the swiftc monolith (build.sh / verify.sh), where the
// core + RenderPipeline sources are part of the same module (glyph-saver ZapRenderer
// pattern). GPUQuad / QuadBuilder / TileRect resolve same-module.

final class QuadRenderer {
    /// CPU mirror of MSL `Uniforms` (Shaders.metal). Field order + sizes MUST match.
    /// `float2` ↔ `SIMD2<Float>` (8-byte, 8-aligned); total 32 bytes. Passed by value
    /// via `setVertexBytes` (well under the 4 KB inline limit) — no per-frame buffer.
    struct Uniforms {
        var viewport: SIMD2<Float>       // device-px drawable size (world→NDC map)
        var camScale: SIMD2<Float>       // camera per-axis scale (1,1 = identity)
        var camTranslate: SIMD2<Float>   // camera translate (device px)
        var t: Float                     // settle parameter [0,1]
        var highlightIndex: Int32        // instance to highlight, or -1
    }

    /// The identity uniform for a viewport: no camera, no settle (`t=0` shows `from`),
    /// no highlight. The offscreen gates and any snap use this.
    static func identityUniforms(viewportWidth w: Double, height h: Double) -> Uniforms {
        Uniforms(viewport: SIMD2(Float(w), Float(h)),
                 camScale: SIMD2(1, 1), camTranslate: SIMD2(0, 0),
                 t: 0, highlightIndex: -1)
    }

    private static let background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// - Parameters:
    ///   - pixelFormat: the target color format (the layer's / offscreen texture's).
    ///   - shaderSource: contents of Shaders.metal. Passed in (not read from a
    ///     Bundle) so the App reads it from its bundle Resources while verify_host
    ///     reads it straight from Sources/App — the renderer has NO Bundle
    ///     dependency. Returns nil if Metal setup fails.
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

    // MARK: - Buffer upload (the only per-scene O(n) main-thread cost — a memcpy)

    /// Copy a prebuilt `[GPUQuad]` into a shared MTLBuffer. Called when the scene (or
    /// the camera base) changes — NOT per frame; the animation reuses the buffer and
    /// varies only uniforms. `nil` for an empty array (nothing to draw).
    func makeQuadBuffer(_ quads: [GPUQuad]) -> MTLBuffer? {
        guard !quads.isEmpty else { return nil }
        return quads.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count,
                              options: .storageModeShared)
        }
    }

    // MARK: - Entry points

    /// Live path: draw `count` instances from the prebuilt `from`/`to` buffers into
    /// the layer's next drawable, with `uniforms` (camera/settle/highlight). For a
    /// non-morphing frame pass the same buffer as both `from` and `to`.
    func render(from: MTLBuffer, to: MTLBuffer, count: Int, uniforms: Uniforms,
                to layer: CAMetalLayer) {
        let ds = layer.drawableSize
        guard ds.width > 0, ds.height > 0,
              let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        encode(from: from, to: to, count: count, uniforms: uniforms,
               into: drawable.texture, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Offscreen seam (verify.sh / tests): render a prebuilt `[GPUQuad]` into `target`
    /// and BLOCK until the GPU finishes. Deterministic — identity camera, no settle,
    /// no highlight; pure function of `quads`.
    func renderSynchronously(quads: [GPUQuad], into target: MTLTexture) {
        guard let buf = makeQuadBuffer(quads), let cmd = queue.makeCommandBuffer() else { return }
        let u = Self.identityUniforms(viewportWidth: Double(target.width),
                                      height: Double(target.height))
        encode(from: buf, to: buf, count: quads.count, uniforms: u, into: target, cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// Offscreen convenience for the deterministic gates: build the render-ready
    /// quads from `tiles` (via the shared off-main builder) and render the committed
    /// state. Renders ONCE per gate frame — no frame-path per-tile conversion.
    func renderSynchronously(tiles: [TileRect], into target: MTLTexture) {
        renderSynchronously(quads: QuadBuilder.build(tiles: tiles), into: target)
    }

    // MARK: - Encoding

    /// One instanced draw of `count` quads. The pass ALWAYS clears (so an empty scene
    /// paints black, not stale pixels); it draws only when there is at least one
    /// instance. Tiles are drawn in the buffer's order — TreemapScene emits pre-order
    /// (parent before children), the painter's-algorithm order that leaves each
    /// parent's inset border showing under its children.
    private func encode(from: MTLBuffer, to: MTLBuffer, count: Int, uniforms: Uniforms,
                        into target: MTLTexture, cmd: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.background
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "TreemapQuadPass"
        enc.setRenderPipelineState(pipeline)
        if count > 0 {
            enc.setVertexBuffer(from, offset: 0, index: 0)
            enc.setVertexBuffer(to, offset: 0, index: 1)
            var u = uniforms
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: count)
        }
        enc.endEncoding()
    }
}
