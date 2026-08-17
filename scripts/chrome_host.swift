//
//  chrome_host.swift — headless, offscreen chrome COLOR + STATE AUDIT (TZ-5 d5; TZ-10 items 5/8).
//  Module maturity: PROTOTYPE (slice TZ-5; retargeted TZ-10)
//
//  WHY THIS EXISTS. The chrome audit proves that EVERY text element in the chrome (control bar,
//  the SIMPLIFIED status bar, FDA banner, canvas overlays, the WATCHLIST panel, the DETAILS
//  dialog, popovers) is legible on the dark theme — no near-black-on-dark NSTextField defaults —
//  VERIFIED AT TWO WINDOW SIZES. The builder-conduct rule forbids raising/activating windows on
//  the live desktop, so this host is the conduct-safe, deterministic substitute:
//
//    - It instantiates the REAL chrome views OFFSCREEN (the same classes AppDelegate builds).
//    - It NEVER creates/orders/activates a window (`.prohibited` activation policy).
//    - For each text element it resolves the effective `textColor` under `.darkAqua` and computes
//      Rec.709 luminance; a near-black-on-dark defect FAILS the gate.
//    - It also writes a PNG of each surface (best-effort, no window) for the operator's visual pass.
//
//  TZ-10 RETARGET. Item 5 (with OPERATOR_NOTE A) moved all accounting EXCEPT the "Free X of Y
//  capacity" figure off the status bar into the Details dialog, so the accounting text the audit
//  used to find on the status bar now lives on `DetailsView` — the audit FOLLOWS it there. The
//  status bar audit now covers the focus path + Free figure + scan state. Item 1 introduced the
//  WATCHLIST panel (with a relative-path line + Export button).
//  Item 8 adds a STATE assertion: after a scan reports complete, the ControlBar progress bar must
//  NOT still be animating (the field bug: the barber-pole kept bouncing post-scan).
//
//  Compiled by scripts/chrome.sh with the App chrome sources (minus main.swift) + cores + ScanFS +
//  RenderPipeline — the same monolith arrangement as build.sh, with this file's @main as the entry.
//

import AppKit
import Foundation

@main
struct ChromeHost {
    /// One audited text element.
    struct Finding {
        let surface: String
        let size: String
        let field: String
        let luma: Double
        let text: String
    }

    /// Text-colour luminance floor. App-palette colours are calibratedWhite 0.55…0.98 and the
    /// semantic labels resolve light under .darkAqua; a near-black default (the defect) is ≈ 0.
    static let lumaFloor = 0.40

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
        guard let dark = NSAppearance(named: .darkAqua) else { die("no .darkAqua appearance") }

        var findings: [Finding] = []
        var visFailures: [String] = []
        var deniedGeom: [(String, CGSize)] = []

        for (sizeLabel, width, height) in [("narrow-700", CGFloat(700), CGFloat(760)),
                                           ("wide-1400", CGFloat(1400), CGFloat(1000))] {
            findings += audit(surface: "ControlBar", size: sizeLabel, dark: dark, outDir: outDir,
                              view: makeControlBar(width: width))
            let statusBar = makeStatusBar(width: width)
            findings += audit(surface: "StatusBar", size: sizeLabel, dark: dark, outDir: outDir,
                              view: statusBar)
            // TZ-10 item 5: the simplified status bar keeps the focus path + scan state readable.
            visFailures += auditStatusBarVisibility(statusBar, size: sizeLabel)
            findings += audit(surface: "FDABanner", size: sizeLabel, dark: dark, outDir: outDir,
                              view: makeFDABanner(width: width))
            findings += audit(surface: "CanvasOverlays", size: sizeLabel, dark: dark, outDir: outDir,
                              view: makeCanvasOverlays(width: width))

            // The Watchlist panel in its REAL constrained configuration: 60 entries hosted inside the
            // actual ChromeContainer at this window size, so the panel is canvas-height-CLAMPED and
            // must SCROLL to reach every row.
            let (panelFindings, panelVis) = auditWatchlistPanelInContainer(
                size: sizeLabel, width: width, height: height, dark: dark, outDir: outDir)
            findings += panelFindings
            visFailures += panelVis

            // The denied popover audited at BOTH sizes (window-independent by construction).
            let deniedVC = CanvasView.makeDeniedListVC(
                title: "3 folders — no permission",
                impliedText: "≈ 1.2 GB implied by the volume accounting",
                items: ["Users/alice", "Users/bob", ".Spotlight-V100"])
            findings += audit(surface: "DeniedPopover", size: sizeLabel, dark: dark, outDir: outDir,
                              view: deniedVC.view)
            deniedGeom.append((sizeLabel, deniedVC.view.frame.size))
        }

