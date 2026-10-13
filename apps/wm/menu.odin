// menu.odin — the compositor's own menus (UX.md P0-3, P1-3).
//
// Three menus, one widget: the window menu (right-click on a title bar,
// Alt+Space, a taskbar entry's right-click, or a client-side-decorated
// client's xdg_toplevel.show_window_menu), the desktop menu (right-click on
// empty desktop), and the layout menu (right-click on the layout badge).
// Every item offers an action from the same vocabulary as the bindings, and
// shows the binding's chord, so the menu teaches the keyboard.
//
// A menu is a modal overlay: while open it takes the pointer and the
// keyboard, and a click outside it dismisses it without passing the click
// through. Items act on release; the release of the very press that opened
// the menu is ignored unless the pointer travelled, so press-drag-release
// works and a plain click does not pick the item under the pointer.
//
// Drawn in the style of palmy's shadcn menus: 8 px radius, a 1 px border,
// 28 px rows, the chord right-aligned and dimmed, the hovered row filled.
package wm

import "core:fmt"
import "core:strings"
import p "palmy:."

MENU_ROW :: 28
MENU_SEP :: 9
MENU_PAD :: 4

Menu_Act :: enum u8 {
	None,
	Minimize,
	Maximize,
	On_Top,
	Sticky,
	Float,
	Move_Ws, // arg: workspace index
	Move_Ws_New,
	Close,
	Spawn_Term,
	Spawn_Launcher,
	Spawn_Software,
	Spawn_Settings,
	Layout, // arg: TILE_LAYOUTS index, or -1 for floating
	Arrange,
	Fullscreen,
}

Menu_Kind :: enum u8 {
	Action,
	Check,
	Sub,
	Sep,
}

Menu_Item :: struct {
	label:    string,
	key:      string,
	kind:     Menu_Kind,
	checked:  bool,
	disabled: bool,
	act:      Menu_Act,
	arg:      int,
	sub:      [dynamic]Menu_Item,
	own:      bool, // the label was allocated for this menu
}

Menu :: struct {
	open:       bool,
	items:      [dynamic]Menu_Item,
	x, y:       f32,
	w:          f32,
	hover:      int,
	sub_open:   int, // index of the item whose submenu is showing, or -1
	sub_hover:  int,
	sub_x:      f32,
	sub_y:      f32,
	sub_w:      f32,
	target:     ^Toplevel,
	opened_at:  f64,
	opened_mp:  [2]int,
	traveled:   bool,
	kbd_focus:  ^Surface, // keyboard focus to hand back on Escape
}

menu: Menu

menu_items_free :: proc(items: ^[dynamic]Menu_Item) {
	for &it in items {
		menu_items_free(&it.sub)
		delete(it.sub)
		if it.own {
			delete(it.label)
		}
		delete(it.key)
	}
	clear(items)
}

menu_close :: proc(s: ^Server) {
	if !menu.open {
		return
	}
	menu.open = false
	menu_items_free(&menu.items)
	menu.target = nil
	s.dirty = true
}

menu_forget :: proc(s: ^Server, t: ^Toplevel) {
	if menu.open && menu.target == t {
		menu_close(s)
	}
}

// menu_height is the height of a list of items, padding included.
menu_height :: proc(items: []Menu_Item) -> f32 {
	h := f32(2 * MENU_PAD)
	for it in items {
		h += it.kind == .Sep ? MENU_SEP : MENU_ROW
	}
	return h
}

// menu_item_at is the menu's hit test, pure: the index of the item at a
// point for a menu at (x, y) of width w, or -1 (separators are not items one
// can be on).
menu_item_at :: proc(items: []Menu_Item, x, y, w: f32, px, py: f32) -> int {
	if px < x || px >= x + w || py < y {
		return -1
	}
	yy := y + MENU_PAD
	for it, i in items {
		h := f32(it.kind == .Sep ? MENU_SEP : MENU_ROW)
		if py >= yy && py < yy + h {
			return it.kind == .Sep ? -1 : i
		}
		yy += h
	}
	return -1
}

// menu_item_y is the top of item i.
menu_item_y :: proc(items: []Menu_Item, y: f32, i: int) -> f32 {
	yy := y + MENU_PAD
	for it, j in items {
		if j == i {
			return yy
		}
		yy += it.kind == .Sep ? MENU_SEP : MENU_ROW
	}
	return yy
}

