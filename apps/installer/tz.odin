package main

// The clock on the time zone page: what time it is in the chosen city.
//
// Odin's core:time/timezone parses TZif files, including the POSIX rule at
// the end that covers dates past the last transition (tzdata built "slim"
// has little else). The live system ships tzdata (INSTALLER.md), and the
// same /usr/share/zoneinfo is what the installed system's /etc/localtime
// will point into, so the time shown is the time the new system will keep.

import "core:fmt"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

ZONEINFO :: "/usr/share/zoneinfo"

Zone_Record :: struct {
	utc_offset: i64,
	shortname:  string,
}

load_region :: proc(name: string) -> ^datetime.TZ_Region {
	r, ok := timezone.region_load_from_file(fmt.tprintf("%s/%s", ZONEINFO, name), name)
	if !ok {
		return nil
	}
	return r
}

region_record :: proc(r: ^datetime.TZ_Region, now: time.Time) -> (rec: Zone_Record, ok: bool) {
	utc := time.time_to_datetime(now) or_return
	local := timezone.datetime_to_tz(utc, r) or_return
	lt := time.datetime_to_time(local.date.year, local.date.month, local.date.day, local.time.hour, local.time.minute, local.time.second) or_return
	rec.utc_offset = time.time_to_unix(lt) - time.time_to_unix(now)
	rec.shortname = timezone.shortname(local) or_return
	return rec, true
}

// offset_label renders an offset the way the page shows it: UTC+02:00,
// UTC−03:30 (with a real minus sign), UTC for zero.
offset_label :: proc(secs: i64) -> string {
	if secs == 0 {
		return "UTC"
	}
	s := secs
	sign := "+"
	if s < 0 {
		sign = "−"
		s = -s
	}
	return fmt.tprintf("UTC%s%02d:%02d", sign, s / 3600, (s % 3600) / 60)
}
