//
//  WatchlistPanel.swift — the side-panel WATCHLIST (TZ-10 item 1).
//  Module maturity: PROTOTYPE (slice TZ-10)
//
//  THE WATCHLIST (PLAN §TZ-10 item 1, human field ruling 2026-08-17). Adding a tile to the
//  Watchlist removes it from layout (siblings renormalize into the freed area — the founding
//  gesture: retire the known monster, see the long tail). The panel is a REAL VISIBLE LIST: every entry is a ROW carrying
//  a hue CHIP (its top-level colour), the FILENAME, the PATH relative to its volume, and the
//  SIZE. ONE CLICK anywhere on a row restores that tile to the map (no separate button). An
//  EXPORT button writes the whole list as plain text (`WatchlistExport` — the pure format;
//  NSSavePanel here). The panel exists ONLY while non-empty (AppDelegate/ChromeContainer hides
//  it when depleted), floating top-right so it covers as little of the map as possible.
//
//  Pure presentation: NavigationController (which owns the watchlist) hands it `[Entry]` value
//  snapshots captured off the denormalized `TileRect` at add time — the panel never touches the
//  pipeline or the tree. A restore click calls back `onRestore(id)`; Export calls `onExport()`.
//
//  EVERY ROW IS REACHABLE (inherited TZ-5 review-2 contract). Rows live in a bounded, SCROLLABLE
//  list: ChromeContainer clamps the panel height to the canvas, and when more rows than fit are
//  present the list SCROLLS rather than dropping any — N watchlisted tiles ⇒ N clickable rows.
//
//  ABSTRACTION LEDGER: two concrete views (WatchlistPanel + its private WatchlistRow), one owner
//  (AppDelegate builds it; NavigationController fills it; ChromeContainer positions it). No
//  protocol. Axis of variation: none — a fixed scrollable list-of-rows presentation with an
//  export action. Rejected simpler alternative: reuse the denied-list NSPopover — a popover is
//  transient (dismisses on any outside click) and cursor-anchored, but the Watchlist must PERSIST
//  beside the map while non-empty and update live, which a `.transient` popover cannot.
//

import AppKit

final class WatchlistPanel: NSView {
    /// One watchlisted tile as a value snapshot (id/name/relativePath/hue captured off its
    /// `TileRect` at add time). `bytes` is MUTABLE: NavigationController refreshes it each scene
    /// from the pipeline's live per-id retained total (`RenderScene.watchlistCurrentById`), so a
    /// growing watchlisted directory's row size tracks the scan instead of freezing.
    struct Entry: Equatable {
        let id: String
        let name: String
        /// Path relative to the volume root (`RelativePath.of(id, under: volumeRoot)`) — the
        /// second line of the row (item 1: "path relative to its volume").
        let relativePath: String
        var bytes: Int64
        let hue: Double
    }

    static let width: CGFloat = 280 // wider than the old 240 to carry the relative path line

    /// Restore callback — the whole row triggers it with the entry's id.
    var onRestore: ((String) -> Void)?
    /// Export callback — the Export button triggers it (the App runs the NSSavePanel).
    var onExport: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Watchlist")
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let docView = FlippedView()
    private let rowStack = NSStackView()
    private var entries: [Entry] = []

