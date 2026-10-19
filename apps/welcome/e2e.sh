#!/usr/bin/env bash
# The first run end to end, against a running cloud/dev stack, as fresh
# users in throwaway homes. Three runs:
#
#   1. the window, offscreen, typed into: account, two identities, drive,
#      a vault with its Emergency Kit, mail (welcome drive)
#   2. the same without a window (welcome setup), then the session.d hook
#      that starts the drive daemons
#   3. this computer only: nothing is contacted, the marker says "local"
#
# and checks what each left behind with the services' own command lines.
#
#   cloud/dev/up.sh --name onboarding --port-base 51521
#   bash apps/welcome/e2e.sh --port-base 51521 [--shots DIR] [--keep]
#
# The mail server (cloud/mail, palm-maild) is started here on base+70..72,
# against the stack's PostgREST and GoTrue. Nothing touches the real HOME.
#
# Notes sync needs `notes sync` and the sync server palm-collab. When this
# tree has them (or WELCOME_E2E_NOTES_TREE names a tree that does), notes
# and palm-collab are built from it, the server runs on base+75, and the
# notes task is checked too; without them it must say "Coming".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE=54321
SHOTS=""
KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--port-base) BASE=$2; shift ;;
	--shots) SHOTS=$2; shift ;;
	--keep) KEEP=1 ;;
	*) echo "e2e.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
