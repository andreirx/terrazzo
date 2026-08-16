//
//  NavigationController.swift — the App's navigation state machine.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  The crossing point of TZ-3's interaction: it owns navigation STATE (the focus
//  stack, the latest streamed tree, the current hover) and orchestrates the three
//  pure cores against the AppKit surfaces. It is App-layer glue — the ONE place
//  hit-testing, the focus camera, and the tree/scene are wired to real mouse,
//  scroll, keyboard, and Finder. Nothing here is a core abstraction; the pure,
//  testable pieces live in TreemapCore (HitTest, FocusCamera, TileColor,
//  TreemapScene) and this class only sequences them.
//
//  RESPONSIBILITY SPLIT (why layout moved here from CanvasView in TZ-3):
//    - ScanController streams a fresh SizeTree via `onSnapshot` (it no longer
//      knows about the canvas — decision recorded in ScanController's header).
//    - NavigationController holds the tree + focus stack and LAYS IT OUT for the
//      current focus (TreemapScene.layout), then hands a flat [TileRect] to the
//      CanvasView, which only renders + animates + forwards input. The canvas is
//      now a dumb surface; navigation policy lives here. This is the seam the
//      new ScanController(onSnapshot:) already expects.
//
//  TWO ANIMATIONS, DELIBERATELY SEPARATE:
//    1. Batched SETTLE (TZ-2, owned by CanvasView): between scan snapshots at the
//       SAME focus, tiles lerp old→new position (calm streaming).
//    2. Focus CAMERA (TZ-3, owned HERE): on a dive/ascend, a fixed world is held
//       and a FocusCamera transform is animated over it (~350 ms), then the focus
//       is committed and the layout snaps to the camera's end state. During a
//       camera animation incoming snapshots update `latestTree` but do NOT
//       relayout (they would fight the camera); the commit relayouts from the
//       freshest tree.
//
//  DETAIL ON DEMAND (decision 4): diving deeper raises the projection depth
//  (focus depth + render window) on the ScanController, which re-projects the
//  already-scanned tree deeper — never a re-scan.
//
//  ABSTRACTION LEDGER: one concrete coordinator, one caller (AppDelegate). It is
//  the CanvasInputDelegate (its one implementer). No protocol beyond that input
//  seam, which exists because CanvasView (a view) must call UP to navigation
//  without importing it — a genuine boundary, not speculative.
//

import AppKit

@MainActor
final class NavigationController: CanvasInputDelegate {
    /// Render window below the focus (levels of child detail). Matches the scene's
    /// default depth so the projected tree always carries enough detail to fill
    /// the renderer's window at any focus.
    private static let renderWindow = TreemapScene.defaultDepthWindow
    /// Scroll magnitude past which a wheel gesture counts as a zoom step. A small
    /// deadzone so trackpad micro-scrolls do not fire navigation.
    private static let scrollZoomThreshold: Double = 4.0

    private let canvas: CanvasView
    private let bottomBar: StatusBar
    /// Set once, right after construction (ScanController needs our `onSnapshot`,
    /// and we need its `setProjectionDepth` — a construction cycle broken by this
    /// one late binding in the Main assembly). Weak-ish: owned by AppDelegate.
    weak var scanController: ScanController?

    private var latestTree: SizeTree?
    /// Focus path as node ids, root→current. Under the live scan a node id IS its
    /// absolute path, so `focusStack.last` is the current focus's absolute path —
    /// exactly the breadcrumb text (packet deliverable 5). Empty until the first
    /// snapshot names the root.
    private var focusStack: [String] = []
    /// The layout currently on screen at the current focus — the surface hit-tests
    /// query (what the user sees, by construction the same list the renderer drew).
    private var displayTiles: [TileRect] = []
    private var hoverChain: HitChain?

