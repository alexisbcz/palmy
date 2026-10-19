#!/usr/bin/env bash
# After vdir.sh: make a contact with khard and an event with khal, sync them
# up, check the server has them, change the contact on the server, sync back
# and check khard sees the change.
#
#   khard_khal.sh WORKDIR URL HANDLE APP_PASSWORD BIN
set -euo pipefail
work=$1 url=$2 user=$3 pass=$4 bin=$5
export VDIRSYNCER_CONFIG="$work/config"
pass_() { printf 'ok    %s\n' "$1"; }
fail_() { printf 'FAIL  %s\n' "$1"; exit 1; }

cat > "$work/khard.conf" <<EOF
[addressbooks]
[[default]]
path = $work/contacts/default/
[general]
default_action = list
editor = /bin/false
merge_editor = /bin/false
[vcard]
preferred_version = 4.0
EOF
cat > "$work/khal.conf" <<EOF
[calendars]
[[default]]
path = $work/calendars/default/
[locale]
timeformat = %H:%M
dateformat = %Y-%m-%d
longdateformat = %Y-%m-%d
datetimeformat = %Y-%m-%d %H:%M
longdatetimeformat = %Y-%m-%d %H:%M
local_timezone = Europe/Paris
default_timezone = Europe/Paris
EOF
khard() { "$bin/khard" -c "$work/khard.conf" "$@"; }
khal() { "$bin/khal" -c "$work/khal.conf" "$@"; }

cat > "$work/grace.yaml" <<'EOF'
First name : Grace
Last name : Hopper
Organisation : US Navy
Title : Rear Admiral
Phone :
    work : +1 202 555 0143
Email :
    work : grace@navy.example
Note : Made with khard, synced through vdirsyncer
EOF
khard new -a default --input-file "$work/grace.yaml" >/dev/null
khal new -a default 2026-11-12 14:00 15:30 "Compiler review (khal)" :: "made with khal" >/dev/null
"$bin/vdirsyncer" sync >/dev/null

auth=(-u "$user:$pass")
q='<C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><D:prop><D:getetag/><C:address-data/></D:prop><C:filter><C:prop-filter name="EMAIL"><C:text-match match-type="equals">grace@navy.example</C:text-match></C:prop-filter></C:filter></C:addressbook-query>'
found=$(curl -s "${auth[@]}" -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' --data "$q" "${url}dav/addressbooks/$user/default/")
grep -q 'FN:Grace Hopper' <<<"$found" && pass_ "the khard contact reached the server (addressbook-query by email)" || fail_ "the contact is not on the server"
href=$(grep -o '<d:href>[^<]*</d:href>' <<<"$found" | head -1 | sed 's/<[^>]*>//g')

cq='<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20261112T000000Z" end="20261113T000000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>'
evs=$(curl -s "${auth[@]}" -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' --data "$cq" "${url}dav/calendars/$user/default/")
grep -q 'Compiler review (khal)' <<<"$evs" && pass_ "the khal event reached the server (calendar-query time-range)" || fail_ "the event is not on the server"

# Change the contact on the server side (as another client would), sync back.
card=$(curl -s "${auth[@]}" "${url%/}$href")
etag=$(curl -s -I "${auth[@]}" "${url%/}$href" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
new=$(sed 's/^TITLE:.*/TITLE:Rear Admiral (ret.)/' <<<"$card")
code=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" -X PUT -H "If-Match: $etag" -H 'Content-Type: text/vcard' --data-binary "$new" "${url%/}$href")
[ "$code" = 204 ] && pass_ "a conditional PUT (If-Match) updates the card on the server" || fail_ "PUT returned $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" -X PUT -H "If-Match: $etag" -H 'Content-Type: text/vcard' --data-binary "$new" "${url%/}$href")
[ "$code" = 412 ] && pass_ "a stale If-Match is refused with 412" || fail_ "stale PUT returned $code"
"$bin/vdirsyncer" sync >/dev/null
khard show --format yaml grace 2>/dev/null | grep -q 'Rear Admiral (ret.)' && pass_ "khard sees the server-side change after sync" || fail_ "khard did not get the change"
khal list 2026-11-12 2026-11-13 | grep -q 'Compiler review' && pass_ "khal lists the event from its synced copy" || fail_ "khal lost the event"
