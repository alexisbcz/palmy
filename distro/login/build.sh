#!/usr/bin/env bash
# Build palm-login and the greeter, and run both selftests against each other.
# Outputs: distro/out/bin/palm-login, distro/out/bin/greeter
#
#   distro/login/build.sh          build
#   distro/login/build.sh --test   build, then run the selftests (no root, no
#                                  sessions, nothing outside a temp directory)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/distro/out/bin"
mkdir -p "$OUT"
cd "$ROOT"

COLL=(-collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn)
odin build distro/login -o:speed "${COLL[@]}" -out:"$OUT/palm-login"
odin build apps/greeter -o:speed "${COLL[@]}" -out:"$OUT/greeter"
echo "palm-login -> $OUT/palm-login"
echo "greeter    -> $OUT/greeter"

if [ "${1:-}" = "--test" ]; then
	"$OUT/palm-login" --selftest

	# The greeter's own selftest, pointed at palm-login in --test mode
	# instead of the mock greetd: the two halves of the protocol agree.
	T="$(mktemp -d)"
	trap 'kill "$PID" 2>/dev/null || true; rm -rf "$T"' EXIT
	printf 'palm:x:1000:1000:Palm:/home/palm:/bin/sh\n' >"$T/passwd"
	printf 'palm:%s:19000::::::\n' "$("$OUT/palm-login" --hash palm --salt greeterselftest)" >"$T/shadow"
	printf 'palm:x:1000:\n' >"$T/group"
	"$OUT/palm-login" --test --sock "$T/sock" --passwd "$T/passwd" --shadow "$T/shadow" --group "$T/group" 2>"$T/log" &
	PID=$!
	for _ in $(seq 50); do [ -S "$T/sock" ] && break; sleep 0.1; done
	"$OUT/greeter" --selftest --sock "$T/sock" --user palm --password palm
fi
