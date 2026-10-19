#!/usr/bin/env bash
# Screenshot a real window (not an offscreen render) on a private headless
# compositor, after a delay — the still-picture companion of
# apps/tools/headless-record.sh, using the same isolation.
#
#   cloud/collab/demo/snap-window.sh <launcher> <out.png> <seconds> [w] [h]
set -uo pipefail
LAUNCH="${1:?launcher}"
OUT="${2:?out.png}"
WAIT="${3:?seconds}"
W="${4:-1440}"
H="${5:-900}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/palm-snap-XXXXXX")"
cat >"$TMP/sway.conf" <<CONF
output HEADLESS-1 resolution ${W}x${H}
default_border none
CONF
echo "exec printf '%s' \"\$WAYLAND_DISPLAY\" > $TMP/display" >>"$TMP/sway.conf"
env -u WAYLAND_DISPLAY -u DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	sway -c "$TMP/sway.conf" >"$TMP/sway.log" 2>&1 &
SWAY=$!
for _ in $(seq 1 80); do
	sleep 0.1
	[ -s "$TMP/display" ] && break
done
export WAYLAND_DISPLAY="$(cat "$TMP/display")"
"$LAUNCH" >"$TMP/app.log" 2>&1 &
APP=$!
sleep "$WAIT"
grim "$OUT"
kill "$APP" 2>/dev/null
pkill -P "$APP" 2>/dev/null
kill "$SWAY" 2>/dev/null
wait "$SWAY" 2>/dev/null
rm -rf "$TMP"
[ -s "$OUT" ] && echo "wrote $OUT"
