#!/usr/bin/env bash
# measure.sh OUTDIR [aec|rate|loss|e2ee|rooms|all]
#
# The live measurements behind PROTOCOL.md's echo cancellation, adaptive
# bitrate, direct-call encryption and 3-/4-party sections. Every call here is
# two (or more) real `call` processes on loopback, headless, with synthetic
# sources only — ffmpeg lavfi noise and tones, a synthetic camera — playing
# into a paced null sink. Nothing opens a microphone, a camera or a speaker.
#
# Binaries: $BIN must hold call.bin (and palm-sfu.bin for `rooms`), built
# with -o:speed; the numbers are real time, so an unoptimised build or a
# loaded machine shows up in them.
set -uo pipefail
OUT=${1:?usage: measure.sh OUTDIR [aec|rate|loss|e2ee|rooms|all]}
WHAT=${2:-all}
BIN=${BIN:?set BIN to the directory holding call.bin}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
FAR_VOICE="anoisesrc=color=pink:amplitude=0.25:seed=3:r=48000,volume='0.3+0.7*gt(sin(2*PI*0.5*t),0)':eval=frame,arealtime"
SILENT="anullsrc=r=48000:cl=mono,arealtime"
# Alice's own voice for the double-talk run: a tone, 2 s of every 8 (5-7 s),
# so both talk a quarter of the time and Bob alone the rest.
NEAR_TURNS="aevalsrc=0.4*sin(2*PI*330*t)*between(mod(t\\,8)\\,5\\,7):s=48000:c=mono,arealtime"

# call2 NAME SECS "ALICE FLAGS" "BOB FLAGS": one two-party call, Alice dials.
call2() {
	local name=$1 secs=$2 af=$3 bf=$4 d="$OUT/$1"
	mkdir -p "$d"
	# shellcheck disable=SC2086
	"$BIN/call.bin" --headless --null-audio --bind 47871 --peer 47872 --name Bob --autoanswer \
		--quit-after $((secs + 1)) --pattern testsrc $bf > "$d/bob.log" 2>&1 &
	local bp=$!
	sleep 0.3
	# shellcheck disable=SC2086
	"$BIN/call.bin" --headless --null-audio --bind 47872 --peer 47871 --name Alice --autocall \
		--quit-after "$secs" $af > "$d/alice.log" 2>&1
	wait $bp
}

pick() { grep -E "$2" "$1" | sed 's/^ *//' ; }

if [[ $WHAT == all || $WHAT == aec ]]; then
	echo "== echo cancellation, live: Bob talks (pink noise), Alice's synthetic room echoes him"
	call2 aec-single 20 "--aec --echo-path 40:-6 --mic-source $SILENT" "--mic-source $FAR_VOICE"
	call2 aec-double 20 "--aec --echo-path 40:-6 --mic-source $NEAR_TURNS" "--mic-source $FAR_VOICE"
	call2 aec-off 20 "--echo-path 40:-6 --mic-source $SILENT" "--mic-source $FAR_VOICE"
	for r in aec-single aec-double aec-off; do
		echo "-- $r"; pick "$OUT/$r/alice.log" "echo canceller|live echo removal|audio frames"
	done
fi

if [[ $WHAT == all || $WHAT == rate ]]; then
	echo "== adaptive bitrate: Alice sends through an emulated 200 kbit/s bottleneck"
	call2 rate-adaptive 40 "--link-kbps 200" ""
	call2 rate-fixed 40 "--link-kbps 200 --fixed-bitrate" ""
	for r in rate-adaptive rate-fixed; do
		echo "-- $r (Alice sends)"; pick "$OUT/$r/alice.log" "bitrate|rate changes|emulated link"
		echo "-- $r (Bob receives)"; pick "$OUT/$r/bob.log" "^ *video  |video latency|loss path|bitrate"
	done
fi

if [[ $WHAT == all || $WHAT == loss ]]; then
	echo "== adaptive bitrate under injected loss: 15 % of Alice's video for 15 s, then none"
	call2 rate-loss 35 "--loss 150 --loss-until 15" ""
	pick "$OUT/rate-loss/alice.log" "bitrate|rate changes|deliberate loss"
fi

if [[ $WHAT == all || $WHAT == e2ee ]]; then
	echo "== direct-call encryption, live"
	call2 e2ee 10 "" ""
	pick "$OUT/e2ee/alice.log" "encryption|e2ee frames|video   "
	pick "$OUT/e2ee/bob.log" "encryption|e2ee frames|video   "
fi

if [[ $WHAT == all || $WHAT == rooms ]]; then
	for n in 3 4; do
		echo "== $n-party call through palm-sfu"
		bash "$HERE/rooms.sh" "$OUT/room$n" "$n" 20
	done
fi
