#!/usr/bin/env bash
# The state the recorded demo starts from, on a real local stack.
#
#   apps/notes/demo/setup.sh [--port-base 47521] [--collab-port 47590]
#
# Camille has two identities, camille (personal) and northwind (work), on a
# laptop; Bob has one. Camille's Lisbon note is shared with Bob to edit. The
# sync server runs in the background (its pid in $D/server.pid). Everything
# lives under $D (default /tmp/palm-notes-demo), and the stack is reset.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE=47521
CPORT=47590
while [ $# -gt 0 ]; do
	case "$1" in
	--port-base) BASE="$2"; shift ;;
	--collab-port) CPORT="$2"; shift ;;
	*) echo "setup.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
D="${NOTES_DEMO_DIR:-/tmp/palm-notes-demo}"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
export PALM_CLOUD_URL="http://127.0.0.1:$BASE"
export PALM_COLLAB_URL="ws://127.0.0.1:$CPORT"
unset PALM_IDENTITY PALMY_NOTES_DIR PALM_CLOUD_SESSION

"$ROOT/cloud/dev/up.sh" --name notes --port-base "$BASE" --reset >/dev/null 2>&1
if [ -f "$D/server.pid" ]; then kill "$(cat "$D/server.pid")" 2>/dev/null || true; fi
rm -rf "$D"
mkdir -p "$D/bin" "$D/laptop/cloud" "$D/bob/cloud"
cd "$ROOT"
odin build apps/notes -collection:palmy=palmy -collection:shadcn=shadcn -collection:kit=apps/kit -o:speed -out:"$D/bin/notes"
odin build cloud/collab/server -o:speed -out:"$D/bin/palm-collab"
odin build cloud/collab/cli -out:"$D/bin/palm-collab-cli"

PALM_COLLAB_SERVICE_KEY="$SERVICE_KEY" nohup "$D/bin/palm-collab" --port "$CPORT" >"$D/server.log" 2>&1 &
echo $! >"$D/server.pid"
sleep 0.5

cli() { "$D/bin/palm-collab-cli" "$@" >/dev/null; }
cli --dir "$D/laptop/cloud" signup camille@notes.test correct-horse-1
cli --dir "$D/laptop/cloud" identity camille "Camille Roux" personal teal
cli --dir "$D/laptop/cloud" identity northwind "Northwind" work blue
cli --dir "$D/bob/cloud" signup bob@notes.test correct-horse-2
cli --dir "$D/bob/cloud" identity bob.okafor "Bob Okafor" personal amber
printf 'camille\n' >"$D/laptop/cloud/current"

laptop() { PALM_CLOUD_DIR="$D/laptop/cloud" PALM_NOTES_ROOT="$D/laptop/Notes" "$D/bin/notes" "$@" >/dev/null; }
bob() { PALM_CLOUD_DIR="$D/bob/cloud" PALM_NOTES_ROOT="$D/bob/Notes" "$D/bin/notes" "$@" >/dev/null; }

laptop sync
laptop new "Garden plan for spring" --identity camille --notebook Home --text "Three raised beds running north to south, so nothing shades its neighbour before noon. Broad beans in February, chard in March. #garden"
laptop new "Restaurants in Lisbon" --identity camille --notebook Travel --text "- Prado, for the terrace, book ahead\n- Taberna da Rua das Flores, no bookings, go at 19:00\n\nBack to [[Lisbon trip]]."
laptop new "Lisbon trip" --identity camille --notebook Travel --tags travel \
	--text "Flights on **Friday**, 07:40 from Orly. The rest is in [[Restaurants in Lisbon]].\n\n## To book\n\n- [x] the hotel near Alfama\n- [ ] a table at Prado for Saturday\n\n## Ideas\n\n> Pastéis at Manteigaria, not the queue at Belém."
laptop new "Q4 plan" --identity northwind --notebook Projects --tags q4 \
	--text "1. **Offline first** for notes and documents\n2. Sharing that is a row you can revoke\n3. Search that never leaves the machine\n\nMy trip that week is in [[camille:Lisbon trip]]."
laptop new "Packing list" --identity northwind --text "- badge\n- laptop charger\n- the Q4 deck on a stick"
laptop new "Standup notes" --identity northwind --notebook Projects --text "- [[Q4 plan]] review moved to Thursday\n- [ ] the offline merge demo #q4"
laptop sync
laptop share "Lisbon trip" bob.okafor --access edit
bob sync
echo "demo state ready in $D (sync server pid $(cat "$D/server.pid"))"
