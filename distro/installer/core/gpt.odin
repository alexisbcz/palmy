package install_core

// The GUID partition table, written and read by hand.
//
// The installer erases the whole disk and lays out exactly two partitions, so
// there is no reason to drive sfdisk through a script: the table is a few
// hundred bytes whose every field is fixed by the UEFI specification (2.10,
// chapter 5). Writing it ourselves means the same code runs against a block
// device inside the live system and against a plain image file on the build
// host, where `sfdisk --dump` / `sfdisk --verify` are the independent judge.
//
// What goes on the disk, in sectors of `sector_size` bytes (512 almost
// everywhere; 4096 on some NVMe and USB bridges, which we honour):
//
//   LBA 0                      protective MBR: one 0xEE partition covering
//                              the disk, so MBR-only tools see it as in use;
//                              its boot code is limine's BIOS stage 1, put
//                              there later by `limine bios-install`
//   LBA 1                      primary GPT header
//   LBA 2 ..                   primary entry array, 128 entries x 128 bytes
//   first_usable .. 1 MiB      partition 3, BIOS boot: limine's stage 2
//   1 MiB .. last_usable       the ESP and the root, aligned to 1 MiB
//   last-1-array .. last-1     backup entry array (same bytes as the primary)
//   last LBA                   backup header (my/alternate LBAs swapped)
//
// Both headers carry a CRC32 of themselves (computed with the field zeroed)
// and of the entry array; firmware ignores a table whose CRCs do not match,
// which is why gpt_read verifies them rather than trusting the layout.

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf16"

ESP_TYPE :: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX_FS_TYPE :: "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
// "Hah!IdontNeedEFI": a partition no file system lives in, where a BIOS boot
// loader keeps the code that does not fit in the MBR (GRUB's convention,
// which limine follows).
BIOS_BOOT_TYPE :: "21686148-6449-6E6F-744E-656564454649"
// Partition numbers. The ESP stays partition 1 and the root 2, as on every
// disk installed before the BIOS boot partition existed; the BIOS boot
// partition is number 3 although it comes first on the disk.
ESP_NUMBER :: 1
ROOT_NUMBER :: 2
BIOS_BOOT_NUMBER :: 3
// limine's stage 2 is about 40 KiB; its documentation asks for 32 KiB at
// least. The gap before the first MiB holds 1007 KiB with 512-byte sectors.
BIOS_BOOT_MIN :: 64 * 1024

ALIGN :: 1024 * 1024 // partition starts and sizes are whole MiB
ESP_SIZE :: 512 * 1024 * 1024
GPT_ENTRIES :: 128
GPT_ENTRY_SIZE :: 128
GPT_HEADER_SIZE :: 92

// ---------------------------------------------------------------- CRC32 -----

// The CRC the GPT uses is the common one (IEEE 802.3, zlib, PNG): reflected
// polynomial 0xEDB88320, initial value and final xor 0xFFFFFFFF. The table is
// built once at start-up; 1 KiB of it is cheaper than a dependency.
@(private = "file")
crc_table: [256]u32

@(init, private = "file")
crc_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		c := u32(i)
		for _ in 0 ..< 8 {
			c = (c & 1) != 0 ? 0xEDB88320 ~ (c >> 1) : c >> 1
		}
		crc_table[i] = c
	}
}

crc32 :: proc "contextless" (data: []u8) -> u32 {
	c := u32(0xFFFFFFFF)
	for b in data {
		c = crc_table[(c ~ u32(b)) & 0xff] ~ (c >> 8)
	}
	return c ~ 0xFFFFFFFF
}

// ----------------------------------------------------------------- GUIDs ----

// A GUID as it is stored on disk. The first three fields are little-endian,
// the last two big-endian ("mixed endian"), so the bytes do not read in the
// same order as the text form; guid_string and guid_parse do the shuffle.
Guid :: [16]u8

guid_string :: proc(g: Guid, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
		g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6],
		g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15],
		allocator = allocator,
	)
}

