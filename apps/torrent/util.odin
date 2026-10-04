package main

// Small shared helpers: formatting into the frame/temp arena, byte order,
// hex, time, and human-readable sizes and rates.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

// tsprint formats into the temporary allocator. Error strings in this program
// are built with it and are only valid until the next `free_all` of the temp
// arena — which, in the engine, is once per loop iteration.
tsprint :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

// asprint formats into the context allocator, for a string that is kept.
asprint :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args)
}

// ---------------------------------------------------------------------------
// Big-endian integers. The peer wire protocol and both tracker protocols are
// network byte order throughout.
// ---------------------------------------------------------------------------

be_u32 :: proc(b: []u8) -> u32 {
	if len(b) < 4 {
		return 0
	}
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

be_u16 :: proc(b: []u8) -> u16 {
	if len(b) < 2 {
		return 0
	}
	return u16(b[0]) << 8 | u16(b[1])
}

be_u64 :: proc(b: []u8) -> u64 {
	if len(b) < 8 {
		return 0
	}
	v: u64
	for i in 0 ..< 8 {
		v = v << 8 | u64(b[i])
	}
	return v
}

put_be_u32 :: proc(b: []u8, v: u32) {
	if len(b) < 4 {
		return
	}
	b[0] = u8(v >> 24)
	b[1] = u8(v >> 16)
	b[2] = u8(v >> 8)
	b[3] = u8(v)
}

put_be_u16 :: proc(b: []u8, v: u16) {
	if len(b) < 2 {
		return
	}
	b[0] = u8(v >> 8)
	b[1] = u8(v)
}

put_be_u64 :: proc(b: []u8, v: u64) {
	if len(b) < 8 {
		return
	}
	for i in 0 ..< 8 {
		b[i] = u8(v >> uint(8 * (7 - i)))
	}
}

append_be_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

append_be_u16 :: proc(out: ^[dynamic]u8, v: u16) {
	append(out, u8(v >> 8), u8(v))
}

append_be_u64 :: proc(out: ^[dynamic]u8, v: u64) {
	for i in 0 ..< 8 {
		append(out, u8(v >> uint(8 * (7 - i))))
	}
}

// ---------------------------------------------------------------------------
// Hex
// ---------------------------------------------------------------------------

@(rodata)
HEX_LOWER := [16]u8{'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'}

@(rodata)
ALNUM36 := [36]u8 {
	'0','1','2','3','4','5','6','7','8','9',
	'a','b','c','d','e','f','g','h','i','j','k','l','m',
	'n','o','p','q','r','s','t','u','v','w','x','y','z',
}

@(rodata)
HEX_UPPER := [16]u8{'0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'}

hex_encode :: proc(b: []u8, allocator := context.allocator) -> string {
	out := make([]u8, len(b) * 2, allocator)
	for v, i in b {
		out[i * 2] = HEX_LOWER[v >> 4]
		out[i * 2 + 1] = HEX_LOWER[v & 15]
	}
	return string(out)
}

hex_nibble :: proc(c: u8) -> (v: u8, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

hex_decode :: proc(s: string, allocator := context.allocator) -> (b: []u8, ok: bool) {
	if len(s) % 2 != 0 {
		return nil, false
	}
	out := make([]u8, len(s) / 2, allocator)
	for i in 0 ..< len(out) {
		hi, ok1 := hex_nibble(s[i * 2])
		lo, ok2 := hex_nibble(s[i * 2 + 1])
		if !ok1 || !ok2 {
			delete(out, allocator)
			return nil, false
		}
		out[i] = hi << 4 | lo
	}
	return out, true
}

// ---------------------------------------------------------------------------
// Human-readable quantities, in the same style as apps/files
// ---------------------------------------------------------------------------

human_size :: proc(n: i64, allocator := context.allocator) -> string {
	if n < 0 {
		return strings.clone("?", allocator)
	}
	if n < 1024 {
		return fmt.aprintf("%d B", n, allocator = allocator)
	}
	units := [?]string{"KiB", "MiB", "GiB", "TiB", "PiB"}
	v := f64(n) / 1024
	u := 0
	for v >= 1024 && u < len(units) - 1 {
		v /= 1024
		u += 1
	}
	if v < 10 {
		return fmt.aprintf("%.2f %s", v, units[u], allocator = allocator)
	}
	if v < 100 {
		return fmt.aprintf("%.1f %s", v, units[u], allocator = allocator)
	}
	return fmt.aprintf("%.0f %s", v, units[u], allocator = allocator)
}

human_rate :: proc(bytes_per_sec: f64, allocator := context.allocator) -> string {
	if bytes_per_sec < 1 {
		return strings.clone("—", allocator)
	}
	s := human_size(i64(bytes_per_sec), context.temp_allocator)
	return fmt.aprintf("%s/s", s, allocator = allocator)
}

human_duration :: proc(seconds: f64, allocator := context.allocator) -> string {
	if seconds <= 0 || seconds > 60 * 60 * 24 * 365 {
		return strings.clone("—", allocator)
	}
	s := i64(seconds)
	if s < 60 {
		return fmt.aprintf("%ds", s, allocator = allocator)
	}
	if s < 3600 {
		return fmt.aprintf("%dm %ds", s / 60, s % 60, allocator = allocator)
	}
	if s < 86400 {
		return fmt.aprintf("%dh %dm", s / 3600, (s % 3600) / 60, allocator = allocator)
	}
	return fmt.aprintf("%dd %dh", s / 86400, (s % 86400) / 3600, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

// now_s is a monotonic-ish seconds clock, used for every interval in the
// engine. It is seconds since the process started.
@(private = "file")
start_time: time.Time
@(private = "file")
start_set: bool

now_s :: proc() -> f64 {
	if !start_set {
		start_time = time.now()
		start_set = true
	}
	return time.duration_seconds(time.since(start_time))
}

unix_now :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

parse_int_default :: proc(s: string, dflt: int) -> int {
	v, ok := strconv.parse_int(strings.trim_space(s), 10)
	if !ok {
		return dflt
	}
	return v
}

// clampf is used by the rate graph and the progress bars.
clampf :: proc(v, lo, hi: f32) -> f32 {
	return math.max(lo, math.min(hi, v))
}
