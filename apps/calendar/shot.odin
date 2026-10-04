// `calendar --shots <dir>`: render the interface offscreen and write PNGs.
//
// No compositor and no window: the same `keys` and the same `frame` the window
// runs, through palmy's offscreen renderer. The date is pinned and the events
// are the invented fixtures from `seed_events`, written into a private store
// under the output directory, so a capture is deterministic and nobody's real
// calendar can reach a picture.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1240
SHOT_H :: 800

// A fixed Wednesday, so the grid, the week numbers and the "today" ring come
// out the same on every run.
SHOT_TODAY :: Date{2026, 3, 18}
SHOT_NOW_MIN :: 10*60 + 25

// shot_fonts loads exactly what `kit.start` gives a window, into the
// offscreen font table: a screenshot in a different face proves nothing.
shot_fonts :: proc(off: ^p.Offscreen) {
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
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("accent-blue", p.hex(ACCENT))
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("calendar --shots: cannot create %s", dir)
		return 1
	}
	// A private store under the output directory. The real events file is
	// never read and never written.
	store := strings.clone(fmt.tprintf("%s/.store/palmy-calendar", dir))
	defer delete(store)
	_ = os.make_directory_all(store, os.perm(0o700))

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(off)

	c := Cal{}
	c.dir = strings.clone(store)
	c.tz = 0
	c.today = SHOT_TODAY
	c.now_min = SHOT_NOW_MIN
	c.sel = c.today
	c.year_sel = c.today.m
	c.form.editing = -1
	c.events = seed_events(c.dir, c.today)
	// A couple more, so the month is not three days of entries in an empty
	// grid. All invented.
	more :: proc(c: ^Cal, d: Date, start, mins: int, title, place: string) {
		append(
			&c.events,
			Event {
				date = d,
				start = start,
				mins = mins,
				title = strings.clone(title),
				place = strings.clone(place),
			},
		)
	}
	more(&c, SHOT_TODAY, 16*60 + 30, 45, "Offscreen renderer walkthrough", "Room 2")
	more(&c, date_add(SHOT_TODAY, -7), 10*60, 60, "Typography review", "Studio")
	more(&c, date_add(SHOT_TODAY, -4), 8*60 + 15, 30, "Swim", "Piscine Pontoise")
	more(&c, date_add(SHOT_TODAY, 2), 9*60, 30, "One-to-one", "Room 1")
	more(&c, date_add(SHOT_TODAY, 2), 15*60, 120, "Font licensing call", "Jitsi")
	more(&c, date_add(SHOT_TODAY, 5), -1, 0, "Library closes early", "")
	more(&c, date_add(SHOT_TODAY, 6), 19*60, 150, "Concert: Ensemble Nord", "Salle Pleyel")
	more(&c, date_add(SHOT_TODAY, 13), 11*60, 90, "Quarterly planning", "Studio")
	more(&c, date_add(SHOT_TODAY, -11), 13*60, 60, "Lunch with Ines", "Le Comptoir")
	events_sort(&c.events)
	save(&c)

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

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		path := fmt.tprintf("%s/%s", dir, name)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// The month grid with today's events in the day pane.
	settle(off, &c)
	shot(off, dir, "app-calendar.png", &n)

	// The year view, which counts the entries per month.
	c.view = .Year
	settle(off, &c)
	shot(off, dir, "02-calendar-year.png", &n)
	c.view = .Month

	// The event form, filled in and ready to commit.
	open_form(&c, -1)
	clear(&c.form.bufs[.Title])
	append(&c.form.bufs[.Title], ..transmute([]u8)string("Rehearsal, strings only"))
	clear(&c.form.bufs[.Place])
	append(&c.form.bufs[.Place], ..transmute([]u8)string("Conservatoire, studio 3"))
	c.form.field = .Place
	settle(off, &c)
	shot(off, dir, "03-calendar-event.png", &n)
	c.mode = .Normal

	// The keyboard sheet.
	c.mode = .Help
	settle(off, &c)
	shot(off, dir, "04-calendar-keys.png", &n)
	c.mode = .Normal

	fmt.printfln("calendar --shots: %d PNGs in %s", n, dir)
	return 0
}
