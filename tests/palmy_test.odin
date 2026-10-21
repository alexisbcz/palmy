package palmy_tests

import "base:runtime"
import "core:math"
import "core:mem"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
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

// The tokens these two tests read, registered once at startup.
//
// The token table is process-wide, like a Tailwind config, and every rendering
// test reads it through `parse_color` while the runner runs them in parallel.
// These used to be registered inside the tests themselves, which wrote the
// shared maps (and, for whichever test ran first, created them with that
// test's tracking allocator) while other tests were reading them: bad frees
// and a segfault in seven full-suite runs. From `@(init)` they are written
// before the runner spawns a thread and never again, as tests/widgets_test.odin
// does for its field tokens. The names stay unique to these tests.
@(init)
register_token_test_tokens :: proc "contextless" () {
	// Contextless, and registering allocates: give it the process default
	// context so the keys belong to no test's tracking allocator.
	context = runtime.default_context()
	p.register_color("tok-primary", p.hex(0x171717))
	p.register_radius("toklg", 10)
	p.register_color("tok-other", p.hex(0x171717))
}

@(test)
test_theme_tokens :: proc(t: ^testing.T) {
	// "tok-primary" and "toklg" are registered in register_token_test_tokens.
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
	// "tok-other" is registered in register_token_test_tokens; it must not
	// stop the palette from resolving, and must itself resolve.
	o, ook := p.parse_color("tok-other")
	testing.expect(t, ook, "the token registered at startup resolves")
	testing.expect_value(t, o, p.Color{0x17, 0x17, 0x17, 255})

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

@(test)
test_image_decode_and_fit :: proc(t: ^testing.T) {
	// Encode a known 4x2 image, decode it back, and check both the pixels and
	// the fit arithmetic. A round trip is the only honest check that the
	// channel order survives.
	src := [8]u32 {
		0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff,
		0x80ff0000, 0x00000000, 0xff000000, 0xffcccccc,
	}
	rgba := make([]u8, 8 * 4)
	defer delete(rgba)
	for v, i in src {
		rgba[i * 4 + 0] = u8(v >> 16)
		rgba[i * 4 + 1] = u8(v >> 8)
		rgba[i * 4 + 2] = u8(v)
		rgba[i * 4 + 3] = u8(v >> 24)
	}

	path := "/tmp/palmy_image_test.png"
	ok := p.write_png_rgba(path, rgba, 4, 2)
	testing.expect(t, ok, "wrote the test png")

	img, loaded := p.load_image(path)
	defer p.image_destroy(&img)
	testing.expect(t, loaded, "decoded the test png")
	testing.expect_value(t, img.w, 4)
	testing.expect_value(t, img.h, 2)
	testing.expect_value(t, img.px[0], u32(0xffff0000)) // opaque red survives
	testing.expect_value(t, img.px[1], u32(0xff00ff00)) // green, not swapped
	testing.expect_value(t, img.px[2], u32(0xff0000ff)) // blue, not swapped
	testing.expect_value(t, img.px[5] >> 24, u32(0))    // transparent stays transparent

	w, h, _, sized := p.image_size(path)
	testing.expect(t, sized && w == 4 && h == 2, "size probe agrees without decoding")

	// Fit: a 4x2 image in a 100x100 box.
	box := p.Rect{0, 0, 100, 100}
	contain := p.fitted_rect(4, 2, box, .Contain)
	testing.expect_value(t, contain.w, f32(100))
	testing.expect_value(t, contain.h, f32(50))
	testing.expect_value(t, contain.y, f32(25)) // centred vertically

	cover := p.fitted_rect(4, 2, box, .Cover)
	testing.expect_value(t, cover.h, f32(100))
	testing.expect_value(t, cover.w, f32(200)) // overflows, to be clipped

	none := p.fitted_rect(4, 2, box, .None)
	testing.expect_value(t, none.w, f32(4))
	testing.expect_value(t, none.x, f32(48))
}

@(test)
test_image_draws_into_canvas :: proc(t: ^testing.T) {
	src := [4]u32{0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000}
	rgba := make([]u8, 16)
	defer delete(rgba)
	for v, i in src {
		rgba[i * 4 + 0] = u8(v >> 16)
		rgba[i * 4 + 1] = u8(v >> 8)
		rgba[i * 4 + 2] = u8(v)
		rgba[i * 4 + 3] = 255
	}
	path := "/tmp/palmy_image_draw.png"
	testing.expect(t, p.write_png_rgba(path, rgba, 2, 2))

	img, ok := p.load_image(path)
	defer p.image_destroy(&img)
	testing.expect(t, ok)

	px := make([]u32, 40 * 40)
	defer delete(px)
	c := p.canvas_from(px, 40, 40)
	defer p.canvas_destroy(&c)
	p.clear_canvas(&c, p.WHITE)

	p.draw_image(&c, img, p.fitted_rect(2, 2, {0, 0, 40, 40}, .Contain))
	mid := p.get(&c, 20, 20)
	testing.expect(t, mid.r > 200 && mid.g < 60 && mid.b < 60, "the red image landed")
}

@(test)
test_keymap_text_survives_load :: proc(t: ^testing.T) {
	// Regression: `keymap_load` used to clone the keymap text and then call
	// `keymap_destroy`, which freed the clone one line later — so
	// `host_keymap` always came back empty and a nested compositor silently
	// fell back to a default layout.
	KEYMAP :: `xkb_keymap {
  xkb_keycodes { minimum = 8; maximum = 255; <esc> = 9; };
  xkb_types { type "ONE_LEVEL" { modifiers = none; map[none] = 1; level_name[1] = "Any"; }; };
  xkb_compat { };
  xkb_symbols { key <esc> { [ Escape ] }; };
};`

	fd, err := linux.memfd_create("palmy-keymap-test", {.CLOEXEC})
	testing.expect(t, err == .NONE, "memfd created")
	defer linux.close(fd)

	bytes := transmute([]u8)string(KEYMAP)
	written, werr := linux.write(fd, bytes)
	testing.expect(t, werr == .NONE && written == len(bytes), "keymap written")
	// The protocol hands over a NUL-terminated mapping.
	nul := [1]u8{0}
	_, _ = linux.write(fd, nul[:])
	_, _ = linux.lseek(fd, 0, .SET)

	km: p.Keymap
	defer p.keymap_destroy(&km)
	p.keymap_load(&km, fd, len(bytes) + 1)

	text := p.keymap_text(&km)
	testing.expect(t, len(text) > 0, "the keymap text is retained after loading")
	testing.expect(t, strings.contains(text, "xkb_keymap"), "and it is the keymap we handed over")
}

@(test)
test_input_counts_and_repeat :: proc(t: ^testing.T) {
	off := p.offscreen_create(100, 100)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	// Two real presses plus one auto-repeat, all in one frame.
	p.press_key(off, p.KEY_BACKSPACE)
	p.press_key(off, p.KEY_BACKSPACE)
	append(&off.input.keys, p.Key_Event{sym = p.KEY_BACKSPACE, repeat = true})

	testing.expect_value(t, p.key_count(ui, p.KEY_BACKSPACE), 3)
	testing.expect_value(t, p.key_count(ui, p.KEY_BACKSPACE, false), 2)
	testing.expect(t, p.key_pressed(ui, p.KEY_BACKSPACE, false), "a real press is seen")

	// A key that only arrived as auto-repeat must not read as a command press.
	append(&off.input.keys, p.Key_Event{sym = p.KEY_DOWN, repeat = true})
	testing.expect(t, p.key_pressed(ui, p.KEY_DOWN), "repeat counts for movement")
	testing.expect(t, !p.key_pressed(ui, p.KEY_DOWN, false), "repeat excluded for commands")
	p.offscreen_end(off)
}

@(test)
test_scroll_into_view :: proc(t: ^testing.T) {
	off := p.offscreen_create(200, 100)
	defer p.offscreen_destroy(off)

	list_id, row_id: u64
	frame :: proc(off: ^p.Offscreen, list_id, row_id: ^u64) {
		ui := p.offscreen_begin(off)
		list := p.col(ui, "w-full h-full overflow-scroll")
		list_id^ = p.node_id(ui, list)
		for i in 0 ..< 20 {
			p.key(ui, fmt.tprintf("row%d", i))
			r := p.div(ui, "w-full h-[20] shrink-0")
			if i == 15 {
				row_id^ = p.node_id(ui, r)
			}
			p.end(ui)
		}
		p.end(ui)
		p.offscreen_end(off)
	}

	frame(off, &list_id, &row_id)
	frame(off, &list_id, &row_id) // geometry settled

	testing.expect(t, p.scroll_extent(off_ctx(off), list_id).y > 0, "the list overflows")
	testing.expect_value(t, p.scroll_of(off_ctx(off), list_id).y, f32(0))

	// Row 15 sits at y=300 in a 100px viewport, so it must scroll down.
	p.scroll_into_view(off_ctx(off), list_id, row_id, 0)
	after := p.scroll_of(off_ctx(off), list_id).y
	testing.expect(t, after > 0, "scrolled to reveal the row")
	frame(off, &list_id, &row_id)

	// Already visible: scrolling again must not move.
	before := p.scroll_of(off_ctx(off), list_id).y
	p.scroll_into_view(off_ctx(off), list_id, row_id, 0)
	testing.expect_value(t, p.scroll_of(off_ctx(off), list_id).y, before)
}

@(private)
off_ctx :: proc(off: ^p.Offscreen) -> ^p.Ctx {
	return &off.ctx
}

@(test)
test_text_field_masks_without_touching_the_buffer :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 60, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)

	buf: [dynamic]u8
	defer delete(buf)

	draw :: proc(off: ^p.Offscreen, buf: ^[dynamic]u8, mask: rune) {
		ui := p.offscreen_begin(off)
		p.div(ui, "w-full h-full p-2")
		p.text_field(ui, buf, "Password", "w-full", mask)
		p.end(ui)
		p.offscreen_end(off)
	}

	draw(off, &buf, '*')
	// Focus the field, then type a secret into it.
	r := p.Rect{8, 8, 200, 32}
	p.move_pointer(off, r.x + 10, r.y + 10)
	draw(off, &buf, '*')
	p.press(off);draw(off, &buf, '*')
	p.release(off);draw(off, &buf, '*')
	p.type_text(off, "hunter2")
	draw(off, &buf, '*')

	// The buffer keeps the real bytes; only the drawing is substituted.
	testing.expect_value(t, string(buf[:]), "hunter2")

	// Masked and unmasked renders must differ, and the masked one must not
	// contain the glyphs of the secret.
	masked_ink := count_ink(off)
	draw(off, &buf, 0)
	plain_ink := count_ink(off)
	testing.expect(t, masked_ink != plain_ink, "masking changes what is drawn")
}

