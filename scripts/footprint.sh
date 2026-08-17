#!/usr/bin/env bash
# footprint.sh — TZ-9 THE NUMBERS gate: retained bytes/node + the rescan leak gate.
# Module maturity: PROTOTYPE (slice TZ-9).
#
# THE MEMORY LAW (CLAUDE.md constraint 6): retained memory per scanned node ≤ ~100 B
# amortized, and a rescan returns footprint to baseline. This compiles
# scripts/footprint_host.swift with the REAL ScanFS walker + ScanCore reducer ONLY (no
# AppKit/Metal — fast to build/run) and drives a real directory scan, measuring the
# process phys_footprint ("Memory" in Activity Monitor) against the reducer's retained
# node count. It prints one TZFOOTPRINT line with bytes/node.
#
# EVIDENCE, not a deterministic CI gate (like scanrate.sh / threads.sh) — the number
# depends on the machine + tree + cache state, so it is run and read, not asserted.
# Run BARE.
#
#   scripts/footprint.sh [rootDir] [maxSeconds] [rescan=N]
#     rootDir     default $HOME (the home-scan measurement target)
#     maxSeconds  default 0 = scan to completion; >0 caps the run (cap a monster scan)
#     rescan=N    run N sequential scans (fresh reducer each, released between) and report
#                 per-scan peak footprint — the leak gate (peak must stay FLAT across rescans)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/xcode_env.sh"
resolve_developer_dir

BIN="build/footprint_host"
SCAN_ROOT="${1:-$HOME}"
MAX_SECONDS="${2:-0}"
shift $(( $# > 2 ? 2 : $# ))   # drop rootDir + maxSeconds; forward the rest ($@) to the host

mkdir -p build

echo "==> Compile the footprint host (real walker + reducer, no AppKit/Metal)"
swiftc \
	-O \
	-o "$BIN" \
	scripts/footprint_host.swift \
	Sources/ScanFS/*.swift \
	Sources/ScanCore/*.swift \
	-target arm64-apple-macos14

echo "==> Measure footprint of scanning $SCAN_ROOT (maxSeconds=$MAX_SECONDS $*)"
"$BIN" "$SCAN_ROOT" "$MAX_SECONDS" "$@"
