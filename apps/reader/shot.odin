// --shots: render the reading views offscreen and write PNGs.
//
// A page can satisfy every assertion in the suite and still have its lines
// overlapping, its list markers in the gutter of the wrong column, or its
// picture on top of the paragraph after it. Reflow is geometry, and geometry
// has to be looked at, so this renders the real views through the real painter
// and writes files to open.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

shots :: proc(dir: string) {
	_ = os.make_directory_all(dir)
	if !os.exists(dir) {
		fmt.eprintfln("reader --shots: cannot create %s", dir)
		os.exit(1)
	}

	// The fixture books live beside the shots, so nothing of the user's is
	// ever rendered into a committed image.
	// These paths are cloned, not temp: `p.offscreen_end` releases the temp
	// allocator the way the windowed frame loop does, so a tprintf string
	// handed across two shots is a dangling one.
	png := make_test_png(dir)
	epub := strings.clone(tfmt("%s/generated.epub", dir))
	mobi := strings.clone(tfmt("%s/generated.mobi", dir))
	_ = gen_epub_file(epub, fixture_book(png))
	_ = gen_mobi_file(
		mobi,
		{title = "A Generated Mobipocket", author = "M. Fixture", html = MOBI_HTML, compress = true},
	)

	pdf := ""
	if docs := find_docs_bin(); docs != "" {
		md := tfmt("%s/shot.md", dir)
		pdf = strings.clone(tfmt("%s/generated.pdf", dir))
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "# A Fixed Page Document\n\n")
		strings.write_string(
			&b,
			"Every page here is a picture the author laid out, so there is no type size to change and no text to re-wrap. The reader offers fit-width, fit-page and zoom instead, and says so.\n\n",
		)
		for i in 0 ..< 24 {
			strings.write_string(
				&b,
				tfmt("Paragraph %d of the fixed-page document, rasterised by pdftoppm and cached per page and per zoom.\n\n", i + 1),
			)
		}
		strings.write_string(&b, "## A Second Section\n\nSo that the outline has more than one entry.\n")
		_ = os.write_entire_file(md, transmute([]u8)strings.to_string(b))
		if _, ok := kit_run({docs, "--convert", md, pdf}); !ok {
			pdf = ""
		}
	}

	n := 0
	// The three themes, at the type size each is shown at.
	n += shot_reading(dir, "01-epub-light", epub, {theme = .Light}, 1180, 820)
	n += shot_reading(dir, "02-epub-sepia-justified", epub, {theme = .Sepia, justify = true, size = 19}, 1180, 820)
	n += shot_reading(dir, "03-epub-dark-bigger", epub, {theme = .Dark, size = 24, line = 1.7}, 1180, 820)
	// The first chapter, which holds every block kind there is.
	n += shot_reading(dir, "04-epub-blocks", epub, {theme = .Light, chapter = 0, page = 0, size = 15}, 1180, 820)
	n += shot_reading(dir, "05-epub-blocks-p2", epub, {theme = .Light, chapter = 0, page = 1, size = 15}, 1180, 820)
	// Continuous scroll, narrow window: the awkward case for margins.
	n += shot_reading(dir, "06-epub-continuous-narrow", epub, {theme = .Sepia, mode = .Continuous, size = 16}, 760, 900)
	// Spaced paragraphs rather than indented.
	n += shot_reading(dir, "07-epub-spaced", epub, {theme = .Light, para = .Spaced, size = 17}, 1000, 760)
	// A MOBI.
	n += shot_reading(dir, "08-mobi", mobi, {theme = .Light, size = 18}, 1100, 780)
	// The panels.
	n += shot_reading(dir, "09-contents", epub, {theme = .Light, panel = .Toc}, 1180, 820)
	n += shot_reading(dir, "10-search", epub, {theme = .Light, panel = .Search, query = "ALPHA-ONE"}, 1180, 820)
	n += shot_reading(dir, "11-settings", epub, {theme = .Sepia, panel = .Settings}, 1180, 820)
	n += shot_reading(dir, "12-marks", epub, {theme = .Light, panel = .Marks, mark_demo = true}, 1180, 820)
	// The library.
	n += shot_library(dir, "13-library", epub, mobi, pdf, .Light, 1180, 820)
	n += shot_library(dir, "14-library-dark", epub, mobi, pdf, .Dark, 1180, 820)
	// Fixed-page.
	if pdf != "" {
		n += shot_reading(dir, "15-pdf-fit-width", pdf, {theme = .Light, fit = .Width}, 1180, 820)
		n += shot_reading(dir, "16-pdf-fit-page", pdf, {theme = .Dark, fit = .Page}, 1180, 820)
		n += shot_reading(dir, "17-pdf-settings", pdf, {theme = .Light, fit = .Page, panel = .Settings}, 1180, 820)
	}
	if dj := make_test_djvu(dir); dj != "" {
		n += shot_reading(dir, "18-djvu", strings.clone(dj), {theme = .Sepia, fit = .Page}, 1000, 820)
	}
	fmt.printfln("reader --shots: %d PNGs in %s", n, dir)
}

