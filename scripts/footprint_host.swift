//
//  footprint_host.swift — THE NUMBERS harness for TZ-9 (retained bytes/node + leak gate).
//  Module maturity: PROTOTYPE (slice TZ-9)
//
//  THE MEMORY LAW (CLAUDE.md constraint 6): retained memory per scanned node ≤ ~100 B
//  amortized, and a rescan returns footprint to baseline. This host MEASURES both, on the
//  REAL walker→reducer path (the same ScanFS → ScanEvents → ScanReducer the App runs, minus
//  TreemapCore — layout is the pipeline's job and does not retain the node store).
//
//  WHY phys_footprint (not RSS): macOS `task_vm_info.phys_footprint` is exactly what Activity
//  Monitor reports as "Memory" — dirty + compressed pages charged to this process — the honest
//  figure for "how much RAM did scanning this tree cost". Read via mach `task_info`.
//
//  MODES:
//    footprint_host <rootDir> [maxSeconds]
//        One scan. Reports: retained node count (reducer.processedCount), the footprint DELTA
//        over the pre-scan baseline, and BYTES PER NODE = delta / nodes — the headline law number.
//
//    footprint_host <rootDir> [maxSeconds] rescan=N
//        N sequential scans, each into a FRESH reducer that is RELEASED before the next. Reports
//        each scan's peak footprint + node count. THE LEAK SIGNAL is that peak footprint does NOT
//        grow with the rescan index (a leak would make scan k+1 cost more than scan k) — "footprint
//        returns to baseline each rescan, flat within a few %". (Freed heap may stay resident to
//        this process, so absolute return-to-zero is not the signal; NO GROWTH across rescans is.)
//
//  Compiled by scripts/footprint.sh with ScanFS + ScanCore ONLY (no AppKit/Metal). Run BARE.
//  EVIDENCE, not a deterministic CI gate — the number depends on the machine + tree; it is run
//  and read (like scanrate.sh), then stated in the report.
//

// Monolith with Sources/ScanFS + Sources/ScanCore (see scripts/footprint.sh) — ScanReducer /
// FileSystemWalker resolve same-module, so NO `import ScanCore`/`import ScanFS`.
import Foundation
import Darwin

/// Current physical footprint (bytes) — Activity Monitor's "Memory" column. 0 if the query fails.
func physFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

func mib(_ bytes: UInt64) -> String { String(format: "%.1f MiB", Double(bytes) / (1024 * 1024)) }
func mib(_ bytes: Int64) -> String { mib(UInt64(max(0, bytes))) }

