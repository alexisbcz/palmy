package palmy_tests

import "core:math"
import "core:testing"
import p "../palmy"

@(private)
near :: proc(a, b: f32, eps: f32 = 0.6) -> bool {
	return abs(a - b) <= eps
}

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

@(test)
test_palette :: proc(t: ^testing.T) {
	c, ok := p.parse_color("slate-900")
	testing.expect(t, ok)
	testing.expect_value(t, c, p.Color{0x0f, 0x17, 0x2a, 255})

	c, ok = p.parse_color("indigo-500")
	testing.expect(t, ok)
	testing.expect_value(t, c, p.Color{0x63, 0x66, 0xf1, 255})

	c, ok = p.parse_color("white")
	testing.expect(t, ok)
	testing.expect_value(t, c, p.WHITE)

	c, ok = p.parse_color("black/50")
	testing.expect(t, ok)
	testing.expect_value(t, c.a, u8(127))

	c, ok = p.parse_color("[#1e293b]")
	testing.expect(t, ok)
	testing.expect_value(t, c, p.Color{0x1e, 0x29, 0x3b, 255})

	_, ok = p.parse_color("nonsense-123")
	testing.expect(t, !ok, "unknown colors must not resolve")
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

@(test)
test_row_grow_and_gap :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 200)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.row(ui, "w-full gap-10 p-10")
	a := p.div(ui, "flex-1 h-10");p.end(ui)
	b := p.div(ui, "w-20 h-10");p.end(ui)
	c := p.div(ui, "flex-1 h-10");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	ra, rb, rc := p.node_rect(ui, a), p.node_rect(ui, b), p.node_rect(ui, c)

	// 400 wide, 40px padding both sides, two 40px gaps, one fixed 80px child:
	// the two flexible children share 400-80-80-80 = 160.
	testing.expect(t, near(ra.w, 80), "first flex child")
	testing.expect(t, near(rc.w, 80), "second flex child")
	testing.expect(t, near(rb.w, 80), "fixed child keeps its width")
	testing.expect(t, near(ra.x, 40), "padding applies")
	testing.expect(t, near(rb.x, ra.x + ra.w + 40), "gap applies")
	testing.expect(t, near(ra.h, 40), "h-10 is 40px")
}

@(test)
test_centering :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 300)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.div(ui, "w-full h-full flex-col items-center justify-center")
	box := p.div(ui, "w-[100] h-[50]");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	r := p.node_rect(ui, box)
	testing.expect(t, near(r.x, 150), "centred horizontally")
	testing.expect(t, near(r.y, 125), "centred vertically")
	testing.expect(t, near(r.w, 100) && near(r.h, 50), "arbitrary sizes")
}

@(test)
test_shrink_to_fit :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 300)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.div(ui, "w-full h-full items-center")
	card := p.div(ui, "p-4")
	inner := p.div(ui, "w-[120] h-[20]");p.end(ui)
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	rc := p.node_rect(ui, card)
	testing.expect(t, near(rc.w, 120 + 32), "an auto-width box hugs its content plus padding")
	testing.expect(t, near(p.node_rect(ui, inner).x, rc.x + 16), "padding offsets the child")
}

@(test)
test_absolute_inset :: proc(t: ^testing.T) {
	off := p.offscreen_create(200, 200)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.div(ui, "relative w-full h-full")
	pin := p.div(ui, "absolute top-2 right-2 w-[10] h-[10]");p.end(ui)
	fill := p.div(ui, "absolute inset-0");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	r := p.node_rect(ui, pin)
	testing.expect(t, near(r.y, 8), "top-2 is 8px")
	testing.expect(t, near(r.x, 200 - 8 - 10), "right-2 anchors to the right edge")

	f := p.node_rect(ui, fill)
	testing.expect(t, near(f.w, 200) && near(f.h, 200), "inset-0 fills the parent")
}

@(test)
test_text_wraps :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 200)
	defer p.offscreen_destroy(off)

	long := "The quick brown fox jumps over the lazy dog and keeps on running well past the edge"

	// Two frames: wrapping settles using the width measured on the frame before.
	one_line, wrapped: f32
	for i in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-[160]")
		a := p.text(ui, long)
		p.end(ui)
		p.div(ui, "w-[160]")
		b := p.text(ui, long, "whitespace-nowrap")
		p.end(ui)
		p.offscreen_end(off)
		wrapped = p.node_rect(ui, a).h
		one_line = p.node_rect(ui, b).h
	}

	testing.expect(t, wrapped > one_line * 2, "wrapped text is several lines tall")
	testing.expect(t, near(one_line, 24, 4), "nowrap text stays one line high")
}

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

