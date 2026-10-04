package kit

// The file picker's one drawing entry point.
//
//	if kit.pick_active(&app.pick) {
//		if res, done := kit.pick_draw(ui, &app.pick); done {
//			defer kit.pick_result_free(res)
//			if res.ok { open(res.path) }
//		}
//		return  // the dialog owns the keyboard while it is up
//	}
//
// It is a modal overlay rather than a second window because there is no
// xdg_popup here: everything is drawn inside the application's own surface,
// absolutely positioned over it.
//
// The whole dialog is usable from the keyboard. That is not a nicety; a file
// dialog that forces the mouse is the one part of an application a person
// cannot work around.

import "core:fmt"
import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

PICK_W_MAX :: f32(940)
PICK_H_MAX :: f32(620)
PICK_SIDE_W :: f32(186)
PICK_HEAD_H :: f32(46)
PICK_BAR_H :: f32(40)
PICK_COLS_H :: f32(26)
PICK_FOOT_H :: f32(56)
PICK_COL_SIZE :: 84
PICK_COL_DATE :: 132

// ---------------------------------------------------------------------------
// pick_draw
// ---------------------------------------------------------------------------

// pick_draw handles this frame's input and draws the dialog. It returns a
// result only on the frame the dialog closes, and `done` is true for a cancel
// as well as a choice — check `result.ok` to tell them apart.
pick_draw :: proc(ui: ^p.Ctx, st: ^Pick) -> (result: Pick_Result, done: bool) {
	if !st.open {
		if st.done {
			st.done = false
			r := st.result
			st.result = {}
			return r, true
		}
		return {}, false
	}

	st.frames += 1
	// The first frames have no geometry yet, so the virtual list cannot know
	// how many rows fit. Keep drawing until it does.
	if st.frames < 5 {
		p.redraw(ui)
	}

	pick_keys(ui, st)

	if !st.open {
		// Something in the key handler finished the dialog.
		st.done = false
		r := st.result
		st.result = {}
		return r, true
	}

	pick_panel(ui, st)

	// And again. The keyboard is handled before the panel is built, but a
	// *click* — Cancel, the scrim, the close button, a second click on a row —
	// is resolved while the panel is being built, so a dialog can also finish
	// here. Without this second check the host sees `pick_active` go false on
	// the next frame and never asks for the result, which is both a silently
	// ignored choice and a leak.
	if !st.open {
		st.done = false
		r := st.result
		st.result = {}
		p.redraw(ui)
		return r, true
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

@(private = "file")
pick_plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

// pick_times counts a key's presses this frame, ignoring modifiers. Two
// arrow presses can land in one frame when a key repeats or a script drives
// the window, and a selection that moves by one falls behind.
@(private = "file")
pick_times :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			n += 1
		}
	}
	return n
}

