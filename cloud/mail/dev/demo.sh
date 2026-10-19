#!/usr/bin/env bash
# The mail demo, end to end, on loopback.
#
#   cloud/mail/dev/demo.sh            fresh database, everything below
#   cloud/mail/dev/demo.sh --keep     reuse the running stack and its data
#
# 1. build palm-maild, mailcore and apps/mail; bring up Postgres + GoTrue +
#    PostgREST on 555xx; migrate; run the pgTAP RLS test
# 2. two people, three identities (people.sh)
# 3. start palm-maild: SMTP MX :55525, submission :55587, JMAP :55580
# 4. the MX port refuses relaying and unknown mailboxes, and delivers to local
#    identities
# 5. Alice sends over SMTP submission (mailcore send, token as password) to
#    Bob, to her own work identity, and to an outside address (held, not sent)
# 6. Bob replies over JMAP (Email/set a draft, EmailSubmission/set it)
# 7. isolation: a token scoped to Alice's personal identity sees one JMAP
#    account and gets accountNotFound for her work one; no token and a forged
#    token get 401; Alice's token cannot submit as Bob
# 8. mailcore palm sync: Alice's identities into Maildirs
# 9. apps/mail, offscreen: sign in through the UI, sync, and screenshot every
#    identity view into $OUT (default /tmp/palm-mail-dev/shots)
#
# Nothing here, or in anything it starts, sends mail off this machine.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && cd .. && pwd)"
source "$HERE/env.sh"
export PALM_MAIL_STATE=${PALM_MAIL_STATE:-/tmp/palm-mail-dev}
STATE=$PALM_MAIL_STATE
OUT=${OUT:-$STATE/shots}
BIN="$ROOT/bin"
mkdir -p "$STATE"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "build"
bash "$HERE/build.sh"

if [ "${1:-}" != "--keep" ]; then
	say "stack (fresh)"
	bash "$HERE/stack.sh" reset
else
	say "stack (kept)"
	bash "$HERE/stack.sh" up
fi

say "pgTAP: mail_rls"
bash "$HERE/stack.sh" test | tail -3

say "people and identities"
bash "$HERE/people.sh"
ALICE_ID=$(cat "$STATE/alice.id")
WORK_ID=$(cat "$STATE/alice.work.id")
BOB_ID=$(cat "$STATE/bob.id")

say "palm-maild"
pkill -f "palm-maild serve" 2>/dev/null || true
sleep 0.3
"$BIN/palm-maild" serve >"$STATE/maild.log" 2>&1 &
MAILD=$!
trap 'kill $MAILD 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PALM_JMAP_PORT/health" >/dev/null && break; sleep 0.1; done
cat "$STATE/maild.log"

say "MX: relaying refused, unknown mailbox refused, local delivery"
python3 -I "$HERE/smtp_probe.py" mx-relay
python3 -I "$HERE/smtp_probe.py" mx-unknown
python3 -I "$HERE/smtp_probe.py" mx-deliver

say "submission: Alice -> Bob, Alice -> her work identity, Alice -> outside (held)"
"$BIN/mailcore" send --port "$PALM_SUBMIT_PORT" --user alice@palm.test --token-file "$STATE/alice.token" \
	--to bob@palm.test --subject "Lunch on Thursday?" \
	--text "Bob — the new place on Rue Oberkampf, 12:30? Alice"
"$BIN/mailcore" send --port "$PALM_SUBMIT_PORT" --user alice@palm.test --token-file "$STATE/alice.token" \
	--to alice.work@palm.test --subject "Note to my work self" \
	--text "Remember to file the Q4 travel receipts. (Sent from my personal identity.)"
"$BIN/mailcore" send --port "$PALM_SUBMIT_PORT" --user alice@palm.test --token-file "$STATE/alice.token" \
	--to friend@example.com --subject "Photos from the weekend" \
	--text "These will wait in the Outbox: outbound delivery is not enabled." || true
"$BIN/mailcore" send --port "$PALM_SUBMIT_PORT" --user alice.work@palm.test --token-file "$STATE/alice.token" \
	--to bob@palm.test --subject "Acme: contract draft v3" \
	--text "Bob, v3 attached in spirit. Comments by Friday please. — Alice, Acme"

say "JMAP: Bob replies to the lunch mail (Email/set draft + EmailSubmission/set)"
MSGID=$(bash "$HERE/jmap.sh" bob "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Email/query\",{\"accountId\":\"$BOB_ID\",\"filter\":{\"subject\":\"Lunch\"}},\"q\"],[\"Email/get\",{\"accountId\":\"$BOB_ID\",\"#ids\":{\"resultOf\":\"q\",\"name\":\"Email/query\",\"path\":\"/ids\"},\"properties\":[\"messageId\"]},\"g\"]]}" \
	| python3 -I -c "import json,sys; print(json.load(sys.stdin)['methodResponses'][1][1]['list'][0]['messageId'][0])")
DRAFTS=$(bash "$HERE/jmap.sh" bob "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Mailbox/get\",{\"accountId\":\"$BOB_ID\"},\"m\"]]}" \
	| python3 -I -c "import json,sys; print([b['id'] for b in json.load(sys.stdin)['methodResponses'][0][1]['list'] if b['role']=='drafts'][0])")
