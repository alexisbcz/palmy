// What lives on disk, which is everything the reader expects to find again.
//
//   ~/.local/share/palmy-reader/
//     settings.tsv        type size, line height, margins, theme, mode
//     library.tsv         one line per book: where it is, and where you were
//     covers/<id>.png     the cover, extracted once
//     marks/<id>.tsv      bookmarks and highlights
//
// Tab-separated because that is readable with `cat`, diffable, and cannot
// silently lose a book to a parse error the way a single JSON document can: a
// corrupt line costs one book, not the library.
//
// Nothing outside this directory is ever written, and nothing outside it is
// ever *read* except the files the reader explicitly picked in the dialog —
// whose paths are recorded here precisely so that the home directory never has
// to be searched. There is no scan, no watcher and no index of the user's
// disk.
package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."

Theme :: enum u8 {
	Light,
	Sepia,
	Dark,
}

theme_name :: proc(t: Theme) -> string {
	switch t {
	case .Light:
		return "Light"
	case .Sepia:
		return "Sepia"
	case .Dark:
		return "Dark"
	}
	return ""
}

Read_Mode :: enum u8 {
	Paged,
	Continuous,
}

Settings :: struct {
	size:    f32, // body type size in px
	line:    f32, // line height multiplier
	margin:  f32, // side margin as a fraction of the window width
	theme:   Theme,
	justify: bool,
	para:    Para_Style,
	mode:    Read_Mode,
	fit:     Fit_Mode,
	zoom:    f32,
}

settings_default :: proc() -> Settings {
	return Settings {
		size = 17,
		line = 1.62,
		margin = 0.11,
		theme = .Light,
		justify = false,
		para = .Indented,
		mode = .Paged,
		fit = .Width,
		zoom = 1,
	}
}

Mark_Kind :: enum u8 {
	Bookmark,
	Highlight,
}

Mark :: struct {
	kind:    Mark_Kind,
	chapter: int,
	block:   int,
	off:     int,
	end:     int,
	page:    int, // fixed documents
	text:    string, // the highlighted words, or a label
	added:   i64,
}

Lib_Entry :: struct {
	id:      string,
	path:    string,
	format:  Book_Format,
	title:   string,
	author:  string,
	added:   i64,
	opened:  i64,
	// Where the reader was. For a reflowable book that is a chapter and a
	// byte offset; for a fixed one, a page.
	chapter: int,
	block:   int,
	off:     int,
	page:    int,
	frac:    f32, // 0..1 through the book, for the progress bar
	pages:   int, // what the book reported, for the library card
	// Loaded lazily by the library view.
	cover:     p.Image,
	cover_try: bool,
	missing:   bool,
	marks:     [dynamic]Mark,
	marks_read: bool,
}

Library :: struct {
	dir:   string,
	books: [dynamic]Lib_Entry,
	err:   string,
}

// ---------------------------------------------------------------------------
// Where
// ---------------------------------------------------------------------------

store_dir :: proc(allocator := context.allocator) -> string {
	if over := os.get_env("PALMY_READER_HOME", context.temp_allocator); over != "" {
		return strings.clone(over, allocator)
	}
	base := ""
	if xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator); xdg != "" {
		base = xdg
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			home = "/tmp"
		}
		base = strings.concatenate({home, "/.local/share"}, context.temp_allocator)
	}
	return strings.concatenate({base, "/palmy-reader"}, allocator)
}

library_init :: proc(l: ^Library) {
	l^ = {}
	l.dir = store_dir()
	l.books = make([dynamic]Lib_Entry, 0, 16)
	// 0700: a reading history is private.
	_ = os.make_directory_all(l.dir)
	if !os.exists(l.dir) {
		l.err = tfmt("cannot create %s", l.dir)
		return
	}
	_ = os.chmod(l.dir, os.perm_number(0o700))
	for sub in ([?]string{"covers", "marks", "cache"}) {
		d := tfmt("%s/%s", l.dir, sub)
		_ = os.make_directory_all(d)
		_ = os.chmod(d, os.perm_number(0o700))
	}
}

