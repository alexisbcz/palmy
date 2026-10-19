// Input: the shortcuts the chrome owns, and everything else forwarded to the
// page. The rule is the one every browser follows -- the chrome takes its own
// shortcuts first, wherever focus is, and the page gets the rest.
package browser

import "core:strings"
import "core:time"
import kit "kit:."
import pb "pb"
import p "palmy:."

mods_of :: proc(m: p.Modifiers) -> u32 {
	r: u32
	if .Shift in m {r |= pb.MOD_SHIFT}
	if .Ctrl in m {r |= pb.MOD_CTRL}
	if .Alt in m {r |= pb.MOD_ALT}
	if .Super in m {r |= pb.MOD_SUPER}
	return r
}

KEY_PLUS :: 0x2b
KEY_EQUAL :: 0x3d
KEY_MINUS :: 0x2d
KEY_COMMA :: 0x2c
KEY_SLASH :: 0x2f

lower_sym :: proc(sym: u32) -> u32 {
	if sym >= 'A' && sym <= 'Z' {
		return sym + 32
	}
	return sym
}

// handle_input runs before the frame is built.
handle_input :: proc(ui: ^p.Ctx, s: ^State) {
	in_ := ui.input
	t := active_tab(s)
	s.list_enter = false
	s.list_enter_new = false
	s.list_delete = false
	s.list_edit = false
	s.list_move = 0

	// Shortcuts the chrome owns. Each consumed key is removed, so neither a
	// field nor the page sees it.
	keep := make([dynamic]p.Key_Event, context.temp_allocator)
	for k in in_.keys {
		if !shortcut(s, ui, k) {
			append(&keep, k)
		}
	}
	clear(&in_.keys)
	append(&in_.keys, ..keep[:])

	// Overlays take the keyboard next.
	if s.dialog.active {
		dialog_keys(ui, s)
		return
	}
	if s.overlay != .None {
		overlay_keys(ui, s)
		return
	}

	switch s.focus {
	case .Omnibox:
		omnibox_keys(ui, s)
	case .Find:
		find_keys(ui, s, t)
	case .Field:
		field_keys(ui, s, t)
	case .Page:
		if t != nil && t.page == .Web {
			page_keys(ui, s, t)
		} else {
			list_keys(ui, s, t)
		}
	case .None, .Dialog:
		list_keys(ui, s, t)
	}

	page_pointer(ui, s, t)
}

