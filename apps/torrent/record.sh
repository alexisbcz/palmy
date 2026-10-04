#!/usr/bin/env bash
# Record the torrent client driving a real transfer between two local clients.
#
#   record.sh <out.mp4> <script-file>
#
# This is apps/tools/record-app.sh with the differences that matter on a shared
# machine, taken from apps/videoedit/record.sh:
#
#   * the window is found by THE PID WE STARTED, never by "the first window of
#     class palmy" — a dozen agents run palmy applications here at once and the
#     first match is routinely somebody else's;
#   * the window is re-focused before EVERY keystroke, because a notification or
#     another agent's window taking focus silently swallows the rest of the
#     script (and types into their app instead);
#   * the lock fd is closed in children (9>&-), so an app that outlives the
#     recorder does not hold the shared recording lock forever.
#
# The application is started with --demo, which stages a complete local swarm:
# a tracker and a seeding client, both children of it, both bound to 127.0.0.1,
# serving a payload it generated from a seeded PRNG. Nothing in the recording
# touches the network.
set -uo pipefail
OUT="${1:?output mp4}"; SCRIPT="${2:?script file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/torrent.bin"
W_WANT=1500
H_WANT=900
mkdir -p "$(dirname "$OUT")"

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 2400 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

cleanup() {
  [ -n "${REC:-}" ] && kill -INT "$REC" 2>/dev/null
  [ -n "${APP:-}" ] && kill "$APP" 2>/dev/null
}
trap cleanup EXIT

"$BIN" --demo 9>&- & APP=$!
sleep 4.0
if ! kill -0 "$APP" 2>/dev/null; then echo "the application exited before it could be recorded"; exit 1; fi

hyprctl dispatch "hl.dsp.window.float({window='pid:$APP'})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.resize({window='pid:$APP', x=$W_WANT, y=$H_WANT, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.move({window='pid:$APP', x=60, y=60, exact=true})" >/dev/null 2>&1
hyprctl dispatch "hl.dsp.window.bring_to_top({window='pid:$APP'})" >/dev/null 2>&1
sleep 1.0

read X Y W H WS <<< "$(APP=$APP python3 -c '
import json,os,subprocess
want = int(os.environ["APP"])
cs = json.loads(subprocess.run(["hyprctl","clients","-j"],capture_output=True,text=True).stdout)
for c in cs:
    if c.get("pid") == want:
        x,y = c["at"]; w,h = c["size"]
        print(x, y, w, h, c["workspace"]["id"]); break')"
if [ -z "${X:-}" ]; then echo "no window appeared for pid $APP"; exit 1; fi

hyprctl dispatch "hl.dsp.focus({workspace='$WS'})" >/dev/null 2>&1
sleep 0.6
echo "recording $BIN (pid $APP) at $X,$Y ${W}x${H} on workspace $WS"

wf-recorder -g "$X,$Y ${W}x${H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite 9>&- >/dev/null 2>&1 &
REC=$!
sleep 1.5

focus_app() { hyprctl dispatch "hl.dsp.focus({window='pid:$APP'})" >/dev/null 2>&1; }

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
