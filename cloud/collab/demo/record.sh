#!/usr/bin/env bash
# Record two people co-editing one document, with apps/tools/headless-record.sh.
#
#   cloud/collab/demo/record.sh <docs|sheets|slides> <binary> <out.mp4> <alice-steps> <bob-script> [seed-file]
#
# Needs the stack from cloud/collab/dev/up.sh, with its environment exported.
# Alice is the window being filmed, driven by the recorder's keystrokes. Bob is
# a second instance of the same binary, headless (`--script`), started inside
# the same session so the two edit at the same time. Both are real clients of
# the real sync server, signed in as two different people.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../../.." && pwd)"
APP="${1:?docs|sheets|slides}"
BIN="$(realpath "${2:?binary}")"
OUT="$(realpath -m "${3:?out.mp4}")"
ASTEPS="$(realpath "${4:?alice steps}")"
BSCRIPT="$(realpath "${5:?bob script}")"
SEED="${6:-}"
[ -n "$SEED" ] && SEED="$(realpath "$SEED")"
STATE="${PALM_COLLAB_DEV:-${TMPDIR:-/tmp}/palm-collab-dev}"
: "${PALM_CLOUD_URL:?export the environment cloud/collab/dev/up.sh prints}"
CLI="$STATE/bin/palm-collab-cli"
case "$APP" in
docs) TITLE="Northwind Q4 launch plan" ;;
sheets) TITLE="Northwind Q4 budget" ;;
slides) TITLE="Northwind Q4 review" ;;
*) echo "unknown app $APP"; exit 2 ;;
esac

DOC=$(PALM_CLOUD_DIR="$STATE/acct-alice" "$BIN" --collab new --title "$TITLE" --as alice.martin \
	--script "$HERE/quit.txt" $SEED | sed -n 's/^shared document \([0-9a-f-]*\).*/\1/p')
[ -n "$DOC" ] || { echo "could not create the document"; exit 1; }
"$CLI" --dir "$STATE/acct-alice" share "$DOC" bob.okafor edit >/dev/null
echo "$APP document $DOC"

WRAP="$(mktemp -d "${TMPDIR:-/tmp}/palm-collab-rec-XXXXXX")"
trap 'rm -rf "$WRAP"' EXIT
cat >"$WRAP/run.sh" <<RUN
#!/usr/bin/env bash
export PALM_CLOUD_URL="$PALM_CLOUD_URL" PALM_COLLAB_URL="$PALM_COLLAB_URL" PALM_COLLAB_DIR="$PALM_COLLAB_DIR"
( sleep 2.5; PALM_CLOUD_DIR="$STATE/acct-bob" "$BIN" --collab "$DOC" --as bob.okafor --script "$BSCRIPT" >"$OUT.bob.log" 2>&1 ) &
PALM_CLOUD_DIR="$STATE/acct-alice" exec "$BIN" --collab "$DOC" --as alice.martin 2>"$OUT.alice.log"
RUN
chmod +x "$WRAP/run.sh"
bash "$ROOT/apps/tools/headless-record.sh" "$WRAP/run.sh" "$OUT" "$ASTEPS" 1440 900
echo "$DOC" >"$OUT.doc"
