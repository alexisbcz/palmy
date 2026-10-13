#!/bin/sh
# Boot the graphical login for real, in QEMU, from a throwaway initramfs.
#
#	distro/login/test-boot.sh
#
# The initramfs is the base skeleton (distro/base), static busybox, palm-init
# as PID 1, and this area's two programs with the window manager they drive:
# palm-login, the greeter, wm — plus glibc from the build host and the base
# font set. test-boot.py then looks at the screen through QMP screendumps,
# types the password with QMP input events, and reads the logs over the
# serial console:
#
#	the greeter is on screen, under wm --drm --kiosk, as `greeter`
#	a wrong password is refused, the right one starts wm --drm as palm
#	the session's environment and /run/user/1000 are what the contract says
#
# QEMU runs with -display none; nothing touches the host's display, seat or
# login. Screenshots and transcripts land in distro/build/login/boot/.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
work=distro/build/login/boot
mkdir -p "$work"

for f in distro/out/bzImage distro/out/busybox distro/out/bin/palm-init; do
	[ -f "$f" ] || { echo "test-boot: $f is missing"; exit 1; }
done

distro/login/build.sh >/dev/null
# The window manager from the tree as it is now, built into our own scratch
# directory so nobody else's output is overwritten.
COLL="-collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn"
odin build apps/wm -o:speed $COLL -out:"$work/wm" || cp distro/out/bin/wm "$work/wm"

rootfs=$work/rootfs
rm -rf "$rootfs"
mkdir -p "$rootfs"

fakeroot -- sh -eu -c '
	rootfs=$1 work=$2
	distro/base/apply-layout.sh "$rootfs"

	install -m 0755 distro/out/busybox "$rootfs/usr/bin/busybox"
	for applet in $("$rootfs/usr/bin/busybox" --list); do
		[ -e "$rootfs/usr/bin/$applet" ] || ln -s busybox "$rootfs/usr/bin/$applet"
	done
	install -m 0755 distro/out/bin/palm-init "$rootfs/usr/bin/palm-init"
	ln -sf palm-init "$rootfs/usr/bin/init"
	install -m 0755 distro/out/bin/palm-login "$rootfs/usr/bin/palm-login"
	install -m 0755 distro/out/bin/greeter "$rootfs/usr/bin/greeter"
	install -m 0755 "$work/wm" "$rootfs/usr/bin/wm"
	[ -f distro/out/bin/term ] && install -m 0755 distro/out/bin/term "$rootfs/usr/bin/term"

	# glibc, exactly the pieces palmy binaries link (see `ldd`).
	for lib in ld-linux-x86-64.so.2 libc.so.6 libm.so.6; do
		install -m 0755 "/usr/lib/$lib" "$rootfs/usr/lib/$lib"
	done

	# The base font set, as distro/apps/fonts.list names it.
	grep -v "^#" distro/apps/fonts.list | while read -r src dst set; do
		[ "$set" = base ] || continue
		install -D -m 0644 "$src" "$rootfs$dst"
	done

	mknod -m 0600 "$rootfs/dev/console" c 5 1
	mknod -m 0666 "$rootfs/dev/null" c 1 3

	(cd "$rootfs" && find . | sort | cpio --quiet -o -H newc) | gzip -1 > "$work/initramfs.cpio.gz"
' sh "$rootfs" "$work"

echo "test-boot: initramfs $(du -h "$work/initramfs.cpio.gz" | cut -f1)"

python3 -I -u distro/login/test-boot.py \
	--kernel distro/out/bzImage \
	--initrd "$work/initramfs.cpio.gz" \
	--work "$work" "$@"