guid_parse :: proc(s: string) -> (g: Guid, ok: bool) {
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return
	}
	hex: [16]u8
	n := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '-' {
			continue
		}
		hi, hok := hex_val(s[i])
		lo, lok := hex_val(s[i + 1])
		if !hok || !lok {
			return
		}
		hex[n] = hi << 4 | lo
		n += 1
		i += 1
	}
	// text order -> disk order
	g = {hex[3], hex[2], hex[1], hex[0], hex[5], hex[4], hex[7], hex[6],
		hex[8], hex[9], hex[10], hex[11], hex[12], hex[13], hex[14], hex[15]}
	return g, true
}

@(private = "file")
hex_val :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9': return c - '0', true
	case 'a' ..= 'f': return c - 'a' + 10, true
	case 'A' ..= 'F': return c - 'A' + 10, true
	}
	return 0, false
}

// guid_random is an RFC 4122 version 4 GUID from getrandom(2). The version
// nibble lives in the high half of the third field, which is little-endian
// on disk, hence byte 7 rather than byte 6.
guid_random :: proc() -> Guid {
	g: Guid
	for got := 0; got < len(g); {
		n, err := linux.getrandom(g[got:], {})
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			panic("getrandom failed")
		}
		got += n
	}
	g[7] = (g[7] & 0x0f) | 0x40
	g[8] = (g[8] & 0x3f) | 0x80
	return g
}

// --------------------------------------------------------------- the table --

Gpt_Partition :: struct {
	type_guid:  Guid,
	part_guid:  Guid,
	first_lba:  u64,
	last_lba:   u64, // inclusive, as the specification has it
	attributes: u64,
	name:       string,
}

Gpt :: struct {
	sector_size:   u64,
	total_sectors: u64,
	disk_guid:     Guid,
	first_usable:  u64,
	last_usable:   u64,
	parts:         []Gpt_Partition,
}

// entry_sectors is how many sectors the 16 KiB entry array occupies.
gpt_entry_sectors :: proc(sector_size: u64) -> u64 {
	return (GPT_ENTRIES * GPT_ENTRY_SIZE + sector_size - 1) / sector_size
}

// gpt_layout_palmy is the one layout the installer writes: a 512 MiB EFI
// system partition at 1 MiB, a Linux root from there to the last whole MiB
// before the backup table, and a BIOS boot partition in the otherwise unused
// space before the first MiB, so the same disk starts under UEFI and under a
// BIOS. Fresh random GUIDs every time, so two disks installed from the same
// medium never share a PARTUUID.
gpt_layout_palmy :: proc(size_bytes: u64, sector_size: u64 = 512, allocator := context.allocator) -> (g: Gpt, ok: bool) {
	ss := sector_size
	if ss < 512 || ss & (ss - 1) != 0 || ALIGN % ss != 0 {
		return
	}
	total := size_bytes / ss
	es := gpt_entry_sectors(ss)
	g.sector_size = ss
	g.total_sectors = total
	g.first_usable = 2 + es
	if total < g.first_usable + es + 1 {
		return
	}
	g.last_usable = total - 1 - es - 1
	g.disk_guid = guid_random()

	per_mib := u64(ALIGN) / ss
	esp_first := per_mib
	esp_last := esp_first + u64(ESP_SIZE) / ss - 1
	root_first := esp_last + 1
	// The root ends on the last MiB boundary that still fits before the
	// backup table, so its size is whole MiB too (what sfdisk would choose).
	root_end := (g.last_usable + 1) / per_mib * per_mib // exclusive
	if root_end <= root_first + per_mib {
		return
	}
	if (per_mib - g.first_usable) * ss < BIOS_BOOT_MIN {
		return
	}
	parts := make([]Gpt_Partition, 3, allocator)
	parts[0] = {
		type_guid = must_guid(ESP_TYPE),
		part_guid = guid_random(),
		first_lba = esp_first,
		last_lba  = esp_last,
		name      = "EFI system partition",
	}
	parts[1] = {
		type_guid = must_guid(LINUX_FS_TYPE),
		part_guid = guid_random(),
		first_lba = root_first,
		last_lba  = root_end - 1,
		name      = "Palmy",
	}
	parts[2] = {
		type_guid = must_guid(BIOS_BOOT_TYPE),
		part_guid = guid_random(),
		first_lba = g.first_usable,
		last_lba  = per_mib - 1,
		name      = "BIOS boot partition",
	}
	g.parts = parts
	return g, true
}

