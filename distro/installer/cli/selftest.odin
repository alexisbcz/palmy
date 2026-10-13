package palm_install

// `palm-install --selftest` — runs on the build host as an ordinary user and
// touches nothing outside a scratch directory it removes afterwards. It never
// opens a block device, never mounts, and never reads or writes the host's
// firmware variables: disks are image files and efivarfs is a directory.
//
// From the bottom up:
//
//   * CRC32 against the published check values, and against core:hash;
//   * GUIDs: the mixed-endian text <-> disk conversion on the ESP type GUID,
//     and the version/variant bits of random ones;
//   * the GPT writer, judged by someone else: tables written into sparse
//     image files are read by `sfdisk --dump` and `sfdisk --verify`, which
//     must report our exact starts, sizes, types and GUIDs and no problems;
//     then our reader on the same files, and on deliberately corrupted ones;
//   * SHA-512 crypt against Drepper's vectors (the copy in install_core);
//   * base.lst and zone1970.tab parsing on the host's real files;
//   * list_languages and list_disks against scratch trees shaped like
//     /usr/share and /sys/block;
//   * the EFI_LOAD_OPTION encoding against a byte string derived by hand
//     from the UEFI specification, not produced by the code under test;
//   * validate's rules;
//   * then install itself, through install_with: partition and format an
//     image file (mtools reads the FAT back), configure and install the boot
//     loader into a scratch root with a fake efivarfs, twice, checking every
//     file it writes; and, when distro/out has palm and the repository, the
//     whole installation with the real packages into a directory;
//   * and the command line: refusals, exit codes, --dry-run.

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import core "install:core"

@(private = "file")
checks := 0
@(private = "file")
failures := 0
@(private = "file")
scratch_dir := ""

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq :: proc(got, want: $T, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %v, want %v\n", fmt.tprintf(what, ..args), got, want)
	}
}

@(private = "file")
scratch :: proc(name: string) -> string {
	p := core.join(scratch_dir, name)
	_ = os.remove_all(p)
	_ = os.make_directory_all(p)
	return p
}

@(private = "file")
exec :: proc(cmd: ..string) -> (int, string) {
	state, out, errb, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil {
		return -1, fmt.tprintf("%v", err)
	}
	return state.exit_code, strings.concatenate({string(out), string(errb)})
}

@(private = "file")
put_s :: proc(path: string, data: string) {
	check(os.write_entire_file(path, data) == nil, "write %s", path)
}
@(private = "file")
put_b :: proc(path: string, data: []u8) {
	check(os.write_entire_file(path, data) == nil, "write %s", path)
}
@(private = "file")
put :: proc{put_s, put_b}

@(private = "file")
slurp :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return ""}
	return string(data)
}

@(private = "file")
make_image :: proc(path: string, size: i64) -> bool {
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.RDWR, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err != .NONE {return false}
	defer linux.close(fd)
	return linux.ftruncate(fd, size) == .NONE
}

selftest :: proc() -> int {
	t0 := time.now()
	fmt.println("palm-install self-test")
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {base = "/tmp"}
	scratch_dir = fmt.aprintf("%s/palm-install-selftest-%d", base, os.get_pid())
	_ = os.make_directory_all(scratch_dir)

	test_crc32()
	test_guid()
	test_gpt()
	test_crypt()
	test_layouts()
	test_zones()
	test_languages()
	test_disks()
	test_efi_load_option()
	test_validate()
	test_install_image()
	test_full_install()
	test_cli()

	_ = os.remove_all(scratch_dir)
	fmt.printf("%d checks, %d failures (%.1f s)\n", checks, failures, time.duration_seconds(time.since(t0)))
	return failures == 0 ? 0 : 1
}

// ------------------------------------------------------------------- CRC32 --

@(private = "file")
test_crc32 :: proc() {
	eq(core.crc32(nil), 0, "crc32 of nothing")
	eq(core.crc32(transmute([]u8)string("123456789")), 0xCBF43926, "crc32 check value")
	eq(core.crc32(transmute([]u8)string("The quick brown fox jumps over the lazy dog")), 0x414FA339, "crc32 of the fox")
	buf := make([]u8, 70000)
	x := u32(12345)
	for &b in buf {
		x = x * 1103515245 + 12345
		b = u8(x >> 16)
	}
	eq(core.crc32(buf), hash.crc32(buf), "crc32 agrees with core:hash on 70000 bytes")
}

// ------------------------------------------------------------------- GUIDs --

@(private = "file")
test_guid :: proc() {
	g, ok := core.guid_parse(core.ESP_TYPE)
	check(ok, "the ESP type GUID parses")
	want := [16]u8{0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B}
	eq(g, want, "the ESP type GUID's on-disk bytes")
	eq(core.guid_string(g), core.ESP_TYPE, "and back to text")
	_, bad := core.guid_parse("C12A7328-F81F-11D2-BA4B-00A0C93EC93")
	check(!bad, "a short GUID is refused")
	_, bad = core.guid_parse("C12A7328-F81F-11D2-BA4B-00A0C93EC9ZZ")
	check(!bad, "a non-hex GUID is refused")
	a := core.guid_random()
	b := core.guid_random()
	check(a != b, "two random GUIDs differ")
	s := core.guid_string(a)
	eq(s[14], '4', "random GUID is version 4 (%s)", s)
	check(strings.index_byte("89AB", s[19]) >= 0, "random GUID has the RFC 4122 variant (%s)", s)
}

// --------------------------------------------------------------------- GPT --

@(private = "file")
Sfdisk_Part :: struct {
	start, size: u64,
	type, uuid:  string,
}

// sfdisk_dump runs `sfdisk --dump` and pulls out the header and partitions.
@(private = "file")
sfdisk_dump :: proc(img: string) -> (label_id: string, first, last: u64, parts: [dynamic]Sfdisk_Part, ok: bool) {
	code, out := exec("sfdisk", "--dump", img)
	if code != 0 {
		fmt.printf("  sfdisk --dump: %s\n", out)
		return
	}
	for line in strings.split_lines(out) {
		if strings.has_prefix(line, "label-id:") {
			label_id = strings.trim_space(line[len("label-id:"):])
		} else if strings.has_prefix(line, "first-lba:") {
			first = u64(parse_int(strings.trim_space(line[len("first-lba:"):])))
		} else if strings.has_prefix(line, "last-lba:") {
			last = u64(parse_int(strings.trim_space(line[len("last-lba:"):])))
		} else if colon := strings.index(line, " : "); colon >= 0 {
			p: Sfdisk_Part
			for f in strings.split(line[colon + 3:], ",") {
				kv := strings.split_n(strings.trim_space(f), "=", 2)
				if len(kv) != 2 {continue}
				v := strings.trim_space(kv[1])
				switch strings.trim_space(kv[0]) {
				case "start": p.start = u64(parse_int(v))
				case "size": p.size = u64(parse_int(v))
				case "type": p.type = v
				case "uuid": p.uuid = v
				}
			}
			append(&parts, p)
		}
	}
	return label_id, first, last, parts, true
}

