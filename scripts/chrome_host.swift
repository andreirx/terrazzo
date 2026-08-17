//
//  chrome_host.swift — headless, offscreen chrome COLOR AUDIT (TZ-5 deliverable 5).
//  Module maturity: PROTOTYPE (slice TZ-5, review-0 change 5)
//
//  WHY THIS EXISTS. TZ-5's chrome audit requires proving that EVERY text element in the chrome
//  (control bar, status bar, FDA banner, volume picker, popovers, Ignore panel) is legible on the
//  dark theme — no near-black-on-dark NSTextField defaults — VERIFIED AT TWO WINDOW SIZES. The
//  builder-conduct rule (CLAUDE.md, binding 2026-08-16) forbids raising/activating windows on the
//  live desktop, so a live screenshot pass is not available to a builder. This host is the
//  conduct-safe, deterministic substitute — the same offscreen-evidence philosophy as verify.sh:
//
//    - It instantiates the REAL chrome views (the same classes AppDelegate builds) OFFSCREEN.
//    - It NEVER creates/orders/activates a window: `NSApplication` runs with activation policy
//      `.prohibited`, `run()`/`activate()`/`orderFront()` are never called, so nothing appears on
//      the human's desktop and no input is posted.
//    - For each text element it resolves the effective `textColor` UNDER THE APP'S ACTUAL
//      appearance (`.darkAqua`, which AppDelegate forces on the window) and computes its Rec.709
//      luminance. A near-black-on-dark defect (the field report's "barely-visible text") is a LOW
//      luminance; the audit FAILS (exit 1) if any element's text-colour luminance is below the
//      threshold. Intentionally-dim-but-light colours (secondary/tertiary label, low-alpha white)
//      are measured by RGB luminance IGNORING alpha, so a legitimately faint "… N more" passes
//      while a dark hue fails — the defect is a dark COLOUR, not a translucent one.
//    - It also writes a PNG of each surface (best-effort `cacheDisplay`, no window) so the operator
//      has the two-size VISUAL pass too; PNG failure does not fail the gate (the luminance check is
//      the machine evidence).
//
//  Compiled by scripts/chrome.sh together with the App chrome sources (minus main.swift) + the
//  cores + ScanFS + RenderPipeline — the same monolith arrangement as build.sh, with this file's
//  @main replacing the app entry point.
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

    /// Text-colour luminance floor. Everything in the app palette is calibratedWhite 0.55…0.98
    /// (luma 0.55…0.98) and the semantic labels resolve light under .darkAqua; a near-black
    /// default (the defect) is ≈ 0. 0.40 cleanly separates the two with margin.
    static let lumaFloor = 0.40

    @MainActor
    static func main() {
        // NEVER activate/raise a window (conduct rule). `.prohibited` keeps the process out of the
        // Dock/menu bar and unable to activate; we never call run()/activate()/orderFront().
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
        guard let dark = NSAppearance(named: .darkAqua) else { die("no .darkAqua appearance") }

        var findings: [Finding] = []
        // VISIBILITY failures are distinct from luminance: a field can be the right COLOUR yet be
        // CLIPPED off the strip (the review-1 defect — the narrow status bar cut off ignored/scale).
        // These are collected separately and fail the gate too.
        var visFailures: [String] = []

        // The denied-popover geometry captured at each window size, compared after the loop to
        // demonstrate it is window-INDEPENDENT (review-3 change 3).
        var deniedGeom: [(String, CGSize)] = []

        // Surfaces AND the full chrome assembly are audited at BOTH window sizes (narrow/wide).
        // Each size uses a full window HEIGHT too, so ChromeContainer produces the real canvas that
        // clamps the floating Ignore panel — the 60-row overflow test needs a genuine canvas, not a
        // free-standing panel sized to its own content (the review-3 defect).
        for (sizeLabel, width, height) in [("narrow-700", CGFloat(700), CGFloat(760)),
                                           ("wide-1400", CGFloat(1400), CGFloat(1000))] {
            findings += audit(surface: "ControlBar", size: sizeLabel, dark: dark, outDir: outDir,
                              view: makeControlBar(width: width))
            let statusBar = makeStatusBar(width: width)
            findings += audit(surface: "StatusBar", size: sizeLabel, dark: dark, outDir: outDir,
                              view: statusBar)
            // The required TZ-5 status fields must remain VISIBLY READABLE at this width, not
            // clipped or detached (review-1 change 4). Deterministic evidence, not just a PNG.
            visFailures += auditStatusBarVisibility(statusBar, size: sizeLabel)
            findings += audit(surface: "FDABanner", size: sizeLabel, dark: dark, outDir: outDir,
                              view: makeFDABanner(width: width))
            findings += audit(surface: "CanvasOverlays", size: sizeLabel, dark: dark, outDir: outDir,
                              view: makeCanvasOverlays(width: width))

            // The Ignore panel in its REAL constrained configuration: 60 entries hosted inside the
            // actual ChromeContainer at this window size, so the panel is canvas-height-CLAMPED and
            // must SCROLL to reach every row (review-3 changes 1 & 2). Deterministic clamp/scroll
            // assertions feed the gate's failure conditions; the PNG shows the scrolled-to-bottom
            // (final) rows so the operator sees the last entry is reachable.
            let (panelFindings, panelVis) = auditIgnorePanelInContainer(
                size: sizeLabel, width: width, height: height, dark: dark, outDir: outDir)
            findings += panelFindings
            visFailures += panelVis

            // The denied popover audited at BOTH sizes (review-3 change 3). Its geometry is computed
            // from its own content (CanvasView.makeDeniedListVC sizes the stack to fittingSize), so
            // it is window-independent by construction — asserted below by comparing the two sizes.
            let deniedVC = CanvasView.makeDeniedListVC(
                title: "3 folders — no permission",
                impliedText: "≈ 1.2 GB implied by the volume accounting",
                items: ["Users/alice", "Users/bob", ".Spotlight-V100"])
            findings += audit(surface: "DeniedPopover", size: sizeLabel, dark: dark, outDir: outDir,
                              view: deniedVC.view)
            deniedGeom.append((sizeLabel, deniedVC.view.frame.size))
        }

        // A few-rows Ignore panel (non-overflow state) — a valid, distinct visual state; not
        // window-dependent, so audited once for luminance + a small-state PNG.
        findings += audit(surface: "IgnorePanel(few)", size: "fixed-240", dark: dark, outDir: outDir,
                          view: makeIgnorePanel(entryCount: 3))

        // The denied popover's intrinsic geometry must be identical across both window sizes — the
        // review-3-accepted demonstration that its fixed geometry renders unchanged at both configs.
        if deniedGeom.count == 2, deniedGeom[0].1 != deniedGeom[1].1 {
            visFailures.append("DeniedPopover geometry differs across window sizes "
                + "(\(deniedGeom[0].0)=\(deniedGeom[0].1) vs \(deniedGeom[1].0)=\(deniedGeom[1].1)) "
                + "— expected window-independent intrinsic size")
        } else if deniedGeom.count == 2 {
            print("CHROME DENIED-POPOVER OK: identical intrinsic geometry \(deniedGeom[0].1) at both "
                  + "700 & 1400 px — its fixed content-sized layout is window-independent.")
        }
        // VolumePicker is an NSPopUpButton (a standard control, no NSTextField) inside ControlBar;
        // its title renders through its cell in the window's .darkAqua appearance — correct by
        // construction (no hardcoded colour to audit). Noted here so the enumeration is complete.

        // Report.
        let failures = findings.filter { $0.luma < lumaFloor }
        print("CHROME AUDIT — \(findings.count) text elements across control bar, status bar, FDA "
              + "banner, canvas overlays, the Ignore panel (few rows + 60-row canvas-clamped scrolling "
              + "overflow, hosted in the real ChromeContainer), and the denied popover, at two window sizes:")
        for f in findings.sorted(by: { $0.luma < $1.luma }) {
            let mark = f.luma < lumaFloor ? "FAIL" : "ok  "
            let text = f.text.isEmpty ? "<empty field>" : "\"\(f.text.prefix(38))\""
            print(String(format: "  [%@] %@ @ %@  luma=%.2f  %@", mark, f.surface, f.size, f.luma, text))
        }
        // Visibility report (the required TZ-5 status fields at both widths).
        if visFailures.isEmpty {
            print("CHROME VISIBILITY OK: the required status fields (ignored · hidden-filtered · "
                  + "active scale · scan state) are unclipped and readable at both 700 and 1400 px.")
        } else {
            for m in visFailures { FileHandle.standardError.write(Data(("CHROME VISIBILITY FAILED: " + m + "\n").utf8)) }
        }

        if failures.isEmpty && visFailures.isEmpty {
            print("CHROME AUDIT OK: every chrome text element resolves light-on-dark (min luma "
                  + String(format: "%.2f", findings.map(\.luma).min() ?? 1.0)
                  + " ≥ floor \(lumaFloor)) and the required status fields are unclipped at both "
                  + "sizes; PNGs written to \(outDir)/chrome-*.png")
        } else {
            for f in failures {
                let lumaStr = String(format: "%.2f", f.luma)
                let msg = "CHROME AUDIT FAILED: \(f.surface) @ \(f.size) has near-dark text (luma \(lumaStr)): '\(f.text)'\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            exit(1)
        }
    }

    /// Assert the required TZ-5 status fields are actually VISIBLE at `size` — present, not
    /// detached/hidden by the responsive strip, and not clipped past the status bar's edges
    /// (review-1 change 4). This is the machine evidence the reviewer asked for: the earlier
    /// luminance-only audit passed while the fields were clipped off the narrow strip.
    @MainActor
    static func auditStatusBarVisibility(_ view: NSView, size: String) -> [String] {
        // Each required field is identified by a stable substring of its rendered text (the fixture
        // in makeStatusBar sets: 2 ignored, hidden filtered, Log scale, ● scanning…).
        let required = ["ignored", "hidden filtered", "Log scale", "scanning"]
        let fields = collectTextFields(view)
        let bounds = view.bounds
        var failures: [String] = []
        for needle in required {
            guard let label = fields.first(where: { $0.stringValue.contains(needle) }) else {
                failures.append("StatusBar @ \(size): required field containing “\(needle)” is absent")
                continue
            }
            if label.isHidden {
                failures.append("StatusBar @ \(size): required field “\(label.stringValue)” is detached/hidden (no room on the strip)")
                continue
            }
            let r = label.convert(label.bounds, to: view) // into the status bar's own coordinate space
            let eps = 0.5
            if r.width < 1 || r.minX < bounds.minX - eps || r.maxX > bounds.maxX + eps {
                failures.append(String(format: "StatusBar @ %@: required field “%@” is clipped (x %.1f…%.1f outside 0…%.1f)",
                                       size, label.stringValue, r.minX, r.maxX, bounds.width))
            }
        }
        return failures
    }

    /// Audit the Ignore panel in its REAL constrained configuration (review-3 changes 1 & 2): 60
    /// entries hosted inside an actual `ChromeContainer` at a real window size, so the panel is
    /// canvas-height-CLAMPED exactly as in the running app (`ChromeContainer.relayout` floats it at
    /// the top-right and clamps its height to `canvasHeight - 2*margin`). Returns the panel's text
    /// findings plus any VISIBILITY failures: the earlier unbounded, free-standing 2708-px panel
    /// could not establish that the clamped list actually scrolls to its final row.
    @MainActor
    static func auditIgnorePanelInContainer(size: String, width: CGFloat, height: CGFloat,
                                            dark: NSAppearance, outDir: String) -> ([Finding], [String]) {
        let controlBar = ControlBar(frame: .zero)
        let banner = FDABanner(frame: .zero)
        let canvas = CanvasView(frame: .zero)
        let statusBar = StatusBar(frame: .zero)
        let panel = IgnorePanel()
        let entries = (0..<60).map {
            IgnorePanel.Entry(id: "/n/\($0)", name: "folder-\($0)",
                              bytes: Int64($0 + 1) * 1_000_000_000, hue: Double($0) * 0.11)
        }
        panel.setEntries(entries)

        let container = ChromeContainer(controlBar: controlBar, banner: banner, canvas: canvas,
                                        statusBar: statusBar, ignorePanel: panel)
        container.appearance = NSAppearance(named: .darkAqua)
        container.showsIgnorePanel = true
        container.setFrameSize(NSSize(width: width, height: height)) // triggers relayout → clamp
        container.layoutSubtreeIfNeeded()

        var vis: [String] = []
        let natural = panel.contentHeight()                                  // wants ALL 60 rows
        let canvasHeight = height - ControlBar.height - StatusBar.height
        let clampCeiling = canvasHeight - 20                                 // ChromeContainer 2*margin
        let ph = panel.frame.height

        // Precondition: 60 rows must actually overflow this window, else the scroll test is vacuous.
        if natural <= clampCeiling {
            vis.append("IgnorePanel @ \(size): 60 rows did not overflow (natural \(Int(natural)) ≤ "
                + "ceiling \(Int(clampCeiling))) — audit window too tall to exercise scrolling")
        }
        // The panel is genuinely height-CLAMPED by ChromeContainer (not the unbounded content frame).
        if ph > clampCeiling + 0.5 {
            vis.append(String(format: "IgnorePanel @ %@: panel height %.0f exceeds canvas clamp %.0f "
                + "— not clamped to the canvas", size, ph, clampCeiling))
        }
        // Every ignored tile is a real clickable row — no cap, no non-restorable "… N more" summary.
        if panel.auditRowCount != 60 {
            vis.append("IgnorePanel @ \(size): expected 60 clickable rows, found \(panel.auditRowCount)")
        }
        // The clamped list SCROLLS (document taller than clip) and reaches its LAST row.
        let reach = panel.auditScrollReachability()
        if !reach.overflows {
            vis.append("IgnorePanel @ \(size): clamped panel does not scroll (document not taller "
                + "than clip) — rows would be truncated instead of scrollable")
        }
        if !reach.lastRowReachable {
            vis.append("IgnorePanel @ \(size): the last of 60 rows is NOT reachable when scrolled to "
                + "the bottom of the clamped panel")
        } else {
            print("CHROME IGNORE-PANEL OK @ \(size): 60/60 rows clickable; panel clamped to "
                  + String(format: "%.0f", ph) + " px (natural " + String(format: "%.0f", natural)
                  + "); list scrolls and the final row is reachable/readable.")
        }

        // PNG of the clamped panel scrolled to its bottom (the operator sees the final rows present).
        let panelFindings = audit(surface: "IgnorePanel(60-clamped)", size: size, dark: dark,
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
        // Populate EVERY field (incl. the TZ-5 additions: ignored, hidden-filtered, scale) so the
        // audit covers each label with real content, not just the empty pool.
        let volume = VolumeProbe.VolumeInfo(capacityBytes: 994_000_000_000,
                                            availableBytes: 120_000_000_000,
                                            availableForImportantBytes: 180_000_000_000)
        v.update(ScanStatus(volume: volume, scannedBytes: 640_000_000_000, belowPixelCount: 7,
                            running: true, filesProcessed: 1_200_000, totalInodes: 2_000_000,
                            isVolumeRoot: true, scaleMode: .log, hiddenFilteredBytes: 3_500_000_000))
        v.setIgnoredAccounting(count: 2, bytes: 40_000_000_000)
        v.setFocusPath("/Users/andrei/Library/Caches")
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
    static func makeIgnorePanel(entryCount: Int) -> NSView {
        let v = IgnorePanel()
        let entries = (0..<entryCount).map {
            IgnorePanel.Entry(id: "/n/\($0)", name: "folder-\($0)",
                              bytes: Int64(($0 + 1)) * 1_000_000_000, hue: Double($0) * 0.11)
        }
        v.setEntries(entries)
        v.frame = NSRect(x: 0, y: 0, width: IgnorePanel.width, height: v.contentHeight())
        finalize(v)
        return v
    }

    @MainActor
    static func makeCanvasOverlays(width: CGFloat) -> NSView {
        let v = CanvasView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        // The on-tile floating labels + the hover callout chip — both carry text over the map.
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

    /// Force the app's real appearance, lay out, enumerate every NSTextField, and render a PNG.
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
        // Best-effort offscreen PNG (no window). Never fails the gate.
        let slug = surface.replacingOccurrences(of: "(", with: "-").replacingOccurrences(of: ")", with: "")
        renderPNG(view, to: "\(outDir)/chrome-\(slug)-\(size).png")
        return out
    }

    /// Recursively collect NSTextField descendants (the enumeration the audit rule requires).
    @MainActor
    static func collectTextFields(_ view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let tf = view as? NSTextField { out.append(tf) }
        for sub in view.subviews { out += collectTextFields(sub) }
        return out
    }

    /// Rec.709 luminance of a colour's RGB (IGNORING alpha), resolved under `appearance` — so a
    /// dynamic semantic colour (labelColor) resolves to its dark-appearance variant, and a
    /// low-alpha light colour (tertiaryLabelColor) still reads as light (its HUE is not the defect).
    @MainActor
    static func luma(of color: NSColor?, under appearance: NSAppearance) -> Double {
        guard let color else { return 1.0 } // never nil for labelWithString, but be safe
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

    /// Offscreen render via cacheDisplay (no window). Best-effort — some controls render blank
    /// without a window; the machine evidence is the luminance enumeration, not this PNG.
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
