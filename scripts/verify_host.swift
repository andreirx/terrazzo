//
//  verify_host.swift — offscreen fixture-frame capture through the REAL renderer.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  The deterministic gate (glyph-saver verify seam, adapted). Compiled by
//  scripts/verify.sh together with Sources/App/QuadRenderer.swift and the two
//  core source trees into ONE swiftc module (so no ScanCore/TreemapCore imports
//  — same-module resolution, like the App layer). Because this is a normal app
//  (not a screensaver), there is NO bundle-load / principalClass dance: we build
//  a QuadRenderer directly and render the fixture scene offscreen.
//
//  It renders the SAME fixture SizeTree at TWO different viewport sizes through
//  the real QuadRenderer into offscreen textures, writes both as PNGs, and
//  asserts each frame is non-blank (has pixels above the black background).
//  verify.sh then asserts both files are non-empty AND byte-differ (different
//  viewport ⇒ different squarified layout ⇒ different pixels).
//
//  TZ-3 ADDS the NAVIGATION gate (packet deliverable 8): at a FIXED viewport it
//  renders the scene at focus=root and at focus=<root's first child> (the
//  committed, post-animation focus states — the deterministic gate renders the
//  COMMITTED state, not the transient camera frames, keeping it byte-stable). The
//  two frames go through the same real QuadRenderer; verify.sh asserts they differ
//  (a different focus ⇒ a different subtree fills the canvas ⇒ different pixels),
//  proving focus navigation actually changes what is drawn.
//
//  Usage: verify_host <shaders.metal> <fixture.json> <out1.png> <out2.png>
//                     <focus-root.png> <focus-child.png>
//

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The two capture viewports (device pixels). Different aspect + size so the
// squarified layout — and therefore the pixels — must differ.
private let viewportA = (w: 900, h: 650)
private let viewportB = (w: 1300, h: 520)

@main
struct VerifyHost {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 13 else {
            FileHandle.standardError.write(Data("usage: \(args.first ?? "verify_host") <shaders.metal> <fixture.json> <out1.png> <out2.png> <focus-root.png> <focus-child.png> <scale-linear.png> <scale-sqrt.png> <scale-sqrt-watchlist.png> <dissolve-0.png> <dissolve-half.png> <dissolve-1.png>\n".utf8))
            exit(2)
        }
        let shaderPath = args[1], fixturePath = args[2], out1 = args[3], out2 = args[4]
        let focusRootOut = args[5], focusChildOut = args[6]
        let scaleLinearOut = args[7], scaleSqrtOut = args[8], scaleSqrtWatchlistOut = args[9]
        let dissolve0Out = args[10], dissolveHalfOut = args[11], dissolve1Out = args[12]

        guard let device = MTLCreateSystemDefaultDevice() else { die("no Metal device") }

        guard let shaderSource = try? String(contentsOfFile: shaderPath, encoding: .utf8) else {
            die("cannot read shader source at \(shaderPath)")
        }
        // No FileManager in this slice (packet constraint): read the fixture
        // bytes via Data(contentsOf:) — the same value-type path FixtureLoader
        // and the App layer use — with explicit error handling.
        let fixtureData: Data
        do {
            fixtureData = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        } catch {
            die("cannot read fixture at \(fixturePath): \(error)")
        }
        let tree: SizeTree
        do {
            tree = try JSONDecoder().decode(SizeTree.self, from: fixtureData)
        } catch {
            die("fixture decode failed: \(error)")
        }

        guard let renderer = QuadRenderer(device: device, pixelFormat: .bgra8Unorm,
                                          shaderSource: shaderSource) else {
            die("QuadRenderer init failed (shader compile / pipeline)")
        }

        renderFrame(device: device, renderer: renderer, tree: tree,
                    px: viewportA.w, py: viewportA.h, out: out1)
        renderFrame(device: device, renderer: renderer, tree: tree,
                    px: viewportB.w, py: viewportB.h, out: out2)

        // Navigation gate (TZ-3): committed focus=root vs focus=<first child> at a
        // fixed viewport. A valid focus child must exist in the fixture.
        guard let focusChild = tree.children.first else {
            die("fixture root has no children — cannot render a focus-child frame")
        }
        renderFrame(device: device, renderer: renderer, tree: tree, focusId: nil,
                    px: viewportA.w, py: viewportA.h, out: focusRootOut)
        renderFrame(device: device, renderer: renderer, tree: tree, focusId: focusChild.id,
                    px: viewportA.w, py: viewportA.h, out: focusChildOut)

