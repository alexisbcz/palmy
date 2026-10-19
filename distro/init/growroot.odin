package main

// Growing the root to fill its disk: what cloud images do on first boot with
// growpart and resize2fs, done here with three system calls' worth of work.
//
// The disk image is built as small as its contents plus 1 GiB, and is meant
// to be copied onto (or `qemu-img resize`d to) something bigger. While
// /etc/palm/grow-root exists, palm-init, right after `/` is remounted
// read-write:
//
//	1. finds the partition `/` is on (stat("/") -> /sys/dev/block/M:m) and its
//	   disk, and reads the disk's GPT. The root must be the last partition on
//	   the disk; anything else is left alone.
//	2. moves the backup GPT (header and entries) to the disk's real end, sets
//	   the last usable LBA to match, and extends the root's entry to it,
//	   rounded down to a MiB. Both headers' and both entry arrays' CRC32s are
//	   rewritten, the protective MBR's size too. Backup first, primary last.
//	3. tells the kernel with BLKPG_RESIZE_PARTITION, which works while the
//	   partition is mounted.
//	4. grows ext4 online with EXT4_IOC_RESIZE_FS — the ioctl resize2fs
//	   itself uses on a mounted filesystem — to the partition's new size.
//
// and deletes the file. Steps that have nothing to do (the partition already
// fills the disk, the filesystem already fills the partition) are skipped, so
// `touch /etc/palm/grow-root` and a reboot after enlarging a disk again is
// also how a person asks for it. If the kernel refuses step 3, the file is
// kept and step 4 happens at the next boot, when the kernel reads the new
// table itself. Installed disks are partitioned to fill the disk and do not
// carry the file.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

GROW_FLAG :: "/etc/palm/grow-root"

BLKPG :: 0x1269
BLKPG_RESIZE_PARTITION :: 3
EXT4_IOC_RESIZE_FS :: 0x40086610 // _IOW('f', 16, __u64)

Blkpg_Partition :: struct {
	start, length: i64,
	pno:           i32,
	devname:       [64]u8,
	volname:       [64]u8,
}

Blkpg_Ioctl_Arg :: struct {
	op, flags, datalen: i32,
	data:               rawptr,
}

crc32 :: proc(data: []u8) -> u32 {
	crc: u32 = 0xFFFFFFFF
	for b in data {
		crc ~= u32(b)
		for _ in 0 ..< 8 {
			crc = (crc >> 1) ~ ((crc & 1) * 0xEDB88320)
		}
	}
	return ~crc
}

