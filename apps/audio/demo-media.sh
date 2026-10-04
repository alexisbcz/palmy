#!/usr/bin/env bash
# Generate the demo's test media. Nothing is downloaded and nothing is
# recorded from a device: every sample comes out of ffmpeg's lavfi sources, and
# the cover art is a generated image. The user's own library is never touched
# and never appears in a recording.
#
#   demo-media.sh [dir]      # default /tmp/palmy-demo-audio
#
# The first two tracks are the gapless demo: one continuous frequency sweep,
# 100 Hz climbing to 7.6 kHz, cut in half and saved as two files. Played back
# to back it should sound and *look* like one unbroken glide — the spectrum
# marches up through the bars and keeps going across the track change. It also
# climbs straight through 4 kHz, which is where the old 8 kHz analysis rate
# stopped being able to represent anything at all.
set -uo pipefail

DIR="${1:-${PALMY_MEDIA_DIR:-/tmp/palmy-demo-audio}}"
mkdir -p "$DIR"

if [ -f "$DIR/01-ascent-part-1.mp3" ] && [ -f "$DIR/02-ascent-part-2.mp3" ]; then
  echo "$DIR"
  exit 0
fi

# Two covers, so the join is visible as well as audible.
ffmpeg -y -v error -f lavfi -i "gradients=size=600x600:duration=1:speed=0.1:n=4" \
  -frames:v 1 "$DIR/c1.png"
ffmpeg -y -v error -f lavfi -i "mandelbrot=size=600x600" -frames:v 1 "$DIR/c2.png"

# A linear chirp has phase 2*PI*(f0*t + (k/2)*t^2) with k = (f1-f0)/T.
# Part one: 100 Hz -> 3400 Hz over 16 s, so k/2 = 103.125.
# Part two: 3400 Hz -> 7600 Hz over 16 s, so k/2 = 131.25.
ffmpeg -y -v error \
  -f lavfi -i "aevalsrc='0.55*sin(2*PI*(100*t+103.125*t*t))':s=48000:d=16" \
  -i "$DIR/c1.png" -map 0:a -map 1:v -c:v mjpeg -disposition:v attached_pic \
  -metadata title="Ascent, Part One" -metadata artist="Test Tones" \
  -metadata album="Gapless" -metadata date="2026" \
  -b:a 192k "$DIR/01-ascent-part-1.mp3"

ffmpeg -y -v error \
  -f lavfi -i "aevalsrc='0.55*sin(2*PI*(3400*t+131.25*t*t))':s=48000:d=16" \
  -i "$DIR/c2.png" -map 0:a -map 1:v -c:v mjpeg -disposition:v attached_pic \
  -metadata title="Ascent, Part Two" -metadata artist="Test Tones" \
  -metadata album="Gapless" -metadata date="2026" \
  -b:a 192k "$DIR/02-ascent-part-2.mp3"

# A couple more so the playlist is a playlist.
ffmpeg -y -v error -f lavfi \
  -i "aevalsrc='0.3*sin(2*PI*220*t)+0.25*sin(2*PI*277*t)+0.2*sin(2*PI*330*t)+0.12*sin(2*PI*5200*t):s=48000:d=40'" \
  -metadata title="A Major Drone" -metadata artist="Test Tones" \
  -metadata album="Gapless" -metadata date="2026" -b:a 192k "$DIR/03-a-major-drone.mp3"

ffmpeg -y -v error -f lavfi -i "anoisesrc=color=pink:duration=25:amplitude=0.4:sample_rate=48000" \
  -metadata title="Pink Noise Floor" -metadata artist="Test Tones" \
  -metadata album="Gapless" -b:a 192k "$DIR/04-pink-noise.mp3"

rm -f "$DIR/c1.png" "$DIR/c2.png"
echo "$DIR"
