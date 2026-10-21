#!/usr/bin/env bash
# Drive sheets with a real pointer, on X11, and check what it did.
#
#   bash apps/sheets/pointer.sh [sheets.bin] [out-dir]
#
# Why X11. The headless Wayland seat the demos are recorded on
# (apps/tools/headless-record.sh, sway) delivers no pointer events to a
# client, so a click there proves nothing. A private Xvfb server with openbox
# as its window manager does, and xdotool moves, presses and releases a real
# core pointer on it: the events arrive through palmy's X11 backend exactly as
# a mouse's would. Nothing appears on anybody's screen.
#
# What it does, on the demo book: clicks a cell, drags a range, widens a
# column and heightens a row by their header borders, clicks the Summary tab,
# drags the chart there by its body and then by its corner handle, and saves
# the book with Ctrl+S. Then it reads the saved file back through the CLI and
# checks every one of those changes, so a run is a pass or a fail, not just a
# film. It writes <out-dir>/pointer.mp4 (the whole take) and a PNG after each
# step, and exits non-zero if a check fails.
#
# Needs Xvfb, openbox, xdotool and ffmpeg (apt install xvfb openbox xdotool
# ffmpeg). The coordinates are the window's own, in logical pixels, for the
# demo book at the default 1240x760: the same geometry `sheets --shot` lays
# out, so `sheets --shot out.png m:x,y d: u:` previews any step offscreen.
set -uo pipefail
cd "$(dirname "$0")/../.."
BIN="$(realpath "${1:-apps/sheets/sheets.bin}")"
OUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/sheets-pointer.XXXXXX")}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
[ -x "$BIN" ] || { echo "build $BIN first"; exit 1; }
for t in Xvfb openbox xdotool ffmpeg; do
	command -v "$t" >/dev/null || { echo "pointer.sh needs $t"; exit 1; }
done

# A display nobody else is using.
N=90
while [ -e "/tmp/.X11-unix/X$N" ] || [ -e "/tmp/.X$N-lock" ]; do N=$((N + 1)); done
export DISPLAY=":$N"
unset WAYLAND_DISPLAY
W=1280 H=800

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

Xvfb "$DISPLAY" -screen 0 "${W}x${H}x24" -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
openbox >"$OUT/openbox.log" 2>&1 &
PIDS+=($!)
sleep 0.5

SAVED="$OUT/pointer.sheet.json"
rm -f "$SAVED"
"$BIN" >"$OUT/sheets.log" 2>&1 &
APP=$!
PIDS+=($APP)
WIN="$(xdotool search --sync --onlyvisible --pid "$APP" 2>/dev/null | head -1)"
[ -n "$WIN" ] || { echo "the window never appeared (see $OUT/sheets.log)"; exit 1; }
xdotool windowmove "$WIN" 0 0
xdotool windowactivate --sync "$WIN" 2>/dev/null || xdotool windowfocus "$WIN"
sleep 0.8

ffmpeg -nostdin -v error -f x11grab -framerate 15 -video_size "${W}x${H}" -i "$DISPLAY" \
	-c:v libx264 -pix_fmt yuv420p -crf 23 -y "$OUT/pointer.mp4" &
REC=$!
sleep 0.8

shot_n=0
shot() { # a still of the screen, named for the step
	shot_n=$((shot_n + 1))
	ffmpeg -nostdin -v error -f x11grab -video_size "${W}x${H}" -i "$DISPLAY" -frames:v 1 -y \
		"$OUT/$(printf %02d "$shot_n")-$1.png"
}
at() { xdotool mousemove --window "$WIN" "$1" "$2"; sleep 0.15; }
click() { at "$1" "$2"; xdotool click 1; sleep 0.4; }
# drag x0 y0 x1 y1: press, move there in steps the way a hand does, release.
drag() {
	at "$1" "$2"
	xdotool mousedown 1
	sleep 0.2
	for i in 1 2 3 4 5 6; do
		at $(($1 + ($3 - $1) * i / 6)) $(($2 + ($4 - $2) * i / 6))
	done
	sleep 0.2
	xdotool mouseup 1
	sleep 0.5
}

# Sales: the grid starts at y 74 (toolbar 40 + formula bar 34), its headers
# are 22 high, the gutter 50 wide; A is 120, D 110, the rest 88; rows 22.
click 302 195            # C5
shot click-C5
drag 214 151 400 217     # B3 -> D6
shot drag-B3-D6
drag 258 85 318 85       # B's right border, +60
shot column-B-wider
drag 25 184 25 214       # row 4's bottom border, +30
shot row-4-taller
click 108 718            # the Summary tab
shot summary
# Summary: A is 130, B 110; the 7x14 chart sits on D1, x 378..994, y 96..404.
drag 600 250 700 350     # its body: two rows of grab, onto G12 -> at E5
shot chart-moved
drag 1080 490 900 600    # its corner handle (now x 1082, y 492) onto I23
shot chart-resized

# Save, through the Save As prompt Ctrl+S opens on an untitled book.
xdotool key --window "$WIN" ctrl+s
sleep 0.5
xdotool type --window "$WIN" --delay 20 "$SAVED"
sleep 0.3
xdotool key --window "$WIN" Return
sleep 0.8
shot saved

sleep 0.5
kill -INT "$REC" 2>/dev/null
wait "$REC" 2>/dev/null

# --- the checks ---------------------------------------------------------------
fails=0
check() { # check <what> <command...>
	local what="$1"
	shift
	if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; fails=$((fails + 1)); fi
}
check "the book was saved by Ctrl+S" test -s "$SAVED"
CH="$("$BIN" charts "$SAVED" --sheet Summary --json 2>/dev/null)"
check "the chart was dragged onto E5" grep -q '"at": "E5"' <<<"$CH"
check "and its handle dragged out to 5x19" grep -Eq '"w": 5' <<<"$CH"
check "  (19 rows)" grep -Eq '"h": 19' <<<"$CH"
# Column B (index 1) on Sales: 88 + 60; row 4 (index 3): 22 + 30.
check "column B was widened to 148 by its border" python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
s=[x for x in d["sheets"] if x["name"]=="Sales"][0]
w={c["i"]:c["v"] for c in s.get("cols") or []}
h={r["i"]:r["v"] for r in s.get("rows") or []}
assert abs(w[1]-148)<1.5, w
assert abs(h[3]-52)<1.5, h
' "$SAVED"
check "the tab was clicked: Summary is the active sheet" python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["sheets"][d["active"]]["name"]=="Summary", d["active"]
' "$SAVED"

echo "frames and pointer.mp4 in $OUT"
[ "$fails" -eq 0 ] && echo "pointer: all checks passed" || echo "pointer: $fails check(s) failed"
exit $((fails > 0))
