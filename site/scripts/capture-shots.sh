#!/usr/bin/env bash
#
# Every screenshot on this site, from scratch.
#
#   site/scripts/capture-shots.sh
#
# Three sources, in the order they cost:
#
#   1. components  parity/out/odin already holds one palmy-rendered PNG per
#                  parity case. shots-components.mjs picks the representative
#                  case for each of the 61 component slugs and frames it.
#   2. the hero    examples/gallery renders its own window offscreen; tab 0 is
#                  a grid of real widgets, which is what the landing page asks
#                  for.
#   3. apps        shots-apps.sh runs each application's own offscreen shot
#                  flag inside a sandbox that keeps the machine's identity out
#                  of the frame, and shots-collect.mjs downscales what comes
#                  back and refuses anything that still carries it.
#
# Nothing here starts a compositor, opens a window, reads the user's files, or
# touches the camera, the microphone or the network. See the header of
# shots-apps.sh for how that is arranged and why each piece is there.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW="${1:-$(mktemp -d /tmp/palmy-shots-raw-XXXXXX)}"
mkdir -p "$RAW"

echo "== components =="
node "$ROOT/site/scripts/shots-components.mjs" | tail -2

echo
echo "== hero =="
BIN="$(mktemp -d /tmp/palmy-gallery-XXXXXX)"
odin build "$ROOT/examples/gallery" -o:speed -out:"$BIN/gallery" >/dev/null 2>&1
if [ -x "$BIN/gallery" ]; then
  (cd "$BIN" && ./gallery render "$BIN/gallery-0.png" 0 >/dev/null)
  # 16:10, which is the aspect the landing page reserves, cropped from the top
  # the way the page's own `object-top` would crop it.
  magick "$BIN/gallery-0.png" -resize 1400x -gravity north -crop 1400x875+0+0 +repage \
         -strip -define png:color-type=2 "$ROOT/site/public/shots/gallery.png"
  echo "  gallery.png"
else
  echo "  FAILED: could not build examples/gallery"
fi
rm -rf "$BIN"

echo
echo "== apps =="
"$ROOT/site/scripts/shots-apps.sh" "$RAW"

echo
echo "== collect and scan =="
node "$ROOT/site/scripts/shots-collect.mjs" "$RAW"

echo
du -sh "$ROOT/site/public/shots"