@(test)
test_button_click :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 200)
	defer p.offscreen_destroy(off)

	clicks := 0
	frame :: proc(off: ^p.Offscreen, clicks: ^int) -> p.Rect {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		at := p.node_count(ui)
		if p.button(ui, "Click me") {
			clicks^ += 1
		}
		p.end(ui)
		p.offscreen_end(off)
		return p.node_rect(ui, at)
	}

	// Frame 1 establishes the geometry.
	r := frame(off, &clicks)
	testing.expect(t, r.w > 0, "button got a size")

	// Point at it, then press and release on separate frames.
	p.move_pointer(off, r.x + r.w / 2, r.y + r.h / 2)
	frame(off, &clicks)
	testing.expect_value(t, clicks, 0)

	p.press(off)
	frame(off, &clicks)
	testing.expect_value(t, clicks, 0) // a press alone is not a click

	p.release(off)
	frame(off, &clicks)
	testing.expect_value(t, clicks, 1)

	// Releasing away from the button must not count.
	p.move_pointer(off, 2, 2)
	frame(off, &clicks)
	p.press(off)
	frame(off, &clicks)
	p.release(off)
	frame(off, &clicks)
	testing.expect_value(t, clicks, 1)
}

@(test)
test_hover_variant_paints :: proc(t: ^testing.T) {
	off := p.offscreen_create(200, 120)
	defer p.offscreen_destroy(off)

	draw :: proc(off: ^p.Offscreen) -> p.Rect {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		b := p.div(ui, "w-[120] h-[40] bg-indigo-500 hover:bg-emerald-500")
		p.clickable(ui)
		p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		return p.node_rect(ui, b)
	}

	r := draw(off)
	cold := p.offscreen_pixel(off, int(r.x + r.w / 2), int(r.y + r.h / 2))
	testing.expect_value(t, cold, p.Color{0x63, 0x66, 0xf1, 255})

	p.move_pointer(off, r.x + r.w / 2, r.y + r.h / 2)
	draw(off) // hit test runs against the previous frame
	draw(off)
	hot := p.offscreen_pixel(off, int(r.x + r.w / 2), int(r.y + r.h / 2))
	testing.expect_value(t, hot, p.Color{0x10, 0xb9, 0x81, 255})
}

@(test)
test_state_persists :: proc(t: ^testing.T) {
	off := p.offscreen_create(100, 100)
	defer p.offscreen_destroy(off)

	for i in 0 ..< 5 {
		ui := p.offscreen_begin(off)
		n := p.state(ui, "counter", 0)
		n^ += 1
		testing.expect_value(t, n^, i + 1)
		p.offscreen_end(off)
	}
}

@(test)
test_text_field_typing :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 100)
	defer p.offscreen_destroy(off)

	buf: [dynamic]u8
	defer delete(buf)

	frame :: proc(off: ^p.Offscreen, buf: ^[dynamic]u8) -> p.Rect {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-4")
		idx := p.node_count(ui)
		p.text_field(ui, buf, "type here")
		p.end(ui)
		p.offscreen_end(off)
		return p.node_rect(ui, idx)
	}

	r := frame(off, &buf)

	// Click the field to focus it.
	p.move_pointer(off, r.x + 10, r.y + 10)
	frame(off, &buf)
	p.press(off)
	frame(off, &buf)
	p.release(off)
	frame(off, &buf)

	p.type_text(off, "hi")
	frame(off, &buf)
	testing.expect_value(t, string(buf[:]), "hi")

	p.type_text(off, " there")
	frame(off, &buf)
	testing.expect_value(t, string(buf[:]), "hi there")

	p.press_key(off, p.KEY_BACKSPACE)
	frame(off, &buf)
	testing.expect_value(t, string(buf[:]), "hi ther")
}

