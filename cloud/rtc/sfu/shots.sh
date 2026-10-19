#!/usr/bin/env bash
# Screenshots of the multi-party call screen, rendered offscreen (no
# compositor): palm-sfu, two headless participants, and a third whose window
# is drawn into PNGs at given times, with keys pressed between them.
#
#   shots.sh OUTDIR [light]
#
# Shots: 1 grid, 2 speaker view (L), 3 speaker view with the people panel (P).
set -euo pipefail
OUT=${1:?usage: shots.sh OUTDIR [light]}
THEME=${2:-dark}
BIN=${BIN:-/tmp/claude-1000/-home-alex-Work-palmy/fa1b6400-3f10-4431-816d-e37e9d672367/scratchpad/rtc/bin}
PORT=${PORT:-47931}
mkdir -p "$OUT"
head -c 32 /dev/urandom | base64 > "$OUT/secret"
CALL=$(cat /proc/sys/kernel/random/uuid)
"$BIN/palm-sfu.bin" --secret-file "$OUT/secret" --port "$PORT" --quit-after 16 > "$OUT/sfu.log" 2>&1 &
SFU=$!
sleep 0.3
mint() {
	"$BIN/palm-sfu.bin" --mint-token --secret-file "$OUT/secret" --call "$CALL" --ch design \
		--id "$1" --handle "$2" --name "$3" --color "$4" --ttl 120
}
TA=$(mint 11111111-aaaa-4aaa-8aaa-111111111111 alice.northwind "Alice Martin" indigo)
TB=$(mint 22222222-bbbb-4bbb-8bbb-222222222222 bob.northwind "Bob Chen" emerald)
TC=$(mint 33333333-cccc-4ccc-8ccc-333333333333 carol "Carol Diaz" amber)
EPOCH=$(python3 -c 'import time; print(f"{time.time() + 1:.3f}")')
common=(--sfu "127.0.0.1:$PORT" --null-audio --talk-period 9 --epoch "$EPOCH")
"$BIN/call.bin" "${common[@]}" --headless --quit-after 14 --join-token "$TB" --talk 3-9 --tone 554 --pattern testsrc > "$OUT/bob.log" 2>&1 &
B=$!
"$BIN/call.bin" "${common[@]}" --headless --quit-after 14 --join-token "$TC" --talk 0-0.1 --tone 659 --camera-off --muted > "$OUT/carol.log" 2>&1 &
C=$!
light=()
if [ "$THEME" = "light" ]; then
	light=(--light)
fi
"$BIN/call.bin" "${common[@]}" "${light[@]}" --join-token "$TA" --talk 0-2.5 --tone 440 --pattern testsrc2 \
	--shot "$OUT/call-$THEME" --shot-at "4,7.5:l,10.5:p" --shot-size 1280x800 --quit-after 11.5 > "$OUT/alice.log" 2>&1
wait $B $C || true
wait $SFU || true
ls -la "$OUT"/*.png
