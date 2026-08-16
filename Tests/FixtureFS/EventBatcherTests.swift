//
//  EventBatcherTests.swift — the batch-size bound is REAL, not just checked.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  review-1 point 1: `EventBatcher.add` used to append a whole supplied array and
//  only then compare `pending.count` to the cap, so a single wide directory
//  (thousands of children submitted at once) produced ONE oversized batch. The
//  fix drains in fixed `maxEventsPerBatch` chunks; this test pins that no
//  delivered batch ever exceeds the cap, whatever the input size, and that every
//  event is delivered exactly once, in order.
//
//  Lives in FixtureFS because that is the test target with `@testable import
//  ScanFS` (EventBatcher is an internal actor). No filesystem is touched here.
//

import XCTest
import ScanCore
@testable import ScanFS

final class EventBatcherTests: XCTestCase {

    /// Thread-safe collector: the batcher's `sink` is `@Sendable`. The actor
    /// serializes calls, but the closure is nonisolated, so guard with a lock.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[ScanEvent]] = []
        func record(_ b: [ScanEvent]) { lock.lock(); batches.append(b); lock.unlock() }
        func snapshot() -> [[ScanEvent]] { lock.lock(); defer { lock.unlock() }; return batches }
    }

    private func evt(_ i: Int) -> ScanEvent {
        .sizeUpdated(nodeId: "n\(i)", allocated: Int64(i), logical: Int64(i))
    }

    func testOversizedAddIsSplitIntoCappedBatches() async {
        let cap = 100
        let collector = Collector()
        let batcher = EventBatcher(maxEventsPerBatch: cap) { collector.record($0) }

        // One submission of 250 events — a "wide directory" in one shot.
        await batcher.add((0..<250).map(evt))

        // 200 delivered eagerly as two FULL batches; the sub-cap remainder (50) is
        // held for the timer/next add — it is NOT emitted as an oversized batch.
        let mid = collector.snapshot()
        XCTAssertEqual(mid.map(\.count), [cap, cap],
                       "a 250-event add yields two 100-batches, not one 250-batch")

        // Drain the remainder (as the walker's ticker / end-of-walk flush would).
        await batcher.flush()
        let final = collector.snapshot()

        XCTAssertTrue(final.allSatisfy { $0.count <= cap },
                      "NO delivered batch may exceed maxEventsPerBatch, however large the input")
        XCTAssertEqual(final.map(\.count), [cap, cap, 50], "chunks: 100, 100, then the 50 remainder")
        XCTAssertEqual(final.flatMap { $0 }, (0..<250).map(evt),
                       "every event delivered exactly once, in original order")
    }

    /// An exact multiple of the cap leaves nothing pending (boundary case).
    func testExactMultipleLeavesNoRemainder() async {
        let cap = 50
        let collector = Collector()
        let batcher = EventBatcher(maxEventsPerBatch: cap) { collector.record($0) }
        await batcher.add((0..<100).map(evt))
        XCTAssertEqual(collector.snapshot().map(\.count), [cap, cap])
        await batcher.flush() // no-op: pending is empty
        XCTAssertEqual(collector.snapshot().map(\.count), [cap, cap], "flush of empty pending is a no-op")
    }
}
