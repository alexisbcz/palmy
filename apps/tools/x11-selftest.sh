#!/usr/bin/env bash
# x11-selftest.sh — prove palmy's X11 backend on an X server nobody can see.
#
#   apps/tools/x11-selftest.sh [display-number]
#
# Everything happens on a private Xvfb (default :107) started with its own
# MIT-MAGIC-COOKIE-1 authority file. That has two consequences worth stating:
#
#   - Nothing appears on the user's screen, and no keystroke can land in
#     another window. A private X server has its own screen and its own input,
#     which is the whole reason this does not need the recording lock that the
#     Wayland tooling needs.
#   - The connection is authenticated, so the cookie parser is exercised by
#     every single assertion rather than by one token test.
#
# The oracle for "did the right pixels arrive" is palmy's own offscreen
# renderer: the rasterizer is shared between backends, so a capture of the
# window and an offscreen render of the same tree at the same size must agree
# exactly. They do, to a mean absolute error of 0.
set -uo pipefail

DISP="${1:-107}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ODIN="${ODIN:-odin}"
WORK="$(mktemp -d /tmp/palmy-x11-selftest.XXXXXX)"
BIN="$WORK/x11-selftest.bin"
PIXDIFF="$ROOT/parity/odin/pixdiff.bin"
SCREEN_W=1280
SCREEN_H=800

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$2', got '$3')"; fi
}

contains() { # contains <description> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) no "$1 (no '$2' in '$3')" ;; esac
}

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  [ -n "${XPID:-}" ] && kill "$XPID" 2>/dev/null
  sleep 0.2
  rm -f "/tmp/.X${DISP}-lock"
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '\n%s\n' "$1"; }

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
say "building"
"$ODIN" build "$ROOT/apps/tools/x11-selftest" \
  -collection:palmy="$ROOT/palmy" -o:minimal -out:"$BIN" || exit 1
[ -x "$PIXDIFF" ] || "$ODIN" build "$ROOT/parity/odin/pixdiff" -o:speed -out:"$PIXDIFF" || exit 1

# --------------------------------------------------------------------------
# A private, authenticated X server
# --------------------------------------------------------------------------
say "starting Xvfb :$DISP with MIT-MAGIC-COOKIE-1"
export XAUTHORITY="$WORK/Xauthority"
: > "$XAUTHORITY"
COOKIE=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
xauth -f "$XAUTHORITY" add ":$DISP" MIT-MAGIC-COOKIE-1 "$COOKIE" >/dev/null 2>&1

rm -f "/tmp/.X${DISP}-lock"
Xvfb ":$DISP" -screen 0 "${SCREEN_W}x${SCREEN_H}x24" -nolisten tcp -auth "$XAUTHORITY" \
  > "$WORK/xvfb.log" 2>&1 &
XPID=$!
export DISPLAY=":$DISP"
for _ in $(seq 1 50); do
  xdotool getdisplaygeometry >/dev/null 2>&1 && break
  sleep 0.1
done
xdotool getdisplaygeometry >/dev/null 2>&1 \
  && ok "the private X server is up and the cookie authenticates xdotool" \
  || { no "Xvfb :$DISP never came up"; echo "$pass passed, $fail failed"; exit 1; }

# An unauthenticated client must be refused, which is what makes the cookie
# parser load-bearing rather than decorative.
say "authentication"
BAD=$(XAUTHORITY="$WORK/empty" PALMY_BACKEND=x11 "$BIN" run "$WORK/bad.txt" 2>&1)
contains "an empty authority file is refused with an explanation" "refused the connection" "$BAD"
contains "and the message names the file it looked in" "MIT-MAGIC-COOKIE-1" "$BAD"

WRONGDIR="$WORK/wrong"; mkdir -p "$WRONGDIR"
xauth -f "$WRONGDIR/Xauthority" add ":$DISP" MIT-MAGIC-COOKIE-1 \
  "00112233445566778899aabbccddeeff" >/dev/null 2>&1
