// Fixed-page documents: PDF through poppler, DjVu through djvulibre.
//
// Writing a PDF *renderer* is a far larger job than writing a PDF *writer* —
// this repository already has the writer, in `apps/docs/pdf.odin`, and it is a
// few hundred lines; a renderer is font programs, shading dictionaries,
// transparency groups and a decade of other people's bugs. The media apps here
// already shell out to ffmpeg for the same reason, so this shells out to the
// real renderers:
//
//   PDF    pdftoppm rasterises a page to PNG, pdftotext gives the text layer
//          for search, pdfinfo gives the page count and page size, and
//          pdftohtml -xml gives the outline with its page numbers.
//   DjVu   ddjvu rasterises to PPM (which stb_image reads, so no extra
//          decoder), djvused gives the page count, the page size and the
//          outline, and djvutxt gives the text layer.
//
// Rasterising is slow enough to be visible — tens to hundreds of milliseconds
// a page — so none of it happens on the UI thread. One worker owns the
// subprocesses, the UI asks for what it wants to show and gets a skeleton
// until the answer arrives, and the pages either side are rendered ahead so
// that a page turn is a cache hit.
//
// Ownership: the worker fills a handoff list, the UI *moves* images out of it
// under the lock, and after that the UI owns those pixels. Anything still in
// the list was never handed out, so shutdown can free it.
package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import p "palmy:."

Fixed_Kind :: enum u8 {
	None,
	Pdf,
	Djvu,
}

Rendered :: struct {
	page: int,
	dpi:  int,
	img:  p.Image,
	ms:   f64,
	used: u64,
	bad:  bool,
}

Req :: struct {
	page: int,
	dpi:  int,
	rank: int, // lower renders first
}

FIXED_CACHE :: 10

Fixed :: struct {
	kind:    Fixed_Kind,
	path:    string,
	pages:   int,
	pt_w:    f32, // first page size in points, for the fit calculations
	pt_h:    f32,
	title:   string,
	author:  string,
	outline: [dynamic]Toc_Entry, // `block` holds a 1-based page number
	err:     string,

	// --- shared with the worker
	mu:      sync.Mutex,
	sem:     sync.Sema,
	quit:    bool,
	worker:  ^thread.Thread,
	reqs:    [dynamic]Req,
	done:    [dynamic]Rendered,
	working: bool,
	tmp_dir: string,

	// --- UI only
	cache:   [dynamic]Rendered,
	clock:   u64,
	renders: int,
	total_ms: f64,
	last_ms: f64,

	// --- the text layer, extracted once on first search
	text:    [dynamic]string,
	text_ok: bool,
}

fixed_is_fixed_path :: proc(path: string) -> Fixed_Kind {
	switch path_ext_lower(path) {
	case "pdf":
		return .Pdf
	case "djvu", "djv":
		return .Djvu
	}
	return .None
}

// fixed_open probes the document. It does not render anything: the first page
// is asked for by the UI, which is also what keeps opening a 900-page scan
// instant.
fixed_open :: proc(f: ^Fixed, path: string, tmp_dir: string) -> (ok: bool, err: string) {
	f.kind = fixed_is_fixed_path(path)
	if f.kind == .None {
		return false, "not a PDF or DjVu file"
	}

	// A file that does not exist, or is zero bytes, must be reported here
	// rather than as a renderer that produces nothing.
	fi, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		return false, tfmt("%s does not exist", path_base(path))
	}
	if fi.size == 0 {
		return false, tfmt("%s is zero bytes", path_base(path))
	}

	// Check the signature, so a .pdf that is actually an HTML error page is
	// reported as such instead of making poppler complain.
	if head, herr := read_head(path, 16); herr == "" {
		switch f.kind {
		case .Pdf:
			if !strings.has_prefix(string(head), "%PDF") {
				return false, tfmt("%s does not start with %%PDF", path_base(path))
			}
		case .Djvu:
			if len(head) < 12 || string(head[0:4]) != "AT&T" {
				return false, tfmt("%s is not a DjVu file (no AT&TFORM header)", path_base(path))
			}
		case .None:
		}
	}

	f.path = strings.clone(path)
	f.tmp_dir = strings.clone(tmp_dir)
	f.outline = make([dynamic]Toc_Entry, 0, 16)
	f.reqs = make([dynamic]Req, 0, 8)
	f.done = make([dynamic]Rendered, 0, 8)
	f.cache = make([dynamic]Rendered, 0, FIXED_CACHE)
	f.text = make([dynamic]string, 0, 8)

	switch f.kind {
	case .Pdf:
		if perr := pdf_probe(f); perr != "" {
			return false, perr
		}
	case .Djvu:
		if derr := djvu_probe(f); derr != "" {
			return false, derr
		}
	case .None:
	}

	if f.pages <= 0 {
		return false, "the document reports no pages"
	}
	if f.pt_w <= 0 || f.pt_h <= 0 {
		f.pt_w, f.pt_h = 595, 842 // A4, so fit-width has something to work with
	}

	f.worker = thread.create(fixed_worker)
	f.worker.data = rawptr(f)
	thread.start(f.worker)
	return true, ""
}

