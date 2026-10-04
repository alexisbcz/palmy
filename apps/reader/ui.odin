// The interface: a library, a reading view for each of the two kinds of book,
// and four panels that slide over the page.
//
// The chrome follows the reading theme rather than the desktop's, because a
// sepia page inside a white window is worse than either. Everything on screen
// takes its colour from one `Palette`, so changing the theme changes one
// struct and the whole window follows.
package main

import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

READ_BAR_H :: f32(46)
READ_FOOT_H :: f32(32)
PAGE_PAD :: f32(12)
PANEL_W :: f32(348)

// ---------------------------------------------------------------------------
// Shared chrome
// ---------------------------------------------------------------------------

panel_bg :: proc(pal: Palette) -> p.Color {
	return p.mix(pal.page, pal.ink, 0.05)
}

// icon_button is a square button that takes its colour from the palette. The
// shadcn button is built for a shadcn theme; the reader has three of its own.
icon_button :: proc(
	r: ^Reader,
	ui: ^p.Ctx,
	id: string,
	ic: p.Icon,
	tip: string,
	on := false,
) -> bool {
	p.key(ui, id)
	idx := p.div(
		ui,
		"flex-row size-8 shrink-0 items-center justify-center rounded-md cursor-pointer transition",
	)
	p.focusable(ui)
	hov := p.is_hovered(ui, idx)
	foc := p.focused(ui, idx)
	s := p.style(ui, idx)
	if on {
		s.bg = p.flat(p.mix(r.pal.page, r.pal.accent, 0.18))
	} else if hov {
		s.bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.09))
	}
	if foc {
		s.ring = 2
		s.ring_col = p.fade(r.pal.accent, 0.6)
	}
	s.fg = on ? r.pal.accent : (hov ? r.pal.ink : r.pal.faint)
	p.icon(ui, ic, "size-4")
	hit := p.activated(ui, idx)
	p.end(ui)
	_ = tip
	return hit
}

text_button :: proc(
	r: ^Reader,
	ui: ^p.Ctx,
	id, label: string,
	on := false,
	extra := "",
) -> bool {
	p.key(ui, id)
	idx := p.div(
		ui,
		p.concat(
			ui,
			"flex-row shrink-0 h-7 px-2.5 items-center justify-center rounded-md cursor-pointer transition text-[12] font-medium ",
			extra,
		),
	)
	p.focusable(ui)
	hov := p.is_hovered(ui, idx)
	s := p.style(ui, idx)
	if on {
		s.bg = p.flat(p.mix(r.pal.page, r.pal.accent, 0.2))
		s.fg = r.pal.accent
	} else if hov {
		s.bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.09))
		s.fg = r.pal.ink
	} else {
		s.fg = r.pal.faint
	}
	if p.focused(ui, idx) {
		s.ring = 2
		s.ring_col = p.fade(r.pal.accent, 0.6)
	}
	p.text(ui, label, "whitespace-nowrap")
	hit := p.activated(ui, idx)
	p.end(ui)
	return hit
}

draw_toast :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.div(ui, "absolute bottom-10 left-0 right-0 flex-row justify-center z-50")
	defer p.end(ui)
	p.div(ui, "flex-row px-3.5 py-2 rounded-lg shadow-lg items-center")
	p.style(ui).bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.88))
	p.style(ui).fg = r.pal.page
	defer p.end(ui)
	p.text(ui, r.note, "text-[12.5] font-medium whitespace-nowrap")
}

// ---------------------------------------------------------------------------
// The library
// ---------------------------------------------------------------------------

LIB_CARD_W :: 168
LIB_CARD_H :: 248

draw_library :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(ui, "w-full h-full")
	p.style(ui).bg = p.flat(r.pal.page)
	p.style(ui).fg = r.pal.ink
	defer p.end(ui)

	// --- header
	p.row(ui, "w-full shrink-0 h-[60] items-center gap-3 px-5")
	p.div(ui, "flex-row size-9 items-center justify-center rounded-xl shrink-0")
	p.style(ui).bg = p.flat(p.mix(r.pal.page, r.pal.accent, 0.16))
	p.style(ui).fg = r.pal.accent
	p.icon(ui, kit.ICON_BOOK, "size-5")
	p.end(ui)
	p.col(ui, "gap-0 shrink-0")
	p.text(ui, "Library", "text-[17] font-semibold")
	p.textf(ui, "text-[11.5]", "%d book%s", len(r.lib.books), len(r.lib.books) == 1 ? "" : "s")
	p.style(ui).fg = r.pal.faint
	p.end(ui)
	p.spacer(ui)
	if text_button(r, ui, "open", "Open a book...", false, "h-8 px-3 text-[12.5]") {
		reader_pick(r)
	}
	if r.book.open {
		if text_button(r, ui, "resume", "Resume reading", true, "h-8 px-3 text-[12.5]") {
			r.view = .Reading
		}
	}
	p.end(ui)

	p.div(ui, "w-full h-px shrink-0")
	p.style(ui).bg = p.flat(r.pal.rule)
	p.end(ui)

	if len(r.lib.books) == 0 {
		draw_library_empty(r, ui)
		return
	}

	// --- the grid
	grid := p.div(ui, "flex-1 w-full overflow-scroll")
	p.row(ui, "w-full flex-wrap gap-4 p-5 items-start content-start")
	for i in 0 ..< len(r.lib.books) {
		draw_library_card(r, ui, i)
	}
	p.end(ui)
	p.end(ui)
	_ = grid
}

