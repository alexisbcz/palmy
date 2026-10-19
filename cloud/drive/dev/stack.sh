#!/usr/bin/env bash
# A minimal Supabase stack for the drive area: Postgres, Storage and PostgREST,
# all on the host network on ports 565xx.
#
# Why not `supabase start`: on this host ufw blocks Docker bridge networking,
# so the CLI's containers cannot reach each other. `--network host` works. The
# accounts area is building the full host-network stack in cloud/dev; once it
# lands, this script should go and the drive tests should run against that.
#
#   stack.sh up        start the three containers and apply every migration
#   stack.sh reset     drop and re-create the public schema, re-apply migrations
#   stack.sh test      run cloud/supabase/tests/drive_*.sql through pg_prove
#   stack.sh env       print the environment the daemon, CLI and app read
#   stack.sh down      stop and remove the containers (and the stored blobs)
#
# The images are pinned to the versions Supabase CLI 2.118.0 runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SUPA="$ROOT/cloud/supabase"

PG_IMAGE=public.ecr.aws/supabase/postgres:17.6.1.171
STORAGE_IMAGE=public.ecr.aws/supabase/storage-api:v1.77.0
REST_IMAGE=public.ecr.aws/supabase/postgrest:v16.3

PG_PORT=${DRIVE_PG_PORT:-56522}
REST_PORT=${DRIVE_REST_PORT:-56530}
STORAGE_PORT=${DRIVE_STORAGE_PORT:-56531}
JWT_SECRET=${DRIVE_JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}
PREFIX=${DRIVE_STACK:-drive}

ANON_KEY=$(python3 "$HERE/jwt.py" "$JWT_SECRET" role=anon exp=315360000)
SERVICE_KEY=$(python3 "$HERE/jwt.py" "$JWT_SECRET" role=service_role exp=315360000)

psql_su() { PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -q -h 127.0.0.1 -p "$PG_PORT" -U supabase_admin -d postgres "$@"; }
psql_pg() { PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -q -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres "$@"; }

wait_pg() {
	for _ in $(seq 60); do
		if PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	echo "postgres did not come up" >&2
	return 1
}

wait_http() {
	for _ in $(seq 60); do
		if curl -fsS -o /dev/null "$1" 2>/dev/null; then return 0; fi
		sleep 1
	done
	echo "$1 did not come up" >&2
	return 1
}

# The pieces the real stack gets from GoTrue, which this one does not run.
auth_stubs() {
	psql_su <<-'SQL'
	create or replace function auth.jwt() returns jsonb language sql stable as $$
		select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
	$$;
	create or replace function auth.uid() returns uuid language sql stable as $$
		select nullif(auth.jwt() ->> 'sub', '')::uuid
	$$;
	grant execute on function auth.jwt() to anon, authenticated, service_role;
	create extension if not exists pgtap with schema extensions;
	SQL
}

