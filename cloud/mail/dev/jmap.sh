#!/usr/bin/env bash
# POST a JMAP request to palm-maild as one of the dev people.
#
#   cloud/mail/dev/jmap.sh alice '{"using":[...],"methodCalls":[...]}'
#   cloud/mail/dev/jmap.sh alice session
#
# The token comes from $PALM_MAIL_STATE/<who>.token (written by people.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
STATE=${PALM_MAIL_STATE:-/tmp/palm-mail-dev}
who=$1
body=$2
tok=$(cat "$STATE/$who.token")
if [ "$body" = session ]; then
	curl -s "http://127.0.0.1:$PALM_JMAP_PORT/.well-known/jmap" -H "Authorization: Bearer $tok"
else
	curl -s -X POST "http://127.0.0.1:$PALM_JMAP_PORT/jmap/api" -H "Authorization: Bearer $tok" \
		-H 'Content-Type: application/json' --data-binary "$body"
fi
echo
