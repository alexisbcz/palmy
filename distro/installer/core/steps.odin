package install_core

// Steps 1 to 4 and 7: partition, format, mount, packages, unmount.
//
// On a real disk these talk to the kernel directly: the table goes in with
// pwrite on the opened device (O_EXCL, so a disk with a mounted filesystem
// refuses to open), BLKRRPART asks the kernel to read the new table back,
// and devtmpfs makes the partition nodes, which we wait for. Mounting is
// mount(2) — there is no util-linux on Palmframe and busybox's mount would
// only add a process.
//
// With Options.disk_image the disk is a file on the build host. The same GPT
// code writes into it; mkfs runs on the file at the partitions' byte
// offsets; and since a file cannot be mounted without root, the remaining
// steps build the system in Options.target as a plain directory.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

BLKRRPART :: 0x125F
BLKSSZGET :: 0x1268
BLKGETSIZE64 :: 0x80081272

// ---------------------------------------------------------------- Partition --

@(private)
step_partition :: proc(c: ^Ctx) -> string {
	flags: linux.Open_Flags = {.RDWR, .CLOEXEC}
	if !c.o.disk_image {
		flags += {.EXCL} // fails with EBUSY while anything on the disk is mounted
	}
	if c.o.dry_run {
		logf(c, "would write a GPT on %s: BIOS boot partition in the first MiB, ESP 512 MiB (FAT32), root ext4 to the end", c.p.disk)
		return ""
	}
	fd, err := linux.open(strings.clone_to_cstring(c.p.disk, context.temp_allocator), flags)
	if err == .EBUSY {
		return fmt.tprintf("%s is in use (a filesystem on it is mounted)", c.p.disk)
	}
	if err != .NONE {
		return fmt.tprintf("open %s: %v", c.p.disk, err)
	}
	size, ss, serr := device_size(c, fd)
	if serr != "" {
		linux.close(fd)
		return serr
	}
	if size < MIN_DISK_BYTES {
		linux.close(fd)
		return fmt.tprintf("%s holds %s; at least 4 GiB is needed", c.p.disk, human_size(size))
	}
	logf(c, "%s: %d bytes, %d-byte sectors", c.p.disk, size, ss)

	g, ok := gpt_layout_palmframe(size, ss, context.temp_allocator)
	if !ok {
		linux.close(fd)
		return "cannot lay out partitions on this disk"
	}
	// Remember what the disk held: a UEFI boot entry that points at one of
	// these partitions pointed at this disk (boot.odin reuses it).
	if old, oerr := gpt_read(fd, size, ss, context.temp_allocator); oerr == "" {
		for op in old.parts {
			append(&c.old_guids, op.part_guid)
		}
		logf(c, "%s held a GPT with %d partitions; erasing it", c.p.disk, len(old.parts))
	}
	progress(c, 0.2, msg(.Writing_Partition_Table))
	if e := gpt_write(fd, g); e != "" {
		linux.close(fd)
		return e
	}
	// Read it back and check it is what we meant: CRCs, both copies, GUIDs.
	back, rerr := gpt_read(fd, size, ss, context.temp_allocator)
	linux.close(fd)
	if rerr != "" {
		return fmt.tprintf("the table just written does not read back: %s", rerr)
	}
	if back.disk_guid != g.disk_guid || len(back.parts) != len(g.parts) || back.parts[1].part_guid != g.parts[1].part_guid {
		return "the table just written reads back differently"
	}
	set_parts(c, back)
	logf(c, "GPT written: disk %s; ESP %s LBA %d+%d; root %s LBA %d+%d; BIOS boot %v",
		guid_string(g.disk_guid, context.temp_allocator),
		guid_string(c.parts.esp_guid, context.temp_allocator), c.parts.esp_first_lba, c.parts.esp_sectors,
		guid_string(c.parts.root_guid, context.temp_allocator), c.parts.root_first_lba, c.parts.root_sectors,
		c.parts.has_bios_boot)

	if c.o.disk_image {
		return ""
	}
	progress(c, 0.6, msg(.Waiting_For_Partitions))
	return reread_partitions(c)
}

