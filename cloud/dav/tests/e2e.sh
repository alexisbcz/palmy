#!/usr/bin/env bash
# The calendar and contacts demo, end to end, on a fresh stack.
#
#   cloud/dav/tests/e2e.sh WORKDIR VENV_BIN [--keep]
#
# Starts its own stack (cloud/dev, name dave2e, ports 59560-59579) and its own
# palm-davd on 59585, builds the server and both apps into WORKDIR/bin, and
# then, with two people — Maya (identities maya, maya-work) and Noah (noah):
#
#   1. events from the Palmy calendar app, including a weekly stand-up
#      with one occurrence deleted (an EXDATE);
#   2. an event and a moved instance (RECURRENCE-ID) from python-caldav, a
#      third-party client on an app password; both sides see both;
#   3. Maya invites Noah from her work identity, Noah accepts, Maya sees it;
#   4. a read-only share from Maya to Noah, which Noah can read and not write;
#   5. isolation: Maya's work app password cannot see her personal calendar,
#      and the app refuses to widen its scope;
#   6. contacts made in the Palmy contacts app round-trip through
#      vdirsyncer and khard and back.
#
# VENV_BIN holds python with caldav and icalendar, vdirsyncer and khard.
# Exits non-zero on the first failed step. --keep leaves the stack running.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$1 venv=$2 keep=${3:-}
mkdir -p "$work/bin"
work=$(cd "$work" && pwd)
API=http://127.0.0.1:59560
DAV=http://127.0.0.1:59585
ANON=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
PW="correct horse battery"

step() { printf '\n== %s\n' "$*"; }
show() { printf '$ %s\n' "$*" | sed -E "s#$work/bin/##g; s#$venv/##g; s#$here/##g; s#$work/##g; s#\b[a-z2-9]{32}\b#<app-password>#g"; "$@"; }
expect() { # description, then a command that must succeed
	local what=$1; shift
	if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; exit 1; fi
}

