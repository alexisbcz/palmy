// Application state: the cursor, the selection, scrolling, the two line
// editors, the clipboard bridge and undo.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."

// Chrome heights, in logical pixels. The grid works out what fits from the
// window size minus these, which is why they live in one place.
TOOLBAR_H :: f32(40)
FORMULA_H :: f32(34)
STATUS_H :: f32(26)
TABS_H :: f32(28)
HDR_H :: f32(22)
HDR_W :: f32(50)

Mode :: enum u8 {
	Nav,
	Edit,
	Prompt,
	Palette,
	Help,
}

Prompt_Kind :: enum u8 {
	None,
	Save_As,
	Open,
	Export_CSV,
	Import_CSV,
	Export_XLSX,
	Import_XLSX,
	Goto,
	Sheet_Name,
	Name_Define,
	Name_Delete,
}

// Line is a one-line text editor owned by this app. palmy's `text_field`
// manages its own focus and caret, which fights a grid that wants every key;
// `text_index_at` and `text_width_upto` are the two measurements it takes to
// do it properly instead.
Line :: struct {
	buf:   [dynamic]u8,
	caret: int,
}

line_set :: proc(l: ^Line, s: string) {
	clear(&l.buf)
	append(&l.buf, s)
	l.caret = len(l.buf)
}

line_text :: proc(l: ^Line) -> string {
	return string(l.buf[:])
}

line_insert :: proc(l: ^Line, s: string) {
	if len(s) == 0 {
		return
	}
	at := clamp(l.caret, 0, len(l.buf))
	tail := make([]u8, len(l.buf) - at, context.temp_allocator)
	copy(tail, l.buf[at:])
	resize(&l.buf, at)
	append(&l.buf, s)
	append(&l.buf, ..tail)
	l.caret = at + len(s)
}

line_backspace :: proc(l: ^Line) {
	if l.caret <= 0 {
		return
	}
	from := rune_start(l.buf[:], l.caret)
	n := l.caret - from
	copy(l.buf[from:], l.buf[l.caret:])
	resize(&l.buf, len(l.buf) - n)
	l.caret = from
}

line_delete :: proc(l: ^Line) {
	if l.caret >= len(l.buf) {
		return
	}
	to := rune_end(l.buf[:], l.caret)
	n := to - l.caret
	copy(l.buf[l.caret:], l.buf[to:])
	resize(&l.buf, len(l.buf) - n)
}

// Caret motion is rune-aware: one Left over "é" moves two bytes.
rune_start :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && (b[i] & 0xc0) == 0x80 {
		i -= 1
	}
	return max(i, 0)
}

rune_end :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && (b[i] & 0xc0) == 0x80 {
		i += 1
	}
	return min(i, len(b))
}

// ---------------------------------------------------------------------------
// Undo
//
// Each entry is the whole document serialised, which sounds extravagant and
// is not: a sheet is small, and it means undo of an inserted column is
// exactly as correct as undo of a typo, with no per-operation inverse to get
// wrong.
// ---------------------------------------------------------------------------

Snap :: struct {
	doc:    string,
	cursor: Addr,
	anchor: Addr,
}

UNDO_LIMIT :: 64

Undo :: struct {
	past:   [dynamic]Snap,
	future: [dynamic]Snap,
}

App :: struct {
	book:      ^Book,
	sh:        ^Sheet, // the active sheet: always book.sheets[book.active]
	fonts:     ^p.Fonts,
	pal:       Palette,
	cur:       Addr,
	anchor:    Addr,
	top_row:   int,
	left_col:  int,
	rows_vis:  int,
	cols_vis:  int,
	grid_w:    f32,
	grid_h:    f32,
	scroll_w:  f32, // the grid minus the frozen strip, which is what scrolls
	scroll_h:  f32,

	mode:      Mode,
	edit:      Line,
	in_bar:    bool, // the edit is happening in the formula bar, not the cell
	prompt:    Prompt_Kind,
	pline:     Line,
	pal_sel:   int, // the highlighted row of the command palette
	pline_new: bool, // the prompt still holds its suggestion: typing replaces it

	path:      string, // owned
	name:      string, // owned
	modified:  bool,
	status:    string, // owned
	clip:      Clipboard,
	last_tsv:  string, // owned: what we last put on the system clipboard
	clip_file: string, // owned: the scratch file the clipboard is written through
	undo:      Undo,
	quit:      bool,
	tab_edit:  bool, // the prompt is renaming the sheet tab
	chart_pick: Chart_Kind,
}