WRONG=$(XAUTHORITY="$WRONGDIR/Xauthority" PALMY_BACKEND=x11 "$BIN" run "$WORK/bad2.txt" 2>&1)
contains "a wrong cookie is refused too" "refused the connection" "$WRONG"

# --------------------------------------------------------------------------
# Backend selection
# --------------------------------------------------------------------------
say "backend selection"
LAYER=$(PALMY_BACKEND=x11 "$BIN" layer 2>&1)
contains "a layer-surface Config on X11 fails with a clear message" "wlr-layer-shell" "$LAYER"
contains "and says what to do instead" "ordinary window" "$LAYER"

BADBE=$(PALMY_BACKEND=mystery "$BIN" run "$WORK/bad3.txt" 2>&1)
contains "an unknown PALMY_BACKEND is rejected" "PALMY_BACKEND must be" "$BADBE"

# --------------------------------------------------------------------------
# Open a window
# --------------------------------------------------------------------------
say "opening a window (backend chosen automatically from DISPLAY)"
STATE="$WORK/state.txt"
env -u WAYLAND_DISPLAY "$BIN" run "$STATE" > "$WORK/app.log" 2>&1 &
APP_PID=$!

WID=""
for _ in $(seq 1 60); do
  WID=$(xdotool search --name "palmy x11 selftest" 2>/dev/null | head -1)
  [ -n "$WID" ] && break
  sleep 0.1
done
[ -n "$WID" ] && ok "the window appears in the server's window tree" \
  || { no "no window ever appeared"; cat "$WORK/app.log"; echo "$pass passed, $fail failed"; exit 1; }

st() { grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-; }

# The server publishes the window a moment before the app gets back from
# create() and reports on it, so wait for the first report.
for _ in $(seq 1 50); do
  [ -s "$STATE" ] && break
  sleep 0.1
done

check "the backend chosen from DISPLAY alone is x11" "x11" "$(st backend)"

GEOM=$(xwininfo -id "$WID")
check "xwininfo reports the requested width" "640" "$(echo "$GEOM" | awk '/Width:/{print $2}')"
check "xwininfo reports the requested height" "400" "$(echo "$GEOM" | awk '/Height:/{print $2}')"
check "the app sees the same size as the server" "640x400" "$(st size)"
check "the window is mapped (IsViewable)" "IsViewable" "$(echo "$GEOM" | awk '/Map State:/{print $3}')"
check "it is a depth-24 InputOutput window" "24" "$(echo "$GEOM" | awk '/Depth:/{print $2}')"

say "window manager properties"
check "WM_NAME is set" '"palmy x11 selftest"' \
  "$(xprop -id "$WID" WM_NAME | sed 's/^[^=]*= //')"
check "_NET_WM_NAME is set, as UTF8_STRING" '"palmy x11 selftest"' \
  "$(xprop -id "$WID" _NET_WM_NAME | sed 's/^[^=]*= //')"
contains "_NET_WM_NAME carries the UTF8_STRING type" "UTF8_STRING" \
  "$(xprop -id "$WID" _NET_WM_NAME)"
check "WM_CLASS carries the app id as instance and class" '"palmy.selftest", "palmy.selftest"' \
  "$(xprop -id "$WID" WM_CLASS | sed 's/^[^=]*= //')"
contains "WM_PROTOCOLS advertises WM_DELETE_WINDOW" "WM_DELETE_WINDOW" \
  "$(xprop -id "$WID" WM_PROTOCOLS)"
check "_NET_WM_PID is the app's own pid" "$APP_PID" \
  "$(xprop -id "$WID" _NET_WM_PID | sed 's/.*= //')"

# --------------------------------------------------------------------------
# Pixels
# --------------------------------------------------------------------------
say "pixels: the capture against palmy's own offscreen render"
xdotool mousemove $((SCREEN_W - 40)) $((SCREEN_H - 40))   # keep hover out of it
sleep 0.4
"$BIN" render "$WORK/oracle.png" 640 400
ffmpeg -y -f x11grab -video_size 640x400 -i "$DISPLAY+0,0" -frames:v 1 -update 1 \
  "$WORK/cap.png" >/dev/null 2>&1
