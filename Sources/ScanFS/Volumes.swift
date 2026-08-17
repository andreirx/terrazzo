//
//  Volumes.swift — mounted-volume enumeration (I/O) + skip policy (pure).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  The VolumePicker (TZ-4 deliverable 2) needs the list of volumes a user would
//  actually want to map. macOS mounts far more than that: alongside the boot volume
//  (`/`) sit the APFS system-role helper volumes — Preboot, VM, Update, Recovery, and
//  the internal `Data` role — under `/System/Volumes/…`, plus non-browsable virtual
//  mounts. Offering those would DOUBLE-COUNT (the boot volume's bytes reappear under
//  its own sub-mounts) and confuse the founding question.
//
//  SPLIT (CLAUDE.md constraint 1 / testability): `VolumeEnumerator` performs the syscalls
//  (FileManager mounted-volume enumeration + URL resource values) and returns raw
//  `VolumeDescriptor` DTOs; `VolumeSkipPolicy` is the PURE decision over a descriptor,
//  so the skip rule is swift-testable without mounting anything (packet deliverable 8:
//  "volume-skip policy" tested).
//
//  WHICH VOLUMES WE SKIP, AND WHY (documented per packet):
//    - NON-BROWSABLE volumes (`volumeIsBrowsable == false`): the APFS helper roles and
//      other virtual mounts report non-browsable; the boot Data volume and real disks
//      report browsable. This is the primary filter.
//    - Anything mounted under `/System/Volumes/…` that is not `/` itself: these are the
//      firmlink helper mounts (Preboot/VM/Update/Recovery and the `Data` role) whose
//      contents are already accounted under `/`. Skipping them prevents double-counting.
//  We deliberately do NOT skip network or external browsable volumes — a user may want
//  to map those; the founding use case is the boot volume, but the picker is general.
//

import Foundation

/// A mounted volume as raw values crossing the ScanFS→App boundary (CLAUDE.md: a DTO,
/// never a framework object). `url` is the mount point; scanning a volume means scanning
/// this URL as the root.
public struct VolumeDescriptor: Sendable, Equatable {
    public let url: URL
    /// Human name (`volumeNameKey`), falling back to the last path component.
    public let name: String
    /// `volumeIsBrowsableKey` — false for virtual/system helper mounts.
    public let isBrowsable: Bool
    /// `volumeIsLocalKey` — false for network mounts (kept, not skipped, but surfaced).
    public let isLocal: Bool
    /// The volume's USED-inode count (`statfs f_files − f_ffree`) at enumeration time — the
    /// entry population a whole-volume scan would retain a node for, and therefore the input to
    /// the giant-volume consent (TZ-9 deliverable 4). It is the SAME statfs figure the progress
    /// bar's denominator already uses (`VolumeProbe.usedInodes`, incl. the boot-Data firmlink
    /// fix), read here per-volume at essentially zero cost. `0` ⇒ unavailable (statfs failed or a
    /// denied/virtual mount); an unknown count NEVER trips a warning (honest silence over a
    /// fabricated number). Additive (default `0`) so every existing `VolumeDescriptor(...)` call
    /// site (tests, harnesses) compiles unchanged.
    public let usedInodes: Int64
    /// Whether this volume looks like a Time Machine BACKUP store (a hardlink/entry forest — the
    /// 60M-inode case behind the field report), by the structural heuristic in
    /// `TimeMachineDetector`. A HEURISTIC, surfaced as such (name honesty): a true detection names
    /// the volume as Time Machine in the consent warning; a miss just falls back to the generic
    /// giant-volume warning (the inode count still trips it). Additive (default `false`).
    public let isTimeMachineBackup: Bool

    public init(url: URL, name: String, isBrowsable: Bool, isLocal: Bool,
                usedInodes: Int64 = 0, isTimeMachineBackup: Bool = false) {
        self.url = url
        self.name = name
        self.isBrowsable = isBrowsable
        self.isLocal = isLocal
        self.usedInodes = usedInodes
        self.isTimeMachineBackup = isTimeMachineBackup
    }