@(private = "file")
parse_int :: proc(s: string) -> int {
	n := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {break}
		n = n * 10 + int(c - '0')
	}
	return n
}

@(private = "file")
test_gpt :: proc() {
	dir := scratch("gpt")
	sizes := [?]i64{8 * 1024 * 1024 * 1024, 4 * 1024 * 1024 * 1024 + 12345 * 512}
	for size in sizes {
		img := core.join(dir, fmt.tprintf("disk-%d.img", size))
		check(make_image(img, size), "made a %d-byte image", size)
		g, ok := core.gpt_layout_palmframe(u64(size), 512)
		check(ok, "layout for %d bytes", size)
		if !ok {continue}

		fd, _ := linux.open(strings.clone_to_cstring(img, context.temp_allocator), {.RDWR, .CLOEXEC})
		eq(core.gpt_write(fd, g), "", "gpt_write %d", size)
		back, rerr := core.gpt_read(fd, u64(size), 512)
		linux.close(fd)
		eq(rerr, "", "gpt_read reads our table back")
		eq(back.disk_guid, g.disk_guid, "disk GUID round trip")
		eq(len(back.parts), 2, "two partitions read back")
		if len(back.parts) == 2 {
			eq(back.parts[0].name, "EFI system partition", "partition 1 name round trip")
			eq(back.parts[1].part_guid, g.parts[1].part_guid, "root GUID round trip")
		}

		// The independent judge.
		code, verify := exec("sfdisk", "--verify", img)
		eq(code, 0, "sfdisk --verify exit (%s)", strings.trim_space(verify))
		check(strings.contains(verify, "No errors detected"), "sfdisk --verify: no errors (%s)", strings.trim_space(verify))
		label, first, last, parts, dok := sfdisk_dump(img)
		check(dok, "sfdisk --dump ran")
		total := u64(size) / 512
		eq(label, core.guid_string(g.disk_guid), "sfdisk sees our disk GUID")
		eq(first, 34, "first usable LBA")
		eq(last, total - 34, "last usable LBA")
		eq(len(parts), 2, "sfdisk sees two partitions")
		if len(parts) == 2 && len(g.parts) == 2 {
			eq(parts[0].start, 2048, "ESP starts at 1 MiB")
			eq(parts[0].size, 512 * 2048, "ESP is 512 MiB")
			eq(parts[0].type, core.ESP_TYPE, "ESP type")
			eq(parts[0].uuid, core.guid_string(g.parts[0].part_guid), "ESP PARTUUID")
			eq(parts[1].start, 2048 + 512 * 2048, "root starts right after the ESP")
			eq(parts[1].start % 2048, 0, "root start aligned to 1 MiB")
			eq(parts[1].size % 2048, 0, "root size whole MiB")
			check(parts[1].start + parts[1].size - 1 <= total - 34, "root ends before the backup table")
			check(parts[1].start + parts[1].size - 1 > total - 34 - 2048, "root uses the disk up to the last MiB")
			eq(parts[1].type, core.LINUX_FS_TYPE, "root type")
			eq(parts[1].uuid, core.guid_string(g.parts[1].part_guid), "root PARTUUID")
		}
	}

	// A table must not survive corruption silently.
	img := core.join(dir, "corrupt.img")
	size := i64(4 * 1024 * 1024 * 1024)
	make_image(img, size)
	g, _ := core.gpt_layout_palmframe(u64(size), 512)
	fd, _ := linux.open(strings.clone_to_cstring(img, context.temp_allocator), {.RDWR, .CLOEXEC})
	defer linux.close(fd)
	core.gpt_write(fd, g)
	poke :: proc(fd: linux.Fd, off: i64) {
		b: [1]u8
		linux.pread(fd, b[:], off)
		b[0] ~= 0x01
		linux.pwrite(fd, b[:], off)
	}
	poke(fd, 512 + 40) // primary header: first usable LBA
	_, e1 := core.gpt_read(fd, u64(size), 512)
	check(strings.contains(e1, "header CRC"), "a changed header byte is caught (%s)", e1)
	poke(fd, 512 + 40)
	poke(fd, 2 * 512 + 32) // primary entry 1: first LBA
	_, e2 := core.gpt_read(fd, u64(size), 512)
	check(strings.contains(e2, "entry array CRC"), "a changed entry byte is caught (%s)", e2)
	poke(fd, 2 * 512 + 32)
	poke(fd, size - 512 + 60) // backup header: disk GUID
	_, e3 := core.gpt_read(fd, u64(size), 512)
	check(strings.contains(e3, "backup"), "a broken backup header is caught (%s)", e3)
	poke(fd, size - 512 + 60)
	_, e4 := core.gpt_read(fd, u64(size), 512)
	eq(e4, "", "and the repaired table reads again")

	// 4 KiB sectors: same layout in bytes, fewer entry sectors.
	g4, ok4 := core.gpt_layout_palmframe(u64(size), 4096)
	check(ok4, "layout with 4096-byte sectors")
	eq(g4.first_usable, 6, "4K: first usable LBA (MBR, header, 4 entry sectors)")
	eq(g4.parts[0].first_lba * 4096, 1024 * 1024, "4K: ESP at 1 MiB")
	img4 := core.join(dir, "disk-4k.img")
	make_image(img4, size)
	fd4, _ := linux.open(strings.clone_to_cstring(img4, context.temp_allocator), {.RDWR, .CLOEXEC})
	core.gpt_write(fd4, g4)
	b4, e5 := core.gpt_read(fd4, u64(size), 4096)
	linux.close(fd4)
	eq(e5, "", "4K table reads back")
	eq(b4.parts[1].part_guid, g4.parts[1].part_guid, "4K root GUID round trip")

	eq(core.partition_path("/dev/vda", 2), "/dev/vda2", "partition node of vda")
	eq(core.partition_path("/dev/nvme0n1", 1), "/dev/nvme0n1p1", "partition node of nvme0n1")
	eq(core.partition_path("/dev/mmcblk0", 2), "/dev/mmcblk0p2", "partition node of mmcblk0")
	_, small := core.gpt_layout_palmframe(300 * 1024 * 1024, 512)
	check(!small, "no layout on a 300 MiB disk")
}

