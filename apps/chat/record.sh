#!/usr/bin/env bash
# Record the palmy-chat demo: one server, two real clients, side by side, on a
# compositor nobody can see.
#
#   record.sh <out.mp4> <script-file> [width] [height]
#
# This used to drive the user's live Hyprland session, and every hard-won line
# in the old version was about that being a bad idea: windows had to be located
# by the pids this script started rather than by class, because another agent's
# palmy window would match first; focus had to be re-asserted before every
# keystroke, because `wtype` would otherwise type into somebody else's app; a
# take had to be rejected automatically when a crash toast or a shell popup
# landed in frame; and everything serialised behind /tmp/palmy-record.lock,
# where one orphaned process stalled every agent for half an hour.
#
# None of that is inherent, and none of it survives here. This starts its own
# headless sway — its own Wayland socket, its own virtual output, its own seat
# — exactly as apps/tools/headless-record.sh does for a single window. What it
# adds is the part that script cannot do: **two** windows.
#
# Two windows is why this file still exists. sway's default layout is a
# horizontal split, so the second client lands beside the first with no
# floating, no `resize exact`, and no placement verification at all — the thing
# the old version spent sixty lines getting wrong. And since there is exactly
# one seat with exactly these two clients on it, a keystroke cannot land
# anywhere else.
#
# No audio device is ever opened: wf-recorder is invoked without `-a`. The
# application has no camera or microphone path of its own.
#
# Two things in here are worked around rather than fixed, both because they
# are outside this directory.
#
# **swaymsg does not find a compositor from `WAYLAND_DISPLAY`.** It reads
# `$SWAYSOCK`, then `$I3SOCK`, then asks `sway --get-socketpath`, which only
# answers inside sway's own environment. Without the `SWAYSOCK` export below
# every swaymsg here fails with "Unable to retrieve socket path" and the waits
# silently time out instead of working. `apps/tools/headless-record.sh` has the
# same gap, which is why its fullscreen and its clicks do nothing.
#
# **A palmy window stops taking input after the first `wtype` process.** Run
# `wtype hello`, then `wtype -k Return`, and the Return never arrives. palmy
# has since had one fix for this — releasing the keyboard when the seat's
# capability goes away — and that is enough for a single window driven by a
# few invocations: probed directly, four in a row all land. It is **not**
# enough here. Re-recorded against the fixed toolkit, this demo still lost
# every keystroke after the first `type`, with no focus change in between, so
# the two-window case is still losing them. Reported; not patched, because
# this directory does not own `palmy/window.odin`.
#
# So the steps file is **compiled into a single `wtype` invocation**, which is
# not the restriction it sounds like: `-s MS` sleeps before the following
# options, `-k KEY` presses a named key, `-M`/`-m` hold a modifier, and a bare
# argument is typed as text, so one command line expresses a whole session and
# `wait` becomes wtype's own `-s`. (Never `--`: it makes everything after it
# literal text.) The steps that are *not* keystrokes — focus the other client,
# post as a third nickname, end a client and start it again — are shell work
# that has to interleave with the typing, so they go through the compositor:
# sway binds one chord to a helper script, the compiled argv presses that chord
# where the step belongs, and the helper pops the next action off a queue. sway
# grabs the chord, so no client ever sees it.
#
# Steps, one per line:
#   focus left|right          give that client the keyboard
#   key <X11name>             a single named key
#   chord <mods>+<key>        e.g. `chord ctrl+o`
#   type <text>               literal text
#   move <x> <y>              pointer, for hover
#   click [button]            press and release
#   post <nick> <ch> <txt>    a third nickname posts over the real protocol
#   attach <nick> <ch> <path> ...and uploads a real file
#   close right               end that client (presence goes offline for real)
#   open right <nick>         start it again, which is how the demo shows that
#                             unread survives a reconnect
#   wait <seconds>
set -uo pipefail

OUT="${1:?output mp4}"; STEPS="${2:?script file}"
W="${3:-1920}"; H="${4:-1080}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/chat.bin"
SRV="$HERE/server/chat-server.bin"

# A scratch store and a port of its own: the demo must not read, write or
# disturb whatever is in the user's real ~/.local/share/palmy-chat, and must
# not collide with a server they are running.
PORT=8809
STORE="$(mktemp -d /tmp/palmy-chat-demo-XXXXXX)"

