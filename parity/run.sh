#!/usr/bin/env bash
# Full parity pass: capture the browser, render with palmy, diff, report.
#
#   ./run.sh              every case
#   ./run.sh button-      only cases whose id starts with this
set -uo pipefail

# Every path is derived from where this script is, so running it from a git
# worktree builds and measures that worktree -- the same fix tools/diff-all.sh
# carries. It used to build against a hardcoded /home/alex/Work/palmy.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
cd "$HERE" || exit 1

FILTER="${1:-}"
BASE_URL="${BASE_URL:-http://localhost:5173}"
ODIN=${ODIN:-/home/alex/.local/share/mise/installs/odin/dev-2026-09/odin}

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

say "building the odin side from $REPO"
"$ODIN" build odin/render -collection:palmy="$REPO/palmy" -collection:shadcn="$REPO/shadcn" -o:speed -out:odin/render.bin || exit 1
"$ODIN" build odin/pixdiff -o:speed -out:odin/pixdiff.bin || exit 1

if ! curl -sf "$BASE_URL/parity/cases.json" -o /dev/null; then
  say "starting the dev server"
  (cd web && npm run dev >/tmp/parity-dev.log 2>&1 &)
  for _ in $(seq 1 60); do
    curl -sf "$BASE_URL/parity/cases.json" -o /dev/null && break
    sleep 1
  done
  STARTED_SERVER=1
fi

say "capturing the browser"
node harness/capture.mjs ${FILTER:+"$FILTER"} || true

say "rendering with palmy"
if [ -n "$FILTER" ]; then
  mapfile -t IDS < <(./odin/render.bin --list | grep "^$FILTER")
  [ ${#IDS[@]} -gt 0 ] && ./odin/render.bin "${IDS[@]}"
else
  ./odin/render.bin --all
fi

say "diffing"
mkdir -p out/diff
: > out/diff/metrics.ndjson
for ref in out/web/*.png; do
  id=$(basename "$ref" .png)
  [ -n "$FILTER" ] && case "$id" in "$FILTER"*) ;; *) continue ;; esac
  cand="out/odin/$id.png"
  if [ ! -f "$cand" ]; then
    echo "{\"id\":\"$id\",\"status\":\"not-implemented\"}" >> out/diff/metrics.ndjson
    continue
  fi
  m=$(./odin/pixdiff.bin "$ref" "$cand" --out "out/diff/$id.png" --json)
  echo "{\"id\":\"$id\",\"status\":\"ok\",\"metrics\":$m}" >> out/diff/metrics.ndjson
done

say "report"
node tools/report.mjs

if [ "${STARTED_SERVER:-}" = "1" ]; then
  pkill -f "react-router dev" 2>/dev/null || true
fi
