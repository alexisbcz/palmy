// reader — EPUB, MOBI, PDF and DjVu in one application.
//
//   reader                       the library
//   reader <file>                open a book
//   reader --selftest            headless assertions
//   reader --shots <dir>         render reference PNGs
//   reader --bench <file>        open timings for one book
//   reader --fixtures <dir>      write the generated test books out
//
// Two reading experiences, because there are two kinds of book here. EPUB and
// MOBI reflow: the text has no page of its own, so the window width and the
// reader's type size decide where the lines fall, and the interface offers
// type size, line height, margins, justification and a theme. PDF and DjVu do
// not reflow: the page is a picture the author laid out, so the interface
// offers fit-width, fit-page and zoom instead, and says so rather than
// offering a font size that would do nothing.
//
// Everything persists under ~/.local/share/palmy-reader/ and nothing else on
// the disk is touched. Books are read where they are; opening one records its
// path so that the library never has to search for it, and the user's home
// directory is never scanned.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

View :: enum u8 {
	Library,
	Reading,
}

Panel :: enum u8 {
	None,
	Toc,
	Search,
	Settings,
	Marks,
	Notes, // the book's parse warnings
}

Reader :: struct {
	app:      ^p.App,
	lib:      Library,
	set:      Settings,
	book:     Book,
	cur:      int, // index into lib.books, -1 when nothing is open
	view:     View,
	panel:    Panel,
	pick:     kit.Pick,
	pal:      Palette,

	// --- where we are
	chapter:  int,
	page:     int, // page within the chapter, reflowable
	fpage:    int, // 1-based page, fixed
	scroll_y: f32,

	// --- search
	search:   Search,
	qbuf:     [dynamic]u8,
	qcur:     int,
	focus_search: bool,

	// --- selection, which is what a highlight is made from
	sel_block: int,
	sel_a:    int,
	sel_b:    int,
	dragging: bool,

	// --- panels
	toc_sel:  int,
	lib_sel:  int,
	mark_sel: int,

	// --- geometry measured last frame
	col_w:    f32,
	col_h:    f32,
	page_id:  u64,
	view_id:  u64,
	// Set when our idea of the scroll offset is the authoritative one and
	// palmy's container has to be moved to match -- after a jump from the
	// contents or a search result, rather than after the wheel.
	scroll_dirty: bool,

	// --- the painter's state, pinned here because p.pixels borrows it
	pd:       Page_Draw,

	// --- transient
	note:     string,
	note_at:  f64,
	// The last position written to disk, and when. Reading position is the
	// feature people notice, so it is not left to a clean exit: it is written
	// a second or two after it changes, which means a crash, a kill, or the
	// machine losing power costs at most the page you were on.
	saved:    [3]int,
	saved_at: f64,
	open_next: string,
	frames:   int,
	turn_ms:  f64,
	relayout_ms: f64,
	dark_registered: bool,
}

main :: proc() {
	args := os.args[1:]
	// The developer modes, which are not commands an agent has any use for
	// and keep the spellings they always had.
	for a, i in args {
		switch a {
		case "--shots":
			dir := i + 1 < len(args) ? args[i + 1] : "apps/reader/shots"
			shots(dir)
			return
		case "--fixtures":
			dir := i + 1 < len(args) ? args[i + 1] : "."
			write_fixtures(dir)
			return
		case "--genbig":
			// A novel-sized EPUB, written by this program, for the
			// performance numbers. `--genbig <path> [chapters] [paragraphs]`
			out := i + 1 < len(args) ? args[i + 1] : "big.epub"
			nch := i + 2 < len(args) ? atoi_simple(args[i + 2]) : 36
			npa := i + 3 < len(args) ? atoi_simple(args[i + 3]) : 70
			ok, n := false, 0
			if path_ext_lower(out) == "mobi" {
				ok, n = gen_big_mobi(out, max(nch, 1), max(npa, 1))
			} else {
				ok, n = gen_big_epub(out, max(nch, 1), max(npa, 1))
			}
			fmt.printfln("%s %v, %.2f MB of markup", out, ok, f32(n) / 1e6)
			return
		case "--bench":
			if i + 1 < len(args) {
				bench(args[i + 1])
			} else {
				fmt.eprintln("reader --bench <file>")
			}
			return
		}
	}

	// Everything else is the command line (cli.odin): the library, a book's
	// text and search, positions, marks and settings, over the same store and
	// the same procedures as the window. `--add` and `--selftest` are spellings
	// it keeps. With no command, or a bare path, there is a window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	r := new(Reader)
	defer free(r)
	library_init(&r.lib)
	library_load(&r.lib)
	r.set = settings_load(&r.lib)
	r.cur = -1
	r.sel_block = -1
	r.qbuf = make([dynamic]u8, 0, 64)
	r.pd.hit_block = -1
	r.pd.sel_block = -1

	app, err := kit.start(
		{
			title = "Reader",
			width = 1180,
			height = 800,
			min_width = 720,
			min_height = 520,
			app_id = "palmy-reader",
			root_class = "w-full h-full bg-background text-foreground",
		},
		r.set.theme == .Dark,
	)
	if err != "" {
		fmt.eprintfln("reader: %s", err)
		os.exit(1)
	}
	r.app = app
	r.dark_registered = r.set.theme == .Dark
	defer p.destroy(app)
	defer reader_shutdown(r)

	// A file on the command line opens straight into it, which is what a
	// double-click in a file manager means.
	for a in args {
		if !strings.has_prefix(a, "-") {
			r.open_next = strings.clone(a)
			break
		}
	}

	for ui in p.frames(app) {
		r.frames += 1
		reader_frame(r, ui)
	}
}

