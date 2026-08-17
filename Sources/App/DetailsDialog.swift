//
//  DetailsDialog.swift — the volume-accounting Details dialog (TZ-10 item 5).
//  Module maturity: PROTOTYPE (slice TZ-10)
//
//  TZ-10 item 5 (human field ruling 2026-08-17, with OPERATOR_NOTE A): the status bar shrank to
//  focus · Free X of Y capacity · state · Details, and every accounting figure EXCEPT that retained
//  Free figure moved HERE — a dialog the DETAILS button opens and that AUTO-POPS ONCE when a
//  scan completes. It shows exactly what the old crowded status strip did, plus the watchlist
//  exclusion, laid out one fact per line with the same one-sentence hover tooltips:
//      Capacity · Free · Reclaimable · Available up to · Scanned · Unaccounted (decomposed) ·
//      Watchlist (when non-empty) · hidden-filtered (when off) · culled tiles · active scale ·
//      scan state (with the retained-footprint projection) · live-monitoring capability.
//
//  TWO PIECES:
//   • `DetailsReport` — the PURE line builder (moved verbatim out of `StatusBar` in TZ-10, where the
//     retired `StatusBar.fields` static func built these same lines for the old crowded strip; the
//     honesty wording and the `UnaccountedSpace`/footprint math are unchanged). No AppKit.
//   • `DetailsView` — renders the lines as labelled rows with tooltips. Its static `make(...)` lets
//     the headless chrome audit build and inspect it OFFSCREEN (no window), exactly as the denied
//     popover is audited — the accounting text the audit used to find on the status bar now lives
//     here, so the audit follows it.
//  The App presents `DetailsView` in an NSPopover anchored to the status bar's Details button
//  (AppDelegate) — no separate window is raised (builder-conduct-safe; app behavior).
//
//  ABSTRACTION LEDGER: `DetailsReport` is a namespace of pure funcs (one caller: DetailsView + the
//  chrome audit); `DetailsView` is one concrete view (users: AppDelegate's popover + the audit). No
//  protocol, no variation axis. Rejected simpler alternative: keep the fields on the status strip —
//  the field report explicitly retired that ("reduced to focus path · scan state · a DETAILS button").
//

import AppKit

enum DetailsReport {
    /// One rendered accounting line: the on-dialog text + its one-sentence hover tooltip.
    struct Line: Equatable {
        let value: String
        let tooltip: String
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file // decimal GB/MB, matching Finder/Storage Settings
        f.allowsNonnumericFormatting = false
        return f
    }()
    private static func b(_ v: Int64) -> String { bytes.string(fromByteCount: v) }

