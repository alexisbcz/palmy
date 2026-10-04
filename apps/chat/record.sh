#!/usr/bin/env bash
# Record the palmy-chat demo: one server, two real clients, side by side.
#
#   record.sh <out.mp4> <script-file>
#
# This is apps/tools/record-app.sh reworked for an application that is two
# processes, with the fix apps/videoedit/record.sh found: windows are located
# by **the pids this script started**, never by "the first window whose class
# is palmy". Several agents run palmy applications on this machine at once, and
# the shared recorder's first-match query hands back someone else's window — one
# agent ended up with a minute of terminal. For a two-client demo that would be
# worse: the capture rectangle has to be the union of two specific windows.
#
# Keyboard focus is explicit for the same reason. `move` only warps the
# pointer, and in this Hyprland a warp does not move focus (follow_mouse reacts
# to real motion), so the first take of this demo had both windows' keystrokes
# land in one client — the server log showed every message authored by `sam`.
# `focus left|right` targets a pid, and every keystroke re-focuses before it is
# sent, because another agent's window can steal focus mid-take.
#
# Nothing but these two windows is captured, and no audio device is opened:
# wf-recorder is invoked without `-a`, so the machine's microphone is never a
# source. The application has no camera or microphone path of its own.
#
# Steps, one per line:
#   key <X11name>          wtype -k, into the focused client
#   type <text>            wtype, into the focused client
#   focus left|right       give that client the keyboard
#   move <x> <y>           pointer to a capture-relative position (hover)
#   post <nick> <ch> <txt> a third nickname posts over the real protocol
#   close right            end that client (presence goes offline for real)
#   grow left              give that client the whole capture rectangle
#   wait <seconds>         sleep
set -uo pipefail

OUT="${1:?output mp4}"; SCRIPT="${2:?script file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/chat.bin"
SRV="$HERE/server/chat-server.bin"
STORE="$HOME/.local/share/palmy-chat"
PORT=8787

# Two 944x1000 windows with a 12px gutter, inside a 1920x1080 screen.
LX=10;  LY=40; CW=944; CH=1000
RX=966; RY=40
CAP_X=$LX; CAP_Y=$LY; CAP_W=$((RX + CW - LX)); CAP_H=$CH

mkdir -p "$(dirname "$OUT")"

LOCK=/tmp/palmy-record.lock
exec 9>"$LOCK"
if ! flock -w 1800 9; then
  echo "timed out waiting for the recording lock ($LOCK)"; exit 1
fi
echo "holding the recording lock"

