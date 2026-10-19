#!/usr/bin/env bash
# Build distro/out/palmframe-live.iso, the Palmframe live installer, from the
# signed repository in distro/out/repo/x86_64.
#
#	distro/live/build.sh             (make -C distro iso runs it)
#
# Environment:
#	ZSTD_LEVEL=19            initramfs compression level
#	LIVE_WITHOUT_INSTALLER=1 a test build for when palm-install/installer are
#	                         not in the repository yet: everything else is
#	                         installed by palm, distro/live/root is copied in
#	                         by hand instead of via palmframe-live, and the
#	                         session falls back to term. Never for a release.
#
# What it makes, and why each step is done this way:
#
# 1. The live root is made by palm itself, exactly like the disk image
#    (distro/image/build.sh): `palm --root ... --initdb add palmframe-live`
#    into an empty directory under fakeroot, against the local repository and
#    the build's key. palmframe-live pulls in the base system, the kiosk wm,
#    the installer and the tools it formats with, tzdata and the catalogues,
#    but not the applications, which only the installed disk needs, and
#    only a subset of the CJK font (distro/live/subset-cjk.py).
# 2. Two services of palmframe-base are masked, not deleted: palmframe-live
#    ships /etc/palm/services.off/palm-login (the live system's session is
#    the installer, not a login screen) and .../getty-ttyS0 (its own
#    root-autologin getty takes the port), and palm-init starts nothing named
#    there. Every file palm installed stays, so `palm verify` on the live
#    system is clean.
# 3. The packages an installation can ask for -- `palmframe`, and
#    `fonts-cjk` for Japanese (LIVE_REPO_PACKAGES) -- and everything they
#    depend on are copied into the root at /usr/share/palm/repo, flat, with
#    an index of their own signed by the build's key: palm reads
#    <base>/x86_64 if it has an index, else <base> itself, so `--repo
#    /usr/share/palm/repo` installs offline with the same signature check,
#    against the public key palmframe-base already put in /etc/palm/keys.
#    palm itself works out that set (`add --dry-run`), so it follows the
#    recipes. The rest of the build's repository (the live-only packages,
#    palmframe-demo, fonts-emoji...) stays off the medium.
# 4. The root is packed as a newc cpio, still inside the same fakeroot
#    session so the owners palm recorded (root, palm 1000, greeter 900) and
#    modes such as /etc/shadow's 0600 are what the archive says, and
#    compressed with zstd (the kernel has CONFIG_RD_ZSTD). The kernel unpacks
#    it into a tmpfs and runs /init (palmframe-live: -> usr/bin/palm-init).
#    /dev/console is created in the archive so PID 1 has a console before it
#    mounts devtmpfs. /boot/vmlinuz is left out: the kernel is on the ISO,
#    and a second copy would only take RAM.
# 5. The ISO is ISO 9660 made by xorriso with limine's El Torito images:
#    limine-bios-cd.bin for BIOS, limine-uefi-cd.bin (a FAT image with
#    BOOTX64.EFI) for UEFI, then `limine bios-install` writes limine's MBR
#    stage so the same file also boots when written raw to a USB stick.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(dirname "$HERE")"
OUT="$DISTRO/out"
WORK="$DISTRO/build/live"
REPO="$OUT/repo/x86_64"
KEYS="$DISTRO/build/keys"
PALM="$OUT/bin/palm"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/iso"
ISO="$OUT/palmframe-live.iso"
LIMINE_SHARE="${LIMINE_SHARE:-/usr/share/limine}"
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"
LIVE_WITHOUT_INSTALLER="${LIVE_WITHOUT_INSTALLER:-0}"
LIVE_REPO_PACKAGES="${LIVE_REPO_PACKAGES:-palmframe fonts-cjk}"
LIVE_REPO="$WORK/repo"
CJK_SUBSET="$HERE/root/usr/share/fonts/palm-live/NotoSansCJKjp-Regular.otf"
CMDLINE="${CMDLINE:-console=tty0 console=ttyS0,115200 quiet loglevel=3}"

for f in "$PALM" "$REPO/PALMINDEX" "$REPO/PALMINDEX.sig" "$KEYS/palmframe.pub" "$KEYS/palmframe.sec"; do
	[ -f "$f" ] || { echo "live: $f is missing (run make -C distro repo)" >&2; exit 1; }
done
for t in fakeroot cpio zstd xorriso limine; do
	command -v "$t" >/dev/null || { echo "live: $t is not installed" >&2; exit 1; }
done
for f in BOOTX64.EFI limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin; do
	[ -f "$LIMINE_SHARE/$f" ] || { echo "live: $LIMINE_SHARE/$f is missing" >&2; exit 1; }
done

# What goes into the root. The real build installs palmframe-live and lets
# its dependencies say the rest; the test build names them by hand, minus
# the two front ends that are not in the repository.
if [ "$LIVE_WITHOUT_INSTALLER" = 1 ]; then
	echo "live: test build WITHOUT palm-install and installer (LIVE_WITHOUT_INSTALLER=1)" >&2
	PKGS="palmframe-base linux busybox glibc palm-init palm palmy-wm fonts libxkbcommon xkeyboard-config tzdata palm-locale term e2fsprogs dosfstools limine"
else
	for p in palm-install installer palmframe-live; do
		ls "$REPO/$p"-[0-9]*.palm >/dev/null 2>&1 || {
			echo "live: package $p is not in $REPO (are distro/out/bin/palm-install and installer built?)" >&2
			echo "live: LIVE_WITHOUT_INSTALLER=1 makes a test image without them" >&2
			exit 1
		}
	done
	PKGS="palmframe-live"