@(private = "file")
must_guid :: proc(s: string) -> Guid {
	g, ok := guid_parse(s)
	assert(ok)
	return g
}

// gpt_encode returns the bytes of the start of the disk (protective MBR,
// primary header, primary entries: first_usable sectors) and of its end
// (backup entries, backup header: the last 1 + entry_sectors sectors).
gpt_encode :: proc(g: Gpt, allocator := context.allocator) -> (head: []u8, tail: []u8) {
	ss := g.sector_size
	es := gpt_entry_sectors(ss)
	last := g.total_sectors - 1

	entries := make([]u8, es * ss, context.temp_allocator)
	for p, i in g.parts {
		p := p
		e := entries[i * GPT_ENTRY_SIZE:][:GPT_ENTRY_SIZE]
		copy(e[0:16], p.type_guid[:])
		copy(e[16:32], p.part_guid[:])
		put_u64(e[32:], p.first_lba)
		put_u64(e[40:], p.last_lba)
		put_u64(e[48:], p.attributes)
		// The name is UTF-16LE, 36 code units, zero padded.
		units: [36]u16
		n := utf16.encode_string(units[:], p.name)
		for k in 0 ..< n {
			put_u16(e[56 + 2 * k:], units[k])
		}
	}
	entries_crc := crc32(entries[:GPT_ENTRIES * GPT_ENTRY_SIZE])

	head = make([]u8, g.first_usable * ss, allocator)
	tail = make([]u8, (es + 1) * ss, allocator)

	// Protective MBR. CHS fields are the conventional "too big" values; the
	// LBA size field saturates at 2^32-1 for disks past 2 TiB.
	mbr := head[0:512]
	pe := mbr[446:462]
	pe[0] = 0x00
	pe[1], pe[2], pe[3] = 0x00, 0x02, 0x00
	pe[4] = 0xEE
	pe[5], pe[6], pe[7] = 0xFF, 0xFF, 0xFF
	put_u32(pe[8:], 1)
	put_u32(pe[12:], u32(min(g.total_sectors - 1, 0xFFFFFFFF)))
	mbr[510], mbr[511] = 0x55, 0xAA

	write_header :: proc(dst: []u8, g: Gpt, my_lba, alt_lba, entries_lba: u64, entries_crc: u32) {
		h := dst[:GPT_HEADER_SIZE]
		copy(h[0:8], "EFI PART")
		put_u32(h[8:], 0x00010000)
		put_u32(h[12:], GPT_HEADER_SIZE)
		// h[16:20] CRC, filled below; h[20:24] reserved, zero
		put_u64(h[24:], my_lba)
		put_u64(h[32:], alt_lba)
		put_u64(h[40:], g.first_usable)
		put_u64(h[48:], g.last_usable)
		dg := g.disk_guid
		copy(h[56:72], dg[:])
		put_u64(h[72:], entries_lba)
		put_u32(h[80:], GPT_ENTRIES)
		put_u32(h[84:], GPT_ENTRY_SIZE)
		put_u32(h[88:], entries_crc)
		put_u32(h[16:], crc32(h))
	}

	write_header(head[ss:], g, 1, last, 2, entries_crc)
	copy(head[2 * ss:], entries)
	copy(tail[0:], entries)
	write_header(tail[es * ss:], g, last, 1, last - es, entries_crc)
	return
}

