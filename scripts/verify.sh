#!/usr/bin/env bash
# verify.sh — TZ-1 deterministic offscreen gate + bundle-structure assertions.
# Module maturity: PROTOTYPE (slice TZ-1)
#
# Two jobs, both bare and exit-code-checked (never piped — CLAUDE.md Gates):
#
#   (1) OFFSCREEN FRAMES: compile scripts/verify_host.swift together with the
#       real Sources/App/QuadRenderer.swift + the two core source trees into one
#       swiftc binary (the App-monolith arrangement), then render the fixture
#       scene at TWO viewport sizes THROUGH the real QuadRenderer into PNGs.
#       Assert both PNGs are non-empty and byte-DIFFER (different viewport ⇒
#       different squarified layout ⇒ different pixels). This is the App-adapted
#       version of glyph-saver's offscreen verify seam — no ScreenSaverEngine,
#       no `screencapture`; the app window is separate, additional evidence.
#
#   (2) BUNDLE STRUCTURE: build the app and assert the .app carries the
#       executable, Info.plist, the runtime shader source, and the fixture.
#
# The operator then judges the two PNGs and the live window (surfaces automation
# does not fully own).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="build/Terrazzo.app"
HOST_BIN="build/verify_host"
SHADER="Sources/App/Shaders.metal"
FIXTURE="Tests/Fixtures/fixture-tree.json"
OUT1="build/verify-1.png"
OUT2="build/verify-2.png"

mkdir -p build
rm -f "$OUT1" "$OUT2"

echo "==> (2a) Build the app bundle (also needed for structure assertions)"
scripts/build.sh

echo "==> (1a) Compile the offscreen verify host (real QuadRenderer + cores)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$HOST_BIN" \
	scripts/verify_host.swift \
	Sources/App/QuadRenderer.swift \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	-framework Metal \
	-framework CoreGraphics \
	-framework ImageIO \
	-target arm64-apple-macos14

echo "==> (1b) Render two fixture frames at different viewport sizes"
"$HOST_BIN" "$SHADER" "$FIXTURE" "$OUT1" "$OUT2"

echo "==> (1c) Assert both frames were written and are non-empty"
if [[ ! -s "$OUT1" || ! -s "$OUT2" ]]; then
	echo "VERIFY FAILED: a frame is missing/empty ($OUT1, $OUT2)" >&2
	exit 1
fi

echo "==> (1d) Assert the two frames differ (layout responded to viewport)"
if cmp -s "$OUT1" "$OUT2"; then
	echo "VERIFY FAILED: $OUT1 and $OUT2 are byte-identical — layout did not respond to size" >&2
	exit 1
fi

echo "==> (2b) Assert bundle structure"
for f in \
	"$APP/Contents/MacOS/Terrazzo" \
	"$APP/Contents/Info.plist" \
	"$APP/Contents/Resources/Shaders.metal" \
	"$APP/Contents/Resources/fixture-tree.json"; do
	if [[ ! -f "$f" ]]; then
		echo "VERIFY FAILED: bundle missing $f" >&2
		exit 1
	fi
done

echo "==> VERIFY OK: $OUT1 and $OUT2 written and differ; $APP structure complete."
echo "    Operator judges the two PNGs + the live window (scripts/run.sh)."
