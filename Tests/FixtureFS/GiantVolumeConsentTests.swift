//
//  GiantVolumeConsentTests.swift — the pure giant-volume consent policy (TZ-9 D4).
//  Module maturity: PROTOTYPE (slice TZ-9)
//
//  `GiantVolumeConsent` decides whether scanning a volume warrants informed consent (its
//  used-inode count vs the threshold) and composes the warning. Pure over three numbers, so
//  it is testable without mounting anything — like `VolumeSkipPolicy`. `TimeMachineDetector` is
//  the I/O heuristic; it is exercised against a real temp directory (the FixtureFS convention).
//  These pin: the threshold gate, the footprint estimate (nodes × bytes/node), overflow safety,
//  the Time-Machine naming, and the detector markers.
//

import XCTest
import ScanFS

final class GiantVolumeConsentTests: XCTestCase {

    // MARK: - The pure consent decision

    func testBelowThresholdNeedsNoConsent() {
        // A typical boot-volume inode count (~5M) is below the ~10M threshold — scan freely.
        XCTAssertNil(GiantVolumeConsent.evaluate(usedInodes: 5_000_000, isTimeMachineBackup: false),
                     "a below-threshold volume must not trip a consent prompt")
    }

    func testUnknownInodeCountNeverPrompts() {
        // A failed statfs surfaces as 0 (or negative) — never fabricate a scary number.
        XCTAssertNil(GiantVolumeConsent.evaluate(usedInodes: 0, isTimeMachineBackup: true))
        XCTAssertNil(GiantVolumeConsent.evaluate(usedInodes: -1, isTimeMachineBackup: false))
    }

    func testAboveThresholdPromptsWithEstimate() {
        let inodes: Int64 = 60_000_000 // the field-report Time Machine forest scale
        guard let p = GiantVolumeConsent.evaluate(usedInodes: inodes, isTimeMachineBackup: false) else {
            return XCTFail("a 60M-inode volume must require consent")
        }
        XCTAssertEqual(p.entryCount, inodes)
        // The estimate is nodes × the currently-measured bytes/node — follows the constant so the
        // test stays honest when the lean store lands and the constant drops.
        XCTAssertEqual(p.estimatedBytes, inodes * GiantVolumeConsent.estimatedBytesPerNode)
        XCTAssertFalse(p.isTimeMachineBackup)
        XCTAssertTrue(p.message.contains("entries"), "the warning states the entry count")
        XCTAssertTrue(p.message.contains("GB"), "the warning states the estimated memory in GB")
        XCTAssertFalse(p.message.contains("Time Machine"), "not a TM volume → no TM wording")
    }

    func testTimeMachineVolumeIsNamedInWarning() {
        guard let p = GiantVolumeConsent.evaluate(usedInodes: 40_000_000, isTimeMachineBackup: true) else {
            return XCTFail("a 40M-inode volume must require consent")
        }
        XCTAssertTrue(p.isTimeMachineBackup)
        XCTAssertTrue(p.message.contains("Time Machine"),
                      "a detected Time Machine backup is named as such (VISION: name honesty)")
    }

    func testThresholdBoundaryIsStrict() {
        // At exactly the threshold, no prompt; one above, a prompt (a named, testable boundary).
        let t = GiantVolumeConsent.inodeThreshold
        XCTAssertNil(GiantVolumeConsent.evaluate(usedInodes: t, isTimeMachineBackup: false))
        XCTAssertNotNil(GiantVolumeConsent.evaluate(usedInodes: t + 1, isTimeMachineBackup: false))
    }

    func testEstimateDoesNotOverflow() {
        // A pathologically huge inode count must clamp to Int64.max, not trap on multiply overflow.
        let p = GiantVolumeConsent.evaluate(usedInodes: Int64.max, isTimeMachineBackup: false,
                                            threshold: 10, bytesPerNode: 1000)
        XCTAssertEqual(p?.estimatedBytes, Int64.max, "overflow clamps, never traps")
    }

    // MARK: - The Time Machine detector (I/O heuristic, real temp dir)

    func testTimeMachineDetectorSpotsBackupMarker() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A plain directory is not a backup volume.
        XCTAssertFalse(TimeMachineDetector.isBackupVolume(mountURL: tmp))
        // Drop the classic marker directory; the detector must now report a backup store.
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Backups.backupdb"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(TimeMachineDetector.isBackupVolume(mountURL: tmp))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tz9-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
