# Terrazzo

A macOS app that shows **where your disk space actually is** — a live,
zoomable, nested treemap (the finviz-heatmap look) of any volume, from the
root down: every folder a rectangle proportional to its size, children
tiling their parent, each level dimmer, hidden folders included, unreadable
and unaccounted space rendered honestly instead of omitted.

Born from a real mystery: the same Mac showing different free space to two
different users. Terrazzo exists to answer "what is actually on this disk,
who can see it, and what can't I see?"

Two strictly separated engines:
- **Scan engine** — `ScanCore` (pure domain: size tree, streaming event
  reducer, policies) + `ScanFS` (the only code that touches the disk)
- **Visualization engine** — `TreemapCore` (pure: squarified layout, nested
  dimming, hit-testing, animated focus camera) + a thin AppKit/Metal shell

They meet at one DTO (`SizeTree`); either is replaceable without the other
noticing.

## Status

Speccing / early implementation. See `docs/VISION.md` and `docs/PLAN.md`.

## Build & run (personal use)

Requires Xcode Command Line Tools (plus Xcode present for the test runner).

```bash
scripts/test.sh      # core tests (headless)
scripts/build.sh     # → build/Terrazzo.app
scripts/run.sh       # build + open
```
