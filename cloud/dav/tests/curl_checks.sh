#!/usr/bin/env bash
# Raw-HTTP checks for the parts no client library drives: MKCALENDAR with
# properties, MOVE between calendars, the calendar as one .ics, vCard
# version negotiation, allprop, OPTIONS and the well-known redirect.
#
#   curl_checks.sh URL HANDLE APP_PASSWORD
set -uo pipefail
url=${1%/} user=$2 pass=$3
auth=(-u "$user:$pass")
n=0 bad=0
ok() { n=$((n + 1)); printf 'ok    %s\n' "$1"; }
no() { n=$((n + 1)); bad=$((bad + 1)); printf 'FAIL  %s\n' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$@"; }

[ "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$url/.well-known/carddav")" = "301 $url/dav/" ] \
	&& ok "/.well-known/carddav redirects to /dav/" || no "well-known"
curl -s -i -X OPTIONS "$url/dav/" | grep -qi '^DAV:.*calendar-access.*addressbook.*calendar-auto-schedule' \
	&& ok "OPTIONS advertises calendar-access, addressbook, calendar-auto-schedule" || no "OPTIONS"

home="$url/dav/calendars/$user"
code -X DELETE "$home/trips/" >/dev/null
mk='<?xml version="1.0"?><C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:A="http://apple.com/ns/ical/"><D:set><D:prop><D:displayname>Trips</D:displayname><A:calendar-color>#f97316FF</A:calendar-color><C:calendar-timezone-id>Europe/Lisbon</C:calendar-timezone-id><C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set></D:prop></D:set></C:mkcalendar>'
[ "$(code -X MKCALENDAR -H 'Content-Type: application/xml' --data "$mk" "$home/trips/")" = 201 ] \
	&& ok "MKCALENDAR with name, colour, zone and component set" || no "MKCALENDAR"
props=$(curl -s "${auth[@]}" -X PROPFIND -H 'Depth: 0' --data '<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:A="http://apple.com/ns/ical/"><D:prop><D:displayname/><A:calendar-color/><C:calendar-timezone-id/><C:supported-calendar-component-set/></D:prop></D:propfind>' "$home/trips/")
grep -q '<d:displayname>Trips</d:displayname>' <<<"$props" && grep -q '#f97316FF' <<<"$props" \
	&& grep -q 'Europe/Lisbon' <<<"$props" && ! grep -q 'name="VTODO"' <<<"$props" \
	&& ok "and PROPFIND returns them" || no "MKCALENDAR properties: $props"

todo=$'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:t1@x\r\nSUMMARY:pack\r\nEND:VTODO\r\nEND:VCALENDAR\r\n'
[ "$(code -X PUT -H 'Content-Type: text/calendar' --data-binary "$todo" "$home/trips/t1.ics")" = 403 ] \
	&& ok "a VTODO in a VEVENT-only calendar is refused (supported-calendar-component)" || no "component check"

ev=$'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:move-me@x\r\nDTSTART;VALUE=DATE:20261120\r\nDTEND;VALUE=DATE:20261123\r\nSUMMARY:Porto\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
code -X DELETE "$home/default/move-me.ics" >/dev/null
code -X PUT -H 'Content-Type: text/calendar' --data-binary "$ev" "$home/default/move-me.ics" >/dev/null
[ "$(code -X MOVE -H "Destination: $home/trips/porto.ics" "$home/default/move-me.ics")" = 201 ] \
	&& [ "$(code "$home/default/move-me.ics")" = 404 ] && [ "$(code "$home/trips/porto.ics")" = 200 ] \
	&& ok "MOVE takes an event from one calendar to another" || no "MOVE"

ics=$(curl -s "${auth[@]}" "$home/trips/")
grep -q '^X-WR-CALNAME:Trips' <<<"$(tr -d '\r' <<<"$ics")" && grep -q 'SUMMARY:Porto' <<<"$ics" \
	&& ok "GET on a calendar is the whole calendar as one .ics (subscribable)" || no "export"

book="$url/dav/addressbooks/$user/default"
card4=$'BEGIN:VCARD\r\nVERSION:4.0\r\nUID:neg-1@x\r\nFN:Ada Byron\r\nN:Byron;Ada;;;\r\nTEL;TYPE=cell;VALUE=uri:tel:+44 20 0000\r\nEND:VCARD\r\n'
code -X DELETE "$book/neg-1.vcf" >/dev/null
code -X PUT -H 'Content-Type: text/vcard' --data-binary "$card4" "$book/neg-1.vcf" >/dev/null
v3=$(curl -s "${auth[@]}" -H 'Accept: text/vcard; version=3.0' "$book/neg-1.vcf")
grep -q 'VERSION:3.0' <<<"$v3" && grep -q 'TEL;TYPE=CELL:+44 20 0000' <<<"$v3" \
	&& ok "a 4.0 card is served as 3.0 when asked (Accept: text/vcard; version=3.0)" || no "version negotiation: $v3"
mg='<C:addressbook-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><D:prop><C:address-data content-type="text/vcard" version="3.0"/></D:prop><D:href>/dav/addressbooks/'"$user"'/default/neg-1.vcf</D:href></C:addressbook-multiget>'
curl -s "${auth[@]}" -X REPORT -H 'Depth: 1' --data "$mg" "$book/" | grep -q 'VERSION:3.0' \
	&& ok "and through addressbook-multiget address-data version=\"3.0\"" || no "multiget version"
code -X DELETE "$book/neg-1.vcf" >/dev/null

allp=$(curl -s "${auth[@]}" -X PROPFIND -H 'Depth: 0' "$home/trips/")
grep -q '<cs:getctag>' <<<"$allp" && grep -q '<d:sync-token>' <<<"$allp" \
	&& ok "PROPFIND without a body (allprop) returns getctag and sync-token" || no "allprop"
[ "$(code -X DELETE "$home/trips/")" = 204 ] && [ "$(code -X PROPFIND "$home/trips/")" = 404 ] \
	&& ok "DELETE on a calendar removes it" || no "DELETE collection"
[ "$(curl -s -o /dev/null -w '%{http_code}' -u "$user:not-the-password" -X PROPFIND "$url/dav/")" = 401 ] \
	&& ok "a wrong app password is 401 with a Basic challenge" || no "401"

echo "$n checks, $bad failed"
[ $bad -eq 0 ]
