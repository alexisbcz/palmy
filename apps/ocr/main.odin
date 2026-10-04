package main

// palmy ocr — a scan or a PDF in, a readable EPUB out.
//
//	ocr [FILE]                        open the interface, with FILE loaded
//	ocr --convert FILE [options]      convert with no window and exit
//	ocr --selftest [--verbose]        the whole pipeline against known text
//	ocr --shot OUT.png [options]      render the interface with no compositor
//	ocr --mock [--port N] [--tls]     run the local Mistral mock server
//	ocr --corpus DIR                  write the ground-truth corpus as PNGs
//	ocr --demo-doc OUT.pdf            a generated multi-page scan, for the demo
//
// Options for --convert:
//
//	--backend tesseract|mistral       default tesseract; mistral needs consent
//	--lang eng                        a tesseract traineddata name
//	--dpi 300                         rasterisation density for PDFs
//	--pages A-B                       a 1-based page range
//	--force-ocr                       OCR a PDF that already has a text layer
//	--epub/--md/--txt PATH            where to write; omit for the data dir
//	--i-consent-to-upload             the remote backend's consent, explicitly
//	--endpoint HOST:PORT              only loopback, for the mock
//	--trace-upload                    print every request a backend would make
//
// SAFETY, by construction and not by convention:
//
//   - the only files read are the ones named on the command line or picked in
//     the dialog. There is no directory walk anywhere in this program.
//   - the only directory written is ~/.local/share/palmy-ocr, enforced by
//     `inside_data_dir` on every write that did not come from an explicit
//     --epub/--md/--txt path.
//   - `http_connect` is the only socket in the program and refuses every
//     non-loopback address unless an endpoint was explicitly marked remote,
//     which only the consented upload path does.
//   - the remote backend is never a fallback. A missing tesseract is an error
//     message, not a reason to upload anything.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."

