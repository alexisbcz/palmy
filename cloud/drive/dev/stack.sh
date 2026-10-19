#!/usr/bin/env bash
# The drive's development stack: cloud/dev (the shared host-network Supabase
# stack: Postgres, GoTrue, PostgREST, Storage behind Kong), run as its own
# instance on ports 56500-56519 so it never meets another worktree's.
#
#   stack.sh up        start it (cloud/dev/up.sh applies every migration)
#   stack.sh reset     empty the drive and remove the seeded people, quickly
#   stack.sh test      every drive_ pgTAP file, through cloud/dev/test.sh
#   stack.sh env       the environment the daemon, CLI and app read
#   stack.sh psql ...  psql as postgres
#   stack.sh down      stop it (cloud/dev/down.sh)
#
# Requests go through the gateway, as they will in production:
# <api>/rest/v1 and <api>/storage/v1, with the anon key as apikey.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DEV="$ROOT/cloud/dev"
STACK=(--name "${DRIVE_STACK:-drive}" --port-base "${DRIVE_PORT_BASE:-56500}")

# shellcheck source=/dev/null
source "$DEV/env.sh" "${STACK[@]}"

psql_() { "$DEV/psql.sh" "${STACK[@]}" "$@"; }

case "${1:-up}" in
up) "$DEV/up.sh" "${STACK[@]}" ;;
reset)
	psql_ <<-'SQL'
	set storage.allow_delete_query = 'true';
	delete from storage.objects where bucket_id = 'drive';
	delete from public.drive_links;
	delete from public.drive_shares;
	update public.drive_items set version_id = null;
	delete from public.drive_versions;
	delete from public.drive_items;
	delete from public.drive_quotas;
	delete from public.identities where id in ('d1111111-1111-4111-8111-111111111111',
		'd2222222-2222-4222-8222-222222222222', 'd3333333-3333-4333-8333-333333333333');
	delete from auth.users where id in ('d0000000-0000-4000-8000-0000000a11ce',
		'd0000000-0000-4000-8000-000000000b0b');
	SQL
	;;
test) "$DEV/test.sh" "${STACK[@]}" drive_ ;;
env)
	cat <<-EOF
	export PALM_SUPABASE_URL=$PALM_API_URL/rest/v1
	export PALM_STORAGE_URL=$PALM_API_URL/storage/v1
	export PALM_SUPABASE_ANON_KEY=$PALM_ANON_KEY
	export PALM_DRIVE_JWT_SECRET=$PALM_JWT_SECRET
	export PALM_CLOUD_URL=$PALM_API_URL
	export PALM_CLOUD_ANON_KEY=$PALM_ANON_KEY
	EOF
	;;
psql) shift; psql_ "$@" ;;
down) "$DEV/down.sh" "${STACK[@]}" ;;
*) echo "usage: stack.sh up|reset|test|env|psql|down" >&2; exit 2 ;;
esac
