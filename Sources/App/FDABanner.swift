//
//  FDABanner.swift — the non-modal Full Disk Access guided-flow banner.
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  TZ-4 deliverable 5. When a volume-root scan starts and the FDA probe reports denied
//  (FDAProbe, in ScanFS), this banner appears BELOW the toolbar. It explains what FDA is
//  and why Terrazzo wants it (read-only mapping), offers a button that opens the exact
//  System Settings pane, and a Rescan affordance for after the grant. It is NON-MODAL and
//  NEVER blocks scanning — the scan proceeds; denied dirs render as denied tiles either
//  way. The banner is a nudge toward a fuller map, not a gate.
//
//  It only shows for a VOLUME-ROOT scan (VolumeSkipPolicy.isVolumeRoot): denial while
//  mapping a single sub-folder does not warrant a system-settings prompt.
//
//  ABSTRACTION LEDGER: one concrete NSView, one owner (AppDelegate). Its two actions are
//  closures the Main assembly binds. No protocol.
//

import AppKit

final class FDABanner: NSView {
    static let height: CGFloat = 56

    /// The exact System Settings pane for Full Disk Access (Privacy & Security → Full
    /// Disk Access). Documented URL scheme; opening it is an OS action, no FS access.
    private static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var onRescan: (() -> Void)?

    private let message = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A muted amber wash — attention without alarm; matches the denied-tile family.
        layer?.backgroundColor = CGColor(red: 0.28, green: 0.20, blue: 0.08, alpha: 1)

        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 11)
        message.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.stringValue = "Some folders can’t be read without Full Disk Access, so parts of this volume show as “no permission”. Terrazzo only reads sizes — it never changes files. Grant access, then Rescan for a complete map."

        let openButton = NSButton(title: "Open Full Disk Access Settings",
                                  target: self, action: #selector(openSettings))
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small

        let rescanButton = NSButton(title: "Rescan", target: self, action: #selector(rescanClicked))
        rescanButton.translatesAutoresizingMaskIntoConstraints = false
        rescanButton.bezelStyle = .rounded
        rescanButton.controlSize = .small

        addSubview(message)
        addSubview(openButton)
        addSubview(rescanButton)

        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            rescanButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rescanButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            openButton.trailingAnchor.constraint(equalTo: rescanButton.leadingAnchor, constant: -8),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("FDABanner is code-only") }

    @objc private func openSettings() { NSWorkspace.shared.open(Self.settingsURL) }
    @objc private func rescanClicked() { onRescan?() }
}
