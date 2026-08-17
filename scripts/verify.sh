#!/usr/bin/env bash
# verify.sh — deterministic offscreen gates + bundle-structure assertions.
# Module maturity: PROTOTYPE (slice TZ-2)
#
# Three jobs, all bare and exit-code-checked (never piped — CLAUDE.md Gates):
#
#   (1) OFFSCREEN FIXTURE FRAMES (TZ-1): compile scripts/verify_host.swift with
#       the real Sources/App/QuadRenderer.swift + the two core source trees into
#       one swiftc binary (the App-monolith arrangement), then render the fixture
#       scene at TWO viewport sizes THROUGH the real QuadRenderer into PNGs.
#       Assert both PNGs are non-empty and byte-DIFFER (different viewport ⇒
#       different squarified layout ⇒ different pixels). This is the App-adapted
#       version of glyph-saver's offscreen verify seam — no ScreenSaverEngine,
#       no `screencapture`; the app window is separate, additional evidence.
#
#   (3) SCAN GATE (TZ-2): compile scripts/scan_host.swift with the real walker
#       (Sources/ScanFS) + reducer + cores + QuadRenderer, walk a REAL fixture
#       directory tree to completion, assert the FULL golden tree (structure +
#       per-node sizes), then render the scanned SizeTree to two PNGs and assert
#       they are non-empty and differ.
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
SCAN_BIN="build/scan_host"
SHADER="Sources/App/Shaders.metal"
FIXTURE="Tests/Fixtures/fixture-tree.json"
OUT1="build/verify-1.png"
OUT2="build/verify-2.png"
FOCUS_ROOT="build/verify-focus-root.png"
FOCUS_CHILD="build/verify-focus-child.png"
SCALE_LINEAR="build/verify-scale-linear.png"
SCALE_LOG="build/verify-scale-log.png"
SCALE_LOG_IGNORE="build/verify-scale-log-ignore.png"
SCAN_OUT1="build/verify-scan-1.png"
SCAN_OUT2="build/verify-scan-2.png"
SCAN_PROMOTED="build/verify-scan-promoted.png"

mkdir -p build
rm -f "$OUT1" "$OUT2" "$FOCUS_ROOT" "$FOCUS_CHILD" "$SCALE_LINEAR" "$SCALE_LOG" "$SCALE_LOG_IGNORE" "$SCAN_OUT1" "$SCAN_OUT2" "$SCAN_PROMOTED"

echo "==> (2a) Build the app bundle (also needed for structure assertions)"
scripts/build.sh

echo "==> (1a) Compile the offscreen verify host (real QuadRenderer + cores)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$HOST_BIN" \
	scripts/verify_host.swift \
	Sources/App/QuadRenderer.swift \
	Sources/RenderPipeline/GPUQuad.swift \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	-framework Metal \
	-framework CoreGraphics \
	-framework ImageIO \
	-target arm64-apple-macos14

echo "==> (1b) Render two viewport frames + two focus frames + three TZ-5 scale/ignore frames"
"$HOST_BIN" "$SHADER" "$FIXTURE" "$OUT1" "$OUT2" "$FOCUS_ROOT" "$FOCUS_CHILD" \
	"$SCALE_LINEAR" "$SCALE_LOG" "$SCALE_LOG_IGNORE"

echo "==> (1c) Assert all seven frames were written and are non-empty"
for f in "$OUT1" "$OUT2" "$FOCUS_ROOT" "$FOCUS_CHILD" "$SCALE_LINEAR" "$SCALE_LOG" "$SCALE_LOG_IGNORE"; do
	if [[ ! -s "$f" ]]; then
		echo "VERIFY FAILED: a frame is missing/empty ($f)" >&2
		exit 1
	fi
done

echo "==> (1d) Assert the two viewport frames differ (layout responded to viewport)"
if cmp -s "$OUT1" "$OUT2"; then
	echo "VERIFY FAILED: $OUT1 and $OUT2 are byte-identical — layout did not respond to size" >&2
	exit 1
