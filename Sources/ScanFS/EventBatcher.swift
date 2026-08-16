//
//  EventBatcher.swift — coalesces per-worker events into delivered batches.
//  Module maturity: PROTOTYPE (slice TZ-2)
//
//  Many concurrent workers (one per top-level folder, ratified decision 5) emit
//  events; this actor is the single funnel that turns those concurrent emissions
//  into an ORDERED sequence of `[ScanEvent]` batches for the pure reducer. Being
//  an actor is the whole point: it serializes `add`/`flush` so the downstream
//  event stream is a clean linear order — the concurrency is dissolved HERE, at
//  the boundary, exactly as decision 5 requires ("events are the concurrency
//  boundary; the reducer stays pure and single-threaded").
//
//  Flush policy (packet TZ-2 deliverable 3): a batch is emitted when it reaches
//  `maxEventsPerBatch`, OR on a ~`flushInterval` timer driven by the walker. Both
//  bounds are named constants (below) so throughput tuning has one home.
//

import Foundation
#if canImport(ScanCore)
import ScanCore
#endif

/// Named batching bounds (packet: "~100ms or ~1000 events per batch").
enum BatchLimits {
    /// Emit as soon as this many events have accumulated (throughput bound).
    static let maxEventsPerBatch = 1000
    /// Time-based flush cadence in nanoseconds (latency bound) — ensures the map
    /// keeps filling even when a subtree trickles events slower than the size cap.
    static let flushIntervalNanos: UInt64 = 100_000_000 // ~100 ms
}

/// Serializes concurrent worker emissions into ordered batches handed to `sink`.
actor EventBatcher {
    private var pending: [ScanEvent] = []
    private let sink: @Sendable ([ScanEvent]) -> Void
    private let maxEventsPerBatch: Int

    init(maxEventsPerBatch: Int = BatchLimits.maxEventsPerBatch,
         sink: @escaping @Sendable ([ScanEvent]) -> Void) {
        self.sink = sink
        self.maxEventsPerBatch = maxEventsPerBatch
    }

    /// Append events; emit as many FULL-SIZE batches as have accumulated.
    ///
    /// A single supplied array can be large — `classifyChildren` of a wide
    /// directory submits one event per child, thousands at once. Appending then
    /// draining in fixed `maxEventsPerBatch` chunks makes the size cap a REAL
    /// per-delivered-batch bound (review-1 point 1): no batch handed to `sink`
    /// ever exceeds the cap, however big the input. The remainder (< cap) stays
    /// `pending` for the next `add` or the periodic `flush` to coalesce.
    func add(_ events: [ScanEvent]) {
        pending.append(contentsOf: events)
        while pending.count >= maxEventsPerBatch {
            let batch = Array(pending.prefix(maxEventsPerBatch))
            pending.removeFirst(maxEventsPerBatch)
            sink(batch)
        }
    }

    /// Emit whatever has accumulated (no-op if empty). Called by the walker's
    /// periodic ticker and at end-of-walk to drain the sub-cap remainder.
    func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        sink(batch)
    }
}