// gpt_write erases the old table and signatures at both ends of the disk
// (the first and last MiB) and writes `g`. `fd` is a block device or a plain
// file of at least total_sectors * sector_size bytes.
gpt_write :: proc(fd: linux.Fd, g: Gpt) -> string {
	ss := g.sector_size
	size := g.total_sectors * ss
	head, tail := gpt_encode(g, context.temp_allocator)

	zero := make([]u8, ALIGN, context.temp_allocator)
	wipe := min(u64(ALIGN), size)
	if e := pwrite_all(fd, zero[:wipe], 0); e != "" {
		return e
	}
	if size > wipe {
		if e := pwrite_all(fd, zero[:wipe], i64(size - wipe)); e != "" {
			return e
		}
	}
	if e := pwrite_all(fd, head, 0); e != "" {
		return e
	}
	if e := pwrite_all(fd, tail, i64(size - u64(len(tail)))); e != "" {
		return e
	}
	if err := linux.fsync(fd); err != .NONE {
		return fmt.tprintf("fsync: %v", err)
	}
	return ""
}

// gpt_read parses and verifies the table on `fd`: the protective MBR, both
// headers and both entry arrays with their CRCs, and that they agree. It is
// how the installer checks its own write before formatting anything, and how
// later steps find the PARTUUIDs when the partition step was skipped.
gpt_read :: proc(fd: linux.Fd, size_bytes: u64, sector_size: u64 = 512, allocator := context.allocator) -> (g: Gpt, err: string) {
	ss := sector_size
	total := size_bytes / ss
	es := gpt_entry_sectors(ss)
	if total < 3 + 2 * es {
		return g, "the disk is too small to hold a GPT"
	}
	mbr := make([]u8, 512, context.temp_allocator)
	if e := pread_all(fd, mbr, 0); e != "" {
		return g, e
	}
	if mbr[510] != 0x55 || mbr[511] != 0xAA || mbr[446 + 4] != 0xEE {
		return g, "no protective MBR"
	}

	read_header :: proc(fd: linux.Fd, lba, ss, es: u64) -> (h: []u8, entries: []u8, err: string) {
		h = make([]u8, ss, context.temp_allocator)
		if e := pread_all(fd, h, i64(lba * ss)); e != "" {
			return nil, nil, e
		}
		if string(h[0:8]) != "EFI PART" {
			return nil, nil, fmt.tprintf("no GPT header at LBA %d", lba)
		}
		hsize := get_u32(h[12:])
		if hsize < GPT_HEADER_SIZE || u64(hsize) > ss {
			return nil, nil, "bad header size"
		}
		want := get_u32(h[16:])
		tmp := make([]u8, hsize, context.temp_allocator)
		copy(tmp, h[:hsize])
		put_u32(tmp[16:], 0)
		if crc32(tmp) != want {
			return nil, nil, fmt.tprintf("header CRC mismatch at LBA %d", lba)
		}
		if get_u64(h[24:]) != lba {
			return nil, nil, fmt.tprintf("header at LBA %d names itself LBA %d", lba, get_u64(h[24:]))
		}
		n := get_u32(h[80:])
		esz := get_u32(h[84:])
		if esz != GPT_ENTRY_SIZE || n == 0 || n > 1024 {
			return nil, nil, "unsupported entry array"
		}
		entries = make([]u8, (u64(n) * u64(esz) + ss - 1) / ss * ss, context.temp_allocator)
		if e := pread_all(fd, entries, i64(get_u64(h[72:]) * ss)); e != "" {
			return nil, nil, e
		}
		if crc32(entries[:n * esz]) != get_u32(h[88:]) {
			return nil, nil, fmt.tprintf("entry array CRC mismatch (header at LBA %d)", lba)
		}
		return h, entries[:n * esz], ""
	}

	ph, pent, perr := read_header(fd, 1, ss, es)
	if perr != "" {
		return g, perr
	}
	alt := get_u64(ph[32:])
	if alt != total - 1 {
		return g, fmt.tprintf("backup header expected at LBA %d, primary says %d", total - 1, alt)
	}
	bh, bent, berr := read_header(fd, alt, ss, es)
	if berr != "" {
		return g, fmt.tprintf("backup: %s", berr)
	}
	if get_u64(bh[32:]) != 1 {
		return g, "backup header does not point back at LBA 1"
	}
	if string(pent) != string(bent) {
		return g, "primary and backup entry arrays differ"
	}
	if string(ph[40:72]) != string(bh[40:72]) {
		return g, "primary and backup headers disagree on the usable range or the disk GUID"
	}

	g.sector_size = ss
	g.total_sectors = total
	g.first_usable = get_u64(ph[40:])
	g.last_usable = get_u64(ph[48:])
	copy(g.disk_guid[:], ph[56:72])
	parts := make([dynamic]Gpt_Partition, allocator)
	for i := 0; i < len(pent); i += GPT_ENTRY_SIZE {
		e := pent[i:][:GPT_ENTRY_SIZE]
		p: Gpt_Partition
		copy(p.type_guid[:], e[0:16])
		if p.type_guid == {} {
			continue
		}
		copy(p.part_guid[:], e[16:32])
		p.first_lba = get_u64(e[32:])
		p.last_lba = get_u64(e[40:])
		p.attributes = get_u64(e[48:])
		units: [36]u16
		n := 0
		for ; n < 36; n += 1 {
			units[n] = get_u16(e[56 + 2 * n:])
			if units[n] == 0 {
				break
			}
		}
		buf: [36 * 4]u8
		w := utf16.decode_to_utf8(buf[:], units[:n])
		p.name = strings.clone(string(buf[:w]), allocator)
		if p.first_lba < g.first_usable || p.last_lba > g.last_usable || p.last_lba < p.first_lba {
			return g, fmt.tprintf("partition %d lies outside the usable range", len(parts) + 1)
		}
		append(&parts, p)
	}
	g.parts = parts[:]
	return g, ""
}