[ -x "$CLI" ] || { echo "not built: $CLI"; exit 1; }
[ -x "$SRV" ] || { echo "not built: $SRV"; exit 1; }
[ -f "$STEPS" ] || { echo "no steps file: $STEPS"; exit 1; }
# Refuse to run against somebody else's server. Without this check a leftover
# process on this port is adopted silently, and the take comes back with every
# client reading "Offline — retrying in 1s" because the real server could not
# bind. That happened once and the frames looked fine until you read the
# footer.
if ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "something is already listening on 127.0.0.1:$PORT; not recording against it"
  exit 1
fi
command -v sway >/dev/null || { echo "sway is required for the headless compositor"; exit 1; }
command -v wf-recorder >/dev/null || { echo "wf-recorder is required"; exit 1; }
command -v wtype >/dev/null || { echo "wtype is required"; exit 1; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d /tmp/palmy-chat-record-XXXXXX)"
mkdir -p "$(dirname "$OUT")"

A=""; B=""; SRV_PID=""; REC=""; SWAY=""
cleanup() {
  [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$REC" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$REC" 2>/dev/null
  [ -n "$A" ] && kill "$A" 2>/dev/null
  [ -n "$B" ] && kill "$B" 2>/dev/null
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  if [ -n "$SWAY" ]; then
    kill "$SWAY" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$SWAY" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$SWAY" 2>/dev/null
    wait "$SWAY" 2>/dev/null
  fi
  if [ -n "${PALMY_RECORD_KEEP:-}" ]; then
    echo "keeping $TMP and $STORE"
  else
    rm -rf "$TMP" "$STORE"
  fi
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
# One chord, bound to a script that pops the next non-keyboard step off a
# queue. sway grabs it, so it never reaches a client. See the note at the top.
bindsym Mod4+F12 exec $TMP/next-step.sh
# Keep this file minimal otherwise: sway paints a red "errors in your config
# file" banner across the top of the screen for any directive it does not
# know, and it lands in every frame of the recording.
CONF

cat > "$TMP/next-step.sh" <<'HELPER'
#!/usr/bin/env bash
# Run the next queued non-keyboard step. sway execs this with its own
# environment, not the recorder's, so everything it needs is in $TMP/env, and
# the clients' pids are in $TMP/a.pid and $TMP/b.pid where `open right` can
# replace one.
set -uo pipefail
TMP="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$TMP/env"; set +a
n="$(cat "$TMP/n" 2>/dev/null || echo 0)"
line="$(sed -n "$((n + 1))p" "$TMP/actions")"
echo $((n + 1)) > "$TMP/n"
echo "step: $line" >> "$TMP/trace"
swh() { swaymsg "$@" >/dev/null 2>&1; }
# Focus by pid, never by direction: `focus left` is relative to whatever
# happens to be focused and to how sway laid the two containers out, and the
# first take with it attributed every message to the wrong client.
focus_pid() {
  p="$(cat "$1" 2>/dev/null)"
  [ -n "$p" ] && swh "[pid=$p] focus"
}
case "$line" in
  focus\ left)  focus_pid "$TMP/a.pid" ;;
  focus\ right) focus_pid "$TMP/b.pid" ;;
  move\ *)  set -- ${line#move }; swh "seat seat0 cursor set $1 $2" ;;
  click*)   b="${line#click}"; b="${b# }"; b="${b:-left}"
            swh "seat seat0 cursor press button$b"; sleep 0.1
            swh "seat seat0 cursor release button$b" ;;
  post\ *)  set -- ${line#post }; nick="$1"; ch="$2"; shift 2
            "$CLI" --port "$PORT" --nick "$nick" --post "$ch" "$*" >/dev/null 2>&1 ;;
  attach\ *) set -- ${line#attach }
            "$CLI" --port "$PORT" --nick "$1" --attach "$2" "$3" >/dev/null 2>&1 ;;
  close\ right)
            pid="$(cat "$TMP/b.pid" 2>/dev/null)"
            [ -n "$pid" ] && kill "$pid" 2>/dev/null
            : > "$TMP/b.pid"
            sleep 0.3; focus_pid "$TMP/a.pid" ;;
  open\ right\ *)
            nick="${line#open right }"
            "$CLI" --port "$PORT" --nick "$nick" > "$TMP/b2.log" 2>&1 &
            echo $! > "$TMP/b.pid"
            for _ in $(seq 1 100); do
              sleep 0.1
              [ "$(swaymsg -t get_tree 2>/dev/null | grep -c '"app_id": "palmy"')" -ge 2 ] && break
            done
            sleep 0.4
            focus_pid "$TMP/b.pid" ;;
  *) echo "unknown step: $line" >> "$TMP/trace" ;;