// ------------------------------------------------------------------- crypt --

@(private = "file")
test_crypt :: proc() {
	vectors := [?][3]string {
		{"$6$saltstring", "Hello world!", "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"},
		{"$6$rounds=10000$saltstringsaltstring", "Hello world!", "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."},
		{"$6$rounds=5000$toolongsaltstring", "This is just a test", "$6$rounds=5000$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0"},
		{"$6$rounds=1400$anotherlongsaltstring", "a very much longer text to encrypt.  This one even stretches over morethan one line.", "$6$rounds=1400$anotherlongsalts$POfYwTEok97VWcjxIiSOjiykti.o/pQs.wPvMxQ6Fm7I6IoYN3CmLs66x9t0oSwbtEW7o7UmJEiDwGqd8p4ur1"},
		{"$6$rounds=77777$short", "we have a short salt string but not a short password", "$6$rounds=77777$short$WuQyW2YR.hBNpjjRhpYD/ifIw05xdfeEyQoMxIXbkvr0gge1a1x3yRULJ5CCaUeOxFmtlcGZelFl5CxtgfiAc0"},
		{"$6$rounds=10$roundstoolow", "the minimum number is still observed", "$6$rounds=1000$roundstoolow$kUMsbe306n21p9R.FRkW3IGn.S9NPN0x50YhH1xhLsPuWGsUSklZt58jaTfF4ZEQpyUNGc0dqbpBYYBaHHrsX."},
	}
	for v in vectors {
		got, ok := core.sha512_crypt(v[1], v[0])
		check(ok && got == v[2], "crypt vector %s (got %s)", v[0], got)
	}
	// The base system's shadow holds root/palm hashed with "palm"; the copy
	// must verify what palm-login verifies.
	shadow := slurp("distro/base/root/etc/shadow")
	if shadow != "" {
		for line in strings.split_lines(shadow) {
			f := strings.split(line, ":")
			if len(f) > 2 && (f[0] == "root" || f[0] == "palm") {
				check(core.verify_password("palm", f[1]), "base shadow: %s's hash verifies", f[0])
			}
		}
	}
	h, ok := core.make_hash("correct horse")
	check(ok && strings.has_prefix(h, "$6$") && len(h) == 3 + 16 + 1 + 86, "make_hash makes a $6$ hash with a 16-char salt (%s)", h)
	check(core.verify_password("correct horse", h), "and it verifies")
	h2, _ := core.make_hash("correct horse")
	check(h != h2, "two hashes of one password differ (random salt)")
}

// ---------------------------------------------------------------- catalogs --

@(private = "file")
test_layouts :: proc() {
	if !os.exists("/usr/share/X11/xkb/rules/base.lst") {
		fmt.println("  skip  layouts: no /usr/share/X11/xkb on this host")
		return
	}
	ls := core.list_layouts()
	check(len(ls) > 500, "base.lst: %d layouts and variants", len(ls))
	found_fr, found_us, found_de_nodead := false, false, false
	idx_fr, idx_fr_variant := -1, -1
	for k, i in ls {
		if k.layout == "fr" && k.variant == "" {
			found_fr = true
			idx_fr = i
			eq(k.description, "French", "fr's description")
		}
		if k.layout == "fr" && k.variant != "" && idx_fr_variant < 0 {idx_fr_variant = i}
		if k.layout == "us" && k.variant == "" {
			found_us = true
			eq(k.description, "English (US)", "us's description")
		}
		if k.layout == "de" && k.variant == "nodeadkeys" {
			found_de_nodead = true
			eq(k.description, "German (no dead keys)", "de:nodeadkeys's description")
		}
		check(k.layout != "" && !strings.contains(k.layout, " "), "a layout code has no spaces (%q)", k.layout)
	}
	check(found_fr && found_us && found_de_nodead, "fr, us and de:nodeadkeys are listed")
	check(idx_fr >= 0 && idx_fr_variant == idx_fr + 1, "fr's variants follow fr")
	// No models or options leak in.
	for k in ls {
		if k.layout == "pc105" || strings.has_prefix(k.layout, "grp:") {
			check(false, "a model or option was taken for a layout: %s", k.layout)
			break
		}
	}
}

@(private = "file")
test_zones :: proc() {
	if !os.exists("/usr/share/zoneinfo/zone1970.tab") {
		fmt.println("  skip  zones: no zone1970.tab on this host")
		return
	}
	zs := core.list_zones()
	check(len(zs) > 300, "zone1970.tab: %d zones", len(zs))
	seen := 0
	for z, i in zs {
		if i > 0 {check(zs[i - 1].name < z.name, "zones sorted (%s, %s)", zs[i - 1].name, z.name)}
		switch z.name {
		case "Europe/Paris":
			eq(z.region, "Europe", "Paris region")
			eq(z.city, "Paris", "Paris city")
			check(strings.contains(z.country, "France"), "Paris is in France (%s)", z.country)
			seen += 1
		case "America/Argentina/Buenos_Aires":
			eq(z.city, "Argentina/Buenos Aires", "Buenos Aires: underscores become spaces")
			seen += 1
		case "UTC":
			seen += 1
		}
		check(os.exists(core.join("/usr/share/zoneinfo", z.name)), "zone %s has a TZif file", z.name)
	}
	eq(seen, 3, "Paris, Buenos Aires and UTC listed")

	// The fallback: a tree with only zone.tab.
	dir := scratch("zones")
	put(core.join(dir, "zone.tab"), "# comment\nFR\t+4852+00220\tEurope/Paris\nJP\t+353916+1394441\tAsia/Tokyo\n")
	put(core.join(dir, "iso3166.tab"), "FR\tFrance\nJP\tJapan\n")
	z2 := core.list_zones(dir)
	eq(len(z2), 3, "zone.tab fallback: two zones and UTC")
	if len(z2) == 3 {
		eq(z2[0].name, "Asia/Tokyo", "zone.tab fallback: sorted")
		eq(z2[0].country, "Japan", "zone.tab fallback: country name")
	}
}

