#!/usr/bin/env bash
# record.sh [out.mp4] [script-file]
#
# Records the greeter running against the mock greetd in ./mock.
#
# Why this is not apps/tools/record-app.sh: the greeter is a wlr-layer-shell
# OVERLAY surface, not a toplevel, so `hyprctl clients` has no window rect for
# the shared recorder to pass to `wf-recorder -g`. A layer surface covers the
# whole output, so the output is what gets captured: `wf-recorder -o <name>`.
#
# It takes the same lock the shared recorder takes (/tmp/palmy-record.lock),
# because this greeter asks for an EXCLUSIVE keyboard grab: while it is up it
# is the only thing on the machine that receives key events, so no other
# recording may be driving `wtype` at the same time.
#
# Script file format, as record-app.sh:
#   key <X11name> | type <text> | wait <seconds>
# plus:
#   shot <name>   grim the output to <out>.<name>.png
#
# Nothing here touches greetd, sddm, display-manager, any systemd unit or
# /etc. The only server involved is ./mock/mock.bin on a socket under
# $XDG_RUNTIME_DIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"
SOCK="${SOCK:-${XDG_RUNTIME_DIR:-/tmp}/greeter-demo-greetd.sock}"
mkdir -p "$(dirname "$OUT")"

[ -x "$HERE/greeter.bin" ]     || { echo "build apps/greeter first"; exit 1; }
[ -x "$HERE/mock/mock.bin" ]   || { echo "build apps/greeter/mock first"; exit 1; }

MON="${MON:-$(hyprctl monitors -j 2>/dev/null | python3 -c '
import json,sys
ms=json.load(sys.stdin)
print(next((m["name"] for m in ms if m.get("focused")), ms[0]["name"]) if ms else "")')}"
[ -z "$MON" ] && { echo "no monitor found"; exit 1; }

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 900 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock; recording output $MON"

APP=""; REC=""; MOCK=""
cleanup() {
  [ -n "$APP" ]  && kill "$APP"  2>/dev/null
  [ -n "$REC" ]  && kill -INT "$REC" 2>/dev/null
  [ -n "$MOCK" ] && kill "$MOCK" 2>/dev/null
  rm -f "$SOCK"
}
trap cleanup EXIT

# The mock greetd. It never authenticates anyone against the system: the
# password check is a string compare against --password.
rm -f "$SOCK"
"$HERE/mock/mock.bin" --sock "$SOCK" > "${OUT%.mp4}.mock.log" 2>&1 </dev/null &
MOCK=$!
sleep 0.4

"$HERE/greeter.bin" --mock --sock "$SOCK" --demo-users \
  > "${OUT%.mp4}.greeter.log" 2>&1 </dev/null &
APP=$!
sleep 2.0

RAW="${OUT%.mp4}.raw.mp4"
wf-recorder -o "$MON" -f "$RAW" -c libx264 -p crf=20 -p preset=veryfast --overwrite \
  > "${OUT%.mp4}.rec.log" 2>&1 </dev/null &
REC=$!
sleep 1.4

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   timeout 5 wtype -k "${line#key }" ;;
    type\ *)  timeout 5 wtype -- "${line#type }" ;;
    shot\ *)  grim -o "$MON" "${OUT%.mp4}.${line#shot }.png" 2>/dev/null ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 0.8
kill -INT $REC 2>/dev/null; timeout 20 tail --pid=$REC -f /dev/null; REC=""
kill $APP 2>/dev/null; APP=""
sleep 0.4

if [ -s "$RAW" ]; then
  ffmpeg -loglevel error -i "$RAW" -r 30 -c:v libx264 -crf 20 -preset veryfast \
    -pix_fmt yuv420p -y "$OUT"
  rm -f "$RAW"
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" \
    | xargs -I{} echo "wrote $OUT ({}s)"
  echo "--- the conversation the mock greetd saw ---"
  cat "${OUT%.mp4}.mock.log"
else
  echo "recording failed"; cat "${OUT%.mp4}.rec.log"; exit 1
fi
