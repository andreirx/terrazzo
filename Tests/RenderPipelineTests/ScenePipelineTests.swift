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
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
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
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
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
            if i == 2 { await pipe.setFocus(rootId) } // immediate emit path
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
        let pipe = ScenePipeline(rootId: "/r", rootName: "r")

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
        let pipe = ScenePipeline(rootId: "/r", rootName: "r")
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
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        // Pin the cull MECHANICS under LINEAR scale: this test is about which tiles the
        // pixel cull drops, not the default scale. Under the ratified LOG default the tail is
        // deliberately EXPANDED (fewer culls) — that behavior is exercised by the TreemapCore
        // scale tests; here we hold scale fixed so the exact culled count is deterministic.
        await pipe.setScale(.linear)
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
    // MARK: - 7. Root promotion: re-root keeps generations monotonic and replaces the root

    /// `promote` grafts the reducer up a level, force-emits the promoted frame, and folds
    /// the new siblings — all while scene generations stay STRICTLY increasing (the
    /// newest-1 buffer never reorders across the promotion). The final scene is rooted at
    /// the promoted parent with the old root grafted as a child.
    func testPromoteIsGenerationMonotonicAndReplacesRoot() async {
        let pipe = ScenePipeline(rootId: "/Users/apple", rootName: "apple")
        await pipe.setViewport(viewport)

        let collector = Task { () -> (gens: [Int], last: RenderScene?) in
            var gens: [Int] = []; var last: RenderScene?
            for await s in pipe.scenes {
                gens.append(s.generation); last = s
                // Break on the SETTLED promoted scan (the final emit): rooted at /Users,
                // not running, with the freshly-scanned sibling present.
                if s.tree.id == "/Users" && !s.running
                    && s.tree.children.contains(where: { $0.id == "/Users/shared" }) { break }
            }
            return (gens, last)
        }

        // Original scan of /Users/apple to completion.
        let (s1, c1) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingest1 = Task { await pipe.ingest(s1) }
        for b in childBatches(rootId: "/Users/apple", n: 3, perChild: 100) {
            c1.yield(b); await pipe.tick()
        }
        c1.finish()
        await ingest1.value

        // Promote to /Users: prefill+finish the sibling stream, then fold it via `promote`.
        let (s2, c2) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        c2.yield([
            .sizeUpdated(nodeId: "/Users", allocated: 0, logical: 0),
            .childrenDiscovered(parentId: "/Users", children: [
                ChildStub(id: "/Users/apple", name: "apple", kind: .dir),   // graft reference
                ChildStub(id: "/Users/shared", name: "shared", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "/Users/shared", allocated: 50, logical: 50),
            .subtreeCompleted(nodeId: "/Users/shared"),
            .subtreeCompleted(nodeId: "/Users"),
        ])
        c2.finish()
        await pipe.promote(newRootId: "/Users", newRootName: "Users", sibling: s2)

        let (gens, last) = await collector.value
        XCTAssertFalse(gens.isEmpty)
        for i in 1..<gens.count {
            XCTAssertGreaterThan(gens[i], gens[i - 1],
                                 "generations strictly increasing across the promotion: \(gens)")
        }
        XCTAssertEqual(last?.tree.id, "/Users", "the final scene is rooted at the promoted parent")
        let ids = Set(last?.tree.children.map(\.id) ?? [])
        XCTAssertTrue(ids.isSuperset(of: ["/Users/apple", "/Users/shared"]),
                      "old root grafted + new sibling scanned, both present")
    }

    // MARK: - 7b. Promotion after the primary drained stays running until siblings drain

    /// review-0 finding 1. When the primary walk has ALREADY completed (running=false), a
    /// promotion must NOT report the scan finished before its siblings stream — otherwise
    /// the App tears down the cadence/hitch and an idle-time promotion never paints its
    /// siblings. The promoted force-emit must carry running=true (a successor walk is
    /// committed), and running must stay true while a sibling update emits, flipping to
    /// false only when the sibling stream drains. We hold the sibling stream OPEN to
    /// observe the promoted frame deterministically (no final emit yet), then drain it.
    func testPromotionKeepsRunningTrueUntilSiblingsDrain() async {
        let pipe = ScenePipeline(rootId: "/Users/apple", rootName: "apple")
        await pipe.setViewport(viewport)

        // Primary scan of /Users/apple to completion → running becomes false.
        let (s1, c1) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingest1 = Task { await pipe.ingest(s1) }
        for b in childBatches(rootId: "/Users/apple", n: 2, perChild: 100) { c1.yield(b) }
        c1.finish()
        await ingest1.value

        // Promote with a sibling stream we keep OPEN. `promote` runs as its own task; its
        // FIRST act is the promoted force-emit, then it blocks awaiting `s2`.
        let (s2, c2) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let promoteTask = Task {
            await pipe.promote(newRootId: "/Users", newRootName: "Users", sibling: s2)
        }

        // Read forward to the promoted frame. With s2 still open, no final emit follows it,
        // so it is the settled buffer content.
        var iterator = pipe.scenes.makeAsyncIterator()
        var promoted: RenderScene?
        while let s = await iterator.next() {
            if s.focusId == "/Users" { promoted = s; break }
        }
        XCTAssertEqual(promoted?.running, true,
            "the promoted frame reports running=true — a successor walk is committed (finding 1)")
        XCTAssertTrue(promoted?.tree.children.contains { $0.id == "/Users/apple" } ?? false,
            "the promoted frame already shows the grafted old root")

        // Stream a sibling update while the walk is still open, then a cadence tick: the
        // emitted scene must STILL be running (the scan is not done until s2 finishes).
        c2.yield([
            .sizeUpdated(nodeId: "/Users", allocated: 0, logical: 0),
            .childrenDiscovered(parentId: "/Users", children: [
                ChildStub(id: "/Users/apple", name: "apple", kind: .dir),
                ChildStub(id: "/Users/shared", name: "shared", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "/Users/shared", allocated: 50, logical: 50),
        ])
        // Drain the sibling stream and let the promotion settle.
        c2.finish()
        await promoteTask.value

        // The FINAL scene (after the stream drained) reports running=false with the sibling.
        var final: RenderScene?
        while let s = await iterator.next() {
            if !s.running { final = s; break }
        }
        XCTAssertEqual(final?.running, false, "running flips to false only once the siblings drain")
        XCTAssertTrue(final?.tree.children.contains { $0.id == "/Users/shared" } ?? false,
            "the settled promotion shows the newly-scanned sibling")
    }

    // MARK: - 7c. Field regressions: deep-focus labels + focus continuity (finding 4)

    /// review-0 finding 4, regressions 1/3/4 as deterministic pipeline assertions:
    ///  (1) labels are present on the subfolders of a DEEP focus (~/Documents analog);
    ///  (3) after ascending back to the root, the root's children carry labels again;
    ///  (4) diving BEYOND the second level keeps focusing DEEPER — never restarts at top.
    /// (Regression 2, focus-relative re-tint, is pinned in TreemapSceneTests where the pure
    /// hue assignment lives.) Labels are the pipeline's `buildLabels` over the focus's
    /// dimLevel-1 children; a deeper focus emits its OWN children's labels.
    func testDeepFocusLabelsAndDiveContinuity() async {
        let root = "/r"
        let docs = "/r/Documents", sub = "/r/Documents/Sub", deep = "/r/Documents/Sub/Deep"
        let pipe = ScenePipeline(rootId: root, rootName: "r")

        // A deterministic 4-level chain, each level with two sizeable children so nothing
        // is sub-pixel culled: Documents/{Sub, note.txt}, Sub/{Deep, s.txt}, Deep/{d1,d2}.
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        cont.yield([
            .sizeUpdated(nodeId: root, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: root, children: [
                ChildStub(id: docs, name: "Documents", kind: .dir)]),
            .childrenDiscovered(parentId: docs, children: [
                ChildStub(id: sub, name: "Sub", kind: .dir),
                ChildStub(id: "\(docs)/note.txt", name: "note.txt", kind: .file)]),
            .sizeUpdated(nodeId: "\(docs)/note.txt", allocated: 5_000_000, logical: 5_000_000),
            .childrenDiscovered(parentId: sub, children: [
                ChildStub(id: deep, name: "Deep", kind: .dir),
                ChildStub(id: "\(sub)/s.txt", name: "s.txt", kind: .file)]),
            .sizeUpdated(nodeId: "\(sub)/s.txt", allocated: 5_000_000, logical: 5_000_000),
            .childrenDiscovered(parentId: deep, children: [
                ChildStub(id: "\(deep)/d1", name: "d1", kind: .file),
                ChildStub(id: "\(deep)/d2", name: "d2", kind: .file)]),
            .sizeUpdated(nodeId: "\(deep)/d1", allocated: 6_000_000, logical: 6_000_000),
            .sizeUpdated(nodeId: "\(deep)/d2", allocated: 4_000_000, logical: 4_000_000),
            .subtreeCompleted(nodeId: root),
        ])
        cont.finish()
        await ingestTask.value
        await pipe.setViewport(viewport)

        var iterator = pipe.scenes.makeAsyncIterator()
        // Force a focus emit and read the first scene at that focus.
        func sceneFocusing(_ id: String) async -> RenderScene? {
            await pipe.setFocus(id)
            while let s = await iterator.next() { if s.focusId == id { return s } }
            return nil
        }
        func labelTexts(_ s: RenderScene?) -> [String] { (s?.labels ?? []).map(\.text) }
        func labelsCover(_ s: RenderScene?, _ names: [String]) -> Bool {
            let texts = labelTexts(s)
            return names.allSatisfy { name in texts.contains { $0.contains(name) } }
        }

        // Regression 4: dive DEEPER, level by level — each focus is honored, never reset.
        let atDocs = await sceneFocusing(docs)
        XCTAssertEqual(atDocs?.focusId, docs, "focus follows the dive to level 1 (Documents)")
        // Regression 1: labels present on the deep focus's subfolders.
        XCTAssertTrue(labelsCover(atDocs, ["Sub", "note.txt"]),
                      "labels present on subfolders when focused deep (Documents): \(labelTexts(atDocs))")

        let atSub = await sceneFocusing(sub)
        XCTAssertEqual(atSub?.focusId, sub, "dive continues to level 2 (Sub) — not restarted at root")
        XCTAssertTrue(labelsCover(atSub, ["Deep", "s.txt"]), "labels present at level 2: \(labelTexts(atSub))")

        let atDeep = await sceneFocusing(deep)
        XCTAssertEqual(atDeep?.focusId, deep, "dive continues BEYOND the second level (Deep)")
        XCTAssertTrue(labelsCover(atDeep, ["d1", "d2"]), "labels present at level 3: \(labelTexts(atDeep))")

        // Regression 3: ascend back to the root — the root's children carry labels again.
        let atRoot = await sceneFocusing(root)
        XCTAssertEqual(atRoot?.focusId, root, "ascended back to the root focus")
        XCTAssertTrue(labelsCover(atRoot, ["Documents"]),
                      "labels present on the root's children after ascending back: \(labelTexts(atRoot))")
    }

    private static let renderWindowForTest = TreemapScene.defaultDepthWindow

    // MARK: - 8. A denied tile survives the sub-pixel cull at root scale (rider 1)

    /// The cycle-1 finding: a tiny denied subtree is sub-pixel at root scale and gets
    /// culled — invisible on the very map that exists to show it. A denied tile's size is
    /// UNKNOWN (a badge, not a measurement), so it is exempt from the cull AND floored to a
    /// minimum display area. Here one enormous folder dwarfs a denied dir of 1 byte; the
    /// denied tile must still be present and above the sub-pixel threshold.
    func testDeniedTileSurvivesCullAtRootScale() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        cont.yield([
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId, children: [
                ChildStub(id: "\(rootId)/big", name: "big", kind: .dir),
                ChildStub(id: "\(rootId)/locked", name: "locked", kind: .dir),
            ]),
            .sizeUpdated(nodeId: "\(rootId)/big", allocated: 1_000_000_000, logical: 1_000_000_000),
            .sizeUpdated(nodeId: "\(rootId)/locked", allocated: 1, logical: 1),
            .accessDenied(nodeId: "\(rootId)/locked"),
            .subtreeCompleted(nodeId: rootId),
        ])
        cont.finish()
        await ingestTask.value

        await pipe.setViewport(viewport)
        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("no scene after viewport arrived") }

        let deniedTile = scene.tiles.first { $0.nodeId == "\(rootId)/locked" }
        XCTAssertNotNil(deniedTile, "the denied tile is present at root scale regardless of its 1-byte size")
        XCTAssertEqual(deniedTile?.kind, .denied)
        XCTAssertGreaterThan(deniedTile!.rect.area, ScenePipeline.minRenderAreaPx,
                             "the denied badge reads — above the sub-pixel cull threshold")
    }

    // MARK: - 8b. Denied-overflow disclosure resolves ON THE ACTOR, off main (review-5)

    /// review-5 (blocking): the aggregate-disclosure lookup/filter/sort/sum MUST run on the
    /// pipeline actor, never on the main actor walking `RenderScene.tree` (which scales with
    /// retained/child count and violates `SizeTree.node(withId:)`'s "never on main" contract).
    /// This pins the ACTUAL actor-side path — `ScenePipeline.deniedDisclosure(aggregateNodeId:)`
    /// — with a HIGH-FANOUT denied parent (200 denied children + one readable child), proving the
    /// App receives the count (names), the names themselves (denied-only, sorted), and the implied
    /// LOWER-BOUND size WITHOUT any main-actor tree traversal: the call is actor-isolated (the
    /// `await` hops to the actor), and it projects only the parent's one level from the retained
    /// reducer state. Also pins the fallback contracts: a non-aggregate id and an unknown parent
    /// both return `nil` (the App then shows a count-only disclosure from the clicked tile).
    func testDeniedAggregateDisclosureResolvesOnActorForHighFanoutParent() async {
        let rootId = "/r"
        let parentId = "\(rootId)/Library"
        let n = 200
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }

        // A high-fanout parent: 200 DENIED children (each with a known own-entry size = the
        // lower bound) + one readable child that must be EXCLUDED from the denied disclosure.
        let deniedStubs = (0..<n).map { ChildStub(id: "\(parentId)/l\($0)", name: "l\($0)", kind: .dir) }
        let openChild = ChildStub(id: "\(parentId)/open", name: "open", kind: .dir)
        var events: [ScanEvent] = [
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId, children: [
                ChildStub(id: parentId, name: "Library", kind: .dir)]),
            .childrenDiscovered(parentId: parentId, children: deniedStubs + [openChild]),
            .sizeUpdated(nodeId: openChild.id, allocated: 9_999, logical: 9_999),
        ]
        for s in deniedStubs {
            events.append(.sizeUpdated(nodeId: s.id, allocated: 100, logical: 100)) // own entry (known)
            events.append(.accessDenied(nodeId: s.id))                              // contents unreadable
        }
        events.append(.subtreeCompleted(nodeId: rootId))
        cont.yield(events)
        cont.finish()
        await ingestTask.value

        // THE ACTOR-SIDE PATH: exactly what the App calls via ScanController. The badge's
        // synthetic id is parentId + the denied-aggregate suffix.
        let aggregateId = parentId + TreemapScene.deniedAggregateSuffix
        let disclosure = await pipe.deniedDisclosure(aggregateNodeId: aggregateId)

        XCTAssertNotNil(disclosure, "the actor resolves the aggregate from retained state")
        XCTAssertEqual(disclosure?.names.count, n,
                       "all \(n) denied children are disclosed (count = every denied fact, VISION)")
        XCTAssertFalse(disclosure?.names.contains("open") ?? true,
                       "the readable child is excluded from the denied disclosure")
        XCTAssertEqual(disclosure?.names, disclosure?.names.sorted(),
                       "names are sorted deterministically")
        XCTAssertEqual(disclosure?.impliedBytes, Int64(n) * 100,
                       "implied size is the sum of the denied dirs' KNOWN own-entry bytes (a lower bound)")

        // Fallback contracts (the App shows a count-only disclosure from the tile on nil):
        let notAggregate = await pipe.deniedDisclosure(aggregateNodeId: parentId) // no suffix
        XCTAssertNil(notAggregate, "a non-aggregate id resolves to nil")
        let unknown = await pipe.deniedDisclosure(
            aggregateNodeId: "\(rootId)/nope" + TreemapScene.deniedAggregateSuffix)
        XCTAssertNil(unknown, "an aggregate whose parent is not retained resolves to nil")
    }

    func testSubPixelTopLevelTilesAreCulledSoRenderStaysViewportBounded() async {
        let rootId = "/r"
        let n = 300
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        await pipe.setScale(.linear) // deterministic cull count — see the note in test 5
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

    // MARK: - 9. Focus commit → target scene from retained state, ≤ ~200 ms

    /// review-1 finding 3 / packet rider 2(b) + regression #5. A dive/ascend must produce the
    /// new focus's scene from ALREADY-RETAINED reducer state in ONE prioritized pipeline pass
    /// — target ≤ ~200 ms commit-to-scene — with NO filesystem work and NO bare flat-fill
    /// wait. We fold a broad, deep tree (40 dirs × 20 files) so makeTree→layout→cull→quad-build
    /// is real work, then change focus to a deep, already-scanned subfolder and MEASURE the
    /// wall time of the forced focus emit. `setFocus` force-emits SYNCHRONOUSLY on the actor,
    /// so this wall time IS the build+emit latency plus any actor-queue wait — the true
    /// commit-to-scene number. (The LIVE, still-scanning case is measured end-to-end on a real
    /// home tree by scripts/thread_host.swift's "WORST FOCUS COMMIT→SCENE latency" line; this
    /// unit test is the DETERMINISTIC gate the reviewer asked for.)
    func testFocusCommitToSceneLatencyFromRetainedState() async {
        let root = "/r"
        let pipe = ScenePipeline(rootId: root, rootName: "r")
        await pipe.setViewport(viewport)

        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        var events: [ScanEvent] = [.sizeUpdated(nodeId: root, allocated: 0, logical: 0)]
        let topStubs = (0..<40).map { ChildStub(id: "\(root)/d\($0)", name: "d\($0)", kind: .dir) }
        events.append(.childrenDiscovered(parentId: root, children: topStubs))
        for a in 0..<40 {
            let aId = "\(root)/d\(a)"
            let kids = (0..<20).map { ChildStub(id: "\(aId)/f\($0)", name: "f\($0)", kind: .file) }
            events.append(.childrenDiscovered(parentId: aId, children: kids))
            for b in 0..<20 {
                events.append(.sizeUpdated(nodeId: "\(aId)/f\(b)",
                                           allocated: Int64((b + 1) * 1_000_000),
                                           logical: Int64((b + 1) * 1_000_000)))
            }
        }
        events.append(.subtreeCompleted(nodeId: root))
        cont.yield(events)
        cont.finish()
        await ingestTask.value // full node map retained (decision 4)

        var iterator = pipe.scenes.makeAsyncIterator()
        let target = "\(root)/d7" // a deep, already-scanned subfolder (20 children retained)
        let t0 = DispatchTime.now().uptimeNanoseconds
        await pipe.setFocus(target)
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6

        var got: RenderScene?
        while let s = await iterator.next() { if s.focusId == target { got = s; break } }

        XCTAssertNotNil(got, "the focus change produced its target scene")
        XCTAssertEqual(got?.focusId, target, "the emitted scene is focused on the dived-into subfolder")
        // Children (rects) present from RETAINED state — never a bare flat fill (regression #5).
        XCTAssertGreaterThan(got?.tiles.filter { $0.dimLevel == 1 }.count ?? 0, 1,
                             "the target focus shows its retained children immediately, not a flat fill")
        print("TZLATENCY focus-commit-to-scene: \(String(format: "%.2f", ms)) ms (target \u{2264} ~200 ms)")
        XCTAssertLessThan(ms, 200.0,
            "focus commit-to-scene latency \u{2264} ~200 ms — the focus emit is one prioritized pipeline pass (rider 2b)")
    }

    // MARK: - 9b. Focus-rooted projection is scoped to the focus subtree (OPERATOR_NOTE #2)

    /// The cycle-3 escalate resolution (TZ-4b OPERATOR_NOTE 2026-08-16 #2). Before, every emit
    /// built the WHOLE retained tree from the scan root and let layout navigate down to the
    /// focus — O(retained nodes), measured at 6.9 s on a full-volume live dive (the field
    /// regression: a dive showed a flat fill for seconds). Now `makeTree` is focus-rooted, so
    /// a dive projects ONLY the focus subtree ∩ window. This pins the STRUCTURAL consequence
    /// (flake-free, unlike a pure timing gate): after diving into one small subfolder of a
    /// ~10k-node tree, the emitted scene's projected tree is rooted at the focus and holds
    /// only its ~101-node subtree — NOT the whole map. It also pins that `scannedBytes` stays
    /// the WHOLE scan-root total while focused on a subfolder (decoupled from the focus tree's
    /// root, which is now the focus). A ≤200 ms wall-clock guard rides along; the live
    /// full-volume number is scripts/thread_host.swift's "WORST FOCUS COMMIT→SCENE latency".
    ///
    /// SCALE IS CHOSEN DELIBERATELY: ~120,000 nodes — the EXACT scale at which build-2's
    /// deterministic measurement of the OLD root-rooted projection was 553 ms (120,600 nodes),
    /// the O(N) cost that drove the cycle-3 escalate. At the SAME scale the focus-rooted dive
    /// must be an order of magnitude under the 200 ms target, proving the escalation's
    /// diagnosed cause is gone — not merely improved.
    func testFocusRootedProjectionIsScopedToFocusSubtree() async {
        let root = "/r"
        let pipe = ScenePipeline(rootId: root, rootName: "r")
        await pipe.setViewport(viewport)

        // 300 top dirs × 400 files = 120,301 nodes. The OLD root-rooted projection materialized
        // ALL of them every emit (553 ms at this scale, build-2); the focus-rooted one builds
        // only the dived-into dir's ~401.
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        var events: [ScanEvent] = [.sizeUpdated(nodeId: root, allocated: 0, logical: 0)]
        let topStubs = (0..<300).map { ChildStub(id: "\(root)/d\($0)", name: "d\($0)", kind: .dir) }
        events.append(.childrenDiscovered(parentId: root, children: topStubs))
        var whole: Int64 = 0
        for a in 0..<300 {
            let aId = "\(root)/d\(a)"
            let kids = (0..<400).map { ChildStub(id: "\(aId)/f\($0)", name: "f\($0)", kind: .file) }
            events.append(.childrenDiscovered(parentId: aId, children: kids))
            for b in 0..<400 {
                let bytes = Int64((b + 1) * 1000)
                whole += bytes
                events.append(.sizeUpdated(nodeId: "\(aId)/f\(b)", allocated: bytes, logical: bytes))
            }
        }
        events.append(.subtreeCompleted(nodeId: root))
        cont.yield(events)
        cont.finish()
        await ingestTask.value // full ~120k-node map retained (decision 4)

        var iterator = pipe.scenes.makeAsyncIterator()
        let target = "\(root)/d137" // one small, already-scanned subfolder (400 children)
        let t0 = DispatchTime.now().uptimeNanoseconds
        await pipe.setFocus(target)
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6

        var got: RenderScene?
        while let s = await iterator.next() { if s.focusId == target { got = s; break } }
        guard let got else { return XCTFail("no scene at the dived focus") }

        // STRUCTURAL proof (deterministic): the projection is rooted at the focus and holds
        // only its subtree — this assertion FAILS on the old root-rooted projection (~120k).
        XCTAssertEqual(got.tree.id, target, "projection is rooted at the focus, not the scan root")
        XCTAssertLessThan(got.tree.nodeCount, 600,
            "focus-rooted projection holds only the focus subtree (~401), not the whole ~120k-node map")
        // "Scanned" stays the WHOLE scan-root total while focused on a subfolder.
        XCTAssertEqual(got.scannedBytes, whole,
            "scannedBytes stays the scan-root total under a focus-rooted (dived) projection")
        print("TZLATENCY focus-rooted dive on ~120k-node tree: \(String(format: "%.2f", ms)) ms (old root-rooted at this scale: 553 ms)")
        XCTAssertLessThan(ms, 200.0,
            "focus-rooted dive commits \u{2264} ~200 ms even on a full-volume-scale retained tree")
    }

    // MARK: - 10. Denied overflow → a single aggregate badge survives to the scene (#3.2)

    /// The composition-layer end of OPERATOR_NOTE #3.2. A focus with FAR more denied children
    /// than the small viewport can host as individual min-badges: the layer must emit EXACTLY
    /// ONE aggregate badge (surviving the sub-pixel cull) and represent every denied node, none
    /// silently dropped. Small viewport so `maxFloored` is small (≈17) and 100 denials overflow.
    func testDeniedOverflowAggregateSurvivesToSceneAtSmallScale() async {
        let smallVp = Rect(x: 0, y: 0, width: 120, height: 120)
        let rootId = "/r"; let n = 100
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        var events: [ScanEvent] = [.sizeUpdated(nodeId: rootId, allocated: 0, logical: 0)]
        let stubs = (0..<n).map { ChildStub(id: "\(rootId)/d\($0)", name: "d\($0)", kind: .dir) }
        events.append(.childrenDiscovered(parentId: rootId, children: stubs))
        for i in 0..<n {
            events.append(.sizeUpdated(nodeId: "\(rootId)/d\(i)", allocated: 1, logical: 1))
            events.append(.accessDenied(nodeId: "\(rootId)/d\(i)"))
        }
        events.append(.subtreeCompleted(nodeId: rootId))
        cont.yield(events); cont.finish()
        await ingestTask.value

        await pipe.setViewport(smallVp)
        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("no scene after viewport arrived") }

        let aggregates = scene.tiles.filter { $0.deniedAggregateCount > 0 }
        let singles = scene.tiles.filter { $0.kind == .denied && $0.deniedAggregateCount == 0 }
        XCTAssertEqual(aggregates.count, 1, "exactly one aggregate badge survives to the scene")
        XCTAssertEqual(singles.count + aggregates[0].deniedAggregateCount, n,
                       "every one of the \(n) denied nodes is represented — none silently culled")
        XCTAssertGreaterThan(aggregates[0].rect.area, ScenePipeline.minRenderAreaPx,
                             "the aggregate badge is above the sub-pixel cull threshold")
    }

    // MARK: - 11. Chunked ingest folds every event exactly once (queue-priority correctness)

    /// The queue-priority fix (OPERATOR_NOTE #3.1) folds large batches in `ingestChunk` slices
    /// with a suspension point between them so a focus emit can overtake. This pins the
    /// CORRECTNESS half deterministically: a SINGLE batch far larger than the chunk size must
    /// still fold every event EXACTLY ONCE — no loss or double-count across chunk boundaries —
    /// so `scannedBytes` and the child count are exact. (The latency/preemption half is measured
    /// live by scripts/thread_host.swift's "WORST FOCUS COMMIT→SCENE latency" line.)
    func testChunkedIngestFoldsEveryEventExactly() async {
        let rootId = "/r"; let n = 5000 // one batch of ~10k events ≫ ingestChunk (2048)
        let perChild: Int64 = 7
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        await pipe.setViewport(viewport)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        var events: [ScanEvent] = [.sizeUpdated(nodeId: rootId, allocated: 0, logical: 0)]
        let stubs = (0..<n).map { ChildStub(id: "\(rootId)/c\($0)", name: "c\($0)", kind: .file) }
        events.append(.childrenDiscovered(parentId: rootId, children: stubs))
        for i in 0..<n {
            events.append(.sizeUpdated(nodeId: "\(rootId)/c\(i)", allocated: perChild, logical: perChild))
        }
        events.append(.subtreeCompleted(nodeId: rootId))
        cont.yield(events); cont.finish()
        await ingestTask.value

        var scene: RenderScene?
        for await s in pipe.scenes { scene = s; break }
        guard let scene else { return XCTFail("pipeline produced no scene") }
        XCTAssertEqual(scene.scannedBytes, Int64(n) * perChild,
                       "the giant single batch folded across chunk boundaries with no loss/dup")
        XCTAssertEqual(scene.filesProcessed, n + 1, // + the root's own size event
                       "each of the \(n) children (plus the root) counted exactly once — no chunk-boundary dup")
        XCTAssertEqual(scene.tree.children.count, n, "all children present after the chunked fold")
    }

    // MARK: - 12. A focus emit is serviced WHILE a scan is still streaming (interleaving)

    /// The interleaving half of the queue-priority behaviour (OPERATOR_NOTE #3.1). With a
    /// prefilled but UNFINISHED walker stream (the scan still running), a `setFocus` must be
    /// serviced and produce its target scene without waiting for the scan to end — the whole
    /// point of letting focus overtake ingest. We assert the focus scene arrives with
    /// `running == true` (the scan has not completed), i.e. the emit interleaved with an active
    /// ingest rather than only after the final settle.
    func testFocusEmitInterleavesWithActiveIngest() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        await pipe.setViewport(viewport)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        // Prefill several batches establishing the focus target's children, but DO NOT finish
        // the stream — the scan stays "running".
        for batch in childBatches(rootId: rootId, n: 12, perChild: 5) { cont.yield(batch) }
        let ingestTask = Task { await pipe.ingest(stream) }

        var iterator = pipe.scenes.makeAsyncIterator()
        await pipe.setFocus(rootId)
        var got: RenderScene?
        while let s = await iterator.next() { if s.focusId == rootId { got = s; break } }
        XCTAssertNotNil(got, "the focus emit produced a scene while ingest was still active")
        XCTAssertTrue(got?.running ?? false,
                      "the focus scene was serviced during an active (unfinished) scan — not only after it ends")

        cont.finish()
        await ingestTask.value
    }

    // MARK: - 13. TZ-5 lenses: scale echoed, hidden + ignore filtered off main

    /// The App-facing end of the TZ-5 lenses. Each setter force-emits, so reading the next scene
    /// after each pins: (a) the scene ECHOES the active scale (the status-bar label matches what is
    /// drawn); (b) show-hidden OFF excludes the hidden node AND reports its mass in
    /// `hiddenFilteredBytes` (never a silent drop); (c) the ignore set excludes a node from the
    /// rendered tiles. All computed on the actor (off main), exactly as the App consumes them.
    func testLensesEchoScaleAndFilterHiddenAndIgnored() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        await pipe.setViewport(viewport)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        cont.yield([
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId, children: [
                ChildStub(id: "\(rootId)/V", name: "V", kind: .dir),
                ChildStub(id: "\(rootId)/.H", name: ".H", kind: .dir, isHidden: true),
                ChildStub(id: "\(rootId)/big", name: "big", kind: .dir)]),
            .sizeUpdated(nodeId: "\(rootId)/V", allocated: 700_000_000, logical: 700_000_000),
            .sizeUpdated(nodeId: "\(rootId)/.H", allocated: 300_000_000, logical: 300_000_000),
            .sizeUpdated(nodeId: "\(rootId)/big", allocated: 500_000_000, logical: 500_000_000),
            .subtreeCompleted(nodeId: rootId),
        ])
        cont.finish()
        await ingestTask.value

        var it = pipe.scenes.makeAsyncIterator()
        // Final settle: LOG is the ratified default scale; hidden is shown, nothing filtered.
        let first = await it.next()
        XCTAssertEqual(first?.scaleMode, .log, "the default scale is Log, echoed on the scene")
        XCTAssertEqual(first?.hiddenFilteredBytes, 0, "nothing filtered while show-hidden is on")
        XCTAssertTrue(first?.tiles.contains { $0.nodeId == "\(rootId)/.H" } ?? false,
                      "the hidden node is drawn while show-hidden is on (the scan always includes it)")

        // Show-hidden OFF: the hidden node is excluded and its mass reported.
        await pipe.setIncludeHidden(false)
        let hiddenOff = await it.next()
        XCTAssertFalse(hiddenOff?.tiles.contains { $0.nodeId == "\(rootId)/.H" } ?? true,
                       "the hidden node is filtered from layout when show-hidden is off")
        XCTAssertEqual(hiddenOff?.hiddenFilteredBytes, 300_000_000,
                       "the filtered hidden mass is reported (invisible-space accounting)")

        // Scale toggled to LINEAR: echoed on the scene.
        await pipe.setScale(.linear)
        let linear = await it.next()
        XCTAssertEqual(linear?.scaleMode, .linear, "the scale toggle is echoed on the scene")

        // Ignore `big`: excluded from the rendered tiles.
        await pipe.setIgnored(["\(rootId)/big"])
        let ignored = await it.next()
        XCTAssertFalse(ignored?.tiles.contains { $0.nodeId == "\(rootId)/big" } ?? true,
                       "an ignored node is excluded from layout (its siblings renormalize)")
    }

    // MARK: - 14. TZ-5: pipeline-level cull counts (linear vs log) + ignore accounting

    /// END-TO-END through the REAL changed path (review-0 change 4b): drive `ScenePipeline`'s
    /// `setScale`/`setIgnored`, which run `ScanReducer.makeRenderTree(excluding:weight:)` +
    /// projection-prune + the final pixel cull on the actor, and read the EMITTED
    /// `RenderScene.belowPixelCount`/`ignoredBytes`. This is the pipeline-level evidence the
    /// verify PNG host cannot give (it lays out a hand-filtered SizeTree directly, bypassing the
    /// reducer projection). A giant + 50 starved siblings: under LINEAR the siblings are sub-pixel
    /// (culled/pruned and COUNTED); under LOG the tail is exposed (fewer culls). Then ignoring the
    /// giant excludes it AND reports its exact excluded mass.
    func testPipelineLinearVsLogCullCountsAndIgnoreAccounting() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        await pipe.setViewport(viewport)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }

        var stubs = [ChildStub(id: "\(rootId)/giant", name: "giant", kind: .file)]
        for i in 0..<50 { stubs.append(ChildStub(id: "\(rootId)/s\(i)", name: "s\(i)", kind: .file)) }
        var events: [ScanEvent] = [
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId, children: stubs),
            .sizeUpdated(nodeId: "\(rootId)/giant", allocated: 1_000_000_000, logical: 1_000_000_000),
        ]
        for i in 0..<50 { events.append(.sizeUpdated(nodeId: "\(rootId)/s\(i)", allocated: 1_000, logical: 1_000)) }
        events.append(.subtreeCompleted(nodeId: rootId))
        cont.yield(events)
        cont.finish()
        await ingestTask.value

        var it = pipe.scenes.makeAsyncIterator()
        // Force LINEAR (default is LOG) and read its cull count from the emitted scene.
        await pipe.setScale(.linear)
        let linear = await it.next()
        // Back to LOG and read again — the SAME scene under the other scale.
        await pipe.setScale(.log)
        let log = await it.next()
        guard let linear, let log else { return XCTFail("no scenes emitted for the scale toggle") }

        XCTAssertEqual(linear.belowPixelCount, 50,
                       "LINEAR: all 50 starved siblings fall below pixel size (pruned/culled + counted)")
        XCTAssertEqual(log.belowPixelCount, 0,
                       "LOG: the tail clears the pixel threshold — the starved siblings are exposed")
        XCTAssertLessThan(log.belowPixelCount, linear.belowPixelCount,
                          "log reduces below-pixel culling through the real pipeline projection")

        // Ignore the giant (under log): excluded from the tiles AND its exact mass reported as the
        // excluded UNION figure (review-0 change 2, computed on the actor from reducer state).
        await pipe.setIgnored(["\(rootId)/giant"])
        let ignored = await it.next()
        guard let ignored else { return XCTFail("no scene after ignore") }
        XCTAssertFalse(ignored.tiles.contains { $0.nodeId == "\(rootId)/giant" },
                       "the ignored giant is excluded from layout")
        XCTAssertEqual(ignored.ignoredBytes, 1_000_000_000,
                       "the excluded UNION mass is the giant's exact retained total")
        XCTAssertEqual(ignored.ignoredCurrentById["\(rootId)/giant"], 1_000_000_000,
                       "the per-row live size matches the giant's retained total")
    }

    // MARK: - 15. TZ-5: ignore child THEN parent — union accounting, never double-count

    /// REGRESSION for review-1 change 2 (the snapshot-sum defect). Ignoring a CHILD and then its
    /// visible PARENT must report the excluded UNION (the parent's whole subtree, which already
    /// contains the child), NOT the sum of the two snapshots. This is checked at the REAL App→
    /// pipeline handoff: `RenderScene.ignoredBytes`, the only figure the App is now allowed to show
    /// (the App-side `Σ row.bytes` that double-counted here is gone). Structure: root → P(own 100)
    /// → C(300); ignore C (300) then P (400 total). The old snapshot sum would read 300+400=700;
    /// the union reads 400.
    func testIgnoreChildThenParentReportsUnionNotDoubleCount() async {
        let rootId = "/r"
        let pipe = ScenePipeline(rootId: rootId, rootName: "r")
        await pipe.setViewport(viewport)
        let (stream, cont) = AsyncStream<[ScanEvent]>.makeStream(bufferingPolicy: .unbounded)
        let ingestTask = Task { await pipe.ingest(stream) }
        cont.yield([
            .sizeUpdated(nodeId: rootId, allocated: 0, logical: 0),
            .childrenDiscovered(parentId: rootId, children: [
                ChildStub(id: "\(rootId)/P", name: "P", kind: .dir),
                ChildStub(id: "\(rootId)/Q", name: "Q", kind: .dir)]),
            .childrenDiscovered(parentId: "\(rootId)/P", children: [
                ChildStub(id: "\(rootId)/P/C", name: "C", kind: .dir)]),
            .sizeUpdated(nodeId: "\(rootId)/P", allocated: 100, logical: 100),   // P's OWN entry
            .sizeUpdated(nodeId: "\(rootId)/P/C", allocated: 300, logical: 300), // → P subtree = 400
            .sizeUpdated(nodeId: "\(rootId)/Q", allocated: 5_000, logical: 5_000),
            .subtreeCompleted(nodeId: rootId),
        ])
        cont.finish()
        await ingestTask.value

        var it = pipe.scenes.makeAsyncIterator()

        // Ignore the CHILD first: excluded mass = C's 300.
        await pipe.setIgnored(["\(rootId)/P/C"])
        let afterChild = await it.next()
        XCTAssertEqual(afterChild?.ignoredBytes, 300, "child alone excludes its own subtree total")

        // Now ALSO ignore its parent P (whose subtree already contains C). The union is P's whole
        // subtree (400) — NOT 300 + 400 = 700 (the snapshot double-count this test guards against).
        await pipe.setIgnored(["\(rootId)/P/C", "\(rootId)/P"])
        let afterParent = await it.next()
        XCTAssertEqual(afterParent?.ignoredBytes, 400,
                       "ancestor+descendant excluded together = the ancestor's subtree ONCE (union, not 700)")
    }
}
