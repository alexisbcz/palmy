#!/usr/bin/env bash
# The account vault end to end, against a running cloud/dev stack.
#
#   cloud/dev/up.sh --name pw --port-base 64521
#   PALM_CLOUD_URL=http://127.0.0.1:64521 PALM_DB_CONTAINER=palm-pw-db \
#     bash apps/vault/e2e.sh path/to/vault path/to/accounts
#
# Three machines, each its own token store and data directory:
#   laptop  alice's own (unscoped) session: identities alice and alice-work
#   phone   a second device of alice's personal identity, scoped to it
#   bob     another person's account
#
# What it shows, in order: setup and the Secret Key; a second device enrolled
# by approval (code compared, Secret Key sealed to it); two devices syncing,
# including a conflict merged per field; a login shared from alice to bob
# (another account) and alice-work's vault shared to alice (the cross-identity
# rule inside one account); revocation and rotation; an assistant getting
# nothing; a Bitwarden import; and a pg_dump of the vault tables searched for
# every secret and URL the demo used.
#
# Every step prints its exit code and a one-line summary; the run ends with
# the count. Nothing here touches a real account: it all lives in a temp dir
# and in the dev stack.
set -uo pipefail
VAULT=$(realpath "${1:?path to vault binary}")
ACCOUNTS=$(realpath "${2:?path to accounts binary}")
HERE=$(cd "$(dirname "$0")" && pwd)
: "${PALM_CLOUD_URL:=http://127.0.0.1:64521}"
: "${PALM_DB_CONTAINER:=palm-pw-db}"
export PALM_CLOUD_URL
unset PALM_IDENTITY PALM_CLOUD_SESSION XDG_DATA_HOME PALM_CLOUD_DIR
W=$(mktemp -d /tmp/vault-e2e.XXXXXX)
trap 'rm -rf "$W"' EXIT
tag=$(date +%s%N | tail -c 6)
pass=0 fail=0

dev() { # machine command... : run with that machine's stores
	local m=$1; shift
	mkdir -p "$W/$m/data" "$W/$m/cloud"
	env XDG_DATA_HOME="$W/$m/data" PALM_CLOUD_DIR="$W/$m/cloud" "$@"
}
step() { # want-exit description command...
	local want=$1 what=$2; shift 2
	local code
	LAST=$("$@" 2>"$W/stderr"); code=$?
	if [ "$code" = "$want" ]; then pass=$((pass + 1)); echo "ok   [$code] $what"
	else fail=$((fail + 1)); echo "FAIL [$code, wanted $want] $what"; sed 's/^/     stderr: /' "$W/stderr" | head -5; fi
	printf '     %s\n' "$(tr -d '\n' <<<"$LAST" | tr -s ' ' | cut -c1-230)"
}
check() { # description python-expression-over-LAST (j is the parsed JSON)
	if python3 -I -c "import json,sys; j=json.loads(sys.stdin.read()); sys.exit(0 if ($2) else 1)" <<<"$LAST" 2>/dev/null; then
		pass=$((pass + 1)); echo "ok        $1"
	else fail=$((fail + 1)); echo "FAIL      $1"; fi
}
field() { python3 -I -c "import json,sys; j=json.loads(sys.stdin.read()); print($1)" <<<"$LAST"; }

printf 'master password %s, correct horse' "$tag" >"$W/alice.mp"
printf 'bob master password %s battery' "$tag" >"$W/bob.mp"
A=alice$tag AW=alicew$tag B=bob$tag

echo "== accounts"
step 0 "alice signs up (identity $A)" dev laptop "$ACCOUNTS" signup "$A@example.test" --name "Alice Martin" --handle "$A" --password "account pw $tag" --json
step 0 "alice adds a work identity ($AW)" dev laptop "$ACCOUNTS" create "$AW" --name "Alice (Northwind)" --kind work --color emerald --json
step 0 "bob signs up (another person, identity $B)" dev bob "$ACCOUNTS" signup "$B@example.test" --name "Bob Lee" --handle "$B" --password "bob account pw $tag" --json

