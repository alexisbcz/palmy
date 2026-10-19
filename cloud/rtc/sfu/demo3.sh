#!/usr/bin/env bash
# A three-person call through palm-sfu, on loopback, measured.
#
#   demo3.sh OUTDIR [SECONDS] [CONSTRAINED_KBPS]
#
# Everything is synthetic and headless: each participant is a real `call`
# process with a synthetic camera (ffmpeg lavfi) and a synthetic microphone
# that "talks" on a schedule — Alice 0-4 s, Bob 4-8 s, Carol 8-12 s, repeating
# every 12 s on one shared clock — and plays what it hears into a paced null
# sink, so nothing is opened and nothing is heard on this machine.
#
# With CONSTRAINED_KBPS, Carol's downlink is emulated at that rate (a token
# bucket on what she receives), and the SFU has to notice from her loss
# reports and move her to the low layer, or to audio only.
#
# Binaries: $BIN (default: the scratch build dir) must hold palm-sfu.bin and
# call.bin. Join tokens are minted here with the shared secret, exactly as the
# chat gateway mints them on `call_join`.
set -euo pipefail

OUT=${1:?usage: demo3.sh OUTDIR [SECONDS] [CONSTRAINED_KBPS]}
SECS=${2:-20}
CAP=${3:-0}
BIN=${BIN:-/tmp/claude-1000/-home-alex-Work-palmy/fa1b6400-3f10-4431-816d-e37e9d672367/scratchpad/rtc/bin}
PORT=${PORT:-47930}
mkdir -p "$OUT"
head -c 32 /dev/urandom | base64 > "$OUT/secret"
CALL=$(cat /proc/sys/kernel/random/uuid)

"$BIN/palm-sfu.bin" --secret-file "$OUT/secret" --port "$PORT" --stats \
	--json-out "$OUT/sfu.json" --quit-after $((SECS + 4)) > "$OUT/sfu.log" 2>&1 &
SFU=$!
sleep 0.3

mint() {
	"$BIN/palm-sfu.bin" --mint-token --secret-file "$OUT/secret" --call "$CALL" --ch demo-channel \
		--id "$1" --handle "$2" --name "$3" --color "$4" --ttl 120
}
TA=$(mint 11111111-aaaa-4aaa-8aaa-111111111111 alice "Alice Martin" indigo)
TB=$(mint 22222222-bbbb-4bbb-8bbb-222222222222 bob "Bob Chen" emerald)
TC=$(mint 33333333-cccc-4ccc-8ccc-333333333333 carol "Carol Diaz" amber)

EPOCH=$(python3 -c 'import time; print(f"{time.time() + 1.5:.3f}")')
echo "$EPOCH" > "$OUT/epoch"
common=(--sfu "127.0.0.1:$PORT" --headless --null-audio --quit-after "$SECS" --talk-period 12 --epoch "$EPOCH")

"$BIN/call.bin" "${common[@]}" --join-token "$TA" --talk 0-4 --tone 440 --pattern testsrc2 \
	--json-out "$OUT/alice.json" > "$OUT/alice.log" 2>&1 &
A=$!
"$BIN/call.bin" "${common[@]}" --join-token "$TB" --talk 4-8 --tone 554 --pattern testsrc \
	--json-out "$OUT/bob.json" > "$OUT/bob.log" 2>&1 &
B=$!
carol=(--join-token "$TC" --talk 8-12 --tone 659 --pattern life --json-out "$OUT/carol.json")
if [ "$CAP" != "0" ]; then
	carol+=(--recv-cap "$CAP")
fi
"$BIN/call.bin" "${common[@]}" "${carol[@]}" > "$OUT/carol.log" 2>&1 &
C=$!

wait $A $B $C
wait $SFU || true
python3 "$(dirname "$0")/report.py" "$OUT"
