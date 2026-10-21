// Popups (palmy/popup.odin): the placement rules, the in-window fallback that
// offscreen rendering and X11 use, and the real xdg_popup on a Wayland
// compositor (tests/wl_server.odin), from the request that creates it to the
// pixels it commits and the click that lands on it outside the window.
package palmy_tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import "core:time"
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

@(private = "file")
Menu_State :: struct {
	open:      bool,
	picked:    string,
	trigger:   u64,
	behind:    int, // clicks on a button the popup covers
	dismissed: int,
}

@(private = "file")
ITEMS := [3]string{"one", "two", "three"}

@(private = "file")
menu_ui :: proc(ui: ^p.Ctx, st: ^Menu_State) {
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
		for it in ITEMS {
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
off_frame :: proc(off: ^p.Offscreen, st: ^Menu_State) {
	ui := p.offscreen_begin(off)
	menu_ui(ui, st)
	p.offscreen_end(off)
}

@(private = "file")
off_click :: proc(off: ^p.Offscreen, st: ^Menu_State, x, y: f32) {
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
	st: Menu_State
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
	st: Menu_State
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

// ---------------------------------------------------------------------------
// A real xdg_popup
// ---------------------------------------------------------------------------

@(private = "file")
watchdog :: proc(done: ^bool) {
	for _ in 0 ..< 3000 {
		if done^ {
			return
		}
		time.sleep(10 * time.Millisecond)
	}
	fmt.eprintln("popup test: the frame loop hung for 30 s")
	os.exit(1)
}

@(private = "file")
run_until :: proc(app: ^p.App, st: ^Menu_State, srv: ^Wl_Server, max_frames: int, cond: proc(s: ^Wl_Server, st: ^Menu_State) -> bool) -> bool {
	for _ in 0 ..< max_frames {
		ui, ok := p.frames(app)
		if !ok {
			return false
		}
		menu_ui(ui, st)
		// Keep the loop turning, so that waiting for the compositor never
		// parks it on an event that is not coming.
		p.redraw(ui)
		sync_ok: bool
		{
			// The condition reads the server's state under its lock.
			Pack :: struct {
				st:  ^Menu_State,
				ok:  bool,
				cond: proc(s: ^Wl_Server, st: ^Menu_State) -> bool,
			}
			pk := Pack{st = st, cond = cond}
			server_with(srv, &pk, proc(s: ^Wl_Server, user: rawptr) {
				pk := (^Pack)(user)
				pk.ok = pk.cond(s, pk.st)
			})
			sync_ok = pk.ok
		}
		if sync_ok {
			return true
		}
	}
	return false
}

@(private = "file")
popup_committed :: proc(s: ^Wl_Server, st: ^Menu_State) -> bool {
	for c in s.commits {
		for pp in s.popups {
			if c.surface == pp.surface && !pp.destroyed {
				return true
			}
		}
	}
	return false
}

@(test)
test_popup_on_wayland_is_a_real_xdg_popup :: proc(t: ^testing.T) {
	done := false
	dog := thread.create_and_start_with_data(&done, proc(d: rawptr) {watchdog((^bool)(d))})
	defer {
		done = true
		thread.join(dog)
		thread.destroy(dog)
	}

	srv := server_start(2)
	defer server_stop(srv)
	os.set_env("PALMY_POPUPS", "")
	app, err := p.create({title = "popup test", app_id = "popup-test", width = 400, height = 300})
	testing.expect_value(t, err, "")
	if err != "" {
		return
	}
	defer p.destroy(app)

	st: Menu_State
	ui, ok := p.frames(app)
	testing.expect(t, ok)
	menu_ui(ui, &st)

	// A click on the trigger, through the server's pointer.
	press := server_next_serial(srv)
	server_send(srv, srv.pointer, 0, server_next_serial(srv), p.Obj(srv.toplevel_surface), fx(50), fx(250)) // enter
	server_send(srv, srv.pointer, 3, press, u32(0), u32(0x110), u32(1))
	server_send(srv, srv.pointer, 3, server_next_serial(srv), u32(0), u32(0x110), u32(0))
	testing.expect(t, run_until(app, &st, srv, 200, popup_committed), "the popup was created, configured and painted")
	testing.expect(t, st.open)

	pp: Srv_Popup
	commit: Srv_Commit
	{
		// Read the server's record of it.
		Out :: struct {
			pp: Srv_Popup,
			c:  Srv_Commit,
			px: [3]u32,
		}
		o: Out
		server_with(srv, &o, proc(s: ^Wl_Server, user: rawptr) {
			o := (^Out)(user)
			o.pp = s.popups[len(s.popups) - 1]
			for c in s.commits {
				if c.surface == o.pp.surface {
					o.c = c
				}
			}
			if len(o.c.px) > 0 {
				w := o.c.w
				o.px = {o.c.px[0], o.c.px[(16 + 4 + 45) * w + 16 + 60], o.c.px[(16 + 97) * w + 16]}
			}
			o.c.px = nil
		})
		pp, commit = o.pp, o.c
		testing.expect_value(t, o.px[0] >> 24, 0) // the margin is transparent
		testing.expect_value(t, o.px[1], 0xffffffff) // the middle item, opaque white
		testing.expect(t, o.px[2] >> 24 < 255, "the rounded corner lets the desktop through")
	}
	testing.expect_value(t, pp.parent, srv.toplevel_xdg)
	testing.expect_value(t, pp.pos.size, [2]i32{120, 98})
	testing.expect_value(t, pp.pos.anchor, [4]i32{20, 240, 100, 30})
	testing.expect_value(t, pp.pos.anc, 6)
	testing.expect_value(t, pp.pos.grav, 8)
	testing.expect_value(t, pp.pos.adjust, 15) // slide and flip, both axes
	testing.expect_value(t, pp.pos.offset, [2]i32{0, 4})
	testing.expect_value(t, pp.grab, press) // the grab names the press that opened it
	testing.expect_value(t, pp.rect, [4]i32{20, 274, 120, 98}) // past the window's bottom edge
	testing.expect_value(t, commit.format, 0) // ARGB8888
	testing.expect_value(t, [2]int{commit.w, commit.h}, [2]int{152, 130})
	testing.expect_value(t, commit.geometry, [4]i32{16, 16, 120, 98})
	testing.expect(t, commit.acked != 0, "the configure was acknowledged")

	// The pointer goes onto the popup -- outside the window -- and clicks the
	// second item. Its coordinates are the popup's own.
	server_send(srv, srv.pointer, 1, server_next_serial(srv), p.Obj(srv.toplevel_surface)) // leave
	server_send(srv, srv.pointer, 0, server_next_serial(srv), p.Obj(pp.surface), fx(16 + 60), fx(16 + 4 + 45)) // enter
	server_send(srv, srv.pointer, 3, server_next_serial(srv), u32(0), u32(0x110), u32(1))
	server_send(srv, srv.pointer, 3, server_next_serial(srv), u32(0), u32(0x110), u32(0))
	picked := run_until(app, &st, srv, 200, proc(s: ^Wl_Server, st: ^Menu_State) -> bool {
		return st.picked != "" && s.popups[len(s.popups) - 1].destroyed
	})
	testing.expect(t, picked, "the click on the popup picked an item and the popup went away")
	testing.expect_value(t, st.picked, "two")
	testing.expect_value(t, st.behind, 0)

	// Open it again and let the compositor dismiss it (a click into
	// another client).
	server_send(srv, srv.pointer, 1, server_next_serial(srv), p.Obj(pp.surface)) // leave
	server_send(srv, srv.pointer, 0, server_next_serial(srv), p.Obj(srv.toplevel_surface), fx(50), fx(250))
	server_send(srv, srv.pointer, 3, server_next_serial(srv), u32(0), u32(0x110), u32(1))
	server_send(srv, srv.pointer, 3, server_next_serial(srv), u32(0), u32(0x110), u32(0))
	testing.expect(t, run_until(app, &st, srv, 200, proc(s: ^Wl_Server, st: ^Menu_State) -> bool {
		n := 0
		for pp in s.popups {
			if pp.configured && !pp.destroyed {
				n += 1
			}
		}
		return n == 1 && st.open
	}), "reopened")
	last: u32
	server_with(srv, &last, proc(s: ^Wl_Server, user: rawptr) {
		(^u32)(user)^ = s.popups[len(s.popups) - 1].id
	})
	server_send(srv, last, 1) // popup_done
	gone := run_until(app, &st, srv, 200, proc(s: ^Wl_Server, st: ^Menu_State) -> bool {
		return !st.open && s.popups[len(s.popups) - 1].destroyed
	})
	testing.expect(t, gone, "popup_done dismissed it and palmy destroyed it")
	testing.expect_value(t, st.dismissed, 1)
}

@(private = "file")
fx :: proc(v: f32) -> p.Fixed {
	return p.Fixed(i32(v * 256))
}
