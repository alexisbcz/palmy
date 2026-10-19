// clock.odin — local time, for the bar's clock.
//
// The kernel keeps UTC; the time zone is a file. Palmy's installer points
// /etc/localtime at ../usr/share/zoneinfo/<Region/City> (tzdata's TZif files),
// and everything that shows a time to a person has to go through it — a bar
// that says 14:05 in Paris when it is 16:05 there is wrong, not "in UTC".
//
// glibc's localtime_r would read the same file, but glibc decides once per
// process whether /etc/localtime is worth re-reading and does not notice the
// link being repointed. The live installer does exactly that while wm is
// running, so the zone is loaded here with core:time/timezone's TZif parser
// (transitions, then the POSIX rule in the footer for dates past the table)
// and loaded again whenever the link or the file under it changes.
//
// TZ, when set, wins, as it does for every other program: `TZ=Asia/Tokyo` or
// `TZ=:Asia/Tokyo` names a file under /usr/share/zoneinfo, `TZ=/path` a file.
// Anything unreadable means UTC, logged once, never a missing clock.
package wm

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

CLOCK_LOCALTIME :: "/etc/localtime"
CLOCK_ZONEINFO :: "/usr/share/zoneinfo"

Clock :: struct {
	region:     ^datetime.TZ_Region,
	name:       string, // "Europe/Paris", or the path when it is not under zoneinfo
	sig:        string, // what the file looked like when it was loaded
	checked_at: f64,
	warned:     bool,
}

clock: Clock

// clock_source is the file to read and the zone's name for the log.
clock_source :: proc() -> (path: string, name: string) {
	tz := os.get_env("TZ", context.temp_allocator)
	if strings.has_prefix(tz, ":") {
		tz = tz[1:]
	}
	switch {
	case tz == "":
		path = CLOCK_LOCALTIME
	case strings.has_prefix(tz, "/"):
		path = tz
	case !strings.contains(tz, ".."):
		path = fmt.tprintf("%s/%s", CLOCK_ZONEINFO, tz)
	case:
		path = CLOCK_LOCALTIME
	}
	name = path
	// The link's target says which zone it is: ../usr/share/zoneinfo/Europe/Paris.
	target := path
	buf: [512]u8
	if n, err := linux.readlink(strings.clone_to_cstring(path, context.temp_allocator), buf[:]); err == .NONE && n > 0 {
		target = strings.clone(string(buf[:n]), context.temp_allocator)
	}
	if i := strings.index(target, "zoneinfo/"); i >= 0 {
		name = target[i + len("zoneinfo/"):]
	}
	return
}

// clock_file_sig changes when the link is repointed or the file is replaced.
clock_file_sig :: proc(path: string) -> string {
	buf: [512]u8
	link := ""
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if n, err := linux.readlink(cpath, buf[:]); err == .NONE {
		link = string(buf[:n])
	}
	st: linux.Stat
	if linux.stat(cpath, &st) != .NONE {
		return fmt.tprintf("%s|missing", link)
	}
	return fmt.tprintf("%s|%d|%d|%d.%d", link, u64(st.ino), i64(st.size), i64(st.mtime.time_sec), i64(st.mtime.time_nsec))
}

// clock_load reads the zone afresh. Called at most every few seconds.
clock_load :: proc() {
	path, name := clock_source()
	sig := clock_file_sig(path)
	if sig == clock.sig && clock.sig != "" {
		return
	}
	if clock.region != nil {
		timezone.region_destroy(clock.region)
		clock.region = nil
	}
	delete(clock.sig)
	clock.sig = strings.clone(sig)
	delete(clock.name)
	clock.name = ""

	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		if !clock.warned && path != CLOCK_LOCALTIME {
			fmt.eprintfln("wm: clock: cannot read %s; showing UTC", path)
		}
		clock.warned = true
		clock.name = strings.clone("UTC")
		return
	}
	reg, ok := timezone.region_load_from_buffer(data, name)
	if !ok {
		fmt.eprintfln("wm: clock: %s is not a TZif file; showing UTC", path)
		clock.name = strings.clone("UTC")
		return
	}
	clock.region = reg
	clock.name = strings.clone(name)
	clock.warned = false
	fmt.printfln("wm: clock: time zone %s", clock.name)
}

// clock_offset is the zone's UTC offset in seconds at `t`, with the
// abbreviation in force then (CET, CEST, JST, +0530 ...).
clock_offset :: proc(region: ^datetime.TZ_Region, t: time.Time) -> (secs: i64, abbr: string) {
	if region == nil {
		return 0, "UTC"
	}
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return 0, "UTC"
	}
	local, lok := timezone.datetime_to_tz(dt, region)
	if !lok {
		return 0, "UTC"
	}
	lt, tok := time.datetime_to_time(local)
	if !tok {
		return 0, "UTC"
	}
	return time.to_unix_seconds(lt) - time.to_unix_seconds(t), timezone.shortname_unsafe(local)
}

