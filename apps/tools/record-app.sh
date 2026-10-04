#!/usr/bin/env bash
# Record a palmy app while driving it with real input.
#
#   record-app.sh <binary> <out.mp4> <script-file>
#
# The script file is a list of commands, one per line, interpreted here:
#   key <X11name>     wtype -k  (Tab, Return, Escape, Down, Up, BackSpace, ...)
#   type <text>       wtype
#   move <dx> <dy>    move the pointer to window-relative coordinates
#   wait <seconds>    sleep
#
# wf-recorder captures the compositor's own composite of the window, so what
# lands in the video is exactly what the display shows.
set -uo pipefail
BIN="${1:?binary}"; OUT="${2:?output mp4}"; SCRIPT="${3:?script file}"
mkdir -p "$(dirname "$OUT")"

# Only one recording at a time. wtype attaches a virtual keyboard to the seat,
# so two concurrent recordings type into each other's windows — and an overlay
# holding an exclusive keyboard grab swallows the lot. Serialise on a lock.
LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 900 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

kill_palmy() {
  for pid in $(hyprctl clients -j | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="palmy": print(c.get("pid"))' 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
}

kill_palmy; sleep 0.4

# 9>&- closes the lock fd in the child. Without it every launched process
# inherits the flock: wl-copy (which kit.clipboard_set starts, and which
# daemonises to serve the selection) then holds the lock for as long as it owns
# the clipboard, and an app that outlives its recorder holds it forever. That
# stalled every agent's recordings for half an hour at a time.
"$BIN" 9>&- & APP=$!
sleep 2.2

# Match the window by THE PID WE STARTED, not by class. A dozen palmy
# applications can be on this desktop at once, and "the first window of class
# palmy" is routinely somebody else's -- one take was 58 seconds of a terminal,
# another recorded a different agent's app while wtype typed into it.
read X Y W H <<< "$(APP=$APP python3 -c '
import json,os,subprocess,sys
want = int(os.environ["APP"])
cs = json.loads(subprocess.run(["hyprctl","clients","-j"],capture_output=True,text=True).stdout)
for c in cs:
    if c.get("pid") == want:
        x,y = c["at"]; w,h = c["size"]; print(x,y,w,h); break')"
if [ -z "${X:-}" ]; then echo "no window appeared for pid $APP"; kill $APP 2>/dev/null; exit 1; fi
echo "recording $BIN at $X,$Y ${W}x${H}"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite 9>&- >/dev/null 2>&1 &
REC=$!
sleep 1.2

# Re-focus our own window before every keystroke. wtype attaches a virtual
# keyboard to the seat, so it types into whatever holds focus -- and a
# notification or another agent's window taking focus mid-take silently
# swallows the rest of the script, or worse, types into someone else's app.
refocus() { hyprctl dispatch focuswindow "pid:$APP" >/dev/null 2>&1; }

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   refocus; wtype -k "${line#key }" ;;
    type\ *)  refocus; wtype -- "${line#type }" ;;
    move\ *)  set -- ${line#move }; hyprctl dispatch "hl.dsp.cursor.move({x=$((X+$1)),y=$((Y+$2))})" >/dev/null 2>&1 ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 1
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
kill $APP 2>/dev/null
sleep 0.4
if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; exit 1
fi
