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

/// The live-monitoring capability the status strip reports (TZ-7 deliverable 5, review-1 change 4).
/// A SUM TYPE, not a bool, because "recovering" is a distinct third state the reviewer requires be
/// stated honestly: after a kernel event LOSS a one-level check cannot be trusted, so the map is
/// re-scanning the affected subtrees and SAYS so until it catches up — never silently "Live".
enum LiveStatus: Equatable {
    /// FSEvents stream up; the map updates from kernel notifications with no rescan.
    case live
    /// FSEvents stream up but recovering from a dropped-events burst (`MustScanSubDirs`/overflow):
    /// affected subtrees are being re-validated; some tiles may lag until it finishes.
    case degraded
    /// FSEvents stream unavailable — Tier-1 only (focus/idle mtime checks). Rescan for a full refresh.
    case off
}

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
    /// The active AREA SCALE this scene was rendered with (TZ-5 deliverable 2). Drives the
    /// always-visible "Sqrt scale"/"Linear" status field (the honesty guard). Echoed from the
    /// scene, so the label matches what is actually drawn. Default `.sqrt` (the ratified default).
    var scaleMode: AreaScale = .sqrt
    /// Retained total of nodes filtered out for being HIDDEN (TZ-5 deliverable 3), from the scene.
    /// Drives the "hidden filtered · X GB" field, shown only when non-zero (show-hidden off AND
    /// hidden mass in view). Default 0 keeps pre-TZ-5 call sites compiling.
    var hiddenFilteredBytes: Int64 = 0
    /// TZ-7 deliverable 5: the live change-monitoring capability (`.live`/`.degraded`/`.off`). Drives
    /// the subtle "Live" indicator; a `.degraded` (recovering from an event loss) or `.off` (stream
    /// unavailable, Tier-1 only) state is STATED in the field/tooltip — never a silent drop or a false
    /// "Live" claim (review-1 change 4). Default `.live` keeps pre-TZ-7 call sites compiling.
    var live: LiveStatus = .live

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
    /// Up to: Capacity/Free/Reclaimable/Available up to/Scanned/Unaccounted (6) + Ignored +
    /// Hidden-filtered + below-pixel + Scale + scan-indicator (5) + Live (1, TZ-7) = 12.
    private static let maxFields = 12

    /// IGNORE accounting (TZ-5 deliverable 1) — the count of ignored tiles + the EXCLUDED UNION
    /// mass, pushed by NavigationController. The count is App-owned (the ignore set it holds); the
    /// bytes are the pipeline's live `RenderScene.ignoredBytes` — the reducer's exact union of the
    /// ignored subtrees, recomputed every emit (streaming-current, overlap-deduplicated, review-0
    /// change 2), NOT a sum of size-at-ignore snapshots. Session-GLOBAL (an ignored monster stays
    /// counted regardless of the current focus). Rebuilt into the field row on either update.
    private var ignoredCount = 0
    private var ignoredBytes: Int64 = 0
    /// The last scene-derived status, held so an ignore-accounting change can rebuild the row
    /// without waiting for the next scene.
    private var lastStatus: ScanStatus?

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

    /// A width change (live window resize) re-runs the responsive field drop against the new width,
    /// without rebuilding the field strings (review-1 change 4).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !currentFields.isEmpty { applyResponsiveVisibility() }
    }

    func update(_ status: ScanStatus) {
        lastStatus = status
        rebuild()
    }

    /// Push the IGNORE accounting (TZ-5 deliverable 1). `bytes` is ALWAYS the pipeline's exact
    /// excluded UNION mass (`RenderScene.ignoredBytes`), never an App-side snapshot sum
    /// (review-1 change 2): NavigationController calls this from `refreshIgnoreAccounting` on each
    /// scene, and once with `(0, 0)` on restore-to-empty. Streaming-current and
    /// overlap-deduplicated by construction.
    func setIgnoredAccounting(count: Int, bytes: Int64) {
        ignoredCount = count
        ignoredBytes = bytes
        rebuild()
    }

    /// Width reserved at the LEADING edge for the focus breadcrumb + margins + the stack gap, when
    /// computing how much room the trailing figures have. The breadcrumb head-truncates into this
    /// floor under pressure (volume figures take priority — the compression rule below); it is a
    /// capacity budget for the drop math, not a hard focus width.
    private static let reservedLeadingWidth: CGFloat = 84

    private func rebuild() {
        guard let status = lastStatus else { return }
        let fields = Self.fields(status, ignoredCount: ignoredCount, ignoredBytes: ignoredBytes)
        // Assign content to the reused pool (extra slots blanked); the responsive pass decides which
        // stay visible.
        for (i, label) in fieldLabels.enumerated() where i < fields.count {
            label.stringValue = fields[i].value
            label.toolTip = fields[i].tooltip
        }
        currentFields = fields
        applyResponsiveVisibility()
    }

    /// The fields currently assigned to the pool (index-parallel with the leading `fieldLabels`),
    /// held so a width change (`setFrameSize`) can re-run the drop without rebuilding the strings.
    private var currentFields: [VolumeField] = []

    /// RESPONSIVE STRIP (review-1 change 4). Show as many fields as fit the strip width; when they
    /// don't all fit, DROP the lowest-`rank` fields first (widest-first among equal rank, to free
    /// the most space per drop), never an `essential` one — so the TZ-5 required figures (active
    /// scale, ignored/hidden accounting, scan state) stay unclipped at every width while the verbose
    /// volume detail yields. Deterministic (measured intrinsic widths, no reliance on NSStackView
    /// auto-detach) so the chrome-visibility gate can prove it at 700 and 1400 px.
    private func applyResponsiveVisibility() {
        let fields = currentFields
        let widths = (0..<fields.count).map { fieldLabels[$0].intrinsicContentSize.width }
        var keep = Set(0..<fields.count)
        func totalWidth() -> CGFloat {
            let content = keep.reduce(CGFloat(0)) { $0 + widths[$1] }
            return content + CGFloat(max(0, keep.count - 1)) * volumeStack.spacing
        }
        let available = max(0, bounds.width - Self.reservedLeadingWidth - 10) // -10 trailing margin
        // Only drop once the view has a real width (0 before first layout → keep all; setFrameSize
        // reruns this with the true width). Essentials are never dropped, so a width too small for
        // even them leaves them in place (the unavoidable minimum) rather than blanking the strip.
        if bounds.width > 1 {
            while totalWidth() > available {
                let victim = keep
                    .filter { fields[$0].importance != .essential }
                    .min { a, b in
                        let ra = fields[a].importance.rank, rb = fields[b].importance.rank
                        return ra != rb ? ra < rb : widths[a] > widths[b] // lowest rank, then widest
                    }
                guard let victim else { break } // only essentials remain
                keep.remove(victim)
            }
        }
        for (i, label) in fieldLabels.enumerated() {
            let visible = i < fields.count && keep.contains(i)
            if label.isHidden == visible { label.isHidden = !visible } // touch only on real change
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

    /// The committed focus breadcrumb (NOT the transient hover override) — a test seam for the
    /// headless trace, which samples it at a dive/ascend commit to prove the label tracks the focus
    /// stack synchronously (OPERATOR_NOTE 2026-08-17 #1), never lagging until a scene arrives.
    var focusPathValue: String { focusPath }

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

    /// How hard a field fights to STAY VISIBLE when the strip is too narrow for all of them
    /// (review-1 change 4). The strip carries up to 11 fields; at 700 px they cannot all fit, so
    /// the low-value volume figures must yield while the required TZ-5 fields stay readable. The
    /// responsive layout (`applyResponsiveVisibility`) drops the LOWEST-rank fields first until the
    /// rest fit the strip width; `essential` is never dropped. (An earlier draft leaned on
    /// NSStackView's own `visibilityPriority` auto-detach, but under an unsatisfiable width the
    /// stack broke its trailing constraint and OVERFLOWED off the right edge instead of detaching —
    /// the chrome-visibility gate caught the essentials clipped at x≈930…1415 on the 700 px strip.
    /// So the drop decision is made HERE, deterministically, from measured field widths.)
    enum Importance: Equatable {
        /// TZ-5 required-always fields: active scale, ignored accounting, hidden-filtered
        /// accounting, scan state. The slice mandates these remain visibly readable at every width.
        case essential
        /// Core scan figures worth keeping when there is room (Scanned total): drop only under
        /// severe pressure.
        case high
        /// Ordinary informational fields (Free, below-pixel count).
        case normal
        /// Verbose volume-reconciliation detail (Capacity, Reclaimable, Available up to,
        /// Unaccounted): the first to yield on a narrow window — its numbers live in the tooltips.
        case low

        /// Drop order: LOWER rank yields first. `essential` (highest) never yields.
        var rank: Int {
            switch self {
            case .low: return 0
            case .normal: return 1
            case .high: return 2
            case .essential: return 3
            }
        }
    }

    /// One rendered field: the on-strip text, its one-sentence hover tooltip, and how hard it
    /// fights to stay visible under width pressure. `importance` defaults to `.normal` so the
    /// existing call sites read unchanged; the required and the droppable fields set it explicitly.
    struct VolumeField: Equatable {
        let value: String
        let tooltip: String
        var importance: Importance = .normal
    }

    /// Pure builder for the status fields, in the ratified order
    /// `Capacity · Free · Reclaimable · Available up to · Scanned` (+ scan
    /// indicator). Plain-language names in the UI; the API terms live in the
    /// tooltips/comments only (deliverable 5d). Testable without AppKit.
    static func fields(_ s: ScanStatus, ignoredCount: Int = 0, ignoredBytes: Int64 = 0) -> [VolumeField] {
        var out: [VolumeField] = []
        if let v = s.volume {
            out.append(VolumeField(
                value: "Capacity \(b(v.capacityBytes))",
                tooltip: "Total formatted size of this volume.",
                importance: .low))
            // Free = volumeAvailableCapacity (the strict free-space API).
            out.append(VolumeField(
                value: "Free \(b(v.availableBytes))",
                tooltip: "Unallocated space right now.",
                importance: .normal))
            // Reclaimable = purgeable (important − available).
            out.append(VolumeField(
                value: "Reclaimable \(b(v.purgeableBytes))",
                tooltip: "Space macOS frees automatically when needed: local Time Machine snapshots, caches, cloud-synced files.",
                importance: .low))
            // Available up to = volumeAvailableCapacityForImportantUsage.
            out.append(VolumeField(
                value: "Available up to \(b(v.availableForImportantBytes))",
                tooltip: "Free + reclaimable: what the system would give an important write — why different tools report different free space.",
                importance: .low))
        } else {
            out.append(VolumeField(value: "Volume —",
                                   tooltip: "Volume accounting is not available yet.",
                                   importance: .normal))
        }
        out.append(VolumeField(
            value: "Scanned \(b(s.scannedBytes))",
            tooltip: "Total size Terrazzo has measured so far.",
            importance: .high))
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
                tooltip: "Volume space Terrazzo could not measure: capacity − free − scanned. Split into reclaimable (purgeable) space and files no scan from this account can see — other users’ home folders and snapshots (Full Disk Access never crosses user boundaries). The two parts always add up to the total. Not a folder; never drawn on the map.",
                importance: .high)) // the founding-mystery reconciliation figure (VISION) — survives
                                    // width pressure over the incidental volume fields; yields only
                                    // at the narrowest widths where the TZ-5 essentials must win
        }
        // IGNORE accounting (TZ-5 deliverable 1) — shown while any tile is ignored. The invisible-
        // space principle applied to user-hidden mass: an ignored monster is still ACCOUNTED, never
        // silently vanished. Session-global (the App owns the count/bytes, focus-independent).
        if ignoredCount > 0 {
            out.append(VolumeField(
                value: "\(ignoredCount) ignored · \(b(ignoredBytes)) excluded",
                tooltip: "Tiles you excluded from the map this session (their siblings filled the freed space). Click a row in the Ignore list to restore one. The scan still measured them — nothing was deleted or rescanned.",
                importance: .essential)) // TZ-5 required-visible at every width
        }
        // HIDDEN-FILTERED accounting (TZ-5 deliverable 3) — shown only when show-hidden is OFF and
        // hidden mass is actually in view. Never double-counts ignored mass (ignored subtrees are
        // accounted above and are not descended into for this figure).
        if s.hiddenFilteredBytes > 0 {
            out.append(VolumeField(
                value: "hidden filtered · \(b(s.hiddenFilteredBytes))",
                tooltip: "Dotfiles and hidden (UF_HIDDEN) items are hidden from the map because “Show hidden files” is off. The scan still includes them; this is the size filtered from view. Turn the checkbox back on to see them.",
                importance: .essential)) // TZ-5 required-visible when show-hidden is off
        }
        // Sub-pixel cull count — shown only when non-zero (no "0 tiles" clutter on a
        // small map). PLAN §"Rendering scale": culled tiles are REPORTED, never silently
        // dropped — the invisible-space principle applied to below-pixel mass.
        if s.belowPixelCount > 0 {
            out.append(VolumeField(
                value: "\(s.belowPixelCount) tiles below pixel size",
                tooltip: "Tiles too small to draw (< ~2 px) at this zoom, so they are not shown. Zoom in to see them; nothing is silently dropped.",
                importance: .normal))
        }
        // ACTIVE SCALE — ALWAYS shown (TZ-5 deliverable 2 honesty guard, VISION: "the active
        // scale is always labeled"). Echoed from the scene so it matches what is drawn; the
        // numbers on tiles/hover are always REAL bytes in either mode.
        switch s.scaleMode {
        case .sqrt:
            out.append(VolumeField(value: "Sqrt scale",
                tooltip: "Tile areas are sqrt-compressed so giant folders don’t eclipse the long tail, while equal size ratios still render as equal area ratios at every depth. The sizes shown on tiles and in hover are always the real bytes; only the areas are compressed. Switch to Linear in the toolbar for true proportions.",
                importance: .essential)) // TZ-5 deliverable 2 honesty guard: the active scale is ALWAYS shown
        case .linear:
            out.append(VolumeField(value: "Linear",
                tooltip: "Tile areas are true-proportional to bytes — the huge folders look huge. Switch to Sqrt scale in the toolbar to expose the long tail.",
                importance: .essential))
        }
        out.append(VolumeField(
            value: s.running ? "● scanning…" : "✓ scan complete",
            tooltip: s.running ? "A scan is in progress; sizes are still growing."
                               : "The scan has finished; sizes are final for this run.",
            importance: .essential)) // the running/complete state must never be clipped off
        // LIVE indicator (TZ-7 deliverable 5) — a subtle marker that the FSEvents change stream is
        // active, so deletions/additions retire or add tiles WITHOUT a rescan. If the stream could not
        // be created the map degrades to Tier-1 (focus/idle mtime checks); that degradation is stated
        // in the tooltip HERE (never a silent drop — the invisible-space principle applied to
        // capability honesty). Kept subtle (`.normal`) so it yields before the essentials on a narrow
        // strip; at normal widths it is always readable.
        switch s.live {
        case .live:
            out.append(VolumeField(
                value: "◉ Live",
                tooltip: "The map is watching the filesystem: deletions, additions, and changes update tiles automatically (FSEvents), no rescan needed.",
                importance: .normal))
        case .degraded:
            // review-1 change 4: a kernel event loss (MustScanSubDirs / dropped queue) means a
            // one-level check cannot be trusted; the map is re-validating the affected subtrees. Say
            // so — never keep claiming full "Live" while recovering.
            out.append(VolumeField(
                value: "◉ Live · recovering",
                tooltip: "A burst of filesystem changes overflowed the live event stream, so some events were dropped. Terrazzo is re-scanning the affected folders to catch up; a few tiles may lag until it finishes. If something still looks stale, use Rescan.",
                importance: .normal))
        case .off:
            out.append(VolumeField(
                value: "Live off",
                tooltip: "Live file-change monitoring (FSEvents) is unavailable, so the map refreshes only when you change focus or reactivate the app (Tier-1 mtime checks). Use Rescan for a full refresh.",
                importance: .normal))
        }
        return out
    }
}