    private static let counter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return f
    }()
    private static func count(_ n: Int) -> String { counter.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// Build the accounting lines, in the ratified order. `watchlistCount`/`watchlistBytes` are the
    /// App's live watchlist accounting (from `RenderScene.watchlistBytes`); the rest come off the
    /// `ScanStatus`. Plain-language names in the UI; API terms live in the tooltips only.
    static func lines(_ s: ScanStatus, watchlistCount: Int, watchlistBytes: Int64) -> [Line] {
        var out: [Line] = []
        if let v = s.volume {
            out.append(Line(value: "Capacity \(b(v.capacityBytes))",
                            tooltip: "Total formatted size of this volume."))
            out.append(Line(value: "Free \(b(v.availableBytes))",
                            tooltip: "Unallocated space right now."))
            out.append(Line(value: "Reclaimable \(b(v.purgeableBytes))",
                            tooltip: "Space macOS frees automatically when needed: local Time Machine snapshots, caches, cloud-synced files."))
            out.append(Line(value: "Available up to \(b(v.availableForImportantBytes))",
                            tooltip: "Free + reclaimable: what the system would give an important write — why different tools report different free space."))
        } else {
            out.append(Line(value: "Volume —", tooltip: "Volume accounting is not available yet."))
        }
        out.append(Line(value: "Scanned \(b(s.scannedBytes))",
                        tooltip: "Total size Terrazzo has measured so far."))
        // UNACCOUNTED (HUMAN FIELD RULING #1: a figure, NEVER a map tile). Always shown when volume
        // accounting is known, INCLUDING zero (a reconciled volume reads "Unaccounted 0").
        if let v = s.volume {
            let u = UnaccountedSpace.figure(capacity: v.capacityBytes, free: v.availableBytes,
                                            scanned: s.scannedBytes, purgeable: v.purgeableBytes)
            out.append(Line(
                value: "Unaccounted \(b(u.total)) (purgeable \(b(u.purgeable)) + other/unknown \(b(u.unknown)))",
                tooltip: "Volume space Terrazzo could not measure: capacity − free − scanned. Split into reclaimable (purgeable) space and files no scan from this account can see — other users’ home folders and snapshots (Full Disk Access never crosses user boundaries). The two parts always add up to the total. Not a folder; never drawn on the map."))
        }
        // WATCHLIST accounting (TZ-10 item 1) — shown while any tile is watchlisted.
        if watchlistCount > 0 {
            out.append(Line(
                value: "\(watchlistCount) on watchlist · \(b(watchlistBytes)) excluded",
                tooltip: "Tiles you added to the Watchlist this session (their siblings filled the freed space). Click a row in the Watchlist panel to restore one. The scan still measured them — nothing was deleted or rescanned."))
        }
        // HIDDEN-FILTERED accounting — shown only when show-hidden is OFF and hidden mass is in view.
        if s.hiddenFilteredBytes > 0 {
            out.append(Line(
                value: "hidden filtered · \(b(s.hiddenFilteredBytes))",
                tooltip: "Dotfiles and hidden (UF_HIDDEN) items are hidden from the map because “Show hidden files” is off. The scan still includes them; this is the size filtered from view."))
        }
        // Sub-pixel cull count — shown only when non-zero.
        if s.belowPixelCount > 0 {
            out.append(Line(
                value: "\(s.belowPixelCount) tiles below pixel size",
                tooltip: "Tiles too small to draw (< ~2 px) at this zoom, so they are not shown. Zoom in to see them; nothing is silently dropped."))
        }
        // ACTIVE SCALE — ALWAYS shown (the honesty guard: the active scale is always labeled).
        switch s.scaleMode {
        case .linear:
            out.append(Line(value: "Linear scale",
                tooltip: "Tile areas are true-proportional to bytes — the huge folders look huge (the default). Switch to Sqrt scale in the toolbar to expose the long tail."))
        case .sqrt:
            out.append(Line(value: "Sqrt scale",
                tooltip: "Tile areas are sqrt-compressed so giant folders don’t eclipse the long tail, while equal size ratios still render as equal area ratios at every depth. The sizes shown on tiles and in hover are always the real bytes; only the areas are compressed."))
        }
        // Scan state + the retained-footprint PROJECTION (name honesty: a projection, not a measurement).
        let retained = max(0, s.filesProcessed)
        let footprint = Int64(retained) * GiantVolumeConsent.estimatedBytesPerNode
        let footprintNote = " Retained \(count(retained)) entries · est. ~\(b(footprint)) of memory (projected at the constant \(GiantVolumeConsent.estimatedBytesPerNode) B/node, not a live measurement)."
        out.append(Line(
            value: s.running ? "● scanning…" : "✓ scan complete",
            tooltip: (s.running ? "A scan is in progress; sizes are still growing."
                                : "The scan has finished; sizes are final for this run.") + footprintNote))
        // LIVE indicator — the FSEvents capability, stated honestly.
        switch s.live {
        case .live:
            out.append(Line(value: "◉ Live",
                tooltip: "The map is watching the filesystem: deletions, additions, and changes update tiles automatically (FSEvents), no rescan needed."))
        case .degraded:
            out.append(Line(value: "◉ Live · recovering",
                tooltip: "A burst of filesystem changes overflowed the live event stream, so some events were dropped. Terrazzo is re-scanning the affected folders to catch up; a few tiles may lag until it finishes. If something still looks stale, use Rescan."))
        case .off:
            out.append(Line(value: "Live off",
                tooltip: "Live file-change monitoring (FSEvents) is unavailable, so the map refreshes only when you change focus or reactivate the app (Tier-1 mtime checks). Use Rescan for a full refresh."))
        }
        return out
    }
}

/// The Details dialog CONTENT: a titled vertical list of accounting rows with per-row tooltips.
/// A plain NSView so the chrome audit can build and inspect it offscreen (no window).
final class DetailsView: NSView {
    private let stack = NSStackView()

    /// Build a Details view for a status snapshot + the App's live watchlist accounting.
    static func make(status: ScanStatus, watchlistCount: Int, watchlistBytes: Int64) -> DetailsView {
        let v = DetailsView(frame: .zero)
        v.set(lines: DetailsReport.lines(status, watchlistCount: watchlistCount, watchlistBytes: watchlistBytes))
        return v
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("DetailsView is code-only") }

    func set(lines: [DetailsReport.Line]) {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Volume details")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        stack.addArrangedSubview(title)
        for line in lines {
            let f = NSTextField(labelWithString: line.value)
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.textColor = NSColor(calibratedWhite: 0.86, alpha: 1) // app-palette (chrome audit)
            f.toolTip = line.tooltip
            f.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(f)
        }
        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        size.width = min(max(size.width, 260), 560)
        frame = NSRect(origin: .zero, size: size)
    }

    /// Preferred content size for the hosting NSPopover.
    var preferredSize: NSSize {
        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        size.width = min(max(size.width, 260), 560)
        return size
    }
}
