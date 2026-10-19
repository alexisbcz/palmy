// `calendar --shots <dir>`: render the interface offscreen and write PNGs,
// light and dark.
//
// No compositor, no window, no account and no server: the same `keys` and
// the same `frame` the window runs, through palmy's offscreen renderer, on
// invented data. The cloud calendars are real local copies in a scratch
// directory under the output (fixture.odin), read through the same cache
// and parser a synced app uses — three identities overlaid in one grid:
// Alice's personal calendar (indigo), her work identity (emerald) and a
// calendar Bob shares with her read-only (amber). Nobody's real calendar can
// reach a picture.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1440
SHOT_H :: 820

// A fixed Wednesday, so the grid, the week numbers and the "today" ring come
// out the same on every run.
SHOT_TODAY :: Date{2026, 10, 21}
SHOT_NOW_MIN :: 10*60 + 25

// shot_fonts loads exactly what `kit.start` gives a window, into the
// offscreen font table: a screenshot in a different face proves nothing.
shot_fonts :: proc(off: ^p.Offscreen, dark: bool) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	theme(dark)
}

@(private = "file")
theme :: proc(dark: bool) {
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
	p.register_color("accent-blue", p.hex(ACCENT))
}

// shot_cloud lays down the three identities' calendars.
@(private = "file")
shot_cloud :: proc(cl: ^Cloud, dir: string) {
	fixture_begin(cl, "Europe/Paris")
	cl.signed = true
	cl.online = true
	cl.fixture = true
	cl.email = "alice@example.test"
	cl.status = "synced 08:24 UTC · 0 up, 17 down"
	fixture_ident(cl, "alice", "Alice Martin", "personal", "indigo")
	fixture_ident(cl, "alice-work", "Alice (Northwind)", "work", "emerald")
	me := fixture_source(cl, dir, "alice", "default", "Personal", "#6366f1", "owner", "alice")
	work := fixture_source(cl, dir, "alice-work", "default", "Northwind", "#10b981", "owner", "alice-work")
	bob := fixture_source(cl, dir, "alice", "bob~default", "Bob's calendar", "#f59e0b", "read", "bob")

	fixture_put(cl, me, "swim.ics", vevent("swim", "20261006T073000", "20261006T081500", "Swim",
		"LOCATION:Piscine Pontoise\r\nRRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\n"))
	fixture_put(cl, me, "marta.ics", vevent("marta", "20261023T200000", "20261023T223000", "Dinner with Marta",
		"LOCATION:Chez Louis\r\n"))
	fixture_put(cl, me, "bday.ics", vevent("bday", "20261027", "20261028", "Marta's birthday", "RRULE:FREQ=YEARLY\r\n"))
	fixture_put(cl, me, "games.ics", vevent("games", "20261030T190000", "20261030T230000", "Board game night",
		"LOCATION:Bob's place\r\nORGANIZER;CN=Bob:mailto:bob@palm.test\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:bob@palm.test\r\nATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alice@palm.test\r\n"))

	fixture_put(cl, work, "planning.ics", vevent("planning", "20261007T100000", "20261007T104500", "Weekly planning",
		"LOCATION:Northwind, room 4\r\nRRULE:FREQ=WEEKLY;COUNT=12\r\nEXDATE;TZID=Europe/Paris:20261028T100000\r\n" +
		"ORGANIZER;CN=Alice:mailto:alice-work@palm.test\r\nATTENDEE;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:alice-work@palm.test\r\n" +
		"ATTENDEE;PARTSTAT=ACCEPTED:mailto:bob@palm.test\r\nATTENDEE;PARTSTAT=TENTATIVE:mailto:dana@northwind.example\r\n" +
		"ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:carol@example.com\r\n"))
	fixture_put(cl, work, "standup.ics", vevent("standup", "20261005T093000", "20261005T094500", "Stand-up",
		"RRULE:FREQ=WEEKLY;BYDAY=MO,FR\r\n"))
	fixture_put(cl, work, "review.ics", vevent("review", "20261021T140000", "20261021T153000", "Quarterly review",
		"LOCATION:Board room\r\n"))
	fixture_put(cl, work, "vendor.ics", vevent("vendor", "20261022T160000", "20261022T170000", "Vendor demo",
		"ORGANIZER:mailto:dana@northwind.example\r\nATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alice-work@palm.test\r\n"))
	fixture_put(cl, work, "offsite.ics", vevent("offsite", "20261112", "20261114", "Team offsite"))

	fixture_put(cl, bob, "climb.ics", vevent("climb", "20261005T183000", "20261005T203000", "Climbing",
		"LOCATION:Arkose\r\nRRULE:FREQ=WEEKLY;BYDAY=MO\r\n"))
	fixture_put(cl, bob, "away.ics", vevent("away", "20261015", "20261018", "Bob away"))
	fixture_end(cl)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("calendar --shots: cannot create %s", dir)
		return 1
	}
	n := 0
	for dark in ([2]bool{false, true}) {
		n += shot_set(dir, dark)
	}
	fmt.printfln("calendar --shots: %d PNGs in %s", n, dir)
	return 0
}

