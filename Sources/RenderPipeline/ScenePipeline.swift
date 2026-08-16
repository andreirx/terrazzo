//
//  ScenePipeline.swift — the serial background pipeline (ratified threading model).
//  Module maturity: PROTOTYPE (slice TZ-3b)
//
//  PLAN §"Threading model (ratified 2026-08-16, after the beachball field report)":
//
//    walker tasks ──batches──▶ serial background actor:
//                              reduce → makeTree → squarify →
//                              build immutable RenderScene
//                                    │ one value handoff
//                                    ▼
//                              main actor: input, camera animation, Metal encode
//
//  This IS that serial background actor. It owns the PURE `ScanReducer` (scan side)
//  and calls the PURE `TreemapScene.layout` (viz side), meeting at the `SizeTree`
//  DTO INSIDE the actor — the App is where the two engines are wired (CLAUDE.md
//  hard constraint 1), and this actor is that wiring, extracted into a headless,
//  swift-testable unit. Actor isolation (not locks) serializes every mutation of
//  reducer/focus/viewport and every scene build: all value types, no locks, exactly
//  as the ratified model requires.
//
//  THE TWO DECOUPLED FLOWS (why a slow main never stalls the walker)
//  ----------------------------------------------------------------
//   1. INGEST: `ingest(_:)` folds walker batches as fast as they arrive, in its own
//      Task. It suspends only at `await` on the next batch, so the actor stays free
//      to service focus/viewport changes and cadence ticks between batches.
//   2. EMIT: scenes are yielded into an AsyncStream buffered `.bufferingNewest(1)`.
//      `yield` on a newest-1 stream NEVER suspends the producer — a slow (or absent)
//      consumer just drops stale scenes; it never applies backpressure. So folding
//      (and therefore the walker upstream of it) is never blocked by main.
//   The pipeline-actor test pins both: generations arrive strictly increasing, and
//   every fed batch is folded even when scenes are consumed only at the very end.
//
//  WHEN A SCENE IS EMITTED. On the cadence `tick()` if the reducer changed since the
//  last emit (batched relayout, ratified decision 3), and IMMEDIATELY on a focus /
//  viewport / depth change (so a dive/ascend commit gets its target scene without
//  waiting a full cadence). An empty layout (focus not yet present in the tree) is
//  NOT emitted — the last good scene stands.
//
//  ABSTRACTION LEDGER: one concrete actor; concrete users are the App's
//  ScanController (feeds the real walker stream, drives the cadence) and
//  ScenePipelineTests (feeds a synthetic stream). Axis of variation: NONE invented —
//  no protocol, no strategy; the reducer and layout are the fixed pure cores it
//  sequences. Rejected simpler alternative: keep this on the main actor (the TZ-3
//  arrangement) — that is precisely the beachball this slice removes.
//

import Foundation
#if canImport(ScanCore)
import ScanCore
#endif
#if canImport(TreemapCore)
import TreemapCore
#endif

