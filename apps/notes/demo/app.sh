#!/usr/bin/env bash
# The program the recorder films: Camille's laptop window, against the demo
# stack, with Bob as a second, real collaborator — `notes coedit`, a client of
# the same sync server, typing his script into the shared note while the take
# runs. Nothing in the window is staged: his caret, his name and his text
# arrive through palm-collab exactly as another window's would.
D="${NOTES_DEMO_DIR:-/tmp/palm-notes-demo}"
export PALM_CLOUD_URL="${PALM_CLOUD_URL:-http://127.0.0.1:47521}"
export PALM_COLLAB_URL="${PALM_COLLAB_URL:-ws://127.0.0.1:47590}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
(
	sleep "${BOB_AFTER:-27}"
	note=$(PALM_CLOUD_DIR="$D/bob/cloud" PALM_NOTES_ROOT="$D/bob/Notes" "$D/bin/notes" read "Lisbon trip" --json |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
	PALM_CLOUD_DIR="$D/bob/cloud" PALM_NOTES_ROOT="$D/bob/Notes" "$D/bin/notes" coedit "$note" --script "$HERE/bob.txt" >"$D/bob.log" 2>&1
) &
export PALM_CLOUD_DIR="$D/laptop/cloud"
export PALM_NOTES_ROOT="$D/laptop/Notes"
exec "$D/bin/notes"
