// The keyboard.
//
// Every command has a key, because this compositor cannot synthesise a pointer
// click — and the recorder that drives the demo cannot hold a modifier down
// either, so every command a demo needs also has a bare function key. The two
// tables below are the whole command surface; the toolbar just calls the same
// procedures.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."

// Keysyms palmy does not name yet.
KEY_F6 :: 0xffc3
KEY_F7 :: 0xffc4
KEY_F8 :: 0xffc5
KEY_F9 :: 0xffc6
KEY_F10 :: 0xffc7
KEY_F12 :: 0xffc9
KEY_KP_ADD :: 0xffab
KEY_KP_SUB :: 0xffad

NO_MODS :: p.Modifiers{}

// plain matches an unmodified, non-repeating press: a command fires once.
plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == NO_MODS {
			return true
		}
	}
	return false
}

// nav reads a movement key: how many times it arrived this frame (repeats
// included, so holding Down keeps moving) and whether Shift or Ctrl was down.
//
// Alt and Super are excluded, because an arrow with Alt held is a *command* —
// Alt+Left and Alt+Right resize a table column, Alt+Up and Alt+Down scale a
// picture — and without this the key would do both: resize the column and then
// walk the caret out of the cell it was resizing. Ctrl stays, because
// Ctrl+arrow is word-wise motion rather than a separate command.
nav :: proc(ui: ^p.Ctx, sym: u32) -> (times: int, shift: bool, ctrl: bool) {
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Alt, .Super} == NO_MODS {
			times += 1
			if .Shift in k.mods {shift = true}
			if .Ctrl in k.mods {ctrl = true}
		}
	}
	return
}

// edit_count counts presses of an editing key, repeats included so holding it
// keeps deleting, but only when no command modifier is down — Ctrl+Backspace
// is a different command and must not also delete a single character.
edit_count :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Ctrl, .Alt, .Super} == NO_MODS {
			n += 1
		}
	}
	return n
}

// typed_printable is the text produced this frame with control characters and
// DEL removed — Return, Tab and the Ctrl shortcuts all produce bytes here that
// must not land in the document.
typed_printable :: proc(ui: ^p.Ctx, alloc := context.temp_allocator) -> string {
	src := p.typed_text(ui)
	b := strings.builder_make(alloc)
	for i in 0 ..< len(src) {
		c := src[i]
		if c >= 0x20 && c != 0x7f {
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

field_edit :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8, swallow: ^bool) -> bool {
	changed := false
	typed := swallow^ ? "" : typed_printable(ui)
	swallow^ = false
	for i in 0 ..< len(typed) {
		append(buf, typed[i])
		changed = true
	}
	if p.key_pressed(ui, p.KEY_BACKSPACE) && len(buf^) > 0 {
		n := 1
		for n < len(buf^) && buf^[len(buf^) - n] & 0xc0 == 0x80 {
			n += 1
		}
		resize(buf, len(buf^) - n)
		changed = true
	}
	if p.shortcut(ui, 'u', {.Ctrl}) && len(buf^) > 0 {
		clear(buf)
		changed = true
	}
	return changed
}

handle_keys :: proc(ui: ^p.Ctx, st: ^State, app: ^p.App) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}

	// The wheel scrolls the workspace whatever has focus.
	if sy := ui.input.scroll.y; sy != 0 {
		st.scroll -= sy * 4
		clamp_scroll(st)
	}
	if sx := ui.input.scroll.x; sx != 0 {
		st.hscroll -= sx * 4
		clamp_scroll(st)
	}

	if st.help {
		if len(ui.input.keys) > 0 || ui.input.pressed[.Left] {
			st.help = false
		}
		return
	}
	if plain(ui, p.KEY_F1) || p.shortcut(ui, '/', {.Ctrl}) {
		st.help = true
		return
	}

	switch st.mode {
	case .Prompt:
		keys_prompt(ui, st)
		return
	case .Find:
		keys_find(ui, st)
		return
	case .Doc:
	}

	if collab_keys(ui, st) {
		return
	}
	keys_mouse(ui, st)
	keys_commands(ui, st)
	keys_motion(ui, st)

	// Text last: a command may have asked for the frame's keystrokes to be
	// dropped, and reading the text first would have typed them anyway.
	typed := st.swallow ? "" : typed_printable(ui)
	st.swallow = false
	if len(typed) > 0 {
		type_text(st, typed)
	}
	for _ in 0 ..< edit_count(ui, p.KEY_RETURN) + edit_count(ui, p.KEY_KP_ENTER) {
		split_line(st)
	}
	for _ in 0 ..< edit_count(ui, p.KEY_BACKSPACE) {
		backspace(st)
	}
	for _ in 0 ..< edit_count(ui, p.KEY_DELETE) {
		delete_forward(st)
	}

	// Ctrl with either delete key takes a whole word.
	if p.shortcut(ui, p.KEY_BACKSPACE, {.Ctrl}, true) {
		if !has_selection(st) {
			move_h(st, -1, true, true)
		}
		backspace(st)
	}
	if p.shortcut(ui, p.KEY_DELETE, {.Ctrl}, true) {
		if !has_selection(st) {
			move_h(st, 1, true, true)
		}
		delete_forward(st)
	}
}

