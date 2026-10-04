package main

// The local backend: tesseract, shelled out to the way the media apps shell
// out to ffmpeg.
//
// It is the default and the one that carries the feature. It runs offline,
// nothing leaves the machine, and because it is a local process the whole
// pipeline is testable against ground truth we generate ourselves.
//
// The output format is TSV rather than hOCR. Both carry the same geometry, but
// TSV is twelve tab-separated columns with no XML, no entity decoding and no
// chance of a `title='bbox ...'` attribute parser quietly mis-reading a page.
// The columns, in order:
//
//   level page_num block_num par_num line_num word_num left top width height
//   conf text
//
// `level` 5 is a word, and words are the only rows this reads: tesseract's own
// block and paragraph numbers are *deliberately ignored*, because recovering
// structure from geometry is the job, and trusting the engine's segmentation
// would mean the column detector is never exercised.
//
// Two tesseract behaviours that matter:
//
//   * it writes `<out>.tsv`, appending the extension itself, so the output
//     argument is a stem and not a path;
//   * a word's `text` column can be empty for a row tesseract emitted but did
//     not resolve, and those rows are dropped rather than becoming empty
//     words that break the line grouper's spacing arithmetic.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."

TESS_BIN :: "tesseract"

// tess_probe answers the question the UI asks on startup: can we OCR at all?
// A missing tesseract is reported here and never anywhere else, which is what
// makes "the OCR failed so we uploaded your bank statements" structurally
// impossible — there is no fallback path to fall back along.
tess_probe :: proc(b: ^Backend) -> (ok: bool, why: string) {
	if !kit.has_tool(TESS_BIN) {
		return false, strings.clone(
			"tesseract is not installed. Install it (pacman -S tesseract tesseract-data-eng) to convert scans on this machine. Nothing will be uploaded.",
		)
	}
	out, good := kit.run({TESS_BIN, "--version"}, context.temp_allocator)
	if !good {
		return false, fmt.aprintf("tesseract is on PATH but would not run: %s", out)
	}
	langs, lok := kit.run({TESS_BIN, "--list-langs"}, context.temp_allocator)
	if !lok || !strings.contains(langs, "eng") {
		return false, strings.clone(
			"tesseract has no English language data. Install tesseract-data-eng.",
		)
	}
	return true, ""
}

// tess_langs lists the traineddata names tesseract can see, minus `osd`
// (orientation detection, not a language). The UI offers these and nothing
// else, so a language that is not installed cannot be selected.
tess_langs :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	text, ok := kit.run({TESS_BIN, "--list-langs"}, context.temp_allocator)
	if !ok {
		append(&out, strings.clone("eng", allocator))
		return out[:]
	}
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || strings.contains(l, " ") || l == "osd" {
			continue // the "List of available languages" banner, or OSD
		}
		append(&out, strings.clone(l, allocator))
	}
	if len(out) == 0 {
		append(&out, strings.clone("eng", allocator))
	}
	return out[:]
}

psm_for :: proc(s: Segmentation) -> string {
	switch s {
	case .Auto:
		return "3"
	case .Block:
		return "6"
	case .Line:
		return "7"
	}
	return "3"
}

tess_recognize :: proc(
	b: ^Backend,
	req: Ocr_Request,
	allocator := context.allocator,
) -> (
	Ocr_Result,
	string,
) {
	started := time.tick_now()
	if !os.exists(req.image_path) {
		return {}, fmt.aprintf("no such image: %s", req.image_path)
	}
	lang := req.lang == "" ? "eng" : req.lang

	// The stem lives in our own cache directory, never beside the user's file.
	stem := cache_path(fmt.tprintf("tess-%d-%d", os.get_pid(), req.page), context.temp_allocator)
	tsv := fmt.tprintf("%s.tsv", stem)
	os.remove(tsv)

	argv := [?]string {
		TESS_BIN,
		req.image_path,
		stem,
		"-l",
		lang,
		"--psm",
		psm_for(req.segment),
		"-c",
		"tessedit_create_tsv=1",
	}
	out, good := kit.run(argv[:], context.temp_allocator)
	if !good && !os.exists(tsv) {
		return {}, fmt.aprintf("tesseract failed on page %d: %s", req.page, out)
	}
	data, rerr := os.read_entire_file_from_path(tsv, context.temp_allocator)
	os.remove(tsv)
	if rerr != nil {
		return {}, fmt.aprintf("tesseract wrote no TSV for page %d", req.page)
	}

	res := Ocr_Result {
		kind    = .Boxes,
		words   = make([dynamic]Ocr_Word, allocator),
		page    = req.page,
		backend = strings.clone("tesseract", allocator),
	}
	if w, h, _, iok := image_dims(req.image_path); iok {
		res.width, res.height = w, h
	}

	tess_parse_tsv(string(data), req.page, &res.words, allocator)
	trace_add(req.trace, "tesseract: page %d, %d words, nothing sent", req.page, len(res.words))
	res.ms = int(time.duration_milliseconds(time.tick_since(started)))
	return res, ""
}

// tess_parse_tsv is separated from the process so the self-test can feed it
// hand-written rows, including the malformed ones a real run produces.
tess_parse_tsv :: proc(
	text: string,
	page: int,
	out: ^[dynamic]Ocr_Word,
	allocator := context.allocator,
) {
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" || strings.has_prefix(line, "level\t") {
			continue
		}
		// Split on tabs only. The text column is the last field and may itself
		// contain spaces, but never a tab.
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 12 {
			continue
		}
		level, lok := strconv.parse_int(f[0], 10)
		if !lok || level != 5 {
			continue // 1 page, 2 block, 3 paragraph, 4 line — all ignored
		}
		word := strings.trim_space(f[11])
		if word == "" {
			continue
		}
		x, xo := strconv.parse_int(f[6], 10)
		y, yo := strconv.parse_int(f[7], 10)
		w, wo := strconv.parse_int(f[8], 10)
		h, ho := strconv.parse_int(f[9], 10)
		if !xo || !yo || !wo || !ho || w <= 0 || h <= 0 {
			continue
		}
		conf, _ := strconv.parse_f32(f[10])
		append(
			out,
			Ocr_Word {
				text = strings.clone(word, allocator),
				x = x,
				y = y,
				w = w,
				h = h,
				conf = conf,
				page = page,
			},
		)
	}
}
