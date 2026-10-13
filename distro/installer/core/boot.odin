package install_core

// Step 6: make the disk boot.
//
// limine is the boot loader, as on the shipped image. UEFI firmware reads
// FAT, not ext4, so everything the firmware and limine need lives on the
// ESP:
//
//   EFI/BOOT/BOOTX64.EFI        the removable-media fallback path: any UEFI
//                               machine boots this disk with no NVRAM entry
//   EFI/palmframe/BOOTX64.EFI   the same binary, where our Boot#### points,
//                               so another OS reinstalling the fallback path
//                               cannot take Palmframe's entry with it
//   boot/limine/limine.conf     limine looks next to itself first, then here;
//                               both copies of the binary find this one
//   vmlinuz                     a copy of the root's /boot/vmlinuz
//
// The kernel is told its root by PARTUUID, which the kernel resolves itself
// (no initramfs, no blkid), and which stays right if disks are renumbered.
//
// Then, if asked, a UEFI boot entry: an EFI_LOAD_OPTION (UEFI 2.10 §3.1.3)
// in a Boot#### variable, and that number first in BootOrder, written through
// efivarfs. The device path is the short form efibootmgr writes — a hard
// drive node naming the partition by GUID, then the file path — which the
// firmware expands by finding the partition. Failing to write the entry does
// not fail the installation: the fallback path still boots.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf16"

EFI_GLOBAL_GUID :: "8be4df61-93ca-11d2-aa0d-00e098032b8c"
EFI_VARIABLE_NON_VOLATILE :: 0x1
EFI_VARIABLE_BOOTSERVICE_ACCESS :: 0x2
EFI_VARIABLE_RUNTIME_ACCESS :: 0x4
LOAD_OPTION_ACTIVE :: 0x1
FS_IOC_GETFLAGS :: 0x80086601
FS_IOC_SETFLAGS :: 0x40086602
FS_IMMUTABLE_FL :: 0x10
EFIVARFS_MAGIC :: 0xde5e81e4

BOOT_ENTRY_NAME :: "Palmframe"
BOOT_LOADER_PATH :: "\\EFI\\palmframe\\BOOTX64.EFI"
KERNEL_CMDLINE_TAIL :: "rw console=tty0 console=ttyS0,115200 quiet loglevel=3"

@(private)
step_bootloader :: proc(c: ^Ctx) -> string {
	if e := load_parts(c); e != "" {
		return e
	}
	esp := c.t.esp
	if c.o.dry_run {
		logf(c, "would install limine to %s/EFI/BOOT and %s/EFI/palmframe, copy the kernel, write limine.conf with root=PARTUUID=<root>", esp, esp)
		if c.p.efi_boot_entry {
			logf(c, "would write Boot#### \"%s\" -> %s and put it first in BootOrder", BOOT_ENTRY_NAME, BOOT_LOADER_PATH)
		}
		return ""
	}

	limine := join(c.t.root, "usr/share/limine/BOOTX64.EFI")
	if !os.is_file(limine) {
		limine = join(c.o.limine_dir, "BOOTX64.EFI")
	}
	if !os.is_file(limine) {
		return fmt.tprintf("limine's BOOTX64.EFI was found neither in the target's /usr/share/limine nor in %s", c.o.limine_dir)
	}
	kernel := join(c.t.root, "boot/vmlinuz")
	if !os.is_file(kernel) {
		return "the target has no /boot/vmlinuz; is the linux package installed?"
	}

	progress(c, 0.1, "Copying the boot loader")
	for d in ([]string{"EFI/BOOT", "EFI/palmframe", "boot/limine"}) {
		if e := mkdir_p(join(esp, d)); e != nil {
			return fmt.tprintf("mkdir %s: %v", join(esp, d), e)
		}
	}
	for dst in ([]string{"EFI/BOOT/BOOTX64.EFI", "EFI/palmframe/BOOTX64.EFI"}) {
		if e := os.copy_file(join(esp, dst), limine); e != nil {
			return fmt.tprintf("copy %s: %v", dst, e)
		}
	}
	progress(c, 0.3, "Copying the kernel")
	if e := os.copy_file(join(esp, "vmlinuz"), kernel); e != nil {
		return fmt.tprintf("copy the kernel: %v", e)
	}
	if e := write_file(c, join(esp, "boot/limine/limine.conf"), limine_conf(c.parts.root_guid), 0o644); e != "" {
		return e
	}
	logf(c, "limine installed on the ESP from %s", limine)

	if !c.p.efi_boot_entry {
		logf(c, "no UEFI boot entry requested; the disk boots through EFI/BOOT/BOOTX64.EFI")
		return ""
	}
	progress(c, 0.7, "Adding the UEFI boot entry")
	num, werr := write_boot_entry(c)
	if werr != "" {
		logf(c, "warning: UEFI boot entry not written: %s (the disk still boots through the fallback path)", werr)
		progress(c, 1, "UEFI boot entry not written; the disk still boots through the fallback path")
		return ""
	}
	logf(c, "UEFI: Boot%04X \"%s\" -> %s, first in BootOrder", num, BOOT_ENTRY_NAME, BOOT_LOADER_PATH)
	return ""
}

