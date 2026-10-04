// Docs — a word processor for palmy.
//
// palmy lays out and draws text; it has no notion of a document, so this app
// owns one: styled runs inside paragraphs, wrapping and pagination onto A4
// pages, a caret and a selection that cross runs and paragraphs, and undo with
// coalescing. See model.odin for the model, layout.odin for the measurement,
// render.odin for the pixels.
//
//	docs [file.json | file.md | file.docx | file.odt]
//	docs --selftest                      headless assertions over the model
//	docs --convert <in> <out>            .json .md .docx .odt in; those plus
//	                                     .html .pdf .odt .rtf out
//	docs --export-png <file> <base>      render every page to <base>-pN.png
//	docs --shots <dir>                   render the interface offscreen to PNGs
//	docs --lint <file> [--json]          prose problems, through vale
//	docs --bench [paragraphs]            layout and typing throughput
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
	if len(os.args) > 1 {
		switch os.args[1] {
		case "--selftest":
			os.exit(run_selftest() ? 0 : 1)
		case "--bench":
			n := 400
			if len(os.args) > 2 {
				n = int_arg(os.args[2], 400)
			}
			run_bench(n)
			return
		case "--convert":
			if len(os.args) < 4 {
				fmt.eprintln("docs --convert <in.json|in.md> <out.json|out.md|out.html>")
				os.exit(2)
			}
			os.exit(cli_convert(os.args[2], os.args[3]) ? 0 : 1)
		case "--shots":
			// Offscreen screenshots of the real editor. No compositor, no
			// window, nothing on anybody's screen.
			dir := len(os.args) > 2 ? os.args[2] : "docs-shots"
			os.exit(shots(dir))
		case "--lint":
			if len(os.args) < 3 {
				fmt.eprintln("docs --lint <file> [--json]")
				os.exit(2)
			}
			as_json := false
			for a in os.args[3:] {
				if a == "--json" {as_json = true}
			}
			os.exit(cli_lint(os.args[2], as_json) ? 0 : 1)
		case "--export-png":
			if len(os.args) < 4 {
				fmt.eprintln("docs --export-png <file> <base>")
				os.exit(2)
			}
			os.exit(cli_export_png(os.args[2], os.args[3]) ? 0 : 1)
		case "--help", "-h":
			fmt.println(
				"docs [file.json | file.md | file.docx | file.odt]\n" +
				"  --selftest                 headless assertions\n" +
				"  --bench [paragraphs]       layout and typing throughput\n" +
				"  --convert <in> <out>       in: .json .md .docx .odt\n" +
				"                             out: .json .md .html .pdf .docx .odt .rtf\n" +
				"  --export-png <file> <base>\n" +
				"  --lint <file> [--json]     prose problems, through vale\n" +
				"  --shots <dir>              render the interface offscreen to PNGs",
			)
			return
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

	if len(os.args) > 1 && !strings.has_prefix(os.args[1], "-") {
		do_open(&st, os.args[1])
	} else {
		seed_document(&st)
	}
	relayout(&st)
	st.dirty = false

	last_title := ""
	for ui in p.frames(app) {
		measure(ui, &st)
		handle_keys(ui, &st, app)
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
	prose_destroy(&st.prose)
	doc_destroy(&st.doc)
	doc_destroy(&st.clip_doc)
	layout_destroy(&st.lay)
	history_destroy(&st.hist)
	delete(st.find)
	delete(st.repl)
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

// cli_load reads either format, picked by extension.
cli_load :: proc(path: string) -> (Doc, bool) {
	switch {
	case strings.has_suffix(path, ".md"), strings.has_suffix(path, ".markdown"):
		return import_markdown(path)
	case strings.has_suffix(path, ".docx"):
		return import_docx(path)
	case strings.has_suffix(path, ".odt"):
		return import_odt(path)
	}
	return load_doc(path)
}

cli_convert :: proc(in_path, out_path: string) -> bool {
	d, ok := cli_load(in_path)
	if !ok {
		fmt.eprintfln("docs: cannot read %s", in_path)
		return false
	}
	defer doc_destroy(&d)

	title := doc_display_title(&d, base_name(in_path))
	wrote := false
	switch {
	case strings.has_suffix(out_path, ".md"), strings.has_suffix(out_path, ".markdown"):
		wrote = export_markdown(&d, out_path)
	case strings.has_suffix(out_path, ".html"), strings.has_suffix(out_path, ".htm"):
		wrote = export_html(&d, out_path, base_name(out_path))
	case strings.has_suffix(out_path, ".pdf"):
		// A PDF is positioned from the layout, so this one conversion has to
		// measure the document rather than just re-serialise it.
		wrote = cli_export_pdf(&d, out_path, title)
	case strings.has_suffix(out_path, ".docx"):
		wrote = export_docx(&d, out_path, title)
	case strings.has_suffix(out_path, ".odt"):
		wrote = export_odt(&d, out_path, title)
	case strings.has_suffix(out_path, ".rtf"):
		wrote = export_rtf(&d, out_path, title)
	case:
		wrote = save_doc(&d, out_path)
	}
	if !wrote {
		fmt.eprintfln("docs: cannot write %s", out_path)
		return false
	}
	fmt.printfln("%s -> %s (%d paragraphs)", in_path, out_path, len(d.paras))
	return true
}

// cli_export_pdf lays the document out headlessly, with the same font table
// the window would use, and writes the PDF from it. Nothing about the result
// depends on a window ever having existed.
cli_export_pdf :: proc(d: ^Doc, out_path, title: string) -> bool {
	fonts: p.Fonts
	headless_fonts(&fonts)
	layout_fonts = &fonts

	st := State{}
	state_init(&st, &fonts)
	defer state_destroy(&st)
	replace_document(&st, doc_clone(d))
	relayout(&st)
	return export_pdf(&st, out_path, title)
}

cli_export_png :: proc(in_path, base: string) -> bool {
	fonts: p.Fonts
	headless_fonts(&fonts)
	layout_fonts = &fonts

	st := State{}
	state_init(&st, &fonts)
	nd, ok := cli_load(in_path)
	if !ok {
		fmt.eprintfln("docs: cannot read %s", in_path)
		return false
	}
	replace_document(&st, nd)
	relayout(&st)
	n := export_all_pages_png(&st, base)
	fmt.printfln("wrote %d of %d page images", n, st.lay.pages)
	return n == st.lay.pages && n > 0
}

run_bench :: proc(n: int) {
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
	fmt.printfln("docs --bench")
	fmt.printfln("  %d paragraphs, %d words, %d characters", len(st.doc.paras), words, chars)
	fmt.printfln("  %d lines over %d pages", len(st.lay.lines), st.lay.pages)
	fmt.printfln("  first layout     %.1f ms", time.duration_milliseconds(cold))
	fmt.printfln(
		"  layout (warm)    %.2f ms   (%d runs, %d paragraphs re-wrapped)",
		warm,
		run_total(&st.doc),
		st.lay.wrapped,
	)
	fmt.printfln("  keystroke+layout %.2f ms   (%d keys)", per_key, keys)
	fmt.printfln("  undo+layout      %.2f ms   (%d steps)", per_undo, undos)
	fmt.printfln("  draw a %dx%d view %.2f ms", dw, dh, per_draw)
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
