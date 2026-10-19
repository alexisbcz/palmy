#!/usr/bin/env bash
# A complete local collaboration stack: database, sync server, two accounts.
#
#   cloud/collab/dev/up.sh [--reset] [--port-base 62521] [--collab-port 62590] [--state DIR]
#
# 1. cloud/dev/up.sh brings up Postgres, GoTrue and PostgREST with every
#    migration applied (project "office" on the given port base).
# 2. palm-collab and palm-collab-cli are built into $STATE/bin.
# 3. Two people are signed up, each with token store under $STATE:
#      alice.martin@collab.test  identities: alice.martin (Alice Martin, indigo), northwind (work, emerald)
#      bob.okafor@collab.test identity: bob.okafor (Bob Okafor, amber)
# 4. palm-collab is started in the background (log: $STATE/server.log).
#
# It prints the environment to export so apps find all of it:
#   PALM_CLOUD_URL, PALM_COLLAB_URL, PALM_COLLAB_DIR, and per person PALM_CLOUD_DIR.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE=62521
CPORT=62590
STATE="${TMPDIR:-/tmp}/palm-collab-dev"
RESET=""
while [ $# -gt 0 ]; do
	case "$1" in
	--reset) RESET=--reset ;;
	--port-base) BASE="$2"; shift ;;
	--collab-port) CPORT="$2"; shift ;;
	--state) STATE="$2"; shift ;;
	*) echo "up.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
mkdir -p "$STATE/bin"
"$ROOT/cloud/dev/up.sh" --name office --port-base "$BASE" $RESET >/dev/null

SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
export PALM_CLOUD_URL="http://127.0.0.1:$BASE"
export PALM_COLLAB_URL="ws://127.0.0.1:$CPORT"
export PALM_COLLAB_DIR="$STATE/local"

(cd "$ROOT" && odin build cloud/collab/server -o:speed -out:"$STATE/bin/palm-collab")
(cd "$ROOT" && odin build cloud/collab/cli -out:"$STATE/bin/palm-collab-cli")

if [ -f "$STATE/server.pid" ] && kill -0 "$(cat "$STATE/server.pid")" 2>/dev/null; then
	kill "$(cat "$STATE/server.pid")" || true
	sleep 0.3
fi
PALM_COLLAB_SERVICE_KEY="$SERVICE_KEY" nohup "$STATE/bin/palm-collab" --port "$CPORT" >"$STATE/server.log" 2>&1 &
echo $! >"$STATE/server.pid"

cli() { "$STATE/bin/palm-collab-cli" "$@"; }
if [ -n "$RESET" ] || [ ! -f "$STATE/acct-alice/session.json" ]; then
	rm -rf "$STATE/acct-alice" "$STATE/acct-bob" "$STATE/local"
	mkdir -p "$STATE/acct-alice" "$STATE/acct-bob"
	cli --dir "$STATE/acct-alice" signup alice.martin@collab.test correct-horse-1 >/dev/null
	cli --dir "$STATE/acct-alice" identity alice.martin "Alice Martin" personal indigo >/dev/null
	cli --dir "$STATE/acct-alice" identity northwind "Northwind" work emerald >/dev/null
	cli --dir "$STATE/acct-bob" signup bob.okafor@collab.test correct-horse-2 >/dev/null
	cli --dir "$STATE/acct-bob" identity bob.okafor "Bob Okafor" personal amber >/dev/null
fi

cat <<ENV
export PALM_CLOUD_URL=$PALM_CLOUD_URL
export PALM_COLLAB_URL=$PALM_COLLAB_URL
export PALM_COLLAB_DIR=$PALM_COLLAB_DIR
# Alice:  PALM_CLOUD_DIR=$STATE/acct-alice
# Bob:    PALM_CLOUD_DIR=$STATE/acct-bob
# server: $STATE/server.log (pid $(cat "$STATE/server.pid"))
ENV
