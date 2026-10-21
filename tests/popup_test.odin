// Popups (palmy/popup.odin): the placement rules, the in-window fallback that
// offscreen rendering and X11 use, and the real xdg_popup on a Wayland
// compositor (tests/wl_server.odin), from the request that creates it to the
// pixels it commits and the click that lands on it outside the window.
package palmy_tests

import "core:testing"
import p "../palmy"

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------

@(test)
test_popup_place_follows_side_and_align :: proc(t: ^testing.T) {
	bounds := p.Rect{0, 0, 800, 600}
	anchor := p.Rect{100, 100, 80, 30}
	size := [2]f32{200, 120}

	r := p.popup_place(anchor, size, p.POPUP_MENU, bounds)
	testing.expect_value(t, r, p.Rect{100, 134, 200, 120}) // under it, left edges together, 4 px gap

	o := p.POPUP_MENU
	o.align = .End
	r = p.popup_place(anchor, size, o, bounds)
	testing.expect_value(t, r, p.Rect{0, 134, 200, 120}) // right edges together would start at -20: slid back inside

	o.align = .Center
	r = p.popup_place(anchor, size, o, bounds)
	testing.expect_value(t, r, p.Rect{40, 134, 200, 120})

	r = p.popup_place(anchor, {40, 20}, p.POPUP_TOOLTIP, bounds)
	testing.expect_value(t, r, p.Rect{120, 74, 40, 20}) // above, centred, 6 px gap

	o = p.POPUP_MENU
	o.side = .Right
	r = p.popup_place(anchor, size, o, bounds)
	testing.expect_value(t, r, p.Rect{184, 100, 200, 120})
}

@(test)
test_popup_place_flips_and_slides :: proc(t: ^testing.T) {
	bounds := p.Rect{0, 0, 400, 300}
	// A trigger near the bottom: the menu does not fit under it, so it flips.
	r := p.popup_place({20, 240, 100, 30}, {120, 90}, p.POPUP_MENU, bounds)
	testing.expect_value(t, r, p.Rect{20, 146, 120, 90})

	// A tooltip on a trigger at the top flips below it.
	r = p.popup_place({20, 10, 100, 30}, {200, 24}, p.POPUP_TOOLTIP, bounds)
	testing.expect_value(t, r, p.Rect{0, 46, 200, 24})

	// Near the right edge it slides left along the cross axis.
	r = p.popup_place({350, 50, 40, 20}, {150, 60}, p.POPUP_MENU, bounds)
	testing.expect_value(t, r, p.Rect{250, 74, 150, 60})

	// Too tall for either side: it stays on the side asked for, pinned to
	// the top edge rather than falling off it.
	r = p.popup_place({20, 100, 100, 30}, {120, 400}, p.POPUP_MENU, bounds)
	testing.expect_value(t, r.y, 0)
}

@(test)
test_popup_anchor_gravity_match_xdg_positioner :: proc(t: ^testing.T) {
	// 1 top, 2 bottom, 3 left, 4 right, 5 top-left, 6 bottom-left,
	// 7 top-right, 8 bottom-right.
	a, g := p.popup_anchor_gravity(p.POPUP_MENU)
	testing.expect_value(t, [2]u32{a, g}, [2]u32{6, 8})
	a, g = p.popup_anchor_gravity(p.POPUP_TOOLTIP)
	testing.expect_value(t, [2]u32{a, g}, [2]u32{1, 1})
	a, g = p.popup_anchor_gravity({side = .Right, align = .Start})
	testing.expect_value(t, [2]u32{a, g}, [2]u32{7, 8})
	a, g = p.popup_anchor_gravity({side = .Bottom, align = .End})
	testing.expect_value(t, [2]u32{a, g}, [2]u32{8, 6})
}

// ---------------------------------------------------------------------------
// In the window (offscreen, X11)
// ---------------------------------------------------------------------------

Popup_Menu_State :: struct {
	open:      bool,
	picked:    string,
	trigger:   u64,
	behind:    int, // clicks on a button the popup covers
	dismissed: int,
}

POPUP_ITEMS := [3]string{"one", "two", "three"}

