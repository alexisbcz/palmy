#!/usr/bin/env bash
# End-to-end check of the scoped-session mechanism through the real gateway,
# GoTrue, PostgREST and Storage (pgTAP covers the database alone).
#
#   ./smoke.sh [--name X] [--port-base N]
#
# Signs up a throwaway account, creates two identities, mints a session
# scoped to one, exchanges its refresh token, and checks that the scoped
# token sees and writes only its own identity, cannot change the account,
# and stops working the moment it is revoked. Needs curl and jq.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh" "$@"

api=$PALM_API_URL
pass=0 fail=0
check() { # description, condition-as-exit-status
	local what=$1; shift
	if "$@"; then pass=$((pass + 1)); echo "ok   $what"
	else fail=$((fail + 1)); echo "FAIL $what"; fi
}
eq() { [ "$1" = "$2" ] || { echo "     got '$1', want '$2'" >&2; return 1; }; }

req() { # method path token [body] -> prints "status body"
	local m=$1 p=$2 t=$3 body=${4:-}
	local args=(-s -o /dev/stdout -w '\n%{http_code}' -X "$m" "$api$p"
		-H "apikey: $PALM_ANON_KEY" -H "Authorization: Bearer $t"
		-H 'Content-Type: application/json' -H 'Prefer: return=representation')
	[ -n "$body" ] && args+=(--data "$body")
	curl "${args[@]}"
}
status() { tail -n1 <<<"$1"; }
body() { sed '$d' <<<"$1"; }
claims() { cut -d. -f2 <<<"$1" | tr '_-' '/+' | { b=$(cat); while [ $(( ${#b} % 4 )) -ne 0 ]; do b+='='; done; base64 -d <<<"$b"; }; }

tag=$(date +%s%N | tail -c 9)
email="smoke$tag@palm.test"
r=$(req POST /auth/v1/signup "$PALM_ANON_KEY" "{\"email\":\"$email\",\"password\":\"correct horse $tag\"}")
check "sign up" eq "$(status "$r")" 200
person=$(body "$r" | jq -r .access_token)

r=$(req POST /rest/v1/rpc/create_identity "$person" "{\"handle\":\"home$tag\",\"display_name\":\"Home\",\"kind\":\"personal\",\"color\":\"emerald\"}")
check "create personal identity" eq "$(status "$r")" 200
home=$(body "$r" | jq -r .id)
r=$(req POST /rest/v1/rpc/create_identity "$person" "{\"handle\":\"work$tag\",\"display_name\":\"Work\",\"kind\":\"work\",\"color\":\"sky\"}")
work=$(body "$r" | jq -r .id)

r=$(req PATCH "/rest/v1/profiles?identity_id=eq.$home" "$person" '{"bio":"home bio"}')
check "person writes the home profile" eq "$(status "$r")" 200

r=$(req POST /rest/v1/rpc/mint_scoped_session "$person" "{\"target\":\"$work\",\"device_name\":\"smoke assistant\",\"device_kind\":\"assistant\"}")
check "mint a session scoped to work" eq "$(status "$r")" 200
refresh=$(body "$r" | jq -r .refresh_token)
device=$(body "$r" | jq -r .device_id)

r=$(req POST '/auth/v1/token?grant_type=refresh_token' "$PALM_ANON_KEY" "{\"refresh_token\":\"$refresh\"}")
check "exchange the scoped refresh token" eq "$(status "$r")" 200
scoped=$(body "$r" | jq -r .access_token)
exchange=$(body "$r")
check "the token carries palm_identity = work" eq "$(claims "$scoped" | jq -r .palm_identity)" "$work"
check "the person's token carries no palm_identity" eq "$(claims "$person" | jq -r '.palm_identity // "none"')" none

r=$(req GET '/rest/v1/identities?select=id' "$scoped")
check "scoped: sees exactly one identity" eq "$(body "$r" | jq -r 'map(.id) | join(",")')" "$work"
r=$(req GET "/rest/v1/profiles?identity_id=eq.$home" "$scoped")
check "scoped: reading home's profile returns nothing" eq "$(body "$r" | jq length)" 0
r=$(req PATCH "/rest/v1/profiles?identity_id=eq.$home" "$scoped" '{"bio":"overwritten"}')
check "scoped: updating home's profile touches no row" eq "$(body "$r" | jq length)" 0
r=$(req POST /rest/v1/profiles "$scoped" "{\"identity_id\":\"$home\"}")
check "scoped: inserting for home is refused" eq "$(status "$r")" 403
r=$(req GET "/rest/v1/profiles?identity_id=eq.$home&select=bio" "$person")
check "home's profile is unchanged" eq "$(body "$r" | jq -r '.[0].bio')" "home bio"
r=$(req PATCH "/rest/v1/profiles?identity_id=eq.$work" "$scoped" '{"bio":"work bio"}')
check "scoped: writes its own identity" eq "$(body "$r" | jq -r '.[0].bio')" "work bio"
r=$(req POST /rest/v1/rpc/mint_scoped_session "$scoped" "{\"target\":\"$home\",\"device_name\":\"escape\"}")
check "scoped: cannot mint a session for another identity" eq "$(status "$r")" 403
r=$(req POST /rest/v1/rpc/create_identity "$scoped" "{\"handle\":\"x$tag\",\"display_name\":\"X\"}")
check "scoped: cannot create an identity" eq "$(status "$r")" 403
r=$(req PUT /auth/v1/user "$scoped" '{"password":"taken over 12345"}')
check "scoped: cannot change the account password (gateway)" eq "$(status "$r") $(body "$r" | jq -r .error_code)" "403 scoped_session"
r=$(req POST '/auth/v1/token?grant_type=refresh_token' "$PALM_ANON_KEY" "{\"refresh_token\":\"$(jq -r .refresh_token <<<"$exchange")\"}")
check "a second refresh keeps the scope" eq "$(claims "$(body "$r" | jq -r .access_token)" | jq -r .palm_identity)" "$work"
refresh=$(body "$r" | jq -r .refresh_token)
r=$(req POST /rest/v1/rpc/whoami "$scoped" '{}')
check "whoami reports the scope" eq "$(body "$r" | jq -r .identity.id)" "$work"

printf 'avatar %s' "$tag" > "$PALM_STATE_DIR/smoke-avatar.png"
up() { curl -s -o /dev/null -w '%{http_code}' -X POST "$api/storage/v1/object/avatars/$1/avatar.png" \
	-H "apikey: $PALM_ANON_KEY" -H "Authorization: Bearer $2" -H 'Content-Type: image/png' \
	-H 'x-upsert: true' --data-binary @"$PALM_STATE_DIR/smoke-avatar.png"; }
check "scoped: uploads its own avatar" eq "$(up "$work" "$scoped")" 200
code=$(up "$home" "$scoped")
check "scoped: uploading home's avatar is refused" eq "$([ "$code" = 400 ] || [ "$code" = 403 ] && echo refused || echo "$code")" refused
check "person uploads home's avatar" eq "$(up "$home" "$person")" 200
code=$(curl -s -o /dev/null -w '%{http_code}' "$api/storage/v1/object/authenticated/avatars/$home/avatar.png" \
	-H "apikey: $PALM_ANON_KEY" -H "Authorization: Bearer $scoped")
check "scoped: downloading home's avatar is refused" eq "$([ "$code" = 400 ] || [ "$code" = 404 ] || [ "$code" = 403 ] && echo refused || echo "$code")" refused

r=$(req POST /rest/v1/rpc/revoke_device "$person" "{\"device\":\"$device\"}")
check "person revokes the device" eq "$(status "$r")" 200
r=$(req GET '/rest/v1/identities?select=id' "$scoped")
check "revoked: the outstanding access token is refused at once" eq "$(status "$r")" 401
r=$(req POST '/auth/v1/token?grant_type=refresh_token' "$PALM_ANON_KEY" "{\"refresh_token\":\"$refresh\"}")
check "revoked: the refresh token no longer works" eq "$(status "$r")" 400

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
