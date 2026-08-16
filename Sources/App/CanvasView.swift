//
//  CanvasView.swift — the Metal canvas: renders prebuilt tile buffers, animates via
//  uniforms, forwards input, and hosts the two on-canvas text overlays.
//  Module maturity: PROTOTYPE (slice TZ-3; TZ-3b: uniform-driven animation)
//
//  A layer-backed NSView whose backing layer is a CAMetalLayer (glyph-saver
//  heritage: a bare CAMetalLayer, not an MTKView — we drive rendering ourselves).
//
//  TZ-3b — NOTHING PER-TILE ON THE FRAME PATH (main-thread law, PLAN §"Threading
//  model"). The scene arrives with its GPU instances ALREADY built (RenderScene.quads
//  from the background pipeline). This view uploads that prebuilt array into an
//  MTLBuffer ONCE per scene (a memcpy, blessed to stay on main) and then animates by
//  varying only UNIFORMS:
//   1. STREAMING settle: between two scenes at the same focus it lerps geometry
//      from→to IN THE VERTEX SHADER (two prebuilt buffers + a scalar `t`). The 60 Hz
//      tick updates `t` and redraws — O(1) on main, no per-tile CPU map.
//   2. CAMERA frames: a dive/ascend holds one prebuilt base buffer and animates the
//      camera AFFINE uniform (`setCamera`) — again O(1)/frame.
//   3. HOVER highlight: a single instance-index uniform (`setHighlightIndex`).
//  The per-tile colour/geometry conversion that used to run here every draw is gone —
//  it happens once, off main, in RenderPipeline.QuadBuilder.
//
//  INPUT (unchanged): it is the NSView that receives mouse/scroll/keys, converts each
//  to DEVICE-PIXEL layout space (top-left origin, y-down — the space tiles live in),
//  and forwards to its `input` delegate. Esc routes to `escapeHandler`.
//
//  TEXT OVERLAYS (unchanged): `setTileLabels` (top-level folder name+size) and
//  `setReadout` (the floating `HoverReadout` label) — plain NSTextFields composited
//  above the Metal layer; the strings are composed off-view (pipeline / controller).
//

import AppKit
import Metal
import QuartzCore
import simd
// App layer is monolith-only (build.sh / verify.sh): GPUQuad / Rect / TileRect /
// Point / QuadRenderer resolve same-module, so no core imports here.

/// What the canvas reports upward. Points are DEVICE PIXELS (top-left origin,
/// y-down — the tile layout space); the delegate decides what they mean. Weak
/// back-reference from the view, so no retain cycle with the delegate.
@MainActor
protocol CanvasInputDelegate: AnyObject {
    func canvasViewportChanged()
    func canvasDidHover(atPx p: Point)
    func canvasDidExit()
    func canvasDidClick(atPx p: Point)
    /// `precise` is `event.hasPreciseScrollingDeltas`: false for a mouse wheel
    /// (notch-based), true for a trackpad (continuous). NavigationController thresholds
    /// the two differently so one notch and one short swipe each = one zoom step.
    func canvasDidScroll(deltaY: Double, precise: Bool, atPx p: Point)
    func canvasContextMenu(atPx p: Point) -> NSMenu?
}

final class CanvasView: NSView {
    /// A top-level tile's floating label: its rect (DEVICE PIXELS) + the text.
    struct TileLabel {
        let rect: Rect
        let text: String
        init(rect: Rect, text: String) { self.rect = rect; self.text = text }
    }

    // Named animation constants (ratified decision 3: batched relayout, animated).
    private static let lerpSeconds: CFTimeInterval = 0.30
    private static let animFPS: Double = 60.0
    /// Tiles narrower than this (device px) get no label — a label wider than its
    /// tile reads as clutter, not information (no silent overflow).
    private static let minLabelWidthPx: Double = 84

    weak var input: CanvasInputDelegate?
    /// Esc handler (zoom out). A closure, not a delegate method, so the input
    /// protocol stays exactly the mouse/scroll surface and Esc wiring lives in the
    /// Main assembly (AppDelegate binds it to NavigationController.ascend).
    var escapeHandler: (() -> Void)?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice?
    private var renderer: QuadRenderer?