apply_migrations() {
	for f in "$SUPA"/migrations/*.sql; do
		echo "  migration $(basename "$f")" >&2
		psql_pg -f "$f"
	done
	# PostgREST caches the schema; ask it to reload.
	psql_pg -c "notify pgrst, 'reload schema'" || true
}

up() {
	if ! docker ps --format '{{.Names}}' | grep -qx "$PREFIX-db"; then
		docker rm -f "$PREFIX-db" >/dev/null 2>&1 || true
		docker run -d --name "$PREFIX-db" --network host \
			-e POSTGRES_PASSWORD=postgres \
			"$PG_IMAGE" postgres -c port="$PG_PORT" -c listen_addresses=127.0.0.1 \
			-c config_file=/etc/postgresql/postgresql.conf >/dev/null
	fi
	wait_pg
	psql_su -c "alter role authenticator with password 'postgres';
	            alter role supabase_storage_admin with password 'postgres';"
	auth_stubs

	if ! docker ps --format '{{.Names}}' | grep -qx "$PREFIX-storage"; then
		docker rm -f "$PREFIX-storage" >/dev/null 2>&1 || true
		docker run -d --name "$PREFIX-storage" --network host \
			-e SERVER_PORT="$STORAGE_PORT" -e SERVER_HOST=127.0.0.1 \
			-e ANON_KEY="$ANON_KEY" -e SERVICE_KEY="$SERVICE_KEY" \
			-e AUTH_JWT_SECRET="$JWT_SECRET" -e PGRST_JWT_SECRET="$JWT_SECRET" \
			-e AUTH_JWT_ALGORITHM=HS256 \
			-e DATABASE_URL="postgres://supabase_storage_admin:postgres@127.0.0.1:$PG_PORT/postgres" \
			-e FILE_SIZE_LIMIT=52428800 -e STORAGE_BACKEND=file \
			-e FILE_STORAGE_BACKEND_PATH=/var/lib/storage \
			-e TENANT_ID=stub -e REGION=local -e GLOBAL_S3_BUCKET=stub \
			-e ENABLE_IMAGE_TRANSFORMATION=false -e DB_INSTALL_ROLES=false \
			"$STORAGE_IMAGE" >/dev/null
	fi
	wait_http "http://127.0.0.1:$STORAGE_PORT/status"

	# Storage creates storage.objects in its own migrations; the drive
	# migration puts policies on it, so the order is storage first.
	for _ in $(seq 60); do
		if psql_pg -tAc "select to_regclass('storage.objects') is not null" | grep -q t; then break; fi
		sleep 1
	done

	if ! psql_pg -tAc "select to_regclass('public.identities') is not null" | grep -q t; then
		apply_migrations
	fi

	if ! docker ps --format '{{.Names}}' | grep -qx "$PREFIX-rest"; then
		docker rm -f "$PREFIX-rest" >/dev/null 2>&1 || true
		docker run -d --name "$PREFIX-rest" --network host \
			-e PGRST_DB_URI="postgres://authenticator:postgres@127.0.0.1:$PG_PORT/postgres" \
			-e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
			-e PGRST_JWT_SECRET="$JWT_SECRET" -e PGRST_SERVER_PORT="$REST_PORT" \
			-e PGRST_SERVER_HOST=127.0.0.1 -e PGRST_DB_USE_LEGACY_GUCS=false \
			"$REST_IMAGE" >/dev/null
	fi
	wait_http "http://127.0.0.1:$REST_PORT/"
	echo "drive stack up: postgres :$PG_PORT  rest :$REST_PORT  storage :$STORAGE_PORT" >&2
}

reset() {
	psql_su <<-'SQL'
	drop schema if exists public cascade;
	create schema public;
	grant usage on schema public to anon, authenticated, service_role;
	grant all on schema public to postgres, anon, authenticated, service_role;
	alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
	alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
	alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
	set storage.allow_delete_query = 'true';
	delete from storage.objects;
	delete from storage.buckets;
	SQL
	# Policies on storage.objects survive a public-schema drop only if they do
	# not reference public; ours do, so cascade took them. Re-apply.
	auth_stubs
	apply_migrations
	docker exec "$PREFIX-storage" sh -c 'rm -rf /var/lib/storage/*' 2>/dev/null || true
}

run_tests() {
	# The files are plain pgTAP; `supabase test db` runs them unchanged on the
	# full stack. Here psql runs each one and this reads the TAP back.
	local fail=0 out plan got
	for f in "$SUPA"/tests/drive_*.sql; do
		out=$(PGPASSWORD=postgres psql -X -q -t -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -f "$f" 2>&1 \
			| grep -E '^ *(ok|not ok|#|1\.\.|psql:.*ERROR)' | sed 's/^ //; s/ *+$//')
		echo "# $(basename "$f")"
		echo "$out"
		if echo "$out" | grep -qE '^(not ok|psql:.*ERROR|# Looks like)'; then fail=1; fi
		plan=$(echo "$out" | sed -n 's/^1\.\.\([0-9]*\)$/\1/p')
		got=$(echo "$out" | grep -c '^ok ' || true)
		echo "# $got/$plan passed"
		[ "$got" = "$plan" ] || fail=1
	done
	return $fail
}

env_out() {
	cat <<-EOF
	export PALM_SUPABASE_URL=http://127.0.0.1:$REST_PORT
	export PALM_STORAGE_URL=http://127.0.0.1:$STORAGE_PORT
	export PALM_SUPABASE_ANON_KEY=$ANON_KEY
	export PALM_DRIVE_JWT_SECRET=$JWT_SECRET
	export PALM_DRIVE_PG=postgres://postgres:postgres@127.0.0.1:$PG_PORT/postgres
	EOF
}

case "${1:-up}" in
up) up ;;
reset) reset ;;
test) run_tests ;;
env) env_out ;;
psql) shift; psql_pg "$@" ;;
down) docker rm -f "$PREFIX-rest" "$PREFIX-storage" "$PREFIX-db" >/dev/null 2>&1 || true ;;
*) echo "usage: stack.sh up|reset|test|env|psql|down" >&2; exit 2 ;;
esac
