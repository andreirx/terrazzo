//
//  FocusCameraTests.swift — the four gated properties of the refocus camera.
//  Module maturity: PROTOTYPE (slice TZ-3)
//
//  Pins FocusCamera (the glyph-saver CameraPlan pattern, adapted): endpoints
//  EXACT, scale MONOTONE, motion C1 (bounded per-frame deltas, eased ends), and
//  CONTAINMENT (a point inside both endpoint frames stays inside every
//  intermediate frame). Pure — no clock, no AppKit.
//

import XCTest
@testable import TreemapCore

final class FocusCameraTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 800, height: 600)
    // A dive target: some child rect strictly inside the viewport, arbitrary aspect.
    private let child = Rect(x: 120, y: 90, width: 240, height: 300)

    private func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool {
        abs(a - b) <= eps * max(1, max(abs(a), abs(b)))
    }
    private func assertRectApprox(_ a: Rect, _ b: Rect, _ eps: Double = 1e-6,
                                  _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: eps, msg, file: file, line: line)
    }

    // MARK: - fit

    func testFitMapsFrameCornersOntoViewport() {
        let t = FocusCamera.fit(frame: child, into: viewport)
        // frame origin → viewport origin; frame far corner → viewport far corner.
        let origin = t.apply(Point(x: child.x, y: child.y))
        let far = t.apply(Point(x: child.x + child.width, y: child.y + child.height))
        XCTAssertEqual(origin.x, viewport.x, accuracy: 1e-9)
        XCTAssertEqual(origin.y, viewport.y, accuracy: 1e-9)
        XCTAssertEqual(far.x, viewport.x + viewport.width, accuracy: 1e-6)
        XCTAssertEqual(far.y, viewport.y + viewport.height, accuracy: 1e-6)
    }

    func testFitOfViewportIsIdentity() {
        let t = FocusCamera.fit(frame: viewport, into: viewport)
        assertRectApprox(t.apply(child), child, 1e-9, "fitting the viewport onto itself is identity")
    }

    func testFitDegenerateFrameFallsBackToUnitScale() {
        let zeroW = Rect(x: 10, y: 10, width: 0, height: 100)
        let t = FocusCamera.fit(frame: zeroW, into: viewport)
        XCTAssertEqual(t.scaleX, 1, "zero-width frame → unit x-scale, not a divide-by-zero")
        XCTAssertGreaterThan(t.scaleY, 0)
    }

    // MARK: - Endpoints EXACT

    func testInterpolatedFrameEndpointsExact() {
        assertRectApprox(FocusCamera.interpolatedFrame(from: viewport, to: child, t: 0), viewport)
        assertRectApprox(FocusCamera.interpolatedFrame(from: viewport, to: child, t: 1), child)
    }

    func testTransformEndpointsFitEndpointFrames() {
        // t=0 fits `viewport` (identity); t=1 fits `child` exactly onto the viewport.
        let at0 = FocusCamera.transform(fromFrame: viewport, toFrame: child, viewport: viewport, t: 0)
        assertRectApprox(at0.apply(child), child, 1e-9, "t=0 is identity (whole world shown)")
        let at1 = FocusCamera.transform(fromFrame: viewport, toFrame: child, viewport: viewport, t: 1)
        // child fills the viewport at t=1.
        assertRectApprox(at1.apply(child), viewport, 1e-6, "t=1: child fills the viewport")
    }

    func testClampOutsideUnitInterval() {
        let below = FocusCamera.interpolatedFrame(from: viewport, to: child, t: -3)
        let above = FocusCamera.interpolatedFrame(from: viewport, to: child, t: 5)
        assertRectApprox(below, viewport, 1e-9, "t<0 clamps to the from-frame (static hold)")
        assertRectApprox(above, child, 1e-9, "t>1 clamps to the to-frame (static hold)")
    }

    // MARK: - Monotone SCALE

    func testScaleMonotoneAcrossAnimation() {
        var lastSX = -Double.infinity, lastSY = -Double.infinity
        let steps = 200
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let tr = FocusCamera.transform(fromFrame: viewport, toFrame: child, viewport: viewport, t: t)
            // Diving into a smaller child ⇒ scale strictly grows (no overshoot/reversal).
            XCTAssertGreaterThanOrEqual(tr.scaleX, lastSX - 1e-12, "scaleX must be monotone non-decreasing")
            XCTAssertGreaterThanOrEqual(tr.scaleY, lastSY - 1e-12, "scaleY must be monotone non-decreasing")
            lastSX = tr.scaleX; lastSY = tr.scaleY
        }
        // End scale > start scale (zoom actually happened).
        let s0 = FocusCamera.transform(fromFrame: viewport, toFrame: child, viewport: viewport, t: 0)
        let s1 = FocusCamera.transform(fromFrame: viewport, toFrame: child, viewport: viewport, t: 1)
        XCTAssertGreaterThan(s1.scaleX, s0.scaleX)
        XCTAssertGreaterThan(s1.scaleY, s0.scaleY)
    }

    // MARK: - C1 (bounded per-frame deltas; eased ends)

    func testC1EasedEndsSlowerThanMiddle() {
        // Sample frame width along t; per-step deltas near the ends must be smaller
        // than in the middle (smoothstep has zero derivative at 0 and 1). This is
        // the glyph-saver anti-jump gate.
        let steps = 100
        func width(_ t: Double) -> Double {
            FocusCamera.interpolatedFrame(from: viewport, to: child, t: t).width
        }
        func delta(around i: Int) -> Double {
            let t0 = Double(i) / Double(steps), t1 = Double(i + 1) / Double(steps)
            return abs(width(t1) - width(t0))
        }
        let startDelta = delta(around: 0)
        let endDelta = delta(around: steps - 1)
        let midDelta = delta(around: steps / 2)
        XCTAssertLessThan(startDelta, midDelta, "eased-in: start moves slower than the middle")
        XCTAssertLessThan(endDelta, midDelta, "eased-out: end moves slower than the middle")
    }

    func testPerFrameDeltasBounded() {
        // No single 60 Hz step may jump more than a sane fraction of the total
        // travel — the bounded-delta half of the anti-jump gate.
        let fps = 1.0 / 60.0
        let dur = FocusCamera.refocusDurationSeconds
        let totalTravel = abs(child.width - viewport.width)
        var maxStep = 0.0
        var elapsed = 0.0
        var prev = FocusCamera.interpolatedFrame(from: viewport, to: child, t: 0).width
        while elapsed <= dur {
            elapsed += fps
            let t = min(1.0, elapsed / dur)
            let w = FocusCamera.interpolatedFrame(from: viewport, to: child, t: t).width
            maxStep = max(maxStep, abs(w - prev))
            prev = w
        }
        // Smoothstep peak slope is 1.5, over ~21 frames ⇒ each step ≪ total.
        XCTAssertLessThan(maxStep, totalTravel * 0.15, "no per-frame jump")
        XCTAssertGreaterThan(FocusCamera.refocusDurationSeconds, 0)
    }

    // MARK: - Containment (convex-combination edges)

    func testContainmentOfPointInsideBothEndpoints() {
        // The child's center is inside both the viewport and the child, so it must
        // lie inside every interpolated frame.
        let p = Point(x: child.x + child.width / 2, y: child.y + child.height / 2)
        for i in 0...50 {
            let t = Double(i) / 50.0
            let f = FocusCamera.interpolatedFrame(from: viewport, to: child, t: t)
            XCTAssertTrue(f.contains(p) || onClosedBoundary(p, f),
                          "point inside both endpoints must stay inside frame at t=\(t)")
        }
    }

    private func onClosedBoundary(_ p: Point, _ r: Rect) -> Bool {
        p.x >= r.x - 1e-9 && p.x <= r.x + r.width + 1e-9 &&
        p.y >= r.y - 1e-9 && p.y <= r.y + r.height + 1e-9
    }

    // MARK: - Inverse (zoom out)

    func testZoomOutIsInverseDirection() {
        // Zoom OUT: from child-fills-viewport back to the parent (identity). Scale
        // must SHRINK over t (opposite of the dive).
        let s0 = FocusCamera.transform(fromFrame: child, toFrame: viewport, viewport: viewport, t: 0)
        let s1 = FocusCamera.transform(fromFrame: child, toFrame: viewport, viewport: viewport, t: 1)
        XCTAssertGreaterThan(s0.scaleX, s1.scaleX, "zoom-out scale shrinks")
        XCTAssertEqual(s1.scaleX, 1, accuracy: 1e-9, "ends at identity (parent fills viewport)")
    }
}