echo "== the account vault, first device"
step 0 "laptop: vault setup creates the Secret Key and a vault per identity" dev laptop "$VAULT" setup --password-file "$W/alice.mp" --json
check "the Secret Key has the PV1 form" "j['secret_key'].startswith('PV1-') and len(j['secret_key'])==34"
check "both identities were set up" "len(j['identities'])==2"
step 0 "bob: vault setup" dev bob "$VAULT" setup --password-file "$W/bob.mp" --json
step 0 "laptop: add a GitHub login to alice's personal vault" dev laptop "$VAULT" add --title GitHub --username alice-gh --url https://github.com --identity "$A" --password-file "$W/alice.mp" --json
step 0 "laptop: add the Northwind VPN to the work vault" dev laptop "$VAULT" add --title "Northwind VPN" --username alice.martin --url https://vpn.northwind.example --identity "$AW" --password-file "$W/alice.mp" --json
GH_PW=$(dev laptop "$VAULT" get github --field password --password-file "$W/alice.mp" 2>/dev/null)
VPN_PW=$(dev laptop "$VAULT" get "Northwind VPN" --field password --password-file "$W/alice.mp" 2>/dev/null)
step 0 "laptop: get masks the password unless asked" dev laptop "$VAULT" get github --password-file "$W/alice.mp" --json
check "the password is masked" "'hidden' in j['password'] and j['revealed']==False"

echo "== a second device, approved by the first"
step 0 "phone: sign in and take a session scoped to $A" dev phone "$ACCOUNTS" signin "$A@example.test" --password "account pw $tag" --json
step 0 "phone: switch (mint the scoped session)" dev phone "$ACCOUNTS" switch "$A" --json
step 0 "phone: ask to be enrolled; shows a code" dev phone env PALM_IDENTITY="$A" "$VAULT" enroll --request --identity "$A" --name "Alice's phone" --json
DEV=$(field "j['device_id']"); CODE=$(field "j['code']")
step 7 "laptop: approving with the wrong code is refused" dev laptop "$VAULT" approve "$DEV" --code "000 000" --json
step 0 "laptop: approve with the code the phone shows (seals the Secret Key to the phone)" dev laptop "$VAULT" approve "$DEV" --code "$CODE" --json
step 0 "phone: the approval opens; enrolled" dev phone env PALM_IDENTITY="$A" "$VAULT" enroll --wait --json
check "enrolled" "j['enrolled']==True"
step 0 "phone: list sees the personal vault, and only it" dev phone env PALM_IDENTITY="$A" "$VAULT" list --password-file "$W/alice.mp" --json
check "GitHub is there, the work VPN is not" "[i['title'] for i in j['items']]==['GitHub']"
step 5 "phone: asking for the work identity is out of scope (exit 5)" dev phone env PALM_IDENTITY="$A" "$VAULT" list --identity "$AW" --password-file "$W/alice.mp" --json

echo "== two devices, one identity"
step 0 "phone: add a bank login" dev phone env PALM_IDENTITY="$A" "$VAULT" add --title "Example Bank" --username alice-0042 --url https://bank.example.org --password-file "$W/alice.mp" --json
step 0 "laptop: sync pulls it" dev laptop "$VAULT" sync --password-file "$W/alice.mp" --json
step 0 "laptop: list" dev laptop "$VAULT" list --identity "$A" --password-file "$W/alice.mp" --offline --json
check "the laptop sees the phone's item" "'Example Bank' in [i['title'] for i in j['items']]"
printf 'branch code 7731' >"$W/notes"
step 0 "laptop, offline: edit the bank's username (queued, not pushed)" dev laptop "$VAULT" edit "Example Bank" --username alice-0042-new --offline --password-file "$W/alice.mp" --json
check "one edit pending" "j['pending']==1"
step 0 "phone: meanwhile edits the bank's notes and password" dev phone env PALM_IDENTITY="$A" "$VAULT" edit "Example Bank" --notes-file "$W/notes" --generate --password-file "$W/alice.mp" --json
step 0 "laptop: sync: the server refuses the stale write, the client merges per field" dev laptop "$VAULT" sync --password-file "$W/alice.mp" --json
check "one conflict merged, nothing dropped" "j['merged']==1 and j['dropped']==0"
step 0 "phone: sync and read the merged item" dev phone env PALM_IDENTITY="$A" "$VAULT" get "Example Bank" --reveal --password-file "$W/alice.mp" --json
check "both edits survived: the laptop's username and the phone's notes" "j['item']['username']=='alice-0042-new' and j['notes']=='branch code 7731'"

