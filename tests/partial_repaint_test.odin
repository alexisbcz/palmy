// A frame that differs from the last in a few places is repainted only there
// (palmy/damage.odin, "Partial repaint"). The claim that makes this safe is
// that the result is the same, pixel for pixel, as painting the whole frame,
// so every test here drives two renderers through the same frames -- one
// painting whole, one partially -- and compares every pixel of every frame.
// The other assertions say the partial one actually did less: a caret blink
// repaints the caret and nothing else.
package palmy_tests

import "core:testing"
import p "../palmy"

@(private = "file")
Scene :: struct {
	field:   [dynamic]u8,
	notes:   [dynamic]u8,
	canvas:  int, // what the `pixels` node draws, and its key
	keyed:   bool,
	extra:   bool, // a whole subtree that comes and goes
	glow:    bool, // a transition starts
	label:   string,
	scroll:  f32,
	list_id: u64,
	marker:  bool, // a leaf beside the shadowed card
	count:   int,  // a tabular number: a new value is exactly as wide
}

@(private = "file")
scene_destroy :: proc(s: ^Scene) {
	delete(s.field)
	delete(s.notes)
}

@(private = "file")
draw_canvas :: proc(c: ^p.Canvas, r: p.Rect, n: ^int) {
	p.fill_rect(c, r, p.hex(0x0f172a))
	for k in 0 ..< 6 {
		x := r.x + f32((k * 37 + n^ * 11) % int(max(r.w - 12, 1)))
		p.fill_round_rect(c, {x, r.y + f32(k) * 9 + 4, 12, 6}, {3, 3, 3, 3}, p.hex(0x38bdf8))
	}
}

@(private = "file")
build :: proc(off: ^p.Offscreen, s: ^Scene) -> ^p.Ctx {
	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-full p-3 gap-3")
	p.text(ui, s.label, "text-lg font-semibold")
	p.textf(ui, "text-sm tabular-nums", "Count %d", s.count)
	p.row(ui, "w-full gap-3 items-start")
	p.col(ui, "w-[220] gap-2 p-3 rounded-xl bg-white shadow-lg ring-1 ring-slate-200")
	p.text(ui, "Name", "text-xs text-slate-500")
	p.text_field(ui, &s.field, "Type a name", "w-full")
	p.text(ui, "Emoji 👩🏽‍💻 🇫🇷 sit inside the card", "text-sm")
	p.end(ui)
	// A leaf next to the card, inside the reach of its shadow.
	if s.marker {
		p.div(ui, "w-[10] h-[40] bg-rose-500")
		p.end(ui)
	}
	cls := s.glow ? "w-[90] h-[40] rounded-lg bg-indigo-600 transition duration-1000" : "w-[90] h-[40] rounded-lg bg-slate-300 transition duration-1000"
	p.div(ui, cls)
	p.end(ui)
	p.end(ui)
	idx := p.pixels(ui, "w-[200] h-[60] rounded-md overflow-hidden", &s.canvas, draw_canvas)
	if s.keyed {
		p.paint_key(ui, u64(s.canvas) + 1, idx)
	}
	if s.extra {
		p.row(ui, "gap-2")
		p.text(ui, "an extra row", "text-sm")
		p.text(ui, "with two labels", "text-sm text-slate-500")
		p.end(ui)
	}
	list := p.col(ui, "w-[260] h-[90] overflow-scroll border border-slate-300 rounded-md")
	s.list_id = p.node_id(ui, list)
	for k in 0 ..< 12 {
		p.textf(ui, "text-sm px-2 py-1", "row %d", k)
	}
	p.end(ui)
	p.text_area(ui, &s.notes, "Notes", "w-[300] h-[60]")
	p.end(ui)
	return ui
}

// Two renderers, one painting whole and one partially, driven identically.
@(private = "file")
Pair :: struct {
	whole, part: ^p.Offscreen,
	a, b:        Scene,
}

@(private = "file")
pair_make :: proc(dt: f32 = 0.3) -> ^Pair {
	pr := new(Pair)
	pr.whole = p.offscreen_create(560, 520, 1, "w-full h-full bg-slate-50 text-slate-900")
	pr.part = p.offscreen_create(560, 520, 1, "w-full h-full bg-slate-50 text-slate-900")
	pr.whole.dt, pr.part.dt = dt, dt
	for s in ([?]^Scene{&pr.a, &pr.b}) {
		s.label = "Partial repaint"
		s.keyed = true
		append(&s.field, "palmy")
		append(&s.notes, "one\ntwo")
	}
	return pr
}