    // --- Prebuilt render state (the frame path reads ONLY these) ---
    // The two instance buffers the vertex shader lerps between (from → to). Both are
    // uploaded PRE-ALIGNED by the caller (the pipeline's `settleFrom`+`quads` for a
    // streaming settle; a camera-end `from`+committed `to` for a dive/ascend commit),
    // so this view does NO per-tile identity matching — the O(n) String-keyed capture
    // that used to live here (`currentDisplayedById`, the 158 ms hitch) is gone. The
    // view keeps only the GPU buffers; there is no CPU mirror to walk per scene.
    private var fromBuf: MTLBuffer?
    private var toBuf: MTLBuffer?
    private var quadCount = 0

    /// Settle-morph state: while active, `t` sweeps 0→1 over `lerpSeconds`.
    private var settleActive = false
    private var transitionStart: CFTimeInterval = 0
    /// Camera affine (world px → screen px). Identity except during a dive/ascend.
    private var camScale = SIMD2<Float>(1, 1)
    private var camTranslate = SIMD2<Float>(0, 0)
    /// Hover-highlight instance index, or -1 (a uniform, not per-instance data).
    private var highlightIndex: Int32 = -1

    private var animTimer: Timer?
    private var trackingArea: NSTrackingArea?

    // Text overlays (composited above the Metal layer).
    private let readoutLabel = CanvasView.makeOverlayLabel(alignment: .left, lines: 2)
    private var tileLabelViews: [NSTextField] = []
    private var currentTileLabels: [TileLabel] = []

