//
//  Shaders.metal — instanced-quad treemap shaders (runtime-compiled).
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  Shipped as SOURCE and compiled at runtime via `device.makeLibrary(source:)`
//  (glyph-saver heritage / PLAN.md: no build-time `metal` toolchain on this
//  machine). Both the App and scripts/verify_host.swift compile THIS file.
//
//  One draw call renders every tile as an instanced unit quad (ZapZap /
//  glyph-saver instanced-rect heritage): the vertex stage positions a corner of
//  the per-instance rect in NDC; the fragment stage fills it with the tile's
//  depth-dimmed color and darkens a thin 1px border band so nested tiles read as
//  distinct rectangles. See QuadRenderer.QuadInstance for the CPU mirror — field
//  order and sizes MUST match `QuadInstance` below.
//

#include <metal_stdlib>
using namespace metal;

// CPU mirror: QuadRenderer.QuadInstance (11 contiguous floats, 44-byte stride).
struct QuadInstance {
    float ox;   // origin x in NDC (top-left corner of the tile)
    float oy;   // origin y in NDC
    float sx;   // width in NDC (may be 0 for a degenerate tile)
    float sy;   // height in NDC (negative = downward in NDC, y-down → y-up flip)
    float r;
    float g;
    float b;
    float pw;   // tile width in device pixels (for the border band)
    float ph;   // tile height in device pixels
    float kd;   // style code: 0 normal, 1 pending (outlined-dim), 2 denied
    float hl;   // hover-highlight flag: 1 = lift fill + bright outline (TZ-3)
};

struct VOut {
    float4 position [[position]];
    float2 local;      // 0..1 within the tile
    float3 color;
    float2 pixelSize;  // tile size in device pixels
    float  style;      // QuadInstance.kd, flat across the tile
    float  highlight;  // QuadInstance.hl, flat across the tile
};

// Unit quad as a triangle strip: vertex ids 0..3 → (0,0)(1,0)(0,1)(1,1).
vertex VOut quad_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        device const QuadInstance *insts [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    QuadInstance q = insts[iid];
    float2 ndc = float2(q.ox, q.oy) + corner * float2(q.sx, q.sy);
    VOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.local = corner;
    o.color = float3(q.r, q.g, q.b);
    o.pixelSize = float2(q.pw, q.ph);
    o.style = q.kd;
    o.highlight = q.hl;
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