    private static let byteFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f
    }()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0.12, alpha: 0.94)
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = CGColor(gray: 0.32, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1) // app-palette (chrome audit)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .small
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.toolTip = "Write the watchlist to a plain-text file (one line per entry: size and path)."
        exportButton.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(rowStack)
        scrollView.documentView = docView

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(exportButton)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            // The export button pins to the bottom; the scroll list fills the space above it.
            exportButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            exportButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: exportButton.topAnchor, constant: -6),
            docView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rowStack.topAnchor.constraint(equalTo: docView.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("WatchlistPanel is code-only") }

    /// Whether the panel has anything to show (AppDelegate toggles visibility on this).
    var isEmpty: Bool { entries.isEmpty }

    @objc private func exportClicked() { onExport?() }

    /// Replace the rows from `entries` (largest-first). EVERY entry gets a clickable row — no cap;
    /// the list scrolls if they exceed the panel height.
    func setEntries(_ entries: [Entry]) {
        self.entries = entries
        for v in rowStack.arrangedSubviews { v.removeFromSuperview() }
        titleLabel.stringValue = "Watchlist (\(entries.count))"
        for e in entries.sorted(by: { $0.bytes > $1.bytes }) {
            let row = WatchlistRow(entry: e, sizeText: Self.byteFmt.string(fromByteCount: e.bytes))
            row.onClick = { [weak self] id in self?.onRestore?(id) }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        needsLayout = true
    }

    /// The NATURAL height the panel wants (title + ALL rows + export button, unclamped).
    /// ChromeContainer clamps this to the canvas height; when clamped the scroll view shows a
    /// subset and scrolls, so no entry is lost.
    func contentHeight() -> CGFloat {
        rowStack.layoutSubtreeIfNeeded()
        let titleH = titleLabel.intrinsicContentSize.height
        let rowsH = rowStack.fittingSize.height
        let exportH = exportButton.intrinsicContentSize.height
        // 8 (top) + title + 6 + rows + 6 + export + 8 (bottom) — mirrors the constraint constants.
        return max(8 + titleH + 6 + rowsH + 6 + exportH + 8, 60)
    }

    // MARK: - Audit seam (offscreen chrome gate)

    /// Number of clickable rows currently laid out (== watchlist count; proves no cap / no summary).
    var auditRowCount: Int { rowStack.arrangedSubviews.count }

    /// Whether the document (all rows) is taller than the visible clip — i.e. the list is genuinely
    /// SCROLLING — and whether, scrolled fully down, the LAST row lands inside the visible rect.
    func auditScrollReachability() -> (overflows: Bool, lastRowReachable: Bool) {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let docH = docView.frame.height
        let clipH = clip.bounds.height
        let overflows = docH > clipH + 0.5
        guard let last = rowStack.arrangedSubviews.last else { return (overflows, true) }
        clip.scroll(to: NSPoint(x: 0, y: max(0, docH - clipH)))
        scrollView.reflectScrolledClipView(clip)
        layoutSubtreeIfNeeded()
        let rowInDoc = last.convert(last.bounds, to: docView)
        return (overflows, scrollView.documentVisibleRect.intersects(rowInDoc))
    }
}

/// A top-left-origin document view so the row column stacks DOWNWARD inside the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One watchlisted-tile row: hue chip + (name·size on top, relative path below), the WHOLE row a
/// click target that restores the tile. A tracking area gives a hover highlight so it reads as
/// clickable.
private final class WatchlistRow: NSView {
    var onClick: ((String) -> Void)?
    private let id: String
    private var tracking: NSTrackingArea?

    init(entry: WatchlistPanel.Entry, sizeText: String) {
        self.id = entry.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 2
        chip.layer?.backgroundColor = NSColor(hue: CGFloat(entry.hue.truncatingRemainder(dividingBy: 1)),
                                              saturation: 0.6, brightness: 0.9, alpha: 1).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: entry.name.isEmpty
            ? (entry.id as NSString).lastPathComponent : entry.name)
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let size = NSTextField(labelWithString: sizeText)
        size.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        size.textColor = NSColor(calibratedWhite: 0.66, alpha: 1)
        size.translatesAutoresizingMaskIntoConstraints = false
        size.setContentHuggingPriority(.required, for: .horizontal)

        // The volume-relative path (item 1) — dim, second line, middle-truncated.
        let path = NSTextField(labelWithString: entry.relativePath)
        path.font = .systemFont(ofSize: 9, weight: .regular)
        path.textColor = NSColor(calibratedWhite: 0.58, alpha: 1)
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(chip); addSubview(name); addSubview(size); addSubview(path)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            chip.widthAnchor.constraint(equalToConstant: 10),
            chip.heightAnchor.constraint(equalToConstant: 10),
            name.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            size.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
        toolTip = "Click to restore this tile to the map."
    }

    required init?(coder: NSCoder) { fatalError("WatchlistRow is code-only") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = CGColor(gray: 0.28, alpha: 1) }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func mouseDown(with event: NSEvent) { onClick?(id) } // the WHOLE row restores
}
