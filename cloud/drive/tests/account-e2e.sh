#!/usr/bin/env bash
# The drive with a real account: sign up through GoTrue with the Accounts
# CLI, create a work identity, then run palm-drive and drive with no
# drive.conf at all -- the configuration, the identities and one scoped token
# per identity all come from apps/cloudkit's token store.
#
#   cloud/drive/dev/stack.sh up && cloud/drive/build.sh && apps/accounts built
#   cloud/drive/tests/account-e2e.sh
#
# Everything lives under a throwaway HOME, so the real ~/.local/share/palm and
# ~/Drive are never touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
eval "$("$ROOT/cloud/drive/dev/stack.sh" env)"
T=${DRIVE_TEST_DIR:-/tmp/palm-drive-account}
rm -rf "$T"
mkdir -p "$T/home"
export HOME="$T/home" PALM_CLOUD_DIR="$T/home/.local/share/palm/cloud"
unset PALM_DRIVE_CONFIG PALM_IDENTITY
ACC="$ROOT/apps/accounts/accounts.bin"
DRIVE="$ROOT/apps/drive/drive.bin"
SYNC="$ROOT/cloud/drive/bin/palm-drive"
N=$RANDOM
EMAIL="dana$N@palm.test"
PASS=0
FAIL=0
check() { if eval "$1"; then PASS=$((PASS + 1)); echo "ok   $2"; else FAIL=$((FAIL + 1)); echo "FAIL $2"; fi; }

printf 'correct horse battery staple' >"$T/pw"
"$ACC" signup "$EMAIL" --name "Dana Okafor" --handle "dana$N" --password-file "$T/pw" --json >"$T/signup.json" 2>&1
check '[ $? = 0 ] || grep -q user_id "$T/signup.json"' "signed up $EMAIL with identity dana$N"
"$ACC" create "dana$N-work" --name "Dana at Fabrikam" --kind work --color sky --json >/dev/null 2>&1
check '[ $? = 0 ]' "created the work identity dana$N-work"

"$SYNC" identities --json >"$T/ids.json" 2>"$T/ids.err"
check '[ "$(jq -r ".identities | length" "$T/ids.json")" = 2 ]' "palm-drive found both identities from the account, with no drive.conf"
check '[ -f "$PALM_CLOUD_DIR/scoped/dana$N.json" ] && [ -f "$PALM_CLOUD_DIR/scoped/dana$N-work.json" ]' "and minted a scoped session for each"

mkdir -p "$HOME/Drive/dana$N-work/Specs" "$HOME/Drive/dana$N"
echo "spec v1" >"$HOME/Drive/dana$N-work/Specs/api.md"
echo "groceries" >"$HOME/Drive/dana$N/list.txt"
"$SYNC" sync --json >"$T/sync.json" 2>"$T/sync.err"
check '[ "$(jq "[.identities[].uploaded] | add" "$T/sync.json")" = 2 ]' "sync uploaded one file into each identity's drive"

PALM_IDENTITY="dana$N-work" "$DRIVE" ls Specs --json >"$T/ls.json" 2>&1
check '[ "$(jq -r ".items[0].name" "$T/ls.json")" = api.md ]' "drive ls, scoped to the work identity, sees Specs/api.md"
PALM_IDENTITY="dana$N-work" "$DRIVE" find groceries --json >"$T/find.json" 2>&1
check '[ "$(jq -r ".count" "$T/find.json")" = 0 ]' "scoped to work, the personal file does not exist"

# A match says where it is: the path from the root of the identity's drive,
# which stat (and every other verb) takes back as is.
mkdir -p "$HOME/Drive/dana$N-work/Specs/2026/Q4"
echo "q4 budget" >"$HOME/Drive/dana$N-work/Specs/2026/Q4/budget.csv"
"$SYNC" sync --json >/dev/null 2>&1
PALM_IDENTITY="dana$N-work" "$DRIVE" find budget --json >"$T/findp.json" 2>&1
check '[ "$(jq -r ".items[0].path" "$T/findp.json")" = Specs/2026/Q4/budget.csv ]' "drive find gives each match its full path in the drive"
PALM_IDENTITY="dana$N-work" "$DRIVE" find 2026 --json >"$T/findf.json" 2>&1
check '[ "$(jq -r ".items[0].kind + \" \" + .items[0].path" "$T/findf.json")" = "folder Specs/2026" ]' "a folder's path too"
PALM_IDENTITY="dana$N-work" "$DRIVE" stat "$(jq -r ".items[0].path" "$T/findp.json")" --json >"$T/statp.json" 2>&1
check '[ "$(jq -r ".item.id" "$T/statp.json")" = "$(jq -r ".items[0].id" "$T/findp.json")" ]' "and that path, given to stat, is the same item"
PALM_IDENTITY="dana$N-work" "$DRIVE" find budget >"$T/findp.txt" 2>&1
check 'grep -q "Specs/2026/Q4/budget.csv" "$T/findp.txt"' "the text output shows the path"
"$DRIVE" --schema >"$T/finds.json" 2>&1
check 'jq -e ".commands[] | select(.verb == \"find\") | .output.fields[] | select(.name == \"items\") | .of[] | select(.name == \"path\")" "$T/finds.json" >/dev/null' "and --schema declares it on each item"

PALM_IDENTITY="dana$N-work" "$DRIVE" ls --identity "dana$N" --json >"$T/scope.json" 2>&1
CODE=$?
check '[ $CODE = 5 ]' "scoped to work, asking for the personal drive exits 5 (out of scope)"

"$DRIVE" share Specs "dana$N" --identity "dana$N-work" --json >/dev/null 2>&1
PALM_IDENTITY="dana$N" "$DRIVE" shared --json >"$T/shared.json" 2>&1
check '[ "$(jq -r ".shared[0].name" "$T/shared.json")" = Specs ]' "after an explicit share, the personal identity sees Specs under Shared with me"

echo
echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