reader_shutdown :: proc(r: ^Reader) {
	reader_save_position(r)
	_ = library_save(&r.lib)
	_ = settings_save(&r.lib, r.set)
	if r.book.open {
		book_close(&r.book)
	}
	search_destroy(&r.search)
	delete(r.qbuf)
	delete(r.note)
	kit.pick_destroy(&r.pick)
	library_destroy(&r.lib)
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

reader_frame :: proc(r: ^Reader, ui: ^p.Ctx) {
	r.pal = palette_of(r.set.theme)

	// Deferred opens happen at the top of a frame, never in the middle of
	// building one: the book being replaced owns the lines the painter is
	// about to be handed.
	if r.open_next != "" {
		path := r.open_next
		r.open_next = ""
		reader_open(r, path)
		delete(path)
	}

	// The file dialog takes the whole window while it is up.
	if kit.pick_active(&r.pick) {
		if res, done := kit.pick_draw(ui, &r.pick); done {
			defer kit.pick_result_free(res)
			if res.ok {
				reader_request_open(r, ui, res.path)
			}
		}
		reader_body(r, ui)
		return
	}

	reader_keys(r, ui)

	// The palette is recomputed *after* the keys, because a key may have just
	// changed the theme. Reading it once at the top of the frame meant the
	// toast said "Sepia theme" over a page that was still white until the
	// next input event woke the loop -- and an idle palmy window waits.
	r.pal = palette_of(r.set.theme)

	// Images decode on the UI thread under a budget, and a decoded picture
	// changes its block's measured height, so the chapter is laid out again.
	if format_is_reflowable(r.book.format) && book_images_pending(&r.book) {
		if book_pump_images(&r.book, 2) > 0 {
			for i in 0 ..< CHAPTER_CACHE {
				r.book.reflow.chaps[i].valid = false
			}
		}
		p.redraw(ui)
	}
	if r.book.open && !format_is_reflowable(r.book.format) {
		if fixed_collect(&r.book.fixed) {
			p.redraw(ui)
		}
		if fixed_busy(&r.book.fixed) {
			p.redraw(ui)
		}
	}

	reader_body(r, ui)
	reader_autosave(r, ui)
}

// reader_autosave writes the position when it has changed and settled. The
// delay is what keeps paging quickly through a book from writing the library
// file once per keystroke.
reader_autosave :: proc(r: ^Reader, ui: ^p.Ctx) {
	if !r.book.open || r.cur < 0 {
		return
	}
	now := f64(p.elapsed(ui))
	cur := [3]int{r.chapter, r.page, r.fpage}
	if cur == r.saved {
		return
	}
	if r.saved_at != 0 && now - r.saved_at < 1.5 {
		p.redraw(ui) // come back and write it once it has settled
		return
	}
	r.saved = cur
	r.saved_at = now
	reader_save_position(r)
	_ = library_save(&r.lib)
}

reader_body :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(ui, "w-full h-full relative overflow-hidden")
	defer p.end(ui)

	switch r.view {
	case .Library:
		draw_library(r, ui)
	case .Reading:
		draw_reading(r, ui)
	}

	if r.note != "" && p.elapsed(ui) - f32(r.note_at) < 4.2 {
		draw_toast(r, ui)
		// Keep the loop awake so the toast can go away on its own; an idle
		// palmy window draws nothing until something happens to it.
		p.redraw(ui)
	} else if r.note != "" {
		delete(r.note)
		r.note = ""
	}
}

