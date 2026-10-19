#!/usr/bin/env bash
# Screenshots of real collaborative sessions, light and dark.
#
#   cloud/collab/demo/shots.sh <bin-dir> <out-dir>
#
# For each app, Alice creates a shared document and shares it with Bob; Bob
# (a headless instance of the same app, --script) edits, suggests and
# comments, then stays present with a selection; Alice (also headless) waits
# for all of it to arrive and renders her window offscreen. What is in the
# pictures is what the sync server delivered — nothing is staged.
#
# Needs the stack from cloud/collab/dev/up.sh, with its environment exported.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(realpath "${1:?bin dir with docs, sheets, slides}")"
OUT="$(realpath -m "${2:?out dir}")"
STATE="${PALM_COLLAB_DEV:-${TMPDIR:-/tmp}/palm-collab-dev}"
: "${PALM_CLOUD_URL:?export the environment cloud/collab/dev/up.sh prints}"
mkdir -p "$OUT"
CLI="$STATE/bin/palm-collab-cli"

one() { # app title seed-file
	local app=$1 title=$2 seed=${3:-}
	local doc
	doc=$(PALM_CLOUD_DIR="$STATE/acct-alice" "$BIN/$app" --collab new --title "$title" --as alice.martin \
		--script "$HERE/quit.txt" $seed | sed -n 's/^shared document \([0-9a-f-]*\).*/\1/p')
	"$CLI" --dir "$STATE/acct-alice" share "$doc" bob.okafor edit >/dev/null
	echo "$app: $doc"
	PALM_CLOUD_DIR="$STATE/acct-bob" "$BIN/$app" --collab "$doc" --as bob.okafor \
		--script "$HERE/shots-$app-bob.txt" >"$OUT/$app-bob.log" 2>&1 &
	local bob=$!
	sed "s|@OUT@|$OUT|g" "$HERE/shots-$app-alice.txt" >"$OUT/.alice-$app.txt"
	PALM_CLOUD_DIR="$STATE/acct-alice" "$BIN/$app" --collab "$doc" --as alice.martin \
		--script "$OUT/.alice-$app.txt" | grep wrote || true
	kill "$bob" 2>/dev/null || true
	wait "$bob" 2>/dev/null || true
	rm -f "$OUT/.alice-$app.txt"
}

one docs "Northwind Q4 launch plan" "$HERE/plan.md"
one sheets "Northwind Q4 budget"
one slides "Northwind Q4 review"