        // TZ-5 scale + watchlist frames (packet acceptance + review-0 change 4b): the SAME fixture
        // scene under (a) linear, (b) sqrt, and (c) sqrt with the LARGEST top-level tile WATCHLISTED —
        // all three must differ. These now go through the REAL CHANGED PATH: a `ScanReducer`
        // rebuilt from the fixture tree, then `makeRenderTree(excluding:weight:)` — the same
        // area-bounded projection + prune the pipeline runs — instead of hand-filtering a
        // `SizeTree` and laying it out directly (the reviewer's note: verify_host "manually
        // removes a child" and its cull metric "bypasses the pipeline's projection-prune"). The
        // reported cull count is now `prunedBelowArea (projection) + final pixel cull` — the exact
        // `RenderScene.belowPixelCount` accounting. The rigorous deterministic quantification is
        // (ScenePipelineTests.testPipelineLinearVsSqrtCullCountsAndWatchlistAccounting).
        let reducer = buildReducer(from: tree)
        let largest = tree.children.max { $0.allocatedBytes < $1.allocatedBytes }
        let cullLinear = renderProjectedFrame(device: device, renderer: renderer, reducer: reducer,
                                              focusId: tree.id, excluding: [], scale: .linear,
                                              px: viewportA.w, py: viewportA.h, out: scaleLinearOut)
        let cullSqrt = renderProjectedFrame(device: device, renderer: renderer, reducer: reducer,
                                           focusId: tree.id, excluding: [], scale: .sqrt,
                                           px: viewportA.w, py: viewportA.h, out: scaleSqrtOut)
        _ = renderProjectedFrame(device: device, renderer: renderer, reducer: reducer,
                                 focusId: tree.id, excluding: Set([largest?.id].compactMap { $0 }),
                                 scale: .sqrt, px: viewportA.w, py: viewportA.h, out: scaleSqrtWatchlistOut)

        print("VERIFY_HOST CULL (fixture @ \(viewportA.w)x\(viewportA.h), via ScanReducer.makeRenderTree): "
              + "linear=\(cullLinear) sqrt=\(cullSqrt) below-pixel tiles (projection-prune + final cull)"
              + " (sqrt ≤ linear — sqrt exposes starved siblings; largest watchlisted = \(largest?.name ?? "<none>"))")
        // TZ-8 GLASS-PANE DISSOLVE gate (packet acceptance): the SAME fixture at focus=root,
        // rendered at dissolveT = 0 (rest/paned), 0.5, and 1 (dived/own) through the REAL
        // shader path (renderSynchronously(dissolveT:)). The scene mean channel value is a
        // LINEAR function of dissolveT (per-tile mix is linear; averaging is linear), so the
        // three means MUST be monotone AND the 0.5 frame their midpoint — a strong, exact check
        // of the shader blend, not merely "the pixels differ". `focusChild` gives a deep tile
        // so the dissolve has a visible descendant (a hue root alone is a no-op — own == pane).
        let mean0 = renderDissolveFrame(device: device, renderer: renderer, tree: tree,
                                        focusId: focusChild.id, dissolveT: 0,
                                        px: viewportA.w, py: viewportA.h, out: dissolve0Out)
        let meanHalf = renderDissolveFrame(device: device, renderer: renderer, tree: tree,
                                           focusId: focusChild.id, dissolveT: 0.5,
                                           px: viewportA.w, py: viewportA.h, out: dissolveHalfOut)
        let mean1 = renderDissolveFrame(device: device, renderer: renderer, tree: tree,
                                        focusId: focusChild.id, dissolveT: 1,
                                        px: viewportA.w, py: viewportA.h, out: dissolve1Out)
        let midpoint = (mean0 + mean1) / 2
        let monotone = (mean0 <= meanHalf && meanHalf <= mean1) || (mean0 >= meanHalf && meanHalf >= mean1)
        // Linearity tolerance: means are 0..765 channel-sums; allow 2.0 for rounding/rasterisation.
        let linear = abs(meanHalf - midpoint) <= 2.0
        print("VERIFY_HOST TZ-8 dissolve means (focus \(focusChild.id)): "
              + "t=0 \(String(format: "%.2f", mean0))  t=0.5 \(String(format: "%.2f", meanHalf))  "
              + "t=1 \(String(format: "%.2f", mean1))  (midpoint \(String(format: "%.2f", midpoint)); "
              + "monotone=\(monotone) linear=\(linear))")
        if !monotone { die("TZ-8 dissolve is not monotone across t (0 → 0.5 → 1)") }
        if !linear { die("TZ-8 dissolve 0.5 frame is not the midpoint of 0 and 1 (shader mix not linear)") }
        if abs(mean1 - mean0) < 1.0 { die("TZ-8 dissolve endpoints barely differ — the fixture's focus child has no paned descendant to dissolve") }

