# Terrazzo — Vision

## What this is

A native macOS application that shows **where your disk space actually is** —
as a live, zoomable, nested **treemap** (Shneiderman; squarified per Bruls et
al.): a black canvas where every folder is a rectangle sized by its disk
footprint — shown in **linear true-proportion by default** (TZ-10, ratified
2026-08-17: the map's default must not distort real byte proportions), with
a **sqrt-compressed mode** one toggle away (power-law scale-invariance;
ratified 2026-08-17, superseding log — see PLAN §TZ-5) so giants cannot
eclipse the long tail when the user chooses it. The active scale is always
labeled and the NUMBERS on tiles are always real bytes (amended 2026-08-16)
— children tiling their parent, each
nesting level drawn progressively dimmer. The finviz-heatmap look, applied to your
filesystem, from the volume root down.

The founding use case is real (2026-08-12): the author's Mac shows
**different free space to two different users**, after a history of aerial
screensaver downloads quietly consuming space in system-wide caches. Finder
and Storage Settings failed to explain it. Terrazzo exists so that question
— *"what is actually on this disk, who can see it, and what can't I see?"* —
has a visual, navigable answer.

## Core principle: invisible space is first-class

A disk map that silently omits what it cannot read **cannot explain a
free-space mystery**. Terrazzo renders:

- **Hidden files and folders** — always scanned, and shown by default
  (`~/Library`, `/Library`, `/private`, dotfiles). Surfacing the paths
  "typically hidden from users' view" is the product. (Amended 2026-08-16:
  a display checkbox "Show hidden files and folders" exists, ON by
  default — a visualization filter only; the scan always includes them,
  and filtered-out mass is accounted in the Details dialog (TZ-10 moved
  the full accounting off the status bar), never silently dropped.)
- **Denied space** — directories the scan cannot enter (other users' homes,
  TCC-protected areas) render as visibly distinct tiles sized by what the
  volume accounting implies, never dropped.
- **Unaccounted space** — a per-volume figure in the Details dialog
  (amended 2026-08-16, human field ruling: the earlier synthetic map tile
  rendered a volume-level quantity inside a subtree map — a category error,
  retracted; TZ-10 further moved the figure off the status bar into the
  Details dialog): `capacity − free − scanned total`, decomposed as
  purgeable + other-users/unknown. The number is always shown; it is never
  drawn as a rectangle pretending to be a folder.
- **Purgeable vs free** — the Details dialog shows capacity, free, and
  purgeable (the APFS quantity that makes "available space" differ between
  contexts and users) via both `volumeAvailableCapacity` and
  `volumeAvailableCapacityForImportantUsage`. The bottom bar keeps only the
  founding "Free X of Y capacity" figure one glance away (TZ-10, OPERATOR_NOTE A).

## The two engines (ratified separation)

1. **Scan engine** (`ScanCore` pure + `ScanFS` I/O adapter): walks a volume,
   computes folder sizes, **streams partial results** — the map must be
   usable while scanning. Pure domain (tree model, event reducer, policies)
   never touches the filesystem; every syscall lives in the adapter.
2. **Visualization engine** (`TreemapCore` pure + `App` shell): consumes only
   the `SizeTree` DTO; squarified layout, nested dimming, hit-testing,
   animated focus camera. Knows nothing about filesystems.

Either engine must be replaceable without the other noticing. The `SizeTree`
DTO is the single crossing point.

## Experience

1. Launch → pick a volume (or default to the boot volume root). The bottom
   bar shows "Free X of Y capacity"; the Details dialog holds the full
   accounting (capacity / free / purgeable / unaccounted).
2. The canvas fills progressively as the scan streams: top-level folders as
   bright rectangles, 2nd level dimmer inside them, 3rd dimmer still —
   default **depth 5** visible/scanned (setting).
3. Mouse hover highlights the top-level rectangle under the cursor (lights
   up; name + size shown).
4. Click (or scroll-in) **zooms into that folder**: animated refocus, the
   folder fills the canvas, its subfolders become the bright top level, and
   the visible depth window slides one level deeper (scan extends as
   needed). Scroll-out / back animates the reverse.
5. Right-click / keyboard: **Open in Finder** on any tile. `.app` bundles
   are leaf tiles (size only — sufficient by ratified decision 2026-08-12)
   and open in Finder like any tile.
6. Partial data is normal: pending tiles render as such and refine as
   events arrive; relayout is batched/animated, never jittering per-event.

## What it is NOT (v1)

- **Not a cleaner.** No delete, no move — Open in Finder is the action
  escape hatch. (Deletion is a named extension, gated on undo-safety
  thinking, not a v1 feature.)
- **Not sandboxed, not distributed.** Personal tool; unsandboxed so it can
  actually see the disk; Full Disk Access granted manually with an in-app
  guided flow (probe → detect denial → open the System Settings pane).
- **Not a duplicate finder / analyzer suite.** One job: truthful spatial
  map of disk usage.

## Constraints

1. **Dependencies point inward.** `ScanCore` and `TreemapCore` are pure
   Swift (Foundation value types only — no AppKit, no Metal, no
   FileManager); exercised headless by `swift test`. `ScanFS` and `App` are
   the only I/O/UI layers.
2. **Files are the system of record** — repo fully determines the build; no
   generated state outside `build/`, no runtime persistence. (A same-day
   2026-08-16 progress-cache exception was proposed and RETRACTED: the
   progress denominator comes free from statfs used-inode counts, so
   nothing needs persisting.)
3. **Streaming is the contract**: the scan API is an event stream; "wait
   until done then draw" is a forbidden simplification.
4. **Name honesty** — a tile that means "denied" is named and rendered
   `denied`, not approximated into ordinary data.

## Named extension points (deferred, not designed for)

- **Root-privileged scan mode** (2026-08-16): exact sizing of other
  users' files requires root — FDA bypasses TCC, never POSIX 700 homes.
  Until then: the unaccounted−purgeable residual estimates the aggregate,
  and each user scanning their own session covers their territory.
- Deletion / cleanup actions (undo-safety design required first).
- Snapshot/purgeable deep inspection (tmutil integration).
- Hard-link/clone dedup accuracy pass (v1 policy set at ratification).
- Distribution (signing/notarization) if it ever leaves this machine.
