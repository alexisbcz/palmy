package main

// Input: what a document is, and how it becomes page images.
//
// Three cases, and the third is the one worth getting right.
//
//   * **An image** (PNG, JPEG, …) is one page. palmy decodes it for the
//     preview; tesseract reads the file itself.
//   * **A PDF with no text layer** — a scan — is rasterised page by page with
//     `pdftoppm` and then OCRed.
//   * **A PDF that already has a text layer** is read with `pdftotext` and
//     **never OCRed**. OCRing text you already have is strictly worse: a born
//     digital PDF's text layer is exact, and running it through a recogniser
//     replaces exact characters with a guess, loses every ligature and turns
//     "fi" into "ﬁ" or worse. Detecting that case is part of doing this
//     properly, and it is the single biggest accuracy win available.
//
// The detection is a measurement, not a flag lookup. `pdftotext` is run over
// the first few pages and the letters it returns are counted against the pages
// it was asked for. A scanned PDF yields nothing, or a handful of stray
// characters from a stamp; a born-digital one yields hundreds per page. The
// threshold sits in the empty middle between those, and the measured value is
// reported rather than hidden, so a borderline file can be overridden.
//
// SAFETY: this module only ever opens a path the user picked in the dialog or
// named on the command line. There is no directory walk anywhere in this
// program, and the only directory it writes is ~/.local/share/palmy-ocr.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."

// ---------------------------------------------------------------------------
// Where we are allowed to write
// ---------------------------------------------------------------------------

DATA_DIR_NAME :: "palmy-ocr"

// data_dir is the one directory this program writes. Exports, the page images
// it rasterises and the config it reads all live under here.
data_dir :: proc() -> string {
	base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		base = fmt.tprintf("%s/.local/share", home)
	}
	dir := fmt.tprintf("%s/%s", base, DATA_DIR_NAME)
	os.make_directory_all(dir)
	return dir
}

cache_dir :: proc() -> string {
	dir := fmt.tprintf("%s/pages", data_dir())
	os.make_directory_all(dir)
	return dir
}

cache_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", cache_dir(), name, allocator = allocator)
}

out_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	dir := fmt.tprintf("%s/out", data_dir())
	os.make_directory_all(dir)
	return fmt.aprintf("%s/%s", dir, name, allocator = allocator)
}

// inside_data_dir is asserted before every write. A path the user typed goes
// through here, so `--out ../../.ssh/authorized_keys` is refused rather than
// honoured.
inside_data_dir :: proc(path: string) -> bool {
	root := data_dir()
	abs := path
	if !strings.has_prefix(abs, "/") {
		return false
	}
	if strings.contains(abs, "/../") || strings.has_suffix(abs, "/..") {
		return false
	}
	return strings.has_prefix(abs, fmt.tprintf("%s/", root)) || abs == root
}

// ---------------------------------------------------------------------------
// What kind of file is this
// ---------------------------------------------------------------------------

Source_Kind :: enum u8 {
	Unknown,
	Image,
	Pdf,
}

sniff :: proc(path: string) -> Source_Kind {
	// Magic bytes, not the extension: a scan emailed as "doc.pdf.jpg" is
	// still a JPEG and a file called "scan" is still a PDF.
	f, oerr := os.open(path)
	if oerr == nil {
		defer os.close(f)
		head: [16]u8
		n, _ := os.read(f, head[:])
		h := head[:max(0, n)]
		if len(h) >= 5 && string(h[:5]) == "%PDF-" {
			return .Pdf
		}
		if len(h) >= 8 && h[0] == 0x89 && string(h[1:4]) == "PNG" {
			return .Image
		}
		if len(h) >= 3 && h[0] == 0xff && h[1] == 0xd8 && h[2] == 0xff {
			return .Image
		}
		if len(h) >= 2 && (string(h[:2]) == "BM") {
			return .Image
		}
		if len(h) >= 6 && string(h[:3]) == "GIF" {
			return .Image
		}
		if len(h) >= 4 && (string(h[:4]) == "RIFF") {
			return .Image
		}
	}
	lower := strings.to_lower(path, context.temp_allocator)
	if strings.has_suffix(lower, ".pdf") {
		return .Pdf
	}
	if p.is_image_path(path) {
		return .Image
	}
	return .Unknown
}

image_dims :: proc(path: string) -> (w, h, ch: int, ok: bool) {
	return p.image_size(path)
}

// ---------------------------------------------------------------------------
// PDFs
// ---------------------------------------------------------------------------

