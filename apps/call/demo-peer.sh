#!/usr/bin/env bash
# The thing `record-app.sh` is handed as "the binary".
#
# A call needs two ends, and the recorder frames exactly one window. So this
# starts the far end headless — same pipeline, same codecs, same sockets, no
# window — and then becomes the near end, which is the window that gets
# recorded.
#
# Starting the peer from here rather than beforehand matters: record-app.sh
# kills every window of class "palmy" before it launches this, so anything
# started earlier would be killed. A headless peer has no window and would
# survive that, but it would also still be running from the previous take.
#
# SYNTHETIC SOURCES ONLY. Neither end is given --allow-real-devices, so the
# camera and the microphone are enumerated, listed in the picker, and refused.
# The far end sends SMPTE bars; the near end sends ffmpeg's testsrc2. Two
# different pictures, so "that is the other instance's video" is visible rather
# than asserted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/call.bin"
# Both ends stop themselves. The near end is `exec`d, so this script's own
# EXIT trap would never run, and the recorder kills only the window it framed —
# a far end that outlives its own call would be a stray process holding a pipe.
LIFE=70

# `exec` keeps this pid, so the window that appears in a moment is ours. Float
# it at the size the layout was designed for before record-app.sh measures the
# geometry at t+2.2s — otherwise the recording frames whatever slice of the
# screen the tiler happened to give us.
MYPID=$$
(
	sleep 1.2
	ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid')==$MYPID: print(c['address'])" 2>/dev/null)
	[ -z "$ADDR" ] && exit 0
	hyprctl dispatch setfloating "address:$ADDR" >/dev/null 2>&1
	hyprctl dispatch resizewindowpixel "exact 1180 780,address:$ADDR" >/dev/null 2>&1
	hyprctl dispatch movewindowpixel "exact 40 80,address:$ADDR" >/dev/null 2>&1
	hyprctl dispatch focuswindow "address:$ADDR" >/dev/null 2>&1
) &

"$BIN" --headless \
	--bind 47812 --peer 47811 --name Bob \
	--pattern smptehdbars --autoanswer \
	--volume 0.0 --quit-after "$LIFE" >/tmp/call-demo-peer.log 2>&1 &

exec "$BIN" \
	--bind 47811 --peer 47812 --name Alice \
	--pattern testsrc2 --autocall \
	--volume 0.25 --quit-after "$LIFE"
