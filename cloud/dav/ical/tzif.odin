// The system time zone database: TZif files (RFC 8536) and the POSIX TZ
// string in their footer, which carries the rule for every year after the
// last listed transition. Modern tzdata is built "slim", so for most zones
// the footer is the *only* source for future dates — which is exactly where
// a calendar lives.
package ical

import "core:os"
import "core:strings"

Posix_Date :: struct {
	kind:  u8, // 'M' month.week.day, 'J' Julian 1..365 without Feb 29, 'n' 0..365
	month: int,
	week:  int,
	day:   int,
	time:  i64, // seconds after local midnight (may be negative or > 24h)
}

Posix_TZ :: struct {
	valid:      bool,
	std_offset: i64, // seconds east of UTC
	has_dst:    bool,
	dst_offset: i64,
	start:      Posix_Date, // into DST
	end:        Posix_Date, // out of DST
}

// load_tzif reads one zone into a transition list plus its footer rule.
load_tzif :: proc(path: string, allocator := context.allocator) -> (trans: []Transition, initial: i64, rule: Posix_TZ, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(data) < 44 || string(data[0:4]) != "TZif" {
		return
	}
	be32 :: proc(b: []u8) -> i64 {
		return i64(i32(u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])))
	}
	be64 :: proc(b: []u8) -> i64 {
		v: u64
		for i in 0 ..< 8 {
			v = v << 8 | u64(b[i])
		}
		return i64(v)
	}
	Counts :: struct {
		isut, isstd, leap, time, typ, char: int,
	}
	counts :: proc(b: []u8) -> Counts {
		return {
			int(be32(b[20:])), int(be32(b[24:])), int(be32(b[28:])),
			int(be32(b[32:])), int(be32(b[36:])), int(be32(b[40:])),
		}
	}
	version := data[4]
	c := counts(data)
	pos := 44
	tsize := 4
	if version >= '2' {
		// Skip the v1 block and read the 64-bit one.
		pos += c.time * 4 + c.time + c.typ * 6 + c.char + c.leap * 8 + c.isstd + c.isut
		if pos + 44 > len(data) || string(data[pos:pos + 4]) != "TZif" {
			return
		}
		c = counts(data[pos:])
		pos += 44
		tsize = 8
	}
	need := c.time * tsize + c.time + c.typ * 6 + c.char + c.leap * (tsize + 4) + c.isstd + c.isut
	if pos + need > len(data) || c.typ == 0 {
		return
	}
	times := data[pos:]
	idxs := data[pos + c.time * tsize:]
	types := data[pos + c.time * tsize + c.time:]
	type_off :: proc(types: []u8, i: int) -> i64 {
		return be32(types[i * 6:])
	}
	out := make([]Transition, c.time, allocator)
	for i in 0 ..< c.time {
		at := tsize == 8 ? be64(times[i * 8:]) : be32(times[i * 4:])
		ti := int(idxs[i])
		if ti >= c.typ {
			return
		}
		out[i] = Transition{at, type_off(types, ti)}
	}
	// The offset before the first transition: the first non-DST type, as
	// RFC 8536 section 3.2 says, else type 0.
	initial = type_off(types, 0)
	trans = out
	pos += need
	if version >= '2' && pos < len(data) && data[pos] == '\n' {
		end := strings.index_byte(string(data[pos + 1:]), '\n')
		if end > 0 {
			rule = parse_posix_tz(string(data[pos + 1:pos + 1 + end]))
		}
	}
	ok = true
	return
}

