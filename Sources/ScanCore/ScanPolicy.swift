//
//  ScanPolicy.swift — the ratified scan rules, as a pure value.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  Pure Foundation value type (CLAUDE.md constraint 1) — NO I/O. It only encodes
//  DECISIONS the walker and reducer read; the walker in ScanFS performs the
//  syscalls those decisions govern. Kept here (not in ScanFS) so the policy is
//  testable headless and so the reducer can share the one depth-window constant.
//
//  Current concrete users (why this type is earned, not speculative):
//    - ScanFS's walker reads `isBundleLeaf`.
//    - ScanReducer.makeTree reads `depthDetailWindow` (default).
//  Two current callers across a documented boundary → a shared value, not a bag
//  of scattered constants. Rejected simpler alternative: literals inline in the
//  walker — loses the single source of truth the reducer also needs.
//
//  NAME HONESTY (review-1 point 2): "hidden files always included" and "symlinks
//  never followed" are NOT fields here. They are FIXED v1 INVARIANTS, not knobs —
//  a configurable `includeHidden`/`followSymlinks` would be a name/contract
//  mismatch: it would let a caller silently defeat the VISION ("surfacing hidden
//  paths IS the product"; "symlinks never followed") the type claims to enforce.
//  The walker enforces both STRUCTURALLY (enumerate without `.skipsHiddenFiles`;
//  `lstat` + treat every symlink as an un-followed leaf) so there is no boolean
//  to set wrong. If a future scan profile ever legitimately needs to vary one,
//  THAT is the demonstrated axis, and it arrives then as a new `ScanPolicy` field
//  — not a speculative knob carried unused today.
//
//  Axis of variation: NONE demonstrated yet — these are fixed v1 rules. This is a
//  value-of-constants, not an abstraction over a growth axis; if a second policy
//  profile ever appears (e.g. a "fast, shallow" preview scan) that is the axis,
//  and it arrives as different `ScanPolicy` values, requiring no new type.
//

import Foundation

/// The ratified v1 scanning rules (decisions 2026-08-12; PLAN §"Ratified
/// decisions", packet TZ-2 deliverable 2).
public struct ScanPolicy: Sendable, Equatable {
    /// Retained/rendered child-detail depth below the focus (ratified decision 4:
    /// "sizes true, detail windowed"). The walker ALWAYS descends fully — every
    /// size is a real recursive total; this window limits only how many levels of
    /// child DETAIL the reducer retains in the projected tree. Root is depth 0, so
    /// a window of 5 retains the root plus 5 levels of children.
    public var depthDetailWindow: Int

    public init(depthDetailWindow: Int) {
        self.depthDetailWindow = depthDetailWindow
    }

    /// The ratified v1 defaults. `depthDetailWindow` 5 matches
    /// `TreemapScene.defaultDepthWindow` (VISION §Experience 2, "default depth 5").
    /// (Hidden-always-included and symlink-never-followed are structural walker
    /// invariants, not fields here — see the header note on name honesty.)
    public static let `default` = ScanPolicy(depthDetailWindow: 5)

    /// Bundle-leaf rule: `.app` directories are OPAQUE LEAVES in v1 (ratified
    /// 2026-08-12; VISION §Experience 5) — sized by their recursive total but not
    /// expanded into child tiles, and opened in Finder like any tile.
    ///
    /// TD (recorded, not silently dropped): other bundle types (`.framework`,
    /// `.bundle`, `.photoslibrary`, `.rtfd`, …) are NOT treated as leaves in v1 —
    /// they scan through as ordinary directories. Making them leaves is a named
    /// extension when the bundle taxonomy is settled; matching only `.app` keeps
    /// the v1 rule honest and small.
    public func isBundleLeaf(name: String) -> Bool {
        name.hasSuffix(".app")
    }
}
