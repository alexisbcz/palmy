// Dates, date-times, durations and time zones.
//
// A DT is a wall-clock reading plus what it is relative to: UTC ("Z"), a
// named zone (TZID), or nothing (floating, which means "in whatever zone the
// reader is in" and is how all-day events are written). Arithmetic on wall
// clocks is done in "local seconds": the reading as if it were UTC. Turning
// local seconds into a real instant needs a Zone.
//
// Zones come from, in order:
//   1. the system's IANA database (/usr/share/zoneinfo) when the TZID names a
//      zone there, after stripping the prefixes some clients add
//      ("/mozilla.org/20050126_1/Europe/Paris", "/citadel.org/.../Europe/X");
//   2. a table of Windows zone names, which Outlook and Exchange write;
//   3. the VTIMEZONE in the object itself, evaluated with the same RRULE
//      engine as events;
//   4. UTC, and the caller is told the zone was not understood.
// IANA wins over an embedded VTIMEZONE when both exist because clients send
// truncated VTIMEZONEs (one rule, no history) and the database is complete.
package ical

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

DT :: struct {
	y, m, d:     int,
	hh, mm, ss:  int,
	is_date:     bool, // VALUE=DATE: no time of day
	utc:         bool,
	tzid:        string, // empty for UTC and floating
}

is_floating :: proc(t: DT) -> bool {
	return !t.utc && t.tzid == ""
}

// ---------------------------------------------------------------------------
// Civil arithmetic (Howard Hinnant's algorithms; see apps/calendar/date.odin)
// ---------------------------------------------------------------------------

