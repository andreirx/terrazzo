//
//  scan_profile_host.swift — TZ-6 PER-PHASE profile (revise finding 5).
//  Module maturity: PROTOTYPE (slice TZ-6)
//
//  The revise note requires the walker's cost be ATTRIBUTED PER PHASE — measured, not
//  inferred — so the 120× fix provably targets the measured cost:
//    1. ENUMERATION   — time in `getattrlistbulk` syscalls (whole-directory attr batches)
//    2. ATTRIBUTES    — time in per-entry `lstat` (dirs/symlinks; files are inline, free)
//    3. ID+EVENT BUILD— time building node ids + ChildStub/ScanEvent arrays
//    4. ACTOR SENDS   — time awaiting the EventBatcher actor (`add`)
//
//  It drives the REAL production primitives so the numbers reflect what ships:
//  `DirectoryReader.read(_:profile:)` accumulates phases 1–2 via its nil-in-production
//  `ReaderProfile` hook (so the measured code IS the hot loop, not a reimplementation),
//  and this host times phases 3–4 around the SAME event-construction the walker's
//  `classifyChildren` performs. The walk is SINGLE-THREADED on purpose: phase attribution
//  must not be smeared across cores. It therefore reports LOWER absolute throughput than
//  the parallel walker (scanrate.sh) — the point here is the RATIO between phases, which is
//  what tells us where the 120× went.
//
//  Simplifications, stated (this is a diagnostic, not the scan path): it treats `.app`
//  bundles as ordinary directories (bundle-leaf policy does not change the per-entry phase
//  ratio) and stays on ONE DEVICE (so profiling `/` does not wander into other volumes).
//
//  Compiled by scripts/profile.sh as a swiftc MONOLITH with Sources/ScanFS + Sources/
//  ScanCore (same arrangement as scan_rate_host) — so DirectoryReader / EventBatcher /
//  ScanEvent resolve same-module with no imports. Usage:
//    scan_profile_host <rootDir>
//  Prints one TZPROFILE line the script greps.
//

import Foundation

@main
struct ScanProfileHost {
    static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func main() async {
        let args = CommandLine.arguments
        let rootPath = args.count > 1 ? args[1] : NSHomeDirectory()
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        let prof = DirectoryReader.ReaderProfile()   // phases 1–2 accumulate here
        var idEventNanos: UInt64 = 0                 // phase 3
        var actorNanos: UInt64 = 0                   // phase 4
        var dirs = 0
        var entries = 0

        // Sink discards — we are timing the ACT of sending to the actor, not consuming.
        let batcher = EventBatcher { _ in }

        // One-device guard (see header): skip children on a different st_dev.
        var rootStat = stat()
        let rootDev: dev_t? = stat(root.path, &rootStat) == 0 ? rootStat.st_dev : nil

        func walk(_ path: String, id: String) async {
            dirs += 1
            let children: [DirectoryReader.Child]
            switch DirectoryReader.read(path, profile: prof) {   // phases 1–2 (timed inside)
            case .unreadable: return
            case .complete(let c), .partial(let c): children = c
            }

            // Phase 3: build ids + stubs + size events — the SAME construction classifyChildren does.
            let t3 = nowNs()
            var stubs: [ChildStub] = []
            var sizeEvents: [ScanEvent] = []
            var subdirs: [(String, String)] = []
            for child in children {
                let cid = FileSystemWalker.joinId(id, child.name)
                switch child.kind {
                case .symlink:
                    stubs.append(ChildStub(id: cid, name: child.name, kind: .file))
                    sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))
                case .file:
                    stubs.append(ChildStub(id: cid, name: child.name, kind: .file))
                    sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))
                case .dir:
                    stubs.append(ChildStub(id: cid, name: child.name, kind: .dir))
                    sizeEvents.append(.sizeUpdated(nodeId: cid, allocated: child.allocated, logical: child.logical))
                    if let rootDev, child.device != rootDev { break }   // one device
                    subdirs.append((path + "/" + child.name, cid))
                }
                entries += 1
            }
            var batch: [ScanEvent] = [.childrenDiscovered(parentId: id, children: stubs)]
            batch.append(contentsOf: sizeEvents)
            idEventNanos &+= nowNs() &- t3

            // Phase 4: hand the batch to the actor (the real hop the walker pays).
            let t4 = nowNs()
            await batcher.add(batch)
            actorNanos &+= nowNs() &- t4

            for (cp, cid) in subdirs { await walk(cp, id: cid) }
        }

        let wall0 = nowNs()
        await walk(root.path, id: root.path)
        await batcher.flush()
        let wallNs = nowNs() &- wall0

        let bulk = prof.bulkNanos, attr = prof.attrNanos
        let accounted = bulk &+ attr &+ idEventNanos &+ actorNanos
        func pct(_ x: UInt64) -> Double { accounted > 0 ? Double(x) / Double(accounted) * 100 : 0 }
        func ms(_ x: UInt64) -> Double { Double(x) / 1e6 }
        let wallS = Double(wallNs) / 1e9
        let rate = wallS > 0 ? Double(entries) / wallS : 0

        print("""
        TZPROFILE root=\(root.path) dirs=\(dirs) entries=\(entries) \
        wall=\(String(format: "%.2f", wallS))s rate=\(String(format: "%.0f", rate)) entries/s (single-threaded)
          enumeration (getattrlistbulk): \(String(format: "%8.1f", ms(bulk))) ms  (\(String(format: "%5.1f", pct(bulk)))%)  calls=\(prof.bulkCalls)
          attributes  (lstat)          : \(String(format: "%8.1f", ms(attr))) ms  (\(String(format: "%5.1f", pct(attr)))%)  calls=\(prof.lstatCalls)
          id+event build               : \(String(format: "%8.1f", ms(idEventNanos))) ms  (\(String(format: "%5.1f", pct(idEventNanos)))%)
          actor sends (EventBatcher)   : \(String(format: "%8.1f", ms(actorNanos))) ms  (\(String(format: "%5.1f", pct(actorNanos)))%)
          accounted total              : \(String(format: "%8.1f", ms(accounted))) ms  (wall includes recursion/scheduling overhead beyond this)
        """)
        fflush(stdout)
    }
}
