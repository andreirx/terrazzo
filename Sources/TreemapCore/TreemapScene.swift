//
//  TreemapScene.swift — SizeTree → flat list of positioned, dimmed tiles.
//  Module maturity: PROTOTYPE (slice TZ-1)
//
//  The visualization core's top-level operation: take a SizeTree (the crossing
//  DTO), a focus node, a depth window, and a viewport rectangle, and produce a
//  FLAT list of tile DTOs the renderer can draw with zero tree knowledge. This
//  is the seam the headless tests drive and the App's QuadRenderer consumes —
//  the renderer never walks the tree; it draws whatever tiles it is handed.
//
//  Layout model (VISION §Experience 2, "nested, depth-dimmed squarified"):
//    - The focus node fills the viewport at dimLevel 0. It is mostly covered by
//      its children and shows through only as the border frame.
//    - Its children tile the focus rect INSET by a small named border
//      (`Layout.borderInset`), at dimLevel 1; their children tile THEM inset, at
//      dimLevel 2; and so on. Deeper level ⇒ higher dimLevel ⇒ the renderer
//      draws it dimmer. "children tile their parent inset by a small border;
//      deeper level = higher dimLevel" (TZ-1 deliverable 3).
//    - Recursion stops at `depthWindow` (default 5): no tile has dimLevel >
//      depthWindow. This is the visible/scanned depth window from VISION.
//
//  Emission order is PRE-ORDER (parent before its children). The renderer relies
//  on this for painter's-algorithm compositing: a parent is drawn first, then
//  its children paint over it, leaving the inset border showing. Documented
//  contract, not an accident.
//
//  Layout weight = allocatedBytes (PLAN open decision 1's recommendation; the
//  metric that explains free space). TZ-1 does not render per-node UNACCOUNTED
//  space (children are scaled to fill the parent's inner rect); surfacing
//  within-node unaccounted area is TZ-2/TZ-4 work (noted, not silently dropped).
//

import Foundation
// ScanCore is a SEPARATE module under SPM (`swift test`) and must be imported;
// under the swiftc monolith build (build.sh / verify.sh) ScanCore's sources are
// compiled into the SAME module, so there is no module to import — canImport is
// false there and the types resolve same-module. This one guard lets the single
// cross-module file compile in both worlds. (App-layer files never import the
// cores — like glyph-saver's ZapRenderer — because they are monolith-only.)
#if canImport(ScanCore)
import ScanCore
#endif

/// One positioned tile the renderer draws. Flat: carries everything needed to
/// draw without the tree — its rect, how deep it is (dim), and its identity/kind
/// for later hit-testing and denied/pending styling.
public struct TileRect: Equatable, Sendable {
    public let rect: Rect
    /// 0 at the focus node, +1 per level of nesting, capped at the depth window.
    /// The renderer maps this to brightness (higher = dimmer).
    public let dimLevel: Int
    public let nodeId: String
    public let kind: NodeKind

    public init(rect: Rect, dimLevel: Int, nodeId: String, kind: NodeKind) {
        self.rect = rect
        self.dimLevel = dimLevel
        self.nodeId = nodeId
        self.kind = kind
    }
}

public enum TreemapScene {
    /// Default number of nesting levels rendered below (and including) the focus.
    /// dimLevel ranges 0...depthWindow, i.e. the focus plus 5 levels of children
    /// (VISION §Experience 2 "default depth 5 visible").
    public static let defaultDepthWindow = 5

    /// Small border, in viewport units, by which each parent is inset before its
    /// children tile it — the visible nesting frame. Named so the tests and the
    /// renderer agree on the exact value.
    public static let defaultBorderInset: Double = 2.0

    /// Flatten `tree` into positioned tiles.
    ///
    /// - Parameters:
    ///   - tree: the whole SizeTree (root).
    ///   - focusId: node to fill the viewport; `nil` ⇒ the root.
    ///   - depthWindow: max dimLevel emitted (default 5).
    ///   - viewport: the rectangle the focus node fills (pixel space in the App;
    ///     any units in tests).
    ///   - borderInset: per-level inset (default `defaultBorderInset`).
    /// - Returns: pre-order tile list; `[]` if `focusId` is not found.
    public static func layout(
        tree: SizeTree,
        focusId: String? = nil,
        depthWindow: Int = defaultDepthWindow,
        viewport: Rect,
        borderInset: Double = defaultBorderInset
    ) -> [TileRect] {
        let focus: SizeTree
        if let focusId {
            guard let found = node(withId: focusId, in: tree) else { return [] }
            focus = found
        } else {
            focus = tree
        }
        var tiles: [TileRect] = []
        place(node: focus, rect: viewport, level: 0,
              depthWindow: depthWindow, borderInset: borderInset, into: &tiles)
        return tiles
    }

    /// Pre-order recursive placement. Emits `node`, then (if within the depth
    /// window and there is room) tiles its children in the inset rect.
    private static func place(
        node: SizeTree, rect: Rect, level: Int,
        depthWindow: Int, borderInset: Double, into tiles: inout [TileRect]
    ) {
        tiles.append(TileRect(rect: rect, dimLevel: level, nodeId: node.id, kind: node.kind))

        guard level < depthWindow, !node.children.isEmpty else { return }
        let inner = rect.inset(by: borderInset)
        guard inner.area > 0 else { return } // no room to nest — stop honestly

        let weights = node.children.map { Double($0.allocatedBytes) }
        let childRects = Squarify.layout(weights: weights, in: inner)
        for (child, childRect) in zip(node.children, childRects) {
            place(node: child, rect: childRect, level: level + 1,
                  depthWindow: depthWindow, borderInset: borderInset, into: &tiles)
        }
    }

    /// Depth-first search for a node by id. O(n); TZ-1 has no index (files are
    /// the system of record, no caches — CLAUDE.md constraint 4).
    private static func node(withId id: String, in tree: SizeTree) -> SizeTree? {
        if tree.id == id { return tree }
        for child in tree.children {
            if let found = node(withId: id, in: child) { return found }
        }
        return nil
    }
}