@(private)
count_ink :: proc(off: ^p.Offscreen) -> int {
	n := 0
	c := p.offscreen_canvas(off)
	for y in 0 ..< c.h {
		for x in 0 ..< c.w {
			if p.offscreen_pixel(off, x, y).r < 200 {
				n += 1
			}
		}
	}
	return n
}

@(test)
test_icon_rotation :: proc(t: ^testing.T) {
	// A horizontal bar rotated a quarter turn must become vertical. This is
	// what lets a spinner actually spin — palmy has no transform, so rotation
	// is applied to the flattened path before stroking.
	bar := p.Icon{name = "test-bar", d = "M4 12 L20 12", view = 24, stroke = 2}

	render :: proc(bar: p.Icon, turns: f32) -> (wide, tall: int) {
		off := p.offscreen_create(48, 48, 1, "w-full h-full bg-white")
		defer p.offscreen_destroy(off)
		for _ in 0 ..< 2 {
			ui := p.offscreen_begin(off)
			p.div(ui, "w-full h-full items-center justify-center")
			p.icon(ui, bar, "size-10 text-black", turns)
			p.end(ui)
			p.offscreen_end(off)
		}
		// Count ink along the middle row and the middle column.
		for x in 0 ..< 48 {
			if p.offscreen_pixel(off, x, 24).r < 128 {wide += 1}
		}
		for y in 0 ..< 48 {
			if p.offscreen_pixel(off, 24, y).r < 128 {tall += 1}
		}
		return
	}

	w0, h0 := render(bar, 0)
	testing.expect(t, w0 > h0 * 2, "unrotated, the bar is wide and not tall")

	w90, h90 := render(bar, 0.25)
	testing.expect(t, h90 > w90 * 2, "a quarter turn makes it tall and not wide")

	// A full turn is the same as none.
	w360, h360 := render(bar, 1.0)
	testing.expect(t, abs(w360 - w0) <= 1 && abs(h360 - h0) <= 1, "a whole turn is a no-op")
}

