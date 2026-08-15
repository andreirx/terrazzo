#!/usr/bin/env bash
# run.sh — build the app and open it.
# Module maturity: PROTOTYPE (slice TZ-1)
#
# Unlike a screensaver, this window survives user input, so `open`-ing the built
# bundle is a legitimate way to SEE the render (live-window screenshots are legal
# extra evidence; the deterministic gate remains scripts/verify.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

scripts/build.sh
echo "==> open build/Terrazzo.app"
open build/Terrazzo.app
