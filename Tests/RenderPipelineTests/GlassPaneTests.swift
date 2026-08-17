//
//  GlassPaneTests.swift — the TZ-8 glass-pane depth tint, on the REAL colour path.
//  Module maturity: PROTOTYPE (slice TZ-8)
//
//  WHAT THIS PINS (PLAN §"TZ-8", ratified 2026-08-17). A tile now carries its colour at
//  BOTH ends of the dive dissolve — `r/g/b` (REST/paned, dissolveT = 0) and
//  `ownR/ownG/ownB` (DIVED/own-hue, dissolveT = 1) — precomputed by `QuadBuilder.quad`;
//  the shader blends them by one `dissolveT` uniform (mirrored headlessly by
//  `QuadBuilder.displayedColor`). These tests drive the ACTUAL production colour path
//  (`QuadBuilder`) over the ACTUAL render type (`GPUQuad`), so there is no second model.
//
//  The ratified invariants (packet deliverable 5). NOTE these describe PIPELINE-SCENE quads
//  (`QuadBuilder.quad`); the ascend camera-handoff quads (`QuadGeometry.embedChild`) repurpose
//  the same two slots as flight start/end DISPLAYED endpoints — see GPUQuad.swift's struct doc
//  and `testAscendReCondensesToParentPane` below.
//   1. DIVED endpoint == today's OWN-hue rendering (exact): a deep tile's `ownR/G/B`
//      equals the colour a HUE ROOT of the same name/depth renders — the tile's own name hue
//      through the dim ladder. Its HUE (chromaticity) is name-derived and focus-invariant; its
//      RGB VALUE is NOT — brightness follows the dim ladder and `dimLevel` is focus-relative, so
//      the same name renders a darker own RGB when it is a deeper descendant. (Each check below
//      fixes the depth, so it pins the hue identity AT that depth, not RGB focus-invariance.)
//   2. REST endpoint == today's INHERITED (pane) rendering, composed: at a hue root
//      rest == own EXACTLY (own == pane there); for a deep descendant rest is the pane
//      composited over own at `paneRestAlpha` (0.5) — the pane hue contributes exactly
//      that fraction (the "within epsilon of the inherited hue" the packet states, made
//      exact as the 0.5 composite the ratified model defines).
//   3. The dissolve is MONOTONE in t and ASCEND (1−t) is its exact reverse.
//   4. RESERVED colours (denied / pending) are UNAFFECTED by the dissolve — both endpoints
//      are the same reserved colour, so the pane never touches them (VISION invisible-space).
//   5. The dim ladder composes MULTIPLICATIVELY with the pane (deeper ⇒ dimmer, both ends).
//
//  Constant-free by construction: every "expected" colour is obtained by asking
//  `QuadBuilder` for a reference tile (a hue root == the pure own/pane colour), never by
//  re-deriving the private saturation/brightness constants — so the test cannot drift from
//  the builder's tuning, only from its STRUCTURE.
//

import XCTest
import ScanCore
import TreemapCore
@testable import RenderPipeline

final class GlassPaneTests: XCTestCase {
    private let unit = Rect(x: 0, y: 0, width: 100, height: 100)
    private let eps: Float = 1e-5

    /// A data tile with an explicit pane (inherited) hue + own name, at `dimLevel`.
    private func dataTile(name: String, paneHue: Double, dimLevel: Int) -> TileRect {
        TileRect(rect: unit, dimLevel: dimLevel, nodeId: name, kind: .dir,
                 scanState: .complete, hue: paneHue, name: name,
                 allocatedBytes: 1, logicalBytes: 1)
    }

    /// A HUE ROOT: pane hue == the name's own hue (exactly what `TreemapScene` builds for
    /// focus/level-1 tiles). Its colour IS the pure own-hue rendering at `dimLevel`.
    private func hueRoot(name: String, dimLevel: Int) -> TileRect {
        dataTile(name: name, paneHue: TileColor.hue(for: name), dimLevel: dimLevel)
    }

