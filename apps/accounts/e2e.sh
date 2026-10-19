#!/usr/bin/env bash
# The accounts CLI end to end against a running cloud/dev stack, in a
# throwaway token store. Prints each step's command, exit code and JSON.
#
#   bash apps/accounts/e2e.sh [path/to/accounts.bin]
set -uo pipefail
bin=${1:-$(dirname "$0")/accounts.bin}
export PALM_CLOUD_DIR=$(mktemp -d /tmp/accounts-e2e.XXXXXX)
trap 'rm -rf "$PALM_CLOUD_DIR"' EXIT
unset PALM_IDENTITY
tag=$(date +%s%N | tail -c 7)
pass=0 fail=0

step() { # want-exit description command...
	local want=$1 what=$2; shift 2
	local out code
	out=$("$@" 2>&1); code=$?
	if [ "$code" = "$want" ]; then pass=$((pass + 1)); echo "ok   [$code] $what"
	else fail=$((fail + 1)); echo "FAIL [$code, wanted $want] $what"; fi
	printf '     %s\n' "$(tr -d '\n' <<<"$out" | tr -s ' ' | cut -c1-220)"
}

step 0 "signup creates the account and its first identity" \
	"$bin" signup "e2e$tag@palm.test" --name "Alex Rivera" --handle "alex$tag" --password "e2e password $tag" --json
step 0 "create a work identity" \
	"$bin" create "work$tag" --name "Alex at Northwind" --kind work --color sky --json
step 0 "list shows both" "$bin" list --json
step 0 "switch to work: a scoped session is stored" "$bin" switch "work$tag" --json
step 0 "PALM_IDENTITY=work: list sees work alone" env PALM_IDENTITY="work$tag" "$bin" list --json
step 0 "PALM_IDENTITY=work: whoami says scoped" env PALM_IDENTITY="work$tag" "$bin" whoami --json
step 5 "PALM_IDENTITY=work: creating an identity is refused (exit 5)" \
	env PALM_IDENTITY="work$tag" "$bin" create "x$tag" --name X --json
step 3 "PALM_IDENTITY=work: the personal identity does not exist for it (exit 3)" \
	env PALM_IDENTITY="work$tag" "$bin" rename "alex$tag" "Hacked" --json
step 5 "PALM_IDENTITY=work --identity alex: widening is refused by the kit (exit 5)" \
	env PALM_IDENTITY="work$tag" "$bin" list --identity "alex$tag" --json
step 5 "--identity alex with no session stored for it: refused, no fallback" \
	"$bin" list --identity "alex$tag" --json
step 0 "delegate an assistant to work" \
	"$bin" delegate "work$tag" --name "Mail assistant" --kind assistant --expires 3600 --json
held=$(ls "$PALM_CLOUD_DIR"/delegated/*.json 2>/dev/null | head -1)
step 0 "the assistant, holding PALM_CLOUD_SESSION, is scoped to work" \
	env PALM_CLOUD_SESSION="$held" "$bin" whoami --json
step 5 "PALM_CLOUD_SESSION cannot be pointed at the person's own session" \
	env PALM_CLOUD_SESSION="$PALM_CLOUD_DIR/session.json" "$bin" list --json
step 5 "PALM_CLOUD_SESSION with a different PALM_IDENTITY is refused" \
	env PALM_CLOUD_SESSION="$held" PALM_IDENTITY="alex$tag" "$bin" list --json
step 0 "devices lists it" "$bin" devices --json
step 0 "sessions lists the account's sessions" "$bin" sessions --json
step 4 "revoke without --yes is refused (exit 4)" "$bin" revoke "Mail assistant" --json
step 0 "revoke --yes" "$bin" revoke "Mail assistant" --yes --json
step 7 "the revoked assistant is refused, and its file is gone" \
	env PALM_CLOUD_SESSION="$held" "$bin" list --json
step 0 "this machine's own work session (from switch) still works" env PALM_IDENTITY="work$tag" "$bin" list --json
step 0 "rename (the handle stays)" "$bin" rename "work$tag" "Alex, Northwind" --json
step 4 "archive without --yes is refused" "$bin" archive "work$tag" --json
step 0 "archive --yes" "$bin" archive "work$tag" --yes --json
step 0 "restore" "$bin" restore "work$tag" --json
step 0 "signout" "$bin" signout --json
step 7 "list when signed out fails with a reason" "$bin" list --json
step 0 "signin" env PALM_CLOUD_PASSWORD="e2e password $tag" "$bin" signin "e2e$tag@palm.test" --json
step 7 "a wrong password is refused" "$bin" signin "e2e$tag@palm.test" --password nope-nope-nope --json
"$bin" signout --json >/dev/null 2>&1
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
