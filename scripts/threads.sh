#!/usr/bin/env bash
# threads.sh — TZ-3b threading evidence over a REAL scan, driving the REAL
# NavigationController (no window, no synthetic input). Module maturity: PROTOTYPE.
#
# Compiles scripts/thread_host.swift with the App navigation stack (CanvasView,
# NavigationController, ScanController, QuadRenderer, HitchMonitor, StatusBar,
# FinderActions — everything EXCEPT the app entry point main.swift and AppDelegate)
# plus RenderPipeline + the real walker (ScanFS) + the two cores, into one swiftc
# binary linking AppKit + Metal. It then drives a real directory scan while calling
# dive()/ascend() on the real controller, and reports the HitchMonitor's worst
# MAIN-THREAD gap during the scan (target < 100 ms) plus scene-generation flow.
#
# EVIDENCE, not a deterministic gate — intentionally NOT wired into verify.sh (which
# must stay fast + deterministic). Run it bare; check the printed WORST MAIN-THREAD
# GAP and the PASS verdict.
#
#   scripts/threads.sh [rootDir] [maxSeconds]     # defaults: $HOME, 180
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/xcode_env.sh"
resolve_developer_dir

BIN="build/thread_host"
SCAN_ROOT="${1:-$HOME}"
MAX_SECONDS="${2:-180}"

mkdir -p build

echo "==> Compile the threading-evidence host (real NavigationController + walker + pipeline)"
swiftc \
	-O \
	-o "$BIN" \
	scripts/thread_host.swift \
	Sources/App/CanvasView.swift \
	Sources/App/NavigationController.swift \
	Sources/App/IgnorePanel.swift \
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

echo "==> Drive the REAL NavigationController over $SCAN_ROOT (cap ${MAX_SECONDS}s) — no window, no synthetic input"
# TERRAZZO_HITCH turns on the HitchMonitor (the main-thread heartbeat); TERRAZZO_TRACE
# emits TZTRACE dive/ascend lines from NavigationController; TERRAZZO_SHADER_PATH lets
# the windowless CanvasView find the shader source with no .app bundle.
TERRAZZO_HITCH=1 \
TERRAZZO_TRACE=1 \
TERRAZZO_SHADER_PATH="$ROOT/Sources/App/Shaders.metal" \
	"$BIN" "$SCAN_ROOT" "$MAX_SECONDS"
