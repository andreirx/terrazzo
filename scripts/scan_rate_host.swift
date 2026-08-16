//
//  scan_rate_host.swift — THE NUMBERS harness for TZ-6 (files/s + wall-clock).
//  Module maturity: PROTOTYPE (slice TZ-6)
//
//  The acceptance gate for TZ-6 is a MEASURED sustained scan rate (≥ 25,000
//  files/s on a home scan) and full-home wall-clock (≤ 3 min). threads.sh proves
//  the THREADING law (worst main gap) but does not isolate raw ingest throughput;
//  this host does exactly that and nothing else, so the number is unambiguous.
//
//  It drives the REAL FileSystemWalker into the REAL ScanReducer — the exact scan
//  engine path the App runs (ScanFS → ScanEvents → ScanReducer), minus TreemapCore
//  (layout is the pipeline's job, not the walker's, and does not gate ingest). It
//  folds every event on one consumer, counting `processedCount` (the reducer's
//  stat'd-entry numerator) against wall-clock, and reports sustained files/s. This
//  is the SAME reducer the golden tests fold, so the rate reflects real per-event
//  cost (id strings, event allocation, bumpSubtree ancestor walk), not a raw
//  syscall microbenchmark.
//
//  ANTICIPATORY-SCAN MODE (packet deliverable 5): with `+anticipate` it starts the
//  volume-root warm (FileSystemWalker.anticipateVolumeRoot) alongside the primary scan
//  and reports the primary rate WITH it running, so "never degrades the primary scan
//  measurably" is a measured before/after, not an assertion. `qos=background` runs the
//  warm at .background instead of the production default .utility — the QoS DECISION
//  comparison (OPERATOR_NOTE tz6_anticipatory_qos). The warm also reports THROUGHPUT
//  (dirs/s over the primary window, via the anticipateVolumeRoot `onDir` seam): whole-
//  volume warm-to-completion is throttle-dominated (tens of minutes), so per-QoS dirs/s
//  is the honest anticipation-speed signal the two-completion-times ask reduces to.
//
//  Compiled by scripts/scanrate.sh with ScanFS + ScanCore ONLY (no AppKit/Metal),
//  so it builds and runs fast. Usage:
//    scan_rate_host <rootDir> [maxSeconds] [+anticipate] [qos=background]
//                              [+progress] [warmonly] [warmcap=<sec>]
//  It runs the scan to completion OR until maxSeconds, whichever first, and prints
//  a single TZRATE summary line the script greps.
//
//  `+progress` (revise-1 finding 4) additionally prints a TZPROGRESS trace: the ratified
//  ScanProgress readout at the fast rate — a percentage + ETA for a volume-root scan, nil
//  (files/sec fallback) for a subtree scan, from the SAME in-flight numerator.
//
//  `warmonly` (revise-1 finding 1) runs ONLY the anticipatory warm (no primary), excluding
//  <rootDir>, and prints a TZWARM line with its ELAPSED and whether it COMPLETED; `warmcap=<sec>`
//  stops it after N seconds (0 = to completion) — the honest time-bound result when the
//  whole-volume warm is throttle-dominated (tens of minutes).
//

// Compiled as a swiftc MONOLITH with Sources/ScanFS + Sources/ScanCore (see
// scripts/scanrate.sh), so ScanReducer / FileSystemWalker resolve same-module — no
// `import ScanCore` / `import ScanFS` (those modules do not exist in the monolith).
import Foundation
import os

