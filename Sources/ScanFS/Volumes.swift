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

    public init(url: URL, name: String, isBrowsable: Bool, isLocal: Bool) {
        self.url = url
        self.name = name
        self.isBrowsable = isBrowsable
        self.isLocal = isLocal
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
            return VolumeDescriptor(
                url: url,
                name: v?.volumeName ?? url.lastPathComponent,
                isBrowsable: v?.volumeIsBrowsable ?? false,
                isLocal: v?.volumeIsLocal ?? true)
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
