#!/usr/bin/env bash
# Record the demo on a compositor nobody can see.
#
# Every command the demo runs is written in steps.txt, in this directory.
# Nothing reads the person's files, their shell configuration or their
# history, and the recording happens on a private headless compositor, so
# nothing appears on anybody's screen.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

odin build "$HERE" \
  -collection:palmy="$ROOT/palmy" \
  -collection:kit="$ROOT/apps/kit" \
  -collection:shadcn="$ROOT/shadcn" \
  -o:speed -out:"$HERE/term.bin"

exec "$ROOT/apps/tools/headless-record.sh" \
  "$HERE/term.bin" "$HERE/demo.mp4" "$HERE/steps.txt" 1280 800
