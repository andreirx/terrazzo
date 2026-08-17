//
//  WatchlistExport.swift — the plain-text Watchlist export FORMAT (pure, testable).
//  Module maturity: PROTOTYPE (slice TZ-10)
//
//  TZ-10 item 1 (human field ruling 2026-08-17): the Watchlist panel's EXPORT button writes a
//  plain-text file — one entry per line, `SIZE<TAB>/path`, with a header line naming the volume
//  and the date. The packet is explicit that the FORMATTING is a "pure formatting function in
//  TreemapCore/RenderPipeline (testable); AppKit only presents the panel". So this owns the file
//  LAYOUT (the load-bearing, greppable/sortable contract) with NO AppKit; the App only runs the
//  NSSavePanel and writes the returned string.
//
//  SIZE IS RAW BYTES (name honesty + determinism). The rows carry the exact on-disk byte count,
//  not a locale-formatted "4.2 GB": a plain-text export is for tooling (sort -rn, awk), the raw
//  integer is unambiguous and lossless, and — unlike `ByteCountFormatter` — it is locale- and
//  platform-independent, so the pure test is deterministic. The panel still SHOWS human sizes;
//  the export is the machine-readable twin.
//
//  ABSTRACTION LEDGER: a namespace of one pure static func + a raw `Row` DTO. Concrete users:
//  `NavigationController` (builds rows from the watchlist, presents the save panel) +
//  `WatchlistExportTests`. Axis of variation: none — one fixed line format. Rejected simpler
//  alternative: format the whole file in the App — untestable (App is not an SPM target) for a
//  contract the packet explicitly requires be testable.
//

public enum WatchlistExport {
    /// One export row: the entry's exact on-disk bytes + its path relative to the volume
    /// (`RelativePath.of(id, under: volumeRoot)`), without a leading slash — this function adds it.
    public struct Row: Equatable, Sendable {
        public let bytes: Int64
        public let relativePath: String
        public init(bytes: Int64, relativePath: String) {
            self.bytes = bytes
            self.relativePath = relativePath
        }
    }

    /// The full file text: one header line (volume + date), then one `bytes<TAB>/path` line per
    /// row, LARGEST FIRST (the monster you watchlisted on top, matching the panel order), and a
    /// trailing newline. `volume`/`date` are caller-formatted strings (the App owns locale/date
    /// presentation); everything below the header is deterministic.
    public static func text(volume: String, date: String, rows: [Row]) -> String {
        var lines = ["# Terrazzo watchlist — \(volume) — \(date)"]
        for r in rows.sorted(by: { $0.bytes > $1.bytes }) {
            let p = r.relativePath.hasPrefix("/") ? r.relativePath : "/" + r.relativePath
            lines.append("\(r.bytes)\t\(p)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
