//
//  FocusCamera.swift — the animated refocus transform (world → view).
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  PROVENANCE: this is the glyph-saver CameraPlan pattern
//  (../glyph-saver/Sources/GlyphCore/CameraPlan.swift, ratified GS-3:
//  "anticipatory keyframes + C1 interpolation"), ADAPTED and SIMPLIFIED. There,
//  the camera anticipated a whole chain of letter keyframes over a proverb; HERE
//  a navigation action has exactly TWO keyframes — the current world-frame and
//  the target world-frame — so the keyframe machinery collapses to a single
//  smoothstep segment between (fromFrame, toFrame). The C1 / monotone-scale /
//  exact-endpoint properties are inherited from the same smoothstep-of-a-convex-
//  combination construction; the containment reasoning is likewise the same.
//
//  WHAT A "FRAME" IS
//  -----------------
//  The world is a `TreemapScene.layout` at a fixed focus: the focus node fills
//  the viewport, children tile it. A refocus does NOT re-tile mid-animation —
//  instead the App holds that world FIXED and moves a CAMERA over it. A `frame`
//  is the world-space rectangle currently mapped onto the whole viewport:
//    - dive into child C: from = the viewport itself (identity, whole world
//      shown) → to = C's world rect (C grows to fill the viewport);
//    - zoom out to parent: the INVERSE — from = the child's rect within the
//      re-laid-out parent world → to = that parent world's viewport (identity).
//  The App commits the focus swap at t=1 (re-layout with the new focus), when the
//  camera has already scaled the target to exactly fill the viewport, so the swap
//  is visually continuous.
//
//  NON-UNIFORM (per-axis) SCALE — deliberate, and unlike glyph-saver's uniform
//  camera. A treemap tile has an arbitrary aspect ratio; making it FILL the
//  viewport requires independent x/y scale, which is exactly what the committed
//  re-layout also does (the focus node is stretched to the viewport aspect). A
//  uniform camera would letterbox and then JUMP at the commit; per-axis fit lands
//  the animation on the committed layout with no jump.
//
//  THE FOUR GATED PROPERTIES (FocusCameraTests)
//  --------------------------------------------
//    - Endpoints EXACT: smoothstep(0)=0, smoothstep(1)=1 ⇒ frame(0)=fromFrame,
//      frame(1)=toFrame identically; the fit of a viewport-sized frame is the
//      identity transform.
//    - Monotone SCALE: frame.width(t)=lerp(fromW,toW,smoothstep(t)) is monotone
//      in t (smoothstep monotone; lerp monotone in its parameter), and
//      scaleX=viewport.width/frame.width is a monotone function of a monotone
//      positive quantity ⇒ scaleX is monotone across the whole animation (ditto
//      y). No overshoot, no zoom reversal.
//    - C1 (no velocity jump — the glyph-saver anti-jump gate): smoothstep has
//      zero derivative at both ends, so d(frame)/dt = 0 at t=0 and t=1; the
//      animation eases in and eases out, joining the static holds before/after
//      with matching (zero) velocity. The test bounds per-frame deltas and checks
//      the endpoints move slower than the middle.
//    - Edges are CONVEX COMBINATIONS of the endpoint frames (frame edges are
//      lerps), so any world point inside BOTH endpoint frames stays inside every
//      intermediate frame — the same containment guarantee glyph-saver proved.
//
//  PURITY: Foundation-free, deterministic pure function of t. No AppKit, no time
//  source — the App supplies t = elapsed / refocusDurationSeconds. (CLAUDE.md
//  hard constraint 1; the App owns the clock.)
//
//  ABSTRACTION LEDGER: `ViewTransform` is a raw DTO (4 Doubles) crossing to the
//  App renderer — no framework types (boundary rule). `FocusCamera` is a
//  namespace of pure functions. One concrete user (NavigationController). No
//  protocol/registry — one camera, one axis of use; rejected inlining the math in
//  the App, which would lose the pure test seam this deliverable requires.
//

/// An affine world→view transform with INDEPENDENT per-axis scale:
/// `view = world · scale + translate` componentwise. Maps a world `frame`
/// exactly onto a viewport rectangle (see `FocusCamera.fit`).
public struct ViewTransform: Equatable, Sendable {
    public let scaleX: Double
    public let scaleY: Double
    public let translateX: Double
    public let translateY: Double

    public init(scaleX: Double, scaleY: Double, translateX: Double, translateY: Double) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.translateX = translateX
        self.translateY = translateY
    }

    /// The identity transform (world coordinates pass through unchanged).
    public static let identity = ViewTransform(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0)

    public func apply(_ r: Rect) -> Rect {
        Rect(x: r.x * scaleX + translateX,
             y: r.y * scaleY + translateY,
             width: r.width * scaleX,
             height: r.height * scaleY)
    }

    public func apply(_ p: Point) -> Point {
        Point(x: p.x * scaleX + translateX, y: p.y * scaleY + translateY)
    }
}

public enum FocusCamera {
    /// Refocus animation duration (VISION §Experience 4 "animated refocus"; packet
    /// TZ-3 "~350 ms"). Named so the App's 60 Hz driver and the tests agree.
    public static let refocusDurationSeconds: Double = 0.35

    /// The world→view transform at animation parameter `t ∈ [0,1]` for a refocus
    /// that moves the world-frame filling the viewport from `fromFrame` to
    /// `toFrame`. `t` is clamped to [0,1] (a static hold outside the interval).
    ///
    /// - t = 0 → `fromFrame` fills the viewport (exact);
    /// - t = 1 → `toFrame` fills the viewport (exact).
    public static func transform(fromFrame: Rect, toFrame: Rect,
                                 viewport: Rect, t: Double) -> ViewTransform {
        let frame = interpolatedFrame(from: fromFrame, to: toFrame, t: t)
        return fit(frame: frame, into: viewport)
    }

    /// The interpolated world-frame at `t`: every edge is `lerp(from, to,
    /// smoothstep(clamp01(t)))`. Exposed (not just used internally) so tests can
    /// pin the frame geometry directly, independent of the fit step.
    public static func interpolatedFrame(from a: Rect, to b: Rect, t: Double) -> Rect {
        let tau = smoothstep(clamp01(t))
        return Rect(x: lerp(a.x, b.x, tau),
                    y: lerp(a.y, b.y, tau),
                    width: lerp(a.width, b.width, tau),
                    height: lerp(a.height, b.height, tau))
    }

    /// The transform mapping world `frame` exactly onto viewport `vp`
    /// (frame origin → vp origin, frame far corner → vp far corner). A degenerate
    /// (zero-width/height) frame falls back to unit scale on that axis rather than
    /// dividing by zero — honest no-op, not a crash.
    public static func fit(frame: Rect, into vp: Rect) -> ViewTransform {
        let sx = frame.width > 0 ? vp.width / frame.width : 1
        let sy = frame.height > 0 ? vp.height / frame.height : 1
        return ViewTransform(scaleX: sx, scaleY: sy,
                             translateX: vp.x - frame.x * sx,
                             translateY: vp.y - frame.y * sy)
    }

    // MARK: - Pure math

    /// Smoothstep on [0,1]: monotone, zero derivative at both ends (⇒ C1 joins
    /// and eased start/stop). Identical form to glyph-saver's CameraPlan.
    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