Tools :: struct {
	tesseract:  bool,
	pdftoppm:   bool,
	pdftotext:  bool,
	pdfinfo:    bool,
}

check_tools :: proc() -> Tools {
	return Tools {
		tesseract = kit.has_tool("tesseract"),
		pdftoppm = kit.has_tool("pdftoppm"),
		pdftotext = kit.has_tool("pdftotext"),
		pdfinfo = kit.has_tool("pdfinfo"),
	}
}

pdf_page_count :: proc(path: string) -> int {
	out, ok := kit.run({"pdfinfo", path}, context.temp_allocator)
	if !ok {
		return 0
	}
	for line in strings.split_lines(out, context.temp_allocator) {
		if strings.has_prefix(line, "Pages:") {
			n, pok := strconv.parse_int(strings.trim_space(line[len("Pages:"):]), 10)
			if pok {
				return n
			}
		}
	}
	return 0
}

// Text_Layer is the measurement that decides whether a PDF is OCRed.
Text_Layer :: struct {
	present:      bool,
	letters:      int, // alphanumeric characters pdftotext returned
	pages_probed: int,
	per_page:     f32,
	text:         string, // heap-owned when present; the extracted text
}

// A born-digital page of prose carries several hundred letters. A scan
// carries none, or a few from an OCR stamp somebody else added. 60 per page
// sits in the gap, and the measured figure is always reported next to the
// verdict so the call can be second-guessed.
TEXT_LAYER_PER_PAGE :: 60.0

// pdf_text_layer probes at most the first `probe` pages, then — if a layer is
// there — extracts the whole document. Probing first keeps a 400-page book
// from being fully extracted just to answer a yes/no question.
pdf_text_layer :: proc(path: string, probe := 3, allocator := context.allocator) -> Text_Layer {
	tl: Text_Layer
	if !kit.has_tool("pdftotext") {
		return tl
	}
	last := fmt.tprintf("%d", max(1, probe))
	head, ok := kit.run({"pdftotext", "-f", "1", "-l", last, "-layout", path, "-"}, context.temp_allocator)
	if !ok && head == "" {
		return tl
	}
	tl.letters = count_letters(head)
	n := pdf_page_count(path)
	tl.pages_probed = n > 0 ? min(n, max(1, probe)) : max(1, probe)
	tl.per_page = f32(tl.letters) / f32(max(1, tl.pages_probed))
	tl.present = f64(tl.per_page) >= TEXT_LAYER_PER_PAGE
	if tl.present {
		full, fok := kit.run({"pdftotext", "-layout", path, "-"}, allocator)
		if fok || full != "" {
			tl.text = full
		} else {
			tl.text = strings.clone(head, allocator)
		}
	}
	return tl
}

count_letters :: proc(s: string) -> int {
	n := 0
	for r in s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			n += 1
		}
	}
	return n
}

// pdf_rasterise renders pages `from`..`to` (1-based, inclusive) to PNGs in the
// cache directory and returns their paths in order.
//
// `pdftoppm -r <dpi> -png -f A -l B in.pdf <stem>` writes <stem>-1.png and so
// on, zero-padded to the width of the highest page number it was asked for —
// which is why the names are globbed back out of the directory rather than
// predicted.
pdf_rasterise :: proc(
	path: string,
	from, to, dpi: int,
	allocator := context.allocator,
) -> (
	pages: []string,
	err: string,
) {
	if !kit.has_tool("pdftoppm") {
		return nil, strings.clone("pdftoppm is not installed; install poppler to read PDFs", allocator)
	}
	stem := cache_path(fmt.tprintf("raster-%d", os.get_pid()), context.temp_allocator)
	// Clear anything a previous run left behind under this stem.
	clear_stem(stem)

	argv := [?]string {
		"pdftoppm",
		"-r",
		fmt.tprintf("%d", dpi),
		"-png",
		"-f",
		fmt.tprintf("%d", from),
		"-l",
		fmt.tprintf("%d", to),
		path,
		stem,
	}
	out, ok := kit.run(argv[:], context.temp_allocator)
	found := collect_stem(stem, allocator)
	if len(found) == 0 {
		return nil, fmt.aprintf("pdftoppm produced no pages: %s", out, allocator = allocator)
	}
	_ = ok
	return found, ""
}

@(private = "file")
clear_stem :: proc(stem: string) {
	dir := stem
	if i := strings.last_index_byte(stem, '/'); i >= 0 {
		dir = stem[:i]
	}
	base := base_name(stem)
	entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if rerr != nil {
		return
	}
	for e in entries {
		if strings.has_prefix(e.name, base) && strings.has_suffix(e.name, ".png") {
			os.remove(fmt.tprintf("%s/%s", dir, e.name))
		}
	}
}

