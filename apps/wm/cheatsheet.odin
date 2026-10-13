// cheatsheet.odin — Super+/ lists every shortcut (UX.md P1-8).
//
// Generated from the live binding table, never from a string literal, so it
// cannot describe keys the configuration no longer binds and it picks up a
// new `bind` line the moment the file is saved. Rows are grouped by what
// they act on (Windows, Focus, Workspaces, Layout, Launch, Session), each a
// chord drawn as key caps beside the action in words; the mouse gestures,
// which have no binding to read, are a fixed section at the end.
//
// Typing filters the rows. Escape closes it; so does any listed chord, which
// also runs.
package wm

import "core:strings"
import p "palmy:."

Cheat :: struct {
	open:   bool,
	filter: strings.Builder,
	panel:  p.Rect,
}

cheat: Cheat

CHEAT_GROUPS := [?]string{"Windows", "Focus", "Workspaces", "Layout", "Launch", "Session"}

CHEAT_MOUSE := [?][2]string {
	{"Double-click title", "Maximize or restore"},
	{"Drag title to an edge", "Snap to half, quarter or maximize"},
	{"Middle-click title", "Lower window"},
	{"Right-click title", "Window menu"},
	{"Super + drag", "Move window"},
	{"Super + right-drag", "Resize from nearest corner"},
	{"Right-click desktop", "Desktop menu"},
	{"Top-left corner", "Overview"},
}

cheat_open :: proc(s: ^Server) {
	if cheat.open {
		cheat_close(s)
		return
	}
	menu_close(s)
	cheat.open = true
	strings.builder_reset(&cheat.filter)
	s.dirty = true
}

cheat_close :: proc(s: ^Server) {
	cheat.open = false
	s.dirty = true
}

Cheat_Row :: struct {
	keys:  []string,
	label: string,
	group: string,
}

// cheat_rows builds the rows from the binding table, filtered.
cheat_rows :: proc(s: ^Server) -> []Cheat_Row {
	q := strings.to_lower(strings.to_string(cheat.filter), context.temp_allocator)
	rows := make([dynamic]Cheat_Row, 0, 96, context.temp_allocator)
	for g in CHEAT_GROUPS {
		for &b in s.cfg.binds {
			if bind_group(b.act) != g {
				continue
			}
			r := Cheat_Row{keys = chord_parts(&b), label = bind_human(&b), group = g}
			if q != "" && !strings.contains(strings.to_lower(r.label, context.temp_allocator), q) && !strings.contains(strings.to_lower(chord_text(&b), context.temp_allocator), q) {
				continue
			}
			append(&rows, r)
		}
	}
	for m in CHEAT_MOUSE {
		// The gesture is one "cap"; it needs a slice that outlives the loop.
		keys := make([]string, 1, context.temp_allocator)
		keys[0] = m[0]
		r := Cheat_Row{keys = keys, label = m[1], group = "Mouse"}
		if q != "" && !strings.contains(strings.to_lower(m[1], context.temp_allocator), q) && !strings.contains(strings.to_lower(m[0], context.temp_allocator), q) {
			continue
		}
		append(&rows, r)
	}
	return rows[:]
}

cheat_key :: proc(s: ^Server, app: ^p.App, k: p.Key_Event, code: u32) -> bool {
	if !cheat.open {
		return false
	}
	switch k.sym {
	case p.KEY_ESCAPE:
		cheat_close(s)
		return true
	case p.KEY_BACKSPACE:
		b := &cheat.filter
		if n := len(b.buf); n > 0 {
			resize(&b.buf, n - 1)
		}
		s.dirty = true
		return true
	case KEY_SUPER_L, KEY_SUPER_R:
		return true
	}
	if k.mods & {.Ctrl, .Alt, .Super} != {} {
		// A listed chord: close, and let the binding run.
		cheat_close(s)
		return false
	}
	if k.sym >= 0x20 && k.sym < 0x7f {
		strings.write_byte(&cheat.filter, u8(k.sym))
		s.dirty = true
	}
	return true
}

cheat_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if !cheat.open {
		return false
	}
	if (in_.pressed[.Left] || in_.pressed[.Right]) && !p.rect_contains(cheat.panel, f32(mp.x), f32(mp.y)) {
		cheat_close(s)
		ix.mode = .Swallow
	}
	return true
}

