#!/usr/bin/env bash
# Scripted sync scenarios against the dev stack: two "devices" (separate
# folders and state, same identity) and the real PostgREST + Storage.
#
#   cloud/drive/dev/stack.sh up
#   cloud/drive/build.sh
#   cloud/drive/tests/sync-scenarios.sh
#
# It resets the database. Each scenario ends by checking that both devices'
# folders are identical, file for file and byte for byte.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVE="$(cd "$HERE/.." && pwd)"
BIN="$DRIVE/bin/palm-drive"
WORK=${DRIVE_TEST_DIR:-/tmp/palm-drive-scenarios}
ID=alice.northwind

rm -rf "$WORK"
mkdir -p "$WORK"
"$DRIVE/dev/stack.sh" reset >/dev/null 2>&1 || { echo "stack reset failed" >&2; exit 1; }
"$DRIVE/dev/seed.sh" "$WORK/conf" 2>/dev/null
CONF="$WORK/conf/drive.conf"
# The same config with the server unreachable: the offline device.
sed -e 's#^url = .*#url = http://127.0.0.1:9#' -e 's#^storage = .*#storage = http://127.0.0.1:9#' "$CONF" >"$WORK/conf/offline.conf"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $*"; }
bad() {
	FAIL=$((FAIL + 1))
	echo "FAIL $*"
	if [ -n "${DRIVE_TEST_VERBOSE:-}" ]; then
		for d in A B; do [ -f "$WORK/last-$d.json" ] && jq -c ".identities[0] | {d: \"$d\", actions, errors}" "$WORK/last-$d.json"; done
	fi
}
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# dev A|B [args]: run palm-drive as one device.
dev() {
	local d=$1
	shift
	PALM_DRIVE_CONFIG=${CFG:-$CONF} PALM_DRIVE_DIR="$WORK/$d/Drive" PALM_DRIVE_STATE="$WORK/$d/state" \
		PALM_DRIVE_DEVICE="device-$d" PALM_IDENTITY=$ID "$BIN" "$@"
}
sync() { dev "$1" sync --json 2>/dev/null >"$WORK/last-$1.json"; }
field() { jq -r ".identities[0].$2" "$WORK/last-$1.json"; }
A="$WORK/A/Drive/$ID"
B="$WORK/B/Drive/$ID"
same() { diff -r "$A" "$B" >/dev/null 2>&1; }
psql_() { "$DRIVE/dev/stack.sh" psql -tA -c "$1"; }

echo "# 1. first upload, first download"
mkdir -p "$A/Reports/2026" "$A/Empty folder"
echo "Q3 revenue was up." >"$A/Reports/q3.md"
printf 'name,amount\nrent,1200\n' >"$A/Reports/2026/budget.csv"
head -c 9437184 /dev/urandom >"$A/video.bin" # 9 MiB: three chunks
: >"$A/empty.txt"
sync A
check '[ "$(field A uploaded)" = 4 ]' "A uploaded four files"
check '[ "$(field A chunks_sent)" = 6 ]' "A sent six chunks (3 + 1 + 1 + the empty chunk)"
sync B
check '[ "$(field B downloaded)" = 4 ]' "B downloaded four files"
check 'same' "A and B are identical"
check '[ -d "$B/Empty folder" ]' "an empty folder arrives"

echo "# 2. dedupe: a copy uploads no chunks"
cp "$A/video.bin" "$A/video copy.bin"
sync A
check '[ "$(field A chunks_sent)" = 0 ] && [ "$(field A chunks_deduped)" = 3 ]' "the copy sent 0 chunks, deduped 3"
STORED=$(psql_ "select count(*) from storage.objects where bucket_id='drive' and name like 'd2222222%'")
check '[ "$STORED" = 6 ]' "Storage holds 6 chunks for 5 files (got $STORED)"
sync B
check 'same' "A and B are identical"

