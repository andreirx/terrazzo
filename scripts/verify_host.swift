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
        guard args.count == 10 else {
            FileHandle.standardError.write(Data("usage: \(args.first ?? "verify_host") <shaders.metal> <fixture.json> <out1.png> <out2.png> <focus-root.png> <focus-child.png> <scale-linear.png> <scale-log.png> <scale-log-ignore.png>\n".utf8))
            exit(2)
        }
        let shaderPath = args[1], fixturePath = args[2], out1 = args[3], out2 = args[4]
        let focusRootOut = args[5], focusChildOut = args[6]
        let scaleLinearOut = args[7], scaleLogOut = args[8], scaleLogIgnoreOut = args[9]

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

        // TZ-5 scale + ignore frames (packet acceptance + review-0 change 4b): the SAME fixture
        // scene under (a) linear, (b) log, and (c) log with the LARGEST top-level tile IGNORED —
        // all three must differ. These now go through the REAL CHANGED PATH: a `ScanReducer`
        // rebuilt from the fixture tree, then `makeRenderTree(excluding:weight:)` — the same
        // area-bounded projection + prune the pipeline runs — instead of hand-filtering a
        // `SizeTree` and laying it out directly (the reviewer's note: verify_host "manually
        // removes a child" and its cull metric "bypasses the pipeline's projection-prune"). The
        // reported cull count is now `prunedBelowArea (projection) + final pixel cull` — the exact
        // `RenderScene.belowPixelCount` accounting. The rigorous deterministic quantification is
        // TZ-14 (ScenePipelineTests.testPipelineLinearVsLogCullCountsAndIgnoreAccounting).
        let reducer = buildReducer(from: tree)
        let largest = tree.children.max { $0.allocatedBytes < $1.allocatedBytes }
        let cullLinear = renderProjectedFrame(device: device, renderer: renderer, reducer: reducer,
                                              focusId: tree.id, excluding: [], scale: .linear,
                                              px: viewportA.w, py: viewportA.h, out: scaleLinearOut)
        let cullLog = renderProjectedFrame(device: device, renderer: renderer, reducer: reducer,
                                           focusId: tree.id, excluding: [], scale: .log,
                                           px: viewportA.w, py: viewportA.h, out: scaleLogOut)
        _ = renderProjectedFrame(device: device, renderer: renderer, reducer: reducer,
                                 focusId: tree.id, excluding: Set([largest?.id].compactMap { $0 }),
                                 scale: .log, px: viewportA.w, py: viewportA.h, out: scaleLogIgnoreOut)

        print("VERIFY_HOST CULL (fixture @ \(viewportA.w)x\(viewportA.h), via ScanReducer.makeRenderTree): "
              + "linear=\(cullLinear) log=\(cullLog) below-pixel tiles (projection-prune + final cull)"
              + " (log ≤ linear — log exposes starved siblings; largest ignored = \(largest?.name ?? "<none>"))")
        print("VERIFY_HOST OK: wrote \(out1) (\(viewportA.w)x\(viewportA.h)) and \(out2) (\(viewportB.w)x\(viewportB.h)); "
              + "focus frames \(focusRootOut) (root) and \(focusChildOut) (child \(focusChild.id)); "
              + "scale frames \(scaleLinearOut) (linear), \(scaleLogOut) (log), \(scaleLogIgnoreOut) (log+ignore)")
    }

    /// Build the scene at the given pixel viewport (optionally focused on `focusId`, under the
    /// given area `scale`), render through the real QuadRenderer into an offscreen texture, assert
    /// non-blank, write PNG. Returns the below-pixel-culled tile count (area < 4 px², non-focus) —
    /// the "same scene under log vs linear" evidence the scale frames report.
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
    /// the scale/ignore frames go through the REAL `makeRenderTree` projection rather than a
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