cleanup() {
	[ -n "${davd_pid:-}" ] && kill "$davd_pid" 2>/dev/null || true
	if [ "$keep" != "--keep" ]; then "$repo/cloud/dev/down.sh" --name dave2e --volumes >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

step "stack, server and apps"
"$repo/cloud/dev/up.sh" --name dave2e --port-base 59560 --reset 2>&1 | grep -E "applied|API URL"
odin build "$repo/cloud/dav" -out:"$work/bin/palm-davd"
for app in calendar contacts; do
	odin build "$repo/apps/$app" -collection:palmy="$repo/palmy" -collection:shadcn="$repo/shadcn" \
		-collection:kit="$repo/apps/kit" -out:"$work/bin/$app"
done
PALM_CLOUD_URL=$API PALM_DAV_PORT=59585 "$work/bin/palm-davd" serve 2>"$work/davd.log" &
davd_pid=$!
sleep 0.5

# Each person is a machine of their own: a token store, a DAV cache, a HOME.
as() { # person, program, args...
	local who=$1 prog=$2; shift 2
	PALM_CLOUD_URL=$API PALM_DAV_URL=$DAV PALM_CLOUD_DIR="$work/$who/cloud" \
		PALM_DAV_CACHE="$work/$who/dav" HOME="$work/$who/home" "$work/bin/$prog" "$@"
}

step "two people sign up; Maya has a personal and a work identity"
for who in maya noah; do
	mkdir -p "$work/$who/cloud" "$work/$who/dav" "$work/$who/home"
	curl -sf "$API/auth/v1/signup" -H "apikey: $ANON" -H 'Content-Type: application/json' \
		-d "{\"email\":\"$who@example.test\",\"password\":\"$PW\"}" >/dev/null
	printf '%s' "$PW" > "$work/$who/password"
	as $who calendar signin "$who@example.test" --password-file "$work/$who/password" >/dev/null
done
ident() { # person handle display kind colour
	local tok
	tok=$(jq -r .access_token "$work/$1/cloud/session.json")
	curl -sf "$API/rest/v1/rpc/create_identity" -H "apikey: $ANON" -H "Authorization: Bearer $tok" \
		-H 'Content-Type: application/json' \
		-d "{\"handle\":\"$2\",\"display_name\":\"$3\",\"kind\":\"$4\",\"color\":\"$5\"}" | jq -r .handle
}
ident maya maya "Maya Lindqvist" personal indigo
ident maya maya-work "Maya (Fjord Labs)" work emerald
ident noah noah "Noah Adeyemi" personal amber
as maya calendar sync >/dev/null
as noah calendar sync >/dev/null
show as maya calendar list

step "1. events from the Palmy calendar app"
show as maya calendar add "Dentist" --date 2026-10-22 --time 08:30 --minutes 30 --calendar maya/default
standup=$(as maya calendar add "Stand-up" --date 2026-10-19 --time 09:30 --minutes 15 \
	--calendar maya-work/default --rrule "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=9" --json | jq -r .uid)
echo "stand-up uid: $standup"
show as maya calendar delete "$standup" --occurrence 2026-10-21 --yes

step "app passwords for the third-party client"
pw_maya=$(as maya calendar app-password create --identity maya --label "python-caldav" --json | jq -r .secret)
pw_work=$(as maya calendar app-password create --identity maya-work --label "python-caldav" --json | jq -r .secret)
pw_noah=$(as noah calendar app-password create --identity noah --label "vdirsyncer" --json | jq -r .secret)
echo "three app passwords, one identity each (shown once, not printed here)"

step "2. python-caldav adds an event and moves one stand-up"
py() { "$venv/python" -I "$here/e2e_client.py" "$DAV/" "$@"; }
show py maya "$pw_maya" add default "$(printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//e2e//EN\r\nBEGIN:VEVENT\r\nUID:ceramics@e2e\r\nDTSTAMP:20261019T080000Z\r\nDTSTART;TZID=Europe/Paris:20261023T183000\r\nDTEND;TZID=Europe/Paris:20261023T203000\r\nSUMMARY:Ceramics class\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n')"
# Friday 23 October, 09:30 Paris = 07:30Z, moved to 11:00 Paris.
show py maya-work "$pw_work" override default "$standup" 20261023T073000Z 20261023T090000Z 20261023T091500Z
echo "-- what python-caldav sees in maya-work, week of 19 October (expanded):"
show py maya-work "$pw_work" events default 20261019 20261026
expect "python-caldav sees the stand-up without Wednesday (EXDATE from the app)" \
	bash -c "! $venv/python -I $here/e2e_client.py $DAV/ maya-work $pw_work events default 20261021 20261022 | grep -q Stand-up"
echo "-- what the app sees after sync:"
as maya calendar sync >/dev/null
show as maya calendar events --from 2026-10-19 --to 2026-10-26
ev=$(as maya calendar events --from 2026-10-19 --to 2026-10-26 --json)
expect "the app sees the event python-caldav made" grep -q "Ceramics class" <<<"$ev"
expect "the app sees the moved stand-up" grep -q "moved by python-caldav" <<<"$ev"
expect "python-caldav sees the event the app made" \
	bash -c "$venv/python -I $here/e2e_client.py $DAV/ maya $pw_maya events default 20261022 20261023 | grep -q Dentist"

step "3. Maya invites Noah from her work identity; Noah accepts"
kick=$(as maya calendar add "Project kickoff" --date 2026-10-27 --time 14:00 --minutes 60 \
	--calendar maya-work/default --attendee noah --json | jq -r .uid)
show as noah calendar invitations
show as noah calendar accept "$kick"
as maya calendar sync >/dev/null
att=$(as maya calendar events --from 2026-10-27 --to 2026-10-28 --calendar maya-work/default --json)
echo "$att" | jq -c '.events[] | {title, attendees}'
expect "Maya's copy says Noah ACCEPTED" bash -c "jq -e '.events[].attendees[] | select(.address|test(\"noah@\")) | select(.partstat==\"ACCEPTED\")' <<<'$att'"

step "4. a read-only share from Maya to Noah"
show as maya calendar share --calendar maya/default --with noah@palm.test --access read
as noah calendar sync >/dev/null
show as noah calendar list
expect "Noah reads Maya's personal calendar" bash -c "PALM_CLOUD_URL=$API PALM_DAV_URL=$DAV PALM_CLOUD_DIR=$work/noah/cloud PALM_DAV_CACHE=$work/noah/dav HOME=$work/noah/home $work/bin/calendar events --from 2026-10-22 --to 2026-10-23 --calendar 'noah/maya~default' | grep -q Dentist"
set +e
as noah calendar add "Noah was here" --date 2026-10-24 --calendar "noah/maya~default"
code=$?
set -e
expect "Noah cannot write into it (exit $code)" test "$code" -ne 0
expect "and the server says 403 too" test "$(curl -s -o /dev/null -w '%{http_code}' -u "noah:$pw_noah" -X PUT \
	-H 'Content-Type: text/calendar' --data-binary $'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:x@e2e\r\nDTSTART:20261024T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' \
	"$DAV/dav/calendars/noah/maya~default/x.ics")" = 403

step "5. isolation"
expect "Maya's work app password lists only maya-work" bash -c "! $venv/python -I $here/e2e_client.py $DAV/ maya-work $pw_work calendars | grep -q '/calendars/maya/'"
expect "and gets 404 for Maya's personal calendar" test "$(curl -s -o /dev/null -w '%{http_code}' -u "maya-work:$pw_work" -X PROPFIND "$DAV/dav/calendars/maya/default/")" = 404
set +e
as maya calendar list --identity noah --json >/dev/null 2>&1
code=$?
set -e
expect "the app refuses another person's identity (exit $code = out of scope)" test "$code" = 5

step "6. contacts: the app, vdirsyncer, khard, and back"
uid=$(as maya contacts add --name "Ingrid Solberg" --email ingrid@fjord.example --phone "+47 22 00 00 00" --org "Fjord Labs" --book maya/default --json | jq -r .uid)
echo "contacts add \"Ingrid Solberg\" ... --book maya/default  ->  uid $uid"
vd="$work/vdir"
bash "$here/vdir.sh" "$vd" "$DAV/" maya "$pw_maya" "$venv" >/dev/null 2>&1
cat > "$vd/khard.conf" <<EOF
[addressbooks]
[[default]]
path = $vd/contacts/default/
[general]
default_action = list
editor = /bin/false
merge_editor = /bin/false
[vcard]
preferred_version = 4.0
EOF
show "$venv/khard" -c "$vd/khard.conf" list
expect "khard sees the contact made in the app" bash -c "$venv/khard -c $vd/khard.conf list | grep -q Solberg"
f=$(grep -l "Ingrid" "$vd"/contacts/default/*.vcf)
sed -i 's/^TITLE:.*$//; s/^FN:Ingrid Solberg/FN:Ingrid Solberg\r\nTITLE:Head of research/' "$f"
VDIRSYNCER_CONFIG="$vd/config" "$venv/vdirsyncer" sync
as maya contacts sync >/dev/null
show as maya contacts show "$uid"
expect "the app sees the edit made on khard's side" bash -c "PALM_CLOUD_URL=$API PALM_DAV_URL=$DAV PALM_CLOUD_DIR=$work/maya/cloud PALM_DAV_CACHE=$work/maya/dav HOME=$work/maya/home $work/bin/contacts show '$uid' | grep -q 'Head of research'"

step "done"
echo "all steps passed"
