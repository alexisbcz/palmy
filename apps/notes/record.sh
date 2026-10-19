#!/usr/bin/env bash
# Record the Notes demo on a private headless compositor, against a real
# local stack, with Bob as a live second collaborator.
#
#   apps/notes/record.sh [out.mp4]
#
# 1. demo/setup.sh resets the `notes` stack, starts palm-collab, signs up
#    Camille (camille + northwind) and Bob, writes the starting notes and
#    shares "Lisbon trip" with Bob to edit.
# 2. apps/tools/headless-record.sh films demo/app.sh — Camille's window — and
#    drives it with demo/steps.txt; app.sh starts Bob's `notes coedit` with
#    demo/bob.txt partway through, so his edits and caret arrive live.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
OUT="${1:-$HERE/demo.mp4}"
export NOTES_DEMO_DIR="${NOTES_DEMO_DIR:-/tmp/palm-notes-demo}"
"$HERE/demo/setup.sh"
"$ROOT/apps/tools/headless-record.sh" "$HERE/demo/app.sh" "$OUT" "$HERE/demo/steps.txt" 1440 900
kill "$(cat "$NOTES_DEMO_DIR/server.pid")" 2>/dev/null || true