    override init(frame frameRect: NSRect) {
        self.device = MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        addSubview(readoutLabel)
        readoutLabel.isHidden = true
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

    override var isFlipped: Bool { false } // AppKit default (bottom-left origin) for subviews

    // MARK: - Public geometry (NavigationController lays out against this)

    /// The layout viewport in DEVICE PIXELS — the space tiles are laid out in.
    var viewportPx: Rect {
        let ds = metalLayer.drawableSize
        return Rect(x: 0, y: 0, width: Double(ds.width), height: Double(ds.height))
    }

    // MARK: - Scene intake (prebuilt quads)

    /// Install a fresh scene's prebuilt instances. `from` and `to` are PRE-ALIGNED by
    /// the caller (index-parallel, same node per index): the pipeline's `settleFrom` +
    /// `quads` for a streaming settle, or a camera-end `from` + committed `to` for a
    /// dive/ascend commit. `animated == true` → morph `from`→`to` in the vertex shader;
    /// `animated == false` → snap to `to` (`from` ignored). No identity matching here.
    func present(from: [GPUQuad], to: [GPUQuad], animated: Bool) {
        makeRendererIfNeeded()
        if animated {
            beginSettle(from: from, to: to)
        } else {
            snap(to: to)
        }
    }

    /// Begin a CAMERA flight over a fixed prebuilt base (dive/ascend). No settle; the
    /// caller animates the camera affine via `setCamera`, and drives the commit morph
    /// itself once the flight ends.
    ///
    /// DELIBERATELY DOES NOT RENDER (review-2 gap 2, ascend continuity): it only uploads
    /// the base buffer and leaves the previous pixels on screen. If it painted here it
    /// would paint at the CURRENT camera (identity), which for ascend is the parent world
    /// — a one-frame flash BEFORE the matching t=0 child frame. The caller renders the
    /// explicit t=0 frame immediately after (`setCamera` in `applyCameraFrame`), so the
    /// FIRST painted frame of every flight is exactly t=0.
    func beginCameraFlight(base: [GPUQuad]) {
        stopAnimTimer()
        settleActive = false
        makeRendererIfNeeded()
        quadCount = base.count
        let buf = renderer?.makeQuadBuffer(base)
        fromBuf = buf; toBuf = buf
    }

    /// Update the camera affine (world px → screen px) and redraw. O(1)/frame — the
    /// prebuilt base buffer is reused; only the uniform changes.
    func setCamera(scaleX: Double, scaleY: Double, translateX: Double, translateY: Double) {
        camScale = SIMD2(Float(scaleX), Float(scaleY))
        camTranslate = SIMD2(Float(translateX), Float(translateY))
        render()
    }

    /// Reset the camera to identity (world px == screen px). Used when a settle takes
    /// over from a camera flight.
    func resetCamera() {
        camScale = SIMD2(1, 1); camTranslate = SIMD2(0, 0)
    }

    /// Set the hover-highlight instance index (or -1). A uniform update + redraw;
    /// never relays out, never restarts the settle.
    func setHighlightIndex(_ index: Int) {
        let v = Int32(index)
        guard v != highlightIndex else { return }
        highlightIndex = v
        render()
    }

    private func snap(to quads: [GPUQuad]) {
        stopAnimTimer()
        settleActive = false
        resetCamera()
        quadCount = quads.count
        let buf = renderer?.makeQuadBuffer(quads)
        fromBuf = buf; toBuf = buf
        render()
    }

    private func beginSettle(from: [GPUQuad], to: [GPUQuad]) {
        // `from` and `to` are pre-aligned by the caller and expressed in identity-camera
        // screen space (a commit's `from` already has the camera's last frame baked in),
        // so the settle runs at identity camera and the shader lerps index-for-index.
        resetCamera()
        quadCount = to.count
        fromBuf = renderer?.makeQuadBuffer(from)
        toBuf = renderer?.makeQuadBuffer(to)
        settleActive = true
        transitionStart = CACurrentMediaTime()
        startAnimTimerIfNeeded()
        render()
    }

    // MARK: - Text overlays

    /// The floating hover readout (top-left). `nil`/empty hides it.
    func setReadout(_ text: String?) {
        if let text, !text.isEmpty {
            readoutLabel.stringValue = text
            readoutLabel.isHidden = false
            layoutReadout()
        } else {
            readoutLabel.isHidden = true
        }
    }

    /// Position/label the top-level tiles. Rebuilds the NSTextField overlay set
    /// (counts are small — top-level tiles only). Labels on tiles too narrow to
    /// carry them are dropped, never overflowed.
    func setTileLabels(_ labels: [TileLabel]) {
        currentTileLabels = labels
        // Grow/shrink the pool to match.
        while tileLabelViews.count < labels.count {
            let v = CanvasView.makeOverlayLabel(alignment: .left, lines: 1)
            addSubview(v)
            tileLabelViews.append(v)
        }
        while tileLabelViews.count > labels.count {
            tileLabelViews.removeLast().removeFromSuperview()
        }
        layoutTileLabels()
    }

    private func layoutTileLabels() {
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        let pad = 4.0
        for (i, label) in currentTileLabels.enumerated() {
            let v = tileLabelViews[i]
            let wPt = label.rect.width / scale
            let hPt = label.rect.height / scale
            guard label.rect.width >= Self.minLabelWidthPx else { v.isHidden = true; continue }
            v.stringValue = label.text
            v.sizeToFit()
            let h = v.frame.height
            // BOTH axes must fit the tile (review-2 item 2): a tile can clear the
            // minimum WIDTH yet be shorter than the fitted text height, which would
            // push the NSTextField frame down into the tile below. The label sits at
            // the tile top with `pad`, so it stays inside the tile iff pad + h ≤ hPt.
            // If it cannot fit vertically, drop it rather than overflow a neighbor.
            guard Double(h) + pad <= hPt else { v.isHidden = true; continue }
            v.isHidden = false
            let xPt = label.rect.x / scale + pad
            let yTopPt = label.rect.y / scale + pad
            let w = min(v.frame.width, wPt - 2 * pad)
            // NSView y-up: convert a top-left-origin y into the flipped frame.
            let originY = Double(bounds.height) - yTopPt - Double(h)
            v.frame = NSRect(x: xPt, y: originY, width: w, height: Double(h))
        }
    }

    private func layoutReadout() {
        readoutLabel.sizeToFit()
        let h = readoutLabel.frame.height
        let w = min(readoutLabel.frame.width, Double(bounds.width) - 20)
        readoutLabel.frame = NSRect(x: 10, y: Double(bounds.height) - Double(h) - 8,
                                    width: w, height: Double(h))
    }

    // MARK: - Streaming animation (uniform-driven; O(1) per frame)

    private func startAnimTimerIfNeeded() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / Self.animFPS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAnimation() } // fires on the main RunLoop
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func stopAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    /// One settle frame: recompute `t` (a scalar) and redraw the SAME two buffers.
    /// No per-tile CPU work — the vertex shader lerps.
    private func tickAnimation() {
        render()
        if CACurrentMediaTime() - transitionStart >= Self.lerpSeconds {
            settleActive = false
            stopAnimTimer()
            render() // crisp final frame at the target (t = 1)
        }
    }