// shortcut handles one chrome shortcut; true when it consumed the key.
shortcut :: proc(s: ^State, ui: ^p.Ctx, k: p.Key_Event) -> bool {
	ctrl := .Ctrl in k.mods
	shift := .Shift in k.mods
	alt := .Alt in k.mods
	sym := lower_sym(k.sym)
	editing := s.focus == .Omnibox || s.focus == .Find || s.focus == .Field || s.dialog.active || s.overlay == .Bookmark_Edit
	if ctrl && !alt {
		switch sym {
		case 't':
			if shift {reopen_closed(s)} else {new_tab(s, PAGE_URLS[.New_Tab])}
			return true
		case 'w':
			close_tab(s, s.active)
			return true
		case 'n':
			new_window(s, s.prof.identity)
			return true
		case 'q':
			s.quit = true
			return true
		case 'l':
			s.overlay = .None
			focus_omnibox(s)
			return true
		case 'k', 'e':
			if !editing || s.focus == .Omnibox {
				s.overlay = .None
				focus_omnibox(s, false)
				edit_set(&s.omni, "")
				return true
			}
		case 'r':
			reload(s, shift)
			return true
		case 'd':
			if !shift {
				s.overlay = .None
				toggle_bookmark(s)
				return true
			}
		case 'b':
			if shift {
				toggle_bookmarks_bar(s)
				return true
			}
		case 'o':
			if shift {
				s.overlay = .None
				open_internal(s, .Bookmarks)
				return true
			}
		case 'h':
			s.overlay = .None
			open_internal(s, .History)
			return true
		case 'j':
			s.overlay = .None
			open_internal(s, .Downloads)
			return true
		case 'f':
			if !editing || s.focus == .Find {
				s.overlay = .None
				open_find(s)
				return true
			}
		case 'g':
			if t := active_tab(s); t != nil && t.has_view && edit_text(&s.find) != "" {
				engine_find(s.engine, t.id, edit_text(&s.find), !shift, true)
				return true
			}
		case KEY_COMMA:
			s.overlay = .None
			open_internal(s, .Settings)
			return true
		case KEY_EQUAL, KEY_PLUS:
			zoom_step(s, 1)
			return true
		case KEY_MINUS:
			zoom_step(s, -1)
			return true
		case '0':
			set_zoom(s, 1)
			return true
		case '1' ..= '8':
			activate_tab(s, min(int(sym - '1'), len(s.tabs) - 1))
			return true
		case '9':
			activate_tab(s, len(s.tabs) - 1)
			return true
		case 'z':
			if s.toast.action == "undo" && !editing && time.tick_diff(time.tick_now(), s.toast.until) > 0 {
				undo_delete(s)
				return true
			}
		}
		switch k.sym {
		case p.KEY_TAB, 0xfe20: // ISO_Left_Tab arrives with Shift
			if len(s.tabs) > 1 {
				d := (shift || k.sym == 0xfe20) ? -1 : 1
				activate_tab(s, (s.active + d + len(s.tabs)) % len(s.tabs))
			}
			return true
		case p.KEY_PAGE_DOWN:
			if shift {move_tab(s, 1)} else {activate_tab(s, (s.active + 1) % len(s.tabs))}
			return true
		case p.KEY_PAGE_UP:
			if shift {move_tab(s, -1)} else {activate_tab(s, (s.active - 1 + len(s.tabs)) % len(s.tabs))}
			return true
		}
	}
	if alt && !ctrl {
		switch k.sym {
		case p.KEY_LEFT:
			if s.focus != .Omnibox && s.focus != .Field {
				go_back(s)
				return true
			}
		case p.KEY_RIGHT:
			if s.focus != .Omnibox && s.focus != .Field {
				go_forward(s)
				return true
			}
		case p.KEY_HOME:
			if t := active_tab(s); t != nil {navigate(s, t, s.prof.settings.homepage)}
			return true
		}
		if sym == 'd' {
			focus_omnibox(s)
			return true
		}
	}
	switch k.sym {
	case p.KEY_F5:
		reload(s, ctrl)
		return true
	case p.KEY_F6:
		focus_omnibox(s)
		return true
	case p.KEY_F11:
		if s.app != nil {p.set_fullscreen(s.app, !p.is_fullscreen(s.app))}
		return true
	case p.KEY_F1:
		s.overlay = s.overlay == .Shortcuts ? .None : .Shortcuts
		return true
	case p.KEY_F3:
		if t := active_tab(s); t != nil && t.has_view && edit_text(&s.find) != "" {
			engine_find(s.engine, t.id, edit_text(&s.find), !shift, true)
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

dialog_keys :: proc(ui: ^p.Ctx, s: ^State) {
	d := &s.dialog
	if d.kind == .Prompt {
		r := edit_keys(ui, &d.field)
		if r.submitted {answer_dialog(s, true)}
		if r.escaped {answer_dialog(s, false)}
		return
	}
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER, ' ':
			answer_dialog(s, true)
			return
		case p.KEY_ESCAPE:
			answer_dialog(s, d.kind == .Alert)
			return
		}
	}
}

overlay_keys :: proc(ui: ^p.Ctx, s: ^State) {
	if s.overlay == .Bookmark_Edit {
		e := s.bm_edit.field == 0 ? &s.bm_edit.title : &s.bm_edit.url
		r := edit_keys(ui, e)
		if r.tab {
			b := find(&s.bookmarks, s.bm_edit.id)
			if b != nil && b.kind == "bookmark" {
				s.bm_edit.field = 1 - s.bm_edit.field
			}
		}
		if r.submitted {close_overlay(s)}
		if r.escaped {
			// Escape on a just-added bookmark keeps it, as every browser does
			close_overlay(s)
		}
		return
	}
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_ESCAPE:
			close_overlay(s)
			return
		case p.KEY_DOWN:
			s.menu_sel = s.menu_count > 0 ? (s.menu_sel + 1) % s.menu_count : 0
		case p.KEY_UP:
			s.menu_sel = s.menu_count > 0 ? (s.menu_sel - 1 + s.menu_count) % s.menu_count : 0
		case p.KEY_RETURN, p.KEY_KP_ENTER, ' ':
			s.menu_enter = true
		}
	}
}

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

