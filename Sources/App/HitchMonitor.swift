//
//  HitchMonitor.swift — the main-thread stall detector (TZ-3b threading evidence).
//  Module maturity: PROTOTYPE (slice TZ-3b)
//
//  THE LAW IT WATCHES (PLAN §"Threading model"): "nothing on the main thread may
//  scale with node count." The failure signature is the system beachball — macOS
//  shows the wait cursor when main stalls for seconds. This makes that observable
//  and CHEAP: a heartbeat Timer on the main RunLoop records the gap between its own
//  fires. When main is free, that gap is ~one frame; when main is blocked doing
//  node-count work (the pre-TZ-3b bug), the next fire is LATE and the gap balloons —
//  a direct measurement of exactly the thing the law forbids.
//
//  It measures the MAIN thread by construction: a `.common`-mode Timer can only fire
//  when the main RunLoop turns, so a blocked main IS a late fire. It logs any gap >
//  50 ms (packet) with the coarse phase that was active, and remembers the worst gap
//  for the acceptance report ("no gap > 100 ms").
//
//  GATED OFF BY DEFAULT (`TERRAZZO_HITCH`): zero cost in normal use (no timer
//  scheduled). The headless threading harness sets the flag; the operator can too.
//  A sibling of the existing `TERRAZZO_TRACE`/`TERRAZZO_SCAN_ROOT` env affordances —
//  reading a process-env value, no ScanFS-boundary I/O.
//
//  ABSTRACTION LEDGER: adds none. One concrete monitor, one owner (ScanController).
//  No protocol; the "phase" is a plain String label, not a state machine.
//

import AppKit
import QuartzCore

@MainActor
final class HitchMonitor {
    /// Log any inter-beat gap above this (packet: "gap > 50 ms").
    static let logThresholdMs: Double = 50
    /// Heartbeat period — one display frame at 60 Hz. The baseline gap is ~this.
    private static let heartbeatSeconds: Double = 1.0 / 60.0
    /// Off unless the env flag is present (debug-only, cheap enough to keep).
    static let enabled = ProcessInfo.processInfo.environment["TERRAZZO_HITCH"] != nil

    private var timer: Timer?
    private var lastBeat: CFTimeInterval = 0
    private var phase = "idle"
    private(set) var worstGapMs: Double = 0
    private(set) var beats = 0

    /// Coarse label of what main was doing, attached to any logged hitch.
    func setPhase(_ p: String) { phase = p }

    func start() {
        guard Self.enabled, timer == nil else { return }
        lastBeat = CACurrentMediaTime()
        worstGapMs = 0
        beats = 0
        let t = Timer(timeInterval: Self.heartbeatSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("monitor on (log threshold \(Self.logThresholdMs) ms)")
    }

    private func beat() {
        let now = CACurrentMediaTime()
        let gapMs = (now - lastBeat) * 1000.0
        lastBeat = now
        beats += 1
        if gapMs > worstGapMs { worstGapMs = gapMs }
        if gapMs > Self.logThresholdMs {
            log(String(format: "gap %.1f ms while %@", gapMs, phase))
        }
    }

    /// Stop and print the headline number for the acceptance report.
    func stop(reason: String) {
        timer?.invalidate()
        timer = nil
        guard Self.enabled else { return }
        log(String(format: "%@: worst main-thread gap %.1f ms over %d beats", reason, worstGapMs, beats))
    }

    private func log(_ s: String) { print("TZHITCH \(s)"); fflush(stdout) }
}
