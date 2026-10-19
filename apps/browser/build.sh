#!/usr/bin/env bash
# Build the browser chrome (and, with an engine directory, its engine hosts).
#   apps/browser/build.sh [out_dir] [cef_dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/bin}"
mkdir -p "$OUT"
odin build "$HERE" -collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" \
	-collection:kit="$ROOT/apps/kit" -collection:cloudkit="$ROOT/apps/cloudkit" \
	-o:speed -out:"$OUT/browser"
if [ -d "$HERE/engine/gecko" ]; then
	odin build "$HERE/engine/gecko" -collection:palmy="$ROOT/palmy" -collection:browser="$HERE" \
		-o:speed -out:"$OUT/palm-browser-gecko"
fi
if [ -n "${2:-}" ]; then
	"$HERE/engine/cef/build.sh" "$2" "$OUT/cef"
fi
echo "built $OUT/browser"
