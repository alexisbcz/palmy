// Docs — a word processor for palmy.
//
// palmy lays out and draws text; it has no notion of a document, so this app
// owns one: styled runs inside paragraphs, wrapping and pagination onto A4
// pages, a caret and a selection that cross runs and paragraphs, and undo with
// coalescing. See model.odin for the model, layout.odin for the measurement,
// render.odin for the pixels.
//
//	docs [file.json | file.md | file.docx | file.odt | file.rtf]
//	docs <command> ... [--json]          the command line; see cli.odin
//	docs --selftest                      headless assertions over the model
//
// The older spellings --convert, --export-png, --shots, --lint and --bench
// are aliases of the commands of the same name in cli.odin and keep working.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

// Real italic faces, loaded into the two Mono weight slots this app never
// asks for. See the ITALIC note in layout.odin.
ITALIC_FILES := [?][2]string {
	{"/usr/share/fonts/noto/NotoSans-Italic.ttf", "/usr/share/fonts/noto/NotoSans-BoldItalic.ttf"},
	{"/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf", "/usr/share/fonts/TTF/DejaVuSans-BoldOblique.ttf"},
	{
		"/usr/share/fonts/liberation/LiberationSans-Italic.ttf",
		"/usr/share/fonts/liberation/LiberationSans-BoldItalic.ttf",
	},
}

load_italics :: proc(f: ^p.Fonts) -> bool {
	for pair in ITALIC_FILES {
		if p.load_font(f, pair[0], ITALIC_FAM, ITALIC_WT) {
			if !p.load_font(f, pair[1], ITALIC_FAM, ITALIC_BOLD_WT) {
				p.load_font(f, pair[0], ITALIC_FAM, ITALIC_BOLD_WT)
			}
			return true
		}
	}
	return false
}

// headless_fonts builds the same font table the window gets, without opening
// one — the self-test and the benchmark measure against exactly what the app
// would draw.
headless_fonts :: proc(f: ^p.Fonts) {
	p.fonts_init(f)
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	load_italics(f)
}

relayout :: proc(st: ^State) {
	layout_doc(&st.lay, &st.doc, st.fonts)
	st.caret = pos_clamp(&st.doc, st.caret)
	st.anchor = pos_clamp(&st.doc, st.anchor)
}