@(private = "file")
pick_keys :: proc(ui: ^p.Ctx, st: ^Pick) {
	// Text before keys, always: a name and the Return that submits it can
	// arrive in the same frame, and handling Return first saves a truncated
	// file name.
	typed := st.swallow ? "" : p.typed_text(ui)
	st.swallow = false
	now := f64(p.elapsed(ui))

	// --- the overwrite confirmation owns everything while it is up --------
	if st.cf_open {
		if pick_plain(ui, p.KEY_ESCAPE) {
			pick_cancel_overwrite(st)
			return
		}
		if pick_times(ui, p.KEY_LEFT) > 0 || p.shortcut(ui, p.KEY_TAB, {.Shift}) {
			st.cf_sel = 0
		}
		if pick_times(ui, p.KEY_RIGHT) > 0 || pick_plain(ui, p.KEY_TAB) {
			st.cf_sel = 1
		}
		if pick_plain(ui, p.KEY_RETURN) || pick_plain(ui, p.KEY_KP_ENTER) {
			// Whatever is focused — and Cancel is what starts focused.
			if st.cf_sel == 1 {
				pick_confirm_overwrite(st)
			} else {
				pick_cancel_overwrite(st)
			}
		}
		return
	}

	// --- the New Folder prompt -------------------------------------------
	if st.nf_open {
		if pick_plain(ui, p.KEY_ESCAPE) {
			pick_new_folder_cancel(st)
			return
		}
		changed, submitted := pick_edit(ui, &st.nf_buf, &st.nf_cur, nil, typed)
		if changed && st.nf_err != "" {
			delete(st.nf_err)
			st.nf_err = ""
		}
		if submitted {
			pick_new_folder_commit(st)
		}
		return
	}

	// --- the filter dropdown ---------------------------------------------
	if st.filter_open {
		if pick_plain(ui, p.KEY_ESCAPE) {
			st.filter_open = false
			return
		}
		for _ in 0 ..< pick_times(ui, p.KEY_DOWN) {
			st.filter_sel = min(st.filter_sel + 1, len(st.filters) - 1)
		}
		for _ in 0 ..< pick_times(ui, p.KEY_UP) {
			st.filter_sel = max(st.filter_sel - 1, 0)
		}
		if pick_plain(ui, p.KEY_RETURN) || pick_plain(ui, p.KEY_SPACE) {
			pick_set_filter(st, st.filter_sel)
			st.filter_open = false
		}
		return
	}

	// --- the typed path bar ----------------------------------------------
	if st.loc_open {
		if pick_plain(ui, p.KEY_ESCAPE) {
			pick_location_cancel(st)
			return
		}
		if pick_plain(ui, p.KEY_TAB) {
			pick_location_complete(st)
			return
		}
		_, submitted := pick_edit(ui, &st.loc_buf, &st.loc_cur, nil, typed)
		if submitted {
			pick_location_commit(st)
		}
		return
	}

	// --- global ------------------------------------------------------------
	if pick_plain(ui, p.KEY_ESCAPE) {
		pick_cancel(st)
		return
	}
	if p.shortcut(ui, 'h', {.Ctrl}) {
		pick_toggle_hidden(st)
	}
	if p.shortcut(ui, 'l', {.Ctrl}) {
		pick_location_begin(st)
		return
	}
	if p.shortcut(ui, 'n', {.Ctrl}) {
		pick_new_folder_begin(st)
		return
	}
	if p.shortcut(ui, 'r', {.Ctrl}) || pick_plain(ui, p.KEY_F5) {
		pick_reload(st)
		pick_note(st, "Reloaded")
	}
	if p.shortcut(ui, '1', {.Ctrl}) {
		pick_set_sort(st, .Name)
	}
	if p.shortcut(ui, '2', {.Ctrl}) {
		pick_set_sort(st, .Size)
	}
	if p.shortcut(ui, '3', {.Ctrl}) {
		pick_set_sort(st, .Date)
	}
	if p.shortcut(ui, p.KEY_UP, {.Alt}) || p.shortcut(ui, p.KEY_BACKSPACE, {.Alt}) {
		pick_up(st)
		return
	}
	if pick_plain(ui, p.KEY_TAB) {
		pick_cycle_pane(st, 1)
		return
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		pick_cycle_pane(st, -1)
		return
	}
	// A slash or a tilde is not a legal file name character, so wherever it
	// is typed it can only mean "let me type a path".
	if strings.contains(typed, "/") || strings.contains(typed, "~") {
		if st.pane != .Name || len(st.name_buf) == 0 {
			pick_location_begin(st)
			if strings.has_prefix(typed, "~") {
				clear(&st.loc_buf)
				append(&st.loc_buf, '~')
				st.loc_cur = 1
			}
			return
		}
	}

	switch st.pane {
	case .Places:
		if d := pick_times(ui, p.KEY_DOWN); d > 0 && len(st.places) > 0 {
			st.place_sel = min(st.place_sel + d, len(st.places) - 1)
			pick_go(st, st.places[st.place_sel].path)
		}
		if d := pick_times(ui, p.KEY_UP); d > 0 && len(st.places) > 0 {
			st.place_sel = max(st.place_sel - d, 0)
			pick_go(st, st.places[st.place_sel].path)
		}
		if pick_plain(ui, p.KEY_RETURN) || pick_plain(ui, p.KEY_RIGHT) {
			st.pane = .List
		}

	case .List:
		pick_list_keys(ui, st, typed, now)

	case .Name:
		changed, submitted := pick_edit(ui, &st.name_buf, &st.name_cur, &st.name_anchor, typed)
		if changed && st.err != "" {
			pick_set_err(st, "")
		}
		if submitted {
			pick_confirm(st)
		}
		// Arrow keys past the field's own handling move the list, so you can
		// still browse while the name field has the caret.
		if p.shortcut(ui, p.KEY_DOWN, {.Ctrl}) {
			pick_move(st, 1)
		}
		if p.shortcut(ui, p.KEY_UP, {.Ctrl}) {
			pick_move(st, -1)
		}

	case .Filter:
		if pick_plain(ui, p.KEY_RETURN) || pick_plain(ui, p.KEY_SPACE) {
			st.filter_open = true
			st.filter_sel = st.filter
			st.swallow = true
			return
		}
		if d := pick_times(ui, p.KEY_DOWN); d > 0 {
			pick_set_filter(st, st.filter + d)
		}
		if d := pick_times(ui, p.KEY_UP); d > 0 {
			pick_set_filter(st, st.filter - d)
		}
	}
}

@(private = "file")
pick_list_keys :: proc(ui: ^p.Ctx, st: ^Pick, typed: string, now: f64) {
	view_h := st.list_id == 0 ? 0 : p.rect_of(ui, st.list_id).h
	page := pick_page(st, view_h)

	if d := pick_times(ui, p.KEY_DOWN); d > 0 {
		pick_move(st, d)
	}
	if d := pick_times(ui, p.KEY_UP); d > 0 {
		pick_move(st, -d)
	}
	if pick_plain(ui, p.KEY_PAGE_DOWN) {
		pick_move(st, page)
	}
	if pick_plain(ui, p.KEY_PAGE_UP) {
		pick_move(st, -page)
	}
	if pick_plain(ui, p.KEY_HOME) {
		st.sel = 0
		st.want_reveal = true
	}
	if pick_plain(ui, p.KEY_END) {
		st.sel = max(0, len(st.vis) - 1)
		st.want_reveal = true
	}
	if pick_plain(ui, p.KEY_BACKSPACE) {
		pick_up(st)
		return
	}
	if pick_plain(ui, p.KEY_LEFT) {
		pick_up(st)
		return
	}
	if pick_plain(ui, p.KEY_RIGHT) {
		if e, ok := pick_selected(st); ok && e.is_dir {
			pick_go(st, e.path)
		}
		return
	}
	if pick_plain(ui, p.KEY_RETURN) || pick_plain(ui, p.KEY_KP_ENTER) {
		pick_confirm(st)
		return
	}
	if pick_plain(ui, p.KEY_SPACE) && st.mode == .Open_Files {
		pick_mark_current(st)
		return
	}
	if p.shortcut(ui, 'a', {.Ctrl}) && st.mode == .Open_Files {
		pick_mark_all(st, st.marks < len(st.vis))
		return
	}

	// Type-ahead. Any printable character searches, with one deliberate
	// exception: a bare `j` or `k` with no search already in progress moves
	// the cursor, because those two keys are muscle memory for everyone who
	// has ever used a list. Once a search has started they are letters again,
	// so "kernel.log" is still reachable by typing it.
	if typed == "" {
		return
	}
	searching := len(st.ahead) > 0 && now - st.ahead_at <= PICK_AHEAD_TIMEOUT
	if !searching && (typed == "j" || typed == "k") {
		pick_move(st, typed == "j" ? 1 : -1)
		return
	}
	pick_typeahead_push(st, typed, now)
}

// ---------------------------------------------------------------------------
// A small text editor, shared by the three fields
// ---------------------------------------------------------------------------

@(private = "file")
pick_rune_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {
		i -= 1
	}
	return max(1, at - i)
}

