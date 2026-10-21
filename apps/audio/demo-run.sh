#!/usr/bin/env bash
# What apps/tools/record-app.sh launches for the demo.
#
# It does two things the bare binary cannot: make sure the demo's test media
# exists (generated with ffmpeg, nothing downloaded), and ask Hyprland to float
# the window at its natural size so the recording is not whatever slot the
# tiling layout happened to give it.
# With no sound device (the build VM, headless-record.sh) run it with
# PALMY_AUDIO_SINK=null: the null sink takes the PCM at a sound card's rate,
# so the clock, the gapless join and the analyser all run for real.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Float the window at its natural size. The recorder reads the geometry a
# couple of seconds after launch, so this has to happen before that; if the
# compositor refuses, the recording simply uses whatever size it got.
float_window() {
  local pid="$1" w="$2" h="$3"
  for _ in $(seq 1 25); do
    local addr
    addr=$(hyprctl clients -j | PID="$pid" python3 -c '
import json,sys,os
pid=int(os.environ["PID"])
for c in json.load(sys.stdin):
    if c.get("pid")==pid: print(c["address"]); break' 2>/dev/null)
    if [ -n "${addr:-}" ]; then
      hyprctl dispatch "hl.dsp.window.float({window='address:$addr', state=true})" >/dev/null 2>&1
      hyprctl dispatch "hl.dsp.window.resize({x=$w, y=$h, window='address:$addr', exact=true})" >/dev/null 2>&1
      hyprctl dispatch "hl.dsp.window.center({window='address:$addr'})" >/dev/null 2>&1
      hyprctl dispatch "hl.dsp.window.focus({window='address:$addr'})" >/dev/null 2>&1
      return 0
    fi
    sleep 0.15
  done
}

DIR="$(bash "$HERE/demo-media.sh" "${PALMY_MEDIA_DIR:-/tmp/palmy-demo-audio}")"
export PALMY_MEDIA_DIR="$DIR"
"$HERE/audio.bin" "$DIR/01-ascent-part-1.mp3" &
APP=$!
trap 'kill $APP 2>/dev/null' TERM INT
( sleep 1.0; float_window "$APP" 1240 800 ) >/dev/null 2>&1 &
wait $APP
