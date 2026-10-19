// Calendar — a month grid, a year view and real events, for palmy.
//
// The grid is computed from first principles in date.odin: no `cal`, no
// timezone database, just the civil-date conversions and integer arithmetic,
// which is what makes leap years and ISO week numbers come out right.
//
// Two kinds of calendar share the grid. The one on this device is the
// tab-separated file in store.odin and needs no account. Signed in to a
// Palmframe account, every identity's calendars join it — its own and the
// ones shared with it — synced over CalDAV (cloud.odin), each in its own
// colour, each one switchable on and off in the sidebar.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import ical "../../cloud/dav/ical"

tfmt :: fmt.tprintf

HEADER_H :: 56
STATUS_H :: 26
DAY_W :: 360
SIDE_W :: 232
WEEKS :: 6
ACCENT :: 0x2563eb

run_cmd :: proc(argv: []string) -> (string, bool) {
	return kit.run(argv, context.temp_allocator)
}

p_register :: proc(name: string, color: u32) {
	p.register_color(name, p.hex(color))
}

View :: enum {
	Month,
	Year,
}

Pane :: enum {
	Grid,
	Day,
	Sources,
}

Mode :: enum {
	Normal,
	Form,
	Confirm_Delete,
	Help,
	Sign_In,
	Invites,
}

Field :: enum {
	Date,
	Time,
	Duration,
	Title,
	Place,
	Calendar,
	Repeat,
	Attendees,
}

Form :: struct {
	editing: int, // index into the view, -1 for a new one
	src:     int, // the source the event is (or will be) in
	obj:     string, // its resource name when editing a cloud event
	lidx:    int, // its index in the device list when editing a local one
	recur:   Recur,
	field:   Field,
	bufs:    [Field][dynamic]u8,
	err:     string,
}

Sign_Form :: struct {
	field: int, // 0 email, 1 password
	email: [dynamic]u8,
	pass:  [dynamic]u8,
	err:   string,
	busy:  bool,
}

Cal :: struct {
	dir:        string,
	local:      [dynamic]Event, // the device calendar, as stored
	events:     [dynamic]Event, // what the grid shows: device + cloud, sorted
	view_arena: virtual.Arena,
	view_ready: bool,
	view_year:  int,
	cloud:      Cloud,
	sel:        Date, // the day the cursor is on
	today:      Date,
	now_min:    int,
	tz:         i64,
	view:       View,
	pane:       Pane,
	mode:       Mode,
	ev_sel:     int, // index into the selected day's events
	src_sel:    int, // the sidebar row
	inv_sel:    int,
	form:       Form,
	sign:       Sign_Form,
	confirm:    int, // 0 keep, 1 delete, 2 this occurrence only
	swallow:    bool,
	toast:      string,
	toast_at:   f64,
	want_quit:  bool,
	year_sel:   int, // month 1..12 highlighted in the year view
}

