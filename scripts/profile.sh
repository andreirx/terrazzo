#!/usr/bin/env bash
# profile.sh — TZ-6 PER-PHASE profile gate (revise finding 5). Module maturity: PROTOTYPE.
#
# The revise note requires the walker's cost be ATTRIBUTED PER PHASE — enumeration /
# attributes / id+event build / actor sends — MEASURED, not inferred, with the command
# transcript in the report. This compiles scripts/scan_profile_host.swift against the REAL
# ScanFS + ScanCore (no AppKit/Metal) and runs a single-threaded walk that times each phase
# via DirectoryReader's production ReaderProfile hook, printing one TZPROFILE block.
#
# EVIDENCE, not a deterministic CI gate — the numbers depend on machine + cache state, so it
# is run and read, not asserted. Run it bare.
#
#   scripts/profile.sh [rootDir]        # default $HOME
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="build/scan_profile_host"
SCAN_ROOT="${1:-$HOME}"

mkdir -p build

echo "==> Compile the per-phase profile host (real DirectoryReader + reducer, no AppKit/Metal)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$BIN" \
	scripts/scan_profile_host.swift \
	Sources/ScanFS/*.swift \
	Sources/ScanCore/*.swift \
	-target arm64-apple-macos14

echo "==> Profile $SCAN_ROOT (single-threaded, per-phase attribution)"
"$BIN" "$SCAN_ROOT"
