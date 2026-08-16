//
//  Shaders.metal — instanced-quad treemap shaders (runtime-compiled).
//  Module maturity: PROTOTYPE (slice TZ-1; TZ-3b moved animation into uniforms)
//
//  Shipped as SOURCE and compiled at runtime via `device.makeLibrary(source:)`
//  (glyph-saver heritage / PLAN.md: no build-time `metal` toolchain on this
//  machine). Both the App and scripts/verify_host.swift compile THIS file.
//
//  TZ-3b — THE ANIMATION MOVED INTO THE VERTEX STAGE (main-thread law).
//  Instances are now PREBUILT off the main thread (RenderPipeline.GPUQuad) in
//  WORLD-PIXEL space and uploaded ONCE per scene. Everything that used to be redone
//  per-tile on the CPU every frame is now a uniform the GPU applies while it already
//  iterates the instances:
//    - CAMERA (dive/ascend zoom): an affine (per-axis scale + translate) uniform.
//    - SETTLE (batched relayout morph): a linear parameter `t` between TWO instance
//      buffers (from → to), lerped per-instance in the vertex stage.
//    - WORLD → NDC: the viewport map, from a uniform (device-px viewport size).
//    - HOVER HIGHLIGHT: a single highlighted instance index uniform.
//  So the per-frame main-thread cost collapses to writing a few scalars — no per-tile
//  work survives on the frame path (PLAN §"Threading model"; OPERATOR_NOTE gap 1).
//
//  See RenderPipeline/GPUQuad.swift for the CPU producer and QuadRenderer.swift for
//  the CPU-side `Uniforms` mirror — field order + sizes MUST match the structs below.
//

#include <metal_stdlib>
using namespace metal;

// CPU mirror: RenderPipeline.GPUQuad (8 contiguous floats, 32-byte stride).
// World-pixel geometry (top-left origin, y-down) + resolved colour + style code.
struct GPUQuad {
    float x;    // world-pixel rect origin x (device px)
    float y;    // world-pixel rect origin y (device px)
    float w;    // world-pixel width
    float h;    // world-pixel height
    float r;
    float g;
    float b;
    float style; // 0 normal, 1 pending (outlined-dim), 2 denied, 3 synthetic (hatched)
};

// CPU mirror: QuadRenderer.Uniforms. Field order + sizes MUST match.
struct Uniforms {
    float2 viewport;     // device-px drawable size (world→NDC map)
    float2 camScale;     // camera per-axis scale (1,1 = identity)
    float2 camTranslate; // camera translate (device px)
    float  t;            // settle parameter in [0,1] (0 = show `from`)
    int    highlightIndex; // instance to highlight, or -1 for none
};

struct VOut {
    float4 position [[position]];
    float2 local;      // 0..1 within the tile
    float3 color;
    float2 pixelSize;  // ON-SCREEN tile size in device pixels (post-camera)
    float  style;      // GPUQuad.style, flat across the tile
    float  highlight;  // 1 if this instance is the hover target, else 0
};

// Unit quad as a triangle strip: vertex ids 0..3 → (0,0)(1,0)(0,1)(1,1). Positions
// come from lerp(from,to,t) of the per-instance world rect, then the camera affine,
// then the world→NDC map — all from uniforms, so one prebuilt buffer pair animates.
vertex VOut quad_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        device const GPUQuad *from [[buffer(0)]],
                        device const GPUQuad *to   [[buffer(1)]],
                        constant Uniforms &u       [[buffer(2)]]) {
    GPUQuad a = from[iid];
    GPUQuad b = to[iid];
    float t = u.t;

    // Settle-lerp the world rect (from → to). For a matched node the colour/style are
    // identical in both buffers; for an unmatched node from==to. Colour/style follow
    // the TARGET (`b`) — geometry morphs, colour snaps to the destination, exactly the
    // prior CPU settle behaviour.
    float2 origin = mix(float2(a.x, a.y), float2(b.x, b.y), t);
    float2 size   = mix(float2(a.w, a.h), float2(b.w, b.h), t);

    // Camera affine (world px → on-screen px). Identity during a settle.
    float2 sOrigin = origin * u.camScale + u.camTranslate;
    float2 sSize   = size * u.camScale;

    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    float2 px = sOrigin + corner * sSize;               // device px, top-left, y-down

    // world/device px → NDC (y-up).
    float2 ndc = float2(2.0 * px.x / u.viewport.x - 1.0,
                        1.0 - 2.0 * px.y / u.viewport.y);

    VOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.local = corner;
    o.color = float3(b.r, b.g, b.b);
    o.pixelSize = abs(sSize);
    o.style = b.style;
    o.highlight = (int(iid) == u.highlightIndex) ? 1.0 : 0.0;
    return o;
}

fragment float4 quad_fragment(VOut in [[stage_in]]) {
    float3 c = in.color;
    float minSide = min(in.pixelSize.x, in.pixelSize.y);
    float2 p = in.local * in.pixelSize;                     // pixel coords in tile
    float d = min(min(p.x, in.pixelSize.x - p.x),
                  min(p.y, in.pixelSize.y - p.y));           // distance to nearest edge

    if (in.style > 0.5 && in.style < 1.5) {
        // PENDING (outlined-dim): dark fill with a BRIGHT outline so a not-yet
        // -known region reads as an explicit placeholder, not empty canvas.
        if (minSide > 3.0 && d < 1.5) {
            c *= 2.2;                                        // bright edge
        } else {
            c *= 0.55;                                       // dim interior
        }
    } else if (in.style > 2.5) {
        // SYNTHETIC (unaccounted): reserved steel-grey fill with a diagonal HATCH so it
        // reads unmistakably as "not a folder" (VISION §"invisible space is first-class").
        // Hatch = periodic bright stripes along (x+y); a thin darker border like data tiles.
        float stripe = fmod(p.x + p.y, 12.0);
        if (stripe < 2.0) {
            c *= 1.7;                                        // bright hatch line
        }
        if (minSide > 3.0 && d < 1.0) {
            c *= 0.35;                                       // border
        }
    } else {
        // NORMAL data tile and DENIED tile: thin darker border so nested tiles
        // read as distinct rectangles (slivers stay solid — no border swallow).
        if (minSide > 3.0 && d < 1.0) {
            c *= 0.35;
        }
    }

    // HOVER HIGHLIGHT (TZ-3, VISION §Experience 3): applied LAST so it overrides
    // the border shading at the tile edge. The highlighted tile is the top-level
    // ancestor under the cursor; its outer edge sits in the inset frame that its
    // children do not cover, so a thin bright outline there reads clearly as "this
    // whole region", plus a modest fill lift. Kept subtle so it tells, not shouts.
    if (in.highlight > 0.5) {
        c *= 1.35;                                          // brightness lift
        if (minSide > 3.0 && d < 2.0) {
            c = float3(0.95, 0.98, 1.0);                    // thin bright outline
        }
    }
    return float4(c, 1.0);
}