@(private = "file")
device_size :: proc(c: ^Ctx, fd: linux.Fd) -> (size: u64, ss: u64, err: string) {
	if c.o.disk_image {
		st: linux.Stat
		if e := linux.fstat(fd, &st); e != .NONE {
			return 0, 0, fmt.tprintf("stat: %v", e)
		}
		return u64(st.size), 512, ""
	}
	sz: u64
	if r := linux.ioctl(fd, BLKGETSIZE64, uintptr(&sz)); int(r) < 0 {
		return 0, 0, fmt.tprintf("BLKGETSIZE64 failed (%d)", int(r))
	}
	s: i32
	if r := linux.ioctl(fd, BLKSSZGET, uintptr(&s)); int(r) < 0 || s < 512 {
		s = 512
	}
	return sz, u64(s), ""
}

// reread_partitions asks the kernel to rescan the table and waits until both
// partition nodes exist. BLKRRPART fails with EBUSY while a partition is
// open, which right after our own close can briefly be true, so it retries.
@(private = "file")
reread_partitions :: proc(c: ^Ctx) -> string {
	cpath := strings.clone_to_cstring(c.p.disk, context.temp_allocator)
	ok := false
	last: int
	for attempt in 0 ..< 10 {
		fd, err := linux.open(cpath, {.CLOEXEC})
		if err != .NONE {
			return fmt.tprintf("reopen %s: %v", c.p.disk, err)
		}
		linux.sync()
		r := linux.ioctl(fd, BLKRRPART, 0)
		linux.close(fd)
		last = int(r)
		if int(r) == 0 {
			ok = true
			break
		}
		logf(c, "BLKRRPART: %v, retrying (%d)", linux.Errno(-int(r)), attempt + 1)
		time.sleep(500 * time.Millisecond)
	}
	if !ok {
		return fmt.tprintf("the kernel did not accept the new partition table (BLKRRPART: %v)", linux.Errno(-last))
	}
	deadline := time.tick_now()
	for {
		if os.exists(c.parts.esp_dev) && os.exists(c.parts.root_dev) {
			logf(c, "partition nodes: %s %s", c.parts.esp_dev, c.parts.root_dev)
			return ""
		}
		if time.duration_seconds(time.tick_since(deadline)) > 15 {
			return fmt.tprintf("%s and %s did not appear", c.parts.esp_dev, c.parts.root_dev)
		}
		time.sleep(100 * time.Millisecond)
	}
}

@(private = "file")
set_parts :: proc(c: ^Ctx, g: Gpt) {
	esp := g.parts[0]
	root := g.parts[1]
	c.parts = Partition_Info {
		sector_size    = g.sector_size,
		esp_guid       = esp.part_guid,
		root_guid      = root.part_guid,
		esp_first_lba  = esp.first_lba,
		esp_sectors    = esp.last_lba - esp.first_lba + 1,
		root_first_lba = root.first_lba,
		root_sectors   = root.last_lba - root.first_lba + 1,
	}
	if len(g.parts) >= BIOS_BOOT_NUMBER && guid_string(g.parts[BIOS_BOOT_NUMBER - 1].type_guid, context.temp_allocator) == BIOS_BOOT_TYPE {
		c.parts.has_bios_boot = true
	}
	if !c.o.disk_image {
		c.parts.esp_dev = partition_path(c.p.disk, 1)
		c.parts.root_dev = partition_path(c.p.disk, 2)
	}
	c.have_parts = true
}

// load_parts reads the existing table when a run starts after the partition
// step (--steps format,..., or a configure-only test against an image).
@(private)
load_parts :: proc(c: ^Ctx) -> string {
	if c.have_parts {
		return ""
	}
	if c.o.dry_run {
		// Nothing was written; invent nothing either. Placeholders keep the
		// dry run's printed commands readable.
		c.parts.esp_dev = partition_path(c.p.disk, 1)
		c.parts.root_dev = partition_path(c.p.disk, 2)
		c.parts.sector_size = 512
		c.parts.esp_first_lba = 2048
		c.parts.esp_sectors = ESP_SIZE / 512
		c.parts.has_bios_boot = true
		c.have_parts = true
		return ""
	}
	fd, err := linux.open(strings.clone_to_cstring(c.p.disk, context.temp_allocator), {.CLOEXEC})
	if err != .NONE {
		return fmt.tprintf("open %s: %v", c.p.disk, err)
	}
	defer linux.close(fd)
	size, ss, serr := device_size(c, fd)
	if serr != "" {
		return serr
	}
	g, rerr := gpt_read(fd, size, ss, context.temp_allocator)
	if rerr != "" {
		return fmt.tprintf("%s: %s", c.p.disk, rerr)
	}
	if len(g.parts) < 2 || guid_string(g.parts[0].type_guid, context.temp_allocator) != ESP_TYPE {
		return fmt.tprintf("%s does not have the installer's layout (ESP, root)", c.p.disk)
	}
	set_parts(c, g)
	return ""
}