// clock_now is the local wall time as a time.Time whose "UTC" fields read as
// local ones, which is all time.clock_from_time and friends need.
clock_now :: proc() -> (local: time.Time, abbr: string) {
	if now := wall_now(); clock.sig == "" || now - clock.checked_at >= 5 {
		clock.checked_at = now
		clock_load()
	}
	t := time.now()
	off, a := clock_offset(clock.region, t)
	return time.time_add(t, time.Duration(off) * time.Second), a
}

WEEKDAYS := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// clock_text is what the bar shows: "Tue 13 Oct  16:05".
clock_text :: proc(local: time.Time) -> string {
	h, m, _ := time.clock_from_time(local)
	_, mon, d := time.date(local)
	wd := int(time.weekday(local))
	return fmt.tprintf("%s %d %s  %02d:%02d", WEEKDAYS[wd % 7], d, MONTHS[(int(mon) - 1) % 12], h, m)
}

// ---------------------------------------------------------------------------
// Self test: offsets against tzdata itself, for zones that exercise the cases
// — DST both ways, a half-hour zone, a half-hour DST shift, past the end of
// the transition table into the POSIX rule.
// ---------------------------------------------------------------------------

clock_selftest :: proc() -> int {
	fmt.println("clock self test")
	fmt.println()
	pass, fail := 0, 0
	check :: proc(pass, fail: ^int, ok: bool, format: string, args: ..any) {
		if ok {pass^ += 1; fmt.printf("  ok    ")} else {fail^ += 1; fmt.printf("  FAIL  ")}
		fmt.printf(format, ..args)
		fmt.println()
	}
	if !os.exists(CLOCK_ZONEINFO + "/Europe/Paris") {
		fmt.printfln("  (skipping: no %s)", CLOCK_ZONEINFO)
		return 0
	}
	Case :: struct {
		zone: string,
		unix: i64,
		off:  i64,
		abbr: string,
	}
	cases := [?]Case {
		{"Europe/Paris", 1767225600, 3600, "CET"}, // 2026-01-01
		{"Europe/Paris", 1782864000, 7200, "CEST"}, // 2026-07-01
		{"America/New_York", 1782864000, -4 * 3600, "EDT"},
		{"America/New_York", 4102444800, -5 * 3600, "EST"}, // 2100: the POSIX rule
		{"Asia/Kolkata", 1782864000, 5 * 3600 + 1800, "IST"},
		{"Australia/Lord_Howe", 1782864000, 10 * 3600 + 1800, "+1030"},
		{"Australia/Lord_Howe", 1767225600, 11 * 3600, "+11"},
		{"Asia/Tokyo", 1782864000, 9 * 3600, "JST"},
		{"UTC", 1782864000, 0, "UTC"},
	}
	for c in cases {
		data, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s", CLOCK_ZONEINFO, c.zone), context.temp_allocator)
		if err != nil {
			check(&pass, &fail, false, "%s: unreadable", c.zone)
			continue
		}
		reg, ok := timezone.region_load_from_buffer(data, c.zone)
		if !ok {
			check(&pass, &fail, false, "%s: not parsed", c.zone)
			continue
		}
		off, abbr := clock_offset(reg, time.unix(c.unix, 0))
		check(&pass, &fail, off == c.off && abbr == c.abbr, "%s at %d: %+d s %s (want %+d %s)", c.zone, c.unix, off, abbr, c.off, c.abbr)
		timezone.region_destroy(reg)
	}

	// TZ steers it, and the text is the local time.
	saved := strings.clone(os.get_env("TZ", context.temp_allocator))
	defer {if saved != "" {os.set_env("TZ", saved)} else {os.unset_env("TZ")}}
	os.set_env("TZ", ":Asia/Kolkata")
	path, name := clock_source()
	check(&pass, &fail, path == CLOCK_ZONEINFO + "/Asia/Kolkata" && name == "Asia/Kolkata", "TZ=:Asia/Kolkata reads %s, named %s", path, name)
	clock.sig = ""
	clock_load()
	off, _ := clock_offset(clock.region, time.unix(1782864000, 0))
	check(&pass, &fail, off == 19800, "and the loaded zone is +05:30, got %+d", off)
	lt := time.time_add(time.unix(1782864000, 0), time.Duration(off) * time.Second)
	txt := clock_text(lt)
	check(&pass, &fail, txt == "Wed 1 Jul  05:30", "the bar text for 2026-07-01 00:00 UTC there: %q", txt)
	os.set_env("TZ", "Nowhere/Atlantis")
	clock.sig = ""
	clock_load()
	check(&pass, &fail, clock.region == nil && clock.name == "UTC", "an unknown zone is UTC, not a missing clock (%q)", clock.name)
	clock.sig = ""
	if clock.region != nil {
		timezone.region_destroy(clock.region)
		clock.region = nil
	}

	fmt.println()
	fmt.printf("clock: %d passed, %d failed\n", pass, fail)
	return fail
}
