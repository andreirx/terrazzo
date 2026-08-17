#!/usr/bin/env bash
# test.sh — the `swift test` gate for the pure cores (ScanCore + TreemapCore).
# Module maturity: PROTOTYPE (slice TZ-1)
#
# WHY THIS WRAPPER (inherited, verified environment fact — glyph-saver GS-2):
# `xcode-select` here points at the Command Line Tools, whose toolchain ships
# NEITHER XCTest NOR swift-testing — a bare `swift test` FAILS or falsely reports
# "0 tests". The full Xcode at /Applications/Xcode.app carries both. Rather than
# switch the global toolchain (a machine-wide side effect), we scope Xcode to
# THIS command via DEVELOPER_DIR, which swift/xcrun honor as an override.
#
# Run BARE and check the exit code — never pipe this gate (CLAUDE.md Gates). A
# green run MUST show a NONZERO executed-test count. Extra args pass through
# (e.g. scripts/test.sh --filter SquarifyTests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/xcode_env.sh"

resolve_developer_dir --require-xctest
exec env DEVELOPER_DIR="$DEVELOPER_DIR" swift test "$@"