@(private = "file")
test_languages :: proc() {
	dir := scratch("share")
	loc := core.join(dir, "palm/locale")
	os.make_directory_all(core.join(loc, "fr"))
	os.make_directory_all(core.join(loc, "ja_JP"))
	os.make_directory_all(core.join(loc, "ar"))
	os.make_directory_all(core.join(loc, "pt_BR"))
	os.make_directory_all(core.join(dir, "fonts/TTF"))
	put(core.join(loc, "fr/installer.msg"), "msgid \"x\"\nmsgstr \"y\"\n")
	put(core.join(loc, "ja_JP/installer.msg"), "msgid \"x\"\nmsgstr \"y\"\n")
	put(core.join(loc, "ar/installer.msg"), "msgid \"x\"\nmsgstr \"y\"\n")
	put(core.join(loc, "pt_BR/installer.msg"), "msgid \"x\"\nmsgstr \"y\"\n")
	put(core.join(dir, "fonts/TTF/DejaVuSans.ttf"), "not really a font")

	find :: proc(ls: []core.Language, code: string) -> (core.Language, bool) {
		for l in ls {
			if l.code == code {return l, true}
		}
		return {}, false
	}
	ls := core.list_languages(loc)
	en, _ := find(ls, "en_US")
	fr, _ := find(ls, "fr_FR")
	de, _ := find(ls, "de_DE")
	ar, _ := find(ls, "ar")
	ja, _ := find(ls, "ja_JP")
	pt, has_pt := find(ls, "pt_BR")
	check(en.available, "English is always available")
	check(fr.available, "French is available through the fr/ catalogue (fr_FR -> fr)")
	eq(fr.native_name, "Français", "French's own name")
	check(!de.available, "German without a catalogue is not available")
	check(ar.available && ar.rtl, "Arabic is available and right to left")
	check(!ja.available, "Japanese without a CJK font is not available")
	check(has_pt && pt.available, "an unknown catalogue (pt_BR) is offered by its code")
	put(core.join(dir, "fonts/TTF/NotoSansCJK-Regular.ttc"), "not really a font")
	ja2, _ := find(core.list_languages(loc), "ja_JP")
	check(ja2.available, "Japanese with a CJK font is available")
}

@(private = "file")
test_disks :: proc() {
	sys := scratch("sys/block")
	mk :: proc(sys, rel, content: string) {
		p := core.join(sys, rel)
		os.make_directory_all(core.dir_of(p))
		put(p, content)
	}
	mk(sys, "vda/size", "16777216\n")
	mk(sys, "vda/removable", "0\n")
	mk(sys, "vda/ro", "0\n")
	mk(sys, "vda/vda1/partition", "1\n")
	mk(sys, "vdb/size", "4194304\n")
	mk(sys, "vdb/ro", "1\n")
	mk(sys, "nvme0n1/size", "1953525168\n")
	mk(sys, "nvme0n1/device/model", "Samsung SSD 980   \n")
	mk(sys, "sda/size", "60000000\n")
	mk(sys, "sda/removable", "1\n")
	mk(sys, "sda/device/vendor", "SanDisk \n")
	mk(sys, "sda/device/model", "Ultra\n")
	mk(sys, "loop0/size", "1000\n")
	mk(sys, "sr0/size", "1000\n")
	mk(sys, "zram0/size", "1000\n")
	mk(sys, "ram0/size", "1000\n")
	mk(sys, "mmcblk0/size", "0\n")
	ds := core.list_disks_in(sys, "/dev", false)
	eq(len(ds), 4, "loop, sr, zram, ram and an empty card reader are left out")
	if len(ds) == 4 {
		eq(ds[0].name, "nvme0n1", "sorted by name")
		eq(ds[0].model, "Samsung SSD 980", "nvme model, trimmed")
		eq(ds[0].size_bytes, u64(1953525168) * 512, "size in bytes")
		eq(ds[1].model, "SanDisk Ultra", "vendor and model")
		check(ds[1].removable, "sda is removable")
		eq(ds[2].path, "/dev/vda", "device path")
		eq(ds[2].model, "VirtIO disk", "virtio has a name")
		check(ds[2].has_partitions && !ds[2].readonly, "vda has partitions, is writable")
		check(ds[3].readonly, "vdb is read-only")
	}
}

// --------------------------------------------------------- EFI load option --

@(private = "file")
test_efi_load_option :: proc() {
	// UEFI 2.10 §3.1.3 EFI_LOAD_OPTION and §10.3.5.1/§10.3.5.4 device path
	// nodes, written out byte by byte by hand for: description "Palmframe",
	// GPT partition 1 at LBA 2048 of 1048576 sectors, partition GUID
	// 01234567-89AB-CDEF-0123-456789ABCDEF, file \EFI\palmframe\BOOTX64.EFI.
	want := strings.concatenate({
		"01000000", // Attributes: LOAD_OPTION_ACTIVE
		"6800", // FilePathListLength = 42 + 58 + 4 = 104
		"500061006c006d006600720061006d0065000000", // "Palmframe\0", UTF-16LE
		"04012a00", // HD(): type 4 (media), subtype 1 (hard drive), length 42
		"01000000", // partition number 1
		"0008000000000000", // partition start, LBA 2048
		"0000100000000000", // partition size, 1048576 sectors
		"67452301ab89efcd0123456789abcdef", // signature: the GUID as stored on disk
		"02", // partition format: GPT
		"02", // signature type: GUID
		"04043a00", // file path: type 4, subtype 4, length 4 + 27 * 2 = 58
		"5c00450046004900", // \EFI
		"5c00700061006c006d006600720061006d006500", // \palmframe
		"5c0042004f004f0054005800360034002e00450046004900", // \BOOTX64.EFI
		"0000", // the path's terminating NUL
		"7fff0400", // end of entire device path
	})
	g, _ := core.guid_parse("01234567-89AB-CDEF-0123-456789ABCDEF")
	got := core.efi_load_option("Palmframe", 1, 2048, 1048576, g, "\\EFI\\palmframe\\BOOTX64.EFI")
	sb := strings.builder_make()
	for b in got {fmt.sbprintf(&sb, "%02x", b)}
	eq(strings.to_string(sb), want, "EFI_LOAD_OPTION bytes")
	eq(len(got), 4 + 2 + 20 + 104, "EFI_LOAD_OPTION length")
	eq(core.load_option_description(got), "Palmframe", "description reads back")
}

// ---------------------------------------------------------------- validate --

