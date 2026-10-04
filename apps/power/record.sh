#!/usr/bin/env bash
# Record power while driving it from the keyboard.
#
#   record.sh [out.mp4] [script-file]
#
# This is apps/tools/record-app.sh with one difference that matters on a shared
# machine: it finds the window by the **pid it started**, not by taking the
# first window whose class is "palmy". Several agents run palmy applications
# here at once, and the shared recorder's first-match query hands back someone
# else's window — one agent recorded 58 seconds of a terminal that way, and the
# stray `wtype` keystrokes that go with it land in whatever is focused.
# Matching on the pid cannot pick the wrong window.
#
# It also makes the window floating, puts it where it asked to be, switches to
# its workspace, and re-focuses it before every single keystroke, because a
# window that steals focus mid-take silently swallows the rest of the script.
#
# The same lock as the shared recorder is taken, and for the same reason: every
# `wtype` attaches its own virtual keyboard to the seat, so two recordings at
# once type into each other's windows. Record once; a re-queued take starves
# every other agent waiting on the lock.
#
# Steps, one per line:
#   key <X11name>   wtype -k
#   type <text>     wtype
#   move <x> <y>    pointer to a window-relative position
#   wait <seconds>  sleep
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"
BIN="$HERE/power.bin"
W_WANT=1160
H_WANT=880
mkdir -p "$(dirname "$OUT")"

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

# The application is started with fd 9 closed. That fd is the flock this
# script holds, and a child that inherits it keeps the lock for as long as it
# lives — `wl-copy` forks a server that holds the selection indefinitely, so a
# single clipboard copy during a take left the shared recording lock held after
# the recording had finished, with every other agent on this machine queued
# behind it. `9>&-` is the whole fix.
"$BIN" 9>&- & APP=$!
sleep 3.0

if ! kill -0 "$APP" 2>/dev/null; then echo "the application exited before it could be recorded"; exit 1; fi

# Float it, give it the size it asked for, and move to its workspace. This
# Hyprland build uses the Lua dispatcher API; the old positional syntax is a
# parse error that silently does nothing.
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

# Be on the workspace the window is on, or the capture is of whatever else is
# showing at those coordinates. This Hyprland build switches workspaces through
# `hl.dsp.focus({workspace = "N"})` — `workspace.change_id` renames one, which
# answers "ID is taken" and leaves you where you were.
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

# Re-focus before every keystroke. Other agents launch windows on this machine
# while a recording runs, and a window that takes focus takes the keystrokes
# with it — the first take of this demo lost everything after the halfway mark
# that way, with no sign of it in the video except an application that stopped
# responding.
focus_app() { hyprctl dispatch "hl.dsp.focus({window='pid:$APP'})" >/dev/null 2>&1; }

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
