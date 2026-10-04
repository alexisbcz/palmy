#!/usr/bin/env bash
# Record the audio demo on a compositor nobody can see.
#
#   record.sh [out.mp4] [steps.txt] [width] [height]
#
# This is apps/tools/headless-record.sh with one difference: **the whole take
# is driven by a single `wtype` process.** The waits become `-s <ms>` inside
# that one command line, so one virtual keyboard attaches to the seat before
# the first key and stays until after the last.
#
# Why that matters, measured rather than assumed:
#
#   The shared recorder runs one `wtype` per step. Each creates a virtual
#   keyboard and destroys it on exit, so on a headless seat — which has no
#   other keyboard — the seat's keyboard capability goes 0 → 2 → 0 around
#   every single step. palmy used to bind `wl_keyboard` the first time and
#   never again, and a thirty-step take delivered one keystroke; that part is
#   fixed in palmy now (the seat handler releases the keyboard when the
#   capability drops, so the next attach re-binds) and per-step wtype does
#   deliver keys again.
#
#   But it does not deliver them *reliably*. Re-binding is asynchronous: the
#   client asks for a new `wl_keyboard` and the compositor sends the keymap
#   and the `enter` afterwards, and a key pressed in that window lands before
#   the window has been given focus and is simply gone. With one wtype per
#   step, every key is pressed in that window. Measured on this app: `t`
#   opened the subtitle track list 1 of 1 times through a single wtype, and
#   0 of 2 times through the shared per-step recorder on the same clip, with
#   neighbouring keys in the same take working. Keeping one keyboard attached
#   for the whole take removes the race rather than narrowing it.
#
# The cost: `move` and `click` go through `swaymsg`, which is a separate
# process and cannot be interleaved inside the single `wtype`. They run first,
# as their own phase. These demos are keyboard-driven, which is also the
# honest way to film an application whose every feature has a key.
#
# The `flock` is for a different hazard. The shared recorder finds its
# compositor by listing the Wayland sockets, starting sway, and taking the one
# that appeared — a race if two takes start at once, since each can see the
# other's new socket. Not theoretical: one take of this app came back showing
# a different agent's chat window. The lock serialises takes started this way;
# it cannot help against a recorder that does not take it, so every take is
# still checked by eye before it is kept.
#
# Steps, one per line:
#   key <X11 keysym>        a single key
#   chord <mods>+<key>      e.g. `chord ctrl,shift+l`, mods comma separated
#   type <text>             literal text
#   wait <seconds>
#   move <x> <y>            pointer, in the phase before the keyboard
#   click [button]          ditto
#   # comment
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/demo.mp4}"
STEPS="${2:-$HERE/demo.txt}"
W="${3:-1280}"
H="${4:-820}"

[ -f "$STEPS" ] || { echo "no steps file: $STEPS"; exit 1; }
for t in sway wf-recorder wtype; do
  command -v "$t" >/dev/null || { echo "$t is required"; exit 1; }
done

exec 9>/tmp/palmy-headless-record.lock
flock 9

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d /tmp/palmy-audio-rec-XXXXXX)"
APP=""; REC=""; SWAY=""

cleanup() {
  [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$REC" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$REC" 2>/dev/null
  [ -n "$APP" ] && kill "$APP" 2>/dev/null
  if [ -n "$SWAY" ]; then
    kill "$SWAY" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$SWAY" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$SWAY" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/sway.conf" <<CONF
output HEADLESS-1 resolution ${W}x${H}
default_border none
CONF

before="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"
env -u WAYLAND_DISPLAY -u DISPLAY \
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$TMP/sway.conf" > "$TMP/sway.log" 2>&1 &
SWAY=$!
# sway names its IPC socket after its own pid, so pinning SWAYSOCK is exact:
# without it, swaymsg takes whichever socket it finds first, which on this
# machine can belong to somebody else's compositor.
export SWAYSOCK="$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$SWAY.sock"

WD=""
for _ in $(seq 1 60); do
  sleep 0.1
  for s in "$XDG_RUNTIME_DIR"/wayland-*; do
    case "$s" in *.lock) continue;; esac
    case " $before " in *" $s "*) continue;; esac
    WD="$(basename "$s")"; break
  done
  [ -n "$WD" ] && [ -S "$SWAYSOCK" ] && break
done
[ -n "$WD" ] || { echo "the headless compositor never came up:"; tail -5 "$TMP/sway.log"; exit 1; }
export WAYLAND_DISPLAY="$WD"
echo "headless compositor on $WAYLAND_DISPLAY (${W}x${H}), invisible to the session"

bash "$HERE/demo-run.sh" > "$TMP/app.log" 2>&1 &
APP=$!

for _ in $(seq 1 150); do
  sleep 0.1
  kill -0 "$APP" 2>/dev/null || { echo "the app exited before mapping a window:"; head -20 "$TMP/app.log"; exit 1; }
  swaymsg -t get_tree 2>/dev/null | grep -q '"app_id"' && break
done
sleep 0.6
# Without the focus the window never gets a keyboard enter at all.
swaymsg '[app_id=".*"] fullscreen enable' >/dev/null 2>&1 </dev/null
swaymsg '[app_id=".*"] focus'             >/dev/null 2>&1 </dev/null
sleep 0.4

wf-recorder -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite \
  > "$TMP/rec.log" 2>&1 &
REC=$!
sleep 1.2

mapfile -t LINES < "$STEPS"

# Phase one: the pointer, if the script asks for any.
for line in "${LINES[@]}"; do
  verb="${line%% *}"; rest="${line#* }"
  [ "$verb" = "$line" ] && rest=""
  case "$verb" in
    move)  set -- $rest
           swaymsg "seat seat0 cursor set $1 $2" >/dev/null 2>&1 </dev/null ;;
    click) b="${rest:-left}"
           swaymsg "seat seat0 cursor press button$b"   >/dev/null 2>&1 </dev/null
           sleep 0.1
           swaymsg "seat seat0 cursor release button$b" >/dev/null 2>&1 </dev/null ;;
  esac
done

# Phase two: one wtype, one keyboard, the whole script.
ARGS=()
for line in "${LINES[@]}"; do
  verb="${line%% *}"; rest="${line#* }"
  [ "$verb" = "$line" ] && rest=""
  case "$verb" in
    key)   ARGS+=(-s 110 -k "$rest") ;;
    chord) mods="${rest%%+*}"; k="${rest##*+}"
           IFS=',' read -ra ms <<< "$mods"
           ARGS+=(-s 110)
           for m in "${ms[@]}"; do ARGS+=(-M "$m"); done
           ARGS+=(-k "$k")
           for m in "${ms[@]}"; do ARGS+=(-m "$m"); done ;;
    # No `--` here: everything after it would be literal text for the rest of
    # the command line, and the rest of the command line is the rest of the demo.
    type)  ARGS+=(-s 110 -d 16 "$rest") ;;
    wait)  ARGS+=(-s "$(awk -v t="$rest" 'BEGIN{printf "%d", t*1000}')") ;;
  esac
done
wtype "${ARGS[@]}" </dev/null || echo "wtype failed"

sleep 1.0
cleanup
trap - EXIT

if [ -s "$OUT" ]; then
  echo "wrote $OUT ($(stat -c %s "$OUT") bytes)"
else
  echo "no output was written"; exit 1
fi