library_destroy :: proc(l: ^Library) {
	for &e in l.books {
		delete(e.id)
		delete(e.path)
		delete(e.title)
		delete(e.author)
		if e.cover.w > 0 {
			p.image_destroy(&e.cover)
		}
		for m in e.marks {
			delete(m.text)
		}
		delete(e.marks)
	}
	delete(l.books)
	delete(l.dir)
	delete(l.err)
	l^ = {}
}

library_cache_dir :: proc(l: ^Library, allocator := context.temp_allocator) -> string {
	return strings.concatenate({l.dir, "/cache"}, allocator)
}

// book_id is a stable, short name for a path: 16 hex digits of FNV-1a. It is
// used for the cover and marks file names, so it must not contain a slash and
// must survive the book being renamed in the library list (it does not — a
// renamed file is a new book, which is the behaviour a reader expects when a
// file genuinely moves).
book_id :: proc(path: string, allocator := context.allocator) -> string {
	h := u64(0xcbf29ce484222325)
	for c in transmute([]u8)path {
		h = (h ~ u64(c)) * 0x100000001b3
	}
	HEX := "0123456789abcdef"
	buf: [16]u8
	for i in 0 ..< 16 {
		buf[15 - i] = HEX[(h >> u64(4 * i)) & 0xf]
	}
	return strings.clone(string(buf[:]), allocator)
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

settings_load :: proc(l: ^Library) -> Settings {
	s := settings_default()
	data, err := os.read_entire_file_from_path(
		tfmt("%s/settings.tsv", l.dir),
		context.temp_allocator,
	)
	if err != nil {
		return s
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		tab := strings.index_byte(line, '\t')
		if tab <= 0 {
			continue
		}
		key := line[:tab]
		val := strings.trim_space(line[tab + 1:])
		switch key {
		case "size":
			if v, ok := strconv.parse_f32(val); ok {s.size = clamp(v, 11, 44)}
		case "line":
			if v, ok := strconv.parse_f32(val); ok {s.line = clamp(v, 1.0, 2.6)}
		case "margin":
			if v, ok := strconv.parse_f32(val); ok {s.margin = clamp(v, 0.02, 0.32)}
		case "theme":
			switch val {
			case "sepia":
				s.theme = .Sepia
			case "dark":
				s.theme = .Dark
			case:
				s.theme = .Light
			}
		case "justify":
			s.justify = val == "1"
		case "para":
			s.para = val == "spaced" ? .Spaced : .Indented
		case "mode":
			s.mode = val == "continuous" ? .Continuous : .Paged
		case "fit":
			switch val {
			case "page":
				s.fit = .Page
			case "zoom":
				s.fit = .Zoom
			case:
				s.fit = .Width
			}
		case "zoom":
			if v, ok := strconv.parse_f32(val); ok {s.zoom = clamp(v, 0.25, 6)}
		}
	}
	return s
}

settings_save :: proc(l: ^Library, s: Settings) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, tfmt("size\t%.1f\n", s.size))
	strings.write_string(&b, tfmt("line\t%.3f\n", s.line))
	strings.write_string(&b, tfmt("margin\t%.3f\n", s.margin))
	strings.write_string(
		&b,
		tfmt("theme\t%s\n", s.theme == .Dark ? "dark" : (s.theme == .Sepia ? "sepia" : "light")),
	)
	strings.write_string(&b, tfmt("justify\t%s\n", s.justify ? "1" : "0"))
	strings.write_string(&b, tfmt("para\t%s\n", s.para == .Spaced ? "spaced" : "indented"))
	strings.write_string(&b, tfmt("mode\t%s\n", s.mode == .Continuous ? "continuous" : "paged"))
	strings.write_string(
		&b,
		tfmt("fit\t%s\n", s.fit == .Page ? "page" : (s.fit == .Zoom ? "zoom" : "width")),
	)
	strings.write_string(&b, tfmt("zoom\t%.3f\n", s.zoom))
	return write_private(tfmt("%s/settings.tsv", l.dir), strings.to_string(b))
}

