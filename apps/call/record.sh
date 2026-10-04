#!/usr/bin/env bash
# Record a real call between two instances of this application.
#
#   record.sh <out.mp4> <script-file>
#
# Why this is not `apps/tools/record-app.sh`:
#
#   * A call needs **two** windows, and the shared recorder launches one
#     binary and frames one window.
#   * The shared recorder finds its window with "the first client whose class
#     is palmy". Several agents run palmy applications on this machine at
#     once, and that query hands back whichever one the compositor lists
#     first — one agent ended up with a recording of a terminal. Both windows
#     here are found by **the pid this script started**, which cannot pick the
#     wrong one.
#   * A window that takes focus mid-script takes the keystrokes with it, and
#     the video gives no sign of it beyond an application that stops
#     responding. Focus is restored to the driven window before every
#     keystroke.
#
# The same `/tmp/palmy-record.lock` is taken, for the same reason the shared
# recorder takes it: every `wtype` attaches its own virtual keyboard to the
# seat, so two recordings at once type into each other's windows.
#
# SYNTHETIC SOURCES ONLY. Neither instance is given `--allow-real-devices`, so
# the camera and the microphone are enumerated, shown in the picker, and
# refused — see `start_media` in main.odin, which substitutes the synthetic
# source even if a real one were somehow selected. The left window sends
# ffmpeg's `testsrc2`; the right sends SMPTE bars. Two different pictures, so
# "each window is showing the other instance's video" is visible rather than
# asserted.
#
# Steps, one per line, driven against the left window:
#   key <X11name>   wtype -k
#   type <text>     wtype
#   wait <seconds>  sleep
set -uo pipefail
OUT="${1:?output mp4}"; SCRIPT="${2:?script file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/call.bin"
LIFE=140
W=946
H=980
mkdir -p "$(dirname "$OUT")"

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 2700 9; then
	echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

cleanup() {
	[ -n "${REC:-}" ] && kill -INT "$REC" 2>/dev/null
	[ -n "${A:-}" ] && kill "$A" 2>/dev/null
	[ -n "${B:-}" ] && kill "$B" 2>/dev/null
}
trap cleanup EXIT

# The right-hand instance answers by itself; the left one is the one the
# script drives, and it dials on startup.
"$BIN" --bind 47812 --peer 47811 --name Bob \
	--pattern smptehdbars --autoanswer --volume 0.0 --quit-after "$LIFE" &
B=$!
sleep 0.8
"$BIN" --bind 47811 --peer 47812 --name Alice \
	--pattern testsrc2 --autocall --volume 0.25 --quit-after "$LIFE" &
A=$!
sleep 3.0

for pid in "$A" "$B"; do
	if ! kill -0 "$pid" 2>/dev/null; then echo "instance $pid exited before it could be recorded"; exit 1; fi
done

# This Hyprland build takes the Lua dispatcher API. The old positional syntax
# (`dispatch setfloating address:0x…`) parses as nothing and silently does
# nothing, which is how an earlier attempt ended up recording a tiled window a
# third of the intended size.
place() { # pid x y
	hyprctl dispatch "hl.dsp.window.float({window='pid:$1'})" >/dev/null 2>&1
	hyprctl dispatch "hl.dsp.window.resize({window='pid:$1', x=$W, y=$H, exact=true})" >/dev/null 2>&1
	hyprctl dispatch "hl.dsp.window.move({window='pid:$1', x=$2, y=$3, exact=true})" >/dev/null 2>&1
	hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$1'})" >/dev/null 2>&1
}
place "$A" 4 48
place "$B" 964 48
sleep 1.2

read X Y RW RH WS <<< "$(hyprctl clients -j | python3 -c "
import json, sys
cl = json.load(sys.stdin)
mine = [c for c in cl if c.get('pid') in ($A, $B)]
if len(mine) != 2:
    sys.exit(0)
x0 = min(c['at'][0] for c in mine); y0 = min(c['at'][1] for c in mine)
x1 = max(c['at'][0] + c['size'][0] for c in mine)
y1 = max(c['at'][1] + c['size'][1] for c in mine)
print(x0, y0, x1 - x0, y1 - y0, mine[0]['workspace']['id'])")"
if [ -z "${X:-}" ]; then echo "both windows never appeared"; exit 1; fi

# Be on the workspace the windows are on, or the capture is of whatever else
# happens to be at those coordinates.
hyprctl dispatch "hl.dsp.focus({workspace='$WS'})" >/dev/null 2>&1
sleep 0.6
ACTIVE=$(hyprctl activeworkspace -j | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
[ "$ACTIVE" != "$WS" ] && echo "note: windows are on workspace $WS but $ACTIVE is showing"
echo "recording Alice(pid $A) + Bob(pid $B) at $X,$Y ${RW}x${RH} on workspace $WS"

wf-recorder -g "$X,$Y ${RW}x${RH}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.6

focus_alice() { hyprctl dispatch "hl.dsp.focus({window='pid:$A'})" >/dev/null 2>&1; }
focus_alice

while IFS= read -r line; do
	[ -z "$line" ] && continue
	case "$line" in
		\#*) ;;
		key\ *)   focus_alice; wtype -k "${line#key }" ;;
		type\ *)  focus_alice; wtype -- "${line#type }" ;;
		wait\ *)  sleep "${line#wait }" ;;
		*) echo "unknown step: $line" ;;
	esac
done < "$SCRIPT"

sleep 1.2
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null; REC=""
kill $A 2>/dev/null; A=""
kill $B 2>/dev/null; B=""
sleep 0.5
if [ -s "$OUT" ]; then
	ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" |
		xargs -I{} echo "wrote $OUT ({}s)"
else
	echo "recording failed"; exit 1
fi
