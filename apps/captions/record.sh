#!/usr/bin/env bash
# Record the captions demo while driving it from the keyboard.
#
#   record.sh [out.mp4] [script-file]
#
# This is apps/tools/record-app.sh with the two changes that matter on a
# machine where several agents run palmy applications at once:
#
#   * the window is found by the **pid this script started**, not by taking the
#     first window whose class is "palmy" — that first-match query hands back
#     somebody else's application, and the resulting video is of their window;
#   * focus is taken back before every keystroke, because a window that opens
#     mid-take steals the rest of the script.
#
# The same `/tmp/palmy-record.lock` is held, and for the same reason: every
# `wtype` attaches its own virtual keyboard to the seat.
#
# The clip the demo transcribes is **synthesised here with espeak-ng**. This
# machine has a real microphone and nothing from it belongs in a recording, a
# screenshot or a repository; synthetic speech is also the only kind whose
# words are known in advance, which is what makes the transcription assertable.
# It is generated into the cache directory, not the source tree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"
BIN="$HERE/captions.bin"
W_WANT=1500
H_WANT=940
mkdir -p "$(dirname "$OUT")"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/palmy-captions"
MEDIA="$CACHE/demo"
CLIP="$MEDIA/talk.mp4"
NARRATION="Welcome to the palmy captions demo. \
This application transcribes speech on your own machine, with no network at all. \
The waveform below comes straight from ffmpeg. \
Each caption carries a start time, an end time, and text you can edit in place. \
Reading speed is measured in characters per second, because a transcript dump \
is not the same thing as usable captions. \
When you are happy, export to SubRip, WebVTT, or Advanced SSA."

if [ ! -s "$CLIP" ]; then
  echo "synthesising the demo clip with espeak-ng (no microphone is opened)"
  mkdir -p "$MEDIA"
  espeak-ng -w "$MEDIA/narration.wav" -s 145 -v en-gb "$NARRATION" || exit 1
  ffmpeg -v error -y \
    -f lavfi -i "gradients=s=1280x720:c0=0x1b2a4a:c1=0x6d3b78:x0=0:y0=0:x1=1280:y1=720:nb_colors=3:d=40:r=25" \
    -i "$MEDIA/narration.wav" \
    -vf "drawtext=text='palmy captions':fontsize=64:fontcolor=white@0.35:x=(w-text_w)/2:y=90,drawgrid=w=160:h=90:t=1:c=white@0.06" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$CLIP" || exit 1
  rm -f "$MEDIA/narration.wav"
fi

# A previous take leaves its exports here; clear them so the folder list and
# the demo are the same on every run.
find "$MEDIA" -maxdepth 1 -type f ! -name 'talk.mp4' -delete

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 3600 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

cleanup() {
  [ -n "${TOPPER:-}" ] && kill "$TOPPER" 2>/dev/null
  [ -n "${REC:-}" ] && kill -INT "$REC" 2>/dev/null
  [ -n "${APP:-}" ] && kill "$APP" 2>/dev/null
}
trap cleanup EXIT

# Started from the media directory, so the folder list has the clip in it.
(cd "$MEDIA" && exec "$BIN") & APP=$!
sleep 3.0
if ! kill -0 "$APP" 2>/dev/null; then echo "the application exited before it could be recorded"; exit 1; fi

# Float it at the size it asked for. This Hyprland build uses the Lua
# dispatcher API; the old positional syntax is a parse error that silently
# does nothing.
hyprctl dispatch "hl.dsp.window.float({window='pid:$APP'})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.resize({window='pid:$APP', x=$W_WANT, y=$H_WANT, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({window='pid:$APP', x=60, y=50, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$APP'})" >/dev/null 2>&1
sleep 1.0

read X Y W H WS <<< "$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid') == $APP:
        x,y = c['at']; w,h = c['size']
        print(x, y, w, h, c['workspace']['id']); break")"
if [ -z "${X:-}" ]; then echo "the application's window never appeared"; exit 1; fi

# Be on the workspace the window is on, or the capture is of whatever else
# happens to be at those coordinates.
hyprctl dispatch "hl.dsp.focus({workspace='$WS'})" >/dev/null 2>&1
sleep 0.6
ACTIVE=$(hyprctl activeworkspace -j | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
if [ "$ACTIVE" != "$WS" ]; then
  echo "note: the window is on workspace $WS but $ACTIVE is showing; recording anyway"
fi
echo "recording $BIN (pid $APP) at $X,$Y ${W}x${H} on workspace $WS"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.4

# Keep the window on top for the whole take. Other agents launch applications
# on this machine while a recording runs, and a window that appears over this
# one is simply what the capture records — one take came back as somebody
# else's video call. Re-raising twice a second costs nothing and cannot
# disturb anyone, because this process is holding the recording lock.
(
  while kill -0 "$APP" 2>/dev/null; do
    hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$APP'})" >/dev/null 2>&1
    sleep 0.5
  done
) & TOPPER=$!

# The focus change is asynchronous: without a moment for the compositor to
# follow through, the first keystroke after it is delivered to whatever had
# focus before. That cost one take its opening keypress, and every step after
# it was then interpreted as a command by an application with no file open.
focus_app() {
  hyprctl dispatch "hl.dsp.focus({window='pid:$APP'})" >/dev/null 2>&1
  sleep 0.08
}

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