echo "== sharing"
step 0 "laptop: share GitHub (read-only) with bob, another account" dev laptop "$VAULT" share github --with "$B" --password-file "$W/alice.mp" --json
check "the safety number is shown for a key the server handed us" "len(j['fingerprint'].split())==4"
step 0 "bob: list shows the shared login" dev bob "$VAULT" list --password-file "$W/bob.mp" --json
check "bob sees GitHub, from alice" "'GitHub' in [i['title'] for i in j['items']]"
step 0 "bob: the password opens, and is alice's" dev bob "$VAULT" get github --field password --password-file "$W/bob.mp"
[ "$LAST" = "$GH_PW" ] && { pass=$((pass+1)); echo "ok        bob decrypted exactly alice's password"; } || { fail=$((fail+1)); echo "FAIL      bob's copy differs"; }
step 5 "bob: editing a read-only share is refused" dev bob "$VAULT" edit github --username hijack --password-file "$W/bob.mp" --json
step 0 "laptop: share the work vault with alice's personal identity (the cross-identity row)" dev laptop "$VAULT" share --vault Work --identity "$AW" --with "$A" --role read --password-file "$W/alice.mp" --json
step 0 "phone (scoped to $A): now sees the work VPN, through the share" dev phone env PALM_IDENTITY="$A" "$VAULT" list --password-file "$W/alice.mp" --json
check "the VPN arrives via the share" "'Northwind VPN' in [i['title'] for i in j['items']]"
step 0 "laptop: the shares, each with a verified signature" dev laptop "$VAULT" shares --password-file "$W/alice.mp" --json
check "two live shares, both verified" "len([s for s in j['shares'] if not s['revoked'] and s['verified']])==2"
GH_SHARE=$(field "[s['id'] for s in j['shares'] if s['what'].startswith('item')][0]")

echo "== revoke and rotate"
step 4 "revoke without --yes is refused (exit 4)" dev laptop "$VAULT" revoke "$GH_SHARE" --password-file "$W/alice.mp" --json
step 0 "laptop: revoke bob's share; the item is re-encrypted under a new key" dev laptop "$VAULT" revoke "$GH_SHARE" --yes --password-file "$W/alice.mp" --json
check "one item rotated" "j['rotated']==1"
step 0 "bob: sync; the login is gone from his device" dev bob "$VAULT" list --password-file "$W/bob.mp" --json
check "bob no longer has GitHub" "'GitHub' not in [i['title'] for i in j['items']]"
step 0 "laptop: health says the revoked share exposed it" dev laptop "$VAULT" health --identity "$A" --password-file "$W/alice.mp" --json
check "GitHub is flagged exposed" "any(f['title']=='GitHub' and f['issue']=='exposed' for f in j['findings'])"

