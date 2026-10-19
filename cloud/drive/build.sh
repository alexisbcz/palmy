#!/usr/bin/env bash
# Build the drive's binaries: palm-drive (the sync daemon) and drive (the app
# and its CLI). Output goes to cloud/drive/bin/ and apps/drive/drive.bin.
#
#   cloud/drive/build.sh            both, optimised
#   cloud/drive/build.sh debug      both, with -debug
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPT=(-o:speed)
if [ "${1:-}" = debug ]; then OPT=(-debug); fi
COLL=(
	-collection:palmy="$ROOT/palmy"
	-collection:shadcn="$ROOT/shadcn"
	-collection:kit="$ROOT/apps/kit"
	-collection:drive="$ROOT/cloud/drive"
)
mkdir -p "$ROOT/cloud/drive/bin"
odin build "$ROOT/cloud/drive/palm-drive" "${COLL[@]}" "${OPT[@]}" -out:"$ROOT/cloud/drive/bin/palm-drive"
if [ -d "$ROOT/apps/drive" ]; then
	odin build "$ROOT/apps/drive" "${COLL[@]}" "${OPT[@]}" -out:"$ROOT/apps/drive/drive.bin"
fi
