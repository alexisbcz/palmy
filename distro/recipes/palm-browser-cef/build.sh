#!/usr/bin/env bash
# Build the optional palm-browser-cef package: Chromium, for apps/browser.
#
#   distro/recipes/palm-browser-cef/build.sh [repo_dir]
#
# Not part of `make -C distro`: it downloads CEF (~320 MB compressed) from
# Spotify's CEF build CDN, and an image that does not want a browser engine
# should not pay for it. Run it, then `palm index` the repository as usual.
#
# What it does:
#   1. fetches the pinned CEF "minimal" distribution and checks its SHA-1
#      (the CDN publishes one per file);
#   2. builds palm-browser-cef (apps/browser/engine/cef/host.c) against it;
#   3. lays out /usr/lib/palm-browser/cef: the host, libcef.so (stripped),
#      V8's snapshot, ICU data, resource packs, locales, SwiftShader;
#   4. copies the shared libraries libcef.so needs that Palmy does not
#      ship (NSS, GLib, ATK, cups, X11 client libraries, ...) from the build
#      host into the same directory -- the same "from the build host" rule as
#      glibc and libxkbcommon, kept private to this package so nothing else on
#      the system starts depending on them by accident. They sit beside
#      libcef.so because its RUNPATH is $ORIGIN (and a RUNPATH hides the
#      executable's RPATH from its dependencies);
#   5. writes a fontconfig file for systems without /etc/fonts;
#   6. builds the package with `palm build` when palm is available.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(cd "$HERE/../.." && pwd)"
ROOT="$(dirname "$DISTRO")"
REPO="${1:-$DISTRO/build/repo}"

CEF_VERSION="152.0.14+g8a0b5b9+chromium-152.0.7977.167"
CEF_SHA1="007ef6e820f2391d63845329e4ca186eec847905"
CEF_NAME="cef_binary_${CEF_VERSION}_linux64_minimal"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_NAME//+/%2B}.tar.bz2"

CACHE="${PALM_DOWNLOADS:-$DISTRO/build/downloads}"
WORK="$DISTRO/build/palm-browser-cef"
STAGE="${PALMY_OUT:-$DISTRO/out}/palm-browser-cef"
mkdir -p "$CACHE" "$WORK"

tarball="$CACHE/$CEF_NAME.tar.bz2"
if [ ! -f "$tarball" ]; then
	echo "fetching $CEF_URL"
	curl -fSL --retry 3 -o "$tarball.part" "$CEF_URL"
	mv "$tarball.part" "$tarball"
fi
echo "$CEF_SHA1  $tarball" | sha1sum -c --quiet
if [ ! -d "$WORK/$CEF_NAME" ]; then
	tar -xjf "$tarball" -C "$WORK"
fi

rm -rf "$STAGE"
"$ROOT/apps/browser/engine/cef/build.sh" "$WORK/$CEF_NAME" "$STAGE"
rm -f "$STAGE/chrome-sandbox" # Palmy's kernel has user namespaces; no setuid helper

# The library closure, minus what Palmy's glibc package provides.
provided=" libc.so.6 libm.so.6 ld-linux-x86-64.so.2 linux-vdso.so.1 "
for bin in "$STAGE/libcef.so" "$STAGE/palm-browser-cef" "$STAGE/libvk_swiftshader.so"; do
	ldd "$bin" | awk '/=> \// {print $1, $3}'
done | sort -u | while read -r name path; do
	name="${name##*/}"
	case "$provided" in *" $name "*) continue ;; esac
	[ -e "$STAGE/$name" ] && continue # shipped by CEF itself (libvulkan.so.1)
	cp -L "$path" "$STAGE/$name"
done
# NSS loads its PKCS#11 modules with dlopen, and the soft token loads SQLite
# the same way, so ldd cannot see them (found by running the package in a
# root holding nothing but glibc)
for so in libsoftokn3.so libfreeblpriv3.so libnssckbi.so libsqlite3.so.0; do
	for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu; do
		[ -f "$d/$so" ] && { cp -L "$d/$so" "$STAGE/$so"; break; }
	done
done
for f in "$STAGE"/lib*.so*; do
	[ "$f" = "$STAGE/libcef.so" ] || strip --strip-unneeded "$f" 2>/dev/null || true
done

cp "$ROOT/apps/browser/engine/fonts.conf" "$STAGE/fonts.conf"

echo "palm-browser-cef staged in $STAGE:"
du -sh "$STAGE" "$STAGE/libcef.so" "$STAGE/locales" | sed 's/^/  /'

PALM="${PALM:-$DISTRO/out/bin/palm}"
if [ -x "$PALM" ]; then
	mkdir -p "$REPO"
	PALMY_OUT="$(dirname "$STAGE")" "$PALM" build "$HERE/package" -o "$REPO"
	ls -l "$REPO"/palm-browser-cef-*.palm
else
	echo "palm not built ($PALM); package not written"
fi
