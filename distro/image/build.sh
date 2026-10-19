#!/usr/bin/env bash
# Assemble distro/out/palmframe.img, the bootable Palmframe disk, from the
# signed repository in distro/out/repo/x86_64.
#
#	distro/image/build.sh            (make -C distro image runs it)
#
# No root and no loop devices. The steps, and why each is done this way:
#
# 1. The root filesystem is made by palm itself: `palm --root ... --initdb
#    add palmframe palmframe-demo` into an empty directory (palmframe-demo is
#    the demo user's home), against the local repository and the build's own
#    key. That is the same code path, the same signature
#    check and the same installed database a user's `palm add` produces, so
#    `palm verify` on the booted machine checks exactly what was shipped.
# 2. palm runs under fakeroot, and mkfs.ext4 -d runs in the same fakeroot
#    session, so the owners palm recorded (root, palm 1000, greeter 900) and
#    the 0600 /etc/shadow are what land in the ext4 image even though every
#    file on the host belongs to the builder.
# 3. The disk is GPT: an EFI system partition (FAT, made with mtools) holding
#    limine and a copy of the kernel -- limine reads FAT, not ext4 -- and the
#    ext4 root as partition 2, which the kernel mounts as /dev/vda2 on QEMU's
#    virtio disk. The partitions are built as separate files and copied into
#    place with dd, and sfdisk writes the table straight into the image file.
# 4. `limine bios-install` makes the same disk boot on legacy BIOS as well;
#    UEFI (OVMF) is what distro/run-qemu.sh uses by default.
# 5. The image is small (the installed size plus ROOT_EXTRA_MIB) and grows
#    itself: the root is the last partition, and /etc/palm/grow-root makes
#    palm-init extend it and its filesystem to the end of the disk on the
#    first boot. `qemu-img resize` or `truncate -s 32G` the copy you boot,
#    or dd it onto a real disk. Swap is zram (/etc/palm/zram), so there is no
#    swap partition to size.
#
#	TIMEZONE=Europe/Paris distro/image/build.sh    /etc/localtime (UTC;
#	                                               `host` = the build host's)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(dirname "$HERE")"
OUT="$DISTRO/out"
WORK="$DISTRO/build/image"
REPO="$OUT/repo/x86_64"
KEYS="$DISTRO/build/keys"
PALM="$OUT/bin/palm"
ROOTFS="$OUT/rootfs"
IMG="$OUT/palmframe.img"
LIMINE_SHARE="${LIMINE_SHARE:-/usr/share/limine}"

# Partition sizes in MiB. The root gets the installed size plus room for the
# user and for `palm add`/`upgrade` (a package is staged in memory, unpacked
# to a temp file beside its destination, then renamed).
ESP_MIB=${ESP_MIB:-128}
ROOT_EXTRA_MIB=${ROOT_EXTRA_MIB:-1024}
# `ro`: the kernel mounts the root read-only, so palm-init can fsck it
# (e2fsck -p) before remounting it read-write from its /etc/fstab line.
CMDLINE="${CMDLINE:-root=/dev/vda2 ro console=tty0 console=ttyS0,115200 quiet loglevel=3}"
# The time zone /etc/localtime points at: a tzdata name (Europe/Paris), or
# `host` for the build host's own. UTC by default, like a fresh install
# before its time zone page.
TIMEZONE="${TIMEZONE:-UTC}"
if [ "$TIMEZONE" = host ]; then
	TIMEZONE="$(readlink -f /etc/localtime | sed -n 's|.*/zoneinfo/||p')"
	[ -n "$TIMEZONE" ] || TIMEZONE=UTC
fi
# Besides the system: e2fsprogs and dosfstools, so that palm-init can check
# `/` and the EFI system partition at boot (fsck.ext4, fsck.fat).
PACKAGES="${PACKAGES:-palmframe palmframe-demo e2fsprogs dosfstools}"

