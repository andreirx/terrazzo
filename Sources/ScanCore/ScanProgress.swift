//
//  ScanProgress.swift — pure file-count progress + ETA arithmetic.
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  THE RATIFIED PROGRESS MODEL (PLAN §TZ-4, human directive 2026-08-16). Scan TIME is
//  spent PER INODE, not per byte — one `stat` for a 10 GB movie, thousands for a cache
//  directory — so the honest progress bar counts FILES, not bytes:
//
//      fraction ≈ filesProcessed / usedInodes         (usedInodes = statfs f_files − f_ffree)
//
//  The denominator is read once at scan start (`VolumeProbe.usedInodes`, zero cost, zero
//  persistence — the earlier scan-history.json idea is RETRACTED). It is VOLUME-WIDE, so
//  it counts inodes the scan can NEVER reach from this account (other users' homes,
//  TCC-denied areas). Consequently the bar may reach its cap BELOW 100 % and then wait;
//  we therefore CLAMP the running fraction strictly below 1 and SNAP to 1 only when the
//  scan actually completes (`running == false`). Never fake linearity — this is a known
//  approximation, surfaced as such (tooltip "estimate").
//
//  This is the PURE part (the arithmetic the packet requires tested): the ratio, the
//  clamp, and the ETA formula. The ROLLING files/sec rate is stateful (it needs two
//  timed samples) and lives in the App's control strip, which feeds its measured rate
//  into `etaSeconds` here. No time source, no I/O — a value function of its inputs.
//
//  ETA HONESTY FOR SUBTREE SCANS (OPERATOR_NOTE 2026-08-16 #2 item 2, binding field
//  ruling). The statfs used-inode denominator is the WHOLE VOLUME's population — it is
//  the workload of a VOLUME-ROOT scan, NOT of a `~`/subtree scan (a `~` scan touches a
//  small fraction of those inodes, so dividing by the volume total produced a nonsense
//  "4h left"). Rule: a percentage + ETA are shown ONLY when the scan root IS the volume
//  root; for a subtree scan `fraction`/`etaSeconds` return nil (the App then shows
//  files/sec + a processed count instead — motion and a real number, no fabricated
//  fraction). `isVolumeRoot` carries that fact from the App (it reads it once at scan
//  start, ScanFS `VolumeSkipPolicy.isVolumeRoot` — the same judgment the FDA banner uses).
//  Root promotion makes the volume-root case the common one, so the percentage/ETA return
//  as the scan reaches the volume root.
//
//  ABSTRACTION LEDGER: a pure value + static functions, no protocol, no state machine.
//  Concrete users: the App's ControlBar (renders fraction + ETA) and ScanProgressTests
//  (pins the clamp + ETA). Rejected simpler alternative — compute the ratio inline in
//  the AppKit view — would bury the clamp rule (the load-bearing "never claim 100 %
//  mid-scan" invariant) in an untestable UI layer.
//

import Foundation

/// A snapshot of scan progress by file count. Raw counts in; a clamped fraction out.
public struct ScanProgress: Equatable, Sendable {
    /// Entries stat'd so far (`ScanReducer.processedCount`).
    public let filesProcessed: Int
    /// Volume used-inode count at scan start (`f_files − f_ffree`); 0 ⇒ unknown.
    public let usedInodes: Int64
    /// Whether the scan is still streaming. Drives the snap-to-done rule.
    public let running: Bool
    /// Whether the scan ROOT is the volume root. The volume-wide inode denominator is the
    /// workload of a volume-root scan only, so a percentage + ETA are honest ONLY here; a
    /// subtree scan (`isVolumeRoot == false`) suppresses both (OPERATOR_NOTE #2 item 2).
    public let isVolumeRoot: Bool

    public init(filesProcessed: Int, usedInodes: Int64, running: Bool,
                isVolumeRoot: Bool = false) {
        self.filesProcessed = filesProcessed
        self.usedInodes = usedInodes
        self.running = running
        self.isVolumeRoot = isVolumeRoot
    }

    /// The running fraction is capped here, strictly below 1, so a volume-wide
    /// denominator inflated by unreachable inodes cannot make the bar claim completion
    /// while the scan is still going.
    public static let maxRunningFraction: Double = 0.99

    /// Fraction in `[0, 1]`, or `nil` when there is no honest percentage to show:
    /// the scan root is NOT the volume root (a subtree scan — the volume-wide inode
    /// denominator is not its workload, OPERATOR_NOTE #2 item 2), OR the denominator is
    /// unknown (no statfs). Completed ⇒ 1 (snap to done). Running ⇒
    /// `min(raw, maxRunningFraction)`, and never negative.
    public var fraction: Double? {
        guard isVolumeRoot else { return nil } // subtree scan: no percentage
        guard usedInodes > 0 else { return nil }
        guard running else { return 1.0 }
        let raw = Double(filesProcessed) / Double(usedInodes)
        return min(max(0, raw), Self.maxRunningFraction)
    }

    /// Inodes still unaccounted-for by the numerator (never negative). Used with a
    /// measured rate to derive the ETA. When the denominator is unknown, `nil`.
    public var remainingInodes: Int64? {
        guard usedInodes > 0 else { return nil }
        return max(0, usedInodes - Int64(filesProcessed))
    }

    /// Estimated seconds remaining, given a measured `filesPerSecond` rate. `nil` when
    /// the scan root is not the volume root (a subtree scan has no honest volume-inode
    /// ETA — OPERATOR_NOTE #2 item 2), indeterminate (no denominator), already done, or
    /// the rate is non-positive (no basis to extrapolate — show "estimating…" rather than
    /// a fabricated number).
    public func etaSeconds(filesPerSecond: Double) -> Double? {
        guard isVolumeRoot else { return nil } // subtree scan: no ETA
        guard running, filesPerSecond > 0, let remaining = remainingInodes, remaining > 0
        else { return nil }
        return Double(remaining) / filesPerSecond
    }
}
