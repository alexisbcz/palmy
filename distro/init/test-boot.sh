#!/bin/sh
# Boot palm-init for real, in QEMU, from a throwaway initramfs.
#
#	distro/init/test-boot.sh [login|single|disk|grow|all]      (default: all)
#	KERNEL=<bzImage> distro/init/test-boot.sh ...   another kernel (one with
#	                                                zram, say)
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
#	        reload services on SIGHUP (add, change, remove), check the early
#	        hooks ran in order before any service, then `poweroff` and
#	        require QEMU to exit by itself.
#	single  boot with palm.single and palm.autologin=palm, check the root
#	        shell appears on the console without a login, and `reboot`
#	        (QEMU runs with -no-reboot, so a reboot is an exit too).
#	disk    the same tree as an ext4 root on virtio-blk, mounted `ro` by
#	        the kernel: palm-init must remount it read-write, and after
#	        `poweroff` e2fsck must find it cleanly unmounted.
#	grow    the disk image's shape: GPT, an ESP and the root by label in
#	        fstab, a swap file, /etc/palm/grow-root, the disk enlarged after
#	        it was built. palm-init must grow the root partition and its ext4
#	        to the disk's end, mount the ESP, turn on the swap file (and zram
#	        when the kernel has it), and undo it all at poweroff. The host
#	        then checks the GPT and the filesystem, and a second boot must
#	        find nothing left to grow.
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

	# Early hooks: a packaged one that /etc replaces, a packaged one that
	# runs, in that order, before any service. test-boot.py reads
	# /run/early back.
	mkdir -p "$rootfs/usr/lib/palm-init/early.d"
	printf "#!/bin/sh\necho usr-10 >>/run/early\n" >"$rootfs/usr/lib/palm-init/early.d/10-mark"
	printf "#!/bin/sh\necho etc-10 >>/run/early\n" >"$rootfs/etc/palm/early.d/10-mark"
	printf "#!/bin/sh\necho \"20 \$PALM_INIT_STAGE services=\$(pidof syslogd getty | wc -w)\" >>/run/early\n" >"$rootfs/usr/lib/palm-init/early.d/20-order"
	chmod 0755 "$rootfs"/usr/lib/palm-init/early.d/* "$rootfs"/etc/palm/early.d/*

	(cd "$rootfs" && find . | sort | cpio --quiet -o -H newc) | gzip -1 > "$2"

	# The same tree as an ext4 disk, for the `disk` scenario: a real root
	# filesystem mounted read-only by the kernel, as the image will be.
	rm -f "$3"
	mkfs.ext4 -q -L palmroot -d "$rootfs" "$3" 64M

	# The `grow` scenario: the disk image'"'"'s shape. A GPT with an ESP
	# (FAT, label TESTESP) and the root (ext4, label palmroot) last; an
	# fstab naming both by label; /etc/palm/grow-root. (The swap file is
	# made in the guest: mkfs.ext4 -d leaves extents the kernel refuses.)
	# Built at 160 MiB and then enlarged to 1 GiB, as `qemu-img resize`
	# would, so palm-init has to grow the partition and the filesystem.
	cat >>"$rootfs/etc/fstab" <<-EOF
	LABEL=palmroot	/	ext4	rw,relatime	0 1
	LABEL=TESTESP	/boot/efi	vfat	rw,relatime,fmask=0077,dmask=0077,shortname=mixed,utf8,errors=remount-ro	0 2
	EOF
	: >"$rootfs/etc/palm/grow-root"
	rm -f "$4" "$4.root" "$4.esp"
	mkfs.ext4 -q -L palmroot -d "$rootfs" "$4.root" 128M
	mkfs.vfat -n TESTESP -C "$4.esp" $((30 * 1024)) >/dev/null
	truncate -s 160M "$4"
	printf "label: gpt\nstart=2048, size=61440, type=uefi, name=\"EFI system\"\nstart=63488, size=262144, type=linux, name=\"palmroot\"\n" | sfdisk --quiet "$4"
	dd if="$4.esp" of="$4" bs=512 seek=2048 conv=notrunc,sparse status=none
	dd if="$4.root" of="$4" bs=512 seek=63488 conv=notrunc,sparse status=none
	rm -f "$4.root" "$4.esp"
	truncate -s 1G "$4"
' sh "$rootfs" "$work/initramfs.cpio.gz" "$work/root.ext4" "$work/grow.img"

echo "test-boot: initramfs $(du -h "$work/initramfs.cpio.gz" | cut -f1)"

python3 -u -I distro/init/test-boot.py \
	--kernel "${KERNEL:-distro/out/bzImage}" \
	--initrd "$work/initramfs.cpio.gz" \
	--work "$work" \
	--disk "$work/root.ext4" \
	--grow-disk "$work/grow.img" \
	"${1:-all}"