menu_width :: proc(app: ^p.App, items: []Menu_Item) -> f32 {
	f := &app.fonts
	w := f32(160)
	for it in items {
		lw := p.text_width(f, it.label, 12.5, .Sans, .Regular) + 34
		if it.key != "" {
			lw += p.text_width(f, it.key, 11.5, .Sans, .Regular) + 28
		}
		if it.kind == .Sub {
			lw += 18
		}
		w = max(w, lw)
	}
	return w
}

menu_place :: proc(s: ^Server, x, y: int) {
	menu.open = true
	menu.hover = -1
	menu.sub_open = -1
	menu.sub_hover = -1
	menu.opened_at = wall_now()
	menu.opened_mp = s_pointer
	menu.traveled = false
	menu.w = menu_width(menu_app, menu.items[:])
	h := menu_height(menu.items[:])
	// Keep the menu on its output: flip left or up rather than run off.
	oi := ws_output_at(s, x, y)
	o := s.outputs[oi]
	mx := f32(x)
	my := f32(y)
	if mx + menu.w > f32(o.x + o.w) - 4 {
		mx = max(f32(o.x) + 4, mx - menu.w)
	}
	if my + h > f32(o.y + o.h) - 4 {
		my = max(f32(o.y) + 4, my - h)
	}
	menu.x, menu.y = mx, my
	s.dirty = true
}

// menu_app is the app whose fonts measure the menus; draw() keeps it fresh.
menu_app: ^p.App

menu_add :: proc(items: ^[dynamic]Menu_Item, label: string, act: Menu_Act, key := "", arg := 0, disabled := false) {
	// The chord text is built in the frame's temporary memory; a menu
	// outlives the frame, so it keeps its own copy.
	append(items, Menu_Item{label = label, key = strings.clone(key), kind = .Action, act = act, arg = arg, disabled = disabled})
}

menu_add_check :: proc(items: ^[dynamic]Menu_Item, label: string, act: Menu_Act, on: bool, key := "") {
	append(items, Menu_Item{label = label, key = strings.clone(key), kind = .Check, act = act, checked = on})
}

menu_add_sep :: proc(items: ^[dynamic]Menu_Item) {
	append(items, Menu_Item{kind = .Sep})
}

// menu_open_window opens the window menu for a window at a point.
menu_open_window :: proc(s: ^Server, t: ^Toplevel, x, y: int) {
	if t == nil || menu_app == nil {
		return
	}
	menu_close(s)
	m := ws_win(t)
	it := &menu.items
	menu_add(it, "Minimize", .Minimize, key_for_act(s, .Minimize, 0))
	menu_add(it, t.maximized ? "Restore" : "Maximize", .Maximize, key_for_act(s, .Toggle_Maximize, 0), disabled = win_fixed(t))
	menu_add(it, m.fullscreen ? "Leave fullscreen" : "Fullscreen", .Fullscreen, key_for_act(s, .Toggle_Fullscreen, 0))
	menu_add_sep(it)
	menu_add_check(it, "Always on top", .On_Top, m.on_top, key_for_act(s, .Toggle_On_Top, 0))
	menu_add_check(it, "Show on all workspaces", .Sticky, m.sticky, key_for_act(s, .Toggle_Sticky, 0))
	tiling := s.workspaces[s.cur_ws].tiling
	menu_add(it, ws_in_layout(s, t) ? "Float" : "Tile", .Float, key_for_act(s, .Toggle_Float, 0), disabled = !tiling)
	sub := Menu_Item{label = "Move to workspace", kind = .Sub}
	for w, i in s.workspaces {
		menu_add(&sub.sub, fmt.aprintf("Workspace %s", w.name), .Move_Ws, key_for_act(s, .Move_To_Workspace, i + 1), arg = i, disabled = i == s.cur_ws)
		sub.sub[len(sub.sub) - 1].own = true
	}
	menu_add_sep(&sub.sub)
	menu_add(&sub.sub, "New (first empty)", .Move_Ws_New)
	append(it, sub)
	menu_add_sep(it)
	menu_add(it, "Close", .Close, key_for_act(s, .Close, 0))
	menu.target = t
	menu_place(s, x, y)
}

