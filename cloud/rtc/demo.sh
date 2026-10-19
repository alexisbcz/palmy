#!/usr/bin/env bash
# cloud/rtc/demo.sh — chat (and, with the SFU, calls) end to end on a local
# stack. Everything here is the real path: accounts are signed up through
# GoTrue by `accounts`, identities are scoped sessions minted by the accounts
# token hook, and every chat command goes through palm-rtc to Postgres under
# RLS. Nothing is seeded behind the gateway's back.
#
#   cloud/dev/up.sh --name rtc --port-base 61520      # the stack
#   cloud/rtc/demo.sh                                  # this
#
# Environment (defaults are the rtc stack's):
#   API, DB, JWT_SECRET    the stack
#   RTC_PORT, SFU_PORT     where palm-rtc and palm-sfu listen (61590, 61592)
#   OUT                    scratch: binaries, token stores, logs
#   KEEP=1                 leave palm-rtc / palm-sfu running afterwards
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
API=${API:-http://127.0.0.1:61520}
DB=${DB:-postgresql://postgres:postgres@127.0.0.1:61521/postgres}
JWT_SECRET=${JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}
RTC_PORT=${RTC_PORT:-61590}
SFU_PORT=${SFU_PORT:-61592}
OUT=${OUT:-${TMPDIR:-/tmp}/palm-rtc-demo}
BIN=$OUT/bin
RUN=$(date +%s | tail -c 6)
mkdir -p "$BIN" "$OUT/people"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { printf '$ %s\n' "$*" | sed "s#$BIN/##g; s#$OUT#\$OUT#g" >&2; "$@"; }

build() {
	odin build "$ROOT/$1" -collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" \
		-collection:kit="$ROOT/apps/kit" -o:speed -out:"$BIN/$2"
}
if [ -z "${NO_BUILD:-}" ]; then
	say "build"
	build cloud/rtc palm-rtc
	build apps/chat chat
	build apps/accounts accounts
	build cloud/rtc/sfu palm-sfu
	build apps/call call
	ls "$BIN"
fi

[ -f "$OUT/sfu.secret" ] || head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$OUT/sfu.secret"

say "palm-rtc on 127.0.0.1:$RTC_PORT"
"$BIN/palm-rtc" --db "$DB" --api "$API" --jwt-secret "$JWT_SECRET" \
	--sfu-secret-file "$OUT/sfu.secret" --sfu "127.0.0.1:$SFU_PORT" --port "$RTC_PORT" > "$OUT/palm-rtc.log" 2>&1 &
RTC_PID=$!
SFU_PID= # palm-sfu is started by sfu/demo-call.sh, for the length of the call
cleanup() {
	if [ -z "${KEEP:-}" ]; then
		kill "$RTC_PID" ${SFU_PID:+"$SFU_PID"} 2>/dev/null || true
	fi
}
trap cleanup EXIT
sleep 0.5
cat "$OUT/palm-rtc.log"

# as <person> [PALM_IDENTITY] <tool> args... — a person's own token store.
as() {
	local who=$1 ident=$2; shift 2
	mkdir -p "$OUT/people/$who-$RUN"
	PALM_CLOUD_DIR="$OUT/people/$who-$RUN" PALM_CLOUD_URL="$API" PALM_RTC_PORT="$RTC_PORT" \
		PALM_IDENTITY="$ident" run "$BIN/$@"
}
jsonof() { as "$@" --json; }

A=alice-$RUN AW=alice.nw-$RUN B=bob-$RUN BW=bob.nw-$RUN C=carol-$RUN
PW=correct-horse-battery-9

say "three people, five identities (accounts → GoTrue + PostgREST)"
as alice "" accounts signup "alice-$RUN@palm.test" --name "Alice" --handle "$A" --password "$PW" > /dev/null
as alice "" accounts create "$AW" --name "Alice Martin" --kind work --color indigo > /dev/null
as bob   "" accounts signup "bob-$RUN@palm.test" --name "Bob" --handle "$B" --password "$PW" > /dev/null
as bob   "" accounts create "$BW" --name "Bob Chen" --kind work --color emerald > /dev/null
as carol "" accounts signup "carol-$RUN@palm.test" --name "Carol Diaz" --handle "$C" --password "$PW" > /dev/null
as carol "" accounts color "$C" sky > /dev/null 2>&1 || true
# A scoped session per identity: PALM_IDENTITY=<handle> then uses that one
# session and nothing else (cloudkit), and its token carries palm_identity.
for h in "$A" "$AW"; do as alice "" accounts switch "$h" > /dev/null; done
for h in "$B" "$BW"; do as bob "" accounts switch "$h" > /dev/null; done
as carol "" accounts switch "$C" > /dev/null
as alice "$AW" chat whoami
as bob "$BW" chat whoami
as carol "$C" chat whoami

say "Alice (work) makes a space; invites Bob (work) to it and Carol to one private channel"
as alice "$AW" chat create-space Northwind
as alice "$AW" chat create-channel Northwind design --private --topic "Pixels and the board deck"
as alice "$AW" chat invite Northwind "$BW"
as alice "$AW" chat invite Northwind "$C" --channel '#design'
as bob "$BW" chat invites
as bob "$BW" chat accept Northwind
as carol "$C" chat accept Northwind
as bob "$BW" chat channels
as carol "$C" chat channels

say "messages, a thread, reactions"
ROOT_ID=$(jsonof alice "$AW" chat post '#general' 'The **deploy** is on Thursday — any blockers?' | jq -r .message.id)
as bob "$BW" chat post '#general' 'None from infra. What time?' --thread "$ROOT_ID"
as alice "$AW" chat post '#general' '10:00, after standup.' --thread "$ROOT_ID"
as bob "$BW" chat react "$ROOT_ID" thumbsup
as carol "$C" chat post '#design' 'New mockups for the board deck are up.'
as alice "$AW" chat react "$(jsonof carol "$C" chat history '#design' --limit 1 | jq -r '.messages[0].id')" heart
as bob "$BW" chat thread "$ROOT_ID"
as bob "$BW" chat history '#general'

say "reconnect: Bob goes away at rev R, Alice keeps talking, Bob asks for exactly what he missed"
REV=$(jsonof bob "$BW" chat history '#general' | jq '[.messages[].rev] | max')
echo "Bob's high-water mark in #general: rev $REV"
as alice "$AW" chat post '#general' 'Standup moved to 9:30.'
as alice "$AW" chat post '#general' 'Bob, can you take the release notes?'
as alice "$AW" chat edit "$ROOT_ID" 'The **deploy** is on Friday now — any blockers?'
as carol "$C" chat post '#design' 'Carol cannot see #general, so this is not in Bob'"'"'s sync.'
as bob "$BW" chat sync '#general' --since "$REV"

say "search: Postgres full text, through RLS"
as bob "$BW" chat search deplo
as bob "$BW" chat search mockups || true
as carol "$C" chat search mockups

say "isolation: the same person's other identity, and strangers, see nothing"
set +e
as alice "$A" chat channels
as alice "$A" chat history '#general'; echo "exit $?"
as alice "$A" chat search deploy
as carol "$C" chat history '#general'; echo "exit $?"
as bob "$B" chat channels
as bob "$B" chat post '#general' 'from home'; echo "exit $?"
set -e

say "DM and read receipt"
as alice "$AW" chat dm "$BW"
as alice "$AW" chat post "@$BW" 'Thanks for taking the notes.'
as bob "$BW" chat history "@$AW"

if [ -z "${NO_CALL:-}" ]; then
	say "a three-way call in #design: tokens from the gateway, media through the SFU"
	as alice "$AW" chat invite Northwind "$BW" --channel '#design' --role member
	as bob "$BW" chat accept Northwind
	. "$ROOT/cloud/rtc/sfu/demo-call.sh"
else
	say "revocation: Alice removes Carol"
	as alice "$AW" chat remove Northwind "$C" --yes
fi

say "after revocation, Carol's access has ended"
set +e
as carol "$C" chat channels
as carol "$C" chat history '#design'; echo "exit $?"
set -e

say "the gateway's log"
cat "$OUT/palm-rtc.log"
