//
//  StatusBar.swift — the simplified bottom strip (TZ-10 item 5).
//  Module maturity: PROTOTYPE (slice TZ-2; SIMPLIFIED TZ-10 item 5)
//
//  TZ-10 item 5 (human field ruling 2026-08-17) REDUCED this strip to:
//      focus path (left) · Free X of Y capacity · scan state · a DETAILS button (right)
//  ALL the OTHER accounting that used to crowd this strip — reclaimable/available/scanned, the
//  unaccounted decomposition, watchlist exclusion, culled tiles, the active scale, the live
//  indicator — MOVED into a Details dialog (`DetailsView`/`DetailsReport`), which also auto-pops
//  once when a scan completes. The strip now reads at a glance.
//
//  OPERATOR_NOTE 2026-08-17 A (amendment to item 5, human ruling): the ONE figure that STAYS on the
//  bar is "Free X of Y capacity" — the founding free-space question the app exists to answer, kept
//  one glance away. Everything else still lives in the Details dialog. When volume accounting is not
//  yet known the figure reads "Free —" (never a fabricated number).
//
//  ITEM 3 (also this strip): the bottom-left shows ONLY the current enclosing (viewport) folder —
//  the focus path — ALWAYS, middle-truncated only when it cannot fit. The TZ-4 hover-path
//  REPLACEMENT behavior is REMOVED (the cursor callout chip already shows hover info), so a hover
//  never stomps the focus path here.
//
//  `ScanStatus`/`LiveStatus` (the status DTO the pipeline→App handoff carries) still live here —
//  they are the shape the whole status system speaks; only the RENDERING moved to the dialog.
//

import AppKit

/// The live-monitoring capability the Details dialog reports (TZ-7). A SUM TYPE, not a bool,
/// because "recovering" is a distinct third state stated honestly: after a kernel event LOSS a
/// one-level check cannot be trusted, so the map is re-scanning and SAYS so until it catches up.
enum LiveStatus: Equatable {
    /// FSEvents stream up; the map updates from kernel notifications with no rescan.
    case live
    /// FSEvents stream up but recovering from a dropped-events burst; affected subtrees re-validating.
    case degraded
    /// FSEvents stream unavailable — Tier-1 only (focus/idle mtime checks). Rescan for a full refresh.
    case off
}

/// The values the status system renders. Plain value type; `volume` is nil until the probe
/// returns (or if it failed — surfaced as "—", not faked). The Details dialog formats it.
struct ScanStatus {
    let volume: VolumeProbe.VolumeInfo?
    let scannedBytes: Int64
    /// Tiles the pipeline dropped as sub-pixel before this scene (no silent truncation).
    let belowPixelCount: Int
    let running: Bool
    /// Entries stat'd so far (progress-bar numerator, TZ-4). Default 0 for pre-TZ-4 call sites.
    var filesProcessed: Int = 0
    /// Volume used-inode count at scan start (progress-bar denominator); 0 ⇒ unknown.
    var totalInodes: Int64 = 0
    /// Whether the scan ROOT is a selectable volume's root — gates the percentage/ETA honesty rule.
    var isVolumeRoot: Bool = false
    /// The active AREA SCALE this scene was rendered with (echoed from the scene). Default `.linear`
    /// (the TZ-10 item 6 default).
    var scaleMode: AreaScale = .linear
    /// Retained total of nodes filtered out for being HIDDEN (from the scene).
    var hiddenFilteredBytes: Int64 = 0
    /// TZ-7: the live change-monitoring capability. Default `.live` keeps pre-TZ-7 call sites compiling.
    var live: LiveStatus = .live

    /// The file-count progress derived from this status (TZ-4) — the ControlBar renders it.
    var progress: ScanProgress {
        ScanProgress(filesProcessed: filesProcessed, usedInodes: totalInodes,
                     running: running, isVolumeRoot: isVolumeRoot)
    }
}

final class StatusBar: NSView {
    static let height: CGFloat = 26

