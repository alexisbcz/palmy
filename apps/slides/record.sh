#!/usr/bin/env bash
# Record the slides demo while driving it from the keyboard.
#
#   record.sh <out.mp4> <script-file>
#
# This is apps/tools/record-app.sh with the three differences that matter on a
# machine where several agents are running palmy applications at once:
#
#   * The window is found by the **pid this script started**. The shared
#     recorder takes the first window whose class is "palmy", which here is
#     routinely somebody else's application.
#   * The window is floated and resized to the whole output. Presenting opens a
#     fullscreen wlr-layer-shell overlay, and a recording cropped to a tiled
#     window would capture a corner of it.
#   * The window is re-focused before every keystroke, because a window that
#     takes focus mid-take takes the rest of the script with it.
#
# The same lock as the shared recorder is taken, and for the same reason: every
# `wtype` attaches its own virtual keyboard to the seat.
#
# Steps, one per line: `key <X11name>`, `type <text>`, `move <x> <y>`,
# `wait <seconds>`.
set -uo pipefail
OUT="${1:?output mp4}"; SCRIPT="${2:?script file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/slides.bin"
mkdir -p "$(dirname "$OUT")"

# The whole output, minus whatever the bar reserves at the top: the editor's
# own top bar should not be hidden behind the desktop's.
read OW OH TOP <<< "$(hyprctl monitors -j | python3 -c '
import json,sys
m = json.load(sys.stdin)[0]
s = m.get("scale", 1) or 1
r = m.get("reserved", [0, 0, 0, 0])
print(int(m["width"] / s), int(m["height"] / s), r[1] if len(r) > 1 else 0)')"
OW=${OW:-1920}; OH=${OH:-1080}; TOP=${TOP:-0}
OH=$((OH - TOP))

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 1800 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

cleanup() {
  [ -n "${REC:-}" ] && kill -INT "$REC" 2>/dev/null
  [ -n "${APP:-}" ] && kill "$APP" 2>/dev/null
}
trap cleanup EXIT

"$BIN" & APP=$!
sleep 3.0
if ! kill -0 "$APP" 2>/dev/null; then echo "the application exited before it could be recorded"; exit 1; fi

# Float it and give it the whole output. This Hyprland build uses the Lua
# dispatcher API; the old positional syntax is a parse error that silently does
# nothing.
hyprctl dispatch "hl.dsp.window.float({window='pid:$APP'})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.resize({window='pid:$APP', x=$OW, y=$OH, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({window='pid:$APP', x=0, y=$TOP, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$APP'})" >/dev/null 2>&1
sleep 1.2

read X Y W H WS <<< "$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid') == $APP:
        x,y = c['at']; w,h = c['size']
        print(x, y, w, h, c['workspace']['id']); break")"
if [ -z "${X:-}" ]; then echo "the application's window never appeared"; exit 1; fi

hyprctl dispatch "hl.dsp.focus({workspace='$WS'})" >/dev/null 2>&1
sleep 0.6
ACTIVE=$(hyprctl activeworkspace -j | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
if [ "$ACTIVE" != "$WS" ]; then
  echo "note: the window is on workspace $WS but $ACTIVE is showing; recording anyway"
fi
echo "recording $BIN (pid $APP) at $X,$Y ${W}x${H} on workspace $WS"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.4

focus_app() { hyprctl dispatch "hl.dsp.focus({window='pid:$APP'})" >/dev/null 2>&1; }
focus_app

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   focus_app; wtype -k "${line#key }" ;;
    type\ *)  focus_app; wtype -- "${line#type }" ;;
    move\ *)  set -- ${line#move }; hyprctl dispatch "hl.dsp.cursor.move({x=$((X+$1)),y=$((Y+$2))})" >/dev/null 2>&1 ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 1
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null; REC=""
kill $APP 2>/dev/null; APP=""
sleep 0.5
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