        // TZ-10 item 7 (COLOR CASCADE v3): the monotone darkening cascade into depth. Through the
        // REAL colour path (`QuadBuilder`, linked here via GPUQuad.swift), build a hue-root tile at
        // each dim level and confirm its rest-colour mean brightness (Rec.709 luminance) STRICTLY
        // DECREASES with depth — the "darker and dimmer" cascade the ruling asks for, replacing the
        // flat confetti look. Deterministic and constant-free (reads whatever QuadBuilder produces).
        checkCascadeBrightness()

        print("VERIFY_HOST OK: wrote \(out1) (\(viewportA.w)x\(viewportA.h)) and \(out2) (\(viewportB.w)x\(viewportB.h)); "
              + "focus frames \(focusRootOut) (root) and \(focusChildOut) (child \(focusChild.id)); "
              + "scale frames \(scaleLinearOut) (linear), \(scaleSqrtOut) (sqrt), \(scaleSqrtWatchlistOut) (sqrt+watchlist); "
              + "dissolve frames \(dissolve0Out) (t=0), \(dissolveHalfOut) (t=0.5), \(dissolve1Out) (t=1)")
    }

    /// Render the focus scene at a fixed TZ-8 `dissolveT` through the real shader and return the
    /// MEAN lit-channel sum (Σ over lit pixels of R+G+B, divided by lit count) — the scalar the
    /// dissolve monotonicity/linearity gate compares. Writes the PNG (operator visual evidence).
    static func renderDissolveFrame(device: MTLDevice, renderer: QuadRenderer, tree: SizeTree,
                                    focusId: String, dissolveT: Float, px: Int, py: Int, out: String) -> Double {
        let viewport = Rect(x: 0, y: 0, width: Double(px), height: Double(py))
        let tiles = TreemapScene.layout(tree: tree, focusId: focusId, viewport: viewport)
        guard !tiles.isEmpty else { die("dissolve scene produced no tiles (focus \(focusId))") }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: px, height: py, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { die("makeTexture failed") }
        renderer.renderSynchronously(tiles: tiles, into: target, dissolveT: dissolveT)

        let bytesPerRow = px * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * py)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, px, py), mipmapLevel: 0)
        }
        var sum = 0.0, lit = 0, i = 0
        while i < pixels.count {
            let s = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            if s > 24 { sum += Double(s); lit += 1 }
            i += 4
        }
        if lit == 0 { die("dissolve frame \(out) is blank") }
        writePNG(pixels: &pixels, width: px, height: py, bytesPerRow: bytesPerRow, path: out)
        let mean = sum / Double(lit)
        print("  dissolve frame \(out): dissolveT=\(dissolveT), \(tiles.count) tiles, \(lit) lit px, mean channel-sum \(String(format: "%.2f", mean))")
        return mean
    }

    /// Build the scene at the given pixel viewport (optionally focused on `focusId`, under the
    /// given area `scale`), render through the real QuadRenderer into an offscreen texture, assert
    /// non-blank, write PNG. Returns the below-pixel-culled tile count (area < 4 px², non-focus) —
    /// the "same scene under sqrt vs linear" evidence the scale frames report (sqrt ratified
    /// 2026-08-17, superseding log — PLAN §TZ-5).
    @discardableResult
    static func renderFrame(device: MTLDevice, renderer: QuadRenderer, tree: SizeTree,
                            focusId: String? = nil, px: Int, py: Int, out: String,
                            scale: AreaScale = .linear) -> Int {
        let viewport = Rect(x: 0, y: 0, width: Double(px), height: Double(py))
        let tiles = TreemapScene.layout(tree: tree, focusId: focusId, viewport: viewport, scale: scale)
        guard !tiles.isEmpty else { die("scene produced no tiles at \(px)x\(py) (focus \(focusId ?? "root"))") }
        let belowPixel = tiles.filter { $0.dimLevel > 0 && $0.rect.area < 4.0 }.count

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: px, height: py, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared // unified memory on Apple Silicon → getBytes works
        guard let target = device.makeTexture(descriptor: desc) else { die("makeTexture failed") }

        renderer.renderSynchronously(tiles: tiles, into: target)

        // Read back BGRA8 pixels.
        let bytesPerRow = px * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * py)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, px, py), mipmapLevel: 0)
        }

        // Non-blank check: at least one pixel meaningfully above black background.
        var lit = 0
        var i = 0
        while i < pixels.count {
            if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 24 { lit += 1 }
            i += 4
        }
        if lit == 0 { die("frame \(out) is blank — the treemap did not render") }

        writePNG(pixels: &pixels, width: px, height: py, bytesPerRow: bytesPerRow, path: out)
        print("  frame \(out): \(tiles.count) tiles, \(lit) lit pixels, scale=\(scale.rawValue), below-pixel=\(belowPixel)")
        return belowPixel
    }

    /// Rebuild a `ScanReducer` from a decoded fixture `SizeTree` by replaying the events the walker
    /// would have emitted (review-0 change 4b). A node's OWN size is its recursive `allocatedBytes`
    /// minus its children's recursive totals (the reducer accumulates own sizes up the tree, so
    /// this inversion reproduces the exact totals). Denied nodes are discovered as dirs then
    /// `accessDenied` (how the reducer derives `.denied`); bundle leaves keep their kind. This lets
    /// the scale/watchlist frames go through the REAL `makeRenderTree` projection rather than a
    /// hand-filtered tree.
    static func buildReducer(from root: SizeTree) -> ScanReducer {
        var reducer = ScanReducer(rootId: root.id, rootName: root.name)
        var events: [ScanEvent] = []
        func emit(_ node: SizeTree) {
            let childAlloc = node.children.reduce(Int64(0)) { $0 + $1.allocatedBytes }
            let childLog = node.children.reduce(Int64(0)) { $0 + $1.logicalBytes }
            let ownAlloc = max(0, node.allocatedBytes - childAlloc)
            let ownLog = max(0, node.logicalBytes - childLog)
            events.append(.sizeUpdated(nodeId: node.id, allocated: ownAlloc, logical: ownLog))
            if node.kind == .denied {
                events.append(.accessDenied(nodeId: node.id))
                return // a denied node exposes no children
            }
            if !node.children.isEmpty {
                let stubs = node.children.map { child -> ChildStub in
                    // A denied child is discovered as a dir first (the walker's order); every other
                    // kind carries through. `.pending`/`.synthetic` never appear in a real scan tree.
                    let stubKind: NodeKind = (child.kind == .denied) ? .dir : child.kind
                    return ChildStub(id: child.id, name: child.name, kind: stubKind, isHidden: child.isHidden)
                }
                events.append(.childrenDiscovered(parentId: node.id, children: stubs))
                for c in node.children { emit(c) }
            }
        }
        emit(root)
        reducer.apply(events)
        return reducer
    }

    /// Render a frame through the REAL `makeRenderTree` area-bounded projection (review-0 change
    /// 4b), returning the pipeline's `belowPixelCount` accounting: `prunedBelowArea` (subtrees the
    /// projection never materialized) + the final sub-pixel pixel cull on the laid-out tiles.
    /// `minRenderArea` (4 px²) mirrors `ScenePipeline.minRenderAreaPx`; RenderPipeline's actor is
    /// not linked here (only its `GPUQuad` value type is), so the constant is stated locally.
    @discardableResult
    static func renderProjectedFrame(device: MTLDevice, renderer: QuadRenderer, reducer: ScanReducer,
                                     focusId: String, excluding: Set<String>, scale: AreaScale,
                                     px: Int, py: Int, out: String) -> Int {
        let viewport = Rect(x: 0, y: 0, width: Double(px), height: Double(py))
        let (projected, prunedBelowArea, _) = reducer.makeRenderTree(
            focusId: focusId, depthWindow: 5, minRenderArea: 4.0, viewportArea: viewport.area,
            excluding: excluding, weight: scale.weight) // AreaScale (TreemapCore) → bare weight seam
        let tiles = TreemapScene.layout(tree: projected, focusId: focusId, viewport: viewport, scale: scale)
        guard !tiles.isEmpty else { die("projected scene produced no tiles at \(px)x\(py) (scale \(scale.rawValue))") }
        // Final pixel cull, exactly as the pipeline: drop non-focus tiles below the threshold.
        let kept = tiles.filter { $0.dimLevel == 0 || $0.rect.area >= 4.0 }
        let belowPixel = prunedBelowArea + (tiles.count - kept.count)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: px, height: py, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { die("makeTexture failed") }
        renderer.renderSynchronously(tiles: kept, into: target)

        let bytesPerRow = px * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * py)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, px, py), mipmapLevel: 0)
        }
        var lit = 0, i = 0
        while i < pixels.count {
            if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 24 { lit += 1 }
            i += 4
        }
        if lit == 0 { die("projected frame \(out) is blank — the treemap did not render") }
        writePNG(pixels: &pixels, width: px, height: py, bytesPerRow: bytesPerRow, path: out)
        print("  projected frame \(out): \(kept.count) tiles, \(lit) lit pixels, scale=\(scale.rawValue), "
              + "below-pixel=\(belowPixel) (pruned \(prunedBelowArea) + culled \(tiles.count - kept.count)), "
              + "excluding=\(excluding.count)")
        return belowPixel
    }

    /// TZ-10 item 7 acceptance: state the mean brightness per nesting level and assert it DECREASES
    /// (COLOR CASCADE v3, the monotone darkening cascade). Uses the production `QuadBuilder` rest
    /// colour of a hue-root tile at each dim level — no hand-derived constants.
    static func checkCascadeBrightness() {
        let unit = Rect(x: 0, y: 0, width: 100, height: 100)
        func lum(_ c: (Float, Float, Float)) -> Double {
            0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2)
        }
        var prev = Double.greatestFiniteMagnitude
        var means: [String] = []
        for depth in 1...5 {
            let tile = TileRect(rect: unit, dimLevel: depth, nodeId: "L\(depth)", kind: .dir,
                                scanState: .complete, hue: TileColor.hue(for: "Library"),
                                name: "Library", allocatedBytes: 1, logicalBytes: 1)
            let q = QuadBuilder.quad(for: tile)
            let l = lum((q.r, q.g, q.b))
            means.append("L\(depth)=\(String(format: "%.3f", l))")
            // STRICT (review-1): each level must be MEASURABLY dimmer than the one above — a flat
            // cascade (dimFalloff regressed to 1.0) leaves l == prev and MUST fail this gate, matching
            // the acceptance requirement "mean brightness per level must decrease".
            if l >= prev - 1e-6 {
                die("TZ-10 cascade brightness NOT strictly decreasing at level \(depth) "
                    + "(\(String(format: "%.3f", l)) not below \(String(format: "%.3f", prev)))")
            }
            prev = l
        }
        print("VERIFY_HOST TZ-10 cascade v3 mean brightness per level (must decrease): "
              + means.joined(separator: "  ") + " — monotone darkening confirmed")
    }

    static func writePNG(pixels: inout [UInt8], width: Int, height: Int,
                         bytesPerRow: Int, path: String) {
        let cs = CGColorSpaceCreateDeviceRGB()
        // BGRA8 in memory → premultipliedFirst + little-endian byte order.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs, bitmapInfo: info.rawValue),
              let img = ctx.makeImage() else {
            die("CGContext/makeImage failed for \(path)")
        }
        let url = URL(fileURLWithPath: path)
        let type = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            die("CGImageDestination create failed for \(path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        if !CGImageDestinationFinalize(dest) { die("PNG finalize failed for \(path)") }
    }

    static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("VERIFY_HOST FAILED: \(msg)\n".utf8))
        exit(1)
    }
}
