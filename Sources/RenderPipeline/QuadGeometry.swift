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
                r: q.r, g: q.g, b: q.b, style: q.style)
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
        var quads = [GPUQuad](); quads.reserveCapacity(parentQuads.count + childQuads.count)
        var nodeIds = [String](); nodeIds.reserveCapacity(quads.capacity)
        // Parent tiles NOT in the child subtree stay as-is.
        for i in parentNodeIds.indices where !childIds.contains(parentNodeIds[i]) {
            quads.append(parentQuads[i]); nodeIds.append(parentNodeIds[i])
        }
        // The child subtree, mapped viewport → C's slot.
        for i in childNodeIds.indices {
            quads.append(transform(childQuads[i], by: embed)); nodeIds.append(childNodeIds[i])
        }
        return (quads, nodeIds)
    }

    /// Build the COMMIT settle-"from": place each committed tile where its node sat in
    /// the camera's LAST frame (the flight base under `finalCam`), matched by nodeId. A
    /// committed node absent from the base (newly-revealed deeper detail, or a new
    /// sibling on ascend) carries its OWN committed quad ⇒ it appears in place, no fly-in.
    /// Result is index-parallel with `sceneQuads`. One O(base) dict + O(scene) pass, both
    /// bounded by the viewport-culled arrays (see the main-thread-law note in the header).
    public static func commitFrom(sceneQuads: [GPUQuad], sceneNodeIds: [String],
                                  baseQuads: [GPUQuad], baseNodeIds: [String],
                                  finalCam: ViewTransform) -> [GPUQuad] {
        var endById = [String: GPUQuad](minimumCapacity: baseNodeIds.count)
        for i in baseNodeIds.indices {
            endById[baseNodeIds[i]] = transform(baseQuads[i], by: finalCam)
        }
        var out = [GPUQuad](); out.reserveCapacity(sceneQuads.count)
        for i in sceneNodeIds.indices {
            out.append(endById[sceneNodeIds[i]] ?? sceneQuads[i])
        }
        return out
    }
}
