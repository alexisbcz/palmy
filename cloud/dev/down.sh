#!/usr/bin/env bash
# Stop a local stack.
#
#   ./down.sh [--name X] [--volumes]
#
# Without --volumes the database and stored files survive for the next up.sh.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh" "$@"

flags=(--remove-orphans)
for a in "${PALM_ARGS[@]+"${PALM_ARGS[@]}"}"; do
	case "$a" in
	--volumes|-v) flags+=(-v) ;;
	-h|--help) sed -n '2,6p' "$0"; exit 0 ;;
	*) echo "down.sh: unknown argument $a" >&2; exit 2 ;;
	esac
done

mkdir -p "$PALM_STATE_DIR"
touch "$PALM_STATE_DIR/kong.yml"
palm_compose down "${flags[@]}"