popup_menu_ui :: proc(ui: ^p.Ctx, st: ^Popup_Menu_State) {
	// Something the popup will cover when it opens upwards.
	p.div(ui, "absolute left-[20] top-[150] w-[200] h-[60] bg-slate-700")
	if p.clickable(ui) {
		st.behind += 1
	}
	p.end(ui)

	tr := p.div(ui, "absolute left-[20] top-[240] w-[100] h-[30] bg-sky-600")
	st.trigger = p.node_id(ui, tr)
	if p.clickable(ui) {
		st.open = !st.open
	}
	p.end(ui)

	if st.open {
		if p.popup_begin(ui, p.rect_of(ui, st.trigger), p.POPUP_MENU) {
			st.open = false
			st.dismissed += 1
		}
		p.div(ui, "w-[120] flex-col bg-white rounded-md p-1")
		for it in POPUP_ITEMS {
			p.key(ui, it)
			p.div(ui, "w-full h-[30] bg-white hover:bg-amber-300")
			if p.clickable(ui) {
				st.picked = it
				st.open = false
			}
			p.end(ui)
		}
		p.end(ui)
		p.popup_end(ui)
	}
}

@(private = "file")
off_frame :: proc(off: ^p.Offscreen, st: ^Popup_Menu_State) {
	ui := p.offscreen_begin(off)
	popup_menu_ui(ui, st)
	p.offscreen_end(off)
}

@(private = "file")
off_click :: proc(off: ^p.Offscreen, st: ^Popup_Menu_State, x, y: f32) {
	p.move_pointer(off, x, y)
	off_frame(off, st)
	p.press(off)
	off_frame(off, st)
	p.release(off)
	off_frame(off, st)
}

@(test)
test_popup_in_window_flips_paints_on_top_and_takes_clicks :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 300)
	defer p.offscreen_destroy(off)
	st: Popup_Menu_State
	off_frame(off, &st)
	off_click(off, &st, 50, 250)
	testing.expect(t, st.open, "the trigger opened it")
	off_frame(off, &st)

	// No room under the trigger in a 300 px window: it opened upwards,
	// over the slate box, and is painted on top of it.
	px := p.offscreen_pixels(off)
	at :: proc(px: []u32, x, y: int) -> u32 {
		return px[y * 400 + x] & 0xffffff
	}
	testing.expect_value(t, at(px, 60, 160), 0xffffff) // the popup's first item, white
	testing.expect_value(t, at(px, 180, 160), 0x334155) // the box beside it, slate-700

	// It sits at y 138 (240 - 4 - 98); its second item is at 138 + 4 + 30..60.
	off_click(off, &st, 60, 190)
	testing.expect_value(t, st.picked, "two")
	testing.expect(t, !st.open)
	testing.expect_value(t, st.behind, 0) // the box under the popup heard nothing
}

@(test)
test_popup_in_window_click_outside_dismisses_and_is_consumed :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 300)
	defer p.offscreen_destroy(off)
	st: Popup_Menu_State
	off_frame(off, &st)
	off_click(off, &st, 50, 250)
	off_frame(off, &st)
	testing.expect(t, st.open)

	// Clicking the trigger again closes it: the press is the popup's
	// dismissal, and the trigger does not see a click to toggle it back.
	off_click(off, &st, 50, 250)
	testing.expect(t, !st.open, "closed by the click away")
	testing.expect_value(t, st.dismissed, 1)

	// And with nothing open, the box is clickable as usual.
	off_click(off, &st, 200, 160)
	testing.expect_value(t, st.behind, 1)
}

// Nothing about a frame without a popup changes: the parity suite holds this
// for 182 renders; this holds it for a frame that has one and then not.
@(test)
test_popup_closed_leaves_no_trace :: proc(t: ^testing.T) {
	a := p.offscreen_create(200, 120)
	defer p.offscreen_destroy(a)
	ui := p.offscreen_begin(a)
	p.div(ui, "w-full h-full bg-slate-800")
	p.end(ui)
	p.offscreen_end(a)
	before := make([]u32, len(p.offscreen_pixels(a)))
	defer delete(before)
	copy(before, p.offscreen_pixels(a))

	ui = p.offscreen_begin(a)
	p.div(ui, "w-full h-full bg-slate-800")
	p.end(ui)
	p.popup_begin(ui, {10, 10, 20, 20})
	p.div(ui, "w-[50] h-[20] bg-white")
	p.end(ui)
	p.popup_end(ui)
	p.offscreen_end(a)

	ui = p.offscreen_begin(a)
	p.div(ui, "w-full h-full bg-slate-800")
	p.end(ui)
	p.offscreen_end(a)
	same := true
	for v, i in p.offscreen_pixels(a) {
		if v != before[i] {
			same = false
			break
		}
	}
	testing.expect(t, same)
}

