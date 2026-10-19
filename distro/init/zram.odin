package main

// Swap in compressed memory: zram.
//
// The disk image has no swap partition, and a swap file sized at build time
// would be wrong for every machine but one. zram needs neither: a block
// device in RAM whose pages are compressed (zstd typically gets 3:1 on
// desktop memory), used as swap with a higher priority than any disk swap.
// It is what Fedora, ChromeOS and Android do by default. palm-init sets it
// up from /etc/palm/zram, which palmframe-base ships:
//
//	size      = 50%     # of MemTotal, or an amount: 512M, 2G; 0 turns it off
//	max       = 4G      # upper bound when size is a percentage
//	algorithm = zstd    # one of /sys/block/zram0/comp_algorithm; else the default
//	priority  = 100     # swap priority (0-32767); disk swap is lower by default
//
// Steps: /sys/block/zram0/comp_algorithm and disksize are written, a swap
// header (what mkswap writes) goes onto /dev/zram0, swapon(2). With zram, the
// kernel's swap read-ahead only costs (there is no seek to save), so
// vm.page-cluster is set to 0, as Fedora's zram-generator does.
//
// A kernel without CONFIG_ZRAM has no /sys/block/zram0: one console line, no
// swap. A zram0 that already has a size is someone else's and left alone.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

ZRAM_CONF :: "/etc/palm/zram"

Zram_Conf :: struct {
	percent:   int, // size as a share of RAM; -1 when size is an amount
	bytes:     u64, // size as an amount
	max_bytes: u64, // 0: no bound
	algorithm: string,
	priority:  int,
}

// parse_size reads 512M, 2G, 1048576, 64K (powers of 1024).
parse_size :: proc(s: string) -> (u64, bool) {
	t := strings.trim_space(s)
	if t == "" {return 0, false}
	mult: u64 = 1
	switch t[len(t) - 1] {
	case 'K', 'k':
		mult = 1 << 10
	case 'M', 'm':
		mult = 1 << 20
	case 'G', 'g':
		mult = 1 << 30
	case 'T', 't':
		mult = 1 << 40
	}
	if mult != 1 {t = t[:len(t) - 1]}
	n, ok := strconv.parse_u64(t, 10)
	return n * mult, ok
}

parse_zram_conf :: proc(text: string) -> (c: Zram_Conf, err: string) {
	c = Zram_Conf{percent = 50, max_bytes = 4 << 30, priority = 100}
	lineno := 0
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		lineno += 1
		line := strings.trim_space(trim_comment(raw))
		if line == "" {continue}
		eq := strings.index_byte(line, '=')
		if eq < 0 {return c, fmt.tprintf("line %d: expected key = value", lineno)}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		switch key {
		case "size":
			if strings.has_suffix(val, "%") {
				p, ok := strconv.parse_int(val[:len(val) - 1], 10)
				if !ok || p < 0 || p > 400 {return c, fmt.tprintf("line %d: bad percentage %q", lineno, val)}
				c.percent = p
			} else {
				b, ok := parse_size(val)
				if !ok {return c, fmt.tprintf("line %d: bad size %q", lineno, val)}
				c.percent = -1
				c.bytes = b
			}
		case "max":
			b, ok := parse_size(val)
			if !ok {return c, fmt.tprintf("line %d: bad size %q", lineno, val)}
			c.max_bytes = b
		case "algorithm":
			c.algorithm = val
		case "priority":
			p, ok := strconv.parse_int(val, 10)
			if !ok || p < 0 || p > 32767 {return c, fmt.tprintf("line %d: priority must be 0-32767", lineno)}
			c.priority = p
		case:
			return c, fmt.tprintf("line %d: unknown key %q", lineno, key)
		}
	}
	return c, ""
}