// menu_open_desktop is the desktop's right-click menu. Items whose program
// is not installed are left out, never shown broken (UX.md P1-3).
menu_open_desktop :: proc(s: ^Server, x, y: int) {
	if menu_app == nil || session.kiosk {
		return
	}
	menu_close(s)
	it := &menu.items
	menu_add(it, "Open Terminal", .Spawn_Term, menu_spawn_key(s, "term"))
	if _, ok := cfg_which("launcher"); ok {
		menu_add(it, "Launcher", .Spawn_Launcher, menu_spawn_key(s, "launcher"))
	}
	if _, ok := cfg_which("software"); ok {
		menu_add(it, "Software", .Spawn_Software)
	}
	menu_add_sep(it)
	append(it, menu_layout_sub(s))
	menu_add(it, "Arrange windows", .Arrange, key_for_act(s, .Cascade, 0))
	if _, ok := cfg_which("settings"); ok {
		menu_add_sep(it)
		menu_add(it, "Settings", .Spawn_Settings)
	}
	menu_place(s, x, y)
}

menu_open_layout :: proc(s: ^Server, x, y: int) {
	if menu_app == nil {
		return
	}
	menu_close(s)
	sub := menu_layout_sub(s)
	menu.items = sub.sub
	sub.sub = {}
	menu_place(s, x, y)
}

menu_layout_sub :: proc(s: ^Server) -> Menu_Item {
	ws := &s.workspaces[s.cur_ws]
	sub := Menu_Item{label = "Layout", kind = .Sub}
	for l, i in TILE_LAYOUTS {
		label := l.name == "master" ? "Master" : (l.name == "monocle" ? "Monocle" : (l.name == "grid" ? "Grid" : l.name))
		append(&sub.sub, Menu_Item{label = label, kind = .Check, act = .Layout, arg = i, checked = ws.tiling && ws.layout == i})
	}
	append(&sub.sub, Menu_Item{label = "Floating", kind = .Check, act = .Layout, arg = -1, checked = !ws.tiling})
	return sub
}

menu_spawn_key :: proc(s: ^Server, prog: string) -> string {
	for &b in s.cfg.binds {
		if b.act == .Spawn && len(b.argv) > 0 && b.argv[0] == prog && !b.any_mods {
			return chord_text(&b)
		}
	}
	return ""
}

// menu_do runs an item.
menu_do :: proc(s: ^Server, it: Menu_Item) {
	t := menu.target
	if t != nil && !ws_on_current(s, t) {
		t = nil
	}
	ix.launch_at = wall_now()
	switch it.act {
	case .None:
	case .Minimize:
		minimize_window(s, t)
	case .Maximize:
		toggle_maximize(s, t)
	case .Fullscreen:
		toggle_fullscreen(s, t)
	case .On_Top:
		toggle_on_top(s, t)
	case .Sticky:
		toggle_sticky(s, t)
	case .Float:
		if t != nil {
			ws_toggle_float(s, t)
		}
	case .Move_Ws:
		ws_move_to(s, t, it.arg)
	case .Move_Ws_New:
		for i in 0 ..< len(s.workspaces) {
			if i != s.cur_ws && ws_count_on(s, i) == 0 {
				ws_move_to(s, t, i)
				break
			}
		}
	case .Close:
		close_window(s, t)
	case .Spawn_Term:
		spawn(s, {"term"})
	case .Spawn_Launcher:
		spawn(s, {"launcher"})
	case .Spawn_Software:
		spawn(s, {"software"})
	case .Spawn_Settings:
		spawn(s, {"settings"})
	case .Layout:
		ws := &s.workspaces[s.cur_ws]
		if it.arg < 0 {
			if ws.tiling {
				ws_toggle_tiling(s)
			}
		} else {
			if !ws.tiling {
				ws_toggle_tiling(s)
			}
			ws.layout = it.arg
			s.needs_layout = true
		}
	case .Arrange:
		cascade_all(s)
	}
}

// menu_activate runs the item under the cursor, or opens its submenu.
menu_activate :: proc(s: ^Server, in_sub: bool, idx: int) {
	items := in_sub ? menu.items[menu.sub_open].sub[:] : menu.items[:]
	if idx < 0 || idx >= len(items) {
		return
	}
	it := items[idx]
	if it.disabled || it.kind == .Sep {
		return
	}
	if it.kind == .Sub {
		menu_open_sub(idx)
		return
	}
	// Copy out what the action needs before the items are freed.
	run := it
	run.sub = {}
	menu_close_keep_target(s)
	menu_do(s, run)
	menu.target = nil
}

