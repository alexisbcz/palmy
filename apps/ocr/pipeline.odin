package main

// The pipeline: a path the user named, and a Doc at the other end.
//
//   sniff ─┬─ image ──────────────────── recognise ─┬─ boxes ── structure ─┐
//          │                                        └─ markdown ── parse ──┤
//          └─ pdf ─┬─ has a text layer? ── pdftotext ─────────────────────┤
//                  └─ no ── pdftoppm ── recognise (per page) ─────────────┘
//                                                                         │
//                                       EPUB / Markdown / plain text ◀────┘
//
// Everything slow is in here and nothing in here touches the UI, so the whole
// thing runs on the worker thread in jobs.odin and the same procedure is what
// `--convert` and `--selftest` call. There is exactly one conversion path in
// this program; the interface is a way of calling it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Convert_Opts :: struct {
	backend:   Backend_Id,
	lang:      string, // a traineddata name: "eng"
	dpi:       int, // for pdftoppm; 300 is the sweet spot for 10pt text
	segment:   Segmentation,
	deskew:    bool, // straighten a crooked page before recognising it
	force_ocr: bool, // OCR a PDF even though it has a text layer
	first:     int, // 1-based page range, 0 means "from the start"
	last:      int, // 0 means "to the end"
	title:     string,
	consent:   ^Consent,
	endpoint:  Endpoint,
	trace:     ^Trace,
	// Progress, called from the worker thread. Both may be nil.
	on_stage:  proc(user: rawptr, stage: string, done, total: int),
	user:      rawptr,
}

default_opts :: proc() -> Convert_Opts {
	return Convert_Opts {
		backend = .Tesseract,
		lang = "eng",
		dpi = 300,
		segment = .Auto,
		deskew = true,
		endpoint = endpoint_default(),
	}
}

Convert_Stats :: struct {
	ocr_pages:  int,
	ocr_ms:     int,
	words:      int,
	columns:    int,
	dropped:    int, // running headers and footers removed
	text_layer: bool,
	deskewed:   int,
	backend:    string, // heap-owned
}

stats_destroy :: proc(s: ^Convert_Stats) {
	if s.backend != "" {delete(s.backend)}
	s^ = {}
}

@(private = "file")
stage :: proc(o: Convert_Opts, text: string, done, total: int) {
	if o.on_stage != nil {
		o.on_stage(o.user, text, done, total)
	}
}

// convert fills `d`. It returns "" on success, or a sentence a user can act
// on. `d` must already have been doc_init'd.
convert :: proc(path: string, o: Convert_Opts, d: ^Doc, st: ^Convert_Stats) -> string {
	if !os.exists(path) {
		return fmt.aprintf("no such file: %s", path)
	}
	doc_set(&d.source, path)
	doc_set(&d.title, o.title != "" ? o.title : pretty_title(stem_name(path), context.temp_allocator))

	switch sniff(path) {
	case .Pdf:
		return convert_pdf(path, o, d, st)
	case .Image:
		return convert_images({path}, o, d, st)
	case .Unknown:
		return fmt.aprintf(
			"%s is neither a PDF nor an image this build can decode (PNG, JPEG, BMP, GIF, TGA, PNM)",
			base_name(path),
		)
	}
	return "unreachable"
}

// pretty_title turns "scan_2026-10-04_page1" into "Scan 2026-10-04 Page1".
// A filename is the only title information a scan carries, and a book called
// "scan_0001" in a library is worse than no conversion at all.
pretty_title :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	cap_next := true
	for r in s {
		c := r
		if c == '_' || c == '-' {
			c = ' '
		}
		if c == ' ' {
			if strings.builder_len(b) == 0 {
				continue
			}
			cap_next = true
			strings.write_byte(&b, ' ')
			continue
		}
		if cap_next && c >= 'a' && c <= 'z' {
			c -= 32
		}
		cap_next = false
		strings.write_rune(&b, c)
	}
	out := strings.trim_space(strings.to_string(b))
	if out == "" {
		return strings.clone("Untitled", allocator)
	}
	return out
}

// ---------------------------------------------------------------------------
// PDFs
// ---------------------------------------------------------------------------

