//
//  QuadGeometryTests.swift — the ascend/dive handoff, on the REAL production geometry.
//  Module maturity: PROTOTYPE (slice TZ-3b, review-2 gap 3)
//
//  WHY THIS EXISTS
//  ---------------
//  Reviews 0–2 rejected the ascend test because it re-implemented the embed/handoff
//  math over `TileRect`/`Double` in the test file — it proved a DUPLICATE model, not
//  the production path. This suite drives the ACTUAL functions NavigationController
//  calls — `RenderPipeline.QuadGeometry.embedChild` / `.transform` / `.commitFrom` —
//  over the ACTUAL render type (`GPUQuad`/`Float`), built exactly as the pipeline
//  builds them (`TreemapScene.layout` → `QuadBuilder.build`). There is no second
//  implementation to drift from: the App and these tests share one.
//
//  THE TWO GUARANTEES IT PINS
//  --------------------------
//   1. ASCEND OPENS EXACTLY (no snap). The ascend base = the cached parent world with
//      the child subtree replaced by the child's committed quads (`embedChild`); the
//      t=0 camera (childRect → viewport) is the exact inverse of that embed, so at t=0
//      EVERY shared child-subtree tile maps back onto the committed child scene within
//      Float epsilon — all shared tiles, no focus-only carve-out, no viewport tolerance.
//   2. DIVE COMMITS EXACTLY on the focus, AND RE-TINTS AT COMMIT. `commitFrom` places each
//      committed tile where its node sat in the camera's last frame (geometry) but snaps its
//      COLOUR/STYLE to the committed focus-relative scene (review-1 finding 2), so the focus
//      tile lands filling the viewport with zero deviation (the mass the eye tracks does not
//      jump), a shared node's hue changes to its new-focus tint from frame 0, a node absent
//      from the base carries its own committed quad, and the result is index-parallel with
//      the committed scene.
//

import XCTest
import ScanCore
import TreemapCore
@testable import RenderPipeline

