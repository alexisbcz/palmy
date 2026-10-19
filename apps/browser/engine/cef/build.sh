#!/usr/bin/env bash
# Build palm-browser-cef against an unpacked CEF binary distribution and lay it
# out the way the package installs it: the host, libcef.so and everything CEF
# loads at runtime in one directory.
#
#   engine/cef/build.sh <cef_binary_dir> <out_dir>
#
# The CEF distribution is the "minimal" Linux x64 build from
# https://cef-builds.spotifycdn.com (see distro/recipes/palm-browser-cef).
set -euo pipefail

CEF="${1:?usage: build.sh <cef_binary_dir> <out_dir>}"
OUT="${2:?missing out dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CEF/include/capi/cef_app_capi.h" ] || { echo "not a CEF distribution: $CEF" >&2; exit 1; }
mkdir -p "$OUT"

# DT_RPATH, not RUNPATH: it also covers the dependencies of the libraries the
# package bundles beside libcef.so (GLib's on PCRE, and so on).
# CEF_API_VERSION pins the C API this file was written against; CEF refuses
# to start if the library does not offer it.
cc -O2 -g0 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
	-DCEF_API_VERSION=15200 -I"$CEF" \
	"$HERE/host.c" -o "$OUT/palm-browser-cef" \
	-L"$CEF/Release" -lcef -lpthread -lm -Wl,--disable-new-dtags,-rpath,'$ORIGIN'

# Runtime files: the library (stripped -- the distribution ships it with
# symbols, 1.4 GB), V8's snapshot, SwiftShader for WebGL without a GPU, the
# resource packs, ICU data and the locales.
if [ ! -f "$OUT/libcef.so" ] || [ "$CEF/Release/libcef.so" -nt "$OUT/libcef.so" ]; then
	strip -o "$OUT/libcef.so" "$CEF/Release/libcef.so"
fi
for f in v8_context_snapshot.bin libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json chrome-sandbox; do
	[ -e "$CEF/Release/$f" ] && cp -u "$CEF/Release/$f" "$OUT/"
done
cp -u "$CEF"/Resources/*.pak "$CEF/Resources/icudtl.dat" "$OUT/"
mkdir -p "$OUT/locales"
cp -u "$CEF"/Resources/locales/*.pak "$OUT/locales/"
echo "built $OUT/palm-browser-cef"
