package main

// The selftest's second half: reload decisions, fstab, superblock probing,
// zram, the GPT arithmetic of growroot, and early hooks. Like the first
// half (selftest.odin), it touches nothing on the machine but a scratch
// directory under /tmp.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

// --- reload ---------------------------------------------------------------------

@(private = "file")
svc :: proc(name, text: string) -> ^Service {
	s := new(Service, context.temp_allocator)
	parsed, err := parse_service(name, text, context.temp_allocator)
	assert(err == "", err)
	s^ = parsed
	return s
}

@(private = "file")
action_of :: proc(steps: []Reload_Step, name: string) -> (Reload_Action, bool) {
	for st in steps {
		if st.name == name {return st.action, true}
	}
	return .Keep, false
}

selftest_reload :: proc() {
	same := svc("same", "cmd = /bin/sleep 1000\nenv = A=1\n")
	changed := svc("changed", "cmd = /bin/sleep 1000\n")
	gone := svc("gone", "cmd = /bin/sleep 1000\n")
	nowmasked := svc("nowmasked", "cmd = /bin/sleep 1000\n")
	typo := svc("typo", "cmd = /bin/sleep 1000\n")
	network := new(Service, context.temp_allocator)
	network^ = Service {
		name    = "network",
		builtin = true,
		cmd     = {"udhcpc"},
	}
	current := []^Service{same, changed, gone, nowmasked, typo, network}

	files := []Service_File {
		{name = "same", def = svc("same", "# a comment now\ncmd   =   /bin/sleep   1000\nenv = A=1\n")},
		{name = "changed", def = svc("changed", "cmd = /bin/sleep 2000\n")},
		{name = "nowmasked", masked = true},
		{name = "typo", err = "line 1: unknown key \"cmdd\""},
		{name = "fresh", def = svc("fresh", "cmd = /bin/true\nrestart = never\n")},
		{name = "freshbroken", err = "no cmd"},
		{name = "freshmasked", masked = true},
	}
	steps := plan_reload(current, files)
	a, ok := action_of(steps, "same")
	check("reload: same definition (comments, spacing) is kept", ok && a == .Keep, fmt.tprint(a))
	a, ok = action_of(steps, "changed")
	check("reload: a changed cmd is a change (restart)", ok && a == .Change, fmt.tprint(a))
	a, ok = action_of(steps, "gone")
	check("reload: a removed file stops the service", ok && a == .Stop, fmt.tprint(a))
	a, ok = action_of(steps, "nowmasked")
	check("reload: a newly masked service is stopped", ok && a == .Stop, fmt.tprint(a))
	a, ok = action_of(steps, "typo")
	check("reload: a file with an error keeps what runs", ok && a == .Broken, fmt.tprint(a))
	a, ok = action_of(steps, "network")
	check("reload: the built-in network stays without a file", ok && a == .Keep, fmt.tprint(a))
	a, ok = action_of(steps, "fresh")
	check("reload: a new file is started", ok && a == .Start, fmt.tprint(a))
	a, ok = action_of(steps, "freshbroken")
	check("reload: a new file with an error is not started", ok && a == .Broken, fmt.tprint(a))
	_, ok = action_of(steps, "freshmasked")
	check("reload: a new masked file is ignored", !ok)
	check("reload: one step per name", len(steps) == 8, fmt.tprint(len(steps)))

	steps = plan_reload({network}, {{name = "network", def = svc("network", "cmd = /sbin/udhcpc -i eth1\nrestart = never\n")}})
	a, ok = action_of(steps, "network")
	check("reload: a network file replaces the built-in", ok && a == .Change, fmt.tprint(a))

	b := svc("x", "cmd = /bin/x\nenv = A=1\nenv = B=2\n")
	c := svc("x", "cmd = /bin/x\nenv = B=2\nenv = A=1\n")
	check("reload: env order is part of the definition", !same_definition(b, c))
	c = svc("x", "cmd = /bin/x\nenv = A=1\nenv = B=2\nuser = palm\n")
	check("reload: user is part of the definition", !same_definition(b, c))
	c = svc("x", "cmd = /bin/x\nenv = A=1\nenv = B=2\nafter = network\n")
	check("reload: after is part of the definition", !same_definition(b, c))
}

// --- fstab ---------------------------------------------------------------------------