WIN_W :: 1280
WIN_H :: 820

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "--selftest":
			os.exit(selftest(args[1:]))
		case "--convert":
			os.exit(cmd_convert(args[1:]))
		case "--mock":
			os.exit(cmd_mock(args[1:]))
		case "--corpus":
			os.exit(cmd_corpus(args[1:]))
		case "--demo-doc":
			os.exit(cmd_demo_doc(args[1:]))
		case "--shot":
			os.exit(shot_main(args))
		case "--help", "-h":
			usage()
			os.exit(0)
		}
	}

	m := new(App)
	app_init(m)
	defer app_destroy(m)

	for a in args {
		if strings.has_prefix(a, "-") {
			continue
		}
		open_path(m, a)
		break
	}

	app, err := kit.start({title = "Convert", width = WIN_W, height = WIN_H, decorate = true}, true)
	if err != "" {
		fmt.eprintfln("ocr: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	p.set_min_size(app, 900, 600)
	m.app = app

	for ui in p.frames(app) {
		tick(m)
		keys(ui, m)
		build(ui, m)
	}
}

usage :: proc() {
	fmt.print(
		`palmy ocr — a scan or a PDF in, a readable EPUB out

  ocr [FILE]                      open the interface
  ocr --convert FILE [options]    convert and exit
  ocr --selftest [--verbose]      the pipeline against text we generated
  ocr --shot OUT.png [options]    render the interface, no compositor
  ocr --mock [--port N] [--tls]   the local Mistral mock server
  ocr --corpus DIR                write the ground-truth corpus as PNGs

Convert options:
  --backend tesseract|mistral     default tesseract (local, offline)
  --lang NAME                     a tesseract traineddata name, default eng
  --dpi N                         PDF rasterisation density, default 300
  --pages A-B                     a 1-based page range
  --force-ocr                     OCR a PDF that already has a text layer
  --epub PATH --md PATH --txt PATH
  --i-consent-to-upload           required by --backend mistral
  --endpoint HOST:PORT            loopback only, for the mock server
  --trace-upload                  print what a remote backend would send

The remote backend uploads your document to a third party. It is never used
unless you ask for it by name and consent, and never as a fallback.
`,
	)
}

// ---------------------------------------------------------------------------
// --convert
// ---------------------------------------------------------------------------

cmd_convert :: proc(args: []string) -> int {
	o := default_opts()
	src := ""
	epub_at, md_at, txt_at := "", "", ""
	consent: Consent
	trace: Trace
	trace_init(&trace)
	defer trace_destroy(&trace)
	want_trace := false
	quiet := false

	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--backend":
			i += 1
			if i < len(args) {
				id, ok := backend_from_name(args[i])
				if !ok {
					fmt.eprintfln("ocr: unknown backend %q (tesseract or mistral)", args[i])
					return 2
				}
				o.backend = id
			}
		case "--lang":
			i += 1
			if i < len(args) {o.lang = args[i]}
		case "--dpi":
			i += 1
			if i < len(args) {o.dpi, _ = strconv.parse_int(args[i], 10)}
		case "--pages":
			i += 1
			if i < len(args) {
				o.first, o.last = parse_range(args[i])
			}
		case "--title":
			i += 1
			if i < len(args) {o.title = args[i]}
		case "--force-ocr":
			o.force_ocr = true
		case "--psm-block":
			o.segment = .Block
		case "--epub":
			i += 1
			if i < len(args) {epub_at = args[i]}
		case "--md":
			i += 1
			if i < len(args) {md_at = args[i]}
		case "--txt":
			i += 1
			if i < len(args) {txt_at = args[i]}
		case "--i-consent-to-upload":
			// The command-line half of the consent gate. It is deliberately
			// long and unmistakable, and it still prints what it agreed to.
			consent.granted = true
		case "--endpoint":
			i += 1
			if i < len(args) {
				h, pt, ok := parse_endpoint(args[i])
				if !ok {
					fmt.eprintfln("ocr: --endpoint wants HOST:PORT")
					return 2
				}
				o.endpoint.host = h
				o.endpoint.port = pt
				o.endpoint.tls = false
			}
		case "--endpoint-tls":
			o.endpoint.tls = true
			o.endpoint.tls_insecure = true
		case "--trace-upload":
			want_trace = true
		case "--quiet":
			quiet = true
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintfln("ocr: unknown option %q", a)
				return 2
			}
			src = a
		}
		i += 1
	}
	if src == "" {
		fmt.eprintln("ocr --convert wants a file")
		return 2
	}
	if want_trace {
		o.trace = &trace
	}
	if o.backend == .Mistral {
		if !consent.granted {
			pl := mistral_plan({src}, o.endpoint, 1)
			defer plan_destroy(&pl)
			fmt.eprintfln("ocr: %s", pl.text)
			fmt.eprintln(
				"ocr: refusing to upload without consent. Pass --i-consent-to-upload if that is what you want.",
			)
			return 3
		}
		pl := mistral_plan({src}, o.endpoint, 1)
		defer plan_destroy(&pl)
		fmt.eprintfln("ocr: %s", pl.text)
		fmt.eprintln("ocr: --i-consent-to-upload was given, so it is being sent now.")
		consent_grant(&consent, o.endpoint.host, pl.file, pl.bytes, pl.pages, 0)
		o.consent = &consent
	}

	d: Doc
	doc_init(&d)
	defer doc_destroy(&d)
	st: Convert_Stats
	defer stats_destroy(&st)

	if err := convert(src, o, &d, &st); err != "" {
		fmt.eprintfln("ocr: %s", err)
		if want_trace {
			print_trace(&trace)
		}
		return 1
	}

	wrote := 0
	for pair in ([?]struct {
		f:    Export_Format,
		path: string,
	}{{.Epub, epub_at}, {.Markdown, md_at}, {.Text, txt_at}}) {
		if pair.path == "" {
			continue
		}
		if werr := write_export(&d, pair.f, pair.path, true); werr != "" {
			fmt.eprintfln("ocr: %s", werr)
			return 1
		}
		if !quiet {
			fmt.printfln("wrote %s (%s)", pair.path, export_name(pair.f))
		}
		wrote += 1
	}
	if wrote == 0 {
		// No destination given: write all three into the data directory,
		// which is the only place this program writes by default.
		for f in Export_Format {
			path := default_export_path(src, f, context.temp_allocator)
			if werr := write_export(&d, f, path); werr != "" {
				fmt.eprintfln("ocr: %s", werr)
				return 1
			}
			if !quiet {
				fmt.printfln("wrote %s (%s)", path, export_name(f))
			}
		}
	}

	if !quiet {
		fmt.printfln(
			"%d page%s, %d words, %d block%s, %d column%s, recognised by %s in %d ms",
			d.pages,
			d.pages == 1 ? "" : "s",
			d.words,
			len(d.blocks),
			len(d.blocks) == 1 ? "" : "s",
			max(1, st.columns),
			max(1, st.columns) == 1 ? "" : "s",
			st.backend,
			st.ocr_ms,
		)
		for n in d.notes {
			fmt.printfln("  - %s", n)
		}
	}
	if want_trace {
		print_trace(&trace)
	}
	return 0
}