// ------------------------------------------------------------ byte helpers --

put_u16 :: proc "contextless" (b: []u8, v: u16) {
	b[0], b[1] = u8(v), u8(v >> 8)
}
put_u32 :: proc "contextless" (b: []u8, v: u32) {
	for i in 0 ..< 4 {b[i] = u8(v >> (8 * uint(i)))}
}
put_u64 :: proc "contextless" (b: []u8, v: u64) {
	for i in 0 ..< 8 {b[i] = u8(v >> (8 * uint(i)))}
}
get_u16 :: proc "contextless" (b: []u8) -> u16 {
	return u16(b[0]) | u16(b[1]) << 8
}
get_u32 :: proc "contextless" (b: []u8) -> (v: u32) {
	for i in 0 ..< 4 {v |= u32(b[i]) << (8 * uint(i))}
	return
}
get_u64 :: proc "contextless" (b: []u8) -> (v: u64) {
	for i in 0 ..< 8 {v |= u64(b[i]) << (8 * uint(i))}
	return
}

pwrite_all :: proc(fd: linux.Fd, buf: []u8, off: i64) -> string {
	done := 0
	for done < len(buf) {
		n, err := linux.pwrite(fd, buf[done:], off + i64(done))
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return fmt.tprintf("write at %d: %v", off + i64(done), err)
		}
		if n == 0 {
			return fmt.tprintf("write at %d: no progress", off + i64(done))
		}
		done += n
	}
	return ""
}

pread_all :: proc(fd: linux.Fd, buf: []u8, off: i64) -> string {
	done := 0
	for done < len(buf) {
		n, err := linux.pread(fd, buf[done:], off + i64(done))
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return fmt.tprintf("read at %d: %v", off + i64(done), err)
		}
		if n == 0 {
			return fmt.tprintf("read at %d: end of device", off + i64(done))
		}
		done += n
	}
	return ""
}