A=""; B=""; SRV_PID=""; REC=""
cleanup() {
  [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null
  [ -n "$A" ] && kill "$A" 2>/dev/null
  [ -n "$B" ] && kill "$B" 2>/dev/null
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

hc() { hyprctl dispatch "$1" >/dev/null 2>&1; }

# place moves a window to an exact rectangle. It does NOT call
# `window.float`: that dispatcher toggles, and the rule below already opens
# these windows floating, so calling it would tile them again — which is
# exactly how one take ended up recording a terminal.
place() { # place <pid> <x> <y>
  hc "hl.dsp.window.resize({window='pid:$1', x=$CW, y=$CH, exact=true})"
  hc "hl.dsp.window.move({window='pid:$1', x=$2, y=$3, exact=true})"
  hc "hl.dsp.window.bring_to_top({window='pid:$1'})"
}

# geom <pid> -> "x y w h ws", or empty if the window is not mapped.
geom() {
  hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid') == $1:
        x,y = c['at']; w,h = c['size']
        print(x, y, w, h, c['workspace']['id']); break"
}

# A stale crash card from another agent's application renders into any
# recording. `hyprctl dismissnotify` is for Hyprland's own notifications;
# these come from the omarchy shell.
omarchy-notification-dismiss "Process crashed" >/dev/null 2>&1

# Both clients open floating at a known size. A window rule is the only thing
# consulted at map time, so this has to be registered before either launches.
# (This Hyprland takes rules through `eval`, not `keyword`.)
hyprctl eval 'o.window({ title = "^chat — .*$" }, { float = true, size = "944 1000" }) return 1' >/dev/null 2>&1
# Omarchy dims every window slightly; a chat client should not have the
# desktop showing through its own background.
hyprctl eval 'o.window({ title = "^chat — .*$" }, { opacity = "1 1" }) return 1' >/dev/null 2>&1

# Only the process actually holding the port is in the way — killing every
# `chat-server.bin` by name would take out a self-test running next to this.
for pid in $(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
  kill "$pid" 2>/dev/null
done
sleep 0.4

rm -rf "$STORE"
setsid "$SRV" --quiet >/dev/null 2>&1 </dev/null &
SRV_PID=$!
sleep 0.9

# Seed a short conversation through the real protocol, so the window is not
# empty when recording starts. The multi-line markdown lives here because
# `wtype -k` cannot send Shift+Enter: a newline is untypeable from a script.
"$CLI" --nick sam    --post general 'Morning — the rasterizer branch is **green** again.' >/dev/null 2>&1
"$CLI" --nick jordan --post general 'Nice. Did the `scroll_into_view` fix land?' >/dev/null 2>&1
"$CLI" --nick sam    --post general $'Yes:\n\n```odin\np.scroll_to(ui, list, {0, 1e9})\n```\n\nIt re-clamps every frame, so the list stays glued to the bottom.' >/dev/null 2>&1
"$CLI" --nick jordan --post general $'Three things left before we cut it:\n\n- the composer caret on wrapped lines\n- unread badges\n- a jump-to-latest affordance' >/dev/null 2>&1
"$CLI" --nick sam    --post general $'> the composer caret on wrapped lines\n\nThat one is mine. See [the notes](https://example.com/notes).' >/dev/null 2>&1

"$CLI" --nick alexis & A=$!
sleep 2.6
"$CLI" --nick sam    & B=$!
sleep 2.6

for pid in "$A" "$B"; do
  if ! kill -0 "$pid" 2>/dev/null; then echo "a client exited before it could be recorded"; exit 1; fi
done

# Place both, then check. Two tries, because a window can still be settling
# into the rule's size when the first resize lands.
for attempt in 1 2 3; do
  place "$A" "$LX" "$LY"
  place "$B" "$RX" "$RY"
  sleep 0.8
  read AX AY AW AH WS <<< "$(geom "$A")"
  read BX BY BW BH WS2 <<< "$(geom "$B")"
  [ -n "${AX:-}" ] && [ -n "${BX:-}" ] && \
    [ "$AX" = "$LX" ] && [ "$AY" = "$LY" ] && [ "$BX" = "$RX" ] && [ "$BY" = "$RY" ] && \
    [ "$AW" = "$CW" ] && [ "$BW" = "$CW" ] && break
  echo "placement attempt $attempt: left=${AX:-?},${AY:-?} ${AW:-?}x${AH:-?} right=${BX:-?},${BY:-?} ${BW:-?}x${BH:-?}"
done

# Refuse to record anything that is not exactly these two windows. A take that
# quietly captures whatever happens to be at those coordinates is worse than
# no take: one came back as a minute of somebody's terminal.
if [ -z "${AX:-}" ] || [ -z "${BX:-}" ]; then
  echo "a client window never appeared"; exit 1
fi
if [ "$AX" != "$LX" ] || [ "$AY" != "$LY" ] || [ "$AW" != "$CW" ] || [ "$AH" != "$CH" ] ||
   [ "$BX" != "$RX" ] || [ "$BY" != "$RY" ] || [ "$BW" != "$CW" ] || [ "$BH" != "$CH" ]; then
  echo "refusing to record: windows are at $AX,$AY ${AW}x${AH} and $BX,$BY ${BW}x${BH},"
  echo "expected $LX,$LY and $RX,$RY at ${CW}x${CH}"
  exit 1
fi
if [ "$WS" != "$WS2" ]; then
  echo "refusing to record: the two clients are on workspaces $WS and $WS2"; exit 1
fi
echo "clients verified at $AX,$AY and $BX,$BY (${CW}x${CH}) on workspace $WS"

# Be on the workspace the windows are on, or the capture is of whatever else
# happens to be showing at those coordinates.
hc "hl.dsp.focus({workspace='$WS'})"
sleep 0.6
ACTIVE=$(hyprctl activeworkspace -j | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
[ "$ACTIVE" != "$WS" ] && echo "note: windows are on workspace $WS but $ACTIVE is showing"

echo "recording $CAP_X,$CAP_Y ${CAP_W}x${CAP_H} (two clients, no audio source)"
wf-recorder -g "$CAP_X,$CAP_Y ${CAP_W}x${CAP_H}" -f "$OUT" -c libx264 -p crf=20 -p preset=veryfast --overwrite >/dev/null 2>&1 &
REC=$!
sleep 1.4

SIDE=$A            # which client currently owns the keyboard
focus_side() { hc "hl.dsp.focus({window='pid:$SIDE'})"; }
focus_side

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    \#*) ;;
    focus\ left)  SIDE=$A; focus_side; sleep 0.25 ;;
    focus\ right) SIDE=$B; focus_side; sleep 0.25 ;;
    key\ *)   focus_side; wtype -k "${line#key }" ;;
    type\ *)  focus_side; wtype -- "${line#type }" ;;
    move\ *)  set -- ${line#move }; hc "hl.dsp.cursor.move({x=$((CAP_X+$1)),y=$((CAP_Y+$2))})" ;;
    post\ *)  set -- ${line#post }; nick="$1"; ch="$2"; shift 2
              "$CLI" --nick "$nick" --post "$ch" "$*" >/dev/null 2>&1 ;;
    close\ right) kill "$B" 2>/dev/null; B=""; SIDE=$A ;;
    grow\ left)   hc "hl.dsp.window.resize({window='pid:$A', x=$CAP_W, y=$CAP_H, exact=true})"
                  hc "hl.dsp.window.move({window='pid:$A', x=$CAP_X, y=$CAP_Y, exact=true})"
                  SIDE=$A; focus_side ;;
    wait\ *)  sleep "${line#wait }" ;;
    *) echo "unknown step: $line" ;;
  esac
