//
//  StatusBar.swift — the volume-accounting header strip.
//  Module maturity: PROTOTYPE (slice TZ-2; plain-language fields + tooltips TZ-3)
//
//  Shows the numbers the founding mystery is about (VISION §"Purgeable vs
//  free"): the volume's capacity, its free space via BOTH availability APIs
//  (their difference is purgeable), the scanned-so-far total, and whether the
//  scan is still running. Since TZ-4b (HUMAN FIELD RULING #1) it ALSO carries the
//  "Unaccounted" reconciliation figure (`capacity − free − scanned`, decomposed) —
//  which was briefly a synthetic MAP TILE and is now, by binding ruling, a
//  status-bar figure ONLY (a volume quantity has no honest rectangle inside a
//  subtree map). So this strip is where the two accountings sit side by side.
//
//  Pure presentation: it receives a `ScanStatus` value (raw Int64 bytes crossing
//  from ScanFS's VolumeProbe DTO) and formats it. No filesystem access.
//
//  PLAIN LANGUAGE + SELF-EXPLANATION (deliverable 5d, human directive 2026-08-16):
//  "Important" is the `volumeAvailableCapacityForImportantUsage` API term — API
//  jargon in the UI is a name-honesty defect (CLAUDE.md constraint 5). The visible
//  fields are, in this ratified order:
//      Capacity · Free · Reclaimable · Available up to · Scanned
//  where the API names live only in code comments / tooltips:
//      Free           = volumeAvailableCapacity        (strict free)
//      Reclaimable    = purgeable                       (important − available)
//      Available up to = volumeAvailableCapacityForImportantUsage (free + reclaimable)
//  Each field is its own NSTextField (a `field` in the trailing stack) carrying a
//  one-sentence `.toolTip` — per-field hover help, which a single concatenated
//  label could not give (NSView.toolTip is view-scoped). The field set is fixed
//  and small, so a reused label pool (the CanvasView.setTileLabels pattern) avoids
//  per-update view churn.
//

import AppKit

/// The values the status strip renders. Plain value type; `volume` is nil until
/// the probe returns (or if it failed — surfaced as "—", not faked).
struct ScanStatus {
    let volume: VolumeProbe.VolumeInfo?
    let scannedBytes: Int64
    /// Tiles the pipeline dropped as sub-pixel before this scene (PLAN §"Rendering
    /// scale": "cull rects < ~2 px … no silent truncation"). Surfaced in the status
    /// line so culled mass is REPORTED, never silently swallowed (invisible-space
    /// principle). Comes prebuilt on the RenderScene; the App only formats it.
    let belowPixelCount: Int
    let running: Bool
    /// Entries stat'd so far (progress-bar numerator, TZ-4). Default 0 keeps the TZ-2/3
    /// call sites that predate the progress bar compiling unchanged.
    var filesProcessed: Int = 0
    /// Volume used-inode count at scan start (progress-bar denominator); 0 ⇒ unknown.
    var totalInodes: Int64 = 0
    /// Whether the scan ROOT is a selectable volume's root (ScanFS
    /// `VolumeSkipPolicy.isVolumeRoot`). Gates the percentage/ETA honesty rule
    /// (OPERATOR_NOTE #2 item 2): a subtree scan shows files/sec + a count, not a fraction
    /// against the volume-wide inode denominator.
    var isVolumeRoot: Bool = false

    /// The file-count progress derived from this status (TZ-4). The ControlBar renders
    /// its clamped fraction + ETA (volume-root scan) or files/sec + count (subtree scan);
    /// kept here so the arithmetic (pure `ScanProgress`) stays testable and out of the
    /// AppKit view.
    var progress: ScanProgress {
        ScanProgress(filesProcessed: filesProcessed, usedInodes: totalInodes,
                     running: running, isVolumeRoot: isVolumeRoot)
    }
}

final class StatusBar: NSView {
    static let height: CGFloat = 26