limine_conf :: proc(root_guid: Guid) -> string {
	cmdline := fmt.tprintf("root=PARTUUID=%s %s", partuuid(root_guid), KERNEL_CMDLINE_TAIL)
	single := fmt.tprintf("root=PARTUUID=%s rw console=tty0 console=ttyS0,115200 palm.single", partuuid(root_guid))
	return fmt.tprintf(`# limine boots the kernel from this partition (the ESP); the root file
# system is the ext4 partition named by PARTUUID. Written by palm-install.
timeout: 3
default_entry: 1

/Palmframe
    protocol: linux
    path: boot():/vmlinuz
    cmdline: %s

/Palmframe (single user, root shell)
    protocol: linux
    path: boot():/vmlinuz
    cmdline: %s
`, cmdline, single)
}

// --------------------------------------------------------- EFI_LOAD_OPTION --

// efi_load_option encodes a boot option for `path` on GPT partition
// `part_number` (1-based) starting at `start_lba` for `size_lba` sectors,
// identified by its partition GUID:
//
//   u32  Attributes            LOAD_OPTION_ACTIVE
//   u16  FilePathListLength    bytes of the device path below
//   u16[] Description          UTF-16LE, NUL terminated
//   device path:
//     04 01 2A00               media / hard drive, 42 bytes
//       u32 PartitionNumber, u64 PartitionStart, u64 PartitionSize,
//       u8[16] PartitionSignature (the GUID as stored on disk),
//       u8 PartitionFormat = 02 (GPT), u8 SignatureType = 02 (GUID)
//     04 04 LLLL               media / file path, 4 + UTF-16LE path + NUL
//     7F FF 0400               end of the entire device path
//   (no optional data)
efi_load_option :: proc(description: string, part_number: u32, start_lba, size_lba: u64, part_guid: Guid, path: string, allocator := context.allocator) -> []u8 {
	desc := utf16_z(description)
	file := utf16_z(path)
	hd_len := 42
	fp_len := 4 + 2 * len(file)
	dp_len := hd_len + fp_len + 4
	out := make([]u8, 4 + 2 + 2 * len(desc) + dp_len, allocator)
	put_u32(out[0:], LOAD_OPTION_ACTIVE)
	put_u16(out[4:], u16(dp_len))
	o := 6
	for u in desc {
		put_u16(out[o:], u)
		o += 2
	}
	// hard drive media device path
	out[o], out[o + 1] = 0x04, 0x01
	put_u16(out[o + 2:], u16(hd_len))
	put_u32(out[o + 4:], part_number)
	put_u64(out[o + 8:], start_lba)
	put_u64(out[o + 16:], size_lba)
	pg := part_guid
	copy(out[o + 24:o + 40], pg[:])
	out[o + 40] = 0x02
	out[o + 41] = 0x02
	o += hd_len
	// file path media device path
	out[o], out[o + 1] = 0x04, 0x04
	put_u16(out[o + 2:], u16(fp_len))
	o += 4
	for u in file {
		put_u16(out[o:], u)
		o += 2
	}
	// end of hardware device path, end entire device path
	out[o], out[o + 1], out[o + 2], out[o + 3] = 0x7F, 0xFF, 0x04, 0x00
	return out
}

// load_option_description reads the description back out of a Boot####
// variable's data (after efivarfs's 4 attribute bytes are stripped).
load_option_description :: proc(data: []u8) -> string {
	if len(data) < 6 {
		return ""
	}
	units := make([dynamic]u16, context.temp_allocator)
	for i := 6; i + 1 < len(data); i += 2 {
		u := get_u16(data[i:])
		if u == 0 {break}
		append(&units, u)
	}
	buf := make([]u8, 4 * len(units) + 4, context.temp_allocator)
	n := utf16.decode_to_utf8(buf, units[:])
	return string(buf[:n])
}

@(private = "file")
utf16_z :: proc(s: string) -> []u16 {
	buf := make([]u16, 2 * len(s) + 1, context.temp_allocator)
	n := utf16.encode_string(buf, s)
	return buf[:n + 1] // the terminating zero is already there
}

// ------------------------------------------------------------- efivarfs --