@(private = "file")
pair_destroy :: proc(pr: ^Pair) {
	p.offscreen_destroy(pr.whole)
	p.offscreen_destroy(pr.part)
	scene_destroy(&pr.a)
	scene_destroy(&pr.b)
	free(pr)
}

// pair_frame runs one frame on both and returns what the partial one did, and
// how many pixels the two disagree on.
@(private = "file")
pair_frame :: proc(pr: ^Pair, change: proc(s: ^Scene, ui: ^p.Ctx) = nil) -> (region: p.Damage_Rect, partial: bool, bad: int) {
	ui := build(pr.whole, &pr.a)
	if change != nil {
		change(&pr.a, ui)
	}
	p.offscreen_end(pr.whole)
	ui = build(pr.part, &pr.b)
	if change != nil {
		change(&pr.b, ui)
	}
	region, partial = p.offscreen_end_partial(pr.part)
	wp, pp := p.offscreen_pixels(pr.whole), p.offscreen_pixels(pr.part)
	for k in 0 ..< len(wp) {
		if wp[k] != pp[k] {
			bad += 1
		}
	}
	return
}

@(private = "file")
both :: proc(pr: ^Pair, f: proc(s: ^Scene)) {
	f(&pr.a)
	f(&pr.b)
}

@(test)
test_partial_repaint_caret_blink_repaints_only_the_caret :: proc(t: ^testing.T) {
	pr := pair_make()
	defer pair_destroy(pr)

	pair_frame(pr)
	pair_frame(pr)
	// Tab into the field: the caret appears and starts blinking.
	p.press_key(pr.whole, p.KEY_TAB)
	p.press_key(pr.part, p.KEY_TAB)
	pair_frame(pr)
	_, _, bad := pair_frame(pr)
	testing.expect_value(t, bad, 0)

	blinks := 0
	for k in 0 ..< 12 {
		region, partial, bad := pair_frame(pr)
		testing.expectf(t, bad == 0, "frame %d: partial and whole paints differ in %d pixels", k, bad)
		testing.expectf(t, partial, "frame %d: an idle blinking field is repainted partially (%s)", k, p.offscreen_repaint_why(pr.part))
		area := region.w * region.h
		if area > 0 {
			blinks += 1
			// The caret is 1.5 x ~20 logical pixels; with its antialiasing
			// margin the region is a few pixels wide, never the field.
			testing.expectf(t, region.w <= 8 && region.h <= 40, "frame %d: the repaint is the caret, not %v", k, region)
		}
	}
	testing.expectf(t, blinks >= 4, "the caret blinked (%d repaints in 12 frames of 0.3 s)", blinks)
}

@(test)
test_partial_repaint_matches_a_whole_paint :: proc(t: ^testing.T) {
	pr := pair_make()
	defer pair_destroy(pr)
	pair_frame(pr)
	pair_frame(pr)

	check :: proc(t: ^testing.T, pr: ^Pair, what: string, want_partial: Maybe(bool), f: proc(s: ^Scene)) {
		if f != nil {
			both(pr, f)
		}
		region, partial, bad := pair_frame(pr)
		testing.expectf(t, bad == 0, "%s: partial and whole paints differ in %d pixels", what, bad)
		if w, ok := want_partial.?; ok {
			testing.expectf(t, partial == w, "%s: partial = %v, wanted %v (%v; %s)", what, partial, w, region, p.offscreen_repaint_why(pr.part))
		}
		// And the next, unchanged frame is partial and empty.
		_, again, bad2 := pair_frame(pr)
		testing.expectf(t, bad2 == 0 && again, "%s: the frame after is partial and equal (%d)", what, bad2)
	}

	check(t, pr, "a label changes", true, proc(s: ^Scene) {s.label = "Partial repaint, retitled"})
	check(t, pr, "a number changes to one exactly as wide", true, proc(s: ^Scene) {s.count = 7})
	check(t, pr, "a leaf inside a shadow's reach appears", true, proc(s: ^Scene) {s.marker = true})
	check(t, pr, "and goes", true, proc(s: ^Scene) {s.marker = false})
	check(t, pr, "a keyed canvas changes its key", true, proc(s: ^Scene) {s.canvas += 1})
	check(t, pr, "a subtree appears", false, proc(s: ^Scene) {s.extra = true})
	check(t, pr, "and goes", false, proc(s: ^Scene) {s.extra = false})
	// A transition: the frame its target changes is partial (the node is
	// damage), then every frame while it moves is whole, because the colour
	// it paints is no longer a function of the tree.
	both(pr, proc(s: ^Scene) {s.glow = true})
	_, partial, bad := pair_frame(pr)
	testing.expectf(t, partial && bad == 0, "a transition's first frame is partial and equal (%v, %d)", partial, bad)
	_, partial, bad = pair_frame(pr)
	testing.expectf(t, !partial && bad == 0, "a moving transition paints whole (%v, %d)", partial, bad)
	for _ in 0 ..< 30 {
		_, _, bad = pair_frame(pr)
		testing.expect_value(t, bad, 0)
	}
	_, partial, _ = pair_frame(pr)
	testing.expect(t, partial, "once it lands, partial again")

	// Typing changes the field's text and moves the caret.
	p.press_key(pr.whole, p.KEY_TAB)
	p.press_key(pr.part, p.KEY_TAB)
	pair_frame(pr)
	p.type_text(pr.whole, "-01")
	p.type_text(pr.part, "-01")
	check(t, pr, "typing", nil, nil)
	testing.expect_value(t, string(pr.b.field[:]), "palmy-01")
}