fi

echo "==> (1e) Assert focus=root and focus=child differ (navigation changes the map)"
if cmp -s "$FOCUS_ROOT" "$FOCUS_CHILD"; then
	echo "VERIFY FAILED: $FOCUS_ROOT and $FOCUS_CHILD are byte-identical — focus did not change what is drawn" >&2
	exit 1
fi

echo "==> (1f) TZ-5: assert linear / log / log+ignore frames all DIFFER (scale toggle + ignore change the map)"
if cmp -s "$SCALE_LINEAR" "$SCALE_LOG"; then
	echo "VERIFY FAILED: $SCALE_LINEAR and $SCALE_LOG are byte-identical — the log scale did not change the layout" >&2
	exit 1
fi
if cmp -s "$SCALE_LOG" "$SCALE_LOG_IGNORE"; then
	echo "VERIFY FAILED: $SCALE_LOG and $SCALE_LOG_IGNORE are byte-identical — ignoring the largest tile did not change the layout" >&2
	exit 1
fi
# review-0 change 4a: assert the THIRD pair too, so ALL THREE frames are proven distinct
# (linear ≠ log ≠ log+ignore ≠ linear) rather than only the two adjacent pairs.
if cmp -s "$SCALE_LINEAR" "$SCALE_LOG_IGNORE"; then
	echo "VERIFY FAILED: $SCALE_LINEAR and $SCALE_LOG_IGNORE are byte-identical — the three scale/ignore frames are not all distinct" >&2
	exit 1
fi

echo "==> (3a) Compile the scan gate host (real walker + reducer + cores + QuadRenderer)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$SCAN_BIN" \
	scripts/scan_host.swift \
	Sources/App/QuadRenderer.swift \
	Sources/RenderPipeline/GPUQuad.swift \
	Sources/ScanFS/*.swift \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	-framework Metal \
	-framework CoreGraphics \
	-framework ImageIO \
	-target arm64-apple-macos14

echo "==> (3b) Walk a real fixture tree to completion, assert golden, render two frames + a PROMOTED-root frame (TZ-4b)"
"$SCAN_BIN" "$SHADER" "$SCAN_OUT1" "$SCAN_OUT2" "$SCAN_PROMOTED"

echo "==> (3c) Assert both scan frames were written, are non-empty, and differ"
if [[ ! -s "$SCAN_OUT1" || ! -s "$SCAN_OUT2" ]]; then
	echo "VERIFY FAILED: a scan frame is missing/empty ($SCAN_OUT1, $SCAN_OUT2)" >&2
	exit 1
fi
if cmp -s "$SCAN_OUT1" "$SCAN_OUT2"; then
	echo "VERIFY FAILED: $SCAN_OUT1 and $SCAN_OUT2 are byte-identical — layout did not respond to size" >&2
	exit 1
fi

echo "==> (3d) Assert the PROMOTED-root frame (old map as one tile among new siblings + denied badge) was written and differs from the un-promoted scan"
if [[ ! -s "$SCAN_PROMOTED" ]]; then
	echo "VERIFY FAILED: promoted-root frame missing/empty ($SCAN_PROMOTED)" >&2
	exit 1
fi
if cmp -s "$SCAN_OUT1" "$SCAN_PROMOTED"; then
	echo "VERIFY FAILED: $SCAN_PROMOTED is byte-identical to $SCAN_OUT1 — promotion did not change the map" >&2
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

echo "==> VERIFY OK: fixture frames ($OUT1,$OUT2), focus frames ($FOCUS_ROOT,$FOCUS_CHILD), and scan frames ($SCAN_OUT1,$SCAN_OUT2) written and differ; $APP structure complete."
echo "    Scan gate: real walker+reducer produced the golden tree and rendered it."
echo "    Operator judges the PNGs + the live window (scripts/run.sh)."