fixed_destroy :: proc(f: ^Fixed) {
	if f.worker != nil {
		sync.lock(&f.mu)
		f.quit = true
		sync.unlock(&f.mu)
		sync.sema_post(&f.sem)
		thread.join(f.worker)
		thread.destroy(f.worker)
		f.worker = nil
	}
	for &r in f.done {
		if r.img.w > 0 {
			p.image_destroy(&r.img)
		}
	}
	delete(f.done)
	for &r in f.cache {
		if r.img.w > 0 {
			p.image_destroy(&r.img)
		}
	}
	delete(f.cache)
	delete(f.reqs)
	for t in f.outline {
		delete(t.title)
		delete(t.href)
	}
	delete(f.outline)
	for s in f.text {
		delete(s)
	}
	delete(f.text)
	delete(f.path)
	delete(f.tmp_dir)
	delete(f.title)
	delete(f.author)
	f^ = {}
}

// ---------------------------------------------------------------------------
// Probing
// ---------------------------------------------------------------------------

@(private = "file")
pdf_probe :: proc(f: ^Fixed) -> string {
	lines, ok := kit_lines({"pdfinfo", f.path})
	if !ok && len(lines) == 0 {
		return "pdfinfo could not read the file; it may be corrupt or encrypted"
	}
	for l in lines {
		switch {
		case strings.has_prefix(l, "Pages:"):
			if v, good := strconv.parse_int(strings.trim_space(l[6:])); good {
				f.pages = v
			}
		case strings.has_prefix(l, "Page size:"):
			rest := strings.trim_space(l[10:])
			parts := strings.fields(rest, context.temp_allocator)
			if len(parts) >= 3 {
				if w, g1 := strconv.parse_f32(parts[0]); g1 {
					f.pt_w = w
				}
				if h, g2 := strconv.parse_f32(parts[2]); g2 {
					f.pt_h = h
				}
			}
		case strings.has_prefix(l, "Title:"):
			t := strings.trim_space(l[6:])
			if t != "" {
				f.title = strings.clone(t)
			}
		case strings.has_prefix(l, "Author:"):
			t := strings.trim_space(l[7:])
			if t != "" {
				f.author = strings.clone(t)
			}
		case strings.has_prefix(l, "Encrypted:"):
			if strings.contains(l, "yes") && !strings.contains(l, "print:yes") {
				// Poppler still renders most "encrypted" PDFs (they are
				// permission-flagged, not password-protected); only a real
				// password stops it, and then pdfinfo fails outright.
			}
		}
	}
	if f.pages <= 0 {
		return "pdfinfo did not report a page count"
	}
	pdf_outline(f)
	return ""
}

// pdf_outline reads the bookmarks through pdftohtml's XML, which is the only
// poppler command line tool that emits them. Restricted to one page so the
// text layer is not generated as well.
@(private = "file")
pdf_outline :: proc(f: ^Fixed) {
	out, _ := kit_run({"pdftohtml", "-xml", "-i", "-f", "1", "-l", "1", "-stdout", f.path})
	if out == "" {
		return
	}
	at := strings.index(out, "<outline>")
	if at < 0 {
		return
	}
	x: Xml
	xml_init(&x, out[at:])
	defer xml_destroy(&x)
	depth := -1
	in_item := false
	page := 0
	buf := make([dynamic]u8, 0, 128, context.temp_allocator)
	for {
		t := xml_next(&x)
		if t.kind == .Eof {
			break
		}
		switch t.kind {
		case .Eof, .Decl:
		case .Text:
			if in_item {
				append(&buf, t.text)
			}
		case .Open, .Empty:
			switch t.name {
			case "outline":
				depth += 1
			case "item":
				in_item = true
				clear(&buf)
				page = 1
				if v, ok := xml_attr(t, "page"); ok {
					if n, good := strconv.parse_int(strings.trim_space(v)); good {
						page = n
					}
				}
			}
		case .Close:
			switch t.name {
			case "outline":
				depth = max(-1, depth - 1)
			case "item":
				if in_item {
					in_item = false
					title := strings.trim_space(string(buf[:]))
					if title != "" {
						append(
							&f.outline,
							Toc_Entry {
								title = strings.clone(title),
								depth = max(0, depth),
								block = clamp(page, 1, f.pages),
							},
						)
					}
				}
			}
		}
	}
}