esac
HELPER
chmod +x "$TMP/next-step.sh"


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

# swaymsg does NOT find a compositor from WAYLAND_DISPLAY. It reads $SWAYSOCK,
# then $I3SOCK, then asks `sway --get-socketpath`, which only answers inside
# sway's own environment. Without this every swaymsg here fails with "Unable to
# retrieve socket path" and the script's waits time out instead of working —
# which is also why `apps/tools/headless-record.sh` never actually focuses,
# fullscreens or clicks anything. Reported as a gap; it is not this app's file
# to fix.
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
# The server, and a conversation to arrive into
# ---------------------------------------------------------------------------

setsid "$SRV" --port "$PORT" --dir "$STORE" --quiet >"$TMP/srv.log" 2>&1 </dev/null &
SRV_PID=$!
for _ in $(seq 1 60); do
  sleep 0.1
  ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . && break
done

post() { "$CLI" --port "$PORT" --nick "$1" --post "$2" "$3" >/dev/null 2>&1; }
attach() { "$CLI" --port "$PORT" --nick "$1" --attach "$2" "$3" >/dev/null 2>&1; }

# The multi-line markdown lives here because `wtype` cannot send Shift+Enter:
# a newline in the composer is untypeable from a script.
post sam    general 'Morning — the rasterizer branch is **green** again.'
post jordan general 'Nice. Did the `scroll_into_view` fix land?'
post sam    general $'Yes:\n\n```odin\np.scroll_to(ui, list, {0, 1e9})\n```\n\nIt re-clamps every frame, so the list stays glued to the bottom.'
post jordan general $'Three things left before we cut it:\n\n- the composer caret on wrapped lines\n- unread badges\n- a jump-to-latest affordance'
post sam    general $'> the composer caret on wrapped lines\n\nThat one is mine. See [the notes](https://example.com/notes).'

# A root with a thread already hanging off it, so the "N replies" stub is on
# screen the moment the window opens. `--post --thread` is the client's own
# one-shot path, so these are real thread replies over the real protocol — the
# server assigns the ids and derives the counts exactly as it does for a live
# client.
post alexis general 'Read state is the one we have to get right: unread must survive a reconnect.'
ROOT=$("$CLI" --port "$PORT" --nick jordan --post general \
       'Proposal: a per-channel read cursor, server-side, keyed on the nickname.' |
       grep -o '#[0-9]*' | tr -d '#')
[ -n "${ROOT:-}" ] || { echo "could not seed the thread root"; exit 1; }
in_thread() { "$CLI" --port "$PORT" --nick "$1" --post general "$2" --thread "$ROOT" >/dev/null 2>&1; }
in_thread sam    'Yes — and derive the count from it rather than storing both.'
in_thread jordan 'Server-side means it follows you between clients, too.'
in_thread sam    'A cursor only ever moves forward, so a stale tab cannot un-read anything.'
in_thread alexis 'Agreed. Threads get their own count, so the channel badge stays honest.'

# A real file, uploaded over the same socket as everything else. It lives in a
# folder of its own rather than beside this script's bookkeeping, because the
# attach dialog opens there and a list of `b.pid`, `actions` and `sway.log` in
# frame says nothing about the application.
mkdir -p "$TMP/files" "$TMP/downloads"
printf 'geometry mismatches: 0\ntext mismatches: 0\nchecked: 412 cases\n' > "$TMP/files/parity.txt"
printf '# Cut 0.4\n\n- composer caret on wrapped lines\n- server-side read cursors\n- threads\n' > "$TMP/files/release-notes.md"
printf 'frame 16.1ms p50, 18.4ms p99, 412 nodes\n' > "$TMP/files/bench.txt"
attach jordan general "$TMP/files/parity.txt"