reader_say :: proc(r: ^Reader, text: string) {
	delete(r.note)
	r.note = strings.clone(text)
	r.note_at = f64(p.app_elapsed(r.app))
}

// ---------------------------------------------------------------------------
// Opening and closing a book
// ---------------------------------------------------------------------------

// reader_request_open defers an open to the top of the next frame, and asks
// for that frame.
//
// The deferral is necessary: the book being replaced owns the lines the
// painter is about to be handed, so it cannot be closed in the middle of
// building a frame. Asking for the next frame is equally necessary and is
// easier to forget — an idle palmy window blocks in `poll` until something
// happens to it, so without this the book opens only when the reader next
// touches a key, and pressing Enter on a library card appears to do nothing.
reader_request_open :: proc(r: ^Reader, ui: ^p.Ctx, path: string) {
	delete(r.open_next)
	r.open_next = strings.clone(path)
	p.redraw(ui)
}

reader_open :: proc(r: ^Reader, path: string) {
	abs := path
	if !strings.has_prefix(abs, "/") {
		if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
			abs = tfmt("%s/%s", cwd, abs)
		}
	}
	abs = path_normalize_abs(abs)

	if r.book.open {
		reader_save_position(r)
		book_close(&r.book)
	}
	r.chapter, r.page, r.fpage, r.scroll_y = 0, 0, 1, 0
	r.sel_block = -1
	r.pd.hit_block = -1
	r.pd.sel_block = -1

	// The same call `reader add` makes: open, record, store the cover, read
	// the marks.
	opts := reader_opts(r)
	idx, opened := library_open_book(&r.lib, &r.book, abs, &r.app.fonts, opts)
	if !opened {
		reader_say(r, tfmt("%s: %s", path_base(abs), r.book.err))
		r.view = .Library
		return
	}
	r.cur = idx
	e := &r.lib.books[r.cur]

	// Restore the position. This is the feature people notice, so it is the
	// one place that re-lays out on open: the chapter the reader was in is
	// laid out at the current type size and the byte offset is turned back
	// into a page.
	if format_is_reflowable(r.book.format) {
		r.chapter = clamp(e.chapter, 0, max(0, len(r.book.doc.chapters) - 1))
		reader_measure_from_window(r)
		cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
		if e.block > 0 || e.off > 0 {
			r.page = clamp(layout_page_of(cl, e.block, e.off), 0, max(0, cl.pages - 1))
		}
		if r.set.mode == .Continuous {
			r.scroll_y = f32(r.page) * r.col_h
		}
	} else {
		r.fpage = clamp(e.page > 0 ? e.page : 1, 1, r.book.fixed.pages)
	}

	r.view = .Reading
	r.panel = .None
	r.saved = {r.chapter, r.page, r.fpage}
	r.saved_at = 0
	search_destroy(&r.search)
	clear(&r.qbuf)
	r.qcur = 0
	_ = library_save(&r.lib)
}

// path_normalize_abs cleans an absolute path without touching the filesystem.
path_normalize_abs :: proc(path: string, allocator := context.temp_allocator) -> string {
	n := path_normalize(path, allocator)
	return strings.concatenate({"/", n}, allocator)
}

reader_close_book :: proc(r: ^Reader) {
	reader_save_position(r)
	if r.book.open {
		book_close(&r.book)
	}
	r.view = .Library
	r.panel = .None
	_ = library_save(&r.lib)
}

// ---------------------------------------------------------------------------
// Position
// ---------------------------------------------------------------------------

reader_opts :: proc(r: ^Reader) -> Reflow_Opts {
	return Reflow_Opts {
		size = r.set.size,
		line = r.set.line,
		measure = max(120, r.col_w),
		page_h = r.set.mode == .Paged ? max(80, r.col_h) : 0,
		justify = r.set.justify,
		para = r.set.para,
	}
}