@(private = "file")
shot_set :: proc(dir: string, dark: bool) -> int {
	// Private stores under the output directory. The real events file and
	// the real DAV cache are never read or written.
	store := strings.clone(fmt.tprintf("%s/.store/palmy-calendar", dir))
	cache := strings.clone(fmt.tprintf("%s/.store/dav", dir))
	_ = os.make_directory_all(store, os.perm(0o700))

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, dark)

	c := Cal{}
	c.dir = store
	c.tz = 0
	c.today = SHOT_TODAY
	c.now_min = SHOT_NOW_MIN
	c.sel = c.today
	c.year_sel = c.today.m
	c.form.editing = -1
	c.local = seed_events(c.dir, c.today)
	shot_cloud(&c.cloud, cache)
	c.cloud.sources[0].visible = false // the overlay is about the identities
	register_source_colors(&c.cloud)
	rebuild_view(&c)

	suffix := dark ? "-dark" : ""
	n := 0
	step :: proc(off: ^p.Offscreen, c: ^Cal) {
		ui := p.offscreen_begin(off)
		keys(ui, c, nil)
		frame(ui, c)
		p.offscreen_end(off)
	}
	// Hover and hit testing run against the previous frame, so the settled
	// picture is never the first one.
	settle :: proc(off: ^p.Offscreen, c: ^Cal, n := 3) {
		for _ in 0 ..< n {
			step(off, c)
		}
	}
	shot :: proc(off: ^p.Offscreen, dir, name, suffix: string, n: ^int) {
		path := fmt.tprintf("%s/%s%s.png", dir, name, suffix)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}
	select :: proc(c: ^Cal, title: string) {
		for idx, k in day_events(c, c.sel) {
			if c.events[idx].title == title {
				c.ev_sel = k
			}
		}
	}

	// 1. The month: three identities overlaid, today's planning meeting open
	//    with its attendees and their answers.
	c.pane = .Day
	select(&c, "Weekly planning")
	settle(off, &c)
	shot(off, dir, "calendar-month", suffix, &n)

	// 2. The sidebar in use: the device calendar hidden, Bob's read-only
	//    share under the cursor.
	c.pane = .Sources
	c.src_sel = 3
	c.sel = Date{2026, 10, 16}
	c.ev_sel = 0
	settle(off, &c)
	shot(off, dir, "calendar-sidebar", suffix, &n)

	// 3. A new event: a work calendar, repeating weekly, with invitations.
	c.pane = .Grid
	c.sel = Date{2026, 10, 22}
	open_form(&c, -1)
	c.form.src = target_source(&c.cloud, "alice-work")
	c.form.recur = .Weekly
	set :: proc(b: ^[dynamic]u8, s: string) {
		clear(b)
		append(b, ..transmute([]u8)s)
	}
	set(&c.form.bufs[.Title], "Design crit")
	set(&c.form.bufs[.Time], "15:00")
	set(&c.form.bufs[.Duration], "45")
	set(&c.form.bufs[.Place], "Studio")
	set(&c.form.bufs[.Attendees], "bob, dana@northwind.example")
	c.form.field = .Attendees
	settle(off, &c)
	shot(off, dir, "calendar-new-event", suffix, &n)
	c.mode = .Normal

	// 4. Invitations across identities.
	c.mode = .Invites
	c.inv_sel = 0
	settle(off, &c)
	shot(off, dir, "calendar-invitations", suffix, &n)
	c.mode = .Normal

	// 5. The year, which counts every visible calendar's entries.
	c.view = .Year
	c.sel = SHOT_TODAY
	settle(off, &c)
	shot(off, dir, "calendar-year", suffix, &n)
	c.view = .Month

	// 6. Signed out: the device calendar alone, and the sign-in sheet.
	signed_out := Cal{}
	signed_out.dir = store
	signed_out.today = SHOT_TODAY
	signed_out.now_min = SHOT_NOW_MIN
	signed_out.sel = SHOT_TODAY
	signed_out.year_sel = 10
	signed_out.form.editing = -1
	signed_out.local = c.local
	append(&signed_out.cloud.sources, c.cloud.sources[0])
	signed_out.cloud.sources[0].visible = true
	register_source_colors(&signed_out.cloud)
	rebuild_view(&signed_out)
	signed_out.mode = .Sign_In
	set(&signed_out.sign.email, "alice@example.test")
	set(&signed_out.sign.pass, "correct horse")
	signed_out.sign.field = 1
	settle(off, &signed_out)
	shot(off, dir, "calendar-sign-in", suffix, &n)

	// 7. The keyboard sheet.
	c.mode = .Help
	register_source_colors(&c.cloud)
	settle(off, &c)
	shot(off, dir, "calendar-keys", suffix, &n)
	return n
}