@(private = "file")
pick_rune_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {
		i += 1
	}
	return min(i, len(b)) - at
}

// pick_edit is the field behaviour the Save name needs and the other two
// reuse: insert, delete, move, and a selection that typing replaces. `anchor`
// is optional — pass nil for a field with no selection.
//
// palmy's own `text_field` owns focus and has no selection, and the whole
// point of the Save field is that the extension is *not* selected while the
// basename is. So the editing lives here.
@(private = "file")
pick_edit :: proc(
	ui: ^p.Ctx,
	buf: ^[dynamic]u8,
	cur: ^int,
	anchor: ^int,
	typed: string,
) -> (
	changed: bool,
	submitted: bool,
) {
	cur^ = clamp(cur^, 0, len(buf))
	if anchor != nil {
		anchor^ = clamp(anchor^, 0, len(buf))
	}

	lo := cur^
	hi := cur^
	if anchor != nil {
		lo = min(cur^, anchor^)
		hi = max(cur^, anchor^)
	}
	drop_sel :: proc(buf: ^[dynamic]u8, cur: ^int, anchor: ^int, lo, hi: int) {
		if hi > lo {
			remove_range(buf, lo, hi)
		}
		cur^ = lo
		if anchor != nil {
			anchor^ = lo
		}
	}

	if len(typed) > 0 {
		// A newline arrives as text on some keymaps; it is a submit, not a
		// character in a file name.
		clean := strings.builder_make(context.temp_allocator)
		for b in transmute([]u8)typed {
			switch b {
			case '\n', '\r':
				submitted = true
			case '\t':
			// Tab is navigation, never content.
			case:
				if b >= 0x20 || b >= 0x80 {
					strings.write_byte(&clean, b)
				}
			}
		}
		ins := strings.to_string(clean)
		if len(ins) > 0 {
			drop_sel(buf, cur, anchor, lo, hi)
			inject_at_elems(buf, cur^, ..transmute([]u8)ins)
			cur^ += len(ins)
			if anchor != nil {
				anchor^ = cur^
			}
			changed = true
			lo, hi = cur^, cur^
		}
	}

	for k in ui.input.keys {
		shift := .Shift in k.mods
		ctrl := .Ctrl in k.mods
		switch k.sym {
		case p.KEY_BACKSPACE:
			if hi > lo {
				drop_sel(buf, cur, anchor, lo, hi)
				changed = true
			} else if cur^ > 0 {
				n := pick_rune_back(buf[:], cur^)
				remove_range(buf, cur^ - n, cur^)
				cur^ -= n
				if anchor != nil {
					anchor^ = cur^
				}
				changed = true
			}
			lo, hi = cur^, cur^
		case p.KEY_DELETE:
			if hi > lo {
				drop_sel(buf, cur, anchor, lo, hi)
				changed = true
			} else if cur^ < len(buf) {
				n := pick_rune_fwd(buf[:], cur^)
				remove_range(buf, cur^, cur^ + n)
				changed = true
			}
			lo, hi = cur^, cur^
		case p.KEY_LEFT:
			if cur^ > 0 {
				cur^ -= pick_rune_back(buf[:], cur^)
			}
			if anchor != nil && !shift {
				anchor^ = cur^
			}
			lo, hi = anchor != nil ? min(cur^, anchor^) : cur^, anchor != nil ? max(cur^, anchor^) : cur^
		case p.KEY_RIGHT:
			if cur^ < len(buf) {
				cur^ += pick_rune_fwd(buf[:], cur^)
			}
			if anchor != nil && !shift {
				anchor^ = cur^
			}
			lo, hi = anchor != nil ? min(cur^, anchor^) : cur^, anchor != nil ? max(cur^, anchor^) : cur^
		case p.KEY_HOME:
			cur^ = 0
			if anchor != nil && !shift {
				anchor^ = 0
			}
			lo, hi = anchor != nil ? min(cur^, anchor^) : cur^, anchor != nil ? max(cur^, anchor^) : cur^
		case p.KEY_END:
			cur^ = len(buf)
			if anchor != nil && !shift {
				anchor^ = cur^
			}
			lo, hi = anchor != nil ? min(cur^, anchor^) : cur^, anchor != nil ? max(cur^, anchor^) : cur^
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			submitted = true
		case 'a':
			if ctrl && anchor != nil {
				anchor^ = 0
				cur^ = len(buf)
				lo, hi = 0, len(buf)
			} else if ctrl {
				cur^ = 0
			}
		case 'e':
			if ctrl {
				cur^ = len(buf)
				if anchor != nil {
					anchor^ = cur^
				}
			}
		case 'u':
			if ctrl {
				clear(buf)
				cur^ = 0
				if anchor != nil {
					anchor^ = 0
				}
				changed = true
				lo, hi = 0, 0
			}
		}
	}
	return changed, submitted
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

@(private = "file")
pick_panel :: proc(ui: ^p.Ctx, st: ^Pick) {
	win := p.size(ui)
	w := min(PICK_W_MAX, max(360, win.x - 48))
	h := min(PICK_H_MAX, max(300, win.y - 48))

	// A scrim, both to dim the host application and to catch the clicks that
	// would otherwise reach it through a modal dialog.
	scrim := p.div(ui, "absolute inset-0 z-40 bg-black/45")
	if p.clickable(ui, scrim) {
		pick_cancel(st)
	}
	p.end(ui)

	wrap := p.col(ui, "absolute z-50 overflow-hidden rounded-xl bg-popover text-popover-foreground ring-1 ring-foreground/15 shadow-lg")
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(math.round((win.x - w) / 2))
	s.inset[p.TOP] = p.px(math.round((win.y - h) / 2))
	s.w = p.px(w)
	s.h = p.px(h)
	defer p.end(ui)

	pick_header(ui, st)
	pick_bar(ui, st)

	p.row(ui, "flex-1 min-h-0 w-full")
	pick_sidebar(ui, st)
	p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	pick_columns(ui, st)
	pick_list(ui, st)
	p.end(ui)
	p.end(ui)

	pick_footer(ui, st)

	if st.filter_open {
		pick_filter_popup(ui, st, w, h)
	}
	if st.nf_open {
		pick_new_folder_dialog(ui, st, w, h)
	}
	if st.cf_open {
		pick_overwrite_dialog(ui, st, w, h)
	}
}

@(private = "file")
pick_header :: proc(ui: ^p.Ctx, st: ^Pick) {
	p.row(
		ui,
		fmt.tprintf(
			"h-[%d] shrink-0 w-full items-center gap-2 px-3.5 border-b border-border bg-sidebar",
			int(PICK_HEAD_H),
		),
	)
	defer p.end(ui)

	ic := st.mode == .Save_File ? ICON_DOWNLOAD : (st.mode == .Open_Folder ? ICON_FOLDER_OPEN : ICON_FILE)
	p.icon(ui, ic, "size-4 shrink-0 text-primary")
	p.text(ui, st.title, "text-[14] font-semibold text-foreground whitespace-nowrap")
	p.style(ui).shrink = 0

	p.spacer(ui, "flex-1")

	if st.marks > 0 {
		p.row(ui, "shrink-0 items-center gap-1 px-2 h-5 rounded-full bg-primary/15")
		p.text(ui, fmt.tprintf("%d selected", st.marks), "text-[11] font-medium text-primary whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}

	p.key(ui, "pick.close")
	x := p.div(
		ui,
		"flex-row size-7 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground cursor-pointer transition",
	)
	if p.clickable(ui, x) {
		pick_cancel(st)
	}
	p.icon(ui, ICON_X, "size-4")
	p.end(ui)
}

// pick_bar is the breadcrumb row, or the typed path bar when it is open.
@(private = "file")
pick_bar :: proc(ui: ^p.Ctx, st: ^Pick) {
	p.row(
		ui,
		fmt.tprintf(
			"h-[%d] shrink-0 w-full items-center gap-1.5 px-3 border-b border-border overflow-hidden",
			int(PICK_BAR_H),
		),
	)
	defer p.end(ui)

	if st.loc_open {
		p.icon(ui, ICON_TERMINAL, "size-3.5 shrink-0 text-muted-foreground")
		pick_field(ui, &st.loc_buf, st.loc_cur, -1, "Type a path", true, "flex-1 min-w-0")
		if st.loc_note != "" {
			p.text(ui, st.loc_note, "text-[11] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		sc.kbd(ui, "Tab")
		p.text(ui, "complete", "text-[11] text-muted-foreground/70 whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	}

	// Up one level.
	p.key(ui, "pick.up")
	up := p.div(ui, "flex-row size-6 shrink-0 items-center justify-center rounded-md transition cursor-pointer")
	if st.dir != "/" {
		p.apply(ui, "hover:bg-accent text-foreground", up)
		if p.clickable(ui, up) {
			pick_up(st)
		}
	} else {
		p.apply(ui, "text-muted-foreground/40", up)
	}
	p.icon(ui, ICON_ARROW_UP, "size-3.5")
	p.end(ui)

	crumbs := pick_crumbs(st.dir, "", context.temp_allocator)

	// Keep the first crumb, elide the middle, keep the last three: a deep
	// path must not push the row's own controls off the end.
	MAX :: 3
	elide := len(crumbs) > MAX + 2

	p.row(ui, "flex-1 min-w-0 items-center gap-0.5 overflow-hidden")
	for c, i in crumbs {
		if elide && i > 0 && i < len(crumbs) - MAX {
			if i == 1 {
				p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground/60")
				p.div(ui, "flex-row h-6 px-1 items-center shrink-0")
				p.text(ui, "...", "text-[12.5] text-muted-foreground")
				p.end(ui)
			}
			continue
		}
		if i > 0 {
			p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground/60")
		}
		last := i == len(crumbs) - 1
		p.key(ui, c.path)
		idx := p.row(
			ui,
			"h-6 items-center gap-1.5 px-1.5 rounded-md shrink-0 cursor-pointer transition hover:bg-accent",
		)
		if p.clickable(ui, idx) {
			pick_go(st, c.path)
			st.pane = .List
		}
		if c.home {
			p.icon(ui, c.path == "/" ? ICON_HARD_DRIVE : ICON_HOUSE, "size-3.5 shrink-0 text-primary")
		}
		p.text(
			ui,
			c.label,
			last \
			? "max-w-[220] truncate text-[12.5] font-semibold text-foreground" \
			: "max-w-[160] truncate text-[12.5] text-muted-foreground",
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)

	// New Folder is only offered where something is being written. An Open
	// dialog has no business creating directories.
	if st.mode == .Save_File || st.mode == .Open_Folder {
		p.key(ui, "pick.newfolder")
		nf := p.row(
			ui,
			"h-6 shrink-0 items-center gap-1 px-2 rounded-md border border-border bg-background hover:bg-accent cursor-pointer transition",
		)
		if p.clickable(ui, nf) {
			pick_new_folder_begin(st)
		}
		p.icon(ui, ICON_FOLDER, "size-3.5 shrink-0 text-sky-500")
		p.text(ui, "New Folder", "text-[11.5] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}

	// Show hidden files.
	p.key(ui, "pick.hidden")
	hid := p.div(ui, "flex-row size-6 shrink-0 items-center justify-center rounded-md cursor-pointer transition")
	p.apply(ui, st.show_hidden ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-accent", hid)
	if p.clickable(ui, hid) {
		pick_toggle_hidden(st)
	}
	p.icon(ui, ICON_EYE, "size-3.5")
	p.end(ui)
}

@(private = "file")
pick_sidebar :: proc(ui: ^p.Ctx, st: ^Pick) {
	p.col(
		ui,
		fmt.tprintf(
			"w-[%d] shrink-0 h-full bg-sidebar border-r border-border px-2 py-2 gap-px overflow-hidden",
			int(PICK_SIDE_W),
		),
	)
	defer p.end(ui)

	p.div(ui, "px-2 pb-1.5 pt-0.5")
	p.text(ui, "Places", "text-[10.5] font-semibold text-muted-foreground/80 tracking-wide")
	p.end(ui)

	for pl, i in st.places {
		exact := pl.path == st.dir
		cursor := st.pane == .Places && i == st.place_sel

		p.key(ui, pl.path)
		idx := p.row(ui, "h-[28] shrink-0 items-center gap-2 px-2 rounded-md cursor-pointer")
		switch {
		case exact:
			p.apply(ui, "bg-primary text-primary-foreground", idx)
		case i == st.place_sel:
			p.apply(ui, "bg-accent", idx)
		case:
			p.apply(ui, "hover:bg-accent/70", idx)
		}
		if cursor && !exact {
			p.apply(ui, "ring-2 ring-primary/40", idx)
		}
		if p.clickable(ui, idx) {
			st.place_sel = i
			pick_go(st, pl.path)
			st.pane = .List
		}
		p.icon(
			ui,
			pick_place_glyph(pl.icon),
			exact ? "size-3.5 shrink-0" : fmt.tprintf("size-3.5 shrink-0 %s", pl.tint),
		)
		p.text(ui, pl.label, "flex-1 min-w-0 truncate text-[12.5] font-medium")
		p.end(ui)
	}

	p.spacer(ui, "flex-1")

	// The dialog is keyboard-first, so it says so.
	p.col(ui, "px-2 pb-0.5 gap-1 shrink-0")
	pick_hint(ui, "Tab", "pane")
	pick_hint(ui, "Ctrl L", "type a path")
	pick_hint(ui, "Ctrl H", "hidden files")
	if st.mode == .Save_File || st.mode == .Open_Folder {
		pick_hint(ui, "Ctrl N", "new folder")
	}
	if st.mode == .Open_Files {
		pick_hint(ui, "Space", "select")
	}
	p.end(ui)
}

@(private = "file")
pick_hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1.5 shrink-0")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[10.5] text-muted-foreground/70 whitespace-nowrap truncate")
	p.end(ui)
}

@(private = "file")
pick_columns :: proc(ui: ^p.Ctx, st: ^Pick) {
	p.row(
		ui,
		fmt.tprintf(
			"h-[%d] shrink-0 w-full items-center gap-2 px-3 border-b border-border bg-background",
			int(PICK_COLS_H),
		),
	)
	defer p.end(ui)

	head :: proc(ui: ^p.Ctx, st: ^Pick, label: string, key: Pick_Sort, w: int, right: bool) {
		active := st.sort == key
		p.key(ui, label)
		idx := p.row(
			ui,
			w == 0 \
			? "flex-1 min-w-0 items-center gap-1 cursor-pointer" \
			: fmt.tprintf("w-[%d] shrink-0 items-center gap-1 cursor-pointer %s", w, right ? "justify-end" : ""),
		)
		if p.clickable(ui, idx) {
			pick_set_sort(st, key)
		}
		hov := p.is_hovered(ui, idx)
		p.text(
			ui,
			label,
			active || hov \
			? "text-[11] font-semibold text-foreground whitespace-nowrap" \
			: "text-[11] font-medium text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		if active {
			p.icon(ui, st.desc ? ICON_CHEVRON_DOWN : ICON_CHEVRON_UP, "size-3 shrink-0 text-muted-foreground")
		}
		p.end(ui)
	}

	head(ui, st, "Name", .Name, 0, false)
	head(ui, st, "Size", .Size, PICK_COL_SIZE, true)
	head(ui, st, "Modified", .Date, PICK_COL_DATE, false)
}

// pick_list is the directory, drawn through palmy's own scroll container but
// only for the rows that are actually on screen. A folder with five thousand
// entries builds thirty nodes a frame; the two spacers give the container the
// full content height, so the wheel, the scrollbar and `scroll_to` all behave
// as if every row were there.
@(private = "file")
pick_list :: proc(ui: ^p.Ctx, st: ^Pick) {
	if st.err != "" {
		pick_empty(ui, ICON_LOCK, "Not available", st.err)
		pick_status(ui, st)
		return
	}
	if len(st.vis) == 0 {
		f := pick_active_filter(st)
		title := "Empty folder"
		body := "There is nothing in here."
		if len(st.entries) > 0 {
			title = "Nothing to show"
			body = st.mode == .Open_Folder \
				? "This folder holds no sub-folders." \
				: fmt.tprintf("Nothing here matches \"%s\".", f.label)
		}
		pick_empty(ui, ICON_FOLDER_OPEN, title, body)
		pick_status(ui, st)
		return
	}

	// `p.div` rather than `p.col`: palmy computes a node's `scrollable` flag
	// inside push_node from the class string it is handed, and `p.col`/`p.row`
	// hand it only their own "flex-col"/"flex-row" and then apply the caller's
	// classes straight onto the style. So `p.col(ui, "overflow-scroll")`
	// produces a clipped box that the wheel never reaches, while
	// `p.div(ui, "flex-col overflow-scroll")` is a real scroll container.
	list := p.div(ui, "flex-col flex-1 min-h-0 w-full overflow-scroll")
	st.list_id = p.node_id(ui, list)
	view_h := p.rect_of(ui, st.list_id).h
	off := p.scroll_of(ui, st.list_id).y

	if st.want_top {
		p.scroll_to(ui, st.list_id, {0, 0})
		off = 0
		st.want_top = false
	}
	if st.want_reveal {
		if view_h > 0 {
			y := f32(st.sel) * PICK_ROW_H
			target := off
			if y < off {
				target = y
			} else if y + PICK_ROW_H > off + view_h {
				target = y + PICK_ROW_H - view_h
			}
			p.scroll_to(ui, st.list_id, {0, target})
			got := p.scroll_of(ui, st.list_id).y
			off = got
			// The scroll extent is only known after a layout, so a jump to
			// the end of a long list may need one more frame to land.
			if abs(got - target) < 0.5 {
				st.want_reveal = false
			} else {
				p.redraw(ui)
			}
		} else {
			p.redraw(ui)
		}
	}

	total := len(st.vis)
	first := 0
	count := 48
	if view_h > 0 {
		first = clamp(int(off / PICK_ROW_H) - 1, 0, max(0, total - 1))
		count = int(view_h / PICK_ROW_H) + 3
	}
	last := min(first + count, total)

	if first > 0 {
		p.div(ui, "w-full shrink-0")
		p.style(ui).h = p.px(f32(first) * PICK_ROW_H)
		p.end(ui)
	}
	for row in first ..< last {
		pick_row(ui, st, row)
	}
	if last < total {
		p.div(ui, "w-full shrink-0")
		p.style(ui).h = p.px(f32(total - last) * PICK_ROW_H)
		p.end(ui)
	}
	p.end(ui)

	pick_scrollbar(ui, st, view_h, off)
	pick_status(ui, st)
}

// pick_scrollbar is drawn rather than scrolled. palmy's scroll container keeps
// the offset but paints no bar, and a list of five thousand files with no
// indication of where you are in it is a list you get lost in. It is placed
// absolutely in the column that holds the header, the list and the status row,
// so the header's height is the offset it starts at.
@(private = "file")
pick_scrollbar :: proc(ui: ^p.Ctx, st: ^Pick, view_h, off: f32) {
	if st.list_id == 0 || view_h <= 0 {
		return
	}
	extent := p.scroll_extent(ui, st.list_id).y
	if extent <= 1 {
		return
	}
	content := view_h + extent
	h := max(28, view_h * (view_h / content))
	travel := view_h - h
	t := clamp(off / extent, 0, 1)

	idx := p.div(ui, "absolute right-[3] w-[5] rounded-full bg-foreground/20")
	s := p.style(ui, idx)
	s.no_hit = true
	s.inset[p.TOP] = p.px(PICK_COLS_H + travel * t + 2)
	s.h = p.px(max(8, h - 4))
	p.end(ui)
}

@(private = "file")
pick_row :: proc(ui: ^p.Ctx, st: ^Pick, row: int) {
	e := st.entries[st.vis[row]]
	on := row == st.sel
	focused := st.pane == .List
	hl := on && focused

	// No `transition` on a row, deliberately. A selected row is white on the
	// primary colour; crossfading it back over 120ms leaves the name white on
	// white for four frames, which in a list you are arrowing through reads as
	// rows blinking out of existence. Selection in a file list is instant
	// everywhere else too.
	p.key(ui, fmt.tprintf("pick.row:%s", e.name))
	idx := p.row(
		ui,
		fmt.tprintf("h-[%d] shrink-0 w-full items-center gap-2 px-3 cursor-pointer", int(PICK_ROW_H)),
	)
	switch {
	case hl:
		p.apply(ui, "bg-primary text-primary-foreground", idx)
	case on:
		p.apply(ui, "bg-foreground/10", idx)
	case e.marked:
		p.apply(ui, "bg-primary/10 hover:bg-primary/15", idx)
	case:
		p.apply(ui, "hover:bg-accent", idx)
	}
	if p.clickable(ui, idx) {
		if st.sel == row && focused {
			pick_confirm(st)
		} else {
			st.sel = row
			st.pane = .List
		}
	}

	if st.mode == .Open_Files {
		box := p.div(ui, "flex-row size-[13] shrink-0 items-center justify-center rounded-[3] border")
		switch {
		case e.is_dir:
			p.apply(ui, "border-transparent", box)
		case e.marked:
			p.apply(ui, hl ? "bg-primary-foreground border-primary-foreground" : "bg-primary border-primary", box)
		case:
			p.apply(ui, hl ? "border-primary-foreground/60" : "border-border", box)
		}
		if !e.is_dir && e.marked {
			p.icon(ui, sc.ICON_CHECK, hl ? "size-[9] text-primary" : "size-[9] text-primary-foreground")
		}
		p.end(ui)
	}

	p.icon(ui, e.icon, hl ? "size-4 shrink-0" : fmt.tprintf("size-4 shrink-0 %s", e.tint))

	p.row(ui, "flex-1 min-w-0 items-center gap-1")
	p.text(ui, e.name, "flex-1 min-w-0 truncate text-[12.5]")
	if e.is_link {
		p.icon(ui, ICON_LINK, hl ? "size-3 shrink-0 opacity-70" : "size-3 shrink-0 text-muted-foreground")
	}
	p.end(ui)

	meta := hl ? "text-[11.5] opacity-80 whitespace-nowrap" : "text-[11.5] text-muted-foreground whitespace-nowrap"
	p.row(ui, fmt.tprintf("w-[%d] shrink-0 items-center justify-end overflow-hidden", PICK_COL_SIZE))
	p.text(ui, e.size_text, meta)
	p.end(ui)
	p.row(ui, fmt.tprintf("w-[%d] shrink-0 items-center overflow-hidden", PICK_COL_DATE))
	p.text(ui, e.date_text, meta)
	p.end(ui)

	p.end(ui)
}

@(private = "file")
pick_status :: proc(ui: ^p.Ctx, st: ^Pick) {
	p.row(ui, "h-[22] shrink-0 w-full items-center gap-2 px-3 border-t border-border bg-sidebar overflow-hidden")
	defer p.end(ui)

	shown := len(st.vis)
	total := 0
	for e in st.entries {
		if !e.hidden || st.show_hidden {
			total += 1
		}
	}
	noun := st.mode == .Open_Folder ? "folders" : "items"
	label := shown == total \
		? fmt.tprintf("%d %s", total, noun) \
		: fmt.tprintf("%d of %d %s", shown, total, noun)
	if st.mode == .Open_Folder {
		// Files are not listed at all in folder mode, so "10 of 26" would be
		// counting against a total the user cannot see.
		label = fmt.tprintf("%d %s", shown, shown == 1 ? "folder" : "folders")
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0

	if len(st.ahead) > 0 {
		p.text(ui, "·", "text-[11] text-muted-foreground/50")
		p.style(ui).shrink = 0
		p.row(ui, "shrink-0 items-center gap-1")
		p.icon(ui, ICON_SEARCH, "size-3 shrink-0 text-primary")
		p.text(ui, string(st.ahead[:]), "text-[11] font-medium text-primary whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}

	p.spacer(ui, "flex-1")

	if st.note != "" {
		p.text(ui, st.note, "truncate text-[11] text-muted-foreground max-w-[320]")
	}
}

@(private = "file")
pick_empty :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "flex-1 min-h-0 w-full items-center justify-center gap-2.5 px-8")
	defer p.end(ui)

	p.div(ui, "flex-row size-11 items-center justify-center rounded-2xl bg-muted shrink-0")
	p.icon(ui, ic, "size-5 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-[13] font-semibold text-foreground")
	p.text(ui, body, "max-w-[380] text-center text-[12] text-muted-foreground")
}

// ---------------------------------------------------------------------------
// Footer: the name field, the filter and the two buttons
// ---------------------------------------------------------------------------

@(private = "file")
pick_footer :: proc(ui: ^p.Ctx, st: ^Pick) {
	p.col(ui, "shrink-0 w-full border-t border-border bg-sidebar")
	defer p.end(ui)

	if st.mode == .Save_File {
		p.row(ui, "h-[44] shrink-0 w-full items-center gap-2.5 px-3.5")
		p.text(ui, "Save as", "text-[12] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		nf := pick_field(
			ui,
			&st.name_buf,
			st.name_cur,
			st.pane == .Name ? st.name_anchor : -1,
			"File name",
			st.pane == .Name,
			"flex-1 min-w-0",
		)
		if p.clickable(ui, nf) {
			st.pane = .Name
			st.swallow = true
		}
		p.end(ui)
	}

	p.row(ui, fmt.tprintf("h-[%d] shrink-0 w-full items-center gap-2 px-3.5", int(PICK_FOOT_H - 12)))
	defer p.end(ui)

	if len(st.filters) > 1 {
		pick_filter_trigger(ui, st)
	}

	if st.mode == .Save_File {
		target := pick_target(st, context.temp_allocator)
		p.row(ui, "flex-1 min-w-0 items-center gap-1 overflow-hidden")
		p.text(
			ui,
			pick_abbreviate(target, "", context.temp_allocator),
			"flex-1 min-w-0 truncate text-[11] text-muted-foreground",
		)
		p.end(ui)
	} else {
		p.spacer(ui, "flex-1")
	}

	if pick_btn(ui, "pick.cancel", "Cancel", .Outline, false, false) {
		pick_cancel(st)
	}
	label := st.confirm_label
	if st.mode == .Open_Files && st.marks > 1 {
		label = fmt.tprintf("%s %d", st.confirm_label, st.marks)
	}
	if pick_btn(ui, "pick.ok", label, .Default, false, !pick_can_confirm(st)) {
		if st.mode == .Open_Folder {
			pick_choose_here(st)
		} else {
			pick_confirm(st)
		}
	}
}

@(private = "file")
pick_btn :: proc(
	ui: ^p.Ctx,
	key, label: string,
	v: sc.Variant,
	focused: bool,
	disabled: bool,
) -> bool {
	p.key(ui, key)
	idx := sc.button_open(ui, v, .Default, sc.State{focus = focused, disabled = disabled})
	p.apply(ui, "shrink-0 px-3", idx)
	fired := false
	if !disabled {
		if p.is_hovered(ui, idx) {
			p.apply(ui, sc.button_variant_class(v, sc.State{hover = true}), idx)
		}
		fired = p.clickable(ui, idx)
	}
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.button_end(ui)
	return fired
}

@(private = "file")
pick_filter_trigger :: proc(ui: ^p.Ctx, st: ^Pick) {
	f := pick_active_filter(st)
	p.key(ui, "pick.filter")
	idx := p.row(
		ui,
		"h-7 w-[168] shrink-0 items-center justify-between gap-1.5 px-2.5 rounded-md border border-input bg-background cursor-pointer transition hover:bg-accent",
	)
	if st.pane == .Filter {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	if p.clickable(ui, idx) {
		st.filter_open = !st.filter_open
		st.filter_sel = st.filter
		st.pane = .Filter
	}
	p.text(ui, f.label, "flex-1 min-w-0 truncate text-[12]")
	p.icon(ui, sc.ICON_CHEVRON_DOWN, "size-3.5 shrink-0 text-muted-foreground")
	p.end(ui)
}

@(private = "file")
pick_filter_popup :: proc(ui: ^p.Ctx, st: ^Pick, pw, ph: f32) {
	scrim := p.div(ui, "absolute inset-0 z-55")
	if p.clickable(ui, scrim) {
		st.filter_open = false
	}
	p.end(ui)

	rows := f32(len(st.filters))
	h := rows * 26 + 8
	wrap := p.div(ui, "absolute z-60 w-[200]")
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(12)
	s.inset[p.TOP] = p.px(max(8, ph - PICK_FOOT_H - h - (st.mode == .Save_File ? 44 : 0)))
	defer p.end(ui)

	sc.menu_content_open(ui)
	p.apply(ui, "shadow-lg")
	defer p.end(ui)

	for f, i in st.filters {
		p.key(ui, f.label)
		idx := sc.menu_check_item_open(ui)
		p.apply(ui, "h-[26] cursor-pointer transition", idx)
		if i == st.filter_sel {
			p.apply(ui, "bg-primary text-primary-foreground", idx)
		} else if p.is_hovered(ui, idx) {
			p.apply(ui, "bg-accent text-accent-foreground", idx)
		}
		if p.clickable(ui, idx) {
			pick_set_filter(st, i)
			st.filter_open = false
		}
		p.text(ui, f.label, "flex-1 min-w-0 truncate text-[12.5] whitespace-nowrap")
		if i == st.filter {
			sc.menu_indicator(ui)
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The two inner dialogs
// ---------------------------------------------------------------------------

@(private = "file")
pick_new_folder_dialog :: proc(ui: ^p.Ctx, st: ^Pick, pw, ph: f32) {
	p.div(ui, "absolute inset-0 z-65 bg-black/35")
	p.end(ui)

	w := f32(360)
	wrap := p.div(ui, "absolute z-70")
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(math.round((pw - w) / 2))
	s.inset[p.TOP] = p.px(math.round(ph * 0.26))
	s.w = p.px(w)
	defer p.end(ui)

	sc.dialog_content_open(ui)
	p.apply(ui, "shadow-lg gap-3")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, ICON_FOLDER, "size-4 shrink-0 text-sky-500")
	p.text(ui, "New Folder", "text-[14] font-medium")
	p.end(ui)

	pick_field(ui, &st.nf_buf, st.nf_cur, -1, "Folder name", true, "w-full")

	if st.nf_err != "" {
		p.row(ui, "items-center gap-1.5 shrink-0")
		p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.text(ui, st.nf_err, "text-[11.5] text-destructive")
		p.end(ui)
	} else {
		p.text(
			ui,
			fmt.tprintf("Inside %s", pick_abbreviate(st.dir, "", context.temp_allocator)),
			"w-full truncate text-[11.5] text-muted-foreground",
		)
	}

	p.row(ui, "w-full justify-end gap-2 shrink-0")
	if pick_btn(ui, "nf.cancel", "Cancel", .Outline, false, false) {
		pick_new_folder_cancel(st)
	}
	if pick_btn(ui, "nf.ok", "Create", .Default, true, false) {
		pick_new_folder_commit(st)
	}
	p.end(ui)
}

// pick_overwrite_dialog is the one thing in this component that must never be
// easy to get wrong. It names the file, it says what will happen to it, and
// Cancel is what is focused: Enter and Escape both decline. Replace takes a
// deliberate move.
@(private = "file")
pick_overwrite_dialog :: proc(ui: ^p.Ctx, st: ^Pick, pw, ph: f32) {
	p.div(ui, "absolute inset-0 z-65 bg-black/45")
	p.end(ui)

	w := f32(400)
	wrap := p.div(ui, "absolute z-70")
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(math.round((pw - w) / 2))
	s.inset[p.TOP] = p.px(math.round(ph * 0.22))
	s.w = p.px(w)
	defer p.end(ui)

	sc.alert_dialog_content_open(ui)
	p.apply(ui, "shadow-lg gap-3.5")
	defer p.end(ui)

	p.row(ui, "w-full items-start gap-3 shrink-0")
	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-md bg-destructive/15")
	p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-5 text-destructive")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-1")
	p.text(
		ui,
		fmt.tprintf("Replace \"%s\"?", pick_base(st.cf_path)),
		"w-full truncate text-[14] font-medium",
	)
	p.text(
		ui,
		fmt.tprintf(
			"A file with that name already exists in %s. Replacing it overwrites its contents, and that cannot be undone.",
			pick_abbreviate(pick_parent(st.cf_path), "", context.temp_allocator),
		),
		"w-full text-[12] text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full justify-end gap-2 shrink-0")
	if pick_btn(ui, "cf.cancel", "Cancel", .Outline, st.cf_sel == 0, false) {
		pick_cancel_overwrite(st)
	}
	if pick_btn(ui, "cf.ok", "Replace", .Destructive, st.cf_sel == 1, false) {
		pick_confirm_overwrite(st)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// A text field with a real selection
// ---------------------------------------------------------------------------

// pick_field draws one of the dialog's fields. `anchor` is the other end of
// the selection, or -1 for none. The editing itself happened in `pick_edit`
// during the key pass; this only draws.
@(private = "file")
pick_field :: proc(
	ui: ^p.Ctx,
	buf: ^[dynamic]u8,
	cursor: int,
	anchor: int,
	placeholder: string,
	focus: bool,
	class: string,
) -> int {
	SIZE :: f32(13)
	field := p.row(
		ui,
		"h-8 items-center px-2.5 rounded-lg border border-input bg-background cursor-text relative overflow-hidden",
	)
	p.apply(ui, class, field)
	if focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50", field)
	}
	defer p.end(ui)

	content := string(buf[:])
	if content == "" {
		if placeholder != "" {
			p.text(ui, placeholder, "flex-1 min-w-0 truncate text-[13] text-muted-foreground")
		}
	}

	inner := p.row(ui, "flex-1 min-w-0 h-full items-center relative overflow-hidden")
	_ = inner

	cur := clamp(cursor, 0, len(content))
	lo := cur
	hi := cur
	if anchor >= 0 {
		a := clamp(anchor, 0, len(content))
		lo = min(cur, a)
		hi = max(cur, a)
	}

	x_lo := p.text_width_upto(ui.fonts, content, lo, SIZE)
	x_hi := p.text_width_upto(ui.fonts, content, hi, SIZE)
	x_cur := p.text_width_upto(ui.fonts, content, cur, SIZE)

	// The selection is painted first so the text sits on top of it.
	if hi > lo {
		rect := p.div(ui, "absolute rounded-[2] bg-primary/30")
		rs := p.style(ui, rect)
		rs.inset[p.LEFT] = p.px(x_lo)
		rs.w = p.px(max(1, x_hi - x_lo))
		rs.inset[p.TOP] = p.px(3)
		rs.inset[p.BOTTOM] = p.px(3)
		p.end(ui)
	}

	if content != "" {
		p.text(ui, content, "text-[13] text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}

	if focus {
		// A blinking caret, which is also what keeps the dialog animating
		// while a field has the keyboard.
		ui.animating = true
		if math.mod_f32(f32(ui.now), 1.06) < 0.62 {
			caret := p.div(ui, "absolute w-px bg-foreground")
			cs := p.style(ui, caret)
			cs.inset[p.LEFT] = p.px(x_cur)
			cs.inset[p.TOP] = p.px(3)
			cs.inset[p.BOTTOM] = p.px(3)
			p.end(ui)
		}
	}
	p.end(ui)
	return field
}
