//
//  WatchlistExportTests.swift — the plain-text Watchlist export format (TZ-10 item 1).
//  Module maturity: PROTOTYPE (slice TZ-10)
//

import XCTest
@testable import TreemapCore

final class WatchlistExportTests: XCTestCase {
    /// One header line (volume + date), then one `bytes<TAB>/path` row per entry, LARGEST FIRST,
    /// path leading-slash-prefixed, with a trailing newline. Deterministic (raw bytes, no locale).
    func testExportLayoutHeaderTabRowsSortedLargestFirst() {
        let rows = [
            WatchlistExport.Row(bytes: 300, relativePath: "Users/apple/small"),
            WatchlistExport.Row(bytes: 9_000, relativePath: "Users/apple/big"),
            WatchlistExport.Row(bytes: 1_500, relativePath: "Users/apple/mid"),
        ]
        let text = WatchlistExport.text(volume: "Macintosh HD", date: "2026-08-17", rows: rows)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "# Terrazzo watchlist — Macintosh HD — 2026-08-17")
        // Sorted largest-first; SIZE<TAB>/path; leading slash added.
        XCTAssertEqual(lines[1], "9000\t/Users/apple/big")
        XCTAssertEqual(lines[2], "1500\t/Users/apple/mid")
        XCTAssertEqual(lines[3], "300\t/Users/apple/small")
        XCTAssertTrue(text.hasSuffix("\n"), "trailing newline so the file ends cleanly")
        // Each data row is exactly SIZE<TAB>PATH — one tab, two fields (greppable/sortable).
        for row in lines[1...3] {
            let fields = row.split(separator: "\t")
            XCTAssertEqual(fields.count, 2, "one tab separating raw bytes from the path")
            XCTAssertNotNil(Int64(fields[0]), "SIZE is raw bytes (locale-free, sortable)")
            XCTAssertTrue(fields[1].hasPrefix("/"), "path is leading-slash-prefixed")
        }
    }

    /// An already-slash-prefixed path (the non-descendant absolute fallback from RelativePath) is
    /// not double-slashed.
    func testAbsoluteFallbackPathNotDoubleSlashed() {
        let text = WatchlistExport.text(volume: "V", date: "D",
                                        rows: [WatchlistExport.Row(bytes: 1, relativePath: "/abs/x")])
        XCTAssertTrue(text.contains("1\t/abs/x"))
        XCTAssertFalse(text.contains("//abs/x"), "no double slash on an already-absolute path")
    }

    /// A header even with no rows (an empty watchlist should never crash the exporter).
    func testEmptyExportIsJustTheHeader() {
        let text = WatchlistExport.text(volume: "V", date: "D", rows: [])
        XCTAssertEqual(text, "# Terrazzo watchlist — V — D\n")
    }
}
