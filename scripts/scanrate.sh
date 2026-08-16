#!/usr/bin/env bash
# scanrate.sh — TZ-6 THE NUMBERS gate: sustained files/s + wall-clock of the REAL
# walker→reducer path. Module maturity: PROTOTYPE (slice TZ-6).
#
# The acceptance for TZ-6 is a MEASURED scan rate (≥ 25,000 files/s on a home scan)
# and full-home wall-clock (≤ 3 min). This compiles scripts/scan_rate_host.swift with
# the real ScanFS walker + ScanCore reducer ONLY (no AppKit/Metal — fast to build and
# run) and drives a real directory scan, printing one TZRATE line with the numbers.
#
# EVIDENCE, not a deterministic CI gate (like threads.sh) — the number depends on the
# machine + cache state, so it is run and read, not asserted. Run it bare.
#
#   scripts/scanrate.sh [rootDir] [maxSeconds] [+anticipate] [qos=background]
#     rootDir       default $HOME (the home-scan acceptance target)
#     maxSeconds    default 0 = run to completion (report wall-clock); >0 caps the run
#     +anticipate   also run the low-priority volume-root warm, to show it does not
#                   measurably degrade the primary rate (state both rates)
#     qos=background run the warm at .background instead of the default .utility (the QoS
#                   DECISION comparison; OPERATOR_NOTE tz6_anticipatory_qos)
#     warmonly      run ONLY the warm (no primary), excluding rootDir, and report its
#                   ELAPSED + whether it COMPLETED (revise-1 finding 1: anticipation time)
#     warmcap=N     with warmonly, stop the warm after N seconds (0 = run to completion) and
#                   report it as capped/non-completed — the honest time-bound result
#   Any arg after maxSeconds is forwarded verbatim to the host (order-independent flags).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="build/scan_rate_host"
SCAN_ROOT="${1:-$HOME}"
MAX_SECONDS="${2:-0}"
shift $(( $# > 2 ? 2 : $# ))   # drop rootDir + maxSeconds; forward the rest ($@) to the host

mkdir -p build

echo "==> Compile the scan-rate host (real walker + reducer, no AppKit/Metal)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
	-O \
	-o "$BIN" \
	scripts/scan_rate_host.swift \
	Sources/ScanFS/*.swift \
	Sources/ScanCore/*.swift \
	-target arm64-apple-macos14

echo "==> Scan $SCAN_ROOT (maxSeconds=$MAX_SECONDS $*)"
"$BIN" "$SCAN_ROOT" "$MAX_SECONDS" "$@"