draw_library_empty :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3 px-10")
	defer p.end(ui)
	p.div(ui, "flex-row size-14 items-center justify-center rounded-2xl shrink-0")
	p.style(ui).bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.07))
	p.style(ui).fg = r.pal.faint
	p.icon(ui, kit.ICON_BOOK, "size-7")
	p.end(ui)
	p.text(ui, "No books yet", "text-[16] font-semibold")
	p.text(
		ui,
		"Open an EPUB, MOBI, PDF or DjVu and it is added here. Nothing on your disk is searched for books.",
		"text-[12.5] text-center max-w-[380]",
	)
	p.style(ui).fg = r.pal.faint
	if text_button(r, ui, "open2", "Open a book...", true, "h-8 px-3.5 text-[12.5] mt-2") {
		reader_pick(r)
	}
}

draw_library_card :: proc(r: ^Reader, ui: ^p.Ctx, i: int) {
	library_load_cover(&r.lib, i)
	e := &r.lib.books[i]
	sel := r.lib_sel == i

	p.key(ui, e.id)
	card := p.col(
		ui,
		p.concat(
			ui,
			"shrink-0 gap-2 p-2 rounded-xl cursor-pointer transition ",
			tfmt("w-[%d]", LIB_CARD_W),
		),
	)
	p.focusable(ui)
	hov := p.is_hovered(ui, card)
	s := p.style(ui, card)
	if sel || p.focused(ui, card) {
		s.bg = p.flat(p.mix(r.pal.page, r.pal.accent, 0.12))
		s.ring = 2
		s.ring_col = p.fade(r.pal.accent, 0.55)
	} else if hov {
		s.bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.06))
	}
	defer p.end(ui)

	if p.clickable(ui, card) {
		r.lib_sel = i
	}
	if p.activated(ui, card) {
		r.lib_sel = i
		if e.missing {
			reader_say(r, tfmt("%s is no longer at that path", path_base(e.path)))
		} else {
			r.open_next = strings.clone(e.path)
		}
	}

	// --- cover
	p.div(ui, "w-full h-[196] rounded-lg overflow-hidden relative shrink-0")
	p.style(ui).bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.1))
	if e.cover.w > 0 {
		p.image(ui, e.cover, "w-full h-full", .Cover)
	} else {
		p.col(ui, "w-full h-full items-center justify-center gap-1.5 px-3")
		p.style(ui).fg = r.pal.faint
		p.icon(ui, format_icon(e.format), "size-6")
		p.text(ui, format_name(e.format), "text-[10.5] font-semibold tracking-wide")
		p.end(ui)
	}
	// Progress, drawn over the bottom of the cover: it is the one number a
	// library needs to show and the cover is where the eye already is.
	if e.frac > 0.002 {
		p.div(ui, "absolute bottom-0 left-0 right-0 h-[3]")
		p.style(ui).bg = p.flat(p.fade(r.pal.ink, 0.25))
		p.div(ui, "h-full rounded-r-sm")
		p.style(ui).w = p.pct(clamp(e.frac, 0.01, 1))
		p.style(ui).bg = p.flat(r.pal.accent)
		p.end(ui)
		p.end(ui)
	}
	if e.missing {
		p.div(ui, "absolute top-1.5 right-1.5 px-1.5 py-0.5 rounded")
		p.style(ui).bg = p.flat(p.hex(0xb91c1c))
		p.text(ui, "missing", "text-[9.5] font-semibold text-white")
		p.end(ui)
	}
	p.end(ui)

	// --- title and author
	p.col(ui, "w-full gap-0.5 px-0.5")
	p.text(ui, e.title == "" ? path_base(e.path) : e.title, "text-[12.5] font-medium truncate w-full")
	p.row(ui, "w-full items-center gap-1.5")
	p.text(ui, e.author == "" ? format_name(e.format) : e.author, "text-[11] truncate")
	p.style(ui).fg = r.pal.faint
	p.spacer(ui)
	if e.frac > 0.002 {
		p.textf(ui, "text-[10.5] font-semibold shrink-0", "%.0f%%", e.frac * 100)
		p.style(ui).fg = r.pal.accent
	}
	p.end(ui)
	p.end(ui)
}

