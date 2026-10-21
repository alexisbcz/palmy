#!/bin/bash
# arch-container.sh -- pkg against a real pacman, a real sudo and a real
# snapper, in an Arch Linux ARM container. Re-runnable; each run starts from a
# fresh copy of the image.
#
#   bash apps/pkg/integration/arch-container.sh [--rebuild-base] [--keep]
#
# Runs in the build VM (Linux, arm64) and needs: podman, btrfs-progs, bsdtar,
# curl, jq-free bash, and sudo on the VM (to mount a loop filesystem and run
# rootful podman). It never touches the machine it runs on beyond its state
# directory, a loop mount under it, and three containers named palmy-pkg-it-*.
#
# WHAT IT BUILDS
#   $STATE/btr.img       a sparse loopback btrfs filesystem (20G)
#   $STATE/mnt/@base     the official Arch Linux ARM aarch64 rootfs, unpacked
#                        once into a subvolume and kept read-only
#   $STATE/mnt/@run      a fresh writable snapshot of @base per run; it is the
#                        container's root filesystem, so / inside is btrfs and
#                        snapper works on it for real
#   $STATE/it/           shared with the containers: results, the numbers one
#                        phase hands the next, and a cache of the
#                        limine-snapper-sync package built from the AUR
#
# THE PHASES (inside.sh holds the assertions)
#   setup  keyring, a full -Syu by the harness (with one leaf held back for
#          pkg's upgrade to do), sudo/snapper/jq, the `palm` user, snapper on
#          /, limine-snapper-sync built from the AUR and its service started
#   a      container A, / = @run (the usual Arch layout: a plain subvolume):
#          every pkg verb for real, each compared with its --dry-run argv
#          through sudo's JSON log and pacman's log
#   b      container B, / = a writable snapper snapshot made the btrfs default
#          (the openSUSE layout, the only one `snapper rollback` accepts):
#          pkg rollback for real
#   c      container C, / = the snapshot that rollback made the default -- the
#          "reboot" -- to check the system is the one from before the install
#
# SAFETY. The containers get their own network namespace (podman's default
# bridge). Their systemd-networkd, -resolved, -timesyncd and dhcpcd are masked
# before boot: the first attempt ran systemd with --network host, and the
# container's networkd took the VM's eth0 lease with it when it stopped (the
# VM was off IPv4 for about a minute). The containers are not --privileged;
# they get CAP_SYS_ADMIN only, which btrfs set-default and snapper need.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
STATE=${PALM_PKG_IT_STATE:-/var/lib/palmy-pkg-it}
TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
ODIN=${ODIN:-$HOME/.local/share/mise/installs/odin/dev-2026-09/odin}
REBUILD=0; KEEP=0
for a in "$@"; do
	case "$a" in
	--rebuild-base) REBUILD=1 ;;
	--keep) KEEP=1 ;;
	*) echo "usage: $0 [--rebuild-base] [--keep]" >&2; exit 2 ;;
	esac
done

MNT=$STATE/mnt
SHARED=$STATE/it
MASK=(systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
	systemd-networkd-varlink.socket systemd-networkd-resolve-hook.socket systemd-resolved.service
	systemd-timesyncd.service dhcpcd.service sshd.service)

say() { echo; echo "### $*"; }
die() { echo "arch-container: $*" >&2; exit 1; }

for t in podman btrfs bsdtar curl; do command -v $t >/dev/null || die "needs $t"; done
[ "$(uname -m)" == aarch64 ] || die "the image is Arch Linux ARM aarch64; run this in the arm64 build VM"

# ---------------------------------------------------------------- pkg itself
say "building pkg from $REPO"
BIN=$(mktemp -d)/pkg.bin
"$ODIN" build "$REPO/apps/pkg" -collection:palmy="$REPO/palmy" -collection:shadcn="$REPO/shadcn" \
	-collection:kit="$REPO/apps/kit" -out:"$BIN" 2>&1 || die "pkg did not build"
echo "pkg self-test: $("$BIN" --selftest 2>/dev/null | tail -1)"
sudo mkdir -p "$STATE" && sudo cp "$BIN" "$STATE/pkg.bin" && rm -rf "$(dirname "$BIN")"
echo "commit: $(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null)"

# ---------------------------------------------------------------- filesystem
say "loopback btrfs at $MNT"
sudo mkdir -p "$MNT" "$SHARED"
if ! mountpoint -q "$MNT"; then
	if [ ! -f "$STATE/btr.img" ] || [ $REBUILD == 1 ]; then
		sudo rm -f "$STATE/btr.img"
		sudo truncate -s 20G "$STATE/btr.img"
		sudo mkfs.btrfs -q -L palmy-pkg-it "$STATE/btr.img" || die "mkfs.btrfs"
	fi
	sudo mount -o loop "$STATE/btr.img" "$MNT" || die "mount"
fi
FSUUID=$(sudo btrfs filesystem show "$MNT" | sed -n 's/.*uuid: //p' | head -1)
echo "btrfs uuid $FSUUID"

# Stop anything left from a previous run before touching its subvolumes.
for c in palmy-pkg-it-a palmy-pkg-it-b palmy-pkg-it-c; do sudo podman rm -f -t 5 $c >/dev/null 2>&1; done