// ---------------------------------------------------------------------------
// The library
// ---------------------------------------------------------------------------

LIB_FIELDS :: 12

library_load :: proc(l: ^Library) {
	data, err := os.read_entire_file_from_path(
		tfmt("%s/library.tsv", l.dir),
		context.temp_allocator,
	)
	if err != nil {
		return
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.trim_space(line) == "" || strings.has_prefix(line, "#") {
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 6 {
			continue // one corrupt line costs one book
		}
		e := Lib_Entry {
			id     = strings.clone(f[0]),
			path   = strings.clone(f[1]),
			format = format_of_path(f[1]),
			title  = strings.clone(f[3]),
			author = strings.clone(f[4]),
		}
		switch f[2] {
		case "EPUB":
			e.format = .Epub
		case "MOBI":
			e.format = .Mobi
		case "PDF":
			e.format = .Pdf
		case "DjVu":
			e.format = .Djvu
		}
		geti :: proc(f: []string, i: int) -> int {
			if i >= len(f) {
				return 0
			}
			v, _ := strconv.parse_int(strings.trim_space(f[i]))
			return v
		}
		getf :: proc(f: []string, i: int) -> f32 {
			if i >= len(f) {
				return 0
			}
			v, _ := strconv.parse_f32(strings.trim_space(f[i]))
			return v
		}
		e.added = i64(geti(f, 5))
		e.opened = i64(geti(f, 6))
		e.chapter = geti(f, 7)
		e.block = geti(f, 8)
		e.off = geti(f, 9)
		e.page = geti(f, 10)
		e.frac = getf(f, 11)
		e.pages = geti(f, 12)
		e.missing = !os.exists(e.path)
		e.marks = make([dynamic]Mark, 0, 4)
		append(&l.books, e)
	}
}

library_save :: proc(l: ^Library) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"# palmy-reader library: id\tpath\tformat\ttitle\tauthor\tadded\topened\tchapter\tblock\toff\tpage\tfrac\tpages\n",
	)
	for e in l.books {
		strings.write_string(
			&b,
			tfmt(
				"%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.5f\t%d\n",
				e.id,
				clean_field(e.path),
				format_name(e.format),
				clean_field(e.title),
				clean_field(e.author),
				e.added,
				e.opened,
				e.chapter,
				e.block,
				e.off,
				e.page,
				e.frac,
				e.pages,
			),
		)
	}
	return write_private(tfmt("%s/library.tsv", l.dir), strings.to_string(b))
}

// clean_field takes the tabs and newlines out of a value, since the format has
// no escaping and a book title with a tab in it must not shift every column
// after it.
clean_field :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "\t\n\r") {
		return s
	}
	a, _ := strings.replace_all(s, "\t", " ", allocator)
	b, _ := strings.replace_all(a, "\n", " ", allocator)
	c, _ := strings.replace_all(b, "\r", " ", allocator)
	return c
}

library_find :: proc(l: ^Library, path: string) -> int {
	for e, i in l.books {
		if e.path == path {
			return i
		}
	}
	return -1
}

// library_add records a book the reader opened. Returns its index.
library_add :: proc(l: ^Library, path: string, b: ^Book) -> int {
	if i := library_find(l, path); i >= 0 {
		e := &l.books[i]
		e.opened = time.now()._nsec / 1_000_000_000
		if b != nil {
			if t := book_title(b); t != "" {
				delete(e.title)
				e.title = strings.clone(t)
			}
			if a := book_author(b); a != "" {
				delete(e.author)
				e.author = strings.clone(a)
			}
			e.pages = b.open && !format_is_reflowable(b.format) ? b.fixed.pages : book_chapters(b)
		}
		e.missing = false
		return i
	}
	now := time.now()._nsec / 1_000_000_000
	e := Lib_Entry {
		id     = book_id(path),
		path   = strings.clone(path),
		format = b != nil ? b.format : format_of_path(path),
		title  = strings.clone(b != nil ? book_title(b) : path_stem_of(path_base(path))),
		author = strings.clone(b != nil ? book_author(b) : ""),
		added  = now,
		opened = now,
		marks  = make([dynamic]Mark, 0, 4),
	}
	if b != nil && b.open && !format_is_reflowable(b.format) {
		e.pages = b.fixed.pages
		e.page = 1
	}
	append(&l.books, e)
	return len(l.books) - 1
}

