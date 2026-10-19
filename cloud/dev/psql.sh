#!/usr/bin/env bash
# psql into a running stack's database as postgres.
#
#   ./psql.sh [--name X] [--port-base N] [psql args...]
#   echo 'select 1' | ./psql.sh
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh" "$@"
if [ -t 0 ]; then
	exec docker exec -it "$(palm_db_container)" psql -X -h 127.0.0.1 -p "$PALM_DB_PORT" \
		-U postgres -d postgres "${PALM_ARGS[@]+"${PALM_ARGS[@]}"}"
fi
palm_psql "${PALM_ARGS[@]+"${PALM_ARGS[@]}"}"
