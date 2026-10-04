package main

// RFC 5322 section 3.3 date-time, with the obsolete syntax from 4.3, because
// real mail is full of it.

import "core:fmt"
import "core:strconv"
import "core:strings"

Mail_Date :: struct {
	unix:       i64, // seconds since the epoch, UTC
	tz_minutes: int, // offset east of UTC that the sender claimed
	tz_known:   bool, // false for -0000 and for the obsolete single letters
	ok:         bool,
}

@(private = "file", rodata)
MONTHS := [12]string {
	"jan",
	"feb",
	"mar",
	"apr",
	"may",
	"jun",
	"jul",
	"aug",
	"sep",
	"oct",
	"nov",
	"dec",
}

@(private = "file", rodata)
MONTH_NAMES := [12]string {
	"Jan",
	"Feb",
	"Mar",
	"Apr",
	"May",
	"Jun",
	"Jul",
	"Aug",
	"Sep",
	"Oct",
	"Nov",
	"Dec",
}

@(private = "file", rodata)
DAY_NAMES := [7]string{"Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"} // 1970-01-01 was a Thursday

// days_from_civil is Howard Hinnant's algorithm: days since 1970-01-01 for a
// proleptic Gregorian y/m/d. Valid far outside any date a mailer will produce.
days_from_civil :: proc(y, m, d: int) -> i64 {
	y := y
	y -= m <= 2 ? 1 : 0
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400 // [0, 399]
	doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 // [0, 365]
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy // [0, 146096]
	return i64(era) * 146097 + i64(doe) - 719468
}

civil_from_days :: proc(z_in: i64) -> (y, m, d: int) {
	z := z_in + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	dd := doy - (153 * mp + 2) / 5 + 1
	mm := mp + (mp < 10 ? 3 : -9)
	return int(yy + (mm <= 2 ? 1 : 0)), int(mm), int(dd)
}

// strip_date_comments removes RFC 5322 CFWS comments, which routinely carry a
// redundant zone name: "Mon, 2 Jan 2006 15:04:05 -0700 (MST)".
@(private = "file")
strip_date_comments :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '(') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	depth := 0
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '(':
			depth += 1
		case ')':
			if depth > 0 {depth -= 1}
		case:
			if depth == 0 {strings.write_byte(&sb, s[i])}
		}
	}
	return strings.to_string(sb)
}

// parse_date accepts every shape the RFC permits and several it does not:
//
//	Mon, 2 Jan 2006 15:04:05 -0700
//	2 Jan 2006 15:04 GMT              (no day name, no seconds)
//	Mon, 02 Jan 06 15:04:05 EST       (two-digit year, obsolete zone)
//	Mon, 2 Jan 2006 15:04:05 -0700 (PDT)
//	Mon, 2 Jan 2006 15:04:05 Z        (military zone -> offset unknown)
//
// On failure `ok` is false and `unix` is 0; nothing here can loop or crash.
parse_date :: proc(raw: string) -> (out: Mail_Date) {
	s := strip_date_comments(unfold_header(raw, context.temp_allocator), context.temp_allocator)
	s = strings.trim_space(s)
	if s == "" {
		return
	}

	// A leading day-of-week, with or without the comma.
	if c := strings.index_byte(s, ','); c >= 0 && c <= 9 {
		s = strings.trim_space(s[c + 1:])
	}

	fields := strings.fields(s, context.temp_allocator)
	// Tolerate a day name that was not comma-separated.
	if len(fields) > 0 && len(fields[0]) == 3 && !is_all_digits(fields[0]) {
		if month_index(fields[0]) < 0 {
			fields = fields[1:]
		}
	}
	if len(fields) < 4 {
		return
	}

	day, dok := strconv.parse_int(strings.trim_space(fields[0]), 10)
	if !dok || day < 1 || day > 31 {
		return
	}
	mon := month_index(fields[1])
	if mon < 0 {
		return
	}
	yr, yok := strconv.parse_int(strings.trim_space(fields[2]), 10)
	if !yok {
		return
	}
	// RFC 5322 4.3: two digits 00..49 are 20xx, 50..99 are 19xx; three digits
	// get 1900 added.
	switch len(strings.trim_space(fields[2])) {
	case 1, 2:
		yr += yr <= 49 ? 2000 : 1900
	case 3:
		yr += 1900
	}

	hh, mm, ss := 0, 0, 0
	tparts := strings.split(fields[3], ":", context.temp_allocator)
	if len(tparts) < 2 {
		return
	}
	ok1, ok2: bool
	hh, ok1 = strconv.parse_int(tparts[0], 10)
	mm, ok2 = strconv.parse_int(tparts[1], 10)
	if !ok1 || !ok2 {
		return
	}
	if len(tparts) >= 3 {
		// A leap second (60) is legal in RFC 5322 and clamped here.
		ss, _ = strconv.parse_int(tparts[2], 10)
		if ss == 60 {
			ss = 59
		}
	}
	if hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 59 {
		return
	}

	// The zone is optional in practice; absent means "unknown", i.e. UTC.
	off, known := 0, false
	if len(fields) >= 5 {
		off, known = parse_zone(fields[4])
	}

	out.unix = days_from_civil(yr, mon + 1, day) * 86400 + i64(hh * 3600 + mm * 60 + ss)
	out.unix -= i64(off) * 60
	out.tz_minutes = off
	out.tz_known = known
	out.ok = true
	return
}

