#!/usr/bin/env bash
# Boot distro/out/palmframe.img in QEMU.
#
#	distro/run-qemu.sh                 a window (gtk), UEFI firmware, the serial
#	                                   console logged to distro/out/serial.log
#	distro/run-qemu.sh --serial        the serial console on this terminal too
#	                                   (a getty: log in as root / palm; ctrl-a x quits)
#	distro/run-qemu.sh --headless      no window; QMP on distro/out/qmp.sock for
#	                                   screendumps and input-send-event
#	distro/run-qemu.sh --serial-socket P   the serial console on a unix socket
#	                                   (QEMU waits for a client), for scripts
#	distro/run-qemu.sh --qmp-socket P      no window, QMP on P (image/test-boot.py)
#	distro/run-qemu.sh --direct        skip firmware and limine: -kernel/-append
#	                                   with the kernel from the image's build
#	distro/run-qemu.sh --bios          legacy BIOS (SeaBIOS) instead of OVMF
#	distro/run-qemu.sh --iso           boot the live installer
#	                                   (distro/out/palmframe-live.iso) as a CD,
#	                                   with a blank target disk on virtio;
#	                                   distro/out/target.qcow2 (8G) is created
#	                                   when missing
#	distro/run-qemu.sh --disk P        the virtio disk is P (qcow2 or raw)
#	                                   instead of the image; without --iso this
#	                                   boots P, e.g. the disk an install wrote
#	distro/run-qemu.sh -- <args>       anything after -- goes to QEMU as is
#
# The machine is the CONTRACT's standard one (virtio-vga, virtio keyboard and
# tablet, user networking) plus the disk on virtio-blk, which is why the root
# is /dev/vda2. With user networking the guest sees the host as 10.0.2.2, so
# `make -C distro serve` on the host is the repository the image's
# /etc/palm/repositories names.
#
# The disk is used in place: what the guest installs stays installed. Rebuild
# the image (make -C distro image) to start over.
#
# With --iso or --disk, OVMF's variable store lives beside that disk
# (<disk>.OVMF_VARS.fd) instead of beside the image, so the Boot#### entry the
# installer writes belongs to the disk it installed onto: install with
# `--iso`, then boot the result with `--disk distro/out/target.qcow2`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
IMG="${IMG:-$OUT/palmframe.img}"
OVMF_DIR="${OVMF_DIR:-$HOME/.local/opt/qemu/usr/share/edk2/x64}"
[ -d "$OVMF_DIR" ] || OVMF_DIR=/usr/share/edk2/x64

display=(-display gtk)
serial=(-serial "file:$OUT/serial.log")
firmware=uefi
direct=0
iso=""
disk=""
extra=()
while [ $# -gt 0 ]; do
	case "$1" in
	--headless)
		display=(-display none -qmp "unix:$OUT/qmp.sock,server,nowait")
		;;
	--serial) serial=(-serial mon:stdio) ;;
	--serial-socket) serial=(-serial "unix:$2,server=on,wait=on"); shift ;;
	--qmp-socket)
		display=(-display none -qmp "unix:$2,server=on,wait=off"); shift ;;
	--direct) direct=1 ;;
	--bios) firmware=bios ;;
	--iso) iso="$OUT/palmframe-live.iso" ;;
	--disk) disk="$2"; shift ;;
	--) shift; extra=("$@"); break ;;
	-h | --help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "run-qemu: unknown option $1 (see --help)" >&2; exit 2 ;;
	esac
	shift
done

if [ -n "$iso" ]; then
	[ -f "$iso" ] || { echo "run-qemu: $iso is missing (make -C distro iso)" >&2; exit 1; }
	[ "$direct" = 0 ] || { echo "run-qemu: --direct and --iso do not mix" >&2; exit 2; }
	if [ -z "$disk" ]; then
		disk="$OUT/target.qcow2"
		[ -f "$disk" ] || qemu-img create -q -f qcow2 "$disk" 8G
	fi
fi
if [ -n "$disk" ]; then
	[ -f "$disk" ] || { echo "run-qemu: $disk is missing (qemu-img create -f qcow2 $disk 8G)" >&2; exit 1; }
	case "$disk" in *.qcow2) fmt=qcow2 ;; *) fmt=raw ;; esac
	drive=(-drive "file=$disk,if=virtio,format=$fmt")
else
	[ -f "$IMG" ] || { echo "run-qemu: $IMG is missing (make -C distro)" >&2; exit 1; }
	drive=(-drive "file=$IMG,if=virtio,format=raw")
fi
cdrom=()
# On q35 -cdrom is an AHCI (SATA) CD drive, /dev/sr0 in the guest.
if [ -n "$iso" ]; then cdrom=(-cdrom "$iso" -boot order=dc,menu=off); fi

boot=()
if [ "$direct" = 1 ]; then
	# The same command line limine passes (distro/image/build.sh).
	boot=(-kernel "$OUT/bzImage"
		-append "root=/dev/vda2 rw console=tty0 console=ttyS0,115200 quiet loglevel=3")
elif [ "$firmware" = uefi ]; then
	# OVMF wants a writable copy of its variable store; keep one beside the
	# image so boot entries persist between runs of the same image.
	vars="$OUT/OVMF_VARS.4m.fd"
	if [ -n "$disk" ]; then vars="${disk%.*}.OVMF_VARS.fd"; fi
	[ -f "$vars" ] || cp "$OVMF_DIR/OVMF_VARS.4m.fd" "$vars"
	boot=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_DIR/OVMF_CODE.4m.fd"
		-drive "if=pflash,format=raw,file=$vars")
fi

exec qemu-system-x86_64 -enable-kvm -cpu host -m 2G -smp 4 \
	-machine q35 \
	"${boot[@]}" \
	"${drive[@]}" "${cdrom[@]}" \
	-device virtio-vga -device virtio-keyboard-pci -device virtio-tablet-pci \
	-nic user,model=virtio-net-pci \
	"${display[@]}" "${serial[@]}" \
	"${extra[@]}"