@(private = "file")
get32 :: proc(b: []u8, off: int) -> u32 {return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24}
@(private = "file")
get64 :: proc(b: []u8, off: int) -> u64 {return u64(get32(b, off)) | u64(get32(b, off + 4)) << 32}
@(private = "file")
put32 :: proc(b: []u8, off: int, v: u32) {b[off], b[off + 1], b[off + 2], b[off + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
@(private = "file")
put64 :: proc(b: []u8, off: int, v: u64) {put32(b, off, u32(v));put32(b, off + 4, u32(v >> 32))}

// Gpt is a disk's partition table as read: the primary header's block and
// the entry array, in logical blocks of `lbs` bytes.
Gpt :: struct {
	lbs:         u64,
	header:      []u8, // one block
	entries:     []u8,
	entries_lba: u64,
	count, size: u32,
}

gpt_parse :: proc(header_block, entries: []u8, lbs: u64) -> (g: Gpt, err: string) {
	h := header_block
	if string(h[:8]) != "EFI PART" {return g, "no GPT"}
	hsize := get32(h, 12)
	if hsize < 92 || u64(hsize) > lbs {return g, "bad GPT header size"}
	tmp := make([]u8, hsize, context.temp_allocator)
	copy(tmp, h[:hsize])
	put32(tmp, 16, 0)
	if crc32(tmp) != get32(h, 16) {return g, "GPT header checksum mismatch"}
	g.lbs = lbs
	g.header = h
	g.entries_lba = get64(h, 72)
	g.count = get32(h, 80)
	g.size = get32(h, 84)
	if g.size < 128 || g.count == 0 || u64(g.count) * u64(g.size) > u64(len(entries)) {return g, "bad GPT entry array"}
	g.entries = entries[:u64(g.count) * u64(g.size)]
	if crc32(g.entries) != get32(h, 88) {return g, "GPT entries checksum mismatch"}
	return g, ""
}

Grow_Plan :: struct {
	index:       int, // entry index of the partition to grow
	first, last: u64, // its LBAs now
	new_last:    u64, // its last LBA after
	last_usable: u64,
	backup_lba:  u64, // the backup header's LBA (the disk's last)
	backup_entries_lba: u64,
}

// gpt_plan_grow works out how partition `first_lba` can grow on a disk of
// total_lbas blocks. ok=false with a reason when it cannot; ok=true and
// new_last == last when it already fills the disk.
gpt_plan_grow :: proc(g: Gpt, first_lba, total_lbas: u64) -> (p: Grow_Plan, reason: string, ok: bool) {
	p.index = -1
	entries_blocks := (u64(g.count) * u64(g.size) + g.lbs - 1) / g.lbs
	if total_lbas < 2 * entries_blocks + 4 {return p, "the disk is too small", false}
	for i in 0 ..< int(g.count) {
		e := g.entries[i * int(g.size):]
		first := get64(e, 32)
		last := get64(e, 40)
		empty := true
		for b in e[:16] {if b != 0 {empty = false}}
		if empty {continue}
		if first == first_lba {
			p.index, p.first, p.last = i, first, last
		}
	}
	if p.index < 0 {return p, "the root's partition is not in the GPT", false}
	for i in 0 ..< int(g.count) {
		e := g.entries[i * int(g.size):]
		empty := true
		for b in e[:16] {if b != 0 {empty = false}}
		if empty || i == p.index {continue}
		if get64(e, 32) > p.first {return p, "the root is not the last partition on its disk", false}
	}
	p.backup_lba = total_lbas - 1
	p.backup_entries_lba = p.backup_lba - entries_blocks
	p.last_usable = p.backup_entries_lba - 1
	align := max(u64(1 << 20) / g.lbs, 1)
	end := (p.last_usable + 1) / align * align - 1
	p.new_last = p.last
	// Less than a MiB to gain is not worth a rewrite.
	if end > p.last && end - p.last >= align {p.new_last = end}
	return p, "", true
}

// gpt_apply rewrites the entry and both headers in memory for plan p; the
// caller writes primary header + entries, and backup entries + header.
gpt_apply :: proc(g: Gpt, p: Grow_Plan) -> (primary, backup: []u8) {
	put64(g.entries[p.index * int(g.size):], 40, p.new_last)
	ecrc := crc32(g.entries)
	hsize := int(get32(g.header, 12))

	primary = make([]u8, len(g.header), context.temp_allocator)
	copy(primary, g.header)
	put64(primary, 32, p.backup_lba) // alternate LBA
	put64(primary, 48, p.last_usable)
	put32(primary, 88, ecrc)
	put32(primary, 16, 0)
	put32(primary, 16, crc32(primary[:hsize]))

	backup = make([]u8, len(g.header), context.temp_allocator)
	copy(backup, primary)
	put64(backup, 24, p.backup_lba) // my LBA
	put64(backup, 32, 1)
	put64(backup, 72, p.backup_entries_lba)
	put32(backup, 16, 0)
	put32(backup, 16, crc32(backup[:hsize]))
	return
}

@(private = "file")
sys_path :: proc(dir, rel: string) -> string {
	return strings.concatenate({dir, rel}, context.temp_allocator)
}

@(private = "file")
sys_u64 :: proc(path: string) -> (u64, bool) {
	text, ok := read_file(path, context.temp_allocator)
	if !ok {return 0, false}
	return strconv.parse_u64(strings.trim_space(text), 10)
}

grow_root :: proc() {
	if !exists(GROW_FLAG) {return}
	done, reason := grow_root_steps()
	if done {
		linux.unlink(GROW_FLAG)
	} else {
		say("grow-root: %s; will try again at the next boot", reason)
	}
}

// grow_root_steps returns done=true when the flag can go: grown, nothing to
// do, or nothing that can ever be done.
@(private = "file")
grow_root_steps :: proc() -> (done: bool, reason: string) {
	st: linux.Stat
	if linux.stat("/", &st) != .NONE {return true, ""}
	dev := u64(st.dev)
	major := ((dev >> 8) & 0xfff) | ((dev >> 32) & ~u64(0xfff))
	minor := (dev & 0xff) | ((dev >> 12) & ~u64(0xff))
	sys := fmt.tprintf("/sys/dev/block/%d:%d", major, minor)
	pno, is_part := sys_u64(sys_path(sys, "/partition"))
	if !is_part {
		say("grow-root: / is not on a partition; nothing to grow")
		return true, ""
	}
	start, _ := sys_u64(sys_path(sys, "/start"))
	uevent, _ := read_file(sys_path(sys, "/uevent"), context.temp_allocator)
	part_name := uevent_value(uevent, "DEVNAME")
	disk_uevent, _ := read_file(sys_path(sys, "/../uevent"), context.temp_allocator)
	disk_name := uevent_value(disk_uevent, "DEVNAME")
	disk_sectors, _ := sys_u64(sys_path(sys, "/../size"))
	lbs, lok := sys_u64(sys_path(sys, "/../queue/logical_block_size"))
	if !lok || lbs < 512 {lbs = 512}
	if disk_name == "" || part_name == "" {return true, ""}
	disk_path := fmt.tprintf("/dev/%s", disk_name)
	total_lbas := disk_sectors * 512 / lbs

	fd, err := linux.open(strings.clone_to_cstring(disk_path, context.temp_allocator), {.RDWR, .CLOEXEC})
	if err != .NONE {return false, fmt.tprintf("cannot open %s (%v)", disk_path, err)}
	defer linux.close(fd)

	head := make([]u8, 2 * lbs, context.temp_allocator)
	if n, _ := linux.pread(fd, head, 0); u64(n) != 2 * lbs {return false, "cannot read the partition table"}
	header := head[lbs:]
	if string(header[:8]) != "EFI PART" {
		say("grow-root: %s has no GPT; not grown", disk_path)
		return true, ""
	}
	entries_lba := get64(header, 72)
	entries_len := u64(get32(header, 80)) * u64(get32(header, 84))
	if entries_len == 0 || entries_len > 1 << 20 {
		say("grow-root: %s: unusual GPT entry array; not grown", disk_path)
		return true, ""
	}
	entries_buf := make([]u8, (entries_len + lbs - 1) / lbs * lbs, context.temp_allocator)
	if n, _ := linux.pread(fd, entries_buf, i64(entries_lba * lbs)); n != len(entries_buf) {return false, "cannot read the GPT entries"}
	g, perr := gpt_parse(header, entries_buf, lbs)
	if perr != "" {
		say("grow-root: %s: %s; not grown", disk_path, perr)
		return true, ""
	}
	plan, why, ok := gpt_plan_grow(g, start * 512 / lbs, total_lbas)
	if !ok {
		say("grow-root: %s; not grown", why)
		return true, ""
	}

	if plan.new_last > plan.last || get64(header, 32) != plan.backup_lba {
		primary, backup := gpt_apply(g, plan)
		// Backup first: until the primary is rewritten, the old table is
		// the one in force, and it is still intact.
		if n, _ := linux.pwrite(fd, g.entries, i64(plan.backup_entries_lba * lbs)); n != len(g.entries) {return false, "cannot write the backup GPT"}
		if n, _ := linux.pwrite(fd, backup, i64(plan.backup_lba * lbs)); n != len(backup) {return false, "cannot write the backup GPT"}
		linux.fsync(fd)
		if n, _ := linux.pwrite(fd, g.entries, i64(entries_lba * lbs)); n != len(g.entries) {return false, "cannot write the GPT"}
		if n, _ := linux.pwrite(fd, primary, i64(lbs)); n != len(primary) {return false, "cannot write the GPT"}
		// The protective MBR's one partition covers the disk.
		mbr := head[:512]
		if mbr[510] == 0x55 && mbr[511] == 0xAA && mbr[446 + 4] == 0xEE {
			put32(mbr, 446 + 12, u32(min(total_lbas - 1, 0xFFFFFFFF)))
			linux.pwrite(fd, mbr, 0)
		}
		linux.fsync(fd)
		if plan.new_last > plan.last {
			say("grow-root: %s%d now ends at %d MiB (was %d MiB)", disk_name, pno, (plan.new_last + 1) * lbs >> 20, (plan.last + 1) * lbs >> 20)
			bp := Blkpg_Partition {
				start  = i64(plan.first * lbs),
				length = i64((plan.new_last - plan.first + 1) * lbs),
				pno    = i32(pno),
			}
			arg := Blkpg_Ioctl_Arg {
				op      = BLKPG_RESIZE_PARTITION,
				datalen = size_of(Blkpg_Partition),
				data    = &bp,
			}
			if r := i64(linux.ioctl(fd, BLKPG, uintptr(&arg))); r < 0 {
				return false, fmt.tprintf("the kernel did not take the new size (errno %d)", -r)
			}
		}
	}

	// The filesystem: ext4's superblock says its size; the partition's
	// size is the kernel's (just updated, or read at boot).
	part_sectors, _ := sys_u64(sys_path(sys, "/size"))
	pfd, perr2 := linux.open(strings.clone_to_cstring(fmt.tprintf("/dev/%s", part_name), context.temp_allocator), {.CLOEXEC})
	if perr2 != .NONE {return false, "cannot open the root partition"}
	sb: [1024]u8
	n, _ := linux.pread(pfd, sb[:], 1024)
	linux.close(pfd)
	if n != 1024 || u32(sb[0x38]) | u32(sb[0x39]) << 8 != 0xEF53 {
		say("grow-root: / is not ext4; the filesystem is not grown")
		return true, ""
	}
	block := u64(1024) << get32(sb[:], 0x18)
	blocks := u64(get32(sb[:], 0x04))
	if get32(sb[:], 0x60) & 0x80 != 0 { 	// INCOMPAT_64BIT
		blocks |= u64(get32(sb[:], 0x150)) << 32
	}
	want := part_sectors * 512 / block
	if want <= blocks || (want - blocks) * block < 1 << 20 {
		return true, ""
	}
	rfd, rerr := linux.open("/", {.DIRECTORY, .CLOEXEC})
	if rerr != .NONE {return false, "cannot open /"}
	defer linux.close(rfd)
	if r := i64(linux.ioctl(rfd, EXT4_IOC_RESIZE_FS, uintptr(&want))); r < 0 {
		return false, fmt.tprintf("EXT4_IOC_RESIZE_FS failed (errno %d)", -r)
	}
	say("grow-root: / grown from %d MiB to %d MiB", blocks * block >> 20, want * block >> 20)
	return true, ""
}