@(private = "file")
test_validate :: proc() {
	disks := []core.Disk {
		{path = "/dev/vda", name = "vda", size_bytes = 8 << 30},
		{path = "/dev/vdb", name = "vdb", size_bytes = 8 << 30, is_live_medium = true},
		{path = "/dev/vdc", name = "vdc", size_bytes = 2 << 30},
		{path = "/dev/vdd", name = "vdd", size_bytes = 8 << 30, readonly = true},
	}
	good := core.default_plan()
	good.disk = "/dev/vda"
	good.user = "alex"
	good.password = "secret"
	good.language = "fr_FR"
	good.keyboard = {layout = "fr"}
	good.timezone = "Europe/Paris"
	good.hostname = "desk"
	ok, probs := core.validate_with(good, core.default_options(), disks)
	check(ok, "a good plan is valid (%v)", probs)

	bad :: proc(p: core.Plan, disks: []core.Disk, needle: string, what: string) {
		ok, probs := core.validate_with(p, core.default_options(), disks)
		hit := false
		for pr in probs {
			if strings.contains(pr, needle) {hit = true}
		}
		check(!ok && hit, "%s is refused (wanted %q in %v)", what, needle, probs)
	}
	p := good
	p.user = "Alex"; bad(p, disks, "user name", "an upper-case user name")
	p.user = "1alex"; bad(p, disks, "user name", "a user name starting with a digit")
	p.user = "root"; bad(p, disks, "used by the system", "root as the user")
	p.user = "wheel"; bad(p, disks, "used by the system", "a system group's name")
	p.user = ""; bad(p, disks, "empty", "an empty user name")
	p.user = "a234567890123456789012345678901234"; bad(p, disks, "32", "a 34-character user name")
	p = good
	for u in ([]string{"alex", "_svc", "a-b_c9", "palm"}) {
		p.user = u
		ok2, pr := core.validate_with(p, core.default_options(), disks)
		check(ok2, "user name %q is accepted (%v)", u, pr)
	}
	p = good
	p.hostname = "-desk"; bad(p, disks, "host name", "a host name starting with '-'")
	p.hostname = "desk_1"; bad(p, disks, "host name", "an underscore in a host name")
	p.hostname = "a..b"; bad(p, disks, "host name", "an empty host name label")
	p.hostname = ""; bad(p, disks, "host name", "an empty host name")
	p.hostname = "my-box.lan"
	ok3, _ := core.validate_with(p, core.default_options(), disks)
	check(ok3, "my-box.lan is a fine host name")
	p = good
	p.password = ""; bad(p, disks, "password", "an empty password")
	p = good
	p.full_name = "A:B"; bad(p, disks, "full name", "a ':' in the full name")
	p = good
	p.language = "french"; bad(p, disks, "language", "a language that is not a locale")
	p = good
	if os.exists("/usr/share/X11/xkb/rules/base.lst") {
		p.keyboard = {layout = "fr", variant = "nonexistent"}; bad(p, disks, "variant", "an unknown variant")
		p.keyboard = {layout = "zz"}; bad(p, disks, "layout", "an unknown layout")
		p.keyboard = {layout = "fr", variant = "azerty"}
		ok4, pr4 := core.validate_with(p, core.default_options(), disks)
		check(ok4, "fr:azerty is a layout (%v)", pr4)
	}
	p = good
	if os.is_dir("/usr/share/zoneinfo") {
		p.timezone = "Europe/Atlantis"; bad(p, disks, "time zone", "an unknown time zone")
	}
	p.timezone = "../../etc/passwd"; bad(p, disks, "time zone", "a time zone escaping zoneinfo")
	p = good
	p.disk = "/dev/vdb"; bad(p, disks, "running system", "the live medium")
	p.disk = "/dev/vdc"; bad(p, disks, "4 GiB", "a 2 GiB disk")
	p.disk = "/dev/vdd"; bad(p, disks, "read-only", "a read-only disk")
	p.disk = "/dev/vdz"; bad(p, disks, "no disk", "a disk that does not exist")
	p.disk = ""; bad(p, disks, "No disk", "no disk")
	p = good
	p.repo = "ftp://x"; bad(p, disks, "repository", "an ftp repository")
	p = good
	p.packages = {"palmframe", "Bad Name"}; bad(p, disks, "package", "a bad package name")

	// Disk images: plain files only, and big enough.
	o := core.default_options()
	o.disk_image = true
	dir := scratch("validate")
	small := core.join(dir, "small.img")
	make_image(small, 1 << 30)
	p = good
	p.disk = small
	ok5, pr5 := core.validate_with(p, o)
	check(!ok5 && len(pr5) == 1 && strings.contains(pr5[0], "4 GiB"), "a 1 GiB image is refused (%v)", pr5)
	p.disk = "/dev/null"
	ok6, pr6 := core.validate_with(p, o)
	check(!ok6 && strings.contains(pr6[0], "device"), "a /dev path is refused as a disk image (%v)", pr6)
}

// --------------------------------------------------- install, image + dir --

// fake_root lays out what palm would have installed that configure and the
// boot loader step read: the base system's /etc, the demo user's home, and a
// kernel.
@(private = "file")
fake_root :: proc(root: string) {
	os.make_directory_all(core.join(root, "etc/palm"))
	os.make_directory_all(core.join(root, "boot"))
	os.make_directory_all(core.join(root, "home/palm/.config"))
	os.make_directory_all(core.join(root, "home/palm/.local/share"))
	put(core.join(root, "home/palm/.profile"), "# hi\n")
	for f in ([]string{"passwd", "group", "shadow", "fstab", "hostname", "hosts"}) {
		src := core.join("distro/base/root/etc", f)
		data, err := os.read_entire_file_from_path(src, context.temp_allocator)
		check(err == nil, "read %s (run the selftest from the repository root)", src)
		put(core.join(root, "etc", f), data)
	}
	put(core.join(root, "etc/palm/repositories"), "http://10.0.2.2:8080/x86_64\n")
	put(core.join(root, "boot/vmlinuz"), "not really a kernel")
}