convert_pdf :: proc(path: string, o: Convert_Opts, d: ^Doc, st: ^Convert_Stats) -> string {
	stage(o, "looking for a text layer", 0, 1)
	tl := pdf_text_layer(path, 3, context.allocator)
	defer if tl.text != "" {delete(tl.text)}

	if tl.present && !o.force_ocr {
		// The decision that matters most for quality, and the one a user is
		// most likely to be surprised by, so it is stated in the notes and in
		// the stats rather than being silent.
		st.text_layer = true
		doc_set(&st.backend, "pdftotext")
		text_layer_to_doc(tl, d)
		st.words = d.words
		return ""
	}
	if tl.present && o.force_ocr {
		doc_note(
			d,
			"this PDF has a text layer (%.0f letters per page) and --force-ocr was given, so it was rasterised and OCRed anyway; the text layer would have been exact",
			tl.per_page,
		)
	} else {
		doc_note(
			d,
			"no text layer found (%d letters over %d probed page%s), so the pages were rasterised at %d dpi and OCRed",
			tl.letters,
			tl.pages_probed,
			tl.pages_probed == 1 ? "" : "s",
			o.dpi,
		)
	}

	total := pdf_page_count(path)
	first := o.first > 0 ? o.first : 1
	last := o.last > 0 ? o.last : (total > 0 ? total : first)
	if total > 0 {
		first = clamp(first, 1, total)
		last = clamp(last, first, total)
	}

	stage(o, "rasterising", 0, last - first + 1)
	pages, rerr := pdf_rasterise(path, first, last, o.dpi, context.allocator)
	defer {
		for pg in pages {
			os.remove(pg)
			delete(pg)
		}
		delete(pages)
	}
	if rerr != "" {
		return rerr
	}
	return convert_images(pages, o, d, st)
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

convert_images :: proc(paths: []string, o: Convert_Opts, d: ^Doc, st: ^Convert_Stats) -> string {
	if len(paths) == 0 {
		return "nothing to convert"
	}
	b := backend_by_id(o.backend)
	if ok, why := b.probe(&b); !ok {
		// A backend that cannot run is reported. It is never swapped for
		// another one: a silent fallback from the local recogniser to a remote
		// service is the one behaviour this program must not have.
		return why
	}
	doc_set(&st.backend, b.name)
	doc_set(&d.backend, b.name)

	layouts := make([dynamic]Page_Layout, context.allocator)
	defer {
		for &pl in layouts {
			layout_destroy(&pl)
		}
		delete(layouts)
	}
	results := make([dynamic]Ocr_Result, context.allocator)
	defer {
		for &r in results {
			result_destroy(&r)
		}
		delete(results)
	}

	md := strings.builder_make(context.temp_allocator)

	deskewed := 0
	skew_sum := f32(0)

	for raw_path, i in paths {
		path := raw_path
		tmp := ""
		if o.deskew {
			stage(o, fmt.tprintf("checking page %d for skew", i + 1), i, len(paths))
			p2, deg, made := deskew_for(raw_path, i + 1, context.temp_allocator)
			if made {
				path = p2
				tmp = p2
				deskewed += 1
				skew_sum += deg
			}
		}
		defer if tmp != "" {
			os.remove(tmp)
		}
		stage(o, fmt.tprintf("recognising page %d of %d", i + 1, len(paths)), i, len(paths))
		req := Ocr_Request {
			image_path = path,
			page       = i + 1,
			lang       = o.lang,
			segment    = o.segment,
			consent    = o.consent,
			endpoint   = o.endpoint,
			trace      = o.trace,
		}
		res, err := b.recognize(&b, req, context.allocator)
		if err != "" {
			return err
		}
		st.ocr_pages += 1
		st.ocr_ms += res.ms
		switch res.kind {
		case .Boxes:
			w := res.width
			h := res.height
			if w == 0 || h == 0 {
				if iw, ih, _, ok := image_dims(path); ok {
					w, h = iw, ih
				}
			}
			append(&layouts, analyse_page(res.words[:], i + 1, w, h))
		case .Blocks:
			if i > 0 {
				strings.write_string(&md, "\n\n")
			}
			strings.write_string(&md, res.markdown)
		}
		append(&results, res)
	}

	if deskewed > 0 {
		doc_note(
			d,
			"straightened %d of %d page%s before recognising (average %.1f degrees); tesseract returns nothing at all past about four",
			deskewed,
			len(paths),
			len(paths) == 1 ? "" : "s",
			f64(skew_sum) / f64(deskewed),
		)
	}
	st.deskewed = deskewed
	stage(o, "recovering structure", len(paths), len(paths))
	if len(layouts) > 0 {
		recover(layouts[:], d)
		for pl in layouts {
			st.columns = max(st.columns, pl.columns)
			for l in pl.lines {
				if l.drop {
					st.dropped += 1
				}
			}
		}
	} else {
		markdown_to_doc(strings.to_string(md), d)
		doc_note(
			d,
			"%s returned Markdown rather than word boxes, so the structure is the service's and not this program's: no column detection, header removal or hyphen joining was applied",
			b.name,
		)
	}
	st.words = d.words
	return ""
}

// ---------------------------------------------------------------------------
// Markdown back into a Doc
//
// The remote backend returns Markdown per page. That is already structured, so
// there is nothing to recover — but it still has to land in the same Doc as
// everything else, or EPUB and plain text would need a second implementation.
//
// This parses only what Mistral OCR actually emits: ATX headings, paragraphs,
// list items, and `![](img-n.png)` image references for figures it extracted.
// Tables come back as GFM pipe tables; they are kept verbatim inside a
// paragraph rather than rebuilt as XHTML tables, because a half-parsed table
// is worse than a legible monospace one.
// ---------------------------------------------------------------------------

markdown_to_doc :: proc(src: string, d: ^Doc) {
	page := 1
	para := strings.builder_make(context.temp_allocator)

	for raw in strings.split_lines(src, context.temp_allocator) {
		line := strings.trim_right_space(raw)
		trimmed := strings.trim_space(line)

		if trimmed == "" {
			md_flush(d, &para, page)
			continue
		}
		// An image on its own line is a figure the service extracted. The
		// image bytes are not downloaded, so all that can honestly be kept is
		// that there was one.
		if strings.has_prefix(trimmed, "![") && strings.has_suffix(trimmed, ")") {
			md_flush(d, &para, page)
			doc_add(d, .Paragraph, "[figure]", page, 0)
			continue
		}
		if strings.has_prefix(trimmed, "#") {
			md_flush(d, &para, page)
			n := 0
			for n < len(trimmed) && trimmed[n] == '#' {
				n += 1
			}
			doc_add(d, .Heading, strings.trim_space(trimmed[n:]), page, 0, min(6, max(1, n)))
			continue
		}
		if trimmed == "---" || trimmed == "***" || trimmed == "___" {
			md_flush(d, &para, page)
			page += 1
			doc_add(d, .Page_Break, "", page, 0)
			continue
		}
		if strings.builder_len(para) > 0 {
			strings.write_byte(&para, ' ')
		}
		strings.write_string(&para, trimmed)
	}
	md_flush(d, &para, page)
	d.pages = max(d.pages, page)
}

@(private = "file")
md_flush :: proc(d: ^Doc, b: ^strings.Builder, page: int) {
	text := strings.trim_space(strings.to_string(b^))
	strings.builder_reset(b)
	if text == "" {
		return
	}
	doc_add(d, .Paragraph, md_unescape(text, context.temp_allocator), page, 0)
}

// md_unescape undoes the inline escapes a Markdown producer added, so the
// plain-text export does not carry backslashes the page never had.
md_unescape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case '\\', '`', '*', '_', '[', ']', '#', '>', '-', '.', '(', ')', '!':
				strings.write_byte(&b, s[i + 1])
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Writing the three outputs
// ---------------------------------------------------------------------------

Export_Format :: enum u8 {
	Epub,
	Markdown,
	Text,
}

export_ext :: proc(f: Export_Format) -> string {
	switch f {
	case .Epub:
		return ".epub"
	case .Markdown:
		return ".md"
	case .Text:
		return ".txt"
	}
	return ""
}

export_name :: proc(f: Export_Format) -> string {
	switch f {
	case .Epub:
		return "EPUB 3"
	case .Markdown:
		return "Markdown"
	case .Text:
		return "plain text"
	}
	return ""
}

// write_export serialises `d` to `path`. The path must be inside the data
// directory unless `allow_outside` is set, which only the command line does
// and only for a path the user typed in full.
write_export :: proc(d: ^Doc, f: Export_Format, path: string, allow_outside := false) -> string {
	if !allow_outside && !inside_data_dir(path) {
		return fmt.aprintf("refusing to write outside %s: %s", data_dir(), path)
	}
	data: []u8
	switch f {
	case .Epub:
		data = doc_to_epub(d, context.temp_allocator)
	case .Markdown:
		data = transmute([]u8)doc_to_markdown(d, context.temp_allocator)
	case .Text:
		data = transmute([]u8)doc_to_text(d, context.temp_allocator)
	}
	if werr := os.write_entire_file(path, data); werr != nil {
		return fmt.aprintf("cannot write %s: %v", path, werr)
	}
	return ""
}

// default_export_path keeps conversions inside the data directory, named after
// the source. Nothing is ever written next to the user's original.
default_export_path :: proc(src: string, f: Export_Format, allocator := context.temp_allocator) -> string {
	return out_path(fmt.tprintf("%s%s", stem_name(src), export_ext(f)), allocator)
}

now_ms :: proc() -> int {
	return int(time.to_unix_nanoseconds(time.now()) / 1_000_000)
}
