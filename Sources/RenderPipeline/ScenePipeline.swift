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
//      Task, via `foldWithPreemption` — which chunks each fold and `await Task.yield()`s
//      between chunks/batches so a queued focus/viewport message OVERTAKES the ingest at
//      the next suspension point (TZ-4b OPERATOR_NOTE #3.1 queue priority). Without those
//      yields a tight fold over an already-buffered stream holds the actor for the whole
//      drain and a focus commit waits behind it (the escalate's 1059 ms).
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

    /// Nesting levels rendered below the focus. The DEFAULT matches the scene default so the
    /// projected tree carries enough detail to fill the render window; TZ-5 makes it USER-SETTABLE
    /// (the control-bar depth stepper → `setDepthWindow`). It is a pure RENDER window over the
    /// fully-retained node map — the reducer keeps every node regardless (sizes true, decision 4),
    /// so raising it re-projects deeper with NO rescan. Used identically by `makeRenderTree` (which
    /// subtrees to materialize) and `TreemapScene.layout` (the dim ladder), so the two always agree.
    private static let defaultRenderWindow = TreemapScene.defaultDepthWindow
    private var renderWindow = ScenePipeline.defaultRenderWindow

    // MARK: - TZ-5 visualization lenses (session-only inputs; scan tree untouched)
    //
    // All four are PURE inputs to the projection/layout the App posts via the setters below;
    // each `set*` force-emits so the change is reflected without waiting a cadence. They live on
    // the actor (not the App) so the node-count-scaling re-projection they trigger stays off main
    // (the ratified threading law). The scan reducer is never mutated — these only change WHICH
    // retained nodes are projected and with WHAT area weighting.

    /// The IGNORE set: node ids excluded from layout so their SIBLINGS renormalize into the freed
    /// area (ancestors keep their areas). The App owns the authoritative set + the panel/accounting;
    /// this is the copy the projection filters on. Ids are absolute paths, so an ignored node stays
    /// excluded wherever it appears under the current focus.
    private var ignoredIds: Set<String> = []
    /// Show-hidden lens (deliverable 3): `true` (default) shows hidden nodes; `false` filters
    /// dotfile/UF_HIDDEN nodes from layout, their mass reported as `hiddenFilteredBytes`.
    private var includeHidden = true
    /// Area scale (deliverable 2): `.log` is the ratified DEFAULT (VISION: "logarithmically
    /// compressed by default"). The App's toggle flips it via `setScale`.
    private var scale: AreaScale = .log

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

    /// The scan root's id. MUTABLE since TZ-4b: `reRoot` promotes the pipeline one
    /// level up (rootId becomes the new parent), coherently with the reducer graft and
    /// the focus/settle reset. Written once at init otherwise.
    private var rootId: String
    private var reducer: ScanReducer
    /// Number of walker streams currently folding into this pipeline. `running` is
    /// derived from this so a SECOND concurrent walk — the sibling-exclusion walk root
    /// promotion spawns while the original walk may still be draining — does not let the
    /// first walk's completion falsely report the scan finished. A walk increments on
    /// entry to `ingest` and decrements on exit; `running == (activeWalks > 0)`.
    private var activeWalks = 0
    // REMOVED (TZ-4b review-4 change 4): the `requestedDetailDepth` parameter/state. Since the
    // focus-rooted projection (OPERATOR_NOTE #2), `emit` always projects a FIXED `renderWindow`
    // from the focus, so a requested depth never reached `makeTree` — it was functionally inert
    // (its only effect was a re-emit trigger, and in the App the requested depth was a pure
    // function of the focus, so it never changed without the focus also changing). A name that
    // claims to "request detail" while only re-emitting is a name-honesty defect (CLAUDE.md 5);
    // the honest fix is to delete it, not rename it. `setFocus` now simply posts the focus and
    // emits its scene immediately (see below).
    private var focusId: String
    private var viewport: Rect?
    private var running = true
    /// The reducer changed since the last emitted scene — a cadence tick emits only
    /// when dirty (calm, batched); an immediate emit (focus/viewport) ignores it.
    private var dirty = true
    private var generation = 0

    // NOTE (TZ-4b, HUMAN FIELD RULING #1): the pipeline no longer holds volume accounting.
    // The synthetic UNACCOUNTED tile it fed was removed (a volume quantity drawn inside a
    // subtree map — a category error); the "Unaccounted" figure is now a STATUS-BAR field
    // the App composes from `VolumeProbe` + `scannedBytes` (see `UnaccountedSpace`). So the
    // pipeline composes tiles from the SizeTree ONLY — no capacity/free/purgeable state.

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

    public init(rootId: String, rootName: String) {
        self.rootId = rootId
        self.focusId = rootId
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
        activeWalks += 1
        running = true
        await foldWithPreemption(stream)
        activeWalks -= 1
        if activeWalks == 0 { running = false } // last walk to drain marks the scan done
        emit(force: true) // final settle — reflects everything folded
    }

    /// Number of events folded between focus-preemption points. See `foldWithPreemption`.
    private static let ingestChunk = 2048

    /// Fold `stream` into the reducer WITH FOCUS PREEMPTION (TZ-4b OPERATOR_NOTE #3.1 — the
    /// ratified queue-priority fix). The problem the escalate measured (worst focus
    /// commit→scene 1059 ms during a live 5M-inode scan): a `setFocus`/`setViewport` message
    /// is enqueued on THIS actor, but the fold holds the actor across long synchronous stretches
    /// and never suspends, so the focus emit waits behind the whole in-flight ingest. Actor
    /// isolation only lets another enqueued message run at a SUSPENSION point; a tight
    /// `for await batch { reducer.apply(batch) }` loop over an already-buffered stream, or one
    /// giant `apply`, has none for long spans.
    ///
    /// THE MECHANISM (the operator's "chunk ingest folds and check a pending-focus flag between
    /// chunks"): fold each batch in fixed `ingestChunk`-sized slices and `await Task.yield()`
    /// between slices AND after each batch. Each yield is a suspension point that RE-ENQUEUES
    /// this fold BEHIND any already-pending actor message — so a queued `setFocus` (which
    /// force-emits synchronously) OVERTAKES the ingest and its target scene commits after at
    /// most one chunk's fold, not the whole stream. The actor's own mailbox IS the
    /// "pending-focus flag"; the yield is what drains it. Correctness is preserved: folding is
    /// order-INSENSITIVE across subtree batches (the reducer's interleaving-invariance
    /// property — file header), so deferring the rest of a batch past a focus emit changes
    /// nothing about the eventual state; the emit simply reflects a valid partial fold, exactly
    /// as any mid-scan cadence emit already does.
    private func foldWithPreemption(_ stream: AsyncStream<[ScanEvent]>) async {
        for await batch in stream {
            if batch.count <= Self.ingestChunk {
                reducer.apply(batch)
                dirty = true
            } else {
                var i = 0
                while i < batch.count {
                    let end = min(i + Self.ingestChunk, batch.count)
                    reducer.apply(Array(batch[i..<end]))
                    dirty = true
                    i = end
                    if i < batch.count { await Task.yield() } // let a queued focus emit overtake
                }
            }
            await Task.yield() // suspension point per batch: drains any pending focus/viewport message
        }
    }

    // MARK: - Root promotion (TZ-4b — "root promotion", ratified)

    /// PROMOTE the pipeline one level up (layers a+c of root promotion) and fold the new
    /// siblings — ONE atomic actor operation so the promoted frame and the successor-walk
    /// registration are inseparable (review-0 finding 1).
    ///
    /// THE RACE THIS FIXES. The previous split (`reRoot` force-emits, then a separate
    /// `ingest` of the siblings) let the promoted frame carry `running == false` whenever
    /// the PRIMARY walk had already drained (`activeWalks == 0`). The App reads that scene,
    /// concludes the scan is done, and tears down the cadence/hitch BEFORE the queued
    /// sibling ingest even starts — so an idle-time promotion never streams its siblings.
    /// Here the successor walk is REGISTERED (`activeWalks += 1`, `running = true`) BEFORE
    /// the promoted force-emit, with no `await` between, so the promoted frame — and every
    /// frame until the siblings truly drain — reports `running == true`. The counter stays
    /// symmetric: this one method owns the matching decrement when the fold completes.
    ///
    /// The re-root itself (COHERENT with the focus/settle reset):
    ///   - `reducer.reRoot` grafts the whole node map under `newRootId` (nothing lost);
    ///   - `rootId`/`focusId` move to the new root (we always land focused on it);
    ///   - the old subtree, now at depth 1, folds beyond the render window but keeps its full
    ///     totals (sizes true — the projection window is a render choice, not a data limit);
    ///   - `lastQuadById` is cleared: the pre-promotion positions are a meaningless
    ///     same-focus settle source across a root change (the App drives the commit morph
    ///     from the promotion camera's last frame instead, exactly as for a dive/ascend).
    /// `generation` is NOT reset — scene generations stay strictly monotonic across the
    /// promotion. Force one emit so the promoted frame appears without waiting a cadence;
    /// the NEW siblings then stream in through the `sibling` walk this method folds.
    /// (No volume accounting is threaded through anymore — HUMAN FIELD RULING #1 moved the
    /// "Unaccounted" figure to the status bar; the App re-reads it per-promotion itself.)
    public func promote(newRootId: String, newRootName: String,
                        sibling: AsyncStream<[ScanEvent]>) async {
        activeWalks += 1
        running = true
        reducer.reRoot(to: newRootId, newRootName: newRootName)
        rootId = newRootId
        focusId = newRootId
        lastQuadById.removeAll(keepingCapacity: true)
        dirty = true
        emit(force: true) // promoted frame — running == true (a successor walk is committed)

        await foldWithPreemption(sibling)
        activeWalks -= 1
        if activeWalks == 0 { running = false } // last walk to drain marks the scan done
        emit(force: true) // final settle at the promoted root
    }

    // MARK: - Denied-overflow disclosure (TZ-4b OPERATOR_NOTE #3.2; review-5 correction)

    /// Resolve a clicked denied-overflow AGGREGATE badge to its disclosure — the denied child
    /// names + implied (lower-bound) size — ON THIS ACTOR, off main.
    ///
    /// WHY THIS MOVED OFF MAIN (review-5, blocking). The App used to resolve the badge on the
    /// main actor by walking the emitted scene tree: `latestScene.tree.node(withId: parentId)`
    /// (an O(retained-in-window) traversal) followed by `TreemapScene.deniedDisclosure` over the
    /// parent's children (O(parent fanout)). Both scale with node/child count and so violate the
    /// ratified main-thread law and `SizeTree.node(withId:)`'s own documented contract ("must
    /// NEVER run on the main actor"). A high-fanout denied parent could stall interaction while
    /// opening its disclosure — exactly the fluid-navigation regression the VISION forbids.
    ///
    /// THE ACTOR-SIDE PATH. The badge carries no id list; its parent id is recovered from the
    /// synthetic nodeId (`deniedAggregateParentId`). We then project ONLY that parent ONE level
    /// from the RETAINED reducer state (`makeTree(focusId: parentId, depthWindow: 1)` — the
    /// parent plus its direct children, O(parent fanout), no `SizeTree` main traversal) and run
    /// the PURE `TreemapScene.deniedInventory` over it (contract v2: the parent's FULL denied
    /// inventory, not only the aggregate's collapsed subset — see TreemapScene doc). Returns `nil` if the parent is not in the
    /// retained state (a stale badge after a re-root); the App then shows a count-only fallback
    /// from the tile itself. The result is a raw `DeniedDisclosure` DTO, `Sendable` back to main.
    /// This is the ratified "a `ScenePipeline` actor operation over its reducer, returning raw
    /// disclosure data for the App to present." User-driven and once-per-click — never the frame
    /// hot path — and now provably off main.
    public func deniedDisclosure(aggregateNodeId: String) -> DeniedDisclosure? {
        guard let parentId = TreemapScene.deniedAggregateParentId(from: aggregateNodeId),
              reducer.contains(parentId) else { return nil }
        let parentTree = reducer.makeTree(focusId: parentId, depthWindow: 1)
        return TreemapScene.deniedInventory(under: parentTree)
    }

    // MARK: - Control inputs (posted by the App's main actor)

    /// Cadence trigger: emit a fresh scene iff the reducer changed since the last one.
    public func tick() {
        emit(force: false)
    }

    /// Post the current focus (dive/ascend) and emit its target scene IMMEDIATELY, so the
    /// App's camera commit does not wait a cadence. An explicit focus post is a request for
    /// that focus's scene now, so it force-emits unconditionally (the immediate-emit path the
    /// App and the pipeline tests rely on). Only a genuine focus CHANGE invalidates the
    /// same-focus settle source (the previous focus's tile positions); re-posting the SAME
    /// focus keeps it so a redundant post still morphs cleanly from the last frame.
    public func setFocus(_ id: String) {
        if id != focusId {
            focusId = id
            lastQuadById.removeAll(keepingCapacity: true)
        }
        emit(force: true)
    }

    /// New viewport (resize) — re-fit and emit immediately.
    public func setViewport(_ vp: Rect) {
        guard vp != viewport else { return }
        viewport = vp
        emit(force: true)
    }

    // MARK: - TZ-5 lens setters (each re-projects immediately, off main)

    /// Post the IGNORE set (deliverable 1). A no-op emit is skipped when the set is unchanged so a
    /// redundant push (e.g. on a new-scan reset) does not churn a scene.
    public func setIgnored(_ ids: Set<String>) {
        guard ids != ignoredIds else { return }
        ignoredIds = ids
        emit(force: true)
    }

    /// Post the show-hidden lens (deliverable 3).
    public func setIncludeHidden(_ include: Bool) {
        guard include != includeHidden else { return }
        includeHidden = include
        emit(force: true)
    }

    /// Post the area scale (deliverable 2).
    public func setScale(_ s: AreaScale) {
        guard s != scale else { return }
        scale = s
        emit(force: true)
    }

    /// Post the depth window (deliverable 4). Clamped to ≥ 1 (the focus plus at least one level);
    /// a non-positive window would render only the focus background — never useful.
    public func setDepthWindow(_ n: Int) {
        let w = max(1, n)
        guard w != renderWindow else { return }
        renderWindow = w
        emit(force: true)
    }

    // MARK: - Scene construction (the node-count-scaling work, off main)

    private func emit(force: Bool) {
        guard force || dirty else { return }
        guard let vp = viewport, vp.width > 0, vp.height > 0 else { return }
        // Never fabricate a scene for a focus the scan has not produced — keep the last good
        // scene (the streaming contract). Under the OLD root-rooted projection the empty
        // layout below did this implicitly; a focus-rooted projection would instead build a
        // lone placeholder tile, so the guard is now explicit (see `ScanReducer.contains`).
        guard reducer.contains(focusId) else { return }

        // FOCUS-ROOTED PROJECTION (TZ-4b, OPERATOR_NOTE 2026-08-16 #2). Project ONLY the
        // focus subtree through the render window — O(focus subtree ∩ window) — instead of
        // building the whole retained tree and letting layout navigate down to the focus
        // (the O(retained nodes) cost that made a full-volume dive take seconds). The
        // projected tree's root IS the focus, so `TreemapScene.layout`'s focus lookup below
        // resolves at the root in O(1) rather than searching the whole tree.
        // The projected tree IS the scene's tree — no synthetic UNACCOUNTED tile is
        // injected anymore (HUMAN FIELD RULING #1: it was a volume quantity drawn inside a
        // subtree map; the figure moved to the status bar, `UnaccountedSpace`). The status
        // bar's "Scanned" total still comes from `reducer.rootAllocatedBytes`, never from
        // this focus-rooted tree's root.
        // AREA-BOUNDED focus-rooted projection (TZ-4b cycle-6): pass the viewport area + the
        // sub-pixel threshold so `makeRenderTree` skips subtrees too small to render. This makes
        // even a VOLUME-ROOT emit O(visible tiles), not O(all-in-window) — the ~900 ms root
        // projection the live measurement caught (24k materialized sub-pixel nodes) collapses to
        // the visible set. The pruned subtrees are exactly those the cull below would drop, so
        // the rendered scene is unchanged, and `prunedBelowArea` is folded into `belowPixelCount`
        // so the drop is never SILENT (invisible-space contract).
        // TZ-5 LENSES applied HERE (off main): the ignore set + show-hidden filter drop nodes so
        // siblings renormalize (makeRenderTree). COHERENCE OF SCALE IS ENFORCED HERE, at the one
        // module that imports both cores (review-1 change 3): this composition layer hands the
        // reducer projection `scale.weight` (a bare `(bytes) -> weight` function — ScanCore stays
        // ignorant of linear vs log) AND hands `TreemapScene.layout` the same `scale` enum below,
        // so the pruned set and the Squarify partition agree by construction (a pruned tail tile is
        // one the same-weighted layout would also cull — never a grown-but-empty tile). The
        // `AreaScale` policy lives in TreemapCore; the pipeline is where it meets the scan side.
        let (tree, prunedBelowArea, hiddenFilteredBytes) = reducer.makeRenderTree(
            focusId: focusId, depthWindow: renderWindow,
            minRenderArea: Self.minRenderAreaPx, viewportArea: vp.area,
            excluding: ignoredIds, includeHidden: includeHidden, weight: scale.weight)
        // IGNORE accounting (review-0 change 2): the EXACT excluded UNION mass + each ignored id's
        // current retained total, from CURRENT reducer state — recomputed every emit so the
        // status figure and the panel rows stay honest while the scan streams and never
        // double-count overlapping ancestor/descendant ignores. O(ignored × chain-depth), on the
        // actor. Empty/zero when nothing is ignored (the common case — no allocation cost).
        let ignoreAcct = reducer.ignoreAccounting(ignoredIds)
        let laidOut = TreemapScene.layout(tree: tree, focusId: focusId,
                                          depthWindow: renderWindow, viewport: vp, scale: scale)
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
        // BADGES ARE NOT EXEMPTED (TZ-4b rider 1, corrected review-0 finding 3c). A
        // `denied` tile's size is UNKNOWN, so `TreemapScene` FLOORS its layout
        // area to `minBadgeArea` (~384 px² ≫ this ~4 px² cull threshold) — which lifts it
        // above the ordinary cull WITHOUT a special case here. The earlier exemption
        // (`|| kind == .denied`) let EVERY badge bypass the cull regardless
        // of area, so a level with pathologically many unknown-size children could retain
        // an unbounded count — defeating the viewport bound below (the main-thread law).
        // Now the layout caps how many badges are floored (see `maxBadgeFraction`), the
        // rest keep their sub-pixel weight, and the plain area test culls them like any
        // tile: the per-level count stays viewport-bounded, badges included.
        var tiles = [TileRect](); tiles.reserveCapacity(laidOut.count)
        for t in laidOut where t.dimLevel == 0 || t.rect.area >= Self.minRenderAreaPx {
            tiles.append(t)
        }
        // Total below-threshold drops = those pruned at PROJECTION (never materialized) + any the
        // layout still produced that this pass culls. Folding both keeps the count honest (no
        // silent truncation) even though most sub-pixel mass is now pruned before layout.
        let belowPixelCount = prunedBelowArea + (laidOut.count - tiles.count)

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
            labels: labels, tree: tree, belowPixelCount: belowPixelCount, running: running,
            filesProcessed: reducer.processedCount,
            // Scan-root total (cheap Int64 sum), NOT the focus tree's root — see
            // `RenderScene.scannedBytes` / `ScanReducer.rootAllocatedBytes`.
            scannedBytes: reducer.rootAllocatedBytes,
            scaleMode: scale, hiddenFilteredBytes: hiddenFilteredBytes,
            ignoredBytes: ignoreAcct.total, ignoredCurrentById: ignoreAcct.currentById))
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
