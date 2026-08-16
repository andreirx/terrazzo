//
//  NavigationController.swift — the App's navigation state machine.
//  Module maturity: PROTOTYPE (slice TZ-3; threading + ascend-handoff TZ-3b)
//
//  The crossing point of TZ-3's interaction: it owns navigation STATE (the focus
//  stack, the latest streamed scene, the current hover) and orchestrates input, the
//  focus camera, and Finder against the AppKit surfaces. It is App-layer glue — the
//  pure, testable pieces live in TreemapCore (HitTest, FocusCamera) and
//  RenderPipeline (the scene build + GPUQuad); this class only sequences them.
//
//  TZ-3b MOVED ALL NODE-COUNT WORK OFF MAIN. The background `ScenePipeline` lays
//  out the tiles, culls sub-pixel ones, AND builds the render-ready GPU instances
//  (`RenderScene.quads`), the tiles' nodeIds, and the streaming settle source
//  (`RenderScene.settleFrom`). This controller no longer squarifies, colours,
//  identity-matches, or even LISTS tiles per node:
//   - PRESENT a streaming scene = install the pipeline's prebuilt `quads`/`nodeIds` and
//     hand the canvas `settleFrom` + `quads` (memcpy's) — ZERO per-tile work on main
//     (the 158 ms String-keyed `currentDisplayedById` AND the `tiles.map { nodeId }`
//     both gone; both run on the actor).
//   - The dive/ascend CAMERA is a per-frame UNIFORM update (`canvas.setCamera`) over
//     ONE prebuilt base buffer — O(1) on main per frame. Dive reuses the CURRENT
//     scene's already-prebuilt quads as that base (no build); ascend embeds the child's
//     prebuilt quads into the parent's prebuilt quads by a pure affine (no colour
//     rebuild). Neither calls QuadBuilder on main (review-1 Sites C/D).
//   - HOVER highlight is a single instance-index uniform.
//  The dive/ascend COMMIT and the ascend EMBED still match per node — the camera's last
//  frame keyed to the committed scene (`commitFrom`), and the child subtree embedded
//  into the parent world (`embedChild`). Both are delegated to the PURE, swift-tested
//  `RenderPipeline.QuadGeometry` (so the tests drive the production math, review-2), run
//  ONCE per user-driven navigation (never per frame), and — because ScenePipeline now
//  culls EVERY non-focus tile below the pixel threshold — operate over arrays bounded by
//  viewport/threshold, PROVABLY independent of node count (the ratified law forbids main
//  work that scales with node count; this does not). They are intrinsically main-side:
//  they compose main-only state (the live camera transform; the cached parent + the
//  displayed child snapshots) the background actor does not hold.
//
//  TWO ANIMATIONS, DELIBERATELY SEPARATE:
//    1. Batched SETTLE (CanvasView): between scenes at the SAME focus, geometry lerps
//       old→new in the vertex shader (calm streaming).
//    2. Focus CAMERA (here): on a dive/ascend, a fixed base world is held and the
//       camera affine is animated over it (~350 ms), then committed. During a camera
//       animation incoming scenes update `latestScene` but do NOT present (they would
//       fight the camera); the commit presents the freshest scene via a settle.
//
//  ASCEND IS DIVE REVERSED (TZ-3b rider 1, review-0 gap 3). Dive animates the camera
//  over the PARENT world (whose t=0 frame IS the displayed parent — clean start) and
//  ABSORBS the anisotropic re-tiling residual at the END via the commit settle
//  (CameraHandoffTests). Ascend is the mirror: its residual would land at the START
//  (the displayed child scene vs a freshly-laid parent world differ by re-tiling). We
//  ELIMINATE that opening residual by construction: ascend animates over the cached
//  parent with the CHILD's own committed layout EMBEDDED into the child's slot, so at
//  t=0 the shared child subtree maps back EXACTLY onto the displayed child scene (the
//  embed transform and the t=0 camera transform are inverses). The now-tiny residual
//  (child shown small in the parent's native re-tiling) lands at the commit and is
//  absorbed by the settle — the geometric inverse of dive. AscendHandoffTests pins
//  the t=0 all-shared-tile match within epsilon.
//
//  DETAIL ON DEMAND (decision 4): diving deeper posts a higher projection depth to
//  the pipeline, which re-projects the already-scanned tree deeper — never a rescan.
//
//  ABSTRACTION LEDGER: one concrete coordinator, one caller (AppDelegate). It is the
//  CanvasInputDelegate (its one implementer). No protocol beyond that input seam.
//