format_icon :: proc(f: Book_Format) -> p.Icon {
	switch f {
	case .Epub, .Mobi:
		return kit.ICON_BOOK
	case .Pdf:
		return kit.ICON_FILE_TEXT
	case .Djvu:
		return kit.ICON_FILE_IMAGE
	case .Unknown:
	}
	return kit.ICON_FILE
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

draw_reading :: proc(r: ^Reader, ui: ^p.Ctx) {
	if !r.book.open {
		r.view = .Library
		draw_library(r, ui)
		return
	}

	p.col(ui, "w-full h-full relative")
	p.style(ui).bg = p.flat(r.pal.page)
	p.style(ui).fg = r.pal.ink
	defer p.end(ui)

	draw_read_bar(r, ui)

	body := p.div(ui, "flex-1 w-full relative overflow-hidden")
	if format_is_reflowable(r.book.format) {
		draw_reflow_body(r, ui)
	} else {
		draw_fixed_body(r, ui)
	}
	if r.panel != .None {
		draw_panel(r, ui)
	}
	p.end(ui)
	_ = body

	draw_read_foot(r, ui)
}

draw_read_bar :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.row(ui, p.concat(ui, "w-full shrink-0 items-center gap-1.5 px-3 ", tfmt("h-[%d]", int(READ_BAR_H))))
	defer p.end(ui)

	if icon_button(r, ui, "back", kit.ICON_ARROW_LEFT, "Library") {
		reader_close_book(r)
	}

	p.col(ui, "flex-1 gap-0 overflow-hidden")
	p.text(ui, book_title(&r.book), "text-[13] font-semibold truncate w-full")
	sub := ""
	if format_is_reflowable(r.book.format) {
		ch := ""
		if r.chapter >= 0 && r.chapter < len(r.book.doc.chapters) {
			ch = r.book.doc.chapters[r.chapter].title
		}
		if a := book_author(&r.book); a != "" {
			sub = tfmt("%s  ·  %s", a, ch)
		} else {
			sub = ch
		}
	} else {
		sub = tfmt("%s  ·  %d pages", format_name(r.book.format), r.book.fixed.pages)
		if a := book_author(&r.book); a != "" {
			sub = tfmt("%s  ·  %s", a, sub)
		}
	}
	p.text(ui, sub, "text-[11] truncate w-full")
	p.style(ui).fg = r.pal.faint
	p.end(ui)

	// The controls that make sense for this kind of book, and only those.
	if format_is_reflowable(r.book.format) {
		if text_button(r, ui, "sz-", "A-", false, "w-8") {
			reader_set_size(r, -1)
		}
		if text_button(r, ui, "sz+", "A+", false, "w-8") {
			reader_set_size(r, 1)
		}
		if icon_button(
			r,
			ui,
			"mode",
			r.set.mode == .Paged ? kit.ICON_FILE_TEXT : kit.ICON_LIST,
			"Paged or continuous",
			r.set.mode == .Continuous,
		) {
			reader_set_mode(r, r.set.mode == .Paged ? .Continuous : .Paged)
		}
	} else {
		if text_button(r, ui, "fw", "Width", r.set.fit == .Width) {
			reader_set_fit(r, .Width)
		}
		if text_button(r, ui, "fp", "Page", r.set.fit == .Page) {
			reader_set_fit(r, .Page)
		}
		if text_button(r, ui, "z-", "-", false, "w-7") {
			reader_zoom(r, 1 / 1.25)
		}
		if text_button(r, ui, "z+", "+", false, "w-7") {
			reader_zoom(r, 1.25)
		}
	}

	p.div(ui, "w-px h-5 shrink-0 mx-1")
	p.style(ui).bg = p.flat(r.pal.rule)
	p.end(ui)

	if icon_button(r, ui, "toc", kit.ICON_LIST, "Contents", r.panel == .Toc) {
		reader_toggle_panel(r, .Toc)
	}
	if icon_button(r, ui, "find", kit.ICON_SEARCH, "Search", r.panel == .Search) {
		reader_toggle_panel(r, .Search)
	}
	if icon_button(r, ui, "marks", kit.ICON_STAR, "Bookmarks", r.panel == .Marks) {
		reader_toggle_panel(r, .Marks)
	}
	if icon_button(r, ui, "set", kit.ICON_SETTINGS, "Reading settings", r.panel == .Settings) {
		reader_toggle_panel(r, .Settings)
	}
	if len(r.book.doc.notes) > 0 {
		if icon_button(r, ui, "notes", kit.ICON_INFO, "What this book got wrong", r.panel == .Notes) {
			reader_toggle_panel(r, .Notes)
		}
	}
}

draw_read_foot :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.row(
		ui,
		p.concat(ui, "w-full shrink-0 items-center gap-3 px-4 ", tfmt("h-[%d]", int(READ_FOOT_H))),
	)
	defer p.end(ui)

	frac := reader_progress(r)
	left := ""
	if format_is_reflowable(r.book.format) {
		cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
		if r.set.mode == .Paged {
			left = tfmt("Page %d of %d in this chapter", r.page + 1, max(1, cl.pages))
		} else {
			left = tfmt("Chapter %d of %d", r.chapter + 1, len(r.book.doc.chapters))
		}
	} else {
		left = tfmt("Page %d of %d", r.fpage, r.book.fixed.pages)
	}
	p.text(ui, left, "text-[11] shrink-0 whitespace-nowrap")
	p.style(ui).fg = r.pal.faint

	p.div(ui, "flex-1 h-[4] rounded-full overflow-hidden")
	p.style(ui).bg = p.flat(r.pal.rule)
	p.div(ui, "h-full rounded-full")
	p.style(ui).w = p.pct(clamp(frac, 0, 1))
	p.style(ui).bg = p.flat(r.pal.accent)
	p.end(ui)
	p.end(ui)

	p.textf(ui, "text-[11] font-semibold shrink-0 w-[40] text-right", "%.0f%%", frac * 100)
	p.style(ui).fg = r.pal.faint
}

// ---------------------------------------------------------------------------
// The reflowable page
// ---------------------------------------------------------------------------

