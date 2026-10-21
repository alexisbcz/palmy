#!/usr/bin/env bash
# Drag and drop between two palmy windows, on a private headless sway.
#
#   dnd-check.sh [shots-dir]
#
# Builds apps/tools/dnd-check, opens a source and a target window side by side
# (sway tiles them 512 px each on a 1024x768 output), presses on the source's
# chip with a resident virtual pointer (wl-pointer.py), moves across into the
# target and releases. Passes when the target printed the dropped text and the
# source heard that the drop finished. With a directory, it also saves a
# screenshot mid-drag and one after the drop.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"
SHOTS="${1:-}"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d /tmp/palmy-dnd-XXXXXX)"
SWAY=""; PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  [ -n "$SWAY" ] && { kill "$SWAY" 2>/dev/null; wait "$SWAY" 2>/dev/null; }
  rm -rf "$TMP"
}
trap cleanup EXIT

"$ODIN" build "$HERE/dnd-check" -collection:palmy="$R/palmy" -out:"$TMP/dnd-check" || exit 1

printf 'output HEADLESS-1 resolution 1024x768\ndefault_border none\nexec printf %%s "$WAYLAND_DISPLAY" > %s/display\n' "$TMP" > "$TMP/sway.conf"
env -u WAYLAND_DISPLAY -u DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
  sway -c "$TMP/sway.conf" > "$TMP/sway.log" 2>&1 &
SWAY=$!
for _ in $(seq 1 80); do sleep 0.1; [ -s "$TMP/display" ] && break; done
export WAYLAND_DISPLAY="$(cat "$TMP/display")"
export SWAYSOCK="$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$SWAY.sock"

mkfifo "$TMP/pin" "$TMP/pout"
python3 "$HERE/wl-pointer.py" --width 1024 --height 768 < "$TMP/pin" > "$TMP/pout" 2> "$TMP/ptr.log" &
PIDS+=($!)
exec 3> "$TMP/pin" 4< "$TMP/pout"
read -r -t 5 _ <&4 || { echo "FAIL: the virtual pointer did not start"; cat "$TMP/ptr.log"; exit 1; }
ptr() { echo "$*" >&3; read -r -t 5 _ <&4; }

"$TMP/dnd-check" source > "$TMP/source.log" 2>&1 & PIDS+=($!)
sleep 0.8
"$TMP/dnd-check" target > "$TMP/target.log" 2>&1 & PIDS+=($!)
sleep 1.2

ptr move 100 70; sleep 0.2
ptr down; sleep 0.2
for x in 120 160 220 300 400 500 560 620 700; do ptr move "$x" 120; sleep 0.08; done
sleep 0.3
[ -n "$SHOTS" ] && grim -c "$SHOTS/dnd-during.png"
ptr up; sleep 0.8
[ -n "$SHOTS" ] && grim -c "$SHOTS/dnd-after.png"

echo "--- source"; cat "$TMP/source.log"
echo "--- target"; cat "$TMP/target.log"
if grep -q '^DROPPED "hello from the source window"' "$TMP/target.log" &&
   grep -q '^DRAG_RESULT Dropped' "$TMP/source.log"; then
  echo "PASS: the drag completed between two palmy windows"
else
  echo "FAIL"; exit 1
fi
