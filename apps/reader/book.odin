// One book, whichever of the four formats it is.
//
// The asymmetry is the design, not an accident of it: EPUB and MOBI are
// *reflowable* — the text has no page of its own, so the window and the
// reader's type size decide where the lines fall — while PDF and DjVu are
// *fixed* — the page is the author's, and the only questions are how big to
// draw it and which part to look at. Those are different reading experiences
// and the interface says so, rather than pretending a scanned page can have
// its font size changed.
//
// What they share is this struct, the library entry, the position that gets
// written to disk, search, and bookmarks.
package main

import "core:strings"
import "core:time"
import p "palmy:."

Book_Format :: enum u8 {
	Unknown,
	Epub,
	Mobi,
	Pdf,
	Djvu,
}

format_name :: proc(f: Book_Format) -> string {
	switch f {
	case .Epub:
		return "EPUB"
	case .Mobi:
		return "MOBI"
	case .Pdf:
		return "PDF"
	case .Djvu:
		return "DjVu"
	case .Unknown:
	}
	return "?"
}

format_of_path :: proc(path: string) -> Book_Format {
	switch path_ext_lower(path) {
	case "epub":
		return .Epub
	case "mobi", "prc", "azw", "azw3", "pdb":
		return .Mobi
	case "pdf":
		return .Pdf
	case "djvu", "djv":
		return .Djvu
	}
	return .Unknown
}

format_is_reflowable :: proc(f: Book_Format) -> bool {
	return f == .Epub || f == .Mobi
}

Book :: struct {
	path:   string,
	format: Book_Format,
	open:   bool,
	err:    string,

	// --- reflowable
	doc:    Doc,
	epub:   Epub,
	mobi:   Mobi,
	reflow: Reflow,
	imgs:   map[i32]p.Image,
	img_queue: [dynamic]i32,

	// --- fixed
	fixed:  Fixed,

	// --- instrumentation, reported in the status bar and the selftest
	open_ms:   f64,
	parse_ms:  f64,
	bytes_held: int,
}

book_close :: proc(b: ^Book) {
	if format_is_reflowable(b.format) {
		reflow_destroy(&b.reflow)
		for _, &im in b.imgs {
			p.image_destroy(&im)
		}
		delete(b.imgs)
		delete(b.img_queue)
		if b.format == .Epub {
			epub_destroy(&b.epub)
		} else {
			mobi_destroy(&b.mobi)
		}
		doc_destroy(&b.doc)
	} else {
		fixed_destroy(&b.fixed)
	}
	delete(b.path)
	delete(b.err)
	b^ = {}
}

// book_open reads whatever the path is. `fonts` is needed because a
// reflowable book measures text as it lays out; `tmp` is where the fixed-page
// renderers put their intermediate images.
book_open :: proc(b: ^Book, path: string, fonts: ^p.Fonts, tmp: string, o: Reflow_Opts) -> bool {
	t0 := time.now()
	b^ = {}
	b.path = strings.clone(path)
	b.format = format_of_path(path)

	if b.format == .Unknown {
		// Go by content rather than by name, because books arrive with the
		// wrong extension constantly.
		if head, herr := read_head(path, 80); herr == "" {
			switch {
			case len(head) >= 4 && string(head[0:4]) == "%PDF":
				b.format = .Pdf
			case len(head) >= 4 && string(head[0:4]) == "AT&T":
				b.format = .Djvu
			case len(head) >= 2 && head[0] == 'P' && head[1] == 'K':
				b.format = .Epub
			case len(head) >= 68 && string(head[60:68]) == "BOOKMOBI":
				b.format = .Mobi
			}
		}
	}
	if b.format == .Unknown {
		b.err = strings.clone("that file is not an EPUB, MOBI, PDF or DjVu")
		return false
	}

	ok := false
	err := ""
	switch b.format {
	case .Epub:
		b.imgs = make(map[i32]p.Image)
		b.img_queue = make([dynamic]i32, 0, 8)
		ok, err = epub_open(&b.epub, &b.doc, path)
	case .Mobi:
		b.imgs = make(map[i32]p.Image)
		b.img_queue = make([dynamic]i32, 0, 8)
		ok, err = mobi_open(&b.mobi, &b.doc, path)
	case .Pdf, .Djvu:
		ok, err = fixed_open(&b.fixed, path, tmp)
		if ok {
			if b.fixed.title != "" {
				b.doc.title = strings.clone(b.fixed.title)
			}
			if b.fixed.author != "" {
				b.doc.author = strings.clone(b.fixed.author)
			}
		}
	case .Unknown:
	}
	b.parse_ms = time.duration_milliseconds(time.since(t0))

	if !ok {
		b.err = strings.clone(err == "" ? "the book could not be opened" : err)
		// A failed open must leave nothing behind, because the library will
		// try the next book immediately.
		if format_is_reflowable(b.format) {
			if b.format == .Epub {
				epub_destroy(&b.epub)
			} else {
				mobi_destroy(&b.mobi)
			}
			for _, &im in b.imgs {
				p.image_destroy(&im)
			}
			delete(b.imgs)
			b.imgs = {}
			delete(b.img_queue)
			b.img_queue = {}
			doc_destroy(&b.doc)
		} else {
			fixed_destroy(&b.fixed)
		}
		return false
	}

	if format_is_reflowable(b.format) {
		reflow_init(&b.reflow, fonts, o)
		b.bytes_held = len(b.doc.text) + len(b.doc.segs) * size_of(Seg) +
			len(b.doc.blocks) * size_of(Block)
		if b.format == .Epub {
			b.bytes_held += len(b.epub.zip.data)
		} else {
			b.bytes_held += len(b.mobi.data) + len(b.mobi.html)
		}
	}

	b.open = true
	b.open_ms = time.duration_milliseconds(time.since(t0))
	return true
}

