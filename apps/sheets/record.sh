#!/usr/bin/env bash
# Record sheets while driving it from the keyboard.
#
#   record.sh <out.mp4> <script-file>
#
# This is apps/tools/record-app.sh with the two fixes that matter on a machine
# where several agents are running palmy applications at once:
#
#   * the window is found by the **pid this script started**, not by taking the
#     first window whose class is "palmy" — that query hands back whichever
#     application happens to be first, and the recording is then of somebody
#     else's window;
#   * focus is taken back before every keystroke, because a window that opens
#     mid-take steals the keyboard and the rest of the script types into it,
#     which looks in the video like an application that simply stopped
#     responding.
#
# It also floats the window at a fixed size and switches to its workspace, and
# it sweeps away the desktop's crash notifications for the length of the take —
# they land in the top-right corner, which is where this demo's new columns
# are.
#
# The same lock as the shared recorder is taken, and for the same reason: every
# `wtype` attaches its own virtual keyboard to the seat.
#
# Steps, one per line:
#   key <X11name>   wtype -k
#   type <text>     wtype
#   wait <seconds>  sleep
set -uo pipefail
OUT="${1:?output mp4}"; SCRIPT="${2:?script file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/sheets.bin"
W_WANT=1500
H_WANT=900
mkdir -p "$(dirname "$OUT")"

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 2400 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

cleanup() {
  [ -n "${SWEEP:-}" ] && kill "$SWEEP" 2>/dev/null
  [ -n "${REC:-}" ] && kill -INT "$REC" 2>/dev/null
  [ -n "${APP:-}" ] && kill "$APP" 2>/dev/null
}
trap cleanup EXIT

( for _ in $(seq 1 400); do hyprctl dismissnotify >/dev/null 2>&1; sleep 1.2; done ) & SWEEP=$!

"$BIN" & APP=$!
sleep 3.0
if ! kill -0 "$APP" 2>/dev/null; then echo "the application exited before it could be recorded"; exit 1; fi

# This Hyprland build uses the Lua dispatcher API; the old positional syntax is
# a parse error that silently does nothing.
hyprctl dispatch "hl.dsp.window.float({window='pid:$APP'})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.resize({window='pid:$APP', x=$W_WANT, y=$H_WANT, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({window='pid:$APP', x=60, y=60, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$APP'})" >/dev/null 2>&1
sleep 1.0

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

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   focus_app; wtype -k "${line#key }" ;;
    type\ *)  focus_app; wtype -- "${line#type }" ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 1
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null; REC=""
kill $APP 2>/dev/null; APP=""
kill $SWEEP 2>/dev/null; SWEEP=""
sleep 0.5
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