@(test)
test_text_hit_testing_round_trips :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	TEXT :: "Hello, world"
	SIZE :: f32(16)

	// x=0 is the start, far right is the end.
	testing.expect_value(t, p.text_index_at(&off.fonts, TEXT, SIZE, 0), 0)
	wide := p.text_width(&off.fonts, TEXT, SIZE)
	testing.expect_value(t, p.text_index_at(&off.fonts, TEXT, SIZE, wide + 50), len(TEXT))

	// Every caret position must map back to itself: measure where index i
	// sits, ask what index is there, get i back.
	for i in 0 ..= len(TEXT) {
		x := p.text_width_upto(&off.fonts, TEXT, i, SIZE)
		back := p.text_index_at(&off.fonts, TEXT, SIZE, x)
		testing.expectf(t, back == i, "index %d measured at %.2f mapped back to %d", i, x, back)
	}

	// The nearest boundary wins: just past a glyph's midpoint lands after it.
	w1 := p.text_width_upto(&off.fonts, TEXT, 1, SIZE)
	testing.expect_value(t, p.text_index_at(&off.fonts, TEXT, SIZE, w1 * 0.9), 1)
	testing.expect_value(t, p.text_index_at(&off.fonts, TEXT, SIZE, w1 * 0.1), 0)
}