    /// The current focus path (breadcrumb, deliverable 5) — leading, emphasized.
    /// Under the live scan a node id IS its absolute path, so this is the focus's
    /// path. Truncates at the HEAD so the deepest components stay visible.
    private let focusLabel = NSTextField(labelWithString: "")
    /// The focus path most recently set (the breadcrumb). Held so a transient hover
    /// path (TZ-4 D9) can REPLACE it during hover and REVERT to it on hover-out.
    private var focusPath = ""
    private static let focusColor = NSColor(calibratedWhite: 0.90, alpha: 1)
    /// A hovered node's full path shows here during hover in a dimmer style (D9),
    /// distinct from the emphasized breadcrumb. Head-truncates only if unavoidable —
    /// the full path is meant to be readable here (the on-tile chip middle-truncates,
    /// the bottom bar does not).
    private static let hoverColor = NSColor(calibratedWhite: 0.62, alpha: 1)
    /// The volume accounting line (TZ-2), now one NSTextField per field so each
    /// carries its own hover tooltip (deliverable 5d) — trailing, monospaced digits.
    private let volumeStack = NSStackView()
    /// Reused pool of field labels (max 8: Capacity/Free/Reclaimable/Available up
    /// to/Scanned + the optional "Unaccounted …" figure + the optional "N tiles below
    /// pixel size" + the scan indicator). Fixed and small → reuse, no per-update churn
    /// (the CanvasView.setTileLabels pattern). `fields(_:)` returns a variable-length
    /// subset; extra labels hide.
    private var fieldLabels: [NSTextField] = []
    private static let maxFields = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0.08, alpha: 1)

        focusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        focusLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        focusLabel.lineBreakMode = .byTruncatingHead
        focusLabel.translatesAutoresizingMaskIntoConstraints = false

        volumeStack.orientation = .horizontal
        volumeStack.spacing = 16
        volumeStack.alignment = .centerY
        volumeStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<Self.maxFields {
            let f = NSTextField(labelWithString: "")
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            f.isHidden = true
            fieldLabels.append(f)
            volumeStack.addArrangedSubview(f)
        }

        addSubview(focusLabel)
        addSubview(volumeStack)
        NSLayoutConstraint.activate([
            focusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            focusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            volumeStack.leadingAnchor.constraint(greaterThanOrEqualTo: focusLabel.trailingAnchor, constant: 16),
            volumeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            volumeStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The focus path yields width to the volume figures under compression.
        focusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        volumeStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("StatusBar is code-only") }

    func update(_ status: ScanStatus) {
        let fields = Self.fields(status)
        for (i, label) in fieldLabels.enumerated() {
            if i < fields.count {
                label.stringValue = fields[i].value
                label.toolTip = fields[i].tooltip
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
    }

    /// Set the current focus path (breadcrumb). Called by NavigationController on
    /// every relayout / focus change. Only paints the label when no hover path is
    /// currently overriding it, so a streaming scene update mid-hover does not stomp
    /// the hovered node's path out of the bottom bar.
    func setFocusPath(_ path: String) {
        focusPath = path
        if !hovering {
            focusLabel.stringValue = path
            focusLabel.textColor = Self.focusColor
        }
    }

    /// Whether a hover path is currently overriding the breadcrumb.
    private var hovering = false

    /// Show a hovered node's FULL path in the bottom bar (D9, dimmer style), or `nil`
    /// to revert to the focus breadcrumb. The chip on the tile middle-truncates a long
    /// path; the bottom bar shows it whole (head-truncated only if the strip is too
    /// narrow), so this is where the operator reads the full path.
    func setHoverPath(_ path: String?) {
        if let path {
            hovering = true
            focusLabel.stringValue = path
            focusLabel.textColor = Self.hoverColor
        } else {
            hovering = false
            focusLabel.stringValue = focusPath
            focusLabel.textColor = Self.focusColor
        }
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file // decimal GB/MB, matching Finder/Storage Settings
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static func b(_ v: Int64) -> String { bytes.string(fromByteCount: v) }

    /// One rendered field: the on-strip text and its one-sentence hover tooltip.
    struct VolumeField: Equatable { let value: String; let tooltip: String }

    /// Pure builder for the status fields, in the ratified order
    /// `Capacity · Free · Reclaimable · Available up to · Scanned` (+ scan
    /// indicator). Plain-language names in the UI; the API terms live in the
    /// tooltips/comments only (deliverable 5d). Testable without AppKit.
    static func fields(_ s: ScanStatus) -> [VolumeField] {
        var out: [VolumeField] = []
        if let v = s.volume {
            out.append(VolumeField(
                value: "Capacity \(b(v.capacityBytes))",
                tooltip: "Total formatted size of this volume."))
            // Free = volumeAvailableCapacity (the strict free-space API).
            out.append(VolumeField(
                value: "Free \(b(v.availableBytes))",
                tooltip: "Unallocated space right now."))
            // Reclaimable = purgeable (important − available).
            out.append(VolumeField(
                value: "Reclaimable \(b(v.purgeableBytes))",
                tooltip: "Space macOS frees automatically when needed: local Time Machine snapshots, caches, cloud-synced files."))
            // Available up to = volumeAvailableCapacityForImportantUsage.
            out.append(VolumeField(
                value: "Available up to \(b(v.availableForImportantBytes))",
                tooltip: "Free + reclaimable: what the system would give an important write — why different tools report different free space."))
        } else {
            out.append(VolumeField(value: "Volume —",
                                   tooltip: "Volume accounting is not available yet."))
        }
        out.append(VolumeField(
            value: "Scanned \(b(s.scannedBytes))",
            tooltip: "Total size Terrazzo has measured so far."))
        // UNACCOUNTED (TZ-4b, HUMAN FIELD RULING #1: status-bar figure, NEVER a map tile).
        // The residual `capacity − free − scanned`, decomposed as purgeable + other/unknown
        // (space no scan from this POSIX account can see — FDA never crosses user
        // boundaries, VISION). Computed by the pure, tested `UnaccountedSpace.figure` (which
        // guarantees purgeable + other/unknown == the total, so this readout always adds up).
        // ALWAYS shown when volume accounting is known, INCLUDING zero (VISION §"Purgeable vs
        // free": "The number is always shown" — a reconciled volume reads "Unaccounted 0",
        // not a vanished field; review-4 change 2). Only a failed/absent probe (no `s.volume`)
        // omits it, because then there is no capacity to reconcile against.
        if let v = s.volume {
            let u = UnaccountedSpace.figure(capacity: v.capacityBytes, free: v.availableBytes,
                                            scanned: s.scannedBytes, purgeable: v.purgeableBytes)
            out.append(VolumeField(
                value: "Unaccounted \(b(u.total)) (purgeable \(b(u.purgeable)) + other/unknown \(b(u.unknown)))",
                tooltip: "Volume space Terrazzo could not measure: capacity − free − scanned. Split into reclaimable (purgeable) space and files no scan from this account can see — other users’ home folders and snapshots (Full Disk Access never crosses user boundaries). The two parts always add up to the total. Not a folder; never drawn on the map."))
        }
        // Sub-pixel cull count — shown only when non-zero (no "0 tiles" clutter on a
        // small map). PLAN §"Rendering scale": culled tiles are REPORTED, never silently
        // dropped — the invisible-space principle applied to below-pixel mass.
        if s.belowPixelCount > 0 {
            out.append(VolumeField(
                value: "\(s.belowPixelCount) tiles below pixel size",
                tooltip: "Tiles too small to draw (< ~2 px) at this zoom, so they are not shown. Zoom in to see them; nothing is silently dropped."))
        }
        out.append(VolumeField(
            value: s.running ? "● scanning…" : "✓ scan complete",
            tooltip: s.running ? "A scan is in progress; sizes are still growing."
                               : "The scan has finished; sizes are final for this run."))
        return out
    }
}