// reader_measure_from_window derives the text column from the window, before
// the frame has been built. Used on open, where layout must happen first.
reader_measure_from_window :: proc(r: ^Reader) {
	w := max(f32(r.app.win.width), 480)
	h := max(f32(r.app.win.height), 360)
	side := w * r.set.margin
	r.col_w = max(180, w - 2 * side)
	r.col_h = max(120, h - READ_BAR_H - READ_FOOT_H - 2 * PAGE_PAD)
	reflow_set_opts(&r.book.reflow, reader_opts(r))
}

// reader_progress is how far through the *book* the reader is, which is the
// number the library shows. It is computed from chapter byte sizes rather than
// page numbers, so it does not move when the type size does.
reader_progress :: proc(r: ^Reader) -> f32 {
	if !r.book.open {
		return 0
	}
	if !format_is_reflowable(r.book.format) {
		return fixed_progress(r.fpage, r.book.fixed.pages)
	}
	d := &r.book.doc
	within := f32(0)
	if r.chapter >= 0 && r.chapter < len(d.chapters) {
		cl := reflow_chapter(&r.book.reflow, d, r.chapter)
		if cl.pages > 0 {
			within = f32(r.page) / f32(cl.pages)
		}
	}
	return doc_progress(d, r.chapter, within)
}

reader_save_position :: proc(r: ^Reader) {
	if !r.book.open || r.cur < 0 || r.cur >= len(r.lib.books) {
		return
	}
	// Where on screen becomes a position here; recording it is the same call
	// `reader seek` makes.
	frac := reader_progress(r)
	if format_is_reflowable(r.book.format) {
		cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
		pg := r.set.mode == .Continuous ? reader_page_from_scroll(r, cl) : r.page
		blk, off := layout_pos_at(cl, clamp(pg, 0, max(0, cl.pages - 1)))
		library_set_position(&r.lib, r.cur, true, r.chapter, blk, off, 0, frac, len(r.book.doc.chapters))
	} else {
		library_set_position(&r.lib, r.cur, false, 0, -1, 0, r.fpage, frac, r.book.fixed.pages)
	}
	_ = marks_save(&r.lib, r.cur)
}

// reader_page_from_scroll turns a continuous-mode scroll offset back into a
// page, so that the position written to disk means the same thing in either
// mode.
reader_page_from_scroll :: proc(r: ^Reader, cl: ^Chapter_Layout) -> int {
	if cl.height <= 0 || r.col_h <= 0 {
		return 0
	}
	// In continuous mode there are no pages, so a position is the first line
	// at or below the top of the viewport.
	for ln, i in cl.lines {
		if ln.y + ln.h > r.scroll_y {
			_ = i
			return 0
		}
	}
	return 0
}

// reader_goto_block moves to a block, which is what the table of contents, a
// search result and an internal link all do.
reader_goto_block :: proc(r: ^Reader, block: int) {
	if !r.book.open || !format_is_reflowable(r.book.format) {
		return
	}
	d := &r.book.doc
	if block < 0 || block >= len(d.blocks) {
		return
	}
	ci := chapter_of_block(d, block)
	r.chapter = ci
	cl := reflow_chapter(&r.book.reflow, d, ci)
	r.page = clamp(layout_page_of(cl, block, 0), 0, max(0, cl.pages - 1))
	if r.set.mode == .Continuous {
		for ln in cl.lines {
			if ln.block >= block {
				r.scroll_y = max(0, ln.y - 8)
				break
			}
		}
	}
}

reader_goto_page :: proc(r: ^Reader, page: int) {
	if !r.book.open || format_is_reflowable(r.book.format) {
		return
	}
	r.fpage = clamp(page, 1, r.book.fixed.pages)
}

// ---------------------------------------------------------------------------
// Turning pages
// ---------------------------------------------------------------------------

