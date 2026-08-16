//
//  StatusBar.swift — the volume-accounting header strip.
//  Module maturity: PROTOTYPE (slice TZ-2; plain-language fields + tooltips TZ-3)
//
//  Shows the numbers the founding mystery is about (VISION §"Purgeable vs
//  free"): the volume's capacity, its free space via BOTH availability APIs
//  (their difference is purgeable), the scanned-so-far total, and whether the
//  scan is still running. TZ-2 shows these figures; the synthetic UNACCOUNTED
//  tile that reconciles scanned-vs-free is TZ-4 (out of scope here) — so this
//  strip is the honest interim place the two accountings sit side by side.
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
    let running: Bool
}

final class StatusBar: NSView {
    static let height: CGFloat = 26

    /// The current focus path (breadcrumb, deliverable 5) — leading, emphasized.
    /// Under the live scan a node id IS its absolute path, so this is the focus's
    /// path. Truncates at the HEAD so the deepest components stay visible.
    private let focusLabel = NSTextField(labelWithString: "")
    /// The volume accounting line (TZ-2), now one NSTextField per field so each
    /// carries its own hover tooltip (deliverable 5d) — trailing, monospaced digits.
    private let volumeStack = NSStackView()
    /// Reused pool of field labels (max 6: Capacity/Free/Reclaimable/Available up
    /// to/Scanned + the scan indicator). Fixed and small → reuse, no per-update
    /// churn (the CanvasView.setTileLabels pattern).
    private var fieldLabels: [NSTextField] = []
    private static let maxFields = 6

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
    /// every relayout / focus change.
    func setFocusPath(_ path: String) {
        focusLabel.stringValue = path
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
        out.append(VolumeField(
            value: s.running ? "● scanning…" : "✓ scan complete",
            tooltip: s.running ? "A scan is in progress; sizes are still growing."
                               : "The scan has finished; sizes are final for this run."))
        return out
    }
}