main :: proc() {
	// A collaboration session is the window's business (or a script's), and
	// its flags predate the command line, so they are looked at first, the
	// way sheets does it.
	if pre, pre_rest := parse_collab_args(os.args[1:]); pre.doc != "" || pre.script != "" {
		if len(os.args) > 1 && os.args[1] == "--collab" && pre.script != "" {
			os.exit(run_script(pre, pre.script, len(pre_rest) > 0 ? pre_rest[0] : ""))
		}
	} else {
		// The command line is the other front end over the same document
		// code: see cli.odin for the declaration and apps/kit/cli.odin for
		// the convention it is parsed by. With no command, or with a path,
		// there is a window.
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
	}

	app, err := kit.start(
		{
			title = "Docs",
			width = 1280,
			height = 880,
			min_width = 900,
			min_height = 600,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("docs: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	load_italics(&app.fonts)

	st := State{}
	state_init(&st, &app.fonts)
	defer state_destroy(&st)

	ca, rest := parse_collab_args(os.args[1:])
	if len(rest) > 0 && !strings.has_prefix(rest[0], "-") {
		do_open(&st, rest[0])
	} else {
		seed_document(&st)
	}
	if ca.doc != "" {
		relayout(&st)
		if err := collab_start(&st, app, ca); err != "" {
			fmt.eprintfln("docs: %s", err)
			os.exit(1)
		}
	}
	relayout(&st)
	st.dirty = false

	last_title := ""
	for ui in p.frames(app) {
		measure(ui, &st)
		handle_keys(ui, &st, app)
		collab_tick(ui, &st)
		measure(ui, &st)
		prose_tick(ui, &st)

		if st.dirty {
			relayout(&st)
			st.dirty = false
		}

		// The caret blinks for a few seconds after the last keystroke and then
		// sits still, so an idle window stops asking for frames.
		t := p.elapsed(ui)
		if len(ui.input.keys) > 0 || ui.input.pressed[.Left] || len(p.typed_text(ui)) > 0 {
			st.last_input = t
		}
		if t - st.last_input < 8 {
			st.caret_on = blink_phase(t - st.last_input)
			p.redraw(ui)
		} else {
			st.caret_on = true
		}
		st.toast_at += p.delta_time(ui)

		frame(ui, &st)

		title := fmt.tprintf("%s%s — Docs", doc_title(&st), st.modified ? " *" : "")
		if title != last_title {
			last_title = strings.clone(title, context.temp_allocator)
			p.set_title(app, title)
		}
	}
}

state_destroy :: proc(st: ^State) {
	collab_destroy(&st.collab)
	prose_destroy(&st.prose)
	doc_destroy(&st.doc)
	doc_destroy(&st.clip_doc)
	layout_destroy(&st.lay)
	history_destroy(&st.hist)
	delete(st.find)
	delete(st.repl)
	delete(st.rx_err)
	if st.rx != nil {
		rx_destroy(st.rx)
		free(st.rx)
		st.rx = nil
	}
	delete(st.prompt_buf)
	delete(st.path)
	delete(st.toast)
	delete(st.clip_text)
}

int_arg :: proc(s: string, def: int) -> int {
	n := 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return def
		}
		n = n * 10 + int(s[i] - '0')
	}
	return n == 0 ? def : n
}

// ---------------------------------------------------------------------------
// Command line entry points
// ---------------------------------------------------------------------------

// Doc_Format is what a file is, which decides how it is read and written.
// The window picks it from the menu entry that was used; the command line
// picks it from the extension. Both then go through doc_import and
// doc_export, so the two front ends read and write a file the same way.
Doc_Format :: enum u8 {
	Json,
	Markdown,
	Html,
	Pdf,
	Docx,
	Odt,
	Rtf,
}

FORMAT_NAMES := [Doc_Format]string {
	.Json     = "json",
	.Markdown = "markdown",
	.Html     = "html",
	.Pdf      = "pdf",
	.Docx     = "docx",
	.Odt      = "odt",
	.Rtf      = "rtf",
}

// FORMAT_READS says which formats can be read back into the model; HTML and
// PDF are written only.
FORMAT_READS := [Doc_Format]bool {
	.Json     = true,
	.Markdown = true,
	.Html     = false,
	.Pdf      = false,
	.Docx     = true,
	.Odt      = true,
	.Rtf      = true,
}

format_of_path :: proc(path: string) -> Doc_Format {
	l := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(l, ".md"), strings.has_suffix(l, ".markdown"):
		return .Markdown
	case strings.has_suffix(l, ".html"), strings.has_suffix(l, ".htm"):
		return .Html
	case strings.has_suffix(l, ".pdf"):
		return .Pdf
	case strings.has_suffix(l, ".docx"):
		return .Docx
	case strings.has_suffix(l, ".odt"):
		return .Odt
	case strings.has_suffix(l, ".rtf"):
		return .Rtf
	}
	return .Json
}

// doc_import is the one reader. A format that cannot be read (HTML, PDF)
// reports failure rather than guessing.
doc_import :: proc(path: string, f: Doc_Format) -> (Doc, bool) {
	switch f {
	case .Markdown:
		return import_markdown(path)
	case .Docx:
		return import_docx(path)
	case .Odt:
		return import_odt(path)
	case .Rtf:
		return import_rtf(path)
	case .Json:
		return load_doc(path)
	case .Html, .Pdf:
	}
	return Doc{}, false
}

// doc_read reads a file in whatever format its extension says.
doc_read :: proc(path: string) -> (Doc, bool) {
	return doc_import(path, format_of_path(path))
}

// cli_load is the older name, kept for the self-tests that use it.
cli_load :: doc_read

// doc_export is the one writer. A PDF is positioned from the layout, so this
// one format brings the layout up to date first; everything else re-serialises
// the model.
doc_export :: proc(st: ^State, path: string, f: Doc_Format, title: string) -> bool {
	switch f {
	case .Markdown:
		return export_markdown(&st.doc, path)
	case .Html:
		return export_html(&st.doc, path, title)
	case .Pdf:
		if st.dirty || len(st.lay.lines) == 0 {
			relayout(st)
			st.dirty = false
		}
		return export_pdf(st, path, title)
	case .Docx:
		return export_docx(&st.doc, path, title)
	case .Odt:
		return export_odt(&st.doc, path, title)
	case .Rtf:
		return export_rtf(&st.doc, path, title)
	case .Json:
		return save_doc(&st.doc, path)
	}
	return false
}

