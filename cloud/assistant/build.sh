#!/usr/bin/env bash
# Build the assistant and every binary it uses, into cloud/assistant/bin/.
#
#   cloud/assistant/build.sh            all of them, optimised
#   cloud/assistant/build.sh debug      with -debug
#   cloud/assistant/build.sh ai mail    only these
#
# bin/        the person's side: ai, and the stack's palm-davd
# bin/tools/  the tool binaries, and nothing else. This directory is the
#             only place the sandbox lets the assistant execute anything
#             from, so what is in it is exactly what it can run.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
opt=(-o:speed)
targets=()
for a in "$@"; do
	case "$a" in
	debug) opt=(-debug) ;;
	*) targets+=("$a") ;;
	esac
done
[ ${#targets[@]} -gt 0 ] || targets=(ai mail sandbox-check drive calendar contacts notes chat forge accounts davd)
coll=(
	-collection:palmy="$root/palmy"
	-collection:shadcn="$root/shadcn"
	-collection:kit="$root/apps/kit"
	-collection:drive="$root/cloud/drive"
	-collection:forge="$root/cloud/forge"
)
mkdir -p "$here/bin/tools"
pids=()
build() { # out, package
	odin build "$2" "${coll[@]}" "${opt[@]}" -out:"$1" >"$1.log" 2>&1 && rm -f "$1.log" || {
		echo "build failed: $2" >&2; cat "$1.log" >&2; return 1; }
}
for t in "${targets[@]}"; do
	case "$t" in
	ai) build "$here/bin/ai" "$root/apps/ai" & ;;
	mail) build "$here/bin/tools/palm-mail" "$here/mail" & ;;
	sandbox-check) build "$here/bin/palm-sandbox-check" "$here/sandbox/check" & ;;
	davd) build "$here/bin/palm-davd" "$root/cloud/dav" & ;;
	accounts) build "$here/bin/accounts" "$root/apps/accounts" & ;;
	drive | calendar | contacts | notes | chat | forge) build "$here/bin/tools/$t" "$root/apps/$t" & ;;
	*) echo "unknown target $t" >&2; exit 2 ;;
	esac
	pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ $fail = 0 ] && echo "built: ${targets[*]} -> ${here#$root/}/bin"
exit $fail
