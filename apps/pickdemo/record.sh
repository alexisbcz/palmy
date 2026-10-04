#!/usr/bin/env bash
# Record the file picker while driving it from the keyboard.
#
#   record.sh [out.mp4] [script-file]
#
# This is apps/tools/record-app.sh with three differences, each of which cost a
# take to learn:
#
#  1. It finds the window by the **pid it started**, not by taking the first
#     window of class "palmy". Several agents run palmy applications on this
#     machine at once, and the shared recorder's first-match query hands back
#     somebody else's window.
#  2. It re-focuses that window before every keystroke, because a window that
#     opens mid-recording takes the focus and the keystrokes with it.
#  3. It understands a `chord` step, so a modifier shortcut can be driven:
#     `chord ctrl h` is `wtype -M ctrl -k h -m ctrl`. The picker's commands are
#     all on Ctrl precisely so that the printable keys are free for type-ahead,
#     and a recording that could not hold a modifier could not show them.
#
# The same lock as the shared recorder is taken, and for the same reason: every
# `wtype` attaches its own virtual keyboard to the seat, so two recordings at
# once type into each other's windows and ruin both takes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"
BIN="$HERE/pickdemo.bin"
FIXTURE=/tmp/palmy-pickdemo
W_WANT=1200
H_WANT=800
mkdir -p "$(dirname "$OUT")"

bash "$HERE/fixture.sh" "$FIXTURE" >/dev/null

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

# 9>&- closes the lock fd in the child. Without it every process this starts
# inherits the flock, and one that outlives the recorder holds the lock for as
# long as it runs -- which stalls every other agent's recording.
"$BIN" "$FIXTURE" 9>&- & APP=$!
sleep 2.5
if ! kill -0 "$APP" 2>/dev/null; then echo "the application exited before it could be recorded"; exit 1; fi

# Float it, size it, and move to its workspace. This Hyprland build uses the
# Lua dispatcher API; the old positional syntax is a parse error that silently
# does nothing.
hyprctl dispatch "hl.dsp.window.float({window='pid:$APP'})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.resize({window='pid:$APP', x=$W_WANT, y=$H_WANT, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({window='pid:$APP', x=80, y=80, exact=true})" >/dev/null 2>&1
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

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite 9>&- >/dev/null 2>&1 &
REC=$!
sleep 1.4

focus_app() { hyprctl dispatch "hl.dsp.focus({window='pid:$APP'})" >/dev/null 2>&1; }

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   focus_app; wtype -k "${line#key }" ;;
    chord\ *) set -- ${line#chord }; focus_app; wtype -M "$1" -k "$2" -m "$1" ;;
    type\ *)  focus_app; wtype -d 28 -- "${line#type }" ;;
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
