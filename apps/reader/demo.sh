#!/usr/bin/env bash
# Rebuild the demo's books and library, then record the demo.
#
#   bash apps/reader/demo.sh            # fixtures + recording
#   bash apps/reader/demo.sh --books    # fixtures only
#
# Every book in the demo is generated here: by this program (the EPUBs and
# MOBIs), by apps/docs and apps/slides (the PDFs), and by djvulibre's own
# encoder (the DjVu). None of the user's files are opened, named or shown, and
# the library the demo shows lives in apps/reader/demo/state rather than in
# ~/.local/share/palmy-reader.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=apps/reader/reader.bin
D=apps/reader/demo
export PALMY_READER_HOME="$PWD/$D/state"

rm -rf "$D/books" "$D/state"
mkdir -p "$D/books" "$D/state"

# The fixture book (every block kind, and a deliberately malformed chapter),
# a MOBI, a PDF from apps/docs with an outline, a PDF from apps/slides, and a
# three-page DjVu.
"$BIN" --fixtures "$D/books" >/dev/null

# Two novel-sized generated books, so the library is not all toys.
"$BIN" --genbig "$D/books/novel.epub" 24 60
"$BIN" --genbig "$D/books/novel.mobi" 12 40

# The DjVu encoder's intermediates are not part of the demo.
rm -f "$D/books"/*.pgm "$D/books"/djvu-p*.djvu "$D/books/outline.txt" "$D/books/oracle.md"

# A DjVu carries its title in an annotation chunk, and a scan usually has none.
djvused -e 'set-meta /dev/stdin' -s "$D/books/generated.djvu" <<'META'
Title "A Scanned Document"
Author "D. Fixture"
META

"$BIN" --add \
  "$D/books/novel.epub" \
  "$D/books/generated.epub" \
  "$D/books/novel.mobi" \
  "$D/books/generated.mobi" \
  "$D/books/generated.pdf" \
  "$D/books/slides.pdf" \
  "$D/books/generated.djvu"

[ "${1:-}" = "--books" ] && exit 0

bash apps/tools/headless-record.sh "$BIN" apps/reader/demo.mp4 apps/reader/demo.txt 1280 820