for f in "$PALM" "$REPO/PALMINDEX" "$REPO/PALMINDEX.sig" "$KEYS/palmframe.pub"; do
	[ -f "$f" ] || { echo "image: $f is missing (run make -C distro repo)" >&2; exit 1; }
done
for t in fakeroot mkfs.ext4 sfdisk mformat mcopy mmd limine; do
	command -v "$t" >/dev/null || { echo "image: $t is not installed" >&2; exit 1; }
done

rm -rf "$WORK" "$ROOTFS"
mkdir -p "$WORK" "$ROOTFS"

# --- 1 + 2: the root filesystem, under one fakeroot session -------------------
# The keys directory holds palmframe.sec too; palm only reads *.pub from it.
root_bytes_file="$WORK/root.bytes"
fakeroot -- bash -euo pipefail -c '
	palm=$1 rootfs=$2 repo=$3 keys=$4 work=$5 extra=$6 tz=$7 packages=$8
	"$palm" --root "$rootfs" --initdb --repo "$repo" --keys-dir "$keys" --yes add $packages

	# What makes this root the disk image rather than any root: palm
	# reports these edits as "modified (config)", like every edit in /etc.
	#  - `/` and the EFI system partition by the labels given below, so
	#    palm-init checks `/` and mounts the ESP at /boot/efi.
	#  - /etc/palm/grow-root: on its first boot palm-init grows the root
	#    partition and filesystem to the end of whatever disk the image was
	#    copied onto (distro/init/growroot.odin), then deletes the file.
	#  - the time zone.
	#  - no /etc/machine-id: palm-init makes one on the first boot, so two
	#    copies of the image are two machines.
	cat >>"$rootfs/etc/fstab" <<-FSTAB
	LABEL=palmframe	/	ext4	rw,relatime	0 1
	LABEL=PALMESP	/boot/efi	vfat	rw,relatime,fmask=0077,dmask=0077,shortname=mixed,utf8,errors=remount-ro	0 2
	FSTAB
	: >"$rootfs/etc/palm/grow-root"
	[ -e "$rootfs/usr/share/zoneinfo/$tz" ] || { echo "image: no time zone $tz in tzdata" >&2; exit 1; }
	ln -sfn "../usr/share/zoneinfo/$tz" "$rootfs/etc/localtime"
	echo "$tz" >"$rootfs/etc/timezone"
	rm -f "$rootfs/etc/machine-id"

	# The repository the installed system uses is the one palmframe-base
	# ships in /etc/palm/repositories (the build host over QEMU user
	# networking, http://10.0.2.2:8080/x86_64). Say so here, so a changed
	# base file does not silently produce an image that points nowhere.
	grep -q "^http://10.0.2.2:" "$rootfs/etc/palm/repositories" ||
		echo "image: warning: /etc/palm/repositories is not the host repository" >&2

	# Size: what is installed plus room to grow, rounded to 4 MiB.
	used=$(du -s --block-size=1M "$rootfs" | cut -f1)
	mib=$(( (used + extra + 3) / 4 * 4 ))
	echo $((mib * 1024 * 1024)) > "$work/root.bytes"
	truncate -s "${mib}M" "$work/root.ext4"
	mkfs.ext4 -q -F -L palmframe -E root_owner=0:0 -d "$rootfs" "$work/root.ext4"
' fakeroot-image "$PALM" "$ROOTFS" "$REPO" "$KEYS" "$WORK" "$ROOT_EXTRA_MIB" "$TIMEZONE" "$PACKAGES"
ROOT_BYTES=$(cat "$root_bytes_file")

# Ownership as the image records it, read back with debugfs rather than
# trusted: shadow must be root 0600, palm's home 1000.
stat_of() { debugfs -R "stat $1" "$WORK/root.ext4" 2>/dev/null | sed -n 's/.*User: *\([0-9]*\) *Group: *\([0-9]*\).*/\1:\2/p; s/.*Mode: *\([0-7]*\).*/\1/p' | tr '\n' ' '; }
echo "image: /etc/shadow $(stat_of /etc/shadow)| /home/palm $(stat_of /home/palm)| /var/lib/greeter $(stat_of /var/lib/greeter)"

