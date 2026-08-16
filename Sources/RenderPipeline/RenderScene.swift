//
//  RenderScene.swift — the immutable value that crosses the pipeline→main boundary.
//  Module maturity: PROTOTYPE (slice TZ-3b)
//
//  THE ONE VALUE HANDOFF (PLAN §"Threading model (ratified 2026-08-16)").
//  The background `ScenePipeline` actor does the whole node-count-scaling job —
//  reduce → makeTree → squarify → label — and packages the finished result as ONE
//  of these. Main receives it and does only input, camera animation, Metal encode,
//  and label application. Nothing main touches here scales with node count: the
//  tiles are already positioned, the labels already composed.
//
//  It is a RAW value DTO (CLAUDE.md: data crossing a boundary is a simple value,
//  never a framework object): TileRect/Rect/SceneLabel (TreemapCore) + SizeTree
//  (ScanCore) + Int/String/Bool. No AppKit, no Metal, no closures. `Sendable` so it
//  crosses the actor boundary by value; `Equatable` so tests can pin scene content.
//
//  WHY `tree` RIDES ALONG (TZ-3b, review-3 item 1). The renderer needs only
//  `tiles`/`quads`. The hover readout and right-click menu NO LONGER traverse the
//  tree on main — TileRect now carries the display metadata (name + allocated/logical
//  bytes) they need, denormalized on the actor at layout time, so those lookups touch
//  only the viewport-bounded rendered tile the user is on (the ratified law forbids
//  main work that scales with node count). `tree` rides along now only for the O(1)
//  `scannedBytes` (root allocated) the status bar shows, and to let the pipeline test
//  introspect the projected structure. It stays a raw value; nothing on main walks it.
//
//  ABSTRACTION LEDGER: `RenderScene`/`SceneLabel` are DTOs, not abstractions —
//  concrete current users: `ScenePipeline` (producer) and the App's ScanController/
//  NavigationController (consumers). No protocol, no variation axis; the rejected
//  alternative (hand main the raw SizeTree + focus and let it squarify) IS the
//  beachball defect this slice removes.
//

import Foundation
// RenderPipeline is a SEPARATE SPM module (Package.swift) that imports the two
// pure cores; under the App's swiftc monolith (build.sh) those cores compile into
// the SAME module, so `canImport` is false there and the types resolve same-module.
// Same one-guard pattern TreemapScene.swift uses across the two build worlds.
#if canImport(ScanCore)
import ScanCore
#endif
#if canImport(TreemapCore)
import TreemapCore
#endif

/// One top-level tile's overlay label, pre-composed on the pipeline (name + human
/// size). Rect is DEVICE PIXELS (the tile layout space); the App converts to points
/// and clips/hides below the minimum width. Composing the text here (off main) is
/// what keeps per-cadence label building off the main thread.
public struct SceneLabel: Equatable, Sendable {
    public let rect: Rect
    public let text: String
    public init(rect: Rect, text: String) {
        self.rect = rect
        self.text = text
    }
}

