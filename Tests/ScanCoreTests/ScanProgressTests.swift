//
//  ScanProgressTests.swift — the pure file-count progress arithmetic (TZ-4 D10).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  Pins the load-bearing invariants of the ratified progress model (PLAN §TZ-4):
//   1. INDETERMINATE when the denominator is unknown (no statfs) — fraction/ETA nil,
//      so the App shows a barber-pole, never a fake 0 %.
//   2. CLAMP strictly below 1 while running — a VOLUME-WIDE denominator (it counts
//      inodes the scan can never reach: other users' homes, TCC areas) must not let
//      the bar claim completion mid-scan.
//   3. SNAP to 1 exactly on completion (`running == false`), even if the numerator
//      plateaued below the denominator — the honest "done" signal.
//   4. ETA extrapolation: nil when there is no basis (done / no rate / indeterminate),
//      else remaining ÷ measured rate.
//

import XCTest
@testable import ScanCore

final class ScanProgressTests: XCTestCase {

    // NOTE (TZ-4b): percentage/ETA are honest ONLY for a volume-root scan (OPERATOR_NOTE
    // #2 item 2), so every test that expects a non-nil fraction/ETA sets `isVolumeRoot:
    // true`; the subtree-suppression rule has its own section (6) below.

    // MARK: 1. Indeterminate (no denominator)

    func testUnknownDenominatorIsIndeterminate() {
        let p = ScanProgress(filesProcessed: 500, usedInodes: 0, running: true, isVolumeRoot: true)
        XCTAssertNil(p.fraction, "no statfs denominator ⇒ indeterminate bar, not a fake fraction")
        XCTAssertNil(p.remainingInodes)
        XCTAssertNil(p.etaSeconds(filesPerSecond: 1000))
    }

    // MARK: 2. Clamp below 100 % while running

    func testRunningFractionClampsBelowOne() {
        // Numerator already exceeds the (volume-wide) denominator: raw > 1.
        let p = ScanProgress(filesProcessed: 2_000, usedInodes: 1_000, running: true, isVolumeRoot: true)
        XCTAssertEqual(p.fraction!, ScanProgress.maxRunningFraction, accuracy: 1e-12,
                       "a running bar must never reach 1 — denied/other-user inodes inflate the denominator")
        XCTAssertLessThan(p.fraction!, 1.0)
    }

    func testRunningFractionIsRawWhenBelowCap() {
        let p = ScanProgress(filesProcessed: 250, usedInodes: 1_000, running: true, isVolumeRoot: true)
        XCTAssertEqual(p.fraction!, 0.25, accuracy: 1e-12)
    }

    func testRunningFractionNeverNegative() {
        // filesProcessed can't be negative in practice, but the min/max guard must hold.
        let p = ScanProgress(filesProcessed: 0, usedInodes: 1_000, running: true, isVolumeRoot: true)
        XCTAssertEqual(p.fraction!, 0.0, accuracy: 1e-12)
    }

    // MARK: 3. Snap to done on completion

    func testCompletedSnapsToOneEvenBelowDenominator() {
        // The scan finished having stat'd far fewer than the volume-wide inode count
        // (the rest were unreachable). The bar must snap to 1, not sit at 0.4.
        let p = ScanProgress(filesProcessed: 400, usedInodes: 1_000, running: false, isVolumeRoot: true)
        XCTAssertEqual(p.fraction!, 1.0, accuracy: 1e-12, "completion snaps to done")
    }

    func testCompletedWithUnknownDenominatorStillIndeterminate() {
        let p = ScanProgress(filesProcessed: 400, usedInodes: 0, running: false, isVolumeRoot: true)
        XCTAssertNil(p.fraction, "no denominator ⇒ indeterminate even when done")
    }

    // MARK: 4. Remaining inodes

    func testRemainingInodesClampsAtZero() {
        let over = ScanProgress(filesProcessed: 1_500, usedInodes: 1_000, running: true)
        XCTAssertEqual(over.remainingInodes, 0, "remaining never goes negative")
        let mid = ScanProgress(filesProcessed: 300, usedInodes: 1_000, running: true)
        XCTAssertEqual(mid.remainingInodes, 700)
    }

    // MARK: 5. ETA

    func testEtaIsRemainingOverRate() {
        let p = ScanProgress(filesProcessed: 200, usedInodes: 1_200, running: true, isVolumeRoot: true)
        // remaining = 1000; at 500 files/sec ⇒ 2 s.
        XCTAssertEqual(p.etaSeconds(filesPerSecond: 500)!, 2.0, accuracy: 1e-9)
    }

    func testEtaNilWhenRateNonPositive() {
        let p = ScanProgress(filesProcessed: 200, usedInodes: 1_200, running: true, isVolumeRoot: true)
        XCTAssertNil(p.etaSeconds(filesPerSecond: 0), "no measured rate ⇒ no fabricated ETA")
        XCTAssertNil(p.etaSeconds(filesPerSecond: -5))
    }

    func testEtaNilWhenDone() {
        let p = ScanProgress(filesProcessed: 1_200, usedInodes: 1_200, running: false, isVolumeRoot: true)
        XCTAssertNil(p.etaSeconds(filesPerSecond: 500), "a finished scan has no time remaining")
    }

    // MARK: 6. Subtree scans suppress percentage + ETA (OPERATOR_NOTE #2 item 2)

    func testSubtreeScanHasNoFraction() {
        // Identical inputs to a volume-root scan that WOULD show 25 %, but the root is a
        // subtree (~) — the volume-wide inode denominator is not this scan's workload, so
        // NO percentage is shown (barber-pole + files/sec instead).
        let subtree = ScanProgress(filesProcessed: 250, usedInodes: 1_000, running: true, isVolumeRoot: false)
        XCTAssertNil(subtree.fraction, "a subtree scan shows no fraction against the volume denominator")
        let volumeRoot = ScanProgress(filesProcessed: 250, usedInodes: 1_000, running: true, isVolumeRoot: true)
        XCTAssertEqual(volumeRoot.fraction!, 0.25, accuracy: 1e-12,
                       "the SAME inputs at the volume root DO show a fraction — isVolumeRoot is the only difference")
    }

    func testSubtreeScanHasNoEta() {
        let subtree = ScanProgress(filesProcessed: 200, usedInodes: 1_200, running: true, isVolumeRoot: false)
        XCTAssertNil(subtree.etaSeconds(filesPerSecond: 500),
                     "a subtree scan has no ETA against the volume-inode denominator")
        let volumeRoot = ScanProgress(filesProcessed: 200, usedInodes: 1_200, running: true, isVolumeRoot: true)
        XCTAssertEqual(volumeRoot.etaSeconds(filesPerSecond: 500)!, 2.0, accuracy: 1e-9,
                       "the SAME inputs at the volume root DO yield an ETA")
    }

    func testSubtreeScanDefaultIsSuppressed() {
        // The default (no isVolumeRoot argument) is a subtree — the conservative choice
        // that never fabricates a percentage for an unknown root.
        let p = ScanProgress(filesProcessed: 250, usedInodes: 1_000, running: true)
        XCTAssertFalse(p.isVolumeRoot)
        XCTAssertNil(p.fraction)
    }
}
