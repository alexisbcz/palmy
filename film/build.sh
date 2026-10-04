#!/usr/bin/env bash
# Rebuild the whole film from the repository.
#
#   bash film/build.sh            everything
#   bash film/build.sh score      just the music
#   bash film/build.sh stills     just chapter four's rendered frames
#   bash film/build.sh cut        just the edit
#   bash film/build.sh encode     just the two encodes and the poster
#   bash film/build.sh scan       just the safety gate
#
# Nothing here records anything. The edit is cut from demo takes that already
# existed (see film/SOURCES.md) and from the parity suite's comparison reel;
# the only thing made for the film is the score, which is written as MIDI by
# film/score/compose.py and synthesised with fluidsynth.
#
# Needs: ffmpeg, fluidsynth with /usr/share/soundfonts/FluidR3_GM.sf2,
# python3, and tesseract for the scan.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STEP="${1:-all}"

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

if [ "$STEP" = all ] || [ "$STEP" = scan ]; then
	say "scanning source footage for the user's identity"
	# Advisory on its own: the clips the shot list draws from were also
	# reviewed by eye, and three of the rejections in SOURCES.md passed this
	# grep. It gates the build only as a last line.
	bash "$HERE/tools/scan-identity.sh" 6 \
		"$ROOT"/apps/wm/demo.mp4@0-8 \
		"$ROOT"/apps/{docs,reader,sheets,torrent,vault,maps,calc,notes,editor,emoji,calendar,audio,ai}/demo.mp4 \
		"$ROOT"/parity/out/video/comparison.mp4 \
		"$ROOT"/parity/out/video/showcase.mp4
fi

if [ "$STEP" = all ] || [ "$STEP" = score ]; then
	say "composing and rendering the score"
	bash "$HERE/score/render.sh"
fi

if [ "$STEP" = all ] || [ "$STEP" = cut ] || [ "$STEP" = stills ]; then
	say "rendering chapter four's stills through palmy"
	# Chapter four is about what the text renderer does and does not do with
	# bidirectional text, so its frames are drawn by that renderer. This also
	# re-checks the claim every time the film is rebuilt: if shaping regresses,
	# the frame the film holds regresses with it.
	bash "$HERE/tools/rtlcheck/run.sh"
fi

if [ "$STEP" = all ] || [ "$STEP" = cut ]; then
	say "cutting the film"
	python3 "$HERE/build.py"
fi

if [ "$STEP" = all ] || [ "$STEP" = encode ]; then
	say "encoding"
	bash "$HERE/encode.sh"
fi

say "done"
