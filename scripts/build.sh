#!/usr/bin/env bash
# build.sh — compile the App layer into build/Terrazzo.app (a normal .app).
# Module maturity: PROTOTYPE (slice TZ-2)
#
# The pure cores (Sources/ScanCore, Sources/TreemapCore) and the ScanFS I/O
# adapter are SPM libraries for `swift test`, but the App is built by swiftc
# (glyph-saver PLAN.md pattern: no build-time Metal toolchain) — the SAME core +
# ScanFS sources are compiled straight into the Terrazzo executable here (see the
# swiftc invocation below, which lists Sources/ScanFS). Shaders ship as SOURCE and
# compile at RUNTIME (makeLibrary(source:)); this script MUST NOT invoke `metal`.
#
# Run BARE, check the exit code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/xcode_env.sh"
resolve_developer_dir

APP="build/Terrazzo.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "==> Clean bundle tree"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Compile Sources/App + Sources/TreemapCore + Sources/ScanCore + Sources/ScanFS + Sources/RenderPipeline -> $MACOS/Terrazzo"
swiftc \
	-O \
	-o "$MACOS/Terrazzo" \
	Sources/App/*.swift \
	Sources/TreemapCore/*.swift \
	Sources/ScanCore/*.swift \
	Sources/ScanFS/*.swift \
	Sources/RenderPipeline/*.swift \
	-framework AppKit \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-framework CoreGraphics \
	-framework CoreServices \
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

echo "==> Code sign with a STABLE identity (operator directive 2026-08-16)"
# WHY (TCC persistence): macOS TCC identifies an app by its code signature. Ad-hoc
# signing mints a NEW identity every rebuild, so every protected-folder prompt
# reappears on every build. Signing with a fixed Developer identity keeps folder
# grants — and the TZ-4 Full Disk Access grant — sticky across rebuilds.
# Operator-verified command/identity on this machine (TeamIdentifier PTN74UT4G3).
# PORTABILITY (2026-08-17): identity resolution instead of a hardcoded cert.
# Order: $TERRAZZO_SIGN_IDENTITY env; else the first Apple Development identity
# in the keychain; else AD-HOC ("-") with a loud warning — the build still runs
# on any machine, at the cost of TCC grants resetting per rebuild.
SIGN_ID="${TERRAZZO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    echo "WARN: no code-signing identity found — signing AD-HOC. The app runs," >&2
    echo "but macOS privacy (TCC) grants will reset on every rebuild. Set" >&2
    echo "TERRAZZO_SIGN_IDENTITY or add an Apple Development cert to persist them." >&2
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" "$APP"

echo "==> Assert the signature matches the chosen identity class"
if [ "$SIGN_ID" = "-" ]; then
    echo "    (ad-hoc build — TeamIdentifier assertion skipped by design)"
else
# An ad-hoc or unsigned bundle reports 'TeamIdentifier=not set'. Require a real
# team id so an identity-less build (which would defeat TCC persistence) fails
# LOUDLY here rather than silently re-prompting the operator at runtime.
#
# CAPTURE-THEN-MATCH (TZ-3 rev-1): do NOT pipe `codesign -dv` into `grep -q`.
# Under `set -o pipefail`, `grep -q` exits at the first match and closes the
# pipe; `codesign` then dies with SIGPIPE (141) on its next write, and pipefail
# propagates that 141 as the pipeline's status — a false "no TeamIdentifier"
# failure that fires intermittently on a perfectly-signed bundle (observed once,
# then vanished on rerun — a timing race, not a code fault). Capturing the
# output first removes the pipe entirely; the assertion is otherwise identical.
SIG_DESC="$(codesign -dv "$APP" 2>&1)"
if ! grep -Eq '^TeamIdentifier=[A-Z0-9]+$' <<<"$SIG_DESC"; then
	echo "BUILD FAILED: $APP has no stable TeamIdentifier after codesign" >&2
	echo "$SIG_DESC" >&2
	exit 1
fi
fi

echo "==> Built $APP (signed: $SIGN_ID)"