cheat_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	if !cheat.open {
		return
	}
	f := &app.fonts
	o := s.outputs[s.cur_out]
	rows := cheat_rows(s)
	ROW :: f32(19)
	HEAD :: f32(27)
	TOP :: f32(66)
	max_h := f32(o.h - ws_bar_h(s)) - 60
	avail_h := max_h - TOP - 20

	// Lay the rows out in columns, top to bottom, starting a new column
	// whenever the next row would run past the bottom. A heading never ends
	// a column on its own.
	Placed :: struct {
		col:  int,
		y:    f32,
		row:  int, // index into rows; negative for a heading of rows[-row-1]
	}
	placed := make([dynamic]Placed, 0, len(rows) + 8, context.temp_allocator)
	col := 0
	y := f32(0)
	last := ""
	for r, i in rows {
		if r.group != last {
			if y + HEAD + ROW > avail_h && y > 0 {
				col += 1
				y = 0
			}
			append(&placed, Placed{col, y, -1 - i})
			y += HEAD
			last = r.group
		}
		if y + ROW > avail_h {
			col += 1
			y = 0
		}
		append(&placed, Placed{col, y, i})
		y += ROW
	}
	cols := col + 1
	col_w := min(f32(330), (f32(o.w) - 72) / f32(cols))
	used_h := f32(0)
	for pl in placed {
		used_h = max(used_h, pl.y + (pl.row < 0 ? HEAD : ROW))
	}
	pw := col_w * f32(cols) + 40
	ph := min(TOP + used_h + 20, max_h)
	panel := p.Rect{f32(o.x) + (f32(o.w) - pw) / 2, f32(o.y + ws_bar_h(s)) + (f32(o.h - ws_bar_h(s)) - ph) / 2, pw, ph}
	cheat.panel = panel
	p.reset_clip(cv)
	p.fill_rect(cv, {f32(o.x), f32(o.y), f32(o.w), f32(o.h)}, p.hexa(0x00000055))
	p.drop_shadow(cv, panel, {14, 14, 14, 14}, 40, 0, {0, 14}, p.hexa(0x000000aa))
	p.fill_round_rect(cv, panel, {14, 14, 14, 14}, p.hex(0x0f0f12))
	p.stroke_round_rect(cv, panel, {14, 14, 14, 14}, 1, p.hex(0x27272a))
	p.draw_text(cv, f, "Keyboard shortcuts", panel.x + 20, panel.y + 34, 17, p.hex(0xfafafa), .Sans, .Semibold)
	q := strings.to_string(cheat.filter)
	hint := q != "" ? q : "type to filter"
	hw := max(p.text_width(f, hint, 12.5, .Sans, .Regular) + 28, 200)
	fr := p.Rect{panel.x + panel.w - hw - 20, panel.y + 16, hw, 28}
	p.fill_round_rect(cv, fr, {7, 7, 7, 7}, p.hex(0x18181b))
	p.stroke_round_rect(cv, fr, {7, 7, 7, 7}, 1, p.hex(q != "" ? ACCENT : 0x27272a))
	p.draw_text(cv, f, hint, fr.x + 12, fr.y + 18.5, 12.5, p.hex(q != "" ? 0xfafafa : 0x71717a), .Sans, .Regular)
	if len(rows) == 0 {
		p.draw_text(cv, f, "no shortcut matches", panel.x + 20, panel.y + TOP + 16, 12.5, p.hex(0x71717a), .Sans, .Regular)
	}

	p.push_clip(cv, {panel.x, panel.y + TOP - 8, panel.w, panel.h - TOP})
	for pl in placed {
		x := panel.x + 20 + f32(pl.col) * col_w
		yy := panel.y + TOP + pl.y
		if pl.row < 0 {
			r := rows[-pl.row - 1]
			p.draw_text(cv, f, r.group, x, yy + 18, 11, p.hex(0xa5b4fc), .Sans, .Semibold)
			continue
		}
		r := rows[pl.row]
		kx := x
		for part, j in r.keys {
			if j > 0 {
				kx += 3
			}
			kw := p.text_width(f, part, 10.5, .Sans, .Medium) + 9
			cap := p.Rect{kx, yy + 1, kw, 16}
			p.fill_round_rect(cv, cap, {4, 4, 4, 4}, p.hex(0x18181b))
			p.stroke_round_rect(cv, cap, {4, 4, 4, 4}, 1, p.hex(0x3f3f46))
			p.draw_text(cv, f, part, kx + 4.5, yy + 13, 10.5, p.hex(0xe4e4e7), .Sans, .Medium)
			kx += kw
		}
		lx := max(kx + 8, x + 112)
		label := ellipsize_end(f, r.label, 11.5, .Regular, x + col_w - 10 - lx)
		p.draw_text(cv, f, label, lx, yy + 13, 11.5, p.hex(0xd4d4d8), .Sans, .Regular)
	}
	p.pop_clip(cv)
}