    /// True iff this is the boot/root volume (`/`). The default scan target (TZ-4).
    public var isRootVolume: Bool { url.path == "/" }
}

/// PURE skip decision over a `VolumeDescriptor` — no I/O, swift-testable.
public enum VolumeSkipPolicy {
    /// Whether the picker should HIDE this volume (see file header for the rationale).
    public static func shouldSkip(_ v: VolumeDescriptor) -> Bool {
        if !v.isBrowsable { return true } // virtual / system helper mounts
        // Firmlink helper mounts (Preboot/VM/Update/Recovery/Data) live here and are
        // already counted under `/`; skip them to avoid double-counting. `/` itself does
        // not match this prefix, so the boot volume is never skipped by this rule.
        if v.url.path.hasPrefix("/System/Volumes/") { return true }
        return false
    }

    /// Whether `path` is the root of a selectable volume — the gate on the FDA banner
    /// (only offer FDA when a WHOLE volume is being mapped, where denial actually
    /// matters; a scan of a single sub-folder does not warrant the prompt). Pure over
    /// the set of selectable volume paths so it is testable without mounting.
    public static func isVolumeRoot(path: String, volumePaths: Set<String>) -> Bool {
        path == "/" || volumePaths.contains(path)
    }
}

/// GIANT-VOLUME CONSENT (TZ-9 deliverable 4) — the PURE decision of whether to warn before
/// scanning a volume, and what to say. Pure over the three numbers the App hands it
/// (used-inode count, is-it-Time-Machine, bytes/node), so it is swift-testable without mounting
/// anything, exactly like `VolumeSkipPolicy`. The I/O that produces those numbers lives in
/// `VolumeEnumerator` / `TimeMachineDetector`; the decision is here.
///
/// WHY IT EXISTS (the field report behind TZ-9): scanning a tens-of-millions-inode volume — a
/// Time Machine hardlink forest — retained ~540 B/node and produced a 33 GB RSS. Until the lean
/// node store lands (TZ-9 deliverable 2), the honest thing is to WARN before committing the
/// user's RAM to a monster, with the estimated footprint at the CURRENTLY-MEASURED bytes/node.
///
/// ABSTRACTION LEDGER — GiantVolumeConsent: a namespace of pure static funcs (no state). Concrete
/// users: `AppDelegate.scanVolumeWithConsent` (production) + `GiantVolumeConsentTests`. Axis:
/// none — a fixed threshold/estimate rule. Rejected simpler alternative: inline the threshold
/// check in the App — but the App is SPM-invisible, so the rule (and its message text) could not
/// be unit-tested, which the reviewer requires.
public enum GiantVolumeConsent {
    /// Estimated peak bytes per scanned node, used to project a volume's memory footprint in the
    /// consent warning. RE-SEEDED to the CURRENTLY-MEASURED reality of the shipping build
    /// (`scripts/footprint.sh` on this machine, 2026-08-17, TZ-9 lean-store + exact-collision landing:
    /// peak 1442 MiB @ 2,828,130-node home scan ≈ 534 B/node, down from the pre-TZ-9 `[String: Node]`
    /// store's 623.8 B/node measured on the SAME machine/tree — a ~14% reduction; scan rate 179k
    /// files/s, ABOVE the TZ-6 ~160k mandate, so the lean store did not buy memory with speed). The
    /// exact-collision side table is empty in this measurement (no FNV-128 collision), so it adds NO
    /// per-node memory — the 534 vs the prior cycle's 532 is phys_footprint run-to-run noise.
    /// NAME-HONESTY RIDER (TZ-9, CLAUDE.md constraint 5): a constant that contradicts the measurement
    /// is a defect, so this always tracks the last real measurement of the running build — never an
    /// aspirational number.
    ///
    /// PARTIAL — THE MEMORY LAW (deliverable 2): the lean node store LANDED this cycle (Phase A —
    /// hashed id→slot map, `Int32` parent/child links, so the two path-string DUPLICATIONS the field
    /// report named are gone), but ≤~100 B/node was NOT reached: the dominant remaining cost is the
    /// ONE retained id string per node (`Node.id`) plus the intrinsic node fields and the Dictionary
    /// overhead. The packet's deliverable 1 asked only that the map hold no SECOND path copy (met);
    /// reaching ≤100 needs DERIVING the id (dropping that last copy), which requires the
    /// `id == parent + "/" + name` contract — the walker honors it, but the shared verify/TreemapCore
    /// fixture uses synthetic ids, so it is a Phase-B step gated on migrating that fixture (see the
    /// TZ-9 build report / DECISION_REQUIRED). This constant is lowered when that lands.
    public static let estimatedBytesPerNode: Int64 = 534