reader_turn :: proc(r: ^Reader, delta: int) {
	if !r.book.open {
		return
	}
	t0 := time.now()
	defer r.turn_ms = time.duration_milliseconds(time.since(t0))

	if !format_is_reflowable(r.book.format) {
		r.fpage = clamp(r.fpage + delta, 1, r.book.fixed.pages)
		return
	}
	d := &r.book.doc
	if r.set.mode == .Continuous {
		r.scroll_y = max(0, r.scroll_y + f32(delta) * r.col_h * 0.92)
		cl := reflow_chapter(&r.book.reflow, d, r.chapter)
		if r.scroll_y > cl.height - r.col_h * 0.5 && r.chapter + 1 < len(d.chapters) {
			r.chapter += 1
			r.scroll_y = 0
		} else if r.scroll_y <= 0 && delta < 0 && r.chapter > 0 {
			r.chapter -= 1
			prev := reflow_chapter(&r.book.reflow, d, r.chapter)
			r.scroll_y = max(0, prev.height - r.col_h)
		}
		return
	}

	cl := reflow_chapter(&r.book.reflow, d, r.chapter)
	np := r.page + delta
	for np >= cl.pages {
		if r.chapter + 1 >= len(d.chapters) {
			r.page = max(0, cl.pages - 1)
			return
		}
		np -= cl.pages
		r.chapter += 1
		cl = reflow_chapter(&r.book.reflow, d, r.chapter)
	}
	for np < 0 {
		if r.chapter == 0 {
			r.page = 0
			return
		}
		r.chapter -= 1
		cl = reflow_chapter(&r.book.reflow, d, r.chapter)
		np += cl.pages
	}
	r.page = clamp(np, 0, max(0, cl.pages - 1))
}

reader_chapter_step :: proc(r: ^Reader, delta: int) {
	if !r.book.open {
		return
	}
	if !format_is_reflowable(r.book.format) {
		// A fixed document's "chapter" is its outline, so step through that.
		ol := r.book.fixed.outline[:]
		if len(ol) == 0 {
			reader_turn(r, delta * 10)
			return
		}
		best := -1
		for e, i in ol {
			if delta > 0 && e.block > r.fpage {
				best = i
				break
			}
			if delta < 0 && e.block < r.fpage {
				best = i
			}
		}
		if best >= 0 {
			reader_goto_page(r, ol[best].block)
		}
		return
	}
	n := len(r.book.doc.chapters)
	r.chapter = clamp(r.chapter + delta, 0, max(0, n - 1))
	r.page = 0
	r.scroll_y = 0
}

// ---------------------------------------------------------------------------
// Settings changes
// ---------------------------------------------------------------------------

// reader_resize keeps the reader on the same *words* when the layout changes
// under them, which is the whole point of storing a byte offset rather than a
// page number. Called whenever the type size, line height, margin, mode or
// window size changes.
reader_keep_place :: proc(r: ^Reader, apply: proc(r: ^Reader)) {
	if !r.book.open || !format_is_reflowable(r.book.format) {
		apply(r)
		return
	}
	cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
	pg := r.page
	if r.set.mode == .Continuous {
		pg = 0
		for ln in cl.lines {
			if ln.y + ln.h > r.scroll_y {
				break
			}
			pg = ln.page
		}
	}
	blk, off := layout_pos_at(cl, clamp(pg, 0, max(0, cl.pages - 1)))
	if r.set.mode == .Continuous {
		for ln in cl.lines {
			if ln.y + ln.h > r.scroll_y {
				blk, off = ln.block, ln.start
				break
			}
		}
	}

	t0 := time.now()
	apply(r)
	reader_measure_from_window(r)
	cl2 := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
	r.relayout_ms = time.duration_milliseconds(time.since(t0))
	if blk >= 0 {
		r.page = clamp(layout_page_of(cl2, blk, off), 0, max(0, cl2.pages - 1))
		if r.set.mode == .Continuous {
			for ln in cl2.lines {
				if ln.block >= blk {
					r.scroll_y = max(0, ln.y - 4)
					break
				}
			}
		}
	}
}

reader_set_size :: proc(r: ^Reader, delta: f32) {
	target := clamp(r.set.size + delta, SET_SIZE_MIN, SET_SIZE_MAX)
	if target == r.set.size {
		return
	}
	size_ctx = target
	reader_keep_place(r, proc(r: ^Reader) {
		r.set.size = size_ctx
	})
	reader_say(r, tfmt("Type size %.0f px", r.set.size))
	_ = settings_save(&r.lib, r.set)
}

// Odin has no closures, so the one-shot value a `reader_keep_place` callback
// needs is parked here. Single-threaded, one call at a time.
size_ctx: f32
line_ctx: f32
margin_ctx: f32
mode_ctx: Read_Mode
para_ctx: Para_Style

reader_set_line :: proc(r: ^Reader, delta: f32) {
	target := clamp(r.set.line + delta, SET_LINE_MIN, SET_LINE_MAX)
	if target == r.set.line {
		return
	}
	line_ctx = target
	reader_keep_place(r, proc(r: ^Reader) {
		r.set.line = line_ctx
	})
	reader_say(r, tfmt("Line height %.2f", r.set.line))
	_ = settings_save(&r.lib, r.set)
}

