#!/usr/bin/env bash
# Record videoedit *with its sound*: the picture through the private headless
# compositor (apps/tools/headless-record.sh), the sound from a private PipeWire
# null sink's monitor, muxed into one file.
#
#   record-audio.sh <out.mp4> [steps]      (default steps: demo-audio.txt)
#
# The sink is created here and removed afterwards, and the app is pointed at it
# with PIPEWIRE_NODE, so nothing is played into the room and nothing but this
# app's own output is recorded: a null sink's monitor is the app's mix, never a
# microphone.
#
# Alignment: wf-recorder's start is not reported, so the sound is placed by its
# first onset, which is the take's first `space` (playback start). PLAY_AT is
# when that lands in the picture: headless-record's 1.0 s warm-up, the waits
# before `space` in demo-audio.txt (4.4 s), and ~0.5 s for the key and the
# mixer's start. It is good to about a tenth of a second; the sound itself —
# where it is continuous and where it is not — does not depend on it.
set -euo pipefail
OUT="${1:?usage: record-audio.sh <out.mp4> [steps]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STEPS="${2:-$HERE/demo-audio.txt}"
PLAY_AT="${PLAY_AT:-5.9}"
TMP="$(mktemp -d /tmp/videoedit-rec-XXXXXX)"
SINK="videoedit-rec-$$"
cleanup() { [ -n "${PR:-}" ] && kill -INT "$PR" 2>/dev/null; [ -n "${PC:-}" ] && kill "$PC" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# The sink drives itself (node.driver), so it has a clock with no sound card.
# pw-cli in monitor mode stays connected after its script ends, and the node
# lives exactly as long as that connection.
pw-cli -m > "$TMP/pw-cli.log" 2>&1 <<PW &
create-node adapter { factory.name=support.null-audio-sink node.name=$SINK media.class=Audio/Sink audio.position=[FL FR] audio.rate=48000 node.driver=true priority.driver=10 object.linger=false }
PW
PC=$!
# (Listed to a file and then searched: `pw-cli | grep -q` under pipefail fails
# whenever grep stops reading first.)
have_sink() { pw-cli ls Node > "$TMP/nodes" 2>/dev/null; grep -q "\"$SINK\"" "$TMP/nodes"; }
for _ in $(seq 1 50); do have_sink && break; sleep 0.1; done
have_sink || { echo "could not create the null sink $SINK"; exit 1; }
export PIPEWIRE_NODE="$SINK"
# The bundled clips (make-media.sh), wherever this is run from.
export PALMY_VIDEOEDIT_MEDIA="${PALMY_VIDEOEDIT_MEDIA:-$HERE/media}"
[ -f "$PALMY_VIDEOEDIT_MEDIA/bars.mp4" ] || "$HERE/make-media.sh" "$PALMY_VIDEOEDIT_MEDIA" >/dev/null

pw-record --target "$SINK" -P "{ stream.capture.sink=true }" --rate 48000 --channels 2 "$TMP/take.wav" & PR=$!
bash "$HERE/../tools/headless-record.sh" "$HERE/demo-run.sh" "$TMP/take.mp4" "$STEPS" 1500 900
kill -INT "$PR"; wait "$PR" 2>/dev/null || true; PR=""

ONSET=$(python3 - "$TMP/take.wav" <<'PY'
import sys, wave, array, math
w = wave.open(sys.argv[1]); sr = w.getframerate(); ch = w.getnchannels()
a = array.array("h"); a.frombytes(w.readframes(w.getnframes()))
win = sr // 100
for k in range(0, len(a) // ch - win, win):
    s = a[k * ch:(k + win) * ch:ch]
    if math.sqrt(sum(x * x for x in s) / len(s)) > 300:
        print(k / sr); break
else:
    print(0)
PY
)
SHIFT=$(python3 -c "print(max(0.0, $ONSET - $PLAY_AT))")
echo "sound starts at ${ONSET}s of the recording; shifted by ${SHIFT}s to land at ${PLAY_AT}s of the picture"
ffmpeg -v error -y -i "$TMP/take.mp4" -ss "$SHIFT" -i "$TMP/take.wav" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k -shortest "$OUT"
echo "wrote $OUT"
