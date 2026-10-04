#!/usr/bin/env bash
# Record a palmy app on a compositor nobody can see.
#
#   headless-record.sh <binary-or-script> <out.mp4> <steps.txt> [width] [height]
#
# Why this exists. The older record-app.sh drives an app on the *user's* live
# compositor, and that turned out to be the single biggest source of wasted
# work in this project: a dozen agents sharing one seat meant takes captured
# somebody else's window, `wtype` typed into another app (one recording added
# slides to another agent's deck), notifications from unrelated crashes landed
# in the frame, and everything had to serialise behind /tmp/palmy-record.lock,
# where one orphaned process could stall every agent for half an hour.
#
# None of that is inherent. It all comes from sharing one compositor. This
# script starts a *private* headless sway for the app: its own Wayland socket,
# its own virtual output, its own seat. Consequences worth stating plainly:
#
#   - Nothing appears on the user's screen. Ever.
#   - No focus to steal, so keystrokes cannot land in the wrong window.
#   - No shared lock. Several of these can run at once, which is the point.
#   - The window gets exactly the size asked for, not a tiling slot.
#
# Steps file is the same format record-app.sh uses:
#   key <X11 keysym name>     a single key
#   chord <mods>+<key>        e.g. `chord ctrl+s`
#   type <text>               literal text
#   move <x> <y>              pointer, relative to the window
#   click [button]            press and release (default left)
#   wait <seconds>
#   # comment

set -uo pipefail

BIN="${1:?usage: headless-record.sh <binary> <out.mp4> <steps.txt> [w] [h]}"
OUT="${2:?missing output path}"
STEPS="${3:?missing steps file}"
W="${4:-1280}"
H="${5:-800}"

[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 1; }
[ -f "$STEPS" ] || { echo "no steps file: $STEPS"; exit 1; }

command -v sway >/dev/null || { echo "sway is required for the headless compositor"; exit 1; }
command -v wf-recorder >/dev/null || { echo "wf-recorder is required"; exit 1; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d /tmp/palmy-headless-XXXXXX)"
trap 'cleanup' EXIT

APP=""; REC=""; SWAY=""

cleanup() {
  [ -n "$REC"  ] && kill -INT  "$REC"  2>/dev/null
  # Give the encoder a moment to finalise the container, but do not hang on it.
  for _ in $(seq 1 60); do kill -0 "$REC" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$REC" 2>/dev/null
  [ -n "$APP"  ] && kill "$APP"  2>/dev/null
  if [ -n "$SWAY" ]; then
    kill "$SWAY" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$SWAY" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$SWAY" 2>/dev/null
    wait "$SWAY" 2>/dev/null
  fi
  rm -rf "$TMP"
}

cat > "$TMP/sway.conf" <<CONF
output HEADLESS-1 resolution ${W}x${H}
default_border none
# No bar, no bindings, no idle inhibitor: this compositor exists to hold one
# window still while it is filmed. Keep this file minimal -- sway paints a red
# "errors in your config file" banner across the top of the screen for any
# unknown directive, and it lands in every frame of the recording.
CONF

# sway picks the next free socket name itself, so note what exists first and
# find the one that appeared. Starting it with a pre-set WAYLAND_DISPLAY would
# make it a *nested* client of the user's session instead of a headless host.
before="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"

env -u WAYLAND_DISPLAY -u DISPLAY \
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$TMP/sway.conf" > "$TMP/sway.log" 2>&1 &
SWAY=$!

WD=""
for _ in $(seq 1 50); do
  sleep 0.1
  for s in "$XDG_RUNTIME_DIR"/wayland-*; do
    case "$s" in *.lock) continue;; esac
    case " $before " in *" $s "*) continue;; esac
    WD="$(basename "$s")"; break
  done
  [ -n "$WD" ] && break
done
[ -n "$WD" ] || { echo "the headless compositor never came up:"; tail -5 "$TMP/sway.log"; exit 1; }
export WAYLAND_DISPLAY="$WD"
echo "headless compositor on $WAYLAND_DISPLAY (${W}x${H}), invisible to the session"

"$BIN" > "$TMP/app.log" 2>&1 &
APP=$!

# Wait for the window rather than sleeping a guessed interval.
for _ in $(seq 1 100); do
  sleep 0.1
  kill -0 "$APP" 2>/dev/null || { echo "the app exited before mapping a window:"; head -5 "$TMP/app.log"; exit 1; }
  if swaymsg -t get_tree 2>/dev/null | grep -q '"app_id"'; then break; fi
done
sleep 0.4

# A private compositor has one window and one seat, so it is always the right
# one -- no pid matching, no re-focusing, no class guessing.
swaymsg '[app_id=".*"] fullscreen enable' >/dev/null 2>&1

wf-recorder -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite \
  > "$TMP/rec.log" 2>&1 &
REC=$!
sleep 1.0

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*)      ;;
    key\ *)   wtype -k "${line#key }" ;;
    chord\ *) set -- $(printf '%s' "${line#chord }" | tr '+' ' ')
              mods=""; while [ $# -gt 1 ]; do mods="$mods -M $1"; shift; done
              wtype $mods -k "$1" $(printf '%s' "$mods" | sed 's/-M/-m/g') ;;
    type\ *)  wtype -- "${line#type }" ;;
    move\ *)  set -- ${line#move }
              swaymsg "seat seat0 cursor set $1 $2" >/dev/null 2>&1 ;;
    click*)   b="${line#click}"; b="${b# }"; b="${b:-left}"
              swaymsg "seat seat0 cursor press button$b"   >/dev/null 2>&1
              sleep 0.1
              swaymsg "seat seat0 cursor release button$b" >/dev/null 2>&1 ;;
    wait\ *)  sleep "${line#wait }" ;;
    *)        echo "unknown step: $line" ;;
  esac
  sleep 0.12
done < "$STEPS"

sleep 0.8
cleanup
trap - EXIT

if [ -s "$OUT" ]; then
  echo "wrote $OUT ($(stat -c %s "$OUT") bytes)"
else
  echo "no output was written"; exit 1
fi
