#!/usr/bin/env bash
# Drive sync badges against a real drive server.
#
#   apps/files/drive-e2e.sh [shots-dir]
#
# Starts a private instance of the drive's development stack (cloud/dev's
# containers: Postgres, GoTrue, PostgREST, Storage behind Kong, on loopback
# ports 57340-57354 so it never meets another worktree's), seeds it, builds
# palm-drive and files into a private directory, stages two devices of one
# identity (the scenario is in selftest_drive.odin), and runs
# `files --selftest` with FILES_DRIVE_E2E set, so the live section reads the
# badges from the real palm-drive through the window's own status thread.
# With a shots dir, it also renders the folder with its real badges.
#
# Needs docker (the stack), python3 (seed.sh mints the tokens) and Odin. The
# stack is left running for the next run; `DRIVE_STACK=files-badges
# DRIVE_PORT_BASE=57340 cloud/drive/dev/stack.sh down` stops it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SHOTS="${1:-}"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"
export DRIVE_STACK="${DRIVE_STACK:-files-badges}" DRIVE_PORT_BASE="${DRIVE_PORT_BASE:-57340}"
STACK="$ROOT/cloud/drive/dev/stack.sh"

command -v docker >/dev/null || { echo "drive-e2e: docker is needed for the drive stack"; exit 6; }
"$STACK" up >/dev/null 2>&1 || { echo "drive-e2e: the drive stack did not start"; "$STACK" up 2>&1 | tail -5; exit 6; }
"$STACK" reset >/dev/null 2>&1 || { echo "drive-e2e: the stack reset failed"; exit 1; }

W="$(mktemp -d /tmp/files-drive-e2e-XXXXXX)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
COLL=(-collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" -collection:kit="$ROOT/apps/kit")
"$ODIN" build "$ROOT/cloud/drive/palm-drive" "${COLL[@]}" -collection:drive="$ROOT/cloud/drive" -out:"$W/bin/palm-drive" || exit 1
"$ODIN" build "$HERE" "${COLL[@]}" -out:"$W/bin/files" || exit 1

"$ROOT/cloud/drive/dev/seed.sh" "$W/conf" >/dev/null 2>&1 || { echo "drive-e2e: seeding failed"; exit 1; }
sed -e 's#^url = .*#url = http://127.0.0.1:9#' -e 's#^storage = .*#storage = http://127.0.0.1:9#' \
  "$W/conf/drive.conf" >"$W/conf/offline.conf"

ID=alice.northwind
dev() { # dev A|B <palm-drive args>: one device of the same identity
  local d=$1; shift
  PALM_DRIVE_CONFIG="$W/conf/drive.conf" PALM_DRIVE_DIR="$W/$d/Drive" PALM_DRIVE_STATE="$W/$d/state" \
    PALM_DRIVE_DEVICE="device-$d" PALM_IDENTITY=$ID "$W/bin/palm-drive" "$@" >/dev/null 2>&1
}
A="$W/A/Drive/$ID"; B="$W/B/Drive/$ID"
mkdir -p "$A/notes" "$A/photos"
echo "a" >"$A/notes/a.md"; echo "b" >"$A/notes/b.md"; echo "report" >"$A/report.txt"
echo "old" >"$A/old.txt"; echo "x" >"$A/photos/x.txt"
dev A sync --json && dev B sync --json || { echo "drive-e2e: the first syncs failed"; exit 1; }
[ -f "$B/notes/a.md" ] || { echo "drive-e2e: device B did not receive the first upload"; exit 1; }
# B adds a file and edits the report, and syncs; A edits the same report,
# edits a note and adds a file in new folders, and does not sync.
echo "from b" >"$B/photos/from-b.txt"; echo "report, as B has it" >"$B/report.txt"
dev B sync --json
echo "a, edited" >"$A/notes/a.md"; mkdir -p "$A/new/dir"; echo "c" >"$A/new/dir/c.md"
echo "report, as A has it" >"$A/report.txt"

# files runs as device A: palm-drive on PATH, its environment the device's.
PATH="$W/bin:$PATH" \
PALM_DRIVE_CONFIG="$W/conf/drive.conf" PALM_DRIVE_DIR="$W/A/Drive" PALM_DRIVE_STATE="$W/A/state" \
PALM_DRIVE_DEVICE=device-A PALM_IDENTITY=$ID \
FILES_DRIVE_E2E=1 FILES_DRIVE_OFFLINE_CONFIG="$W/conf/offline.conf" FILES_DRIVE_E2E_SHOTS="$SHOTS" \
WAYLAND_DISPLAY= DISPLAY= HOME="$W/home" \
  "$W/bin/files" --selftest 2>&1 | tee "$W/selftest.log" | grep -E 'live|FAIL|checks'
grep -qE '^[0-9]+ checks, 0 failed' "$W/selftest.log"
