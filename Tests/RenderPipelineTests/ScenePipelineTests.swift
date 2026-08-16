//
//  ScenePipelineTests.swift — the background pipeline's threading guarantees.
//  Module maturity: PROTOTYPE (slice TZ-3b)
//
//  The ratified threading model (PLAN §"Threading model") stands on two properties
//  of the serial background actor. These pin them WITHOUT the filesystem or AppKit,
//  by feeding a synthetic `AsyncStream<[ScanEvent]>` (exactly the shape the real
//  walker emits) and driving the actor directly:
//
//    1. A SLOW CONSUMER NEVER BLOCKS THE WALKER. We yield many batches, finish the
//       stream, and consume NO scenes until after ingest completes — then assert the
//       final scene reflects EVERY folded batch. If scene emission back-pressured
//       the fold (the beachball failure mode), ingest could not have drained the
//       whole stream while nobody read scenes.
//    2. SCENE GENERATIONS ARRIVE IN ORDER. Across a run, collected scenes are
//       strictly increasing in `generation` — the newest-1 buffer may DROP scenes
//       under a slow reader but never REORDER them.
//

import XCTest
import ScanCore
import TreemapCore
@testable import RenderPipeline

final class ScenePipelineTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 1000, height: 700)

    /// N direct children of the root, each a file of `perChild` bytes. Emitted as N
    /// separate batches so "fold them all" is a real multi-batch drain.
    private func childBatches(rootId: String, n: Int, perChild: Int64) -> [[ScanEvent]] {
        var out: [[ScanEvent]] = []
        out.append([.sizeUpdated(nodeId: rootId, allocated: 0, logical: 0)])
        let stubs = (0..<n).map { ChildStub(id: "\(rootId)/c\($0)", name: "c\($0)", kind: .file) }
        out.append([.childrenDiscovered(parentId: rootId, children: stubs)])
        for i in 0..<n {
            out.append([.sizeUpdated(nodeId: "\(rootId)/c\(i)", allocated: perChild, logical: perChild)])
        }
        out.append([.subtreeCompleted(nodeId: rootId)])
        return out
    }

    // MARK: - 1. Slow consumer never blocks the walker

    func testSlowConsumerNeverBlocksTheFold() async {
        let rootId = "/r"
        let n = 500
        let perChild: Int64 = 7
        let pipe = ScenePipeline(rootId: rootId, rootName: "r", projectionDepth: 10)
        await pipe.setViewport(viewport)

        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)

        // Start folding. NOTHING consumes `pipe.scenes` yet.
        let ingestTask = Task { await pipe.ingest(stream) }

        // Yield every batch, then finish. On a newest-1 scene buffer with no reader,
        // none of this can block on scene emission.
        for batch in childBatches(rootId: rootId, n: n, perChild: perChild) {
            cont.yield(batch)
        }
        cont.finish()

        // Ingest drains the whole stream and force-emits a final scene — even though
        // no scene was ever consumed during the fold.
        await ingestTask.value

        // Now read the (buffered newest) final scene: it must reflect ALL n children.
        var final: RenderScene?
        for await scene in pipe.scenes { final = scene; break }
        guard let final else { return XCTFail("pipeline produced no scene after draining the stream") }

        XCTAssertFalse(final.running, "stream finished ⇒ scan not running")
        XCTAssertEqual(final.scannedBytes, Int64(n) * perChild,
                       "final scene must reflect every folded batch — the fold was not back-pressured by a slow consumer")
        XCTAssertEqual(final.tree.children.count, n, "all discovered children present in the projected tree")
    }

    // MARK: - 2. Generations strictly increasing

    func testSceneGenerationsAreStrictlyIncreasing() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r", projectionDepth: 10)
        await pipe.setViewport(viewport)

        // Collect scenes concurrently with driving the actor.
        let collector = Task { () -> [Int] in
            var gens: [Int] = []
            for await scene in pipe.scenes {
                gens.append(scene.generation)
                if !scene.running { break } // stop after the final settle scene
            }
            return gens
        }

        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }

        // Interleave data with cadence ticks and a focus change → several emits.
        let batches = childBatches(rootId: rootId, n: 6, perChild: 3)
        for (i, batch) in batches.enumerated() {
            cont.yield(batch)
            await pipe.tick()                       // cadence emit (if dirty)
            if i == 2 { await pipe.setFocus(rootId, projectionDepth: 10) } // immediate emit path
        }
        cont.finish()
        await ingestTask.value

        let gens = await collector.value
        XCTAssertFalse(gens.isEmpty, "expected at least the final scene")
        for i in 1..<gens.count {
            XCTAssertGreaterThan(gens[i], gens[i - 1],
                                 "scene generations must arrive strictly increasing (newest-1 may drop, never reorder): \(gens)")
        }
    }

    // MARK: - 3. A scene is withheld until the viewport is known, then emitted

    func testSceneWithheldUntilViewportThenEmitted() async {
        let pipe = ScenePipeline(rootId: "/r", rootName: "r", projectionDepth: 10)

        // Fold a complete tree BEFORE any viewport is set: nothing can be laid out,
        // so no scene may be emitted (the honest "hold last frame" behavior).
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        for batch in childBatches(rootId: "/r", n: 3, perChild: 5) { cont.yield(batch) }
        cont.finish()
        await ingestTask.value

        // Now the viewport arrives — its immediate emit lays out the already-folded
        // tree and yields exactly the settled scene.
        await pipe.setViewport(viewport)
        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("no scene after viewport arrived") }
        XCTAssertEqual(scene.tree.children.count, 3, "the withheld tree lays out once the viewport is known")
        XCTAssertFalse(scene.tiles.isEmpty)
        XCTAssertFalse(scene.running, "the scan had already completed before the viewport arrived")
    }

    // MARK: - 4. The FIRST scene's settle-from is a snap (settleFrom == quads)

    /// The streaming settle "from" is built ON THE ACTOR (removing the 158 ms main-side
    /// String match). Its contract: index-parallel with `quads`, and for the FIRST emit
    /// (no previous scene) every entry is the tile's OWN quad — a snap, no fly-in. We
    /// pin this on a single, drop-free emit: fold a complete tree, THEN set the viewport
    /// (the withheld-then-emit path), which yields exactly one scene — the pipeline's
    /// first — so `lastQuadById` is empty and settleFrom must equal quads.
    func testFirstSceneSettleFromIsSnap() async {
        let pipe = ScenePipeline(rootId: "/r", rootName: "r", projectionDepth: 10)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        for batch in childBatches(rootId: "/r", n: 8, perChild: 40) { cont.yield(batch) }
        cont.finish()
        await ingestTask.value

        await pipe.setViewport(viewport)
        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("no scene after viewport arrived") }

        XCTAssertEqual(scene.settleFrom.count, scene.quads.count,
                       "settleFrom is index-parallel with quads")
        XCTAssertEqual(scene.settleFrom, scene.quads,
                       "the first scene has no predecessor ⇒ settleFrom == quads (a snap, not a fly-in)")
    }

    // MARK: - 5. Sub-pixel tiles are culled off main (bounded by viewport, not tree)

    /// One big grandchild + four sub-pixel grandchildren under a single child. The tiny
    /// tiles (dimLevel 2, area ≪ the cull threshold) must be dropped from the rendered
    /// scene and COUNTED in `belowPixelCount` (no silent truncation), while the focus,
    /// the top-level child (dimLevel ≤ 1), and the big grandchild survive. This is what
    /// keeps every main-side array bounded by the viewport rather than the node count.
    func testSubPixelTilesAreCulledAndCounted() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r", projectionDepth: 10)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }

        let tinies = (1...4).map { ChildStub(id: "\(rootId)/A/g\($0)", name: "g\($0)", kind: .file) }
        let g0 = ChildStub(id: "\(rootId)/A/g0", name: "g0", kind: .file)
        var events: [ScanEvent] = [
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId,
                                children: [ChildStub(id: "\(rootId)/A", name: "A", kind: .dir)]),
            .childrenDiscovered(parentId: "\(rootId)/A", children: [g0] + tinies),
            .sizeUpdated(nodeId: "\(rootId)/A/g0", allocated: 1_000_000, logical: 1_000_000),
        ]
        for t in tinies { events.append(.sizeUpdated(nodeId: t.id, allocated: 1, logical: 1)) }
        events.append(.subtreeCompleted(nodeId: rootId))
        cont.yield(events)
        cont.finish()
        await ingestTask.value

        await pipe.setViewport(viewport) // one emit — deterministic, no newest-1 drop
        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("no scene after viewport arrived") }

        let ids = Set(scene.tiles.map { $0.nodeId })
        XCTAssertEqual(scene.belowPixelCount, 4, "the four sub-pixel grandchildren are culled and counted")
        XCTAssertTrue(ids.isSuperset(of: [rootId, "\(rootId)/A", "\(rootId)/A/g0"]),
                      "focus, top-level child, and the big grandchild survive culling")
        for t in tinies {
            XCTAssertFalse(ids.contains(t.id), "sub-pixel tile \(t.id) is not rendered")
        }
        XCTAssertEqual(scene.quads.count, scene.tiles.count, "quads are 1:1 with the culled tiles")
    }

    // MARK: - 6. Sub-pixel TOP-LEVEL tiles are culled too → render bounded by viewport

    /// The structural main-thread bound (review-2 item 1). A focus with MANY direct
    /// children, all but one sub-pixel: the pre-fix `dimLevel <= 1` cull exemption would
    /// have RETAINED every one of them, so the main-side arrays (quads/nodeIds/commit &
    /// embed alignment) scaled with the child COUNT. With only dimLevel 0 exempt, every
    /// sub-pixel top-level tile is culled and counted, so the rendered-tile count is
    /// bounded by viewport/threshold regardless of how many children the focus has. Also
    /// pins that `nodeIds` is PREBUILT on the actor, index-parallel with tiles and quads.
    func testSubPixelTopLevelTilesAreCulledSoRenderStaysViewportBounded() async {
        let rootId = "/r"
        let n = 300
        let pipe = ScenePipeline(rootId: rootId, rootName: "r", projectionDepth: 10)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }

        let big = ChildStub(id: "\(rootId)/big", name: "big", kind: .file)
        let tinies = (0..<n).map { ChildStub(id: "\(rootId)/t\($0)", name: "t\($0)", kind: .file) }
        var events: [ScanEvent] = [
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId, children: [big] + tinies),
            .sizeUpdated(nodeId: big.id, allocated: 1_000_000, logical: 1_000_000),
        ]
        for t in tinies { events.append(.sizeUpdated(nodeId: t.id, allocated: 1, logical: 1)) }
        events.append(.subtreeCompleted(nodeId: rootId))
        cont.yield(events)
        cont.finish()
        await ingestTask.value

        await pipe.setViewport(viewport)
        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("no scene after viewport arrived") }

        let ids = Set(scene.nodeIds)
        XCTAssertTrue(ids.contains(rootId), "the focus (dimLevel 0) always survives")
        XCTAssertTrue(ids.contains(big.id), "the one above-threshold top-level tile survives")
        XCTAssertEqual(scene.belowPixelCount, n,
                       "all \(n) sub-pixel TOP-LEVEL (dimLevel 1) tiles are culled and counted")
        XCTAssertLessThan(scene.tiles.count, 10,
                          "rendered tile count is bounded by the viewport, not the \(n) direct children")
        XCTAssertEqual(scene.nodeIds, scene.tiles.map { $0.nodeId },
                       "prebuilt nodeIds are index-parallel with tiles (built on the actor, not on main)")
        XCTAssertEqual(scene.nodeIds.count, scene.quads.count, "nodeIds are index-parallel with quads")
    }
}
