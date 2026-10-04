// Calendar — a month grid, a year view and real events, for palmy.
//
// The grid is computed from first principles in date.odin: no `cal`, no
// timezone database, just the civil-date conversions and integer arithmetic,
// which is what makes leap years and ISO week numbers come out right.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

tfmt :: fmt.tprintf

HEADER_H :: 56
STATUS_H :: 26
DAY_W :: 360
WEEKS :: 6
ACCENT :: 0x2563eb

run_cmd :: proc(argv: []string) -> (string, bool) {
	return kit.run(argv, context.temp_allocator)
}

View :: enum {
	Month,
	Year,
}

Pane :: enum {
	Grid,
	Day,
}

Mode :: enum {
	Normal,
	Form,
	Confirm_Delete,
	Help,
}

Field :: enum {
	Date,
	Time,
	Duration,
	Title,
	Place,
}

Form :: struct {
	editing: int, // index into events, -1 for a new one
	field:   Field,
	bufs:    [Field][dynamic]u8,
	err:     string,
}

Cal :: struct {
	dir:      string,
	events:   [dynamic]Event,
	sel:      Date, // the day the cursor is on
	today:    Date,
	now_min:  int,
	tz:       i64,
	view:     View,
	pane:     Pane,
	mode:     Mode,
	ev_sel:   int, // index into the selected day's events
	form:     Form,
	confirm:  bool,
	swallow:  bool,
	toast:    string,
	toast_at: f64,
	want_quit: bool,
	year_sel: int, // month 1..12 highlighted in the year view
}