WORK=$(mktemp -d /tmp/welcome-e2e.XXXXXX)
BIN=${WELCOME_E2E_BIN:-$WORK/bin}
MAILD=""
COLLAB=""
cleanup() {
	[ -n "$MAILD" ] && kill "$MAILD" 2>/dev/null
	[ -n "$COLLAB" ] && kill "$COLLAB" 2>/dev/null
	pkill -f "$WORK/" 2>/dev/null
	[ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { # description, command...
	local what=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$what"; else no "$what"; fi
}

# --- build every program the welcome runs ------------------------------------
if [ -z "${WELCOME_E2E_BIN:-}" ]; then
	mkdir -p "$BIN"
	COLL=(-collection:palmy="$ROOT/palmy" -collection:kit="$ROOT/apps/kit" -collection:shadcn="$ROOT/shadcn" -collection:drive="$ROOT/cloud/drive")
	for a in welcome accounts vault calendar contacts notes chat drive; do
		odin build "$ROOT/apps/$a" "${COLL[@]}" -out:"$BIN/$a" >"$WORK/build-$a.log" 2>&1 || echo "build $a failed: $WORK/build-$a.log"
	done
	odin build "$ROOT/cloud/drive/palm-drive" "${COLL[@]}" -out:"$BIN/palm-drive" >"$WORK/build-palm-drive.log" 2>&1 || echo "build palm-drive failed"
	odin build "$ROOT/apps/mailcore" -out:"$BIN/mailcore" >"$WORK/build-mailcore.log" 2>&1 || echo "build mailcore failed"
	odin build "$ROOT/cloud/mail" -out:"$BIN/palm-maild" >"$WORK/build-maild.log" 2>&1 || echo "build palm-maild failed"
	NT="${WELCOME_E2E_NOTES_TREE:-$ROOT}"
	if [ -d "$NT/cloud/collab/server" ] && grep -q 'verb = "sync"' "$NT/apps/notes/cli.odin" 2>/dev/null; then
		NC=(-collection:palmy="$NT/palmy" -collection:kit="$NT/apps/kit" -collection:shadcn="$NT/shadcn")
		odin build "$NT/apps/notes" "${NC[@]}" -out:"$BIN/notes" >"$WORK/build-notes.log" 2>&1 || echo "build notes ($NT) failed"
		odin build "$NT/cloud/collab/server" -o:speed -out:"$BIN/palm-collab" >"$WORK/build-collab.log" 2>&1 || echo "build palm-collab failed"
	fi
fi
echo "binaries: $(ls "$BIN" | tr '\n' ' ')"

# --- the mail server, on this stack --------------------------------------------
export PALM_JWT_SECRET=super-secret-jwt-token-with-at-least-32-characters-long
PALM_REST_PORT=$((BASE + 11)) PALM_AUTH_PORT=$((BASE + 10)) \
PALM_SMTP_PORT=$((BASE + 70)) PALM_SUBMIT_PORT=$((BASE + 71)) PALM_JMAP_PORT=$((BASE + 72)) \
PALM_MAIL_DOMAIN=palm.test "$BIN/palm-maild" serve >"$WORK/maild.log" 2>&1 &
MAILD=$!
if [ -x "$BIN/palm-collab" ]; then
	PALM_CLOUD_URL="http://127.0.0.1:$BASE" \
	PALM_COLLAB_SERVICE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU \
	"$BIN/palm-collab" --port $((BASE + 75)) >"$WORK/collab.log" 2>&1 &
	COLLAB=$!
fi
sleep 1

fresh_home() { # name
	local h="$WORK/$1"
	mkdir -p "$h"
	echo "$h"
}

# The environment of a fresh person: their own HOME and nothing else of ours.
as() { # home, command...
	local h=$1; shift
	env -i HOME="$h" PATH="$BIN:/usr/bin:/bin" XDG_RUNTIME_DIR="$h/.run" \
		PALM_CLOUD_URL="http://127.0.0.1:$BASE" PALM_LOCALE_DIR="$ROOT/distro/locale" \
		PALM_MAIL_JMAP_PORT=$((BASE + 72)) PALM_MAIL_SUBMIT_PORT=$((BASE + 71)) \
		PALM_COLLAB_URL="ws://127.0.0.1:$((BASE + 75))" \
		WELCOME_BIN_DIR="$BIN" "$@"
}

tag=$(date +%s%N | tail -c 6)

# --- 1. the window, typed into -----------------------------------------------------
echo "== 1. the window, offscreen, typed into"
H1=$(fresh_home gui)
mkdir -p "$H1/.run" && chmod 700 "$H1/.run"
E1="gui$tag@example.org"
out=$(as "$H1" welcome drive --email "$E1" ${SHOTS:+--shots "$SHOTS/account"} --json 2>"$WORK/drive.err")
code=$?
echo "     $out"
sed 's/^/     /' "$WORK/drive.err"
[ "$code" = 0 ] && ok "every page reached by keys, Done pressed" || no "the window run stopped: $out"
check "the marker says account" grep -q '"mode":"account"' "$H1/.local/state/palm/welcome/done"
st=$(as "$H1" welcome status --json)
echo "     status: $st"
check "welcome status: done, signed in" jq -e '.done and .signed_in' <<<"$st"
ids=$(as "$H1" accounts list --json)
echo "     accounts list: $(echo "$ids" | head -c 400)"
check "the account has two identities" jq -e '.count == 2' <<<"$ids"
check "gui$tag and gui$tag.northwind exist" jq -e --arg a "gui$tag" '[.identities[].handle] | (index($a) != null) and (index($a + ".northwind") != null)' <<<"$ids"
check "sync.conf lists both" sh -c "grep -c '^handle = gui$tag' '$H1/.config/palm/sync.conf' | grep -q 2"
check "a session scoped to each identity is stored" sh -c "test -f '$H1/.local/share/palm/cloud/scoped/gui$tag.json' && test -f '$H1/.local/share/palm/cloud/scoped/gui$tag.northwind.json'"
check "~/Drive/gui$tag exists" test -d "$H1/Drive/gui$tag"
echo "hello from the welcome e2e" >"$H1/Drive/gui$tag/hello.txt"
as "$H1" env PALM_IDENTITY="gui$tag" palm-drive sync --json >"$WORK/drive-sync.json" 2>&1
ls1=$(as "$H1" env PALM_IDENTITY="gui$tag" drive ls --json 2>&1)
check "a file put in ~/Drive/gui$tag reaches the server" grep -q hello.txt <<<"$ls1"
ls2=$(as "$H1" env PALM_IDENTITY="gui$tag.northwind" drive ls --json 2>&1)
check "and the work identity's drive does not see it" sh -c "! grep -q hello.txt <<'EOF'
$ls2
EOF"
vs=$(as "$H1" vault status --json 2>&1)
echo "     vault status: $vs"
check "the vault is enrolled on this computer" jq -e '.enrolled' <<<"$vs"
check "the Emergency Kit was saved (PNG and text)" sh -c "test -s '$H1/Documents/Palmy Emergency Kit.png' && grep -q 'PV1-' '$H1/Documents/Palmy Emergency Kit.txt'"
check "the kit is readable by its owner only" sh -c "stat -c %a '$H1/Documents/Palmy Emergency Kit.txt' | grep -q '^600$'"
check "mail: palmy.conf names both identities" sh -c "grep -q 'handle = gui$tag$' '$H1/.local/share/palmy-mail/palmy.conf' && grep -q 'handle = gui$tag.northwind' '$H1/.local/share/palmy-mail/palmy.conf'"
check "mail: a Maildir per address" sh -c "test -d '$H1/.local/share/palmy-mail/gui$tag@palm.test' && test -d '$H1/.local/share/palmy-mail/gui$tag.northwind@palm.test'"
if [ -n "$COLLAB" ]; then
	check "notes: ~/Notes/gui$tag exists after the first sync" test -d "$H1/Notes/gui$tag"
	ns=$(as "$H1" env PALM_IDENTITY="gui$tag" notes status --json 2>&1)
	echo "     notes status: $(tr -d '\n' <<<"$ns" | head -c 300)"
	check "notes: status answers for gui$tag" jq -e . <<<"$ns"
	check "notes: the work identity was not given notes" test ! -d "$H1/Notes/gui$tag.northwind"
else
	check "notes: no sync verb here, the task says Coming" grep -q "Notes .*Coming" "$WORK/drive.err"
fi
[ -n "$SHOTS" ] && cp "$H1/Documents/Palmy Emergency Kit.png" "$SHOTS/account/emergency-kit.png" 2>/dev/null

# --- 2. the same without a window -------------------------------------------------------
echo "== 2. welcome setup, and the session.d hook"
H2=$(fresh_home cli)
mkdir -p "$H2/.run" && chmod 700 "$H2/.run"
printf 'pw cli %s correct horse' "$tag" >"$WORK/pw"
printf 'vault cli %s battery staple' "$tag" >"$WORK/vpw"
out=$(as "$H2" welcome setup --create --email "cli$tag@example.org" --name "Cli $tag" --password-file "$WORK/pw" \
	--identities "cli$tag:personal:teal:Cli $tag;cli$tag.work:work:blue:Cli at Work" \
	--sync "cli$tag=mail,drive,passwords;cli$tag.work=drive,calendar" \
	--vault-password-file "$WORK/vpw" --kit-dir "$H2/kit" --finish --json 2>&1)
code=$?
echo "     $(echo "$out" | head -c 900)"
[ "$code" = 0 ] && ok "welcome setup exits 0" || no "welcome setup exited $code"
check "setup: both identities created" jq -e '[.identities[] | select(.created and (.error == null))] | length == 2' <<<"$out"
check "setup: the drive task is Done for both" jq -e '[.tasks[] | select(.task == "Drive" and .state == "Done")] | length == 2' <<<"$out"
check "setup: the kit was written where asked" test -s "$H2/kit/Palmy Emergency Kit.png"
check "setup: work has no mailbox task (mail not chosen)" jq -e --arg w "cli$tag.work" '[.tasks[] | select(.identity == $w and .task == "Mailbox")] | length == 0' <<<"$out"
# The hook, as palm-login runs it: as the user, with the session's environment.
mkdir -p "$WORK/hook-bin"
as "$H2" sh "$ROOT/distro/base/root/etc/palm/session.d/60-palm-drive" &
HOOK=$!
sleep 3
n=$(pgrep -f "palm-drive watch" -u "$(id -u)" | while read -r p; do tr '\0' '\n' </proc/$p/environ 2>/dev/null | grep -q "^HOME=$H2$" && echo "$p"; done | wc -l)
[ "$n" = 2 ] && ok "60-palm-drive started one palm-drive watch per drive identity" || no "60-palm-drive started $n watchers, wanted 2"
pkill -f "palm-drive watch" -u "$(id -u)" 2>/dev/null; kill "$HOOK" 2>/dev/null
st2=$(as "$H2" welcome status --json)
check "status lists cli$tag with mail, drive, passwords" jq -e --arg h "cli$tag" '.identities[] | select(.handle == $h) | .services == ["mail","drive","passwords"]' <<<"$st2"
as "$H2" welcome reset --json >/dev/null 2>&1
check "reset without --yes is refused (exit 4)" test $? = 4
r=$(as "$H2" welcome reset --yes --json)
check "reset --yes removes the marker" sh -c "jq -e .removed >/dev/null <<'EOF' && test ! -e '$H2/.local/state/palm/welcome/done'
$r
EOF"
as "$H2" env PALM_WELCOME_WAIT=2 sh "$ROOT/distro/base/root/etc/palm/session.d/90-welcome" >/dev/null 2>&1
check "90-welcome gives up quietly when no compositor appears" test $? = 0

# --- 3. this computer only ------------------------------------------------------------------
echo "== 3. this computer only"
H3=$(fresh_home local)
mkdir -p "$H3/.run" && chmod 700 "$H3/.run"
out=$(as "$H3" env PALM_CLOUD_URL=http://127.0.0.1:9 welcome drive --local ${SHOTS:+--shots "$SHOTS/local"} --json 2>&1)
echo "     $out"
check "local: every page reached, Done pressed" jq -e .finished <<<"$out"
check "local: the marker says local" grep -q '"mode":"local"' "$H3/.local/state/palm/welcome/done"
check "local: sync.conf says mode = local" grep -q '^mode = local' "$H3/.config/palm/sync.conf"
check "local: no token store was created" test ! -e "$H3/.local/share/palm/cloud/session.json"
r=$(as "$H3" welcome run --first-login --json)
check "local: run --first-login does nothing once finished" jq -e '.shown == false' <<<"$r"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
