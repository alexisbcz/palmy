#!/usr/bin/env bash
# Autofill between apps/browser and apps/vault, for real, on both engines:
# the security cases and the fill-submit-update flow against a local vault.
#
#   apps/browser/autofill-test.sh <browser> <vault> [chromium] [firefox]
#
# Needs: the engines (palm-browser-cef beside <browser>, or
# PALM_BROWSER_CEF_HOST; Firefox at PALM_BROWSER_FIREFOX), python3, openssl.
# Nothing leaves loopback: the site is testdata/autofill/server.py on
# https://bank.localhost:$PORT (and evil.localhost, the lookalike
# bank.localhost.evil.localhost, and plain http on another port), with a
# self-signed certificate the engines accept only because
# PALM_BROWSER_TEST_CERTS=1 says so, and only for loopback hosts.
#
# The vault is a throwaway local vault served headless by
# `vault autofill --allow once` (nobody to click, so "yes"), plus a second
# server that holds every answer for 2.5 s (the page moves meanwhile), a
# locked one, and none at all. Every step prints ok/FAIL; the last line is
# the count. Ends by searching every engine profile for every password used.
set -uo pipefail
BROWSER=$(realpath "${1:?path to the browser binary}")
VAULT=$(realpath "${2:?path to the vault binary}")
shift 2
ENGINES=("$@")
[ ${#ENGINES[@]} = 0 ] && ENGINES=(chromium firefox)
HERE=$(cd "$(dirname "$0")" && pwd)
W=${AF_WORK:-$(mktemp -d /tmp/palm-autofill.XXXXXX)}
mkdir -p "$W"
HTTPS=${AF_HTTPS_PORT:-18443}
HTTP=${AF_HTTP_PORT:-18080}
RUN=${XDG_RUNTIME_DIR:-/tmp}/palm-af-$$
mkdir -p "$RUN"; chmod 700 "$RUN"
pass=0 fail=0
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$RUN"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- the site --------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" -days 2 -subj /CN=bank.localhost \
	-addext "subjectAltName=DNS:bank.localhost,DNS:evil.localhost,DNS:bank.localhost.evil.localhost,DNS:localhost" >/dev/null 2>&1
PW1="first-Pass-$RANDOM-0042"   # the site's password, and the vault's
PW2="changed-Pass-$RANDOM-0777" # what the person changes it to
PWB="bobs-typed-Pass-$RANDOM"   # typed by hand for an account the vault lacks
SITELOG="$W/site.log"; : >"$SITELOG"
python3 -I "$HERE/testdata/autofill/server.py" --https-port "$HTTPS" --http-port "$HTTP" --cert "$W/cert.pem" --key "$W/key.pem" \
	--log "$SITELOG" --account "alice@bank.test:$PW1" >"$W/site.out" 2>&1 &
SITEPID=$!
PIDS+=($SITEPID)
B="https://bank.localhost:$HTTPS"
for _ in $(seq 50); do curl -sk "https://127.0.0.1:$HTTPS/login" -o /dev/null && break; sleep 0.1; done

# --- the vault -------------------------------------------------------------
export XDG_DATA_HOME="$W/vault-data"
mkdir -p "$XDG_DATA_HOME"
"$VAULT" --make-demo-vault="$W/local.pvz" >/dev/null
printf 'demo-vault-not-a-real-password' >"$W/mp"
printf '%s' "$PW1" >"$W/s1"
VF=(--local --vault-file "$W/local.pvz" --password-file "$W/mp")
"$VAULT" add "${VF[@]}" --title "Loopback Bank" --username alice@bank.test --url "$B" --secret-file "$W/s1" --json >"$W/add.json"
BANK_ID=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['item']['id'])" "$W/add.json")
serve() { # socket extra-flags...
	local sock=$1; shift
	"$VAULT" autofill "${VF[@]}" --socket "$sock" "$@" >/dev/null 2>>"$W/vault.log" &
	PIDS+=($!)
	for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.05; done
}
# the servers hold the vault in memory: started afresh for each engine
VPIDS=()
start_vaults() {
	local n=${#PIDS[@]}
	serve "$RUN/once.sock" --allow once
	serve "$RUN/slow.sock" --allow once --delay 2500
	serve "$RUN/locked.sock" --locked
	VPIDS=("${PIDS[@]:$n}")
}
stop_vaults() { for p in "${VPIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -f "$RUN"/*.sock; }

# test mode for the self-signed site: Firefox's BiDi session accepts it,
# Chromium trusts exactly this certificate's public key
export PALM_BROWSER_TEST_CERTS=1
PALM_BROWSER_TEST_SPKI=$(openssl x509 -pubkey -noout -in "$W/cert.pem" | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
export PALM_BROWSER_TEST_SPKI
export PALM_VAULT_BIN=/bin/true # "Open Passwords" must not open a window in a test
unset PALM_IDENTITY PALM_CLOUD_SESSION

# run <name> <engine> <socket> <url> <steps...>: one window, one script
run() {
	local name=$1 engine=$2 sock=$3 url=$4; shift 4
	printf '%s\n' "$@" >"$W/$engine-$name.steps"
	env PALM_BROWSER_HOME="$W/browser-$engine" PALM_VAULT_SOCKET="$sock" \
		"$BROWSER" autofill-run --engine "$engine" --url "$url" --steps-file "$W/$engine-$name.steps" >"$W/$engine-$name.out" 2>"$W/$engine-$name.err"
	local code=$?
	local n_ok n_fail
	n_ok=$(grep -c '^ok ' "$W/$engine-$name.out"); n_fail=$(grep -c '^FAIL' "$W/$engine-$name.out")
	if [ "$code" = 0 ] && [ "$n_fail" = 0 ]; then ok "[$engine] $name ($n_ok checks)"
	else bad "[$engine] $name (exit $code)"; sed 's/^/       /' "$W/$engine-$name.out" | grep -v '^       #' ; grep -h '^#       ' "$W/$engine-$name.out" | tail -12 | sed 's/^/     /'; fi
}
# site <python expression over L, the log's records since mark M>
mark() { wc -l <"$SITELOG"; }
site() { python3 -I -c "
import json,sys
L=[json.loads(x) for x in open(sys.argv[1]).read().splitlines()[int(sys.argv[2]):]]
sys.exit(0 if ($2) else 1)" "$SITELOG" "$1" 2>/dev/null; }
stamp() { grep "^# stamp $2 " "$W/$1.out" | awk '{print $4}'; }

for E in "${ENGINES[@]}"; do
	echo "== $E"
	rm -rf "$W/browser-$E"
	start_vaults

	# 1. first use: no pairing. The dropdown offers to connect; the code is
	#    shown in the browser and the vault (here: --allow once) confirms.
	run pair "$E" "$RUN/once.sock" "$B/login" \
		"wait-focus username" "wait-state unpaired" "key Down" "wait-open" "expect-rows 0" \
		"key Return" "wait-state unlocked" "expect-trace pairing: code" "expect-trace pairing: paired"
	check "[$E] the pairing is kept in the profile, 0600" "[ \"\$(stat -c %a '$W/browser-$E/personal/vault-pair.json' 2>/dev/null)\" = 600 ]"
	# every server reads the pairings when it starts: let the others see this one
	stop_vaults; start_vaults

	# 2. fill and sign in. The page reads its fields every 40 ms and beacons
	#    whatever it sees: nothing may arrive before the person picks.
	M=$(mark)
	run fill "$E" "$RUN/once.sock" "$B/leak" \
		"wait-focus username" "key Down" "wait-open" "expect-rows 1" "sleep 1.5" "stamp picked" \
		"key Return" "wait-vault-fill allowed" "wait-fill ok" "sleep 0.5" "key Return" "sleep 2" "expect-no-bar"
	T=$(stamp "$E-fill" picked)
	check "[$E] the page read nothing before the pick" "site $M \"not [r for r in L if r['kind']=='beacon' and r['what'] in ('username','password') and r['t'] < $T]\""
	check "[$E] ... and the filled values after it" "site $M \"any(r['kind']=='beacon' and r['what']=='password' and r['value']=='$PW1' for r in L)\""
	check "[$E] the page sees no autofill globals" "site $M \"any(r['kind']=='beacon' and r['what']=='globals' and r['value']=='[]' for r in L)\""
	check "[$E] the filled form signed in (submitted from the page's own fields)" "site $M \"any(r['kind']=='signin' and r['ok'] and r['user']=='alice@bank.test' for r in L)\""

	# 3. React-style controlled inputs see the fill (state updated by the input event)
	M=$(mark)
	run react "$E" "$RUN/once.sock" "$B/react" \
		"wait-focus username" "key Down" "wait-open" "key Return" "wait-fill ok" "sleep 0.3" "key Return" "sleep 2"
	check "[$E] React-style state got the filled values" "site $M \"any(r['kind']=='signin' and r['path']=='/react-login' and r['ok'] for r in L)\""

	# 4. a lookalike host and plain http get nothing, and a fill forced
	#    with the bank's id is refused by the vault
	run lookalike "$E" "$RUN/once.sock" "https://bank.localhost.evil.localhost:$HTTPS/login" \
		"wait-focus username" "key Down" "wait-open" "expect-rows 0" "force-fill id:$BANK_ID" "wait-vault-fill refused"
	run http "$E" "$RUN/once.sock" "http://bank.localhost:$HTTP/login" \
		"wait-focus username" "key Down" "wait-open" "expect-rows 0" "force-fill id:$BANK_ID" "wait-vault-fill refused"

	# 5. a cross-origin iframe: its focused login field is never reported,
	#    and "Fill login" from the address bar finds no field in the top page
	M=$(mark)
	run iframe "$E" "$RUN/once.sock" "$B/frame" \
		"sleep 3" "expect-no-trace focus" "expect-closed"
	check "[$E] the framed attacker's page got no post or beacon" "site $M \"not [r for r in L if r['origin'].startswith('https://evil.') and r['kind'] in ('post','beacon')]\""

	# 6. the form's action moves to another origin when a field is focused:
	#    the fill is refused, and what the page then posts carries nothing
	M=$(mark)
	run swap "$E" "$RUN/once.sock" "$B/swap" \
		"wait-focus username" "key Down" "wait-open" "key Return" "wait-vault-fill allowed" "wait-fill form_action" "key Return" "sleep 2"
	check "[$E] nothing filled reached the attacker" "site $M \"all(not r.get('form',{}).get('password') for r in L if r['kind']=='post')\""

	# 7. the page navigates to another origin while the vault is asking: the
	#    engine host drops the fill
	M=$(mark)
	run moved "$E" "$RUN/slow.sock" "$B/login" \
		"wait-focus username" "key Down" "wait-open" "key Return" "navigate https://evil.localhost:$HTTPS/leak" \
		"wait-vault-fill allowed" "wait-fill origin_changed" "sleep 1"
	check "[$E] the other origin saw no filled value" "site $M \"not [r for r in L if r['kind']=='beacon' and r['what'] in ('username','password')]\""

	# 8. locked, not running, and a forged pairing
	run locked "$E" "$RUN/locked.sock" "$B/login" \
		"wait-focus username" "wait-state locked" "key Down" "wait-open" "expect-rows 0" "force-fill id:$BANK_ID" "wait-vault-fill refused"
	run absent "$E" "$RUN/nobody.sock" "$B/login" \
		"wait-focus username" "wait-state not_running" "key Down" "wait-open" "expect-rows 0"
	cp -r "$W/browser-$E/personal" "$W/browser-$E/forged"
	python3 -I -c "import json,sys,base64,os; p=json.load(open(sys.argv[1])); p['key']=base64.b64encode(os.urandom(32)).decode(); json.dump(p,open(sys.argv[1],'w'))" "$W/browser-$E/forged/vault-pair.json"
	env PALM_BROWSER_HOME="$W/browser-$E" PALM_VAULT_SOCKET="$RUN/once.sock" "$BROWSER" autofill-run --identity forged --engine "$E" --url "$B/login" \
		--steps "wait-focus username;wait-state unpaired;key Down;wait-open;expect-rows 0" >"$W/$E-forged.out" 2>&1 \
		&& ok "[$E] forged pairing key: unpaired, nothing offered" || { bad "[$E] forged pairing key"; cat "$W/$E-forged.out"; }

	# 9. change the password on the site; the bar offers to update the login
	run change "$E" "$RUN/once.sock" "$B/login" \
		"wait-focus username" "key Down" "wait-open" "key Return" "wait-fill ok" "key Return" "sleep 1.5" \
		"navigate $B/change" "wait-focus password" "key Down" "wait-open" "key Return" "wait-fill ok" \
		"key Tab" "type $PW2" "key Tab" "type $PW2" "key Return" \
		"wait-bar update" "key Return" "wait-saved updated"
	GOT=$("$VAULT" get "Loopback Bank" "${VF[@]}" --field password 2>/dev/null)
	check "[$E] the vault holds the new password" "[ \"$GOT\" = '$PW2' ]"
	check "[$E] the site changed it" "site 0 \"any(r['kind']=='changed' and r['ok'] for r in L)\""
	# put things back for the other engine
	stop_vaults
	printf '%s' "$PW1" >"$W/s1"
	"$VAULT" edit "Loopback Bank" "${VF[@]}" --secret-file "$W/s1" --json >/dev/null 2>&1
	start_vaults
	kill "$SITEPID" 2>/dev/null; wait "$SITEPID" 2>/dev/null
	python3 -I "$HERE/testdata/autofill/server.py" --https-port "$HTTPS" --http-port "$HTTP" --cert "$W/cert.pem" --key "$W/key.pem" \
		--log "$SITELOG" --account "alice@bank.test:$PW1" >>"$W/site.out" 2>&1 &
	SITEPID=$!
	PIDS+=($SITEPID)
	for _ in $(seq 50); do curl -sk "https://127.0.0.1:$HTTPS/login" -o /dev/null && break; sleep 0.1; done

	# 10. a login the vault does not have, typed by hand: "Save this login?",
	#     and "Not now" keeps nothing
	run typed "$E" "$RUN/once.sock" "$B/login" \
		"wait-focus username" "key Escape" "type bob@bank.test" "key Tab" "type $PWB" "key Return" \
		"wait-bar save" "key Escape" "expect-no-bar"
	check "[$E] Not now saved nothing" "! '$VAULT' list ${VF[*]} --json 2>/dev/null | grep -q 'bob@bank.test'"
	stop_vaults
done

# --- no credential in any engine profile ------------------------------------
echo "== profiles"
for E in "${ENGINES[@]}"; do
	D="$W/browser-$E"
	[ -d "$D" ] || continue
	for s in "$PW1" "$PW2" "$PWB"; do
		hits=$(grep -rlaF -- "$s" "$D" 2>/dev/null | grep -v '\.steps$')
		check "[$E] '$s' appears in no file of the profile" "[ -z \"$hits\" ]"
		[ -n "$hits" ] && echo "$hits" | sed 's/^/       /'
	done
	u=$(grep -rlaF -- "alice@bank.test" "$D" 2>/dev/null | grep -v '\.steps$' | wc -l)
	echo "     (the username alice@bank.test appears in $u file(s) of the $E profile)"
done

echo
echo "autofill: $pass passed, $fail failed  (work dir $W)"
[ "$fail" = 0 ]