draw_reflow_body :: proc(r: ^Reader, ui: ^p.Ctx) {
	win := p.size(ui)
	// A panel is drawn inside the window -- palmy has no popups -- so it takes
	// its width from the page rather than covering it. Text sliding under a
	// sidebar is the one thing worse than a narrower column.
	avail := max(240, win.x - (r.panel != .None ? PANEL_W : 0))
	side := avail * r.set.margin
	r.col_w = max(180, avail - 2 * side)
	r.col_h = max(120, win.y - READ_BAR_H - READ_FOOT_H - 2 * PAGE_PAD)
	reflow_set_opts(&r.book.reflow, reader_opts(r))

	d := &r.book.doc
	cl := reflow_chapter(&r.book.reflow, d, r.chapter)
	r.page = clamp(r.page, 0, max(0, cl.pages - 1))

	// Fill in the painter's state. It lives in the model because p.pixels
	// borrows it until the frame is painted.
	r.pd.fonts = &r.app.fonts
	r.pd.doc = d
	r.pd.book = &r.book
	r.pd.pal = r.pal
	r.pd.frags = cl.frags[:]
	r.pd.measure = r.col_w
	r.pd.chapter = r.chapter
	r.pd.marks = nil
	if r.cur >= 0 && r.cur < len(r.lib.books) {
		r.pd.marks = r.lib.books[r.cur].marks[:]
	}
	r.pd.sel_block = r.sel_block
	r.pd.sel_start = min(r.sel_a, r.sel_b)
	r.pd.sel_end = max(r.sel_a, r.sel_b)

	if r.set.mode == .Paged {
		r.pd.lines = layout_page_lines(cl, r.page)
		r.pd.y0 = len(r.pd.lines) > 0 ? f32(r.page) * r.col_h : 0

		p.col(ui, "h-full items-center")
		p.style(ui).w = p.px(avail)
		defer p.end(ui)
		p.div(
			ui,
			p.concat(
				ui,
				"shrink-0 relative ",
				tfmt("w-[%d] h-[%d] mt-[%d]", int(r.col_w), int(r.col_h), int(PAGE_PAD)),
			),
		)
		defer p.end(ui)
		idx := p.pixels(ui, "w-full h-full", &r.pd, draw_page)
		r.page_id = p.node_id(ui, idx)
		reader_page_mouse(r, ui, idx)
		// A click on the right or left third turns the page, which is what a
		// reader expects from a paginated book.
		return
	}

	// Continuous: palmy's own scroll container moves a tall element, so there
	// is no scroll arithmetic in the painter.
	r.pd.lines = cl.lines[:]
	r.pd.y0 = 0
	scr := p.div(ui, "h-full overflow-scroll")
	p.style(ui).w = p.px(avail)
	r.view_id = p.node_id(ui, scr)
	defer p.end(ui)
	p.col(ui, "w-full items-center")
	defer p.end(ui)
	p.div(
		ui,
		p.concat(
			ui,
			"shrink-0 relative ",
			tfmt("w-[%d] h-[%d] my-[%d]", int(r.col_w), int(max(cl.height, 10)), int(PAGE_PAD)),
		),
	)
	defer p.end(ui)
	idx := p.pixels(ui, "w-full h-full", &r.pd, draw_page)
	r.page_id = p.node_id(ui, idx)
	reader_page_mouse(r, ui, idx)
	// Keep palmy's scroll and our own idea of position in step.
	off := p.scroll_of(ui, r.view_id)
	if abs(off.y - r.scroll_y) > 0.5 {
		if r.scroll_dirty {
			p.scroll_to(ui, r.view_id, {0, r.scroll_y})
			r.scroll_dirty = false
		} else {
			r.scroll_y = off.y
		}
	} else {
		r.scroll_dirty = false
	}
}

// reader_page_mouse turns clicks and drags on the page into a selection, a
// followed link, or a page turn.
reader_page_mouse :: proc(r: ^Reader, ui: ^p.Ctx, idx: int) {
	rect := p.node_rect(ui, idx)
	if rect.w <= 0 {
		return
	}
	mp := p.mouse_pos(ui)
	inside := p.rect_contains(rect, mp.x, mp.y)
	lx, ly := mp.x - rect.x, mp.y - rect.y

	if inside {
		p.apply(ui, "cursor-text", idx)
	}

	down := p.mouse_down(ui)
	if down && inside && !r.dragging {
		r.dragging = true
		// A link wins over a selection.
		if link := page_link_at(&r.pd, lx, ly); link >= 0 {
			reader_follow_link(r, int(link))
			r.dragging = false
			return
		}
		li := page_line_at(&r.pd, lx, ly)
		if li >= 0 {
			r.sel_block = r.pd.lines[li].block
			r.sel_a = page_offset_at(&r.pd, li, lx)
			r.sel_b = r.sel_a
		} else {
			r.sel_block = -1
		}
	} else if down && r.dragging && inside {
		li := page_line_at(&r.pd, lx, ly)
		if li >= 0 && r.pd.lines[li].block == r.sel_block {
			r.sel_b = page_offset_at(&r.pd, li, lx)
		}
	} else if !down && r.dragging {
		r.dragging = false
		if r.sel_block >= 0 && abs(r.sel_b - r.sel_a) < 2 {
			// A click, not a drag: in paged mode the outer thirds turn.
			r.sel_block = -1
			if r.set.mode == .Paged {
				if lx > rect.w * 0.68 {
					reader_turn(r, 1)
				} else if lx < rect.w * 0.32 {
					reader_turn(r, -1)
				}
			}
		}
	}
}