// ---------------------------------------------------------------------------
// Pointer
// ---------------------------------------------------------------------------

keys_mouse :: proc(ui: ^p.Ctx, st: ^State) {
	m := ui.input.mouse
	inside := p.rect_contains(st.view, m.x, m.y)
	if ui.input.pressed[.Left] && inside {
		q := pos_at_view(st, m.x - st.view.x, m.y - st.view.y)
		st.caret = q
		st.anchor = q
		st.mark = false
		st.dragging = true
		st.focus_doc = true
		st.pending_on = false
		st.goal_ok = false
		history_break(&st.hist)
	}
	if st.dragging {
		if ui.input.down[.Left] {
			st.caret = pos_at_view(st, m.x - st.view.x, m.y - st.view.y)
		} else {
			st.dragging = false
		}
	}
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

keys_commands :: proc(ui: ^p.Ctx, st: ^State) {
	fire :: proc(st: ^State) {
		st.swallow = true
	}

	// --- character formatting
	if plain(ui, p.KEY_F2) || p.shortcut(ui, 'b', {.Ctrl}) {
		toggle_bold(st)
		fire(st)
	}
	if plain(ui, p.KEY_F3) || p.shortcut(ui, 'i', {.Ctrl}) {
		toggle_italic(st)
		fire(st)
	}
	if plain(ui, p.KEY_F4) || p.shortcut(ui, 'u', {.Ctrl}) {
		toggle_underline(st)
		fire(st)
	}
	if p.shortcut(ui, 'j', {.Ctrl}) {
		toggle_mono(st)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_SPACE, {.Ctrl}) {
		clear_formatting(st)
		fire(st)
	}

	// --- paragraph formatting
	if plain(ui, p.KEY_F5) {
		cycle_kind(st)
		fire(st)
	}
	if plain(ui, KEY_F6) || p.shortcut(ui, 'l', {.Ctrl, .Shift}) {
		set_list(st, .Bullet)
		fire(st)
	}
	if plain(ui, KEY_F7) || p.shortcut(ui, 'n', {.Ctrl, .Shift}) {
		set_list(st, .Numbered)
		fire(st)
	}
	if plain(ui, KEY_F8) {
		cycle_align(st)
		fire(st)
	}
	for sym, i in ([?]u32{'0', '1', '2', '3', '4', '5'}) {
		if p.shortcut(ui, sym, {.Ctrl}) {
			set_kind(st, Para_Kind(i))
			fire(st)
		}
	}
	if p.shortcut(ui, 'l', {.Ctrl}) {set_align(st, .Left);fire(st)}
	if p.shortcut(ui, 'e', {.Ctrl}) {set_align(st, .Center);fire(st)}
	if p.shortcut(ui, 'r', {.Ctrl}) {set_align(st, .Right);fire(st)}
	if p.shortcut(ui, 'j', {.Ctrl, .Shift}) {set_align(st, .Justify);fire(st)}
	// Tab is the table key first and the indent key second: inside a grid it
	// is how every word processor walks the cells, and Tab at the last cell
	// grows the table by a row.
	if plain(ui, p.KEY_TAB) {
		if !table_move_cell(st, 1) {
			indent_paras(st, 1)
		}
		fire(st)
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		if !table_move_cell(st, -1) {
			indent_paras(st, -1)
		}
		fire(st)
	}

	// --- selection, clipboard, history
	if p.shortcut(ui, p.KEY_RETURN, {.Ctrl}) || p.shortcut(ui, p.KEY_KP_ENTER, {.Ctrl}) {
		insert_page_break(st)
		fire(st)
	}

	// --- prose. Ctrl+G opens the problems panel and checks; the four Alt keys
	// work the alert the caret is sitting in, so the panel never has to be
	// clicked to use the feature from the keyboard.
	if p.shortcut(ui, 'g', {.Ctrl}) {prose_toggle(st);fire(st)}
	if p.shortcut(ui, 'n', {.Alt}) {prose_step(st, 1);fire(st)}
	if p.shortcut(ui, 'p', {.Alt}) {prose_step(st, -1);fire(st)}
	if p.shortcut(ui, 'y', {.Alt}) {prose_accept(st);fire(st)}
	if p.shortcut(ui, 'x', {.Alt}) {prose_ignore(st);fire(st)}
	if p.shortcut(ui, 'x', {.Alt, .Shift}) {prose_restore_rules(st);fire(st)}

	if p.shortcut(ui, 'a', {.Ctrl}) {select_all(st);fire(st)}
	if plain(ui, KEY_F10) {
		toggle_mark(st)
		fire(st)
	}
	if p.shortcut(ui, 'w', {.Ctrl}) {select_word(st);fire(st)}
	if p.shortcut(ui, 'c', {.Ctrl}) {do_copy(st);fire(st)}
	if p.shortcut(ui, 'x', {.Ctrl}) {do_cut(st);fire(st)}
	if p.shortcut(ui, 'v', {.Ctrl}) {do_paste(st);fire(st)}
	if p.shortcut(ui, 'z', {.Ctrl}) {do_undo(st);fire(st)}
	if p.shortcut(ui, 'y', {.Ctrl}) || p.shortcut(ui, 'z', {.Ctrl, .Shift}) {
		do_redo(st)
		fire(st)
	}

	// --- tables
	//
	// Every one of these also has a bare function key or an unmodified
	// alternative where it can, because the recorder that drives the demo
	// cannot hold a modifier down. The table keys are grouped on Alt, which
	// `wtype` can send as a chord.
	if p.shortcut(ui, 't', {.Ctrl, .Shift}) {
		open_prompt(st, .Insert_Table)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_RETURN, {.Alt}) || p.shortcut(ui, 'r', {.Alt}) {
		table_row_cmd(st, true)
		fire(st)
	}
	if p.shortcut(ui, 'r', {.Alt, .Shift}) {
		table_row_cmd(st, false)
		fire(st)
	}
	if p.shortcut(ui, 'c', {.Alt}) {
		table_col_cmd(st, true)
		fire(st)
	}
	if p.shortcut(ui, 'c', {.Alt, .Shift}) {
		table_col_cmd(st, false)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_BACKSPACE, {.Alt}) {
		table_delete_row_cmd(st)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_DELETE, {.Alt}) {
		table_delete_col_cmd(st)
		fire(st)
	}
	if p.shortcut(ui, 'h', {.Alt}) {
		table_toggle_header(st)
		fire(st)
	}
	if p.shortcut(ui, 'b', {.Alt}) {
		table_toggle_borders(st)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_RIGHT, {.Alt}) {
		table_nudge_width(st, 24)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_LEFT, {.Alt}) {
		table_nudge_width(st, -24)
		fire(st)
	}
	if p.shortcut(ui, 'k', {.Alt}) {
		delete_block(st)
		fire(st)
	}

	// --- pictures
	if p.shortcut(ui, 'i', {.Ctrl, .Shift}) {
		open_prompt(st, .Insert_Image)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_UP, {.Alt}) {
		image_nudge_scale(st, 1.25)
		fire(st)
	}
	if p.shortcut(ui, p.KEY_DOWN, {.Alt}) {
		image_nudge_scale(st, 0.8)
		fire(st)
	}

	// --- find and replace
	if plain(ui, KEY_F9) || p.shortcut(ui, 'f', {.Ctrl}) || p.shortcut(ui, 'h', {.Ctrl}) {
		st.mode = .Find
		st.find_field = 0
		if len(st.find) == 0 && has_selection(st) {
			t := selection_text(st, context.temp_allocator)
			if len(t) > 0 && len(t) < 64 {
				clear(&st.find)
				append(&st.find, ..transmute([]u8)t)
			}
		}
		st.find_hits = count_hits(st)
		return
	}
	if plain(ui, p.KEY_F11) {replace_one(st);fire(st)}
	if plain(ui, KEY_F12) {replace_all(st);fire(st)}

	// --- zoom
	if plain(ui, KEY_KP_ADD) || p.shortcut(ui, '=', {.Ctrl}) || p.shortcut(ui, '+', {.Ctrl, .Shift}) {
		set_zoom(st, st.zoom_i + 1)
		fire(st)
	}
	if plain(ui, KEY_KP_SUB) || p.shortcut(ui, '-', {.Ctrl}) {
		set_zoom(st, st.zoom_i - 1)
		fire(st)
	}
	if p.shortcut(ui, '9', {.Ctrl}) {set_zoom(st, 3);fire(st)}

	// --- files
	if p.shortcut(ui, 's', {.Ctrl}) {
		if st.path == "" {
			open_prompt(st, .Save_As)
		} else {
			do_save(st, st.path)
		}
		fire(st)
	}
	if p.shortcut(ui, 's', {.Ctrl, .Shift}) {open_prompt(st, .Save_As);fire(st)}
	if p.shortcut(ui, 'o', {.Ctrl}) {open_prompt(st, .Open);fire(st)}
	if p.shortcut(ui, 'm', {.Ctrl}) {open_prompt(st, .Export_Md);fire(st)}
	if p.shortcut(ui, 'm', {.Ctrl, .Shift}) {open_prompt(st, .Import_Md);fire(st)}
	if p.shortcut(ui, 'h', {.Ctrl, .Shift}) {open_prompt(st, .Export_Html);fire(st)}
	if p.shortcut(ui, 'p', {.Ctrl}) {open_prompt(st, .Export_Pdf);fire(st)}
	if p.shortcut(ui, 'p', {.Ctrl, .Shift}) {open_prompt(st, .Export_Png);fire(st)}
	if p.shortcut(ui, 'd', {.Ctrl}) {open_prompt(st, .Export_Docx);fire(st)}
	if p.shortcut(ui, 'd', {.Ctrl, .Shift}) {open_prompt(st, .Export_Odt);fire(st)}
	if p.shortcut(ui, 't', {.Ctrl}) {open_prompt(st, .Export_Rtf);fire(st)}
	if p.shortcut(ui, 'o', {.Ctrl, .Shift}) {open_prompt(st, .Import_Docx);fire(st)}
	if p.shortcut(ui, 'o', {.Ctrl, .Alt}) {open_prompt(st, .Import_Odt);fire(st)}
	if p.shortcut(ui, 't', {.Ctrl, .Alt}) {open_prompt(st, .Import_Rtf);fire(st)}
}

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

keys_motion :: proc(ui: ^p.Ctx, st: ^State) {
	if n, sh, ct := nav(ui, p.KEY_LEFT); n > 0 {
		for _ in 0 ..< n {move_h(st, -1, sh, ct)}
	}
	if n, sh, ct := nav(ui, p.KEY_RIGHT); n > 0 {
		for _ in 0 ..< n {move_h(st, 1, sh, ct)}
	}
	if n, sh, ct := nav(ui, p.KEY_UP); n > 0 {
		_ = ct
		for _ in 0 ..< n {move_v(st, -1, sh)}
	}
	if n, sh, ct := nav(ui, p.KEY_DOWN); n > 0 {
		_ = ct
		for _ in 0 ..< n {move_v(st, 1, sh)}
	}
	if n, sh, ct := nav(ui, p.KEY_HOME); n > 0 {
		if ct {
			place_caret(st, pos(0, 0), sh)
		} else {
			move_line_edge(st, false, sh)
		}
	}
	if n, sh, ct := nav(ui, p.KEY_END); n > 0 {
		if ct {
			place_caret(st, doc_end(&st.doc), sh)
		} else {
			move_line_edge(st, true, sh)
		}
	}

	// Page Up/Down move by as many visual lines as the window shows.
	step := max(1, int(st.view.h / st.zoom / 24))
	if n, sh, _ := nav(ui, p.KEY_PAGE_UP); n > 0 {
		for _ in 0 ..< n {move_v(st, -step, sh)}
	}
	if n, sh, _ := nav(ui, p.KEY_PAGE_DOWN); n > 0 {
		for _ in 0 ..< n {move_v(st, step, sh)}
	}
	if plain(ui, p.KEY_ESCAPE) {
		if st.mark {
			toggle_mark(st)
		} else if has_selection(st) {
			st.anchor = st.caret
		}
	}
}

// ---------------------------------------------------------------------------
// The find bar
// ---------------------------------------------------------------------------

keys_find :: proc(ui: ^p.Ctx, st: ^State) {
	if plain(ui, p.KEY_ESCAPE) || plain(ui, KEY_F9) {
		st.mode = .Doc
		return
	}
	if plain(ui, p.KEY_TAB) || p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		st.find_field = 1 - st.find_field
		return
	}
	// The two depth switches. Both are also buttons on the find bar.
	if plain(ui, p.KEY_F5) || p.shortcut(ui, 'c', {.Alt}) {
		toggle_find_case(st)
		return
	}
	if plain(ui, KEY_F6) || p.shortcut(ui, 'w', {.Alt}) {
		toggle_find_word(st)
		return
	}
	if plain(ui, KEY_F7) || p.shortcut(ui, 'r', {.Alt}) {
		toggle_find_regex(st)
		return
	}
	if plain(ui, p.KEY_F11) {
		replace_one(st)
		st.find_hits = count_hits(st)
		return
	}
	if plain(ui, KEY_F12) {
		replace_all(st)
		st.find_hits = count_hits(st)
		return
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_KP_ENTER) || plain(ui, KEY_F10) {
		find_next(st)
		return
	}
	if plain(ui, p.KEY_DOWN) {
		find_next(st)
		return
	}

	buf := st.find_field == 0 ? &st.find : &st.repl
	if field_edit(ui, buf, &st.swallow) {
		if st.find_field == 0 {
			rx_recompile(st)
		}
		st.find_hits = count_hits(st)
		if st.find_field == 0 && len(st.find) > 0 {
			// Search from the top of the current paragraph so the view does
			// not jump about while the term is still being typed.
			if lo, hi, ok := find_from(st, pos(st.caret.para, 0)); ok {
				st.anchor = lo
				st.caret = hi
				scroll_to_caret(st)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The path prompt
// ---------------------------------------------------------------------------

open_prompt :: proc(st: ^State, kind: Prompt_Kind) {
	st.prompt = kind
	st.mode = .Prompt
	clear(&st.prompt_buf)
	def := ""
	switch kind {
	case .Open, .Save_As:
		def = default_path(st, ".json")
	case .Export_Md, .Import_Md:
		def = default_path(st, ".md")
	case .Export_Html:
		def = default_path(st, ".html")
	case .Export_Png:
		def = default_path(st, "")
	case .Export_Pdf:
		def = default_path(st, ".pdf")
	case .Export_Docx, .Import_Docx:
		def = default_path(st, ".docx")
	case .Export_Odt, .Import_Odt:
		def = default_path(st, ".odt")
	case .Export_Rtf, .Import_Rtf:
		def = default_path(st, ".rtf")
	case .Insert_Image:
		def = fmt_image_default(st)
	case .Insert_Table:
		def = "3x3"
	case .Share:
		def = "handle edit"
	case .Comment, .Reply, .Name_Version:
	case .None:
	}
	append(&st.prompt_buf, ..transmute([]u8)def)
}

prompt_label :: proc(kind: Prompt_Kind) -> string {
	switch kind {
	case .Open:
		return "Open document"
	case .Save_As:
		return "Save document as"
	case .Export_Md:
		return "Export Markdown to"
	case .Import_Md:
		return "Import Markdown from"
	case .Export_Html:
		return "Export HTML to"
	case .Export_Png:
		return "Export pages as PNG, base name"
	case .Export_Pdf:
		return "Export PDF to"
	case .Export_Docx:
		return "Export Word .docx to"
	case .Export_Odt:
		return "Export OpenDocument .odt to"
	case .Export_Rtf:
		return "Export RTF to"
	case .Import_Docx:
		return "Import Word .docx from"
	case .Import_Odt:
		return "Import OpenDocument .odt from"
	case .Import_Rtf:
		return "Import RTF from"
	case .Insert_Image:
		return "Insert picture from"
	case .Insert_Table:
		return "Insert table, rows x columns"
	case .Comment:
		return "Comment on the selection"
	case .Reply:
		return "Reply"
	case .Share:
		return "Share with: <handle> <view|comment|suggest|edit>, or: link <role>"
	case .Name_Version:
		return "Name this version"
	case .None:
	}
	return ""
}

// fmt_image_default suggests the last picture's directory, or the home
// directory, so the prompt starts somewhere useful.
fmt_image_default :: proc(st: ^State) -> string {
	for &pa in st.doc.paras {
		if pa.kind == .Image && pa.img != nil && pa.img.path != "" {
			return pa.img.path
		}
	}
	return fmt.tprintf("%s/", kit_home())
}

// parse_table_spec reads "RxC", "R x C" or "R" from the prompt.
parse_table_spec :: proc(s: string) -> (rows, cols: int) {
	rows, cols = 0, 0
	at := 0
	for at < len(s) && (s[at] == ' ' || s[at] == '\t') {
		at += 1
	}
	for at < len(s) && s[at] >= '0' && s[at] <= '9' {
		rows = rows * 10 + int(s[at] - '0')
		at += 1
	}
	for at < len(s) && (s[at] == ' ' || s[at] == 'x' || s[at] == 'X' || s[at] == '*' || s[at] == ',') {
		at += 1
	}
	for at < len(s) && s[at] >= '0' && s[at] <= '9' {
		cols = cols * 10 + int(s[at] - '0')
		at += 1
	}
	if rows <= 0 {
		rows = 3
	}
	if cols <= 0 {
		cols = 3
	}
	return clamp(rows, 1, TABLE_MAX_ROWS), clamp(cols, 1, TABLE_MAX_COLS)
}

keys_prompt :: proc(ui: ^p.Ctx, st: ^State) {
	if plain(ui, p.KEY_ESCAPE) {
		st.mode = .Doc
		st.prompt = .None
		return
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_KP_ENTER) {
		commit_prompt(st)
		return
	}
	field_edit(ui, &st.prompt_buf, &st.swallow)
}

// commit_prompt and cancel_prompt are what Return and Escape do, as
// procedures, so the overlay's own buttons run exactly the same path.
commit_prompt :: proc(st: ^State) {
	if st.mode != .Prompt {
		return
	}
	path := strings.clone(string(st.prompt_buf[:]), context.temp_allocator)
	kind := st.prompt
	st.mode = .Doc
	st.prompt = .None
	run_prompt(st, kind, path)
}

cancel_prompt :: proc(st: ^State) {
	st.mode = .Doc
	st.prompt = .None
}

// prompt_verb is the word on the overlay's confirm button.
prompt_verb :: proc(kind: Prompt_Kind) -> string {
	switch kind {
	case .Open, .Import_Md, .Import_Docx, .Import_Odt, .Import_Rtf:
		return "Open"
	case .Save_As:
		return "Save"
	case .Export_Md, .Export_Html, .Export_Png, .Export_Pdf, .Export_Docx, .Export_Odt, .Export_Rtf:
		return "Export"
	case .Insert_Image, .Insert_Table:
		return "Insert"
	case .Comment, .Reply:
		return "Comment"
	case .Share:
		return "Share"
	case .Name_Version:
		return "Name"
	case .None:
	}
	return "OK"
}

run_prompt :: proc(st: ^State, kind: Prompt_Kind, path: string) {
	full := expand_home(path, context.temp_allocator)
	switch kind {
	case .Open:
		do_open(st, full)
	case .Save_As:
		do_save(st, full)
	case .Export_Md:
		note(st, export_markdown(&st.doc, full) ? "Exported Markdown" : "Export failed")
	case .Import_Md:
		nd, ok := import_markdown(full)
		if ok {
			replace_document(st, nd)
			st.modified = true
			note(st, "Imported Markdown")
		} else {
			note(st, "Import failed")
		}
	case .Export_Html:
		note(st, export_html(&st.doc, full, doc_title(st)) ? "Exported HTML" : "Export failed")
	case .Export_Png:
		n := export_all_pages_png(st, full)
		note(st, n > 0 ? tfmt("Wrote %d page image%s", n, n == 1 ? "" : "s") : "PNG export failed")
	case .Export_Pdf:
		// The PDF is written from the live layout, so it needs one that is
		// current — the same object the window is drawing from.
		if st.dirty {
			relayout(st)
			st.dirty = false
		}
		ok := export_pdf(st, full, doc_display_title(&st.doc, doc_title(st)))
		note(st, ok ? tfmt("Exported %d page PDF", st.lay.pages) : "PDF export failed")
	case .Export_Docx:
		note(
			st,
			export_docx(&st.doc, full, doc_display_title(&st.doc, doc_title(st))) \
			? "Exported .docx" \
			: "Export failed",
		)
	case .Export_Odt:
		note(
			st,
			export_odt(&st.doc, full, doc_display_title(&st.doc, doc_title(st))) \
			? "Exported .odt" \
			: "Export failed",
		)
	case .Export_Rtf:
		note(
			st,
			export_rtf(&st.doc, full, doc_display_title(&st.doc, doc_title(st))) \
			? "Exported .rtf" \
			: "Export failed",
		)
	case .Import_Docx, .Import_Odt, .Import_Rtf:
		nd: Doc
		ok: bool
		switch kind {
		case .Import_Docx:
			nd, ok = import_docx(full)
		case .Import_Odt:
			nd, ok = import_odt(full)
		case .Import_Rtf:
			nd, ok = import_rtf(full)
		case .None, .Open, .Save_As, .Export_Md, .Import_Md, .Export_Html, .Export_Png,
		     .Export_Pdf, .Export_Docx, .Export_Odt, .Export_Rtf, .Insert_Image, .Insert_Table,
		     .Comment, .Reply, .Share, .Name_Version:
		}
		if ok {
			replace_document(st, nd)
			st.modified = true
			note(st, tfmt("Imported %d paragraphs", len(st.doc.paras)))
		} else {
			note(st, "Import failed")
		}
	case .Insert_Image:
		do_insert_image(st, full)
	case .Insert_Table:
		r, c := parse_table_spec(path)
		insert_table(st, r, c)
	case .Comment:
		collab_comment(st, path)
	case .Reply:
		cb := &st.collab
		if n := len(cb.comments); n > 0 {
			collab_reply(st, cb.comments[clamp(collab_x.sel, 0, n - 1)].id, path)
		}
	case .Share:
		collab_share_cmd(st, path)
	case .Name_Version:
		collab_name_version(st, path)
	case .None:
	}
}