public actor ScenePipeline {
    /// Batched relayout cadence — ratified decision 3 ("batched ~1 s, animated").
    /// The DRIVER (the App's main-actor timer, or a test) calls `tick()` at this
    /// rate; the O(n) work `tick()` triggers runs here, off main.
    public static let cadenceSeconds: TimeInterval = 1.0

    /// Nesting levels rendered below the focus. Matches the scene default so the
    /// projected tree always carries enough detail to fill the render window.
    private static let renderWindow = TreemapScene.defaultDepthWindow

    /// Sub-pixel cull threshold (device-px area). A tile smaller than ~2×2 device px
    /// carries no readable pixels, and the tail of a deep tree is almost all such
    /// tiles; dropping them here (PLAN §"Rendering scale": "cull rects < ~2 px") bounds
    /// EVERY main-side array/dict — quads, settleFrom, nodeIds, the App's commit/embed
    /// alignment — by the VIEWPORT area instead of the tree's node count.
    ///
    /// THE STRUCTURAL BOUND (review-2 item 1; corrected review-3 item 3). Only dimLevel
    /// 0 — the SINGLE focus background tile — is exempt; EVERY other retained tile has
    /// area ≥ this threshold. The bound is PER LEVEL, not across all tiles at once: a
    /// TreemapScene layout NESTS rects (a parent's rect contains its children's), so
    /// tiles across dim levels OVERLAP — they are NOT globally disjoint, and the naive
    /// "all retained rects disjoint ⇒ at most V/t of them" argument does not hold. What
    /// DOES hold: within ONE dimLevel the tiles ARE disjoint — siblings partition their
    /// parent's inner rect and cousins live in disjoint parents (the HitTest invariant:
    /// at most one tile per dimLevel contains any point). So at each level, disjoint
    /// rects of area ≥ t inside a viewport of area V number at most V/t. The render
    /// window is FIXED at `renderWindow` non-focus levels (detail beyond it is never
    /// laid out), so the total retained count is at most renderWindow · (V/t) + 1 (the
    /// +1 is the focus) — bounded by the viewport AND a fixed depth, PROVABLY independent
    /// of node count, including a focus with arbitrarily many direct children (the
    /// earlier `dimLevel <= 1` exemption let those grow unbounded — the hole the reviewer
    /// flagged). A geometric bound, not an empirical "culling keeps it small"
    /// observation. A sub-pixel top-level tile loses nothing usable: its label is already
    /// suppressed below the far larger `minLabelWidthPx`, and a <2 px tile is not a
    /// meaningful hover target.
    static let minRenderAreaPx: Double = 4.0

    private let rootId: String
    private var reducer: ScanReducer
    /// Retained/rendered child depth passed to `makeTree` (focus depth + render
    /// window) — the detail-on-demand knob (decision 4), set by the App on dive.
    private var projectionDepth: Int
    private var focusId: String
    private var viewport: Rect?
    private var running = true
    /// The reducer changed since the last emitted scene — a cadence tick emits only
    /// when dirty (calm, batched); an immediate emit (focus/viewport) ignores it.
    private var dirty = true
    private var generation = 0

    /// The PREVIOUS emitted scene's quads, keyed by nodeId — the source for the next
    /// scene's `settleFrom` (the streaming settle "from", aligned HERE on the actor so
    /// main never does the String-keyed match). Reset on a focus change: across a
    /// dive/ascend the old-focus positions are meaningless as a same-focus morph
    /// source, and main drives the commit morph from the camera's last frame instead.
    private var lastQuadById: [String: GPUQuad] = [:]

    /// Newest-1 buffered so a slow main never blocks the producer (see header).
    public nonisolated let scenes: AsyncStream<RenderScene>
    private let continuation: AsyncStream<RenderScene>.Continuation

    /// Formatter for label sizes. Instance-owned (actor-isolated) — `ByteCountFormatter`
    /// is not Sendable, so it must not be shared across concurrency domains.
    private let sizeFormatter: ByteCountFormatter

    public init(rootId: String, rootName: String, projectionDepth: Int) {
        self.rootId = rootId
        self.focusId = rootId
        self.projectionDepth = projectionDepth
        self.reducer = ScanReducer(rootId: rootId, rootName: rootName)
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        self.sizeFormatter = f
        let (stream, cont) = AsyncStream<RenderScene>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.scenes = stream
        self.continuation = cont
    }

    // MARK: - Ingest (folds walker batches; never blocked by main)

    /// Fold `stream` (the walker's `AsyncStream<[ScanEvent]>`) to completion, marking
    /// the reducer dirty as data arrives. On completion, mark not-running and force a
    /// final settle scene. Runs as its own Task (the App spawns it); reentrant with
    /// the setters/tick at each `await`.
    public func ingest(_ stream: AsyncStream<[ScanEvent]>) async {
        for await batch in stream {
            reducer.apply(batch)
            dirty = true
        }
        running = false
        emit(force: true) // final settle — reflects everything folded
    }

    // MARK: - Control inputs (posted by the App's main actor)

    /// Cadence trigger: emit a fresh scene iff the reducer changed since the last one.
    public func tick() {
        emit(force: false)
    }

    /// New focus (dive/ascend) + its projection depth in one hop — emit the target
    /// scene immediately so the App's camera commit does not wait a cadence.
    public func setFocus(_ id: String, projectionDepth depth: Int) {
        let focusChanged = id != focusId
        let depthChanged = depth != projectionDepth
        focusId = id
        projectionDepth = depth
        // A new focus invalidates the same-focus settle source (old-focus positions).
        if focusChanged { lastQuadById.removeAll(keepingCapacity: true) }
        if depthChanged { dirty = true } // deeper projection is genuinely new data
        if focusChanged || depthChanged { emit(force: true) }
    }

    /// New viewport (resize) — re-fit and emit immediately.
    public func setViewport(_ vp: Rect) {
        guard vp != viewport else { return }
        viewport = vp
        emit(force: true)
    }

    // MARK: - Scene construction (the node-count-scaling work, off main)

    private func emit(force: Bool) {
        guard force || dirty else { return }
        guard let vp = viewport, vp.width > 0, vp.height > 0 else { return }

        let tree = reducer.makeTree(depthWindow: projectionDepth)
        let laidOut = TreemapScene.layout(tree: tree, focusId: focusId,
                                          depthWindow: Self.renderWindow, viewport: vp)
        guard !laidOut.isEmpty else { return } // focus not present yet — keep last scene

        // Cull sub-pixel tiles (off main). Keep ONLY the focus (dimLevel 0)
        // unconditionally — it is the single background/breadcrumb anchor — and drop
        // EVERY other tile (including top-level dimLevel 1) below the pixel threshold.
        // This is what makes the main-thread bound structural: after this pass every
        // retained non-focus tile has area ≥ minRenderAreaPx, so their PER-LEVEL count is
        // bounded by viewport/threshold (tiles within one dimLevel are disjoint) and —
        // the render window being a FIXED depth — the total is too, regardless of how many
        // direct children the focus has (the corrected bound is in `minRenderAreaPx`).
        // Containment keeps it hierarchically consistent: a
        // culled parent's children sit inside its (sub-threshold) area, so they are
        // culled too — no orphaned child of a dropped parent.
        var tiles = [TileRect](); tiles.reserveCapacity(laidOut.count)
        for t in laidOut where t.dimLevel == 0 || t.rect.area >= Self.minRenderAreaPx {
            tiles.append(t)
        }
        let belowPixelCount = laidOut.count - tiles.count

        // Build the render-ready GPU instances HERE (off main) — the per-tile colour
        // + geometry conversion the App used to do every draw (PLAN §"Threading
        // model" law). O(tiles), on the background actor, once per emitted scene.
        let quads = QuadBuilder.build(tiles: tiles)

        // Build the streaming settle "from" HERE (off main): where each tile sat in the
        // previous emitted scene, index-parallel with `quads`. This is the String-keyed
        // identity match the App used to run on the main thread (the 158 ms hitch);
        // it now runs on the actor, and main receives a ready-to-upload buffer. A node
        // absent from the previous scene carries its own quad (from == to ⇒ no fly-in).
        // Also build the tiles' nodeId list HERE (off main): index-parallel with
        // `quads`, so the App installs its DisplaySnapshot without the per-node
        // `tiles.map { $0.nodeId }` it used to run on the main actor (review-2).
        var settleFrom = [GPUQuad](); settleFrom.reserveCapacity(tiles.count)
        var nodeIds = [String](); nodeIds.reserveCapacity(tiles.count)
        var nextById = [String: GPUQuad](minimumCapacity: tiles.count)
        for (i, t) in tiles.enumerated() {
            settleFrom.append(lastQuadById[t.nodeId] ?? quads[i])
            nodeIds.append(t.nodeId)
            nextById[t.nodeId] = quads[i]
        }
        lastQuadById = nextById

        let labels = buildLabels(tree: tree, tiles: tiles)
        generation += 1
        dirty = false
        continuation.yield(RenderScene(
            generation: generation, focusId: focusId, viewport: vp,
            tiles: tiles, nodeIds: nodeIds, quads: quads, settleFrom: settleFrom,
            labels: labels, tree: tree, belowPixelCount: belowPixelCount, running: running))
    }

    /// Compose a label (name + human size) for each top-level (dimLevel 1) tile.
    /// O(top-level) after one O(top-level) index of the focus node's children — it
    /// does NOT walk the whole tree per label (the trap the App's TZ-3
    /// refreshTileLabels fell into, which this slice moves off main entirely).
    private func buildLabels(tree: SizeTree, tiles: [TileRect]) -> [SceneLabel] {
        guard let focus = tree.node(withId: focusId) else { return [] }
        var byId: [String: SizeTree] = [:]
        byId.reserveCapacity(focus.children.count)
        for c in focus.children { byId[c.id] = c }
        return tiles.compactMap { tile in
            guard tile.dimLevel == 1 else { return nil }
            let node = byId[tile.nodeId]
            let name = node?.name ?? tile.nodeId
            let size = sizeFormatter.string(fromByteCount: node?.allocatedBytes ?? 0)
            return SceneLabel(rect: tile.rect, text: "\(name)  ·  \(size)")
        }
    }
}
