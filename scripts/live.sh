#!/usr/bin/env bash
# live.sh — TZ-7 LIVE headless evidence gate (the living map).
# Module maturity: PROTOTYPE (slice TZ-7)
#
# Compiles scripts/live_host.swift with the REAL walker + reducer + FSEvents watcher (Sources/ScanFS
# + Sources/ScanCore) into one swiftc binary and runs it. The host scans a fixture directory, then
# mutates it (create / delete / grow) while holding focus — proving BOTH tiers detect the change and
# update the tree WITHOUT a rescan, with measured latencies (TZTRACE lines). NO synthetic input, NO
# window (CLAUDE.md builder conduct). Run BARE, check the exit code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/xcode_env.sh"
resolve_developer_dir

BIN="build/live_host"
mkdir -p build

echo "==> Compile the live-evidence host (real walker + reducer + FSEvents)"
swiftc \
	-O \
	-o "$BIN" \
	scripts/live_host.swift \
	Sources/ScanFS/*.swift \
	Sources/ScanCore/*.swift \
	-framework CoreServices \
	-target arm64-apple-macos14

echo "==> Run the living-map evidence (Tier-1 mtime, Tier-2 FSEvents, HOME delete)"
"$BIN"