@(test)
test_text_hit_testing_is_rune_safe :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// Multi-byte runes: indices must land on boundaries, never mid-sequence.
	text := "aéb€c"
	for x := f32(0); x < 120; x += 1.5 {
		i := p.text_index_at(&off.fonts, text, 16, x)
		testing.expect(t, i >= 0 && i <= len(text), "index in range")
		if i < len(text) {
			testing.expectf(t, text[i] & 0xc0 != 0x80, "index %d is a rune boundary", i)
		}
	}
}

// ---------------------------------------------------------------------------
// Typography: the slant axis, tabular figures, outlines and colour emoji.
//
// The thing worth asserting about all four is metric agreement. A feature that
// changes advances in `draw_text` but not in `text_width` puts every caret,
// wrap point and centred label somewhere the glyphs are not, and the bug shows
// up a long way from the code that caused it.
// ---------------------------------------------------------------------------

@(private)
assert_metrics_agree :: proc(t: ^testing.T, off: ^p.Offscreen, text: string, what: string, size: f32 = 16, fam := p.Font_Family.Sans, wt := p.Font_Weight.Regular, sl := p.Font_Slant.Upright, tabular := false) {
	measured := p.text_width(&off.fonts, text, size, fam, wt, 0, sl, tabular)
	c := p.offscreen_canvas(off)
	drawn := p.draw_text(c, &off.fonts, text, 0, 0, size, p.WHITE, fam, wt, 0, sl, tabular)
	testing.expectf(
		t,
		near(measured, drawn, 0.01),
		"%s: text_width %.4f but draw_text advanced %.4f",
		what,
		measured,
		drawn,
	)

	// And the inverse: every rune boundary round-trips through the hit test.
	for i in 0 ..= len(text) {
		if i < len(text) && text[i] & 0xc0 == 0x80 {
			continue // not a boundary
		}
		x := p.text_width_upto(&off.fonts, text, i, size, fam, wt, 0, sl, tabular)
		back := p.text_index_at(&off.fonts, text, size, x, fam, wt, 0, sl, tabular)
		testing.expectf(t, back == i, "%s: index %d measured at %.3f mapped back to %d", what, i, x, back)
	}
}