fi

# The Japanese subset must still cover every catalogue; a changed Japanese
# translation needs distro/live/subset-cjk.py run again.
if command -v fc-query >/dev/null; then
	python3 -I "$HERE/subset-cjk.py" --check "$CJK_SUBSET"
fi

rm -rf "$ROOTFS" "$ISOROOT" "$LIVE_REPO" "$WORK/closure"
mkdir -p "$ROOTFS" "$ISOROOT/boot/limine" "$ISOROOT/EFI/BOOT" "$LIVE_REPO"

# --- 3, first half: the medium's repository ------------------------------------
# shellcheck disable=SC2086
"$PALM" --root "$WORK/closure" --initdb --repo "$REPO" --keys-dir "$KEYS" --dry-run --yes add $LIVE_REPO_PACKAGES |
	awk '$1 == "install" { print $2 "-" $3 ".palm" }' >"$WORK/repo.list"
rm -rf "$WORK/closure"
[ -s "$WORK/repo.list" ] || { echo "live: palm planned nothing for $LIVE_REPO_PACKAGES" >&2; exit 1; }
while read -r f; do
	[ -f "$REPO/$f" ] || { echo "live: $f is not in $REPO" >&2; exit 1; }
	cp "$REPO/$f" "$LIVE_REPO/"
done <"$WORK/repo.list"
"$PALM" index "$LIVE_REPO" --key "$KEYS/palmframe.sec" >/dev/null

# --- 1-4: the root and the initramfs, under one fakeroot session ---------------
# shellcheck disable=SC2016
fakeroot -- bash -euo pipefail -c '
	palm=$1 rootfs=$2 repo=$3 keys=$4 out=$5 level=$6 test=$7 live=$8 liverepo=$9; shift 9
	"$palm" --root "$rootfs" --initdb --repo "$repo" --keys-dir "$keys" --yes add "$@" >/dev/null

	if [ "$test" = 1 ]; then
		cp -a "$live/root/." "$rootfs/"
		ln -sfn usr/bin/palm-init "$rootfs/init"
	fi

	mkdir -p "$rootfs/usr/share/palm/repo"
	cp "$liverepo"/PALMINDEX "$liverepo"/PALMINDEX.sig "$liverepo"/*.palm "$rootfs/usr/share/palm/repo/"
	chmod 0644 "$rootfs"/usr/share/palm/repo/*

	mkdir -p "$rootfs/dev"
	mknod -m 0600 "$rootfs/dev/console" c 5 1
	mknod -m 0666 "$rootfs/dev/null" c 1 3

	(cd "$rootfs" && find . -path ./boot/vmlinuz -prune -o -print | LC_ALL=C sort |
		cpio --quiet -o -H newc --reproducible) |
		zstd -q -T0 -"$level" >"$out"
' fakeroot-live "$PALM" "$ROOTFS" "$REPO" "$KEYS" "$ISOROOT/boot/initramfs.zst" "$ZSTD_LEVEL" \
	"$LIVE_WITHOUT_INSTALLER" "$HERE" "$LIVE_REPO" $PKGS

[ -f "$ROOTFS/init" ] || { echo "live: the root has no /init" >&2; exit 1; }
[ -f "$ROOTFS/etc/palm/services/installer" ] || { echo "live: the root has no installer service" >&2; exit 1; }

# --- 5: the ISO ---------------------------------------------------------------
cp "$ROOTFS/boot/vmlinuz" "$ISOROOT/boot/vmlinuz"
cp "$LIMINE_SHARE/limine-bios.sys" "$LIMINE_SHARE/limine-bios-cd.bin" \
	"$LIMINE_SHARE/limine-uefi-cd.bin" "$ISOROOT/boot/limine/"
cp "$LIMINE_SHARE/BOOTX64.EFI" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"

# No root= : the kernel then keeps the initramfs as the root, in a tmpfs.
cat >"$ISOROOT/boot/limine/limine.conf" <<EOF
# The Palmframe live installer. Written by distro/live/build.sh.
# The whole system is the initramfs; nothing is read from this medium after
# the kernel starts, so it can be removed once the menu has gone.
timeout: 5
default_entry: 1

/Install Palmframe
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs.zst
    cmdline: $CMDLINE

/Install Palmframe (serial console only)
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs.zst
    cmdline: console=ttyS0,115200 palm.live.serial
EOF

rm -f "$ISO.tmp"
xorriso -as mkisofs -quiet -R -r -J -V PALMFRAME_LIVE \
	-b boot/limine/limine-bios-cd.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
	--efi-boot boot/limine/limine-uefi-cd.bin -efi-boot-part --efi-boot-image \
	--protective-msdos-label \
	"$ISOROOT" -o "$ISO.tmp" >"$WORK/xorriso.log" 2>&1 || { cat "$WORK/xorriso.log" >&2; exit 1; }
limine bios-install "$ISO.tmp" >"$WORK/limine.log" 2>&1 || { cat "$WORK/limine.log" >&2; exit 1; }
mv -f "$ISO.tmp" "$ISO"

unpacked=$(du -s --block-size=1M --exclude=vmlinuz "$ROOTFS" | cut -f1)
echo "live: $ISO ($(du -h --apparent-size "$ISO" | cut -f1)); initramfs $(du -h --apparent-size "$ISOROOT/boot/initramfs.zst" | cut -f1) compressed, ~${unpacked} MiB in RAM unpacked; $(grep -c '^pkgname' "$ROOTFS/usr/lib/palm/db/installed") packages installed; repository $(wc -l <"$WORK/repo.list") packages, $(du -sh --apparent-size "$LIVE_REPO" | cut -f1)"
