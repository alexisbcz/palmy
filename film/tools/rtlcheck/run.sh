#!/usr/bin/env bash
# Build and run the RTL render check. Writes film/.work/rtl.png.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$ROOT/film/.work"
cd "$ROOT"
odin build film/tools/rtlcheck -collection:palmy="$ROOT/palmy" \
	-out:film/.work/rtlcheck.bin
film/.work/rtlcheck.bin
ls -la film/.work/rtl-wired.png film/.work/rtl-gaps.png
