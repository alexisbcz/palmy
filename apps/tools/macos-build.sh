#!/bin/bash
# macos-build.sh: build and verify palmy natively on a Mac (docs/MACOS.md).
#
#   apps/tools/macos-build.sh tests          odin test tests
#   apps/tools/macos-build.sh check          the windowed self-check (opens one
#                                             window for ~5 s; own events only)
#   apps/tools/macos-build.sh parity CAPTURES BASELINE
#                                             render all 182 parity cases and
#                                             byte-compare them with BASELINE/*.png
#                                             (CAPTURES: the browser PNGs that size
#                                             the canvases)
#   apps/tools/macos-build.sh app NAME...    build apps/NAME (or a path) with
#                                             -o:speed into $OUT
#
# Odin is the pinned dev-2026-09 (brew's `odin` formula, or $ODIN). Binaries go
# to $OUT (default: a temporary directory), never into the tree: the tree is
# shared with the Linux VM, which would otherwise find Mach-O files where its
# scripts expect its own.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"
ODIN=${ODIN:-$(command -v odin)}
OUT=${OUT:-$(mktemp -d -t palmy-macos)}; mkdir -p "$OUT"
C=(-collection:palmy="$R/palmy" -collection:shadcn="$R/shadcn" -collection:kit="${KIT:-$R/apps/kit}")

[ "$(uname -s)" = Darwin ] || { echo "macos-build.sh: this is for macOS; in Linux use ~/palmy-env/check.sh" >&2; exit 2; }
[ -x "$ODIN" ] || { echo "macos-build.sh: no odin (brew install odin, or set ODIN)" >&2; exit 2; }
case "$("$ODIN" version)" in
  *dev-2026-09*) ;;
  *) echo "macos-build.sh: warning: $("$ODIN" version) is not the pinned dev-2026-09" >&2 ;;
esac

cmd=${1:-tests}; shift || true
case "$cmd" in
tests)
  cd "$R" && "$ODIN" test tests "${C[@]}" -out:"$OUT/palmy-tests" 2>&1 | grep -vE "^\s+bidi:" | tail -4
  ;;
check)
  "$ODIN" build "$R/palmy/darwin/check" -out:"$OUT/macos-check" || exit 1
  PALMY_MAC_NO_ACTIVATE=${PALMY_MAC_NO_ACTIVATE:-1} "$OUT/macos-check"
  ;;
parity)
  CAP=${1:?parity CAPTURES BASELINE}; BASE=${2:?parity CAPTURES BASELINE}
  mkdir -p "$R/parity/out/web"
  for f in "$CAP"/*.png; do [ -f "$R/parity/out/web/$(basename "$f")" ] || cp "$f" "$R/parity/out/web/"; done
  "$ODIN" build "$R/parity/odin/render" "${C[@]}" -o:speed -out:"$OUT/render" || exit 1
  PARITY_ROOT="$R/parity" "$OUT/render" --all 2>/dev/null | tail -1
  n=0; same=0
  for f in "$BASE"/*.png; do
    if cmp -s "$f" "$R/parity/out/odin/$(basename "$f")"; then same=$((same+1)); else echo "  moved: $(basename "$f")"; n=$((n+1)); fi
  done
  echo "renders byte-identical to $BASE: $same, moved: $n"
  [ $n -eq 0 ]
  ;;
app)
  rc=0
  for a in "$@"; do
    d=$a; [ -d "$d" ] || d="$R/apps/$a"
    name=$(basename "$d")
    if "$ODIN" build "$d" "${C[@]}" -o:speed -out:"$OUT/$name" 2>"$OUT/$name.err"; then
      echo "built $OUT/$name"
    else
      echo "FAIL $name: $(grep -m2 Error "$OUT/$name.err" | sed 's/^.*Error: //')"; rc=1
    fi
  done
  exit $rc
  ;;
*)
  sed -n 2,16p "$0"; exit 2
  ;;
esac