@(private = "file")
djvu_probe :: proc(f: ^Fixed) -> string {
	if n, ok := kit_run({"djvused", "-e", "n", f.path}); ok {
		if v, good := strconv.parse_int(strings.trim_space(n)); good {
			f.pages = v
		}
	}
	if f.pages <= 0 {
		return "djvused could not read the page count; the file may be corrupt"
	}
	if s, ok := kit_run({"djvused", "-e", "select 1; size", f.path}); ok {
		// "width=2550 height=3300"
		for part in strings.fields(s, context.temp_allocator) {
			if strings.has_prefix(part, "width=") {
				if v, good := strconv.parse_f32(part[6:]); good {
					// DjVu sizes are pixels at the page's own resolution;
					// 300 dpi is the near-universal choice for a scan, so
					// convert to points for the fit arithmetic.
					f.pt_w = v * 72 / 300
				}
			}
			if strings.has_prefix(part, "height=") {
				if v, good := strconv.parse_f32(part[7:]); good {
					f.pt_h = v * 72 / 300
				}
			}
		}
	}
	djvu_meta(f)
	djvu_outline(f)
	return ""
}

// djvu_meta reads the annotation chunk's metadata, which is where a DjVu keeps
// a title and an author when it has them at all. Most scans have neither, and
// then the file name stands in.
@(private = "file")
djvu_meta :: proc(f: ^Fixed) {
	out, ok := kit_run({"djvused", "-e", "print-meta", f.path})
	if !ok || out == "" {
		return
	}
	for line in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(line)
		q := strings.index_byte(l, '"')
		if q < 0 || !strings.has_suffix(l, "\"") {
			continue
		}
		key := strings.to_lower(strings.trim_space(l[:q]), context.temp_allocator)
		val := strings.trim_space(l[q + 1:len(l) - 1])
		if val == "" {
			continue
		}
		switch key {
		case "title":
			if f.title == "" {f.title = strings.clone(val)}
		case "author", "creator":
			if f.author == "" {f.author = strings.clone(val)}
		}
	}
}

// djvu_outline parses djvused's s-expression outline:
//   (bookmarks ("Title" "#page" ("Sub" "#page")) ...)
@(private = "file")
djvu_outline :: proc(f: ^Fixed) {
	out, _ := kit_run({"djvused", "-e", "print-outline", f.path})
	s := strings.trim_space(out)
	if s == "" || !strings.has_prefix(s, "(") {
		return
	}
	// A tiny reader: track paren depth, and take strings in pairs. The first
	// string of a node is its title, the second its target.
	depth := 0
	i := 0
	pending := ""
	have := false
	for i < len(s) {
		c := s[i]
		switch c {
		case '(':
			depth += 1
			i += 1
		case ')':
			if have {
				have = false
				pending = ""
			}
			depth = max(0, depth - 1)
			i += 1
		case '"':
			j := i + 1
			sb := strings.builder_make(context.temp_allocator)
			for j < len(s) && s[j] != '"' {
				if s[j] == '\\' && j + 1 < len(s) {
					j += 1
				}
				strings.write_byte(&sb, s[j])
				j += 1
			}
			val := strings.to_string(sb)
			i = min(len(s), j + 1)
			if !have {
				pending = strings.clone(val, context.temp_allocator)
				have = true
			} else {
				page := 1
				t := val
				if strings.has_prefix(t, "#") {
					t = t[1:]
				}
				if n, good := strconv.parse_int(t); good {
					page = n
				}
				append(
					&f.outline,
					Toc_Entry {
						title = strings.clone(pending),
						depth = max(0, depth - 2),
						block = clamp(page, 1, f.pages),
					},
				)
				have = false
				pending = ""
			}
		case:
			i += 1
		}
	}
}

// ---------------------------------------------------------------------------
// The text layer
// ---------------------------------------------------------------------------