@(private = "file")
test_install_image :: proc() {
	dir := scratch("install")
	img := core.join(dir, "disk.img")
	size := i64(4 * 1024 * 1024 * 1024 + 256 * 1024 * 1024)
	check(make_image(img, size), "made the install image")
	root := core.join(dir, "root")
	efivars := core.join(dir, "efivars")
	os.make_directory_all(efivars)
	fake_root(root)

	// An existing firmware entry (Boot0000) and boot order, as OVMF has them.
	SUFFIX :: "-8be4df61-93ca-11d2-aa0d-00e098032b8c"
	shell_opt := core.efi_load_option("UEFI Shell", 1, 34, 100, {}, "\\shell.efi")
	b0 := make([]u8, 4 + len(shell_opt))
	core.put_u32(b0, 7)
	copy(b0[4:], shell_opt)
	put(core.join(efivars, "Boot0000" + SUFFIX), b0)
	put(core.join(efivars, "BootOrder" + SUFFIX), []u8{7, 0, 0, 0, 0, 0})

	p := core.default_plan()
	p.disk = img
	p.user = "alex"
	p.full_name = "Alex Example"
	p.password = "hunter2"
	p.root_password = "toor"
	p.language = "fr_FR"
	p.keyboard = {layout = "fr", variant = "azerty"}
	p.timezone = "Europe/Paris"
	p.hostname = "desk"
	p.repo = "http://example.org/palmframe/x86_64"
	p.efi_boot_entry = true

	o := core.default_options()
	o.disk_image = true
	o.target = root
	o.efivars = efivars
	o.log_path = core.join(dir, "install.log")
	o.steps = {.Partition, .Format}

	steps_seen: bit_set[core.Step]
	last_fraction: f32 = -1
	monotonic := true
	Rep :: struct {
		seen:     ^bit_set[core.Step],
		last:     ^f32,
		monotone: ^bool,
	}
	rep := Rep{&steps_seen, &last_fraction, &monotonic}
	report :: proc(pr: core.Progress, user: rawptr) {
		r := (^Rep)(user)
		r.seen^ += {pr.step}
		if pr.fraction < r.last^ {r.monotone^ = false}
		r.last^ = pr.fraction
	}

	ok, err := core.install_with(p, o, report, &rep)
	check(ok, "partition + format an image: %s", err)
	code, verify := exec("sfdisk", "--verify", img)
	check(code == 0 && strings.contains(verify, "No errors"), "sfdisk --verify after install: %s", verify)
	fd, _ := linux.open(strings.clone_to_cstring(img, context.temp_allocator), {.CLOEXEC})
	g, gerr := core.gpt_read(fd, u64(size), 512)
	eq(gerr, "", "the installed table reads back")
	// The file systems, at the partitions' offsets.
	if len(g.parts) == 2 {
		esp_off := i64(g.parts[0].first_lba * 512)
		root_off := i64(g.parts[1].first_lba * 512)
		fat: [8]u8
		linux.pread(fd, fat[:], esp_off + 82)
		eq(string(fat[:]), "FAT32   ", "a FAT32 boot sector at the ESP")
		label: [11]u8
		linux.pread(fd, label[:], esp_off + 71)
		eq(string(label[:]), "PALMEFI    ", "the ESP's label")
		magic: [2]u8
		linux.pread(fd, magic[:], root_off + 1024 + 56)
		eq(core.get_u16(magic[:]), 0xEF53, "an ext4 superblock at the root")
		vol: [16]u8
		linux.pread(fd, vol[:], root_off + 1024 + 120)
		eq(strings.trim_right(string(vol[:]), "\x00"), "palmroot", "the root's label")
		// mtools reads the FAT, as firmware will.
		mcode, mout := exec("mdir", "-i", fmt.tprintf("%s@@%d", img, esp_off), "::")
		check(mcode == 0 && strings.contains(mout, "PALMEFI"), "mdir reads the ESP (%s)", strings.trim_space(mout))
		// And e2fsck the root, carved out of the image (it takes no offset).
		if os.exists("/usr/bin/e2fsck") {
			part := core.join(dir, "root.ext4")
			exec("dd", fmt.tprintf("if=%s", img), fmt.tprintf("of=%s", part), "bs=1M", fmt.tprintf("skip=%d", root_off / (1 << 20)), fmt.tprintf("count=%d", (g.parts[1].last_lba - g.parts[1].first_lba + 1) * 512 / (1 << 20)), "conv=sparse", "status=none")
			ecode, eout := exec("e2fsck", "-fn", part)
			check(ecode == 0, "e2fsck -fn on the root: %s", strings.trim_space(eout))
			os.remove(part)
		}
	}
	linux.close(fd)

	// Configure and the boot loader into the scratch root, reading the
	// PARTUUIDs back from the image (load_parts, as a resumed run would).
	o.steps = {.Mount, .Configure, .Bootloader, .Unmount}
	last_fraction = -1 // a new run starts from its first step's share again
	ok, err = core.install_with(p, o, report, &rep)
	check(ok, "configure + bootloader into a directory: %s", err)
	check(monotonic, "progress fractions never go backwards")
	check(steps_seen >= {.Partition, .Format, .Configure, .Bootloader, .Done}, "every step reported (%v)", steps_seen)
	check_configured(root, g, efivars)

	// Again: the same Boot#### is reused, BootOrder does not grow.
	ok, err = core.install_with(p, o, nil, nil)
	check(ok, "a second configure run: %s", err)
	order := transmute([]u8)slurp(core.join(efivars, "BootOrder" + SUFFIX))
	eq(len(order), 8, "BootOrder still has two entries after a second run")
	check(!os.exists(core.join(efivars, "Boot0002" + SUFFIX)), "no second Palmframe entry")
	pw := slurp(core.join(root, "etc/passwd"))
	eq(strings.count(pw, "\nalex:x:"), 1, "the user is not added twice")

	log := slurp(o.log_path)
	check(strings.contains(log, "mkfs.ext4") && strings.contains(log, "installation finished"), "the log records commands and the outcome")

	// A disk image may not be a device, whatever validate said.
	p2 := p
	p2.disk = "/dev/null"
	o2 := o
	o2.steps = {.Partition}
	ok, err = core.install_with(p2, o2, nil, nil)
	check(!ok && strings.contains(err, "refuses devices"), "install_with refuses /dev/* as a disk image (%s)", err)
	// Nor is the host's efivarfs ever used for one.
	o3 := o
	o3.efivars = core.DEFAULT_EFIVARS
	o3.steps = {.Bootloader}
	ok, err = core.install_with(p, o3, nil, nil)
	check(ok, "bootloader with the default efivars on an image still succeeds: %s", err)
	check(strings.contains(slurp(o.log_path), "not touching this machine's firmware variables"), "and says it left the firmware alone")
}

