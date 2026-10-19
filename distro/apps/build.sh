#!/usr/bin/env bash
# Build every palmy application that builds into distro/out/bin/<name>.
#
# An application is any directory under apps/ whose package has an entry
# point. Each is built exactly the way CONTRACT.md says Odin binaries are
# built, from the repository root, so a binary here is the binary the image
# ships. A failure is recorded and skipped rather than stopping the run: the
# application set is wide and owned by many hands, and one broken app must not
# hold back the forty that build.
#
#   distro/apps/build.sh                 every application
#   distro/apps/build.sh term files      just these
#   JOBS=8 distro/apps/build.sh          parallelism (default: half the cores)
#
# Output: distro/out/bin/<name>, logs in distro/build/apps/logs/<name>.log,
# and a summary in distro/build/apps/results.tsv (source, binary,
# built|failed, seconds).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(dirname "$HERE")"
ROOT="$(dirname "$DISTRO")"
OUT="$DISTRO/out/bin"
LOGS="$DISTRO/build/apps/logs"
RESULTS="$DISTRO/build/apps/results.tsv"
JOBS="${JOBS:-$(( $(nproc) / 2 ))}"
ODIN="${ODIN:-odin}"
mkdir -p "$OUT" "$LOGS"

# Directories under apps/ that are not applications: the shared kit, the
# prose library the docs app imports, the tools tree (an X11 harness), and
# cloudkit (the Odin client library the cloud apps import).
NOT_APPS=" kit prose tools cloudkit "

# Where an application's binary name must differ from its directory. apps/palm
# is the application command dispatcher (`palm schema`, `palm notes ...`);
# /usr/bin/palm on the installed system is the package manager from
# distro/palm, so the dispatcher ships under another name. See
# distro/notes/apps.md.
binary_name() {
	case "$1" in
	palm) echo "palm-apps" ;;
	*/*) echo "$(source_extra_name "$1")" ;;
	*) echo "$1" ;;
	esac
}

# Programs that live in a subdirectory of an application rather than at its
# top: the prose engine the docs app runs as a subprocess, and the chat relay
# the chat app connects to, and the drive sync daemon, which lives with the
# drive service under cloud/. Named as <dir under apps/>=<binary>.
EXTRAS="prose/cli=prose chat/server=chat-server ../cloud/drive/palm-drive=palm-drive"
source_extra_name() {
	for e in $EXTRAS; do
		[ "${e%%=*}" = "$1" ] && echo "${e#*=}"
	done
}

if [ "$#" -gt 0 ]; then
	apps=("$@")
else
	apps=()
	for d in "$ROOT"/apps/*/; do
		n="$(basename "$d")"
		case "$NOT_APPS" in *" $n "*) continue ;; esac
		ls "$d"*.odin >/dev/null 2>&1 || continue
		apps+=("$n")
	done
	for e in $EXTRAS; do apps+=("${e%%=*}"); done
fi

build_one() {
	local app="$1" bin start end
	bin="$(binary_name "$app")"
	local log="$LOGS/${bin}.log"
	start=$(date +%s)
	if (cd "$ROOT" && "$ODIN" build "apps/$app" -o:speed \
		-collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn \
		-collection:drive=cloud/drive -collection:forge=cloud/forge \
		-out:"$OUT/$bin.tmp") >"$log" 2>&1; then
		mv -f "$OUT/$bin.tmp" "$OUT/$bin"
		end=$(date +%s)
		printf '%s\t%s\tbuilt\t%d\n' "$app" "$bin" $((end - start))
	else
		rm -f "$OUT/$bin.tmp"
		end=$(date +%s)
		printf '%s\t%s\tfailed\t%d\n' "$app" "$bin" $((end - start))
	fi
}
export -f build_one binary_name source_extra_name
export ROOT OUT LOGS ODIN EXTRAS

printf '%s\n' "${apps[@]}" | xargs -P "$JOBS" -I{} bash -c 'build_one "$@"' _ {} | sort >"$RESULTS"

built=$(awk -F'\t' '$3 == "built"' "$RESULTS" | wc -l)
failed=$(awk -F'\t' '$3 == "failed"' "$RESULTS" | wc -l)
awk -F'\t' '$3 == "failed" { print "failed: " $1 "  (" ENVIRON["LOGS"] "/" $2 ".log)" }' "$RESULTS"
echo "built $built, failed $failed -> $OUT"
