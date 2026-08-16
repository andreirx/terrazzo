//
//  ControlBar.swift — the top toolbar strip: volume picker, rescan, progress + ETA.
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  TZ-4 deliverables 2/3/4 collected into one top strip (the "toolbar/status area"):
//    - VolumePicker    — pick a mounted volume to map (rescans it).
//    - Rescan button   — cancel + re-run the current volume (the map is a scan-time
//                        snapshot; rescan refreshes it).
//    - Progress bar    — file-count progress (filesProcessed / statfs used-inodes),
//                        clamped below 100 % while denied files inflate the denominator,
//                        snapping to done on completion; tooltip says "estimate".
//    - ETA label       — a rolling files/sec-derived estimate next to the bar.
//
//  THE PROGRESS ARITHMETIC IS PURE (`ScanCore.ScanProgress`): this view only measures
//  the rolling rate (two timed samples) and formats. The clamp rule ("never claim 100 %
//  mid-scan") lives in the tested value type, not here.
//
//  ABSTRACTION LEDGER: one concrete NSView, one owner (AppDelegate). No protocol; the
//  two actions are closures the Main assembly binds. The rejected alternative — an
//  NSToolbar — is heavier machinery (item identifiers, delegate) for a fixed three-control
//  strip this manual layout expresses directly, matching StatusBar's code-only style.
//

import AppKit

final class ControlBar: NSView {
    static let height: CGFloat = 38

    let volumePicker = VolumePicker()
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let etaLabel = NSTextField(labelWithString: "")

    /// Bound by the Main assembly (AppDelegate). Rescan re-runs the current volume.
    var onRescan: (() -> Void)?

    // Rolling files/sec estimate: keep the last timed sample and smooth with an EMA so a
    // single slow/fast batch does not make the ETA jump. Presentation-only state.
    private var lastFiles = 0
    private var lastSampleTime: CFTimeInterval = 0
    private var smoothedRate: Double = 0
    private static let etaSmoothing = 0.3 // EMA weight on the newest sample

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0.11, alpha: 1)

        rescanButton.translatesAutoresizingMaskIntoConstraints = false
        rescanButton.bezelStyle = .rounded
        rescanButton.controlSize = .small
        rescanButton.target = self
        rescanButton.action = #selector(rescanClicked)
        rescanButton.toolTip = "Cancel and re-run the scan for the current volume."

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.toolTip = "Scan progress by file count (estimate): files stat'd ÷ the volume's used inodes. May finish below 100 % because it counts files no scan from this account can reach."

        etaLabel.translatesAutoresizingMaskIntoConstraints = false
        etaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        etaLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        etaLabel.stringValue = ""

        let volLabel = NSTextField(labelWithString: "Volume")
        volLabel.translatesAutoresizingMaskIntoConstraints = false
        volLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        volLabel.textColor = NSColor(calibratedWhite: 0.70, alpha: 1)

        addSubview(volLabel)
        addSubview(volumePicker)
        addSubview(rescanButton)
        addSubview(progressBar)
        addSubview(etaLabel)

        NSLayoutConstraint.activate([
            volLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            volLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            volumePicker.leadingAnchor.constraint(equalTo: volLabel.trailingAnchor, constant: 8),
            volumePicker.centerYAnchor.constraint(equalTo: centerYAnchor),

            rescanButton.leadingAnchor.constraint(equalTo: volumePicker.trailingAnchor, constant: 10),
            rescanButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            progressBar.leadingAnchor.constraint(greaterThanOrEqualTo: rescanButton.trailingAnchor, constant: 16),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 220),

            etaLabel.leadingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: 10),
            etaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            etaLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("ControlBar is code-only") }

    @objc private func rescanClicked() { onRescan?() }

    /// Update the progress bar + ETA from a scan-progress snapshot (TZ-4). Indeterminate
    /// denominator ⇒ a barber-pole; otherwise the clamped fraction. ETA uses a rolling
    /// files/sec rate measured here and the pure `ScanProgress.etaSeconds` formula.
    func update(_ progress: ScanProgress) {
        if let fraction = progress.fraction {
            if progressBar.isIndeterminate { progressBar.isIndeterminate = false }
            progressBar.doubleValue = fraction
        } else {
            // No denominator yet — show motion, not a fake 0 %.
            if !progressBar.isIndeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
        }
        etaLabel.stringValue = etaText(for: progress)
    }

    /// Measure the rolling rate and format the ETA line. Kept private; the pure ETA
    /// formula is `ScanProgress.etaSeconds`.
    private func etaText(for progress: ScanProgress) -> String {
        guard progress.running else { return "done" }
        let now = CACurrentMediaTime()
        if lastSampleTime > 0 {
            let dt = now - lastSampleTime
            let df = progress.filesProcessed - lastFiles
            if dt >= 0.25 && df >= 0 {
                let instant = Double(df) / dt
                smoothedRate = smoothedRate == 0 ? instant
                    : smoothedRate * (1 - Self.etaSmoothing) + instant * Self.etaSmoothing
                lastSampleTime = now
                lastFiles = progress.filesProcessed
            }
        } else {
            lastSampleTime = now
            lastFiles = progress.filesProcessed
        }
        guard let seconds = progress.etaSeconds(filesPerSecond: smoothedRate) else {
            return "estimating…"
        }
        return "~\(Self.formatDuration(seconds)) left"
    }

    /// "1h 04m", "3m 20s", "45s" — a coarse remaining-time string.
    static func formatDuration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    /// Reset the rolling-rate state (on a rescan / volume switch) so the ETA does not
    /// carry a stale rate across scans.
    func resetProgressSampling() {
        lastFiles = 0; lastSampleTime = 0; smoothedRate = 0
        progressBar.doubleValue = 0
        etaLabel.stringValue = ""
    }
}