echo "== the assistant gets nothing"
step 0 "laptop: delegate an assistant to $A" dev laptop "$ACCOUNTS" delegate "$A" --name "Mail assistant" --kind assistant --expires 3600 --json
HELD=$(ls "$W"/laptop/cloud/delegated/*.json | head -1)
step 5 "the assistant, holding PALM_CLOUD_SESSION, is refused by every vault verb" dev laptop env PALM_CLOUD_SESSION="$HELD" "$VAULT" list --json
TOKEN=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['access_token'])" "$HELD" 2>/dev/null)
if [ -z "$TOKEN" ]; then
	# The stored file holds a refresh token; exchange it as the assistant would.
	RT=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['refresh_token'])" "$HELD")
	TOKEN=$(curl -s "$PALM_CLOUD_URL/auth/v1/token?grant_type=refresh_token" -H "apikey: $ANON" -H 'Content-Type: application/json' -d "{\"refresh_token\":\"$RT\"}" | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
fi
# The local stack's public anon key (cloud/dev): it identifies the project, RLS decides.
ANON=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
for t in vault_items vault_keysets vault_vaults vault_shares vault_devices; do
	step 0 "the assistant's own token, straight at PostgREST: $t" curl -s "$PALM_CLOUD_URL/rest/v1/$t?select=*" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN"
	check "$t: nothing" "j==[]"
done
step 0 "the same token reads alice's identity (it is a working session)" curl -s "$PALM_CLOUD_URL/rest/v1/identities?select=handle" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN"
check "it sees $A" "len(j)==1"

echo "== import"
step 0 "laptop: import a Bitwarden JSON export into alice's vault" dev laptop "$VAULT" import "$HERE/testdata/bitwarden.json" --identity "$A" --password-file "$W/alice.mp" --json
check "5 imported, the trashed one skipped" "j['imported']==5 and j['skipped']==1"
step 0 "phone: the imports synced" dev phone env PALM_IDENTITY="$A" "$VAULT" list --search example --password-file "$W/alice.mp" --json
check "the passkey item and the card arrived" "{'Example Passkey Site','Example Card'} <= set(i['title'] for i in j['items'])"
step 0 "phone: TOTP from an imported otpauth:// URI" dev phone env PALM_IDENTITY="$A" "$VAULT" totp "Example Forge" --password-file "$W/alice.mp" --json
check "an 8-digit code" "len(j['code'])==8"

echo "== autofill: the browser's side, simulated"
SOCK="$W/laptop/run/autofill.sock"; mkdir -p "$W/laptop/run"
# Headless, so nobody is there to click: --allow once answers yes. The window
# asks a person instead (see the screenshots).
dev laptop "$VAULT" autofill --socket "$SOCK" --allow once --max-requests 40 --password-file "$W/alice.mp" --offline >/dev/null 2>"$W/af.log" &
AFPID=$!
for _ in $(seq 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
PAIR="$W/laptop/pair.json"
step 0 "client: pair, authenticate, query https://github.com as a tab of $A" dev laptop "$VAULT" autofill-client https://github.com --identity-of-tab "$A" --socket "$SOCK" --pair-file "$PAIR" --json
check "one candidate: GitHub, exact match, and no password in the answer" "len(j['candidates'])==1 and j['candidates'][0]['title']=='GitHub' and j['candidates'][0]['match']=='exact'"
GH_ID=$(field "j['candidates'][0]['id']")
step 0 "client: the same origin from a tab of the work identity gets nothing" dev laptop "$VAULT" autofill-client https://github.com --identity-of-tab "$AW" --socket "$SOCK" --pair-file "$PAIR" --json
check "no candidates across identities" "j['candidates']==[]"
step 0 "client: http://github.com (a downgrade) gets nothing" dev laptop "$VAULT" autofill-client http://github.com --identity-of-tab "$A" --socket "$SOCK" --pair-file "$PAIR" --json
check "no candidates over http" "j['candidates']==[]"
step 0 "client: https://github.com.evil.example gets nothing" dev laptop "$VAULT" autofill-client https://github.com.evil.example --identity-of-tab "$A" --socket "$SOCK" --pair-file "$PAIR" --json
check "no candidates for a lookalike host" "j['candidates']==[]"
step 0 "client: https://gist.github.com matches as a subdomain" dev laptop "$VAULT" autofill-client https://gist.github.com --identity-of-tab "$A" --socket "$SOCK" --pair-file "$PAIR" --json
check "subdomain match" "len(j['candidates'])==1 and j['candidates'][0]['match']=='subdomain'"
step 0 "client: fill GitHub on https://github.com" dev laptop "$VAULT" autofill-client https://github.com --identity-of-tab "$A" --fill "$GH_ID" --socket "$SOCK" --pair-file "$PAIR" --json
check "filled" "j['filled']==True"
step 0 "client: asking to fill GitHub on another origin is refused" dev laptop "$VAULT" autofill-client https://example.org --identity-of-tab "$A" --fill "$GH_ID" --socket "$SOCK" --pair-file "$PAIR" --json
check "not filled" "j.get('filled')==False"
cp "$PAIR" "$W/stolen.json"; python3 -I -c "import json,sys; p=json.load(open(sys.argv[1])); p['key']='A'*43+'='; json.dump(p,open(sys.argv[1],'w'))" "$W/stolen.json"
step 8 "client: a forged pairing key is refused" bash -c "'$VAULT' autofill-client https://github.com --identity-of-tab '$A' --socket '$SOCK' --pair-file '$W/stolen.json' --json; e=\$?; [ \$e = 5 ] && exit 8 || exit \$e"
kill $AFPID 2>/dev/null; wait $AFPID 2>/dev/null

echo "== what the server holds"
docker exec "$PALM_DB_CONTAINER" pg_dump -U postgres --data-only \
	-t public.vault_keysets -t public.vault_vaults -t public.vault_items -t public.vault_shares -t public.vault_devices postgres >"$W/dump.sql" 2>/dev/null
rows=$(grep -c . "$W/dump.sql")
echo "     pg_dump of the five vault tables: $(wc -c <"$W/dump.sql") bytes, $rows lines"
leaks=0
for s in "$GH_PW" "$VPN_PW" "github.com" "GitHub" "alice-gh" "Northwind" "northwind" "vpn." "bank.example" "Example Bank" \
	"alice-0042" "branch code" "bw-fixture-pass-Ab12!" "forge.example" "4111111111111111" "fixture-dev" "Personal" "Work" \
	"PV1-" "$(cat "$W/alice.mp")"; do
	n=$(grep -cF -- "$s" "$W/dump.sql")
	if [ "$n" != 0 ]; then leaks=$((leaks + 1)); echo "     LEAK: '$s' appears $n times"; fi
done
if [ $leaks = 0 ]; then pass=$((pass+1)); echo "ok        none of 20 secrets, titles, usernames, URLs or vault names appear in the dump"
else fail=$((fail+1)); echo "FAIL      $leaks plaintext string(s) found in the dump"; fi
echo "     a vault_items row, as the server stores it:"
grep -A1 "COPY public.vault_items" "$W/dump.sql" | tail -1 | cut -c1-200 | sed 's/^/       /'

echo
echo "$pass passed, $fail failed"
[ $fail = 0 ]
