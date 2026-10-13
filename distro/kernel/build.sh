#!/usr/bin/env bash
# Build the Palmframe kernel: Linux LTS, defconfig + kvm_guest + our fragment,
# everything built in. Output: distro/out/bzImage (and distro/out/kernel.config).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(dirname "$HERE")"
VER="${KERNEL_VERSION:-6.18.56}"
SRC="$DISTRO/build/linux-$VER"
mkdir -p "$DISTRO/build" "$DISTRO/out"
if [ ! -d "$SRC" ]; then
	curl -fL "https://cdn.kernel.org/pub/linux/kernel/v${VER%%.*}.x/linux-$VER.tar.xz" -o "$DISTRO/build/linux-$VER.tar.xz"
	tar -C "$DISTRO/build" -xf "$DISTRO/build/linux-$VER.tar.xz"
fi
cd "$SRC"
make -s x86_64_defconfig
make -s kvm_guest.config
scripts/kconfig/merge_config.sh -m .config "$HERE/palmframe.config" >/dev/null
make -s olddefconfig
make -s -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$DISTRO/out/bzImage"
cp .config "$DISTRO/out/kernel.config"
echo "kernel $VER -> $DISTRO/out/bzImage"
