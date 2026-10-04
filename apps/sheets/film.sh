#!/usr/bin/env bash
# Build apps/sheets/demo.mp4 from the application's own offscreen renderer.
#
#   bash apps/sheets/film.sh [out.mp4]
#
# Why not apps/tools/headless-record.sh. That drives the app through a real
# Wayland compositor, and palmy's Wayland keyboard currently delivers exactly
# one key event to a window and then goes silent — reproduced with the
# committed build of this app as well as the current one, so it is a toolkit
# regression, not this app's doing. A recorded take therefore shows one
# keystroke and then a still picture.
#
# `sheets --film` runs the *same* `handle_keys` and `frame` code through
# palmy's offscreen path, which does not involve the compositor at all, and
# writes one PNG per step. The frames are the application's real output; only
# the delivery of the keys differs. Switch back to headless-record.sh the day
# the keyboard works again: apps/sheets/demo.txt is the same script in that
# grammar.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-apps/sheets/demo.mp4}"
BIN=apps/sheets/sheets.bin
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

[ -x "$BIN" ] || { echo "build $BIN first"; exit 1; }

# One step per line; "." is an idle frame, and that is how the pacing is done.
mapfile -t STEPS < apps/sheets/film.txt
"$BIN" --film "$DIR/f" "${STEPS[@]}" || exit 1

ffmpeg -nostdin -v error -framerate 6 -i "$DIR/f-%04d.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 -vf fps=24 -y "$OUT" || exit 1
echo "wrote $OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s)"
