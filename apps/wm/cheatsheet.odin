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
	alt:   string, // other chords for the same action, as text
}

// cheat_rows builds the rows from the binding table, filtered.
cheat_rows :: proc(s: ^Server) -> []Cheat_Row {
	q := strings.to_lower(strings.to_string(cheat.filter), context.temp_allocator)
	rows := make([dynamic]Cheat_Row, 0, 96, context.temp_allocator)
	seen := make(map[string]int, 96, context.temp_allocator)
	for g in CHEAT_GROUPS {
		for &b in s.cfg.binds {
			if bind_group(b.act) != g {
				continue
			}
			// One row per action: Super+T on a row of its own under
			// Super+Return, both "Open term", is noise. A second chord for
			// the same action is named after the first row's label, dimmed
			// ("Open term  also Super+T"), so the caps column stays one
			// width and a bind line the user just added still shows even
			// when it duplicates a default.
			label := bind_human(&b)
			if at, dup := seen[label]; dup {
				r := &rows[at]
				r.alt = r.alt == "" ? chord_text(&b) : strings.concatenate({r.alt, ", ", chord_text(&b)}, context.temp_allocator)
				continue
			}
			r := Cheat_Row{keys = chord_parts(&b), label = label, group = g}
			if q != "" && !strings.contains(strings.to_lower(r.label, context.temp_allocator), q) && !strings.contains(strings.to_lower(chord_text(&b), context.temp_allocator), q) {
				continue
			}
			seen[label] = len(rows)
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
	HEAD :: f32(27)
	TOP :: f32(66)
	max_h := f32(o.h - ws_bar_h(s)) - 60
	avail_h := max_h - TOP - 20

	// Rows are 19 px, and tighten (down to 17 px) when that saves a whole
	// column — otherwise one overflowing row sits alone in a column.
	ROW := f32(19)
	placed, cols := cheat_layout(rows, avail_h, ROW, HEAD)
	if cols > 1 {
		_, tight := cheat_layout(rows, avail_h, 17, HEAD)
		for ROW > 17 && cols > tight {
			ROW -= 1
			placed, cols = cheat_layout(rows, avail_h, ROW, HEAD)
		}
	}
	col_w := min(f32(330), (f32(o.w) - 72) / f32(cols))
	// Each column's labels start on one line: past the widest run of key
	// caps in that column, so a four-cap chord does not push its label out
	// of line with its neighbours'. A gesture whose text is wider than half
	// the column is left out of the measure and simply pushes its own label.
	label_x := make([]f32, cols, context.temp_allocator)
	for pl in placed {
		if pl.row < 0 {
			continue
		}
		w := cheat_caps_w(f, rows[pl.row].keys)
		if w <= col_w * 0.5 {
			label_x[pl.col] = max(label_x[pl.col], w)
		}
	}
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
		lx := max(kx + 10, x + label_x[pl.col] + 10)
		label := ellipsize_end(f, r.label, 11.5, .Regular, x + col_w - 10 - lx)
		p.draw_text(cv, f, label, lx, yy + 13, 11.5, p.hex(0xd4d4d8), .Sans, .Regular)
		if r.alt != "" {
			ax := lx + p.text_width(f, label, 11.5, .Sans, .Regular) + 8
			if room := x + col_w - 10 - ax; room > 40 {
				alt := ellipsize_end(f, strings.concatenate({"also ", r.alt}, context.temp_allocator), 10.5, .Regular, room)
				p.draw_text(cv, f, alt, ax, yy + 13, 10.5, p.hex(0x71717a), .Sans, .Regular)
			}
		}
	}
	p.pop_clip(cv)
}

// cheat_caps_w is the width a row's key caps take, as cheat_draw lays them.
cheat_caps_w :: proc(f: ^p.Fonts, keys: []string) -> f32 {
	w := f32(0)
	for part, j in keys {
		if j > 0 {
			w += 3
		}
		w += p.text_width(f, part, 10.5, .Sans, .Medium) + 9
	}
	return w
}

Cheat_Placed :: struct {
	col: int,
	y:   f32,
	row: int, // index into rows; negative for a heading of rows[-row-1]
}

// cheat_layout lays the rows out in columns, top to bottom, starting a new
// column whenever the next row would run past the bottom. A heading never
// ends a column on its own, nor with a single row under it.
cheat_layout :: proc(rows: []Cheat_Row, avail_h, row_h, head_h: f32) -> ([dynamic]Cheat_Placed, int) {
	placed := make([dynamic]Cheat_Placed, 0, len(rows) + 8, context.temp_allocator)
	col := 0
	y := f32(0)
	last := ""
	for r, i in rows {
		if r.group != last {
			if y + head_h + 2 * row_h > avail_h && y > 0 {
				col += 1
				y = 0
			}
			append(&placed, Cheat_Placed{col, y, -1 - i})
			y += head_h
			last = r.group
		}
		if y + row_h > avail_h {
			col += 1
			y = 0
		}
		append(&placed, Cheat_Placed{col, y, i})
		y += row_h
	}
	return placed, col + 1
}
