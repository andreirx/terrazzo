//
//  UnaccountedSpaceTests.swift — the per-volume "Unaccounted" STATUS figure math.
//  Module maturity: PROTOTYPE (slice TZ-4; retargeted TZ-4b)
//
//  Pins the pure arithmetic behind the status-bar "Unaccounted" field (HUMAN FIELD
//  RULING 2026-08-16 #1 — a status figure, NEVER a map tile). Lives in ScanCore
//  (TZ-4b review-4 change 1): pure scan/volume accounting, beside `ScanProgress`.
//   1. residual = max(0, capacity − free − scanned), clamped ≥ 0 (a scanned total that
//      momentarily exceeds capacity − free — naive clone double-counting — yields an
//      honest zero, the ratified signal for a future dedup pass, not a negative figure).
//   2. decompose splits the residual into (purgeable, unknown) — ADDITIVE by construction
//      (purgeable + unknown == residual for EVERY input, review-4 change 2): the displayed
//      purgeable is capped at the residual it decomposes, so the readout never claims a
//      false split (a volume reporting more reclaimable than the residual).
//   3. figure composes both into the exact triple the status bar renders
//      ("Unaccounted X (purgeable Y + other/unknown Z)"), tested as ONE unit.
//

import XCTest
@testable import ScanCore

final class UnaccountedSpaceTests: XCTestCase {

    // MARK: 1. Residual sizing + clamp

    func testResidual() {
        XCTAssertEqual(UnaccountedSpace.residual(capacity: 1000, free: 200, scanned: 500), 300)
    }

    func testResidualClampsAtZeroWhenScannedExceedsCapacity() {
        // scanned + free > capacity (naive clone double-count) ⇒ honest zero, not negative.
        XCTAssertEqual(UnaccountedSpace.residual(capacity: 1000, free: 200, scanned: 900), 0)
    }

    // MARK: 2. decompose (ADDITIVE — the two parts always sum to the residual)

    func testDecomposeSplitsPurgeableAndUnknown() {
        let (purge, unknown) = UnaccountedSpace.decompose(residual: 300, purgeable: 120)
        XCTAssertEqual(purge, 120)
        XCTAssertEqual(unknown, 180)
        XCTAssertEqual(purge + unknown, 300, "decomposition is additive: purgeable + unknown == residual")
    }

    func testDecomposeIsAdditiveWhenPurgeableExceedsResidual() {
        // review-4 change 2: the volume can report MORE reclaimable than the residual
        // (reclaimable overlaps scanned bytes). The DISPLAYED purgeable must be capped at
        // the residual so the "Unaccounted = purgeable + other/unknown" readout adds up —
        // it must never show a purgeable component larger than the total it decomposes.
        let residual: Int64 = 100
        let (purge, unknown) = UnaccountedSpace.decompose(residual: residual, purgeable: 250)
        XCTAssertEqual(purge, 100, "displayed purgeable is capped at the residual it decomposes")
        XCTAssertEqual(unknown, 0, "unknown never goes negative")
        XCTAssertEqual(purge + unknown, residual,
                       "decomposition stays additive even when reclaimable exceeds the residual")
    }

    // MARK: 3. figure (the composed status triple the App renders)

    func testFigureComposesResidualAndDecomposition() {
        // capacity 1000 − free 200 − scanned 500 = 300 residual; purgeable 120 ⇒ unknown 180.
        let f = UnaccountedSpace.figure(capacity: 1000, free: 200, scanned: 500, purgeable: 120)
        XCTAssertEqual(f.total, 300)
        XCTAssertEqual(f.purgeable, 120)
        XCTAssertEqual(f.unknown, 180)
        XCTAssertEqual(f.purgeable + f.unknown, f.total, "the rendered triple is additive")
    }

    func testFigureDecompositionIsAdditiveWhenPurgeableExceedsResidual() {
        // The composed path (what StatusBar calls) is additive too — the purgeable > residual
        // regression the reviewer asked for, at the `figure` seam the App actually uses.
        let f = UnaccountedSpace.figure(capacity: 1000, free: 200, scanned: 750, purgeable: 900)
        XCTAssertEqual(f.total, 50, "residual = 1000 − 200 − 750")
        XCTAssertEqual(f.purgeable, 50, "displayed purgeable capped at the 50-byte residual, not the 900 reported")
        XCTAssertEqual(f.unknown, 0)
        XCTAssertEqual(f.purgeable + f.unknown, f.total,
                       "purgeable + other/unknown == Unaccounted even when reclaimable dwarfs the residual")
    }

    func testFigureIsZeroWhenVolumeReconciledOrUnknown() {
        // Fully reconciled (scanned + free == capacity) ⇒ total 0. Per VISION the field is
        // STILL shown by the App ("the number is always shown"); the math just yields zero.
        let reconciled = UnaccountedSpace.figure(capacity: 1000, free: 200, scanned: 800, purgeable: 50)
        XCTAssertEqual(reconciled.total, 0)
        XCTAssertEqual(reconciled.purgeable + reconciled.unknown, 0, "zero total decomposes to zero + zero")
        // Unknown capacity (probe failed / no volume) ⇒ total 0.
        XCTAssertEqual(UnaccountedSpace.figure(capacity: 0, free: 0, scanned: 500, purgeable: 0).total, 0)
    }
}
