#!/usr/bin/env bash
# Generate the demo's test media. Nothing is downloaded and nothing is
# recorded from a device: every sample comes out of ffmpeg's lavfi sources, and
# the cover art is a generated image. The user's own library is never touched
# and never appears in a recording.
#
#   demo-media.sh [dir]      # default /tmp/palmy-demo-audio
#
# The first two tracks are the gapless demo: one continuous frequency sweep,
# 100 Hz climbing to 16 kHz, cut in half and saved as two files. Played back
# to back it should sound and *look* like one unbroken glide — the spectrum
# marches up through the bars and keeps going across the track change. It also
# climbs straight through 4 and 8 kHz, where the old 8 and 16 kHz analysis
# rates stopped being able to represent anything at all; the analyser now
# reaches 24 kHz.
#
# The fifth is an "audiobook": four chapters, each a different chord, so the
# chapter marks, the list and ] / [ have something to show.
set -uo pipefail

DIR="${1:-${PALMY_MEDIA_DIR:-/tmp/palmy-demo-audio}}"
mkdir -p "$DIR"

if [ -f "$DIR/01-ascent-part-1.mp3" ] && [ -f "$DIR/02-ascent-part-2.mp3" ] && [ -f "$DIR/05-audiobook.m4a" ]; then
  echo "$DIR"
  exit 0
fi

# Two covers, so the join is visible as well as audible.
ffmpeg -y -v error -f lavfi -i "gradients=size=600x600:duration=1:speed=0.1:n=4" \
  -frames:v 1 "$DIR/c1.png"
ffmpeg -y -v error -f lavfi -i "mandelbrot=size=600x600" -frames:v 1 "$DIR/c2.png"

# A linear chirp has phase 2*PI*(f0*t + (k/2)*t^2) with k = (f1-f0)/T.
# Part one: 100 Hz -> 3400 Hz over 16 s, so k/2 = 103.125.
# Part two: 3400 Hz -> 16000 Hz over 16 s, so k/2 = 393.75.
ffmpeg -y -v error \
  -f lavfi -i "aevalsrc='0.55*sin(2*PI*(100*t+103.125*t*t))':s=48000:d=16" \
  -i "$DIR/c1.png" -map 0:a -map 1:v -c:v mjpeg -disposition:v attached_pic \
  -metadata title="Ascent, Part One" -metadata artist="Test Tones" \
  -metadata album="Gapless" -metadata date="2026" \
  -b:a 192k "$DIR/01-ascent-part-1.mp3"

ffmpeg -y -v error \
  -f lavfi -i "aevalsrc='0.55*sin(2*PI*(3400*t+393.75*t*t))':s=48000:d=16" \
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

cat > "$DIR/chapters.txt" <<'META'
;FFMETADATA1
title=The Four Rooms
artist=Test Tones
album=Audiobook
[CHAPTER]
TIMEBASE=1/1000
START=0
END=15000
title=Prologue
[CHAPTER]
TIMEBASE=1/1000
START=15000
END=35000
title=One: The Low Room
[CHAPTER]
TIMEBASE=1/1000
START=35000
END=55000
title=Two: The High Room
[CHAPTER]
TIMEBASE=1/1000
START=55000
END=70000
title=Epilogue
META
ffmpeg -y -v error -f lavfi \
  -i "aevalsrc='0.3*sin(2*PI*if(lt(t,15),220,if(lt(t,35),110,if(lt(t,55),1760,440)))*t)+0.2*sin(2*PI*if(lt(t,15),330,if(lt(t,35),165,if(lt(t,55),2640,660)))*t)+0.1*sin(2*PI*if(lt(t,35),3000,if(lt(t,55),12000,6000))*t)':s=48000:d=70" \
  -i "$DIR/chapters.txt" -map 0:a -map_metadata 1 -map_chapters 1 \
  -c:a aac -b:a 160k "$DIR/05-audiobook.m4a"

rm -f "$DIR/c1.png" "$DIR/c2.png" "$DIR/chapters.txt"
echo "$DIR"
