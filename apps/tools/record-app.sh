#!/usr/bin/env bash
# Record a palmy app while driving it with real input.
#
#   record-app.sh <binary> <out.mp4> <script-file>
#
# The script file is a list of commands, one per line, interpreted here:
#   key <X11name>     wtype -k  (Tab, Return, Escape, Down, Up, BackSpace, ...)
#   type <text>       wtype
#   move <dx> <dy>    move the pointer to window-relative coordinates
#   wait <seconds>    sleep
#
# wf-recorder captures the compositor's own composite of the window, so what
# lands in the video is exactly what the display shows.
set -uo pipefail
BIN="${1:?binary}"; OUT="${2:?output mp4}"; SCRIPT="${3:?script file}"
mkdir -p "$(dirname "$OUT")"

kill_palmy() {
  for pid in $(hyprctl clients -j | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="palmy": print(c.get("pid"))' 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
}

kill_palmy; sleep 0.4
"$BIN" & APP=$!
sleep 2.2

read X Y W H <<< "$(hyprctl clients -j | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="palmy":
        x,y=c["at"]; w,h=c["size"]; print(x,y,w,h); break')"
if [ -z "${X:-}" ]; then echo "no palmy window appeared"; kill $APP 2>/dev/null; exit 1; fi
echo "recording $BIN at $X,$Y ${W}x${H}"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.2

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   wtype -k "${line#key }" ;;
    type\ *)  wtype -- "${line#type }" ;;
    move\ *)  set -- ${line#move }; hyprctl dispatch "hl.dsp.cursor.move({x=$((X+$1)),y=$((Y+$2))})" >/dev/null 2>&1 ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 1
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
kill $APP 2>/dev/null
sleep 0.4
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