library_remove :: proc(l: ^Library, i: int) {
	if i < 0 || i >= len(l.books) {
		return
	}
	e := &l.books[i]
	_ = os.remove(tfmt("%s/covers/%s.png", l.dir, e.id))
	_ = os.remove(tfmt("%s/marks/%s.tsv", l.dir, e.id))
	delete(e.id)
	delete(e.path)
	delete(e.title)
	delete(e.author)
	if e.cover.w > 0 {
		p.image_destroy(&e.cover)
	}
	for m in e.marks {
		delete(m.text)
	}
	delete(e.marks)
	ordered_remove(&l.books, i)
}

// ---------------------------------------------------------------------------
// Covers
// ---------------------------------------------------------------------------

cover_path :: proc(l: ^Library, id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({l.dir, "/covers/", id, ".png"}, allocator)
}

// library_store_cover saves a book's cover into the library so the grid does
// not have to open every book to draw itself.
library_store_cover :: proc(l: ^Library, i: int, b: ^Book) {
	if i < 0 || i >= len(l.books) {
		return
	}
	e := &l.books[i]
	path := cover_path(l, e.id)
	if os.exists(path) {
		return
	}
	data, got := book_cover_bytes(b)
	if got && len(data) > 0 {
		defer delete(data)
		if im, ok := p.decode_image(data); ok {
			defer p.image_destroy(&im)
			save_image_png(path, im)
			return
		}
	}
	if !format_is_reflowable(b.format) {
		// Render the first page small, which is the cover of a scan.
		if im, ok := fixed_first_page(b, library_cache_dir(l)); ok {
			defer p.image_destroy(&im)
			save_image_png(path, im)
		}
	}
}

// fixed_first_page rasterises page one at a thumbnail resolution, for the
// library card. Synchronous on purpose: it happens once per book, at the
// moment the book is added.
fixed_first_page :: proc(b: ^Book, tmp: string) -> (img: p.Image, ok: bool) {
	if format_is_reflowable(b.format) {
		return {}, false
	}
	return fixed_rasterise_public(b.fixed.kind, b.fixed.path, tmp, 1, 50)
}

save_image_png :: proc(path: string, im: p.Image) -> bool {
	if im.w <= 0 || im.h <= 0 {
		return false
	}
	rgba := make([]u8, im.w * im.h * 4, context.temp_allocator)
	for i in 0 ..< im.w * im.h {
		c := im.px[i]
		rgba[i * 4 + 0] = u8(c >> 16)
		rgba[i * 4 + 1] = u8(c >> 8)
		rgba[i * 4 + 2] = u8(c)
		rgba[i * 4 + 3] = u8(c >> 24)
	}
	return p.write_png_rgba(path, rgba, im.w, im.h)
}

// library_load_cover reads a stored cover, once.
library_load_cover :: proc(l: ^Library, i: int) {
	if i < 0 || i >= len(l.books) {
		return
	}
	e := &l.books[i]
	if e.cover_try {
		return
	}
	e.cover_try = true
	if im, ok := p.load_image(cover_path(l, e.id)); ok {
		e.cover = im
	}
}

// ---------------------------------------------------------------------------
// Bookmarks and highlights
// ---------------------------------------------------------------------------

marks_path :: proc(l: ^Library, id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({l.dir, "/marks/", id, ".tsv"}, allocator)
}