@(private = "file")
check_configured :: proc(root: string, g: core.Gpt, efivars: string) {
	SUFFIX :: "-8be4df61-93ca-11d2-aa0d-00e098032b8c"
	eq(slurp(core.join(root, "etc/hostname")), "desk\n", "/etc/hostname")
	check(strings.contains(slurp(core.join(root, "etc/hosts")), "127.0.1.1\tdesk\n"), "/etc/hosts names the host")
	pw := slurp(core.join(root, "etc/passwd"))
	check(strings.contains(pw, "alex:x:1000:1000:Alex Example:/home/alex:/bin/sh\n"), "passwd: the user at uid 1000 (%s)", pw)
	check(!strings.contains(pw, "\npalm:"), "passwd: the demo user is gone")
	check(strings.has_prefix(pw, "root:x:0:0:"), "passwd: root stays first")
	gr := slurp(core.join(root, "etc/group"))
	for want in ([]string{"wheel:x:10:root,alex\n", "audio:x:63:alex\n", "video:x:39:greeter,alex\n", "input:x:97:greeter,alex\n", "alex:x:1000:\n"}) {
		check(strings.contains(gr, want), "group: %q (%s)", strings.trim_space(want), gr)
	}
	check(!strings.contains(gr, "palm"), "group: no trace of the demo user")
	sh := slurp(core.join(root, "etc/shadow"))
	root_hash, user_hash := "", ""
	for line in strings.split_lines(sh) {
		f := strings.split(line, ":")
		if len(f) < 2 {continue}
		if f[0] == "root" {root_hash = f[1]}
		if f[0] == "alex" {user_hash = f[1]}
		check(f[0] != "palm", "shadow: the demo user is gone")
	}
	check(core.verify_password("hunter2", user_hash), "shadow: the user's password verifies")
	check(core.verify_password("toor", root_hash), "shadow: root's own password verifies")
	check(!core.verify_password("palm", root_hash), "shadow: root's demo password is gone")
	check(strings.contains(sh, "greeter:!:"), "shadow: the greeter stays locked")
	st, _ := os.stat(core.join(root, "etc/shadow"), context.temp_allocator)
	eq(transmute(u32)st.mode & 0o777, 0o600, "shadow is 0600")
	check(!strings.contains(sh, "hunter2") && !strings.contains(pw, "hunter2"), "the plain password is nowhere")
	check(os.is_dir(core.join(root, "home/alex/.config")) && os.is_file(core.join(root, "home/alex/.profile")), "home made from the demo home")
	check(!os.exists(core.join(root, "home/palm")), "the demo home is gone")
	hs, _ := os.stat(core.join(root, "home/alex"), context.temp_allocator)
	eq(transmute(u32)hs.mode & 0o777, 0o700, "home is 0700")
	eq(slurp(core.join(root, "etc/locale.conf")), "LANG=fr_FR.UTF-8\n", "/etc/locale.conf")
	kb := slurp(core.join(root, "etc/palm/keyboard"))
	check(strings.contains(kb, "\nlayout = fr\nvariant = azerty\noptions =\n"), "/etc/palm/keyboard (%s)", kb)
	lt, _ := os.read_link(core.join(root, "etc/localtime"), context.temp_allocator)
	eq(lt, "../usr/share/zoneinfo/Europe/Paris", "/etc/localtime points into zoneinfo, relatively")
	eq(slurp(core.join(root, "etc/timezone")), "Europe/Paris\n", "/etc/timezone")
	fs := slurp(core.join(root, "etc/fstab"))
	if len(g.parts) == 2 {
		root_uuid := core.partuuid(g.parts[1].part_guid)
		esp_uuid := core.partuuid(g.parts[0].part_guid)
		check(strings.contains(fs, fmt.tprintf("PARTUUID=%s\t/\text4\t", root_uuid)), "fstab: root by PARTUUID (%s)", fs)
		check(strings.contains(fs, fmt.tprintf("PARTUUID=%s\t/boot/efi\tvfat\t", esp_uuid)), "fstab: the ESP at /boot/efi")
		check(strings.has_prefix(fs, "# palm-init mounts"), "fstab: the base file's comment is kept")
		eq(strings.count(fs, "PARTUUID="), 2, "fstab: exactly two entries")
		conf := slurp(core.join(root, "boot/efi/boot/limine/limine.conf"))
		check(strings.contains(conf, fmt.tprintf("cmdline: root=PARTUUID=%s rw ", root_uuid)), "limine.conf boots root=PARTUUID (%s)", conf)
		check(strings.contains(conf, "path: boot():/vmlinuz"), "limine.conf boots /vmlinuz on the ESP")
	}
	eq(slurp(core.join(root, "etc/palm/repositories")), "# One repository per line: an http:// URL or an absolute path.\n# Written by palm-install: the repository this system was installed from.\nhttp://example.org/palmframe/x86_64\n", "/etc/palm/repositories")
	for f in ([]string{"EFI/BOOT/BOOTX64.EFI", "EFI/palmframe/BOOTX64.EFI", "vmlinuz"}) {
		check(os.is_file(core.join(root, "boot/efi", f)), "ESP has %s", f)
	}
	eq(slurp(core.join(root, "boot/efi/vmlinuz")), "not really a kernel", "the kernel copied to the ESP")
	// The Boot#### variable: attributes, then the load option for partition 1.
	b1 := transmute([]u8)slurp(core.join(efivars, "Boot0001" + SUFFIX))
	check(len(b1) > 4 && core.get_u32(b1) == 7, "Boot0001 has NV|BS|RT")
	if len(b1) > 4 && len(g.parts) == 2 {
		want := core.efi_load_option("Palmframe", 1, g.parts[0].first_lba, g.parts[0].last_lba - g.parts[0].first_lba + 1, g.parts[0].part_guid, "\\EFI\\palmframe\\BOOTX64.EFI", context.temp_allocator)
		check(string(b1[4:]) == string(want), "Boot0001 names the ESP and \\EFI\\palmframe\\BOOTX64.EFI")
	}
	order := transmute([]u8)slurp(core.join(efivars, "BootOrder" + SUFFIX))
	check(len(order) == 8 && core.get_u32(order) == 7 && core.get_u16(order[4:]) == 1 && core.get_u16(order[6:]) == 0, "BootOrder is 0001,0000 (%v)", order)
}

// ------------------------------------------------- the real packages, too --

