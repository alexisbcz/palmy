#!/usr/bin/env bash
# Screen sharing, tested where it can work: a private headless sway (a
# wlroots compositor, so wlr-screencopy is there for grim), with a terminal on
# it. Bob shares that screen into a call through palm-sfu; Alice's call
# window is rendered offscreen in speaker view, showing what Bob shares.
#
#   screenshare.sh OUTDIR
#
# Nothing here touches the user's session: sway is started with no inherited
# WAYLAND_DISPLAY, on its own socket, and grim only ever talks to it.
set -euo pipefail
OUT=${1:?usage: screenshare.sh OUTDIR}
BIN=${BIN:-/tmp/claude-1000/-home-alex-Work-palmy/fa1b6400-3f10-4431-816d-e37e9d672367/scratchpad/rtc/bin}
PORT=${PORT:-47932}
mkdir -p "$OUT"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TMP=$(mktemp -d "$OUT/sway-XXXXXX")
cat > "$TMP/sway.conf" <<CONF
output HEADLESS-1 resolution 1280x720
default_border none
CONF
echo "exec printf '%s' \"\$WAYLAND_DISPLAY\" > $TMP/display" >> "$TMP/sway.conf"
env -u WAYLAND_DISPLAY -u DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	sway -c "$TMP/sway.conf" > "$TMP/sway.log" 2>&1 &
SWAY=$!
trap 'kill $SWAY 2>/dev/null || true' EXIT
for _ in $(seq 1 80); do
	sleep 0.1
	[ -s "$TMP/display" ] && break
done
WD=$(cat "$TMP/display")
echo "private compositor: $WD"

# Something worth sharing: a terminal showing the protocol notes.
WAYLAND_DISPLAY=$WD foot --font=monospace:size=13 -e sh -c \
	"printf '\033[1mPCP2 through palm-sfu\033[0m  (shared from a private sway)\n\n'; sed -n '1,40p' $(dirname "$0")/../pcp/header.odin; sleep 30" \
	> "$TMP/foot.log" 2>&1 &
sleep 1.5
WAYLAND_DISPLAY=$WD grim "$OUT/screen-as-captured.png"

head -c 32 /dev/urandom | base64 > "$OUT/secret"
CALL=$(cat /proc/sys/kernel/random/uuid)
"$BIN/palm-sfu.bin" --secret-file "$OUT/secret" --port "$PORT" --quit-after 14 > "$OUT/sfu.log" 2>&1 &
SFU=$!
sleep 0.3
mint() {
	"$BIN/palm-sfu.bin" --mint-token --secret-file "$OUT/secret" --call "$CALL" --ch design \
		--id "$1" --handle "$2" --name "$3" --color "$4" --ttl 120
}
TA=$(mint 11111111-aaaa-4aaa-8aaa-111111111111 alice.northwind "Alice Martin" indigo)
TB=$(mint 22222222-bbbb-4bbb-8bbb-222222222222 bob.northwind "Bob Chen" emerald)
EPOCH=$(python3 -c 'import time; print(f"{time.time() + 1:.3f}")')
WAYLAND_DISPLAY=$WD "$BIN/call.bin" --sfu "127.0.0.1:$PORT" --null-audio --headless --quit-after 12 \
	--join-token "$TB" --share-screen --allow-screen --talk 0-30 --epoch "$EPOCH" > "$OUT/bob.log" 2>&1 &
B=$!
"$BIN/call.bin" --sfu "127.0.0.1:$PORT" --null-audio --join-token "$TA" --speaker-view --talk 0-0.1 --epoch "$EPOCH" \
	--shot "$OUT/share" --shot-at 8 --shot-size 1280x800 --quit-after 9 > "$OUT/alice.log" 2>&1
wait $B || true
wait $SFU || true
grep -E "video .* decoded|L0" "$OUT/alice.log" | head -3
ls -la "$OUT"/*.png
