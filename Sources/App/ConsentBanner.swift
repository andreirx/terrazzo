//
//  ConsentBanner.swift — the non-modal giant-volume consent strip.
//  Module maturity: PROTOTYPE (slice TZ-9)
//
//  TZ-9 deliverable 4. When the user PICKS a volume whose used-inode count is above the
//  consent threshold (GiantVolumeConsent, in ScanFS), this banner appears BELOW the toolbar
//  with the estimated memory footprint ("≈ N million entries, est. X GB memory — proceed?").
//  A detected Time Machine backup volume is NAMED as such in the message. It is NON-MODAL and
//  REMEMBERED for the session (AppDelegate holds the acknowledged-volume set): "Scan anyway"
//  proceeds and records the acknowledgement; "Cancel" reverts the picker selection and scans
//  nothing. This mirrors the FDABanner pattern exactly (a self-contained dynamic top strip the
//  ChromeContainer re-flows), differing only in message + the two closures.
//
//  WHY A WARNING AT ALL (the field report behind TZ-9): a tens-of-millions-inode volume — a
//  Time Machine hardlink forest — produced a 33 GB RSS. Until the lean node store lands, the
//  honest thing is to tell the user the memory cost before committing their RAM to it. The
//  estimate uses the CURRENTLY-MEASURED bytes/node (GiantVolumeConsent.estimatedBytesPerNode).
//
//  ABSTRACTION LEDGER: one concrete NSView, one owner (AppDelegate); two actions are closures
//  the Main assembly binds. No protocol — same shape as FDABanner.
//

import AppKit

final class ConsentBanner: NSView {
    static let height: CGFloat = 56

    /// Proceed with the scan (records the session acknowledgement in the Main assembly).
    var onProceed: (() -> Void)?
    /// Abandon the selection (reverts the volume picker; scans nothing).
    var onCancel: (() -> Void)?

    private let message = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The same muted amber wash as the FDA banner — attention without alarm, and consistent
        // with the denied-tile family (this is a "before you commit" nudge, not an error).
        layer?.backgroundColor = CGColor(red: 0.28, green: 0.20, blue: 0.08, alpha: 1)

        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 11)
        message.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping

        let proceed = NSButton(title: "Scan anyway", target: self, action: #selector(proceedClicked))
        proceed.translatesAutoresizingMaskIntoConstraints = false
        proceed.bezelStyle = .rounded
        proceed.controlSize = .small
        proceed.keyEquivalent = "\r" // Return = the default affordance

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small

        addSubview(message)
        addSubview(proceed)
        addSubview(cancel)

        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.trailingAnchor.constraint(lessThanOrEqualTo: proceed.leadingAnchor, constant: -12),

            cancel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: centerYAnchor),

            proceed.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            proceed.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("ConsentBanner is code-only") }

    /// Set the consent sentence (composed by the pure `GiantVolumeConsent.evaluate`).
    func setMessage(_ text: String) { message.stringValue = text }

    @objc private func proceedClicked() { onProceed?() }
    @objc private func cancelClicked() { onCancel?() }
}
