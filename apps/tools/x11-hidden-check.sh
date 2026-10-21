#!/usr/bin/env bash
# A minimised X11 window that stays mapped stops painting.
#
#   x11-hidden-check.sh
#
# Compositing window managers keep a minimised window mapped for its
# thumbnail and mark it _NET_WM_STATE_HIDDEN instead. This opens an
# always-animating palmy window on a private Xvfb with no window manager,
# counts the frames it sends (PALMY_TRACE_LOOP) for 2 s visible, 2 s with
# _NET_WM_STATE_HIDDEN set on it while it stays mapped, and 2 s after the
# state is cleared. Passes when it painted while visible, not at all while
# hidden, and again afterwards. On main before the fix: 114 frames hidden.
# Needs Xvfb, xprop, xdotool.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"
TMP="$(mktemp -d /tmp/palmy-hidden-XXXXXX)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
"$ODIN" build "$HERE/x11-hidden-check" -collection:palmy="$R/palmy" -out:"$TMP/anim" || exit 1
n=75; while [ -e /tmp/.X11-unix/X$n ] || [ -e /tmp/.X$n-lock ]; do n=$((n+1)); done
Xvfb :$n -screen 0 800x600x24 -nolisten tcp >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 1 50); do [ -e /tmp/.X11-unix/X$n ] && break; sleep 0.1; done
export DISPLAY=:$n PALMY_BACKEND=x11 PALMY_TRACE_LOOP=1
unset WAYLAND_DISPLAY
"$TMP/anim" 2> "$TMP/loop.log" & PIDS+=($!)
id=""
for _ in $(seq 1 50); do id=$(xdotool search --name '^x11-hidden-check$' 2>/dev/null | head -1); [ -n "$id" ] && break; sleep 0.1; done
[ -n "$id" ] || { echo "FAIL: no window"; exit 1; }
sleep 1
count() { grep -c ' sent ' "$TMP/loop.log"; }
window() { local a b; a=$(count); sleep 2; b=$(count); echo $((b - a)); }
visible=$(window)
xprop -id "$id" -f _NET_WM_STATE 32a -set _NET_WM_STATE _NET_WM_STATE_HIDDEN; sleep 0.3
hidden=$(window)
mapped=$(xwininfo -id "$id" | grep -c IsViewable)
xprop -id "$id" -remove _NET_WM_STATE; sleep 0.3
again=$(window)
echo "frames in 2 s: visible $visible, mapped but hidden $hidden (still viewable: $mapped), shown again $again"
if [ "$visible" -gt 10 ] && [ "$hidden" -eq 0 ] && [ "$mapped" -eq 1 ] && [ "$again" -gt 10 ]; then
  echo "PASS"
else
  echo "FAIL"; exit 1
fi
