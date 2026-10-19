// `home --shots <dir>`: render the interface offscreen and write PNGs, in
// the light theme and the dark one.
//
// No compositor and no window: the same `keys` and `frame` the window runs,
// through palmy's offscreen renderer, over the invented fixtures only.
package main

import "core:fmt"
import "core:os"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1280
SHOT_H :: 820

shot_fonts :: proc(off: ^p.Offscreen, dark: bool) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf"}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			break
		}
	}
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
}

set_buf :: proc(b: ^[dynamic]u8, s: string) {
	clear(b)
	append(b, ..transmute([]u8)s)
}

shots :: proc(dir: string, src := Source.Fixtures) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("home --shots: cannot create %s", dir)
		return 1
	}
	n := 0
	for dark in ([?]bool{false, true}) {
		n += src == .Device ? shots_device(dir, dark) : shots_theme(dir, dark)
	}
	fmt.printfln("home --shots: %d PNGs in %s", n, dir)
	return 0
}

settle :: proc(off: ^p.Offscreen, h: ^Home) {
	for _ in 0 ..< 3 {
		ui := p.offscreen_begin(off)
		keys(ui, h)
		frame(ui, h)
		p.offscreen_end(off)
	}
}

// shot renders one picture on a fresh offscreen. Reusing one carries the
// last picture's colour transitions into the next, half-faded.
shot :: proc(h: ^Home, dir, theme, name: string, n: ^int) {
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, h.dark)
	register_identity_colors(&h.store, h.dark)
	h.toast = ""
	settle(off, h)
	path := fmt.tprintf("%s/%s-%s.png", dir, name, theme)
	if p.offscreen_write_png(off, path) {
		n^ += 1
		fmt.printfln("  %s", path)
	}
}

shots_theme :: proc(dir: string, dark: bool) -> int {
	h := Home{}
	home_init(&h, dark)
	theme := dark ? "dark" : "light"
	n := 0
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, dark)
	register_identity_colors(&h.store, dark)

	// Today across every identity, each item labelled.
	h.sel = 1
	shot(&h, dir, theme, "01-today-all", &n)

	// Today inside one identity: the labels go, the window is tinted.
	h.ident = 1
	h.sel = 0
	shot(&h, dir, theme, "02-today-work", &n)
	h.ident = -1

	// Universal search, grouped by kind, every result labelled.
	set_buf(&h.query, "roadmap")
	h.sel = 2
	shot(&h, dir, theme, "03-search", &n)

	// The same search narrowed to one identity.
	h.ident = 3
	h.sel = 0
	shot(&h, dir, theme, "04-search-halcyon", &n)
	h.ident = -1
	clear(&h.query)

	// The command palette.
	h.mode = .Palette
	set_buf(&h.pal_query, "")
	h.pal_sel = 0
	h.ident = 1
	shot(&h, dir, theme, "05-palette", &n)
	h.ident = -1
	h.mode = .Normal

	// Quick-create while showing everything: Home will not guess the sender.
	open_create(&h, .Mail, -1)
	shot(&h, dir, theme, "06-create-choose", &n)
	h.new_ident = 1
	set_buf(&h.new_title, "Q4 roadmap: signed off")
	shot(&h, dir, theme, "07-create-work", &n)
	h.mode = .Normal

	// Carry: the deliberate cross-identity act.
	h.sel = 0
	settle(off, &h)
	for item, k in h.rows {
		if h.store.items[item].title == "Passport scan.pdf" {
			h.sel = k
		}
	}
	// Passport scan is not on Today, so carry from a search result.
	set_buf(&h.query, "passport")
	settle(off, &h)
	h.sel = 1
	for item, k in h.rows {
		if h.store.items[item].kind == .File {
			h.sel = k
		}
	}
	open_carry(&h)
	h.carry_to = 1
	shot(&h, dir, theme, "08-carry", &n)
	h.mode = .Normal
	clear(&h.query)
	return n
}
