//
//  CanvasView.swift — the Metal canvas: renders tiles, animates, forwards input,
//  and hosts the two on-canvas text overlays (tile labels + hover readout).
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  A layer-backed NSView whose backing layer is a CAMetalLayer (glyph-saver
//  heritage: a bare CAMetalLayer, not an MTKView — we drive rendering ourselves).
//
//  RESPONSIBILITIES (TZ-3 narrowed them — layout moved to NavigationController):
//   1. STREAMING settle (TZ-2, preserved): `present(animated:true)` LERPs each
//      tile's rect old→new by node id over `lerpSeconds` — the calm scan settle.
//   2. CAMERA frames (TZ-3): `renderCameraFrame` draws an already-transformed tile
//      list immediately (no lerp) — NavigationController pushes ~350 ms of these.
//   3. INPUT: it is the NSView that receives mouse/scroll/keys, converts each to
//      DEVICE-PIXEL layout space (top-left origin, y-down — the space tiles live
//      in), and forwards to its `input` delegate. Esc routes to `escapeHandler`.
//   4. TEXT OVERLAYS: `setTileLabels` (top-level folder name+size, deliverable 5c)
//      and `setReadout` (the floating `HoverReadout` label, top-left, deliverable
//      3) — plain NSTextFields composited above the Metal layer; the strings are
//      composed by NavigationController (it owns the tree + formatter).
//

import AppKit
import Metal
import QuartzCore
// App layer is monolith-only (build.sh / verify.sh): SizeTree / Rect /
// TreemapScene / TileRect / Point resolve same-module, so no core imports here.

/// What the canvas reports upward. Points are DEVICE PIXELS (top-left origin,
/// y-down — the tile layout space); the delegate decides what they mean. Weak
/// back-reference from the view, so no retain cycle with the delegate.
@MainActor
protocol CanvasInputDelegate: AnyObject {
    func canvasViewportChanged()
    func canvasDidHover(atPx p: Point)
    func canvasDidExit()
    func canvasDidClick(atPx p: Point)
    func canvasDidScroll(deltaY: Double, atPx p: Point)
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

    /// What is currently on screen (fully interpolated), in device-pixel space.
    private var displayedTiles: [TileRect] = []
    private var highlightedId: String?

    // Streaming transition state: interpolate displayed → target over lerpSeconds.
    private var fromTiles: [String: TileRect] = [:]
    private var targetTiles: [TileRect] = []
    private var transitionStart: CFTimeInterval = 0
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

    // MARK: - Tile intake

    /// Install a fresh world tile list. `animated == true` → streaming settle lerp;
    /// `animated == false` → snap (resize / a committed focus swap).
    func present(tiles: [TileRect], highlightedId: String?, animated: Bool) {
        self.highlightedId = highlightedId
        makeRendererIfNeeded()
        if animated {
            beginTransition(to: tiles)
        } else {
            stopAnimTimer()
            displayedTiles = tiles
            targetTiles = tiles
            render()
        }
    }

    /// Update the hover highlight WITHOUT relaying out — hover must not restart the
    /// settle lerp or move any tile.
    func setHighlight(_ id: String?) {
        guard id != highlightedId else { return }
        highlightedId = id
        render()
    }

    /// Draw an ALREADY-TRANSFORMED tile list immediately (a camera frame). Never
    /// highlights — the zoom is a transient. It DOES record the drawn geometry as
    /// `displayedTiles` so that the committing `present(animated:true)` at the end
    /// of the flight lerps FROM the camera's exact last frame into the freshly
    /// squarified focus layout (TZ-3 rev-1): the camera lands the focus tile
    /// exactly and the bounded inner-tile residual (scaled border + squarify
    /// re-tiling to the new aspect) is closed by the existing settle-lerp instead of
    /// a hard snap — a perceptually continuous handoff, no new animation machinery.
    func renderCameraFrame(tiles: [TileRect]) {
        stopAnimTimer()
        makeRendererIfNeeded()
        guard let renderer else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        displayedTiles = tiles
        renderer.render(tiles: tiles, highlightedId: nil, to: metalLayer)
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

    // MARK: - Streaming animation (TZ-2, preserved)

    private func beginTransition(to newTiles: [TileRect]) {
        fromTiles = Dictionary(displayedTiles.map { ($0.nodeId, $0) },
                               uniquingKeysWith: { a, _ in a })
        targetTiles = newTiles
        transitionStart = CACurrentMediaTime()
        startAnimTimerIfNeeded()
        tickAnimation()
    }

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
                scanState: target.scanState,
                hue: target.hue // hue is per-node constant — carry it, never lerp to 0
            )
        }
        render()

        if t >= 1.0 {
            displayedTiles = targetTiles
            stopAnimTimer()
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
        guard let renderer else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        renderer.render(tiles: displayedTiles, highlightedId: highlightedId, to: metalLayer)
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
        input?.canvasDidScroll(deltaY: Double(event.scrollingDeltaY), atPx: layoutPoint(event))
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