@main
struct ScanRateHost {
    static func main() async {
        let args = CommandLine.arguments
        let rootPath = args.count > 1 ? args[1] : NSHomeDirectory()
        let maxSeconds = args.count > 2 ? (Double(args[2]) ?? 0) : 0 // 0 = run to completion
        let anticipate = args.contains("+anticipate")
        // QoS override for the QoS DECISION (OPERATOR_NOTE tz6_anticipatory_qos): `qos=background`
        // runs the warm at .background, else the production default (.utility). Reported so both
        // primary rates are attributable.
        let qosBackground = args.contains("qos=background")
        let warmPriority: TaskPriority = qosBackground ? .background : .utility
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        // WARM-ONLY COMPLETION mode (revise-1 finding 1). The QoS decision needs each QoS's
        // ANTICIPATION ELAPSED reported, not only its throughput measured under the primary
        // window. Here we run ONLY the warm (no primary), excluding `root`, and either await
        // its natural completion OR stop at `warmcap=<sec>` (0 = run to completion). We report
        // whether it COMPLETED and the elapsed time — an honest, time-bounded result when the
        // whole-volume warm is throttle-dominated (4 ms/dir floor ⇒ tens of minutes), exactly
        // the "non-completion/time-bound" outcome the reviewer permits. This is a real completion
        // watcher, not a proxy: `await warmTask.value` returns iff the warm finished on its own.
        if args.contains("warmonly") {
            let warmCap = args.first(where: { $0.hasPrefix("warmcap=") })
                .flatMap { Double($0.dropFirst("warmcap=".count)) } ?? 0
            let warmDirs = OSAllocatedUnfairLock(initialState: 0)
            let start = DispatchTime.now().uptimeNanoseconds
            let warmTask = FileSystemWalker.anticipateVolumeRoot(
                excluding: root, priority: warmPriority,
                onDir: { _ in warmDirs.withLock { $0 += 1 } })
            let finished = OSAllocatedUnfairLock(initialState: false)
            let watcher = Task { await warmTask.value; finished.withLock { $0 = true } }
            // Poll for natural completion or the cap. 250 ms granularity — negligible vs the
            // tens-of-minutes warm, and it never touches the warm's own throttle timing.
            while true {
                if finished.withLock({ $0 }) { break }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
                if warmCap > 0, elapsed >= warmCap { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let completed = finished.withLock { $0 }
            warmTask.cancel(); watcher.cancel()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
            let dirs = warmDirs.withLock { $0 }
            let rate = elapsed > 0 ? Double(dirs) / elapsed : 0
            print(String(format: "TZWARM qos=%@ excluding=%@ dirs=%d elapsed=%.2fs rate=%.0f dirs/s %@",
                         qosBackground ? "background" : "utility", root.path, dirs, elapsed, rate,
                         completed ? "(completed)" : "(capped — warm did NOT complete)"))
            fflush(stdout)
            return
        }

        // Optional anticipatory volume-root warm (excludes the active scan root subtree).
        // `onDir` now passes the warmed directory's PATH (revise: exclusion-observability seam);
        // this harness ignores the path and just counts warmed directories (thread-safe) so we
        // can report warm THROUGHPUT — whole-volume warm-to-completion is throttle-dominated
        // (tens of minutes), so dirs/s over the measured window is the honest per-QoS signal.
        let warmDirs = OSAllocatedUnfairLock(initialState: 0)
        var warmTask: Task<Void, Never>?
        let warmStart = DispatchTime.now().uptimeNanoseconds
        if anticipate {
            warmTask = FileSystemWalker.anticipateVolumeRoot(
                excluding: root, priority: warmPriority,
                onDir: { _ in warmDirs.withLock { $0 += 1 } })
        }

        var reducer = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
        let start = DispatchTime.now().uptimeNanoseconds
        var batches = 0
        var timedOut = false

        // A GENUINE in-flight snapshot for the progress-readout trace (revise-1 finding 4):
        // the reducer's processedCount + wall-clock as they stood just BEFORE the final batch
        // — a real running(true) sample at the fast rate, not a post-hoc reconstruction.
        var snapProcessed = 0
        var snapElapsed = 0.0
        let stream = FileSystemWalker.scan(root: root)
        for await batch in stream {
            snapProcessed = reducer.processedCount
            snapElapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
            reducer.apply(batch)
            batches += 1
            if maxSeconds > 0 {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
                if elapsed > maxSeconds { timedOut = true; break }
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9

        // Snapshot warm progress at the moment the primary window ends (BEFORE cancel), so the
        // warm throughput is measured over the same wall-clock the primary ran under contention.
        let warmElapsed = Double(DispatchTime.now().uptimeNanoseconds &- warmStart) / 1e9
        let warmedDirs = warmDirs.withLock { $0 }
        warmTask?.cancel()

        let processed = reducer.processedCount
        let rate = elapsed > 0 ? Double(processed) / elapsed : 0
        let mode = anticipate ? "primary+anticipate" : "primary"
        var line = String(format: "TZRATE mode=%@ root=%@ processed=%d batches=%d elapsed=%.2fs rate=%.0f files/s%@",
                          mode, root.path, processed, batches, elapsed, rate,
                          timedOut ? " (capped)" : " (completed)")
        if anticipate {
            let warmRate = warmElapsed > 0 ? Double(warmedDirs) / warmElapsed : 0
            line += String(format: " | warm qos=%@ dirs=%d warmElapsed=%.2fs warmRate=%.0f dirs/s",
                           qosBackground ? "background" : "utility", warmedDirs, warmElapsed, warmRate)
        }
        print(line)

        // PROGRESS-READOUT TRACE (revise-1 finding 4). Prove the ratified progress model
        // (ScanProgress) behaves at the NEW fast rate: the SAME in-flight numerator yields a
        // percentage + ETA for a VOLUME-ROOT scan and NOTHING (nil, → files/sec fallback) for a
        // SUBTREE scan (OPERATOR_NOTE #2 item 2). The denominator is the UNCHANGED statfs
        // used-inode count (VolumeProbe.usedInodes). isVolumeRoot is the ONLY difference — this
        // is the live-trace companion to the deterministic ScanProgressTests §6.
        if args.contains("+progress") {
            let used = VolumeProbe.usedInodes(for: root) ?? 0
            let rate = snapElapsed > 0 ? Double(snapProcessed) / snapElapsed : 0
            let sub = ScanProgress(filesProcessed: snapProcessed, usedInodes: used,
                                   running: true, isVolumeRoot: false)
            let vol = ScanProgress(filesProcessed: snapProcessed, usedInodes: used,
                                   running: true, isVolumeRoot: true)
            let subFrac = sub.fraction.map { String(format: "%.3f", $0) } ?? "nil"
            let subEta = sub.etaSeconds(filesPerSecond: rate).map { String(format: "%.1fs", $0) } ?? "nil"
            let volFrac = vol.fraction.map { String(format: "%.3f", $0) } ?? "nil"
            let volEta = vol.etaSeconds(filesPerSecond: rate).map { String(format: "%.1fs", $0) } ?? "nil"
            print(String(format: "TZPROGRESS in-flight processed=%d usedInodes=%d measuredRate=%.0f files/s | SUBTREE fraction=%@ eta=%@ | VOLUME-ROOT fraction=%@ eta=%@",
                         snapProcessed, used, rate, subFrac, subEta, volFrac, volEta))
        }
        fflush(stdout)
    }
}