    // Camera animation state.
    private var cameraTimer: Timer?
    private var isAnimatingCamera = false
    /// Path targeted by the right-click context menu item (the deepest tile under
    /// the click). Stored so the menu item's action has a concrete subject.
    private var contextTargetPath: String?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f
    }()

    init(canvas: CanvasView, bottomBar: StatusBar) {
        self.canvas = canvas
        self.bottomBar = bottomBar
        canvas.input = self
    }

    /// Diagnostic trace of navigation actions to stdout, gated by `TERRAZZO_TRACE`
    /// (a Main-assembly test affordance, sibling to `TERRAZZO_SCAN_ROOT`). It makes
    /// the LIVE AppKit navigation path OBSERVABLE to a headless E2E harness that
    /// cannot see the rendered map: the harness drives real mouse/keyboard events
    /// and reads these lines back to confirm dive/ascend/reveal actually fired
    /// (review-1 asked for exactly this evidence). Reading a process-env flag is a
    /// value read — no ScanFS-boundary I/O. Unset in normal use → silent.
    private static let traceEnabled = ProcessInfo.processInfo.environment["TERRAZZO_TRACE"] != nil
    private func trace(_ s: String) {
        if Self.traceEnabled { print("TZTRACE \(s)"); fflush(stdout) }
    }

    // MARK: - Snapshot intake (from ScanController)

    func onSnapshot(_ tree: SizeTree) {
        latestTree = tree
        if focusStack.isEmpty {
            focusStack = [tree.id]
            bottomBar.setFocusPath(tree.id)
        }
        // Do not disturb an in-flight camera animation; it will relayout on commit.
        guard !isAnimatingCamera else { return }
        relayoutCurrent(animated: true)
    }

    // MARK: - Layout at the current focus

    private var viewport: Rect { canvas.viewportPx }

    private func relayoutCurrent(animated: Bool) {
        guard let tree = latestTree, let focusId = focusStack.last else { return }
        let vp = viewport
        guard vp.width > 0, vp.height > 0 else { return }
        let tiles = TreemapScene.layout(tree: tree, focusId: focusId,
                                        depthWindow: Self.renderWindow, viewport: vp)
        guard !tiles.isEmpty else { return } // focus not present yet — keep last frame
        displayTiles = tiles
        canvas.present(tiles: tiles, highlightedId: highlightId, animated: animated)
        bottomBar.setFocusPath(focusId)
        refreshTileLabels()
    }

    private var highlightId: String? { hoverChain?.topLevelUnderFocus?.nodeId }

    /// Top-level tile labels (packet 5c): name + human size for each dimLevel-1
    /// tile of the current focus. Rects are in device pixels; CanvasView converts
    /// to points and clips/hides below the minimum width. Rebuilt on every relayout
    /// and focus change; hidden entirely during a camera animation.
    private func refreshTileLabels() {
        guard let tree = latestTree else { canvas.setTileLabels([]); return }
        let labels: [CanvasView.TileLabel] = displayTiles
            .filter { $0.dimLevel == 1 }
            .map { tile in
                let node = tree.node(withId: tile.nodeId)
                let name = node?.name ?? tile.nodeId
                let size = Self.sizeFormatter.string(fromByteCount: node?.allocatedBytes ?? 0)
                return CanvasView.TileLabel(rect: tile.rect, text: "\(name)  ·  \(size)")
            }
        canvas.setTileLabels(labels)
    }

    // MARK: - CanvasInputDelegate

    func canvasViewportChanged() {
        // A resize is a viewport change, not a data change → snap (no settle lerp).
        guard !isAnimatingCamera else { return }
        relayoutCurrent(animated: false)
    }

    func canvasDidHover(atPx p: Point) {
        guard !isAnimatingCamera else { return }
        hoverChain = HitTest.hit(tiles: displayTiles, at: p)
        canvas.setHighlight(highlightId)
        canvas.setReadout(readoutText(for: hoverChain))
    }

    func canvasDidExit() {
        hoverChain = nil
        canvas.setHighlight(nil)
        canvas.setReadout(nil)
    }

    func canvasDidClick(atPx p: Point) {
        guard !isAnimatingCamera else { return }
        guard let target = HitTest.hit(tiles: displayTiles, at: p)?.topLevelUnderFocus?.nodeId else { return }
        dive(to: target)
    }

    func canvasDidScroll(deltaY: Double, atPx p: Point) {
        guard !isAnimatingCamera else { return }
        if deltaY > Self.scrollZoomThreshold {
            if let target = HitTest.hit(tiles: displayTiles, at: p)?.topLevelUnderFocus?.nodeId {
                dive(to: target)
            }
        } else if deltaY < -Self.scrollZoomThreshold {
            ascend()
        }
    }

    func canvasContextMenu(atPx p: Point) -> NSMenu? {
        guard let deepest = HitTest.hit(tiles: displayTiles, at: p)?.deepest else { return nil }
        contextTargetPath = deepest.nodeId
        let node = latestTree?.node(withId: deepest.nodeId)
        let name = node?.name ?? deepest.nodeId
        let menu = NSMenu()
        let item = NSMenuItem(title: "Reveal “\(name)” in Finder",
                              action: #selector(revealContextTarget), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    // MARK: - Navigation actions

    /// Dive ONE level: the top-level folder under the cursor becomes the new focus
    /// root, filling the canvas (VISION §Experience 4). Animated by the focus
    /// camera, then committed.
    private func dive(to childId: String) {
        guard childId != focusStack.last else { return }
        guard let childRect = displayTiles.first(where: { $0.nodeId == childId })?.rect else { return }
        trace("dive -> \(childId)")
        let base = displayTiles
        let vp = viewport
        // Dive: whole world (viewport) → child rect grows to fill the viewport.
        animateCamera(fromFrame: vp, toFrame: childRect, base: base) { [weak self] in
            guard let self else { return }
            self.focusStack.append(childId)
            self.applyProjectionDepth()
            // Commit ANIMATED (rev-1): the camera left the focus tile filling the
            // viewport EXACTLY. The freshly squarified child layout can differ on the
            // INNER tiles — by the scaled nesting border AND, because squarify is not
            // affine-equivariant under an anisotropic re-fit, by genuine re-tiling of
            // the children to the new aspect (CameraHandoffTests). Lerping FROM the
            // camera's last frame (now in the canvas's displayedTiles) INTO the
            // committed layout closes that bounded, on-screen residual over the settle
            // window instead of snapping — a perceptually continuous handoff.
            self.relayoutCurrent(animated: true)
        }
    }

    /// Zoom OUT to the parent focus (Esc / scroll-out / ⌘↑). The parent world is
    /// laid out as the camera base; the current focus animates from its rect within
    /// that world back out to fill the viewport, then the focus pops.
    func ascend() {
        guard !isAnimatingCamera else { return }
        guard focusStack.count > 1, let tree = latestTree else { return }
        let childId = focusStack[focusStack.count - 1]
        let parentId = focusStack[focusStack.count - 2]
        trace("ascend \(childId) -> \(parentId)")
        let vp = viewport
        let parentTiles = TreemapScene.layout(tree: tree, focusId: parentId,
                                              depthWindow: Self.renderWindow, viewport: vp)
        guard let childRect = parentTiles.first(where: { $0.nodeId == childId })?.rect else {
            // Parent layout does not contain the child (drift) — commit without anim.
            focusStack.removeLast(); applyProjectionDepth(); relayoutCurrent(animated: false); return
        }
        // Zoom out: child-fills-viewport (from) → parent fills viewport (identity).
        animateCamera(fromFrame: childRect, toFrame: vp, base: parentTiles) { [weak self] in
            guard let self else { return }
            self.focusStack.removeLast()
            self.applyProjectionDepth()
            // Zoom-out lands on the parent world EXACTLY (t=1 fits vp→vp = identity
            // over the parent layout that IS the commit target), so this settle is a
            // no-op lerp; animated for symmetry with dive and detail-on-demand.
            self.relayoutCurrent(animated: true)
        }
    }

    /// Set the ScanController's projected detail depth to focus depth + the render
    /// window, so the focused subtree carries enough child detail (decision 4).
    private func applyProjectionDepth() {
        let focusDepth = max(0, focusStack.count - 1)
        scanController?.setProjectionDepth(focusDepth + Self.renderWindow)
    }

    // MARK: - Camera animation driver

    private func animateCamera(fromFrame: Rect, toFrame: Rect, base: [TileRect],
                               completion: @escaping () -> Void) {
        let vp = viewport
        guard vp.width > 0, vp.height > 0 else { completion(); return }
        isAnimatingCamera = true
        // Hide overlays during the flight; they re-target on commit.
        canvas.setHighlight(nil)
        canvas.setTileLabels([])
        canvas.setReadout(nil)
        hoverChain = nil

        let start = CACurrentMediaTime()
        let dur = FocusCamera.refocusDurationSeconds
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tmr in
            MainActor.assumeIsolated {
                guard let self else { tmr.invalidate(); return }
                let t = min(1.0, (CACurrentMediaTime() - start) / dur)
                let tr = FocusCamera.transform(fromFrame: fromFrame, toFrame: toFrame, viewport: vp, t: t)
                let framed = base.map { tile in
                    TileRect(rect: tr.apply(tile.rect), dimLevel: tile.dimLevel,
                             nodeId: tile.nodeId, kind: tile.kind,
                             scanState: tile.scanState, hue: tile.hue)
                }
                self.canvas.renderCameraFrame(tiles: framed)
                if t >= 1.0 {
                    tmr.invalidate()
                    self.cameraTimer = nil
                    self.isAnimatingCamera = false
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cameraTimer = timer
    }

    // MARK: - Finder reveal

    @objc private func revealContextTarget() {
        if let p = contextTargetPath { trace("reveal(context) -> \(p)"); FinderActions.revealInFinder(path: p) }
    }

    /// ⌘R: reveal the currently hovered tile's deepest node (VISION §Experience 5).
    @objc func revealHovered() {
        if let path = hoverChain?.deepest.nodeId {
            trace("reveal(hover) -> \(path)"); FinderActions.revealInFinder(path: path)
        } else {
            trace("reveal(hover) -> <no hover>")
        }
    }

    /// ⌘↑ menu action → zoom out.
    @objc func zoomOut() { ascend() }

    // MARK: - Readout text

    /// The hover readout (packet deliverable 3): the DEEPEST hit tile's full path +
    /// allocated + logical size. Named surface: the floating `HoverReadout` label
    /// in the top-left of the canvas (CanvasView owns the view; text is composed
    /// here from the resolved node).
    private func readoutText(for chain: HitChain?) -> String? {
        guard let chain, let tree = latestTree else { return nil }
        let id = chain.deepest.nodeId
        guard let node = tree.node(withId: id) else { return id }
        let alloc = Self.sizeFormatter.string(fromByteCount: node.allocatedBytes)
        let logical = Self.sizeFormatter.string(fromByteCount: node.logicalBytes)
        // id is the absolute path under the live scan.
        return "\(id)\nallocated \(alloc)   ·   logical \(logical)"
    }
}