/// Fold the whole walker stream for `root` into ONE reducer, returning it plus the peak footprint
/// observed while it was alive. The reducer is returned (not dropped) so the caller controls its
/// lifetime — the single-scan mode reads its final footprint; the leak mode drops it and re-measures.
func scanIntoReducer(root: URL, maxSeconds: Double) async -> (reducer: ScanReducer, peak: UInt64, elapsed: Double) {
    var reducer = ScanReducer(rootId: root.path, rootName: root.lastPathComponent)
    var peak: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    let stream = FileSystemWalker.scan(root: root)
    for await batch in stream {
        reducer.apply(batch)
        let f = physFootprintBytes()
        if f > peak { peak = f }
        if maxSeconds > 0 {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
            if elapsed > maxSeconds { break }
        }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
    return (reducer, max(peak, physFootprintBytes()), elapsed)
}

@main
struct FootprintHost {
    static func main() async {
        let args = CommandLine.arguments
        let rootPath = args.count > 1 ? args[1] : NSHomeDirectory()
        let maxSeconds = args.count > 2 ? (Double(args[2]) ?? 0) : 0
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rescans = args.first(where: { $0.hasPrefix("rescan=") })
            .flatMap { Int($0.dropFirst("rescan=".count)) } ?? 0

        let baseline = physFootprintBytes()

        if rescans > 0 {
            // LEAK GATE: N sequential scans, each into a fresh reducer released before the next.
            print(String(format: "TZFOOTPRINT leak-gate root=%@ baseline=%@ rescans=%d",
                         root.path, mib(baseline), rescans))
            var peaks: [UInt64] = []
            for i in 1...rescans {
                var (reducer, peak, elapsed) = await scanIntoReducer(root: root, maxSeconds: maxSeconds)
                let nodes = reducer.processedCount
                let bytesPerNode = nodes > 0 ? Double(Int64(peak) - Int64(baseline)) / Double(nodes) : 0
                peaks.append(peak)
                print(String(format: "  rescan %d: nodes=%d peak=%@ delta=%@ B/node=%.1f elapsed=%.1fs",
                             i, nodes, mib(peak), mib(Int64(peak) - Int64(baseline)), bytesPerNode, elapsed))
                // Release the reducer's node store before the next scan (the rescan-hygiene contract).
                reducer = ScanReducer(rootId: "/", rootName: "/")
                _ = reducer
                let afterRelease = physFootprintBytes()
                print(String(format: "           after release: %@ (baseline %@)", mib(afterRelease), mib(baseline)))
                fflush(stdout) // stream per-scan progress on a long multi-rescan run
            }
            if let first = peaks.first, let last = peaks.last, first > 0,
               let lo = peaks.min(), let hi = peaks.max() {
                // THE LEAK SIGNAL is DIRECTIONAL: does peak footprint GROW with the rescan index?
                // (last − first)/first — POSITIVE means each rescan cost more than the last (a leak);
                // ≤0 means no growth (the law's "returns to baseline each rescan"). The min..max range
                // is reported too, but it is NOT the signal (a direction-blind spread would call a
                // DECREASING series "growth", a name-honesty defect).
                //
                // SIGNED arithmetic (bugfix TZ-9): `last`/`first` are `UInt64`; when a later rescan's
                // peak is LOWER (the healthy case — footprint did not grow), `last − first` UNDERFLOWED
                // the unsigned subtraction and trapped (SIGTRAP). Compute the delta in `Int64` first,
                // exactly as the per-scan `Int64(peak) − Int64(baseline)` line already does.
                let trend = Double(Int64(last) - Int64(first)) / Double(first) * 100
                // COMPUTE the ≤5% criterion as a hard PASS/FAIL (acceptance: "COMPUTE its ≤5% criterion,
                // not narrate direction"). PASS = peak did not grow more than 5% from first to last scan
                // (the law's "a rescan returns footprint to baseline"); a DROP is a pass (trend ≤ 5).
                let passed = trend <= 5.0
                let verdict = passed ? "PASS: peak did not grow >5% across rescans (no leak)"
                                     : "FAIL: peak grew >5% across rescans (LEAK SUSPECT)"
                print(String(format: "TZFOOTPRINT leak-gate result: peaks first=%@ last=%@ (trend %+.1f%%, criterion ≤5%%) across %d rescans range=%@..%@ — %@",
                             mib(first), mib(last), trend, rescans, mib(lo), mib(hi), verdict))
            }
            fflush(stdout)
            return
        }

        // SINGLE SCAN: headline bytes/node.
        let (reducer, peak, elapsed) = await scanIntoReducer(root: root, maxSeconds: maxSeconds)
        let nodes = reducer.processedCount
        let delta = Int64(peak) - Int64(baseline)
        let bytesPerNode = nodes > 0 ? Double(delta) / Double(nodes) : 0
        let rate = elapsed > 0 ? Double(nodes) / elapsed : 0
        print(String(format: "TZFOOTPRINT root=%@ nodes=%d baseline=%@ peak=%@ delta=%@ B/node=%.1f (law ≤ ~100) rate=%.0f files/s elapsed=%.1fs",
                     root.path, nodes, mib(baseline), mib(peak), mib(delta), bytesPerNode, rate, elapsed))
        fflush(stdout)
    }
}
