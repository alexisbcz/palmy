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
#   click [button]            press and release (default left, or right/middle)
#   down [button] / up [button]   press or release alone, for a drag
#   wheel <dy>                scroll (10 per notch, positive is down)
#   wait <seconds>
#   # comment
#
# WINDOW=WxH+X+Y floats the window at that size and place instead of making
# it fullscreen, for takes that show something outside it (a popup past its
# edge); pointer steps stay relative to the window.
#
# The seat has no real devices, so it holds one virtual keyboard
# (`wtype -s`, asleep) and one virtual pointer (wl-pointer.py, beside this
# script) for the whole take. See "Input" below for why that matters.

set -uo pipefail

BIN="${1:?usage: headless-record.sh <binary> <out.mp4> <steps.txt> [w] [h]}"
OUT="${2:?missing output path}"
STEPS="${3:?missing steps file}"
W="${4:-1280}"
H="${5:-800}"

[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 1; }
[ -f "$STEPS" ] || { echo "no steps file: $STEPS"; exit 1; }

command -v sway >/dev/null || { echo "sway is required for the headless compositor"; exit 1; }
command -v grim >/dev/null || { echo "grim is required to capture frames"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required to encode the take"; exit 1; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d /tmp/palmy-headless-XXXXXX)"
trap 'cleanup' EXIT

APP=""; REC=""; SWAY=""; KBD=""; PTR=""; FRAMES=""

cleanup() {
  stop_capture
  [ -n "$APP"  ] && kill "$APP"  2>/dev/null
  [ -n "$KBD"  ] && kill "$KBD"  2>/dev/null
  [ -n "$PTR"  ] && kill "$PTR"  2>/dev/null
  if [ -n "$SWAY" ]; then
    kill "$SWAY" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$SWAY" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$SWAY" 2>/dev/null
    wait "$SWAY" 2>/dev/null
  fi
  [ -n "${KEEP_TMP:-}" ] && cp -r "$TMP" "$KEEP_TMP"; rm -rf "$TMP"
}

OFFX=0; OFFY=0; FLOAT=""
if [ -n "${WINDOW:-}" ]; then
  if [[ "$WINDOW" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
    FLOAT="for_window [app_id=\".*\"] floating enable, resize set ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}, move position ${BASH_REMATCH[3]} ${BASH_REMATCH[4]}"
    OFFX=${BASH_REMATCH[3]}; OFFY=${BASH_REMATCH[4]}
  else
    echo "WINDOW must look like 480x300+272+234"; exit 1
  fi
fi

cat > "$TMP/sway.conf" <<CONF
output HEADLESS-1 resolution ${W}x${H}
default_border none
$FLOAT
# No bar, no bindings, no idle inhibitor: this compositor exists to hold one
# window still while it is filmed. Keep this file minimal -- sway paints a red
# "errors in your config file" banner across the top of the screen for any
# unknown directive, and it lands in every frame of the recording.
CONF

# Ask sway which display it opened, through a helper it execs itself. Starting
# it with a pre-set WAYLAND_DISPLAY would make it a nested client of the user's
# session instead of a headless host, so it has to choose -- but it must then
# *tell* us.
#
# This used to diff the socket directory before and after, which is a race: two
# recordings overlapping meant one could adopt the other's compositor, and a
# take really did come back showing a different agent's chat window.
echo "exec printf '%s' \"\$WAYLAND_DISPLAY\" > $TMP/display" >> "$TMP/sway.conf"

env -u WAYLAND_DISPLAY -u DISPLAY \
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$TMP/sway.conf" > "$TMP/sway.log" 2>&1 &
SWAY=$!

WD=""
for _ in $(seq 1 80); do
  sleep 0.1
  WD="$(cat "$TMP/display" 2>/dev/null)"
  [ -n "$WD" ] && break
done
[ -n "$WD" ] || { echo "the headless compositor never reported a display:"; tail -5 "$TMP/sway.log"; exit 1; }
export WAYLAND_DISPLAY="$WD"

# swaymsg finds its socket through SWAYSOCK, which only sway's own children
# inherit -- and this script is sway's *parent*. Without it every swaymsg below
# failed silently, so the window wait, the fullscreen and every cursor move and
# click were no-ops and nobody noticed, because each one redirects its own
# errors away. Point it at the socket sway opened for this pid.
export SWAYSOCK="$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$SWAY.sock"
for _ in $(seq 1 50); do [ -S "$SWAYSOCK" ] && break; sleep 0.1; done
if ! swaymsg -t get_version >/dev/null 2>&1; then
  echo "warning: cannot reach sway's IPC at $SWAYSOCK -- pointer steps will not work"
fi
echo "headless compositor on $WAYLAND_DISPLAY (${W}x${H}), invisible to the session"

# Input. A headless seat has no keyboard and no pointer until a virtual one
# attaches, and loses the capability again when it detaches. A tool that
# attaches per step (wtype, wlrctl) therefore toggles the capability for every
# keystroke: the client is told to drop its wl_keyboard and bind a new one, and
# sway only flushes that news to it once its own loop goes idle -- after
# wtype's press and release have both been processed and sent to nobody.
# Measured at 79-82 keys in 100 lost, one wtype per key. palmy now recovers a
# key still held when it re-binds, which brings that to 14-18 in 100; the rest
# no client can recover. So the seat keeps one keyboard and one pointer
# attached for the whole take, and the capability never changes: 0 of 200
# keys lost with a wtype per key and no gap at all.
#
# Both start before the app, so it sees the seat complete from its first
# frame.
wtype -s 86400000 &
KBD=$!
PTR_IN="$TMP/pointer.in"; PTR_OUT="$TMP/pointer.out"
mkfifo "$PTR_IN" "$PTR_OUT"
python3 "$(dirname "$(readlink -f "$0")")/wl-pointer.py" --width "$W" --height "$H" \
  < "$PTR_IN" > "$PTR_OUT" 2>"$TMP/pointer.log" &
PTR=$!
exec 3> "$PTR_IN" 4< "$PTR_OUT"
read -r -t 5 ready <&4 || { echo "the virtual pointer did not start:"; cat "$TMP/pointer.log"; exit 1; }
sleep 0.2

# pointer sends one command to the virtual pointer and waits until the
# compositor has acknowledged it, so steps stay in order with the keyboard's.
pointer() {
  printf '%s\n' "$*" >&3
  read -r -t 5 ack <&4 || echo "warning: the virtual pointer did not acknowledge: $*" >&2
}

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
[ -z "$FLOAT" ] && swaymsg '[app_id=".*"] fullscreen enable' >/dev/null 2>&1

# Capture. This used to be wf-recorder, and in the build VM it records almost
# nothing: sway's headless output only renders when something is damaged, so
# a take of an idle-between-steps app came back as 2 to 64 frames squeezed
# into a second or so, and SIGINT never finalised it (it waits for a frame
# that does not come). grim takes one screencopy per call whatever the damage,
# so the loop below grabs a frame about ten times a second with the time it
# was taken, and the encoder holds each frame for exactly as long as it was
# on screen. RECORDER=wf-recorder brings the old path back where it works.
FRAMES="$TMP/frames"
mkdir -p "$FRAMES"
start_capture() {
  if [ "${RECORDER:-grim}" = wf-recorder ]; then
    wf-recorder -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite > "$TMP/rec.log" 2>&1 &
    REC=$!
    return
  fi
  (
    i=0
    while [ ! -e "$FRAMES/stop" ]; do
      f=$(printf '%s/%06d.png' "$FRAMES" "$i")
      grim -c -l 1 "$f" 2>/dev/null && { date +%s.%N >> "$FRAMES/times"; i=$((i+1)); }
      sleep 0.05
    done
  ) &
  REC=$!
}
stop_capture() {
  [ -z "$REC" ] && return
  if [ "${RECORDER:-grim}" = wf-recorder ]; then
    kill -INT "$REC" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$REC" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$REC" 2>/dev/null
    REC=""
    return
  fi
  touch "$FRAMES/stop"
  wait "$REC" 2>/dev/null
  REC=""
  [ -s "$FRAMES/times" ] || return
  # A concat list: every frame shown until the next one was taken.
  awk -v d="$FRAMES" '
    { t[NR] = $1 }
    END {
      for (i = 1; i <= NR; i++) {
        dur = (i < NR) ? t[i+1] - t[i] : 0.1
        printf "file '"'"'%s/%06d.png'"'"'\nduration %.4f\n", d, i - 1, dur
      }
      printf "file '"'"'%s/%06d.png'"'"'\n", d, NR - 1
    }' "$FRAMES/times" > "$FRAMES/list.txt"
  ffmpeg -v error -y -f concat -safe 0 -i "$FRAMES/list.txt" -vf fps=30,format=yuv420p \
    -c:v libx264 -crf 20 -preset veryfast "$OUT" 2>"$TMP/rec.log" ||
    { echo "encoding failed:"; tail -5 "$TMP/rec.log"; }
}
start_capture
sleep 1.0

# Drive the take one step at a time. This used to batch the whole steps file
# into a single wtype process, because a wtype per step lost about one key in
# five; with the resident keyboard above it loses none, and per-step keys keep
# their order with pointer steps, which a batch could not.
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*)      ;;
    key\ *)   wtype -k "${line#key }" ;;
    # No `--`: it makes wtype treat everything after it as literal text. A
    # step whose text starts with a dash is refused rather than typed as a flag.
    type\ *)  txt="${line#type }"
              case "$txt" in -*) echo "step text may not start with '-': $txt"; exit 1;; esac
              wtype -d 8 "$txt" ;;
    chord\ *) set -- $(printf '%s' "${line#chord }" | tr '+' ' ')
              args=(); mods=(); while [ $# -gt 1 ]; do mods+=( "$1" ); shift; done
              for m in "${mods[@]}"; do args+=( -M "$m" ); done
              args+=( -k "$1" )
              for m in "${mods[@]}"; do args+=( -m "$m" ); done
              wtype "${args[@]}" ;;
    wait\ *)  sleep "${line#wait }" ;;
    # The window is fullscreen on the only output, or floating at
    # (OFFX, OFFY): pointer steps are relative to it.
    move\ *)  set -- ${line#move }
              pointer move $(( $1 + OFFX )) $(( $2 + OFFY )) ;;
    click*|down*|up*|wheel\ *) pointer $line ;;
    *)        echo "unknown step: $line" ;;
  esac
done < "$STEPS"

sleep 0.8
cleanup
trap - EXIT

if [ -s "$OUT" ]; then
  echo "wrote $OUT ($(stat -c %s "$OUT") bytes)"
else
  echo "no output was written"; exit 1
fi
