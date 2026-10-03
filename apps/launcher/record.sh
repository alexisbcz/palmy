#!/usr/bin/env bash
# Record the launcher while driving it with real input.
#
#   record.sh [out.mp4] [script-file]
#
# This is ../tools/record-app.sh adapted twice over.
#
# 1. The launcher is a wlr-layer-shell overlay, so it is not a toplevel and
#    never appears in `hyprctl clients -j`; the shared recorder cannot find its
#    rectangle. The compositor centres the surface on the output, so the
#    rectangle is computed from the monitor geometry and the launcher's own
#    800x600 instead, and wf-recorder is pointed at that region.
#
# 2. Each `wtype` process brings its own virtual keyboard with its own keymap.
#    Running one per step races the client's keymap reload: a key pressed before
#    the new keymap has been applied resolves against the old one, and arrives
#    as whatever used to live at that keycode — Tab, Escape, a digit. So every
#    step between pointer moves is compiled into a *single* wtype invocation
#    with `-s` for the pauses, which uploads one keymap and then plays the whole
#    sequence against it.
#
# The script format is the shared one: `key <X11name>`, `type <text>`,
# `move <x> <y>` (window-relative), `wait <seconds>`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/launcher.bin"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"

W=800
H=600

read -r MON MW MH MX MY <<<"$(hyprctl monitors -j | python3 -c '
import json,sys
ms = json.load(sys.stdin)
m = ([m for m in ms if m.get("focused")] or ms)[0]
print(m["name"], m["width"], m["height"], m["x"], m["y"])')"
X=$(( MX + (MW - W) / 2 ))
Y=$(( MY + (MH - H) / 2 ))
echo "recording $BIN on $MON at $X,$Y ${W}x${H}"

pkill -x launcher.bin; sleep 0.5
setsid "$BIN" >/dev/null 2>&1 < /dev/null &
sleep 2.0

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast \
  --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.2

ARGS=()
flush() {
  if [ ${#ARGS[@]} -gt 0 ]; then
    wtype "${ARGS[@]}"
    ARGS=()
  fi
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   ARGS+=(-s 120 -k "${line#key }") ;;
    type\ *)  ARGS+=(-s 120 -d 55 "${line#type }") ;;
    wait\ *)  ARGS+=(-s "$(python3 -c "print(int(float('${line#wait }')*1000))")") ;;
    move\ *)  flush
              set -- ${line#move }
              hyprctl dispatch "hl.dsp.cursor.move({x=$((X+$1)),y=$((Y+$2))})" >/dev/null 2>&1 ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"
flush

sleep 1.2
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
pkill -x launcher.bin 2>/dev/null
sleep 0.4
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" \
    | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