// zram_size is the device size for a machine with mem_total bytes of RAM,
// rounded down to whole pages.
zram_size :: proc(c: Zram_Conf, mem_total: u64) -> u64 {
	size := c.bytes
	if c.percent >= 0 {
		size = mem_total * u64(c.percent) / 100
		if c.max_bytes > 0 {size = min(size, c.max_bytes)}
	}
	return size / 4096 * 4096
}

// swap_header is the first page mkswap writes: version 1, the last usable
// page, no bad pages, a UUID and the magic at the page's end.
swap_header :: proc(size: u64, uuid: []u8, label: string) -> [4096]u8 {
	h: [4096]u8
	put32 :: proc(b: []u8, off: int, v: u32) {
		b[off], b[off + 1], b[off + 2], b[off + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	put32(h[:], 1024, 1)
	put32(h[:], 1028, u32(size / 4096 - 1))
	put32(h[:], 1032, 0)
	copy(h[1036:1052], uuid)
	copy(h[1052:1068], label)
	copy(h[4086:], "SWAPSPACE2")
	return h
}

mem_total :: proc() -> u64 {
	text, ok := read_file("/proc/meminfo", context.temp_allocator)
	if !ok {return 0}
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(line, "MemTotal:") {
			f := split_fields(line, context.temp_allocator)
			if len(f) >= 2 {
				kb, _ := strconv.parse_u64(f[1], 10)
				return kb * 1024
			}
		}
	}
	return 0
}

zram_setup :: proc() {
	text, ok := read_file(ZRAM_CONF, context.temp_allocator)
	if !ok {return}
	c, err := parse_zram_conf(text)
	if err != "" {
		say("zram: %s: %s; no zram swap", ZRAM_CONF, err)
		return
	}
	size := zram_size(c, mem_total())
	if size < 1 << 20 {return}
	if !exists("/sys/block/zram0") {
		say("zram: this kernel has no zram; no swap")
		return
	}
	if cur, _ := read_file("/sys/block/zram0/disksize", context.temp_allocator); strings.trim_space(cur) != "0" {
		return
	}
	if c.algorithm != "" {
		have, _ := read_file("/sys/block/zram0/comp_algorithm", context.temp_allocator)
		// The list marks the current one as [zstd].
		listed := false
		for a in split_fields(have, context.temp_allocator) {
			if strings.trim(a, "[]") == c.algorithm {listed = true}
		}
		if listed {
			write_file("/sys/block/zram0/comp_algorithm", c.algorithm)
		} else {
			say("zram: no %s in this kernel; using its default", c.algorithm)
		}
	}
	if !write_file("/sys/block/zram0/disksize", fmt.tprintf("%d", size)) {
		say("zram: cannot set the size")
		return
	}
	uuid: [16]u8
	linux.getrandom(uuid[:], {})
	uuid[6] = (uuid[6] & 0x0f) | 0x40 // version 4
	uuid[8] = (uuid[8] & 0x3f) | 0x80 // RFC 4122 variant
	header := swap_header(size, uuid[:], "zram0")
	fd, oerr := linux.open("/dev/zram0", {.WRONLY, .CLOEXEC})
	if oerr != .NONE {
		say("zram: cannot open /dev/zram0 (%v)", oerr)
		return
	}
	linux.pwrite(fd, header[:], 0)
	linux.fsync(fd)
	linux.close(fd)
	raw := transmute(u32)linux.Swap_Flags{.PREFER} | (u32(c.priority) & 0x7fff)
	if serr := linux.swapon("/dev/zram0", transmute(linux.Swap_Flags)raw); serr != .NONE {
		say("zram: swapon failed (%v)", serr)
		return
	}
	write_file("/proc/sys/vm/page-cluster", "0")
	algo, _ := read_file("/sys/block/zram0/comp_algorithm", context.temp_allocator)
	current := c.algorithm
	for a in split_fields(algo, context.temp_allocator) {
		if strings.has_prefix(a, "[") {current = strings.trim(a, "[]")}
	}
	say("zram: %d MiB of swap on /dev/zram0 (%s, priority %d)", size >> 20, current, c.priority)
}