reader_follow_link :: proc(r: ^Reader, link: int) {
	if link < 0 || link >= len(r.book.doc.links) {
		return
	}
	href := r.book.doc.links[link]
	if strings.has_prefix(href, "http:") ||
	   strings.has_prefix(href, "https:") ||
	   strings.has_prefix(href, "mailto:") {
		// No network, and no handing a URL to a browser from inside a book
		// without being asked. Say where it points and stop.
		reader_say(r, tfmt("External link: %s", href))
		return
	}
	if strings.has_prefix(href, "filepos:") {
		off := 0
		for c in transmute([]u8)href[8:] {
			if c < '0' || c > '9' {
				break
			}
			off = off * 10 + int(c - '0')
		}
		if bi := doc_anchor_pos(&r.book.doc, off); bi >= 0 {
			reader_goto_block(r, bi)
			return
		}
		reader_say(r, "That link points outside the book")
		return
	}
	base := ""
	if r.chapter >= 0 && r.chapter < len(r.book.doc.chapters) {
		base = path_dir(r.book.doc.chapters[r.chapter].path)
	}
	path, frag := split_frag(href)
	if path == "" {
		// A fragment inside the current file.
		self := r.chapter >= 0 && r.chapter < len(r.book.doc.chapters) \
			? r.book.doc.chapters[r.chapter].path \
			: ""
		if bi, ok := r.book.doc.anchors[anchor_key(self, frag, context.temp_allocator)]; ok {
			reader_goto_block(r, bi)
			return
		}
		reader_say(r, "That anchor is not in the book")
		return
	}
	if bi := doc_anchor(&r.book.doc, base, href); bi >= 0 {
		reader_goto_block(r, bi)
		return
	}
	reader_say(r, tfmt("%s is not in this book", path_base(path)))
}

// ---------------------------------------------------------------------------
// The fixed page
// ---------------------------------------------------------------------------