// fixed_load_text extracts every page's text in one subprocess call. Pages are
// separated by a form feed, which is what both tools emit.
fixed_load_text :: proc(f: ^Fixed) {
	if f.text_ok {
		return
	}
	f.text_ok = true
	raw := ""
	switch f.kind {
	case .Pdf:
		raw, _ = kit_run({"pdftotext", "-layout", f.path, "-"})
	case .Djvu:
		raw, _ = kit_run({"djvutxt", f.path})
	case .None:
	}
	if raw == "" {
		for _ in 0 ..< f.pages {
			append(&f.text, strings.clone(""))
		}
		return
	}
	parts := strings.split(raw, "\f", context.temp_allocator)
	for s in parts {
		append(&f.text, strings.clone(s))
	}
	for len(f.text) < f.pages {
		append(&f.text, strings.clone(""))
	}
}

fixed_page_text :: proc(f: ^Fixed, page: int) -> string {
	fixed_load_text(f)
	if page < 1 || page > len(f.text) {
		return ""
	}
	return f.text[page - 1]
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// fixed_want asks for a page at a zoom, plus the pages either side so a turn
// in either direction is already in hand.
fixed_want :: proc(f: ^Fixed, page, dpi: int) {
	sync.lock(&f.mu)
	clear(&f.reqs)
	push :: proc(f: ^Fixed, page, dpi, rank: int) {
		if page < 1 || page > f.pages {
			return
		}
		append(&f.reqs, Req{page = page, dpi = dpi, rank = rank})
	}
	push(f, page, dpi, 0)
	push(f, page + 1, dpi, 1)
	push(f, page - 1, dpi, 2)
	push(f, page + 2, dpi, 3)
	sync.unlock(&f.mu)
	sync.sema_post(&f.sem)
}

// fixed_collect moves anything the worker finished into the UI's own cache.
// Called once a frame.
fixed_collect :: proc(f: ^Fixed) -> bool {
	got := false
	sync.lock(&f.mu)
	for r in f.done {
		fixed_cache_put(f, r)
		got = true
	}
	clear(&f.done)
	sync.unlock(&f.mu)
	return got
}

@(private = "file")
fixed_cache_put :: proc(f: ^Fixed, r: Rendered) {
	e := r
	f.clock += 1
	e.used = f.clock
	// Replace an existing entry for the same page and zoom.
	for &c, i in f.cache {
		if c.page == e.page && c.dpi == e.dpi {
			if c.img.w > 0 {
				p.image_destroy(&c.img)
			}
			f.cache[i] = e
			return
		}
	}
	if len(f.cache) >= FIXED_CACHE {
		victim := 0
		for c, i in f.cache {
			if c.used < f.cache[victim].used {
				victim = i
			}
			_ = c
		}
		if f.cache[victim].img.w > 0 {
			p.image_destroy(&f.cache[victim].img)
		}
		f.cache[victim] = e
		return
	}
	append(&f.cache, e)
}

// fixed_page_image is what the UI draws. A miss returns ok = false and the
// caller shows a skeleton; the render is already on its way.
fixed_page_image :: proc(f: ^Fixed, page, dpi: int) -> (img: p.Image, ok: bool, bad: bool) {
	for &c in f.cache {
		if c.page == page && c.dpi == dpi {
			f.clock += 1
			c.used = f.clock
			return c.img, !c.bad, c.bad
		}
	}
	// Any zoom of the right page is better than nothing while the right one
	// renders: it keeps the page on screen instead of flashing a skeleton
	// every time the zoom changes.
	best := -1
	for c, i in f.cache {
		if c.page == page && !c.bad {
			if best < 0 || abs(c.dpi - dpi) < abs(f.cache[best].dpi - dpi) {
				best = i
			}
		}
	}
	if best >= 0 {
		return f.cache[best].img, true, false
	}
	return {}, false, false
}

fixed_busy :: proc(f: ^Fixed) -> bool {
	sync.lock(&f.mu)
	defer sync.unlock(&f.mu)
	return f.working || len(f.reqs) > 0 || len(f.done) > 0
}

@(private = "file")
fixed_worker :: proc(t: ^thread.Thread) {
	f := (^Fixed)(t.data)
	for {
		sync.sema_wait(&f.sem)
		for {
			sync.lock(&f.mu)
			if f.quit {
				sync.unlock(&f.mu)
				return
			}
			// Take the highest-priority request that is not already in hand.
			pick := -1
			for r, i in f.reqs {
				if fixed_have_locked(f, r.page, r.dpi) {
					continue
				}
				if pick < 0 || r.rank < f.reqs[pick].rank {
					pick = i
				}
			}
			if pick < 0 {
				clear(&f.reqs)
				f.working = false
				sync.unlock(&f.mu)
				break
			}
			req := f.reqs[pick]
			unordered_remove(&f.reqs, pick)
			f.working = true
			path := f.path
			kind := f.kind
			tmp := f.tmp_dir
			npages := f.pages
			sync.unlock(&f.mu)

			start := time.now()
			img, good := fixed_rasterise(kind, path, tmp, req.page, req.dpi, npages)
			ms := time.duration_milliseconds(time.since(start))
			// Every argv and every captured line went into this thread's own
			// temp arena, which nothing else will reset.
			free_all(context.temp_allocator)

			sync.lock(&f.mu)
			if f.quit {
				sync.unlock(&f.mu)
				if good {
					p.image_destroy(&img)
				}
				return
			}
			append(
				&f.done,
				Rendered{page = req.page, dpi = req.dpi, img = img, ms = ms, bad = !good},
			)
			f.renders += 1
			f.total_ms += ms
			f.last_ms = ms
			sync.unlock(&f.mu)
		}
	}
}

// fixed_have_locked asks whether a page is already rendered. The worker holds
// the lock and reads the *done* list only; the UI cache is not shared, so a
// page the UI already has may be rendered once more after a zoom change. That
// costs one render and buys not having to lock the UI's cache on every draw.
@(private = "file")
fixed_have_locked :: proc(f: ^Fixed, page, dpi: int) -> bool {
	for r in f.done {
		if r.page == page && r.dpi == dpi {
			return true
		}
	}
	return false
}

// fixed_rasterise_public is the same call for the one synchronous use: the
// library's cover thumbnail, rendered once when a book is added.
fixed_rasterise_public :: proc(
	kind: Fixed_Kind,
	path, tmp: string,
	page, dpi: int,
	pages := 0,
) -> (
	img: p.Image,
	ok: bool,
) {
	return fixed_rasterise(kind, path, tmp, page, dpi, pages)
}

@(private = "file")
fixed_rasterise :: proc(
	kind: Fixed_Kind,
	path, tmp: string,
	page, dpi: int,
	pages := 0,
) -> (
	img: p.Image,
	ok: bool,
) {
	// The page range is checked here rather than trusted to the renderer.
	// pdftoppm refuses a page past the end; ddjvu renders the last page
	// instead, which would quietly show the reader the wrong page.
	if page < 1 || (pages > 0 && page > pages) {
		return {}, false
	}
	switch kind {
	case .Pdf:
		root := tfmt("%s/page-%d-%d", tmp, page, dpi)
		out := tfmt("%s.png", root)
		os.remove(out)
		_, good := kit_run(
			{
				"pdftoppm",
				"-singlefile",
				"-png",
				"-r",
				itoa_tmp(dpi),
				"-f",
				itoa_tmp(page),
				"-l",
				itoa_tmp(page),
				path,
				root,
			},
		)
		if !good {
			return {}, false
		}
		im, loaded := p.load_image(out)
		os.remove(out)
		return im, loaded
	case .Djvu:
		out := tfmt("%s/page-%d-%d.ppm", tmp, page, dpi)
		os.remove(out)
		// ddjvu takes a target box rather than a dpi, so convert through the
		// page's own size.
		_, good := kit_run(
			{
				"ddjvu",
				"-format=ppm",
				tfmt("-page=%d", page),
				tfmt("-scale=%d", clamp(dpi, 20, 600)),
				path,
				out,
			},
		)
		if !good {
			return {}, false
		}
		im, loaded := p.load_image(out)
		os.remove(out)
		return im, loaded
	case .None:
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Fit
// ---------------------------------------------------------------------------

Fit_Mode :: enum u8 {
	Width,
	Page,
	Zoom,
}

// fixed_dpi is the raster resolution for a viewport and a fit mode, quantised
// so that dragging a window edge does not re-render on every pixel.
fixed_dpi :: proc(f: ^Fixed, view_w, view_h: f32, mode: Fit_Mode, zoom: f32 = 1) -> int {
	if f.pt_w <= 0 || f.pt_h <= 0 {
		return 110
	}
	d := f32(110)
	switch mode {
	case .Width:
		d = view_w * 72 / f.pt_w
	case .Page:
		d = min(view_w * 72 / f.pt_w, view_h * 72 / f.pt_h)
	case .Zoom:
		d = 110 * zoom
	}
	// Quantise to 10 dpi steps, and keep it inside what is worth rastering.
	q := int((d + 5) / 10) * 10
	return clamp(q, 30, 400)
}

