#!/usr/bin/env bash
# Start a local Palmframe cloud stack and apply cloud/supabase/migrations.
#
#   ./up.sh [--port-base N] [--name X] [--reset]
#
# Idempotent: run it again and it applies only the migrations it has not
# applied yet. --reset throws the database and stored files away first.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh" "$@"

reset=0
for a in "${PALM_ARGS[@]+"${PALM_ARGS[@]}"}"; do
	case "$a" in
	--reset) reset=1 ;;
	-h|--help) sed -n '2,8p' "$0"; exit 0 ;;
	*) echo "up.sh: unknown argument $a" >&2; exit 2 ;;
	esac
done

log() { printf '[%s] %s\n' "$PALM_NAME" "$*" >&2; }

wait_for() { # description, command...
	local what=$1; shift
	for _ in $(seq 1 180); do
		if "$@" >/dev/null 2>&1; then return 0; fi
		sleep 1
	done
	log "timed out waiting for $what"
	palm_compose logs --tail 40 >&2 || true
	exit 6
}

# Refuse to start on top of a port something else already holds, which with
# host networking would otherwise fail silently inside a container.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

if [ "$reset" = 1 ]; then
	log "reset: removing containers and volumes"
	palm_compose down -v --remove-orphans >/dev/null 2>&1 || true
fi

running=$(docker ps -q --filter "label=com.docker.compose.project=palm-$PALM_NAME" | wc -l)
if [ "$running" -eq 0 ]; then
	for p in $PALM_API_PORT $PALM_DB_PORT $PALM_AUTH_PORT $PALM_REST_PORT \
		$PALM_REST_ADMIN_PORT $PALM_STORAGE_PORT $PALM_STORAGE_ADMIN_PORT; do
		if port_busy "$p"; then
			log "port $p is already in use; pick another --port-base"
			exit 6
		fi
	done
fi

mkdir -p "$PALM_STATE_DIR"
sed -e "s/@AUTH_PORT@/$PALM_AUTH_PORT/g" \
    -e "s/@REST_PORT@/$PALM_REST_PORT/g" \
    -e "s/@STORAGE_PORT@/$PALM_STORAGE_PORT/g" \
    "$PALM_DEV_DIR/kong.yml.in" > "$PALM_STATE_DIR/kong.yml"

log "starting postgres on 127.0.0.1:$PALM_DB_PORT"
palm_compose up -d db >/dev/null 2>&1
wait_for postgres docker exec "$(palm_db_container)" pg_isready -q -h 127.0.0.1 -p "$PALM_DB_PORT" -U postgres
# The image's init finishes before it listens on TCP, but give the role
# passwords a moment to be the ones we expect.
wait_for "postgres login" palm_psql -c 'select 1'

log "starting auth, rest, storage, gateway"
palm_compose up -d auth rest storage kong >/dev/null 2>&1
wait_for auth curl -fsS "http://127.0.0.1:$PALM_AUTH_PORT/health"
wait_for storage curl -fsS "http://127.0.0.1:$PALM_STORAGE_PORT/status"
wait_for rest curl -fsS "http://127.0.0.1:$PALM_REST_PORT/"
wait_for gateway curl -fsS -o /dev/null "http://127.0.0.1:$PALM_API_PORT/auth/v1/health"

applied=0
for f in "$PALM_SUPABASE_DIR"/migrations/*.sql; do
	[ -e "$f" ] || continue
	base=$(basename "$f" .sql)
	version=${base%%_*}
	name=${base#*_}
	done_already=$(palm_psql -tA -c "select 1 from supabase_migrations.schema_migrations where version = '$version'")
	[ "$done_already" = 1 ] && continue
	log "migration $base"
	{
		cat "$f"
		printf '\ninsert into supabase_migrations.schema_migrations (version, name) values (%s, %s);\n' \
			"'$version'" "'$name'"
	} | palm_psql -1 >/dev/null
	applied=$((applied + 1))
done

# The development seed (cloud/supabase/seed.sql), after every migration.
if [ -f "$PALM_SUPABASE_DIR/seed.sql" ]; then
	palm_psql -1 -f - <"$PALM_SUPABASE_DIR/seed.sql" >/dev/null
	log "seed applied"
fi

palm_psql -c "notify pgrst, 'reload schema'; notify pgrst, 'reload config';" >/dev/null

log "$applied new migration(s) applied"
cat <<EOF
name         $PALM_NAME
API URL      $PALM_API_URL
DB URL       $PALM_DB_URL
anon key     $PALM_ANON_KEY
service key  $PALM_SERVICE_KEY
JWT secret   $PALM_JWT_SECRET
EOF
