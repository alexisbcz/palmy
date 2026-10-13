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

import "core:fmt"
import "core:strconv"
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
	keys:   []string,
	label:  string,
	group:  string,
	alt:    string, // other chords for the same action, as text
	search: string, // what the filter matches: every label and chord folded into the row, lowercased
}

// cheat_rows builds the rows from the binding table, filtered by `filter`.
//
// Families of bindings fold into one row: Super+1 … Super+9 is "Workspace
// 1…9", and Super+H/J/K/L moving focus four ways is one row with four caps.
// Twenty-seven workspace rows said the same thing nine times and pushed the
// sheet to three columns; folded, the whole table fits the two the spec
// asks for. The filter still sees every row that was folded in, so typing
// "workspace 3" finds the "Workspace 1…9" row.
cheat_rows :: proc(s: ^Server, filter: string) -> []Cheat_Row {
	q := strings.to_lower(filter, context.temp_allocator)
	rows := make([dynamic]Cheat_Row, 0, 96, context.temp_allocator)
	for g in CHEAT_GROUPS {
		base := make([dynamic]Cheat_Row, 0, 48, context.temp_allocator)
		seen := make(map[string]int, 48, context.temp_allocator)
		if g == "Focus" && s.cfg.super_tap && !session.kiosk {
			// The overview's main way in has no binding to read: a lone tap
			// of Super (keys.odin). It is the first thing worth knowing.
			keys := make([]string, 1, context.temp_allocator)
			keys[0] = "Super"
			append(&base, Cheat_Row{keys = keys, label = "Overview (tap alone)", group = g, search = "super tap overview"})
		}
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
			text := chord_text(&b)
			if at, dup := seen[label]; dup {
				r := &base[at]
				r.alt = r.alt == "" ? text : strings.concatenate({r.alt, ", ", text}, context.temp_allocator)
				r.search = strings.concatenate({r.search, " ", strings.to_lower(text, context.temp_allocator)}, context.temp_allocator)
				continue
			}
			seen[label] = len(base)
			append(&base, Cheat_Row{keys = chord_parts(&b), label = label, group = g, search = strings.to_lower(strings.concatenate({label, " ", text}, context.temp_allocator), context.temp_allocator)})
		}
		for r in cheat_fold(base[:]) {
			if q != "" && !strings.contains(r.search, q) {
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

// cheat_same_mods says whether two rows' caps agree on everything but the
// last one, the key itself.
cheat_same_mods :: proc(a, b: Cheat_Row) -> bool {
	if len(a.keys) != len(b.keys) || len(a.keys) < 2 {
		return false
	}
	for i in 0 ..< len(a.keys) - 1 {
		if a.keys[i] != b.keys[i] {
			return false
		}
	}
	return true
}

// cheat_digit is the digit a row's key is, or -1.
cheat_digit :: proc(r: Cheat_Row) -> int {
	k := r.keys[len(r.keys) - 1]
	if len(k) == 1 && k[0] >= '0' && k[0] <= '9' {
		return int(k[0] - '0')
	}
	return -1
}

// cheat_dir_word is the direction a label ends in, and the label before it.
cheat_dir_word :: proc(label: string) -> (prefix: string, word: string, ok: bool) {
	for w in ([4]string{"left", "right", "up", "down"}) {
		if strings.has_suffix(label, w) && len(label) > len(w) + 1 && label[len(label) - len(w) - 1] == ' ' {
			return label[:len(label) - len(w) - 1], w, true
		}
	}
	return "", "", false
}

cheat_is_arrow :: proc(k: string) -> bool {
	return k == "Left" || k == "Right" || k == "Up" || k == "Down"
}

// cheat_fold folds runs of one group's rows into a row each: a digit run
// (same modifiers, keys counting up by one, labels that end in that digit)
// becomes "1…9"; four rows that move one way each (same modifiers, labels
// "<x> left/down/up/right") become one row, with the four letter caps, or a
// single "Arrows" cap for the arrow keys. A row with other chords folded
// into it already (`alt`) is left alone: folding would lose them.
cheat_fold :: proc(rows: []Cheat_Row) -> []Cheat_Row {
	out := make([dynamic]Cheat_Row, 0, len(rows), context.temp_allocator)
	i := 0
	for i < len(rows) {
		r := rows[i]
		// A digit run.
		if d := cheat_digit(r); d >= 0 && r.alt == "" && strings.has_suffix(r.label, r.keys[len(r.keys) - 1]) {
			stem := r.label[:len(r.label) - 1]
			j := i + 1
			for j < len(rows) {
				n := rows[j]
				if n.alt != "" || !cheat_same_mods(r, n) || cheat_digit(n) != d + (j - i) || n.label != strings.concatenate({stem, n.keys[len(n.keys) - 1]}, context.temp_allocator) {
					break
				}
				j += 1
			}
			if j - i >= 3 {
				span := fmt.tprintf("%d…%d", d, d + (j - i) - 1)
				keys := make([]string, len(r.keys), context.temp_allocator)
				copy(keys, r.keys)
				keys[len(keys) - 1] = span
				search := make([dynamic]string, 0, j - i, context.temp_allocator)
				for k in i ..< j {
					append(&search, rows[k].search)
				}
				append(&out, Cheat_Row{keys = keys, label = strings.concatenate({stem, span}, context.temp_allocator), group = r.group, search = strings.join(search[:], " ", context.temp_allocator)})
				i = j
				continue
			}
		}
		// Four directions.
		if i + 4 <= len(rows) && len(r.keys) >= 2 {
			stem, _, ok := cheat_dir_word(r.label)
			words: [4]string
			seen: bit_set[0 ..< 4]
			for k in 0 ..< 4 {
				n := rows[i + k]
				st, w, nok := cheat_dir_word(n.label)
				if !ok || !nok || st != stem || n.alt != "" || !cheat_same_mods(r, n) {
					ok = false
					break
				}
				idx := w == "left" ? 0 : w == "right" ? 1 : w == "up" ? 2 : 3
				if idx in seen {
					ok = false
					break
				}
				seen += {idx}
				words[k] = w
			}
			if ok {
				mods := r.keys[:len(r.keys) - 1]
				arrows := true
				for k in 0 ..< 4 {
					arrows = arrows && cheat_is_arrow(rows[i + k].keys[len(r.keys) - 1])
				}
				keys := make([dynamic]string, 0, len(mods) + 4, context.temp_allocator)
				append(&keys, ..mods)
				label := stem
				if arrows {
					append(&keys, "Arrows")
				} else {
					for k in 0 ..< 4 {
						append(&keys, rows[i + k].keys[len(r.keys) - 1])
					}
					label = strings.concatenate({stem, " ", strings.join(words[:], ", ", context.temp_allocator)}, context.temp_allocator)
				}
				search := make([dynamic]string, 0, 4, context.temp_allocator)
				for k in 0 ..< 4 {
					append(&search, rows[i + k].search)
				}
				append(&out, Cheat_Row{keys = keys[:], label = label, group = r.group, search = strings.join(search[:], " ", context.temp_allocator)})
				i += 4
				continue
			}
		}
		append(&out, r)
		i += 1
	}
	return out[:]
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
	q := strings.to_string(cheat.filter)
	all := cheat_rows(s, "")
	rows := q == "" ? all : cheat_rows(s, q)
	HEAD :: f32(27)
	TOP :: f32(66)
	max_h := f32(o.h - ws_bar_h(s)) - 60
	avail_h := max_h - TOP - 20

	// Rows are 19 px, and tighten (down to 17 px) when that saves a whole
	// column — otherwise one overflowing row sits alone in a column.
	//
	// The panel's size comes from the whole table, not the filtered rows:
	// a panel that shrinks and jumps with every letter typed makes the
	// field being typed into move under the eyes.
	ROW := f32(19)
	full, cols := cheat_layout(all, avail_h, ROW, HEAD)
	if cols > 1 {
		_, tight := cheat_layout(all, avail_h, 17, HEAD)
		for ROW > 17 && cols > tight {
			ROW -= 1
			full, cols = cheat_layout(all, avail_h, ROW, HEAD)
		}
	}
	placed := full
	if q != "" {
		placed, _ = cheat_layout(rows, avail_h, ROW, HEAD)
	}
	col_w := min(f32(cols <= 2 ? 460 : 380), (f32(o.w) - 72) / f32(cols))
	// Every label starts on one line: past the widest run of key caps in
	// the whole table, so a four-cap chord does not push its label out of
	// line with its neighbours', and the column does not shift as typing
	// filters rows out (it used to be measured from the visible rows). A
	// gesture whose text is wider than half the column is left out of the
	// measure and simply pushes its own label.
	label_x := f32(0)
	for r in all {
		w := cheat_caps_w(f, r.keys)
		if w <= col_w * 0.5 {
			label_x = max(label_x, w)
		}
	}
	used_h := f32(0)
	for pl in full {
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
			if pl.cont {
				// A group that runs on into the next column says so, or
				// its rows there read as belonging to nothing.
				gx := x + p.text_width(f, r.group, 11, .Sans, .Semibold) + 6
				p.draw_text(cv, f, "continued", gx, yy + 18, 11, p.hex(0x52525b), .Sans, .Regular)
			}
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
		lx := max(kx + 10, x + label_x + 10)
		label := ellipsize_end(f, r.label, 11.5, .Regular, x + col_w - 10 - lx)
		p.draw_text(cv, f, label, lx, yy + 13, 11.5, p.hex(0xd4d4d8), .Sans, .Regular)
		if r.alt != "" {
			ax := lx + p.text_width(f, label, 11.5, .Sans, .Regular) + 8
			if alt := cheat_alt_text(f, r.alt, x + col_w - 10 - ax); alt != "" {
				p.draw_text(cv, f, alt, ax, yy + 13, 10.5, p.hex(0x71717a), .Sans, .Regular)
			}
		}
	}
	p.pop_clip(cv)
}

// cheat_alt_text is "also A, B" cut to whole chords: as many as fit in
// `room`, then "+n" for the rest. A chord cut in the middle ("also
// Super+P…") names a key that does not exist.
cheat_alt_text :: proc(f: ^p.Fonts, alt: string, room: f32) -> string {
	parts := strings.split(alt, ", ", context.temp_allocator)
	for k := len(parts); k >= 0; k -= 1 {
		rest := len(parts) - k
		text := k > 0 ? strings.concatenate({"also ", strings.join(parts[:k], ", ", context.temp_allocator)}, context.temp_allocator) : ""
		if rest > 0 {
			more := strings.concatenate({"+", fmt_int(rest)}, context.temp_allocator)
			text = text == "" ? more : strings.concatenate({text, " ", more}, context.temp_allocator)
		}
		if p.text_width(f, text, 10.5, .Sans, .Regular) <= room {
			return text
		}
	}
	return ""
}

fmt_int :: proc(n: int) -> string {
	buf := make([]u8, 20, context.temp_allocator)
	return strconv.write_int(buf, i64(n), 10)
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
	col:  int,
	y:    f32,
	row:  int, // index into rows; negative for a heading of rows[-row-1]
	cont: bool, // a heading repeated at the top of a column its group ran on into
}

// cheat_layout lays the rows out in columns, top to bottom, starting a new
// column whenever the next row would run past the bottom. A heading never
// ends a column on its own, nor with a single row under it; a group cut by
// a column break has its heading repeated, marked continued, at the top of
// the next.
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
			append(&placed, Cheat_Placed{col, y, -1 - i, false})
			y += head_h
			last = r.group
		}
		if y + row_h > avail_h {
			col += 1
			y = 0
			append(&placed, Cheat_Placed{col, y, -1 - i, true})
			y += head_h
		}
		append(&placed, Cheat_Placed{col, y, i, false})
		y += row_h
	}
	return placed, col + 1
}
