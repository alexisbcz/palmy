#!/usr/bin/env bash
# Two people and three identities on the dev stack:
#
#   alice@example.test (password palm-dev-alice) owns
#       alice       personal   alice@palm.test
#       alice.work  work       alice.work@palm.test
#   bob@example.test   (password palm-dev-bob) owns
#       bob         personal   bob@palm.test
#
# Sign-up goes through GoTrue; identities are created through PostgREST with
# each person's own token, under the contract's identities_insert policy.
# Idempotent: existing users and identities are left as they are.
#
# Writes the access tokens to $PALM_MAIL_STATE (default /tmp/palm-mail-dev).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
STATE=${PALM_MAIL_STATE:-/tmp/palm-mail-dev}
mkdir -p "$STATE"
chmod 700 "$STATE"
AUTH=http://127.0.0.1:$PALM_AUTH_PORT
REST=http://127.0.0.1:$PALM_REST_PORT

json() { python3 -I -c "import json,sys; print(json.load(sys.stdin)$1)"; }

token_for() {
	local who=$1
	curl -sf -X POST "$AUTH/signup" -H 'Content-Type: application/json' \
		-d "{\"email\":\"$who@example.test\",\"password\":\"palm-dev-$who\"}" >/dev/null 2>&1 || true
	curl -sf -X POST "$AUTH/token?grant_type=password" -H 'Content-Type: application/json' \
		-d "{\"email\":\"$who@example.test\",\"password\":\"palm-dev-$who\"}" | json "['access_token']"
}

identity() {
	local tok=$1 handle=$2 name=$3 kind=$4 color=$5
	local uid
	uid=$(python3 -I -c "import base64,json,sys; p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p))['sub'])" "$tok")
	curl -s -X POST "$REST/identities" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
		-H 'Prefer: return=minimal' \
		-d "{\"owner\":\"$uid\",\"handle\":\"$handle\",\"display_name\":\"$name\",\"kind\":\"$kind\",\"color\":\"$color\"}" >/dev/null
	curl -sf "$REST/identities?handle=eq.$handle&select=id" -H "Authorization: Bearer $tok" | json "[0]['id']"
}

ALICE=$(token_for alice)
BOB=$(token_for bob)
echo "$ALICE" > "$STATE/alice.token"
echo "$BOB" > "$STATE/bob.token"
identity "$ALICE" alice "Alice Martin" personal indigo > "$STATE/alice.id"
identity "$ALICE" alice.work "Alice Martin (Acme)" work emerald > "$STATE/alice.work.id"
identity "$BOB" bob "Bob Lefèvre" personal amber > "$STATE/bob.id"
echo "people: alice (alice@palm.test, alice.work@palm.test), bob (bob@palm.test); tokens in $STATE"
