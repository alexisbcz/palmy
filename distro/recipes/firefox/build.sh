#!/usr/bin/env bash
# Build the optional firefox package: Mozilla's Firefox, as the browser app's
# Gecko engine (and runnable on its own once the window manager has
# xdg_popup).
#
#   distro/recipes/firefox/build.sh [repo_dir]
#
# Not part of `make -C distro`: it downloads Mozilla's release tarball
# (~80 MB, 330 MB unpacked).
#
#   1. fetches the pinned release and checks it against Mozilla's SHA256SUMS
#      (the sum is pinned here too, so a changed file on the CDN fails);
#   2. unpacks it to /usr/lib/firefox -- Mozilla's build as published, which
#      bundles its own NSS, SQLite, codecs and certificate roots;
#   3. copies the system libraries libxul.so needs that Palmy does not
#      ship (GTK 3, GLib, Pango, cairo, HarfBuzz, the X11 client libraries
#      GTK links even on Wayland, ...) from the build host into
#      /usr/lib/firefox/syslib. The browser's Gecko host puts that directory on
#      LD_LIBRARY_PATH when it starts Firefox;
#   4. adds a fontconfig file for systems without /etc/fonts, and writes a
#      policies.json that turns off Firefox's own update checks --
#      updates come as packages, like everything else here;
#   5. builds the package with `palm build` when palm is available.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(cd "$HERE/../.." && pwd)"
ROOT="$(dirname "$DISTRO")"
REPO="${1:-$DISTRO/build/repo}"

FF_VERSION="158.0"
FF_SHA256="9549b054ec4cf85f50f6a19d8c6fb79580312e71ebc4ec2cb217ec9af09dc12a"
FF_URL="https://download-installer.cdn.mozilla.net/pub/firefox/releases/$FF_VERSION/linux-x86_64/en-US/firefox-$FF_VERSION.tar.xz"

CACHE="${PALM_DOWNLOADS:-$DISTRO/build/downloads}"
STAGE="${PALMY_OUT:-$DISTRO/out}/firefox"
mkdir -p "$CACHE"

tarball="$CACHE/firefox-$FF_VERSION.tar.xz"
if [ ! -f "$tarball" ]; then
	echo "fetching $FF_URL"
	curl -fSL --retry 3 -o "$tarball.part" "$FF_URL"
	mv "$tarball.part" "$tarball"
fi
echo "$FF_SHA256  $tarball" | sha256sum -c --quiet

rm -rf "$STAGE"
mkdir -p "$(dirname "$STAGE")"
tar -xJf "$tarball" -C "$(dirname "$STAGE")" # the tarball's top directory is firefox/

# the system library closure
mkdir -p "$STAGE/syslib"
provided=" libc.so.6 libm.so.6 ld-linux-x86-64.so.2 linux-vdso.so.1 "
for bin in "$STAGE"/libxul.so "$STAGE"/firefox "$STAGE"/firefox-bin "$STAGE"/libmozgtk.so "$STAGE"/libmozwayland.so; do
	[ -e "$bin" ] || continue
	LD_LIBRARY_PATH="$STAGE" ldd "$bin" | awk '/=> \// {print $1, $3}'
done | sort -u | while read -r name path; do
	name="${name##*/}"
	case "$provided" in *" $name "*) continue ;; esac
	case "$path" in "$STAGE"/*) continue ;; esac # Mozilla's own
	cp -L "$path" "$STAGE/syslib/$name"
done
strip --strip-unneeded "$STAGE"/syslib/*.so* 2>/dev/null || true

mkdir -p "$STAGE/distribution"
cat >"$STAGE/distribution/policies.json" <<'EOF'
{
  "policies": {
    "DisableAppUpdate": true,
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": ""
  }
}
EOF
cp "$ROOT/apps/browser/engine/fonts.conf" "$STAGE/fonts.conf"

echo "firefox staged in $STAGE:"
du -sh "$STAGE" "$STAGE/libxul.so" "$STAGE/syslib" | sed 's/^/  /'

PALM="${PALM:-$DISTRO/out/bin/palm}"
if [ -x "$PALM" ]; then
	mkdir -p "$REPO"
	PALMY_OUT="$(dirname "$STAGE")" "$PALM" build "$HERE/package" -o "$REPO"
	ls -l "$REPO"/firefox-*.palm
else
	echo "palm not built ($PALM); package not written"
fi