// app_init gives the application a book with one sheet in it.
app_init :: proc(app: ^App) {
	app.book = book_new()
	app.sh = app.book.sheets[0]
}

app_destroy :: proc(app: ^App) {
	if app.book == nil {
		return
	}
	book_destroy(app.book)
	free(app.book)
	app.book = nil
	app.sh = nil
}

// use_sheet switches the active tab. The cursor and the scroll are shared
// between sheets, as they are in a spreadsheet that remembers one selection
// per book; what matters is that both are clamped into the new sheet's frozen
// region, or the cursor would sit under the split.
use_sheet :: proc(app: ^App, i: int) {
	if app.book == nil || len(app.book.sheets) == 0 {
		return
	}
	want := clamp(i, 0, len(app.book.sheets) - 1)
	if want == app.book.active && app.sh != nil {
		return
	}
	if app.sh != nil {
		app.sh.ui_cur = app.cur
		app.sh.ui_anchor = app.anchor
		app.sh.ui_top = app.top_row
		app.sh.ui_left = app.left_col
	}
	app.book.active = want
	app.sh = app.book.sheets[want]
	app.cur = app.sh.ui_cur
	app.anchor = app.sh.ui_anchor
	app.top_row = max(app.sh.ui_top, app.sh.frz_rows)
	app.left_col = max(app.sh.ui_left, app.sh.frz_cols)
	follow_cursor(app)
}

// sync_sheet re-points `app.sh` after the book changed under it — which a
// document load and an undo both do.
sync_sheet :: proc(app: ^App) {
	if app.book == nil || len(app.book.sheets) == 0 {
		return
	}
	app.book.active = clamp(app.book.active, 0, len(app.book.sheets) - 1)
	app.sh = app.book.sheets[app.book.active]
}

sel_rect :: proc(app: ^App) -> Rect_I {
	return rect_norm(app.cur, app.anchor)
}

// work_rect is the selection an operation actually touches. A selection may
// legitimately be "A1:XFD1048576" after a Go To; walking seventeen billion
// addresses to bold them is not what the user meant, so operations are
// bounded by the used area with room to grow into.
WORK_MARGIN_ROWS :: 200
WORK_MARGIN_COLS :: 50
WORK_MAX_CELLS :: 65536

work_rect :: proc(app: ^App) -> Rect_I {
	r := sel_rect(app)
	r.r1 = min(r.r1, max(app.sh.max_row, r.r0) + WORK_MARGIN_ROWS)
	r.c1 = min(r.c1, max(app.sh.max_col, r.c0) + WORK_MARGIN_COLS)
	// And a hard ceiling on the area, so a selection of the whole sheet is a
	// bounded amount of work rather than an unresponsive window.
	w := r.c1 - r.c0 + 1
	if w > WORK_MAX_CELLS {
		r.c1 = r.c0 + WORK_MAX_CELLS - 1
		w = WORK_MAX_CELLS
	}
	if h := r.r1 - r.r0 + 1; h * w > WORK_MAX_CELLS {
		r.r1 = r.r0 + max(0, WORK_MAX_CELLS / w - 1)
	}
	return r
}

clear_status :: proc(app: ^App) {
	if app.status != "" {
		delete(app.status)
		app.status = ""
	}
}

set_status :: proc(app: ^App, format: string, args: ..any) {
	if app.status != "" {
		delete(app.status)
	}
	app.status = fmt.aprintf(format, ..args)
}

set_path :: proc(app: ^App, path: string) {
	if app.path != "" {
		delete(app.path)
	}
	app.path = strings.clone(path)
	if app.name != "" {
		delete(app.name)
	}
	app.name = strings.clone(base_name(path))
}

base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