done < "$SCRIPT"

sleep 1
kill -INT "$REC" 2>/dev/null; wait "$REC" 2>/dev/null; REC=""
kill "$A" 2>/dev/null; A=""
[ -n "$B" ] && kill "$B" 2>/dev/null; B=""
kill "$SRV_PID" 2>/dev/null; SRV_PID=""
sleep 0.5

if [ ! -s "$OUT" ]; then
  echo "recording failed"; exit 1
fi

# Reject a contaminated take automatically rather than eyeballing it. The
# top-right corner of the capture is always a member panel — `bg-card`, which
# is nearly black in this theme. Anything bright there means something was
# drawn over the clients: the omarchy bar's agents popup put a usage panel
# over one take for its whole duration, and another agent's window could do
# the same. A take that shows someone else's screen is not shippable.
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
BAD=0
for frac in 0.05 0.2 0.35 0.5 0.65 0.8 0.95; do
  t=$(python3 -c "print(round($DUR * $frac, 2))")
  m=$(ffmpeg -v error -ss "$t" -i "$OUT" -frames:v 1 \
        -vf "crop=240:240:$((CAP_W-250)):10,format=gray" -f rawvideo - 2>/dev/null |
      python3 -c "
import sys
d = sys.stdin.buffer.read()
print(round(sum(d)/len(d), 1) if d else 255)")
  over=$(python3 -c "print(1 if $m > 120 else 0)")
  if [ "$over" = "1" ]; then
    echo "frame at ${t}s: something is covering the clients (corner brightness $m)"
    BAD=1
  fi
done
if [ "$BAD" = "1" ]; then
  echo "rejecting this take; re-run when the desktop is clear"
  rm -f "$OUT"
  exit 1
fi

ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" | xargs -I{} echo "wrote $OUT ({}s, corners clean)"