omnibox_keys :: proc(ui: ^p.Ctx, s: ^State) {
	r := edit_keys(ui, &s.omni)
	if r.changed {
		build_suggestions(s)
		s.omni_open = len(s.suggestions) > 0
		s.omni_sel = 0
	}
	if s.omni_open {
		n := len(s.suggestions)
		for _ in 0 ..< r.down {s.omni_sel = (s.omni_sel + 1) % n}
		for _ in 0 ..< r.up {s.omni_sel = (s.omni_sel - 1 + n) % n}
		if (r.up > 0 || r.down > 0) && s.omni_sel >= 0 && s.omni_sel < n {
			// the field shows what Enter would open, as Chrome and Firefox do
			sg := s.suggestions[s.omni_sel]
			if sg.kind != .Search {
				clear(&s.omni.buf)
				append(&s.omni.buf, ..transmute([]u8)sg.url)
				s.omni.caret = len(s.omni.buf)
				s.omni.anchor = s.omni.caret
			}
		}
	}
	if r.submitted || r.alt_enter {
		if s.omni_open {
			take_suggestion(s, s.omni_sel, r.alt_enter)
		} else {
			open_input(s, edit_text(&s.omni), r.alt_enter)
		}
		s.omni_open = false
		if t := active_tab(s); t != nil && t.page == .Web {
			set_focus(s, .Page)
		} else if s.focus == .Omnibox {
			set_focus(s, .None)
		}
		return
	}
	if r.escaped {
		if s.omni_open {
			s.omni_open = false
			t := active_tab(s)
			edit_set(&s.omni, t != nil && t.page == .Web ? t.url : "", true)
		} else {
			t := active_tab(s)
			set_focus(s, t != nil && t.page == .Web ? .Page : .None)
		}
	}
}

find_keys :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	before := strings.clone(edit_text(&s.find), context.temp_allocator)
	r := edit_keys(ui, &s.find)
	if t == nil || !t.has_view {
		return
	}
	if r.changed && edit_text(&s.find) != before {
		engine_find(s.engine, t.id, edit_text(&s.find), true, false)
	}
	if r.submitted {
		engine_find(s.engine, t.id, edit_text(&s.find), .Shift not_in ui.input.mods, true)
	}
	if r.escaped {
		close_find(s)
	}
}

field_keys :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	r := edit_keys(ui, &s.field)
	if r.changed {
		s.list_sel = 0
	}
	if r.escaped {
		if edit_text(&s.field) != "" {
			edit_set(&s.field, "")
		} else {
			set_focus(s, .None)
		}
	}
	if r.down > 0 || r.submitted {
		set_focus(s, .None)
		if r.submitted {s.list_enter = true}
	}
}

// list_keys drives the internal pages' lists: arrows, Enter, Delete, E, /.
list_keys :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	if t == nil || t.page == .Web {
		return
	}
	for k in ui.input.keys {
		alt := .Alt in k.mods
		switch k.sym {
		case p.KEY_DOWN, 'j':
			if alt {s.list_move = 1} else {s.list_sel = min(s.list_sel + 1, max(0, s.list_len - 1))}
		case p.KEY_UP, 'k':
			if alt {s.list_move = -1} else {s.list_sel = max(s.list_sel - 1, 0)}
		case p.KEY_HOME:
			s.list_sel = 0
		case p.KEY_END:
			s.list_sel = max(0, s.list_len - 1)
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			s.list_enter = true
			s.list_enter_new = .Ctrl in k.mods
		case p.KEY_DELETE:
			s.list_delete = true
		case 'e', p.KEY_F2:
			s.list_edit = true
		case '/':
			if t.page == .Bookmarks || t.page == .History {
				set_focus(s, .Field)
			}
		case p.KEY_BACKSPACE:
			if t.page == .Bookmarks {
				if f := find(&s.bookmarks, s.bm_folder); f != nil && !is_root(f.id) {
					s.bm_folder = strings.clone(f.parent)
					s.list_sel = 0
				}
			}
		}
	}
	// on the new tab page, typing goes to the address bar
	if t.page == .New_Tab && s.focus == .None {
		if typed := p.typed_text(ui); typed != "" && .Ctrl not_in ui.input.mods {
			focus_omnibox(s, false)
			edit_set(&s.omni, typed)
			build_suggestions(s)
			s.omni_open = len(s.suggestions) > 0
		}
	}
}

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