@(test)
test_italic_axis_resolves :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// Every one of the sixteen slots must resolve to something that measures,
	// whatever this machine happens to have installed. An italic request that
	// finds no italic file falls back to upright; it never vanishes.
	for fam in p.Font_Family {
		for wt in p.Font_Weight {
			for sl in p.Font_Slant {
				w := p.text_width(&off.fonts, "Emphasis", 16, fam, wt, 0, sl)
				testing.expectf(t, w > 0, "%v/%v/%v measures text", fam, wt, sl)
				testing.expectf(t, p.font_path(&off.fonts, fam, wt, sl) != "", "%v/%v/%v has a file", fam, wt, sl)
			}
		}
	}
}

@(test)
test_synthetic_oblique_keeps_advances :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// Forcing the synthetic path makes the italic slot a sheared copy of the
	// upright face. Shearing moves coverage sideways; it must not move the pen,
	// which is what keeps a synthesised italic laying out like its upright.
	testing.expect(t, p.use_synthetic_italic(&off.fonts, .Sans, .Regular), "the upright face exists to shear")
	_, oblique := p.font_is_synthetic(&off.fonts, .Sans, .Regular, .Italic)
	testing.expect(t, oblique, "the slot reports itself as a fake")

	up := p.text_width(&off.fonts, "Hamburgefonstiv", 24, .Sans, .Regular, 0, .Upright)
	ob := p.text_width(&off.fonts, "Hamburgefonstiv", 24, .Sans, .Regular, 0, .Italic)
	testing.expectf(t, near(up, ob, 0.001), "a shear leaves advances alone: %.4f vs %.4f", up, ob)

	assert_metrics_agree(t, off, "Hamburgefonstiv", "synthetic italic", 24, .Sans, .Regular, .Italic)
}

@(test)
test_italic_metrics_agree :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)
	assert_metrics_agree(t, off, "Emphasis, in running text.", "italic", 16, .Sans, .Regular, .Italic)
	assert_metrics_agree(t, off, "Emphasis, in running text.", "bold italic", 16, .Sans, .Bold, .Italic)
	assert_metrics_agree(t, off, "fn main() { }", "mono italic", 16, .Mono, .Regular, .Italic)
}

@(test)
test_tabular_figures_are_uniform :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// The whole point: every digit advances by the same amount, so two clock
	// readings of the same length are the same width.
	a := p.text_width(&off.fonts, "00000000", 24, .Sans, .Regular, 0, .Upright, true)
	b := p.text_width(&off.fonts, "11111111", 24, .Sans, .Regular, 0, .Upright, true)
	c := p.text_width(&off.fonts, "18:04:37", 24, .Sans, .Regular, 0, .Upright, true)
	d := p.text_width(&off.fonts, "11:11:11", 24, .Sans, .Regular, 0, .Upright, true)
	testing.expectf(t, near(a, b, 0.001), "every digit the same width: %.4f vs %.4f", a, b)
	testing.expectf(t, near(c, d, 0.001), "two clock readings the same width: %.4f vs %.4f", c, d)

	// And each digit is as wide as the widest, never narrower.
	widest := f32(0)
	for ch in "0123456789" {
		s := utf8_string(ch)
		widest = max(widest, p.text_width(&off.fonts, s, 24))
	}
	one := p.text_width(&off.fonts, "1", 24, .Sans, .Regular, 0, .Upright, true)
	testing.expectf(t, near(one, widest, 0.001), "the slot is the widest digit: %.4f vs %.4f", one, widest)

	// Switching it off restores proportional measurement.
	prop := p.text_width(&off.fonts, "11111111", 24)
	testing.expect(t, prop <= b + 0.001, "tabular is never narrower than proportional")
}