bash "$HERE/jmap.sh" bob "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\",\"urn:ietf:params:jmap:submission\"],\"methodCalls\":[
 [\"Email/set\",{\"accountId\":\"$BOB_ID\",\"create\":{\"d1\":{\"mailboxIds\":{\"$DRAFTS\":true},\"keywords\":{\"\$draft\":true,\"\$seen\":true},
   \"from\":[{\"name\":\"Bob Lefèvre\",\"email\":\"bob@palm.test\"}],\"to\":[{\"name\":\"Alice Martin\",\"email\":\"alice@palm.test\"}],
   \"subject\":\"Re: Lunch on Thursday?\",\"inReplyTo\":[\"$MSGID\"],\"references\":[\"$MSGID\"],
   \"textBody\":[{\"partId\":\"t\",\"type\":\"text/plain\"}],\"bodyValues\":{\"t\":{\"value\":\"12:30 works. I'll book for two.\\n\\nBob\\n\"}}}}},\"c1\"],
 [\"EmailSubmission/set\",{\"accountId\":\"$BOB_ID\",\"create\":{\"s1\":{\"identityId\":\"$BOB_ID\",\"emailId\":\"#d1\"}},\"onSuccessDestroyEmail\":[\"#s1\"]},\"c2\"]]}" \
	| python3 -I -c "
import json,sys
r=json.load(sys.stdin)['methodResponses']
for name,args,cid in r:
    print(f'{cid} {name}: created={list(args.get(\"created\",{}).keys())} destroyed={args.get(\"destroyed\",[])} notCreated={args.get(\"notCreated\",{})}')"

say "isolation"
SUB=$(python3 -I -c "import base64,json,sys; p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p))['sub'])" "$(cat "$STATE/alice.token")")
"$BIN/palm-maild" mint --sub "$SUB" --identity "$ALICE_ID" >"$STATE/alice-scoped.token"
bash "$HERE/jmap.sh" alice session | python3 -I -c "import json,sys; d=json.load(sys.stdin); print('unscoped alice: JMAP accounts =', sorted(a['name'] for a in d['accounts'].values()))"
bash "$HERE/jmap.sh" alice-scoped session | python3 -I -c "import json,sys; d=json.load(sys.stdin); print('scoped to alice@palm.test: JMAP accounts =', sorted(a['name'] for a in d['accounts'].values()))"
bash "$HERE/jmap.sh" alice-scoped "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Email/query\",{\"accountId\":\"$WORK_ID\"},\"q\"]]}" \
	| python3 -I -c "import json,sys; print('scoped token, Email/query on the work identity ->', json.load(sys.stdin)['methodResponses'][0][1])"
bash "$HERE/jmap.sh" alice "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Email/query\",{\"accountId\":\"$BOB_ID\"},\"q\"]]}" \
	| python3 -I -c "import json,sys; print('alice, Email/query on Bob\\'s account ->', json.load(sys.stdin)['methodResponses'][0][1])"
printf 'no token -> HTTP %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PALM_JMAP_PORT/.well-known/jmap")"
FORGED=$(PALM_JWT_SECRET=not-the-project-secret-not-the-project-secret "$BIN/palm-maild" mint --sub "$SUB")
printf 'forged token -> HTTP %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FORGED" "http://127.0.0.1:$PALM_JMAP_PORT/.well-known/jmap")"
python3 -I "$HERE/smtp_probe.py" submit "$STATE/alice.token" bob@palm.test alice@palm.test 2>&1 | grep -E "535|AUTH" | head -2 || true

say "mailcore palm sync (Alice) into $STATE/xdg"
rm -rf "$STATE/xdg"
XDG_DATA_HOME="$STATE/xdg" "$BIN/mailcore" palm login --email alice@example.test --password palm-dev-alice
XDG_DATA_HOME="$STATE/xdg" "$BIN/mailcore" palm sync
for d in "$STATE"/xdg/palmy-mail/*@*; do
	printf '%-28s inbox %s, sent %s, outbox %s\n' "$(basename "$d")" \
		"$(ls "$d"/new "$d"/cur 2>/dev/null | grep -vc ':$\|^$' || true)" \
		"$(ls "$d"/.Sent/new "$d"/.Sent/cur 2>/dev/null | grep -vc ':$\|^$' || true)" \
		"$(ls "$d"/.Outbox/new "$d"/.Outbox/cur 2>/dev/null | grep -vc ':$\|^$' || true)"
done

say "apps/mail Send, then sync: a message queued in the local Outbox is submitted"
Q="$STATE/xdg/palmy-mail/alice@palm.test/.Outbox"
mkdir -p "$Q/tmp" "$Q/new" "$Q/cur"
# Exactly what apps/mail's Send writes (compose.odin), marker header included.
printf 'From: Alice Martin <alice@palm.test>\r\nTo: Bob Lefèvre <bob@palm.test>, carol@elsewhere.example\r\nSubject: Written in apps/mail\r\nDate: %s\r\nMessage-ID: <ui-1@palm.test>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\nX-Palmy-Mail: queued-locally; never-transmitted\r\n\r\nQueued in the client, handed to the server by the next sync.\r\n' "$(date -R)" >"$Q/new/$(date +%s).M1P$$.palmy"
XDG_DATA_HOME="$STATE/xdg" "$BIN/mailcore" palm sync
bash "$HERE/jmap.sh" bob "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Email/query\",{\"accountId\":\"$BOB_ID\",\"filter\":{\"subject\":\"apps/mail\"}},\"q\"]]}" \
	| python3 -I -c "import json,sys; print('Bob has the apps/mail message:', len(json.load(sys.stdin)['methodResponses'][0][1]['ids']) == 1)"

say "apps/mail: sign in through the UI and render the identity views into $OUT"
rm -rf "$STATE/ui"
mkdir -p "$STATE/ui/palmy-mail"
PALMY_MAILCORE="$BIN/mailcore" PALM_DEMO_EMAIL=alice@example.test PALM_DEMO_PASSWORD=palm-dev-alice \
	"$BIN/mail" --palm-shots="$OUT" --data-dir="$STATE/ui/palmy-mail"

say "palm-maild log"
cat "$STATE/maild.log"