@(private = "file")
collect_stem :: proc(stem: string, allocator := context.allocator) -> []string {
	dir := stem
	if i := strings.last_index_byte(stem, '/'); i >= 0 {
		dir = stem[:i]
	}
	base := base_name(stem)
	entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if rerr != nil {
		return nil
	}
	Hit :: struct {
		n:    int,
		path: string,
	}
	hits := make([dynamic]Hit, 0, 16, context.temp_allocator)
	for e in entries {
		if !strings.has_prefix(e.name, base) || !strings.has_suffix(e.name, ".png") {
			continue
		}
		mid := e.name[len(base):len(e.name) - len(".png")]
		mid = strings.trim_left(mid, "-")
		n, _ := strconv.parse_int(strings.trim_left(mid, "0"), 10)
		append(&hits, Hit{n = n, path = fmt.aprintf("%s/%s", dir, e.name, allocator = allocator)})
	}
	// Insertion sort by page number: there are never many.
	for i in 1 ..< len(hits) {
		j := i
		for j > 0 && hits[j - 1].n > hits[j].n {
			hits[j - 1], hits[j] = hits[j], hits[j - 1]
			j -= 1
		}
	}
	out := make([dynamic]string, allocator)
	for h in hits {
		append(&out, h.path)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// The text layer, turned into a Doc
//
// `pdftotext -layout` keeps the page's visual arrangement, which means the
// column and paragraph questions are already answered — in two-space runs and
// blank lines rather than in boxes. Parsing that is a different job from
// parsing OCR output and gets its own small pass: blank lines separate
// paragraphs, a form feed separates pages, and a line that is short and in
// title case on its own between blank lines is a heading.
// ---------------------------------------------------------------------------

text_layer_to_doc :: proc(tl: Text_Layer, d: ^Doc) {
	doc_set(&d.backend, "pdftotext (the PDF's own text layer; no OCR)")
	page := 1
	para := strings.builder_make(context.temp_allocator)

	flush := proc(d: ^Doc, b: ^strings.Builder, page: int) {
		text := strings.trim_space(strings.to_string(b^))
		strings.builder_reset(b)
		if text == "" {
			return
		}
		// A short standalone line with no terminal punctuation reads as a
		// heading. There is no font size here to measure, so this is the only
		// signal available, and it is a weak one — stated as such in the
		// notes rather than dressed up.
		words := count_words(text)
		last := text[len(text) - 1]
		if words <= 10 && last != '.' && last != ',' && last != ';' && last != ':' && !strings.contains(text, "\n") {
			doc_add(d, .Heading, text, page, 0, words <= 6 ? 1 : 2)
			return
		}
		doc_add(d, .Paragraph, collapse_spaces(text, context.temp_allocator), page, 0)
	}

	for raw in strings.split_lines(tl.text, context.temp_allocator) {
		line := raw
		// A form feed is poppler's page separator.
		if strings.contains(line, "\f") {
			parts := strings.split(line, "\f", context.temp_allocator)
			for part, i in parts {
				if i > 0 {
					flush(d, &para, page)
					page += 1
					doc_add(d, .Page_Break, "", page, 0)
				}
				if strings.trim_space(part) != "" {
					if strings.builder_len(para) > 0 {
						strings.write_byte(&para, ' ')
					}
					strings.write_string(&para, strings.trim_space(part))
				}
			}
			continue
		}
		if strings.trim_space(line) == "" {
			flush(d, &para, page)
			continue
		}
		t := strings.trim_space(line)
		stem, hyph := ends_with_hyphen(t)
		if strings.builder_len(para) > 0 {
			strings.write_byte(&para, ' ')
		}
		if hyph {
			strings.write_string(&para, stem)
		} else {
			strings.write_string(&para, t)
		}
	}
	flush(d, &para, page)
	d.pages = max(d.pages, page)
	doc_note(
		d,
		"the PDF already had a text layer (%d letters over %d probed page%s, %.0f per page), so nothing was OCRed",
		tl.letters,
		tl.pages_probed,
		tl.pages_probed == 1 ? "" : "s",
		tl.per_page,
	)
	doc_note(d, "headings in a text layer are guessed from line length; there is no font size to measure")
}

collapse_spaces :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	sp := false
	for r in s {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			sp = true
			continue
		}
		if sp && strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		sp = false
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}
