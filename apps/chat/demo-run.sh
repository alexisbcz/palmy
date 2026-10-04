#!/usr/bin/env bash
# The "binary" that apps/tools/record-app.sh launches for this app.
#
# A chat demo is only worth anything if there are two clients in it, so this
# brings up the real server and two real client processes side by side. Both
# speak the protocol in PROTOCOL.md to 127.0.0.1:8787; nothing on screen is
# faked.
#
# Window placement, and why it looks like this: record-app.sh reads the
# geometry of the *first* palmy window about 2.2s after launch and records that
# rectangle for the whole take. So the first client opens fullscreen — which
# makes the recorded rectangle the whole screen — and is dropped back to the
# left half a moment later, after the rectangle has been fixed. The second
# client then takes the right half.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRV="$HERE/server/chat-server.bin"
CLI="$HERE/chat.bin"
STORE="$HOME/.local/share/palmy-chat"

A=""; B=""; OWN_SRV=""; FOCUS=""
cleanup() {
  [ -n "$FOCUS" ] && kill "$FOCUS" 2>/dev/null
  [ -n "$A" ] && kill "$A" 2>/dev/null
  [ -n "$B" ] && kill "$B" 2>/dev/null
  [ -n "$OWN_SRV" ] && kill "$OWN_SRV" 2>/dev/null
  return 0
}
trap cleanup EXIT TERM INT

hc() { hyprctl dispatch "$1" >/dev/null 2>&1; }

# A fresh store, so the take reads the same way every time.
rm -rf "$STORE"
for pid in $(pgrep -x chat-server.bin 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 0.3

# A stale crash card from some other app sitting over the recording helps
# nobody. (`hyprctl dismissnotify` is for Hyprland's own notifications; these
# come from the omarchy shell.)
omarchy-notification-dismiss "Process crashed" >/dev/null 2>&1

# Window rules first: they are only consulted when a window maps.
hyprctl eval 'o.window({ title = "^chat — .*$" }, { float = true, size = "944 1000" }) return 1' >/dev/null 2>&1
# Omarchy dims every window slightly; a recording of a chat client should not
# have the desktop showing through its own background.
hyprctl eval 'o.window({ title = "^chat — .*$" }, { opacity = "1 1" }) return 1' >/dev/null 2>&1

# Client one goes up first and fullscreen, because record-app.sh reads the
# geometry at 2.2s and that read is what fixes the recorded rectangle. It will
# spend its first half second offline and reconnect by itself, which is the
# honest thing for it to show.
"$CLI" --nick alexis --fullscreen &
A=$!
setsid "$SRV" --quiet >/dev/null 2>&1 </dev/null &
OWN_SRV=$!

# Seed a short conversation over the real protocol. The multi-line markdown
# goes in here because `wtype -k` cannot send Shift+Enter, so a newline cannot
# be typed from a recorder script.
sleep 1.4
"$CLI" --nick sam    --post general 'Morning — the rasterizer branch is **green** again.' >/dev/null 2>&1
"$CLI" --nick jordan --post general 'Nice. Did the `scroll_into_view` fix land?' >/dev/null 2>&1
"$CLI" --nick sam    --post general $'Yes:\n\n```odin\np.scroll_to(ui, list, {0, 1e9})\n```\n\nIt re-clamps every frame, so the list stays glued to the bottom.' >/dev/null 2>&1
"$CLI" --nick jordan --post general $'Three things left before we cut it:\n\n- the composer caret on wrapped lines\n- unread badges\n- a jump-to-latest affordance' >/dev/null 2>&1
"$CLI" --nick sam    --post general $'> the composer caret on wrapped lines\n\nThat one is mine. See [the notes](https://example.com/notes).' >/dev/null 2>&1

# Wait out the recorder's geometry read, then take client one out of
# fullscreen and park it on the left.
sleep 2.2
hc 'hl.dsp.cursor.move({x=960,y=540})'
sleep 0.2
hc 'hl.dsp.window.fullscreen({mode="fullscreen"})'
sleep 0.4
hc 'hl.dsp.window.resize({x=944,y=1000,exact=true})'
hc 'hl.dsp.window.move({x=10,y=40,exact=true})'

# Client two on the right.
"$CLI" --nick sam &
B=$!
sleep 2.2
# The newest floating window opens centred and on top, so the middle of the
# screen is reliably inside it — unlike the right half, which it may not cover
# until it has been moved there.
hc 'hl.dsp.cursor.move({x=960,y=540})'
sleep 0.3
hc 'hl.dsp.window.resize({x=944,y=1000,exact=true})'
hc 'hl.dsp.window.move({x=966,y=40,exact=true})'
hc 'hl.dsp.cursor.move({x=480,y=620})'

# Keyboard focus, and why this loop exists.
#
# record-app.sh's `move` step warps the pointer, and in this Hyprland a warp
# does NOT move keyboard focus — follow_mouse only reacts to real pointer
# motion. Without this, every keystroke in the script would land in whichever
# window mapped last, and the recording would show one client talking to
# itself. (It did, the first time.) So: poll the cursor and give the keyboard
# to whichever of the two windows it is sitting over, which is what `move`
# means in the script.
(
  last=""
  while true; do
    read -r cx cy <<< "$(hyprctl cursorpos 2>/dev/null | tr -d ',')"
    [ -z "${cx:-}" ] && { sleep 0.25; continue; }
    if [ "$cx" -lt 960 ]; then want=$A; else want=$B; fi
    if kill -0 "$want" 2>/dev/null && [ "$want" != "$last" ]; then
      hc "hl.dsp.focus({window=\"pid:$want\"})"
      last=$want
    fi
    sleep 0.25
  done
) &
FOCUS=$!

# Two timed events the recorder script cannot produce by itself: a message
# into a channel nobody is looking at (so an unread badge appears), and the
# second client vanishing (so presence goes offline for real).
(
  sleep 28
  "$CLI" --nick jordan --post design 'Spacing pass on the sidebar is up for review.' >/dev/null 2>&1
) &
(
  sleep 51
  [ -n "$B" ] && kill "$B" 2>/dev/null
  # With the second client gone, give the first one the whole screen rather
  # than leaving half the recording showing the desktop behind it.
  sleep 0.6
  hc "hl.dsp.focus({window=\"pid:$A\"})"
  hc 'hl.dsp.window.resize({x=1900,y=1000,exact=true})'
  hc 'hl.dsp.window.move({x=10,y=40,exact=true})'
) &

wait "$A"
