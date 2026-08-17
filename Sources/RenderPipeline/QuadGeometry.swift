//
//  QuadGeometry.swift — pure navigation-handoff geometry over PREBUILT quads.
//  Module maturity: PROTOTYPE (slice TZ-3b, review-2 gap 3)
//
//  WHY THIS EXISTS — ONE IMPLEMENTATION, TWO CALLERS (the earned test seam).
//  The App's NavigationController performs three geometric operations on already-built
//  `GPUQuad`s during a dive/ascend: apply the camera affine to a quad, EMBED a child's
//  committed quads into the cached parent world (the ascend base), and build the COMMIT
//  settle-"from" (each committed tile placed where its node sat in the camera's last
//  frame). Reviews 0–2 rejected the ascend test because it re-implemented this geometry
//  over `TileRect`/`Double` in the test file, proving a DUPLICATE model rather than the
//  production path. These functions are that production path, extracted into a PURE,
//  swift-testable home so NavigationController and the handoff tests call the SAME code
//  over the SAME `GPUQuad`/`Float` types. (App is an AppKit monolith SPM cannot see;
//  RenderPipeline is a real module `swift test` links — the only place a shared seam
//  exists.)
//
//  WHY HERE (charter-compliant). RenderPipeline already owns `GPUQuad` (the render
//  instance) and `QuadBuilder` (TileRect → GPUQuad), and its charter (CLAUDE.md
//  constraint 1) is pure composition with ZERO I/O and ZERO AppKit/Metal imports.
//  These are pure arithmetic over `GPUQuad` (RenderPipeline) + `ViewTransform`/`Rect`/
//  `FocusCamera` (TreemapCore) — no framework types, exactly the "plain value data"
//  the OPERATOR_NOTE blesses. The cores never import this; App and the tests do.
//
//  THE MAIN-THREAD LAW (PLAN §"Threading model"). NavigationController runs `commitFrom`
//  and `embedChild` on main, but ONCE per USER-DRIVEN dive/ascend (never per frame), and
//  ONLY over the VIEWPORT-CULLED quad arrays (ScenePipeline drops every non-focus tile
//  below the pixel threshold, so array length is bounded by viewport/threshold, not by
//  node count). They are intrinsically main-side — they compose main-only navigation
//  state (the live camera transform; the cached parent + displayed child snapshots the
//  background actor does not hold) — so they cannot move onto the pipeline actor without
//  duplicating that state across the boundary. Bounded, once-per-navigation, and
//  node-count-independent: the law forbids main work that SCALES WITH NODE COUNT, and
//  none of this does. QuadGeometryTests pins the geometry these rely on.
//
//  ABSTRACTION LEDGER: `QuadGeometry` is a namespace of pure functions (no protocol, no
//  state, no variation axis) over the existing `GPUQuad` DTO. Concrete current users:
//  NavigationController (production dive/ascend/commit) and QuadGeometryTests (the
//  handoff/symmetry gates). It is earned by exactly the "a test needs a seam
//  unobtainable more simply" + "two concrete callers" criteria — the same justification
//  GPUQuad/QuadBuilder carry. Rejected simpler alternative: leave the geometry private
//  in NavigationController (App), which forced the reviewer-rejected duplicate test and
//  hid the production math from `swift test`.
//

import Foundation
#if canImport(TreemapCore)
import TreemapCore
#endif

public enum QuadGeometry {
    /// Apply a world→view affine to a prebuilt quad's GEOMETRY (colour/style pass
    /// through untouched). The same per-axis map `FocusCamera`/the vertex shader use;
    /// arithmetic done in `Double` then narrowed to the quad's `Float` storage.
    public static func transform(_ q: GPUQuad, by t: ViewTransform) -> GPUQuad {
        GPUQuad(x: Float(Double(q.x) * t.scaleX + t.translateX),
                y: Float(Double(q.y) * t.scaleY + t.translateY),
                w: Float(Double(q.w) * t.scaleX),
                h: Float(Double(q.h) * t.scaleY),
                r: q.r, g: q.g, b: q.b,
                ownR: q.ownR, ownG: q.ownG, ownB: q.ownB, style: q.style) // BOTH colours pass through
    }