    // MARK: - Renderer

    private func makeRendererIfNeeded() {
        guard renderer == nil, let device else { return }
        let source: String
        if let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            source = s
        } else if let path = ProcessInfo.processInfo.environment["TERRAZZO_SHADER_PATH"],
                  let s = try? String(contentsOfFile: path, encoding: .utf8) {
            // Headless threading harness (no .app bundle): read the shader from a path
            // named in the environment. A value-read env seam (sibling of
            // TERRAZZO_SCAN_ROOT), not I/O across the ScanFS boundary.
            source = s
        } else {
            NSLog("CanvasView: Shaders.metal missing (bundle Resources and TERRAZZO_SHADER_PATH)")
            return
        }
        renderer = QuadRenderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source)
    }

    // MARK: - Sizing & render

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        input?.canvasViewportChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        layoutReadout()
        layoutTileLabels()
        input?.canvasViewportChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        input?.canvasViewportChanged()
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
        guard let renderer, let fromBuf, let toBuf else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        let t: Float = settleActive
            ? Float(min(1.0, (CACurrentMediaTime() - transitionStart) / Self.lerpSeconds))
            : 1.0
        let u = QuadRenderer.Uniforms(
            viewport: SIMD2(Float(ds.width), Float(ds.height)),
            camScale: camScale, camTranslate: camTranslate,
            t: t, highlightIndex: highlightIndex)
        renderer.render(from: fromBuf, to: toBuf, count: quadCount, uniforms: u, to: metalLayer)
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// Window location → DEVICE-PIXEL layout space (top-left origin, y-down),
    /// clamped strictly inside the drawable so half-open `Rect.contains` resolves
    /// the far edges (see Rect.contains docs).
    private func layoutPoint(_ event: NSEvent) -> Point {
        let viewPt = convert(event.locationInWindow, from: nil) // points, bottom-left origin
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        let ds = metalLayer.drawableSize
        let px = Double(viewPt.x) * scale
        let py = (Double(bounds.height) - Double(viewPt.y)) * scale
        let cx = min(max(0, px), max(0, Double(ds.width) - 0.001))
        let cy = min(max(0, py), max(0, Double(ds.height) - 0.001))
        return Point(x: cx, y: cy)
    }

    override func mouseMoved(with event: NSEvent) { input?.canvasDidHover(atPx: layoutPoint(event)) }
    override func mouseExited(with event: NSEvent) { input?.canvasDidExit() }
    override func mouseDown(with event: NSEvent) { input?.canvasDidClick(atPx: layoutPoint(event)) }

    override func scrollWheel(with event: NSEvent) {
        input?.canvasDidScroll(deltaY: Double(event.scrollingDeltaY),
                               precise: event.hasPreciseScrollingDeltas,
                               atPx: layoutPoint(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        input?.canvasContextMenu(atPx: layoutPoint(event))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc → zoom out
            escapeHandler?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Overlay label factory

    private static func makeOverlayLabel(alignment: NSTextAlignment, lines: Int) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: 11, weight: .medium)
        f.textColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        f.alignment = alignment
        f.maximumNumberOfLines = lines
        f.lineBreakMode = lines > 1 ? .byTruncatingMiddle : .byTruncatingTail
        f.drawsBackground = true
        f.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.45) // legible over any tile hue
        f.wantsLayer = true
        f.layer?.cornerRadius = 3
        f.isBezeled = false
        f.isEditable = false
        f.isSelectable = false
        return f
    }
}