marks_load :: proc(l: ^Library, i: int) {
	if i < 0 || i >= len(l.books) {
		return
	}
	e := &l.books[i]
	if e.marks_read {
		return
	}
	e.marks_read = true
	data, err := os.read_entire_file_from_path(marks_path(l, e.id), context.temp_allocator)
	if err != nil {
		return
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 6 {
			continue
		}
		gi :: proc(f: []string, i: int) -> int {
			if i >= len(f) {
				return 0
			}
			v, _ := strconv.parse_int(strings.trim_space(f[i]))
			return v
		}
		m := Mark {
			kind    = f[0] == "highlight" ? .Highlight : .Bookmark,
			chapter = gi(f, 1),
			block   = gi(f, 2),
			off     = gi(f, 3),
			end     = gi(f, 4),
			page    = gi(f, 5),
			text    = strings.clone(len(f) > 6 ? f[6] : ""),
			added   = i64(gi(f, 7)),
		}
		append(&e.marks, m)
	}
}

marks_save :: proc(l: ^Library, i: int) -> bool {
	if i < 0 || i >= len(l.books) {
		return false
	}
	e := &l.books[i]
	if len(e.marks) == 0 {
		_ = os.remove(marks_path(l, e.id))
		return true
	}
	b := strings.builder_make(context.temp_allocator)
	for m in e.marks {
		strings.write_string(
			&b,
			tfmt(
				"%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\n",
				m.kind == .Highlight ? "highlight" : "bookmark",
				m.chapter,
				m.block,
				m.off,
				m.end,
				m.page,
				clean_field(m.text),
				m.added,
			),
		)
	}
	return write_private(marks_path(l, e.id), strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// write_private writes a file and then tightens its mode. A reading history
// and a list of what is on somebody's disk is nobody else's business.
write_private :: proc(path, body: string) -> bool {
	if os.write_entire_file(path, transmute([]u8)body) != nil {
		return false
	}
	_ = os.chmod(path, os.perm_number(0o600))
	return true
}

// ---------------------------------------------------------------------------
// Operations shared by the window and the command line
//
// Each of these is the one implementation of something a person can do in the
// window and an agent can do with `reader <verb>` (cli.odin). The window's
// procedures in main.odin work out *where* from the layout on screen — the
// page under the reader's eyes, the words under the drag — and then call
// these; the command line works out where from its arguments and calls the
// same ones. Neither writes library.tsv or a marks file any other way, so the
// two front ends cannot disagree about what a bookmark or a position is.
// ---------------------------------------------------------------------------

// The ranges the window's controls move within. settings_load is deliberately
// more tolerant (a hand-edited file is clamped, not rejected), but anything
// either front end *sets* lands inside these.
SET_SIZE_MIN :: f32(11)
SET_SIZE_MAX :: f32(40)
SET_LINE_MIN :: f32(1.08)
SET_LINE_MAX :: f32(2.4)
SET_MARGIN_MIN :: f32(0.03)
SET_MARGIN_MAX :: f32(0.3)
SET_ZOOM_MIN :: f32(0.3)
SET_ZOOM_MAX :: f32(5)

settings_clamp :: proc(s: Settings) -> Settings {
	o := s
	o.size = clamp(o.size, SET_SIZE_MIN, SET_SIZE_MAX)
	o.line = clamp(o.line, SET_LINE_MIN, SET_LINE_MAX)
	o.margin = clamp(o.margin, SET_MARGIN_MIN, SET_MARGIN_MAX)
	o.zoom = clamp(o.zoom, SET_ZOOM_MIN, SET_ZOOM_MAX)
	return o
}

// library_open_book opens a file and records it in the library: the cover is
// stored and the marks are read. It is what opening a book in the window does
// and what `reader add` does. On failure the index is -1 and b.err says why.
library_open_book :: proc(
	l: ^Library,
	b: ^Book,
	abs: string,
	fonts: ^p.Fonts,
	o: Reflow_Opts,
) -> (
	idx: int,
	ok: bool,
) {
	if !book_open(b, abs, fonts, library_cache_dir(l), o) {
		return -1, false
	}
	i := library_add(l, abs, b)
	library_store_cover(l, i, b)
	marks_load(l, i)
	return i, true
}

// doc_progress is how far through a reflowable book a position is, from
// chapter byte sizes, so that it does not move when the type size does.
// `within` is the fraction of the chapter already read.
doc_progress :: proc(d: ^Doc, chapter: int, within: f32) -> f32 {
	total := doc_total_bytes(d)
	if total <= 0 {
		return 0
	}
	before := 0
	for i in 0 ..< clamp(chapter, 0, len(d.chapters)) {
		before += d.chapters[i].bytes
	}
	inside := f32(0)
	if chapter >= 0 && chapter < len(d.chapters) {
		inside = f32(d.chapters[chapter].bytes) * clamp(within, 0, 1)
	}
	return clamp((f32(before) + inside) / f32(total), 0, 1)
}

// fixed_progress is the same question for a page of a fixed document.
fixed_progress :: proc(page, pages: int) -> f32 {
	if pages <= 1 {
		return 1
	}
	return clamp(f32(page - 1) / f32(pages - 1), 0, 1)
}

// library_set_position records where the reader is in one book. For a
// reflowable book that is a chapter, a block and a byte offset into it; for a
// fixed one, a page. A negative block leaves the stored block alone, which is
// what the window wants when the layout could not name one.
library_set_position :: proc(
	l: ^Library,
	i: int,
	reflowable: bool,
	chapter, block, off, page: int,
	frac: f32,
	pages: int,
) {
	if i < 0 || i >= len(l.books) {
		return
	}
	e := &l.books[i]
	e.opened = time.now()._nsec / 1_000_000_000
	e.frac = frac
	if reflowable {
		e.chapter = chapter
		if block >= 0 {
			e.block, e.off = block, off
		}
	} else {
		e.page = page
	}
	e.pages = pages
}

// marks_find_bookmark is the bookmark at a position, or -1. A reflowable
// position is a chapter and a block; a fixed one, a page.
marks_find_bookmark :: proc(l: ^Library, i: int, reflowable: bool, chapter, block, page: int) -> int {
	if i < 0 || i >= len(l.books) {
		return -1
	}
	for m, k in l.books[i].marks {
		if m.kind != .Bookmark {
			continue
		}
		same := reflowable ? (m.chapter == chapter && m.block == block) : (m.page == page)
		if same {
			return k
		}
	}
	return -1
}

marks_add_bookmark :: proc(l: ^Library, i: int, chapter, block, off, page: int, label: string) {
	if i < 0 || i >= len(l.books) {
		return
	}
	append(
		&l.books[i].marks,
		Mark {
			kind = .Bookmark,
			chapter = chapter,
			block = block,
			off = off,
			end = off,
			page = page,
			text = strings.clone(label),
			added = time.now()._nsec / 1_000_000_000,
		},
	)
	_ = marks_save(l, i)
}

// marks_find_highlight is a highlight overlapping a range of one block, or -1.
marks_find_highlight :: proc(l: ^Library, i: int, block, from, to: int) -> int {
	if i < 0 || i >= len(l.books) {
		return -1
	}
	for m, k in l.books[i].marks {
		if m.kind == .Highlight && m.block == block && !(m.end <= from || m.off >= to) {
			return k
		}
	}
	return -1
}

marks_add_highlight :: proc(l: ^Library, i: int, chapter, block, from, to: int, text: string) {
	if i < 0 || i >= len(l.books) {
		return
	}
	append(
		&l.books[i].marks,
		Mark {
			kind = .Highlight,
			chapter = chapter,
			block = block,
			off = from,
			end = to,
			text = strings.clone(text),
			added = time.now()._nsec / 1_000_000_000,
		},
	)
	_ = marks_save(l, i)
}

marks_remove :: proc(l: ^Library, i: int, k: int) {
	if i < 0 || i >= len(l.books) || k < 0 || k >= len(l.books[i].marks) {
		return
	}
	delete(l.books[i].marks[k].text)
	ordered_remove(&l.books[i].marks, k)
	_ = marks_save(l, i)
}
