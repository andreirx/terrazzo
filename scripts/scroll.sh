#!/usr/bin/env bash
# scroll.sh — scroll-to-zoom regression check (TZ-10 OPERATOR_NOTE 2026-08-17 C).
# Module maturity: PROTOTYPE.
#
# Compiles scripts/scroll_host.swift with the App navigation stack (the same monolith
# arrangement as threads.sh) and drives the REAL NavigationController.canvasDidScroll with
# notch + trackpad deltas over a real scan — no window, no synthetic OS input (conduct rule).
# It asserts scroll-IN dives and scroll-OUT ascends from the focus-path state alone, catching
# the field regression "scrolling no longer zooms" (OPERATOR_NOTE C).
#
# EVIDENCE + regression check — run it bare; check the TZSCROLL verdict and the exit code
# (0 = PASS, non-zero = the scroll accumulation / dive-ascend posts regressed).
#
#   scripts/scroll.sh [rootDir] [maxSeconds]     # defaults: repo Sources, 30
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/xcode_env.sh"
resolve_developer_dir

BIN="build/scroll_host"
SCAN_ROOT="${1:-$ROOT/Sources}"
MAX_SECONDS="${2:-30}"

mkdir -p build

echo "==> Compile the scroll regression host (real NavigationController + walker + pipeline)"
swiftc \
	-O \
	-o "$BIN" \
	scripts/scroll_host.swift \
	Sources/App/CanvasView.swift \
	Sources/App/NavigationController.swift \
	Sources/App/WatchlistPanel.swift \
	Sources/App/ScanController.swift \
	Sources/App/QuadRenderer.swift \
	Sources/App/HitchMonitor.swift \
	Sources/App/StatusBar.swift \
	Sources/App/FinderActions.swift \
	Sources/RenderPipeline/*.swift \
	Sources/ScanFS/*.swift \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	-framework AppKit \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-framework CoreGraphics \
	-target arm64-apple-macos14

echo "==> Drive scroll gestures on the REAL NavigationController over $SCAN_ROOT (cap ${MAX_SECONDS}s)"
# TERRAZZO_TRACE emits the TZTRACE dive/ascend lines so the posts are visible; TERRAZZO_SHADER_PATH
# lets the windowless CanvasView find the shader source with no .app bundle.
TERRAZZO_TRACE=1 \
TERRAZZO_SHADER_PATH="$ROOT/Sources/App/Shaders.metal" \
	"$BIN" "$SCAN_ROOT" "$MAX_SECONDS"
