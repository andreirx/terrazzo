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
//  TEXT OVERLAYS: `setTileLabels` (top-level folder name+size) and `setCallout` (the
//  hover chip anchored ON the hovered tile — TZ-4 D9, replacing the old fixed top-left
//  readout that overlapped the Desktop tile's label) — composited above the Metal layer;
//  the strings are composed off-view (pipeline / controller).
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
    /// The hover CALLOUT chip (TZ-4 D9), anchored near the cursor ON the hovered tile —
    /// replaces the old fixed top-left readout (which overlapped the Desktop tile's
    /// label, operator field report). A rounded translucent-dark chip with bright text
    /// and a 1px border in the hovered tile's hue, so it reads as distinct from the
    /// static top-level labels.
    private let calloutChip = CalloutChip()
    private var tileLabelViews: [NSTextField] = []
    private var currentTileLabels: [TileLabel] = []

    /// The on-hover IGNORE button (TZ-5 deliverable 1) — a small pill anchored at the TOP-RIGHT
    /// corner of the hovered top-level tile (labels sit top-LEFT, so no overlap). Shown by
    /// `showIgnore(atPx:)` only for a tile wide enough to carry it (the SAME `minLabelWidthPx`
    /// rule as labels — the packet's "sufficiently large tiles"); the context menu covers the
    /// small ones. As a canvas SUBVIEW inside `bounds`, it consumes its own click (no dive) and
    /// does NOT trigger `mouseExited` on the canvas, so hover stays live while the cursor is on it.
    private let ignoreButton: NSButton = {
        let b = NSButton(title: "Ignore", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .mini
        b.isHidden = true
        b.toolTip = "Exclude this tile from the map so its siblings fill the space. It stays in the Ignore list (click there to restore). Nothing is deleted."
        return b
    }()
    /// Bound by NavigationController — ignores the currently-hovered top-level tile.
    var onIgnore: (() -> Void)?
    /// The denied-overflow disclosure POPOVER (TZ-4b OPERATOR_NOTE #3.2, review-4 change 3 —
    /// the ratified "click shows the list (popover)", replacing the earlier NSMenu). One
    /// reused instance: `.transient` so a click elsewhere dismisses it; its content view
    /// controller is rebuilt per disclosure. Held strongly so it is not deallocated while shown.
    private lazy var deniedPopover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        return p
    }()

    /// The viewport (device px) the currently-installed quads were LAID OUT for. Set on
    /// every scene present; read by `applyStretchCamera` during a live resize to scale
    /// the current scene to the new drawable via the camera uniform — O(1), no relayout
    /// (TZ-4 D8 stretch-then-settle). `nil` until the first scene lands.
    private var sceneViewport: Rect?
    /// Throttle for viewport posts during a live-resize drag (D8): stretch every frame
    /// (cheap), but only ask the pipeline to re-squarify on a modest cadence so a huge
    /// tree's relayout does not thrash the actor at 60 Hz.
    private var lastResizePush: CFTimeInterval = 0
    private static let resizePushInterval: CFTimeInterval = 0.12

    override init(frame frameRect: NSRect) {
        self.device = MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        addSubview(calloutChip)
        calloutChip.isHidden = true
        ignoreButton.target = self
        ignoreButton.action = #selector(ignoreClicked)
        addSubview(ignoreButton)
    }

    @objc private func ignoreClicked() { onIgnore?() }

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

    /// Record the viewport the freshly-installed quads were laid out for (TZ-4 D8). The
    /// caller (NavigationController) sets this on every present so a live resize can
    /// stretch the current scene to the new drawable size without a relayout.
    func setSceneViewport(_ vp: Rect) { sceneViewport = vp }

    /// STRETCH the current scene to the current drawable via the camera uniform (D8).
    /// The installed quads live in `sceneViewport`-px world space; scaling by
    /// drawable/sceneViewport makes them fill the resized drawable — an O(1) main-thread
    /// uniform update, no re-squarify. Briefly aspect-stretched during the drag is the
    /// intended trade; the re-squarified scene swaps in on settle and resets the camera.
    func applyStretchCamera() {
        guard let sv = sceneViewport, sv.width > 0, sv.height > 0 else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        camScale = SIMD2(Float(Double(ds.width) / sv.width), Float(Double(ds.height) / sv.height))
        camTranslate = SIMD2(0, 0)
        render()
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

    /// Show the hover CALLOUT chip near the cursor (TZ-4 D9). `text` is the chip label
    /// (name + size); `hue` in [0,1) paints the 1px border in the hovered tile's hue;
    /// `p` is the cursor in DEVICE PIXELS. The chip is clamped to the viewport and may
    /// overflow a small tile — anchoring to the cursor, never clipped unreadable.
    func setCallout(text: String, hue: Double, atPx p: Point) {
        guard !text.isEmpty else { clearCallout(); return }
        calloutChip.set(text: text, hue: hue)
        calloutChip.isHidden = false
        positionCallout(atPx: p)
    }

    /// Hide the hover callout chip.
    func clearCallout() { calloutChip.isHidden = true }

    /// Show the on-hover IGNORE button anchored at the top-right of `tileRect` (DEVICE PIXELS),
    /// but ONLY when the tile is at least `minLabelWidthPx` wide — the SAME "sufficiently large"
    /// rule labels use (small tiles are ignored via the context menu instead). Returns whether
    /// the button is shown, so NavigationController can wire its `onIgnore` only when it is.
    @discardableResult
    func showIgnore(atPx tileRect: Rect) -> Bool {
        guard tileRect.width >= Self.minLabelWidthPx else { ignoreButton.isHidden = true; return false }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ignoreButton.sizeToFit()
        let size = ignoreButton.frame.size
        let bw = Double(size.width), bh = Double(size.height)
        let pad = 4.0
        // Tile top-right in top-left-origin POINTS; clamp inside the tile so the pill never
        // spills past the tile edge (labels own the top-LEFT, so the top-RIGHT is free).
        let rightPt = (tileRect.x + tileRect.width) / scale
        let topPt = tileRect.y / scale
        let xPt = max(tileRect.x / scale + pad, rightPt - bw - pad)
        let yTopPt = topPt + pad
        // NSView is y-up — convert the top-left y to a frame origin.
        let frameY = Double(bounds.height) - yTopPt - bh
        ignoreButton.frame = NSRect(x: xPt, y: frameY, width: bw, height: bh)
        ignoreButton.isHidden = false
        return true
    }

    /// Hide the on-hover ignore button (hover-out, dive, animation).
    func hideIgnore() { ignoreButton.isHidden = true }

    /// Disclose the collapsed denied list of a clicked denied-overflow AGGREGATE badge (TZ-4b
    /// OPERATOR_NOTE #3.2, review-4 change 3). The ratified affordance is a POPOVER anchored at the
    /// cursor listing the denied item names + the aggregate's implied (lower-bound) size — so every
    /// denied fact the badge stands for is reachable, not merely counted. `impliedText` is the
    /// caller-formatted "≥ N (contents unreadable)" qualifier. `p` is the cursor in DEVICE PIXELS
    /// (top-left origin), converted here to the view's y-up point space. Bounded (long lists
    /// truncate with a "… N more" tail — never a wall of items).
    func showDeniedList(title: String, items: [String], impliedText: String, atPx p: Point) {
        let vc = Self.makeDeniedListVC(title: title, impliedText: impliedText, items: items)
        deniedPopover.contentViewController = vc
        deniedPopover.contentSize = vc.preferredContentSize
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        // Device px (top-left, y-down) → view points (bottom-left, y-up) — inverse of layoutPoint.
        let viewPt = NSPoint(x: p.x / scale, y: Double(bounds.height) - p.y / scale)
        // A 1×1 anchor rect at the cursor; the popover chooses a non-clipping edge itself.
        let anchor = NSRect(x: viewPt.x, y: viewPt.y, width: 1, height: 1)
        deniedPopover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    /// Build the disclosure popover's content: a bold title, the implied-size qualifier, and the
    /// denied item names (bounded to 40 with a "… N more" tail). A plain vertical stack in a view
    /// controller — presentation only; the CONTENT (names + implied size) is resolved by the pure,
    /// unit-tested `TreemapScene.deniedInventory`, so this method carries no untested logic.
    /// Internal (not private) so the headless chrome audit (scripts/chrome_host.swift, review-0
    /// change 5) can build and inspect the popover content OFFSCREEN without showing the popover.
    static func makeDeniedListVC(title: String, impliedText: String,
                                 items: [String]) -> NSViewController {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        let impliedLabel = NSTextField(labelWithString: impliedText)
        impliedLabel.font = .systemFont(ofSize: 11)
        impliedLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(impliedLabel)

        let shown = items.prefix(40)
        for name in shown {
            let row = NSTextField(labelWithString: name)
            row.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            stack.addArrangedSubview(row)
        }
        if items.count > shown.count {
            let more = NSTextField(labelWithString: "… and \(items.count - shown.count) more")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(more)
        }

        // Give the stack a concrete size from its content: an offscreen NSPopover has no
        // window to resolve Auto Layout against, so `contentSize` must be set explicitly or it
        // renders zero-sized. `fittingSize` computes from the arranged subviews' intrinsic sizes
        // without a window; we clamp the width so a long path does not make a runaway-wide popover.
        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        size.width = min(max(size.width, 180), 520)
        stack.frame = NSRect(origin: .zero, size: size)

        let vc = NSViewController()
        vc.view = stack
        vc.preferredContentSize = size
        return vc
    }

    /// Anchor the callout chip near the cursor, clamped strictly inside the view. Placed
    /// down-right of the cursor by default, flipping to the opposite side when it would
    /// spill past an edge, so it is never clipped.
    private func positionCallout(atPx p: Point) {
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        let size = calloutChip.fittingSize
        let w = Double(size.width), h = Double(size.height)
        let bw = Double(bounds.width), bh = Double(bounds.height)
        // Cursor in top-left-origin POINTS (the chip layout space before the y-flip).
        let cx = p.x / scale
        let cyTop = p.y / scale
        let gap = 14.0, margin = 4.0
        var xTop = cx + gap
        if xTop + w > bw - margin { xTop = cx - gap - w }        // flip left near the right edge
        xTop = min(max(margin, xTop), max(margin, bw - w - margin))
        var yTop = cyTop + gap
        if yTop + h > bh - margin { yTop = cyTop - gap - h }      // flip above near the bottom edge
        yTop = min(max(margin, yTop), max(margin, bh - h - margin))
        // NSView is y-up (isFlipped == false) — convert the top-left y to a frame origin.
        let frameY = bh - yTop - h
        calloutChip.frame = NSRect(x: xTop, y: frameY, width: w, height: h)
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

    /// Hide the top-level tile labels for the duration of a live-resize drag (D8) — a
    /// re-square is coming on settle, and stretched labels mid-drag read as clutter.
    private func hideTileLabelsDuringResize() {
        for v in tileLabelViews { v.isHidden = true }
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
        if inLiveResize {
            // D8 STRETCH-THEN-SETTLE: track the drag frame-by-frame via the camera
            // uniform (O(1) on main, no relayout); hide overlays during the drag; and
            // post the new viewport only on a modest cadence so the pipeline's
            // re-squarify (newest-wins) never thrashes on a large tree at 60 Hz.
            clearCallout()
            hideTileLabelsDuringResize()
            applyStretchCamera()
            let now = CACurrentMediaTime()
            if now - lastResizePush >= Self.resizePushInterval {
                lastResizePush = now
                input?.canvasViewportChanged()
            }
        } else {
            layoutTileLabels()
            input?.canvasViewportChanged()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Settle: request the re-squarified scene for the FINAL size. When it lands,
        // `present` resets the camera to identity and re-places the labels.
        lastResizePush = 0
        updateDrawableSize()
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

// MARK: - Callout chip (TZ-4 D9)

/// The hover callout chip: a rounded, translucent-dark pill with bright text and a 1px
/// border in the hovered tile's hue — VISIBLY distinct from the static top-level labels
/// (which are flat dark rounded rects with no coloured border). A container view (not a
/// bare NSTextField) so it can carry internal padding around the text and a hue border
/// the plain overlay labels don't have.
///
/// ABSTRACTION LEDGER: one concrete view, one user (CanvasView's hover callout). Axis:
/// the callout's styling (padding + per-hover hue border + middle-truncation to a max
/// width) is not expressible on the reused flat overlay label, and the packet requires
/// it read as distinct. Rejected simpler alternative — reuse `makeOverlayLabel` — cannot
/// pad the text or draw the hue border, and would read the same as the static labels the
/// operator asked to disambiguate from.
private final class CalloutChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private static let hPad: CGFloat = 7, vPad: CGFloat = 4
    /// Long paths middle-truncate in the CHIP (never in the bottom bar) — cap the text
    /// width so the chip stays a readable pill rather than spanning the viewport.
    private static let maxTextWidth: CGFloat = 320

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 0.72)
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPad),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.vPad),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.vPad),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTextWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("CalloutChip is code-only") }

    /// `hue` in [0,1); a medium-sat bright border keeps the chip tied to the tile's hue
    /// while staying legible against the translucent-dark fill.
    func set(text: String, hue: Double) {
        label.stringValue = text
        layer?.borderColor = NSColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1)),
                                     saturation: 0.75, brightness: 1.0, alpha: 0.95).cgColor
    }
}
