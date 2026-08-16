//
//  scan_host.swift — end-to-end gate: real walker → reducer → golden → PNGs.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  The TZ-2 deterministic scan gate (packet deliverable 6). Compiled by
//  scripts/verify.sh together with Sources/ScanFS + Sources/ScanCore +
//  Sources/TreemapCore + Sources/App/QuadRenderer into ONE swiftc module (same
//  monolith arrangement as verify_host — no imports, same-module resolution).
//
//  It builds a small REAL directory tree under a temp dir (hidden file, an
//  un-followed symlink, a chmod-000 denied dir, a readable `.app` bundle, and a
//  `.app` bundle with a locked dir inside → denied), runs the REAL
//  FileSystemWalker to COMPLETION into the REAL ScanReducer, asserts the FULL
//  golden tree — every node's kind, allocated + logical bytes, and scanState,
//  recomputed INDEPENDENTLY via the same `FileSystemWalker.measure` syscalls and
//  `ScanPolicy` rules (review TZ-2 points 1 & 2) — then renders the resulting
//  SizeTree through the REAL QuadRenderer at TWO viewport sizes into PNGs.
//  verify.sh then asserts both PNGs are non-empty and byte-differ.
//
//  This is a script host (like verify_host): using FileManager here is fine — the
//  purity rule ("no syscalls outside Sources/ScanFS") scopes the Sources/ product
//  modules, not the test/gate harnesses in scripts/.
//
//  Usage: scan_host <shaders.metal> <out1.png> <out2.png>
//

import Foundation
import Darwin
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let viewportA = (w: 900, h: 650)
private let viewportB = (w: 1300, h: 520)

