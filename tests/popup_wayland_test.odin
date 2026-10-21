#+build linux
// A real xdg_popup, on the small compositor in tests/wl_server.odin: from the
// request that creates it to the pixels it commits and the click that lands
// on it outside the window. The UI is popup_test.odin's.
package palmy_tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import "core:time"
import p "../palmy"

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
run_until :: proc(app: ^p.App, st: ^Popup_Menu_State, srv: ^Wl_Server, max_frames: int, cond: proc(s: ^Wl_Server, st: ^Popup_Menu_State) -> bool) -> bool {
	for _ in 0 ..< max_frames {
		ui, ok := p.frames(app)
		if !ok {
			return false
		}
		popup_menu_ui(ui, st)
		// Keep the loop turning, so that waiting for the compositor never
		// parks it on an event that is not coming.
		p.redraw(ui)
		sync_ok: bool
		{
			// The condition reads the server's state under its lock.
			Pack :: struct {
				st:  ^Popup_Menu_State,
				ok:  bool,
				cond: proc(s: ^Wl_Server, st: ^Popup_Menu_State) -> bool,
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
popup_committed :: proc(s: ^Wl_Server, st: ^Popup_Menu_State) -> bool {
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

	st: Popup_Menu_State
	ui, ok := p.frames(app)
	testing.expect(t, ok)
	popup_menu_ui(ui, &st)

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
	picked := run_until(app, &st, srv, 200, proc(s: ^Wl_Server, st: ^Popup_Menu_State) -> bool {
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
	testing.expect(t, run_until(app, &st, srv, 200, proc(s: ^Wl_Server, st: ^Popup_Menu_State) -> bool {
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
	gone := run_until(app, &st, srv, 200, proc(s: ^Wl_Server, st: ^Popup_Menu_State) -> bool {
		return !st.open && s.popups[len(s.popups) - 1].destroyed
	})
	testing.expect(t, gone, "popup_done dismissed it and palmy destroyed it")
	testing.expect_value(t, st.dismissed, 1)
}

@(private = "file")
fx :: proc(v: f32) -> p.Fixed {
	return p.Fixed(i32(v * 256))
}