reader_set_margin :: proc(r: ^Reader, delta: f32) {
	target := clamp(r.set.margin + delta, SET_MARGIN_MIN, SET_MARGIN_MAX)
	if target == r.set.margin {
		return
	}
	margin_ctx = target
	reader_keep_place(r, proc(r: ^Reader) {
		r.set.margin = margin_ctx
	})
	reader_say(r, tfmt("Margins %.0f%%", r.set.margin * 100))
	_ = settings_save(&r.lib, r.set)
}

reader_set_mode :: proc(r: ^Reader, m: Read_Mode) {
	if r.set.mode == m {
		return
	}
	mode_ctx = m
	reader_keep_place(r, proc(r: ^Reader) {
		r.set.mode = mode_ctx
	})
	reader_say(r, m == .Paged ? "Paged" : "Continuous scroll")
	_ = settings_save(&r.lib, r.set)
}

reader_set_para :: proc(r: ^Reader, s: Para_Style) {
	if r.set.para == s {
		return
	}
	para_ctx = s
	reader_keep_place(r, proc(r: ^Reader) {
		r.set.para = para_ctx
	})
	_ = settings_save(&r.lib, r.set)
}

reader_set_theme :: proc(r: ^Reader, t: Theme) {
	r.set.theme = t
	dark := t == .Dark
	if dark != r.dark_registered {
		sc.register_shadcn_theme(dark)
		r.dark_registered = dark
	}
	reader_say(r, tfmt("%s theme", theme_name(t)))
	_ = settings_save(&r.lib, r.set)
}

reader_set_justify :: proc(r: ^Reader, on: bool) {
	if r.set.justify == on {
		return
	}
	r.set.justify = on
	reader_keep_place(r, proc(r: ^Reader) {})
	_ = settings_save(&r.lib, r.set)
}

reader_set_fit :: proc(r: ^Reader, f: Fit_Mode) {
	r.set.fit = f
	reader_say(
		r,
		f == .Width ? "Fit width" : (f == .Page ? "Fit page" : tfmt("Zoom %.0f%%", r.set.zoom * 100)),
	)
	_ = settings_save(&r.lib, r.set)
}

reader_zoom :: proc(r: ^Reader, mul: f32) {
	r.set.zoom = clamp(r.set.zoom * mul, SET_ZOOM_MIN, SET_ZOOM_MAX)
	r.set.fit = .Zoom
	reader_say(r, tfmt("Zoom %.0f%%", r.set.zoom * 100))
	_ = settings_save(&r.lib, r.set)
}

// ---------------------------------------------------------------------------
// Bookmarks and highlights
// ---------------------------------------------------------------------------

reader_toggle_bookmark :: proc(r: ^Reader) {
	if !r.book.open || r.cur < 0 {
		return
	}
	reflowable := format_is_reflowable(r.book.format)
	blk, off, page := -1, 0, 0
	if reflowable {
		cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
		blk, off = layout_pos_at(cl, r.page)
		if blk < 0 {
			return
		}
	} else {
		page = r.fpage
	}
	// The page on screen becomes a position; finding, adding and removing the
	// bookmark at it are the calls `reader bookmark` makes.
	if k := marks_find_bookmark(&r.lib, r.cur, reflowable, r.chapter, blk, page); k >= 0 {
		marks_remove(&r.lib, r.cur, k)
		reader_say(r, "Bookmark removed")
		return
	}
	marks_add_bookmark(&r.lib, r.cur, r.chapter, blk, off, page, bookmark_label(&r.book, blk, page))
	reader_say(r, "Bookmarked")
}

// bookmark_label is what a bookmark is called in the marks panel: the start of
// the paragraph it is on, or the page number of a fixed document.
bookmark_label :: proc(b: ^Book, block, page: int) -> string {
	if format_is_reflowable(b.format) {
		t := block_text(&b.doc, block)
		return t[:utf8_floor(t, min(len(t), 72))]
	}
	return tfmt("Page %d", page)
}

// utf8_floor backs a byte count off to the start of a character, so a label
// cut at 72 bytes never ends in half of one.
utf8_floor :: proc(s: string, n: int) -> int {
	k := n
	for k > 0 && k < len(s) && (s[k] & 0xC0) == 0x80 {
		k -= 1
	}
	return k
}

