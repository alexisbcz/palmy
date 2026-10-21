#!/usr/bin/env bash
# Build a palmy application for another architecture.
#
#   cross-build.sh <amd64|riscv64> <app-dir> <out> [odin build flags...]
#
# Odin cross-compiles palmy itself without help; what does not cross is the
# prebuilt `vendor:stb` archives in the Odin install (font and image loading),
# which are for the host. So this keeps a private copy of the Odin root per
# target under $PALMY_CROSS (default ~/.cache/palmy-cross), rebuilds the stb
# archives there with `clang --target`, and links with lld against the
# target's libc (Debian/Ubuntu multiarch: libc6-dev:amd64 or :riscv64).
# The shared Odin install is never touched.
#
# The result runs on the build VM itself: amd64 binaries under Rosetta (or
# qemu-x86_64), riscv64 under qemu-riscv64, both through binfmt_misc. Needs
# clang and ld.lld.
set -euo pipefail
ARCH="${1:?usage: cross-build.sh <amd64|riscv64> <app-dir> <out> [flags]}"; APP="${2:?app dir}"; OUT="${3:?out}"
shift 3
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"
SRC_ROOT="$(dirname "$(readlink -f "$ODIN")")"
case "$ARCH" in
  amd64)   TRIPLE=x86_64-linux-gnu;  TARGET=linux_amd64 ;;
  riscv64) TRIPLE=riscv64-linux-gnu; TARGET=linux_riscv64 ;;
  *) echo "unknown arch $ARCH"; exit 1 ;;
esac
ROOT="${PALMY_CROSS:-$HOME/.cache/palmy-cross}/$ARCH"
if [ ! -x "$ROOT/odin" ]; then
  mkdir -p "$(dirname "$ROOT")"
  cp -r "$SRC_ROOT" "$ROOT.tmp"
  ( cd "$ROOT.tmp/vendor/stb/src"
    for f in stb_image stb_image_write stb_image_resize stb_truetype stb_rect_pack stb_sprintf stb_vorbis; do
      clang --target="$TRIPLE" -O2 -fPIC -c "$f.c" -o "/tmp/palmy-cross-$$-$f.o" 2>/dev/null
      rm -f "../lib/$f.a"; ar rcs "../lib/$f.a" "/tmp/palmy-cross-$$-$f.o"; rm -f "/tmp/palmy-cross-$$-$f.o"
    done )
  mv "$ROOT.tmp" "$ROOT"
fi
ODIN_ROOT="$ROOT" "$ROOT/odin" build "$APP" -target:"$TARGET" -linker:lld -extra-linker-flags:"--target=$TRIPLE" \
  -collection:palmy="$R/palmy" -collection:shadcn="$R/shadcn" -collection:kit="$R/apps/kit" -out:"$OUT" "$@"
