#!/usr/bin/env bash
# native-replay.sh: build an application natively with the replay compiled in.
#
#   palmy/web/demo/native-replay.sh <app-dir> <hook.odin> <out-binary>
#
# The app's own .odin files are copied unchanged into a staging directory next
# to replay/replay.odin and the hook, and built for the host against the real
# palmy/, shadcn/ and apps/kit. Run the result with PALMY_REPLAY=<log> (see
# replay/replay.odin); without it, it is the ordinary native app.
#
# NOFMA=1 links stb_truetype rebuilt with -ffp-contract=off. The library Odin
# ships for arm64 is compiled with contraction, so its glyph rasterizer
# (stbtt__rasterize_sorted_edges, the curve tessellators) uses fused
# multiply-adds; WebAssembly has none. At some glyph sizes that moves a stem
# edge's coverage by one level -- seen at 2x, never at 1x in these demos. A
# replay linked without contraction is byte-identical to the browser, which is
# how run.sh tells that difference from any other.
set -euo pipefail
APP=$(cd "$1" && pwd)
HOOK=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
OUTBIN=$3
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ODIN=${ODIN:-$HOME/.local/share/mise/installs/odin/dev-2026-09/odin}
STAGE=$(dirname "$OUTBIN")/.replay-stage-$(basename "$OUTBIN")
rm -rf "$STAGE"
mkdir -p "$STAGE"
STAGE=$(cd "$STAGE" && pwd)
cp "$APP"/*.odin "$STAGE/"
cp "$ROOT/palmy/web/demo/replay/replay.odin" "$STAGE/zz_replay.odin"
cp "$HOOK" "$STAGE/zz_replay_hook.odin"
# An app that finds files relative to its own source (#directory) would look
# in the staging directory; point those at the original.
for f in "$STAGE"/*.odin; do
	sed -i "s|#directory|\"$APP/\"|g" "$f"
done
if [ "${NOFMA:-}" = 1 ]; then
	O=$(dirname "$(readlink -f "$ODIN")")
	R=$STAGE/.odin-root
	mkdir -p "$R/vendor/stb/lib" "$R/vendor/stb/truetype"
	for e in "$O"/*; do [ "$(basename "$e")" = vendor ] || ln -s "$e" "$R/$(basename "$e")"; done
	for e in "$O"/vendor/*; do [ "$(basename "$e")" = stb ] || ln -s "$e" "$R/vendor/$(basename "$e")"; done
	for e in "$O"/vendor/stb/*; do case $(basename "$e") in lib|truetype) ;; *) ln -s "$e" "$R/vendor/stb/$(basename "$e")" ;; esac; done
	for e in "$O"/vendor/stb/lib/*; do ln -s "$e" "$R/vendor/stb/lib/$(basename "$e")"; done
	cp "$O"/vendor/stb/truetype/*.odin "$R/vendor/stb/truetype/"
	rm "$R/vendor/stb/lib/stb_truetype.a"
	clang -O2 -ffp-contract=off -c "$O/vendor/stb/src/stb_truetype.c" -o "$STAGE/.stb_truetype.o"
	ar rcs "$R/vendor/stb/lib/stb_truetype.a" "$STAGE/.stb_truetype.o"
	export ODIN_ROOT=$R
fi
"$ODIN" build "$STAGE" -o:speed \
	-collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" -collection:kit="$ROOT/apps/kit" \
	-out:"$OUTBIN"
