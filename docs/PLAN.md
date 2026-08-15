# Terrazzo — Implementation Plan

Status: DRAFT pending ratification of the open decisions below; tree
structure and engine separation ratified 2026-08-12. This will be the
`sliceDoc` for slices TZ-1…TZ-4.

## Toolchain (verified on this machine — inherited from glyph-saver, 2026-08-12)

- macOS 26.6.1 arm64, Swift 6.2.3 via CLT; `swiftc` app-bundle builds work
  without full Xcode. Tests REQUIRE
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  (CLT ships no XCTest) — `scripts/test.sh` wraps it; a green run must show
  a NONZERO executed-test count.
- Gates run bare, exit codes checked individually, never piped, never
  chained with commits (operator law).
- This is an APP, not a saver: the window survives user input, so live
  screenshots are legal evidence — verification is strictly easier than
  glyph-saver's. Keep the offscreen-frame seam for deterministic gates;
  `screencapture` of the app window is additional evidence, not the gate.
- Metal: runtime shader compile (`makeLibrary(source:)`) — no Metal
  toolchain needed at build time (same as glyph-saver).

## Architecture

Two pure cores, two thin outer layers, one crossing DTO:

```
ScanCore   (SPM lib, pure)  SizeTree DTO, ScanEvents + reducer, ScanPolicy
ScanFS     (I/O adapter)    parallel walker → ScanEvents; volume enumeration
                            (statfs / URLResourceValues incl. purgeable);
                            FDA probe; ALL APFS quirks (firmlinks, symlink
                            no-follow, /System overlap) contained here
TreemapCore(SPM lib, pure)  Squarify, TreemapScene (tree+focus+depth+viewport
                            → rect DTOs with dim level), FocusCamera
                            (anticipatory keyframes + C1 — the glyph-saver
                            GS-3 pattern), HitTest
App        (AppKit+Metal)   window/menu shell, CanvasView (CAMetalLayer +
                            input), QuadRenderer (instanced rects — ZapZap/
                            glyph-saver heritage), FinderActions,
                            VolumePicker
```

Abstraction ledger:
- `ScanCore`/`ScanFS` split — users: reducer unit tests (dry) + real walker;
  axis: filesystem volatility (APFS quirks) isolated from domain logic;
  simpler alternative rejected: walker-computes-everything (untestable
  without disk, mystery-explaining logic buried in I/O).
- `SizeTree` DTO — the ratified boundary between engines (VISION).
- `FocusCamera` — proven pattern reuse, not new abstraction.
- Nothing else. No renderer protocol, no plugin system, no persistence
  layer (rescan is cheap; no cache in v1 — recorded as possible debt).

## Rendering scale

Depth-5 tree of a full disk ≈ 10⁴–10⁶ rects. Instanced quads in one draw
call; dim level = per-instance color multiplier; highlight = instance flag.
Cull rects < ~2 px (record count culled — no silent truncation: the status
line shows "N tiles below pixel size").

## Progressive data (the hard part, ratified approach)

- Walker emits `ScanEvents` (childDiscovered, sizeUpdated, denied,
  completed) batched.
- Reducer folds events into the SizeTree; the scene relayouts on a
  **batched cadence (~1 s) with camera-animated transitions**, never
  per-event — treemap jitter is the known failure mode of naive streaming.
- Tiles carry scan state (pending/partial/complete/denied) → rendered
  distinctly (pending = outlined dim, denied = hatched/distinct color).

## Open decisions (ratify before TZ-2 — will be presented problem-first)

1. **Allocated vs logical size as the primary metric.** Recommendation:
   allocated (explains free space, the founding mystery); logical shown in
   the hover/status detail.
2. **Hard links / APFS clones.** v1 recommendation: count naively, record
   TD (dedup-by-inode pass as extension). Cheap, slightly over-counts.
3. **Relayout cadence value** (~1 s start, operator latitude).
4. **Depth-scan semantics**: scan computes FULL sizes to unlimited depth
   (sizes must be true), but only maintains child detail to depth N
   (default 5) below the current focus; zooming extends detail on demand.
   (Sizes true, detail windowed — recommendation; the alternative
   "sizes only to depth N" would make every ancestor size a lie.)

## Slices

Gates every slice: `scripts/test.sh` (count must grow), `scripts/build.sh`
exit 0 → `build/Terrazzo.app`, `scripts/verify.sh` exit 0 (offscreen fixture
frames differ + named output surface), operator visual review, human glance.

### TZ-1 — App shell + treemap of a fixture tree (PROTOTYPE)
Window + menu + quit; Metal canvas; `TreemapCore` (Squarify + Scene + dim
ladder) rendering a HARDCODED fixture SizeTree (from a JSON fixture, no
scanning) with nested dimming to depth 5. Tests: tiling exactness (children
areas sum to parent, no overlap/gap — assert numerically), area
proportionality, aspect-ratio bound, dim ladder. Output surface: the app
opens showing the nested map of the fixture.

### TZ-2 — The scanner, live (PROTOTYPE)
`ScanCore` (events, reducer, policy — dry-tested) + `ScanFS` walker
(parallel, streaming, hidden-included, symlink no-follow, bundle-leaf,
denied detection) + fixture-directory integration tests. Wire to canvas:
scanning ~ (home) fills the map progressively; batched relayout; pending/
denied tile rendering; volume header (capacity/free/purgeable/unaccounted).
Requires decisions 1–4 ratified. Output: watch your home directory
materialize as a map.

### TZ-3 — Navigation (PROTOTYPE)
Hover highlight + name/size readout; click / scroll-in zooms into a folder
(FocusCamera animated refocus; depth window slides deeper; scan detail
extends on demand); scroll-out / Esc zooms out; breadcrumb path; Open in
Finder (right-click + ⌘R) on any tile incl. bundle leaves. Output: navigate
your disk fluidly.

### TZ-4 — Volumes, root, and the mystery (PROTOTYPE → acceptance)
VolumePicker (all mounted volumes); root scan with FDA guided flow (probe →
explain → open System Settings pane → rescan); depth setting UI (default 5);
unaccounted-space tile verified against volume accounting; denied tiles for
other users' homes. ACCEPTANCE = the founding use case: map the boot volume
as each user, see where the space disagreement lives, find what the
Storage-Settings view hides. Output: the answer to "what is going on."

## Slice → relay mapping

Same operator loop as glyph-saver: bootstrap
`.agent-manager/slices/TZ-n/{selection.md,selection.json,status.json}`,
builder claude (claude-opus-4-8, high) / supervisor codex (gpt-5.6-terra),
`npm run relay-target -- ../terrazzo --slice TZ-n --max-iter 3 --timeout 30`,
checkpoint every ≤3 cycles, operator commits deliverables on approval.

## Deliberately deferred

- Deletion/cleanup (undo-safety design first), scan-result cache/persistence,
  snapshot & purgeable deep-dive (tmutil), hard-link dedup pass,
  distribution signing.
