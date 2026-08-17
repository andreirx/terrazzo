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
**ETA HONESTY FOR SUBTREE SCANS** (OPERATOR_NOTE 2026-08-16 #2 item 2,
binding field ruling): the volume-inode denominator is the workload of a
VOLUME-ROOT scan, not of a `~`/subtree scan (dividing a `~` scan by the
volume total produced a nonsense "4h left"). Rule: show progress % + ETA
ONLY when the scan root is the volume root; for a subtree scan show
files/sec + a files-processed count, NO percentage, NO ETA. (Enforced in
the pure `ScanProgress` — `fraction`/`etaSeconds` return nil unless
`isVolumeRoot` — fed by ScanFS `VolumeSkipPolicy.isVolumeRoot`, the same
judgment the FDA banner uses. Root promotion makes the volume-root case
the common one.)
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
Settings pane → rescan); unaccounted-space STATUS-BAR FIGURE (amended
2026-08-16 #1: NEVER a map tile — a volume quantity has no honest
rectangle inside a subtree map) verified against volume accounting;
denied tiles for other users' homes. ACCEPTANCE = the founding use case: map the boot volume as each
user, see where the space disagreement lives, find what Storage Settings
hides. (The founding mystery itself was solved during TZ-2/3 field use —
a stale pinned TM snapshot; TZ-4 makes such answers visible by design.)
Output: the answer to "what is going on."

### TZ-5 — Explorer controls: IGNORE list, depth setting (PROTOTYPE)
Human directive 2026-08-16; RENAMED per human 2026-08-16 (was
"hide/unhide"): the button is **IGNORE**, the ledger is the **Ignore
list**. Ignore button on every sufficiently large tile (same min-width
rule as labels; also in the context menu for small ones): ignoring
excludes the tile from layout so its SIBLINGS renormalize into the freed
area — the giant rectangle retires and the smaller ones get room (the
founding gesture: ignore the known monster, see the long tail). Ignored
tiles appear in a **side-panel Ignore list** (name, size, hue chip);
**ONE CLICK on a list item restores it** as a rectangle (the whole row
is the restore affordance — no separate button); the panel exists only
while non-empty and disappears when depleted.
Hiding is a VISUALIZATION lens only: pure TreemapCore input (hidden path
set), scan tree untouched, session-only (not persisted), and the status
bar shows "N ignored · X GB excluded" while any tile is ignored (the
invisible-space principle applies to user-hidden mass too). Depth setting
UI (default 5) moves here from TZ-4. **Chrome color audit** (human field
report 2026-08-16: dark-grey top bar with near-black barely-visible
text): every text element in the chrome (control bar, status bar, FDA
banner, volume picker, popovers) uses semantic or app-palette colors —
NEVER an unstyled NSTextField default. DURABLE RULE for all App chrome:
text on the dark theme is labelColor-derived or app-palette; hardcoded
blacks are defects. Acceptance: a screenshot pass over every chrome
element at both window sizes; state each element checked. **Scale toggle: SQRT area by default, linear option** (human decision
2026-08-17, superseding log after field use on a second machine: log
flattened 8 orders of magnitude into ~3:1 and its distortion was
magnitude-dependent — a 4KB root file outsized a nested 7GB one; power
laws are the unique scale-invariant monotone family, so equal byte
ratios render as equal area ratios at every depth; sqrt chosen over
x^0.4 by the human for milder compression): weights pass through
sqrt(bytes) before Squarify, per sibling set — pure TreemapCore, tiling exactness
and sibling ordering unchanged (tests reuse). Linear mode shows true
proportional areas ("the HUGE rectangles"). HONESTY GUARD: the active
scale is always visible in the status bar ("Sqrt scale" / "Linear");
labels and hover chips show real bytes in both modes — areas may
compress, numbers never lie. Toggle in the control bar next to the
depth setting. EVIDENCE ITEM: report the below-pixel-culled count on the
SAME scene under sqrt vs linear (quantifies the sibling-starvation
exposure; note in the report that depth-starved tiles are exposed by
ZOOM, not scale — no monotone transform can exceed a parent's pixel
budget, which is why the culled counter legitimately never reaches zero
at root scale). **"Show hidden files and folders"
checkbox, ON by default** (human directive 2026-08-16; VISION amended):
another visualization lens — the scan ALWAYS includes hidden items;
unchecking filters dotfiles/UF_HIDDEN-flagged nodes from layout with the
same status-bar accounting ("dotfiles/hidden filtered · X GB"). Requires
an `isHidden` flag on SizeTree nodes captured by the walker at scan time
(additive DTO change; ScanFS sets it from the URL hidden resource key +
leading-dot rule). Tests: layout with hidden set
(sibling renormalization exactness, ancestors unchanged), hide→unhide
round-trip restores the original layout.

### TZ-6 — Scan performance & scheduling (REORDERED ahead of TZ-5, 2026-08-16)
**Measured facts (operator, 2026-08-16, this machine):** volume has
5,078,381 used inodes; the app's implied rate was ~350 files/s ("4h
left"); a single-threaded Python os.walk+lstat measured 42,258 files/s —
the walker is ~120x slower than a naive baseline. Per-file suspects:
Foundation URL/URLResourceValues per entry (ObjC bridging + multi-syscall
attribute fetches vs one lstat), per-entry id-string/event allocations,
worker contention on the single EventBatcher actor with small batches.
System Settings' Storage is fast because it reads Spotlight/CacheDelete
indexes — a ledger, not a census; fast censuses use getattrlistbulk
(whole-directory attribute batches, the Finder path).
**Scope:** (a) rewrite the walker hot loop on getattrlistbulk (or
fts/readdir+lstat minimum) — no Foundation URL in the per-entry path;
(b) aggregate per-directory before any actor hop (one batch per dir
minimum); (c) THEN the original scheduling work:
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
promotion finds siblings warm or complete. ACCEPTANCE (hard numbers): sustained ≥ 25,000 files/s on the home scan
(5.7x the measured Python baseline is NOT required — parallel Swift
should exceed 42k/s, but 25k/s is the floor); full home scan wall-clock
≤ 3 minutes; state before/after files/s and wall-clock; threading law
untouched (worst main gap < 100 ms during the fast scan).
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