    /// The used-inode count above which a volume warrants informed consent before scanning (TZ-9:
    /// "a named constant, ~10M"). At ~534 B/node, 10M entries ≈ 5.3 GB peak — the point past which
    /// committing RAM without asking is user-hostile. Below it, no warning (the common home /
    /// boot-volume scan on this machine is ~2.8M inodes, ~1.4 GB — surfaced in the tooltip, not gated).
    public static let inodeThreshold: Int64 = 10_000_000

    /// The rendered consent prompt for a volume that needs one. All raw values + a ready-to-show
    /// message (composed here so the App renders one string, not re-derives the wording). A struct,
    /// not a tuple: three fields, two callers (App + test).
    public struct Prompt: Equatable, Sendable {
        /// The volume's used-inode entry count (the warning's "N million entries").
        public let entryCount: Int64
        /// The projected retained footprint = entryCount × bytesPerNode.
        public let estimatedBytes: Int64
        /// Whether the volume was detected as a Time Machine backup store (named as such below).
        public let isTimeMachineBackup: Bool
        /// The one-line, non-modal consent sentence the banner shows.
        public let message: String
        public init(entryCount: Int64, estimatedBytes: Int64, isTimeMachineBackup: Bool, message: String) {
            self.entryCount = entryCount
            self.estimatedBytes = estimatedBytes
            self.isTimeMachineBackup = isTimeMachineBackup
            self.message = message
        }
    }

    /// Decide whether scanning a volume with `usedInodes` entries needs consent, and compose the
    /// prompt if so. Returns `nil` when the volume is below `threshold` (scan freely, no warning) or
    /// its inode count is unknown (`≤ 0` — never fabricate a scary number from a failed statfs).
    ///
    /// The estimate is honest and labelled: entries × the CURRENTLY-MEASURED bytes/node
    /// (`estimatedBytesPerNode`). A detected Time Machine backup is named — those are the hardlink
    /// forests the field report hit, and users deserve to know THAT is what they picked.
    public static func evaluate(usedInodes: Int64,
                                isTimeMachineBackup: Bool,
                                threshold: Int64 = inodeThreshold,
                                bytesPerNode: Int64 = estimatedBytesPerNode) -> Prompt? {
        guard usedInodes > threshold else { return nil }
        let estimatedBytes = usedInodes.multipliedReportingOverflow(by: bytesPerNode).overflow
            ? Int64.max : usedInodes * bytesPerNode
        let entriesText = millions(usedInodes)
        let memText = gigabytes(estimatedBytes)
        let kind = isTimeMachineBackup ? "This looks like a Time Machine backup volume — " : ""
        let message = "\(kind)scanning this volume means about \(entriesText) entries " +
            "(≈ \(memText) of memory at current sizes). Scan anyway?"
        return Prompt(entryCount: usedInodes, estimatedBytes: estimatedBytes,
                      isTimeMachineBackup: isTimeMachineBackup, message: message)
    }

    /// "≈ 12 million" / "≈ 8.4 million" — a coarse entry-count phrase for the warning. Kept pure
    /// (no NumberFormatter locale dependence in the tested string) so the test can pin the wording.
    static func millions(_ n: Int64) -> String {
        let m = Double(n) / 1_000_000
        return m >= 10 ? String(format: "%.0f million", m) : String(format: "%.1f million", m)
    }