snap_take :: proc(app: ^App) -> Snap {
	return Snap {
		doc = doc_save_string(app.sh, app.name, app.cur, app.anchor),
		cursor = app.cur,
		anchor = app.anchor,
	}
}

snap_free :: proc(s: Snap) {
	delete(s.doc)
}

undo_push :: proc(app: ^App) {
	append(&app.undo.past, snap_take(app))
	if len(app.undo.past) > UNDO_LIMIT {
		snap_free(app.undo.past[0])
		ordered_remove(&app.undo.past, 0)
	}
	for s in app.undo.future {
		snap_free(s)
	}
	clear(&app.undo.future)
	app.modified = true
}

snap_restore :: proc(app: ^App, s: Snap) {
	// The undo entry is the whole book, so restoring it rebuilds the sheet
	// list — and `app.sh` has to be re-pointed at whatever came back.
	_, cur, anc, ok := doc_load_string(app.book.sheets[0], s.doc)
	sync_sheet(app)
	if ok {
		app.cur = cur
		app.anchor = anc
	} else {
		app.cur = s.cursor
		app.anchor = s.anchor
	}
}

do_undo :: proc(app: ^App) {
	if len(app.undo.past) == 0 {
		set_status(app, "Nothing to undo")
		return
	}
	append(&app.undo.future, snap_take(app))
	s := pop(&app.undo.past)
	snap_restore(app, s)
	snap_free(s)
	app.modified = true
	set_status(app, "Undo")
}

do_redo :: proc(app: ^App) {
	if len(app.undo.future) == 0 {
		set_status(app, "Nothing to redo")
		return
	}
	append(&app.undo.past, snap_take(app))
	s := pop(&app.undo.future)
	snap_restore(app, s)
	snap_free(s)
	app.modified = true
	set_status(app, "Redo")
}

// ---------------------------------------------------------------------------
// Viewport
// ---------------------------------------------------------------------------

// visible_cols counts the columns that fit starting at `left_col`, honouring
// the per-column widths.
visible_cols :: proc(app: ^App, from: int, width: f32) -> int {
	x := f32(0)
	n := 0
	for c := from; c < MAX_COLS; c += 1 {
		w := col_width(app.sh, c)
		if x + w > width && n > 0 {
			break
		}
		x += w
		n += 1
		if x >= width {
			break
		}
	}
	return max(n, 1)
}

visible_rows :: proc(app: ^App, from: int, height: f32) -> int {
	y := f32(0)
	n := 0
	for r := from; r < MAX_ROWS; r += 1 {
		h := row_height(app.sh, r)
		if y + h > height && n > 0 {
			break
		}
		y += h
		n += 1
		if y >= height {
			break
		}
	}
	return max(n, 1)
}

// header_width grows the row-number gutter to fit the numbers in it, so row
// 1048576 is not clipped the way row 12 does not need the room.
header_width :: proc(app: ^App) -> f32 {
	n := app.top_row + max(app.rows_vis, 1)
	d := 1
	for v := n; v >= 10; v /= 10 {
		d += 1
	}
	return max(HDR_W, f32(d) * 7.5 + 18)
}

// frozen_w / frozen_h measure the pinned strip. Everything else is measured
// against what is left, which is the whole of what freezing changes about the
// viewport: the scrolled region is smaller, and it starts after the split.
frozen_w :: proc(app: ^App) -> f32 {
	w := f32(0)
	for c in 0 ..< min(app.sh.frz_cols, 64) {
		w += col_width(app.sh, c)
	}
	return w
}

frozen_h :: proc(app: ^App) -> f32 {
	h := f32(0)
	for r in 0 ..< min(app.sh.frz_rows, 64) {
		h += row_height(app.sh, r)
	}
	return h
}

measure_viewport :: proc(app: ^App, win: [2]f32) {
	app.grid_h = max(win.y - TOOLBAR_H - FORMULA_H - STATUS_H - TABS_H - HDR_H, 1)
	app.grid_w = max(win.x - header_width(app), 1)
	// A frozen strip is never scrolled past, so the scroll position can never
	// be inside it.
	app.top_row = max(app.top_row, app.sh.frz_rows)
	app.left_col = max(app.left_col, app.sh.frz_cols)
	app.scroll_h = max(app.grid_h - frozen_h(app), 1)
	app.scroll_w = max(app.grid_w - frozen_w(app), 1)
	app.rows_vis = visible_rows(app, app.top_row, app.scroll_h)
	app.cols_vis = visible_cols(app, app.left_col, app.scroll_w)
}