# delete_tree <subvolume path relative to MNT>: nested subvolumes first.
delete_tree() {
	local top=$1
	sudo btrfs subvolume set-default 5 "$MNT" >/dev/null 2>&1
	sudo btrfs subvolume list "$MNT" | awk '{print $NF}' | grep -E "^$top(/|\$)" | awk '{print length, $0}' |
		sort -rn | cut -d' ' -f2- | while read -r sv; do
		sudo btrfs property set -ts "$MNT/$sv" ro false >/dev/null 2>&1
		sudo btrfs subvolume delete "$MNT/$sv" >/dev/null || die "could not delete $sv"
	done
}

if [ $REBUILD == 1 ] || [ ! -d "$MNT/@base/etc" ]; then
	say "unpacking Arch Linux ARM into @base"
	if [ ! -f "$STATE/alarm.tar.gz" ] || [ $REBUILD == 1 ]; then
		sudo curl -sSLf -o "$STATE/alarm.tar.gz" "$TARBALL_URL" || die "download"
		sudo rm -f "$STATE/alarm.tar.gz.md5"
	fi
	[ -f "$STATE/alarm.tar.gz.md5" ] || sudo curl -sSLf -o "$STATE/alarm.tar.gz.md5" "$TARBALL_URL.md5" || die "download md5"
	(cd "$STATE" && sed 's/ArchLinuxARM-aarch64-latest.tar.gz/alarm.tar.gz/' alarm.tar.gz.md5 | md5sum -c -) || die "checksum"
	delete_tree @base
	sudo btrfs subvolume create "$MNT/@base" >/dev/null
	sudo bsdtar -xpf "$STATE/alarm.tar.gz" -C "$MNT/@base" || die "unpack"
	sudo btrfs property set -ts "$MNT/@base" ro true
fi
echo "image: $(sudo grep PRETTY_NAME "$MNT/@base/etc/os-release"), unpacked $(sudo stat -c %y "$MNT/@base/etc/os-release" | cut -d. -f1)"

say "fresh @run from @base"
delete_tree @run
sudo btrfs subvolume snapshot "$MNT/@base" "$MNT/@run" >/dev/null || die "snapshot @base"
for u in "${MASK[@]}"; do sudo ln -sf /dev/null "$MNT/@run/etc/systemd/system/$u"; done
sudo cp "$STATE/pkg.bin" "$MNT/@run/usr/local/bin/pkg"
sudo cp "$HERE/inside.sh" "$HERE/build-limine-snapper-sync.sh" "$MNT/@run/usr/local/bin/"
# Keep the AUR build cache; drop the previous run's results.
sudo rm -f "$SHARED/results" "$SHARED/vars"

# boot <name> <rootfs> [extra podman args...]
boot() {
	local name=$1 root=$2; shift 2
	sudo podman run -d --name "$name" --cap-add SYS_ADMIN --systemd=always \
		-v "$SHARED:/srv/it" "$@" --rootfs "$root" /usr/lib/systemd/systemd >/dev/null || die "podman run $name"
	local i
	for i in $(seq 1 60); do
		case "$(sudo podman exec "$name" systemctl is-system-running 2>/dev/null)" in
		running | degraded) return 0 ;;
		esac
		sleep 1
	done
	die "$name did not boot"
}
inside() { local name=$1; shift; sudo podman exec -e PKG_IT_FSUUID="$FSUUID" "$name" bash /usr/local/bin/inside.sh "$@"; }

say "container A: / is the plain subvolume @run"
boot palmy-pkg-it-a "$MNT/@run"
inside palmy-pkg-it-a setup
inside palmy-pkg-it-a a
sudo podman rm -f -t 10 palmy-pkg-it-a >/dev/null

BASE=$(sudo grep '^BASE=' "$SHARED/vars" | tail -1 | cut -d= -f2)
if [ -n "$BASE" ]; then
	say "container B: / is snapshot #$BASE, the btrfs default (openSUSE layout)"
	boot palmy-pkg-it-b "$MNT/@run/.snapshots/$BASE/snapshot" -v "$MNT/@run/.snapshots:/.snapshots"
	inside palmy-pkg-it-b b
	sudo podman rm -f -t 10 palmy-pkg-it-b >/dev/null
	echo "btrfs default subvolume on the host side: $(sudo btrfs subvolume get-default "$MNT")"
fi

ROLLED=$(sudo grep '^ROLLED=' "$SHARED/vars" | tail -1 | cut -d= -f2)
if [ -n "$ROLLED" ]; then
	say "container C: the reboot -- / is #$ROLLED, the subvolume rollback made the default"
	boot palmy-pkg-it-c "$MNT/@run/.snapshots/$ROLLED/snapshot" -v "$MNT/@run/.snapshots:/.snapshots"
	inside palmy-pkg-it-c c
	sudo podman rm -f -t 10 palmy-pkg-it-c >/dev/null
fi

say "result"
P=$(sudo grep -c '^PASS' "$SHARED/results")
F=$(sudo grep -c '^FAIL' "$SHARED/results")
sudo grep '^FAIL' "$SHARED/results" | sed 's/^/  /'
echo "$P passed, $F failed"
if [ $KEEP == 0 ]; then
	delete_tree @run
	sudo umount "$MNT"
	echo "(@run deleted and the filesystem unmounted; --keep leaves them for inspection)"
fi
[ "$F" == 0 ] && [ "$P" -gt 0 ]