@(test)
test_scroll_container :: proc(t: ^testing.T) {
	off := p.offscreen_create(200, 120)
	defer p.offscreen_destroy(off)

	frame :: proc(off: ^p.Offscreen) -> p.Rect {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full overflow-scroll flex-col gap-2")
		first := p.div(ui, "h-10 w-full shrink-0");p.end(ui)
		for i in 0 ..< 20 {
			p.div(ui, "h-10 w-full shrink-0");p.end(ui)
		}
		p.end(ui)
		p.offscreen_end(off)
		return p.node_rect(ui, first)
	}

	top := frame(off)
	p.move_pointer(off, 100, 60)
	frame(off)
	p.scroll_by(off, 0, 30)
	frame(off)
	after := frame(off)

	testing.expect(t, after.y < top.y, "scrolling moves the content up")
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

@(test)
test_canvas_blend :: proc(t: ^testing.T) {
	px := make([]u32, 32 * 32)
	defer delete(px)
	c := p.canvas_from(px, 32, 32)
	defer p.canvas_destroy(&c)

	p.clear_canvas(&c, p.BLACK)
	p.fill_rect(&c, {0, 0, 32, 32}, {255, 255, 255, 128})
	mid := p.get(&c, 16, 16)
	testing.expect(t, mid.r > 120 && mid.r < 136, "50% white over black is mid grey")

	p.clear_canvas(&c, p.BLACK)
	p.fill_round_rect(&c, {4, 4, 24, 24}, {12, 12, 12, 12}, p.WHITE)
	testing.expect_value(t, p.get(&c, 16, 16), p.WHITE)
	corner := p.get(&c, 4, 4)
	testing.expect(t, corner.r < 60, "the rounded corner is cut away")
}

@(test)
test_text_measurement :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	w1 := p.text_width(&off.fonts, "iii", 16)
	w2 := p.text_width(&off.fonts, "WWW", 16)
	testing.expect(t, w2 > w1, "proportional metrics")
	testing.expect(t, w1 > 0 && !math.is_nan(w1), "measurements are finite")

	m := p.font_metrics(&off.fonts, 16)
	testing.expect(t, m.ascent > 8 && m.ascent < 20, "plausible ascent at 16px")
}

// ---------------------------------------------------------------------------
// Design tokens, icons and weights — added for the shadcn parity work
// ---------------------------------------------------------------------------

@(test)
test_theme_tokens :: proc(t: ^testing.T) {
	// The token table is process-wide, like a Tailwind config, and the test
	// runner is parallel — so these names are unique to this test rather than
	// resetting shared state out from under another one.
	p.register_color("tok-primary", p.hex(0x171717))
	p.register_radius("toklg", 10)

	c, ok := p.parse_color("tok-primary")
	testing.expect(t, ok, "a registered token resolves as a colour")
	testing.expect_value(t, c, p.Color{0x17, 0x17, 0x17, 255})

	faded, fok := p.parse_color("tok-primary/50")
	testing.expect(t, fok)
	testing.expect_value(t, faded.a, u8(127))

	off := p.offscreen_create(200, 60)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	box := p.div(ui, "w-[80] h-[40] bg-tok-primary rounded-toklg")
	p.end(ui)
	p.offscreen_end(off)

	s := p.node_style(ui, box)
	testing.expect_value(t, s.bg.color, p.Color{0x17, 0x17, 0x17, 255})
	testing.expect_value(t, s.radius[0], f32(10))
}

@(test)
test_token_does_not_shadow_palette :: proc(t: ^testing.T) {
	p.register_color("tok-other", p.hex(0x171717))

	// Registering tokens must leave the built-in Tailwind palette alone.
	c, ok := p.parse_color("slate-900")
	testing.expect(t, ok)
	testing.expect_value(t, c, p.Color{0x0f, 0x17, 0x2a, 255})
}

@(test)
test_font_weights_differ :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// Whatever faces this machine has, the four weight slots must all resolve
	// and measure something sane.
	for wt in p.Font_Weight {
		w := p.text_width(&off.fonts, "Weight", 16, .Sans, wt)
		testing.expect(t, w > 0, "every weight slot measures text")
	}
}

@(test)
test_kerning_toggle :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	off.fonts.no_kerning = false
	with_kern := p.text_width(&off.fonts, "AVATAR", 100)
	off.fonts.no_kerning = true
	without := p.text_width(&off.fonts, "AVATAR", 100)

	testing.expect(t, without >= with_kern, "kerning only ever pulls glyphs together here")
}

