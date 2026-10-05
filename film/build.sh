#!/usr/bin/env bash
# Rebuild the whole film from the repository.
#
#   bash film/build.sh            everything
#   bash film/build.sh score      just the music
#   bash film/build.sh capture    just the two recordings
#   bash film/build.sh cut        just the edit
#   bash film/build.sh encode     just the two encodes and the poster
#   bash film/build.sh scan       just the safety gate
#
# Everything on screen is the window manager or an application. Most of it is
# cut from demo takes that already existed (see film/SOURCES.md); three takes
# are recorded here, because the committed footage could not serve them. The
# score is written as MIDI by film/score/compose.py and synthesised with
# fluidsynth.
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
	# This scans the windows the shot list actually takes, derived from it,
	# so a shot that moves is re-scanned where it moved to. Scanning whole
	# clips asks the wrong question: `apps/docs/demo.mp4` has the real home
	# directory on screen around fifty seconds in, and the film takes four
	# seconds at forty-four and two at fifty-five.
	#
	# It is a last line and not the first: four of the rejections in
	# SOURCES.md passed this grep and were caught by looking at a contact
	# sheet. A grep cannot see a photograph.
	mapfile -t WINDOWS < <(python3 "$HERE/tools/scan-used.py")
	bash "$HERE/tools/scan-identity.sh" 16 "${WINDOWS[@]}"
fi

if [ "$STEP" = all ] || [ "$STEP" = score ]; then
	say "composing and rendering the score"
	bash "$HERE/score/render.sh"
fi

if [ "$STEP" = all ] || [ "$STEP" = capture ]; then
	say "recording the window manager and chapter four's document"
	# Both takes are made here rather than committed, for two reasons. The
	# window manager's own demo recording leaks a shell prompt ten seconds in,
	# so the film needs a take made inside the sandbox; and chapter four's
	# claim about right-to-left text should be re-checked on every build, so
	# that a regression in shaping shows up in the frame the film holds.
	bash "$HERE/tools/capture/run.sh"
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
