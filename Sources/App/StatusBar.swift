//
//  StatusBar.swift — the volume-accounting header strip.
//  Module maturity: PROTOTYPE (slice TZ-2)
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

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("StatusBar is code-only") }

    func update(_ status: ScanStatus) {
        label.stringValue = Self.format(status)
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file // decimal GB/MB, matching Finder/Storage Settings
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static func b(_ v: Int64) -> String { bytes.string(fromByteCount: v) }

    static func format(_ s: ScanStatus) -> String {
        var parts: [String] = []
        if let v = s.volume {
            parts.append("Capacity \(b(v.capacityBytes))")
            parts.append("Free \(b(v.availableBytes))")
            parts.append("Important \(b(v.availableForImportantBytes))")
            parts.append("Purgeable \(b(v.purgeableBytes))")
        } else {
            parts.append("Volume —")
        }
        parts.append("Scanned \(b(s.scannedBytes))")
        parts.append(s.running ? "● scanning…" : "✓ scan complete")
        return parts.joined(separator: "    ")
    }
}