M=$("$PIXDIFF" "$WORK/oracle.png" "$WORK/cap.png" --json)
check "the capture is the same size as the oracle" "true" \
  "$(echo "$M" | grep -o '"size_match":[a-z]*' | cut -d: -f2)"
check "not one pixel differs from the offscreen render" "0" \
  "$(echo "$M" | grep -o '"changed_pixels":[0-9]*' | cut -d: -f2)"
check "mean absolute error is zero" "0.0000" \
  "$(echo "$M" | grep -o '"mae":[0-9.]*' | cut -d: -f2)"

pixel() { # pixel <x> <y> -> "rr gg bb"
  ffmpeg -y -i "$WORK/cap.png" -vf "crop=1:1:$1:$2" -f rawvideo -pix_fmt rgb24 - 2>/dev/null \
    | od -An -tx1 | tr -s ' ' | sed 's/^ //;s/ $//'
}
# bg-red-500, bg-emerald-500 and bg-sky-500, read straight off the screen.
check "the red block is Tailwind red-500 on screen"     "ef 44 44" "$(pixel 40 110)"
check "the emerald block is Tailwind emerald-500"       "10 b9 81" "$(pixel 150 110)"
check "the sky block is Tailwind sky-500"               "0e a5 e9" "$(pixel 260 110)"
check "the page background is Tailwind slate-950"       "02 06 17" "$(pixel 630 390)"

# --------------------------------------------------------------------------
# Resize. This runs before any input, because the oracle renders the window's
# initial state and typing into it would legitimately change the picture.
# --------------------------------------------------------------------------
say "resize (ConfigureNotify, which is this backend's apply_pending)"
xdotool windowsize "$WID" 700 500; sleep 0.8
check "the app follows the new size" "700x500" "$(st size)"
check "and the server agrees" "700" "$(xwininfo -id "$WID" | awk '/Width:/{print $2}')"

xdotool mousemove $((SCREEN_W - 40)) $((SCREEN_H - 40)); sleep 0.5
"$BIN" render "$WORK/oracle2.png" 700 500
ffmpeg -y -f x11grab -video_size 700x500 -i "$DISPLAY+0,0" -frames:v 1 -update 1 \
  "$WORK/cap2.png" >/dev/null 2>&1
M2=$("$PIXDIFF" "$WORK/oracle2.png" "$WORK/cap2.png" --json)
check "the resized window redraws at the new size, pixel for pixel" "0" \
  "$(echo "$M2" | grep -o '"changed_pixels":[0-9]*' | cut -d: -f2)"

# --------------------------------------------------------------------------
# Keyboard
# --------------------------------------------------------------------------
say "keyboard"
xdotool windowfocus "$WID"; sleep 0.3
xdotool type --delay 40 "Hello X11"; sleep 0.6
check "typed text reaches the app, with shift applied" "Hello X11" "$(st typed)"

xdotool key --delay 40 BackSpace BackSpace BackSpace; sleep 0.5
check "Backspace arrives as KEY_BACKSPACE" "Hello " "$(st typed)"

xdotool key Return; sleep 0.3
check "Return arrives as KEY_RETURN" "1" "$(st enters)"
xdotool key Escape; sleep 0.3
check "Escape arrives as KEY_ESCAPE" "1" "$(st escapes)"
xdotool key ctrl+s; sleep 0.3
check "ctrl+s is seen as a shortcut with the Ctrl modifier" "1" "$(st ctrl_s)"
check "and a modified key produces no text" "Hello " "$(st typed)"

