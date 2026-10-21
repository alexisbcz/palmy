#!/usr/bin/env bash
# run.sh: the web backend's end-to-end check. For each demo it builds the web
# version and a native replay, drives the page in Playwright's Chromium,
# replays the same frames natively, byte-compares every capture and reports
# frame times.
#
#   palmy/web/demo/run.sh <scratch-dir> [demo...]      demos: showcase colorpick clip hidpi resize
#
# Needs, in the build VM: Odin, wasm-ld, node, and Playwright with a Chromium
# (PLAYWRIGHT_DIR=<.../node_modules/playwright> if it is not resolvable from
# here; see TODO.md's tooling note for installing the browser by hand).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
D=$ROOT/palmy/web/demo
S=${1:?scratch dir}
shift
mkdir -p "$S"
S=$(cd "$S" && pwd)
DEMOS=("$@")
[ ${#DEMOS[@]} -gt 0 ] || DEMOS=(showcase colorpick clip hidpi resize)
PORT=${PORT:-8795}
fail=0

# demo name -> app dir, hook, scenario, build name
spec() {
	case $1 in
	showcase) echo "parity/odin/showcase showcase showcase showcase" ;;
	hidpi) echo "parity/odin/showcase showcase showcase-hidpi showcase" ;;
	resize) echo "parity/odin/showcase showcase showcase-resize showcase" ;;
	colorpick) echo "apps/colorpick colorpick colorpick colorpick" ;;
	clip) echo "palmy/web/demo/clipdemo clipdemo clip clipdemo" ;;
	*) return 1 ;;
	esac
}

declare -A built
for demo in "${DEMOS[@]}"; do
	read -r app hook scen name < <(spec "$demo") || { echo "unknown demo $demo"; exit 2; }
	echo "== $demo"
	home=$S/home-$demo
	rm -rf "$home"
	mkdir -p "$home"
	if [ -z "${built[$name]:-}" ]; then
		"$D/native-replay.sh" "$ROOT/$app" "$D/hooks/$hook.odin" "$S/$name-native" || { fail=1; continue; }
		NOFMA=1 "$D/native-replay.sh" "$ROOT/$app" "$D/hooks/$hook.odin" "$S/$name-native-nofma" || { fail=1; continue; }
		HOME=$home PALMY_REPLAY_FONTS="$S/$name-fonts.txt" "$S/$name-native"
		"$ROOT/apps/tools/web-build.sh" "$ROOT/$app" "$S/$name-web" --ship-list "$S/$name-fonts.txt" --title "$name" || { fail=1; continue; }
		built[$name]=1
	fi
	node "$ROOT/palmy/web/serve.mjs" "$S/$name-web" "$PORT" >/dev/null &
	srv=$!
	sleep 0.5
	out=$S/run-$demo
	rm -rf "$out"
	node "$D/drive.mjs" "http://127.0.0.1:$PORT/" "$D/scenarios/$scen.json" "$out" || fail=1
	kill $srv
	wait $srv 2>/dev/null
	rm -rf "$home"
	mkdir -p "$home"
	(cd "$out" && HOME=$home PALMY_REPLAY="$out/frames.ndjson" PALMY_REPLAY_OUT="$out" "$S/$name-native") || fail=1
	if ! node "$D/compare.mjs" "$out"; then
		# Against the replay linked with a stb_truetype built without fused
		# multiply-add (native-replay.sh, NOFMA): identical there means the
		# only difference was the C compiler's contraction, not palmy.
		nf=$out/nofma
		mkdir -p "$nf"
		cp "$out"/captures.json "$out"/web-*.rgba "$nf/"
		rm -rf "$home"
		mkdir -p "$home"
		(cd "$nf" && HOME=$home PALMY_REPLAY="$out/frames.ndjson" PALMY_REPLAY_OUT="$nf" "$S/$name-native-nofma" >/dev/null) || fail=1
		if node "$D/compare.mjs" "$nf" >"$nf/compare.txt"; then
			echo "   ...and identical to a replay whose stb_truetype has no fused multiply-add: the difference is the C compiler's contraction"
		else
			cat "$nf/compare.txt"
			fail=1
		fi
	fi
	node "$D/times.mjs" "$out" | head -4
done
[ $fail = 0 ] && echo "web: all demos passed" || echo "web: FAILED"
exit $fail