// shot_scrub_author drops the author a *generated* fixed-page document picked
// up from the machine that made it. apps/docs stamps the PDF it exports with
// the invoking user's name, and a screenshot that is checked into the
// repository must not carry the name of whoever ran the build.
shot_scrub_author :: proc(r: ^Reader) {
	if format_is_reflowable(r.book.format) {
		return
	}
	delete(r.book.doc.author)
	r.book.doc.author = strings.clone("palmy reader fixture")
	if r.cur >= 0 && r.cur < len(r.lib.books) {
		delete(r.lib.books[r.cur].author)
		r.lib.books[r.cur].author = strings.clone("palmy reader fixture")
	}
}

Shot_Opts :: struct {
	theme:     Theme,
	size:      f32,
	line:      f32,
	justify:   bool,
	para:      Para_Style,
	mode:      Read_Mode,
	fit:       Fit_Mode,
	chapter:   int,
	page:      int,
	panel:     Panel,
	query:     string,
	mark_demo: bool,
}

// shot_reading drives the real reading view through the offscreen renderer.
// It uses the same Reader struct and the same draw procedures the window does,
// so what lands in the PNG is what lands on screen.
shot_reading :: proc(dir, name, path: string, o: Shot_Opts, w, h: int) -> int {
	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_test_fonts(&off.fonts)

	r := new(Reader)
	defer free(r)
	r.cur = -1
	r.sel_block = -1
	r.qbuf = make([dynamic]u8, 0, 32)
	defer delete(r.qbuf)
	r.pd.hit_block = -1
	r.pd.sel_block = -1
	r.set = settings_default()
	r.set.theme = o.theme
	if o.size > 0 {r.set.size = o.size}
	if o.line > 0 {r.set.line = o.line}
	r.set.justify = o.justify
	r.set.para = o.para
	r.set.mode = o.mode
	r.set.fit = o.fit

	// A private library under the shots directory, so nothing of the user's
	// is read or written.
	home := tfmt("%s/state", dir)
	_ = os.make_directory_all(home)
	_ = os.set_env("PALMY_READER_HOME", home)
	library_init(&r.lib)
	defer library_destroy(&r.lib)

	// The offscreen renderer has no App, and the reading view only reaches
	// into one for its font table and its window size, so a stand-in is
	// enough: the geometry the view actually uses comes from `p.size(ui)`.
	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height = w, h
	app.fonts = off.fonts
	r.app = app

	opts := Reflow_Opts {
		size    = r.set.size,
		line    = r.set.line,
		measure = f32(w) * (1 - 2 * r.set.margin),
		page_h  = f32(h) - READ_BAR_H - READ_FOOT_H - 2 * PAGE_PAD,
		justify = r.set.justify,
		para    = r.set.para,
	}
	if !book_open(&r.book, path, &app.fonts, home, opts) {
		fmt.eprintfln("reader --shots: %s: %s", name, r.book.err)
		return 0
	}
	defer book_close(&r.book)
	r.cur = library_add(&r.lib, path, &r.book)
	shot_scrub_author(r)
	r.view = .Reading
	r.panel = o.panel
	r.chapter = o.chapter
	r.page = o.page
	r.fpage = 1

	if o.mark_demo && format_is_reflowable(r.book.format) {
		// Two marks, so the panel has something true in it.
		e := &r.lib.books[r.cur]
		append(
			&e.marks,
			Mark{kind = .Bookmark, chapter = 0, block = 0, text = strings.clone("Chapter One: The Measure")},
		)
		for bi in 0 ..< len(r.book.doc.blocks) {
			text := block_text(&r.book.doc, bi)
			if at := strings.index(text, "measure is the width"); at >= 0 {
				append(
					&e.marks,
					Mark {
						kind = .Highlight,
						chapter = 0,
						block = bi,
						off = at,
						end = at + len("measure is the width"),
						text = strings.clone("measure is the width"),
					},
				)
				r.chapter = 0
				break
			}
		}
	}
	defer search_destroy(&r.search)
	if o.query != "" {
		append(&r.qbuf, o.query)
		book_search(&r.book, &r.search, o.query)
		if len(r.search.hits) > 0 {
			h0 := r.search.hits[0]
			if format_is_reflowable(r.book.format) {
				r.pd.hit_block = h0.block
				r.pd.hit_start = h0.start
				r.pd.hit_end = h0.end
				reader_goto_block(r, h0.block)
			}
		}
	}

	// Fixed-page documents need their first page rendered before the frame,
	// since the worker would otherwise still be busy when the PNG is written.
	if !format_is_reflowable(r.book.format) {
		dpi := fixed_dpi(
			&r.book.fixed,
			f32(w) - 24,
			f32(h) - READ_BAR_H - READ_FOOT_H - 24,
			r.set.fit,
			r.set.zoom,
		)
		if img, ok := fixed_rasterise_public(
			r.book.fixed.kind,
			r.book.fixed.path,
			home,
			1,
			dpi,
			r.book.fixed.pages,
		); ok {
			r.book.fixed.cache = make([dynamic]Rendered, 0, 4)
			append(&r.book.fixed.cache, Rendered{page = 1, dpi = dpi, img = img, used = 1})
		}
	}

	// Two frames: hover and hit testing run against the previous one, so the
	// second frame is the settled picture.
	for _ in 0 ..< 2 {
		if format_is_reflowable(r.book.format) {
			for book_images_pending(&r.book) {
				book_pump_images(&r.book, 8)
			}
			for i in 0 ..< CHAPTER_CACHE {
				r.book.reflow.chaps[i].valid = false
			}
		}
		ui := p.offscreen_begin(off)
		r.pal = palette_of(r.set.theme)
		reader_body(r, ui)
		p.offscreen_end(off)
	}

	out := tfmt("%s/%s.png", dir, name)
	if !p.offscreen_write_png(off, out) {
		fmt.eprintfln("reader --shots: could not write %s", out)
		return 0
	}
	fmt.printfln("  %s", out)
	return 1
}

