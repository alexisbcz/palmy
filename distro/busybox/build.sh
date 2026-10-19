#!/usr/bin/env bash
# Build a static busybox: the base userland (sh, coreutils, mount, ...) that
# sits beside Palmy's own Odin init and package manager.
# Output: distro/out/busybox
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(dirname "$HERE")"
VER="${BUSYBOX_VERSION:-1.37.0}"
SRC="$DISTRO/build/busybox-$VER"
mkdir -p "$DISTRO/build" "$DISTRO/out"
if [ ! -d "$SRC" ]; then
	curl -fL "https://busybox.net/downloads/busybox-$VER.tar.bz2" -o "$DISTRO/build/busybox-$VER.tar.bz2"
	tar -C "$DISTRO/build" -xf "$DISTRO/build/busybox-$VER.tar.bz2"
fi
cd "$SRC"
make -s defconfig
# Static, and without the applets that do not build against current headers
# (tc) or that Palmy replaces with its own (init, which is palm-init).
sed -i \
	-e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
	-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
	-e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
	-e 's/^CONFIG_INIT=y/# CONFIG_INIT is not set/' \
	-e 's/^CONFIG_LINUXRC=y/# CONFIG_LINUXRC is not set/' \
	.config
(set +o pipefail; yes "" | make -s oldconfig >/dev/null)
make -s -j"$(nproc)" busybox
cp busybox "$DISTRO/out/busybox"
echo "busybox $VER -> $DISTRO/out/busybox"