main :: proc() {
	args := os.args[1:]
	for a, i in args {
		if a == "--selftest" {
			run_selftest()
			os.exit(failures == 0 ? 0 : 1)
		}
		// `--shots <dir>` renders the interface offscreen and writes PNGs,
		// with no window and no compositor. See shot.odin.
		if a == "--shots" || strings.has_prefix(a, "--shots=") {
			dir := ""
			if eq := strings.index_byte(a, '='); eq > 0 {
				dir = a[eq + 1:]
			} else if i + 1 < len(args) {
				dir = args[i + 1]
			}
			if dir == "" {
				fmt.eprintln("calendar --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(dir))
		}
	}

	app, err := kit.start(
		{
			title = "Calendar",
			width = 1240,
			height = 800,
			min_width = 820,
			min_height = 520,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("calendar: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	p.register_color("accent-blue", p.hex(ACCENT))

	c := Cal{}
	c.dir = store_dir()
	c.tz = local_offset()
	c.today, c.now_min = today(c.tz)
	c.sel = c.today
	c.year_sel = c.today.m
	c.form.editing = -1

	c.events = events_load(c.dir)
	if len(c.events) == 0 && !os.exists(store_path(c.dir)) {
		delete(c.events)
		c.events = seed_events(c.dir, c.today)
	}

	for ui in p.frames(app) {
		keys(ui, &c, app)
		frame(ui, &c)
		if c.want_quit {
			p.quit_app(app)
		}
	}
}

note :: proc(c: ^Cal, msg: string) {
	delete(c.toast)
	c.toast = strings.clone(msg)
	c.toast_at = 0
}

// local_offset asks the system for the UTC offset, since the timezone
// database is not linked in.
local_offset :: proc() -> i64 {
	out, ok := run_cmd({"date", "+%z"})
	if !ok || len(out) < 5 {
		return 0
	}
	sign := i64(out[0] == '-' ? -1 : 1)
	h := i64(out[1] - '0') * 10 + i64(out[2] - '0')
	m := i64(out[3] - '0') * 10 + i64(out[4] - '0')
	return sign * (h * 3600 + m * 60)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

day_events :: proc(c: ^Cal, d: Date, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, 8, allocator)
	for e, i in c.events {
		if date_eq(e.date, d) {
			append(&out, i)
		}
	}
	return out[:]
}

day_count :: proc(c: ^Cal, d: Date) -> int {
	n := 0
	for e in c.events {
		if date_eq(e.date, d) {
			n += 1
		}
	}
	return n
}

month_count :: proc(c: ^Cal, y, m: int) -> int {
	n := 0
	for e in c.events {
		if e.date.y == y && e.date.m == m {
			n += 1
		}
	}
	return n
}

selected_event :: proc(c: ^Cal) -> (int, bool) {
	list := day_events(c, c.sel)
	if len(list) == 0 {
		return -1, false
	}
	i := clamp(c.ev_sel, 0, len(list) - 1)
	return list[i], true
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

save :: proc(c: ^Cal) {
	events_sort(&c.events)
	if !events_save(c.dir, c.events[:]) {
		note(c, "Could not write the events file")
	}
}

open_form :: proc(c: ^Cal, editing: int) {
	c.mode = .Form
	c.form.editing = editing
	c.form.field = editing < 0 ? .Title : .Title
	c.form.err = ""
	c.swallow = true

	for f in Field {
		clear(&c.form.bufs[f])
	}
	set :: proc(b: ^[dynamic]u8, s: string) {
		clear(b)
		append(b, ..transmute([]u8)s)
	}
	if editing >= 0 && editing < len(c.events) {
		e := c.events[editing]
		set(&c.form.bufs[.Date], date_iso(e.date))
		set(&c.form.bufs[.Time], e.start < 0 ? "" : clock_text(e.start))
		set(&c.form.bufs[.Duration], e.mins > 0 ? tfmt("%d", e.mins) : "")
		set(&c.form.bufs[.Title], e.title)
		set(&c.form.bufs[.Place], e.place)
	} else {
		set(&c.form.bufs[.Date], date_iso(c.sel))
		set(&c.form.bufs[.Time], "09:00")
		set(&c.form.bufs[.Duration], "60")
	}
}

commit_form :: proc(c: ^Cal) -> bool {
	date, dok := parse_iso(strings.trim_space(string(c.form.bufs[.Date][:])))
	if !dok {
		c.form.err = "The date has to be YYYY-MM-DD and has to exist"
		c.form.field = .Date
		return false
	}
	start, tok := parse_clock(strings.trim_space(string(c.form.bufs[.Time][:])))
	if !tok {
		c.form.err = "The time has to be HH:MM, or empty for an all-day entry"
		c.form.field = .Time
		return false
	}
	mins := 0
	dur := strings.trim_space(string(c.form.bufs[.Duration][:]))
	if dur != "" {
		v := 0
		for i in 0 ..< len(dur) {
			if dur[i] < '0' || dur[i] > '9' {
				c.form.err = "The duration is a whole number of minutes"
				c.form.field = .Duration
				return false
			}
			v = v * 10 + int(dur[i] - '0')
		}
		mins = v
	}
	title := strings.trim_space(string(c.form.bufs[.Title][:]))
	if title == "" {
		c.form.err = "An event needs a title"
		c.form.field = .Title
		return false
	}
	place := strings.trim_space(string(c.form.bufs[.Place][:]))

	if c.form.editing >= 0 && c.form.editing < len(c.events) {
		e := &c.events[c.form.editing]
		delete(e.title)
		delete(e.place)
		e^ = Event {
			date  = date,
			start = start,
			mins  = mins,
			title = strings.clone(title),
			place = strings.clone(place),
		}
		note(c, tfmt("Updated \"%s\"", title))
	} else {
		append(
			&c.events,
			Event {
				date = date,
				start = start,
				mins = mins,
				title = strings.clone(title),
				place = strings.clone(place),
			},
		)
		note(c, tfmt("Added \"%s\"", title))
	}
	c.sel = date
	save(c)
	// Put the cursor on what was just written.
	list := day_events(c, date)
	for idx, k in list {
		if c.events[idx].title == title {
			c.ev_sel = k
			break
		}
	}
	c.mode = .Normal
	return true
}

delete_selected :: proc(c: ^Cal) {
	i, ok := selected_event(c)
	if !ok {
		return
	}
	title := strings.clone(c.events[i].title, context.temp_allocator)
	event_free(c.events[i])
	ordered_remove(&c.events, i)
	save(c)
	c.ev_sel = max(0, c.ev_sel - 1)
	note(c, tfmt("Deleted \"%s\"", title))
}
