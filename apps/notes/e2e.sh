#!/usr/bin/env bash
# Notes, end to end, against a real local stack: Postgres, GoTrue, PostgREST
# and Storage from cloud/dev, and the sync server palm-collab.
#
#   apps/notes/e2e.sh [--keep] [--no-reset] [--port-base 47521] [--collab-port 47590]
#
# One person, Camille, with two identities — camille (personal) and northwind
# (work) — and two devices, a laptop and a phone, each with its own token
# store and its own ~/Notes. A second person, Bob. Everything is driven
# through the real `notes` binary; nothing is mocked. Each step prints what
# it did and the checks it made, and the script exits non-zero on the first
# failed check.
#
#   1. both devices enrol both identities; a note written on the laptop
#      reaches the phone
#   2. the sync server goes away; both devices edit the same note offline,
#      in different places; it comes back and both merge, with no conflicted
#      copy, every line from both devices kept
#   3. offline on both again, the same line edited on both: both edits kept
#   4. a note moved to a notebook on one device and pinned on the other: both
#   5. a share to Bob (edit): Bob's device gets it under Shared/, Bob's edit
#      reaches Camille; a share to read refuses Bob's edit; revoking removes
#      Bob's copy at his next sync
#   6. carry: a work note carried into personal; an independent copy, a log
#      row on both sides, the scoped work session cannot see the copy; an
#      attachment uploaded from the laptop arrives on the phone
#   7. isolation: a process scoped to northwind sees only northwind's notes,
#      on disk and in the database; asking for camille exits 5
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE=47521
CPORT=47590
RESET=1
KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--keep) KEEP=1 ;;
	--no-reset) RESET=0 ;;
	--port-base) BASE="$2"; shift ;;
	--collab-port) CPORT="$2"; shift ;;
	*) echo "e2e.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done

T="${NOTES_E2E_DIR:-${TMPDIR:-/tmp}/palm-notes-e2e}"
BIN="$T/bin/notes"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
export PALM_CLOUD_URL="http://127.0.0.1:$BASE"
export PALM_COLLAB_URL="ws://127.0.0.1:$CPORT"
unset PALM_IDENTITY PALMY_NOTES_DIR PALM_CLOUD_SESSION

pass=0
fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }
check() { # description, command...
	local what=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}
show() { printf '  $ %s\n' "$*"; }

# ---------------------------------------------------------------- the stack
step "stack"
if [ "$RESET" = 1 ]; then
	"$ROOT/cloud/dev/up.sh" --name notes --port-base "$BASE" --reset >/dev/null 2>&1 || { echo "cloud/dev/up.sh failed"; exit 6; }
else
	"$ROOT/cloud/dev/up.sh" --name notes --port-base "$BASE" >/dev/null 2>&1 || { echo "cloud/dev/up.sh failed"; exit 6; }
fi
rm -rf "$T"
mkdir -p "$T/bin"
(cd "$ROOT" && odin build apps/notes -collection:palmy=palmy -collection:shadcn=shadcn -collection:kit=apps/kit -out:"$BIN") || exit 7
(cd "$ROOT" && odin build cloud/collab/server -o:speed -out:"$T/bin/palm-collab") || exit 7
(cd "$ROOT" && odin build cloud/collab/cli -out:"$T/bin/palm-collab-cli") || exit 7
(cd "$ROOT" && odin build apps/accounts -collection:palmy=palmy -collection:shadcn=shadcn -collection:kit=apps/kit -out:"$T/bin/accounts") || exit 7