reader_highlight :: proc(r: ^Reader) {
	if !r.book.open || r.cur < 0 || !format_is_reflowable(r.book.format) {
		reader_say(r, "Highlights need a reflowable book")
		return
	}
	if r.sel_block < 0 || r.sel_b <= r.sel_a {
		reader_say(r, "Select some words first: drag across them")
		return
	}
	// A highlight over an existing one removes it, which is how every reader
	// behaves and saves inventing a delete gesture. The selection on screen
	// becomes a range; the rest is the calls `reader highlight` makes.
	if k := marks_find_highlight(&r.lib, r.cur, r.sel_block, r.sel_a, r.sel_b); k >= 0 {
		marks_remove(&r.lib, r.cur, k)
		reader_say(r, "Highlight removed")
		return
	}
	marks_add_highlight(
		&r.lib,
		r.cur,
		r.chapter,
		r.sel_block,
		r.sel_a,
		r.sel_b,
		range_text(&r.book.doc, r.sel_block, r.sel_a, r.sel_b, context.temp_allocator),
	)
	r.sel_block = -1
	reader_say(r, "Highlighted")
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

reader_run_search :: proc(r: ^Reader) {
	if !r.book.open {
		return
	}
	book_search(&r.book, &r.search, string(r.qbuf[:]))
	if len(r.search.hits) > 0 {
		reader_show_hit(r, 0)
	}
}

reader_show_hit :: proc(r: ^Reader, i: int) {
	if i < 0 || i >= len(r.search.hits) {
		return
	}
	r.search.sel = i
	h := r.search.hits[i]
	if format_is_reflowable(r.book.format) {
		reader_goto_block(r, h.block)
		r.pd.hit_block = h.block
		r.pd.hit_start = h.start
		r.pd.hit_end = h.end
	} else {
		reader_goto_page(r, h.page)
	}
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

bench :: proc(path: string) {
	lib: Library
	library_init(&lib)
	defer library_destroy(&lib)

	off := p.offscreen_create(1180, 800)
	defer p.offscreen_destroy(off)
	fonts := bench_fonts(off)

	o := Reflow_Opts {
		size    = 17,
		line    = 1.62,
		measure = 640,
		page_h  = 660,
		justify = false,
		para    = .Indented,
	}

	b: Book
	t0 := time.now()
	if !book_open(&b, path, fonts, library_cache_dir(&lib), o) {
		fmt.eprintfln("reader --bench: %s", b.err)
		return
	}
	open_ms := time.duration_milliseconds(time.since(t0))
	defer book_close(&b)

	fmt.printfln("file        %s", path_base(path))
	fmt.printfln("format      %s", format_name(b.format))
	fmt.printfln("open        %.1f ms (parse %.1f ms)", open_ms, b.parse_ms)

	if !format_is_reflowable(b.format) {
		fmt.printfln("pages       %d", b.fixed.pages)
		t := time.now()
		img, ok := fixed_rasterise_public(b.fixed.kind, b.fixed.path, library_cache_dir(&lib), 1, 110)
		fmt.printfln(
			"raster p1   %.1f ms (%v)",
			time.duration_milliseconds(time.since(t)),
			ok ? "ok" : "failed",
		)
		if ok {
			fmt.printfln("page px     %d x %d = %.1f MB", img.w, img.h, f32(img.w * img.h * 4) / 1e6)
			p.image_destroy(&img)
		}
		t2 := time.now()
		fixed_load_text(&b.fixed)
		fmt.printfln("text layer  %.1f ms", time.duration_milliseconds(time.since(t2)))
		return
	}

	fmt.printfln("chapters    %d", len(b.doc.chapters))
	fmt.printfln("blocks      %d", len(b.doc.blocks))
	fmt.printfln("text        %.2f MB", f32(len(b.doc.text)) / 1e6)
	fmt.printfln("held        %.2f MB", f32(b.bytes_held) / 1e6)
	fmt.printfln("toc         %d entries", len(b.doc.toc))

	// First chapter, cold. Open plus this is how long it takes before the
	// reader can see a word, which is the number that matters on a tap.
	t1 := time.now()
	cl := reflow_chapter(&b.reflow, &b.doc, 0)
	first_ms := time.duration_milliseconds(time.since(t1))
	fmt.printfln(
		"chapter 1   %.2f ms cold (%d blocks wrapped, %d lines, %d pages)",
		first_ms,
		b.reflow.wrapped,
		len(cl.lines),
		cl.pages,
	)
	fmt.printfln("first page  %.1f ms from the file being named", open_ms + first_ms)

	// A type size change, which is the expensive interaction.
	for step in ([?]f32{19, 15, 17}) {
		o2 := o
		o2.size = step
		reflow_set_opts(&b.reflow, o2)
		t := time.now()
		c := reflow_chapter(&b.reflow, &b.doc, 0)
		fmt.printfln(
			"size -> %.0f   %.2f ms (%d wrapped, %d pages)",
			step,
			time.duration_milliseconds(time.since(t)),
			b.reflow.wrapped,
			c.pages,
		)
	}
	reflow_set_opts(&b.reflow, o)

	// A chapter nobody has looked at, which is what crossing a chapter
	// boundary costs.
	reflow_invalidate(&b.reflow)
	mid := len(b.doc.chapters) / 2
	t1b := time.now()
	cm := reflow_chapter(&b.reflow, &b.doc, mid)
	fmt.printfln(
		"new chapter %.2f ms cold (%d blocks, %d lines, %d pages)",
		time.duration_milliseconds(time.since(t1b)),
		b.reflow.wrapped,
		len(cm.lines),
		cm.pages,
	)
	reflow_invalidate(&b.reflow)

	// Every chapter, cold, which is the worst case a reader can provoke by
	// reading the book end to end.
	t2 := time.now()
	lines, pages := 0, 0
	for ci in 0 ..< len(b.doc.chapters) {
		c := reflow_chapter(&b.reflow, &b.doc, ci)
		lines += len(c.lines)
		pages += c.pages
	}
	all_ms := time.duration_milliseconds(time.since(t2))
	fmt.printfln("whole book  %.1f ms, %d lines, %d pages", all_ms, lines, pages)
	cache_bytes := b.reflow.lines_cached * size_of(Line) + len(b.reflow.cache) * 96
	fmt.printfln(
		"cache       %d entries, %d lines, %d hits, %d misses, about %.2f MB",
		len(b.reflow.cache),
		b.reflow.lines_cached,
		b.reflow.hits,
		b.reflow.misses,
		f32(cache_bytes) / 1e6,
	)
	fmt.printfln(
		"memory      %.2f MB document and archive + %.2f MB wrap cache = %.2f MB",
		f32(b.bytes_held) / 1e6,
		f32(cache_bytes) / 1e6,
		f32(b.bytes_held + cache_bytes) / 1e6,
	)

	// A page turn inside the chapter already on screen, which is what almost
	// every turn is: no text is measured, so it is a page index lookup.
	{
		cl0 := reflow_chapter(&b.reflow, &b.doc, 0)
		t := time.now()
		N :: 20000
		sink := 0
		for i in 0 ..< N {
			c := reflow_chapter(&b.reflow, &b.doc, 0)
			sink += len(layout_page_lines(c, i % max(1, c.pages)))
		}
		fmt.printfln(
			"turn (hot)  %.5f ms each over %d turns inside one chapter (%d pages)",
			time.duration_milliseconds(time.since(t)) / f64(N),
			N,
			cl0.pages,
		)
		_ = sink
	}

	// And reading the whole book end to end, which crosses every chapter
	// boundary and outruns the wrap cache on a long book.
	t3 := time.now()
	turns := 0
	ci := 0
	pg := 0
	for turns < 2000 {
		c := reflow_chapter(&b.reflow, &b.doc, ci)
		pg += 1
		if pg >= c.pages {
			pg = 0
			ci = (ci + 1) % len(b.doc.chapters)
		}
		turns += 1
	}
	fmt.printfln(
		"turn (cold) %.4f ms each over %d turns across every chapter",
		time.duration_milliseconds(time.since(t3)) / f64(turns),
		turns,
	)

	t4 := time.now()
	s: Search
	defer search_destroy(&s)
	book_search(&b, &s, "the")
	fmt.printfln(
		"search      %.2f ms, %d hits (capped at %d)",
		time.duration_milliseconds(time.since(t4)),
		len(s.hits),
		SEARCH_MAX,
	)
}

bench_fonts :: proc(off: ^p.Offscreen) -> ^p.Fonts {
	load_test_fonts(&off.fonts)
	return &off.fonts
}