selftest_fstab :: proc() {
	entries := parse_fstab(`# <device>  <mountpoint>  <type>  <options>  <dump>  <pass>
LABEL=palmframe	/	ext4	rw,relatime	0 1
PARTUUID=0a1b2c3d-0000-4000-8000-00000000abcd  /boot/efi  vfat  rw,relatime,fmask=0077,dmask=0077,errors=remount-ro  0 2
/swapfile none swap sw,pri=10,discard 0 0
/dev/sdb1 /mnt/My\040Disk ext4
broken line
tmpfs /tmp tmpfs size=50%,mode=1777 0 0
`, context.temp_allocator)
	check("fstab: well-formed lines only", len(entries) == 5, fmt.tprint(len(entries)))
	if len(entries) == 5 {
		check("fstab: root line", entries[0].spec == "LABEL=palmframe" && entries[0].dir == "/" && entries[0].type == "ext4" && entries[0].pass == 1)
		check("fstab: ESP line, pass 2", entries[1].dir == "/boot/efi" && entries[1].type == "vfat" && entries[1].pass == 2)
		check("fstab: \\040 is a space", entries[3].dir == "/mnt/My Disk", entries[3].dir)
		check("fstab: missing options, dump, pass default", entries[3].options == "defaults" && entries[3].pass == 0)
	}
	o := parse_mount_options("rw,relatime,fmask=0077,dmask=0077,errors=remount-ro,nofail,x-systemd.device-timeout=5", context.temp_allocator)
	check("options: flags vs data", o.flags == {.RELATIME} && o.data == "fmask=0077,dmask=0077,errors=remount-ro", fmt.tprint(o.flags, o.data))
	check("options: nofail and x-* are fstab's own", o.nofail && !o.noauto)
	o = parse_mount_options("ro,nosuid,nodev,noexec,noatime,noauto", context.temp_allocator)
	check("options: ro nosuid nodev noexec noatime", o.flags == {.RDONLY, .NOSUID, .NODEV, .NOEXEC, .NOATIME} && o.data == "" && o.noauto, fmt.tprint(o.flags))
	o = parse_mount_options("defaults", context.temp_allocator)
	check("options: defaults is nothing", o.flags == {} && o.data == "" && o.swap_pri == -1)
	o = parse_mount_options("sw,pri=10,discard", context.temp_allocator)
	check("options: swap priority and discard", o.swap_pri == 10 && o.swap_discard, fmt.tprint(o.swap_pri))
	o = parse_mount_options("ro,rw", context.temp_allocator)
	check("options: the later of ro/rw wins", .RDONLY not_in o.flags)
	check("fstab: tmpfs needs no device, vfat does", !needs_device("tmpfs") && needs_device("vfat") && needs_device("ext4"))
}

// --- probe ------------------------------------------------------------------------------

selftest_probe :: proc() {
	buf: [PROBE_BYTES]u8
	// ext4: magic, UUID, label.
	buf[1024 + 0x38], buf[1024 + 0x39] = 0x53, 0xEF
	uuid := [16]u8{0x2f, 0x1e, 0x0a, 0x4b, 0x11, 0x22, 0x43, 0x44, 0x95, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc}
	copy(buf[1024 + 0x68:], uuid[:])
	copy(buf[1024 + 0x78:], "palmframe")
	p := probe_buffer(buf[:], context.temp_allocator)
	check("probe: ext4 type, UUID, label", p.type == "ext4" && p.uuid == "2f1e0a4b-1122-4344-9566-778899aabbcc" && p.label == "palmframe", fmt.tprint(p))

	// FAT32 as mformat -F writes it.
	buf = {}
	copy(buf[0x52:], "FAT32   ")
	buf[0x43], buf[0x44], buf[0x45], buf[0x46] = 0x78, 0x56, 0x34, 0x12
	copy(buf[0x47:], "PALMESP    ")
	buf[510], buf[511] = 0x55, 0xAA
	p = probe_buffer(buf[:], context.temp_allocator)
	check("probe: FAT32 serial as XXXX-XXXX, label trimmed", p.type == "vfat" && p.uuid == "1234-5678" && p.label == "PALMESP", fmt.tprint(p))

	buf = {}
	copy(buf[0x36:], "FAT16   ")
	buf[0x27], buf[0x28], buf[0x29], buf[0x2A] = 0xEF, 0xBE, 0xAD, 0xDE
	copy(buf[0x2B:], "NO NAME    ")
	buf[510], buf[511] = 0x55, 0xAA
	p = probe_buffer(buf[:], context.temp_allocator)
	check("probe: FAT16, NO NAME is no label", p.type == "vfat" && p.uuid == "DEAD-BEEF" && p.label == "", fmt.tprint(p))

	h := swap_header(64 << 20, uuid[:], "zram0")
	p = probe_buffer(h[:], context.temp_allocator)
	check("probe: our swap header reads back", p.type == "swap" && p.uuid == "2f1e0a4b-1122-4344-9566-778899aabbcc" && p.label == "zram0", fmt.tprint(p))
	last := u32(h[1028]) | u32(h[1029]) << 8 | u32(h[1030]) << 16 | u32(h[1031]) << 24
	check("swap header: version 1, last page", h[1024] == 1 && last == (64 << 20) / 4096 - 1, fmt.tprint(last))

	buf = {}
	check("probe: zeros are nothing", probe_buffer(buf[:], context.temp_allocator).type == "")

	t, ok := parse_tag(`LABEL="My Disk"`)
	check("tag: quotes stripped", ok && t.key == "LABEL" && t.value == "My Disk", fmt.tprint(t))
	_, ok = parse_tag("/dev/vda2")
	check("tag: a path is not a tag", !ok)
	ue := "MAJOR=253\nMINOR=2\nDEVNAME=vda2\nDEVTYPE=partition\nDISKSEQ=1\nPARTN=2\nPARTNAME=palmframe\nPARTUUID=0A1B2C3D-0000-4000-8000-00000000ABCD\n"
	check("tag: PARTUUID ignores case", tag_matches({"PARTUUID", "0a1b2c3d-0000-4000-8000-00000000abcd"}, ue, {}))
	check("tag: PARTLABEL is the GPT name", tag_matches({"PARTLABEL", "palmframe"}, ue, {}) && !tag_matches({"PARTLABEL", "Palmframe"}, ue, {}))
	check("tag: UUID from the probe, case-blind", tag_matches({"UUID", "dead-beef"}, ue, {type = "vfat", uuid = "DEAD-BEEF"}))
	check("tag: LABEL is exact", tag_matches({"LABEL", "PALMESP"}, ue, {label = "PALMESP"}) && !tag_matches({"LABEL", "palmesp"}, ue, {label = "PALMESP"}))
}