draw_fixed_body :: proc(r: ^Reader, ui: ^p.Ctx) {
	win := p.size(ui)
	panel := r.panel != .None ? PANEL_W : 0
	view_w := max(100, win.x - panel - 24)
	view_h := max(100, win.y - READ_BAR_H - READ_FOOT_H - 24)
	f := &r.book.fixed

	dpi := fixed_dpi(f, view_w, view_h, r.set.fit, r.set.zoom)
	fixed_want(f, r.fpage, dpi)

	img, ok, bad := fixed_page_image(f, r.fpage, dpi)

	scr := p.div(ui, "h-full overflow-scroll")
	p.style(ui).w = p.px(max(100, win.x - panel))
	r.view_id = p.node_id(ui, scr)
	defer p.end(ui)
	p.col(ui, "w-full items-center justify-start py-3 px-3 gap-3")
	defer p.end(ui)

	if ok && img.w > 0 {
		// The page is drawn at its own pixel size inside a scroll container,
		// so panning a zoomed page is palmy's scrolling rather than ours.
		w := f32(img.w)
		h := f32(img.h)
		if r.set.fit == .Page {
			s := min(view_w / w, view_h / h)
			w *= s
			h *= s
		} else if r.set.fit == .Width && w > view_w {
			s := view_w / w
			w *= s
			h *= s
		}
		p.div(
			ui,
			p.concat(ui, "shrink-0 rounded-sm overflow-hidden shadow-md ", tfmt("w-[%d] h-[%d]", int(w), int(h))),
		)
		p.style(ui).bg = p.flat(p.WHITE)
		p.image(ui, img, "w-full h-full", .Fill)
		p.end(ui)
	} else {
		// A skeleton at the page's real aspect ratio, so nothing jumps when
		// the render arrives.
		ar := f.pt_h > 0 ? f.pt_w / f.pt_h : 0.7
		h := min(view_h, view_w / max(ar, 0.2))
		w := h * ar
		p.col(
			ui,
			p.concat(
				ui,
				"shrink-0 rounded-sm items-center justify-center gap-2 ",
				tfmt("w-[%d] h-[%d]", int(w), int(h)),
			),
		)
		p.style(ui).bg = p.flat(p.mix(r.pal.page, r.pal.ink, 0.07))
		p.style(ui).fg = r.pal.faint
		if bad {
			p.icon(ui, kit.ICON_INFO, "size-6")
			p.textf(ui, "text-[12]", "Page %d could not be rendered", r.fpage)
		} else {
			sc.spinner(ui, "size-5")
			p.textf(ui, "text-[11.5]", "Rendering page %d at %d dpi", r.fpage, dpi)
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Panels
// ---------------------------------------------------------------------------

draw_panel :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(
		ui,
		p.concat(ui, "absolute top-0 right-0 bottom-0 z-30 shadow-2xl ", tfmt("w-[%d]", int(PANEL_W))),
	)
	p.style(ui).bg = p.flat(panel_bg(r.pal))
	p.style(ui).fg = r.pal.ink
	p.style(ui).border_w = {0, 0, 0, 1}
	p.style(ui).border_col = r.pal.rule
	defer p.end(ui)

	title := ""
	switch r.panel {
	case .Toc:
		title = "Contents"
	case .Search:
		title = "Search in book"
	case .Settings:
		title = format_is_reflowable(r.book.format) ? "Reading" : "View"
	case .Marks:
		title = "Bookmarks & highlights"
	case .Notes:
		title = "What this book got wrong"
	case .None:
	}

	p.row(ui, "w-full shrink-0 h-[44] items-center gap-2 px-3")
	p.text(ui, title, "text-[13] font-semibold flex-1 truncate")
	if icon_button(r, ui, "pclose", kit.ICON_X, "Close") {
		r.panel = .None
	}
	p.end(ui)
	p.div(ui, "w-full h-px shrink-0")
	p.style(ui).bg = p.flat(r.pal.rule)
	p.end(ui)

	switch r.panel {
	case .Toc:
		draw_toc_panel(r, ui)
	case .Search:
		draw_search_panel(r, ui)
	case .Settings:
		draw_settings_panel(r, ui)
	case .Marks:
		draw_marks_panel(r, ui)
	case .Notes:
		draw_notes_panel(r, ui)
	case .None:
	}
}

draw_toc_panel :: proc(r: ^Reader, ui: ^p.Ctx) {
	toc := book_toc(&r.book)
	if len(toc) == 0 {
		panel_empty(r, ui, "This book has no table of contents.")
		return
	}
	p.col(ui, "flex-1 w-full overflow-scroll py-1.5")
	defer p.end(ui)
	for e, i in toc {
		current := false
		if format_is_reflowable(r.book.format) {
			current = e.block >= 0 && chapter_of_block(&r.book.doc, e.block) == r.chapter
		} else {
			current = e.block == r.fpage
		}
		p.key(ui, tfmt("toc%d", i))
		row := p.row(
			ui,
			p.concat(
				ui,
				"w-full shrink-0 items-start gap-2 py-1.5 pr-3 cursor-pointer rounded-md transition ",
				tfmt("pl-[%d]", 12 + min(e.depth, 4) * 14),
			),
		)
		p.focusable(ui)
		hov := p.is_hovered(ui, row)
		s := p.style(ui, row)
		if r.toc_sel == i || p.focused(ui, row) {
			s.bg = p.flat(p.mix(panel_bg(r.pal), r.pal.accent, 0.14))
		} else if hov {
			s.bg = p.flat(p.mix(panel_bg(r.pal), r.pal.ink, 0.07))
		}
		s.fg = current ? r.pal.accent : r.pal.ink
		p.text(
			ui,
			e.title,
			current ? "text-[12.5] font-semibold flex-1" : "text-[12.5] flex-1",
		)
		if !format_is_reflowable(r.book.format) {
			p.textf(ui, "text-[10.5] shrink-0 pt-0.5", "%d", e.block)
			p.style(ui).fg = r.pal.faint
		} else if e.block < 0 {
			p.text(ui, "missing", "text-[10] shrink-0 pt-0.5")
			p.style(ui).fg = r.pal.faint
		}
		if p.activated(ui, row) {
			r.toc_sel = i
			if format_is_reflowable(r.book.format) {
				if e.block >= 0 {
					reader_goto_block(r, e.block)
					r.panel = .None
				} else {
					reader_say(r, "That entry points at a file the book does not contain")
				}
			} else {
				reader_goto_page(r, e.block)
				r.panel = .None
			}
		}
		p.end(ui)
	}
}

draw_search_panel :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(ui, "w-full shrink-0 p-3 gap-2")
	// Opening the panel has to put the caret in the field. A search box you
	// have to click before you can type into is a search box nobody uses from
	// the keyboard, and `/` is how everyone opens one.
	at := p.node_count(ui)
	changed, submitted := p.text_field(ui, &r.qbuf, "Find in this book")
	if r.focus_search {
		p.set_focus(ui, p.node_id(ui, at))
		r.focus_search = false
	}
	if submitted || (changed && len(r.qbuf) >= 3) {
		reader_run_search(r)
	}
	if r.search.ran {
		p.row(ui, "w-full items-center gap-2")
		if len(r.search.hits) == 0 {
			p.text(ui, "No matches", "text-[11.5]")
			p.style(ui).fg = r.pal.faint
		} else {
			p.textf(
				ui,
				"text-[11.5] flex-1",
				"%d match%s in %.1f ms%s",
				len(r.search.hits),
				len(r.search.hits) == 1 ? "" : "es",
				r.search.ms,
				len(r.search.hits) >= SEARCH_MAX ? " (capped)" : "",
			)
			p.style(ui).fg = r.pal.faint
			if text_button(r, ui, "prev", "Prev", false, "h-6 px-2") {
				reader_show_hit(r, max(0, r.search.sel - 1))
			}
			if text_button(r, ui, "next", "Next", false, "h-6 px-2") {
				reader_show_hit(r, min(len(r.search.hits) - 1, r.search.sel + 1))
			}
		}
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "flex-1 w-full overflow-scroll px-2 pb-2 gap-1")
	defer p.end(ui)
	for h, i in r.search.hits {
		p.key(ui, tfmt("hit%d", i))
		row := p.col(ui, "w-full shrink-0 gap-0.5 px-2 py-1.5 rounded-md cursor-pointer transition")
		p.focusable(ui)
		s := p.style(ui, row)
		if r.search.sel == i || p.focused(ui, row) {
			s.bg = p.flat(p.mix(panel_bg(r.pal), r.pal.accent, 0.14))
		} else if p.is_hovered(ui, row) {
			s.bg = p.flat(p.mix(panel_bg(r.pal), r.pal.ink, 0.07))
		}
		loc := ""
		if format_is_reflowable(r.book.format) {
			ci := clamp(h.chapter, 0, max(0, len(r.book.doc.chapters) - 1))
			loc = len(r.book.doc.chapters) > 0 ? r.book.doc.chapters[ci].title : ""
		} else {
			loc = tfmt("Page %d", h.page)
		}
		p.text(ui, loc, "text-[10.5] font-semibold truncate w-full")
		p.style(ui).fg = r.pal.faint
		p.text(ui, h.line, "text-[12] w-full")
		if p.activated(ui, row) {
			reader_show_hit(r, i)
		}
		p.end(ui)
	}
}

draw_marks_panel :: proc(r: ^Reader, ui: ^p.Ctx) {
	if r.cur < 0 {
		panel_empty(r, ui, "Nothing yet.")
		return
	}
	marks := r.lib.books[r.cur].marks[:]

	p.row(ui, "w-full shrink-0 px-3 py-2 gap-2")
	if text_button(r, ui, "bm", "Bookmark this page", false, "h-7 px-2.5") {
		reader_toggle_bookmark(r)
	}
	if format_is_reflowable(r.book.format) {
		if text_button(r, ui, "hl", "Highlight selection", false, "h-7 px-2.5") {
			reader_highlight(r)
		}
	}
	p.end(ui)

	if len(marks) == 0 {
		panel_empty(
			r,
			ui,
			"No bookmarks or highlights. Press B to bookmark, drag across words and press H to highlight.",
		)
		return
	}

	p.col(ui, "flex-1 w-full overflow-scroll px-2 pb-2 gap-1")
	defer p.end(ui)
	for m, i in marks {
		p.key(ui, tfmt("mk%d", i))
		row := p.row(ui, "w-full shrink-0 items-start gap-2 px-2 py-1.5 rounded-md cursor-pointer transition")
		p.focusable(ui)
		s := p.style(ui, row)
		if r.mark_sel == i || p.focused(ui, row) {
			s.bg = p.flat(p.mix(panel_bg(r.pal), r.pal.accent, 0.14))
		} else if p.is_hovered(ui, row) {
			s.bg = p.flat(p.mix(panel_bg(r.pal), r.pal.ink, 0.07))
		}
		p.div(ui, "flex-row size-5 items-center justify-center shrink-0 mt-0.5")
		p.style(ui).fg = m.kind == .Highlight ? r.pal.accent : r.pal.faint
		p.icon(ui, m.kind == .Highlight ? kit.ICON_PENCIL : kit.ICON_STAR, "size-3.5")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 overflow-hidden")
		p.text(ui, m.text == "" ? "(no text)" : m.text, "text-[12] w-full")
		loc := format_is_reflowable(r.book.format) \
			? tfmt("Chapter %d", m.chapter + 1) \
			: tfmt("Page %d", m.page)
		p.text(ui, loc, "text-[10.5]")
		p.style(ui).fg = r.pal.faint
		p.end(ui)
		if p.activated(ui, row) {
			r.mark_sel = i
			if format_is_reflowable(r.book.format) {
				reader_goto_block(r, m.block)
			} else {
				reader_goto_page(r, m.page)
			}
			r.panel = .None
		}
		p.end(ui)
	}
}

draw_notes_panel :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(ui, "flex-1 w-full overflow-scroll p-3 gap-2")
	defer p.end(ui)
	p.text(
		ui,
		"The book opened, and these are the things in it that are not what the format says they should be. Shown rather than hidden, because a chapter missing from the contents is better explained than silently absent.",
		"text-[11.5] w-full",
	)
	p.style(ui).fg = r.pal.faint
	for n in r.book.doc.notes {
		p.row(ui, "w-full shrink-0 items-start gap-2 py-1")
		p.div(ui, "size-1.5 rounded-full shrink-0 mt-1.5")
		p.style(ui).bg = p.flat(r.pal.faint)
		p.end(ui)
		p.text(ui, n, "text-[12] flex-1")
		p.end(ui)
	}
}

