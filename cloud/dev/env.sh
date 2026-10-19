# Sourced by up.sh, down.sh, test.sh and psql.sh. Parses --port-base / --name
# and derives every port from the base, so two stacks never collide.
#
#   base+0   API gateway (kong)            54321
#   base+1   Postgres                      54322
#   base+10  GoTrue                        54331
#   base+11  PostgREST                     54332
#   base+12  PostgREST admin               54333
#   base+13  Storage                       54334
#   base+14  Storage admin                 54335
#
# Everything binds 127.0.0.1 and runs with network_mode: host (see README.md).

PALM_PORT_BASE=${PALM_PORT_BASE:-54321}
PALM_NAME=${PALM_NAME:-palmy}
PALM_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--port-base) PALM_PORT_BASE=$2; shift 2 ;;
	--port-base=*) PALM_PORT_BASE=${1#*=}; shift ;;
	--name) PALM_NAME=$2; shift 2 ;;
	--name=*) PALM_NAME=${1#*=}; shift ;;
	*) PALM_ARGS+=("$1"); shift ;;
	esac
done

case "$PALM_PORT_BASE" in
''|*[!0-9]*) echo "port base must be a number: $PALM_PORT_BASE" >&2; exit 2 ;;
esac
case "$PALM_NAME" in
''|*[!a-z0-9_-]*) echo "name must be [a-z0-9_-]: $PALM_NAME" >&2; exit 2 ;;
esac

export PALM_NAME PALM_PORT_BASE
export PALM_API_PORT=$((PALM_PORT_BASE))
export PALM_DB_PORT=$((PALM_PORT_BASE + 1))
export PALM_AUTH_PORT=$((PALM_PORT_BASE + 10))
export PALM_REST_PORT=$((PALM_PORT_BASE + 11))
export PALM_REST_ADMIN_PORT=$((PALM_PORT_BASE + 12))
export PALM_STORAGE_PORT=$((PALM_PORT_BASE + 13))
export PALM_STORAGE_ADMIN_PORT=$((PALM_PORT_BASE + 14))

# The well-known local development secret and keys, the same ones the
# Supabase CLI prints. They sign nothing that leaves this machine.
export PALM_JWT_SECRET=super-secret-jwt-token-with-at-least-32-characters-long
export PALM_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
export PALM_SERVICE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU
export PALM_API_URL=http://127.0.0.1:$PALM_API_PORT
export PALM_DB_URL=postgresql://postgres:postgres@127.0.0.1:$PALM_DB_PORT/postgres

PALM_DEV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PALM_SUPABASE_DIR=$(cd -- "$PALM_DEV_DIR/../supabase" && pwd)
PALM_STATE_DIR=$PALM_DEV_DIR/.state/$PALM_NAME
export PALM_DEV_DIR PALM_SUPABASE_DIR PALM_STATE_DIR

palm_compose() {
	docker compose -p "palm-$PALM_NAME" -f "$PALM_DEV_DIR/compose.yml" "$@"
}

palm_db_container() {
	echo "palm-$PALM_NAME-db"
}

# psql inside the database container, as postgres. Extra arguments are
# passed through; SQL comes from stdin unless -c or -f is given.
palm_psql() {
	docker exec -i "$(palm_db_container)" psql -X -q -v ON_ERROR_STOP=1 \
		-h 127.0.0.1 -p "$PALM_DB_PORT" -U postgres -d postgres "$@"
}

# The same, as supabase_admin (a superuser), for what postgres may not do.
palm_psql_admin() {
	docker exec -i "$(palm_db_container)" psql -X -q -v ON_ERROR_STOP=1 \
		-h 127.0.0.1 -p "$PALM_DB_PORT" -U supabase_admin -d postgres "$@"
}