page_keys :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	if !t.has_view || s.engine == nil {
		return
	}
	text := p.typed_text(ui)
	runes := make([dynamic]rune, context.temp_allocator)
	for r in text {
		append(&runes, r)
	}
	ri := 0
	for k in ui.input.keys {
		m := mods_of(k.mods)
		ctrl := .Ctrl in k.mods
		sym := lower_sym(k.sym)
		// the system clipboard is the chrome's: copy goes both ways, paste
		// is inserted as text
		if ctrl && !(.Alt in k.mods) {
			switch sym {
			case 'c':
				if t.selection != "" {kit.clipboard_set(t.selection)}
			case 'x':
				if t.selection != "" {kit.clipboard_set(t.selection)}
			case 'v':
				if clip, ok := kit.clipboard_get(context.temp_allocator); ok {
					engine_edit(s.engine, t.id, .Insert, clip)
				}
				continue
			}
		}
		if k.sym == p.KEY_ESCAPE && t.loading {
			stop_loading(s)
		}
		cp: u32 = 0
		if r, ok := pb.keysym_rune(k.sym); ok && !ctrl && .Alt not_in k.mods {
			if ri < len(runes) {
				cp = u32(runes[ri])
				ri += 1
			} else {
				cp = u32(r)
			}
		}
		engine_key(s.engine, t.id, .Down, m, k.sym, cp)
		engine_key(s.engine, t.id, .Up, m, k.sym, cp)
	}
	// text with no key of its own (a compose sequence, an input method)
	for ri < len(runes) {
		engine_key(s.engine, t.id, .Char, 0, 0, u32(runes[ri]))
		ri += 1
	}
}

page_pointer :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	in_ := ui.input
	if t == nil || t.page != .Web || !t.has_view || s.engine == nil || !s.engine.ok || t.error.active || t.crashed != "" {
		s.pointer_in = false
		return
	}
	r := p.rect_of(ui, s.page_id)
	s.page_rect = r
	m := in_.mouse
	inside := m.x >= r.x && m.y >= r.y && m.x < r.x + r.w && m.y < r.y + r.h && in_.over_surface
	blocked := s.overlay != .None || s.dialog.active
	if s.focus == .Omnibox && s.omni_open {
		d := p.rect_of(ui, s.drop_id)
		if m.x >= d.x && m.y >= d.y && m.x < d.x + d.w && m.y < d.y + d.h {
			blocked = true
		}
	}
	if s.find_open {
		// the find bar sits over the page's top right corner
		if m.x > r.x + r.w - 360 && m.y < r.y + 56 {
			blocked = true
		}
	}
	x := m.x - r.x
	y := m.y - r.y
	mods := mods_of(in_.mods)
	if blocked && !s.capture {
		if s.pointer_in {
			engine_mouse(s.engine, t.id, .Leave, .Left, 0, mods, x, y)
			s.pointer_in = false
		}
		return
	}
	if inside || s.capture {
		if in_.mouse_delta != {0, 0} || !s.pointer_in {
			engine_mouse(s.engine, t.id, .Move, .Left, 0, mods, x, y)
		}
		s.pointer_in = inside
		buttons := [3]p.Mouse_Button{.Left, .Middle, .Right}
		for b, bi in buttons {
			if in_.pressed[b] && inside {
				clicks := 1
				if b == .Left {
					if time.tick_since(s.last_click) < 450 * time.Millisecond && abs(m.x - s.last_click_at.x) < 5 && abs(m.y - s.last_click_at.y) < 5 {
						s.clicks += 1
					} else {
						s.clicks = 1
					}
					s.last_click = time.tick_now()
					s.last_click_at = m
					clicks = s.clicks
				}
				if s.focus != .Page {
					set_focus(s, .Page)
				}
				engine_mouse(s.engine, t.id, .Down, pb.Button(bi), clicks, mods, x, y)
				s.capture = true
			}
			if in_.released[b] && s.capture {
				engine_mouse(s.engine, t.id, .Up, pb.Button(bi), b == .Left ? s.clicks : 1, mods, x, y)
			}
		}
		if !in_.down[.Left] && !in_.down[.Right] && !in_.down[.Middle] {
			s.capture = false
		}
		if inside && in_.scroll != {0, 0} {
			// palmy reports wheel motion in surface pixels, down positive;
			// Blink wants deltas the other way round, a notch being ~120
			engine_wheel(s.engine, t.id, mods, x, y, -in_.scroll.x * 4, -in_.scroll.y * 4)
		}
	} else if s.pointer_in {
		engine_mouse(s.engine, t.id, .Leave, .Left, 0, mods, x, y)
		s.pointer_in = false
	}
}
