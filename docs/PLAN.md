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

## Visual language (amended 2026-08-16, human direction from live use)

- **Hue per top-level tile, RE-TINTED at every focus level** (clarified
  2026-08-16, human: "going into one tinted rectangle, the subfolders get
  THEIR OWN tints — not the parent's"): hue derives DETERMINISTICALLY from
  the folder NAME (hash → hue wheel), and the display rule is
  focus-relative — tiles ONE level below the current focus each show
  their OWN hue; their deeper descendants inherit that level-1 ancestor's
  hue through the dim ladder. Dive into Library and its children get a
  fresh palette; zoom out and the top-level palette returns. Identity
  stays stable: any given folder shows the same hue whenever it is a
  top-level tile, across zooms, rescans, restarts. Medium saturation over
  black; denied/pending keep reserved non-data colors.
- **Tile labels**: every top-level tile (relative to current focus) shows
  its folder name (+ size) as an overlay label, clipped to the tile,
  hidden below a minimum tile width (named constant). Labels re-target on
  zoom (the new top level gets labels).
- **Focus path label at the bottom**: the current focus path as absolute
  path text ("/", then "/Users/apple", "/Users/apple/Library", … growing
  with zoom-in, shrinking on zoom-out), alongside the volume status bar.
- **Status bar speaks plain language** (2026-08-16): fields are
  `Capacity · Free · Reclaimable · Available up to · Scanned` — "Important"
  (the `volumeAvailableCapacityForImportantUsage` API term) never appears
  in the UI; every field has a one-sentence hover tooltip. Verified
  identity on this machine: Available-up-to = Free + Reclaimable
  (513.70 = 124.73 + 388.97) — the two-users free-space discrepancy is
  these two answers to the same question.

## Threading model (ratified 2026-08-16, after the beachball field report)

```
walker tasks (N per top level) ──batches──▶ serial background actor:
                                             reduce → makeTree → squarify →
                                             build immutable RenderScene
                                             (instance arrays, labels data)
                                                      │ one value handoff
                                                      ▼
                                             main actor: input, camera
                                             animation, Metal encode ONLY
```

Law: **nothing on the main thread may scale with node count.** The pure
cores exist precisely so the whole reduce/layout/scene pipeline runs on a
background actor over value types with no locks; main receives finished
immutable scenes. The system beachball is the failure signature of
violating this (there is no spinner in the app; macOS shows the wait
cursor when main stalls ≥ ~2 s) — any beachball during scan is a bug by
definition.

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
- **Navigation is never gated on scan completion** (reaffirmed 2026-08-16
  after a TZ-3 field regression showed a blocking spinner): hover, dive,
  zoom-out, and Finder actions work at all times during an active scan;
  on-demand depth-detail extension is async events into the live map —
  a modal spinner or blocked input anywhere in the scan path is a
  constraint violation, not a UX choice.

## Ratified decisions (human, 2026-08-12)

1. **Allocated size is the primary metric** (tile area = allocated bytes;
   logical shown in hover detail). The map must reconcile against volume
   accounting — that is the founding purpose.
2. **Hard links / APFS clones: count naively in v1.** Recorded debt with a
   named trigger: dedup-by-inode pass when scanned totals visibly exceed
   volume used space (the unaccounted tile going negative is the signal).
3. **Relayout batched ~1 s, animated** (named constant; operator tuning
   latitude at checkpoints). Per-event relayout is forbidden (jitter).
4. **Sizes true, detail windowed.** The scanner always descends fully —
   every size on screen is the real recursive total; the depth setting
   (default 5) limits only retained/rendered child DETAIL below the current
   focus, extended on demand when zooming.
5. **Per-top-level-folder parallel scanning** (human addition): each
   top-level folder of the scan root gets its own concurrent worker so ALL
   top-level tiles show progress simultaneously — no sequential DFS where
   one folder monopolizes the map. Workers emit subtree-tagged ScanEvents
   into the single reducer; the reducer stays pure and single-threaded
   (events are the concurrency boundary).

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
**Scan progress bar — BY FILE COUNT** (human directive 2026-08-16,
superseding same-day byte/persistence draft): progress =
filesProcessed / volume used-inode count (statfs `f_files − f_ffree`,
available at t=0, zero cost, zero persistence — the earlier
`scan-history.json` idea is RETRACTED, nothing is persisted). Rationale
(human): scan TIME is spent per inode, not per byte — one stat for a
10 GB movie, thousands for a cache dir — so a file-count bar tracks
actual remaining work and yields an honest ETA. Show a rolling
files/sec-derived ETA next to the bar. Known approximation, displayed
as such: the denominator is volume-wide (includes denied/other-user
files), so the bar may complete below 100% — clamp and snap to done on
completion; never fake linearity.
VolumePicker (all mounted volumes); **root promotion** (refined
2026-08-16, superseding "default /"): scans start at `~` for fast first
paint, and zooming out AT the scan root promotes it one level
(`/Users/apple` → `/Users` → `/`) — the existing tree grafts as a child
of the new root (nothing discarded), only new siblings scan, the camera
animates the old map shrinking into its parent tile; repeatable to the
volume root; **Rescan button** in the
toolbar/status area (human directive 2026-08-16 — the map is a snapshot of
scan time; rescan re-runs the current volume+focus scan, streaming as
usual); root scan with FDA guided flow (probe → explain → open System
Settings pane → rescan); unaccounted-space tile verified against volume
accounting; denied tiles for other users' homes. ACCEPTANCE = the founding use case: map the boot volume as each
user, see where the space disagreement lives, find what Storage Settings
hides. (The founding mystery itself was solved during TZ-2/3 field use —
a stale pinned TM snapshot; TZ-4 makes such answers visible by design.)
Output: the answer to "what is going on."

### TZ-5 — Explorer controls: hide/unhide, depth setting (PROTOTYPE)
Human directive 2026-08-16. **Hide** button on every sufficiently large
tile (same min-width rule as labels; also in the context menu for small
ones): hiding excludes the tile from layout so its SIBLINGS renormalize
into the freed area (LOCAL renormalization — operator decision: the rest
of the map stays stable; ancestors keep their areas). Hidden tiles appear
in a **side panel ledger** (name, size, hue chip, UNHIDE button each);
the panel exists only while non-empty and disappears when depleted.
Hiding is a VISUALIZATION lens only: pure TreemapCore input (hidden path
set), scan tree untouched, session-only (not persisted), and the status
bar shows "N hidden · X GB excluded" while any tile is hidden (the
invisible-space principle applies to user-hidden mass too). Depth setting
UI (default 5) moves here from TZ-4. **"Show hidden files and folders"
checkbox, ON by default** (human directive 2026-08-16; VISION amended):
another visualization lens — the scan ALWAYS includes hidden items;
unchecking filters dotfiles/UF_HIDDEN-flagged nodes from layout with the
same status-bar accounting ("dotfiles/hidden filtered · X GB"). Requires
an `isHidden` flag on SizeTree nodes captured by the walker at scan time
(additive DTO change; ScanFS sets it from the URL hidden resource key +
leading-dot rule). Tests: layout with hidden set
(sibling renormalization exactness, ancestors unchanged), hide→unhide
round-trip restores the original layout.

### TZ-6 — Scan scheduling: hierarchical spawning + anticipatory root scan
Human design 2026-08-16 (after reading the walker's task model). Today:
one task per top-level folder, sequential DFS inside — finished siblings'
pool threads idle while one giant subtree (~/Library) grinds in a single
task. (a) HIERARCHICAL SPAWNING: walkDirectory spawns child-dir subtasks
to a bounded depth (~2-3 levels or child-count threshold; guardrail
against task-overhead explosion), sequential below — Swift's cooperative
pool then work-steals automatically ("finished threads help out" with
zero pool-management code). (b) ANTICIPATORY ROOT SCAN: alongside the ~
scan, one .utility-priority task walks / EXCLUDING the active scan root
(shares promotion's scan-X-excluding-grafted-Y machinery) so zoom-out
promotion finds siblings warm or complete. Acceptance: wall-clock home
scan improves measurably (state before/after); threading law untouched.
DISJOINTNESS INVARIANTS (human question 2026-08-16 — why nothing is ever
walked twice): (1) one enumeration point (classifyChildren), called once
by a directory's single owner; (2) ownership transfers exclusively at
enumeration — a parent never descends into a delegated child; stealing
picks up unstarted subtasks, never splits a directory; (3) symlinks never
followed; (4) ONE SCAN = ONE DEVICE: any child whose st_dev differs from
the scan root's is a boundary stub, never entered (kills the
/System/Volumes/Data firmlink double-count, /Volumes mounts, network
mounts); (5) a concurrent anticipatory scan excludes the active scan
root by emitting a graft reference at its enumeration point.

### TZ-7 — The living map: staleness detection and live updates
Human field report 2026-08-16 (deleted a folder; its tile persisted).
Tier 1 (near-free): store each directory's mtime in SizeTree at scan
time; revalidate the FOCUS directory with ONE stat on focus change, app
activation, and a lazy idle timer — mtime unchanged ⇒ listing current;
changed ⇒ re-enumerate that one directory and diff. Tier 2 (the real
mechanism): an FSEvents recursive subscription on the scan root —
kernel-coalesced change notifications per directory; each event
re-enumerates the touched directory and emits diff events. New additive
ScanCore vocabulary: childRemoved (+ subtree prune; sizes ripple up).
The reducer/pipeline consume diffs exactly like scan events — the map
updates live without rescan. Manual Rescan (TZ-4) remains the
full-truth fallback. ALL revalidation is async events — never blocks
navigation (the law).

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
