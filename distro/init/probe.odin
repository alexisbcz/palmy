package main

// Finding a block device by name: what blkid and findfs do for mount(8),
// for the four tags fstab uses.
//
//	PARTUUID=, PARTLABEL=   the GPT entry's GUID and name. The kernel puts
//	                        both in the partition's uevent file, so these
//	                        need no reading of the disk.
//	UUID=, LABEL=           the filesystem's own, read from its superblock:
//
//	ext2/3/4   superblock at 1024: magic 0xEF53 at +0x38, UUID at +0x68
//	           (16 bytes, printed 8-4-4-4-12), label at +0x78 (16 bytes)
//	FAT        boot sector: "FAT32   " at 0x52 puts the serial at 0x43
//	           and the label at 0x47, otherwise "FAT" at 0x36 puts them at
//	           0x27 and 0x2B; the serial prints as XXXX-XXXX, "NO NAME" is
//	           no label
//	swap       "SWAPSPACE2" in the last 10 bytes of the first 4 KiB page,
//	           UUID at 1024+12, label at 1024+28
//
// Tags are compared without regard to case for UUIDs (FAT's are upper case,
// ext4's lower) and exactly for labels.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

Probe :: struct {
	type:  string, // "ext4" (for any of ext2/3/4), "vfat", "swap", or ""
	uuid:  string,
	label: string,
}

PROBE_BYTES :: 4096

@(private = "file")
le16 :: proc(b: []u8, off: int) -> u32 {return u32(b[off]) | u32(b[off + 1]) << 8}
@(private = "file")
le32 :: proc(b: []u8, off: int) -> u32 {return le16(b, off) | le16(b, off + 2) << 16}

// probe_buffer recognises a filesystem from its first PROBE_BYTES bytes.
probe_buffer :: proc(b: []u8, allocator := context.allocator) -> (p: Probe) {
	if len(b) < PROBE_BYTES {return}
	if le16(b, 1024 + 0x38) == 0xEF53 {
		p.type = "ext4"
		p.uuid = uuid_string(b[1024 + 0x68:][:16], allocator)
		p.label = c_string(b[1024 + 0x78:][:16], allocator)
		return
	}
	if string(b[PROBE_BYTES - 10:PROBE_BYTES]) == "SWAPSPACE2" {
		p.type = "swap"
		p.uuid = uuid_string(b[1024 + 12:][:16], allocator)
		p.label = c_string(b[1024 + 28:][:16], allocator)
		return
	}
	if b[510] == 0x55 && b[511] == 0xAA {
		serial_at, label_at := -1, -1
		if string(b[0x52:0x5A]) == "FAT32   " {
			serial_at, label_at = 0x43, 0x47
		} else if string(b[0x36:0x39]) == "FAT" {
			serial_at, label_at = 0x27, 0x2B
		}
		if serial_at >= 0 {
			p.type = "vfat"
			serial := le32(b, serial_at)
			p.uuid = fmt.aprintf("%04X-%04X", serial >> 16, serial & 0xffff, allocator = allocator)
			label := strings.trim_right(string(b[label_at:][:11]), " \x00")
			if label != "NO NAME" {p.label = strings.clone(label, allocator)}
		}
	}
	return
}

uuid_string :: proc(u: []u8, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15],
		allocator = allocator,
	)
}

@(private = "file")
c_string :: proc(b: []u8, allocator := context.allocator) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {n += 1}
	return strings.clone(string(b[:n]), allocator)
}

probe_device :: proc(path: string) -> Probe {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {return {}}
	defer linux.close(fd)
	buf: [PROBE_BYTES]u8
	n, rerr := linux.pread(fd, buf[:], 0)
	if rerr != .NONE || n < PROBE_BYTES {return {}}
	return probe_buffer(buf[:], context.temp_allocator)
}

// Tag is a parsed `KEY=value` device name.
Tag :: struct {
	key, value: string,
}

parse_tag :: proc(spec: string) -> (t: Tag, ok: bool) {
	eq := strings.index_byte(spec, '=')
	if eq <= 0 || !is_tag(spec) {return {}, false}
	v := spec[eq + 1:]
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v) - 1] == v[0] {
		v = v[1:len(v) - 1]
	}
	return Tag{spec[:eq], v}, v != ""
}

// tag_matches compares one device's identity with a tag. uevent is the
// partition's (or disk's) uevent file; probe is read only for UUID/LABEL.
tag_matches :: proc(t: Tag, uevent: string, probe: Probe) -> bool {
	switch t.key {
	case "PARTUUID":
		return strings.equal_fold(uevent_value(uevent, "PARTUUID"), t.value)
	case "PARTLABEL":
		return uevent_value(uevent, "PARTNAME") == t.value
	case "UUID":
		return probe.uuid != "" && strings.equal_fold(probe.uuid, t.value)
	case "LABEL":
		return probe.label != "" && probe.label == t.value
	}
	return false
}

uevent_value :: proc(uevent, key: string) -> string {
	rest := uevent
	for line in strings.split_lines_iterator(&rest) {
		if len(line) > len(key) && line[len(key)] == '=' && strings.has_prefix(line, key) {
			return line[len(key) + 1:]
		}
	}
	return ""
}

// resolve_device turns an fstab device into a path under /dev. A plain path
// is returned as it is. With wait, a tag that matches nothing is looked for
// again until DEVICE_WAIT_MS has passed since the first wait of this boot (a
// USB disk can be announced a little after init starts).
@(private = "file")
wait_started: i64 = 0

resolve_device :: proc(spec: string, wait: bool) -> (path: string, found: bool) {
	t, is := parse_tag(spec)
	for {
		if !is {
			if exists(spec) {return spec, true}
		} else if p, ok := find_tagged(t); ok {
			return p, true
		}
		if !wait {return "", false}
		if wait_started == 0 {wait_started = now_ms()}
		if now_ms() - wait_started >= DEVICE_WAIT_MS {return "", false}
		sleep_ms(100)
	}
}

find_tagged :: proc(t: Tag) -> (string, bool) {
	names, ok := list_dir("/sys/class/block")
	if !ok {return "", false}
	for name in names {
		dir := strings.concatenate({"/sys/class/block/", name}, context.temp_allocator)
		uevent, _ := read_file(strings.concatenate({dir, "/uevent"}, context.temp_allocator), context.temp_allocator)
		devname := uevent_value(uevent, "DEVNAME")
		if devname == "" {continue}
		path := strings.concatenate({"/dev/", devname}, context.temp_allocator)
		probe: Probe
		if t.key == "UUID" || t.key == "LABEL" {
			// Empty devices (an unloaded loop, a CD drive with no disc)
			// are not opened at all.
			size, _ := read_file(strings.concatenate({dir, "/size"}, context.temp_allocator), context.temp_allocator)
			if strings.trim_space(size) == "0" {continue}
			probe = probe_device(path)
		}
		if tag_matches(t, uevent, probe) {return strings.clone(path), true}
	}
	return "", false
}