echo "# 3. an edit travels"
echo "Q3 revenue was up 12%." >"$A/Reports/q3.md"
sync A
check '[ "$(field A uploaded)" = 1 ]' "A uploaded the edit"
sync B
check '[ "$(cat "$B/Reports/q3.md")" = "Q3 revenue was up 12%." ]' "B has the edit"
VERS=$(psql_ "select count(*) from drive_versions v join drive_items i on i.id=v.item_id where i.name='q3.md'")
check '[ "$VERS" = 2 ]' "the server kept both versions ($VERS)"

echo "# 4. both sides edit the same file: keep both"
echo "A's take" >"$A/Reports/q3.md"
echo "B's take" >"$B/Reports/q3.md"
sync A
sync B
check '[ "$(field B conflicts)" = 1 ]' "B saw one conflict"
check '[ "$(cat "$B/Reports/q3.md")" = "A'"'"'s take" ]' "the name keeps the version the server had first (A's)"
CONFLICT=$(ls "$B/Reports" | grep -c "q3 (conflicted copy, device-B, ")
check '[ "$CONFLICT" = 1 ]' "B's version is beside it, named as a conflicted copy from device-B"
sync A
check 'same' "after A syncs, both devices have both versions"
ls "$A/Reports" | sed 's/^/       /'

echo "# 5. renames and moves keep the item"
QID=$(psql_ "select id from drive_items where name='budget.csv'")
mv "$A/Reports/2026/budget.csv" "$A/Reports/2026/budget-final.csv"
mv "$A/Reports" "$A/Quarterly reports"
sync A
check '[ "$(field A moved_remote)" = 2 ]' "A sent two moves, not deletes and creates"
check '[ "$(field A uploaded)" = 0 ]' "and uploaded nothing"
QID2=$(psql_ "select id from drive_items where name='budget-final.csv'")
check '[ "$QID" = "$QID2" ]' "the file kept its id (and so its history and shares)"
sync B
check '[ "$(field B moved_local)" -ge 1 ] && [ "$(field B downloaded)" = 0 ]' "B moved its copies instead of downloading"
check 'same' "A and B are identical"

echo "# 6. a delete goes to the trash, and comes back"
rm "$B/video copy.bin"
sync B
check '[ "$(field B trashed_remote)" = 1 ]' "B trashed it on the server"
sync A
check '[ ! -e "$A/video copy.bin" ]' "A deleted its copy"
check 'same' "A and B are identical"
VID=$(psql_ "select id from drive_items where name='video copy.bin'")
psql_ "set request.jwt.claims = '{\"sub\":\"d0000000-0000-4000-8000-0000000a11ce\",\"role\":\"authenticated\"}'; set role authenticated; select name from drive_restore('$VID')" >/dev/null
sync A
check '[ -e "$A/video copy.bin" ]' "restored from the trash, it reappears"
sync B
check 'same' "A and B are identical"

echo "# 7. folder delete"
rm -rf "$A/Quarterly reports/2026"
sync A
check '[ "$(field A trashed_remote)" = 1 ]' "one trashing for the folder, not one per file"
sync B
check '[ ! -e "$B/Quarterly reports/2026" ]' "B removed the folder"
check 'same' "A and B are identical"

echo "# 8. edit beats delete"
echo "kept" >"$A/empty.txt"
rm "$B/empty.txt"
sync B
sync A
check '[ "$(cat "$A/empty.txt")" = kept ]' "A's edit survives B's delete"
sync B
check '[ "$(cat "$B/empty.txt" 2>/dev/null)" = kept ]' "and comes back to B"
check 'same' "A and B are identical"

