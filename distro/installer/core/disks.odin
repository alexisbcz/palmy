package install_core

// Which disks there are, from /sys/block, and which of them must not be
// touched.
//
// /sys/block lists every whole block device the kernel knows. Some are not
// disks anyone would install to — loop devices, RAM disks, CD drives,
// compressed swap in RAM — and are left out by name. The rest are described
// from sysfs alone (size, model, removable, read-only, partitions), which
// needs no privileges and opens no device, so `palm-install --list-disks`
// is safe to run anywhere.
//
// The live medium is the disk the running system came from. Installing over
// it would destroy the system doing the installing, so it is marked and
// validate() refuses it. Two ways to recognise it:
//
//   * it holds the mounted root filesystem (running palm-install from an
//     installed Palmy, or from a live system that mounted its medium), or
//   * it carries an ISO 9660 volume descriptor ("CD001" at byte 32769):
//     the hybrid live ISO written to a USB stick. This one reads the device,
//     so it is only checked when running as root, i.e. on the live system,
//     never as an ordinary user on a build host.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

list_disks :: proc(allocator := context.allocator) -> []Disk {
	return list_disks_in("/sys/block", "/dev", linux.geteuid() == 0, allocator)
}

// list_disks_in is list_disks against any sysfs-shaped tree; the selftest
// gives it a fake one.
list_disks_in :: proc(sys_block, dev_dir: string, read_signatures: bool, allocator := context.allocator) -> []Disk {
	context.allocator = allocator
	out := make([dynamic]Disk)
	entries, err := os.read_all_directory_by_path(sys_block, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	root_disk := disk_of_mount("/")
	for fi in entries {
		name := fi.name
		if skip_device(name) {
			continue
		}
		dir := join(sys_block, name)
		sectors := read_u64(join(dir, "size"))
		if sectors == 0 {
			continue // an empty card reader, an unattached nbd
		}
		d := Disk {
			path       = strings.clone(join(dev_dir, name)),
			name       = strings.clone(name),
			size_bytes = sectors * 512, // sysfs counts 512-byte units whatever the device's sector
			removable  = read_trim(join(dir, "removable")) == "1",
			readonly   = read_trim(join(dir, "ro")) == "1",
		}
		d.model = strings.clone(disk_model(dir, name))
		subs, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for s in subs {
			if strings.has_prefix(s.name, name) && os.exists(join(dir, s.name, "partition")) {
				d.has_partitions = true
			}
		}
		if root_disk != "" && root_disk == name {
			d.is_live_medium = true
		}
		if read_signatures && !d.is_live_medium && has_iso9660(d.path) {
			d.is_live_medium = true
		}
		append(&out, d)
	}
	slice.sort_by(out[:], proc(a, b: Disk) -> bool {return a.name < b.name})
	return out[:]
}

@(private = "file")
skip_device :: proc(name: string) -> bool {
	for p in ([]string{"loop", "ram", "sr", "zram", "fd", "nbd", "dm-", "md"}) {
		if strings.has_prefix(name, p) {
			return true
		}
	}
	return false
}

@(private = "file")
disk_model :: proc(dir, name: string) -> string {
	model := read_trim(join(dir, "device/model"))
	vendor := read_trim(join(dir, "device/vendor"))
	if model != "" {
		if vendor != "" && !strings.has_prefix(vendor, "0x") && !strings.has_prefix(model, vendor) {
			return fmt.tprintf("%s %s", vendor, model)
		}
		return model
	}
	// virtio-blk has no model string; say what it is rather than nothing.
	if strings.has_prefix(name, "vd") {
		return "VirtIO disk"
	}
	if strings.has_prefix(name, "mmcblk") {
		if n := read_trim(join(dir, "device/name")); n != "" {
			return n
		}
		return "SD/MMC card"
	}
	return ""
}

// partition_path is the device node of partition `n` of `disk`: vda -> vda1,
// but nvme0n1 -> nvme0n1p1 and mmcblk0 -> mmcblk0p1, because a name that
// already ends in a digit gets a 'p' first.
partition_path :: proc(disk: string, n: int, allocator := context.allocator) -> string {
	last := disk[len(disk) - 1]
	if last >= '0' && last <= '9' {
		return fmt.aprintf("%sp%d", disk, n, allocator = allocator)
	}
	return fmt.aprintf("%s%d", disk, n, allocator = allocator)
}

// disk_of_mount finds the whole-disk name holding the filesystem mounted at
// `mountpoint`, through /proc/self/mountinfo's major:minor and
// /sys/dev/block. "" when it is not on a block device (tmpfs, initramfs).
disk_of_mount :: proc(mountpoint: string) -> string {
	data, err := os.read_entire_file_from_path("/proc/self/mountinfo", context.temp_allocator)
	if err != nil {
		return ""
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 5 || f[4] != mountpoint {
			continue
		}
		if d := disk_of_devnum(f[2]); d != "" {
			return d
		}
	}
	return ""
}

// disks_in_use returns the whole disks that have any mounted filesystem.
disks_in_use :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	data, err := os.read_entire_file_from_path("/proc/self/mountinfo", context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 5 {continue}
		if d := disk_of_devnum(f[2]); d != "" && !slice.contains(out[:], d) {
			append(&out, d)
		}
	}
	return out[:]
}

@(private = "file")
disk_of_devnum :: proc(devnum: string) -> string {
	if strings.has_prefix(devnum, "0:") {
		return "" // anonymous: tmpfs, proc, overlay...
	}
	link, err := os.read_link(join("/sys/dev/block", devnum), context.temp_allocator)
	if err != nil {
		return ""
	}
	// .../block/vda/vda2 for a partition, .../block/vda for a whole disk.
	parts := strings.split(link, "/", context.temp_allocator)
	if len(parts) == 0 {return ""}
	leaf := parts[len(parts) - 1]
	if os.exists(join("/sys/dev/block", devnum, "partition")) && len(parts) >= 2 {
		return strings.clone(parts[len(parts) - 2], context.temp_allocator)
	}
	return strings.clone(leaf, context.temp_allocator)
}

@(private = "file")
has_iso9660 :: proc(path: string) -> bool {
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
	if err != .NONE {
		return false
	}
	defer linux.close(fd)
	buf: [5]u8
	n, rerr := linux.pread(fd, buf[:], 32769)
	return rerr == .NONE && n == 5 && string(buf[:]) == "CD001"
}

// ------------------------------------------------------------- file helpers --

read_trim :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

read_u64 :: proc(path: string) -> u64 {
	v, _ := strconv.parse_u64(read_trim(path))
	return v
}
