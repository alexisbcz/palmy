#!/usr/bin/env bash
# Record a real call between two instances of this application, on a
# compositor nobody can see.
#
#   record.sh <out.mp4> <script-file> [width] [height]
#
# Why this is not `apps/tools/headless-record.sh`
# -----------------------------------------------
#
# One reason only: a call needs **two** windows side by side, and the shared
# recorder starts one binary and fullscreens one window. Everything else here
# is the shared recorder's design, and it is worth restating because it is what
# made the difference. This script starts its own headless `sway` with its own
# Wayland socket, its own virtual output and its own seat, so:
#
#   - nothing appears on the user's screen, ever;
#   - there is no focus to steal, so a keystroke cannot land in another app;
#   - no other agent's window can be picked up instead of ours;
#   - there is no shared lock, so several of these can run at once.
#
# The previous version of this file drove the user's live Hyprland session, and
# everything it went wrong at — capturing somebody else's window, keystrokes
# arriving in the wrong application, crash toasts in frame, and a lock one
# orphaned process could hold for half an hour — came from sharing one seat.
# None of it survives here.
#
# Two things about this machine that cost takes before they were understood
# ------------------------------------------------------------------------
#
# 1. **`swaymsg` does not find a compositor from `WAYLAND_DISPLAY`.** It reads
#    `$SWAYSOCK`, then `$I3SOCK`, then asks `sway --get-socketpath`, which only
#    answers from inside sway's own environment. Without `SWAYSOCK` set by
#    hand, every `swaymsg` here fails with "Unable to retrieve socket path" and
#    the waits below time out instead of working. It is set and then verified
#    with `swaymsg -t get_version`, so the failure is loud rather than silent.
#
# 2. **A palmy window takes input from the first `wtype` process and no
#    later one.** `wtype hello` then `wtype world` delivers only "hello". So
#    the whole steps file is compiled into **one** `wtype` argv: `-s MS` sleeps
#    before the following options, `-k KEY` presses a named key, and a bare
#    argument is typed as text. `--` is never used, because it makes
#    everything after it literal text. The pacing happens inside the one
#    process, which is also why it is more even than a shell loop's.
#
# That leaves focus. On a private seat with two windows nothing steals it, so
# it is asserted once by pid — `swaymsg "[pid=N] focus"`, never `focus left`,
# because a direction is relative to however sway laid the containers out and
# that is how an earlier take swapped which instance was being driven.
#
# Steps, one per line, all driven against the left window (Alice):
#   key <X11 keysym name>     a single key
#   chord <mods>+<key>        e.g. `chord ctrl+s`
#   type <text>               literal text
#   wait <seconds>
#   # comment
#
# SYNTHETIC SOURCES ONLY. Neither instance is given `--allow-real-devices`, so
# the camera and the microphone are enumerated, shown in the picker, and
# refused — see `resolve_capture` in main.odin, which substitutes the synthetic
# source even if a real one were somehow selected. The left window sends
# ffmpeg's `testsrc2`; the right sends SMPTE bars. Two different pictures, so
# "each window is showing the other instance's video" is visible rather than
# asserted.
#
# Both instances offer both video codecs, so the call runs on H.264 at
# ~300 kbit/s and the Statistics panel names it. `--video-codec mjpeg` on one
# end would record the MJPEG call instead, and the same demo script drives it.
set -uo pipefail

OUT="${1:?usage: record.sh <out.mp4> <steps.txt> [w] [h]}"
STEPS="${2:?missing steps file}"
W="${3:-1920}"
H="${4:-1000}"
LIFE=140

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/call.bin"

[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 1; }
[ -f "$STEPS" ] || { echo "no steps file: $STEPS"; exit 1; }
command -v sway        >/dev/null || { echo "sway is required for the headless compositor"; exit 1; }
command -v wf-recorder >/dev/null || { echo "wf-recorder is required"; exit 1; }
command -v wtype       >/dev/null || { echo "wtype is required"; exit 1; }

# Each window is half the output, and the application asks for a 920-point
# minimum. Anything narrower than 1840 total is a tiling slot the UI was not
# laid out for.
if [ "$W" -lt 1860 ]; then
  echo "width $W leaves less than 920 points a window; use 1860 or more"; exit 1
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d /tmp/palmy-call-record-XXXXXX)"
mkdir -p "$(dirname "$OUT")"

