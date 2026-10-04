#!/usr/bin/env bash
# What apps/tools/record-app.sh launches for the demo.
#
# It does two things the bare binary cannot: make sure the demo's test media
# exists (generated with ffmpeg, nothing downloaded), and ask Hyprland to float
# the window at its natural size so the recording is not whatever slot the
# tiling layout happened to give it.
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

DIR="${PALMY_MEDIA_DIR:-/tmp/palmy-demo-audio}"
mkdir -p "$DIR"
if [ ! -f "$DIR/01-slow-pulse.mp3" ]; then
  ffmpeg -y -v error -f lavfi -i "gradients=size=600x600:duration=1:speed=0.1:n=4" -frames:v 1 "$DIR/c1.png"
  ffmpeg -y -v error -f lavfi -i "mandelbrot=size=600x600" -frames:v 1 "$DIR/c2.png"
  ffmpeg -y -v error -f lavfi -i "sine=frequency=220:duration=48" -i "$DIR/c1.png" \
    -filter:a "volume='0.3+0.3*sin(2*PI*t/6)':eval=frame" -map 0:a -map 1:v -c:v mjpeg \
    -disposition:v attached_pic -metadata title="Slow Pulse in A" -metadata artist="Test Tones" \
    -metadata album="Signals" -metadata date="2026" -b:a 192k "$DIR/01-slow-pulse.mp3"
  ffmpeg -y -v error -f lavfi -i "aevalsrc='0.3*sin(2*PI*220*t)+0.25*sin(2*PI*277*t)+0.2*sin(2*PI*330*t)+0.12*sin(2*PI*660*t):d=72'" \
    -i "$DIR/c2.png" -map 0:a -map 1:v -c:v mjpeg -disposition:v attached_pic \
    -metadata title="A Major Drone" -metadata artist="Test Tones" -metadata album="Signals" \
    -metadata date="2026" -b:a 192k "$DIR/02-a-major-drone.mp3"
  ffmpeg -y -v error -f lavfi -i "sine=frequency=60:beep_factor=4:duration=36" \
    -metadata title="Beep Factor Four" -metadata artist="Test Tones" -metadata album="Signals" \
    -b:a 192k "$DIR/03-beep-factor-four.mp3"
  ffmpeg -y -v error -f lavfi -i "anoisesrc=color=pink:duration=25:amplitude=0.4" \
    -metadata title="Pink Noise Floor" -metadata artist="Test Tones" -metadata album="Signals" \
    -b:a 192k "$DIR/04-pink-noise.mp3"
  rm -f "$DIR/c1.png" "$DIR/c2.png"
fi
export PALMY_MEDIA_DIR="$DIR"
"$HERE/audio.bin" "$DIR/01-slow-pulse.mp3" &
APP=$!
trap 'kill $APP 2>/dev/null' TERM INT
( sleep 1.0; float_window "$APP" 1240 800 ) >/dev/null 2>&1 &
wait $APP
