package main

import "core:fmt"
import "core:strings"
import "core:sync"

os_fd :: Fd
import "core:time"
import kit "kit:."
import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// The window.
//
// Two things live here: the tab strip, which is an ordinary palmy tree, and
// the grid, which is a single `pixels` node holding the renderer's output.
// Keeping the grid as one node is what lets the pixel cache work -- a tree of
// two thousand text nodes would be rebuilt and repainted every frame no
// matter how little changed.
// ---------------------------------------------------------------------------

TAB_STRIP_PX :: "34"
TAB_STRIP_H :: f32(34)
PAD :: f32(6)

Term_App :: struct {
	app:        ^p.App,
	sess:       Session,
	// Holds the fonts and the cell size every pane's renderer copies.
	metrics:    Grid_Renderer,
	sel:        Selection,
	// The pane the selection is in. Only one pane has a selection at once.
	sel_pane:   ^Pane,
	font_size:  f32,
	always_tabs: bool,
	focused:    bool,
	blink_at:   time.Time,
	blink_on:   bool,
	pump:       Pump,
	drag_tab:   int,
	status:     string,
	status_at:  time.Time,
	// Panes asked to close whose child has not gone yet.
	zombies:    [dynamic]^Pane,
	quit:       bool,
	paste_confirmed: bool,
	// Clipboard work, deferred to the end of the frame. palmy speaks the
	// clipboard natively now, but the fallback still shells out to wl-copy
	// and wl-paste, and forking while holding the lock the reader thread
	// wants is the kind of deadlock that happens once a month and is never
	// reproducible, so the frame only records the intent.
	clip_copy:  string,
	clip_paste: bool,
	// The primary selection: what a finished drag selected, and a
	// middle-click paste.
	clip_primary:       string,
	clip_paste_primary: bool,
	// The grid area of the last frame, in device pixels, and the divider
	// width between panes.
	area:       [4]int,
	div:        int,
	scale:      f32,
}

note :: proc(a: ^Term_App, s: string) {
	delete(a.status)
	a.status = strings.clone(s)
	a.status_at = time.now()
}

// ---------------------------------------------------------------------------
// Waiting
//
// palmy's frame loop parks in poll() on the display socket and nothing else,
// so a terminal cannot be woken by its child writing. Until `wake(app)` lands
// in palmy/app.odin this does the waiting itself, at the top of the frame
// body, over the display socket *and* every pty at once. The loop is marked
// animating so that palmy keeps calling back; the actual blocking happens
// here, so an idle terminal costs a handful of wakeups a second rather than
// a repaint every vsync.
//
// When `wake(app)` exists this becomes a reader thread that calls it, and the
// only thing that changes is this procedure.
// ---------------------------------------------------------------------------

// wait_for_work itself is in sys_linux.odin and sys_darwin.odin. On macOS
// there is no display descriptor to poll beside the reader's pipe, so there
// it is the other way round: the reader thread calls palmy.wake(app), the
// frame loop is not kept animating, and the timeout becomes a wake_after.

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

// layout_tab places the panes of a tab in the grid area and gives each the
// grid size that fits its rectangle, resizing its terminal and telling its
// child when that changed.
layout_tab :: proc(a: ^Term_App, tab: ^Tab) {
	tab_layout(tab, a.area, a.div)
	panes := make([dynamic]^Pane, context.temp_allocator)
	tab_panes(tab, &panes)
	pad := int(PAD * a.scale)
	for pn in panes {
		if !pn.shown {
			continue
		}
		r := &pn.rend
		if r.fonts == nil {
			r.fonts = a.metrics.fonts
		}
		cell_changed := false
		if r.scale != a.metrics.scale || r.size != a.metrics.size {
			renderer_metrics(r, a.metrics.size, a.metrics.scale)
			r.full = true
			cell_changed = r.cell_w != pn.term.gfx.cell_w || r.cell_h != pn.term.gfx.cell_h
			vt.terminal_set_cell_size(&pn.term, r.cell_w, r.cell_h)
		}
		cols, rows := renderer_fit(r, pn.rect[2] - 2 * pad, pn.rect[3] - 2 * pad)
		if cols != pn.term.cols || rows != pn.term.rows {
			pane_resize(pn, cols, rows)
		} else if cell_changed {
			pty_resize(&pn.pty, cols, rows, r.cell_w, r.cell_h)
		}
		renderer_resize(r, cols, rows)
		pn.grid = {
			pn.rect[0] + max(0, (pn.rect[2] - r.w) / 2),
			pn.rect[1] + max(0, (pn.rect[3] - r.h) / 2),
		}
	}
}