import AppKit

@MainActor
final class NavigationController: CanvasInputDelegate {
    /// Render window below the focus (levels of child detail). Matches the scene's
    /// default so the projected tree always carries enough detail to fill the window.
    private static let renderWindow = TreemapScene.defaultDepthWindow

    // MARK: Scroll-feel constants (TZ-3b rider 2). One INTENTIONAL zoom step per
    // gesture unit; sustained scrolling steps rhythmically because a step can only
    // fire between camera animations (the mid-animation debounce), and the
    // accumulator resets at each animation so the next step needs fresh scrolling.
    //
    //  - Mouse WHEEL (non-precise deltas): one notch = one step. macOS delivers a
    //    wheel notch as a single event with |deltaY| ≳ 1 line, so a tiny threshold
    //    fires exactly once per notch.
    //  - TRACKPAD (precise deltas): a short ~1–2 cm swipe sums to ~40–80 units; we
    //    step once per `trackpadStepUnits` of accumulated delta so one swipe = one
    //    step, not a burst of dives.
    private static let wheelStepUnits: Double = 1.0
    private static let trackpadStepUnits: Double = 40.0

    private let canvas: CanvasView
    private let bottomBar: StatusBar
    /// Set once, right after construction (the Main-assembly late binding that breaks
    /// the ScanController↔NavigationController construction cycle). Owned by AppDelegate.
    weak var scanController: ScanController?

    /// A committed on-screen scene captured as prebuilt render state. Concrete users:
    /// `displayed` (what is on screen now) and the `sceneStack` entries (the parent
    /// worlds we dived through, replayed on ascend). Axis of variation: none — it is a
    /// DTO bundling three index-parallel arrays that always travel together (tiles for
    /// hit-test, quads for the GPU, nodeIds for identity). Rejected simpler
    /// alternative: three parallel `[…]` properties per level, which invites an
    /// index-length mismatch across the dive/ascend push/pop.
    private struct DisplaySnapshot {
        var tiles: [TileRect]
        var quads: [GPUQuad]
        var nodeIds: [String]
        static let empty = DisplaySnapshot(tiles: [], quads: [], nodeIds: [])
    }

    /// The latest scene the pipeline emitted (positioned tiles + prebuilt quads +
    /// composed labels + the projected tree for hover/menu lookups).
    private var latestScene: RenderScene?
    /// Focus path as node ids, root→current. Under the live scan a node id IS its
    /// absolute path, so `focusStack.last` is the current focus's absolute path.
    private var focusStack: [String] = []
    /// The prebuilt parent worlds we dived THROUGH, parallel to `focusStack` above the
    /// root: index i is the parent snapshot present when we dived to `focusStack[i+1]`.
    /// Popped on ascend to run the dive-reversed camera over the exact geometry the
    /// user saw (TZ-3b rider 1) using its already-prebuilt quads — no rebuild on main.
    private var sceneStack: [DisplaySnapshot] = []
    /// The scene currently on screen at the current focus — hit-tests query its tiles,
    /// the camera base reuses its prebuilt quads, hover indexes its nodeIds.
    private var displayed: DisplaySnapshot = .empty
    private var hoverChain: HitChain?
    /// Accumulated scroll delta since the last step (see scroll-feel constants).
    private var scrollAccum: Double = 0