// headless_open gives a document the same State the window would hold, laid
// out with the same font table, and no window. Every command that needs pages
// starts here, so a page count from the command line is the page count the
// window shows.
headless_open :: proc(st: ^State, d: Doc) {
	fonts := new(p.Fonts)
	headless_fonts(fonts)
	layout_fonts = fonts
	state_init(st, fonts)
	replace_document(st, d)
	relayout(st)
	st.dirty = false
}

// convert_file is `docs convert`: read one file, write another, the format of
// each picked by its extension.
convert_file :: proc(in_path, out_path: string, dry_run := false) -> (paras, pages: int, err: string) {
	if !FORMAT_READS[format_of_path(in_path)] {
		return 0, 0, fmt.tprintf("%s cannot be read: %s is written only", in_path, FORMAT_NAMES[format_of_path(in_path)])
	}
	d, ok := doc_read(in_path)
	if !ok {
		return 0, 0, fmt.tprintf("cannot read %s", in_path)
	}
	st := State{}
	headless_open(&st, d)
	defer state_destroy(&st)

	f := format_of_path(out_path)
	// HTML has always been titled after the file it is written to; the rest
	// carry the document's own title.
	title := f == .Html ? base_name(out_path) : doc_display_title(&st.doc, base_name(in_path))
	if !dry_run && !doc_export(&st, out_path, f, title) {
		return len(st.doc.paras), st.lay.pages, fmt.tprintf("cannot write %s", out_path)
	}
	return len(st.doc.paras), st.lay.pages, ""
}

// cli_export_pdf lays the document out headlessly, with the same font table
// the window would use, and writes the PDF from it. Nothing about the result
// depends on a window ever having existed.
cli_export_pdf :: proc(d: ^Doc, out_path, title: string) -> bool {
	st := State{}
	headless_open(&st, doc_clone(d))
	defer state_destroy(&st)
	return doc_export(&st, out_path, .Pdf, title)
}

// export_png_file renders every page of a file to <base>-pN.png.
export_png_file :: proc(in_path, base: string, dry_run := false) -> (wrote, pages: int, err: string) {
	d, ok := doc_read(in_path)
	if !ok {
		return 0, 0, fmt.tprintf("cannot read %s", in_path)
	}
	st := State{}
	headless_open(&st, d)
	defer state_destroy(&st)
	if dry_run {
		return 0, st.lay.pages, ""
	}
	n := export_all_pages_png(&st, base)
	if n != st.lay.pages || n == 0 {
		return n, st.lay.pages, fmt.tprintf("wrote %d of %d page images", n, st.lay.pages)
	}
	return n, st.lay.pages, ""
}

Bench_Result :: struct {
	paragraphs, words, chars, lines, pages, runs, rewrapped, keys, undos: int,
	first_ms, warm_ms, key_ms, undo_ms, draw_ms:                         f64,
	draw_w, draw_h:                                                      int,
}