final class QuadGeometryTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 1100, height: 680)

    // A multi-level subtree so a dive/ascend exercises real anisotropic re-tiling
    // (squarify is NOT affine-equivariant under anisotropic scale — CameraHandoffTests).
    private func tree() -> SizeTree {
        func file(_ id: String, _ b: Int64) -> SizeTree {
            SizeTree(id: id, name: id, kind: .file, allocatedBytes: b, logicalBytes: b)
        }
        let sub = SizeTree(id: "a/sub", name: "a/sub", kind: .dir, allocatedBytes: 400,
                           logicalBytes: 400, children: [file("a/x1", 100), file("a/x2", 300)])
        let a = SizeTree(id: "A", name: "A", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [sub, file("a/f", 600)])
        let b = SizeTree(id: "B", name: "B", kind: .dir, allocatedBytes: 1000, logicalBytes: 1000,
                         children: [file("b/1", 500), file("b/2", 500)])
        return SizeTree(id: "root", name: "root", kind: .dir, allocatedBytes: 2000,
                        logicalBytes: 2000, children: [a, b])
    }

    /// Lay out a focus world exactly as the pipeline does, then build its GPU instances
    /// through the SAME off-main builder — the production (tiles, nodeIds, quads) triple.
    private func world(focus: String?) -> (tiles: [TileRect], nodeIds: [String], quads: [GPUQuad]) {
        let tiles = TreemapScene.layout(tree: tree(), focusId: focus, viewport: viewport)
        return (tiles, tiles.map { $0.nodeId }, QuadBuilder.build(tiles: tiles))
    }

    /// Max corner deviation between two quads' GEOMETRY (all four edges), in device px.
    private func geomDev(_ a: GPUQuad, _ b: GPUQuad) -> Float {
        max(abs(a.x - b.x), abs(a.y - b.y),
            abs((a.x + a.w) - (b.x + b.w)), abs((a.y + a.h) - (b.y + b.h)))
    }

    // Float32 over ~1e3-px coordinates through two narrowed affine composites: worst-case
    // rounding is a few ×1e-4 px. 0.02 px is comfortably above that and far below one
    // pixel, so a pass means "geometrically identical", i.e. NO opening snap.
    private let eps: Float = 0.02
    // Colour epsilon (test 4): components are in [0,1] from a single HSB→RGB, so a few ×1e-6.
    private let colorEps: Float = 1e-5

    /// Rendered LUMINANCE — Rec.709 relative luminance (`0.2126·R + 0.7152·G + 0.0722·B`), the
    /// standard linear brightness of an RGB colour. TZ-8's CONTINUITY LAW speaks of "monotone
    /// luminance through both flights"; this computes that literal quantity, not a proxy. The
    /// earlier un-weighted `R+G+B` sum was a DIFFERENT metric mis-named "luminance" (review-5): a
    /// weighted luma is NOT a mere rescaling of the sum — because the pane→own per-channel deltas
    /// can carry mixed signs, re-weighting the channels can flip which endpoint is brighter and so
    /// change the sign of a step. Testing the real luminance the law names is the name-honest
    /// witness; if a hue pairing ever made real luminance non-monotone that would be a genuine
    /// CONTINUITY-LAW finding to surface, not a test to weaken. Matches the `lum` in GlassPaneTests.
    private func lum(_ c: (Float, Float, Float)) -> Float { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }

    /// The EXACT rendered-RGB rebase-continuity assertion (TZ-8 OPERATOR_NOTE #4, resolved by
    /// #5), PER CHANNEL and non-flaky. Both arguments are RENDERED colours — the colour the shader
    /// actually emits, `displayedColor` INCLUDING the `brightnessRebase` uniform (the pure mirror of
    /// Shaders.metal). The dive endpoint in the OLD scene is rendered with the flight-end rebase
    /// (`QuadBuilder.diveRebaseEnd` = 1/dimFalloff, brightening it by one dim-ladder step); the rest
    /// in the NEW scene is rendered un-rebased (factor 1). OPERATOR_NOTE #5 ANIMATES the rebase so
    /// these two RENDERED colours are EQUAL per channel (no `/0.74` tolerance, no ~35% pop — the
    /// review-5 blocker) — this is the strict equality note #5 mandates restoring.
    private func assertRenderedContinuous(oldDivedRendered: (Float, Float, Float),
                                          newRestRendered: (Float, Float, Float),
                                          _ what: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(newRestRendered.0, oldDivedRendered.0, accuracy: colorEps,
                       "\(what): rendered red at new-t=0 == rendered red at old-t=1 (rebased) — no pop", file: file, line: line)
        XCTAssertEqual(newRestRendered.1, oldDivedRendered.1, accuracy: colorEps,
                       "\(what): rendered green at new-t=0 == rendered green at old-t=1 (rebased) — no pop", file: file, line: line)
        XCTAssertEqual(newRestRendered.2, oldDivedRendered.2, accuracy: colorEps,
                       "\(what): rendered blue at new-t=0 == rendered blue at old-t=1 (rebased) — no pop", file: file, line: line)
    }

    // MARK: - 1. Ascend opens on the committed child scene — ALL shared tiles, within eps

    func testAscendOpeningMatchesChildSceneExactlyOnAllSharedTiles() {
        for childId in ["A", "B"] {
            let parent = world(focus: nil)
            let child = world(focus: childId)
            guard let childRect = parent.tiles.first(where: { $0.nodeId == childId })?.rect else {
                return XCTFail("childRect for \(childId) not found in parent world")
            }

            // The child focus fills the viewport — this IS what is on screen at ascend.
            let focusQ = child.quads[child.nodeIds.firstIndex(of: childId)!]
            XCTAssertEqual(Double(focusQ.w), viewport.width, accuracy: 1e-3)
            XCTAssertEqual(Double(focusQ.h), viewport.height, accuracy: 1e-3)

            // PRODUCTION embed + PRODUCTION t=0 camera (the exact NavigationController path).
            let base = QuadGeometry.embedChild(
                childQuads: child.quads, childNodeIds: child.nodeIds, into: childRect,
                parentQuads: parent.quads, parentNodeIds: parent.nodeIds, childId: childId)
            let t0 = FocusCamera.transform(fromFrame: childRect, toFrame: viewport, viewport: viewport, t: 0)
            var openingById = [String: GPUQuad]()
            for (i, id) in base.nodeIds.enumerated() {
                openingById[id] = QuadGeometry.transform(base.quads[i], by: t0)
            }

            // Every committed child-scene tile must be reproduced at t=0 within eps.
            var shared = 0
            for (i, id) in child.nodeIds.enumerated() {
                guard let o = openingById[id] else {
                    XCTFail("child tile \(id) missing from ascend opening frame"); continue
                }
                shared += 1
                XCTAssertLessThan(geomDev(o, child.quads[i]), eps,
                    "ascend opening tile \(id) must equal the committed child scene within \(eps) px — no opening snap (\(childId))")
                // TZ-8 (review-0 item 1): the ascend flight OPENS at dissolveT = 1 (own slot).
                // `embedChild` puts the child's DISPLAYED colour (its rest colour — the child
                // scene renders at rest) in that slot, so the opening frame reproduces the child
                // scene in COLOUR too, not only geometry. (The rest slot now holds the PARENT
                // paned colour, the dissolveT = 0 re-condensation target — checked in
                // GlassPaneTests.testAscendReCondensesToParentPane.)
                let opening = QuadBuilder.displayedColor(o, dissolveT: 1)
                XCTAssertEqual(opening.0, child.quads[i].r, "ascend opens on the child displayed red (\(id))")
                XCTAssertEqual(opening.1, child.quads[i].g, "ascend opens on the child displayed green (\(id))")
                XCTAssertEqual(opening.2, child.quads[i].b, "ascend opens on the child displayed blue (\(id))")
                XCTAssertEqual(o.style, child.quads[i].style, "style is preserved across the embed (\(id))")
            }
            XCTAssertGreaterThan(shared, 1,
                "the opening frame must reproduce the WHOLE child subtree, not just the focus tile (\(childId))")
        }
    }

    // MARK: - 2. Ascend's opening camera IS dive's closing camera (dive reversed)

    func testAscendCameraIsDiveTransformReversed() {
        let parent = world(focus: nil)
        let childRect = parent.tiles.first { $0.nodeId == "A" }!.rect
        let diveClose = FocusCamera.transform(fromFrame: viewport, toFrame: childRect, viewport: viewport, t: 1)
        let ascendOpen = FocusCamera.transform(fromFrame: childRect, toFrame: viewport, viewport: viewport, t: 0)
        XCTAssertEqual(diveClose, ascendOpen,
                       "ascend's opening camera transform is dive's closing transform — dive reversed")
    }

    // MARK: - 3. Dive commit lands the focus exactly + parallel + absent-node fallback

    func testCommitFromLandsFocusExactlyAndIsParallel() {
        for childId in ["A", "B"] {
            let parent = world(focus: nil)
            let child = world(focus: childId)
            let childRect = parent.tiles.first { $0.nodeId == childId }!.rect
            let finalCam = FocusCamera.transform(fromFrame: viewport, toFrame: childRect, viewport: viewport, t: 1)

            let from = QuadGeometry.commitFrom(
                sceneQuads: child.quads, sceneNodeIds: child.nodeIds,
                baseQuads: parent.quads, baseNodeIds: parent.nodeIds, finalCam: finalCam)

            XCTAssertEqual(from.count, child.quads.count, "commitFrom is index-parallel with the committed scene")

            // The focus tile: its camera-last-frame position (parent's child rect under
            // finalCam) fills the viewport, exactly the committed focus quad — zero jump.
            let fi = child.nodeIds.firstIndex(of: childId)!
            XCTAssertLessThan(geomDev(from[fi], child.quads[fi]), eps,
                "commit lands the focus tile exactly on its committed position (\(childId))")

            // A committed node ABSENT from the base (deeper detail revealed by focusing)
            // carries its OWN committed quad — appears in place, no fly-in.
            let baseIds = Set(parent.nodeIds)
            var checkedAbsent = false
            for (i, id) in child.nodeIds.enumerated() where !baseIds.contains(id) {
                XCTAssertEqual(from[i], child.quads[i],
                    "committed node \(id) absent from the flight base falls back to its own quad")
                checkedAbsent = true
            }
            // A shared node present in the base morphs FROM its camera-last-frame GEOMETRY
            // but with the COMMITTED scene's COLOUR/STYLE snapped in (review-1 finding 2: the
            // focus-relative re-tint lands AT commit, not after the settle).
            let baseById = Dictionary(uniqueKeysWithValues: zip(parent.nodeIds, parent.quads))
            var sawReTint = false
            for (i, id) in child.nodeIds.enumerated() where baseById[id] != nil && id != childId {
                let endGeom = QuadGeometry.transform(baseById[id]!, by: finalCam)
                // Geometry: still the camera's last frame (the settle's spatial morph source).
                XCTAssertLessThan(geomDev(from[i], endGeom), eps,
                    "shared node \(id) morphs from its camera-last-frame position")
                // Colour/style: the COMMITTED scene, NOT the stale flight-base colour.
                XCTAssertEqual(from[i].r, child.quads[i].r, "commit snaps red to the committed scene (\(id))")
                XCTAssertEqual(from[i].g, child.quads[i].g, "commit snaps green to the committed scene (\(id))")
                XCTAssertEqual(from[i].b, child.quads[i].b, "commit snaps blue to the committed scene (\(id))")
                XCTAssertEqual(from[i].style, child.quads[i].style, "commit snaps style to the committed scene (\(id))")
                // The re-tint is OBSERVABLE: at least one shared node's committed colour
                // differs from its old (flight-base) colour — a real focus-relative recolour,
                // not merely a changed target scene.
                if (baseById[id]!.r, baseById[id]!.g, baseById[id]!.b)
                    != (child.quads[i].r, child.quads[i].g, child.quads[i].b) { sawReTint = true }
            }
            XCTAssertTrue(sawReTint,
                "commit CHANGES colours (not only geometry): a shared node is re-tinted to its new focus-relative hue (\(childId))")
            _ = checkedAbsent // the tree is deep enough that this fires for at least one child
        }
    }

    // MARK: - 4. Dive REBASE: exact per-channel handoff continuity across the commit (TZ-8 NOTE #4)

    /// HANDOFF CONTINUITY across the dive REBASE (TZ-8 OPERATOR_NOTE #4, 2026-08-17 — the test the
    /// operator mandated to close the slice).
    ///
    /// THE LIFECYCLE IT PINS. The glass-pane dissolve is PER-FLIGHT on the OUTGOING scene: a dive
    /// drives `dissolveT` 0→1 over the OLD (parent-focus) scene — the dive target's pane dissolves
    /// so its children's OWN hues emerge — and AT COMMIT the scene REBASES: the target becomes the
    /// focus, its children become the NEW level-1 panes, and `dissolveT` resets to 0 (the settled
    /// state at the new depth; NavigationController.animateCamera resets it on commit). What the eye
    /// requires is that a tile it is tracking does NOT jump across that rebase: a target-child
    /// rendered at the dive endpoint (OLD scene, `dissolveT = 1`) shows its own name hue, and the
    /// SAME node rendered at rest in the NEW scene (`dissolveT = 0`, where it is now a hue root)
    /// shows that SAME own hue. This drives the REAL production path — two independently-laid-out
    /// scenes via `world(focus:)` through the REAL colour builder — so there is no second model.
    ///
    /// THE COMPARISON IS DIRECT, PER-CHANNEL, AND ON THE RENDERED COLOUR (OPERATOR_NOTE #5). For
    /// each tracked tile it asserts the colour the shader actually EMITS at old-`dissolveT=1` equals
    /// the colour it emits at new-`dissolveT=0`, on EACH of r/g/b at `colorEps` — a RAW equality, no
    /// `/0.74` tolerance. The equality holds because the rendered old-endpoint folds in the flight's
    /// `brightnessRebase` (`QuadBuilder.diveRebaseEnd` = 1/dimFalloff): `displayedColor` mirrors the
    /// shader's `mix(...) * brightnessRebase` for normal tiles, so old-t=1 renders one dim step
    /// brighter — landing exactly on the incoming scene's rest.
    ///
    /// WHY THIS IS NOW EXACT (the review-5 escalation, RESOLVED by OPERATOR_NOTE #5). `dimLevel` is
    /// FOCUS-RELATIVE (TreemapScene.place: focus = 0, +1 per nesting level), so the rebase makes a
    /// tracked tile exactly ONE dim step shallower across the commit — a target child is dimLevel 2
    /// under the parent focus but dimLevel 1 (a hue root) under the new focus. Two ratified
    /// constraints pin the two RAW-colour endpoints one dim step apart: (i) deliverable 5a +
    /// OPERATOR_NOTE #3 bind the OLD dived endpoint to own hue at the OLD depth (base·falloff²);
    /// (ii) focus-relative dimming (test 3's `sawReTint`) binds the NEW rest to own hue at the NEW
    /// depth (base·falloff¹). Earlier iterations left that one-step gap ON SCREEN (a ~35% pop) or
    /// hid it behind a `/dimFalloff` test tolerance — both rejected. OPERATOR_NOTE #5 ANIMATES the
    /// gap away: the App ramps `brightnessRebase` 1 → 1/dimFalloff over the dive, so the RENDERED
    /// colours are literally equal at the handoff. This test pins that rendered equality.
    func testDiveRebaseRgbContinuityAtCommit() {
        for targetId in ["A", "B"] {
            let old = world(focus: nil)      // OLD scene: root focus; target is a level-1 pane
            let new = world(focus: targetId) // NEW scene: target is the focus; its children are level-1
            let oldById = Dictionary(uniqueKeysWithValues: zip(old.nodeIds, old.quads))
            let newById = Dictionary(uniqueKeysWithValues: zip(new.nodeIds, new.quads))
            func dim(_ tiles: [TileRect], _ id: String) -> Int? { tiles.first { $0.nodeId == id }?.dimLevel }

            // The target ITSELF keeps its own hue across the rebase: a hue root at dimLevel 1 under
            // the parent focus, the focus tile at dimLevel 0 under itself — same own hue, one step
            // brighter (a hue root's rest == own, so the dive endpoint reads it directly).
            if let oldT = oldById[targetId], let newT = newById[targetId] {
                // RENDERED colours: old dive endpoint carries the flight's end rebase (one dim step
                // brighter); new rest is un-rebased. NOTE #5 makes them equal per channel.
                let oldTdived = QuadBuilder.displayedColor(oldT, dissolveT: 1,
                                                           brightnessRebase: QuadBuilder.diveRebaseEnd)
                let newTrest  = QuadBuilder.displayedColor(newT, dissolveT: 0)
                assertRenderedContinuous(oldDivedRendered: oldTdived, newRestRendered: newTrest,
                                         "target \(targetId)")
            }

            // The tiles the eye tracks across the rebase: the target's DIRECT children — the NEW
            // scene's level-1 panes. Present in both scenes (old: dimLevel 2, paned; new: dimLevel 1).
            let targetChildren = new.tiles.filter { $0.dimLevel == 1 }.map { $0.nodeId }
            XCTAssertGreaterThan(targetChildren.count, 0,
                "target \(targetId) must have level-1 children in its focus scene")

            var checked = 0
            for id in targetChildren {
                guard let oldQ = oldById[id], let newQ = newById[id] else { continue }
                checked += 1

                // STRUCTURAL: the one-step rebase (the SOURCE of the brightness re-tint, non-flaky).
                XCTAssertEqual(dim(old.tiles, id), 2, "old scene: target child \(id) is a dimLevel-2 descendant (paned)")
                XCTAssertEqual(dim(new.tiles, id), 1, "new scene: target child \(id) is a dimLevel-1 hue root")

                // GROUNDING: in the NEW scene the child is a HUE ROOT — its rest == own (its pane
                // covers ITS children, not it), so the dissolve is a visual no-op on it at the new
                // depth. This is what makes `dissolveT = 0` in the new scene show the OWN hue.
                let newRest = QuadBuilder.displayedColor(newQ, dissolveT: 0)
                let newOwn  = QuadBuilder.displayedColor(newQ, dissolveT: 1)
                XCTAssertEqual(newRest.0, newOwn.0, accuracy: colorEps, "new scene: child \(id) is a hue root (rest == own)")
                XCTAssertEqual(newRest.1, newOwn.1, accuracy: colorEps, "new scene: child \(id) is a hue root (rest == own)")
                XCTAssertEqual(newRest.2, newOwn.2, accuracy: colorEps, "new scene: child \(id) is a hue root (rest == own)")

                // THE OPERATOR'S REQUIREMENT (NOTE #5) — RENDERED colours EQUAL at the handoff, per
                // channel and exact. The dive endpoint in the OLD scene renders WITH the flight's end
                // brightnessRebase (`diveRebaseEnd` = 1/dimFalloff — own hue emerging as the target's
                // pane dissolves, brightened one dim step); the child's rest in the NEW scene renders
                // un-rebased (own hue as a fresh level-1 pane). The animated rebase (note #5) makes
                // them literally equal — no `/0.74` tolerance, no pop (the review-5 blocker resolved).
                let oldDivedRendered = QuadBuilder.displayedColor(oldQ, dissolveT: 1,
                                                                  brightnessRebase: QuadBuilder.diveRebaseEnd)
                assertRenderedContinuous(oldDivedRendered: oldDivedRendered, newRestRendered: newRest,
                                         "target child \(id)")

                // The dive genuinely dissolved a pane: in the OLD scene the child INHERITS the
                // target's hue as its pane (TreemapScene: level ≥ 2 inherits the ancestor hue), so
                // its rest colour is that pane composited over its own hue — the continuity above is
                // about the child's OWN hue, which the pane HID at rest. Structural (non-flaky): the
                // inherited pane hue IS the dive target's name hue. (name == id in this tree.)
                let oldChildTile = old.tiles.first { $0.nodeId == id }!
                XCTAssertEqual(oldChildTile.hue, TileColor.hue(for: targetId), accuracy: 1e-12,
                    "old scene: target child \(id) is paned under the target (inherited pane hue == target hue)")
            }
            XCTAssertGreaterThan(checked, 0,
                "at least one target child must be present in both scenes (\(targetId))")
        }
    }

    // MARK: - 5. Monotone LUMINANCE through the DIVE flight (TZ-8 CONTINUITY LAW, OPERATOR_NOTE #6)

    /// The law (PLAN §"TZ-8" CONTINUITY LAW, ratified 2026-08-17) requires "monotone luminance
    /// through both flights". A dive drives the WHOLE outgoing scene by ONE global pair
    /// `(dissolveT, brightnessRebase)`, COUPLED by the SAME smoothstep `s`
    /// (NavigationController.applyCameraFrame:717-719): for a dive `dissolveT = s` and
    /// `brightnessRebase = 1 + (diveRebaseEnd − 1)·s`, `s ∈ [0,1]` the flight progress. The
    /// rendered colour is therefore `mix(rest, own, s) · (1 + (k−1)s)` — a QUADRATIC in `s` that
    /// NO fixed-rebase endpoint test samples (the endpoint tests pin only `s = 0` and `s = 1`).
    /// This samples the interior and asserts the RENDERED luminance is monotone (strictly rising —
    /// "descending into the light": every normal tile brightens, with no mid-flight reversal).
    ///
    /// Sampling by `s` (not real time) is faithful: smoothstep is a monotone reparametrization of
    /// time, so luminance-monotone-in-`s` ⇔ luminance-monotone-in-time. Drives the REAL production
    /// scene (`world`) through the REAL colour path (`QuadBuilder.displayedColor`, the shader mirror).
    func testDiveFlightLuminanceIsMonotone() {
        let old = world(focus: nil)                 // OUTGOING scene of a dive from the root
        let k = QuadBuilder.diveRebaseEnd           // rebase endpoint = 1/dimFalloff (≈ 1.351)
        let steps = 40
        var checkedNormal = 0
        for (i, q) in old.quads.enumerated() where q.style < 0.5 { // normal tiles carry the pane+rebase
            checkedNormal += 1
            let start = lum(QuadBuilder.displayedColor(q, dissolveT: 0, brightnessRebase: 1))
            var prev = start
            for step in 1...steps {
                let s = Float(step) / Float(steps)
                // The EXACT App coupling: rebase rides the same `s` as the dissolve.
                let cur = lum(QuadBuilder.displayedColor(q, dissolveT: s, brightnessRebase: 1 + (k - 1) * s))
                XCTAssertGreaterThanOrEqual(cur, prev - colorEps,
                    "dive luminance is non-decreasing through the flight (tile \(old.nodeIds[i]), s=\(s))")
                prev = cur
            }
            XCTAssertGreaterThan(prev, start + colorEps,
                "the dive brightens the tile end-to-end — descending into the light (tile \(old.nodeIds[i]))")
        }
        XCTAssertGreaterThan(checkedNormal, 1, "the dive flight must sample multiple normal tiles")
    }

    // MARK: - 6. Monotone LUMINANCE through the ASCEND flight (TZ-8 CONTINUITY LAW, OPERATOR_NOTE #6)

    /// The ascend half of the law's "monotone luminance through both flights". Ascend drives
    /// `dissolveT` 1→0 with `brightnessRebase` IDENTITY (the `embedChild` base already bakes the
    /// dim-correct parent colours, so no scalar rebase — NavigationController.ascend:543-544,
    /// NOTE #5). The rendered colour is then a pure LINEAR mix of the baked flight endpoints, so
    /// its luminance is linear in `t` — monotone by construction; this pins that the pane
    /// re-condensation has NO mid-flight luminance reversal (each shared tile moves one way, from
    /// the child-displayed colour toward the dimmer parent-paned colour). Drives the REAL ascend
    /// base (`QuadGeometry.embedChild`, the exact NavigationController path) over the real scenes.
    func testAscendFlightLuminanceIsMonotone() {
        for childId in ["A", "B"] {
            let parent = world(focus: nil)
            let child = world(focus: childId)
            guard let childRect = parent.tiles.first(where: { $0.nodeId == childId })?.rect else {
                return XCTFail("childRect for \(childId) not found in parent world")
            }
            let base = QuadGeometry.embedChild(
                childQuads: child.quads, childNodeIds: child.nodeIds, into: childRect,
                parentQuads: parent.quads, parentNodeIds: parent.nodeIds, childId: childId)
            let steps = 40
            var checked = 0
            for (i, q) in base.quads.enumerated() where q.style < 0.5 {
                checked += 1
                let lStart = lum(QuadBuilder.displayedColor(q, dissolveT: 1)) // flight start (dissolveT = 1)
                let lEnd   = lum(QuadBuilder.displayedColor(q, dissolveT: 0)) // flight end   (dissolveT = 0)
                var prev = lStart
                for step in 1...steps {
                    let f = Float(step) / Float(steps)
                    let cur = lum(QuadBuilder.displayedColor(q, dissolveT: 1 - f)) // ascend drives 1→0
                    if lEnd >= lStart {
                        XCTAssertGreaterThanOrEqual(cur, prev - colorEps,
                            "ascend luminance non-decreasing toward the flight end (tile \(base.nodeIds[i]), \(childId))")
                    } else {
                        XCTAssertLessThanOrEqual(cur, prev + colorEps,
                            "ascend luminance non-increasing toward the flight end (tile \(base.nodeIds[i]), \(childId))")
                    }
                    prev = cur
                }
                XCTAssertEqual(prev, lEnd, accuracy: colorEps,
                    "ascend luminance sweep lands on the flight-end luminance (tile \(base.nodeIds[i]), \(childId))")
            }
            XCTAssertGreaterThan(checked, 1, "the ascend flight must sample multiple normal tiles (\(childId))")
        }
    }
}
