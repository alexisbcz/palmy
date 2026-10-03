#!/usr/bin/env bash
# record.sh [out.mp4] [script-file]
#
# Records the greeter against the mock greetd in ./mock.
#
# Two reasons this does not use apps/tools/record-app.sh:
#
#  1. The greeter is a wlr-layer-shell OVERLAY surface, not a toplevel, so
#     `hyprctl clients` has no window rect for it to record.
#  2. It asks for EXCLUSIVE keyboard focus, which on the user's own session
#     means it swallows every keystroke on the machine — including the
#     synthetic input other recordings are using at the same time.
#
# So the greeter is run inside a nested sway on a headless output of its own.
# wf-recorder then captures that whole output, which is exactly what a layer
# surface covers, and `wtype` reaches nothing but the greeter.
#
# Nothing here touches greetd, sddm, any systemd unit or /etc: the only server
# involved is ./mock/mock.bin on a socket in $TMPDIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
SCRIPT="${2:-$HERE/demo.txt}"
SOCK="${SOCK:-${XDG_RUNTIME_DIR:-/tmp}/greeter-demo-greetd.sock}"
mkdir -p "$(dirname "$OUT")"

[ -x "$HERE/greeter.bin" ] || { echo "build apps/greeter first"; exit 1; }
[ -x "$HERE/mock/mock.bin" ] || { echo "build apps/greeter/mock first"; exit 1; }

# The mock greetd lives outside the nested compositor; it needs no display.
rm -f "$SOCK"
"$HERE/mock/mock.bin" --sock "$SOCK" > "${OUT%.mp4}.mock.log" 2>&1 &
MOCK=$!
sleep 0.4

CFG=$(mktemp "${TMPDIR:-/tmp}/greeter-sway-XXXX.cfg")
cat > "$CFG" <<EOF
default_border none
default_floating_border none
gaps inner 0
EOF

# The wayland backend rather than the headless one: a headless seat has no
# keyboard device, so sway never advertises the keyboard capability, the client
# never creates a wl_keyboard, and `wtype` has nothing to type into. Nesting in
# the parent compositor gives the seat a real keyboard. The window it opens is
# an ordinary toplevel; it does not take the screen over the way the greeter
# itself would.
before=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)
WLR_BACKENDS=wayland WLR_WL_OUTPUTS=1 \
  sway -c "$CFG" > "${OUT%.mp4}.sway.log" 2>&1 &
SWAY=$!
cleanup() {
  kill ${APP:-} 2>/dev/null
  kill $SWAY 2>/dev/null
  kill $MOCK 2>/dev/null
  rm -f "$CFG" "$SOCK"
}
trap cleanup EXIT

NEST=""
for _ in $(seq 1 40); do
  sleep 0.25
  after=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)
  NEST=$(comm -13 <(echo "$before") <(echo "$after") | head -n1)
  [ -n "$NEST" ] && break
done
[ -z "$NEST" ] && { echo "nested compositor never came up"; cat "${OUT%.mp4}.sway.log"; exit 1; }
# The nested sway is an ordinary toplevel in the parent compositor, so the
# parent decides how big it is, and a greeter wants a whole screen. If the
# parent is Hyprland, and the window it just opened is the focused one, ask for
# fullscreen so the nested output is the size of a real display. Only that one
# window is touched and nothing is written to any config; if the check fails
# the recording simply happens at whatever size the parent gave.
if command -v hyprctl >/dev/null 2>&1; then
  FULL=0
  for _ in $(seq 1 20); do
    FOCUSED_PID=$(hyprctl activewindow -j 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('pid'))
except Exception: print(0)")
    if [ "${FOCUSED_PID:-0}" = "$SWAY" ]; then
      hyprctl dispatch "hl.dsp.window.fullscreen()" >/dev/null 2>&1
      sleep 1.0
      FULL=1
      break
    fi
    sleep 0.3
  done
  [ "$FULL" = 0 ] && echo "note: the nested compositor never held focus; recording at its tiled size"
fi

echo "nested display: $NEST, mock greetd on $SOCK"
export WAYLAND_DISPLAY="$NEST"
export SWAYSOCK=$(ls -t "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -n1)

# Only now, with the nested output at its final size, start the greeter: it
# measures the output once and asks for a layer surface exactly that big.
"$HERE/greeter.bin" --mock --sock "$SOCK" --demo-users >> "${OUT%.mp4}.sway.log" 2>&1 </dev/null &
APP=$!
sleep 2.5

RAW="${OUT%.mp4}.raw.mp4"
wf-recorder -f "$RAW" -c libx264 -p crf=20 -p preset=veryfast --overwrite > "${OUT%.mp4}.rec.log" 2>&1 </dev/null &
REC=$!
sleep 1.2

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    key\ *)   timeout 5 wtype -k "${line#key }" ;;
    type\ *)  timeout 5 wtype -- "${line#type }" ;;
    shot\ *)  grim "${OUT%.mp4}.${line#shot }.png" 2>/dev/null ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 1
kill -INT $REC 2>/dev/null; timeout 20 tail --pid=$REC -f /dev/null
swaymsg exit >/dev/null 2>&1
sleep 0.6

echo "raw: $(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$RAW" 2>/dev/null)"
if [ -s "$RAW" ]; then
  ffmpeg -loglevel error -i "$RAW" -r 30 -c:v libx264 -crf 20 -preset veryfast -pix_fmt yuv420p -y "$OUT"
  rm -f "$RAW"
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" \
    | xargs -I{} echo "wrote $OUT ({}s)"
  echo "--- mock greetd conversation ---"
  cat "${OUT%.mp4}.mock.log"
else
  echo "recording failed"; cat "${OUT%.mp4}.sway.log"; exit 1
fi
