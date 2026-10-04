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

# Drive the whole take through ONE wtype process.
#
# wtype attaches a virtual keyboard, sends, and detaches. Running it per step
# means the seat's keyboard capability cycles for every keystroke, and the
# client's re-bind is asynchronous -- it asks for a keyboard and the keymap and
# focus arrive afterwards, so a key pressed in that window is simply gone.
# Measured at roughly one key in five lost, which is worse than it sounds: a
# dropped key does not just omit a step, it redirects the ones after it. One
# take left a mail demo deleting the wrong conversation.
#
# Two agents measured the same thing independently, and driving the identical
# keys by hand without the per-step loop works every time. So: translate the
# whole steps file into a single argv, where `wait` becomes wtype's own `-s`
# (sleep before the following options) and one keyboard stays attached from the
# first key to the last.
#
# Pointer steps have to break the batch, so they flush what has accumulated,
# act, and start a new one.
argv=()
flush_keys() {
  [ ${#argv[@]} -eq 0 ] && return
  # Lead with a shift press and release. The first event of an invocation is
  # the one exposed to the re-bind window, and a bare `key` step that loses it
  # loses the whole step; a modifier that is pressed and released produces no
  # character whether it arrives or not, so it is the right thing to sacrifice.
  # (`-M shift` is the modifier form; `-k shift` is a keysym lookup and fails,
  # which is why an earlier attempt at this made things worse rather than
  # better.)
  wtype -M shift -m shift "${argv[@]}"
  argv=()
}

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*)      ;;
    key\ *)   argv+=( -k "${line#key }" ) ;;
    # No `--` here: it makes wtype treat everything after it as literal text,
    # so the flags of later steps get typed into the window. Text therefore
    # goes in as a plain positional, which means a step whose text starts with
    # a dash is not supported -- say so rather than silently typing a flag.
    type\ *)  txt="${line#type }"
              case "$txt" in -*) echo "step text may not start with '-': $txt"; exit 1;; esac
              argv+=( -d 8 "$txt" ) ;;
    chord\ *) set -- $(printf '%s' "${line#chord }" | tr '+' ' ')
              mods=(); while [ $# -gt 1 ]; do mods+=( "$1" ); shift; done
              for m in "${mods[@]}"; do argv+=( -M "$m" ); done
              argv+=( -k "$1" )
              for m in "${mods[@]}"; do argv+=( -m "$m" ); done ;;
    wait\ *)  ms=$(awk -v s="${line#wait }" 'BEGIN{printf "%d", s*1000}')
              argv+=( -s "$ms" ) ;;
    # POINTER STEPS DO NOT REACH THE CLIENT ON THIS SEAT, and they are kept
    # only so an existing steps file does not fail outright. The compositor is
    # started with WLR_LIBINPUT_NO_DEVICES=1, so the seat never gains a pointer
    # capability and no client is ever sent motion or button. `swaymsg seat
    # cursor` reports success regardless -- it is moving sway's own cursor --
    # which is why these appeared to work for a long time and never did.
    # wlrctl speaks the right protocol but its move is relative, and a click
    # with no pointer capability still reaches nobody; verified by clicking a
    # calculator keypad and watching nothing happen.
    #
    # Drive demos from the keyboard. Every application here is keyboard-usable
    # because of this.
    move\ *|click*)
              flush_keys
              if [ -z "${POINTER_WARNED:-}" ]; then
                echo "warning: pointer steps do not reach the client on this seat; drive from the keyboard" >&2
                POINTER_WARNED=1
              fi ;;
    *)        echo "unknown step: $line" ;;
  esac
done < "$STEPS"
flush_keys

sleep 0.8
cleanup
trap - EXIT

if [ -s "$OUT" ]; then
  echo "wrote $OUT ($(stat -c %s "$OUT") bytes)"
else
  echo "no output was written"; exit 1
fi