    /// Build the ASCEND CAMERA BASE (rider 1 / review-0 gap 3). Take the cached parent
    /// world's prebuilt quads and REPLACE the child subtree's slot with the child's OWN
    /// committed quads, mapped viewport → `childRect`. Siblings/ancestors of the child
    /// are carried unchanged. Returns render-only `(quads, nodeIds)`, index-parallel.
    ///
    /// The map is `FocusCamera.fit(childFocusRect → childRect)`, whose INVERSE is exactly
    /// the ascend camera's t=0 transform (`childRect → viewport`). So at t=0 every shared
    /// child-subtree tile maps back onto the committed child scene EXACTLY — the opening
    /// frame is the displayed child scene, no snap. `childFocusRect` is read from the
    /// child focus quad (dimLevel 0 fills the viewport), so no viewport value is needed.
    ///
    /// TZ-8 GLASS-PANE RE-CONDENSATION (review-0 item 1 — the ascend colour snap). This is a
    /// DIVE-REVERSED flight: the caller drives `dissolveT` 1→0 over it. The displayed colour
    /// at a flight parameter is `mix(rest, own, dissolveT)`, so the endpoint SHOWN at
    /// dissolveT = 1 (flight START) is the OWN slot and the endpoint shown at dissolveT = 0
    /// (flight END) is the REST slot. For the shared child subtree we must therefore:
    ///   - own slot  (shown at dissolveT = 1) := the CHILD scene's DISPLAYED colour (its
    ///     rest colour — the child scene renders at rest/dissolveT = 0), so t = 0 opens
    ///     EXACTLY on what is on screen (continuity, no opening snap); and
    ///   - rest slot (shown at dissolveT = 0) := the PARENT scene's paned colour for that
    ///     node, so as the flight runs 1→0 the tile MORPHS from its child-focus colour to its
    ///     parent-focus paned colour, landing on the parent scene BEFORE the commit — the
    ///     commit's settle then finds the colour already correct (no snap).
    /// NOTE the OWN slot deliberately carries the child's rest, NOT the parent's own: colour
    /// is FOCUS-RELATIVE and `dimLevel` is focus-relative, so a shared tile is one dim level
    /// SHALLOWER (brighter) under the child focus than under the parent — using the parent's
    /// own here would darken the opening frame by one ladder step, reintroducing a t = 0 snap.
    /// A child-only tile (deeper detail absent from the parent projection) has no parent
    /// target; it holds its displayed colour (both slots = child rest) as it shrinks away.
    public static func embedChild(childQuads: [GPUQuad], childNodeIds: [String],
                                  into childRect: Rect,
                                  parentQuads: [GPUQuad], parentNodeIds: [String],
                                  childId: String) -> (quads: [GPUQuad], nodeIds: [String]) {
        guard let focusIdx = childNodeIds.firstIndex(of: childId) else {
            return (parentQuads, parentNodeIds) // child not in its own scene (drift) — no embed
        }
        let f = childQuads[focusIdx] // the child focus quad == the viewport (it fills it)
        let focusRect = Rect(x: Double(f.x), y: Double(f.y), width: Double(f.w), height: Double(f.h))
        let embed = FocusCamera.fit(frame: focusRect, into: childRect) // viewport → childRect
        let childIds = Set(childNodeIds)
        // Parent REST (paned) colour by node id — the re-condensation TARGET (shown at the
        // flight end, dissolveT = 0) for a shared child-subtree tile.
        var parentRestById = [String: (Float, Float, Float)](minimumCapacity: parentNodeIds.count)
        for i in parentNodeIds.indices {
            parentRestById[parentNodeIds[i]] = (parentQuads[i].r, parentQuads[i].g, parentQuads[i].b)
        }
        var quads = [GPUQuad](); quads.reserveCapacity(parentQuads.count + childQuads.count)
        var nodeIds = [String](); nodeIds.reserveCapacity(quads.capacity)
        // Parent tiles NOT in the child subtree stay as-is.
        for i in parentNodeIds.indices where !childIds.contains(parentNodeIds[i]) {
            quads.append(parentQuads[i]); nodeIds.append(parentNodeIds[i])
        }
        // The child subtree, mapped viewport → C's slot, with dissolve endpoints reset so the
        // pane RE-CONDENSES from the child-focus colour to the parent-focus paned colour.
        for i in childNodeIds.indices {
            let g = transform(childQuads[i], by: embed) // child-scene geometry into C's slot
            let displayed = (childQuads[i].r, childQuads[i].g, childQuads[i].b) // child renders at rest
            let recondensed = parentRestById[childNodeIds[i]] ?? displayed // parent paned, or hold
            quads.append(GPUQuad(
                x: g.x, y: g.y, w: g.w, h: g.h,
                r: recondensed.0, g: recondensed.1, b: recondensed.2,        // dissolveT = 0 (parent paned)
                ownR: displayed.0, ownG: displayed.1, ownB: displayed.2,     // dissolveT = 1 (child displayed)
                style: g.style))
            nodeIds.append(childNodeIds[i])
        }
        return (quads, nodeIds)
    }

