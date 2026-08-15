# Terrazzo — Project Instructions

## Read order

1. `docs/VISION.md` — what this is and the invisible-space principle
2. `docs/PLAN.md` — architecture, slices, open decisions
3. This file — execution rules

## Hard constraints

1. **Two engines, one crossing point.** `ScanCore`+`ScanFS` (scanning) and
   `TreemapCore`+`App` (visualization) meet ONLY at the `SizeTree` DTO.
   Core libs (`ScanCore`, `TreemapCore`) are pure Swift — Foundation value
   types only; no FileManager, no AppKit, no Metal. All syscalls in
   `ScanFS`; all UI/GPU in `Sources/App/`.
2. **Invisible space is first-class.** `denied`, `pending`, and
   `unaccounted` are rendered states, never silent omissions. A tile kind
   that means "we don't know" must SAY "we don't know".
3. **Streaming is the contract.** The scan API is an event stream; the map
   works on partial data. "Scan fully, then draw" is forbidden.
4. **Files are the system of record.** No hidden state; no caches in v1.
5. **Name honesty.** Names must match verified behavior; ported patterns
   cite their source (glyph-saver / ZapZap heritage where applicable).

## Build & gates (imported lessons — do not relearn)

- `scripts/test.sh` wraps
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  (CLT has no XCTest). A green run MUST show a nonzero executed-test count.
- Gates run BARE — never piped, never chained with a commit. Check `$?`
  per command.
- Metal shaders compile at runtime (`makeLibrary(source:)`).
- The app window survives input (unlike a screensaver) — live window
  screenshots are legitimate additional evidence; the deterministic gate is
  offscreen fixture-frame rendering in `scripts/verify.sh`.
- Builders: do NOT commit. The operator commits deliverables after review.

## Module maturity

Declare in header comments: PROTOTYPE (contracts moving) → MATURE (breaking
changes need a decision record) → PRODUCTION. Everything starts PROTOTYPE.

## Storage

Tracked: `Sources/`, `Tests/`, `docs/`, `scripts/`, `Package.swift`.
Gitignored: `build/`, `.build/`, `.agent-manager/`, `.DS_Store`.
