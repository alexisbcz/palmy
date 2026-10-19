#!/usr/bin/env bash
# Bookmark sync end to end against a running cloud/dev stack: two "devices"
# (two browser homes) sharing one account, two identities, a throwaway token
# store. Prints each step, its exit code and a slice of its output.
#
#   bash apps/browser/sync-e2e.sh <browser binary> <accounts binary> [api url]
#
#   cloud/dev/up.sh --name browser --port-base 63521
#   bash apps/browser/sync-e2e.sh bin/browser accounts.bin http://127.0.0.1:63521
set -uo pipefail
browser=${1:?browser binary}
accounts=${2:?accounts binary}
export PALM_CLOUD_URL=${3:-http://127.0.0.1:54321}
export PALM_CLOUD_DIR=$(mktemp -d /tmp/browser-sync-e2e.XXXXXX)
A=$PALM_CLOUD_DIR/deviceA
B=$PALM_CLOUD_DIR/deviceB
trap 'rm -rf "$PALM_CLOUD_DIR"' EXIT
unset PALM_IDENTITY
tag=$(date +%s%N | tail -c 7)
me="alex$tag"
work="work$tag"
pass=0 fail=0

step() { # want-exit description command...
	local want=$1 what=$2; shift 2
	local out code
	out=$("$@" 2>&1); code=$?
	if [ "$code" = "$want" ]; then pass=$((pass + 1)); echo "ok   [$code] $what"
	else fail=$((fail + 1)); echo "FAIL [$code, wanted $want] $what"; fi
	printf '     %s\n' "$(tr -d '\n' <<<"$out" | tr -s ' ' | cut -c1-200)"
}
expect() { # description command... ; passes when the command's output contains $WANT
	local what=$1; shift
	local out; out=$("$@" 2>&1)
	if grep -q -- "$WANT" <<<"$out"; then pass=$((pass + 1)); echo "ok   $what"
	else fail=$((fail + 1)); echo "FAIL $what (wanted '$WANT')"; printf '     %s\n' "$(tr -d '\n' <<<"$out" | cut -c1-300)"; fi
}
refute() {
	local what=$1; shift
	local out; out=$("$@" 2>&1)
	if grep -q -- "$WANT" <<<"$out"; then fail=$((fail + 1)); echo "FAIL $what (did not want '$WANT')"
	else pass=$((pass + 1)); echo "ok   $what"; fi
}
onA() { env PALM_BROWSER_HOME="$A" PALM_IDENTITY="$1" "$browser" "${@:2}"; }
onB() { env PALM_BROWSER_HOME="$B" PALM_IDENTITY="$1" "$browser" "${@:2}"; }

step 0 "an account with a personal identity" "$accounts" signup "sync$tag@palm.test" --name "Alex" --handle "$me" --password "sync password $tag" --json
step 0 "and a work identity" "$accounts" create "$work" --name "Alex at work" --kind work --json
step 0 "a session scoped to the personal identity on this machine" "$accounts" switch "$me" --json
step 0 "and one scoped to work" "$accounts" switch "$work" --json

step 0 "device A: two bookmarks in the personal profile" onA "$me" bookmark-add https://odin-lang.org --title Odin --json
step 0 "  (the second)" onA "$me" bookmark-add https://ziglang.org --title Zig --json
step 0 "device A: a work bookmark" onA "$work" bookmark-add https://intranet.example --title Intranet --json
WANT='"pending": 2'; expect "device A: two personal changes wait to be sent" onA "$me" sync-status --json
step 0 "device A syncs personal" onA "$me" sync --json
step 0 "device A syncs work" onA "$work" sync --json
WANT='"pending": 0'; expect "device A: nothing waits after a sync" onA "$me" sync-status --json

step 0 "device B pulls personal" onB "$me" sync --json
WANT=odin-lang.org; expect "device B has Odin" onB "$me" bookmarks --json
WANT=ziglang.org; expect "device B has Zig" onB "$me" bookmarks --json
WANT=intranet.example; refute "device B's personal profile has nothing of work" onB "$me" bookmarks --json

# concurrent edits of the same bookmark: A renames it, B moves it
step 0 "device A renames Odin" onA "$me" bookmark-edit https://odin-lang.org --title "Odin language" --json
step 0 "device B moves Odin to Other bookmarks" onB "$me" bookmark-edit https://odin-lang.org --folder other --json
step 0 "device A syncs" onA "$me" sync --json
step 0 "device B syncs" onB "$me" sync --json
step 0 "device A syncs again" onA "$me" sync --json
WANT='Odin language'; expect "device B kept A's rename" onB "$me" bookmarks --folder other --json
WANT='Odin language'; expect "device A has B's move (Odin is in Other bookmarks)" onA "$me" bookmarks --folder other --json

step 4 "deleting without --yes is refused" onB "$me" bookmark-remove https://ziglang.org --json
step 0 "device B deletes Zig (a tombstone)" onB "$me" bookmark-remove https://ziglang.org --yes --json
step 0 "device B syncs" onB "$me" sync --json
step 0 "device A syncs" onA "$me" sync --json
WANT=ziglang.org; refute "the delete reached device A" onA "$me" bookmarks --json

step 0 "work syncs on device B" onB "$work" sync --json
WANT=intranet.example; expect "device B's work profile has the work bookmark" onB "$work" bookmarks --json
WANT=odin-lang.org; refute "and none of the personal ones" onB "$work" bookmarks --json

"$accounts" signout --json >/dev/null 2>&1
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
