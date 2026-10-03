#!/usr/bin/env bash
# Record the nested compositor while driving it with real input.
#
#   record.sh <out.mp4> <script-file>
#
# The compositor is started in --overlay mode: a layer-shell surface above
# everything on the host, with the keyboard taken exclusively. That is what
# makes a recording reproducible here — nothing else on the host can draw over
# it or steal the keystrokes while the script runs.
#
# Steps, one per line:
#   key <X11name>   wtype -k
#   type <text>     wtype
#   move <x> <y>    pointer to a position inside the compositor
#   wait <seconds>  sleep
set -uo pipefail
OUT="${1:?output mp4}"; SCRIPT="${2:?script file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/wm.bin"
mkdir -p "$(dirname "$OUT")"

pkill -9 -x wm.bin 2>/dev/null
sleep 0.5

"$BIN" --overlay --seconds=120 & APP=$!
sleep 2.4

read X Y W H <<< "$(hyprctl layers -j | python3 -c '
import json,sys
d=json.load(sys.stdin)
for mon,v in d.items():
    for lvl,ls in v.get("levels",{}).items():
        for l in ls:
            if l.get("namespace")=="palmy-wm":
                print(l["x"], l["y"], l["w"], l["h"]); raise SystemExit')"
if [ -z "${X:-}" ]; then echo "the compositor layer never appeared"; kill $APP 2>/dev/null; exit 1; fi
echo "recording at $X,$Y ${W}x${H}"

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
pkill -9 -x wm.bin 2>/dev/null
sleep 0.4
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