/// A complete, immutable frame description built entirely on the background
/// pipeline. Everything positioned; nothing left for main to compute per node.
public struct RenderScene: Equatable, Sendable {
    /// Monotonically increasing across a pipeline's lifetime. Lets main order scenes
    /// and detect staleness; the pipeline-actor test pins that these arrive strictly
    /// increasing even under a slow consumer (older scenes are dropped, never
    /// reordered — the AsyncStream buffers newest-1).
    public let generation: Int
    /// The focus this scene was laid out for. Under the live scan a node id IS its
    /// absolute path, so this doubles as the breadcrumb text. Main presents a scene
    /// only when its `focusId` matches the current focus (a scene laid out for an
    /// old focus, in flight when the user dived, is ignored).
    public let focusId: String
    /// The viewport (device px) this layout fits. Carried so main can detect a scene
    /// laid out for a stale viewport after a resize.
    public let viewport: Rect
    /// The squarified tiles for `focusId` at `viewport` — already positioned. Kept
    /// for the main-side USER-DRIVEN hit-test (hover/click resolve a cursor to a
    /// tile's nodeId); the RENDER path never reads these — it reads `quads`.
    public let tiles: [TileRect]
    /// The tiles' nodeIds, index-parallel with `tiles`/`quads`, PREBUILT here on the
    /// actor. Main used to derive this with `scene.tiles.map { $0.nodeId }` on every
    /// present (review-2: a per-node map on the main actor); carrying it prebuilt lets
    /// the App install a `DisplaySnapshot` with ZERO per-tile work on main. It also
    /// feeds the navigation-handoff geometry (`QuadGeometry.commitFrom`/`embedChild`),
    /// which needs the id list aligned to the quads. Bounded by the viewport (post-cull),
    /// never by node count.
    public let nodeIds: [String]
    /// The render-ready GPU instances for `tiles`, built OFF MAIN (QuadBuilder) —
    /// 1:1 and index-parallel with `tiles`. The App memcpy's these into an MTLBuffer
    /// and draws them; no per-tile colour/geometry conversion survives on main
    /// (PLAN §"Threading model" law; OPERATOR_NOTE gap 1).
    public let quads: [GPUQuad]
    /// The STREAMING settle "from": for a same-focus cadence update, where each of
    /// `quads` sat in the PREVIOUS emitted scene — index-parallel with `quads`, so the
    /// App uploads it straight as the settle-morph source with ZERO alignment on main
    /// (this is what used to be `CanvasView.currentDisplayedById`, the 158 ms path the
    /// reviewer flagged; the String-keyed identity match now runs on the pipeline
    /// actor). A node absent from the previous scene carries its OWN quad here (from ==
    /// to ⇒ it appears in place, no fly-in). The FIRST scene at a focus has
    /// settleFrom == quads (no previous), i.e. a snap. Not used on the camera/commit
    /// path — a dive/ascend commit builds its own from from the camera's last frame
    /// (NavigationController), because only main knows the live camera.
    public let settleFrom: [GPUQuad]
    /// Pre-composed top-level labels (dimLevel 1 tiles).
    public let labels: [SceneLabel]
    /// The projected tree. Main uses it ONLY for the O(1) `scannedBytes` (root
    /// allocated); hover/menu read denormalized TileRect metadata instead of walking
    /// it (review-3 item 1). Also lets the pipeline test introspect the projected
    /// structure. Never traversed on main, never used for layout.
    public let tree: SizeTree
    /// How many laid-out tiles were dropped as sub-pixel before this scene was built
    /// (PLAN §"Rendering scale": "cull rects < ~2 px … no silent truncation"). Carried
    /// so the count is REPORTABLE (status line / evidence), never silently swallowed —
    /// the invisible-space principle applied to below-pixel mass. The culling itself
    /// runs on the pipeline actor, and is what keeps every main-side array here bounded
    /// by the VIEWPORT rather than the tree's node count (the ratified main-thread law).
    public let belowPixelCount: Int
    /// Whether the scan is still streaming (drives the status indicator).
    public let running: Bool

    public init(generation: Int, focusId: String, viewport: Rect,
                tiles: [TileRect], nodeIds: [String], quads: [GPUQuad], settleFrom: [GPUQuad],
                labels: [SceneLabel], tree: SizeTree, belowPixelCount: Int,
                running: Bool) {
        self.generation = generation
        self.focusId = focusId
        self.viewport = viewport
        self.tiles = tiles
        self.nodeIds = nodeIds
        self.quads = quads
        self.settleFrom = settleFrom
        self.labels = labels
        self.tree = tree
        self.belowPixelCount = belowPixelCount
        self.running = running
    }

    /// Full recursive scanned total (root allocated) — the status bar's "Scanned".
    public var scannedBytes: Int64 { tree.allocatedBytes }
}
