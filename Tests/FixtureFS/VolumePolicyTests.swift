//
//  VolumePolicyTests.swift — the pure volume-skip policy (TZ-4 D10).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  `VolumeSkipPolicy` decides which mounted volumes the picker HIDES. Pure over a
//  `VolumeDescriptor`, so it is testable without mounting anything (packet D8: "volume
//  -skip policy tested"). Pins the documented skip rules:
//   - non-browsable volumes (APFS helper roles / virtual mounts) are hidden;
//   - anything under /System/Volumes/… (firmlink helper mounts already counted under /)
//     is hidden — the double-count guard;
//   - the boot volume "/" and ordinary browsable disks are KEPT.
//  Plus `isVolumeRoot`, the gate on the FDA banner (only offer FDA when a WHOLE volume
//  is being mapped).
//

import XCTest
import ScanFS

final class VolumePolicyTests: XCTestCase {

    private func vol(_ path: String, browsable: Bool = true, local: Bool = true) -> VolumeDescriptor {
        VolumeDescriptor(url: URL(fileURLWithPath: path, isDirectory: true),
                         name: (path as NSString).lastPathComponent,
                         isBrowsable: browsable, isLocal: local)
    }

    // MARK: shouldSkip

    func testSkipsNonBrowsableVolumes() {
        XCTAssertTrue(VolumeSkipPolicy.shouldSkip(vol("/System/Volumes/Preboot", browsable: false)))
    }

    func testSkipsSystemVolumesHelperMounts() {
        // Browsable but under /System/Volumes/ — the boot Data role + firmlink helpers,
        // already accounted under /. Skipped to avoid double-counting.
        XCTAssertTrue(VolumeSkipPolicy.shouldSkip(vol("/System/Volumes/Data")))
        XCTAssertTrue(VolumeSkipPolicy.shouldSkip(vol("/System/Volumes/VM")))
    }

    func testKeepsBootVolume() {
        XCTAssertFalse(VolumeSkipPolicy.shouldSkip(vol("/")), "the boot volume is the founding target")
    }

    func testKeepsOrdinaryExternalVolume() {
        XCTAssertFalse(VolumeSkipPolicy.shouldSkip(vol("/Volumes/BackupDisk")))
    }

    func testKeepsNetworkVolume() {
        // Network mounts are surfaced, not skipped (a user may want to map them).
        XCTAssertFalse(VolumeSkipPolicy.shouldSkip(vol("/Volumes/NAS", local: false)))
    }

    // MARK: isRootVolume / isVolumeRoot

    func testIsRootVolumeProperty() {
        XCTAssertTrue(vol("/").isRootVolume)
        XCTAssertFalse(vol("/Volumes/BackupDisk").isRootVolume)
    }

    func testIsVolumeRootMatchesRootOrKnownVolumePaths() {
        let vols: Set<String> = ["/", "/Volumes/BackupDisk"]
        XCTAssertTrue(VolumeSkipPolicy.isVolumeRoot(path: "/", volumePaths: vols))
        XCTAssertTrue(VolumeSkipPolicy.isVolumeRoot(path: "/Volumes/BackupDisk", volumePaths: vols))
        // A sub-folder of a volume is NOT a volume root — no FDA banner for a folder scan.
        XCTAssertFalse(VolumeSkipPolicy.isVolumeRoot(path: "/Users/apple", volumePaths: vols))
    }
}