// With distro/out built, run the whole installation into a directory: our
// partitioning and mkfs on an image, then palm installing the real signed
// repository, then configure and the boot loader on what palm installed.
@(private = "file")
test_full_install :: proc() {
	palm := "distro/out/bin/palm"
	repo := "distro/out/repo/x86_64"
	keys := "distro/build/keys"
	if !os.is_file(palm) || !os.is_file(core.join(repo, "PALMINDEX")) || !os.is_file(core.join(keys, "palmframe.pub")) {
		fmt.println("  skip  full install: distro/out has no palm or repository (make -C distro repo)")
		return
	}
	dir := scratch("full")
	img := core.join(dir, "disk.img")
	make_image(img, 5 * 1024 * 1024 * 1024)
	root := core.join(dir, "root")
	efivars := core.join(dir, "efivars")
	os.make_directory_all(efivars)
	abs_repo, _ := os.get_absolute_path(repo, context.temp_allocator)

	p := core.default_plan()
	p.disk = img
	p.user = "sam"
	p.password = "pw"
	p.hostname = "full"
	p.timezone = "Asia/Tokyo"
	p.repo = fmt.tprintf("file://%s", abs_repo)
	p.efi_boot_entry = true
	o := core.default_options()
	o.disk_image = true
	o.target = root
	o.efivars = efivars
	o.palm = palm
	o.keys_dir = keys
	o.log_path = core.join(dir, "install.log")
	pkgs := 0
	ok, err := core.install_with(p, o, proc(pr: core.Progress, user: rawptr) {
		if pr.step == .Packages && strings.has_prefix(pr.message, "Installing ") && strings.contains(pr.message, " of ") {
			(^int)(user)^ += 1
		}
	}, &pkgs)
	check(ok, "full install into a directory: %s", err)
	check(pkgs > 20, "package progress reported per package (%d)", pkgs)
	check(os.is_file(core.join(root, "usr/bin/palm-login")) && os.is_file(core.join(root, "boot/vmlinuz")), "palm installed the system")
	check(strings.contains(slurp(core.join(root, "etc/passwd")), "sam:x:1000:1000:sam:/home/sam:/bin/sh"), "configure ran on palm's /etc")
	check(os.is_file(core.join(root, "boot/efi/EFI/BOOT/BOOTX64.EFI")), "limine on the ESP")
	vm, _ := os.stat(core.join(root, "boot/efi/vmlinuz"), context.temp_allocator)
	check(vm.size > 1_000_000, "the real kernel copied to the ESP (%d bytes)", vm.size)
	check(strings.contains(slurp(core.join(root, "etc/palm/repositories")), "http://"), "the installed system keeps a network repository")
	vcode, vout := exec(palm, "--root", root, "--keys-dir", keys, "verify")
	_ = vcode
	// Configured /etc files are "modified (config)", which verify accepts;
	// anything else would be a file configure should not have touched.
	for line in strings.split_lines(vout) {
		if strings.contains(line, "missing") || (strings.contains(line, "modified") && !strings.contains(line, "(config)")) {
			check(strings.contains(line, "/home/palm"), "palm verify after configure: %s", line)
		}
	}
}

// ---------------------------------------------------------------- the CLI --

@(private = "file")
test_cli :: proc() {
	dir := scratch("cli")
	img := core.join(dir, "disk.img")
	make_image(img, 4 * 1024 * 1024 * 1024 + 64 * 1024 * 1024)
	pwf := core.join(dir, "pw")
	put(pwf, "s3cret\n")
	null, _ := os.open("/dev/null", {.Write})
	defer os.close(null)
	self, _ := os.get_executable_path(context.temp_allocator)
	cli :: proc(self: string, args: ..string) -> (int, string) {
		cmd := make([dynamic]string)
		append(&cmd, self)
		append(&cmd, ..args)
		return exec(..cmd[:])
	}
	base := []string{"--disk-image", img, "--target", core.join(dir, "root"), "--user", "alex", "--password-file", pwf, "--log", core.join(dir, "log")}

	code, out := cli(self, "--frobnicate")
	eq(code, EXIT_USAGE, "unknown option -> usage (%s)", out)
	code, out = cli(self, "--disk")
	eq(code, EXIT_USAGE, "missing value -> usage")
	code, out = cli(self, "--password", "x")
	eq(code, EXIT_USAGE, "a password on the command line is refused")

	args := make([dynamic]string)
	append(&args, ..base)
	code, out = cli(self, ..args[:])
	eq(code, EXIT_REFUSED, "no --yes -> refused (%s)", out)
	check(strings.contains(out, "WILL BE ERASED"), "the summary says the disk will be erased")
	check(strings.contains(out, "without --yes"), "and why it refused")

	append(&args, "--user", "Root!")
	code, out = cli(self, ..args[:])
	eq(code, EXIT_REFUSED, "an invalid user -> refused")
	check(strings.contains(out, "user name"), "and the problem is named (%s)", out)

	clear(&args)
	append(&args, ..base)
	append(&args, "--dry-run", "--json")
	code, out = cli(self, ..args[:])
	eq(code, EXIT_OK, "--dry-run --json succeeds (%s)", out)
	check(strings.contains(out, "{\"event\":\"progress\",\"step\":\"partition\""), "JSON progress lines")
	check(strings.contains(out, "\"line\":\"$ mkfs.fat"), "the dry run shows the mkfs command")
	check(strings.contains(out, "{\"event\":\"done\",\"ok\":true}"), "a final JSON done line")
	st, _ := os.stat(img, context.temp_allocator)
	buf: [512]u8
	fd, _ := linux.open(strings.clone_to_cstring(img, context.temp_allocator), {.CLOEXEC})
	linux.pread(fd, buf[:], 512)
	linux.close(fd)
	check(string(buf[:8]) != "EFI PART", "the dry run wrote nothing")
	_ = st

	// Answers file under the options; options win.
	ans := core.join(dir, "answers")
	put(ans, fmt.tprintf("# test\ndisk-image = %s\ntarget = %s\nuser = fromfile\npassword = pw\nkeyboard = de:nodeadkeys\npackage = a\npackage = b\n", img, core.join(dir, "root")))
	code, out = cli(self, "--answers", ans, "--user", "fromflag", "--dry-run", "--verbose")
	eq(code, EXIT_OK, "--answers dry run (%s)", out)
	check(strings.contains(out, "user fromflag"), "an option overrides the answers file")
	check(strings.contains(out, "keyboard de:nodeadkeys"), "the answers file's keyboard is used")
	check(strings.contains(out, "packages a b"), "repeated package lines")

	code, out = cli(self, "--list-zones", "--json")
	if os.exists("/usr/share/zoneinfo/zone1970.tab") {
		check(code == 0 && strings.has_prefix(out, "[{\"name\":"), "--list-zones --json")
	}
	code, out = cli(self, "--list-layouts")
	if os.exists("/usr/share/X11/xkb/rules/base.lst") {
		check(code == 0 && strings.contains(out, "fr:azerty"), "--list-layouts shows variants")
	}

	// Partition only, for real, through the binary.
	code, out = cli(self, "--disk-image", img, "--steps", "partition,format", "--yes", "--log", core.join(dir, "log"))
	eq(code, EXIT_OK, "--steps partition,format --yes on an image (%s)", out)
	vcode, vout := exec("sfdisk", "--verify", img)
	check(vcode == 0 && strings.contains(vout, "No errors"), "sfdisk --verify after the CLI run")
}
