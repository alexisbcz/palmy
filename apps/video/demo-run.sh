#!/usr/bin/env bash
# What the recorder launches for the demo.
#
# It does two things the bare binary cannot: build the demo's media, and ask
# Hyprland to float the window at its natural size when there is a Hyprland to
# ask (there is not, under apps/tools/headless-record.sh, and that is fine).
#
# Everything the demo shows is generated here with ffmpeg's lavfi sources. No
# camera, no microphone, no file of the user's — the player is pointed at one
# directory that this script owns, so nothing from ~/Videos can reach a frame of
# the recording or a filename in the repository.
#
# The clip is built to exercise the three features the demo is about:
#
#   * a sidecar `palmy-video-demo.srt`, written below, found on open
#   * a second, *embedded* subtitle stream in the Matroska container
#   * five chapters, from an ffmetadata file
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Float the window at its natural size. The recorder reads the geometry a
# couple of seconds after launch, so this has to happen before that; if the
# compositor refuses — or is the headless one, which has no hyprctl — the
# recording simply uses whatever size it got.
float_window() {
  local pid="$1" w="$2" h="$3"
  command -v hyprctl >/dev/null || return 0
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

DIR="${PALMY_MEDIA_DIR:-/tmp/palmy-demo-video}"
mkdir -p "$DIR"
CLIP="$DIR/palmy-video-demo.mkv"
SIDECAR="$DIR/palmy-video-demo.srt"

# The sidecar. SRT, so the one the player prefers, and the cues run the whole
# length of the clip so there is always something on the plate to look at.
cat > "$SIDECAR" <<'SRT'
1
00:00:00,300 --> 00:00:05,500
A sidecar .srt, found next to the file on open —
two lines, centred inside the picture.

2
00:00:05,800 --> 00:00:13,500
<i>Markup is stripped</i>, and the cue is timed off
the audio clock, not off the frame on screen.

3
00:00:13,800 --> 00:00:25,500
t lists the tracks · c cycles them · v hides them

4
00:00:25,800 --> 00:00:36,000
] and [ change the speed in quarter steps,
0.5x to 2x, and \ resets it.

5
00:00:36,300 --> 00:00:48,000
atempo keeps the sample rate at 48 kHz, so one
output second now carries SPEED seconds of media.

6
00:00:48,300 --> 00:01:00,000
clock = base + (bytes/BPS - latency) x speed
The latency is inside the brackets, not outside.

7
00:01:00,300 --> 00:01:12,000
At 2x the decoder has to deliver 120 fps of a
1080p60 clip. Measured: 119.8. It keeps up.

8
00:01:12,300 --> 00:01:24,000
PgUp and PgDn jump chapters. They are marked on
the scrub bar and listed on the right.

9
00:01:24,300 --> 00:01:40,000
Five chapters, read from the container with
ffprobe -show_chapters.
SRT

# A different dialect for the embedded stream, so switching tracks is visibly a
# different track and not a re-read of the same file.
EMBED="$DIR/embedded.vtt"
cat > "$EMBED" <<'VTT'
WEBVTT

00:00.300 --> 00:00:12.000
This one is the EMBEDDED track, pulled out of the
Matroska container with ffmpeg -map 0:2 -f srt -

00:00:12.200 --> 00:00:26.000
A bitmap track (PGS, DVD, DVB) would be listed as
unsupported instead of silently showing nothing.

00:00:26.200 --> 00:00:48.000
Sidecar and embedded tracks share one parser:
SRT, WebVTT and ASS all become the same cue list.

00:00:48.200 --> 00:01:40.000
The cue covering the clock is found by binary
search from a cached cursor, not by scanning.
VTT

# Five chapters, as ffmpeg metadata.
META="$DIR/chapters.txt"
cat > "$META" <<'META'
;FFMETADATA1
title=palmy video demo clip
[CHAPTER]
TIMEBASE=1/1000
START=0
END=13500
title=Sidecar subtitles
[CHAPTER]
TIMEBASE=1/1000
START=13500
END=25500
title=Switching tracks
[CHAPTER]
TIMEBASE=1/1000
START=25500
END=60000
title=Playback speed
[CHAPTER]
TIMEBASE=1/1000
START=60000
END=84000
title=Chapter marks
[CHAPTER]
TIMEBASE=1/1000
START=84000
END=100000
title=End of the clip
META

if [ ! -f "$CLIP" ]; then
  ffmpeg -y -v error \
    -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=100" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=100" \
    -i "$EMBED" -i "$META" \
    -map 0:v -map 1:a -map 2:s -map_metadata 3 \
    -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 22 \
    -c:a aac -c:s srt \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="English (embedded)" \
    -shortest "$CLIP"
fi

# The player is pointed straight at the clip, so the library it builds is this
# directory and nothing else.
export PALMY_MEDIA_DIR="$DIR"
"$HERE/video.bin" "$CLIP" &
APP=$!
trap 'kill $APP 2>/dev/null' TERM INT
( sleep 1.0; float_window "$APP" 1240 800 ) >/dev/null 2>&1 &
wait $APP
