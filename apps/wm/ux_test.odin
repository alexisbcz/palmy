// ux_test.odin — `wm --selftest` assertions for the interaction model.
//
// The arithmetic under UX.md's behaviour, pinned down without a screen: snap
// zones and their rectangles, the keyboard snap table, the relative grab
// point of a restore, double-click timing, most-recently-used order, the
// minimum-size layout solver, easing curves, menu and frame hit testing,
// binding matching by key position, and the restore geometry of maximize,
// snap and fullscreen on fabricated windows. The pixels are QEMU's job
// (qemu-test.sh); these are the parts a picture cannot prove.
package wm

import "core:strings"
import p "palmy:."

ux_selftest :: proc(s: ^Server, c: ^Client) {
	out := Tile_Rect{0, 0, 1280, 800}
	bar := 34

	// --- snap zones -------------------------------------------------------
	ws_check(snap_zone_at(2, 400, out, bar) == .Left, "the left edge is the left half")
	ws_check(snap_zone_at(1279, 400, out, bar) == .Right, "the right edge is the right half")
	ws_check(snap_zone_at(640, 40, out, bar) == .Maximize, "the top edge, bar included, maximizes")
	ws_check(snap_zone_at(640, 2, out, bar) == .Maximize, "and so does the bar itself")
	ws_check(snap_zone_at(2, 60, out, bar) == .Top_Left, "the top-left corner is a quarter")
	ws_check(snap_zone_at(1279, 799, out, bar) == .Bottom_Right, "the bottom-right corner is a quarter")
	ws_check(snap_zone_at(30, 2, out, bar) == .Top_Left, "a corner reached along the top edge is a quarter too")
	ws_check(snap_zone_at(640, 799, out, bar) == .None, "the bottom edge alone does nothing")
	ws_check(snap_zone_at(640, 400, out, bar) == .None, "the middle does nothing")
	ws_check(snap_zone_at(9, 400, out, bar) == .None, "9 px from the edge is not the edge")

	area := Tile_Rect{10, 44, 1260, 746}
	full := Tile_Rect{0, 34, 1280, 766}
	l := snap_frame(.Left, area, full, 6)
	r := snap_frame(.Right, area, full, 6)
	ws_eq(l.x, 10, "the left half starts at the outer gap")
	ws_eq(l.w + 6 + r.w, area.w, "the halves and the inner gap fill the width exactly")
	ws_eq(r.x, l.x + l.w + 6, "the right half starts one gap after the left")
	tl := snap_frame(.Top_Left, area, full, 6)
	bl := snap_frame(.Bottom_Left, area, full, 6)
	ws_eq(tl.h + 6 + bl.h, area.h, "two quarters stack to the full height")
	m := snap_frame(.Maximize, area, full, 6)
	ws_check(m == full, "maximize fills the work area, gaps and all")
	t1 := snap_frame(.Left_Third, area, full, 6)
	t2 := snap_frame(.Right_Two_Thirds, area, full, 6)
	ws_eq(t1.w + 6 + t2.w, area.w, "a third and two thirds fill the width")

	// --- the keyboard snap table ----------------------------------------
	ws_check(snap_key(.None, false, .Left).zone == .Left, "Super+Left on a free window: left half")
	ws_check(snap_key(.Left, false, .Left).zone == .Left_Third, "again: a third")
	ws_check(snap_key(.Left_Third, false, .Left).zone == .Left_Two_Thirds, "again: two thirds")
	ws_check(snap_key(.Left_Two_Thirds, false, .Left).zone == .Left, "and around to the half")
	ws_check(snap_key(.Right, false, .Left).restore, "Super+Left from the right half restores")
	ws_check(snap_key(.Left, false, .Up).zone == .Top_Left, "Super+Left then Super+Up is the top-left quarter")
	ws_check(snap_key(.Bottom_Right, false, .Up).zone == .Top_Right, "Up from a bottom quarter is the top quarter")
	ws_check(snap_key(.None, false, .Up).zone == .Maximize, "Up on a free window maximizes")
	ws_check(snap_key(.None, true, .Down).restore, "Down on a maximized window restores")
	ws_check(snap_key(.Left, false, .Down).restore, "Down on a snapped window restores")
	ws_check(snap_key(.None, false, .Down).minimize, "Down on a free window minimizes")
	ws_check(snap_key(.Top_Left, false, .Down).restore, "Down from a top quarter restores")

	// --- restore under the pointer --------------------------------------
	{
		// Grabbed at 75% across a 1280 px maximized title, restored to 600:
		// still at 75%.
		x := grab_restore_x(960, 0, 1280, 600, 12, 100)
		ws_near(960 - x, 450, 1, "the grab point keeps its relative position across the title")
		// Grabbed over where the buttons will be: pulled back onto the title.
		x2 := grab_restore_x(1270, 0, 1280, 600, 12, 100)
		ws_check(1270 - x2 <= 600 - 100, "the pointer never lands on the restored window's buttons")
		x3 := grab_restore_x(2, 0, 1280, 600, 12, 100)
		ws_check(2 - x3 >= 12, "nor past the title's left end")
	}

	// --- double-click ----------------------------------------------------
	{
		a := new(Toplevel)
		b := new(Toplevel)
		ws_check(dbl_click_ok(a, a, 10.0, 10.3, {100, 50}, {102, 51}, 400), "two clicks 300 ms and 2 px apart are a double-click")
		ws_check(!dbl_click_ok(a, a, 10.0, 10.45, {100, 50}, {100, 50}, 400), "450 ms apart is two clicks")
		ws_check(!dbl_click_ok(a, a, 10.0, 10.1, {100, 50}, {106, 50}, 400), "6 px apart is two clicks")
		ws_check(!dbl_click_ok(a, b, 10.0, 10.1, {100, 50}, {100, 50}, 400), "on two windows is two clicks")
		ws_check(!dbl_click_ok(nil, a, 10.0, 10.1, {100, 50}, {100, 50}, 400), "a first click is never a double")
		ws_check(dbl_click_ok(a, a, 10.0, 10.6, {100, 50}, {100, 50}, 700), "double_click_ms widens the interval")
		free(a)
		free(b)
	}

	// --- most recently used ----------------------------------------------
	{
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		d := ws_test_win(s, c, "d", "app", 400, 300)
		append(&s.stack, a, b, d)
		focus_window(s, a)
		focus_window(s, b)
		focus_window(s, d)
		order := mru_order(s.stack[:])
		ws_check(order[0] == d && order[1] == b && order[2] == a, "the switcher lists the last focused first")
		minimize_window(s, b)
		order = mru_order(s.stack[:])
		ws_check(order[len(order) - 1] == b, "a minimized window comes last")
		ws_check(s.focus == d, "minimizing an unfocused window leaves focus alone")
		minimize_window(s, d)
		ws_check(s.focus == a, "minimizing the focused one hands focus to the most recent other")
	}

	// --- the minimum-size layout solver ----------------------------------
	{
		hs: [3]int
		ok, _ := tile_share(300, {50, 50, 50}, hs[:])
		ws_check(ok && hs[0] == 100 && hs[2] == 100, "even minimums share evenly")
		ok2, _ := tile_share(300, {200, 30, 30}, hs[:])
		ws_check(ok2 && hs[0] == 200 && hs[1] + hs[2] == 100, "a big minimum takes its share and the rest split what is left")
		ok3, worst := tile_share(300, {200, 150, 30}, hs[:])
		ws_check(!ok3 && worst == 0, "minimums that cannot fit name the greediest")
	}
	{
		// A client whose minimum width fits no stack cell floats, centred,
		// instead of overlapping a tile (UX.md 1.7).
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		g := ws_test_win(s, c, "g", "app", 400, 300)
		g.min_w = 1500
		append(&s.stack, a, b, g)
		tile_apply(s)
		ws_check(ws_floating(g), "a window wider than any cell is floated by the layout")
		ws_check(ws_win(g).auto_float, "and marked as the layout's doing")
		ws_eq(len(tile_windows(s, 0)), 2, "leaving the others to tile")
		ws_check(a.x + a.req_w < b.x, "and they do not overlap")
		g.min_w = 200
		tile_apply(s)
		ws_check(!ws_floating(g), "once it fits again it goes back into the layout")
	}
	{
		// A master whose minimum is wider than the ratio allows widens its
		// column rather than overlapping the stack.
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		append(&s.stack, a, b)
		b.min_w = 900
		tile_apply(s)
		ws_check(!ws_floating(b), "a stack window that can fit is not floated")
		ws_check(b.req_w >= 900, "its column grew to its minimum")
		ws_check(a.x + a.req_w <= b.x, "without overlapping the master")
	}

	{
		// Super+Left on a tile puts it beside the layout, never over it: the
		// layout yields the snapped half and tiles into the rest, and every
		// other window stays in view (UX.md P0-5, principle 2).
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		g := ws_test_win(s, c, "g", "app", 400, 300)
		g.min_w = 720
		append(&s.stack, a, b, g)
		tile_apply(s)
		s.focus = g
		snap_keyboard(s, .Left)
		tile_apply(s)
		gr := target_frame(g)
		ok := true
		for t in ([]^Toplevel{a, b}) {
			if p.rect_overlaps(target_frame(t), gr) {
				ok = false
			}
		}
		ws_check(ws_win(g).snap == .Left, "Super+Left snaps the tile to the left")
		ws_check(ok, "and the tiles left behind sit beside it, not under it")
		snap_keyboard(s, .Down)
		tile_apply(s)
		ws_check(!ws_floating(g) && s.workspaces[0].tiled_in == tile_area(s, 0), "Super+Down gives the layout its whole area back")
	}
	{
		// A new window cascades from the window that is there, not from a
		// position remembered from one long closed (UX.md P0-13).
		ws_test_reset(s)
		s.workspaces[0].tiling = false
		a := ws_test_win(s, c, "a", "app", 700, 480)
		ws_win(a).floating = true
		a.x, a.y = 400, 260
		append(&s.stack, a)
		b := ws_test_win(s, c, "b", "app", 1000, 670)
		place_new_window(s, b)
		af, bf := frame_rect(a), target_frame(b)
		covered := bf.x <= af.x && bf.y <= af.y && bf.x + bf.w >= af.x + af.w && bf.y + bf.h >= af.y + af.h
		ws_check(!covered, "a large new window does not cover the one below it whole")
		ws_check(bf.y >= af.y + f32(ws_title_h(a)), "the window below keeps its title bar in view")
		s.workspaces[0].tiling = s.cfg.tiling
	}

	// --- maximize and restore, exactly -----------------------------------
	{
		ws_test_reset(s)
		s.workspaces[0].tiling = false
		a := ws_test_win(s, c, "a", "app", 500, 300)
		append(&s.stack, a)
		a.x, a.y = 200, 150
		ws_win(a).floating = true
		before := win_rect(a)
		set_maximized(s, a, true)
		ws_check(a.maximized, "maximize sets the flag")
		wa := ws_work_area(s, 0)
		ws_eq(a.x - ws_border(a), wa.x, "a maximized frame starts at the work area's left")
		set_maximized(s, a, false)
		ws_check(win_rect(a) == before, "restore returns the exact rect")

		snap_apply(s, a, .Left)
		ws_check(ws_win(a).snap == .Left, "snapping records the zone")
		set_maximized(s, a, true)
		set_maximized(s, a, false)
		ws_check(ws_win(a).snap == .Left, "maximize then restore of a snapped window returns to the snap")
		snap_release(s, a)
		ws_check(win_rect(a) == before, "and releasing the snap returns the free rect")

		set_fullscreen(s, a, true)
		ws_eq(ws_title_h(a), 0, "fullscreen has no title bar")
		ws_eq(a.req_w, s.outputs[0].w, "and covers the output")
		set_fullscreen(s, a, false)
		ws_check(win_rect(a) == before, "leaving fullscreen restores exactly")
		s.workspaces[0].tiling = s.cfg.tiling
	}
	{
		// A tiled window keeps its cell while maximized: no other window
		// moves at any point (UX.md P0-2).
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		append(&s.stack, a, b)
		tile_apply(s)
		bx, bw := b.x, b.req_w
		set_maximized(s, b, true)
		tile_apply(s)
		ws_eq(a.req_w + a.x, a.req_w + a.x, "the master is untouched")
		set_maximized(s, a, true)
		set_maximized(s, a, false)
		tile_apply(s)
		ws_check(!ws_floating(a), "restoring a tiled window leaves it tiled")
		set_maximized(s, b, false)
		tile_apply(s)
		ws_eq(b.x, bx, "and the restored stack window is back in its cell")
		ws_eq(b.req_w, bw, "at its tiled width")
	}
	{
		// The drag that starts on a maximized window restores it under the
		// pointer, and clears the flag so the button means maximize again.
		ws_test_reset(s)
		s.workspaces[0].tiling = false
		a := ws_test_win(s, c, "a", "app", 600, 400)
		append(&s.stack, a)
		a.x, a.y = 300, 200
		ws_win(a).floating = true
		set_maximized(s, a, true)
		a.w, a.h = a.req_w, a.req_h // what the client's commit would do
		s_pointer = {960, 50}
		ix_restore_for_move(s, a, s_pointer)
		ws_check(!a.maximized, "the drag clears maximized")
		ws_eq(a.req_w, 600, "and restores the free width")
		s.workspaces[0].tiling = s.cfg.tiling
	}

	// --- easing ------------------------------------------------------------
	ws_check(ease_out(0) == 0 && ease_out(1) == 1, "ease-out runs 0 to 1")
	ws_check(ease_out(0.5) > 0.5, "and is ahead of linear halfway")
	ws_check(ease_in(0.5) < 0.5, "ease-in is behind it")
	ws_check(ease_out(-1) == 0 && ease_out(2) == 1, "and both clamp")
	{
		r := scale_rect({100, 100, 200, 100}, 0.5)
		ws_check(r.x == 150 && r.y == 125 && r.w == 100, "scaling a rect keeps its centre")
	}

	// --- menus ------------------------------------------------------------
	{
		items := make([dynamic]Menu_Item, context.temp_allocator)
		append(&items, Menu_Item{label = "Minimize"}, Menu_Item{label = "Maximize"}, Menu_Item{kind = .Sep}, Menu_Item{label = "Close"})
		x, y, w := f32(100), f32(100), f32(200)
		ws_eq(menu_item_at(items[:], x, y, w, 150, 100 + MENU_PAD + 5), 0, "the first row is the first item")
		ws_eq(menu_item_at(items[:], x, y, w, 150, 100 + MENU_PAD + MENU_ROW + 5), 1, "the second row the second")
		ws_eq(menu_item_at(items[:], x, y, w, 150, 100 + MENU_PAD + 2 * MENU_ROW + 3), -1, "a separator is not an item")
		ws_eq(menu_item_at(items[:], x, y, w, 150, 100 + MENU_PAD + 2 * MENU_ROW + MENU_SEP + 5), 3, "the row after it is")
		ws_eq(menu_item_at(items[:], x, y, w, 50, 110), -1, "left of the menu is nothing")
		ws_check(menu_height(items[:]) == f32(2 * MENU_PAD + 3 * MENU_ROW + MENU_SEP), "the height adds up")
	}

	// --- frame hit testing -------------------------------------------------
	{
		fr := p.Rect{400, 170, 600, 430}
		e, near := frame_edges_at(fr, 396, 598, 8, 4, 16)
		ws_check(near && e == {.Left, .Bottom}, "4 px outside the bottom-left corner is the corner")
		e2, _ := frame_edges_at(fr, 1004, 400, 8, 4, 16)
		ws_check(e2 == {.Right}, "4 px outside the right edge is the right edge")
		e3, _ := frame_edges_at(fr, 402, 300, 8, 4, 16)
		ws_check(e3 == {.Left}, "2 px inside the left edge too")
		e4, _ := frame_edges_at(fr, 410, 168, 8, 4, 16)
		ws_check(e4 == {.Top, .Left}, "near a corner along the top edge is the corner")
		_, far := frame_edges_at(fr, 390, 300, 8, 4, 16)
		ws_check(!far, "10 px outside is nothing")
		e5, _ := frame_edges_at(fr, 700, 400, 8, 4, 16)
		ws_check(e5 == {}, "the middle is no edge")
		ws_eq(corner_inset(10, 0), 7, "a 10 px corner starts 7 px in on its outer row")
		ws_eq(corner_inset(10, 9), 0, "and not at all on its last")
	}

	// --- bindings by key position (UX.md P0-11) ---------------------------
	{
		b := Cfg_Bind{mods = {.Super, .Shift}, sym = '2'}
		ws_check(bind_matches_key(&b, '@', '2', 3), "Shift+2 delivered as `at` still matches a `2` binding by its level-one symbol")
		ws_check(bind_matches_key(&b, 0xe9, 0xe9, 3), "on AZERTY, the key where US has 2 matches by position")
		ws_check(!bind_matches_key(&b, '3', '3', 4), "another key does not")
		tab := Cfg_Bind{mods = {.Alt, .Shift}, sym = p.KEY_TAB}
		ws_check(bind_matches_key(&tab, KEY_ISO_LEFT_TAB, 0, 15), "Shift+Tab arrives as ISO_Left_Tab and still matches")
		code := Cfg_Bind{code = 10}
		ws_check(bind_matches_key(&code, 0, 0, 2), "code:10 is the evdev key 2")
		ws_eq(int(us_digit_of(11)), int('0'), "the tenth number-row key is 0")
		sl := Cfg_Bind{mods = {.Super}, sym = '/'}
		ws_check(bind_matches_key(&sl, '!', '!', 53, true), "on AZERTY, Super and the key where US has / matches a Slash binding")
		ws_check(!bind_matches_key(&sl, '!', '!', 53, false), "but not on a layout that types / unshifted elsewhere")
		ws_check(bind_shift_consumed(&sl, '/', ':'), "AZERTY's Shift+: types /, and that Shift is spent on the symbol")
		ws_check(!bind_shift_consumed(&sl, '?', '/'), "US Shift+/ is ?, which is not the binding")
	}
	{
		cfg: Cfg
		cfg_scalars(&cfg)
		cfg_parse(&cfg, "buttons = close,minimize,maximize:left\nfocus_new = never\nanimations = reduced\nmod_drag = ALT\nrule = class~^palmy-, ontop, opacity 0.8, sticky\nbind = $mod, code:10, workspace 1\n", "t")
		ws_eq(len(cfg.errors), 0, "the new settings parse")
		ws_check(cfg.buttons_left && cfg.buttons[0] == .Close && cfg.buttons_n == 3, "buttons on the left, close first")
		ws_check(cfg.focus_new == .Never, "focus_new")
		ws_check(cfg.animations == .Reduced, "animations")
		ws_check(cfg.drag_mod == {.Alt} && cfg.drag_mod_set, "mod_drag")
		ws_check(len(cfg.rules) == 1 && cfg.rules[0].app_re == "^palmy-" && cfg.rules[0].on_top && cfg.rules[0].sticky, "a regex rule with on-top and sticky")
		ws_check(cfg.rules[0].opacity > 0.79 && cfg.rules[0].opacity < 0.81, "and opacity")
		ws_check(cfg.binds[0].code == 10, "a binding by keycode")
		t := new(Toplevel)
		t.app_id = "palmy-counter"
		ws_check(rule_matches(&cfg.rules[0], t), "the regex matches palmy-counter")
		t.app_id = "foot"
		ws_check(!rule_matches(&cfg.rules[0], t), "and not foot")
		free(t)
		cfg_destroy(&cfg)
	}
	{
		// A user file adds to the default table (P1-8): one new bind keeps
		// the other defaults, a bind on a default chord replaces it, and
		// unbind removes one.
		cfg: Cfg
		cfg_scalars(&cfg)
		cfg_parse(&cfg, CFG_DEFAULT, "<built-in>")
		n := len(cfg.binds)
		user :: "bind = $mod, Z, spawn todo\nbind = $mod, Q, minimize\nunbind = ALT, F4\n"
		ws_check(!cfg_replaces_default_binds(user), "a user file with binds keeps the defaults")
		ws_check(cfg_replaces_default_binds("default_binds = replace\n" + user), "unless it says default_binds = replace")
		ws_check(!cfg_replaces_default_binds("default_binds = keep\n"), "keep still means keep")
		cfg_parse(&cfg, user, "t")
		ws_eq(len(cfg.errors), 0, "the user lines parse")
		ws_eq(len(cfg.binds), n, "one added, one replaced, one removed")
		sup_q, alt_f4, sup_z := false, false, false
		for b in cfg.binds {
			if b.mods == {.Super} && (b.sym == 'q' || b.sym == 'Q') {sup_q = b.act == .Minimize}
			if b.mods == {.Alt} && b.sym == p.KEY_F4 {alt_f4 = true}
			if b.mods == {.Super} && (b.sym == 'z' || b.sym == 'Z') {sup_z = true}
		}
		ws_check(sup_q && sup_z && !alt_f4, "Super+Q rebound, Super+Z added, Alt+F4 gone")
		cfg_destroy(&cfg)
	}
	{
		c2: Cfg
		cfg_scalars(&c2)
		cfg_parse(&c2, CFG_DEFAULT, "<built-in>")
		found := false
		for &b in c2.binds {
			if b.act == .Move_To_Workspace && b.arg == 2 {
				found = chord_text(&b) == "Super+Shift+2"
			}
		}
		ws_check(found, "the cheat sheet calls movetoworkspace 2 Super+Shift+2")
		any_f := false
		for b in c2.binds {
			if b.any_mods && b.act != .Toggle_Fullscreen {
				any_f = true
			}
		}
		ws_check(!any_f, "the default has no bare function-key twins left but F11")
		cfg_destroy(&c2)
	}
	{
		// The cheat sheet folds binding families into one row each, and the
		// filter still finds a binding folded in.
		ws_ensure(s)
		folded, focus4 := false, false
		for r in cheat_rows(s, "workspace 2") {
			if r.label == "Move window to workspace 1…9" && len(r.keys) == 3 && r.keys[2] == "1…9" {
				folded = true
			}
		}
		for r in cheat_rows(s, "") {
			if r.label == "Focus window left, down, up, right" && len(r.keys) == 5 {
				focus4 = true
			}
		}
		ws_check(folded, "the cheat sheet folds Super+Shift+1…9 into one row, found by \"workspace 2\"")
		ws_check(focus4, "and Super+H/J/K/L into one row with four caps")
	}

	// --- edge resistance and the overview grid ------------------------------
	{
		x, y := snap_resist(105, 300, 200, 100, {100, 500}, {0}, 8)
		ws_eq(x, 100, "an edge 5 px from a target sticks to it")
		ws_eq(y, 300, "with nothing near on the other axis, nothing moves")
		x2, _ := snap_resist(120, 300, 200, 100, {100}, {}, 8)
		ws_eq(x2, 120, "20 px away is left alone")
		x3, _ := snap_resist(294, 300, 200, 100, {500}, {}, 8)
		ws_eq(x3, 300, "a right edge sticks as well")
	}
	{
		sizes := [?][2]f32{{800, 600}, {800, 600}, {400, 300}}
		rects: [3]p.Rect
		ov_grid({0, 0, 1200, 600}, sizes[:], 20, rects[:])
		ok := true
		for i in 0 ..< 3 {
			for j in i + 1 ..< 3 {
				if p.rect_overlaps(rects[i], rects[j]) {
					ok = false
				}
			}
			if rects[i].w > sizes[i].x {
				ok = false
			}
		}
		ws_check(ok, "the overview lays windows out without overlap and never enlarges them")
		r0 := rects[0].w / sizes[0].x
		r2 := rects[2].w / sizes[2].x
		ws_check(abs(r0 - r2) < 0.001, "every window is scaled by the same factor")
		if abs(rects[0].y - rects[1].y) < 1 {
			ws_check(abs((rects[0].y + rects[0].h / 2) - (rects[1].y + rects[1].h / 2)) < 1, "a row shares a centre line")
		}
	}
	_ = strings.contains
}