BEFORE=$(st typed)
xdotool keydown a; sleep 1.0; xdotool keyup a; sleep 0.4
AFTER=$(st typed)
GREW=$(( ${#AFTER} - ${#BEFORE} ))
[ "$GREW" -ge 3 ] && ok "the server's auto-repeat reaches the app ($GREW characters in a second)" \
  || no "auto-repeat produced $GREW characters"
[ "$GREW" -le 40 ] && ok "and it is not doubled by palmy's own repeat timer" \
  || no "auto-repeat looks doubled ($GREW characters in a second)"
# The distinction palmy's input API rests on: key_count(.., include_repeat=false)
# must see one press no matter how long the key was held.
check "a held key is exactly one non-repeat press" "1" "$(st a_fresh)"
A_ALL=$(st a_all)
[ "$A_ALL" -gt 1 ] && ok "while key_count including repeats sees all $A_ALL of them" \
  || no "repeats were not delivered at all (a_all=$A_ALL)"

# --------------------------------------------------------------------------
# Pointer
# --------------------------------------------------------------------------
say "pointer"
xdotool mousemove 100 200; sleep 0.3
check "motion updates the pointer position in logical pixels" "100,200" "$(st mouse)"
xdotool click 1; sleep 0.3
check "a left click arrives" "1" "$(st clicks)"
xdotool click 3; sleep 0.3
check "a right click arrives, as the right button" "1" "$(st rclicks)"
check "and the right click did not count as a left one" "1" "$(st clicks)"

xdotool click 5; xdotool click 5; sleep 0.4
check "wheel button 5 scrolls down, two notches" "2" "$(st wheel_dn)"
xdotool click 4; sleep 0.4
check "wheel button 4 scrolls up, one notch" "1" "$(st wheel_up)"

# --------------------------------------------------------------------------
# Resize
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# Closing
# --------------------------------------------------------------------------
say "WM_DELETE_WINDOW"
"$BIN" close "$WID"
GONE=0
for _ in $(seq 1 50); do
  kill -0 "$APP_PID" 2>/dev/null || { GONE=1; break; }
  sleep 0.1
done
check "a WM_DELETE_WINDOW ClientMessage ends the frame loop" "1" "$GONE"
check "the app ran its shutdown path" "true" "$(st closed)"
wait "$APP_PID" 2>/dev/null
RC=$?
check "and exited successfully" "0" "$RC"
APP_PID=""

# --------------------------------------------------------------------------
# The PutImage fallback
# --------------------------------------------------------------------------
say "the PutImage fallback (no MIT-SHM)"
STATE2="$WORK/state-noshm.txt"
PALMY_X11_NO_SHM=1 PALMY_BACKEND=x11 "$BIN" run "$STATE2" > "$WORK/app2.log" 2>&1 &
APP_PID=$!
WID2=""
for _ in $(seq 1 60); do
  WID2=$(xdotool search --name "palmy x11 selftest" 2>/dev/null | head -1)
  [ -n "$WID2" ] && break
  sleep 0.1
done
[ -n "$WID2" ] && ok "the window opens with MIT-SHM switched off" || no "no window without MIT-SHM"
xdotool mousemove $((SCREEN_W - 40)) $((SCREEN_H - 40)); sleep 0.6
ffmpeg -y -f x11grab -video_size 640x400 -i "$DISPLAY+0,0" -frames:v 1 -update 1 \
  "$WORK/cap3.png" >/dev/null 2>&1
M3=$("$PIXDIFF" "$WORK/oracle.png" "$WORK/cap3.png" --json)
check "chunked PutImage delivers exactly the same pixels" "0" \
  "$(echo "$M3" | grep -o '"changed_pixels":[0-9]*' | cut -d: -f2)"
xdotool windowfocus "$WID2"; sleep 0.2
xdotool type --delay 40 "fallback"; sleep 0.6
check "input still works on the fallback path" "fallback" \
  "$(grep -m1 '^typed=' "$STATE2" | cut -d= -f2-)"
"$BIN" close "$WID2"
GONE2=0
for _ in $(seq 1 50); do
  kill -0 "$APP_PID" 2>/dev/null || { GONE2=1; break; }
  sleep 0.1
done
check "and it closes cleanly too" "1" "$GONE2"
APP_PID=""

# --------------------------------------------------------------------------
say "---"
printf '%d assertions passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