# --- 3: the EFI system partition ----------------------------------------------
cat >"$WORK/limine.conf" <<EOF
# limine boots the kernel from this partition; the root filesystem is the
# ext4 partition after it. Written by distro/image/build.sh.
timeout: 3
default_entry: 1

/Palmframe
    protocol: linux
    path: boot():/boot/vmlinuz
    cmdline: $CMDLINE

/Palmframe (log in automatically as palm)
    protocol: linux
    path: boot():/boot/vmlinuz
    cmdline: $CMDLINE palm.autologin=palm

/Palmframe (single user, root shell)
    protocol: linux
    path: boot():/boot/vmlinuz
    cmdline: ${CMDLINE/ quiet loglevel=3/} palm.single
EOF

ESP="$WORK/esp.fat"
truncate -s "${ESP_MIB}M" "$ESP"
mformat -i "$ESP" -F -v PALMESP ::
mmd -i "$ESP" ::/EFI ::/EFI/BOOT ::/boot ::/boot/limine
mcopy -i "$ESP" "$LIMINE_SHARE/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP" "$LIMINE_SHARE/limine-bios.sys" ::/boot/limine/limine-bios.sys
mcopy -i "$ESP" "$WORK/limine.conf" ::/boot/limine/limine.conf
mcopy -i "$ESP" "$ROOTFS/boot/vmlinuz" ::/boot/vmlinuz

# --- the disk -----------------------------------------------------------------
# The GPT and 1 MiB of alignment, a 1 MiB BIOS boot partition for limine's
# legacy stage 2, the ESP, the root, and 1 MiB at the end for the backup GPT.
# The BIOS boot partition is physically first but entry 3, so the ESP and the
# root stay /dev/vda1 and /dev/vda2.
MiB=$((1024 * 1024))
BIOS_START=$MiB
ESP_START=$((2 * MiB))
ROOT_START=$((ESP_START + ESP_MIB * MiB))
TOTAL=$((ROOT_START + ROOT_BYTES + MiB))
rm -f "$IMG.tmp"
truncate -s "$TOTAL" "$IMG.tmp"
sfdisk --quiet "$IMG.tmp" <<EOF
label: gpt
${IMG}.tmp1 : start=$((ESP_START / 512)), size=$((ESP_MIB * MiB / 512)), type=uefi, name="EFI system"
${IMG}.tmp2 : start=$((ROOT_START / 512)), size=$((ROOT_BYTES / 512)), type=linux, name="palmframe"
${IMG}.tmp3 : start=$((BIOS_START / 512)), size=$((MiB / 512)), type=21686148-6449-6E6F-744E-656564454649, name="BIOS boot"
EOF
dd if="$ESP" of="$IMG.tmp" bs=1M seek=$((ESP_START / MiB)) conv=notrunc,sparse status=none
dd if="$WORK/root.ext4" of="$IMG.tmp" bs=1M seek=$((ROOT_START / MiB)) conv=notrunc,sparse status=none

# --- 4: legacy BIOS -----------------------------------------------------------
# limine's stage 1 goes into the protective MBR, stage 2 into partition 3.
limine bios-install "$IMG.tmp" 3 >"$WORK/limine.log" 2>&1 || { cat "$WORK/limine.log" >&2; exit 1; }

mv -f "$IMG.tmp" "$IMG"
rm -f "$WORK/root.ext4" "$ESP"
echo "image: $IMG ($(du -h --apparent-size "$IMG" | cut -f1), $(du -h "$IMG" | cut -f1) on disk); $(wc -l <"$ROOTFS/etc/palm/world") package(s) in world, $(grep -c '^pkgname' "$ROOTFS/usr/lib/palm/db/installed") installed"
