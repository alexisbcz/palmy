// Events on disk.
//
// One tab-separated file, ~/.local/share/palmy-calendar/events.tsv, sorted by
// date and start time. A line is:
//
//	YYYY-MM-DD <tab> HH:MM or "-" <tab> minutes <tab> title <tab> location
//
// Tab separation rather than JSON because the file is meant to be readable and
// repairable in any text editor, and because a title can contain anything
// except a tab.
package main

import "core:os"
import "core:strconv"
import "core:strings"

DIR_NAME :: "palmy-calendar"
FILE_NAME :: "events.tsv"

Event :: struct {
	date:  Date,
	start: int, // minutes from midnight, -1 for all day
	mins:  int, // duration in minutes, 0 when unset
	title: string,
	place: string,
}

event_free :: proc(e: Event) {
	delete(e.title)
	delete(e.place)
}

store_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	base := tfmt("%s/.local/share", home)
	if !os.is_dir(base) {
		os.make_directory(base)
	}
	dir := tfmt("%s/%s", base, DIR_NAME)
	if !os.is_dir(dir) {
		os.make_directory(dir)
	}
	return strings.clone(dir)
}

store_path :: proc(dir: string) -> string {
	return tfmt("%s/%s", dir, FILE_NAME)
}

events_load :: proc(dir: string) -> [dynamic]Event {
	out := make([dynamic]Event, 0, 64)
	data, err := os.read_entire_file_from_path(store_path(dir), context.temp_allocator)
	if err != nil {
		return out
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" || t[0] == '#' {
			continue
		}
		cols := strings.split(t, "\t", context.temp_allocator)
		if len(cols) < 4 {
			continue
		}
		date, ok := parse_iso(cols[0])
		if !ok {
			continue
		}
		start := -1
		if cols[1] != "-" && cols[1] != "" {
			if v, good := parse_clock(cols[1]); good {
				start = v
			}
		}
		mins, _ := strconv.parse_int(cols[2])
		e := Event {
			date  = date,
			start = start,
			mins  = mins,
			title = strings.clone(cols[3]),
			place = strings.clone(len(cols) > 4 ? cols[4] : ""),
		}
		append(&out, e)
	}
	events_sort(&out)
	return out
}

events_sort :: proc(list: ^[dynamic]Event) {
	// Insertion sort: a calendar has tens of events, not millions, and this
	// keeps the order stable for entries that share a date and time.
	for i in 1 ..< len(list) {
		j := i
		for j > 0 && event_before(list[j], list[j - 1]) {
			list[j], list[j - 1] = list[j - 1], list[j]
			j -= 1
		}
	}
}

event_before :: proc(a, b: Event) -> bool {
	if !date_eq(a.date, b.date) {
		return date_less(a.date, b.date)
	}
	if a.start != b.start {
		// All-day entries come first, which is how every calendar shows them.
		if a.start < 0 {
			return true
		}
		if b.start < 0 {
			return false
		}
		return a.start < b.start
	}
	return false
}

events_save :: proc(dir: string, list: []Event) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# palmy-calendar\tdate\ttime\tminutes\ttitle\tlocation\n")
	for e in list {
		strings.write_string(&sb, date_iso(e.date))
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, e.start < 0 ? "-" : clock_text(e.start))
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, tfmt("%d", e.mins))
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, sanitise(e.title))
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, sanitise(e.place))
		strings.write_byte(&sb, '\n')
	}
	return os.write_entire_file(store_path(dir), transmute([]u8)strings.to_string(sb)) == nil
}

// sanitise keeps the file's one invariant: a field never contains a tab or a
// newline, because those are what separates the fields and the records.
sanitise :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "\t") && !strings.contains(s, "\n") && !strings.contains(s, "\r") {
		return s
	}
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		strings.write_byte(&sb, c == '\t' || c == '\n' || c == '\r' ? ' ' : c)
	}
	return strings.to_string(sb)
}

// seed writes a handful of entries around today on first run, so the grid is
// not an empty month on the very first launch.
seed_events :: proc(dir: string, now: Date) -> [dynamic]Event {
	out := make([dynamic]Event, 0, 8)
	add :: proc(out: ^[dynamic]Event, d: Date, start, mins: int, title, place: string) {
		append(
			out,
			Event {
				date = d,
				start = start,
				mins = mins,
				title = strings.clone(title),
				place = strings.clone(place),
			},
		)
	}
	add(&out, now, 9 * 60 + 30, 45, "Stand-up", "Jitsi")
	add(&out, now, 14 * 60, 60, "Design review: calendar grid", "Studio")
	add(&out, now, -1, 0, "Pay the electricity bill", "")
	add(&out, date_add(now, 1), 11 * 60, 90, "Lunch with Marta", "Café Vivant")
	add(&out, date_add(now, 3), 18 * 60 + 30, 120, "Odin meetup", "Station F")
	add(&out, date_add(now, -2), 16 * 60, 30, "Dentist", "Rue Lafayette")
	add(&out, date_add(now, 9), -1, 0, "Deadline: parity report", "")
	add(&out, Date{now.y, now.m, min(25, days_in_month(now.y, now.m))}, 20 * 60, 180, "Dinner", "Chez Louis")
	events_sort(&out)
	events_save(dir, out[:])
	return out
}
