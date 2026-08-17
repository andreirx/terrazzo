# Terrazzo — Project Instructions

## Read order

1. `docs/VISION.md` — what this is and the invisible-space principle
2. `docs/PLAN.md` — architecture, slices, open decisions
3. This file — execution rules

## Hard constraints

1. **Two engines, one crossing point, one composition layer.**
   `ScanCore`+`ScanFS` (scanning) and `TreemapCore` (visualization math)
   meet ONLY at the `SizeTree` DTO. Core libs are pure Swift — Foundation
   value types only; no FileManager, no AppKit, no Metal. All syscalls in
   `ScanFS`; all UI/GPU in `Sources/App/`.
   **`RenderPipeline`** (ratified 2026-08-16, human decision
   pipeline-module-boundary) is the ONLY module allowed to import both
   cores: a PURE COMPOSITION layer hosting the background pipeline actor
   (reduce → tree → layout → immutable RenderScene). Charter, enforced by
   review token-search every slice: zero I/O, zero AppKit/Metal/ScreenSaver
   imports; composes the engines only through `SizeTree`; the cores never
   import it; `App` shrinks to instantiation, input, and Metal encode.
   Anything beyond composition drifting into RenderPipeline is a
   boundary violation.
2. **Invisible space is first-class.** `denied`, `pending`, and
   `unaccounted` are rendered states, never silent omissions. A tile kind
   that means "we don't know" must SAY "we don't know".
3. **Streaming is the contract.** The scan API is an event stream; the map
   works on partial data. "Scan fully, then draw" is forbidden.
4. **Files are the system of record.** No hidden state; no caches in v1.
5. **Name honesty.** Names must match verified behavior; ported patterns
   cite their source (glyph-saver / ZapZap heritage where applicable).
6. **THE MEMORY LAW** (ratified 2026-08-17, TZ-9, sibling to the threading
   law — after a 33 GB RSS field report on a tens-of-millions-inode
   machine): Retained memory per scanned node ≤ ~100 B amortized; a rescan
   returns footprint to baseline. Anything that scales worse is a defect.
   STATUS (honest, 2026-08-17): the law is the TARGET, not yet the
   achieved state. Phase A shipped and measured: 534 B/node (was 624);
   rescan leak gate green. Phase B (derive Node.id from parent-chain
   names — the ~200 B/node whale) is OPEN: three builder cycles failed
   to land it (strain recorded for the human). Until it lands, the
   giant-volume consent screen is the field protection. Claiming the
   law as achieved would be the appearance of a guarantee without the
   guarantee — prohibited.

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

## Builder conduct on the live desktop (binding, 2026-08-16)

Builders must NEVER post synthetic input events (CGEvent, System Events
keystrokes/clicks) or activate/raise windows — the human works on this
machine and cycle-4's e2e harness moved their real mouse. Evidence comes
from: unit tests, offscreen verify frames, direct programmatic driving of
controllers (no window), trace logs, and timing measurements. Live
interaction evidence belongs to the operator and the human.
