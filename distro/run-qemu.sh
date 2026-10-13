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
	--) shift; extra=("$@"); break ;;
	-h | --help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "run-qemu: unknown option $1 (see --help)" >&2; exit 2 ;;
	esac
	shift
done

[ -f "$IMG" ] || { echo "run-qemu: $IMG is missing (make -C distro)" >&2; exit 1; }

boot=()
if [ "$direct" = 1 ]; then
	# The same command line limine passes (distro/image/build.sh).
	boot=(-kernel "$OUT/bzImage"
		-append "root=/dev/vda2 rw console=tty0 console=ttyS0,115200 quiet loglevel=3")
elif [ "$firmware" = uefi ]; then
	# OVMF wants a writable copy of its variable store; keep one beside the
	# image so boot entries persist between runs of the same image.
	vars="$OUT/OVMF_VARS.4m.fd"
	[ -f "$vars" ] || cp "$OVMF_DIR/OVMF_VARS.4m.fd" "$vars"
	boot=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_DIR/OVMF_CODE.4m.fd"
		-drive "if=pflash,format=raw,file=$vars")
fi

exec qemu-system-x86_64 -enable-kvm -cpu host -m 2G -smp 4 \
	-machine q35 \
	"${boot[@]}" \
	-drive "file=$IMG,if=virtio,format=raw" \
	-device virtio-vga -device virtio-keyboard-pci -device virtio-tablet-pci \
	-nic user,model=virtio-net-pci \
	"${display[@]}" "${serial[@]}" \
	"${extra[@]}"