// --- zram ----------------------------------------------------------------------------------

selftest_zram :: proc() {
	c, err := parse_zram_conf("# zram\nsize = 50%\nmax = 4G\nalgorithm = zstd\npriority = 100\n")
	check("zram: parses", err == "" && c.percent == 50 && c.max_bytes == 4 << 30 && c.algorithm == "zstd" && c.priority == 100, err)
	check("zram: 50% of 2 GiB", zram_size(c, 2 << 30) == 1 << 30)
	check("zram: capped at max", zram_size(c, 16 << 30) == 4 << 30)
	c, err = parse_zram_conf("size = 512M\n")
	check("zram: an amount, max ignored", err == "" && zram_size(c, 64 << 30) == 512 << 20, err)
	c, err = parse_zram_conf("size = 0\n")
	check("zram: size 0 is off", err == "" && zram_size(c, 2 << 30) == 0)
	_, err = parse_zram_conf("sise = 1G\n")
	check("zram: unknown key is an error", strings.contains(err, "unknown key"), err)
	_, err = parse_zram_conf("priority = 40000\n")
	check("zram: priority range", strings.contains(err, "priority"), err)
	v, ok := parse_size("64K")
	check("size: 64K", ok && v == 65536)
}

// --- GPT ------------------------------------------------------------------------------------