    /// Build the COMMIT settle-"from": place each committed tile where its node sat in
    /// the camera's LAST frame (the flight base under `finalCam`) for its GEOMETRY, but
    /// carry the COMMITTED scene's COLOUR/STYLE (`sceneQuads[i]`). Matched by nodeId; a
    /// committed node absent from the base (newly-revealed deeper detail, or a new sibling
    /// on ascend) carries its OWN committed quad ⇒ it appears in place, no fly-in. Result
    /// is index-parallel with `sceneQuads`. One O(base) dict + O(scene) pass, both bounded
    /// by the viewport-culled arrays (see the main-thread-law note in the header).
    ///
    /// WHY COLOUR SNAPS TO THE COMMITTED SCENE (review-1 finding 2 — the "prompt re-tint").
    /// Colour in Terrazzo is FOCUS-RELATIVE: the same node has one hue when it is a deep
    /// descendant of the old focus and a DIFFERENT hue when it becomes a hue-root under the
    /// new focus (PLAN §"Visual language"; TreemapSceneTests.testFocusRelativeReTintAtDepth).
    /// The commit settle morphs GEOMETRY old-position → committed-position; its COLOUR must
    /// already be the committed (new-focus) tint from frame 0, not the stale old-focus tint
    /// carried on the flight base — otherwise the map would re-tint only after the settle.
    /// The live Metal path already samples colour/style from the settle's TARGET buffer
    /// (Shaders.metal: `o.color`/`o.style` = `to`), so on-screen the tint is correct today;
    /// snapping the `from` buffer here makes BOTH buffers agree, so the invariant holds for
    /// ANY colour-lerp the shader might later use and is pinned by QuadGeometryTests without
    /// a GPU. Geometry (x/y/w/h) still comes from the camera-last frame, so the settle's
    /// spatial morph is unchanged.
    public static func commitFrom(sceneQuads: [GPUQuad], sceneNodeIds: [String],
                                  baseQuads: [GPUQuad], baseNodeIds: [String],
                                  finalCam: ViewTransform) -> [GPUQuad] {
        var endGeomById = [String: GPUQuad](minimumCapacity: baseNodeIds.count)
        for i in baseNodeIds.indices {
            endGeomById[baseNodeIds[i]] = transform(baseQuads[i], by: finalCam)
        }
        var out = [GPUQuad](); out.reserveCapacity(sceneQuads.count)
        for i in sceneNodeIds.indices {
            if let placed = endGeomById[sceneNodeIds[i]] {
                // Geometry from the camera's last frame; COLOUR/STYLE snapped to the
                // committed (focus-relative) scene so the re-tint lands AT commit.
                let c = sceneQuads[i]
                out.append(GPUQuad(x: placed.x, y: placed.y, w: placed.w, h: placed.h,
                                   r: c.r, g: c.g, b: c.b,
                                   ownR: c.ownR, ownG: c.ownG, ownB: c.ownB, // BOTH dissolve
                                   style: c.style))                          // colours snap
            } else {
                out.append(sceneQuads[i]) // absent from the base — its own committed quad
            }
        }
        return out
    }
}