A=""; B=""; REC=""; SWAY=""
cleanup() {
  [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null
  # Give the encoder a moment to finalise the container, but do not hang on it.
  for _ in $(seq 1 60); do kill -0 "$REC" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$REC" 2>/dev/null
  [ -n "$A" ] && kill "$A" 2>/dev/null
  [ -n "$B" ] && kill "$B" 2>/dev/null
  if [ -n "$SWAY" ]; then
    kill "$SWAY" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$SWAY" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$SWAY" 2>/dev/null
    wait "$SWAY" 2>/dev/null
  fi
  if [ -n "${PALMY_RECORD_KEEP:-}" ]; then echo "keeping $TMP"; else rm -rf "$TMP"; fi
  return 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# The private compositor
# ---------------------------------------------------------------------------

cat > "$TMP/sway.conf" <<CONF
output HEADLESS-1 resolution ${W}x${H}
default_border none
gaps inner 0
# Keep this file minimal: sway paints a red "errors in your config file"
# banner across the top of the screen for any directive it does not know, and
# it lands in every frame of the recording.
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

SWAYSOCK=""
for _ in $(seq 1 50); do
  sk="$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$SWAY.sock"
  [ -S "$sk" ] && { SWAYSOCK="$sk"; break; }
  sleep 0.1
done
[ -n "$SWAYSOCK" ] || { echo "the compositor came up but its IPC socket never appeared"; exit 1; }
export SWAYSOCK
swaymsg -t get_version >/dev/null || { echo "cannot talk to the headless compositor"; exit 1; }
echo "headless compositor on $WAYLAND_DISPLAY (${W}x${H}) via $(basename "$SWAYSOCK"), invisible to the session"

# ---------------------------------------------------------------------------
# Two instances, tiled by the compositor
#
# Alice goes first so she takes the left container; sway opens the second
# window to the right of the focused one. She dials on startup and repeats the
# invite every 400 ms for thirty seconds, so Bob coming up a second later still
# answers it — there is no race to lose here.
# ---------------------------------------------------------------------------

"$BIN" --bind 47811 --peer 47812 --name Alice \
  --pattern testsrc2 --autocall --volume 0.25 --quit-after "$LIFE" > "$TMP/a.log" 2>&1 &
A=$!
for _ in $(seq 1 100); do
  sleep 0.1
  kill -0 "$A" 2>/dev/null || { echo "Alice exited early:"; head -5 "$TMP/a.log"; exit 1; }
  [ "$(swaymsg -t get_tree 2>/dev/null | grep -c '"app_id": "palmy"')" -ge 1 ] && break
done

"$BIN" --bind 47812 --peer 47811 --name Bob \
  --pattern smptehdbars --autoanswer --volume 0.0 --quit-after "$LIFE" > "$TMP/b.log" 2>&1 &
B=$!
for _ in $(seq 1 100); do
  sleep 0.1
  kill -0 "$B" 2>/dev/null || { echo "Bob exited early:"; head -5 "$TMP/b.log"; exit 1; }
  [ "$(swaymsg -t get_tree 2>/dev/null | grep -c '"app_id": "palmy"')" -ge 2 ] && break
done

# Refuse to record anything that is not exactly these two windows. On a private
# seat that can only fail if one of them died, but a silent one-window take is
# not a two-peer call and should not be mistaken for one.
N=$(swaymsg -t get_tree | grep -c '"app_id": "palmy"')
[ "$N" = "2" ] || { echo "expected 2 windows on the headless seat, found $N"; exit 1; }

# Let the call come up before the camera rolls: Connecting ends on the first
# media datagram, so by the time this is over both windows are showing the
# other one's picture.
sleep 3.0
for pid in "$A" "$B"; do
  kill -0 "$pid" 2>/dev/null || { echo "instance $pid exited before it could be recorded"; exit 1; }
done
grep -h "video codec" "$TMP/a.log" "$TMP/b.log" 2>/dev/null
echo "two instances on $WAYLAND_DISPLAY, tiled side by side by sway"

wf-recorder -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite \
  > "$TMP/rec.log" 2>&1 &
REC=$!
sleep 1.4
swaymsg "[pid=$A] focus" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Compile the whole steps file into one wtype argv
# ---------------------------------------------------------------------------

# The very first key is sometimes swallowed while the window is still taking
# keyboard focus, so spend it on something with no effect. This application
# has no text field, and `s` only selects the panel that is already showing.
ARGS=( -s 900 -k s )
SEEN=0

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  SEEN=$((SEEN + 1))
  case "$line" in
    wait\ *)  ARGS+=( -s "$(awk -v t="${line#wait }" 'BEGIN{printf "%d", t*1000}')" ) ;;
    key\ *)   ARGS+=( -k "${line#key }" ) ;;
    chord\ *) set -- $(printf '%s' "${line#chord }" | tr '+' ' ')
              mods=(); while [ $# -gt 1 ]; do mods+=( "$1" ); shift; done
              for m in "${mods[@]}"; do ARGS+=( -M "$m" ); done
              ARGS+=( -k "$1" )
              for ((i=${#mods[@]} - 1; i >= 0; i--)); do ARGS+=( -m "${mods[$i]}" ); done ;;
    type\ *)  txt="${line#type }"
              case "$txt" in
                -*) echo "refusing a 'type' line starting with '-': wtype reads it as an option"; exit 1 ;;
              esac
              ARGS+=( "$txt" ) ;;
    *)        echo "unsupported step (this recorder drives the keyboard only): $line"; exit 1 ;;
  esac
  ARGS+=( -s 120 )
done < "$STEPS"

echo "compiled $SEEN steps into one wtype argv"
wtype "${ARGS[@]}"
WT=$?
[ "$WT" = "0" ] || echo "wtype exited $WT"

for pid in "$A" "$B"; do
  kill -0 "$pid" 2>/dev/null || echo "WARNING: instance $pid died during the take"
done

sleep 1.0
cleanup
trap - EXIT

if [ ! -s "$OUT" ]; then
  echo "no output was written"; exit 1
fi
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
echo "wrote $OUT (${DUR}s, $(stat -c %s "$OUT") bytes)"
