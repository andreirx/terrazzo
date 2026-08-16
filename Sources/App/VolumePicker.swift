//
//  VolumePicker.swift — the toolbar popup of mounted volumes.
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  TZ-4 deliverable 2: a popup listing the mounted volumes a user would want to map,
//  with the boot volume (`/`) default. Selecting a volume rescans it (the callback the
//  App wires to ScanController.scan(root:) + NavigationController.reset()).
//
//  The list comes from ScanFS's VolumeEnumerator (all syscalls there — CLAUDE.md
//  constraint 1); this view only presents `[VolumeDescriptor]` DTOs. The skip policy
//  (which virtual/system mounts are hidden, and why) is VolumeSkipPolicy's — this view
//  never decides what to show, it renders what it is handed.
//
//  ABSTRACTION LEDGER: an NSPopUpButton subclass, one concrete user (ControlBar). No
//  protocol — a single popup with a selection callback. The `descriptors` array indexed
//  by menu-item order IS the model; the rejected alternative (store paths in item
//  representedObject and re-enumerate on select) re-queries the filesystem from the UI
//  layer, crossing the ScanFS boundary the App must not touch.
//

import AppKit

final class VolumePicker: NSPopUpButton {
    /// Called when the user picks a volume (or the selection is set programmatically to a
    /// different volume). The App rescans that volume.
    var onSelect: ((VolumeDescriptor) -> Void)?

    /// Backing model, index-parallel with the menu items. The source of truth for what a
    /// selected index means (never re-derived from the title string).
    private var descriptors: [VolumeDescriptor] = []

    init() {
        super.init(frame: .zero, pullsDown: false)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(picked)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("VolumePicker is code-only") }

    /// Populate the popup and select the volume whose path == `selectedPath` (falls back
    /// to the first). Rebuilding the menu is cheap (a handful of volumes) and keeps the
    /// model in lock-step with the items.
    func setVolumes(_ volumes: [VolumeDescriptor], selectedPath: String) {
        descriptors = volumes
        removeAllItems()
        for v in volumes {
            // "Macintosh HD — /"  ·  a network volume is marked so the user knows.
            let suffix = v.isRootVolume ? " — /" : (v.isLocal ? "" : " (network)")
            addItem(withTitle: "\(v.name)\(suffix)")
        }
        if let idx = volumes.firstIndex(where: { $0.url.path == selectedPath }) {
            selectItem(at: idx)
        } else if !volumes.isEmpty {
            selectItem(at: 0)
        }
        // Enabled whenever there is anything to pick — NOT `count > 1`. The initial scan
        // is the home directory (fast first paint), so on a single-volume machine the
        // ONLY UI path to a full boot-volume (`/`) scan is picking that volume here;
        // disabling a one-item picker would make the root scan unreachable (root
        // promotion / zoom-out-past-root is deferred). Re-selecting the current item
        // still fires `picked`, so choosing the already-shown boot volume starts the
        // root scan.
        isEnabled = !volumes.isEmpty
    }

    @objc private func picked() {
        let idx = indexOfSelectedItem
        guard descriptors.indices.contains(idx) else { return }
        onSelect?(descriptors[idx])
    }
}
