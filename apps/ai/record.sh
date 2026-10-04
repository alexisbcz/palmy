#!/usr/bin/env bash
# Record apps/ai while driving it from the keyboard.
#
#   record.sh [out.mp4] [script-file]
#
# This is apps/tools/record-app.sh with the three changes this shared machine
# turned out to need, all of them learned the hard way:
#
#   * It finds the window by **the pid it started**. The shared recorder takes
#     the first window whose class is "palmy", and with several agents running
#     palmy applications at once that is somebody else's window.
#   * It **re-focuses before every keystroke**. A window that appears mid-take
#     takes the focus, and the keystrokes with it; the first take of this demo
#     lost everything after the halfway mark that way.
#   * It puts a **timeout on stopping wf-recorder**. One take left wf-recorder
#     wedged after SIGINT, holding the shared lock for ten minutes and starving
#     every other agent queued behind it.
#
# It takes /tmp/palmy-record.lock like the shared recorder, and for the same
# reason: every `wtype` attaches its own virtual keyboard to the seat.
#
# Steps, one per line:
#   key <X11name>   wtype -k
#   type <text>     wtype
#   wait <seconds>  sleep
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"
BIN="$HERE/ai.bin"
W_WANT=1560
H_WANT=940
mkdir -p "$(dirname "$OUT")"

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 1800 9; then
	echo "timed out waiting for the recording lock ($LOCK)"
	exit 1
fi
echo "holding the recording lock at $(date +%H:%M:%S)"

cleanup() {
	[ -n "${REC:-}" ] && kill -INT "$REC" 2>/dev/null
	[ -n "${APP:-}" ] && kill -9 "$APP" 2>/dev/null
	return 0
}
trap cleanup EXIT

# 9>&- so the application does not inherit the lock descriptor and keep the
# lock held after this script has exited.
"$BIN" 9>&- & APP=$!
sleep 3.0
if ! kill -0 "$APP" 2>/dev/null; then
	echo "the application exited before it could be recorded"
	exit 1
fi

# Hyprland's own crash notifications sit over the top right of every window.
hyprctl dismissnotify >/dev/null 2>&1

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
if [ -z "${X:-}" ]; then
	echo "the application's window never appeared"
	exit 1
fi

# Be on the workspace the window is on, or the capture is of whatever else is
# showing at those coordinates.
hyprctl dispatch "hl.dsp.focus({workspace='$WS'})" >/dev/null 2>&1
sleep 0.6
echo "recording $BIN (pid $APP) at $X,$Y ${W}x${H} on workspace $WS"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.4

focus_app() {
	hyprctl dispatch "hl.dsp.focus({window='pid:$APP'})" >/dev/null 2>&1
	hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$APP'})" >/dev/null 2>&1
}

while IFS= read -r line; do
	[ -z "$line" ] && continue
	case "$line" in
	\#*) ;;
	key\ *)
		focus_app
		wtype -k "${line#key }"
		;;
	type\ *)
		focus_app
		wtype -- "${line#type }"
		;;
	wait\ *) sleep "${line#wait }" ;;
	*) echo "unknown step: $line" ;;
	esac
done < "$SCRIPT"

sleep 1
kill -INT $REC 2>/dev/null
# wf-recorder has been seen to ignore SIGINT and sit there; do not let it hold
# the shared lock while it does.
for _ in $(seq 1 20); do
	kill -0 $REC 2>/dev/null || break
	sleep 0.5
done
kill -0 $REC 2>/dev/null && { echo "wf-recorder would not stop; killing it"; kill -9 $REC 2>/dev/null; }
wait $REC 2>/dev/null
REC=""
kill -9 $APP 2>/dev/null
APP=""
sleep 0.5

if [ -s "$OUT" ]; then
	D=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
	echo "wrote $OUT (${D}s)"
else
	echo "recording failed"
	exit 1
fi
