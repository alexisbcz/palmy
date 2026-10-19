#!/usr/bin/env bash
# Build the Palmy kernel and its modules: Linux LTS, x86_64_defconfig +
# kvm_guest.config, then every driver family in modular.list as modules, then
# palmy.config over all of it (distro/notes/kernel.md says why).
#
#	distro/kernel/build.sh           JOBS=8 distro/kernel/build.sh
#
# Output, all in distro/out:
#	bzImage          the kernel
#	kernel.config    its .config
#	kernel.release   `make kernelrelease`, e.g. 6.18.56-palmy
#	modules/<rel>/   the modules (stripped, zstd) and depmod's indexes,
#	                 which the linux package installs as /usr/lib/modules/<rel>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(dirname "$HERE")"
OUT="$DISTRO/out"
VER="${KERNEL_VERSION:-6.18.56}"
SRC="$DISTRO/build/linux-$VER"
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$DISTRO/build" "$OUT"
if [ ! -d "$SRC" ]; then
	curl -fL "https://cdn.kernel.org/pub/linux/kernel/v${VER%%.*}.x/linux-$VER.tar.xz" -o "$DISTRO/build/linux-$VER.tar.xz"
	tar -C "$DISTRO/build" -xf "$DISTRO/build/linux-$VER.tar.xz"
fi
for t in depmod zstd; do
	command -v "$t" >/dev/null || { echo "kernel: $t is not installed (kmod, zstd)" >&2; exit 1; }
done
cd "$SRC"

# modular.list -> a fragment with every tristate option under those
# directories set to m. A Kconfig entry starts at `config X` or
# `menuconfig X`; it is a module candidate if its type line says tristate.
modular="$DISTRO/build/kernel-modular.config"
grep -v -e '^#' -e '^$' "$HERE/modular.list" | while read -r dir; do
	[ -d "$dir" ] || { echo "kernel: modular.list: no directory $dir" >&2; exit 1; }
	find "$dir" -name 'Kconfig*' -type f | LC_ALL=C sort | xargs awk '
		FNR == 1 { sym = "" }
		/^[ \t]*(menu)?config[ \t]+[A-Za-z0-9_]+[ \t]*$/ { sym = $2; next }
		/^[ \t]*(def_)?tristate([ \t]|$)/ { if (sym != "") print "CONFIG_" sym "=m"; sym = ""; next }
		/^[ \t]*(bool|def_bool|int|hex|string)([ \t]|$)/ { sym = "" }
	'
done | LC_ALL=C sort -u >"$modular"

make -s x86_64_defconfig
make -s kvm_guest.config
scripts/kconfig/merge_config.sh -m .config "$modular" "$HERE/palmy.config" >/dev/null
make -s olddefconfig

# Every line of palmy.config must have survived: a dependency that is
# not met makes Kconfig drop an option silently, which on real hardware
# means a missing driver nobody notices until the machine has no disk.
bad=0
while IFS= read -r line; do
	case "$line" in
	CONFIG_*=*) sym="${line%%=*}" ;;
	"# CONFIG_"*" is not set") sym="${line#\# }"; sym="${sym%% *}" ;;
	*) continue ;;
	esac
	got="$(grep -E "^$sym=|^# $sym is not set" .config || true)"
	if [ "$line" != "$got" ] && ! { [ "${line#*=}" = n ] && [ "$got" = "# $sym is not set" -o -z "$got" ]; }; then
		echo "kernel: palmy.config wants $line, got ${got:-nothing}" >&2
		bad=1
	fi
done <"$HERE/palmy.config"
[ "$bad" = 0 ] || exit 1
[ "${1:-}" = --config ] && { echo "kernel: $SRC/.config"; exit 0; }

make -s -j"$JOBS" bzImage modules
REL="$(make -s kernelrelease)"

# The modules, stripped of debug info and compressed with zstd by the
# kernel's own modules_install (CONFIG_MODULE_COMPRESS_ZSTD), which then
# runs depmod against the staging directory.
STAGE="$DISTRO/build/kernel-modules"
rm -rf "$STAGE"
make -s INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install
rm -f "$STAGE/lib/modules/$REL/build" "$STAGE/lib/modules/$REL/source"
[ -s "$STAGE/lib/modules/$REL/modules.alias" ] || { echo "kernel: depmod wrote no modules.alias" >&2; exit 1; }

rm -rf "$OUT/modules"
mkdir -p "$OUT/modules"
mv "$STAGE/lib/modules/$REL" "$OUT/modules/$REL"
cp arch/x86/boot/bzImage "$OUT/bzImage"
cp .config "$OUT/kernel.config"
echo "$REL" >"$OUT/kernel.release"
echo "kernel $REL -> $OUT/bzImage ($(du -h "$OUT/bzImage" | cut -f1)), $(find "$OUT/modules" -name '*.ko*' | wc -l) modules ($(du -sh "$OUT/modules" | cut -f1))"