@(private = "file")
write_boot_entry :: proc(c: ^Ctx) -> (num: int, err: string) {
	dir := c.o.efivars
	if c.o.disk_image && dir == DEFAULT_EFIVARS {
		// A disk image is a test on someone's machine: its firmware's
		// variables are not ours to change.
		return 0, "not touching this machine's firmware variables for a disk image (give an efivars directory to test with)"
	}
	if dir == DEFAULT_EFIVARS {
		if !os.is_dir("/sys/firmware/efi") {
			return 0, "this machine did not boot through UEFI"
		}
		if !is_mountpoint(dir) {
			// palm-init does not mount efivarfs; the installer does, for as
			// long as it needs it.
			if e := mount(c, "efivarfs", dir, "efivarfs", ""); e != "" {
				return 0, e
			}
			defer _ = umount(c, dir)
			return write_boot_entry_in(c, dir)
		}
	}
	return write_boot_entry_in(c, dir)
}

@(private = "file")
write_boot_entry_in :: proc(c: ^Ctx, dir: string) -> (num: int, err: string) {
	entries, rerr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if rerr != nil {
		return 0, fmt.tprintf("%s: %v", dir, rerr)
	}
	// Reuse an entry of ours from an earlier installation rather than pile
	// up "Palmframe" entries; otherwise take the lowest free number.
	used := make(map[int]bool, context.temp_allocator)
	num = -1
	suffix :: "-" + EFI_GLOBAL_GUID
	for fi in entries {
		if !strings.has_prefix(fi.name, "Boot") || !strings.has_suffix(fi.name, suffix) || len(fi.name) != 8 + len(suffix) {
			continue
		}
		n, ok := strconv.parse_int(fi.name[4:8], 16)
		if !ok {continue}
		used[n] = true
		data, _ := os.read_entire_file_from_path(join(dir, fi.name), context.temp_allocator)
		if num < 0 && len(data) > 4 && load_option_description(data[4:]) == BOOT_ENTRY_NAME {
			num = n
		}
	}
	if num < 0 {
		for num = 0; used[num]; num += 1 {}
	}
	if num > 0xFFFF {
		return 0, "no free Boot#### number"
	}

	opt := efi_load_option(BOOT_ENTRY_NAME, 1, c.parts.esp_first_lba, c.parts.esp_sectors, c.parts.esp_guid, BOOT_LOADER_PATH, context.temp_allocator)
	if e := efivar_write(join(dir, fmt.tprintf("Boot%04X%s", num, suffix)), opt); e != "" {
		return 0, e
	}

	order_path := join(dir, "BootOrder" + suffix)
	order := make([dynamic]u16, context.temp_allocator)
	append(&order, u16(num))
	if data, e := os.read_entire_file_from_path(order_path, context.temp_allocator); e == nil && len(data) > 4 {
		for i := 4; i + 1 < len(data); i += 2 {
			v := get_u16(data[i:])
			if int(v) != num && !slice.contains(order[:], v) {
				append(&order, v)
			}
		}
	}
	buf := make([]u8, 2 * len(order), context.temp_allocator)
	for v, i in order {
		put_u16(buf[2 * i:], v)
	}
	if e := efivar_write(order_path, buf); e != "" {
		return 0, fmt.tprintf("BootOrder: %s", e)
	}
	return num, ""
}

// efivar_write replaces a variable. efivarfs wants the 4 attribute bytes and
// the data in a single write(2), and marks existing variables immutable
// (chattr +i) so an rm cannot brick a machine; we clear that flag first.
// On a plain directory (the selftest) the ioctl fails harmlessly.
@(private = "file")
efivar_write :: proc(path: string, data: []u8) -> string {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if os.exists(path) {
		if fd, err := linux.open(cpath, {.CLOEXEC}); err == .NONE {
			flags: u64
			if int(linux.ioctl(fd, FS_IOC_GETFLAGS, uintptr(&flags))) == 0 && flags & FS_IMMUTABLE_FL != 0 {
				flags &~= FS_IMMUTABLE_FL
				_ = linux.ioctl(fd, FS_IOC_SETFLAGS, uintptr(&flags))
			}
			linux.close(fd)
		}
	}
	buf := make([]u8, 4 + len(data), context.temp_allocator)
	put_u32(buf, EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS)
	copy(buf[4:], data)
	fd, err := linux.open(cpath, {.WRONLY, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE {
		return fmt.tprintf("open %s: %v", path, err)
	}
	defer linux.close(fd)
	// On efivarfs the write replaces the variable whole; on an ordinary
	// directory (the selftest's stand-in) a shorter BootOrder must not keep
	// the old tail, so truncate there — and only there.
	sfs: linux.Stat_FS
	if linux.fstatfs(fd, &sfs) == .NONE && u32(sfs.type) != EFIVARFS_MAGIC {
		_ = linux.ftruncate(fd, 0)
	}
	n, werr := linux.write(fd, buf)
	if werr != .NONE {
		return fmt.tprintf("write %s: %v", path, werr)
	}
	if n != len(buf) {
		return fmt.tprintf("write %s: short write", path)
	}
	return ""
}
