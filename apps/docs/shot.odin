package main

// `docs --shots <dir>`: render the editor offscreen and write PNGs.
//
// The same `frame`, the same `handle_keys` and the same layout the window
// runs, through palmy's offscreen renderer -- no compositor, no window, and
// nothing on anybody's screen. The document it opens is generated here into a
// scratch directory, so a picture can never hold something of a user's.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1280
SHOT_H :: 880

// The generated document lives outside the shots directory: the title strip
// prints its file name, and a shots directory chosen by a caller may carry a
// path that has no business being in a picture.
SHOT_FIXTURE_DIR :: "/tmp/palmy-docs-shots"

// The document the shots open. Invented, about an invented thing, and written
// out as Markdown so the real import path is the one exercised.
SHOT_DOC :: `# The Tidewater Ferry Survey

A crossing is a promise about a minute. The survey below counts the minutes
that promise cost over one season, on four crossings, and says which of them
the tide alone decides.

## What was measured

Five numbers, taken every sailing day between June and October:

- **Departures** against the published minute, per crossing and per hour.
- **Tide holds** — minutes spent waiting at the gate, which nobody had counted before.
- **Loading** — foot passengers against vehicles, because they queue differently.
- *Weather holds*, with the reason recorded rather than inferred.
- **Berth conflicts** on the one quay that cannot take the evening boat.

### The northern reach

Deep water the whole way across, so the tide never holds a sailing. Every
minute lost on this crossing is lost at the quay, and the quay is a single
berth shared with the freight run. The timetable asks for a seven minute turn
and the measured median is eleven.

> A berth that is busy is cheaper to fix than a channel that is shallow.
> This is the whole recommendation in one sentence.

### The southern reach

A shoal at the halfway mark takes the channel to one and a half metres at low
water, which the evening boat cannot clear loaded. The crossing was held on 31
evenings out of the 92 surveyed, and the hold lasted a median of 24 minutes.
The quay at either end was never the constraint.

## The season in one table

| Month | Sailings | Held for tide | Median hold | Worst hold |
| --- | --- | --- | --- | --- |
| June | 540 | 3 | 11 min | 19 min |
| July | 586 | 6 | 18 min | 33 min |
| August | 594 | 12 | 27 min | 51 min |
| September | 551 | 7 | 22 min | 38 min |
| October | 471 | 3 | 14 min | 24 min |

August is both the worst month and the busiest one, which is the finding the
board will care about. Every other month the shoal is an inconvenience; in
August it is the timetable.

## What we recommend

Lengthen the inner berth on the northern reach by eighteen metres. It removes
the berth conflict outright, it costs a fraction of any dredging, and it can
be done between seasons without taking a crossing out of service.

Publish two timetables rather than one, with the southern evening sailing
moved to 19:05 on spring tides. That costs the 19:30 connection twice a month
and saves 25 evenings of waiting.

Dredge the southern shoal only if the two measures above prove insufficient
after a full season under the new timetable. The estimate is in the appendix,
and it is an order of magnitude larger than either of the other two.

Everything below this line is ordinary body text, which is what most of a
report is. It wraps, it reflows when the window changes, and it carries the
caret from line to line by *visual* line rather than by paragraph.

The status bar keeps a live count of words, characters, lines and pages, and
the page number under the caret, so the pagination is visibly real rather than
decorative.
`

