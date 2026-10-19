#!/usr/bin/env bash
# Record two people co-editing one document, with apps/tools/headless-record.sh.
#
#   cloud/collab/demo/record-docs.sh <docs-binary> <out.mp4> [alice-steps] [bob-script]
#
# Needs the stack from cloud/collab/dev/up.sh (and its environment exported).
# Alice is the window being filmed, driven by the recorder's keystrokes. Bob is
# a second instance of the same docs binary, headless, driven by a script
# (docs --script), started inside the same private compositor session so the
# two edit at the same time. Both are real clients of the real sync server.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../../.." && pwd)"
DOCS="$(realpath "${1:?docs binary}")"
OUT="$(realpath -m "${2:?out.mp4}")"
ASTEPS="$(realpath "${3:-$HERE/alice-docs.txt}")"
BSCRIPT="$(realpath "${4:-$HERE/bob-docs.txt}")"
STATE="${PALM_COLLAB_DEV:-${TMPDIR:-/tmp}/palm-collab-dev}"
: "${PALM_CLOUD_URL:?export the environment cloud/collab/dev/up.sh prints}"
CLI="$STATE/bin/palm-collab-cli"

# A fresh document from plan.md, owned by Alice, shared with Bob as an editor.
DOC=$(PALM_CLOUD_DIR="$STATE/acct-alice" "$DOCS" --collab new --title "Northwind Q4 launch plan" --as alice.martin \
	--script "$HERE/quit.txt" "$HERE/plan.md" | sed -n 's/^shared document \([0-9a-f-]*\).*/\1/p')
[ -n "$DOC" ] || { echo "could not create the document"; exit 1; }
"$CLI" --dir "$STATE/acct-alice" share "$DOC" bob.okafor edit >/dev/null
echo "document $DOC"

WRAP="$(mktemp -d "${TMPDIR:-/tmp}/palm-collab-rec-XXXXXX")"
trap 'rm -rf "$WRAP"' EXIT
cat >"$WRAP/run.sh" <<RUN
#!/usr/bin/env bash
export PALM_CLOUD_URL="$PALM_CLOUD_URL" PALM_COLLAB_URL="$PALM_COLLAB_URL" PALM_COLLAB_DIR="$PALM_COLLAB_DIR"
( sleep 2.5; PALM_CLOUD_DIR="$STATE/acct-bob" "$DOCS" --collab "$DOC" --as bob.okafor --script "$BSCRIPT" >"$WRAP/bob.log" 2>&1 ) &
PALM_CLOUD_DIR="$STATE/acct-alice" exec "$DOCS" --collab "$DOC" --as alice.martin
RUN
chmod +x "$WRAP/run.sh"
bash "$ROOT/apps/tools/headless-record.sh" "$WRAP/run.sh" "$OUT" "$ASTEPS" 1440 900
echo "final text, as the server has it:"
"$CLI" --dir "$STATE/acct-alice" cat "$DOC" | head -20
echo "$DOC" >"$OUT.doc"