// ------------------------------------------------------------------- Format --

@(private)
step_format :: proc(c: ^Ctx) -> string {
	if e := load_parts(c); e != "" {
		return e
	}
	ss := c.parts.sector_size
	if c.o.disk_image {
		// mkfs.fat takes the offset in sectors and the size in KiB blocks;
		// mke2fs takes a byte offset and a size with a unit suffix.
		esp_kib := c.parts.esp_sectors * ss / 1024
		root_kib := c.parts.root_sectors * ss / 1024
		progress(c, 0.1, msg(.Formatting_Esp))
		if e := run(c, {"mkfs.fat", "-F", "32", "-n", "PALMEFI", fmt.tprintf("--offset=%d", c.parts.esp_first_lba * ss / 512), c.p.disk, fmt.tprintf("%d", esp_kib)}); e != "" {
			return e
		}
		progress(c, 0.4, msg(.Formatting_Root))
		return run(c, {"mkfs.ext4", "-F", "-q", "-L", "palmroot", "-E", fmt.tprintf("offset=%d", c.parts.root_first_lba * ss), c.p.disk, fmt.tprintf("%dk", root_kib)})
	}
	progress(c, 0.1, msg(.Formatting_Esp))
	if e := run(c, {"mkfs.fat", "-F", "32", "-n", "PALMEFI", c.parts.esp_dev}); e != "" {
		return e
	}
	progress(c, 0.4, msg(.Formatting_Root))
	return run(c, {"mkfs.ext4", "-F", "-q", "-L", "palmroot", c.parts.root_dev})
}

// -------------------------------------------------------------------- Mount --

@(private)
step_mount :: proc(c: ^Ctx) -> string {
	if c.o.disk_image {
		logf(c, "disk image: building the system in %s (a plain directory, not mounted)", c.t.root)
		if c.o.dry_run {return ""}
		if e := mkdir_p(c.t.esp); e != nil {
			return fmt.tprintf("mkdir %s: %v", c.t.esp, e)
		}
		return ""
	}
	if e := load_parts(c); e != "" {
		return e
	}
	if c.o.dry_run {
		logf(c, "would mount %s on %s (ext4) and %s on %s (vfat)", c.parts.root_dev, c.t.root, c.parts.esp_dev, c.t.esp)
		return ""
	}
	// A previous attempt that died half way may have left these mounted.
	for m in ([]string{c.t.esp, c.t.root}) {
		if is_mountpoint(m) {
			logf(c, "%s is still mounted from an earlier attempt; unmounting", m)
			if e := umount(c, m); e != "" {
				return e
			}
		}
	}
	if e := mkdir_p(c.t.root); e != nil {
		return fmt.tprintf("mkdir %s: %v", c.t.root, e)
	}
	if e := mount(c, c.parts.root_dev, c.t.root, "ext4", ""); e != "" {
		return e
	}
	c.mounted_root = true
	if e := mkdir_p(c.t.esp); e != nil {
		return fmt.tprintf("mkdir %s: %v", c.t.esp, e)
	}
	// The ESP holds the boot loader and a kernel; nobody but root needs to
	// read it, and FAT has no permissions of its own, so the masks decide.
	if e := mount(c, c.parts.esp_dev, c.t.esp, "vfat", "fmask=0077,dmask=0077"); e != "" {
		return e
	}
	c.mounted_esp = true
	return ""
}

@(private)
mount :: proc(c: ^Ctx, dev, dir, fstype, data: string) -> string {
	logf(c, "mount -t %s %s %s%s%s", fstype, dev, dir, data != "" ? " -o " : "", data)
	cdata := data != "" ? rawptr(strings.clone_to_cstring(data, context.temp_allocator)) : nil
	err := linux.mount(
		strings.clone_to_cstring(dev, context.temp_allocator),
		strings.clone_to_cstring(dir, context.temp_allocator),
		strings.clone_to_cstring(fstype, context.temp_allocator),
		{.RELATIME},
		cdata,
	)
	if err != .NONE {
		return fmt.tprintf("mount %s on %s: %v", dev, dir, err)
	}
	return ""
}