shot_library :: proc(dir, name, epub, mobi, pdf: string, theme: Theme, w, h: int) -> int {
	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_test_fonts(&off.fonts)

	r := new(Reader)
	defer free(r)
	r.cur = -1
	r.sel_block = -1
	r.pd.hit_block = -1
	r.pd.sel_block = -1
	r.set = settings_default()
	r.set.theme = theme
	r.qbuf = make([dynamic]u8, 0, 8)
	defer delete(r.qbuf)

	home := tfmt("%s/state", dir)
	_ = os.make_directory_all(home)
	_ = os.set_env("PALMY_READER_HOME", home)
	library_init(&r.lib)
	defer library_destroy(&r.lib)

	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height = w, h
	app.fonts = off.fonts
	r.app = app

	// Add each generated book, extract its cover, and give it a plausible
	// amount of progress so the cards show the thing a library is for.
	fracs := [?]f32{0.37, 0.08, 0.72}
	paths := [?]string{epub, mobi, pdf}
	k := 0
	for path in paths {
		if path == "" {
			continue
		}
		b: Book
		if !book_open(&b, path, &app.fonts, home, Reflow_Opts{size = 17, line = 1.6, measure = 600, page_h = 600}) {
			continue
		}
		i := library_add(&r.lib, path, &b)
		library_store_cover(&r.lib, i, &b)
		r.lib.books[i].frac = fracs[k % len(fracs)]
		if !format_is_reflowable(b.format) {
			delete(r.lib.books[i].author)
			r.lib.books[i].author = strings.clone("palmy reader fixture")
		}
		book_close(&b)
		k += 1
	}
	r.view = .Library
	r.lib_sel = 0

	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		r.pal = palette_of(r.set.theme)
		reader_body(r, ui)
		p.offscreen_end(off)
	}
	out := tfmt("%s/%s.png", dir, name)
	if !p.offscreen_write_png(off, out) {
		return 0
	}
	fmt.printfln("  %s", out)
	return 1
}