server_start() {
	PALM_COLLAB_SERVICE_KEY="$SERVICE_KEY" "$T/bin/palm-collab" --port "$CPORT" >>"$T/server.log" 2>&1 &
	SERVER=$!
	sleep 0.4
}
server_stop() {
	[ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null && wait "$SERVER" 2>/dev/null
	SERVER=""
}
cleanup() {
	server_stop
	[ "$KEEP" = 1 ] || true
}
trap cleanup EXIT
server_start
echo "  stack $PALM_CLOUD_URL, sync server $PALM_COLLAB_URL (pid $SERVER), state in $T"

cli() { "$T/bin/palm-collab-cli" "$@" >/dev/null; }
mkdir -p "$T/laptop/cloud" "$T/phone/cloud" "$T/bob/cloud"
cli --dir "$T/laptop/cloud" signup camille@notes.test correct-horse-1
cli --dir "$T/laptop/cloud" identity camille "Camille Roux" personal teal
cli --dir "$T/laptop/cloud" identity northwind "Northwind" work blue
cli --dir "$T/phone/cloud" signin camille@notes.test correct-horse-1
cli --dir "$T/bob/cloud" signup bob@notes.test correct-horse-2
cli --dir "$T/bob/cloud" identity bob.okafor "Bob Okafor" personal amber

# Each device is its own token store and its own ~/Notes.
laptop() { PALM_CLOUD_DIR="$T/laptop/cloud" PALM_NOTES_ROOT="$T/laptop/Notes" "$BIN" "$@"; }
phone() { PALM_CLOUD_DIR="$T/phone/cloud" PALM_NOTES_ROOT="$T/phone/Notes" "$BIN" "$@"; }
bob() { PALM_CLOUD_DIR="$T/bob/cloud" PALM_NOTES_ROOT="$T/bob/Notes" "$BIN" "$@"; }
L="$T/laptop/Notes"
P="$T/phone/Notes"
B="$T/bob/Notes"
jq_() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
one_file() { find "$1" -name "$2" -not -path '*/.palm/*' | head -1; }
body_of() { python3 - "$1" <<'PY'
import sys
t = open(sys.argv[1]).read()
if t.startswith('---\n'):
    t = t.split('\n---\n', 1)[1].lstrip('\n')
print(t, end='')
PY
}

# ---------------------------------------------------------------- 1
step "1. two devices, two identities"
show "laptop: notes sync"
laptop sync --json | jq_ '"  enrolled %d identities: %s" % (d["enrolled"], ", ".join(i["identity"] for i in d["identities"]))'
phone sync >/dev/null 2>&1
check "the laptop has a folder per identity" test -f "$L/camille/.palm/identity.json" -a -f "$L/northwind/.palm/identity.json"
check "and so has the phone" test -f "$P/camille/.palm/identity.json" -a -f "$P/northwind/.palm/identity.json"

show 'laptop: notes new "Lisbon trip" --identity camille --text ...'
laptop new "Lisbon trip" --identity camille --notebook Travel \
	--text "Flights on Friday.\n\n## To book\n- [ ] the hotel near Alfama\n- [ ] a table at Prado\n\n## Ideas\nThe tram to Belém in the morning." --json >/dev/null
show "laptop: notes sync; phone: notes sync"
laptop sync --json | jq_ '"  laptop: created %d, pushed %d" % (sum(i["created"] for i in d["identities"]), sum(i["pushed"] for i in d["identities"]))'
phone sync --json | jq_ '"  phone: arrived %d — %s" % (sum(i["arrived"] for i in d["identities"]), "; ".join(e for i in d["identities"] for e in i["events"]))'
PL=$(one_file "$P/camille" "lisbon-trip.md")
check "the note arrived on the phone, in its notebook" test -n "$PL" -a "$(dirname "$PL")" = "$P/camille/Travel"
check "with the same text" diff <(body_of "$L/camille/Travel/lisbon-trip.md") <(body_of "$PL")
check "and the same id in its front matter" test "$(grep '^id:' "$L/camille/Travel/lisbon-trip.md")" = "$(grep '^id:' "$PL")"

# ---------------------------------------------------------------- 2
step "2. offline on both devices, then the merge"
server_stop
echo "  (the sync server is down)"
show 'laptop: notes write ... (adds a line at the top and ticks the hotel)'
laptop write "Lisbon trip" --text "# Lisbon trip\n\nFlights on Friday, 07:40 from Orly.\n\n## To book\n- [x] the hotel near Alfama\n- [ ] a table at Prado\n\n## Ideas\nThe tram to Belém in the morning." --json >/dev/null
show 'phone: edits the same file in place (adds an idea at the bottom)'
printf '%s\n' "Pastéis at Manteigaria, not the queue at Belém." >>"$PL"
laptop sync --json | jq_ '"  laptop, sync server down: %d note(s) queued in the outbox" % sum(i["queued"] for i in d["identities"])'
phone sync --json | jq_ '"  phone, sync server down: %d note(s) queued in the outbox" % sum(i["queued"] for i in d["identities"])'
check "the laptop's edit waits in its outbox" test "$(laptop status --json | jq_ 'sum(i["waiting"] for i in d["identities"])')" -ge 1
server_start
echo "  (the sync server is back)"
laptop sync >/dev/null 2>&1
phone sync --json | jq_ '"  phone: pushed %d, pulled %d" % (sum(i["pushed"] for i in d["identities"]), sum(i["pulled"] for i in d["identities"]))'
laptop sync --json | jq_ '"  laptop: pulled %d" % sum(i["pulled"] for i in d["identities"])'
echo "  --- the note on the laptop now:"
body_of "$L/camille/Travel/lisbon-trip.md" | sed 's/^/  | /'
check "the laptop's new line is on the phone" grep -q "07:40 from Orly" "$PL"
check "the laptop's ticked box is on the phone" grep -q "\[x\] the hotel" "$PL"
check "the phone's new line is on the laptop" grep -q "Manteigaria" "$L/camille/Travel/lisbon-trip.md"
check "both devices hold exactly the same text" diff <(body_of "$L/camille/Travel/lisbon-trip.md") <(body_of "$PL")
check "no conflicted copy anywhere" test -z "$(find "$L" "$P" -iname '*conflict*')"
check "one Lisbon note per device, not two" test "$(find "$L/camille" "$P/camille" -name 'lisbon*.md' -not -path '*/.palm/*' | wc -l)" = 2

# ---------------------------------------------------------------- 3
step "3. the same line, edited on both devices offline"
server_stop
sed -i 's/a table at Prado/a table at Prado for Saturday/' "$L/camille/Travel/lisbon-trip.md"
sed -i 's/a table at Prado/a table at Prado (ask for the terrace)/' "$PL"
laptop sync --offline >/dev/null 2>&1
phone sync --offline >/dev/null 2>&1
server_start
laptop sync >/dev/null 2>&1; phone sync >/dev/null 2>&1; laptop sync >/dev/null 2>&1
echo "  merged line: $(grep 'Prado' "$PL")"
check "both edits to one line survive" grep -q "for Saturday" "$PL"
check "both edits to one line survive (2)" grep -q "terrace" "$PL"
check "and the devices agree" diff <(body_of "$L/camille/Travel/lisbon-trip.md") <(body_of "$PL")

# ---------------------------------------------------------------- 4
step "4. moved on one device, pinned on the other"
server_stop
laptop move "Lisbon trip" "Travel/2026" --json >/dev/null
phone pin "Lisbon trip" --json >/dev/null
server_start
laptop sync >/dev/null 2>&1; phone sync >/dev/null 2>&1; laptop sync >/dev/null 2>&1
PL=$(one_file "$P/camille" "lisbon-trip.md")
check "the phone filed it where the laptop moved it" test "$(dirname "$PL")" = "$P/camille/Travel/2026"
check "the laptop has the phone's pin" grep -q "^pinned: true" "$L/camille/Travel/2026/lisbon-trip.md"

# ---------------------------------------------------------------- 5
step "5. sharing with Bob"
bob sync >/dev/null 2>&1
show "laptop: notes share \"Lisbon trip\" bob.okafor --access edit"
laptop share "Lisbon trip" bob.okafor --access edit --json | jq_ '"  shared %s with %s (%s)" % (d["title"], d["with"], d["access"])'
bob sync --json | jq_ '"  bob: %s" % "; ".join(e for i in d["identities"] for e in i["events"])'
BL=$(one_file "$B/bob.okafor/Shared" "lisbon-trip.md")
check "Bob's device has it under Shared/camille/" test "$(dirname "$BL")" = "$B/bob.okafor/Shared/camille"
check "marked as shared, to edit" grep -q "^access: edit" "$BL"
bob append "Lisbon trip" --text "Bob: the Gulbenkian is free on Sundays." --json >/dev/null
bob sync >/dev/null 2>&1; laptop sync >/dev/null 2>&1
check "Bob's edit reached Camille's laptop" grep -q "Gulbenkian" "$L/camille/Travel/2026/lisbon-trip.md"
show "laptop: notes share \"Lisbon trip\" bob.okafor --access read"
laptop share "Lisbon trip" bob.okafor --access read --json >/dev/null
bob sync >/dev/null 2>&1
check "read: Bob's copy is read-only on disk" test ! -w "$BL"
code=0; bob append "Lisbon trip" --text "Bob again" --json >/dev/null 2>&1 || code=$?
check "read: notes append refuses with exit 5" test "$code" = 5
show "laptop: notes unshare \"Lisbon trip\" bob.okafor"
laptop unshare "Lisbon trip" bob.okafor --json >/dev/null
bob sync --json | jq_ '"  bob: %s" % "; ".join(e for i in d["identities"] for e in i["events"])'
check "revoked: Bob's copy is gone" test -z "$(find "$B" -name 'lisbon*.md')"

# ---------------------------------------------------------------- 6
step "6. carry from work to personal"
laptop new "Packing list" --identity northwind --text "- badge\n- laptop charger\n- the Q4 deck on a stick" --json >/dev/null
laptop sync >/dev/null 2>&1
show 'laptop: notes carry "Packing list" --to camille --device laptop'
laptop carry "Packing list" --to camille --device laptop --json | jq_ '"  %s: %s -> %s, copy %s, recorded %s" % (d["title"], d["from"], d["to"], d["id"][:8], d["recorded"])'
check "the copy is in camille's folder" test -f "$L/camille/packing-list.md"
check "the original is still in northwind's" test -f "$L/northwind/packing-list.md"
check "they have different ids" test "$(grep '^id:' "$L/camille/packing-list.md")" != "$(grep '^id:' "$L/northwind/packing-list.md")"
echo "  northwind's carry log:"
laptop log --identity northwind --json | jq_ '"\n".join("    %s  %-22s %s %s  sha256 %s…  from %s" % (e["direction"], e["title"], "to" if e["direction"]=="out" else "from", e["peer"], e["hash"][:12], e["device"]) for e in d["entries"])'
echo "  camille's carry log:"
laptop log --identity camille --json | jq_ '"\n".join("    %s  %-22s %s %s  sha256 %s…  from %s" % (e["direction"], e["title"], "to" if e["direction"]=="out" else "from", e["peer"], e["hash"][:12], e["device"]) for e in d["entries"])'
check "northwind's log says out to camille" test "$(laptop log --identity northwind --json | jq_ 'd["entries"][0]["direction"] + " " + d["entries"][0]["peer"]')" = "out camille"
check "camille's log says in from northwind" test "$(laptop log --identity camille --json | jq_ 'd["entries"][0]["direction"] + " " + d["entries"][0]["peer"]')" = "in northwind"
laptop append "Packing list" --identity northwind --text "- a second shirt" --json >/dev/null
laptop sync >/dev/null 2>&1; phone sync >/dev/null 2>&1
check "independent: editing the original leaves the copy alone" bash -c "! grep -q 'second shirt' '$L/camille/packing-list.md'"
check "the copy reached the phone's personal folder" test -f "$P/camille/packing-list.md"
code=0; PALM_IDENTITY=northwind laptop carry "Packing list" --to camille --json >/dev/null 2>&1 || code=$?
check "a process scoped to northwind cannot carry (exit 5)" test "$code" = 5

# ---------------------------------------------------------------- 6b
step "6b. an attachment travels with its note"
python3 -c "import sys; sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\n' + bytes(range(256)) * 8)" >"$T/map.png"
show 'laptop: notes attach "Lisbon trip" map.png'
laptop attach "Lisbon trip" "$T/map.png" --json | jq_ '"  linked as %s" % d["link"]'
laptop sync >/dev/null 2>&1; phone sync --json | jq_ '"  phone: %s" % "; ".join(e for i in d["identities"] for e in i["events"])'
SHA=$(sha256sum "$T/map.png" | cut -c1-12)
check "the phone fetched the attachment into attachments/" test -f "$P/camille/attachments/$SHA-map.png"
check "byte for byte" cmp -s "$T/map.png" "$P/camille/attachments/$SHA-map.png"
check "and the note links it" grep -q "attachments/$SHA-map.png" "$(one_file "$P/camille" "lisbon-trip.md")"

# ---------------------------------------------------------------- 7
step "7. isolation"
n=$(PALM_IDENTITY=northwind laptop list --json | jq_ 'len(set(x["identity"] for x in d["notes"]))')
check "scoped to northwind, list shows one identity" test "$n" = 1
check "and it is northwind" test "$(PALM_IDENTITY=northwind laptop list --json | jq_ 'd["notes"][0]["identity"]')" = northwind
check "search inside the scope never finds camille's Lisbon note" test "$(PALM_IDENTITY=northwind laptop search lisbon --json | jq_ 'd["count"]')" = 0
check "unscoped search finds it, labelled camille" test "$(laptop search lisbon --json | jq_ 'd["matches"][0]["identity"]')" = camille
code=0; PALM_IDENTITY=northwind laptop list --identity camille --json >/dev/null 2>&1 || code=$?
check "asking a northwind process for camille exits 5" test "$code" = 5
# The database, through a token scoped to northwind: a fresh work laptop
# that holds only a northwind session (minted by the accounts app, the way
# `accounts switch` does on a real machine) syncs from empty.
PALM_CLOUD_DIR="$T/laptop/cloud" "$T/bin/accounts" switch northwind --json >/dev/null 2>&1
check "the accounts app minted a session scoped to northwind" test -f "$T/laptop/cloud/scoped/northwind.json"
work() { PALM_IDENTITY=northwind PALM_CLOUD_DIR="$T/laptop/cloud" PALM_NOTES_ROOT="$T/worklaptop/Notes" "$BIN" "$@"; }
show "work laptop (PALM_IDENTITY=northwind): notes sync"
work sync --json | jq_ '"  enrolled %d: %s; arrived %d" % (d["enrolled"], ", ".join(i["identity"] for i in d["identities"]), sum(i["arrived"] for i in d["identities"]))'
check "the scoped device enrolled northwind only" test "$(ls "$T/worklaptop/Notes")" = northwind
check "northwind's notes arrived" test -f "$T/worklaptop/Notes/northwind/packing-list.md"
check "nothing of camille's reached it, not even through the database" test -z "$(grep -rl 'Lisbon' "$T/worklaptop/Notes" 2>/dev/null)"
code=0; work carry "Packing list" --to camille --json >/dev/null 2>&1 || code=$?
check "the scoped device cannot carry out of northwind (exit 5)" test "$code" = 5
echo
echo "notes e2e: $pass passed, $fail failed"
[ "$fail" = 0 ]
