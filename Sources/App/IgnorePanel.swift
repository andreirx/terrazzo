//
//  IgnorePanel.swift — the side-panel Ignore list (TZ-5 deliverable 1).
//  Module maturity: PROTOTYPE (slice TZ-5)
//
//  The ledger for the IGNORE lens (PLAN §TZ-5, human-named "Ignore list"). Each ignored
//  tile appears as one ROW: a hue CHIP (its top-level colour), its NAME, and its SIZE.
//  The WHOLE ROW is the restore affordance — ONE CLICK anywhere on it restores the tile
//  to the map (no separate button; the packet's "whole row = the affordance"). The panel
//  exists ONLY while the ignore set is non-empty (AppDelegate/ChromeContainer hides it when
//  depleted), floating at the top-right of the canvas so it covers as little of the map as
//  possible (the freed space the founding gesture reveals is on the left/centre).
//
//  It is pure presentation: NavigationController (which owns the ignore set) hands it
//  `[Entry]` value snapshots captured off the denormalized `TileRect` at ignore time — the
//  panel never touches the pipeline or the tree. A restore click calls back `onRestore(id)`.
//
//  EVERY ROW IS REACHABLE (TZ-5 review-2 change 1). The rows live in a bounded, SCROLLABLE
//  list: ChromeContainer clamps the panel height to the canvas, and when more rows than fit are
//  ignored the list SCROLLS rather than dropping any. The earlier fix capped the list at 40 rows
//  and replaced the overflow with a non-clickable "… N more" label — but a capped-off entry then
//  had no name/size/hue chip and could not be restored with one click, breaking the Ignore-list
//  contract (every ignored tile restorable). No cap now: N ignored tiles ⇒ N clickable rows.
//
//  ABSTRACTION LEDGER: two concrete views (IgnorePanel + its private IgnoreRow), one owner
//  (AppDelegate builds it; NavigationController fills it; ChromeContainer positions it). No
//  protocol. Axis of variation: none — a fixed scrollable list-of-rows presentation. Rejected
//  simpler alternative: reuse the denied-list NSPopover — a popover is transient (dismisses on any
//  outside click) and cursor-anchored, but the Ignore list must PERSIST beside the map while
//  non-empty and update live as tiles are ignored/restored, which a `.transient` popover cannot.
//

import AppKit

final class IgnorePanel: NSView {
    /// One ignored tile as a value snapshot (id/name/hue captured off its `TileRect` at ignore
    /// time). `bytes` is MUTABLE: NavigationController refreshes it each scene from the pipeline's
    /// live per-id retained total (`RenderScene.ignoredCurrentById`, review-0 change 2), so a
    /// growing ignored directory's row size tracks the scan instead of freezing at ignore time.
    struct Entry: Equatable {
        let id: String
        let name: String
        var bytes: Int64
        let hue: Double
    }

    static let width: CGFloat = 240

    /// Restore callback — the whole row triggers it with the entry's id.
    var onRestore: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Ignored")
    /// The rows scroll when there are more than the (canvas-clamped) panel height fits, so EVERY
    /// ignored entry stays reachable/clickable — never a non-restorable summary (review-2 change 1).
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
        // Translucent dark card over the map, with a hairline border so it reads as a panel.
        layer?.backgroundColor = CGColor(gray: 0.12, alpha: 0.94)
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = CGColor(gray: 0.32, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1) // app-palette (deliverable 5)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        // The scrollable rows region. Transparent (the panel card shows through), no border,
        // scrollers auto-hide so the list looks like a plain column until it overflows.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay // overlay scrollers do not steal row width
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(rowStack)
        scrollView.documentView = docView

        addSubview(titleLabel)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // The scroll view fills from below the title to the panel bottom; ChromeContainer sets
            // the panel's (clamped) height, so the list scrolls when the rows exceed it.
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            // The document (rows column) is as wide as the clip and grows only in height.
            docView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rowStack.topAnchor.constraint(equalTo: docView.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("IgnorePanel is code-only") }

