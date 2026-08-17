#!/usr/bin/env bash
# xcode_env.sh — shared toolchain resolver (PORTABILITY, 2026-08-17).
# Module maturity: PROTOTYPE
#
# Replaces per-script hardcoding of this machine's Xcode path. Contract:
#   resolve_developer_dir                 # soft: full Xcode if found, else CLT
#   resolve_developer_dir --require-xctest # hard: full Xcode or loud failure
# Resolution order: explicit $DEVELOPER_DIR wins; else the xcode-selected dir
# IF it is a full Xcode (Platforms/ marker — the CLT has none); else the
# conventional /Applications/Xcode.app; else unset (fine for plain swiftc
# builds) or an error under --require-xctest (XCTest needs full Xcode).
# Abstraction ledger: one function, eight concrete script users, one axis
# (toolchain location per machine); rejected alternative: eight copies.
resolve_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR; return 0; fi
    local sel
    sel="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$sel" ] && [ -d "$sel/Platforms" ]; then
        export DEVELOPER_DIR="$sel"; return 0
    fi
    if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"; return 0
    fi
    if [ "${1:-}" = "--require-xctest" ]; then
        echo "ERROR: this gate needs a full Xcode toolchain (XCTest); the" >&2
        echo "Command Line Tools alone are not enough. Install Xcode, or set" >&2
        echo "DEVELOPER_DIR to a full Xcode's Contents/Developer." >&2
        return 1
    fi
    return 0
}
