//
//  VolumeProbe.swift — volume capacity/free/purgeable accounting + home URL.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  The I/O adapter's second job: read the numbers the status bar reconciles the
//  scanned total against — the founding mystery is "free space disagrees"
//  (VISION). All syscalls stay in ScanFS, so the App asks this for volume figures
//  and the home path instead of calling Foundation filesystem APIs itself.
//
//  PURGEABLE is the crux (VISION §"Purgeable vs free"): macOS reports TWO
//  "available" numbers and they differ by the purgeable amount that makes free
//  space disagree between contexts. We surface BOTH raw APIs and derive purgeable
//  as their difference — never collapsing them into one lie.
//

import Foundation
import Darwin // statfs — the used-inode denominator for the file-count progress bar

public enum VolumeProbe {

    /// Raw volume figures crossing the ScanFS→App boundary as a plain DTO
    /// (CLAUDE.md: data across a boundary is a raw value type, never a framework
    /// object). All bytes; `nil` fields become 0 (honest zero, surfaced as such).
    public struct VolumeInfo: Sendable, Equatable {
        /// Total volume capacity (`volumeTotalCapacity`).
        public let capacityBytes: Int64
        /// Available space, the strict `volumeAvailableCapacity` API.
        public let availableBytes: Int64
        /// Available-for-important-usage (`volumeAvailableCapacityForImportantUsage`),
        /// which counts space macOS could reclaim by purging — usually larger.
        public let availableForImportantBytes: Int64

        public init(capacityBytes: Int64, availableBytes: Int64,
                    availableForImportantBytes: Int64) {
            self.capacityBytes = capacityBytes
            self.availableBytes = availableBytes
            self.availableForImportantBytes = availableForImportantBytes
        }

        /// Purgeable ≈ the gap between the two available figures (space free only
        /// once macOS reclaims it). Clamped ≥ 0. This is the quantity that makes
        /// "available space" differ between users/contexts (VISION). Approximation
        /// recorded as such; exact purgeable inspection (tmutil) is a named
        /// extension (VISION §"Named extension points").
        public var purgeableBytes: Int64 {
            max(0, availableForImportantBytes - availableBytes)
        }
    }

    /// Read the volume figures for the volume containing `url`. Returns `nil` only
    /// if the resource query fails entirely.
    public static func volumeInfo(for url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeInfo(
            capacityBytes: Int64(v.volumeTotalCapacity ?? 0),
            availableBytes: Int64(v.volumeAvailableCapacity ?? 0),
            availableForImportantBytes: v.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }

    /// The volume's USED inode count at this instant: `statfs.f_files − f_ffree`
    /// (total inodes minus free inodes). This is the DENOMINATOR of the file-count
    /// progress bar (TZ-4, PLAN ratified): the walker's `processedCount` divided by
    /// this estimates how much of the volume's entry population has been stat'd. Read
    /// ONCE at scan start (ScanFS owns the syscall — CLAUDE.md constraint 1); zero cost,
    /// nothing persisted.
    ///
    /// APPROXIMATION, surfaced as such: this is volume-WIDE — it includes inodes the
    /// scan can never reach from this account (other users' homes, TCC-denied areas) —
    /// so the numerator can plateau below it; the progress model (`ScanProgress`) clamps
    /// for exactly this reason. Returns `nil` if `statfs` fails; a returned value is
    /// clamped ≥ 0 (a transient count where free momentarily exceeds total is an honest
    /// zero, not a negative).
    public static func usedInodes(for url: URL) -> Int64? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let used = Int64(bitPattern: UInt64(s.f_files)) - Int64(bitPattern: UInt64(s.f_ffree))
        return max(0, used)
    }

    /// The user's home directory URL. Lives here so the App never calls a
    /// filesystem API directly (keeps the purity check — no FS calls outside
    /// ScanFS — trivially true).
    public static func homeDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
