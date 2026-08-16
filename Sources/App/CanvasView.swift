//
//  CanvasView.swift — the Metal canvas hosting the LIVE treemap.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  A layer-backed NSView whose backing layer is a CAMetalLayer (glyph-saver
//  heritage: a bare CAMetalLayer, not an MTKView — we drive rendering ourselves).
//
//  TZ-2 makes it LIVE: `updateTree` is called on a ~1 s cadence (ratified
//  decision 3) with a fresh SizeTree snapshot from the streaming scan. Between
//  snapshots the canvas does NOT snap — it LERPS each tile's rectangle from its
//  old to its new position over `lerpSeconds` (~300 ms), matched by node id, so
//  the map settles calmly instead of jittering per event (the known failure mode
//  of naive streaming, PLAN §"Progressive data"). Tiles present only in the new
//  layout appear at their final rect; tiles that vanished simply drop.
//
//  Timing uses CACurrentMediaTime() and a 60 Hz Timer — this is the LIVE app
//  path, not the deterministic gate (scripts/verify.sh renders static frames
//  through the same QuadRenderer). Layout is in DEVICE PIXELS (drawableSize).
//

import AppKit
import Metal
import QuartzCore
// App layer is monolith-only (build.sh / verify.sh): SizeTree / Rect /
// TreemapScene / TileRect resolve same-module, so no core imports here.

final class CanvasView: NSView {
    // Named animation constants (ratified decision 3: batched relayout, animated).
    private static let lerpSeconds: CFTimeInterval = 0.30
    private static let animFPS: Double = 60.0

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice?
    private var renderer: QuadRenderer?

    /// The most recent tree snapshot; re-laid-out on resize.
    private var tree: SizeTree?

    /// What is currently on screen (fully interpolated). The source of every
    /// frame's draw — the renderer never sees the tree.
    private var displayedTiles: [TileRect] = []

    // Transition state: interpolate displayed → target over lerpSeconds.
    private var fromTiles: [String: TileRect] = [:]
    private var targetTiles: [TileRect] = []
    private var transitionStart: CFTimeInterval = 0
    private var animTimer: Timer?

    override init(frame frameRect: NSRect) {
        self.device = MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("CanvasView is code-only (no storyboard)") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        return l
    }

    // MARK: - Live updates

    /// Install a fresh tree snapshot (called ~1 s from the scan cadence). Begins a
    /// ~300 ms rect interpolation from the current display to the new layout.
    func updateTree(_ tree: SizeTree) {
        self.tree = tree
        makeRendererIfNeeded()
        guard let newTiles = layoutTiles() else { return }
        beginTransition(to: newTiles)
    }

    private func beginTransition(to newTiles: [TileRect]) {
        fromTiles = Dictionary(displayedTiles.map { ($0.nodeId, $0) },
                               uniquingKeysWith: { a, _ in a })
        targetTiles = newTiles
        transitionStart = CACurrentMediaTime()
        startAnimTimerIfNeeded()
        // Render the first interpolated frame immediately (t≈0).
        tickAnimation()
    }

    private func startAnimTimerIfNeeded() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / Self.animFPS, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
        // .common so the timer keeps firing during live window resize tracking.
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func stopAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func tickAnimation() {
        let elapsed = CACurrentMediaTime() - transitionStart
        let t = min(1.0, elapsed / Self.lerpSeconds)

        displayedTiles = targetTiles.map { target in
            guard let from = fromTiles[target.nodeId], t < 1.0 else { return target }
            return TileRect(
                rect: lerp(from.rect, target.rect, t),
                dimLevel: target.dimLevel,
                nodeId: target.nodeId,
                kind: target.kind,
                scanState: target.scanState
            )
        }
        render()

        if t >= 1.0 {
            displayedTiles = targetTiles
            stopAnimTimer() // idle until the next snapshot — no needless frames
        }
    }

    private func lerp(_ a: Rect, _ b: Rect, _ t: Double) -> Rect {
        Rect(x: a.x + (b.x - a.x) * t,
             y: a.y + (b.y - a.y) * t,
             width: a.width + (b.width - a.width) * t,
             height: a.height + (b.height - a.height) * t)
    }

    // MARK: - Renderer

    private func makeRendererIfNeeded() {
        guard renderer == nil, let device else { return }
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
        relayoutForResize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        relayoutForResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        relayoutForResize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        let px = bounds.width * scale
        let py = bounds.height * scale
        guard px > 0, py > 0 else { return }
        metalLayer.drawableSize = CGSize(width: px, height: py)
        metalLayer.contentsScale = scale
    }

    /// On resize we SNAP to the new layout (no lerp — a resize is a viewport
    /// change, not a data change) and redraw.
    private func relayoutForResize() {
        makeRendererIfNeeded()
        guard let newTiles = layoutTiles() else { return }
        displayedTiles = newTiles
        targetTiles = newTiles
        render()
    }

    private func layoutTiles() -> [TileRect]? {
        guard let tree else { return nil }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return nil }
        let viewport = Rect(x: 0, y: 0, width: Double(ds.width), height: Double(ds.height))
        return TreemapScene.layout(tree: tree, viewport: viewport)
    }

    private func render() {
        makeRendererIfNeeded()
        guard let renderer else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        renderer.render(tiles: displayedTiles, to: metalLayer)
    }
}