// parse_posix_tz reads "CET-1CEST,M3.5.0,M10.5.0/3" and its relatives.
parse_posix_tz :: proc(s: string) -> (r: Posix_TZ) {
	i := 0
	name :: proc(s: string, i: ^int) -> bool {
		if i^ < len(s) && s[i^] == '<' {
			end := strings.index_byte(s[i^:], '>')
			if end < 0 {
				return false
			}
			i^ += end + 1
			return true
		}
		start := i^
		for i^ < len(s) && ((s[i^] >= 'A' && s[i^] <= 'Z') || (s[i^] >= 'a' && s[i^] <= 'z')) {
			i^ += 1
		}
		return i^ - start >= 3
	}
	// [+-]hh[:mm[:ss]] -> seconds
	clock :: proc(s: string, i: ^int) -> (v: i64, ok: bool) {
		sign := i64(1)
		if i^ < len(s) && (s[i^] == '+' || s[i^] == '-') {
			if s[i^] == '-' {
				sign = -1
			}
			i^ += 1
		}
		part :: proc(s: string, i: ^int) -> (int, bool) {
			n, k := 0, 0
			for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
				n = n * 10 + int(s[i^] - '0')
				i^ += 1
				k += 1
			}
			return n, k > 0
		}
		h := part(s, i) or_return
		m, sec := 0, 0
		if i^ < len(s) && s[i^] == ':' {
			i^ += 1
			m = part(s, i) or_return
			if i^ < len(s) && s[i^] == ':' {
				i^ += 1
				sec = part(s, i) or_return
			}
		}
		return sign * i64(h * 3600 + m * 60 + sec), true
	}
	date :: proc(s: string, i: ^int) -> (d: Posix_Date, ok: bool) {
		num :: proc(s: string, i: ^int) -> int {
			n := 0
			for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
				n = n * 10 + int(s[i^] - '0')
				i^ += 1
			}
			return n
		}
		d.time = 7200
		if i^ < len(s) && s[i^] == 'M' {
			i^ += 1
			d.kind = 'M'
			d.month = num(s, i)
			if i^ >= len(s) || s[i^] != '.' {
				return
			}
			i^ += 1
			d.week = num(s, i)
			if i^ >= len(s) || s[i^] != '.' {
				return
			}
			i^ += 1
			d.day = num(s, i)
		} else if i^ < len(s) && s[i^] == 'J' {
			i^ += 1
			d.kind = 'J'
			d.day = num(s, i)
		} else {
			d.kind = 'n'
			d.day = num(s, i)
		}
		if i^ < len(s) && s[i^] == '/' {
			i^ += 1
			d.time = clock(s, i) or_return
		}
		return d, true
	}

	if !name(s, &i) {
		return
	}
	std, ok := clock(s, &i)
	if !ok {
		return
	}
	r.std_offset = -std
	r.valid = true
	if i >= len(s) {
		return
	}
	if !name(s, &i) {
		r.valid = false
		return
	}
	r.has_dst = true
	r.dst_offset = r.std_offset + 3600
	if i < len(s) && s[i] != ',' {
		dst, dok := clock(s, &i)
		if !dok {
			r.valid = false
			return
		}
		r.dst_offset = -dst
	}
	if i < len(s) && s[i] == ',' {
		i += 1
		r.start, ok = date(s, &i)
		if !ok || i >= len(s) || s[i] != ',' {
			r.valid = false
			return
		}
		i += 1
		r.end, ok = date(s, &i)
		if !ok {
			r.valid = false
		}
	} else {
		// The POSIX default, US rules.
		r.start = {kind = 'M', month = 3, week = 2, day = 0, time = 7200}
		r.end = {kind = 'M', month = 11, week = 1, day = 0, time = 7200}
	}
	return
}

// posix_local is the local wall-clock second, in year y, of a rule date.
@(private)
posix_local :: proc(y: int, d: Posix_Date) -> i64 {
	day: i64
	switch d.kind {
	case 'M':
		first := days_from_civil(y, d.month, 1)
		// d.day: 0 = Sunday; weekday_of_days: 0 = Monday.
		want := (d.day + 6) % 7
		off := i64((want - weekday_of_days(first) + 7) % 7)
		day = first + off + i64(d.week - 1) * 7
		dim := i64(days_in_month(y, d.month))
		for day >= first + dim {
			day -= 7
		}
	case 'J':
		n := d.day
		if is_leap(y) && n >= 60 {
			n += 1
		}
		day = days_from_civil(y, 1, 1) + i64(n - 1)
	case:
		day = days_from_civil(y, 1, 1) + i64(d.day)
	}
	return day * 86400 + d.time
}

posix_offset_at :: proc(r: Posix_TZ, unix: i64) -> i64 {
	if !r.has_dst {
		return r.std_offset
	}
	y, _, _ := civil_from_days((unix + r.std_offset) / 86400)
	start := posix_local(y, r.start) - r.std_offset // into DST, in standard time
	end := posix_local(y, r.end) - r.dst_offset // out of DST, in daylight time
	if start < end {
		return unix >= start && unix < end ? r.dst_offset : r.std_offset
	}
	// Southern hemisphere: DST spans the new year.
	return unix >= end && unix < start ? r.std_offset : r.dst_offset
}