menu_close_keep_target :: proc(s: ^Server) {
	menu.open = false
	menu_items_free(&menu.items)
	s.dirty = true
}

menu_open_sub :: proc(idx: int) {
	if idx < 0 || idx >= len(menu.items) || menu.items[idx].kind != .Sub {
		return
	}
	menu.sub_open = idx
	menu.sub_hover = -1
	sub := menu.items[idx].sub[:]
	menu.sub_w = menu_width(menu_app, sub)
	menu.sub_x = menu.x + menu.w - 4
	menu.sub_y = menu_item_y(menu.items[:], menu.y, idx) - MENU_PAD
	o := server.outputs[ws_output_at(&server, int(menu.x), int(menu.y))]
	if menu.sub_x + menu.sub_w > f32(o.x + o.w) - 4 {
		menu.sub_x = menu.x - menu.sub_w + 4
	}
	h := menu_height(sub)
	if menu.sub_y + h > f32(o.y + o.h) - 4 {
		menu.sub_y = max(f32(o.y) + 4, f32(o.y + o.h) - 4 - h)
	}
}

// menu_pointer runs the menu's share of a frame of pointer input. It owns
// the pointer while the menu is open.
menu_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if !menu.open {
		return false
	}
	px, py := f32(mp.x), f32(mp.y)
	if abs(mp.x - menu.opened_mp.x) > 4 || abs(mp.y - menu.opened_mp.y) > 4 {
		menu.traveled = true
	}
	in_sub := false
	idx := -1
	if menu.sub_open >= 0 {
		sub := menu.items[menu.sub_open].sub[:]
		if i := menu_item_at(sub, menu.sub_x, menu.sub_y, menu.sub_w, px, py); i >= 0 || p.rect_contains({menu.sub_x, menu.sub_y, menu.sub_w, menu_height(sub)}, px, py) {
			in_sub = true
			idx = i
		}
	}
	if !in_sub {
		idx = menu_item_at(menu.items[:], menu.x, menu.y, menu.w, px, py)
		if idx != menu.hover && idx >= 0 {
			menu.hover = idx
			if menu.items[idx].kind == .Sub {
				menu_open_sub(idx)
			} else {
				menu.sub_open = -1
			}
			s.dirty = true
		}
	} else if idx != menu.sub_hover {
		menu.sub_hover = idx
		s.dirty = true
	}
	inside := idx >= 0 || p.rect_contains({menu.x, menu.y, menu.w, menu_height(menu.items[:])}, px, py) || in_sub

	pressed := in_.pressed[.Left] || in_.pressed[.Right] || in_.pressed[.Middle]
	released := in_.released[.Left] || in_.released[.Right]
	if pressed && !inside {
		// A click outside dismisses, and goes no further.
		menu_close(s)
		ix.mode = .Swallow
		return true
	}
	if released && inside && idx >= 0 {
		opening_release := !menu.traveled && wall_now() - menu.opened_at < 0.5
		if !opening_release {
			menu_activate(s, in_sub, idx)
			ix.mode = .Swallow
		}
	}
	return true
}

