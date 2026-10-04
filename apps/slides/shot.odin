package main

// `slides --shots <dir>`: render the editor offscreen and write PNGs.
//
// No compositor, no window, nothing on anybody's screen -- the same `build`
// the window runs, through palmy's offscreen renderer. The deck it opens is
// generated here into a scratch directory, so a screenshot can never contain
// a deck somebody was actually working on.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

SHOT_W :: 1320
SHOT_H :: 860

// The generated deck lives outside the shots directory on purpose: the
// inspector prints the deck's file name, and a shots directory chosen by a
// caller may carry a path that has no business being in a picture.
SHOT_FIXTURE_DIR :: "/tmp/palmy-slides-shots"

// shot_fonts is `kit.start`'s font table, loaded into the offscreen renderer's
// own one. A screenshot in a different face proves nothing about the app.
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
}

// shot_deck is an invented deck about an invented thing, generated rather than
// read, so that nothing of anybody's appears in a committed image.
shot_deck :: proc() -> Deck {
	d := Deck {
		version = DECK_VERSION,
		title   = "Tidewater Ferry Survey",
		author  = "Harbour Office",
		theme   = THEMES[0],
		slides  = make([dynamic]Slide),
	}

	{
		s := slide_make(.Title)
		append(&s.elems, text_box("Tidewater Ferry\nSurvey 2041", .Title, 140, 212, 1000, 190, .Center))
		append(&s.elems, text_box("Four crossings, one timetable, and the tide that decides both", .Subtitle, 140, 418, 1000, 70, .Center))
		append(&s.elems, text_box("Harbour Office  ·  autumn review", .Caption, 140, 600, 1000, 40, .Center))
		s.notes = "Open on the title. The whole survey is four crossings and one timetable.\n\nPress Right to begin."
		append(&d.slides, s)
	}

	{
		s := slide_make(.Title_Content)
		append(&s.elems, text_box("What the survey measured", .Title, MARGIN, 72, 1120, 96))
		append(
			&s.elems,
			text_box(
				"- Sailings kept to the published minute, per crossing\n- Minutes lost waiting on the tide gate\n- Foot passengers against vehicles, by hour\n- Weather holds, and how long each one lasted\n- The one berth that cannot take the evening boat",
				.Bullets,
				MARGIN,
				208,
				1000,
				400,
			),
		)
		s.notes = "Five measures, taken every day for a season. The tide gate is the one nobody had numbers for before."
		append(&d.slides, s)
	}

	{
		s := slide_make(.Two_Content)
		append(&s.elems, text_box("Two crossings, two problems", .Title, MARGIN, 72, 1120, 96))
		append(&s.elems, text_box("Northern reach\n\n- Deep water the whole way\n- Never held for tide\n- Berth is the bottleneck", .Bullets, MARGIN, 232, 500, 340))
		append(&s.elems, text_box("Southern reach\n\n- Shoal at the halfway mark\n- Held on 31 evenings\n- Berth is never busy", .Bullets, 660, 232, 500, 340))
		append(&s.elems, shape(.Rect, MARGIN - 16, 208, 532, 390, SLOT_SURFACE))
		s.elems[len(s.elems) - 1].fill_a = 0.55
		elem_to_back(&s, len(s.elems) - 1)
		s.notes = "The two reaches fail in opposite ways, which is why one timetable cannot serve both."
		append(&d.slides, s)
	}

	{
		s := slide_make(.Blank)
		append(&s.elems, text_box("Minutes lost to the tide gate", .Title, MARGIN, 72, 1120, 96))
		append(&s.elems, text_box("31", .Metric, MARGIN, 230, 260, 180))
		s.elems[len(s.elems) - 1].color = SLOT_ACCENT
		append(&s.elems, text_box("evenings held\nout of 92 surveyed", .Body, MARGIN, 420, 320, 120))
		append(&s.elems, shape(.Rect, 520, 460, 90, 150, SLOT_ACCENT))
		append(&s.elems, shape(.Rect, 630, 390, 90, 220, SLOT_ACCENT))
		append(&s.elems, shape(.Rect, 740, 300, 90, 310, SLOT_ACCENT2))
		append(&s.elems, shape(.Rect, 850, 420, 90, 190, SLOT_ACCENT))
		append(&s.elems, shape(.Rect, 960, 500, 90, 110, SLOT_ACCENT))
		append(&s.elems, text_box("Jun      Jul      Aug      Sep      Oct", .Caption, 520, 626, 620, 40))
		s.notes = "August is the worst month, and it is also the busiest. That is the finding."
		append(&d.slides, s)
	}

	{
		s := slide_make(.Blank)
		append(&s.elems, text_box("Shapes, strokes, rotation", .Title, MARGIN, 72, 1120, 96))
		append(&s.elems, shape(.Rect, 110, 250, 240, 170, SLOT_ACCENT))
		append(&s.elems, shape(.Rect, 300, 320, 240, 170, SLOT_ACCENT2))
		s.elems[len(s.elems) - 1].rotation = -12
		s.elems[len(s.elems) - 1].fill_a = 0.9
		append(&s.elems, shape(.Ellipse, 600, 250, 220, 220, SLOT_NONE, SLOT_ACCENT))
		s.elems[len(s.elems) - 1].stroke_w = 8
		append(&s.elems, shape(.Arrow, 860, 300, 220, 120, SLOT_FG))
		append(&s.elems, text_box("The berth diagram, drawn with the editor's own shapes rather than imported.", .Caption, 110, 540, 520, 60))
		s.notes = "Every edge is a signed distance field, evaluated in the shape's own rotated frame."
		append(&d.slides, s)
	}

	{
		s := slide_make(.Section_Header)
		append(&s.elems, text_box("What we recommend", .Title, 140, 288, 1000, 110))
		append(&s.elems, text_box("Two timetables, published together, and one dredged channel", .Subtitle, 140, 416, 1000, 70))
		append(&s.elems, text_box("06", .Metric, 940, 180, 240, 160, .Right))
		s.elems[len(s.elems) - 1].color = SLOT_ACCENT
		s.elems[len(s.elems) - 1].opacity = 0.35
		s.notes = "Close here. The recommendation is cheap on the northern reach and expensive on the southern one."
		append(&d.slides, s)
	}

	for &s in d.slides {
		for &e in s.elems {
			normalise(&e)
		}
	}
	return d
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("slides --shots: cannot create %s", dir)
		return 1
	}
	_ = os.make_directory_all(SHOT_FIXTURE_DIR, os.perm(0o755))

	// Generated, written out, and read back through the real loader, so the
	// picture is of a deck that came off disk the way a user's would.
	deck_path := strings.clone(fmt.tprintf("%s/tidewater.json", SHOT_FIXTURE_DIR))
	{
		d := shot_deck()
		if e := save_deck(&d, deck_path); e != "" {
			fmt.eprintfln("slides --shots: %s", e)
			return 1
		}
	}
	d, lerr := load_deck(deck_path)
	if lerr != "" {
		fmt.eprintfln("slides --shots: %s", lerr)
		return 1
	}

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	register_chrome_theme()
	p.set_text_gamma(1.8)

	st := new(St)
	st.exe_dir = exe_directory()
	st.imgs = img_cache_make(st.exe_dir)
	st.guides = make([dynamic]Guide)
	st.sel = -1
	st.snap = true
	st.footer = true
	st.show_notes = true
	st.deck = d
	st.path = deck_path
	st.fonts = &off.fonts
	for i in 0 ..< MAX_THUMBS {
		st.thumbs[i] = {st, i}
	}

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		st.fonts = ui.fonts
		clamp_state(st)
		build(ui, st)
		p.offscreen_end(off)
	}

	// Hover and hit testing run against the previous frame, so the second
	// frame is the settled picture.
	shot :: proc(off: ^p.Offscreen, st: ^St, dir, name: string) {
		step(off, st)
		step(off, st)
		path := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, path) {
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// The representative frame: slide three selected, an element picked, so
	// the sorter, the canvas and the inspector all have something true in them.
	st.slide = 2
	st.sel = 1
	st.prop = .Size
	shot(off, st, dir, "app-slides")

	// The chart slide, nothing selected.
	st.slide = 3
	st.sel = -1
	shot(off, st, dir, "02-slides-chart")

	// Editing a text box in place, with the caret in the buffer.
	st.slide = 1
	st.sel = 1
	st.mode = .Text
	clear(&st.ed.buf)
	e := cur_elem(st)
	if e != nil {
		append(&st.ed.buf, e.text)
		st.ed.caret = len(st.ed.buf)
	}
	shot(off, st, dir, "03-slides-editing-text")
	st.mode = .Browse

	// The cheatsheet.
	st.mode = .Help
	st.help_top = 0
	shot(off, st, dir, "04-slides-help")
	st.mode = .Browse

	// The projector, at the size a fullscreen overlay would get.
	pres := p.offscreen_create(1600, 900, 1, "w-full h-full bg-black overflow-hidden")
	defer p.offscreen_destroy(pres)
	shot_fonts(&pres.fonts)
	st.slide = 0
	st.sel = -1
	st.pres_notes = false
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(pres)
		st.fonts = ui.fonts
		clamp_state(st)
		build_present(ui, st)
		p.offscreen_end(pres)
	}
	ppath := fmt.tprintf("%s/05-slides-projector.png", dir)
	if p.offscreen_write_png(pres, ppath) {
		fmt.printfln("  %s", ppath)
	}

	fmt.printfln("slides --shots: wrote PNGs to %s", dir)
	return 0
}