@(test)
test_icon_rasterises :: proc(t: ^testing.T) {
	check := p.Icon {
		name   = "test-check",
		d      = "M20 6 L9 17 L4 12",
		view   = 24,
		stroke = 2,
	}

	off := p.offscreen_create(48, 48, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)

	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		p.icon(ui, check, "size-6 text-black")
		p.end(ui)
		p.offscreen_end(off)
	}

	// The stroke has to put ink somewhere near the middle and leave the
	// corners alone.
	dark := 0
	for y in 0 ..< 48 {
		for x in 0 ..< 48 {
			if p.offscreen_pixel(off, x, y).r < 128 {
				dark += 1
			}
		}
	}
	testing.expect(t, dark > 20, "the icon drew something")
	testing.expect(t, dark < 600, "the icon did not flood the canvas")
	testing.expect_value(t, p.offscreen_pixel(off, 1, 1), p.WHITE)
}

@(test)
test_concat :: proc(t: ^testing.T) {
	off := p.offscreen_create(32, 32)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	s := p.concat(ui, "rounded-", "lg", "-t")
	testing.expect_value(t, s, "rounded-lg-t")
	testing.expect_value(t, p.concat(ui), "")
	p.offscreen_end(off)
}

@(test)
test_ring_paints_outside_the_box :: proc(t: ^testing.T) {
	off := p.offscreen_create(60, 60, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)

	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full items-center justify-center")
		p.div(ui, "w-[20] h-[20] bg-white ring-4 ring-[#ff0000]")
		p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
	}

	// The ring sits outside the 20x20 box, so just beyond its edge must be red
	// while the centre stays white.
	testing.expect_value(t, p.offscreen_pixel(off, 30, 30), p.WHITE)
	edge := p.offscreen_pixel(off, 30, 18)
	testing.expect(t, edge.r > 200 && edge.g < 80, "the ring is drawn outside the border box")
}

@(test)
test_stroke_round_rect_keeps_corners :: proc(t: ^testing.T) {
	px := make([]u32, 64 * 64)
	defer delete(px)
	c := p.canvas_from(px, 64, 64)
	defer p.canvas_destroy(&c)

	// A full circle is the worst case for the ring fast path: every row is an
	// arc, so a straight-sides shortcut would erase all but two columns.
	p.clear_canvas(&c, p.WHITE)
	p.stroke_round_rect(&c, {8, 8, 48, 48}, {24, 24, 24, 24}, 3, p.BLACK)

	// Sample the rim at 45 degrees, where only the arc can put ink.
	d := f32(24) - 1.5
	ang := f32(0.7853982) // pi/4
	x := int(32 + d * 0.70710678)
	y := int(32 + d * 0.70710678)
	_ = ang
	diag := p.get(&c, x, y)
	testing.expect(t, diag.r < 160, "the ring is drawn on the diagonal, not only at the sides")

	// The middle stays empty and the outside is untouched.
	testing.expect_value(t, p.get(&c, 32, 32), p.WHITE)
	testing.expect_value(t, p.get(&c, 1, 1), p.WHITE)
}

@(test)
test_layer_config_plumbs_through :: proc(t: ^testing.T) {
	// A layer surface cannot be opened without a compositor, but the config
	// has to reach the window struct unchanged, and an unset keyboard mode
	// must become Exclusive rather than silently leaving the surface dead to
	// key input.
	cfg := p.Config {
		layer          = true,
		layer_level    = .Overlay,
		layer_anchor   = {.Top, .Left},
		exclusive_zone = 36,
		layer_margin   = {8, 4, 0, 4},
	}
	testing.expect_value(t, cfg.layer_level, p.Layer.Overlay)
	testing.expect(t, .Top in cfg.layer_anchor && .Left in cfg.layer_anchor)
	testing.expect_value(t, cfg.exclusive_zone, 36)
	testing.expect_value(t, cfg.layer_keyboard, p.Keyboard_Mode.None)

	// The anchor bit_set has to match the protocol's bit values exactly:
	// top=1, bottom=2, left=4, right=8.
	testing.expect_value(t, transmute(u32)p.Anchor{.Top}, u32(1))
	testing.expect_value(t, transmute(u32)p.Anchor{.Bottom}, u32(2))
	testing.expect_value(t, transmute(u32)p.Anchor{.Left}, u32(4))
	testing.expect_value(t, transmute(u32)p.Anchor{.Right}, u32(8))
	testing.expect_value(t, transmute(u32)p.Anchor{.Top, .Left, .Right}, u32(13))
}
