#!/usr/bin/env bash
# Render the score: fluidsynth for the notes, ffmpeg for the sound.
#
# A General MIDI "clean electric guitar" is a clean electric guitar and
# nothing else, which is the right starting point, because the thing that
# makes instrumental surf sound like instrumental surf is not the patch -- it
# is the chain after it. Amp tremolo at five or six hertz, and a spring
# reverb tank, which is a few dense early reflections followed by a longer,
# duller tail. `tremolo` and a pair of staggered `aecho`s are literally that,
# so the stems are rendered dry and processed separately:
#
#   lead     tremolo 5.6 Hz, deep -> four early reflections -> two late ones
#   rhythm   tremolo 3.7 Hz, shallow, a single short slap, panned opposite
#   drums    a short room only; a kit through a reverb tank turns to soup
#   western  no tremolo, a long slow echo, which is the other genre entirely
#
# Mixed with `amix`, then `loudnorm` to a target that leaves headroom, then a
# fade so the last bar does not end on a cliff.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/../.work/audio}"
SF="${SOUNDFONT:-/usr/share/soundfonts/FluidR3_GM.sf2}"
RATE=44100

[ -f "$SF" ] || { echo "no soundfont at $SF" >&2; exit 1; }
mkdir -p "$OUT"

python3 "$HERE/compose.py"

# The film's length comes from the shot list, not from a number typed here, so
# the fade and the trim move when the edit grows.
LEN=$(python3 -c "
import json; s=json.load(open('$HERE/../shots.json'))
print(f\"{sum(x['beats'] for x in s['shots'])*60/s['tempo_bpm']:.3f}\")")
FADE=$(awk -v l="$LEN" 'BEGIN{printf "%.3f", l-2.0}')
echo "film is $LEN s; fading from $FADE"

for stem in lead rhythm drums western; do
	# -a file keeps fluidsynth from probing ALSA, which on this machine prints
	# a page of errors about PCM devices it was never going to use.
	fluidsynth -ni -a file -g 0.8 -r "$RATE" -F "$OUT/$stem.raw.wav" \
		"$SF" "$HERE/$stem.mid" >/dev/null 2>&1
done

LEAD='tremolo=f=5.6:d=0.72,
      aecho=0.92:0.88:29|37|47|59:0.50|0.40|0.32|0.25,
      aecho=0.85:0.72:113|167:0.30|0.20,
      highpass=f=95,lowpass=f=7600,volume=1.15'
RHYTHM='tremolo=f=3.7:d=0.35,
        aecho=0.9:0.7:71:0.22,
        highpass=f=110,lowpass=f=6400,volume=0.85'
DRUMS='aecho=0.95:0.5:23|31:0.18|0.12,
       highpass=f=45,volume=1.0'
WESTERN='aecho=0.86:0.92:181|337:0.42|0.26,
         highpass=f=80,lowpass=f=9000,volume=0.62'

ffmpeg -nostdin -v error -y \
	-i "$OUT/lead.raw.wav" -i "$OUT/rhythm.raw.wav" \
	-i "$OUT/drums.raw.wav" -i "$OUT/western.raw.wav" \
	-filter_complex "
		[0:a]${LEAD//[$'\n\t ']/}[l];
		[1:a]${RHYTHM//[$'\n\t ']/}[r];
		[2:a]${DRUMS//[$'\n\t ']/}[d];
		[3:a]${WESTERN//[$'\n\t ']/}[w];
		[l][r][d][w]amix=inputs=4:duration=longest:normalize=0[m];
		[m]loudnorm=I=-16:TP=-1.5:LRA=11,
		   afade=t=out:st=$FADE:d=2.0,
		   atrim=end=$LEN,asetpts=N/SR/TB,
		   alimiter=limit=0.95[out]" \
	-map "[out]" -ac 2 -ar "$RATE" -c:a pcm_s16le "$OUT/score.wav"

ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/score.wav" \
	| xargs printf 'score.wav  %s s\n'
