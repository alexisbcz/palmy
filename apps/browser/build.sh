#!/usr/bin/env bash
# Build the browser (the chrome, which is also the Firefox engine host) and,
# given an unpacked CEF distribution, the Chromium engine host beside it.
#   apps/browser/build.sh [out_dir] [cef_dir]
# The plain build is what distro/apps/build.sh does for every application.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/bin}"
mkdir -p "$OUT"
cd "$ROOT"
odin build apps/browser -o:speed -collection:palmy=palmy -collection:kit=apps/kit \
	-collection:shadcn=shadcn -out:"$OUT/browser"
if [ -n "${2:-}" ]; then
	"$HERE/engine/cef/build.sh" "$2" "$OUT/cef"
fi
echo "built $OUT/browser"
