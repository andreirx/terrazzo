#!/usr/bin/env bash
# chrome.sh — headless chrome COLOR AUDIT gate (TZ-5 deliverable 5, review-0 change 5).
# Module maturity: PROTOTYPE (slice TZ-5)
#
# Compiles the REAL App chrome sources (minus main.swift, whose top-level entry is replaced
# by scripts/chrome_host.swift's @main) together with the cores + ScanFS + RenderPipeline —
# the same monolith arrangement as build.sh — then runs the offscreen audit. NO window is
# ever shown/activated (chrome_host runs NSApplication at .prohibited); this is the
# conduct-safe substitute for a live two-size screenshot pass.
#
# Run BARE, check the exit code (CLAUDE.md Gates).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST_BIN="build/chrome_host"
mkdir -p build
rm -f build/chrome-*.png

# App chrome sources EXCEPT main.swift (its top-level code would collide with the host's @main).
APP_SRCS=()
for f in Sources/App/*.swift; do
	[[ "$f" == "Sources/App/main.swift" ]] && continue
	APP_SRCS+=("$f")
done

echo "==> Compile the chrome audit host (real App chrome + cores, minus main.swift)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$HOST_BIN" \
	scripts/chrome_host.swift \
	"${APP_SRCS[@]}" \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	Sources/ScanFS/*.swift \
	Sources/RenderPipeline/*.swift \
	-framework AppKit \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-framework CoreGraphics \
	-target arm64-apple-macos14

echo "==> Run the offscreen chrome audit (no window shown/activated)"
"$HOST_BIN" build

echo "==> CHROME AUDIT OK (see build/chrome-*.png for the two-size visual pass)"
