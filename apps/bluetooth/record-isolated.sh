#!/usr/bin/env bash
# record-isolated.sh <binary> <out.mp4> <script-file>
#
# The same thing apps/tools/record-app.sh does — launch the app, drive it with
# real input, capture the compositor's own composite — except that it runs the
# app inside a nested sway driving a headless output of its own.
#
# Why: three of these applets are being built at once on this machine, and the
# shared recorder kills every window of class "palmy" and types into whichever
# one happens to hold focus. A nested compositor gives this app a display of
# its own: nothing else can be focused in it, nothing else draws over it, and a
# sibling's `hyprctl clients` cannot see it to kill it.
#
# The script file format is identical to record-app.sh:
#   key <X11name> | type <text> | move <x> <y> | wait <seconds>
set -uo pipefail
BIN="${1:?binary}"; OUT="${2:?output mp4}"; SCRIPT="${3:?script file}"
W="${W:-1060}"; H="${H:-700}"
mkdir -p "$(dirname "$OUT")"

CFG=$(mktemp /tmp/bt-sway-XXXX.cfg)
cat > "$CFG" <<EOF
output * resolution ${W}x${H}@30Hz
default_border none
default_floating_border none
gaps inner 0
focus_follows_mouse yes
exec env PALMY_CONTINUOUS=1 "$(realpath "$BIN")"
EOF

before=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1 sway -c "$CFG" >/tmp/bt-sway.log 2>&1 &
SWAY=$!
cleanup() { kill $SWAY 2>/dev/null; rm -f "$CFG"; }
trap cleanup EXIT

NEST=""
for _ in $(seq 1 40); do
  sleep 0.25
  after=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)
  NEST=$(comm -13 <(echo "$before") <(echo "$after") | head -n1)
  [ -n "$NEST" ] && break
done
[ -z "$NEST" ] && { echo "nested compositor never came up"; cat /tmp/bt-sway.log; exit 1; }
echo "nested display: $NEST (${W}x${H})"
export WAYLAND_DISPLAY="$NEST"
export SWAYSOCK=$(ls -t "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -n1)
sleep 2.5

RAW="${OUT%.mp4}.raw.mp4"
wf-recorder -f "$RAW" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.2
T0=$(date +%s.%N)

# palmy stops decoding keys after the first wtype process exits: each wtype
# installs its own virtual-keyboard keymap, and the window only follows the
# first one. So the whole key track is handed to a SINGLE wtype process, with
# `-s` carrying the waits, and the pointer track is replayed alongside it on the
# same timeline. (Reported as a toolkit gap; not worked around inside palmy.)
ARGS=()
while IFS= read -r line; do
  case "$line" in
    \#*|"") ;;
    wait\ *) ARGS+=(-s "$(python3 -c "print(int(float('${line#wait }')*1000))")") ;;
    key\ *)  ARGS+=(-k "${line#key }") ;;
    type\ *) for (( i=0; i<${#line}-5; i++ )); do
                c="${line:5+i:1}"
                case "$c" in
                  " ") ARGS+=(-k space) ;;
                  *)   ARGS+=(-k "$c") ;;
                esac
              done ;;
  esac
done < "$SCRIPT"
wtype "${ARGS[@]}" &
TYPER=$!

# The pointer track, on the same clock.
while IFS= read -r line; do
  case "$line" in
    \#*|"") ;;
    wait\ *) sleep "${line#wait }" ;;
    move\ *) set -- ${line#move }; timeout 5 swaymsg "seat seat0 cursor set $1 $2" >/dev/null 2>&1 ;;
  esac
done < "$SCRIPT"
wait $TYPER 2>/dev/null

sleep 1
T1=$(date +%s.%N)
kill -INT $REC 2>/dev/null; timeout 20 tail --pid=$REC -f /dev/null
swaymsg exit >/dev/null 2>&1
sleep 0.6

# A headless wlroots output ticks on its own software clock, and wf-recorder
# timestamps the frames against it, so the capture comes out uniformly faster
# than real time. The app runs with PALMY_CONTINUOUS=1 so that clock is the only
# thing varying: frames arrive at a constant rate, and scaling the timestamps by
# the measured wall duration puts the demo back at the speed it ran at.
if [ -s "$RAW" ]; then
  GOT=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$RAW")
  WANT=$(python3 -c "print(max(0.1, $T1 - $T0))")
  K=$(python3 -c "print($WANT / max(0.001, $GOT))")
  echo "re-timing: captured ${GOT}s -> ${WANT}s (x$K)"
  ffmpeg -v error -i "$RAW" -filter:v "setpts=${K}*PTS,fps=30" \
    -c:v libx264 -crf 20 -preset veryfast -pix_fmt yuv420p -an "$OUT" -y
  rm -f "$RAW"
fi

if [ -s "$OUT" ]; then
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s)"
else
  echo "recording failed"; cat /tmp/bt-sway.log; exit 1
fi
