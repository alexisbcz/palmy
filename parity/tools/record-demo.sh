#!/usr/bin/env bash
# Record the live palmy window while driving it with real input.
#
#   record-demo.sh <out.mp4>
#
# wf-recorder captures the Wayland output; the cursor is moved with Hyprland's
# dispatcher and keys are sent with wtype, so what lands in the video is the
# compositor's own composite of palmy's shared-memory buffer.
set -uo pipefail
OUT="${1:-/home/alex/Work/palmy/parity/out/video/showcase.mp4}"
mkdir -p "$(dirname "$OUT")"
BIN=/home/alex/Work/palmy/parity/odin/showcase.bin

kill_palmy() {
  for pid in $(hyprctl clients -j | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="palmy": print(c.get("pid"))'); do kill -9 "$pid" 2>/dev/null; done
}

geometry() {
  hyprctl clients -j | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="palmy":
        x,y=c["at"]; w,h=c["size"]; print(x,y,w,h); break'
}

move() { hyprctl dispatch "hl.dsp.cursor.move({x=$1,y=$2})" >/dev/null 2>&1; }

kill_palmy; sleep 0.4
"$BIN" & APP=$!
sleep 2

read X Y W H <<< "$(geometry)"
if [ -z "${X:-}" ]; then echo "no palmy window"; kill $APP 2>/dev/null; exit 1; fi
echo "recording window $X,$Y ${W}x${H}"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=18 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.5

# Hover each button in the variant row, left to right.
for dx in 139 232 325 402 494 580; do
  move $((X+dx)) $((Y+210)); sleep 0.45
done

# Keyboard: Tab through the buttons and activate several with Return. There is
# no click dispatcher in this compositor build, so activation goes through the
# keyboard path, which exercises focus, the focus ring and the click handler.
sleep 0.4
for i in 1 2 3; do
  wtype -k Tab; sleep 0.35
  wtype -k Return; sleep 0.55
done

# Walk focus down to the name field and type into it.
for _ in $(seq 1 8); do wtype -k Tab; sleep 0.1; done
wtype "Ada Lovelace"; sleep 0.8
wtype -k Tab; sleep 0.4
wtype "rounded corners"; sleep 0.9
for _ in $(seq 1 7); do wtype -k BackSpace; sleep 0.07; done
sleep 0.9

# A last sweep across the sizes row.
for dx in 633 680 747 810; do move $((X+dx)) $((Y+212)); sleep 0.35; done
sleep 1

kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
kill $APP 2>/dev/null
sleep 0.5
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