run_bench :: proc(n: int) -> (r: Bench_Result) {
	fonts: p.Fonts
	headless_fonts(&fonts)
	layout_fonts = &fonts

	st := State{}
	state_init(&st, &fonts)
	st.view = {0, 0, 1280, 760}

	FILLER :: "Pagination is the part a text box never has to do: the engine must know how tall every line is before it can decide which page the line belongs to, and a change anywhere above can move everything below."
	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, n),
	}
	for i in 0 ..< n {
		kind := Para_Kind.Body
		if i % 25 == 0 {
			kind = .H2
		}
		pa := para_make(kind, fmt.tprintf("%d. %s", i + 1, FILLER))
		// Every tenth paragraph carries a bold and an italic run, so the
		// benchmark measures mixed runs rather than one run per paragraph.
		if i % 10 == 0 {
			k := split_at(&pa, 20)
			j := split_at(&pa, 40)
			for q in k ..< j {
				pa.runs[q].style.bold = true
			}
			normalise(&pa)
		}
		append(&st.doc.paras, pa)
	}

	t0 := time.now()
	relayout(&st)
	cold := time.since(t0)

	reps := 20
	t1 := time.now()
	for _ in 0 ..< reps {
		layout_doc(&st.lay, &st.doc, st.fonts)
	}
	warm := time.duration_milliseconds(time.since(t1)) / f64(reps)

	// Typing in the middle of the document: each keystroke is an edit plus a
	// full relayout, which is what the app actually does per frame.
	st.caret = pos(n / 2, 0)
	st.anchor = st.caret
	t2 := time.now()
	keys := 200
	for i in 0 ..< keys {
		// Spaces every sixth character, so the undo stack ends up with real
		// word-sized groups rather than one 200-character burst.
		type_text(&st, i % 6 == 5 ? " " : "x")
		relayout(&st)
	}
	per_key := time.duration_milliseconds(time.since(t2)) / f64(keys)

	// Undo the lot, to time history as well.
	t3 := time.now()
	undos := 0
	for history_can_undo(&st.hist) {
		do_undo(&st)
		relayout(&st)
		undos += 1
	}
	per_undo := undos > 0 ? time.duration_milliseconds(time.since(t3)) / f64(undos) : 0

	// Drawing is the other half of a frame: the page, its shadow, and every
	// visible glyph, straight into a buffer the size of a real window.
	st.scroll = doc_view_height(&st) / 2
	clamp_scroll(&st)
	dw, dh := 1280, 760
	px := make([]u32, dw * dh)
	defer delete(px)
	canvas := p.canvas_from(px, dw, dh, 1)
	defer p.canvas_destroy(&canvas)
	st.view = {0, 0, f32(dw), f32(dh)}
	draw_workspace(&canvas, {0, 0, f32(dw), f32(dh)}, &st) // warm the glyph cache
	t4 := time.now()
	for _ in 0 ..< reps {
		draw_workspace(&canvas, {0, 0, f32(dw), f32(dh)}, &st)
	}
	per_draw := time.duration_milliseconds(time.since(t4)) / f64(reps)

	words, chars := doc_counts(&st.doc)
	r = Bench_Result {
		paragraphs = len(st.doc.paras),
		words      = words,
		chars      = chars,
		lines      = len(st.lay.lines),
		pages      = st.lay.pages,
		runs       = run_total(&st.doc),
		rewrapped  = st.lay.wrapped,
		keys       = keys,
		undos      = undos,
		first_ms   = time.duration_milliseconds(cold),
		warm_ms    = warm,
		key_ms     = per_key,
		undo_ms    = per_undo,
		draw_ms    = per_draw,
		draw_w     = dw,
		draw_h     = dh,
	}
	return r
}

run_total :: proc(d: ^Doc) -> int {
	n := 0
	for &pa in d.paras {
		n += len(pa.runs)
	}
	return n
}

// ---------------------------------------------------------------------------
// The document a fresh window opens with
// ---------------------------------------------------------------------------

SEED :: `# The Anatomy of a Page

A word processor is not a text box. The difference is **pagination**: before a
line can be placed, its height has to be known, and a change anywhere above it
can move everything below onto a different sheet of paper.

## What this one owns

palmy draws text and measures it. Everything else is this program's:

- **Styled runs** — a paragraph is a list of runs, each with its own weight, *slant*, size and colour.
- **Normalisation** — adjacent runs that agree are merged, so typing never degrades the model into one run per character.
- **Layout** — words are measured with ` + "`p.text_width`" + ` and wrapped to the measure, then poured into fixed pages.
- **A caret** that crosses runs and paragraphs, remembers its column, and maps clicks back to byte offsets.

### Try it

Press F1 for the keyboard. F2 bolds, F5 walks the paragraph styles, F9 opens
find and replace, and F10 sets a mark so the arrow keys extend a selection
without a modifier.

> A page is a promise about where the reader's eye will be. Keeping that
> promise is most of the work.

Sizes here are the real thing: A4 at 96 dots per inch is 794 by 1123 pixels,
with one-inch margins leaving a 602 pixel measure. The ruler above the page
agrees with it, and the footer numbers every sheet.

Everything below is ordinary body text, which is what most of a document is.
It wraps, it reflows when the window changes, and it carries the caret from
line to line by *visual* line rather than by paragraph — so walking down
through a wrapped paragraph and back up again returns the caret to the column
it started in.

The status bar keeps a live count of words, characters, lines and pages, and
the page number under the caret. Type enough and the count moves on, which is
the clearest proof that the pagination is real rather than decorative.
`

seed_document :: proc(st: ^State) {
	nd := doc_from_markdown(SEED)
	replace_document(st, nd)
	st.modified = false
	note(st, "F1 for the keyboard")
}