    /// "≈ 6.5 GB" — a coarse footprint phrase (decimal GB, matching Finder/Storage Settings).
    static func gigabytes(_ bytes: Int64) -> String {
        let g = Double(bytes) / 1_000_000_000
        if g >= 100 { return String(format: "%.0f GB", g) }
        if g >= 10 { return String(format: "%.0f GB", g) }
        return String(format: "%.1f GB", g)
    }
}

/// TIME MACHINE BACKUP DETECTION (TZ-9 deliverable 4) — the I/O heuristic that decides whether a
/// mounted volume is a Time Machine backup STORE (the hardlink/entry forest behind the field
/// report). A HEURISTIC, and named as one (CLAUDE.md constraint 5: name honesty): it checks for
/// the two structural markers a TM store carries, and returns `false` when it cannot tell (a
/// denied read, or an unfamiliar layout) rather than guessing — a miss degrades to the generic
/// giant-volume warning, never a false "this is Time Machine" claim.
///
/// The markers:
///   - `Backups.backupdb` at the mount root — the classic (pre-APFS) Time Machine database dir.
///   - a `*.backupbundle` / a Big-Sur+ APFS backup carries `.com.apple.timemachine.donotpresent`
///     or a top-level machine-directory tree; the robust, permission-tolerant signal we use is the
///     `Backups.backupdb` dir OR a `.com.apple.timemachine.supported` marker file at the root.
/// All syscalls stay here in ScanFS (CLAUDE.md constraint 1).
public enum TimeMachineDetector {
    public static func isBackupVolume(mountURL: URL) -> Bool {
        let fm = FileManager.default
        let path = mountURL.path
        let markers = [
            "Backups.backupdb",                       // legacy TM database directory
            ".com.apple.timemachine.supported",       // TM-capable marker
            ".com.apple.timemachine.donotpresent",    // APFS TM backup volume marker
        ]
        for marker in markers {
            let full = path.hasSuffix("/") ? path + marker : path + "/" + marker
            if fm.fileExists(atPath: full) { return true }
        }
        return false
    }
}

/// The I/O side: enumerate mounted volumes and read the resource values the policy
/// decides on. Every syscall here (CLAUDE.md constraint 1).
public enum VolumeEnumerator {
    /// All mounted volumes as raw descriptors (unfiltered). `.skipHiddenVolumes` already
    /// drops most hidden mounts; the policy filters the rest.
    public static func mountedVolumes() -> [VolumeDescriptor] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            // TZ-9: the used-inode count (same statfs figure the progress denominator uses, incl.
            // the boot-Data firmlink fix) + the Time Machine heuristic. Both are one cheap syscall
            // per volume (a handful of volumes), read here so the picker + consent get them as raw
            // DTO values — the App never calls statfs / FileManager itself (CLAUDE.md constraint 1).
            let inodes = VolumeProbe.usedInodes(for: url) ?? 0
            let isTM = TimeMachineDetector.isBackupVolume(mountURL: url)
            return VolumeDescriptor(
                url: url,
                name: v?.volumeName ?? url.lastPathComponent,
                isBrowsable: v?.volumeIsBrowsable ?? false,
                isLocal: v?.volumeIsLocal ?? true,
                usedInodes: inodes,
                isTimeMachineBackup: isTM)
        }
    }

    /// The volumes the picker offers — mounted minus policy-skipped, boot volume first.
    public static func selectableVolumes() -> [VolumeDescriptor] {
        let kept = mountedVolumes().filter { !VolumeSkipPolicy.shouldSkip($0) }
        // Boot volume (`/`) first so it is the default selection; stable otherwise.
        return kept.sorted { a, b in
            if a.isRootVolume != b.isRootVolume { return a.isRootVolume }
            return a.url.path < b.url.path
        }
    }
}