@(private = "file")
repaint_all :: proc(a: ^Term_App) {
	for pn in a.sess.panes {
		pn.rend.full = true
	}
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(a: ^Term_App, ui: ^p.Ctx) {
	// Keep the loop turning; the blocking happens in wait_for_work. (Not on
	// macOS: there palmy's own loop blocks; see sys_darwin.odin.)
	if LOOP_ANIMATES {
		ui.animating = true
	}

	sync.lock(&a.pump.mu)
	defer sync.unlock(&a.pump.mu)

	busy := a.pump.dirty
	a.pump.dirty = false
	busy ||= session_housekeeping(&a.sess)
	reap_zombies(a)
	if a.sess.clipboard_request != "" {
		// A program asked for the clipboard through OSC 52. Writing is
		// allowed; reading is refused in the engine and never gets here.
		delete(a.clip_copy)
		a.clip_copy = a.sess.clipboard_request
		a.sess.clipboard_request = ""
	}

	size := p.size(ui)
	scale := f32(p.window_scale(ui))
	show_tabs := a.always_tabs || len(a.sess.tabs) > 1
	grid_h := size.y - (show_tabs ? TAB_STRIP_H : 0)
	grid_w := size.x

	if a.metrics.scale != scale || a.metrics.size != a.font_size {
		renderer_metrics(&a.metrics, a.font_size, scale)
	}
	a.scale = scale
	a.div = max(1, int(DIVIDER_LOGICAL * scale + 0.5))
	a.area = {0, 0, int(grid_w * scale), int(grid_h * scale)}
	a.sess.cell_w, a.sess.cell_h = a.metrics.cell_w, a.metrics.cell_h
	pad := int(PAD * scale)
	a.sess.cols, a.sess.rows = renderer_fit(&a.metrics, a.area[2] - 2 * pad, a.area[3] - 2 * pad)

	if tab := session_tab(&a.sess); tab != nil {
		layout_tab(a, tab)
	}
	handle_keys(a, ui)
	handle_mouse(a, ui, show_tabs, scale)
	// The keys may have split, closed, zoomed or switched, or opened the
	// second tab and with it the strip; lay out again so this frame already
	// draws the result.
	show_tabs = a.always_tabs || len(a.sess.tabs) > 1
	grid_h = size.y - (show_tabs ? TAB_STRIP_H : 0)
	a.area = {0, 0, int(grid_w * scale), int(grid_h * scale)}
	tab := session_tab(&a.sess)
	if tab != nil {
		layout_tab(a, tab)
	}

	// The cursor blink is the one thing that has to keep ticking on its own.
	t := session_active(&a.sess)
	if t != nil && (t.term.modes.cursor_blink || t.rend.has_blink) {
		if time.since(a.blink_at) > 530 * time.Millisecond {
			a.blink_on = !a.blink_on
			a.blink_at = time.now()
		}
	} else {
		a.blink_on = true
		a.blink_at = time.now()
	}

	a.focused = ui.input.focused

	// --- the tree -------------------------------------------------------
	p.col(ui, "w-full h-full bg-slate-950 gap-0")
	defer p.end(ui)

	if show_tabs {
		tab_strip(a, ui)
	}

	if tab != nil {
		panes := make([dynamic]^Pane, context.temp_allocator)
		tab_panes(tab, &panes)
		for pn in panes {
			if !pn.shown {
				continue
			}
			if vt.graphics_take_changed(&pn.term) {
				pn.rend.full = true
			}
			sel := pn == a.sel_pane ? a.sel : Selection{}
			renderer_draw(&pn.rend, &pn.term, sel, a.focused && pn == tab.focus, a.blink_on)
		}
	}
	p.pixels(ui, "flex-1 w-full", a, proc(c: ^p.Canvas, r: p.Rect, a: ^Term_App) {
		p.fill_rect(c, r, p.Color{11, 17, 32, 255})
		tab := session_tab(&a.sess)
		if tab == nil {
			return
		}
		panes := make([dynamic]^Pane, context.temp_allocator)
		tab_panes(tab, &panes)
		split := len(panes) > 1 && !tab.zoomed
		for pn in panes {
			if !pn.shown {
				continue
			}
			// The panes that will not get the keystrokes are dimmed, which
			// is how a glance says where typing goes; their cursors are
			// hollow as well.
			dim := split && pn != tab.focus
			renderer_blit(&pn.rend, c, {r.x + f32(pn.grid[0]), r.y + f32(pn.grid[1]), f32(pn.rend.w), f32(pn.rend.h)}, dim)
		}
		divs := make([dynamic][4]int, context.temp_allocator)
		tab_dividers(tab, &divs, a.div)
		for d in divs {
			p.fill_rect(c, {r.x + f32(d[0]), r.y + f32(d[1]), f32(d[2]), f32(d[3])}, p.Color{0x33, 0x41, 0x55, 255})
		}
	})

	if t != nil && t.term.view_offset > 0 {
		scroll_hint(a, ui, t)
	}
	if a.status != "" && time.since(a.status_at) < 2500 * time.Millisecond {
		p.text(ui, a.status, "absolute text-xs text-slate-400 px-2")
	}

	_ = busy
}

@(private = "file")
scroll_hint :: proc(a: ^Term_App, ui: ^p.Ctx, t: ^Pane) {
	p.row(ui, "w-full px-3 py-1 bg-slate-900 border-t border-slate-800 items-center gap-2")
	defer p.end(ui)
	p.textf(ui, "text-xs text-amber-300", "scrolled back %d lines", t.term.view_offset)
	p.spacer(ui)
	p.text(ui, "shift+end to return", "text-xs text-slate-500")
}

@(private = "file")
tab_strip :: proc(a: ^Term_App, ui: ^p.Ctx) {
	// The height is written from the constant the grid geometry is computed
	// against, so the two cannot drift apart. Note the bracket value has no
	// unit: palmy's bracket classes are already exact pixels, and a `px`
	// suffix makes the whole class fail to parse and be dropped silently.
	p.row(ui, p.concat(ui, "w-full items-stretch gap-1 px-1 pt-1 bg-slate-950 h-[", TAB_STRIP_PX, "]"))
	defer p.end(ui)

	for t, i in a.sess.tabs {
		p.key(ui, fmt.tprintf("tab%d", t.id))
		active := i == a.sess.active
		cls := active \
		? "px-3 items-center gap-2 rounded-t-md bg-slate-900 border-t border-x border-slate-700 cursor-pointer" \
		: "px-3 items-center gap-2 rounded-t-md bg-slate-950 hover:bg-slate-900 cursor-pointer"
		p.row(ui, cls)
		if p.clickable(ui) {
			session_select(&a.sess, i)
		}
		f := t.focus
		if f != nil && (f.term.progress == .Set || f.term.progress == .Indetermine) {
			p.textf(ui, "text-xs text-sky-400", "%d%%", f.term.progress_pct)
		} else if f != nil && f.dead {
			p.text(ui, "●", "text-xs text-rose-400")
		}
		if n := tab_pane_count(t); n > 1 {
			// How many panes the tab holds, so a split tab is told apart
			// from a plain one without switching to it.
			p.textf(ui, "text-xs text-slate-500", t.zoomed ? "%d panes, zoomed" : "%d panes", n)
		}
		title := tab_title(t)
		if len(title) > 24 {
			title = fmt.tprintf("%s…", title[:23])
		}
		p.text(ui, title, active ? "text-xs text-slate-100" : "text-xs text-slate-400")
		p.end(ui)
	}

	p.spacer(ui)
	p.row(ui, "px-2 items-center rounded-t-md hover:bg-slate-900 cursor-pointer")
	if p.clickable(ui) {
		new_tab(a)
	}
	p.text(ui, "+", "text-sm text-slate-400")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private = "file")
new_tab :: proc(a: ^Term_App) {
	// A new tab opens where the focused pane is, the same way a split does.
	cwd := ""
	if f := session_active(&a.sess); f != nil {
		cwd = pane_cwd(f)
	}
	if _, err := tab_open(&a.sess, nil, cwd); err != "" {
		note(a, err)
		return
	}
	repaint_all(a)
}

split_pane :: proc(a: ^Term_App, dir: Split_Dir) {
	tab := session_tab(&a.sess)
	if tab == nil {
		return
	}
	if _, err := tab_split(&a.sess, tab, dir); err != "" {
		note(a, err)
		return
	}
	repaint_all(a)
}

// close_pane closes one pane, and its tab with it when it was the last.
close_pane :: proc(a: ^Term_App, pn: ^Pane) {
	if pn == nil {
		return
	}
	tab := pane_tab(&a.sess, pn)
	if a.sel_pane == pn {
		a.sel = {}
		a.sel_pane = nil
	}
	if tab != nil && tab_detach(&a.sess, tab, pn) {
		for x, i in a.sess.tabs {
			if x == tab {
				ordered_remove(&a.sess.tabs, i)
				break
			}
		}
		free(tab)
		if a.sess.active >= len(a.sess.tabs) {
			a.sess.active = max(0, len(a.sess.tabs) - 1)
		}
	}
	if !pn.dead {
		pane_request_close(pn)
		append(&a.zombies, pn)
	} else {
		pane_destroy(pn)
	}
	repaint_all(a)
	if len(a.sess.tabs) == 0 {
		a.quit = true
	}
}

// reap_zombies finishes closing panes whose child was signalled but had not
// gone yet. Nothing blocks on it: the window stays responsive while a child
// takes its time dying.
@(private = "file")
reap_zombies :: proc(a: ^Term_App) {
	for i := len(a.zombies) - 1; i >= 0; i -= 1 {
		t := a.zombies[i]
		if pane_close_ready(t) {
			pane_destroy(t)
			unordered_remove(&a.zombies, i)
		}
	}
}

@(private = "file")
arrow_dir :: proc(sym: u32) -> (Direction, bool) {
	switch sym {
	case 0xff51:
		return .Left, true
	case 0xff52:
		return .Up, true
	case 0xff53:
		return .Right, true
	case 0xff54:
		return .Down, true
	}
	return .Left, false
}

// pane_key handles the split shortcuts. alt+arrow moves focus and
// alt+shift+arrow moves a divider -- but only in a tab that has more than
// one pane, so in an ordinary tab those keys still reach the program.
pane_key :: proc(a: ^Term_App, mods: u16, sym: u32) -> bool {
	ctrl := mods & vt.MOD_CTRL != 0
	shift := mods & vt.MOD_SHIFT != 0
	alt := mods & vt.MOD_ALT != 0
	tab := session_tab(&a.sess)
	if tab == nil {
		return false
	}
	if ctrl && shift && !alt {
		switch sym {
		case 'R', 'r':
			split_pane(a, .Columns)
			return true
		case 'D', 'd':
			split_pane(a, .Rows)
			return true
		case 'Z', 'z':
			if tab_pane_count(tab) > 1 {
				tab.zoomed = !tab.zoomed
				repaint_all(a)
			}
			return true
		}
		return false
	}
	if alt && !ctrl && tab_pane_count(tab) > 1 {
		d, ok := arrow_dir(sym)
		if !ok {
			return false
		}
		if shift {
			step := (d == .Left || d == .Right) ? a.metrics.cell_w : a.metrics.cell_h
			min_px := 2 * int(PAD * a.scale) + 2 * max(a.metrics.cell_w, a.metrics.cell_h)
			if tab_resize(tab, d, step, min_px, a.div) {
				repaint_all(a)
			}
		} else if tab_focus_move(tab, d, a.div) {
			a.sel = {}
			a.sel_pane = nil
			repaint_all(a)
		}
		return true
	}
	return false
}

@(private = "file")
handle_keys :: proc(a: ^Term_App, ui: ^p.Ctx) {
	buf: [8]u8
	enc: [256]u8

	for k in ui.input.keys {
		t := session_active(&a.sess)
		mods := mods_from_palmy(k.mods)
		ctrl := mods & vt.MOD_CTRL != 0
		shift := mods & vt.MOD_SHIFT != 0
		alt := mods & vt.MOD_ALT != 0
		sym := k.sym

		// --- the application's own shortcuts ---------------------------
		if pane_key(a, mods, sym) {
			continue
		}
		if ctrl && shift {
			switch sym {
			case 'T', 't':
				new_tab(a)
				continue
			case 'W', 'w':
				close_pane(a, t)
				continue
			case 'C', 'c':
				copy_selection(a)
				continue
			case 'V', 'v':
				paste_clipboard(a)
				continue
			case 0xff51: // Left
				session_move(&a.sess, a.sess.active, a.sess.active - 1)
				continue
			case 0xff53: // Right
				session_move(&a.sess, a.sess.active, a.sess.active + 1)
				continue
			case 0xff09, 0xfe20: // Tab / ISO_Left_Tab
				session_prev(&a.sess)
				repaint_all(a)
				continue
			}
		}
		if ctrl && !shift && sym == 0xff09 {
			session_next(&a.sess)
			repaint_all(a)
			continue
		}
		if ctrl && (sym == KEY_PRIOR || sym == KEY_NEXT) {
			if sym == KEY_PRIOR {
				session_prev(&a.sess)
			} else {
				session_next(&a.sess)
			}
			repaint_all(a)
			continue
		}
		if ctrl && (sym == '+' || sym == '=' || sym == '-' || sym == '_' || sym == '0') {
			switch sym {
			case '+', '=':
				a.font_size = min(a.font_size + 1, 48)
			case '-', '_':
				a.font_size = max(a.font_size - 1, 6)
			case '0':
				a.font_size = 14
			}
			repaint_all(a)
			continue
		}
		if alt && sym >= '1' && sym <= '9' {
			session_select(&a.sess, int(sym - '1'))
			repaint_all(a)
			continue
		}
		if shift && (sym == KEY_PRIOR || sym == KEY_NEXT || sym == 0xff57 || sym == 0xff50) {
			if t != nil {
				scroll_view(a, t, sym)
			}
			continue
		}

		if t == nil {
			continue
		}
		if t.dead {
			continue
		}

		// Any key cancels a scrollback view, the way every terminal does:
		// you typed, so you want to see what you typed.
		if t.term.view_offset != 0 {
			t.term.view_offset = 0
			t.rend.full = true
		}
		a.sel.active = false

		ev := key_event_from(k, buf[:])
		if ev.key == .Unidentified && len(ev.utf8) == 0 {
			continue
		}
		e := vt.Key_Encoder {
			kitty_flags                = vt.terminal_kitty_flags(&t.term),
			cursor_key_application     = t.term.modes.cursor_keys_app,
			keypad_key_application     = t.term.modes.keypad_app,
			ignore_keypad_with_numlock = t.term.modes.ignore_keypad_num,
			alt_esc_prefix             = t.term.modes.alt_esc_prefix,
			modify_other_keys_state_2  = t.term.modes.modify_other_keys,
		}
		out := vt.key_encode(e, ev, enc[:])
		if len(out) > 0 {
			pty_write(&t.pty, out)
		}
	}
}

@(private = "file")
scroll_view :: proc(a: ^Term_App, t: ^Pane, sym: u32) {
	s := vt.screen(&t.term)
	maxoff := max(0, vt.screen_total_rows(s) - t.term.rows)
	page := max(1, t.term.rows - 2)
	switch sym {
	case KEY_PRIOR:
		t.term.view_offset = min(t.term.view_offset + page, maxoff)
	case KEY_NEXT:
		t.term.view_offset = max(t.term.view_offset - page, 0)
	case 0xff50: // Home
		t.term.view_offset = maxoff
	case 0xff57: // End
		t.term.view_offset = 0
	}
	t.rend.full = true
}

@(private = "file")
handle_mouse :: proc(a: ^Term_App, ui: ^p.Ctx, show_tabs: bool, scale: f32) {
	tab := session_tab(&a.sess)
	if tab == nil {
		return
	}
	mouse := p.mouse_pos(ui)
	top := show_tabs ? TAB_STRIP_H : 0
	mx := int(mouse.x * scale)
	my := int((mouse.y - top) * scale)
	if mouse.y < top {
		return
	}
	hit := tab_pane_at(tab, mx, my)

	// A drag stays with the pane it started in, wherever the pointer goes.
	t := hit
	if a.sel.dragging && a.sel_pane != nil {
		t = a.sel_pane
	}
	if t == nil {
		return
	}
	if ui.input.pressed[.Left] && hit != nil && hit != tab.focus {
		// Clicking a pane focuses it.
		tab.focus = hit
		repaint_all(a)
	}
	col := (mx - t.grid[0]) / max(t.rend.cell_w, 1)
	row := (my - t.grid[1]) / max(t.rend.cell_h, 1)
	in_grid := my >= t.grid[1] && mx >= t.grid[0] && row >= 0 && row < t.rend.rows && col >= 0 && col < t.rend.cols

	wheel := p.wheel(ui)
	if wheel.y != 0 && in_grid {
		if vt.mouse_wants(&t.term) && t.term.view_offset == 0 {
			buf: [32]u8
			// p.wheel is in notches already. Wayland's axis is positive
			// downwards (towards the end of the text), as palmy keeps it.
			n := int(abs(wheel.y))
			n = clamp(n, 1, 5)
			for _ in 0 ..< n {
				ev := vt.Mouse_Event {
					button = wheel.y < 0 ? .Wheel_Up : .Wheel_Down,
					action = .Press,
					col    = col,
					row    = row,
					mods   = mods_from_palmy(ui.input.mods),
				}
				if out := vt.mouse_encode(&t.term, ev, buf[:]); len(out) > 0 {
					pty_write(&t.pty, out)
				}
			}
		} else {
			s := vt.screen(&t.term)
			maxoff := max(0, vt.screen_total_rows(s) - t.term.rows)
			step := 3
			// Up (negative) goes back into the scrollback.
			if wheel.y < 0 {
				t.term.view_offset = min(t.term.view_offset + step, maxoff)
			} else {
				t.term.view_offset = max(t.term.view_offset - step, 0)
			}
			t.rend.full = true
		}
	}

	if !in_grid && !a.sel.dragging {
		return
	}
	col = clamp(col, 0, max(t.rend.cols - 1, 0))
	row = clamp(row, 0, max(t.rend.rows - 1, 0))
	s := vt.screen(&t.term)
	abs_row := max(0, vt.screen_total_rows(s) - t.rend.rows - t.term.view_offset) + row
	shift := .Shift in ui.input.mods
	report := vt.mouse_wants(&t.term) && !shift

	if ui.input.pressed[.Left] {
		if report {
			send_mouse(a, t, .Left, .Press, col, row, ui)
		} else {
			if a.sel_pane != nil && a.sel_pane != t {
				a.sel_pane.rend.full = true
			}
			a.sel = sel_press(col, abs_row)
			a.sel_pane = t
			t.rend.full = true
		}
	} else if ui.input.down[.Left] {
		if report {
			send_mouse(a, t, .Left, .Motion, col, row, ui)
		} else if a.sel_pane == t && sel_drag(&a.sel, col, abs_row) {
			t.rend.full = true
		}
	} else if ui.input.released[.Left] {
		if report {
			send_mouse(a, t, .Left, .Release, col, row, ui)
		}
		if a.sel.dragging && a.sel.active {
			// A finished selection becomes the primary selection, which is
			// what a middle click anywhere pastes.
			delete(a.clip_primary)
			a.clip_primary = selection_text(a)
		}
		a.sel.dragging = false
	}
	if ui.input.pressed[.Middle] && !report {
		a.clip_paste_primary = true
	}
}

@(private = "file")
send_mouse :: proc(
	a: ^Term_App,
	t: ^Pane,
	b: vt.Mouse_Button_Kind,
	act: vt.Mouse_Action,
	col, row: int,
	ui: ^p.Ctx,
) {
	buf: [32]u8
	ev := vt.Mouse_Event {
		button = b,
		action = act,
		col    = col,
		row    = row,
		mods   = mods_from_palmy(ui.input.mods),
	}
	if out := vt.mouse_encode(&t.term, ev, buf[:]); len(out) > 0 {
		pty_write(&t.pty, out)
	}
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

selection_text :: proc(a: ^Term_App, allocator := context.allocator) -> string {
	t := a.sel_pane
	if t == nil || !a.sel.active {
		return ""
	}
	s := vt.screen(&t.term)
	lo, hi := sel_normalized(a.sel)
	b := strings.builder_make(allocator)
	for y in lo[1] ..= hi[1] {
		row := vt.screen_row(s, y)
		if row == nil {
			continue
		}
		start := y == lo[1] ? lo[0] : 0
		end := y == hi[1] ? hi[0] : len(row.cells) - 1
		if a.sel.block {
			start = min(lo[0], hi[0])
			end = max(lo[0], hi[0])
		}
		last := -1
		for x in max(start, 0) ..= min(end, len(row.cells) - 1) {
			c := row.cells[x]
			if .Spacer in c.attrs {
				continue
			}
			if c.ch != 0 && c.ch != ' ' {
				last = strings.builder_len(b)
			}
			strings.write_rune(&b, c.ch == 0 ? ' ' : c.ch)
			for g in vt.screen_grapheme(s, c) {
				strings.write_rune(&b, g)
			}
			if c.ch != 0 && c.ch != ' ' {
				last = strings.builder_len(b)
			}
		}
		// Trim the trailing blanks a terminal pads every row with, then
		// re-join a soft-wrapped line rather than inventing a newline.
		if last >= 0 {
			resize(&b.buf, last)
		} else {
			resize(&b.buf, strings.builder_len(b))
		}
		if y < hi[1] && !row.wrapped {
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

copy_selection :: proc(a: ^Term_App) {
	text := selection_text(a)
	if text == "" {
		return
	}
	delete(a.clip_copy)
	a.clip_copy = text
}

paste_clipboard :: proc(a: ^Term_App) {
	a.clip_paste = true
}

// run_clipboard does the deferred work, outside the lock: palmy's own
// clipboard first, which talks to the display server on this thread, and
// wl-copy / wl-paste only when that is unavailable, since those fork.
run_clipboard :: proc(a: ^Term_App) {
	if a.clip_copy != "" {
		if p.clipboard_set(a.app, a.clip_copy) || kit.clipboard_set(a.clip_copy) {
			note(a, "copied")
		} else {
			note(a, "there is no clipboard to copy to")
		}
		delete(a.clip_copy)
		a.clip_copy = ""
	}
	if a.clip_primary != "" {
		p.primary_set(a.app, a.clip_primary)
		delete(a.clip_primary)
		a.clip_primary = ""
	}
	text: string
	ok: bool
	if a.clip_paste_primary {
		a.clip_paste_primary = false
		text, ok = p.primary_get(a.app, context.temp_allocator)
		if !ok {
			// No primary selection (or no protocol for one): paste the
			// clipboard, which is what this did before there was a primary.
			a.clip_paste = true
		}
	}
	if a.clip_paste {
		a.clip_paste = false
		text, ok = p.clipboard_get(a.app, context.temp_allocator)
		if !ok && !p.clipboard_available(a.app) {
			text, ok = kit.clipboard_get(context.temp_allocator)
		}
	}
	if !ok || text == "" {
		return
	}
	sync.lock(&a.pump.mu)
	defer sync.unlock(&a.pump.mu)
	t := session_active(&a.sess)
	if t == nil || t.dead {
		return
	}
	if !t.term.modes.bracketed_paste && !vt.paste_is_safe(text) {
		// Without bracketed paste the shell cannot tell this from typing,
		// so a newline in the middle runs whatever came before it. Say so
		// and make the person ask twice.
		if !a.paste_confirmed {
			a.paste_confirmed = true
			note(a, "the paste contains a newline and would run; press again to send it")
			return
		}
	}
	a.paste_confirmed = false
	wrapped := vt.paste_encode(&t.term, text, context.temp_allocator)
	pty_write(&t.pty, transmute([]u8)wrapped)
}