### TZ-9 — Memory law & giant-volume consent (human field report 2026-08-17)
The other machine: 33 GB RSS scanning tens of millions of files —
measured here: ~540 bytes per retained node (full-path String ids as
dict keys, repeated in children arrays, O(depth) growth). LAW (sibling
to the threading law): retained bytes per scanned node ≤ ~100 B, and a
rescan returns RSS to baseline (leak gate: N rescans, footprint flat).
Mechanism: lean node store — name-only strings + parent INDICES,
children as index ranges into one contiguous array, full-path ids
derived on demand at the boundaries (events/FSEvents mapping adapt).
Targets: 5M-node volume ≲ 500 MB; 60M-node TM forest ≲ 6 GB. PLUS
informed consent: the volume picker shows each volume's used-inode
count (statfs, free) and warns before scanning monsters — Time Machine
backup volumes (hardlink forests, detectable) get an explicit "this is
N million entries" confirmation. Acceptance: measured B/node before/
after on a real scan; rescan leak gate; footprint stated at home scale.

### TZ-8 — Glass-pane depth tint (human design 2026-08-17)
The focus level's hue acts as a TRANSLUCENT PANE (~50% alpha at rest,
named constant) over its descendants, whose OWN hues partially show
through even before diving. Diving DISSOLVES the target subtree's pane
in sync with the camera flight (alpha 0.5 → 0 over the flight's t);
ascending re-condenses it (0 → 0.5). The discrete re-tint swap is
replaced by this continuous emergence — depth becomes material.
Mechanism (fits the law by construction): GPUQuad carries TWO colors
(own hue, inherited pane hue) precomputed on the pipeline actor; the
fragment shader blends by ONE uniform driven by the camera flight t —
O(1) per frame on main. Tests: the dissolved endpoint
preserves the ratified hue identities; dissolve monotone in t; the dim
ladder composes with the pane (multiplicative, order stated).
CONTINUITY LAW (refined 2026-08-17 through two review escalates): each
direction must be POP-FREE with TESTED endpoint equalities — the
MECHANISM may differ per scene encoding. Dive: dissolve 0→1 on the
outgoing scene + a brightnessRebase uniform 1→1/dimFalloff (children
gain one focus-relative dim step during the flight — "descending into
the light"); commit rebases to (new scene, t=0) with EXACT per-channel
equality. Ascend: the incoming parent scene's per-instance endpoints
BAKE both looks (flight-start == committed child rest; flight-end ==
parent rest), dissolve 1→0, rebase uniform IDENTITY (the dim step lives
in the baked endpoints — an inverse uniform would double-apply it).
Tests: both handoff equalities within epsilon + monotone luminance
through both flights. Builders never edit this document — mechanism
corrections route through the operator (governance reaffirmed after a
builder edit was reverted).

### TZ-10 — Field batch 2026-08-17 (ten human rulings from live / scan)
1. WATCHLIST replaces Ignore (rename everywhere, name honesty): button
   "Add to Watchlist" (removes the tile from layout exactly as ignore
   did); the WATCHLIST panel is a REAL VISIBLE LIST — every entry a row
   with filename, path relative to its volume, and size; one-click row
   restore stays; EXPORT button writes a plain-text file (one entry per
   line: size <TAB> path; NSSavePanel).
2. Consistent watchlist affordance: the hover button appears under one
   predictable rule (state it; no sometimes-shows), and the context menu
   always carries the action for every level (see item 9).
3. Bottom-left shows ONLY the current enclosing (viewport) folder —
   always, never truncated (middle-truncate only above a generous width),
   and the TZ-4 hover-path replacement behavior is REMOVED (the cursor
   chip already shows hover info).
4. Context-menu items show paths RELATIVE to the current viewport folder
   (including the topmost visible ancestor), not bare filenames.
5. Status bar reduced to: focus path (left) · scan state · a DETAILS
   button. ALL accounting (capacity/free/reclaimable/available/scanned/
   unaccounted decomposition/watchlist exclusion/culled tiles/scale)
   moves into a Details dialog; the dialog also auto-pops once when a
   scan completes.
6. Scale DEFAULT = LINEAR (impact first); sqrt stays as the option.
   (Reverses the sqrt-default half of the 2026-08-17 decision; the
   human: linear's impact "is really driving your attention".)
7. COLOR CASCADE v3: level-1 tiles tint STRONGER (raise pane presence),
   and each level below goes progressively DARKER AND DIMMER while
   inheriting the ancestor tint — a monotone darkening cascade into
   depth (replaces the flat confetti look where all depths compete at
   similar brightness; exact curve = named constants, operator tunes at
   checkpoint with the human).
8. Progress bar STOPS at completion — no indeterminate bounce after
   "done" (field bug: the bar kept animating post-scan).
9. Right-click menu lists the WHOLE ancestor chain under the cursor —
   from the immediate child of the focus down to the deepest hit tile
   (cap: named constant, default 5) — each row with its relative path +
   "Add to Watchlist" + "Show in Finder". (Field bug: UI highlighted the
   top child but the menu acted on the deepest — mismatch resolved by
   showing all levels explicitly.)
10. MCP server exposing the map/watchlist to Claude: EXTENSION POINT
    ONLY, explicitly deferred by the human — NOT in this slice.

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
