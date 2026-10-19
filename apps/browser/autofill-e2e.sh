#!/usr/bin/env bash
# Autofill end to end with a real account: browser, vault, cloud/dev.
#
#   cloud/dev/up.sh --name autofill --port-base 56521
#   PALM_CLOUD_URL=http://127.0.0.1:56521 \
#     bash apps/browser/autofill-e2e.sh <browser> <vault> <accounts> [chromium] [firefox]
#
# Two "machines", each with its own data and token stores:
#   laptop  alice's account: identities $A (personal) and $AW (work); the
#           vault set up here, served to the browser by `vault autofill`
#           (headless, --allow once: nobody to click)
#   phone   a second device of $A, enrolled by approval; it only reads, to
#           show what the browser saved reached the server
# For each engine: sign up (once), add a login for the local test site, open
# the site in the browser, pair, focus the field, pick the login, submit,
# change the password on the site, accept "Update password", and read the
# new password on the phone after a sync. Then the work identity's browser
# profile asks for the same site and gets nothing, and a fill forced with the
# personal item's id is refused.
set -uo pipefail
BROWSER=$(realpath "${1:?browser}")
VAULT=$(realpath "${2:?vault}")
ACCOUNTS=$(realpath "${3:?accounts}")
shift 3
ENGINES=("$@")
[ ${#ENGINES[@]} = 0 ] && ENGINES=(chromium firefox)
HERE=$(cd "$(dirname "$0")" && pwd)
: "${PALM_CLOUD_URL:=http://127.0.0.1:56521}"
export PALM_CLOUD_URL
unset PALM_IDENTITY PALM_CLOUD_SESSION XDG_DATA_HOME PALM_CLOUD_DIR
W=${AF_WORK:-$(mktemp -d /tmp/palm-autofill-e2e.XXXXXX)}
mkdir -p "$W"
HTTPS=${AF_HTTPS_PORT:-18444}
HTTP=${AF_HTTP_PORT:-18081}
RUN=${XDG_RUNTIME_DIR:-/tmp}/palm-afe-$$
mkdir -p "$RUN"; chmod 700 "$RUN"
pass=0 fail=0
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$RUN"; }
trap cleanup EXIT
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
dev() { local m=$1; shift; mkdir -p "$W/$m/data" "$W/$m/cloud" "$W/$m/config"; env XDG_DATA_HOME="$W/$m/data" PALM_CLOUD_DIR="$W/$m/cloud" XDG_CONFIG_HOME="$W/$m/config" "$@"; }
step() { # want description command...
	local want=$1 what=$2; shift 2
	LAST=$("$@" 2>"$W/stderr"); local code=$?
	if [ "$code" = "$want" ]; then ok "[$code] $what"; else bad "[$code, wanted $want] $what"; sed 's/^/     stderr: /' "$W/stderr" | head -5; fi
}
field() { python3 -I -c "import json,sys; j=json.loads(sys.stdin.read()); print($1)" <<<"$LAST"; }

tag=$(date +%s%N | tail -c 6)
A=alice$tag AW=alicew$tag
printf 'master password %s, autofill' "$tag" >"$W/mp"

# --- the site ----------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" -days 2 -subj /CN=bank.localhost \
	-addext "subjectAltName=DNS:bank.localhost,DNS:evil.localhost,DNS:localhost" >/dev/null 2>&1
B="https://bank.localhost:$HTTPS"
SITELOG="$W/site.log"; : >"$SITELOG"
SITEPID=
site_start() { # the account's password
	[ -n "$SITEPID" ] && { kill "$SITEPID" 2>/dev/null; wait "$SITEPID" 2>/dev/null; }
	python3 -I "$HERE/testdata/autofill/server.py" --https-port "$HTTPS" --http-port "$HTTP" --cert "$W/cert.pem" --key "$W/key.pem" \
		--log "$SITELOG" --account "alice@bank.test:$1" >>"$W/site.out" 2>&1 &
	SITEPID=$!; PIDS+=($SITEPID)
	for _ in $(seq 50); do curl -sk "https://127.0.0.1:$HTTPS/login" -o /dev/null && break; sleep 0.1; done
}

# --- the account, the vault, the second device ---------------------------------
echo "== the account"
step 0 "alice signs up ($A) against $PALM_CLOUD_URL" dev laptop "$ACCOUNTS" signup "$A@example.test" --name "Alice Martin" --handle "$A" --password "account pw $tag" --json
step 0 "alice adds a work identity ($AW)" dev laptop "$ACCOUNTS" create "$AW" --name "Alice (Northwind)" --kind work --color emerald --json
step 0 "laptop: vault setup" dev laptop "$VAULT" setup --password-file "$W/mp" --json
PW0="site-Pass-$tag-0001"
printf '%s' "$PW0" >"$W/s0"
step 0 "laptop: add the bank login to $A's vault" dev laptop "$VAULT" add --title "Loopback Bank" --username alice@bank.test --url "$B" --secret-file "$W/s0" --identity "$A" --password-file "$W/mp" --json
BANK_ID=$(field "j['item']['id']")
step 0 "phone: sign in and take a session scoped to $A" dev phone "$ACCOUNTS" signin "$A@example.test" --password "account pw $tag" --json
step 0 "phone: switch to $A" dev phone "$ACCOUNTS" switch "$A" --json
step 0 "phone: ask to be enrolled" dev phone env PALM_IDENTITY="$A" "$VAULT" enroll --request --identity "$A" --name "Alice's phone" --json
DEV=$(field "j['device_id']"); CODE=$(field "j['code']")
step 0 "laptop: approve the phone with its code" dev laptop "$VAULT" approve "$DEV" --code "$CODE" --json
step 0 "phone: enrolled" dev phone env PALM_IDENTITY="$A" "$VAULT" enroll --wait --json
step 0 "phone: reads the bank login" dev phone env PALM_IDENTITY="$A" "$VAULT" get "Loopback Bank" --field password --password-file "$W/mp"
check "phone: it is the password the laptop saved" "[ \"$LAST\" = '$PW0' ]"

# test mode for the self-signed site: Firefox's BiDi session accepts it,
# Chromium trusts exactly this certificate's public key
export PALM_BROWSER_TEST_CERTS=1
PALM_BROWSER_TEST_SPKI=$(openssl x509 -pubkey -noout -in "$W/cert.pem" | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
export PALM_BROWSER_TEST_SPKI
export PALM_VAULT_BIN=/bin/true # "Open Passwords" must not open a window in a test
SOCK="$RUN/vault.sock"
VPID=
vault_start() {
	[ -n "$VPID" ] && { kill "$VPID" 2>/dev/null; wait "$VPID" 2>/dev/null; }
	rm -f "$SOCK"
	dev laptop "$VAULT" autofill --password-file "$W/mp" --socket "$SOCK" --allow once >/dev/null 2>>"$W/vault.log" &
	VPID=$!; PIDS+=($VPID)
	for _ in $(seq 200); do [ -S "$SOCK" ] && break; sleep 0.05; done
}
run() { # name engine identity url steps...
	local name=$1 engine=$2 ident=$3 url=$4; shift 4
	printf '%s\n' "$@" >"$W/$engine-$name.steps"
	dev laptop env PALM_BROWSER_HOME="$W/browser-$engine" PALM_VAULT_SOCKET="$SOCK" \
		"$BROWSER" autofill-run --identity "$ident" --engine "$engine" --url "$url" --steps-file "$W/$engine-$name.steps" >"$W/$engine-$name.out" 2>"$W/$engine-$name.err"
	local code=$? n_ok n_fail
	n_ok=$(grep -c '^ok ' "$W/$engine-$name.out"); n_fail=$(grep -c '^FAIL' "$W/$engine-$name.out")
	if [ "$code" = 0 ] && [ "$n_fail" = 0 ]; then ok "[$engine] $name ($n_ok checks)"
	else bad "[$engine] $name (exit $code)"; grep -v '^#' "$W/$engine-$name.out" | sed 's/^/       /'; grep -h '^#       ' "$W/$engine-$name.out" | tail -12 | sed 's/^/     /'; fi
}
site() { python3 -I -c "
import json,sys
L=[json.loads(x) for x in open(sys.argv[1]).read().splitlines()[int(sys.argv[2]):]]
sys.exit(0 if ($2) else 1)" "$SITELOG" "$1" 2>/dev/null; }

CUR=$PW0
USED=("$PW0")
n=0
for E in "${ENGINES[@]}"; do
	n=$((n + 1))
	echo "== $E"
	NEW="changed-$E-$tag-000$n"
	site_start "$CUR"
	vault_start
	M=$(wc -l <"$SITELOG")
	run flow "$E" "$A" "$B/login" \
		"wait-focus username" "wait-state unpaired" "key Down" "wait-open" "key Return" "wait-state unlocked" \
		"key Down" "shot $W/$E-dropdown.png" "key Return" "wait-vault-fill allowed" "wait-fill ok" "key Return" "sleep 1.5" "expect-no-bar" \
		"navigate $B/change" "wait-focus password" "key Down" "wait-open" "key Return" "wait-fill ok" \
		"key Tab" "type $NEW" "key Tab" "type $NEW" "key Return" \
		"wait-bar update" "shot $W/$E-bar.png" "key Return" "wait-saved updated"
	check "[$E] the site signed alice in with the filled password" "site $M \"any(r['kind']=='signin' and r['ok'] for r in L)\""
	check "[$E] the site changed the password" "site $M \"any(r['kind']=='changed' and r['ok'] for r in L)\""
	step 0 "[$E] laptop: the vault item has the new password" dev laptop "$VAULT" get "Loopback Bank" --field password --offline --password-file "$W/mp"
	check "[$E] ... it is $NEW" "[ \"$LAST\" = '$NEW' ]"
	step 0 "[$E] phone: sync" dev phone env PALM_IDENTITY="$A" "$VAULT" sync --password-file "$W/mp" --json
	step 0 "[$E] phone: read the bank login" dev phone env PALM_IDENTITY="$A" "$VAULT" get "Loopback Bank" --field password --offline --password-file "$W/mp"
	check "[$E] the phone has the password the browser updated" "[ \"$LAST\" = '$NEW' ]"
	CUR=$NEW
	USED+=("$NEW")

	# the work identity's profile, same site: nothing offered, nothing filled
	run work "$E" "$AW" "$B/login" \
		"wait-focus username" "wait-state unpaired" "key Down" "wait-open" "key Return" "wait-state unlocked" \
		"expect-rows 0" "force-fill id:$BANK_ID" "wait-vault-fill refused" "expect-trace another identity"
done

echo "== profiles"
for E in "${ENGINES[@]}"; do
	for secret in "${USED[@]}"; do
		hits=$(grep -rlaF -- "$secret" "$W/browser-$E" 2>/dev/null)
		if [ -z "$hits" ]; then ok "[$E] '$secret' is in no file of the browser profile"
		else bad "[$E] '$secret' found in: $hits"; fi
	done
done
echo
echo "autofill e2e: $pass passed, $fail failed  (work dir $W; identities $A, $AW)"
[ "$fail" = 0 ]