    /// The current focus path (item 3) — leading, emphasized, MIDDLE-truncated so both ends stay
    /// readable (the enclosing folder's name at the tail, its root context at the head).
    private let focusLabel = NSTextField(labelWithString: "")
    private static let focusColor = NSColor(calibratedWhite: 0.90, alpha: 1)

    /// The kept "Free X of Y capacity" figure (OPERATOR_NOTE A) — trailing, before the scan state.
    /// The founding free-space question, one glance away; the rest of the accounting is in Details.
    private let freeLabel = NSTextField(labelWithString: "")
    private static let byteFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f
    }()

    /// The scan state indicator (● scanning… / ✓ scan complete) — trailing, before the Details button.
    private let scanStateLabel = NSTextField(labelWithString: "")
    /// The DETAILS button (item 5). AppDelegate wires `onDetails`; `detailsAnchor` is where the
    /// Details popover anchors.
    private let detailsButton = NSButton(title: "Details", target: nil, action: nil)
    /// Bound by the Main assembly — opens the Details dialog.
    var onDetails: (() -> Void)?
    /// The view the Details popover should anchor to (the Details button).
    var detailsAnchor: NSView { detailsButton }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0.08, alpha: 1)

        focusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        focusLabel.textColor = Self.focusColor
        focusLabel.lineBreakMode = .byTruncatingMiddle // item 3: middle-truncate only when it must
        focusLabel.translatesAutoresizingMaskIntoConstraints = false
        focusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        freeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        freeLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1) // app-palette (chrome audit)
        freeLabel.toolTip = "Free space now, of this volume's total capacity — the founding free-space figure. Full accounting is in Details."
        freeLabel.translatesAutoresizingMaskIntoConstraints = false
        freeLabel.setContentHuggingPriority(.required, for: .horizontal)
        freeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        scanStateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        scanStateLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        scanStateLabel.translatesAutoresizingMaskIntoConstraints = false
        scanStateLabel.setContentHuggingPriority(.required, for: .horizontal)
        scanStateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailsButton.bezelStyle = .rounded
        detailsButton.controlSize = .small
        detailsButton.target = self
        detailsButton.action = #selector(detailsClicked)
        detailsButton.toolTip = "Show all volume accounting: capacity, free, reclaimable, scanned, unaccounted, watchlist, culled tiles, and the active scale."
        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(focusLabel)
        addSubview(freeLabel)
        addSubview(scanStateLabel)
        addSubview(detailsButton)
        NSLayoutConstraint.activate([
            focusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            focusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            scanStateLabel.trailingAnchor.constraint(equalTo: detailsButton.leadingAnchor, constant: -12),
            scanStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            freeLabel.trailingAnchor.constraint(equalTo: scanStateLabel.leadingAnchor, constant: -14),
            freeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusLabel.trailingAnchor.constraint(lessThanOrEqualTo: freeLabel.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("StatusBar is code-only") }

    @objc private func detailsClicked() { onDetails?() }

    /// Update the scan-state indicator + the kept "Free X of Y capacity" figure from a status (item
    /// 5 + OPERATOR_NOTE A). All the OTHER accounting lives in the Details dialog now.
    func update(_ status: ScanStatus) {
        scanStateLabel.stringValue = status.running ? "● scanning…" : "✓ scan complete"
        if let v = status.volume {
            freeLabel.stringValue = "Free \(Self.byteFmt.string(fromByteCount: v.availableBytes))"
                + " of \(Self.byteFmt.string(fromByteCount: v.capacityBytes)) capacity"
        } else {
            freeLabel.stringValue = "Free —" // volume accounting not known yet — never a fabricated number
        }
    }

    /// The rendered free-capacity string (headless chrome-audit seam — the audit asserts the figure
    /// stays on the bar per OPERATOR_NOTE A). Empty until the first `update`.
    var freeCapacityValue: String { freeLabel.stringValue }

    /// Set the current focus path (item 3) — the current enclosing (viewport) folder. Always painted
    /// (no hover override anymore). `focusPathValue` exposes it as a headless test/trace seam.
    func setFocusPath(_ path: String) {
        focusPath = path
        focusLabel.stringValue = path
    }
    private var focusPath = ""
    var focusPathValue: String { focusPath }
}