// follow_cursor scrolls the least amount that brings the cursor back into
// view, which is what keeps arrow-key navigation from jumping around. A
// cursor inside the frozen region needs no scrolling at all — it is already
// on screen by definition, and scrolling for it would pull the data out from
// under the headers.
follow_cursor :: proc(app: ^App) {
	sh := app.sh
	app.top_row = max(app.top_row, sh.frz_rows)
	app.left_col = max(app.left_col, sh.frz_cols)

	if app.cur.row >= sh.frz_rows {
		if app.cur.row < app.top_row {
			app.top_row = app.cur.row
		}
		// Converge on the scroll position rather than crawling to it: jumping
		// to row 900000 must not iterate 900000 times.
		for _ in 0 ..< 64 {
			n := visible_rows(app, app.top_row, app.scroll_h)
			if app.cur.row < app.top_row + n {
				break
			}
			app.top_row = min(app.cur.row, app.cur.row - n + 1)
		}
	}
	if app.cur.col >= sh.frz_cols {
		if app.cur.col < app.left_col {
			app.left_col = app.cur.col
		}
		for _ in 0 ..< 64 {
			n := visible_cols(app, app.left_col, app.scroll_w)
			if app.cur.col < app.left_col + n {
				break
			}
			app.left_col = min(app.cur.col, app.cur.col - n + 1)
		}
	}
	app.top_row = max(app.top_row, sh.frz_rows)
	app.left_col = max(app.left_col, sh.frz_cols)
	app.cols_vis = visible_cols(app, app.left_col, app.scroll_w)
	app.rows_vis = visible_rows(app, app.top_row, app.scroll_h)
}

move_cursor :: proc(app: ^App, dr, dc: int, extend: bool) {
	clear_status(app)
	app.cur.row = clamp(app.cur.row + dr, 0, MAX_ROWS - 1)
	app.cur.col = clamp(app.cur.col + dc, 0, MAX_COLS - 1)
	if !extend {
		app.anchor = app.cur
	}
	follow_cursor(app)
}

goto_cell :: proc(app: ^App, a: Addr, extend := false) {
	clear_status(app)
	app.cur = {clamp(a.row, 0, MAX_ROWS - 1), clamp(a.col, 0, MAX_COLS - 1)}
	if !extend {
		app.anchor = app.cur
	}
	follow_cursor(app)
}

// jump_edge is Ctrl+Arrow: to the end of the current run of data, or across a
// gap to the start of the next one.
jump_edge :: proc(app: ^App, dr, dc: int, extend: bool) {
	has :: proc(app: ^App, a: Addr) -> bool {
		return cell_at(app.sh, a) != nil
	}
	lim_r := max(app.sh.max_row, 0)
	lim_c := max(app.sh.max_col, 0)
	a := app.cur
	in_bounds :: proc(a: Addr) -> bool {
		return a.row >= 0 && a.col >= 0 && a.row < MAX_ROWS && a.col < MAX_COLS
	}
	next := Addr{a.row + dr, a.col + dc}
	if !in_bounds(next) {
		goto_cell(app, a, extend)
		return
	}
	if has(app, next) {
		// Walk to the far end of this block of data.
		for {
			n := Addr{a.row + dr, a.col + dc}
			if !in_bounds(n) || !has(app, n) {
				break
			}
			a = n
		}
	} else {
		// Cross the gap to the next cell holding something, or to the edge of
		// the used area.
		for {
			n := Addr{a.row + dr, a.col + dc}
			if !in_bounds(n) {
				break
			}
			if n.row > lim_r && dr > 0 {
				break
			}
			if n.col > lim_c && dc > 0 {
				break
			}
			a = n
			if has(app, a) {
				break
			}
		}
	}
	goto_cell(app, a, extend)
}