        // The DETAILS dialog (TZ-10 item 5) — all the accounting that left the status bar. Audited
        // once (its content-sized layout is window-independent, like the denied popover): every line
        // must be light-on-dark, and the required accounting fields must be present.
        let detailsView = makeDetailsView()
        findings += audit(surface: "DetailsDialog", size: "fixed", dark: dark, outDir: outDir,
                          view: detailsView)
        visFailures += auditDetailsFields(detailsView)

        // A few-rows Watchlist panel (non-overflow state) — a valid, distinct visual state.
        findings += audit(surface: "WatchlistPanel(few)", size: "fixed-280", dark: dark, outDir: outDir,
                          view: makeWatchlistPanel(entryCount: 3))

        // TZ-10 item 8: a completed scan must leave the ControlBar progress bar NOT animating.
        visFailures += auditProgressStopsAtCompletion()

        if deniedGeom.count == 2, deniedGeom[0].1 != deniedGeom[1].1 {
            visFailures.append("DeniedPopover geometry differs across window sizes "
                + "(\(deniedGeom[0].0)=\(deniedGeom[0].1) vs \(deniedGeom[1].0)=\(deniedGeom[1].1)) "
                + "— expected window-independent intrinsic size")
        } else if deniedGeom.count == 2 {
            print("CHROME DENIED-POPOVER OK: identical intrinsic geometry \(deniedGeom[0].1) at both "
                  + "700 & 1400 px.")
        }

        // Report.
        let failures = findings.filter { $0.luma < lumaFloor }
        print("CHROME AUDIT — \(findings.count) text elements across control bar, the simplified "
              + "status bar, FDA banner, canvas overlays, the Watchlist panel (few rows + 60-row "
              + "canvas-clamped scrolling overflow), the Details dialog, and the denied popover:")
        for f in findings.sorted(by: { $0.luma < $1.luma }) {
            let mark = f.luma < lumaFloor ? "FAIL" : "ok  "
            let text = f.text.isEmpty ? "<empty field>" : "\"\(f.text.prefix(38))\""
            print(String(format: "  [%@] %@ @ %@  luma=%.2f  %@", mark, f.surface, f.size, f.luma, text))
        }
        if visFailures.isEmpty {
            print("CHROME STATE OK: status bar focus/scan-state readable at both widths; Details dialog "
                  + "carries the accounting fields; Watchlist panel scrolls to its final row; progress "
                  + "bar stops at completion (item 8).")
        } else {
            for m in visFailures { FileHandle.standardError.write(Data(("CHROME STATE FAILED: " + m + "\n").utf8)) }
        }

        if failures.isEmpty && visFailures.isEmpty {
            print("CHROME AUDIT OK: every chrome text element resolves light-on-dark (min luma "
                  + String(format: "%.2f", findings.map(\.luma).min() ?? 1.0)
                  + " ≥ floor \(lumaFloor)) and every state assertion passed; PNGs in \(outDir)/chrome-*.png")
        } else {
            for f in failures {
                let lumaStr = String(format: "%.2f", f.luma)
                let msg = "CHROME AUDIT FAILED: \(f.surface) @ \(f.size) has near-dark text (luma \(lumaStr)): '\(f.text)'\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            exit(1)
        }
    }

    /// The SIMPLIFIED status bar (item 5) keeps the focus path + scan state readable, unclipped, at
    /// this width. (The accounting fields moved to the Details dialog — audited separately.)
    @MainActor
    static func auditStatusBarVisibility(_ view: NSView, size: String) -> [String] {
        // makeStatusBar sets the focus path "…/Caches", a running scan ("● scanning…"), and the
        // KEPT "Free X of Y capacity" figure (OPERATOR_NOTE A — that one accounting figure stays).
        let required = ["Caches", "scanning", "Free", "capacity"]
        let fields = collectTextFields(view)
        let bounds = view.bounds
        var failures: [String] = []
        for needle in required {
            guard let label = fields.first(where: { $0.stringValue.contains(needle) }) else {
                failures.append("StatusBar @ \(size): required text containing “\(needle)” is absent")
                continue
            }
            if label.isHidden {
                failures.append("StatusBar @ \(size): “\(label.stringValue)” is hidden")
                continue
            }
            let r = label.convert(label.bounds, to: view)
            let eps = 0.5
            if r.width < 1 || r.minX < bounds.minX - eps || r.maxX > bounds.maxX + eps {
                failures.append(String(format: "StatusBar @ %@: “%@” is clipped (x %.1f…%.1f outside 0…%.1f)",
                                       size, label.stringValue, r.minX, r.maxX, bounds.width))
            }
        }
        return failures
    }