print_trace :: proc(t: ^Trace) {
	fmt.eprintfln("-- upload trace: %d request%s, %d body bytes", t.calls, t.calls == 1 ? "" : "s", t.bytes)
	for l in t.lines {
		fmt.eprintfln("   %s", l)
	}
}

parse_range :: proc(s: string) -> (from, to: int) {
	if dash := strings.index_byte(s, '-'); dash > 0 {
		from, _ = strconv.parse_int(s[:dash], 10)
		to, _ = strconv.parse_int(s[dash + 1:], 10)
		return
	}
	n, _ := strconv.parse_int(s, 10)
	return n, n
}

parse_endpoint :: proc(s: string) -> (host: string, port: int, ok: bool) {
	colon := strings.last_index_byte(s, ':')
	if colon <= 0 {
		return "", 0, false
	}
	port, ok = strconv.parse_int(s[colon + 1:], 10)
	if !ok || port <= 0 || port > 65535 {
		return "", 0, false
	}
	return s[:colon], port, true
}

// ---------------------------------------------------------------------------
// --corpus
// ---------------------------------------------------------------------------

cmd_corpus :: proc(args: []string) -> int {
	dir := len(args) > 0 ? args[0] : cache_path("corpus", context.temp_allocator)
	os.make_directory_all(dir)
	cases := corpus_cases(context.temp_allocator)
	for c in cases {
		paths, err := corpus_render(c, dir, context.temp_allocator)
		if err != "" {
			fmt.eprintfln("ocr: %s", err)
			return 1
		}
		for pth in paths {
			fmt.printfln("%s", pth)
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// --demo-doc
//
// The demo needs a document, and nothing in a demo may be a document of the
// user's. So the pages of the corpus — which were written for this program and
// rendered by it — are thresholded to 1 bit and wrapped in a PDF with no text
// layer at all, which is as close to a real flatbed scan as something
// generated can be.
// ---------------------------------------------------------------------------

cmd_demo_doc :: proc(args: []string) -> int {
	out := len(args) > 0 ? args[0] : "demo-scan.pdf"
	tmp := cache_path("demo-pages", context.temp_allocator)
	os.make_directory_all(tmp)

	want := [?]string{"headings", "two-column", "furniture"}
	pages := make([dynamic]string, context.temp_allocator)
	for c in corpus_cases(context.temp_allocator) {
		keep := false
		for w in want {
			if c.id == w {keep = true}
		}
		if !keep {
			continue
		}
		paths, err := corpus_render(c, tmp, context.temp_allocator)
		if err != "" {
			fmt.eprintfln("ocr: %s", err)
			return 1
		}
		append(&pages, ..paths)
	}
	if err := write_scan_pdf_multi(out, pages[:], 200); err != "" {
		fmt.eprintfln("ocr: %s", err)
		return 1
	}
	for pg in pages {
		os.remove(pg)
	}
	fmt.printfln("%s — %d pages, no text layer", out, len(pages))
	return 0
}
