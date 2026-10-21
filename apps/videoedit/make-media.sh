#!/usr/bin/env bash
# make-media.sh [dir] — the four synthetic clips the window, the benches, the
# self-test's live sections and the demos expect in apps/videoedit/media.
# They are generated, not committed (.gitignore: apps/*/media/*.mp4): lavfi
# test patterns, each with a tone or noise of its own so the mix is audible
# and the clips can be told apart by ear and by level.
#
#   bars     testsrc2      440 Hz sine at 1/8
#   fractal  mandelbrot    660 Hz sine at 1/8
#   life     life          pink noise at 0.2
#   smpte    smptehdbars   1 kHz sine at 1/8
set -euo pipefail
D="${1:-$(cd "$(dirname "$0")" && pwd)/media}"
mkdir -p "$D"
g() { ffmpeg -nostdin -y -v error -f lavfi -i "$2" -f lavfi -i "$3" -t 8 -c:v libx264 -pix_fmt yuv420p -preset veryfast -c:a aac -shortest "$D/$1"; }
g bars.mp4    "testsrc2=s=1280x720:r=30" "sine=f=440:r=48000"
g fractal.mp4 "mandelbrot=s=1280x720:r=30" "sine=f=660:r=48000"
g life.mp4    "life=s=1280x720:r=30:mold=10:ratio=0.1:death_color=#C83232:life_color=#00ff00" "anoisesrc=c=pink:a=0.2:r=48000"
g smpte.mp4   "smptehdbars=s=1280x720:r=30" "sine=f=1000:r=48000"
ls -la "$D"