    /// The Details dialog must actually carry the accounting the status bar shed (item 5).
    @MainActor
    static func auditDetailsFields(_ view: NSView) -> [String] {
        let required = ["Scanned", "Unaccounted", "on watchlist", "hidden filtered", "scale"]
        let texts = collectTextFields(view).map { $0.stringValue }
        var failures: [String] = []
        for needle in required where !texts.contains(where: { $0.contains(needle) }) {
            failures.append("DetailsDialog: required accounting field containing “\(needle)” is absent")
        }
        return failures
    }

    /// TZ-10 item 8: drive a subtree scan (barber-pole animating) then a COMPLETE status, and assert
    /// the progress bar stops animating — no indeterminate bounce after "done".
    @MainActor
    static func auditProgressStopsAtCompletion() -> [String] {
        let cb = ControlBar(frame: NSRect(x: 0, y: 0, width: 900, height: ControlBar.height))
        finalize(cb)
        // A running SUBTREE scan (isVolumeRoot false ⇒ fraction nil ⇒ indeterminate barber-pole).
        cb.update(ScanProgress(filesProcessed: 1000, usedInodes: 0, running: true, isVolumeRoot: false))
        var failures: [String] = []
        if !cb.progressAnimating {
            failures.append("ControlBar: a running subtree scan should animate the barber-pole, but it is not")
        }
        // Scan COMPLETE: the bar must stop.
        cb.update(ScanProgress(filesProcessed: 1000, usedInodes: 0, running: false, isVolumeRoot: false))
        if cb.progressAnimating {
            failures.append("ControlBar: the progress bar is STILL animating after the scan reported complete (item 8)")
        } else {
            print("CHROME PROGRESS OK: the progress bar stops animating at completion (item 8).")
        }
        return failures
    }

    /// The Watchlist panel in its REAL constrained configuration: 60 entries inside an actual
    /// `ChromeContainer` at a real window size, so the panel is canvas-height-CLAMPED as in the app
    /// and must SCROLL to its final row.
    @MainActor
    static func auditWatchlistPanelInContainer(size: String, width: CGFloat, height: CGFloat,
                                               dark: NSAppearance, outDir: String) -> ([Finding], [String]) {
        let controlBar = ControlBar(frame: .zero)
        let banner = FDABanner(frame: .zero)
        let consentBanner = ConsentBanner(frame: .zero)
        let canvas = CanvasView(frame: .zero)
        let statusBar = StatusBar(frame: .zero)
        let panel = WatchlistPanel()
        let entries = (0..<60).map {
            WatchlistPanel.Entry(id: "/n/\($0)", name: "folder-\($0)",
                                 relativePath: "Users/apple/folder-\($0)",
                                 bytes: Int64($0 + 1) * 1_000_000_000, hue: Double($0) * 0.11)
        }
        panel.setEntries(entries)

        let container = ChromeContainer(controlBar: controlBar, banner: banner, consentBanner: consentBanner,
                                        canvas: canvas, statusBar: statusBar, watchlistPanel: panel)
        container.appearance = NSAppearance(named: .darkAqua)
        container.showsWatchlistPanel = true
        container.setFrameSize(NSSize(width: width, height: height))
        container.layoutSubtreeIfNeeded()

        var vis: [String] = []
        let natural = panel.contentHeight()
        let canvasHeight = height - ControlBar.height - StatusBar.height
        let clampCeiling = canvasHeight - 20 // ChromeContainer 2*margin
        let ph = panel.frame.height

        if natural <= clampCeiling {
            vis.append("WatchlistPanel @ \(size): 60 rows did not overflow (natural \(Int(natural)) ≤ "
                + "ceiling \(Int(clampCeiling))) — audit window too tall to exercise scrolling")
        }
        if ph > clampCeiling + 0.5 {
            vis.append(String(format: "WatchlistPanel @ %@: panel height %.0f exceeds canvas clamp %.0f",
                              size, ph, clampCeiling))
        }
        if panel.auditRowCount != 60 {
            vis.append("WatchlistPanel @ \(size): expected 60 clickable rows, found \(panel.auditRowCount)")
        }
        let reach = panel.auditScrollReachability()
        if !reach.overflows {
            vis.append("WatchlistPanel @ \(size): clamped panel does not scroll — rows would be truncated")
        }
        if !reach.lastRowReachable {
            vis.append("WatchlistPanel @ \(size): the last of 60 rows is NOT reachable when scrolled to bottom")
        } else {
            print("CHROME WATCHLIST-PANEL OK @ \(size): 60/60 rows clickable; panel clamped to "
                  + String(format: "%.0f", ph) + " px (natural " + String(format: "%.0f", natural)
                  + "); list scrolls and the final row is reachable.")
        }

        let panelFindings = audit(surface: "WatchlistPanel(60-clamped)", size: size, dark: dark,
                                  outDir: outDir, view: panel)
        return (panelFindings, vis)
    }