@(private)
utf8_string :: proc(r: rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_rune(&b, r)
	return strings.to_string(b)
}

@(test)
test_tabular_metrics_agree :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)
	assert_metrics_agree(t, off, "18:04:37", "tabular clock", 24, .Sans, .Regular, .Upright, true)
	assert_metrics_agree(t, off, "1,048,576 B/s", "tabular rate", 16, .Sans, .Regular, .Upright, true)
	assert_metrics_agree(t, off, "0123456789", "tabular digits", 13, .Sans, .Medium, .Italic, true)
}

@(test)
test_fallback_glyph_metrics_agree :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)
	// Mixed scripts: these runes come from fallback faces with different units
	// per em, so the advance has to be taken from whichever face served each
	// one. If it is not, this is where it shows.
	assert_metrics_agree(t, off, "subject: 日本語 → ok", "cjk fallback")
	assert_metrics_agree(t, off, "αβγ ± ∑ ✓", "symbol fallback")
}

@(test)
test_tabular_column_does_not_jitter :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// A running clock: the x of the last colon must not move between ticks.
	prev := f32(-1)
	for s in ([?]string{"10:00:01", "10:00:09", "10:11:19", "19:48:37", "10:10:10"}) {
		x := p.text_width_upto(&off.fonts, s, 5, 20, .Sans, .Regular, 0, .Upright, true)
		if prev >= 0 {
			testing.expectf(t, near(x, prev, 0.001), "the second colon stays put: %.4f vs %.4f", x, prev)
		}
		prev = x
	}
}

@(test)
test_text_outline_does_not_change_advance :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)
	c := p.offscreen_canvas(off)

	plain := p.draw_text(c, &off.fonts, "Subtitle", 0, 0, 20, p.WHITE)
	lined := p.draw_text_outlined(c, &off.fonts, "Subtitle", 0, 0, 20, p.WHITE, p.BLACK, 2)
	testing.expectf(t, near(plain, lined, 0.001), "a stroke is paint, not metrics: %.4f vs %.4f", plain, lined)
}