// shot_fonts is `kit.start`'s font table plus this app's italics, loaded into
// the offscreen renderer's own table. A screenshot in a different face proves
// nothing about the application.
shot_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
	load_italics(f)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("docs --shots: cannot create %s", dir)
		return 1
	}
	_ = os.make_directory_all(SHOT_FIXTURE_DIR, os.perm(0o755))

	// `p.offscreen_end` frees the temp allocator, so a path handed across two
	// frames has to be a real clone rather than a `tprintf`.
	md := strings.clone(fmt.tprintf("%s/tidewater-survey.md", SHOT_FIXTURE_DIR))
	if e := os.write_entire_file(md, transmute([]u8)string(SHOT_DOC)); e != nil {
		fmt.eprintfln("docs --shots: cannot write %s", md)
		return 1
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	// Offscreen there is no `^p.App`, and this app only reaches into one to
	// quit; a stand-in carrying the window size and the font table is enough.
	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height = SHOT_W, SHOT_H
	app.fonts = off.fonts

	st := State{}
	state_init(&st, &off.fonts)
	defer state_destroy(&st)

	do_open(&st, md)
	if len(st.doc.paras) == 0 {
		fmt.eprintfln("docs --shots: the generated document did not import")
		return 1
	}
	relayout(&st)
	st.dirty = false
	st.caret_on = true

	step :: proc(off: ^p.Offscreen, st: ^State, app: ^p.App) {
		ui := p.offscreen_begin(off)
		measure(ui, st)
		handle_keys(ui, st, app)
		measure(ui, st)
		if st.dirty {
			relayout(st)
			st.dirty = false
		}
		st.caret_on = true
		frame(ui, st)
		p.offscreen_end(off)
	}

	// Hover and hit testing run against the previous frame, so the second
	// frame is the settled picture.
	shot :: proc(off: ^p.Offscreen, st: ^State, app: ^p.App, dir, name: string) {
		step(off, st, app)
		step(off, st, app)
		path := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, path) {
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// The representative frame: the top of the document, caret in the second
	// paragraph, both toolbars and the status bar populated.
	st.caret = pos(2, 40)
	st.anchor = st.caret
	shot(off, &st, app, dir, "app-docs")

	// A selection that runs from a bulleted item into the heading and the body
	// below it, so it crosses both runs and paragraphs.
	first := -1
	last := -1
	for pi in 0 ..< len(st.doc.paras) {
		t := para_text(&st.doc.paras[pi], context.temp_allocator)
		if first < 0 && strings.has_prefix(t, "Loading") {
			first = pi
		}
		if strings.has_prefix(t, "Deep water the whole way") {
			last = pi
			break
		}
	}
	if first >= 0 && last > first {
		st.anchor = pos(first, 0)
		st.caret = pos(last, 72)
		scroll_to_caret(&st)
		st.scroll = max(0, st.scroll - 120)
		clamp_scroll(&st)
	}
	shot(off, &st, app, dir, "02-docs-selection")

	// Find and replace.
	st.anchor = st.caret
	p.press_key(off, KEY_F9)
	step(off, &st, app)
	p.type_text(off, "tide")
	shot(off, &st, app, dir, "03-docs-find-replace")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st, app)
	// The bar is closed, but the matches it found stay highlighted; clear them
	// so the remaining shots are of a document nobody has searched.
	clear(&st.find)
	st.dirty = true
	step(off, &st, app)

	// The keyboard sheet.
	p.press_key(off, p.KEY_F1)
	shot(off, &st, app, dir, "04-docs-keys")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st, app)

	// The table, with the caret inside it so the table strip is up -- which is
	// the one toolbar that only exists while the caret is in a grid.
	st.scroll = 0
	for pi in 0 ..< len(st.doc.paras) {
		if st.doc.paras[pi].kind == .Table {
			st.caret = pos(pi, 0)
			st.anchor = st.caret
			break
		}
	}
	scroll_to_caret(&st)
	// `scroll_to_caret` only brings the caret just into view, which leaves the
	// grid itself on the bottom edge; show the whole of it.
	st.scroll += 330
	clamp_scroll(&st)
	shot(off, &st, app, dir, "05-docs-table")

	// The second page, so the pagination is visible rather than claimed.
	st.caret = pos(len(st.doc.paras) - 1, 0)
	st.anchor = st.caret
	scroll_to_caret(&st)
	shot(off, &st, app, dir, "06-docs-last-page")

	// The prose checker. One deliberately bad sentence is typed into the
	// document first, through the ordinary edit path, so the picture is of
	// real alerts over real text rather than a mock-up -- and so the squiggles
	// and the panel agree about where the words are.
	//
	// The lint runs synchronously here: offscreen there is no frame loop to
	// poll the worker thread with, and a screenshot has to be deterministic.
	// Without vale on the machine this still produces a picture -- of the
	// panel saying so, which is the state it is meant to show.
	st.scroll = 0
	st.caret = doc_end(&st.doc)
	st.anchor = st.caret
	for pi in 0 ..< len(st.doc.paras) {
		t := para_text(&st.doc.paras[pi], context.temp_allocator)
		if strings.has_prefix(t, "A crossing is a promise") {
			st.caret = pos(pi, para_len(&st.doc.paras[pi]))
			st.anchor = st.caret
			break
		}
	}
	type_text(
		&st,
		" We utilize the the survey data in order to demonstrate that it was prepared very obviously.",
	)
	relayout(&st)
	st.prose.show = true
	prose_lint_sync(&st)
	if len(st.prose.alerts) > 0 {
		prose_go(&st, 0)
		for i in 0 ..< len(st.prose.alerts) {
			if st.prose.alerts[i].fix != "" {
				prose_go(&st, i)
				break
			}
		}
	}
	relayout(&st)
	shot(off, &st, app, dir, "07-docs-prose")

	// And the same alert accepted: the linter's own replacement, applied
	// through the edit path, so the Ctrl+Z after it is a single step.
	prose_accept(&st)
	relayout(&st)
	shot(off, &st, app, dir, "08-docs-prose-accepted")

	fmt.printfln("docs --shots: wrote PNGs to %s", dir)
	return 0
}