    // MARK: - Surface builders (the REAL chrome classes, offscreen)

    @MainActor
    static func makeControlBar(width: CGFloat) -> NSView {
        let v = ControlBar(frame: NSRect(x: 0, y: 0, width: width, height: ControlBar.height))
        finalize(v)
        return v
    }

    @MainActor
    static func makeStatusBar(width: CGFloat) -> NSView {
        let v = StatusBar(frame: NSRect(x: 0, y: 0, width: width, height: StatusBar.height))
        // OPERATOR_NOTE A: a real volume so the KEPT "Free X of Y capacity" figure renders and is audited.
        let volume = VolumeProbe.VolumeInfo(capacityBytes: 994_000_000_000,
                                            availableBytes: 120_000_000_000,
                                            availableForImportantBytes: 180_000_000_000)
        v.update(ScanStatus(volume: volume, scannedBytes: 640_000_000_000, belowPixelCount: 7,
                            running: true))
        v.setFocusPath("/Users/andrei/Library/Caches")
        finalize(v)
        return v
    }

    @MainActor
    static func makeDetailsView() -> NSView {
        let volume = VolumeProbe.VolumeInfo(capacityBytes: 994_000_000_000,
                                            availableBytes: 120_000_000_000,
                                            availableForImportantBytes: 180_000_000_000)
        let status = ScanStatus(volume: volume, scannedBytes: 640_000_000_000, belowPixelCount: 7,
                                running: true, filesProcessed: 1_200_000, totalInodes: 2_000_000,
                                isVolumeRoot: true, scaleMode: .linear, hiddenFilteredBytes: 3_500_000_000)
        let v = DetailsView.make(status: status, watchlistCount: 2, watchlistBytes: 40_000_000_000)
        finalize(v)
        return v
    }

    @MainActor
    static func makeFDABanner(width: CGFloat) -> NSView {
        let v = FDABanner(frame: NSRect(x: 0, y: 0, width: width, height: FDABanner.height))
        finalize(v)
        return v
    }

    @MainActor
    static func makeWatchlistPanel(entryCount: Int) -> NSView {
        let v = WatchlistPanel()
        let entries = (0..<entryCount).map {
            WatchlistPanel.Entry(id: "/n/\($0)", name: "folder-\($0)",
                                 relativePath: "Users/apple/folder-\($0)",
                                 bytes: Int64(($0 + 1)) * 1_000_000_000, hue: Double($0) * 0.11)
        }
        v.setEntries(entries)
        v.frame = NSRect(x: 0, y: 0, width: WatchlistPanel.width, height: v.contentHeight())
        finalize(v)
        return v
    }

    @MainActor
    static func makeCanvasOverlays(width: CGFloat) -> NSView {
        let v = CanvasView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        v.setTileLabels([
            CanvasView.TileLabel(rect: Rect(x: 20, y: 20, width: 300, height: 120), text: "System  ·  221 GB"),
            CanvasView.TileLabel(rect: Rect(x: 340, y: 20, width: 300, height: 120), text: "Library  ·  175 GB"),
        ])
        v.setCallout(text: "/Users/andrei/Library/Caches  ·  4.2 GB", hue: 0.6,
                     atPx: Point(x: 200, y: 200))
        finalize(v)
        return v
    }

    // MARK: - Audit + render

    @MainActor
    static func finalize(_ v: NSView) {
        v.appearance = NSAppearance(named: .darkAqua)
        v.layoutSubtreeIfNeeded()
    }

    @MainActor
    static func audit(surface: String, size: String, dark: NSAppearance, outDir: String,
                      view: NSView) -> [Finding] {
        let fields = collectTextFields(view)
        var out: [Finding] = []
        for f in fields {
            out.append(Finding(surface: surface, size: size, field: "NSTextField",
                               luma: luma(of: f.textColor, under: dark), text: f.stringValue))
        }
        let slug = surface.replacingOccurrences(of: "(", with: "-").replacingOccurrences(of: ")", with: "")
        renderPNG(view, to: "\(outDir)/chrome-\(slug)-\(size).png")
        return out
    }

    @MainActor
    static func collectTextFields(_ view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let tf = view as? NSTextField { out.append(tf) }
        for sub in view.subviews { out += collectTextFields(sub) }
        return out
    }

    @MainActor
    static func luma(of color: NSColor?, under appearance: NSAppearance) -> Double {
        guard let color else { return 1.0 }
        var result = 1.0
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                result = 0.2126 * Double(c.redComponent)
                       + 0.7152 * Double(c.greenComponent)
                       + 0.0722 * Double(c.blueComponent)
            }
        }
        return result
    }

    @MainActor
    static func renderPNG(_ view: NSView, to path: String) {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("CHROME_HOST FAILED: \(msg)\n".utf8))
        exit(1)
    }
}
