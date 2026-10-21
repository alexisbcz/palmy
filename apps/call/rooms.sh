#!/usr/bin/env bash
# rooms.sh OUTDIR N [SECONDS]: an N-party call (3..6) through palm-sfu on
# loopback, end-to-end encrypted, headless, synthetic sources only.
#
# Each participant is a real `call` process with a synthetic camera (ffmpeg
# lavfi) and a synthetic talker that takes a 4 s turn in an N*4 s cycle on a
# shared clock, playing what it hears into a paced null sink. The summary is
# per receiver <- sender: audio frames, video frames, latency, and anything
# that failed to decrypt; and whether every participant shows one safety code.
#
# $BIN must hold call.bin and palm-sfu.bin. This is cloud/rtc/sfu/demo3.sh
# generalised from three people to N; that script is left as it is.
set -euo pipefail
OUT=${1:?usage: rooms.sh OUTDIR N [SECONDS]}
N=${2:?how many people}
SECS=${3:-20}
BIN=${BIN:?set BIN to the directory holding call.bin and palm-sfu.bin}
PORT=${PORT:-47940}
mkdir -p "$OUT"
head -c 32 /dev/urandom | base64 > "$OUT/secret"
CALL=$(cat /proc/sys/kernel/random/uuid)
NAMES=(alice bob carol dave erin frank)
TONES=(440 554 659 784 880 988)
PATTERNS=(testsrc2 testsrc smptebars rgbtestsrc mandelbrot life)
COLORS=(indigo emerald amber rose sky violet)

"$BIN/palm-sfu.bin" --secret-file "$OUT/secret" --port "$PORT" --stats \
	--json-out "$OUT/sfu.json" --quit-after $((SECS + 4)) > "$OUT/sfu.log" 2>&1 &
SFU=$!
sleep 0.3

EPOCH=$(python3 -c 'import time; print(f"{time.time() + 1.5:.3f}")')
echo "$EPOCH" > "$OUT/epoch"
PERIOD=$((N * 4))
pids=()
for ((i = 0; i < N; i++)); do
	who=${NAMES[$i]}
	id=$(printf '%08d-0000-4000-8000-%012d' $((i + 1)) $((i + 1)))
	tok=$("$BIN/palm-sfu.bin" --mint-token --secret-file "$OUT/secret" --call "$CALL" --ch demo-channel \
		--id "$id" --handle "$who" --name "${who^}" --color "${COLORS[$i]}" --ttl 120)
	"$BIN/call.bin" --sfu "127.0.0.1:$PORT" --join-token "$tok" --headless --null-audio \
		--quit-after "$SECS" --talk-period "$PERIOD" --epoch "$EPOCH" \
		--talk "$((i * 4))-$((i * 4 + 4))" --tone "${TONES[$i]}" --pattern "${PATTERNS[$i]}" \
		--json-out "$OUT/$who.json" > "$OUT/$who.log" 2>&1 &
	pids+=($!)
done
wait "${pids[@]}"
wait $SFU || true

python3 - "$OUT" "$N" <<'EOF'
import json, os, sys
out, n = sys.argv[1], int(sys.argv[2])
names = ["alice", "bob", "carol", "dave", "erin", "frank"][:n]
people = [json.load(open(os.path.join(out, x + ".json"))) for x in names]
print(f"{'receiver':<8} {'sender':<7} {'audio rx':>8} {'wire ms':>8} {'played ms':>9} {'video':>6} {'video ms':>8} {'lost':>5} {'no key':>6} {'bad auth':>8}")
streams = 0
bad = 0
for me in people:
    for f in me["from"]:
        streams += 1
        bad += f["bad_auth"]
        print(f"{me['handle']:<8} {f['handle']:<7} {f['audio_rx']:>8} {f['wire_ms']:>8.2f} {f['played_ms']:>9.2f} "
              f"{f['video_frames']:>6} {f['video_ms']:>8.2f} {f['lost']:>5} {f['no_key']:>6} {f['bad_auth']:>8}")
codes = {me["safety"] for me in people}
print(f"\n{n} participants, {streams} receiver<-sender streams (expected {n*(n-1)}), {bad} frames failed authentication")
print("safety code: " + (f"identical at all {n}: {codes.pop()}" if len(codes) == 1 else f"DIFFERS: {codes}"))
print("encrypted: " + ", ".join(f"{me['handle']}={me['e2ee']}" for me in people))
sfu = json.load(open(os.path.join(out, "sfu.json")))
print(f"sfu: {sfu['rx_pkts']} datagrams in, {sfu['tx_pkts']} out, {sfu['rejected']} rejected")
EOF
