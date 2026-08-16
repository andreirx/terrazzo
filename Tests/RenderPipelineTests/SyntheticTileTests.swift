//
//  SyntheticTileTests.swift — the per-volume "Unaccounted" tile math (TZ-4 D10).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  Pins the sizing/clamp/non-mutation properties of the synthetic UNACCOUNTED tile
//  (VISION §"invisible space is first-class"):
//   1. residual = max(0, capacity − free − scanned), clamped ≥ 0 (a scanned total that
//      momentarily exceeds capacity — naive hard-link/clone double-counting — yields an
//      honest zero, the ratified signal for a future dedup pass, not a negative tile).
//   2. augment APPENDS the tile as a child WITHOUT changing the root's own totals, so
//      the status bar's "Scanned" stays the real scanned total, not scanned+unaccounted.
//   3. augment is a NO-OP when the accounting is unknown (capacity 0) or the residual is
//      zero — no tile for nothing (every pre-TZ-4 pipeline test still behaves as before).
//   4. decompose splits the residual into (purgeable, unknown = max(0, residual −
//      purgeable)) for the hover readout — the literal ratified formula.
//

import XCTest
import ScanCore
@testable import RenderPipeline

final class SyntheticTileTests: XCTestCase {

    private func root(scanned: Int64) -> SizeTree {
        SizeTree(id: "/", name: "/", kind: .dir,
                 allocatedBytes: scanned, logicalBytes: scanned,
                 children: [SizeTree(id: "/a", name: "a", kind: .dir,
                                     allocatedBytes: scanned, logicalBytes: scanned)])
    }

    // MARK: 1. Residual sizing + clamp

    func testUnaccountedResidual() {
        XCTAssertEqual(SyntheticTile.unaccountedBytes(capacity: 1000, free: 200, scanned: 500), 300)
    }

    func testUnaccountedClampsAtZeroWhenScannedExceedsCapacity() {
        // Scanned + free > capacity (naive clone double-count) ⇒ honest zero, not negative.
        XCTAssertEqual(SyntheticTile.unaccountedBytes(capacity: 1000, free: 200, scanned: 900), 0)
    }

    // MARK: 2. augment appends without mutating totals

    func testAugmentAppendsSyntheticChildPreservingRootTotals() {
        let r = root(scanned: 500)
        let out = SyntheticTile.augment(root: r, capacity: 1000, free: 200) // residual 300
        // Root's own totals unchanged — "Scanned" must not include the synthetic bytes.
        XCTAssertEqual(out.allocatedBytes, r.allocatedBytes)
        XCTAssertEqual(out.logicalBytes, r.logicalBytes)
        // Exactly one synthetic child appended, after the real children.
        XCTAssertEqual(out.children.count, r.children.count + 1)
        let synth = out.children.last!
        XCTAssertEqual(synth.kind, .synthetic)
        XCTAssertEqual(synth.id, SyntheticTile.unaccountedId)
        XCTAssertEqual(synth.name, SyntheticTile.unaccountedName)
        XCTAssertEqual(synth.allocatedBytes, 300)
        XCTAssertTrue(synth.children.isEmpty, "the unaccounted tile is a leaf — never divable")
    }

    // MARK: 3. no-op cases

    func testAugmentIsNoOpWhenCapacityUnknown() {
        let r = root(scanned: 500)
        XCTAssertEqual(SyntheticTile.augment(root: r, capacity: 0, free: 0), r)
    }

    func testAugmentIsNoOpWhenResidualZero() {
        let r = root(scanned: 900)
        // capacity 1000, free 200 ⇒ residual clamped to 0 ⇒ no tile.
        XCTAssertEqual(SyntheticTile.augment(root: r, capacity: 1000, free: 200), r)
    }

    // MARK: 4. decompose

    func testDecomposeSplitsPurgeableAndUnknown() {
        let (purge, unknown) = SyntheticTile.decompose(unaccounted: 300, purgeable: 120)
        XCTAssertEqual(purge, 120)
        XCTAssertEqual(unknown, 180)
    }

    func testDecomposeClampsUnknownAtZeroWhenPurgeableExceedsResidual() {
        let (purge, unknown) = SyntheticTile.decompose(unaccounted: 100, purgeable: 250)
        XCTAssertEqual(purge, 250, "purgeable is shown verbatim (X = purgeable)")
        XCTAssertEqual(unknown, 0, "unknown never goes negative")
    }
}
