#!/usr/bin/env bash
# Make the three recordings the film cannot get from committed footage.
#
#   1,2. the window manager, twice, with four applications running inside it
#      each time: calc/maps/sheets/calendar, then editor/reader/emoji/archive.
#      The committed apps/wm/demo.mp4 opens a terminal ten seconds in whose
#      prompt reads `alex@omarchy`, so the film could use only its first seven
#      seconds. These takes never open one: sandbox.sh binds /bin/true over
#      the terminal's path.
#   3. the word processor, on a document in Arabic, Devanagari and English.
#      That is chapter four's evidence, and re-recording it on every build is
#      what keeps the chapter honest: if shaping regresses, the frame the film
#      holds regresses with it.
#
# All three run inside film/tools/capture/sandbox.sh. None appears on
# anybody's screen: the recorder starts its own headless compositor.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/film/.work/capture"
REC="$ROOT/apps/tools/headless-record.sh"
mkdir -p "$OUT"

sb() { bash "$HERE/sandbox.sh" "$@"; }

echo "-- the window manager: calc, maps, sheets, calendar"
sb bash "$REC" "$ROOT/apps/wm/wm.bin" "$OUT/wm.mp4" "$HERE/wm.txt" 1920 1080

echo "-- the window manager again: editor, reader, emoji, archive"
SLOT_F1="$ROOT/apps/editor/editor.bin" \
SLOT_F2="$ROOT/apps/reader/reader.bin" \
SLOT_F3="$ROOT/apps/emoji/emoji.bin" \
SLOT_F5="$ROOT/apps/archive/archive.bin" \
	sb bash "$REC" "$ROOT/apps/wm/wm.bin" "$OUT/wm2.mp4" "$HERE/wm.txt" 1920 1080

echo "-- the word processor, on a document in three scripts"
cat > "$OUT/run-docs.sh" <<SH
#!/usr/bin/env bash
exec "$ROOT/apps/docs/docs.bin" "$HERE/rtl.md"
SH
chmod +x "$OUT/run-docs.sh"
sb bash "$REC" "$OUT/run-docs.sh" "$OUT/rtl.mp4" "$HERE/docs-rtl.txt" 1360 860

ls -la "$OUT"/*.mp4