@(private = "file")
p32 :: proc(b: []u8, off: int, v: u32) {b[off], b[off + 1], b[off + 2], b[off + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
@(private = "file")
p64 :: proc(b: []u8, off: int, v: u64) {p32(b, off, u32(v));p32(b, off + 4, u32(v >> 32))}
@(private = "file")
g32 :: proc(b: []u8, off: int) -> u32 {return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24}
@(private = "file")
g64 :: proc(b: []u8, off: int) -> u64 {return u64(g32(b, off)) | u64(g32(b, off + 4)) << 32}

@(private = "file")
gpt_entry :: proc(entries: []u8, i: int, first, last: u64) {
	e := entries[i * 128:]
	e[0] = 0xAF // any non-zero type GUID
	e[16] = u8(i + 1)
	p64(e, 32, first)
	p64(e, 40, last)
}

selftest_gpt :: proc() {
	check("crc32: the check value of \"123456789\"", crc32(transmute([]u8)string("123456789")) == 0xCBF43926)

	// A disk of 4096 blocks of 512 bytes laid out the way the image builder
	// does it, before it is enlarged to 8192 blocks: BIOS boot (entry 3)
	// physically first, the ESP, then the root, last.
	lbs: u64 = 512
	header := make([]u8, lbs, context.temp_allocator)
	entries := make([]u8, 128 * 128, context.temp_allocator)
	root_first := u64(4062 - 1023)
	gpt_entry(entries, 0, 2048, root_first - 1) // ESP
	gpt_entry(entries, 1, root_first, 4062) // root, to the last usable LBA
	gpt_entry(entries, 2, 34, 2047) // BIOS boot
	copy(header, "EFI PART")
	p32(header, 8, 0x00010000)
	p32(header, 12, 92)
	p64(header, 24, 1)
	p64(header, 32, 4095)
	p64(header, 40, 34)
	p64(header, 48, 4062)
	p64(header, 72, 2)
	p32(header, 80, 128)
	p32(header, 84, 128)
	p32(header, 88, crc32(entries))
	p32(header, 16, crc32(header[:92]))

	g, err := gpt_parse(header, entries, lbs)
	check("gpt: a well-formed table parses", err == "", err)
	plan, why, ok := gpt_plan_grow(g, root_first, 4096)
	check("gpt: same size, nothing to grow", ok && plan.new_last == plan.last, fmt.tprint(plan, why))
	plan, why, ok = gpt_plan_grow(g, root_first, 8192)
	// 8192 blocks: backup header 8191, entries 8159..8190, last usable
	// 8158; the last whole MiB (2048 blocks) ends at 6143.
	check("gpt: the root grows to the last whole MiB", ok && plan.index == 1 && plan.new_last == 6143, fmt.tprint(plan, why))
	check("gpt: the backup goes to the disk's end", plan.backup_lba == 8191 && plan.backup_entries_lba == 8159 && plan.last_usable == 8158, fmt.tprint(plan))
	_, why, ok = gpt_plan_grow(g, 2048, 8192)
	check("gpt: the ESP is not last, so it does not grow", !ok && strings.contains(why, "not the last"), why)
	_, why, ok = gpt_plan_grow(g, 999, 8192)
	check("gpt: an unknown start is refused", !ok, why)

	primary, backup := gpt_apply(g, plan)
	g2, err2 := gpt_parse(primary, g.entries, lbs)
	check("gpt: the rewritten primary checks out", err2 == "", err2)
	check("gpt: primary points at the new backup", g64(primary, 32) == 8191 && g64(primary, 48) == plan.last_usable)
	_, err3 := gpt_parse(backup, g.entries, lbs)
	check("gpt: the backup header checks out", err3 == "" && g64(backup, 24) == 8191 && g64(backup, 32) == 1 && g64(backup, 72) == plan.backup_entries_lba, err3)
	check("gpt: the root entry ends where planned", g2.count == 128 && g64(g2.entries[128:], 40) == plan.new_last)

	bad := make([]u8, lbs, context.temp_allocator)
	copy(bad, primary)
	bad[60] ~= 1
	_, err = gpt_parse(bad, g.entries, lbs)
	check("gpt: a corrupt header is refused", strings.contains(err, "checksum"), err)
}

// --- hooks --------------------------------------------------------------------------------------

selftest_hooks :: proc() {
	base :: "/tmp/palm-init-selftest-hooks"
	usr :: base + "/usr"
	etc :: base + "/etc"
	mkdir_p(usr)
	mkdir_p(etc)
	files := [][3]string {
		{usr, "10-modules", "x"},
		{usr, "20-masked", "x"},
		{usr, "30-replaced", "x"},
		{usr, "40-plain", "-"}, // not executable: not a hook
		{etc, "20-masked", "-"}, // a non-executable file in /etc masks
		{etc, "30-replaced", "x"},
		{etc, "05-local", "x"},
		{etc, ".hidden", "x"},
		{etc, "50-backup~", "x"},
	}
	for f in files {
		path := strings.concatenate({f[0], "/", f[1]}, context.temp_allocator)
		mode: u32 = f[2] == "x" ? 0o755 : 0o644
		write_file(path, "#!/bin/sh\n", mode)
		linux.chmod(strings.clone_to_cstring(path, context.temp_allocator), transmute(linux.Mode)mode)
	}
	hooks := list_hooks({usr, etc}, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for h in hooks {append(&names, h.name)}
	check("hooks: merged, masked, sorted", fmt.tprint(names[:]) == `["05-local", "10-modules", "30-replaced"]`, fmt.tprint(names[:]))
	replaced := ""
	for h in hooks {if h.name == "30-replaced" {replaced = h.path}}
	check("hooks: /etc replaces /usr/lib by name", replaced == etc + "/30-replaced", replaced)
	for f in files {
		linux.unlink(strings.clone_to_cstring(strings.concatenate({f[0], "/", f[1]}, context.temp_allocator), context.temp_allocator))
	}
	linux.rmdir(strings.clone_to_cstring(usr, context.temp_allocator))
	linux.rmdir(strings.clone_to_cstring(etc, context.temp_allocator))
	linux.rmdir(strings.clone_to_cstring(base, context.temp_allocator))
	check("hooks: no directories, no hooks", len(list_hooks({usr, etc}, context.temp_allocator)) == 0)
}