    /// Whether the panel has anything to show (AppDelegate toggles visibility on this).
    var isEmpty: Bool { entries.isEmpty }

    /// Replace the rows from `entries` (largest-first, so the monster you ignored is on top).
    /// EVERY entry gets a clickable row — no cap; the list scrolls if they exceed the panel height
    /// (review-2 change 1).
    func setEntries(_ entries: [Entry]) {
        self.entries = entries
        for v in rowStack.arrangedSubviews { v.removeFromSuperview() }

        titleLabel.stringValue = entries.count == 1 ? "Ignored (1)" : "Ignored (\(entries.count))"
        for e in entries.sorted(by: { $0.bytes > $1.bytes }) {
            let row = IgnoreRow(entry: e, sizeText: Self.byteFmt.string(fromByteCount: e.bytes))
            row.onClick = { [weak self] id in self?.onRestore?(id) }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        needsLayout = true
    }

    /// The NATURAL height the panel wants (title + ALL rows, unclamped). ChromeContainer clamps
    /// this to the canvas height; when clamped, the scroll view shows a subset and scrolls, so no
    /// entry is lost. Computed directly from the row column (a scroll view's own `fittingSize`
    /// collapses to its minimum, so it cannot report the document height).
    func contentHeight() -> CGFloat {
        rowStack.layoutSubtreeIfNeeded()
        let titleH = titleLabel.intrinsicContentSize.height
        let rowsH = rowStack.fittingSize.height
        // 8 (top) + title + 6 (gap) + rows + 8 (bottom) — mirrors the constraint constants above.
        return max(8 + titleH + 6 + rowsH + 8, 40)
    }

    // MARK: - Audit seam (offscreen chrome gate, TZ-5 review-3)
    //
    // The chrome host (scripts/chrome_host.swift) must PROVE — through the real ChromeContainer at
    // both window sizes — that an OVERFLOWING list (more ignored rows than the canvas-clamped height
    // fits) still reaches its final row by SCROLLING, never dropping it (the review-2 contract:
    // every ignored tile restorable). These two `internal` accessors give the host the exact facts
    // it needs without publishing the private scroll plumbing; they are compiled into the App module
    // but read only by the audit host, never by the running app. Simpler rejected alternative:
    // inspect `scrollView`/`docView` from the host — impossible, they are (correctly) private.

    /// Number of clickable rows currently laid out (== ignored count; proves no cap / no summary row).
    var auditRowCount: Int { rowStack.arrangedSubviews.count }

    /// Whether the document (all rows) is taller than the visible clip — i.e. the list is genuinely
    /// SCROLLING rather than fitting, and whether, scrolled fully down, the LAST row lands inside the
    /// visible rect. Returns `overflows` (document exceeds clip) and `lastRowReachable`.
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

/// A top-left-origin document view so the row column stacks DOWNWARD inside the scroll view
/// (AppKit's default bottom-left origin would otherwise pin the first row to the bottom).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One ignored-tile row: hue chip + name + size, the WHOLE row a click target that restores
/// the tile (the packet's "one click on the row restores it — the whole row is the affordance").
/// A tracking area gives a hover highlight so the row reads as clickable.
private final class IgnoreRow: NSView {
    var onClick: ((String) -> Void)?
    private let id: String
    private var tracking: NSTrackingArea?

    init(entry: IgnorePanel.Entry, sizeText: String) {
        self.id = entry.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        translatesAutoresizingMaskIntoConstraints = false

        // Hue chip — the tile's top-level colour (medium-sat, matching the map's tint rule).
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

        addSubview(chip); addSubview(name); addSubview(size)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 10),
            chip.heightAnchor.constraint(equalToConstant: 10),
            name.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            size.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Click to restore this tile to the map."
    }

    required init?(coder: NSCoder) { fatalError("IgnoreRow is code-only") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = CGColor(gray: 0.28, alpha: 1)
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
    override func mouseDown(with event: NSEvent) {
        onClick?(id) // the WHOLE row restores — no separate button
    }
}
