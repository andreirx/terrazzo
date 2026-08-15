//
//  CanvasView.swift — the Metal canvas hosting the treemap.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  A layer-backed NSView whose backing layer is a CAMetalLayer (glyph-saver
//  heritage: a bare CAMetalLayer, not an MTKView — we drive rendering ourselves).
//  It owns the fixture SizeTree, rebuilds the flat scene whenever the drawable
//  size changes, and renders it through QuadRenderer.
//
//  TZ-1 is a STATIC fixture: there is no animation loop and no interaction (TZ-3
//  owns navigation). We render on demand — when the tree is set and on every
//  resize — which is sufficient to fill the window and to re-tile on resize.
//
//  The scene is laid out in DEVICE PIXELS (drawableSize), so border widths and
//  the renderer's pixel-space border band are in real pixels on any display.
//

import AppKit
import Metal
import QuartzCore
// App layer is monolith-only (build.sh / verify.sh): SizeTree / Rect /
// TreemapScene resolve same-module, so no core imports here.

final class CanvasView: NSView {
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice?
    private var renderer: QuadRenderer?
    private var tree: SizeTree?

    override init(frame frameRect: NSRect) {
        self.device = MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("CanvasView is code-only (no storyboard)") }

    // Back this view with a CAMetalLayer configured for our device/format.
    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        return l
    }

    /// Install the tree to render (the loaded fixture). Triggers a render.
    func setTree(_ tree: SizeTree) {
        self.tree = tree
        makeRendererIfNeeded()
        render()
    }

    private func makeRendererIfNeeded() {
        guard renderer == nil, let device else { return }
        // Shader source ships in the app bundle Resources (build.sh copies it);
        // the renderer stays Bundle-free and just takes the string.
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("CanvasView: Shaders.metal missing from bundle Resources")
            return
        }
        renderer = QuadRenderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source)
    }

    // MARK: - Sizing & render

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        render()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        render()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        let px = bounds.width * scale
        let py = bounds.height * scale
        guard px > 0, py > 0 else { return }
        metalLayer.drawableSize = CGSize(width: px, height: py)
        metalLayer.contentsScale = scale
    }

    private func render() {
        makeRendererIfNeeded()
        guard let renderer, let tree else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        let viewport = Rect(x: 0, y: 0, width: Double(ds.width), height: Double(ds.height))
        let tiles = TreemapScene.layout(tree: tree, viewport: viewport)
        renderer.render(tiles: tiles, to: metalLayer)
    }
}