panel_empty :: proc(r: ^Reader, ui: ^p.Ctx, text: string) {
	p.col(ui, "flex-1 w-full items-center justify-center px-6")
	defer p.end(ui)
	p.text(ui, text, "text-[12] text-center")
	p.style(ui).fg = r.pal.faint
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

draw_settings_panel :: proc(r: ^Reader, ui: ^p.Ctx) {
	p.col(ui, "flex-1 w-full overflow-scroll p-3 gap-4")
	defer p.end(ui)

	// The theme applies to both kinds of book: it is the window, not the text.
	setting_label(r, ui, "Theme")
	p.row(ui, "w-full shrink-0 gap-1.5")
	for t in Theme {
		p.key(ui, tfmt("th%d", int(t)))
		if text_button(r, ui, tfmt("th%d", int(t)), theme_name(t), r.set.theme == t, "flex-1 h-8") {
			reader_set_theme(r, t)
		}
	}
	p.end(ui)

	if !format_is_reflowable(r.book.format) {
		setting_note(
			r,
			ui,
			"This is a fixed-page document: every page is a picture the author laid out, so there is no type size to change and no text to re-wrap. What there is instead is how big to draw the page.",
		)
		setting_label(r, ui, "Fit")
		p.row(ui, "w-full shrink-0 gap-1.5")
		if text_button(r, ui, "sfw", "Width", r.set.fit == .Width, "flex-1 h-8") {
			reader_set_fit(r, .Width)
		}
		if text_button(r, ui, "sfp", "Whole page", r.set.fit == .Page, "flex-1 h-8") {
			reader_set_fit(r, .Page)
		}
		if text_button(r, ui, "sfz", tfmt("%.0f%%", r.set.zoom * 100), r.set.fit == .Zoom, "flex-1 h-8") {
			reader_set_fit(r, .Zoom)
		}
		p.end(ui)
		setting_label(r, ui, tfmt("Zoom  ·  %.0f%%", r.set.zoom * 100))
		p.row(ui, "w-full shrink-0 gap-1.5")
		if text_button(r, ui, "zo", "Smaller", false, "flex-1 h-8") {
			reader_zoom(r, 1 / 1.25)
		}
		if text_button(r, ui, "zi", "Bigger", false, "flex-1 h-8") {
			reader_zoom(r, 1.25)
		}
		p.end(ui)
		f := &r.book.fixed
		setting_note(
			r,
			ui,
			tfmt(
				"%d pages, %.0f x %.0f pt. Rendered by %s; %d pages rasterised this session, %.0f ms each.",
				f.pages,
				f.pt_w,
				f.pt_h,
				f.kind == .Pdf ? "pdftoppm" : "ddjvu",
				f.renders,
				f.renders > 0 ? f.total_ms / f64(f.renders) : 0,
			),
		)
		return
	}

	setting_label(r, ui, tfmt("Type size  ·  %.0f px", r.set.size))
	p.row(ui, "w-full shrink-0 gap-1.5")
	if text_button(r, ui, "s-", "Smaller", false, "flex-1 h-8") {
		reader_set_size(r, -1)
	}
	if text_button(r, ui, "s+", "Bigger", false, "flex-1 h-8") {
		reader_set_size(r, 1)
	}
	p.end(ui)

	setting_label(r, ui, tfmt("Line height  ·  %.2f", r.set.line))
	p.row(ui, "w-full shrink-0 gap-1.5")
	if text_button(r, ui, "l-", "Tighter", false, "flex-1 h-8") {
		reader_set_line(r, -0.06)
	}
	if text_button(r, ui, "l+", "Looser", false, "flex-1 h-8") {
		reader_set_line(r, 0.06)
	}
	p.end(ui)

	setting_label(r, ui, tfmt("Margins  ·  %.0f%%", r.set.margin * 100))
	p.row(ui, "w-full shrink-0 gap-1.5")
	if text_button(r, ui, "m-", "Narrower", false, "flex-1 h-8") {
		reader_set_margin(r, -0.015)
	}
	if text_button(r, ui, "m+", "Wider", false, "flex-1 h-8") {
		reader_set_margin(r, 0.015)
	}
	p.end(ui)

	setting_label(r, ui, "Paragraphs")
	p.row(ui, "w-full shrink-0 gap-1.5")
	if text_button(r, ui, "pi", "Indented", r.set.para == .Indented, "flex-1 h-8") {
		reader_set_para(r, .Indented)
	}
	if text_button(r, ui, "ps", "Spaced", r.set.para == .Spaced, "flex-1 h-8") {
		reader_set_para(r, .Spaced)
	}
	p.end(ui)

	setting_label(r, ui, "Lines")
	p.row(ui, "w-full shrink-0 gap-1.5")
	if text_button(r, ui, "jr", "Ragged right", !r.set.justify, "flex-1 h-8") {
		reader_set_justify(r, false)
	}
	if text_button(r, ui, "jj", "Justified", r.set.justify, "flex-1 h-8") {
		reader_set_justify(r, true)
	}
	p.end(ui)

	setting_label(r, ui, "Flow")
	p.row(ui, "w-full shrink-0 gap-1.5")
	if text_button(r, ui, "mp", "Paged", r.set.mode == .Paged, "flex-1 h-8") {
		reader_set_mode(r, .Paged)
	}
	if text_button(r, ui, "mc", "Continuous", r.set.mode == .Continuous, "flex-1 h-8") {
		reader_set_mode(r, .Continuous)
	}
	p.end(ui)

	cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
	setting_note(
		r,
		ui,
		tfmt(
			"%d chapters, %d blocks, %.0f KB of text. This chapter: %d lines over %d pages, laid out in %.1f ms; %d blocks cached.",
			len(r.book.doc.chapters),
			len(r.book.doc.blocks),
			f32(len(r.book.doc.text)) / 1024,
			len(cl.lines),
			cl.pages,
			r.relayout_ms,
			len(r.book.reflow.cache),
		),
	)
}

setting_label :: proc(r: ^Reader, ui: ^p.Ctx, text: string) {
	p.text(ui, text, "text-[11] font-semibold shrink-0 w-full")
	p.style(ui).fg = r.pal.faint
}

setting_note :: proc(r: ^Reader, ui: ^p.Ctx, text: string) {
	p.text(ui, text, "text-[11] w-full shrink-0")
	p.style(ui).fg = r.pal.faint
}

reader_toggle_panel :: proc(r: ^Reader, which: Panel) {
	r.panel = r.panel == which ? .None : which
	r.focus_search = r.panel == .Search
	if r.panel == .Toc {
		// Open the contents on the entry you are reading.
		toc := book_toc(&r.book)
		for e, i in toc {
			if format_is_reflowable(r.book.format) {
				if e.block >= 0 && chapter_of_block(&r.book.doc, e.block) == r.chapter {
					r.toc_sel = i
					break
				}
			} else if e.block <= r.fpage {
				r.toc_sel = i
			}
		}
	}
}

READER_FILTERS := [?]kit.Pick_Filter {
	{"Books", {"epub", "mobi", "azw", "azw3", "prc", "pdf", "djvu", "djv"}},
	{"EPUB", {"epub"}},
	{"MOBI", {"mobi", "azw", "azw3", "prc"}},
	{"PDF", {"pdf"}},
	{"DjVu", {"djvu", "djv"}},
	kit.PICK_DOCS,
	kit.PICK_ALL,
}

reader_pick :: proc(r: ^Reader) {
	kit.pick_begin(
		&r.pick,
		.Open_File,
		{title = "Open a book", filters = READER_FILTERS[:], confirm = "Open"},
	)
}