@(test)
test_partial_repaint_scrolls_and_unknown_canvases :: proc(t: ^testing.T) {
	pr := pair_make()
	defer pair_destroy(pr)
	pair_frame(pr)
	pair_frame(pr)

	// Scrolling moves the rows and the thumb; both are damage.
	for k in 1 ..= 4 {
		region, partial, bad := pair_frame(pr, proc(s: ^Scene, ui: ^p.Ctx) {p.scroll_to(ui, s.list_id, {0, 30})})
		testing.expectf(t, bad == 0, "scrolled frame %d differs in %d pixels (partial %v, %v)", k, bad, partial, region)
	}

	// An unkeyed canvas is repainted every frame: palmy cannot see what its
	// procedure depends on. Its key withdrawn, it is in every region.
	both(pr, proc(s: ^Scene) {s.keyed = false})
	pair_frame(pr)
	for k in 0 ..< 3 {
		region, partial, bad := pair_frame(pr)
		testing.expectf(t, bad == 0, "unkeyed frame %d differs in %d pixels", k, bad)
		testing.expectf(t, partial && region.w >= 200 && region.h >= 60, "unkeyed frame %d repaints the canvas (%v %v)", k, partial, region)
	}
	// And an unkeyed canvas that really changed shows the change.
	_, _, bad := pair_frame(pr, proc(s: ^Scene, ui: ^p.Ctx) {s.canvas += 3})
	testing.expect_value(t, bad, 0)
}

// The cases that must fall back to a whole paint do, and say why.
@(test)
test_partial_repaint_falls_back :: proc(t: ^testing.T) {
	off := p.offscreen_create(200, 100, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	draw :: proc(off: ^p.Offscreen, label: string) -> (p.Damage_Rect, bool) {
		ui := p.offscreen_begin(off)
		p.text(ui, label)
		return p.offscreen_end_partial(off)
	}
	_, partial := draw(off, "a")
	testing.expect(t, !partial, "the first frame is whole")
	_, partial = draw(off, "a")
	testing.expect(t, partial, "an identical frame is partial")

	// A frame built and not painted breaks the chain.
	ui := p.offscreen_begin(off)
	p.text(ui, "b")
	_, partial = draw(off, "b")
	testing.expectf(t, !partial, "after an unpainted frame, whole (%s)", p.offscreen_repaint_why(off))

	// New faces draw the same text differently.
	_, partial = draw(off, "b")
	testing.expect(t, partial, "partial again")
	p.use_synthetic_italic(p.offscreen_fonts(off), .Sans, .Regular)
	_, partial = draw(off, "b")
	testing.expectf(t, !partial, "after a font change, whole (%s)", p.offscreen_repaint_why(off))

	// A translucent root blends onto whatever the buffer held.
	glass := p.offscreen_create(200, 100, 1, "w-full h-full bg-white/50")
	defer p.offscreen_destroy(glass)
	draw(glass, "a")
	_, partial = draw(glass, "a")
	testing.expectf(t, !partial, "a translucent root is painted whole (%s)", p.offscreen_repaint_why(glass))
}
