package main

// The second half of `colorpick --selftest`: the editor itself, driven through
// palmy's offscreen renderer so that `handle_keys` and `build` — the code the
// window runs — are exercised with no compositor involved.
//
// The colour-space maths is checked in color.odin; this file checks that
// editing one notation really does re-derive the other three.

import "core:fmt"
import "core:strings"
import p "palmy:."

@(private = "file")
fails: int
@(private = "file")
checks: int

@(private = "file")
ok :: proc(cond: bool, format: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.printf("FAIL  ")
		fmt.printfln(format, ..args)
	}
}

@(private = "file")
frame :: proc(o: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(o)
	handle_keys(ui, nil, st)
	switch st.mode {
	case .Editor:
		build_editor(ui, st)
	case .Screen:
		build_screen(ui, st)
	}
	p.offscreen_end(o)
}

ui_selftest :: proc() -> (checks_out, fails_out: int) {
	g_test = true

	fmt.println("\n-- hex parsing")
	for c in ([?]struct {
		in_:  string,
		r, g, b: u8,
		good: bool,
	} {
		{"#3b82f6", 0x3b, 0x82, 0xf6, true},
		{"3b82f6", 0x3b, 0x82, 0xf6, true},
		{"  #FFF  ", 0xff, 0xff, 0xff, true},
		{"#abc", 0xaa, 0xbb, 0xcc, true},
		{"#12345", 0, 0, 0, false},
		{"nothex", 0, 0, 0, false},
		{"", 0, 0, 0, false},
	}) {
		rgb, good := parse_hex(c.in_)
		ok(good == c.good, "parse_hex(%q) ok=%v, expected %v", c.in_, good, c.good)
		if c.good && good {
			b := to_bytes(rgb)
			ok(
				b[0] == c.r && b[1] == c.g && b[2] == c.b,
				"parse_hex(%q) = #%02x%02x%02x, expected #%02x%02x%02x",
				c.in_,
				b[0],
				b[1],
				b[2],
				c.r,
				c.g,
				c.b,
			)
		}
	}

	// ---------------------------------------------------------------------
	fmt.println("-- the editor, driven through handle_keys")

	off := p.offscreen_create(1060, 720, 1, "w-full h-full flex-col bg-background text-foreground")
	defer p.offscreen_destroy(off)
	register_dark_theme()

	st := St {
		rgb     = {0x3b / 255.0, 0x82 / 255.0, 0xf6 / 255.0},
		zoom    = 12,
		palette = make([dynamic][3]u8),
	}
	for i in 0 ..< FIELD_N {
		st.bufs[i] = make([dynamic]u8)
	}
	resync(&st, .Hex)
	st.hex_caret = len(st.bufs[0])
	frame(off, &st)

	ok(buf_str(&st, 0) == "#3b82f6", "the hex field should start at #3b82f6, shows %q", buf_str(&st, 0))
	ok(buf_str(&st, 1) == "59", "R should read 59, shows %q", buf_str(&st, 1))
	ok(buf_str(&st, 2) == "130", "G should read 130, shows %q", buf_str(&st, 2))
	ok(buf_str(&st, 3) == "246", "B should read 246, shows %q", buf_str(&st, 3))

	// Down walks the fields.
	p.press_key(off, p.KEY_DOWN)
	frame(off, &st)
	ok(st.sel == 1, "Down should select the R field, selected %d", st.sel)

	// Right nudges a numeric field by its step, and everything else follows.
	p.press_key(off, p.KEY_RIGHT)
	p.press_key(off, p.KEY_RIGHT)
	p.press_key(off, p.KEY_RIGHT)
	frame(off, &st)
	ok(to_bytes(st.rgb)[0] == 62, "three Rights should take R from 59 to 62, got %d", to_bytes(st.rgb)[0])
	ok(buf_str(&st, 0) == "#3e82f6", "the hex field should have followed to #3e82f6, shows %q", buf_str(&st, 0))
	ok(st.src == .Rgb, "RGB should be the authoritative model, it is %v", st.src)
	{
		h := srgb_to_hsl(st.rgb)
		shown, _ := parse_number(buf_str(&st, 4))
		ok(abs(shown - h[0]) < 0.11, "the HSL hue field (%g) should track the colour (%g)", shown, h[0])
	}

	// Shift+Left moves by the larger step.
	p.press_key(off, p.KEY_LEFT, {.Shift})
	frame(off, &st)
	ok(to_bytes(st.rgb)[0] == 62 - 16, "Shift+Left should move R by 16, got %d", to_bytes(st.rgb)[0])

	// Typing into the hex field re-derives everything.
	st.sel = 0
	set_buf(&st, 0, "")
	st.hex_caret = 0
	frame(off, &st)
	p.type_text(off, "#ff0000")
	frame(off, &st)
	ok(buf_str(&st, 0) == "#ff0000", "typing did not reach the hex field: %q", buf_str(&st, 0))
	b := to_bytes(st.rgb)
	ok(b[0] == 255 && b[1] == 0 && b[2] == 0, "the colour should be pure red, got #%02x%02x%02x", b[0], b[1], b[2])
	ok(buf_str(&st, 1) == "255", "R should read 255, shows %q", buf_str(&st, 1))
	{
		o := srgb_to_oklch(st.rgb)
		ok(abs(o[0] - 0.62796) < 5e-4, "OKLCH L for red should be 0.628, got %g", o[0])
		shown, _ := parse_number(buf_str(&st, 9))
		ok(abs(shown - 29.23) < 0.05, "the OKLCH hue field should read 29.23, shows %g", shown)
	}

	// Only hex digits are accepted there.
	p.type_text(off, "zq")
	frame(off, &st)
	ok(buf_str(&st, 0) == "#ff0000", "non-hex characters should be ignored, field is %q", buf_str(&st, 0))

	// Enter commits and files the colour in the palette.
	p.press_key(off, p.KEY_RETURN)
	frame(off, &st)
	ok(len(st.palette) == 1, "Enter should save the colour, the palette holds %d", len(st.palette))
	ok(st.palette[0] == [3]u8{255, 0, 0}, "the palette should hold pure red")

	// Editing hue at zero saturation keeps the hue instead of snapping to 0:
	// that is the whole reason three representations are kept side by side.
	st.rgb = {0.5, 0.5, 0.5}
	resync(&st, .Hex)
	st.sel = 4 // HSL hue
	set_buf(&st, 4, field_text(&st, 4))
	frame(off, &st)
	for _ in 0 ..< 20 {
		p.press_key(off, p.KEY_RIGHT)
	}
	frame(off, &st)
	ok(abs(st.hsl[0] - 20) < 0.001, "the hue should have moved to 20, it is %g", st.hsl[0])
	ok(st.src == .Hsl, "HSL should now be authoritative, it is %v", st.src)
	// Grey has no saturation, so the colour itself must not have moved.
	ok(to_bytes(st.rgb) == [3]u8{128, 128, 128}, "a hue change at zero saturation must not alter the colour")

	// OKLCH out of the sRGB gamut is reported rather than silently clipped.
	st.lch = {0.7, 0.4, 150}
	resync(&st, .Oklch)
	frame(off, &st)
	ok(!st.in_gamut, "oklch(0.7 0.4 150) is outside sRGB and should be flagged")
	st.lch = srgb_to_oklch({0.2, 0.4, 0.6})
	resync(&st, .Oklch)
	frame(off, &st)
	ok(st.in_gamut, "a colour that came from sRGB must round-trip inside the gamut")

	// Copying, in each notation.
	st.rgb = {0x3b / 255.0, 0x82 / 255.0, 0xf6 / 255.0}
	resync(&st, .Hex)
	st.sel = 0
	frame(off, &st)
	for c in ([?]struct {
		key:  u32,
		want: string,
	} {
		{'1', "#3b82f6"},
		{'2', "rgb(59, 130, 246)"},
		{'3', "hsl(217.2, 91.2%, 59.8%)"},
	}) {
		p.press_key(off, c.key, {.Ctrl})
		frame(off, &st)
		ok(g_test_clip == c.want, "Ctrl+%c copied %q, expected %q", rune(c.key), g_test_clip, c.want)
	}
	p.press_key(off, '4', {.Ctrl})
	frame(off, &st)
	ok(
		strings.has_prefix(g_test_clip, "oklch(0.62") && strings.has_suffix(g_test_clip, ")"),
		"Ctrl+4 copied %q, expected an oklch() around L=0.62",
		g_test_clip,
	)

	// Tab reaches the palette, and Enter there loads the colour back.
	st.rgb = {0, 0, 0}
	resync(&st, .Hex)
	p.press_key(off, p.KEY_TAB)
	frame(off, &st)
	ok(st.pane == .Palette, "Tab should focus the palette, pane is %v", st.pane)
	p.press_key(off, p.KEY_RETURN)
	frame(off, &st)
	ok(to_bytes(st.rgb) == [3]u8{255, 0, 0}, "Enter in the palette should load red back, got #%02x%02x%02x", to_bytes(st.rgb)[0], to_bytes(st.rgb)[1], to_bytes(st.rgb)[2])
	ok(st.pane == .Fields, "loading a palette colour should return focus to the fields")

	// The contrast readout agrees with the WCAG formula, and the ink chosen
	// for the big swatch is whichever of black and white actually wins.
	{
		white_bg := contrast_ratio({1, 1, 1}, {0, 0, 0})
		ok(abs(white_bg - 21) < 1e-3, "white on black should be 21:1, got %g", white_bg)
		light := [3]f32{0.95, 0.95, 0.95}
		ok(ink_for(light) == p.BLACK, "black ink belongs on a near-white swatch")
		dark := [3]f32{0.05, 0.05, 0.05}
		ok(ink_for(dark) == p.WHITE, "white ink belongs on a near-black swatch")
	}

	// The screen-pick view renders without a capture behind it.
	st.mode = .Screen
	frame(off, &st)
	ok(st.mode == .Screen, "the screen view should stay open with no capture loaded")
	p.press_key(off, p.KEY_ESCAPE)
	frame(off, &st)
	ok(st.mode == .Editor, "Escape should return from the screen view")

	// Something is actually drawn.
	{
		bg := p.offscreen_pixel(off, 2, 2)
		different := 0
		for y := 0; y < 720; y += 7 {
			for x := 0; x < 1060; x += 7 {
				if p.offscreen_pixel(off, x, y) != bg {different += 1}
			}
		}
		ok(different > 500, "the rendered frame is nearly uniform (%d differing samples)", different)
	}

	return checks, fails
}