days_from_civil :: proc(y0, m, d: int) -> i64 {
	y := i64(y0)
	if m <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mm := i64(m)
	doy := (153 * (mm + (mm > 2 ? -3 : 9)) + 2) / 5 + i64(d) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

civil_from_days :: proc(days: i64) -> (y, m, d: int) {
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	dd := doy - (153 * mp + 2) / 5 + 1
	mo := mp + (mp < 10 ? 3 : -9)
	return int(yy + (mo <= 2 ? 1 : 0)), int(mo), int(dd)
}

is_leap :: proc(y: int) -> bool {
	return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

days_in_month :: proc(y, m: int) -> int {
	switch m {
	case 2:
		return is_leap(y) ? 29 : 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

// weekday: 0 = Monday ... 6 = Sunday.
weekday_of_days :: proc(days: i64) -> int {
	return int(((days + 3) % 7 + 7) % 7)
}

// local_secs is the wall-clock reading as seconds since 1970 "as if UTC".
local_secs :: proc(t: DT) -> i64 {
	return days_from_civil(t.y, t.m, t.d) * 86400 + i64(t.hh * 3600 + t.mm * 60 + t.ss)
}

dt_from_local :: proc(secs: i64, like: DT) -> DT {
	days := secs / 86400
	sod := secs % 86400
	if sod < 0 {
		sod += 86400
		days -= 1
	}
	y, m, d := civil_from_days(days)
	out := like
	out.y, out.m, out.d = y, m, d
	out.hh, out.mm, out.ss = int(sod / 3600), int(sod % 3600 / 60), int(sod % 60)
	if like.is_date {
		out.hh, out.mm, out.ss = 0, 0, 0
	}
	return out
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

digits :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	v := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + int(c - '0')
	}
	return v, true
}

// parse_dt reads "20261020", "20261020T090000", "20261020T090000Z". The
// TZID comes from the property's parameter, not the value.
parse_dt :: proc(s: string, tzid := "") -> (t: DT, ok: bool) {
	v := strings.trim_space(s)
	// Tolerate the extended form some clients write: 2026-10-20T09:00:00.
	if strings.contains(v, "-") || strings.contains(v, ":") {
		b := strings.builder_make(context.temp_allocator)
		for c in transmute([]u8)v {
			if c != '-' && c != ':' {
				strings.write_byte(&b, c)
			}
		}
		v = strings.to_string(b)
	}
	if len(v) < 8 {
		return {}, false
	}
	y, ok1 := digits(v[0:4])
	m, ok2 := digits(v[4:6])
	d, ok3 := digits(v[6:8])
	if !ok1 || !ok2 || !ok3 || m < 1 || m > 12 || d < 1 || d > days_in_month(y, m) {
		return {}, false
	}
	t.y, t.m, t.d = y, m, d
	if len(v) == 8 {
		t.is_date = true
		return t, true
	}
	if len(v) < 15 || v[8] != 'T' {
		return {}, false
	}
	hh, ok4 := digits(v[9:11])
	mm, ok5 := digits(v[11:13])
	ss, ok6 := digits(v[13:15])
	if !ok4 || !ok5 || !ok6 || hh > 23 || mm > 59 || ss > 60 {
		return {}, false
	}
	t.hh, t.mm, t.ss = hh, mm, min(ss, 59)
	rest := v[15:]
	if len(rest) > 0 && rest[0] == '.' {
		// Fractional seconds are not iCalendar, but appear; drop them.
		k := 1
		for k < len(rest) && rest[k] >= '0' && rest[k] <= '9' {
			k += 1
		}
		rest = rest[k:]
	}
	if rest == "Z" || rest == "z" {
		t.utc = true
	} else if rest != "" {
		return {}, false
	}
	if !t.utc {
		t.tzid = tzid
	}
	return t, true
}

// prop_dt reads a DTSTART-like property, honouring VALUE=DATE and TZID.
prop_dt :: proc(p: ^Prop) -> (DT, bool) {
	if p == nil {
		return {}, false
	}
	t, ok := parse_dt(p.value, param(p, "TZID"))
	if ok && strings.equal_fold(param(p, "VALUE"), "DATE") && !t.is_date {
		t.hh, t.mm, t.ss = 0, 0, 0
		t.is_date = true
		t.tzid = ""
		t.utc = false
	}
	return t, ok
}

format_dt :: proc(t: DT, allocator := context.allocator) -> string {
	if t.is_date {
		return strings.clone(tprintf_date(t), allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, tprintf_date(t))
	strings.write_byte(&b, 'T')
	pad2(&b, t.hh)
	pad2(&b, t.mm)
	pad2(&b, t.ss)
	if t.utc {
		strings.write_byte(&b, 'Z')
	}
	return strings.to_string(b)
}

@(private)
tprintf_date :: proc(t: DT) -> string {
	b := strings.builder_make(context.temp_allocator)
	y := t.y
	strings.write_byte(&b, u8('0' + (y / 1000) % 10))
	strings.write_byte(&b, u8('0' + (y / 100) % 10))
	strings.write_byte(&b, u8('0' + (y / 10) % 10))
	strings.write_byte(&b, u8('0' + y % 10))
	pad2(&b, t.m)
	pad2(&b, t.d)
	return strings.to_string(b)
}

@(private)
pad2 :: proc(b: ^strings.Builder, v: int) {
	strings.write_byte(b, u8('0' + (v / 10) % 10))
	strings.write_byte(b, u8('0' + v % 10))
}

// utc_dt is the UTC reading of an instant.
utc_dt :: proc(unix: i64) -> DT {
	return dt_from_local(unix, DT{utc = true})
}

// iso8601 is what Postgres timestamptz accepts.
iso8601 :: proc(unix: i64, allocator := context.allocator) -> string {
	t := utc_dt(unix)
	b := strings.builder_make(allocator)
	y := t.y
	if y < 0 || y > 9999 {
		y = clamp(y, 0, 9999)
	}
	strings.write_byte(&b, u8('0' + (y / 1000) % 10))
	strings.write_byte(&b, u8('0' + (y / 100) % 10))
	strings.write_byte(&b, u8('0' + (y / 10) % 10))
	strings.write_byte(&b, u8('0' + y % 10))
	strings.write_byte(&b, '-')
	pad2(&b, t.m)
	strings.write_byte(&b, '-')
	pad2(&b, t.d)
	strings.write_byte(&b, 'T')
	pad2(&b, t.hh)
	strings.write_byte(&b, ':')
	pad2(&b, t.mm)
	strings.write_byte(&b, ':')
	pad2(&b, t.ss)
	strings.write_byte(&b, 'Z')
	return strings.to_string(b)
}

// parse_iso8601 reads what Postgres returns: "2026-10-20T09:00:00+00:00".
parse_iso8601 :: proc(s: string) -> (unix: i64, ok: bool) {
	if len(s) < 19 {
		return 0, false
	}
	y, a := digits(s[0:4])
	m, b := digits(s[5:7])
	d, c := digits(s[8:10])
	hh, e := digits(s[11:13])
	mm, f := digits(s[14:16])
	ss, g := digits(s[17:19])
	if !(a && b && c && e && f && g) {
		return 0, false
	}
	unix = days_from_civil(y, m, d) * 86400 + i64(hh * 3600 + mm * 60 + ss)
	rest := s[19:]
	if len(rest) > 0 && rest[0] == '.' {
		k := 1
		for k < len(rest) && rest[k] >= '0' && rest[k] <= '9' {
			k += 1
		}
		rest = rest[k:]
	}
	if len(rest) >= 3 && (rest[0] == '+' || rest[0] == '-') {
		oh, _ := digits(rest[1:3])
		om := 0
		if len(rest) >= 6 {
			om, _ = digits(rest[4:6])
		}
		off := i64(oh * 3600 + om * 60)
		unix -= rest[0] == '+' ? off : -off
	}
	return unix, true
}

// parse_duration reads RFC 5545 durations: [+-]P[nW][nD][T[nH][nM][nS]].
parse_duration :: proc(s: string) -> (secs: i64, ok: bool) {
	v := strings.trim_space(s)
	sign := i64(1)
	if len(v) > 0 && (v[0] == '+' || v[0] == '-') {
		if v[0] == '-' {
			sign = -1
		}
		v = v[1:]
	}
	if len(v) < 2 || (v[0] != 'P' && v[0] != 'p') {
		return 0, false
	}
	n := i64(0)
	have := false
	in_time := false
	total := i64(0)
	for c in transmute([]u8)v[1:] {
		switch c {
		case '0' ..= '9':
			n = n * 10 + i64(c - '0')
			have = true
		case 'T', 't':
			in_time = true
		case 'W', 'w':
			total += n * 7 * 86400; n = 0
		case 'D', 'd':
			total += n * 86400; n = 0
		case 'H', 'h':
			total += n * 3600; n = 0
		case 'M', 'm':
			if !in_time {
				return 0, false
			}
			total += n * 60; n = 0
		case 'S', 's':
			total += n; n = 0
		case:
			return 0, false
		}
	}
	if !have {
		return 0, false
	}
	return sign * total, true
}

format_duration :: proc(secs: i64, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	s := secs
	if s < 0 {
		strings.write_byte(&b, '-')
		s = -s
	}
	strings.write_byte(&b, 'P')
	days := s / 86400
	rest := s % 86400
	if days > 0 && days % 7 == 0 && rest == 0 {
		strings.write_i64(&b, days / 7)
		strings.write_byte(&b, 'W')
		return strings.to_string(b)
	}
	if days > 0 {
		strings.write_i64(&b, days)
		strings.write_byte(&b, 'D')
	}
	if rest > 0 || days == 0 {
		strings.write_byte(&b, 'T')
		if rest / 3600 > 0 {
			strings.write_i64(&b, rest / 3600)
			strings.write_byte(&b, 'H')
		}
		if rest % 3600 / 60 > 0 {
			strings.write_i64(&b, rest % 3600 / 60)
			strings.write_byte(&b, 'M')
		}
		if rest % 60 > 0 || rest == 0 {
			strings.write_i64(&b, rest % 60)
			strings.write_byte(&b, 'S')
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Zones
// ---------------------------------------------------------------------------

Zone_Kind :: enum u8 {
	UTC,
	Fixed,
	IANA,
	Defined, // from a VTIMEZONE
}

Transition :: struct {
	at:     i64, // UTC
	offset: i64, // seconds east of UTC, in force from `at`
}

Zone :: struct {
	name:    string,
	kind:    Zone_Kind,
	fixed:   i64,
	rule:    Posix_TZ, // IANA: the footer rule, after the last transition
	trans:   []Transition, // Defined
	initial: i64, // Defined: the offset before the first transition
}

UTC_ZONE := Zone{name = "UTC", kind = .UTC}

// The IANA cache is process-wide and shared between server threads; regions
// are loaded once and kept.
@(private)
g_zone_lock: sync.Mutex
@(private)
g_zones: map[string]^Zone

// zoneinfo_dir can be pointed elsewhere (tests, a distro without tzdata).
zoneinfo_dir := "/usr/share/zoneinfo"

// iana_name normalises a TZID to an IANA name, or "" if none fits.
iana_name :: proc(tzid: string) -> string {
	t := strings.trim_space(tzid)
	if t == "" {
		return ""
	}
	if win, ok := windows_zone(t); ok {
		return win
	}
	if t == "UTC" || t == "GMT" || t == "Etc/UTC" || t == "Z" {
		return "UTC"
	}
	// Try the whole string, then drop leading path segments one at a time.
	rest := strings.trim_left(t, "/")
	for {
		if valid_zone_path(rest) {
			return rest
		}
		slash := strings.index_byte(rest, '/')
		if slash < 0 {
			break
		}
		rest = rest[slash + 1:]
	}
	return ""
}

@(private)
valid_zone_path :: proc(name: string) -> bool {
	if name == "" || strings.contains(name, "..") || strings.contains(name, " ") {
		return false
	}
	path := strings.concatenate({zoneinfo_dir, "/", name}, context.temp_allocator)
	return os.is_file(path)
}

// zone_for resolves a TZID against the IANA database, falling back to the
// object's own VTIMEZONEs (pass the VCALENDAR). ok is false when the zone was
// not understood and UTC was used.
zone_for :: proc(tzid: string, cal: ^Component = nil) -> (z: ^Zone, ok: bool) {
	if tzid == "" {
		return &UTC_ZONE, true
	}
	if name := iana_name(tzid); name != "" {
		if name == "UTC" {
			return &UTC_ZONE, true
		}
		if z, found := iana_zone(name); found {
			return z, true
		}
	}
	if cal != nil {
		for ch in cal.children {
			if ch.name == "VTIMEZONE" && text(ch, "TZID") == tzid {
				if z, good := zone_from_vtimezone(ch); good {
					return z, true
				}
			}
		}
	}
	return &UTC_ZONE, false
}

iana_zone :: proc(name: string) -> (^Zone, bool) {
	sync.mutex_lock(&g_zone_lock)
	defer sync.mutex_unlock(&g_zone_lock)
	if g_zones == nil {
		g_zones = make(map[string]^Zone, 32, runtime.heap_allocator())
	}
	if z, ok := g_zones[name]; ok {
		return z, z != nil
	}
	heap := runtime.heap_allocator()
	path := strings.concatenate({zoneinfo_dir, "/", name}, context.temp_allocator)
	trans, initial, rule, ok := load_tzif(path, heap)
	if !ok {
		g_zones[strings.clone(name, heap)] = nil
		return nil, false
	}
	z := new(Zone, heap)
	z.name = strings.clone(name, heap)
	z.kind = .IANA
	z.trans = trans
	z.initial = initial
	z.rule = rule
	g_zones[z.name] = z
	return z, true
}

// offset_at is the zone's UTC offset at an instant.
offset_at :: proc(z: ^Zone, unix: i64) -> i64 {
	switch z.kind {
	case .UTC:
		return 0
	case .Fixed:
		return z.fixed
	case .IANA, .Defined:
		if z.rule.valid && (len(z.trans) == 0 || unix >= z.trans[len(z.trans) - 1].at) {
			return posix_offset_at(z.rule, unix)
		}
		off := z.initial
		lo, hi := 0, len(z.trans)
		for lo < hi {
			mid := (lo + hi) / 2
			if z.trans[mid].at <= unix {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 {
			off = z.trans[lo - 1].offset
		}
		return off
	}
	return 0
}

// to_utc turns a wall-clock reading in a zone into an instant. In a fold
// (the hour that happens twice) the first occurrence wins; in a gap (the
// hour that does not happen) the reading is pushed forward by the gap,
// which is what RFC 5545 section 3.3.5 asks.
to_utc :: proc(z: ^Zone, local: i64) -> i64 {
	if z.kind == .UTC {
		return local
	}
	if z.kind == .Fixed {
		return local - z.fixed
	}
	before := offset_at(z, local - 86400)
	after := offset_at(z, local + 86400)
	// The earlier instant has the larger offset subtracted.
	cands := [2]i64{before, after}
	if after > before {
		cands = {after, before}
	}
	for o in cands {
		u := local - o
		if offset_at(z, u) == o {
			return u
		}
	}
	// A gap: use the offset in force before it.
	return local - before
}

// instant is the UTC time of a DT; floating and DATE values are read in
// `floating` (the calendar's zone, UTC if none).
instant :: proc(t: DT, cal: ^Component = nil, floating: ^Zone = nil) -> i64 {
	l := local_secs(t)
	if t.utc {
		return l
	}
	if t.tzid != "" {
		z, _ := zone_for(t.tzid, cal)
		return to_utc(z, l)
	}
	if floating != nil {
		return to_utc(floating, l)
	}
	return l
}

// zone_of returns the zone a DT's wall clock runs in.
zone_of :: proc(t: DT, cal: ^Component, floating: ^Zone) -> ^Zone {
	if t.utc {
		return &UTC_ZONE
	}
	if t.tzid != "" {
		z, _ := zone_for(t.tzid, cal)
		return z
	}
	return floating != nil ? floating : &UTC_ZONE
}

// parse_utc_offset reads "+0200", "-0530", "+013000".
parse_utc_offset :: proc(s: string) -> (i64, bool) {
	v := strings.trim_space(s)
	if len(v) < 5 || (v[0] != '+' && v[0] != '-') {
		return 0, false
	}
	h, a := digits(v[1:3])
	m, b := digits(v[3:5])
	sec := 0
	if len(v) >= 7 {
		sec, _ = digits(v[5:7])
	}
	if !a || !b {
		return 0, false
	}
	o := i64(h * 3600 + m * 60 + sec)
	return v[0] == '-' ? -o : o, true
}

// zone_from_vtimezone evaluates STANDARD and DAYLIGHT observances into a
// transition list from their onset to 2100.
zone_from_vtimezone :: proc(vtz: ^Component) -> (^Zone, bool) {
	trans := make([dynamic]Transition, 0, 64)
	initial := i64(0)
	have_initial := false
	earliest := max(i64)
	LIMIT :: i64(4102444800) // 2100-01-01
	for ob in vtz.children {
		if ob.name != "STANDARD" && ob.name != "DAYLIGHT" {
			continue
		}
		from, f_ok := parse_utc_offset(value(ob, "TZOFFSETFROM"))
		to, t_ok := parse_utc_offset(value(ob, "TZOFFSETTO"))
		start, s_ok := prop_dt(prop(ob, "DTSTART"))
		if !f_ok || !t_ok || !s_ok {
			continue
		}
		start.tzid = ""
		start.utc = false
		onset := local_secs(start) - from
		if onset < earliest {
			earliest = onset
			initial = from
			have_initial = true
		}
		append(&trans, Transition{onset, to})
		if rp := prop(ob, "RRULE"); rp != nil {
			if rule, ok := parse_rrule(rp.value); ok {
				it := rrule_iter_make(rule, start)
				for k := 0; k < 400; k += 1 {
					occ, more := rrule_next(&it)
					if !more {
						break
					}
					u := local_secs(occ) - from
					if rule.until_set && rule.until.utc && u > local_secs(rule.until) {
						break
					}
					if u > LIMIT {
						break
					}
					if u != onset {
						append(&trans, Transition{u, to})
					}
				}
			}
		}
		for rd in props(ob, "RDATE") {
			for part in strings.split(rd.value, ",", context.temp_allocator) {
				if t, ok := parse_dt(part); ok {
					append(&trans, Transition{local_secs(t) - from, to})
				}
			}
		}
	}
	if len(trans) == 0 {
		return nil, false
	}
	// Sort by instant (insertion sort: tens to hundreds of entries).
	for i in 1 ..< len(trans) {
		j := i
		for j > 0 && trans[j].at < trans[j - 1].at {
			trans[j], trans[j - 1] = trans[j - 1], trans[j]
			j -= 1
		}
	}
	z := new(Zone)
	z.name = text(vtz, "TZID")
	z.kind = .Defined
	z.trans = trans[:]
	z.initial = have_initial ? initial : trans[0].offset
	return z, true
}

// local_zone_name is the system's zone (for the apps), "UTC" if unknown.
local_zone_name :: proc(allocator := context.allocator) -> string {
	if tz := os.get_env("TZ", context.temp_allocator); tz != "" {
		t := strings.trim_left(tz, ":")
		if iana_name(t) != "" {
			return strings.clone(iana_name(t), allocator)
		}
	}
	target, err := os.read_link("/etc/localtime", context.temp_allocator)
	if err != nil {
		return "UTC"
	}
	if i := strings.index(target, "zoneinfo/"); i >= 0 {
		return strings.clone(target[i + len("zoneinfo/"):], allocator)
	}
	return "UTC"
}

parse_int :: proc(s: string) -> (int, bool) {
	return strconv.parse_int(strings.trim_space(s))
}
