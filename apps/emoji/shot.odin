package main

// `emoji --shots <dir>`: render the picker offscreen and write PNGs.
//
// Same `handle_keys` and `build` the window runs, same fonts, same theme — no
// compositor and no window, so a screenshot costs a second and can be taken on
// a machine with no display at all. Nothing of the user's is read: the picker's
// only persistent state is the recents file, and this never loads it.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

// shot_load_fonts loads exactly the faces `kit.start` gives a window, so the
// PNG is in the same type as the real interface.
shot_load_fonts :: proc(f: ^p.Fonts) {
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

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintfln("emoji --shots: cannot create %s", dir)
		return 1
	}

	// The clipboard is made observable rather than real: a shot must not
	// reach wl-copy and overwrite whatever the user has copied.
	g_test = true

	// Enter files a character under Recently used, and that list is written
	// to `$HOME/.local/share/palmy-emoji/recent`. A screenshot run must not
	// rewrite the user's own recents, so home is pointed at the output
	// directory for the duration.
	home := strings.clone(fmt.tprintf("%s/.emoji-shot-state", dir))
	defer delete(home)
	_ = os.make_directory_all(home)
	_ = os.set_env("HOME", home)

	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_load_fonts(&off.fonts)
	// The grid is drawn with `font-mono`, and DejaVu Sans is the face whose
	// cmap the character table was generated against — see chars.odin.
	glyphs := p.load_font(&off.fonts, GLYPH_FONT, .Mono, .Regular)
	register_dark_theme()
	p.set_text_gamma(1.8)

	st := St {
		hits   = make([dynamic]int),
		query  = make([dynamic]u8),
		recent = make([dynamic]rune),
		cat    = 0,
		glyphs = glyphs,
	}
	build_index(&st)
	refilter(&st)
	// A few plausible recents, so the pinned pseudo-category is not empty.
	// Typed in, not loaded from disk.
	for r in ([?]rune{0x2192, 0x2318, 0x03BB, 0x2714, 0x266B, 0x2665}) {
		append(&st.recent, r)
	}

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		handle_keys(ui, nil, st)
		build(ui, st)
		p.offscreen_end(off)
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// Two frames per shot: hover and hit testing run against the previous
	// frame, so the second one is the settled picture.
	step(off, &st)
	step(off, &st)
	shot(off, dir, "app-emoji", &n)

	// A search by name.
	p.type_text(off, "arrow")
	step(off, &st)
	step(off, &st)
	shot(off, dir, "02-emoji-search", &n)

	// Clear it, then a block picked from the sidebar.
	for _ in 0 ..< 6 {
		p.press_key(off, p.KEY_BACKSPACE)
		step(off, &st)
	}
	st.cat = 0
	st.sel = 0
	st.top = 0
	for name, i in CATEGORIES {
		if strings.contains(strings.to_lower(name, context.temp_allocator), "math") {
			st.cat = i
			break
		}
	}
	refilter(&st)
	step(off, &st)
	step(off, &st)
	shot(off, dir, "03-emoji-block", &n)

	// A codepoint typed straight in, which is the detail panel's real job.
	st.cat = 0
	refilter(&st)
	step(off, &st)
	p.type_text(off, "2318")
	step(off, &st)
	step(off, &st)
	shot(off, dir, "04-emoji-codepoint", &n)

	// And the recents, which Enter has just added to.
	p.press_key(off, p.KEY_RETURN)
	step(off, &st)
	clear(&st.query)
	st.caret = 0
	st.cat = CAT_RECENT
	st.sel = 0
	refilter(&st)
	step(off, &st)
	step(off, &st)
	shot(off, dir, "05-emoji-recent", &n)

	fmt.printfln("emoji --shots: %d PNGs in %s", n, dir)
	if !glyphs {
		fmt.eprintfln("emoji --shots: %s did not load; the grid will be empty boxes", GLYPH_FONT)
		return 1
	}
	return 0
}