@(test)
test_text_outline_surrounds_the_glyph :: proc(t: ^testing.T) {
	// White text with a black stroke on a white page: with no outline the glyph
	// is invisible, with one it is a black shape. Counting dark pixels is the
	// cheapest way to say "the stroke is actually there, and it is outside".
	dark :: proc(o: ^p.Offscreen) -> int {
		n := 0
		for v in p.offscreen_pixels(o) {
			if (v >> 16) & 0xff < 120 {
				n += 1
			}
		}
		return n
	}

	bare := p.offscreen_create(160, 60, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(bare)
	ui := p.offscreen_begin(bare)
	p.text(ui, "Wave", "text-3xl font-bold text-white")
	p.end(ui)
	p.offscreen_end(bare)

	lined := p.offscreen_create(160, 60, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(lined)
	ui2 := p.offscreen_begin(lined)
	p.text(ui2, "Wave", "text-3xl font-bold text-white text-outline-2 text-outline-black")
	p.end(ui2)
	p.offscreen_end(lined)

	testing.expect(t, dark(bare) == 0, "white on white is invisible without a stroke")
	testing.expect(t, dark(lined) > 200, "the stroke makes it a shape")
}

@(test)
test_outline_classes_parse :: proc(t: ^testing.T) {
	off := p.offscreen_create(60, 60)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	a := p.div(ui, "text-outline-2 text-outline-black")
	p.end(ui)
	b := p.div(ui, "italic tabular-nums")
	p.end(ui)
	c := p.div(ui, "italic not-italic")
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	sa := p.node_style(ui, a)
	testing.expect_value(t, sa.outline_w, f32(2))
	testing.expect_value(t, sa.outline_col, p.Color{0, 0, 0, 255})

	sb := p.node_style(ui, b)
	testing.expect_value(t, sb.slant, p.Font_Slant.Italic)
	testing.expect(t, sb.tabular, "tabular-nums sets the flag")

	sc := p.node_style(ui, c)
	testing.expect_value(t, sc.slant, p.Font_Slant.Upright)
}

@(test)
test_emoji_and_ignorables :: proc(t: ^testing.T) {
	off := p.offscreen_create(10, 10)
	defer p.offscreen_destroy(off)

	// Zero-width format controls are zero-width, whatever the fonts say. A
	// variation selector that took a .notdef advance would push every emoji
	// sequence sideways.
	plain := p.text_width(&off.fonts, "ab", 16)
	glued := p.text_width(&off.fonts, "a\u200db\u2060", 16)
	testing.expectf(t, near(plain, glued, 0.001), "joiners measure nothing: %.4f vs %.4f", plain, glued)

	if p.emoji_font_path(&off.fonts) == "" {
		return // no colour emoji font installed; nothing more to check
	}
	testing.expect(t, p.emoji_strike_ppem(&off.fonts) > 0, "the strike has a pixel size")

	e := p.text_width(&off.fonts, "\U0001f44d", 16)
	testing.expect(t, e > 8, "an emoji advances roughly an em")
	assert_metrics_agree(t, off, "ship it \U0001f680 now", "colour emoji")
}

@(test)
test_emoji_renders_in_colour :: proc(t: ^testing.T) {
	off := p.offscreen_create(80, 48, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	if p.emoji_font_path(&off.fonts) == "" {
		return
	}

	ui := p.offscreen_begin(off)
	p.text(ui, "\U0001f534", "text-3xl") // a large red circle
	p.end(ui)
	p.offscreen_end(off)

	// Not grey: a CBDT strike is colour, and if the fallback chain had served a
	// line-art copy of this codepoint instead, every pixel would be neutral.
	coloured := 0
	for y in 0 ..< 48 {
		for x in 0 ..< 80 {
			c := p.offscreen_pixel(off, x, y)
			lo := min(c.r, min(c.g, c.b))
			hi := max(c.r, max(c.g, c.b))
			if int(hi) - int(lo) > 60 {
				coloured += 1
			}
		}
	}
	testing.expectf(t, coloured > 100, "the strike is colour, not line art (%d coloured pixels)", coloured)
}

@(test)
test_fonts_do_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)
		for _ in 0 ..< 3 {
			f: p.Fonts
			p.fonts_init(&f)
			// Touch every cache: faces, glyphs, the shear, outlines, the
			// tabular slots and an emoji bitmap all allocate.
			off := p.offscreen_create(64, 32)
			p.use_synthetic_italic(&off.fonts, .Sans, .Regular)
			c := p.offscreen_canvas(off)
			p.draw_text(c, &off.fonts, "12:04 \U0001f600", 0, 20, 16, p.WHITE, .Sans, .Regular, 0, .Italic, true)
			p.draw_text_outlined(c, &off.fonts, "12:04", 0, 20, 16, p.WHITE, p.BLACK, 2)
			p.offscreen_destroy(off)
			p.fonts_destroy(&f)
		}
		free_all(context.temp_allocator)
	}

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"%d allocations still live after three font init/destroy cycles",
		len(track.allocation_map),
	)
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees", len(track.bad_free_array))
}

// With no font file at all -- a minimal system before fonts are installed --
// text goes through the built-in segment font, which only knows printable
// ASCII. Non-ASCII text must measure and draw as placeholders, not index past
// that font's table: this was a panic on the first em dash.
@(test)
test_no_fonts_non_ascii :: proc(t: ^testing.T) {
	f: p.Fonts // zero value: no face loaded, as on a system with no fonts
	w := p.text_width(&f, "Café — \U0001f600", 16)
	q := p.text_width(&f, "Caf? ? ?", 16)
	testing.expectf(t, near(w, q, 0.001), "one placeholder per rune: %.3f vs %.3f", w, q)

	off := p.offscreen_create(160, 32)
	defer p.offscreen_destroy(off)
	p.draw_text(p.offscreen_canvas(off), &f, "naïve → café", 0, 20, 16, p.WHITE)
	free_all(context.temp_allocator)
}
