#!/bin/sh
# Boot palm-init for real, in QEMU, from a throwaway initramfs.
#
#	distro/init/test-boot.sh [login|single|disk|all]      (default: all)
#
# The initramfs is the smallest thing palm-init can be PID 1 of: the
# palmframe-base skeleton (distro/base), static busybox with its applet links,
# and palm-init as /sbin/init. It is packed with fakeroot so every file is
# root-owned and /dev/console is a real node, as the kernel expects.
#
# test-boot.py then drives the serial console like a person would:
#
#	login   wait for the getty prompt on ttyS0, log in as root with the
#	        password from /etc/shadow, look at what init set up (mounts,
#	        hostname, network, device groups, service logs), hot-plug a USB
#	        keyboard through QMP and check its event node lands in `input`,
#	        then `poweroff` and require QEMU to exit by itself.
#	single  boot with palm.single and palm.autologin=palm, check the root
#	        shell appears on the console without a login, and `reboot`
#	        (QEMU runs with -no-reboot, so a reboot is an exit too).
#	disk    the same tree as an ext4 root on virtio-blk, mounted `ro` by
#	        the kernel: palm-init must remount it read-write, and after
#	        `poweroff` e2fsck must find it cleanly unmounted.
#
# Nothing here touches the host's display or devices: QEMU runs with
# -display none, and the window manager is not part of this image.
#
# Transcripts land in distro/build/init/; the script exits non-zero if any
# check fails.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
work=distro/build/init
mkdir -p "$work"

[ -f distro/out/bzImage ] || { echo "test-boot: no distro/out/bzImage (distro/kernel/build.sh)"; exit 1; }
[ -f distro/out/busybox ] || { echo "test-boot: no distro/out/busybox (distro/busybox/build.sh)"; exit 1; }

distro/init/build.sh --test >"$work/selftest.txt" || { cat "$work/selftest.txt"; exit 1; }
tail -1 "$work/selftest.txt"

# --- the initramfs -----------------------------------------------------------
rootfs=$work/rootfs
rm -rf "$rootfs"
mkdir -p "$rootfs"

fakeroot -- sh -eu -c '
	rootfs=$1
	distro/base/apply-layout.sh "$rootfs"

	install -m 0755 distro/out/busybox "$rootfs/usr/bin/busybox"
	for applet in $("$rootfs/usr/bin/busybox" --list); do
		[ -e "$rootfs/usr/bin/$applet" ] || ln -s busybox "$rootfs/usr/bin/$applet"
	done
	install -m 0755 distro/out/bin/palm-init "$rootfs/usr/bin/palm-init"
	ln -sf palm-init "$rootfs/usr/bin/init"

	# palm-login and the window manager are not in this image; their service
	# would only show "not found" and back off, which says nothing here.
	rm -f "$rootfs/etc/palm/services/palm-login"

	mknod -m 0600 "$rootfs/dev/console" c 5 1
	mknod -m 0666 "$rootfs/dev/null" c 1 3

	(cd "$rootfs" && find . | sort | cpio --quiet -o -H newc) | gzip -1 > "$2"

	# The same tree as an ext4 disk, for the `disk` scenario: a real root
	# filesystem mounted read-only by the kernel, as the image will be.
	rm -f "$3"
	mkfs.ext4 -q -L palmroot -d "$rootfs" "$3" 64M
' sh "$rootfs" "$work/initramfs.cpio.gz" "$work/root.ext4"

echo "test-boot: initramfs $(du -h "$work/initramfs.cpio.gz" | cut -f1)"

python3 -u -I distro/init/test-boot.py \
	--kernel distro/out/bzImage \
	--initrd "$work/initramfs.cpio.gz" \
	--work "$work" \
	--disk "$work/root.ext4" \
	"${1:-all}"