@(private)
umount :: proc(c: ^Ctx, dir: string) -> string {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	for attempt in 0 ..< 10 {
		err := linux.umount2(cdir, {})
		if err == .NONE {
			logf(c, "umount %s", dir)
			return ""
		}
		if err != .EBUSY {
			return fmt.tprintf("umount %s: %v", dir, err)
		}
		logf(c, "umount %s: busy, retrying (%d)", dir, attempt + 1)
		time.sleep(300 * time.Millisecond)
	}
	return fmt.tprintf("umount %s: still busy", dir)
}

@(private)
is_mountpoint :: proc(dir: string) -> bool {
	data, err := os.read_entire_file_from_path("/proc/self/mountinfo", context.temp_allocator)
	if err != nil {
		return false
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) >= 5 && f[4] == dir {
			return true
		}
	}
	return false
}

// ----------------------------------------------------------------- Packages --

@(private)
Pkg_Progress :: struct {
	total: int,
	done:  int,
}

@(private = "file")
pkg_state: Pkg_Progress

@(private)
step_packages :: proc(c: ^Ctx) -> string {
	repo := c.p.repo
	// palm takes a path or an http:// URL; file:// is the installer's
	// spelling for "a path on the live medium".
	if strings.has_prefix(repo, "file://") {
		repo = repo[len("file://"):]
	}
	palm := c.o.palm != "" ? c.o.palm : "palm"
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, palm, "--root", c.t.root, "--initdb", "--repo", repo, "--keys-dir", c.o.keys_dir, "--yes", "add")
	append(&argv, ..c.p.packages)
	if !c.p.no_firmware {
		fw := firmware_for_repo(c.p.repo, context.temp_allocator)
		outer: for f in fw {
			for have in c.p.packages {
				if have == f {continue outer}
			}
			append(&argv, f)
		}
		if len(fw) == 0 {
			logf(c, "firmware: %s has no firmware packages; none installed", c.p.repo)
		} else {
			logf(c, "firmware: %s", strings.join(fw, " ", context.temp_allocator))
		}
	}
	pkg_state = {}
	// palm prints its plan first ("  install   <name> <ver>", one per
	// package), then "installing <name> <ver>" as it goes: the first gives
	// the total, the second the progress.
	return run(c, argv[:], proc(c: ^Ctx, line: string) {
		if strings.has_prefix(line, "  install ") {
			pkg_state.total += 1
		} else if strings.has_prefix(line, "installing ") || strings.has_prefix(line, "reinstalling ") || strings.has_prefix(line, "upgrading ") {
			pkg_state.done += 1
			total := max(pkg_state.total, pkg_state.done)
			name := strings.fields(line, context.temp_allocator)
			if len(name) >= 2 {
				progress(c, f32(pkg_state.done) / f32(total), msg(.Installing_Package, name[1], fmt.tprint(pkg_state.done), fmt.tprint(total)))
			}
		}
	})
}

// ------------------------------------------------------------------ Unmount --

@(private)
step_unmount :: proc(c: ^Ctx) -> string {
	if c.o.dry_run {
		logf(c, "would sync and unmount %s and %s", c.t.esp, c.t.root)
		return ""
	}
	linux.sync()
	if c.o.disk_image {
		return ""
	}
	if c.mounted_esp || is_mountpoint(c.t.esp) {
		if e := umount(c, c.t.esp); e != "" {
			return e
		}
		c.mounted_esp = false
	}
	if c.mounted_root || is_mountpoint(c.t.root) {
		if e := umount(c, c.t.root); e != "" {
			return e
		}
		c.mounted_root = false
	}
	linux.sync()
	return ""
}

human_size :: proc(b: u64) -> string {
	switch {
	case b >= 1 << 40: return fmt.tprintf("%.1f TiB", f64(b) / f64(u64(1) << 40))
	case b >= 1 << 30: return fmt.tprintf("%.1f GiB", f64(b) / f64(u64(1) << 30))
	case b >= 1 << 20: return fmt.tprintf("%.0f MiB", f64(b) / f64(u64(1) << 20))
	}
	return fmt.tprintf("%d bytes", b)
}