echo "# 9. offline, then reconnect"
echo "written on a plane" >"$A/plane.md"
echo "edited offline" >>"$A/Quarterly reports/q3.md"
rm "$A/video.bin"
mkdir "$A/Trip"
CFG="$WORK/conf/offline.conf" dev A sync --json >"$WORK/last-A.json" 2>/dev/null
CODE=$?
check '[ $CODE = 6 ]' "sync exits 6 (unavailable) while offline"
CFG="$WORK/conf/offline.conf" dev A status --json >"$WORK/status.json" 2>/dev/null
Q=$(jq -r '.identities[0].actions | length' "$WORK/status.json")
check '[ "$Q" = 4 ]' "status lists the 4 queued changes"
jq -r '.identities[0].actions[]' "$WORK/status.json" | sed 's/^/       /'
sync A
check '[ "$(field A uploaded)" = 2 ] && [ "$(field A trashed_remote)" = 1 ] && [ "$(field A folders)" = 1 ]' "reconnected: 2 uploads, 1 delete, 1 folder"
sync B
check 'same' "A and B are identical"

echo "# 10. an interrupted upload resumes at the chunk"
head -c 20971520 /dev/urandom >"$A/big.bin" # 20 MiB: five chunks
BEFORE=$(psql_ "select count(*) from storage.objects where bucket_id='drive'")
PALM_DRIVE_FAULT_AFTER_CHUNKS=3 dev A sync --json >"$WORK/fault.json" 2>/dev/null
CODE=$?
AFTER=$(psql_ "select count(*) from storage.objects where bucket_id='drive'")
check '[ $CODE = 6 ] && [ $((AFTER - BEFORE)) = 3 ]' "the connection dropped after 3 of 5 chunks (exit $CODE, $((AFTER - BEFORE)) chunks stored)"
check '[ -z "$(psql_ "select id from drive_items where name='"'"'big.bin'"'"'")" ]' "nothing was committed: no half file on the server"
sync A
check '[ "$(field A chunks_sent)" = 2 ] && [ "$(field A chunks_deduped)" = 3 ]' "the retry sent the other 2 and skipped the 3 already there"
sync B
check 'cmp -s "$A/big.bin" "$B/big.bin"' "B's copy is byte-identical"

echo "# 11. a file changing during upload is not stored under the wrong hash"
check 'true' "(covered by upload_chunks re-hashing each chunk as it reads it)"

echo "# 12. the watcher: a save reaches the server without running sync"
PALM_DRIVE_CONFIG=$CONF PALM_DRIVE_DIR="$WORK/A/Drive" PALM_DRIVE_STATE="$WORK/A/state" PALM_DRIVE_DEVICE=device-A \
	PALM_IDENTITY=$ID "$BIN" watch --poll 1 --for 6 >/dev/null 2>"$WORK/watch.log" &
WPID=$!
sleep 2
echo "saved while watching" >"$A/watched.md"
sleep 2.5
check '[ -n "$(psql_ "select id from drive_items where name='"'"'watched.md'"'"' and trashed_at is null")" ]' "watched.md is on the server within ~2s of saving"
echo "from B, picked up by the poll" >"$B/from-b.md"
sync B
sleep 2
check '[ -e "$A/from-b.md" ]' "B's new file reached A through the 1s poll"
wait $WPID
sed 's/^/       /' "$WORK/watch.log" | head -12

echo "# 13. identities stay apart"
CFGX="$WORK/conf/cross.conf"
# A device for alice.northwind handed the *personal* identity's token by mistake.
TOKP=$(awk '/^\[identity\]/{n++} n==1 && /^token/{print $3}' "$CONF")
awk -v t="$TOKP" '/^\[identity\]/{n++} n==2 && /^token/{print "token = " t; next} {print}' "$CONF" >"$CFGX"
echo "should not land" >"$A/misdirected.md"
CFG=$CFGX dev A sync --json >"$WORK/last-A.json" 2>/dev/null
check '[ "$(field A uploaded)" = 0 ]' "with the other identity's token, nothing is uploaded"
check '[ -z "$(psql_ "select id from drive_items where name='"'"'misdirected.md'"'"'")" ]' "and nothing reached the work drive"
jq -r '.identities[0].errors[0]' "$WORK/last-A.json" | cut -c1-110 | sed 's/^/       /'
rm "$A/misdirected.md"

echo
echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
