package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/linux"

os_fd :: linux.Fd
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
	rend:       Grid_Renderer,
	sel:        Selection,
	font_size:  f32,
	always_tabs: bool,
	focused:    bool,
	blink_at:   time.Time,
	blink_on:   bool,
	pump:       Pump,
	drag_tab:   int,
	status:     string,
	status_at:  time.Time,
	// Tabs asked to close whose child has not gone yet.
	zombies:    [dynamic]^Tab,
	quit:       bool,
	paste_confirmed: bool,
	// Clipboard work, deferred out of the frame. Both of these shell out to
	// wl-copy and wl-paste, and forking while holding the lock the reader
	// thread wants is the kind of deadlock that happens once a month and is
	// never reproducible, so the frame only records the intent.
	clip_copy:  string,
	clip_paste: bool,
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

wait_for_work :: proc(a: ^Term_App, timeout_ms: int) {
	pfds := [2]linux.Poll_Fd {
		{fd = a.pump.wake_r, events = {.IN}},
		{fd = a.app.win.conn.fd, events = {.IN}},
	}
	linux.poll(pfds[:], i32(timeout_ms))
	pump_drain(&a.pump)
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(a: ^Term_App, ui: ^p.Ctx) {
	// Keep the loop turning; the blocking happens in wait_for_work.
	ui.animating = true

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
	grid_h := size.y - (show_tabs ? TAB_STRIP_H : 0) - PAD * 2
	grid_w := size.x - PAD * 2

	if a.rend.scale != scale || a.rend.size != a.font_size {
		renderer_metrics(&a.rend, a.font_size, scale)
		a.rend.full = true
	}
	cols, rows := renderer_fit(&a.rend, int(grid_w * scale), int(grid_h * scale))
	if cols != a.sess.cols || rows != a.sess.rows {
		session_resize(&a.sess, cols, rows)
		renderer_resize(&a.rend, cols, rows)
	}
	renderer_resize(&a.rend, cols, rows)

	handle_keys(a, ui)
	handle_mouse(a, ui, show_tabs, scale)

	// The cursor blink is the one thing that has to keep ticking on its own.
	t := session_active(&a.sess)
	if t != nil && (t.term.modes.cursor_blink || a.rend.has_blink) {
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

	if t != nil {
		renderer_draw(&a.rend, &t.term, a.sel, a.focused, a.blink_on)
	}
	p.pixels(ui, "flex-1 w-full", a, proc(c: ^p.Canvas, r: p.Rect, a: ^Term_App) {
		p.fill_rect(c, r, p.Color{11, 17, 32, 255})
		// Centre the grid in whatever space the layout gave it, so a window
		// that is not an exact multiple of the cell size has an even border
		// rather than a fat edge on one side.
		x := r.x + max(0, (r.w - f32(a.rend.w)) * 0.5)
		y := r.y + max(0, (r.h - f32(a.rend.h)) * 0.5)
		renderer_blit(&a.rend, c, {x, y, f32(a.rend.w), f32(a.rend.h)})
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
scroll_hint :: proc(a: ^Term_App, ui: ^p.Ctx, t: ^Tab) {
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
		if t.term.progress == .Set || t.term.progress == .Indetermine {
			p.textf(ui, "text-xs text-sky-400", "%d%%", t.term.progress_pct)
		} else if t.dead {
			p.text(ui, "●", "text-xs text-rose-400")
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
	if _, err := tab_open(&a.sess); err != "" {
		note(a, err)
		return
	}
	session_resize_force(&a.sess)
	a.rend.full = true
}

session_resize_force :: proc(s: ^Session) {
	for t in s.tabs {
		vt.terminal_resize(&t.term, s.cols, s.rows)
		pty_resize(&t.pty, s.cols, s.rows)
	}
}

@(private = "file")
close_tab :: proc(a: ^Term_App, idx: int) {
	if idx < 0 || idx >= len(a.sess.tabs) {
		return
	}
	t := a.sess.tabs[idx]
	if !t.dead {
		tab_request_close(t)
		append(&a.zombies, t)
	} else {
		tab_destroy(t)
	}
	ordered_remove(&a.sess.tabs, idx)
	if a.sess.active >= len(a.sess.tabs) {
		a.sess.active = max(0, len(a.sess.tabs) - 1)
	}
	a.rend.full = true
	if len(a.sess.tabs) == 0 {
		a.quit = true
	}
}

// reap_zombies finishes closing tabs whose child was signalled but had not
// gone yet. Nothing blocks on it: the window stays responsive while a child
// takes its time dying.
@(private = "file")
reap_zombies :: proc(a: ^Term_App) {
	for i := len(a.zombies) - 1; i >= 0; i -= 1 {
		t := a.zombies[i]
		if tab_close_ready(t) {
			tab_destroy(t)
			unordered_remove(&a.zombies, i)
		}
	}
}

@(private = "file")
handle_keys :: proc(a: ^Term_App, ui: ^p.Ctx) {
	t := session_active(&a.sess)
	buf: [8]u8
	enc: [256]u8

	for k in ui.input.keys {
		mods := mods_from_palmy(k.mods)
		ctrl := mods & vt.MOD_CTRL != 0
		shift := mods & vt.MOD_SHIFT != 0
		alt := mods & vt.MOD_ALT != 0
		sym := k.sym

		// --- the application's own shortcuts ---------------------------
		if ctrl && shift {
			switch sym {
			case 'T', 't':
				new_tab(a)
				continue
			case 'W', 'w':
				close_tab(a, a.sess.active)
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
				a.rend.full = true
				continue
			}
		}
		if ctrl && !shift && sym == 0xff09 {
			session_next(&a.sess)
			a.rend.full = true
			continue
		}
		if ctrl && (sym == KEY_PRIOR || sym == KEY_NEXT) {
			if sym == KEY_PRIOR {
				session_prev(&a.sess)
			} else {
				session_next(&a.sess)
			}
			a.rend.full = true
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
			a.rend.full = true
			continue
		}
		if alt && sym >= '1' && sym <= '9' {
			session_select(&a.sess, int(sym - '1'))
			a.rend.full = true
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
			a.rend.full = true
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
scroll_view :: proc(a: ^Term_App, t: ^Tab, sym: u32) {
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
	a.rend.full = true
}

@(private = "file")
handle_mouse :: proc(a: ^Term_App, ui: ^p.Ctx, show_tabs: bool, scale: f32) {
	t := session_active(&a.sess)
	if t == nil {
		return
	}
	mouse := p.mouse_pos(ui)
	top := (show_tabs ? TAB_STRIP_H : 0) + PAD
	gx := (mouse.x - PAD) * scale
	gy := (mouse.y - top) * scale
	col := int(gx) / max(a.rend.cell_w, 1)
	row := int(gy) / max(a.rend.cell_h, 1)
	in_grid := gy >= 0 && row >= 0 && row < a.rend.rows && col >= 0 && col < a.rend.cols

	wheel := p.wheel(ui)
	if wheel.y != 0 && in_grid {
		if vt.mouse_wants(&t.term) && t.term.view_offset == 0 {
			buf: [32]u8
			n := int(abs(wheel.y) / p.SCROLL_NOTCH)
			n = clamp(n, 1, 5)
			for _ in 0 ..< n {
				ev := vt.Mouse_Event {
					button = wheel.y > 0 ? .Wheel_Up : .Wheel_Down,
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
			if wheel.y > 0 {
				t.term.view_offset = min(t.term.view_offset + step, maxoff)
			} else {
				t.term.view_offset = max(t.term.view_offset - step, 0)
			}
			a.rend.full = true
		}
	}

	if !in_grid {
		return
	}
	s := vt.screen(&t.term)
	abs_row := max(0, vt.screen_total_rows(s) - a.rend.rows - t.term.view_offset) + row
	shift := .Shift in ui.input.mods
	report := vt.mouse_wants(&t.term) && !shift

	if ui.input.pressed[.Left] {
		if report {
			send_mouse(a, t, .Left, .Press, col, row, ui)
		} else {
			a.sel = Selection {
				active   = true,
				dragging = true,
				a        = {col, abs_row},
				b        = {col, abs_row},
			}
			a.rend.full = true
		}
	} else if ui.input.down[.Left] {
		if report {
			send_mouse(a, t, .Left, .Motion, col, row, ui)
		} else if a.sel.dragging {
			nb := [2]int{col, abs_row}
			if a.sel.b != nb {
				a.sel.b = nb
				a.rend.full = true
			}
		}
	} else if ui.input.released[.Left] {
		if report {
			send_mouse(a, t, .Left, .Release, col, row, ui)
		}
		a.sel.dragging = false
	}
	if ui.input.pressed[.Middle] && !report {
		paste_clipboard(a)
	}
}

@(private = "file")
send_mouse :: proc(
	a: ^Term_App,
	t: ^Tab,
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
	t := session_active(&a.sess)
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

// run_clipboard does the deferred work, outside the frame and outside the
// lock, because both halves of it fork a process.
run_clipboard :: proc(a: ^Term_App) {
	if a.clip_copy != "" {
		if kit.clipboard_set(a.clip_copy) {
			note(a, "copied")
		} else {
			note(a, "wl-copy is not installed")
		}
		delete(a.clip_copy)
		a.clip_copy = ""
	}
	if !a.clip_paste {
		return
	}
	a.clip_paste = false
	text, ok := kit.clipboard_get(context.temp_allocator)
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