@(private = "file")
is_all_digits :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

@(private = "file")
month_index :: proc(s: string) -> int {
	if len(s) < 3 {
		return -1
	}
	m := strings.to_lower(s[:3], context.temp_allocator)
	for name, i in MONTHS {
		if name == m {
			return i
		}
	}
	return -1
}

// parse_zone handles numeric offsets, the four RFC 5322 named zones, the eight
// North American obsolete zones, and the military single letters.
//
// RFC 5322 4.3 is explicit that the military zones were defined backwards in
// RFC 822 and are widely wrong, so they "SHOULD be considered equivalent to
// -0000" — an unknown offset. That is what `tz_known = false` means, and it is
// also what a literal `-0000` means.
parse_zone :: proc(z_in: string) -> (minutes: int, known: bool) {
	z := strings.trim_space(z_in)
	if z == "" {
		return 0, false
	}
	if z[0] == '+' || z[0] == '-' {
		digits := z[1:]
		if len(digits) < 4 || !is_all_digits(digits[:4]) {
			return 0, false
		}
		h, _ := strconv.parse_int(digits[:2], 10)
		m, _ := strconv.parse_int(digits[2:4], 10)
		v := h * 60 + m
		if z[0] == '-' {
			if v == 0 {
				return 0, false // -0000: offset deliberately withheld
			}
			v = -v
		}
		return v, true
	}
	switch strings.to_upper(z, context.temp_allocator) {
	case "UT", "UTC", "GMT", "Z":
		return 0, true
	case "EST":
		return -5 * 60, true
	case "EDT":
		return -4 * 60, true
	case "CST":
		return -6 * 60, true
	case "CDT":
		return -5 * 60, true
	case "MST":
		return -7 * 60, true
	case "MDT":
		return -6 * 60, true
	case "PST":
		return -8 * 60, true
	case "PDT":
		return -7 * 60, true
	}
	if len(z) == 1 {
		c := z[0]
		if (c >= 'A' && c <= 'Z' && c != 'J') || (c >= 'a' && c <= 'z' && c != 'j') {
			return 0, false // military zone: unknown, per RFC 5322 4.3
		}
	}
	return 0, false
}

// format_date renders an RFC 5322 Date: value for an outgoing message.
format_date :: proc(unix: i64, tz_minutes: int, allocator := context.allocator) -> string {
	local := unix + i64(tz_minutes) * 60
	days := local / 86400
	secs := local % 86400
	if secs < 0 {
		secs += 86400
		days -= 1
	}
	y, m, d := civil_from_days(days)
	dow := DAY_NAMES[((days % 7) + 7) % 7]
	sign := tz_minutes < 0 ? "-" : "+"
	az := tz_minutes < 0 ? -tz_minutes : tz_minutes
	return fmt.aprintf(
		"%s, %d %s %d %02d:%02d:%02d %s%02d%02d",
		dow,
		d,
		MONTH_NAMES[m - 1],
		y,
		secs / 3600,
		secs / 60 % 60,
		secs % 60,
		sign,
		az / 60,
		az % 60,
		allocator = allocator,
	)
}

// format_iso8601 is what JMAP uses for its UTCDate type (RFC 8620 1.4).
format_iso8601 :: proc(unix: i64, allocator := context.allocator) -> string {
	days := unix / 86400
	secs := unix % 86400
	if secs < 0 {
		secs += 86400
		days -= 1
	}
	y, m, d := civil_from_days(days)
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		m,
		d,
		secs / 3600,
		secs / 60 % 60,
		secs % 60,
		allocator = allocator,
	)
}

// parse_iso8601 reads a JMAP UTCDate back. Only the `Z` form is accepted,
// which is all RFC 8620 permits for UTCDate.
parse_iso8601 :: proc(s: string) -> (unix: i64, ok: bool) {
	if len(s) < 20 || s[4] != '-' || s[7] != '-' || s[10] != 'T' {
		return 0, false
	}
	y, o1 := strconv.parse_int(s[0:4], 10)
	m, o2 := strconv.parse_int(s[5:7], 10)
	d, o3 := strconv.parse_int(s[8:10], 10)
	hh, o4 := strconv.parse_int(s[11:13], 10)
	mi, o5 := strconv.parse_int(s[14:16], 10)
	ss, o6 := strconv.parse_int(s[17:19], 10)
	if !(o1 && o2 && o3 && o4 && o5 && o6) {
		return 0, false
	}
	if m < 1 || m > 12 || d < 1 || d > 31 {
		return 0, false
	}
	return days_from_civil(y, m, d) * 86400 + i64(hh * 3600 + mi * 60 + ss), true
}