# Saving an attachment writes a real file, so point the clients at a scratch
# directory rather than the user's own ~/Downloads.
export PALMY_CHAT_DOWNLOADS="$TMP/downloads"
export PALMY_CHAT_ATTACH_DIR="$TMP/files"

# ---------------------------------------------------------------------------
# Two clients, tiled by the compositor
# ---------------------------------------------------------------------------

"$CLI" --port "$PORT" --nick alexis > "$TMP/a.log" 2>&1 &
A=$!
for _ in $(seq 1 100); do
  sleep 0.1
  kill -0 "$A" 2>/dev/null || { echo "the left client exited early:"; head -5 "$TMP/a.log"; exit 1; }
  [ "$(swaymsg -t get_tree 2>/dev/null | grep -c '"app_id": "palmy"')" -ge 1 ] && break
done

# Let the first window settle before the second maps: two palmy clients
# racing onto a compositor that is itself still coming up produced one take
# where the second exited before it ever drew.
sleep 0.8

"$CLI" --port "$PORT" --nick sam > "$TMP/b.log" 2>&1 &
B=$!
for _ in $(seq 1 100); do
  sleep 0.1
  kill -0 "$B" 2>/dev/null || { echo "the right client exited early:"; head -5 "$TMP/b.log"; exit 1; }
  [ "$(swaymsg -t get_tree 2>/dev/null | grep -c '"app_id": "palmy"')" -ge 2 ] && break
done

# Refuse to record anything that is not exactly these two clients. On a private
# seat that can only fail if one of them died, but a silent one-window take is
# not a two-client demo and should not be mistaken for one.
N=$(swaymsg -t get_tree | grep -c '"app_id": "palmy"')
[ "$N" = "2" ] || { echo "expected 2 client windows on the headless seat, found $N"; exit 1; }
echo "two clients on $WAYLAND_DISPLAY, tiled side by side by sway"
sleep 0.6

wf-recorder -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite \
  > "$TMP/rec.log" 2>&1 &
REC=$!
sleep 1.2
swaymsg "[pid=$A] focus" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Compile the steps file into one wtype argv plus a queue of shell actions
# ---------------------------------------------------------------------------

: > "$TMP/actions"
: > "$TMP/trace"
echo 0 > "$TMP/n"
echo "$A" > "$TMP/a.pid"
echo "$B" > "$TMP/b.pid"

cat > "$TMP/env" <<ENV
CLI=$CLI
PORT=$PORT
WAYLAND_DISPLAY=$WAYLAND_DISPLAY
SWAYSOCK=$SWAYSOCK
XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
PALMY_CHAT_DOWNLOADS=$PALMY_CHAT_DOWNLOADS
PALMY_CHAT_ATTACH_DIR=$PALMY_CHAT_ATTACH_DIR
ENV

# The very first key is sometimes swallowed while the client is still taking
# keyboard focus, so spend it on something with no effect: BackSpace in an
# empty composer.
ARGS=( -s 900 -k BackSpace )
SEEN=0
QUEUED=0

queue() {
  printf '%s\n' "$1" >> "$TMP/actions"
  QUEUED=$((QUEUED + 1))
  # Press the chord, then leave the helper room to finish before the next key.
  ARGS+=( -M logo -k F12 -m logo -s 500 )
}

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
    *)        queue "$line" ;;
  esac
  ARGS+=( -s 120 )    # the pause that used to sit between step processes
done < "$STEPS"

echo "compiled $SEEN steps: $QUEUED through the compositor, the rest into one wtype argv"
wtype "${ARGS[@]}"
WT=$?

if ! ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "WARNING: the server stopped listening during the take — the clients will have gone offline"
  tail -20 "$TMP/srv.log" 2>/dev/null
fi

RAN="$(cat "$TMP/n" 2>/dev/null || echo 0)"
[ "$WT" = "0" ] || echo "wtype exited $WT"
[ "$RAN" = "$QUEUED" ] || echo "WARNING: $RAN of $QUEUED queued steps ran"
[ -n "${PALMY_RECORD_TRACE:-}" ] && cat "$TMP/trace"
B="$(cat "$TMP/b.pid" 2>/dev/null)"

sleep 1.0
cleanup
trap - EXIT

if [ ! -s "$OUT" ]; then
  echo "no output was written"; exit 1
fi
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
echo "wrote $OUT (${DUR}s, $(stat -c %s "$OUT") bytes)"
