#!/usr/bin/env bash
# Build a video that walks every compared case: Chromium on the left, palmy in
# the middle, the difference heat map on the right, with the measured error.
#
#   make-comparison-video.sh [out.mp4]
set -uo pipefail
# The parity/ directory this script lives in, so a worktree films its own
# measurements; PARITY_ROOT overrides, as in tools/diff-all.sh.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PARITY_ROOT:-$(dirname "$HERE")}"
cd "$ROOT" || exit 1
OUT="${1:-out/video/comparison.mp4}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"

W=1280; H=720
FONT="$ROOT/web/public/fonts/Geist-500.ttf"
[ -f "$FONT" ] || FONT=$(fc-match -f "%{file}" sans)

i=0
while read -r line; do
  id=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('id',''))" 2>/dev/null)
  status=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('status',''))" 2>/dev/null)
  [ "$status" = "ok" ] || continue
  [ -f "out/diff/$id.png" ] || continue
  mae=$(echo "$line" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(f\"{d['metrics']['mae']:.2f}\")" 2>/dev/null)
  w2=$(echo "$line" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(f\"{d['metrics']['within_2_pct']:.1f}\")" 2>/dev/null)

  frame=$(printf "%s/%04d.png" "$WORK" "$i")
  # Scale the triptych to fit, centre it on a dark card, and caption it.
  magick out/diff/"$id".png -filter point -resize "$((W-200))x$((H-260))" \
    -bordercolor '#18181b' -border 20 \
    -background '#09090b' -gravity center -extent ${W}x$((H-120)) \
    \( -background '#09090b' -fill '#fafafa' -font "$FONT" -pointsize 30 \
       -gravity west -size $((W-80))x50 label:"  $id" \) -append \
    \( -background '#09090b' -fill '#a1a1aa' -font "$FONT" -pointsize 20 \
       -gravity west -size $((W-80))x40 label:"  mean abs error ${mae}/255   ·   ${w2}% of pixels within 2/255   ·   left: Chromium   middle: palmy (Odin)   right: difference" \) -append \
    -background '#09090b' -gravity north -extent ${W}x${H} "$frame" 2>/dev/null
  [ -f "$frame" ] && i=$((i+1))
done < out/diff/metrics.ndjson

if [ "$i" -eq 0 ]; then echo "no frames"; exit 1; fi
echo "built $i frames"

# Hold each case for 1.4s.
ffmpeg -v error -y -framerate 1/1.4 -i "$WORK/%04d.png" \
  -vf "scale=${W}:${H}:flags=lanczos,format=yuv420p" -r 30 -c:v libx264 -crf 20 -preset veryfast "$OUT"
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s, $i cases)"
