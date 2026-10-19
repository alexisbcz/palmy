#!/usr/bin/env bash
# Run the pgTAP tests in cloud/supabase/tests against a running stack.
#
#   ./test.sh [--name X] [--port-base N] [PATTERN...]
#
# PATTERN filters by file name prefix (accounts_, mail_, drive_). Each file
# is run in its own psql session and is expected to wrap itself in
# begin ... rollback, so tests leave nothing behind. Exit status is 0 only if
# every plan ran to completion with no failures.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh" "$@"

if ! docker exec "$(palm_db_container)" true 2>/dev/null; then
	echo "test.sh: stack '$PALM_NAME' is not running; start it with up.sh" >&2
	exit 6
fi

palm_psql -c 'set client_min_messages = warning' -c 'create extension if not exists pgtap with schema extensions' >/dev/null

files=()
for f in "$PALM_SUPABASE_DIR"/tests/*.sql; do
	[ -e "$f" ] || continue
	b=$(basename "$f")
	if [ ${#PALM_ARGS[@]} -gt 0 ]; then
		keep=0
		for p in "${PALM_ARGS[@]}"; do
			case "$b" in "$p"*) keep=1 ;; esac
		done
		[ $keep = 1 ] || continue
	fi
	files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
	echo "test.sh: no test files matched" >&2
	exit 3
fi

total=0 failed=0 bad_files=()
for f in "${files[@]}"; do
	b=$(basename "$f")
	set +e
	out=$(palm_psql -tA -P footer=off < "$f" 2>&1)
	status=$?
	set -e
	pass=$(grep -cE '^ok ' <<<"$out" || true)
	fail=$(grep -cE '^not ok ' <<<"$out" || true)
	plan=$(grep -oE '^1\.\.[0-9]+' <<<"$out" | head -1 | cut -d. -f3)
	ok=1
	[ $status -eq 0 ] || ok=0
	[ "$fail" -eq 0 ] || ok=0
	[ -n "$plan" ] && [ "$plan" -eq $((pass + fail)) ] || ok=0
	grep -q '^# Looks like' <<<"$out" && ok=0
	total=$((total + pass + fail))
	failed=$((failed + fail))
	if [ $ok = 1 ]; then
		printf 'ok    %-40s %s/%s\n' "$b" "$pass" "${plan:-?}"
	else
		printf 'FAIL  %-40s %s/%s\n' "$b" "$pass" "${plan:-?}"
		grep -vE '^ok ' <<<"$out" | sed 's/^/      /'
		bad_files+=("$b")
	fi
done

echo "${#files[@]} file(s), $total assertion(s), $failed failed, ${#bad_files[@]} file(s) not ok"
[ ${#bad_files[@]} -eq 0 ]