@main
struct ScanHost {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            die("usage: \(args.first ?? "scan_host") <shaders.metal> <out1.png> <out2.png>")
        }
        let shaderPath = args[1], out1 = args[2], out2 = args[3]

        // 1. Build the fixture tree.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terrazzo-scan-\(UUID().uuidString)", isDirectory: true)
        do { try buildFixture(at: root) } catch { die("fixture build failed: \(error)") }
        defer { cleanup(root) }

        // 2. Walk to completion into the reducer.
        var reducer = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
        for await batch in FileSystemWalker.scan(root: root) {
            reducer.apply(batch)
        }
        let tree = reducer.makeTree(depthWindow: window)

        // 3. Assert the FULL golden tree (structure + per-node sizes).
        assertGolden(tree, root: root)

        // 4. Render two frames through the real QuadRenderer.
        guard let device = MTLCreateSystemDefaultDevice() else { die("no Metal device") }
        guard let shaderSource = try? String(contentsOfFile: shaderPath, encoding: .utf8) else {
            die("cannot read shader source at \(shaderPath)")
        }
        guard let renderer = QuadRenderer(device: device, pixelFormat: .bgra8Unorm,
                                          shaderSource: shaderSource) else {
            die("QuadRenderer init failed")
        }
        renderFrame(device: device, renderer: renderer, tree: tree,
                    px: viewportA.w, py: viewportA.h, out: out1)
        renderFrame(device: device, renderer: renderer, tree: tree,
                    px: viewportB.w, py: viewportB.h, out: out2)

        print("SCAN_HOST OK: walked \(tree.nodeCount) nodes, allocated \(tree.allocatedBytes) bytes; wrote \(out1) + \(out2)")
    }

    // MARK: - Fixture (mirrors Tests/FixtureFS/FixtureWalkTests)

    static func buildFixture(at root: URL) throws {
        let fm = FileManager.default
        func mkdir(_ u: URL) throws { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        func write(_ u: URL, _ s: String) throws { try Data(s.utf8).write(to: u) }

        try mkdir(root)
        try write(root.appendingPathComponent(".hidden"), "hidden-bytes")
        try write(root.appendingPathComponent("visible.txt"), "hello world")
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try mkdir(sub); try write(sub.appendingPathComponent("inner.txt"), "inner content here")
        // Readable bundle → opaque bundleLeaf.
        let fooBin = root.appendingPathComponent("Foo.app/Contents/MacOS", isDirectory: true)
        try mkdir(fooBin); try write(fooBin.appendingPathComponent("bin"), "pretend-binary")
        // Bundle with a locked dir inside → denied (cannot be honestly sized).
        let barRes = root.appendingPathComponent("Bar.app/Contents/Resources", isDirectory: true)
        try mkdir(barRes); try write(barRes.appendingPathComponent("r.bin"), "bar-resource")
        let barLocked = root.appendingPathComponent("Bar.app/Contents/Locked", isDirectory: true)
        try mkdir(barLocked); try write(barLocked.appendingPathComponent("hidden.bin"), "cannot read me")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: barLocked.path)
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try mkdir(denied); try write(denied.appendingPathComponent("secret.txt"), "top secret")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try mkdir(target); try write(target.appendingPathComponent("real.txt"), "target payload")
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
    }

    static func cleanup(_ root: URL) {
        let fm = FileManager.default
        for p in ["denied", "Bar.app/Contents/Locked"] {
            let u = root.appendingPathComponent(p, isDirectory: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
        }
        try? fm.removeItem(at: root)
    }

    // MARK: - Golden (full tree, sizes included — review TZ-2 points 1 & 2)

    /// Deep enough that nothing in the fixture folds.
    static let window = 10

    static func assertGolden(_ tree: SizeTree, root: URL) {
        let expected = expectedTree(root, name: root.lastPathComponent, depth: 0)
        compareTrees(tree, expected, path: root.lastPathComponent)
        if tree.allocatedBytes <= 0 { die("scanned allocated total is not positive") }
        // Spot-check the two invisible-space edges by name, for a legible failure.
        func child(_ n: String) -> SizeTree? { tree.children.first { $0.name == n } }
        guard child("denied")?.kind == .denied else { die("denied dir did not surface as denied") }
        guard child("Bar.app")?.kind == .denied else {
            die("Bar.app (locked dir inside) did not surface as denied — an EPERM was silently hidden")
        }
        guard child("Foo.app")?.kind == .bundleLeaf else { die("Foo.app is not an opaque bundle leaf") }
    }

    /// Node-for-node comparison; dies at the first divergence with its path.
    static func compareTrees(_ a: SizeTree, _ e: SizeTree, path: String) {
        // `id` is the path-derived DTO identity that drives rectangle
        // interpolation — pin it in the golden too (review-1 point 3).
        if a.id != e.id { die("id @ \(path): \(a.id) != \(e.id)") }
        if a.name != e.name { die("name @ \(path): \(a.name) != \(e.name)") }
        if a.kind != e.kind { die("kind @ \(path): \(a.kind) != \(e.kind)") }
        if a.allocatedBytes != e.allocatedBytes {
            die("allocated @ \(path): \(a.allocatedBytes) != \(e.allocatedBytes)")
        }
        if a.logicalBytes != e.logicalBytes {
            die("logical @ \(path): \(a.logicalBytes) != \(e.logicalBytes)")
        }
        if a.scanState != e.scanState { die("scanState @ \(path): \(a.scanState) != \(e.scanState)") }
        let an = a.children.map(\.name), en = e.children.map(\.name)
        if an != en { die("children @ \(path): \(an) != \(en)") }
        for (ac, ec) in zip(a.children, e.children) {
            compareTrees(ac, ec, path: "\(path)/\(ac.name)")
        }
    }

    /// Recompute the ENTIRE expected SizeTree independently — same measure
    /// syscalls, same ScanPolicy rules, same (name, id) ordering. Mirrors the
    /// XCTest golden in Tests/FixtureFS. Every node is `.complete` after a finished
    /// walk (files/bundles via size, dirs via completion, denied via the flag).
    static func expectedTree(_ url: URL, name: String, depth: Int) -> SizeTree {
        let policy = ScanPolicy.default
        let id = url.path

        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            let (a, l) = FileSystemWalker.measure(url)
            return leaf(id, name, .file, a, l)
        }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let (ownA, ownL) = FileSystemWalker.measure(url)
        guard isDir else { return leaf(id, name, .file, ownA, ownL) }

        if policy.isBundleLeaf(name: name) {
            let (ba, bl, fullyRead) = expectedBundleTotal(url)
            return fullyRead ? leaf(id, name, .bundleLeaf, ba, bl) : leaf(id, name, .denied, ownA, ownL)
        }

        // Hidden entries are ALWAYS included (structural walker invariant).
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []) else {
            return leaf(id, name, .denied, ownA, ownL)
        }
        var kids = entries.map { expectedTree($0, name: $0.lastPathComponent, depth: depth + 1) }
        kids.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        let totalA = kids.reduce(ownA) { $0 + $1.allocatedBytes }
        let totalL = kids.reduce(ownL) { $0 + $1.logicalBytes }
        let retained = depth < window ? kids : []
        return SizeTree(id: id, name: name, kind: .dir,
                        allocatedBytes: totalA, logicalBytes: totalL,
                        children: retained, scanState: .complete)
    }

    static func leaf(_ id: String, _ name: String, _ kind: NodeKind, _ a: Int64, _ l: Int64) -> SizeTree {
        SizeTree(id: id, name: name, kind: kind, allocatedBytes: a, logicalBytes: l,
                 children: [], scanState: .complete)
    }

    static func expectedBundleTotal(_ url: URL) -> (allocated: Int64, logical: Int64, fullyRead: Bool) {
        var totalA = FileSystemWalker.measure(url).allocated
        var totalL = FileSystemWalker.measure(url).logical
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else { return (totalA, totalL, false) }
        var fullyRead = true
        for e in entries {
            let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true {
                let (a, l) = FileSystemWalker.measure(e); totalA += a; totalL += l
            } else if v?.isDirectory == true {
                let (a, l, sub) = expectedBundleTotal(e); totalA += a; totalL += l
                fullyRead = fullyRead && sub
            } else {
                let (a, l) = FileSystemWalker.measure(e); totalA += a; totalL += l
            }
        }
        return (totalA, totalL, fullyRead)
    }

    // MARK: - Render (mirrors verify_host)

    static func renderFrame(device: MTLDevice, renderer: QuadRenderer, tree: SizeTree,
                            px: Int, py: Int, out: String) {
        let viewport = Rect(x: 0, y: 0, width: Double(px), height: Double(py))
        let tiles = TreemapScene.layout(tree: tree, viewport: viewport)
        guard !tiles.isEmpty else { die("scene produced no tiles at \(px)x\(py)") }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: px, height: py, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { die("makeTexture failed") }
        renderer.renderSynchronously(tiles: tiles, into: target)

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
        if lit == 0 { die("frame \(out) is blank — the scanned map did not render") }

        writePNG(pixels: &pixels, width: px, height: py, bytesPerRow: bytesPerRow, path: out)
        print("  frame \(out): \(tiles.count) tiles, \(lit) lit pixels")
    }

    static func writePNG(pixels: inout [UInt8], width: Int, height: Int,
                         bytesPerRow: Int, path: String) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs, bitmapInfo: info.rawValue),
              let img = ctx.makeImage() else { die("CGContext/makeImage failed for \(path)") }
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            die("CGImageDestination create failed for \(path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        if !CGImageDestinationFinalize(dest) { die("PNG finalize failed for \(path)") }
    }

    static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("SCAN_HOST FAILED: \(msg)\n".utf8))
        exit(1)
    }
}
