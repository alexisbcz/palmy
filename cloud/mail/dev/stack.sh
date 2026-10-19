#!/usr/bin/env bash
# A minimal Supabase stack for the mail server, on the host network.
#
#   cloud/mail/dev/stack.sh up        Postgres, GoTrue (auth) and PostgREST
#   cloud/mail/dev/stack.sh migrate   apply cloud/supabase/migrations, then the dev seed
#   cloud/mail/dev/stack.sh test      run cloud/supabase/tests/mail_*.sql with pgTAP
#   cloud/mail/dev/stack.sh psql      a shell on the database
#   cloud/mail/dev/stack.sh down      remove the containers (the data goes with them)
#
# Why not `supabase start`: on this host the firewall blocks Docker bridge
# networking, so every container here runs with --network host on ports in
# the 555xx range, which keeps it clear of a default stack on 543xx. When the
# accounts area's cloud/dev stack lands, this script should give way to it.
#
# Nothing here sends mail. GoTrue has no SMTP configured and autoconfirms
# sign-ups, so it never tries to.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

PG_IMAGE=public.ecr.aws/supabase/postgres:17.6.1.171
AUTH_IMAGE=public.ecr.aws/supabase/gotrue:v2.197.0
REST_IMAGE=public.ecr.aws/supabase/postgrest:v16.3

source "$HERE/env.sh"

db=palm-mail-db
auth=palm-mail-auth
rest=palm-mail-rest

psql_c() { docker exec -i "$db" psql -v ON_ERROR_STOP=1 -q -U supabase_admin -p "$PALM_PG_PORT" -d postgres "$@"; }

wait_for() {
	local what=$1; shift
	for _ in $(seq 1 60); do
		if "$@" >/dev/null 2>&1; then return 0; fi
		sleep 1
	done
	echo "stack: $what did not come up" >&2
	return 1
}

case "${1:-}" in
up)
	if ! docker ps --format '{{.Names}}' | grep -qx "$db"; then
		docker rm -f "$db" >/dev/null 2>&1 || true
		docker run -d --name "$db" --network host -e POSTGRES_PASSWORD=postgres \
			"$PG_IMAGE" postgres -D /etc/postgresql -p "$PALM_PG_PORT" >/dev/null
	fi
	wait_for postgres docker exec "$db" pg_isready -p "$PALM_PG_PORT" -U postgres
	sleep 2
	if ! docker ps --format '{{.Names}}' | grep -qx "$auth"; then
		docker rm -f "$auth" >/dev/null 2>&1 || true
		docker run -d --name "$auth" --network host \
			-e GOTRUE_API_HOST=127.0.0.1 -e PORT="$PALM_AUTH_PORT" \
			-e API_EXTERNAL_URL="http://127.0.0.1:$PALM_AUTH_PORT" \
			-e GOTRUE_DB_DRIVER=postgres \
			-e "GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:postgres@127.0.0.1:$PALM_PG_PORT/postgres?search_path=auth" \
			-e GOTRUE_SITE_URL=http://127.0.0.1:3000 \
			-e GOTRUE_JWT_SECRET="$PALM_JWT_SECRET" -e GOTRUE_JWT_EXP=3600 -e GOTRUE_JWT_AUD=authenticated \
			-e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated -e GOTRUE_JWT_ADMIN_ROLES=service_role \
			-e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=true \
			-e GOTRUE_DISABLE_SIGNUP=false \
			"$AUTH_IMAGE" >/dev/null
	fi
	wait_for gotrue curl -sf "http://127.0.0.1:$PALM_AUTH_PORT/health"
	if ! docker ps --format '{{.Names}}' | grep -qx "$rest"; then
		docker rm -f "$rest" >/dev/null 2>&1 || true
		docker run -d --name "$rest" --network host \
			-e "PGRST_DB_URI=postgres://authenticator:postgres@127.0.0.1:$PALM_PG_PORT/postgres" \
			-e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
			-e PGRST_JWT_SECRET="$PALM_JWT_SECRET" \
			-e PGRST_SERVER_HOST=127.0.0.1 -e PGRST_SERVER_PORT="$PALM_REST_PORT" \
			"$REST_IMAGE" >/dev/null
	fi
	wait_for postgrest curl -sf "http://127.0.0.1:$PALM_REST_PORT/"
	echo "stack: postgres :$PALM_PG_PORT  auth :$PALM_AUTH_PORT  rest :$PALM_REST_PORT"
	;;
migrate)
	psql_c -c "set client_min_messages = warning; create table if not exists public._palm_migrations (version text primary key)" >/dev/null
	for f in "$ROOT"/cloud/supabase/migrations/*.sql; do
		v=$(basename "$f" | cut -d_ -f1)
		if [ -n "$(psql_c -Atc "select 1 from public._palm_migrations where version = '$v'")" ]; then
			continue
		fi
		echo "migrate: $(basename "$f")"
		# Run as postgres, the role a hosted project's migrations run as.
		{ echo "set role postgres;"; cat "$f"; echo "reset role; insert into public._palm_migrations values ('$v');"; } \
			| psql_c -1 >/dev/null
	done
	psql_c -c "revoke all on public._palm_migrations from anon, authenticated" >/dev/null
	psql_c < "$HERE/seed.sql" >/dev/null
	# PostgREST caches the schema; tell it to look again.
	psql_c -c "notify pgrst, 'reload schema'" >/dev/null
	echo "migrate: done"
	;;
test)
	psql_c -c "create extension if not exists pgtap with schema extensions" >/dev/null
	status=0
	for f in "$ROOT"/cloud/supabase/tests/mail_*.sql; do
		echo "== $(basename "$f")"
		out=$(docker exec -i "$db" psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -p "$PALM_PG_PORT" -d postgres < "$f" 2>&1) || status=1
		echo "$out"
		if echo "$out" | grep -q '^not ok\|Looks like you'; then status=1; fi
	done
	[ $status = 0 ] && echo "test: all passed" || echo "test: FAILED"
	exit $status
	;;
psql)
	shift
	docker exec -it "$db" psql -U supabase_admin -p "$PALM_PG_PORT" -d postgres "$@"
	;;
down)
	docker rm -f "$rest" "$auth" "$db" >/dev/null 2>&1 || true
	echo "stack: removed"
	;;
*)
	sed -n '2,10p' "$0"
	exit 2
	;;
esac