    // Camera animation state.
    private var cameraTimer: Timer?
    private var isAnimatingCamera = false
    /// The camera flight's fixed base (prebuilt quads + parallel nodeIds) and the
    /// transform at its LAST frame. On commit these build the settle "from" = the
    /// camera's last frame, matched by nodeId to the committed scene — the one place
    /// main aligns per node, and only per user-driven navigation over the culled base.
    /// Not a `DisplaySnapshot`: a flight base is render-only (an ascend base reorders
    /// quads relative to any tile list), so it deliberately carries no hit-test tiles.
    private var flightBaseQuads: [GPUQuad] = []
    private var flightBaseNodeIds: [String] = []
    private var flightFinalCam: ViewTransform = .identity
    /// Set when a flight committed but the fresh scene for the new focus had not yet
    /// arrived: the NEXT scene at that focus drives the commit morph from `flightBase`
    /// rather than from its own (stale, cross-focus) `settleFrom`.
    private var awaitingFocusScene = false
    /// Path targeted by the right-click context menu item (deepest tile under click).
    private var contextTargetPath: String?
    /// Anchor (device px) for the synthetic-tile explainer popover — captured at the
    /// click / context-menu location so a menu action fired later still has a position.
    private var syntheticAnchorPx: Point?
    /// The reused "About Unaccounted space" explainer popover (TZ-4 D7). Lazily built.
    private var explainerPopover: NSPopover?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f
    }()

    init(canvas: CanvasView, bottomBar: StatusBar) {
        self.canvas = canvas
        self.bottomBar = bottomBar
        canvas.input = self
    }

    /// Diagnostic trace of navigation actions to stdout, gated by `TERRAZZO_TRACE`.
    /// Makes the LIVE navigation path OBSERVABLE to a headless harness that cannot see
    /// the rendered map. Reading a process-env flag is a value read — no I/O. Silent
    /// unless set.
    private static let traceEnabled = ProcessInfo.processInfo.environment["TERRAZZO_TRACE"] != nil
    private func trace(_ s: String) {
        if Self.traceEnabled { print("TZTRACE \(s)"); fflush(stdout) }
    }

    /// Post the current focus + its projection depth to the pipeline (detail on
    /// demand). Called on every dive/ascend so the pipeline lays out the new focus.
    private func applyFocusToPipeline() {
        guard let focusId = focusStack.last else { return }
        let focusDepth = max(0, focusStack.count - 1)
        scanController?.setFocus(focusId, projectionDepth: focusDepth + Self.renderWindow)
    }

    /// Post the current viewport to the pipeline (startup + resize). Called by
    /// AppDelegate once ScanController is wired, and on every viewport change.
    func pushViewport() {
        let vp = viewport
        guard vp.width > 0, vp.height > 0 else { return }
        scanController?.setViewport(vp)
    }

    // MARK: - Scene intake (from ScanController → pipeline)

    func onScene(_ scene: RenderScene) {
        latestScene = scene
        if focusStack.isEmpty {
            focusStack = [scene.focusId]
            bottomBar.setFocusPath(scene.focusId)
        }
        // Do not disturb an in-flight camera animation; it presents on commit.
        guard !isAnimatingCamera else { return }
        // Ignore a scene laid out for a focus we have already left (in flight when
        // the user dived/ascended). The matching scene follows immediately.
        guard scene.focusId == focusStack.last else { return }
        if awaitingFocusScene {
            // First scene at a focus a flight just committed to, but which had not
            // emitted yet at commit time: morph from the camera's last frame, not from
            // this scene's own settleFrom (which aligns to the PREVIOUS focus).
            awaitingFocusScene = false
            presentScene(scene, from: commitFrom(for: scene), animated: true)
        } else {
            // Same-focus streaming update: the pipeline already built the settle "from".
            // During a live resize, SNAP to the re-squarified scene (the camera has been
            // stretching the prior scene) rather than settle-morph mid-drag (D8).
            presentScene(scene, from: scene.settleFrom, animated: !canvas.inLiveResize)
        }
    }

    /// Install a finished scene: prebuilt quads → canvas, composed labels → overlays,
    /// focus path → breadcrumb. No layout, no per-tile build here — it was all done
    /// off main; the canvas memcpy's the prebuilt `from`/`to` buffers and the shader
    /// morphs between them. `from` is the pre-aligned settle source (pipeline
    /// `settleFrom` for streaming; a camera-end frame for a commit).
    private func presentScene(_ scene: RenderScene, from: [GPUQuad], animated: Bool) {
        // nodeIds come PREBUILT in the scene (built on the pipeline actor) — no
        // `scene.tiles.map { $0.nodeId }` on the main actor (review-2, main-thread law).
        displayed = DisplaySnapshot(tiles: scene.tiles, quads: scene.quads,
                                    nodeIds: scene.nodeIds)
        canvas.present(from: from, to: scene.quads, animated: animated)
        // Record the viewport this scene was laid out for, so a live resize can stretch
        // it to a new drawable via the camera uniform without a relayout (D8).
        canvas.setSceneViewport(scene.viewport)
        canvas.setHighlightIndex(currentHighlightIndex())
        bottomBar.setFocusPath(scene.focusId)
        canvas.setTileLabels(scene.labels.map { CanvasView.TileLabel(rect: $0.rect, text: $0.text) })
    }

    /// The settle "from" for a COMMIT — delegated to the PURE, swift-tested
    /// `QuadGeometry.commitFrom` (the production path QuadGeometryTests exercises).
    /// Each committed tile is placed where its node sat in the camera's LAST frame (the
    /// flight base under `flightFinalCam`), matched by nodeId; an absent node carries its
    /// own quad (appears in place). Run only per user-driven dive/ascend, over the
    /// viewport-CULLED base + scene — bounded by the viewport, not the tree's node count.
    private func commitFrom(for scene: RenderScene) -> [GPUQuad] {
        QuadGeometry.commitFrom(sceneQuads: scene.quads, sceneNodeIds: scene.nodeIds,
                                baseQuads: flightBaseQuads, baseNodeIds: flightBaseNodeIds,
                                finalCam: flightFinalCam)
    }

    private var highlightId: String? { hoverChain?.topLevelUnderFocus?.nodeId }

    /// Index of the hovered top-level tile in the current instance buffer (or -1) —
    /// the hover-highlight uniform. O(displayed) on hover only (user-driven).
    private func currentHighlightIndex() -> Int {
        guard let id = highlightId else { return -1 }
        return displayed.nodeIds.firstIndex(of: id) ?? -1
    }

    // MARK: - Layout viewport

    private var viewport: Rect { canvas.viewportPx }

    // MARK: - CanvasInputDelegate

    func canvasViewportChanged() {
        // A resize is a viewport change → tell the pipeline to re-fit (immediate emit).
        pushViewport()
        guard !isAnimatingCamera, !displayed.quads.isEmpty else { return }
        // During a LIVE resize the CanvasView is stretching the current scene via the
        // camera uniform (D8); an identity snap here would fight it. Skip — the
        // re-squarified scene swaps in on settle (viewDidEndLiveResize / cadence).
        guard !canvas.inLiveResize else { return }
        // Redraw the current tiles at the new drawable size so the canvas is not blank
        // during the sub-frame until the re-fitted scene lands (snap, not settle). Do NOT
        // update sceneViewport here — these quads still match the PREVIOUS scene's
        // viewport; presentScene sets it when a scene laid out for a viewport lands.
        canvas.present(from: displayed.quads, to: displayed.quads, animated: false)
        canvas.setHighlightIndex(currentHighlightIndex())
    }

    func canvasDidHover(atPx p: Point) {
        guard !isAnimatingCamera else { return }
        hoverChain = HitTest.hit(tiles: displayed.tiles, at: p)
        canvas.setHighlightIndex(currentHighlightIndex())
        if let tile = hoverChain?.deepest {
            // Callout chip anchored ON the tile near the cursor (D9); full path (or the
            // decomposed unaccounted explanation) in the bottom bar.
            canvas.setCallout(text: calloutText(for: tile), hue: tile.hue, atPx: p)
            bottomBar.setHoverPath(hoverPathText(for: tile))
        } else {
            canvas.clearCallout()
            bottomBar.setHoverPath(nil)
        }
    }

    func canvasDidExit() {
        hoverChain = nil
        canvas.setHighlightIndex(-1)
        canvas.clearCallout()
        bottomBar.setHoverPath(nil)
    }

    func canvasDidClick(atPx p: Point) {
        guard !isAnimatingCamera else { return }
        guard let top = HitTest.hit(tiles: displayed.tiles, at: p)?.topLevelUnderFocus else { return }
        // The UNACCOUNTED tile is not a folder — never dive it; explain instead (D7).
        if top.kind == .synthetic { syntheticAnchorPx = p; showSyntheticExplainer(atPx: p); return }
        dive(to: top.nodeId)
    }

    func canvasDidScroll(deltaY: Double, precise: Bool, atPx p: Point) {
        // Mid-animation debounce: a step can only fire between camera animations, and
        // the accumulator resets so the next step needs fresh scrolling (rhythmic).
        guard !isAnimatingCamera else { scrollAccum = 0; return }
        let step = precise ? Self.trackpadStepUnits : Self.wheelStepUnits
        scrollAccum += deltaY
        if scrollAccum >= step {
            scrollAccum = 0
            // Scroll-in dives — but never into the synthetic unaccounted tile (D7).
            if let top = HitTest.hit(tiles: displayed.tiles, at: p)?.topLevelUnderFocus,
               top.kind != .synthetic {
                dive(to: top.nodeId)
            }
        } else if scrollAccum <= -step {
            scrollAccum = 0
            ascend()
        }
    }

    func canvasContextMenu(atPx p: Point) -> NSMenu? {
        guard let deepest = HitTest.hit(tiles: displayed.tiles, at: p)?.deepest else { return nil }
        let menu = NSMenu()
        // The unaccounted tile is not revealable in Finder (no real path) — offer the
        // explainer instead (D7). Name/kind come PREBUILT on the hit tile (denormalized
        // off main at layout time) — no tree traversal on the main actor.
        if deepest.kind == .synthetic {
            contextTargetPath = nil
            syntheticAnchorPx = p
            let item = NSMenuItem(title: "About Unaccounted space…",
                                  action: #selector(explainSyntheticFromMenu), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }
        contextTargetPath = deepest.nodeId
        let name = deepest.name.isEmpty ? deepest.nodeId : deepest.name
        let item = NSMenuItem(title: "Reveal “\(name)” in Finder",
                              action: #selector(revealContextTarget), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    // MARK: - Navigation actions

    /// Dive ONE level: the top-level folder under the cursor becomes the new focus,
    /// filling the canvas. The camera animates against the CURRENT (old) scene while
    /// the pipeline lays out the child focus async; the child scene swaps in on commit.
    private func dive(to childId: String) {
        guard childId != focusStack.last else { return }
        guard let childTile = displayed.tiles.first(where: { $0.nodeId == childId }) else { return }
        // Defense in depth: the synthetic unaccounted tile is never a dive target (D7);
        // the click/scroll paths already gate on it, this guards any other caller.
        guard childTile.kind != .synthetic else { return }
        let childRect = childTile.rect
        trace("dive -> \(childId)")
        let base = displayed // already prebuilt — no QuadBuilder on main (OPERATOR_NOTE gap 1)
        let vp = viewport
        // Cache the parent snapshot we dived through, for a dive-reversed ascend.
        sceneStack.append(base)
        focusStack.append(childId)
        scanController?.setPhase("dive")
        applyFocusToPipeline() // pipeline lays out the child focus; scene arrives async

        // Dive: whole world (viewport) → child rect grows to fill the viewport. The
        // camera flies over the parent's ALREADY-prebuilt quads (no per-tile build).
        animateCamera(fromFrame: vp, toFrame: childRect,
                      baseQuads: base.quads, baseNodeIds: base.nodeIds) { [weak self] in
            guard let self else { return }
            self.commitToLatestScene()
            self.scanController?.setPhase("scanning")
        }
    }

    /// Zoom OUT to the parent focus (Esc / scroll-out / ⌘↑). Runs the camera from the
    /// child framing back out over the cached parent world with the CHILD's own
    /// committed layout embedded into the child's slot — so t=0 lands exactly on the
    /// displayed child scene (no opening snap), then settles onto the fresh parent
    /// scene the pipeline emits (TZ-3b rider 1, review-0 gap 3).
    func ascend() {
        guard !isAnimatingCamera else { return }
        guard focusStack.count > 1 else { return }
        let childId = focusStack[focusStack.count - 1]
        let parentId = focusStack[focusStack.count - 2]

        guard let cachedParent = sceneStack.last,
              let childRect = cachedParent.tiles.first(where: { $0.nodeId == childId })?.rect else {
            // No cached parent geometry (drift) — pop and let the pipeline re-emit.
            trace("ascend \(childId) -> \(parentId) (no cache, snap)")
            focusStack.removeLast()
            if !sceneStack.isEmpty { sceneStack.removeLast() }
            applyFocusToPipeline()
            return
        }
        trace("ascend \(childId) -> \(parentId)")
        let childScene = displayed // the committed child layout currently on screen
        focusStack.removeLast()
        _ = sceneStack.removeLast()
        let vp = viewport
        scanController?.setPhase("ascend")
        applyFocusToPipeline() // pipeline lays out the parent focus; fresh scene async

        // Build the ascend base IN QUAD SPACE (no QuadBuilder, no HSB — OPERATOR_NOTE
        // gap 1 / review-1 Site D) via the PURE, swift-tested `QuadGeometry.embedChild`
        // (the production path QuadGeometryTests exercises): the cached parent's
        // ALREADY-prebuilt quads, but with C's subtree replaced by the child's OWN
        // committed quads mapped from the viewport into C's slot. At the t=0 camera
        // transform (childRect → viewport) these map back EXACTLY onto the displayed
        // child scene, so the animation opens on it with no snap.
        let (baseQuads, baseNodeIds) = QuadGeometry.embedChild(
            childQuads: childScene.quads, childNodeIds: childScene.nodeIds, into: childRect,
            parentQuads: cachedParent.quads, parentNodeIds: cachedParent.nodeIds, childId: childId)

        // Zoom out: child-fills-viewport (from) → parent fills viewport (identity).
        animateCamera(fromFrame: childRect, toFrame: vp,
                      baseQuads: baseQuads, baseNodeIds: baseNodeIds) { [weak self] in
            guard let self else { return }
            if !self.commitToLatestScene() {
                // Fresh parent scene not here yet (rare — setFocus force-emits): hold the
                // cached parent (identity, prebuilt) so the frame is stable; the next
                // parent scene streams in via onScene shortly.
                self.presentSnapshot(cachedParent)
            }
            self.scanController?.setPhase("scanning")
        }
    }

    /// Present the freshest scene for the CURRENT focus if the pipeline has emitted it,
    /// morphing from the camera's LAST frame (built by `commitFrom`) into the committed
    /// layout. Returns whether a matching scene was available.
    @discardableResult
    private func commitToLatestScene() -> Bool {
        guard let scene = latestScene, scene.focusId == focusStack.last else {
            // The fresh scene has not arrived; the next onScene at this focus drives the
            // commit morph from the camera's last frame instead of its own settleFrom.
            awaitingFocusScene = true
            return false
        }
        awaitingFocusScene = false
        presentScene(scene, from: commitFrom(for: scene), animated: true)
        return true
    }

    /// Snap a prebuilt display snapshot onto the canvas (no build). Used only on the
    /// rare ascend fallback where the fresh parent scene has not yet been emitted.
    private func presentSnapshot(_ snap: DisplaySnapshot) {
        displayed = snap
        canvas.present(from: snap.quads, to: snap.quads, animated: false)
        canvas.setHighlightIndex(-1)
        bottomBar.setFocusPath(focusStack.last ?? snap.nodeIds.first ?? "")
    }

    // MARK: - Camera animation driver (uniform-based; O(1) per frame)

    private func animateCamera(fromFrame: Rect, toFrame: Rect,
                               baseQuads: [GPUQuad], baseNodeIds: [String],
                               completion: @escaping () -> Void) {
        let vp = viewport
        guard vp.width > 0, vp.height > 0 else { completion(); return }
        isAnimatingCamera = true
        // Hide overlays during the flight; they re-target on commit.
        canvas.setHighlightIndex(-1)
        canvas.setTileLabels([])
        canvas.clearCallout()
        bottomBar.setHoverPath(nil)
        hoverChain = nil

        // Remember the flight base + its LAST-frame transform so the commit can build
        // its settle "from" (the camera's last frame) without rebuilding anything.
        flightBaseQuads = baseQuads
        flightBaseNodeIds = baseNodeIds
        flightFinalCam = FocusCamera.transform(fromFrame: fromFrame, toFrame: toFrame,
                                               viewport: vp, t: 1)

        // Upload the prebuilt base buffer ONCE (NO paint — beginCameraFlight no longer
        // renders); every frame then only sets the camera uniform over it (no per-tile
        // map — the pre-TZ-3b defect).
        canvas.beginCameraFlight(base: baseQuads)
        // The FIRST painted frame is this explicit t=0 frame — nothing is drawn between
        // the buffer upload and here, so there is no identity/parent-world flash before
        // the matching t=0 child frame (review-2 gap 2, ascend continuity).
        applyCameraFrame(fromFrame: fromFrame, toFrame: toFrame, viewport: vp, t: 0)

        let start = CACurrentMediaTime()
        let dur = FocusCamera.refocusDurationSeconds
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tmr in
            MainActor.assumeIsolated {
                guard let self else { tmr.invalidate(); return }
                let t = min(1.0, (CACurrentMediaTime() - start) / dur)
                self.applyCameraFrame(fromFrame: fromFrame, toFrame: toFrame, viewport: vp, t: t)
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

    /// Push the camera affine at parameter `t` to the canvas (a uniform update).
    private func applyCameraFrame(fromFrame: Rect, toFrame: Rect, viewport vp: Rect, t: Double) {
        let tr = FocusCamera.transform(fromFrame: fromFrame, toFrame: toFrame, viewport: vp, t: t)
        canvas.setCamera(scaleX: tr.scaleX, scaleY: tr.scaleY,
                         translateX: tr.translateX, translateY: tr.translateY)
    }

    // MARK: - Headless test seam (TZ-3b threading harness — conduct rule)

    /// Drive one navigation step programmatically — dive into the first displayed
    /// top-level tile, or ascend — with NO synthetic input and NO window. Exercises
    /// the REAL dive()/ascend() camera + scene-handoff path so the windowless
    /// threading harness can measure the main thread under continuous navigation
    /// (packet gap 2, conduct rule). Not used by the app.
    func driveNavigationStep(dive: Bool) {
        guard !isAnimatingCamera else { return }
        if dive {
            // Dive into the LARGEST top-level folder — the deepest subtree, so the
            // camera base built on main (and the pipeline's re-projection) is the most
            // demanding case, not a trivial leaf. This scan is over the VIEWPORT-CULLED
            // `displayed.tiles` (bounded by viewport/threshold, not node count), and is
            // HARNESS-ONLY (not on any app input path) — it stands in for the human's
            // pick of a tile, which the conduct rule forbids simulating with real input.
            let biggest = displayed.tiles
                .filter { $0.dimLevel == 1 }
                .max { $0.rect.area < $1.rect.area }?.nodeId
            if let biggest { self.dive(to: biggest) }
        } else {
            ascend()
        }
    }

    // MARK: - Finder reveal

    @objc private func revealContextTarget() {
        if let p = contextTargetPath { trace("reveal(context) -> \(p)"); FinderActions.revealInFinder(path: p) }
    }

    /// ⌘R: reveal the currently hovered tile's deepest node (VISION §Experience 5).
    @objc func revealHovered() {
        guard let tile = hoverChain?.deepest else { trace("reveal(hover) -> <no hover>"); return }
        // The synthetic unaccounted tile has no real path — never send it to Finder (D7).
        guard tile.kind != .synthetic else { trace("reveal(hover) -> <synthetic, ignored>"); return }
        trace("reveal(hover) -> \(tile.nodeId)"); FinderActions.revealInFinder(path: tile.nodeId)
    }

    /// ⌘↑ menu action → zoom out.
    @objc func zoomOut() { ascend() }

    // MARK: - New-scan reset (rescan / volume switch, TZ-4)

    /// Reset all navigation state for a fresh scan (Rescan button / VolumePicker). The
    /// next scene the new pipeline emits re-seeds the focus stack from its root, so the
    /// map starts clean at the new volume's root rather than carrying a stale focus.
    func resetForNewScan() {
        cameraTimer?.invalidate(); cameraTimer = nil
        isAnimatingCamera = false
        awaitingFocusScene = false
        latestScene = nil
        focusStack = []
        sceneStack = []
        displayed = .empty
        hoverChain = nil
        scrollAccum = 0
        flightBaseQuads = []; flightBaseNodeIds = []
        canvas.setHighlightIndex(-1)
        canvas.clearCallout()
        canvas.setTileLabels([])
        bottomBar.setHoverPath(nil)
    }

    // MARK: - Hover callout / path text (TZ-4 D9) + synthetic explainer (D7)

    /// The on-tile callout chip text: name + allocated size (+ logical only when it
    /// differs). Read straight off the hit `TileRect` (name/sizes denormalized onto the
    /// tile on the pipeline actor at layout time, TZ-3b) — NO tree traversal on main.
    private func calloutText(for tile: TileRect) -> String {
        if tile.kind == .synthetic {
            let name = tile.name.isEmpty ? SyntheticTile.unaccountedName : tile.name
            return "\(name)  ·  \(Self.sizeFormatter.string(fromByteCount: tile.allocatedBytes))"
        }
        let name = tile.name.isEmpty ? (tile.nodeId as NSString).lastPathComponent : tile.name
        // Denied dir (D6): the readout SAYS "no permission" (its size is only the dir's
        // own entry — contents are unreadable), with the path shown in the bottom bar.
        if tile.kind == .denied {
            return "\(name)  ·  no permission"
        }
        let alloc = Self.sizeFormatter.string(fromByteCount: tile.allocatedBytes)
        if tile.logicalBytes != tile.allocatedBytes {
            let logical = Self.sizeFormatter.string(fromByteCount: tile.logicalBytes)
            return "\(name)  ·  \(alloc)  (logical \(logical))"
        }
        return "\(name)  ·  \(alloc)"
    }

    /// The bottom-bar hover text: the hovered node's FULL path, or — for the synthetic
    /// unaccounted tile — its DECOMPOSED accounting (human directive 2026-08-16):
    /// "purgeable X + other users / unknown Y", phrased as space no scan from this POSIX
    /// account can see (FDA never crosses user boundaries — VISION).
    private func hoverPathText(for tile: TileRect) -> String {
        guard tile.kind == .synthetic else { return tile.nodeId }
        let purgeable = latestScene?.purgeableBytes ?? 0
        let (p, unknown) = SyntheticTile.decompose(unaccounted: tile.allocatedBytes, purgeable: purgeable)
        let ps = Self.sizeFormatter.string(fromByteCount: p)
        let us = Self.sizeFormatter.string(fromByteCount: unknown)
        return "Unaccounted — purgeable \(ps) + other users / unknown \(us) (space no scan from this account can see)"
    }

    @objc private func explainSyntheticFromMenu() {
        showSyntheticExplainer(atPx: syntheticAnchorPx ?? Point(x: viewport.width / 2, y: viewport.height / 2))
    }

    /// Show the "About Unaccounted space" explainer popover anchored at `p` (device px).
    /// The unaccounted tile is a volume-accounting residual, not a folder — this is the
    /// short explanation the packet requires clicking it to surface (D7).
    private func showSyntheticExplainer(atPx p: Point) {
        let pop = explainerPopover ?? Self.makeExplainerPopover()
        explainerPopover = pop
        let scale = Double(canvas.window?.backingScaleFactor ?? 2.0)
        let xPt = p.x / scale
        let yUp = Double(canvas.bounds.height) - (p.y / scale) // device px (y-down) → view pts (y-up)
        let rect = NSRect(x: xPt - 1, y: yUp - 1, width: 2, height: 2)
        pop.show(relativeTo: rect, of: canvas, preferredEdge: .maxY)
    }

    private static func makeExplainerPopover() -> NSPopover {
        let text = NSTextField(wrappingLabelWithString:
            "Unaccounted space\n\nThis isn’t a folder — it’s the gap between the volume’s used space and everything Terrazzo could measure from this account. It covers reclaimable (purgeable) space plus files no scan from your user can see: other users’ home folders and system snapshots.\n\nFull Disk Access lets Terrazzo read TCC-protected files, but it never crosses POSIX user boundaries, so this residual is the closest estimate of other users’ disk usage. It can’t be opened or revealed in Finder.")
        text.font = .systemFont(ofSize: 11)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = 300
        let container = NSView()
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            text.widthAnchor.constraint(equalToConstant: 300),
        ])
        let vc = NSViewController()
        vc.view = container
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        return pop
    }
}