    private func rgb(_ q: GPUQuad) -> (Float, Float, Float) { (q.r, q.g, q.b) }
    private func ownRGB(_ q: GPUQuad) -> (Float, Float, Float) { (q.ownR, q.ownG, q.ownB) }
    private func assertClose(_ a: (Float, Float, Float), _ b: (Float, Float, Float),
                             _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.0, b.0, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.1, b.1, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.2, b.2, accuracy: eps, msg, file: file, line: line)
    }

    // MARK: - 1. Dived endpoint reproduces today's own-hue rendering exactly

    func testDivedEndpointIsOwnHueRendering() {
        // A deep descendant whose pane hue (an ancestor's) differs from its own name hue.
        for depth in 1...4 {
            let deep = QuadBuilder.quad(for: dataTile(name: "Child", paneHue: TileColor.hue(for: "Ancestor"),
                                                      dimLevel: depth))
            // The pure own-hue rendering at this depth == a hue root of the same name/depth.
            let ownRef = QuadBuilder.quad(for: hueRoot(name: "Child", dimLevel: depth))
            assertClose(ownRGB(deep), rgb(ownRef),
                        "dived (dissolveT=1) colour must equal today's own-hue rendering at depth \(depth)")
            // And the shader mirror agrees at the endpoint.
            assertClose(QuadBuilder.displayedColor(deep, dissolveT: 1), ownRGB(deep),
                        "displayedColor(1) == own colour")
        }
    }

    // MARK: - 2. Rest endpoint: exact at hue roots, 0.5 pane-composite deeper

    func testRestEndpointAtHueRootReproducesTodayExactly() {
        // At a hue root own == pane, so REST == OWN == today's (inherited==own) rendering — the
        // dive dissolve is a visual no-op on a hue root (its pane covers ITS CHILDREN, not it).
        for depth in 0...2 {
            let root = QuadBuilder.quad(for: hueRoot(name: "Library", dimLevel: depth))
            assertClose(rgb(root), ownRGB(root),
                        "hue-root rest colour equals its own colour exactly (depth \(depth))")
            assertClose(QuadBuilder.displayedColor(root, dissolveT: 0),
                        QuadBuilder.displayedColor(root, dissolveT: 1),
                        "dissolve is a no-op on a hue root")
        }
    }

    func testRestEndpointIsPaneOverOwnAtRestAlpha() {
        let depth = 2
        let deep = QuadBuilder.quad(for: dataTile(name: "Child", paneHue: TileColor.hue(for: "Ancestor"),
                                                  dimLevel: depth))
        let ownRef = QuadBuilder.quad(for: hueRoot(name: "Child", dimLevel: depth))     // pure own
        let paneRef = QuadBuilder.quad(for: hueRoot(name: "Ancestor", dimLevel: depth)) // pure pane (== today's inherited)
        // REST = mix(own, pane, paneRestAlpha): the pane (inherited hue) contributes EXACTLY
        // paneRestAlpha, the own hue the remainder — the ratified glass composite.
        let expected = QuadBuilder.mix3(rgb(ownRef), rgb(paneRef), QuadBuilder.paneRestAlpha)
        assertClose(rgb(deep), expected,
                    "rest colour is the pane composited over own at paneRestAlpha (\(QuadBuilder.paneRestAlpha))")
        // The pane hue must genuinely differ from own here, else the test proves nothing.
        XCTAssertNotEqual(rgb(ownRef).0, rgb(paneRef).0, accuracy: 0, "distinct pane vs own hue for the composite test")
        // "within epsilon of today's inherited rendering": rest sits paneRestAlpha of the way
        // from own toward the inherited (pane) colour — closer to today than pure own is.
        func dist(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }
        XCTAssertLessThan(dist(rgb(deep), rgb(paneRef)), dist(ownRGB(deep), rgb(paneRef)),
                          "rest is nearer the inherited (pane) colour than the dived (own) colour is")
    }

    // MARK: - 3. Dissolve monotone in t; ascend RE-CONDENSES to the parent pane (production path)

    func testDissolveMonotoneInT() {
        let deep = QuadBuilder.quad(for: dataTile(name: "Child", paneHue: TileColor.hue(for: "Ancestor"),
                                                  dimLevel: 2))
        let rest = rgb(deep), own = ownRGB(deep)
        var prev = QuadBuilder.displayedColor(deep, dissolveT: 0)
        assertClose(prev, rest, "displayedColor(0) == rest")
        let steps = 20
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let c = QuadBuilder.displayedColor(deep, dissolveT: t)
            // Each channel moves monotonically from rest toward own (direction per channel).
            for (cur, (p, (r0, o0))) in zip([c.0, c.1, c.2],
                                            zip([prev.0, prev.1, prev.2],
                                                zip([rest.0, rest.1, rest.2], [own.0, own.1, own.2]))) {
                if o0 >= r0 { XCTAssertGreaterThanOrEqual(cur, p - eps, "channel non-decreasing toward own") }
                else { XCTAssertLessThanOrEqual(cur, p + eps, "channel non-increasing toward own") }
            }
            prev = c
        }
        assertClose(prev, own, "displayedColor(1) == own")
    }

    /// The ascend RE-CONDENSATION on the PRODUCTION handoff path (review-0 item 1; item 3
    /// replaces the prior tautological ascend test). Builds a child scene and a parent scene
    /// through the REAL colour path (`QuadBuilder`), runs the REAL `QuadGeometry.embedChild`
    /// the NavigationController ascend calls, and proves the resulting flight base makes a
    /// shared tile MORPH from the child-focus colour to the parent-focus paned colour:
    ///   - at dissolveT = 1 (the ascend flight START) it shows the CHILD scene's displayed
    ///     colour (opens exactly on what is on screen — no snap); and
    ///   - at dissolveT = 0 (the flight END) it shows the CACHED PARENT scene's paned colour
    ///     (the pane re-condenses before the commit, so the commit finds it already correct).
    /// The two endpoints must genuinely DIFFER (the pane actually re-condenses), the sweep is
    /// monotone, and the ascend dissolve sequence (1→0) is the exact reverse of the dive
    /// sequence (0→1) — a real statement about two distinct sample sets, not a self-compare.
    func testAscendReCondensesToParentPane() {
        // CHILD scene (focus = C, on screen when we start to ascend): C is a hue root at
        // dimLevel 0 filling the viewport; its child X is a hue root at dimLevel 1.
        let cChild = hueRoot(name: "C", dimLevel: 0) // rect == unit (fills the viewport)
        let xChild = TileRect(rect: Rect(x: 10, y: 10, width: 40, height: 40), dimLevel: 1,
                              nodeId: "X", kind: .dir, scanState: .complete,
                              hue: TileColor.hue(for: "X"), name: "X", allocatedBytes: 1, logicalBytes: 1)
        let childQuads = QuadBuilder.build(tiles: [cChild, xChild])
        let childNodeIds = ["C", "X"]

        // PARENT scene (focus = P, the cached world we ascend back into): P is a hue root at
        // dimLevel 0; C is a hue root at dimLevel 1 occupying its slot `childRect`; X is now a
        // dimLevel-2 DESCENDANT, paned under C (X inherits C's hue). X is therefore one dim
        // level DEEPER (dimmer own hue) AND panned here — exactly the re-condensation target.
        let childRect = Rect(x: 0, y: 0, width: 50, height: 50) // C's slot in the parent
        let pParent = hueRoot(name: "P", dimLevel: 0)
        let cParent = TileRect(rect: childRect, dimLevel: 1, nodeId: "C", kind: .dir,
                               scanState: .complete, hue: TileColor.hue(for: "C"), name: "C",
                               allocatedBytes: 1, logicalBytes: 1)
        let xParent = dataTile(name: "X", paneHue: TileColor.hue(for: "C"), dimLevel: 2)
        let parentQuads = QuadBuilder.build(tiles: [pParent, cParent, xParent])
        let parentNodeIds = ["P", "C", "X"]

        // The PRODUCTION ascend base (the exact NavigationController.ascend call).
        let base = QuadGeometry.embedChild(
            childQuads: childQuads, childNodeIds: childNodeIds, into: childRect,
            parentQuads: parentQuads, parentNodeIds: parentNodeIds, childId: "C")
        guard let bxi = base.nodeIds.firstIndex(of: "X") else { return XCTFail("X missing from ascend base") }
        let bX = base.quads[bxi]

        // The two references, straight off the production colour path.
        let childXDisplayed = rgb(childQuads[1]) // X in the child scene renders at rest (== its own hue @1)
        let parentXPaned = rgb(parentQuads[2])   // X in the parent scene = pane over own @0.5, dimmer

        // The endpoints the ascend flight actually SHOWS (via the shader mirror).
        assertClose(QuadBuilder.displayedColor(bX, dissolveT: 1), childXDisplayed,
                    "ascend opens (dissolveT=1) on the child scene's displayed colour — no snap")
        assertClose(QuadBuilder.displayedColor(bX, dissolveT: 0), parentXPaned,
                    "ascend ends (dissolveT=0) on the cached parent scene's PANED colour — re-condensed")

        // The re-condensation is REAL: the two endpoints differ (the pane genuinely appears as
        // we ascend). If they were equal the test would prove nothing.
        func dist(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }
        XCTAssertGreaterThan(dist(childXDisplayed, parentXPaned), 10 * eps,
                             "the child-focus and parent-paned colours must differ — the pane re-condenses")

        // The FOCUS tile C itself also re-condenses: opens on its child-focus colour (dimLevel 0,
        // fills the viewport), ends on its parent-focus colour (dimLevel 1, one ladder step dimmer).
        guard let bci = base.nodeIds.firstIndex(of: "C") else { return XCTFail("C missing from ascend base") }
        assertClose(QuadBuilder.displayedColor(base.quads[bci], dissolveT: 1), rgb(childQuads[0]),
                    "focus C opens on its child-focus colour")
        assertClose(QuadBuilder.displayedColor(base.quads[bci], dissolveT: 0), rgb(parentQuads[1]),
                    "focus C ends on its parent-focus colour")

        // As the ascend flight drives dissolveT 1→0, each channel moves MONOTONICALLY from the
        // child-displayed colour toward the parent-paned colour (no reversal, no overshoot).
        // The dive/ascend DIRECTION itself (dive drives 0→1, ascend 1→0) is set by the App
        // driver's `dissolveFrom`/`dissolveTo` literals — not linkable to `swift test` — so the
        // pure layer pins the two ENDPOINTS (above) and this monotone sweep between them, which
        // together fully determine the ascend trajectory as the reverse of the dive trajectory.
        let steps = 20
        var last = childXDisplayed // ascend starts at dissolveT = 1 (child displayed)
        for i in 1...steps {
            let f = Float(i) / Float(steps)
            let ascend = QuadBuilder.displayedColor(bX, dissolveT: 1 - f) // ascend drives 1→0
            let chans = [(ascend.0, last.0, childXDisplayed.0, parentXPaned.0),
                         (ascend.1, last.1, childXDisplayed.1, parentXPaned.1),
                         (ascend.2, last.2, childXDisplayed.2, parentXPaned.2)]
            for (cur, prevC, from, to) in chans {
                if to >= from { XCTAssertGreaterThanOrEqual(cur, prevC - eps, "channel non-decreasing toward parent paned") }
                else { XCTAssertLessThanOrEqual(cur, prevC + eps, "channel non-increasing toward parent paned") }
            }
            last = ascend
        }
        assertClose(last, parentXPaned, "ascend sweep lands on the parent paned colour")
    }

    // MARK: - 4. Reserved colours (denied / pending) never participate in panes

    func testReservedColoursUnaffectedByDissolve() {
        let denied = TileRect(rect: unit, dimLevel: 2, nodeId: "d", kind: .denied,
                              scanState: .complete, hue: TileColor.hue(for: "Ancestor"), name: "d")
        let pending = TileRect(rect: unit, dimLevel: 2, nodeId: "p", kind: .dir,
                               scanState: .pending, hue: TileColor.hue(for: "Ancestor"), name: "p")
        let aggregate = TileRect(rect: unit, dimLevel: 2, nodeId: "agg", kind: .denied,
                                 scanState: .complete, hue: TileColor.hue(for: "Ancestor"),
                                 name: "9 denied items", deniedAggregateCount: 9)
        for t in [denied, pending, aggregate] {
            let q = QuadBuilder.quad(for: t)
            assertClose(rgb(q), ownRGB(q), "reserved tile: both dissolve endpoints are the same reserved colour")
            for d: Float in [0, 0.25, 0.5, 0.75, 1] {
                assertClose(QuadBuilder.displayedColor(q, dissolveT: d), rgb(q),
                            "reserved colour is constant across the dissolve (t=\(d)) — never paned")
            }
        }
    }

    // MARK: - 4b. The DIVE brightness REBASE (OPERATOR_NOTE #5): one dim step, reserved-safe

    /// The rebase mechanism note #5 ratified, pinned purely (the shader mirror `displayedColor`).
    ///  (a) `diveRebaseEnd` is EXACTLY one dim-ladder step (1/dimFalloff).
    ///  (b) Rebasing a NORMAL tile's dived endpoint by `diveRebaseEnd` renders it one dim step
    ///      SHALLOWER — literally the own-hue rendering at `depth-1` (this is WHY old-t=1 lands on
    ///      the incoming scene's rest at commit; the handoff identity, in the pure layer).
    ///  (c) RESERVED colours (denied/pending/aggregate) are NEVER rebased — any factor leaves them
    ///      exactly their reserved colour, so reserved handoff stays factor-1 (deliverable 4/5e).
    func testDiveRebaseIsOneDimStepAndSkipsReserved() {
        // (a) the endpoint is exactly one ladder step.
        XCTAssertEqual(QuadBuilder.diveRebaseEnd, 1 / QuadBuilder.dimFalloff, accuracy: 0,
                       "diveRebaseEnd is exactly one dim-ladder step (1/dimFalloff)")

        // (b) rebased dived endpoint == own rendering one step shallower.
        for depth in 1...4 {
            let deep = QuadBuilder.quad(for: dataTile(name: "Child", paneHue: TileColor.hue(for: "Ancestor"),
                                                      dimLevel: depth))
            let rebasedDived = QuadBuilder.displayedColor(deep, dissolveT: 1,
                                                          brightnessRebase: QuadBuilder.diveRebaseEnd)
            let shallowerOwn = ownRGB(QuadBuilder.quad(for: hueRoot(name: "Child", dimLevel: depth - 1)))
            assertClose(rebasedDived, shallowerOwn,
                        "dive rebase brightens the dived endpoint by exactly one dim step (depth \(depth))")
        }

        // (c) reserved colours ignore the rebase entirely.
        let denied = TileRect(rect: unit, dimLevel: 2, nodeId: "d", kind: .denied,
                              scanState: .complete, hue: TileColor.hue(for: "Ancestor"), name: "d")
        let pending = TileRect(rect: unit, dimLevel: 2, nodeId: "p", kind: .dir,
                               scanState: .pending, hue: TileColor.hue(for: "Ancestor"), name: "p")
        let aggregate = TileRect(rect: unit, dimLevel: 2, nodeId: "agg", kind: .denied,
                                 scanState: .complete, hue: TileColor.hue(for: "Ancestor"),
                                 name: "9 denied items", deniedAggregateCount: 9)
        for t in [denied, pending, aggregate] {
            let q = QuadBuilder.quad(for: t)
            for d: Float in [0, 0.5, 1] {
                for rebase: Float in [QuadBuilder.diveRebaseEnd, 2.0, 0.3] {
                    assertClose(QuadBuilder.displayedColor(q, dissolveT: d, brightnessRebase: rebase), rgb(q),
                                "reserved colour ignores the dive rebase (t=\(d), rebase=\(rebase))")
                }
            }
        }
    }

    // MARK: - 5. The dim ladder composes multiplicatively with the pane (deeper ⇒ dimmer)

    func testDimLadderComposesWithBothEndpoints() {
        // Same tile identity at increasing depth: both the rest and the own colours darken
        // monotonically (brightness = base·falloff^dimLevel, applied within each hue).
        var prevRestLum: Float = .greatestFiniteMagnitude
        var prevOwnLum: Float = .greatestFiniteMagnitude
        // Rec.709 relative luminance (name honesty, review-5) — the standard linear brightness of
        // an RGB colour. Any positive-weighted metric witnesses this dim-ladder monotonicity (a
        // uniform brightness scale dims every channel together), but naming it "luminance" now
        // means the real thing, matching `lum` in QuadGeometryTests.
        func lum(_ c: (Float, Float, Float)) -> Float { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
        for depth in 0...5 {
            let q = QuadBuilder.quad(for: dataTile(name: "Child", paneHue: TileColor.hue(for: "Ancestor"),
                                                   dimLevel: depth))
            let restLum = lum(rgb(q)), ownLum = lum(ownRGB(q))
            XCTAssertLessThanOrEqual(restLum, prevRestLum + eps, "rest colour dims with depth \(depth)")
            XCTAssertLessThanOrEqual(ownLum, prevOwnLum + eps, "own colour dims with depth \(depth)")
            prevRestLum = restLum; prevOwnLum = ownLum
        }
    }
}