book_title :: proc(b: ^Book) -> string {
	if b.doc.title != "" {
		return b.doc.title
	}
	return path_stem_of(path_base(b.path))
}

book_author :: proc(b: ^Book) -> string {
	return b.doc.author
}

path_stem_of :: proc(name: string) -> string {
	if i := strings.last_index_byte(name, '.'); i > 0 {
		return name[:i]
	}
	return name
}

// book_chapters is how many units the book divides into, which is chapters for
// a reflowable book and 1 for a fixed one.
book_chapters :: proc(b: ^Book) -> int {
	if format_is_reflowable(b.format) {
		return len(b.doc.chapters)
	}
	return 1
}

book_toc :: proc(b: ^Book) -> []Toc_Entry {
	if format_is_reflowable(b.format) {
		return b.doc.toc[:]
	}
	return b.fixed.outline[:]
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

// book_image returns a decoded picture, or asks for it to be decoded.
//
// Decoding happens on the UI thread, under a budget: a page with eight
// pictures on it decodes two of them this frame and the rest over the next
// few, so a frame is never held up by stb_image. The picture's natural size
// feeds back into the block cache key, so a block whose image has just
// arrived re-wraps and the page settles.
book_image :: proc(b: ^Book, idx: i32) -> (img: p.Image, ok: bool) {
	if idx < 0 || int(idx) >= len(b.doc.images) {
		return {}, false
	}
	if im, have := b.imgs[idx]; have {
		return im, im.w > 0
	}
	for q in b.img_queue {
		if q == idx {
			return {}, false
		}
	}
	append(&b.img_queue, idx)
	return {}, false
}

// book_pump_images decodes up to `budget` queued pictures. Returns how many
// were decoded, so the caller knows to invalidate its layout.
book_pump_images :: proc(b: ^Book, budget := 2) -> int {
	done := 0
	for done < budget && len(b.img_queue) > 0 {
		idx := b.img_queue[0]
		ordered_remove(&b.img_queue, 0)
		if _, have := b.imgs[idx]; have {
			continue
		}
		rec := &b.doc.images[idx]
		rec.tried = true
		data, got := book_resource(b, rec.key)
		if !got || len(data) == 0 {
			b.imgs[idx] = {}
			done += 1
			continue
		}
		im, decoded := p.decode_image(data)
		delete(data)
		if !decoded {
			b.imgs[idx] = {}
			doc_note(&b.doc, tfmt("could not decode %s", path_base(rec.key)))
			done += 1
			continue
		}
		rec.w, rec.h, rec.ok = im.w, im.h, true
		b.imgs[idx] = im
		b.bytes_held += im.w * im.h * 4
		done += 1
	}
	return done
}

book_images_pending :: proc(b: ^Book) -> bool {
	return len(b.img_queue) > 0
}

// book_resource reads a file out of the book by the key an image block holds:
// an archive path for an EPUB, "rec:N" for a MOBI record.
book_resource :: proc(b: ^Book, key: string) -> ([]u8, bool) {
	switch b.format {
	case .Epub:
		return epub_resource(&b.epub, key)
	case .Mobi:
		if strings.has_prefix(key, "rec:") {
			n := 0
			for c in transmute([]u8)key[4:] {
				if c < '0' || c > '9' {
					break
				}
				n = n * 10 + int(c - '0')
			}
			ri := mobi_image_record(&b.mobi, n)
			if ri < 0 {
				return nil, false
			}
			rec := mobi_record(&b.mobi, ri)
			if len(rec) == 0 {
				return nil, false
			}
			out := make([]u8, len(rec))
			copy(out, rec)
			return out, true
		}
	case .Pdf, .Djvu, .Unknown:
	}
	return nil, false
}

// book_cover_bytes is the cover image's file bytes, for the library grid.
book_cover_bytes :: proc(b: ^Book) -> ([]u8, bool) {
	switch b.format {
	case .Epub:
		if path := epub_cover_path(&b.epub); path != "" {
			return epub_resource(&b.epub, path)
		}
		// No declared cover: the first picture in the first chapter is very
		// often it.
		for im in b.doc.images {
			if data, ok := epub_resource(&b.epub, im.key); ok {
				return data, true
			}
		}
	case .Mobi:
		for im in b.doc.images {
			if data, ok := book_resource(b, im.key); ok {
				return data, true
			}
		}
	case .Pdf, .Djvu, .Unknown:
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

Hit :: struct {
	chapter: int,
	block:   int,
	start:   int, // block-relative, or page-relative for a fixed document
	end:     int,
	page:    int, // 1-based, fixed documents only
	line:    string, // a line of context, owned
}

Search :: struct {
	query: string,
	hits:  [dynamic]Hit,
	sel:   int,
	ran:   bool,
	ms:    f64,
}

search_destroy :: proc(s: ^Search) {
	for h in s.hits {
		delete(h.line)
	}
	delete(s.hits)
	delete(s.query)
	s^ = {}
}

SEARCH_MAX :: 500

// book_search scans the whole book. For a reflowable book that is a pass over
// one contiguous byte arena, which is why it is instant even on a long novel;
// for a fixed one it extracts the text layer once and then scans that.
book_search :: proc(b: ^Book, s: ^Search, query: string) {
	t0 := time.now()
	for h in s.hits {
		delete(h.line)
	}
	clear(&s.hits)
	delete(s.query)
	s.query = strings.clone(query)
	s.sel = 0
	s.ran = true
	q := strings.trim_space(query)
	if len(q) < 2 {
		s.ms = 0
		return
	}
	needle := strings.to_lower(q, context.temp_allocator)

	if format_is_reflowable(b.format) {
		for bi in 0 ..< len(b.doc.blocks) {
			text := block_text(&b.doc, bi)
			if len(text) < len(needle) {
				continue
			}
			lower := strings.to_lower(text, context.temp_allocator)
			at := 0
			for {
				k := strings.index(lower[at:], needle)
				if k < 0 {
					break
				}
				start := at + k
				append(
					&s.hits,
					Hit {
						chapter = int(b.doc.blocks[bi].chapter),
						block = bi,
						start = start,
						end = start + len(needle),
						line = snippet(text, start, len(needle)),
					},
				)
				at = start + max(1, len(needle))
				if len(s.hits) >= SEARCH_MAX {
					s.ms = time.duration_milliseconds(time.since(t0))
					return
				}
			}
		}
	} else {
		fixed_load_text(&b.fixed)
		for page in 1 ..= b.fixed.pages {
			text := fixed_page_text(&b.fixed, page)
			if len(text) < len(needle) {
				continue
			}
			lower := strings.to_lower(text, context.temp_allocator)
			at := 0
			for {
				k := strings.index(lower[at:], needle)
				if k < 0 {
					break
				}
				start := at + k
				append(
					&s.hits,
					Hit {
						page = page,
						block = -1,
						start = start,
						end = start + len(needle),
						line = snippet(text, start, len(needle)),
					},
				)
				at = start + max(1, len(needle))
				if len(s.hits) >= SEARCH_MAX {
					s.ms = time.duration_milliseconds(time.since(t0))
					return
				}
			}
		}
	}
	s.ms = time.duration_milliseconds(time.since(t0))
}

// snippet is a line of context around a hit, with the match roughly centred.
snippet :: proc(text: string, at, n: int, allocator := context.allocator) -> string {
	lo := max(0, at - 42)
	hi := min(len(text), at + n + 58)
	// Do not cut a UTF-8 sequence in half.
	for lo > 0 && lo < len(text) && (text[lo] & 0xc0) == 0x80 {
		lo -= 1
	}
	for hi < len(text) && (text[hi] & 0xc0) == 0x80 {
		hi += 1
	}
	body := strings.trim_space(text[lo:hi])
	// Collapse the newlines a PDF text layer is full of.
	cleaned, _ := strings.replace_all(body, "\n", " ", context.temp_allocator)
	cleaned2, _ := strings.replace_all(cleaned, "\t", " ", context.temp_allocator)
	pre := lo > 0 ? "..." : ""
	post := hi < len(text) ? "..." : ""
	return strings.concatenate({pre, cleaned2, post}, allocator)
}
