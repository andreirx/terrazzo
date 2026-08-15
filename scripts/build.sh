#!/usr/bin/env bash
# build.sh — compile the App layer into build/Terrazzo.app (a normal .app).
# Module maturity: PROTOTYPE (slice TZ-1)
#
# The two pure cores (Sources/ScanCore, Sources/TreemapCore) are SPM libraries
# for `swift test`, but the App is built by swiftc (glyph-saver PLAN.md pattern:
# no build-time Metal toolchain) — the SAME core sources are compiled straight
# into the Terrazzo executable here. Shaders ship as SOURCE and compile at
# RUNTIME (makeLibrary(source:)); this script MUST NOT invoke the `metal` tool.
#
# Run BARE, check the exit code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="build/Terrazzo.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "==> Clean bundle tree"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Compile Sources/App + Sources/TreemapCore + Sources/ScanCore -> $MACOS/Terrazzo"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$MACOS/Terrazzo" \
	Sources/App/*.swift \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	-framework AppKit \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-framework CoreGraphics \
	-target arm64-apple-macos14

echo "==> Copy Info.plist"
cp Sources/App/Info.plist "$APP/Contents/Info.plist"

echo "==> Copy shader source + fixture into Resources"
cp Sources/App/Shaders.metal "$RES/"
cp Tests/Fixtures/fixture-tree.json "$RES/"

echo "==> Verify required artifacts exist"
for f in \
	"$MACOS/Terrazzo" \
	"$APP/Contents/Info.plist" \
	"$RES/Shaders.metal" \
	"$RES/fixture-tree.json"; do
	if [[ ! -f "$f" ]]; then
		echo "BUILD FAILED: missing $f" >&2
		exit 1
	fi
done

echo "==> Built $APP"
