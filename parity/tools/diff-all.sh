#!/usr/bin/env bash
# Render every registered case and diff it against the browser capture.
set -uo pipefail
cd /home/alex/Work/palmy/parity
ODIN=/home/alex/.local/share/mise/installs/odin/dev-2026-09/odin

"$ODIN" build odin/render -collection:palmy=/home/alex/Work/palmy/palmy -collection:shadcn=/home/alex/Work/palmy/shadcn -o:speed -out:odin/render.bin || exit 1
./odin/render.bin --all 2>/dev/null | tail -1

mkdir -p out/diff
: > out/diff/metrics.ndjson
for ref in out/web/*.png; do
  id=$(basename "$ref" .png)
  cand="out/odin/$id.png"
  if [ ! -f "$cand" ]; then
    printf '{"id":"%s","status":"not-implemented"}\n' "$id" >> out/diff/metrics.ndjson
    continue
  fi
  m=$(./odin/pixdiff.bin "$ref" "$cand" --out "out/diff/$id.png" --json 2>/dev/null)
  if [ -n "$m" ]; then
    printf '{"id":"%s","status":"ok","metrics":%s}\n' "$id" "$m" >> out/diff/metrics.ndjson
  else
    printf '{"id":"%s","status":"diff-failed"}\n' "$id" >> out/diff/metrics.ndjson
  fi
done
node tools/report.mjs