main :: proc() {
	args := os.args[1:]
	for a, i in args {
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
	// Everything else that is not a bare launch is the command line.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	// PALM_THEME=dark, as apps/home reads it.
	dark := os.get_env("PALM_THEME", context.temp_allocator) == "dark"
	app, err := kit.start(
		{
			title = "Calendar",
			width = 1440,
			height = 820,
			min_width = 980,
			min_height = 560,
			root_class = "w-full h-full bg-background text-foreground",
		},
		dark,
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

	c.local = events_load(c.dir)
	if len(c.local) == 0 && !os.exists(store_path(c.dir)) {
		delete(c.local)
		c.local = seed_events(c.dir, c.today)
	}
	cloud_open(&c.cloud, os.get_env("PALM_IDENTITY", context.temp_allocator))
	if c.cloud.signed {
		if _, e := cloud_sync(&c.cloud); e != "" {
			note(&c, tfmt("Working offline: %s", e))
		}
	}
	register_source_colors(&c.cloud)
	rebuild_view(&c)

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
// The view: device entries and cloud instances, for the year on screen
// ---------------------------------------------------------------------------

rebuild_view :: proc(c: ^Cal) {
	if c.view_ready {
		virtual.arena_destroy(&c.view_arena)
	}
	_ = virtual.arena_init_growing(&c.view_arena)
	c.view_ready = true
	alloc := virtual.arena_allocator(&c.view_arena)
	c.view_year = c.sel.y
	c.events = make([dynamic]Event, 0, 128, alloc)
	if len(c.cloud.sources) == 0 || c.cloud.sources[0].visible {
		for e, i in c.local {
			v := e
			v.title = strings.clone(e.title, alloc)
			v.place = strings.clone(e.place, alloc)
			v.src = 0
			v.lidx = i
			append(&c.events, v)
		}
	}
	// The year in view, with a month of margin either side for the grid's
	// leading and trailing weeks.
	from := Date{c.sel.y - 1, 12, 1}
	to := Date{c.sel.y + 1, 2, 1}
	cloud := cloud_events(&c.cloud, from, to, alloc)
	for e in cloud {
		if c.cloud.sources[e.src].visible {
			append(&c.events, e)
		}
	}
	events_sort(&c.events)
}

// ensure_view rebuilds when the cursor leaves the expanded year.
ensure_view :: proc(c: ^Cal) {
	if c.sel.y != c.view_year {
		rebuild_view(c)
	}
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

// writable_sources lists the sources a new event may go to.
writable_sources :: proc(c: ^Cal, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, 4, allocator)
	for &s, i in c.cloud.sources {
		if writable(&s) && s.events_ok {
			append(&out, i)
		}
	}
	return out[:]
}

// default_source: the first owned calendar of the session's first identity,
// else this device.
default_source :: proc(c: ^Cal) -> int {
	for ident in c.cloud.idents {
		if i := target_source(&c.cloud, ident.handle); i >= 0 {
			return i
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

save :: proc(c: ^Cal) {
	events_sort(&c.local)
	if !events_save(c.dir, c.local[:]) {
		note(c, "Could not write the events file")
	}
}

@(private = "file")
set_buf :: proc(b: ^[dynamic]u8, s: string) {
	clear(b)
	append(b, ..transmute([]u8)s)
}

open_form :: proc(c: ^Cal, editing: int) {
	c.mode = .Form
	c.form.editing = editing
	c.form.field = .Title
	c.form.err = ""
	c.form.recur = .None
	c.form.obj = ""
	c.form.lidx = -1
	c.swallow = true

	for f in Field {
		clear(&c.form.bufs[f])
	}
	if editing >= 0 && editing < len(c.events) {
		e := c.events[editing]
		c.form.src = e.src
		c.form.lidx = e.lidx
		delete(c.form.obj)
		c.form.obj = strings.clone(e.obj)
		date := e.date
		if e.src > 0 {
			// Editing a recurring event edits the series: show its first date.
			if o := find_obj(&c.cloud.sources[e.src], e.obj); o != nil {
				master, _ := ical.masters_and_overrides(o.cal, "VEVENT")
				if master != nil {
					c.form.recur = recur_of(ical.value(master, "RRULE"))
					if t, ok := ical.prop_dt(ical.prop(master, "DTSTART")); ok && e.recurring {
						if t.is_date {
							date = Date{t.y, t.m, t.d}
						} else {
							date, _ = to_local(&c.cloud, ical.instant(t, o.cal, c.cloud.zone))
						}
					}
				}
			}
		}
		set_buf(&c.form.bufs[.Date], date_iso(date))
		set_buf(&c.form.bufs[.Time], e.start < 0 ? "" : clock_text(e.start))
		set_buf(&c.form.bufs[.Duration], e.mins > 0 ? tfmt("%d", e.mins) : "")
		set_buf(&c.form.bufs[.Title], e.title)
		set_buf(&c.form.bufs[.Place], e.place)
		people := people_of(&c.cloud, e.src, e.obj)
		list := make([dynamic]string, 0, len(people), context.temp_allocator)
		for pp in people {
			if !pp.organizer {
				append(&list, pp.address)
			}
		}
		set_buf(&c.form.bufs[.Attendees], strings.join(list[:], ", ", context.temp_allocator))
	} else {
		c.form.src = default_source(c)
		set_buf(&c.form.bufs[.Date], date_iso(c.sel))
		set_buf(&c.form.bufs[.Time], "09:00")
		set_buf(&c.form.bufs[.Duration], "60")
	}
}

// field_editable: choice fields are cycled, not typed; attendees and
// repetition only exist for cloud calendars.
field_editable :: proc(c: ^Cal, f: Field) -> bool {
	if f == .Calendar {
		return c.form.editing < 0
	}
	if f == .Repeat || f == .Attendees {
		return c.form.src > 0
	}
	return true
}

cycle_source :: proc(c: ^Cal, by: int) {
	list := writable_sources(c)
	if len(list) == 0 {
		return
	}
	at := 0
	for s, i in list {
		if s == c.form.src {
			at = i
		}
	}
	c.form.src = list[(at + by + len(list)) % len(list)]
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

	if c.form.src > 0 {
		return commit_cloud(c, date, start, mins, title, place)
	}

	if c.form.editing >= 0 && c.form.lidx >= 0 && c.form.lidx < len(c.local) {
		e := &c.local[c.form.lidx]
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
		append(&c.local, Event{date = date, start = start, mins = mins, title = strings.clone(title), place = strings.clone(place)})
		note(c, tfmt("Added \"%s\"", title))
	}
	c.sel = date
	save(c)
	after_change(c, title)
	return true
}

@(private = "file")
commit_cloud :: proc(c: ^Cal, date: Date, start, mins: int, title, place: string) -> bool {
	src := &c.cloud.sources[c.form.src]
	if !writable(src) {
		c.form.err = tfmt("\"%s\" is shared with you read-only", src.name)
		return false
	}
	atts := make([dynamic]string, 0, 4, context.temp_allocator)
	for piece in strings.split(string(c.form.bufs[.Attendees][:]), ",", context.temp_allocator) {
		a := strings.trim_space(piece)
		if a == "" {
			continue
		}
		if !strings.contains(a, "@") {
			// A bare handle means a Palmframe identity.
			a = tfmt("%s@%s", a, mail_domain())
		}
		append(&atts, a)
	}
	dr := Draft {
		date      = date,
		start     = start,
		mins      = mins,
		title     = title,
		place     = place,
		rrule     = RECUR_RULES[c.form.recur],
		attendees = atts[:],
		organizer = src.handle,
	}
	msg := ""
	if c.form.editing >= 0 && c.form.obj != "" {
		msg = cloud_edit(&c.cloud, c.form.src, c.form.obj, dr)
		note(c, msg != "" ? msg : tfmt("Updated \"%s\" in %s", title, src.name))
	} else {
		_, msg = cloud_create(&c.cloud, c.form.src, dr)
		if msg == "" && len(atts) > 0 {
			note(c, tfmt("Invited %d · \"%s\" in %s", len(atts), title, src.name))
		} else {
			note(c, msg != "" ? msg : tfmt("Added \"%s\" to %s", title, src.name))
		}
	}
	c.sel = date
	after_change(c, title)
	return true
}

after_change :: proc(c: ^Cal, title: string) {
	rebuild_view(c)
	list := day_events(c, c.sel)
	for idx, k in list {
		if c.events[idx].title == title {
			c.ev_sel = k
			break
		}
	}
	c.mode = .Normal
}

delete_selected :: proc(c: ^Cal, only_this: bool) {
	i, ok := selected_event(c)
	if !ok {
		return
	}
	e := c.events[i]
	title := strings.clone(e.title, context.temp_allocator)
	if e.src > 0 {
		msg := ""
		if only_this && e.recurring {
			msg = cloud_delete(&c.cloud, e.src, e.obj, e.rid)
		} else {
			msg = cloud_delete(&c.cloud, e.src, e.obj)
		}
		if msg != "" {
			note(c, msg)
		} else {
			note(c, only_this ? tfmt("Removed one \"%s\"", title) : tfmt("Deleted \"%s\"", title))
		}
	} else if e.lidx >= 0 && e.lidx < len(c.local) {
		event_free(c.local[e.lidx])
		ordered_remove(&c.local, e.lidx)
		save(c)
		note(c, tfmt("Deleted \"%s\"", title))
	}
	rebuild_view(c)
	c.ev_sel = max(0, c.ev_sel - 1)
}

do_sync :: proc(c: ^Cal) {
	if !c.cloud.signed {
		c.mode = .Sign_In
		c.swallow = true
		return
	}
	rep, err := cloud_sync(&c.cloud)
	register_source_colors(&c.cloud)
	rebuild_view(c)
	if err != "" {
		note(c, tfmt("Offline: %s", err))
	} else if rep.invitations > 0 {
		note(c, tfmt("Synced · %d invitation%s waiting (V)", rep.invitations, rep.invitations == 1 ? "" : "s"))
	} else {
		note(c, tfmt("Synced · %d up, %d down", rep.pushed, rep.pulled + rep.removed))
	}
}

do_sign_in :: proc(c: ^Cal) {
	email := strings.trim_space(string(c.sign.email[:]))
	pass := string(c.sign.pass[:])
	if email == "" || pass == "" {
		c.sign.err = "Both the email and the password are needed"
		return
	}
	if e := cloud_sign_in(&c.cloud, email, pass); e != "" {
		c.sign.err = strings.clone(e)
		return
	}
	clear(&c.sign.pass)
	c.mode = .Normal
	do_sync(c)
}
