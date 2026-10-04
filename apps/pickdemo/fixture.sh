#!/usr/bin/env bash
# Build the tree the recorded demo browses.
#
# The picker reads the user's real home directory, and that is the point of it
# — but a demo video should show a known tree rather than whatever happens to
# be on this machine, and it should not put somebody's private file names on
# film. So the recording points the dialogs at this fixture instead.
set -euo pipefail
ROOT="${1:-/tmp/palmy-pickdemo}"
rm -rf "$ROOT"
mkdir -p "$ROOT"

f() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/zero | tr '\0' 'x' > "$1"; }

mkdir -p "$ROOT/Documents" "$ROOT/Downloads" "$ROOT/Music" "$ROOT/Projects"

# Photographs — the folder the demo descends into, and the one the Images
# filter is shown against.
f "$ROOT/Photographs/sunset-over-the-harbour.png"  412000
f "$ROOT/Photographs/harbour-at-dawn.jpg"          2380000
f "$ROOT/Photographs/lighthouse.png"               861000
f "$ROOT/Photographs/contact-sheet.pdf"            54000
f "$ROOT/Photographs/notes-from-the-shoot.txt"     1800
f "$ROOT/Photographs/résumé-du-voyage.txt"         940
f "$ROOT/Photographs/日本-2026.jpg"                 1740000
f "$ROOT/Photographs/صور-العائلة.png"               320000
f "$ROOT/Photographs/a-photograph-whose-filename-is-far-longer-than-any-column-could-ever-show-and-has-to-be-ellipsized.jpg" 96000
f "$ROOT/Photographs/.hidden-contact-sheet.png"    1200
mkdir -p "$ROOT/Photographs/Raw"
f "$ROOT/Photographs/Raw/IMG_0001.dng" 24000000
f "$ROOT/Photographs/Raw/IMG_0002.dng" 23400000

f "$ROOT/Documents/annual-report.pdf"   180000
f "$ROOT/Documents/invoice-2026-03.pdf" 42000
f "$ROOT/Documents/letter.odt"          19000
f "$ROOT/Documents/budget.csv"          3400

f "$ROOT/Downloads/palmy-0.9.tar.gz" 8400000
f "$ROOT/Downloads/font-sample.ttf"  220000
f "$ROOT/Music/overture.flac"        38000000
f "$ROOT/Projects/notes.md"          2100
f "$ROOT/Projects/main.odin"         14000

# The file the Save demo tries to write over. It must already exist, or there
# is no overwrite confirmation to show. One copy in the folder the Save dialog
# opens on, one in Photographs where it belongs.
f "$ROOT/sunset.png" 310000
f "$ROOT/Photographs/sunset.png" 310000

echo "$ROOT"