// menu_key is the menu's keyboard: arrows, Right into a submenu, Left out
// of it, Enter, Escape, and the first letter of an item.
menu_key :: proc(s: ^Server, app: ^p.App, k: p.Key_Event) -> bool {
	if !menu.open {
		return false
	}
	in_sub := menu.sub_open >= 0 && menu.sub_hover >= 0
	items := in_sub ? menu.items[menu.sub_open].sub[:] : menu.items[:]
	cur := in_sub ? menu.sub_hover : menu.hover
	step :: proc(items: []Menu_Item, from, dir: int) -> int {
		n := len(items)
		if n == 0 {
			return -1
		}
		i := from
		for _ in 0 ..< n {
			i = ((i + dir) % n + n) % n
			if items[i].kind != .Sep && !items[i].disabled {
				return i
			}
		}
		return from
	}
	switch k.sym {
	case p.KEY_ESCAPE:
		if in_sub {
			menu.sub_hover = -1
			menu.sub_open = -1
		} else {
			menu_close(s)
		}
	case p.KEY_DOWN, p.KEY_UP:
		dir := k.sym == p.KEY_DOWN ? 1 : -1
		start := cur < 0 ? (dir > 0 ? -1 : len(items)) : cur
		n := step(items, start, dir)
		if in_sub {
			menu.sub_hover = n
		} else {
			menu.hover = n
			menu.sub_open = -1
		}
	case p.KEY_RIGHT:
		if !in_sub && cur >= 0 && menu.items[cur].kind == .Sub {
			menu_open_sub(cur)
			menu.sub_hover = step(menu.items[cur].sub[:], -1, 1)
		}
	case p.KEY_LEFT:
		if in_sub {
			menu.sub_hover = -1
			menu.sub_open = -1
		}
	case p.KEY_RETURN, p.KEY_SPACE:
		if cur >= 0 {
			if !in_sub && menu.items[cur].kind == .Sub {
				menu_open_sub(cur)
				menu.sub_hover = step(menu.items[cur].sub[:], -1, 1)
			} else {
				menu_activate(s, in_sub, cur)
			}
		}
	case:
		// The accelerator: the first item whose label starts with the letter.
		if k.sym >= 0x20 && k.sym < 0x7f {
			want := rune(k.sym)
			if want >= 'A' && want <= 'Z' {
				want += 32
			}
			for it, i in items {
				if it.kind == .Sep || it.disabled || len(it.label) == 0 {
					continue
				}
				first := rune(it.label[0])
				if first >= 'A' && first <= 'Z' {
					first += 32
				}
				if first == want {
					menu_activate(s, in_sub, i)
					break
				}
			}
		}
	}
	s.dirty = true
	return true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

draw_menu :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	if !menu.open {
		return
	}
	p.reset_clip(cv)
	draw_menu_list(app, cv, menu.items[:], menu.x, menu.y, menu.w, menu.hover, menu.sub_open)
	if menu.sub_open >= 0 && menu.sub_open < len(menu.items) {
		draw_menu_list(app, cv, menu.items[menu.sub_open].sub[:], menu.sub_x, menu.sub_y, menu.sub_w, menu.sub_hover, -1)
	}
}

draw_menu_list :: proc(app: ^p.App, cv: ^p.Canvas, items: []Menu_Item, x, y, w: f32, hover, open_sub: int) {
	f := &app.fonts
	h := menu_height(items)
	r := p.Rect{x, y, w, h}
	p.drop_shadow(cv, r, {8, 8, 8, 8}, 22, 0, {0, 8}, p.hexa(0x00000099))
	p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(0x0f0f12))
	p.stroke_round_rect(cv, r, {8, 8, 8, 8}, 1, p.hex(0x27272a))
	yy := y + MENU_PAD
	for it, i in items {
		if it.kind == .Sep {
			p.fill_rect(cv, {x + 1, yy + MENU_SEP / 2, w - 2, 1}, p.hex(0x27272a))
			yy += MENU_SEP
			continue
		}
		row := p.Rect{x + MENU_PAD, yy, w - 2 * MENU_PAD, MENU_ROW}
		if (i == hover || i == open_sub) && !it.disabled {
			p.fill_round_rect(cv, row, {5, 5, 5, 5}, p.hex(0x27272a))
		}
		col := u32(it.disabled ? 0x52525b : 0xfafafa)
		if it.kind == .Check && it.checked {
			cx := row.x + 12
			cy := yy + MENU_ROW / 2
			p.draw_line(cv, cx - 4, cy, cx - 1.5, cy + 3, 1.5, p.hex(0xa5b4fc))
			p.draw_line(cv, cx - 1.5, cy + 3, cx + 4, cy - 3.5, 1.5, p.hex(0xa5b4fc))
		}
		p.draw_text(cv, f, it.label, row.x + 26, yy + 18, 12.5, p.hex(col), .Sans, .Regular)
		if it.key != "" {
			kw := p.text_width(f, it.key, 11.5, .Sans, .Regular)
			p.draw_text(cv, f, it.key, row.x + row.w - kw - (it.kind == .Sub ? 22 : 8), yy + 18, 11.5, p.hex(0x71717a), .Sans, .Regular)
		}
		if it.kind == .Sub {
			ax := row.x + row.w - 12
			ay := yy + MENU_ROW / 2
			p.draw_line(cv, ax - 2, ay - 4, ax + 2, ay, 1.4, p.hex(0xa1a1aa))
			p.draw_line(cv, ax + 2, ay, ax - 2, ay + 4, 1.4, p.hex(0xa1a1aa))
		}
		yy += MENU_ROW
	}
}
