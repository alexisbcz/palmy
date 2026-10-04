#!/usr/bin/env bash
# The demo's entry point: the recorder takes a binary or a script, and this is
# how the application gets its argument.
#
# The document is generated — `ocr --demo-doc` renders pages this program wrote
# and wraps them in a PDF with no text layer, so the demo is a real scan-shaped
# conversion with nothing of the user's anywhere in it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$here/demo"
doc="$here/demo/scan.pdf"
[ -f "$doc" ] || "$here/ocr.bin" --demo-doc "$doc" >/dev/null
exec "$here/ocr.bin" "$doc"
