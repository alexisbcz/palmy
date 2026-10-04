#!/usr/bin/env bash
# Mux the score onto the cut and produce the two encodes the page serves.
#
# The budget is 15 MB, because this lands in a git repository and on a CDN.
# At 116.667 s that is about 1.05 Mbit/s for everything, so:
#
#   video   two-pass at the rate below; UI footage is very compressible and
#           film grain is not, which is why the grade's `noise` is kept light
#   audio   Opus at 56k, or AAC at 72k for the fallback, which for a mix with
#           no dialogue in it is plenty
#
# Two encodes, because a <video> with one source has no fallback chain:
# VP9/WebM first for the browsers that take it, H.264/MP4 behind it for
# everything else, and a poster frame for before either loads.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$HERE/.work"
OUT="$ROOT/site/public/film"

VIDEO_V="${VIDEO_V:-760k}"      # VP9
VIDEO_H="${VIDEO_H:-760k}"      # H.264, kept at the same rate so the fallback is not the bigger file
POSTER_AT="${POSTER_AT:-45.0}"

mkdir -p "$OUT" "$WORK/pass"
cd "$WORK"

GRADED="$WORK/graded.mp4"
SCORE="$WORK/audio/score.wav"
[ -f "$GRADED" ] || { echo "no cut at $GRADED -- run film/build.py" >&2; exit 1; }
[ -f "$SCORE" ]  || { echo "no score at $SCORE -- run film/score/render.sh" >&2; exit 1; }

# -- VP9 / WebM --------------------------------------------------------------
# row-mt and tiles keep a two-pass VP9 of this length down to a minute or two.
VP9_COMMON=(-c:v libvpx-vp9 -b:v "$VIDEO_V" -g 48 -row-mt 1 -tile-columns 2
            -frame-parallel 0 -auto-alt-ref 1 -lag-in-frames 25
            -pix_fmt yuv420p -threads 8)
ffmpeg -nostdin -v error -y -i "$GRADED" "${VP9_COMMON[@]}" \
	-pass 1 -passlogfile "$WORK/pass/vp9" -an -f null /dev/null
ffmpeg -nostdin -v error -y -i "$GRADED" -i "$SCORE" \
	"${VP9_COMMON[@]}" -pass 2 -passlogfile "$WORK/pass/vp9" \
	-c:a libopus -b:a 56k -ac 2 \
	-map 0:v:0 -map 1:a:0 -shortest \
	-metadata title="Palmframe" \
	"$OUT/palmframe.webm"

# -- H.264 / MP4 -------------------------------------------------------------
X264_COMMON=(-c:v libx264 -b:v "$VIDEO_H" -preset slower -profile:v high -level 4.0
             -g 48 -pix_fmt yuv420p)
ffmpeg -nostdin -v error -y -i "$GRADED" "${X264_COMMON[@]}" \
	-pass 1 -passlogfile "$WORK/pass/x264" -an -f null /dev/null
ffmpeg -nostdin -v error -y -i "$GRADED" -i "$SCORE" \
	"${X264_COMMON[@]}" -pass 2 -passlogfile "$WORK/pass/x264" \
	-c:a aac -b:a 72k -ac 2 \
	-map 0:v:0 -map 1:a:0 -shortest -movflags +faststart \
	-metadata title="Palmframe" \
	"$OUT/palmframe.mp4"

# -- poster ------------------------------------------------------------------
# The split screen, which is the project's signature image: Chromium's render,
# palmy's, and every pixel where they disagree.
ffmpeg -nostdin -v error -y -ss "$POSTER_AT" -i "$GRADED" -frames:v 1 \
	-q:v 4 "$OUT/palmframe-poster.jpg"

python3 "$HERE/tools/captions.py" "$OUT/film.vtt"

echo
for f in "$OUT"/palmframe.webm "$OUT"/palmframe.mp4 \
         "$OUT"/palmframe-poster.jpg "$OUT"/film.vtt; do
	printf '%-34s %8.2f MB\n' "${f#"$ROOT/"}" \
		"$(awk -v b="$(stat -c%s "$f")" 'BEGIN{print b/1048576}')"
done
