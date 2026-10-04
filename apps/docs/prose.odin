// Prose linting, through vale.
//
// The engine is `vale`, shelled out to the way the media apps shell out to
// ffmpeg and the OCR app shells out to tesseract. What vale does *not* bring
// is any rules: a fresh machine has an empty `~/.local/share/vale/styles`, and
// the only way to fill it is `vale sync`, which downloads style packages from
// GitHub. This application may not use the network, so it ships its own style
// package instead — `prose/Palm/*.yml` beside this file, embedded into the
// binary with `#load` and written into a cache directory on first use. The
// repository copy is the authoritative one; the binary is self-contained
// because `#load` takes a copy at compile time. Nothing is ever downloaded,
// and `vale sync` is never invoked.
//
// The whole of the difficulty is in one place: **position mapping**.
//
// vale lints a *file* and reports `line` plus a `Span` of two column numbers.
// This app holds a block model — a list of paragraphs, each a list of styled
// runs, addressed as (block, byte offset). So a document has to be serialised
// to something vale understands, and every alert mapped back.
//
// Three measured facts about vale 3.22 decided the design:
//
//  1. A span is `[first, last]`, **inclusive at both ends**, **1-based**, and
//     counted in **runes, not bytes**. `漢字漢字 really bad` reports `really`
//     at 6..11 — rune 6, not byte 13. Getting this wrong is invisible in
//     ASCII and wrong everywhere else, which is the classic bug here.
//  2. The columns are in the coordinates of the **original file**, not of the
//     plain text vale renders the markup down to. A heading reports its text
//     starting at column 3, past the `# ` it never linted.
//  3. The alert carries `Match`: the exact text vale flagged. That is a
//     checkable oracle for the mapping, and it is checked — at run time on
//     every alert, not only in the self-test.
//
// So the serialiser does not try to be clever about columns. It records, for
// every rune it emits, the byte offset in the block that rune came from, or -1
// for a rune that is syntax rather than content. Mapping is then an array
// index and cannot drift: no arithmetic over prefix widths, no assumption that
// a rune is a byte, no silent shift when a character is escaped.
//
// What is deliberately *not* serialised: inline emphasis. `**bold**` would
// round-trip through vale's columns correctly — that was measured too — but it
// buys nothing for a linter and every delimiter is another chance for the map
// to be wrong. Runs are flattened to their text. Block structure *is* kept,
// because vale is markup-aware and a heading, a list item and a blockquote are
// different scopes to it.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import kit "kit:."

PROSE_BIN :: "vale"

// How long after the last keystroke a lint runs. vale costs 110-160ms on this
// machine (measured, over documents from one line to seventeen kilobytes), so
// it can never run on the edit path; see `prose_tick` for the frame story.
PROSE_DEBOUNCE :: f32(0.9)

// ---------------------------------------------------------------------------
// The style package
// ---------------------------------------------------------------------------

Prose_Asset :: struct {
	path: string, // relative to the materialised styles directory
	body: string,
}

// The style package, embedded. Nine rules; `prose/Palm/<name>.yml` carries the
// argument for each one in its own header comment.
PROSE_ASSETS := [?]Prose_Asset {
	{"Palm/Consistent.yml", #load("prose/Palm/Consistent.yml", string)},
	{"Palm/Heading.yml", #load("prose/Palm/Heading.yml", string)},
	{"Palm/Hedge.yml", #load("prose/Palm/Hedge.yml", string)},
	{"Palm/Passive.yml", #load("prose/Palm/Passive.yml", string)},
	{"Palm/Repeated.yml", #load("prose/Palm/Repeated.yml", string)},
	{"Palm/Sentence.yml", #load("prose/Palm/Sentence.yml", string)},
	{"Palm/Spacing.yml", #load("prose/Palm/Spacing.yml", string)},
	{"Palm/Spelling.yml", #load("prose/Palm/Spelling.yml", string)},
	{"Palm/Wordy.yml", #load("prose/Palm/Wordy.yml", string)},
	{
		"config/vocabularies/Palm/accept.txt",
		#load("prose/config/vocabularies/Palm/accept.txt", string),
	},
}

PROSE_RULES := [?]string {
	"Palm.Consistent",
	"Palm.Heading",
	"Palm.Hedge",
	"Palm.Passive",
	"Palm.Repeated",
	"Palm.Sentence",
	"Palm.Spacing",
	"Palm.Spelling",
	"Palm.Wordy",
}

PROSE_INI :: `# Written by docs from the style package embedded in the binary.
# The authoritative copy of these rules is apps/docs/prose/ in the repository.
StylesPath = styles
MinAlertLevel = suggestion
Vocab = Palm

[*.md]
BasedOnStyles = Palm
`

prose_cache_dir :: proc(alloc := context.temp_allocator) -> string {
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if base == "" {
		base = fmt.tprintf("%s/.cache", kit_home())
	}
	return fmt.aprintf("%s/palmy-docs/vale", base, allocator = alloc)
}

// prose_materialise writes the embedded style package out, and returns the
// path of the generated `.vale.ini`.
//
// A file is only rewritten when its content differs, so a second run costs
// nine reads and no writes, and a vale process reading the directory can never
// see a file half-replaced by an identical copy.
prose_materialise :: proc(alloc := context.allocator) -> (ini: string, err: string) {
	dir := prose_cache_dir()
	styles := fmt.tprintf("%s/styles", dir)
	if e := os.make_directory_all(styles, os.perm(0o755)); e != nil && !os.exists(styles) {
		return "", fmt.aprintf("cannot create %s", styles, allocator = alloc)
	}

	for a in PROSE_ASSETS {
		path := fmt.tprintf("%s/%s", styles, a.path)
		if cut := strings.last_index_byte(path, '/'); cut > 0 {
			parent := path[:cut]
			if e := os.make_directory_all(parent, os.perm(0o755)); e != nil && !os.exists(parent) {
				return "", fmt.aprintf("cannot create %s", parent, allocator = alloc)
			}
		}
		if old, got := os.read_entire_file_from_path(path, context.temp_allocator);
		   got == nil && string(old) == a.body {
			continue
		}
		if e := os.write_entire_file(path, transmute([]u8)a.body); e != nil {
			return "", fmt.aprintf("cannot write %s", path, allocator = alloc)
		}
	}

	ini_path := fmt.tprintf("%s/.vale.ini", dir)
	if old, got := os.read_entire_file_from_path(ini_path, context.temp_allocator);
	   got != nil || string(old) != PROSE_INI {
		if e := os.write_entire_file(ini_path, transmute([]u8)string(PROSE_INI)); e != nil {
			return "", fmt.aprintf("cannot write %s", ini_path, allocator = alloc)
		}
	}
	return strings.clone(ini_path, alloc), ""
}

// prose_project_config looks for a `.vale.ini` in the directory of the file
// being edited and in its ancestors, which is the behaviour a writer who keeps
// a style guide beside their prose expects.
//
// It stops *below* `$HOME`: a config in the home directory is vale's global
// config, which `--no-global` exists to keep out of here, and walking any
// further would be reading directories this app has no business in. Nothing
// but `.vale.ini` is ever stat'ed, and no directory is ever listed.
prose_project_config :: proc(doc_path: string, alloc := context.allocator) -> string {
	if doc_path == "" {
		return ""
	}
	cut := strings.last_index_byte(doc_path, '/')
	if cut <= 0 {
		return ""
	}
	home := kit_home()
	dir := doc_path[:cut]
	for len(dir) > 1 {
		if dir == home {
			break
		}
		cand := fmt.tprintf("%s/.vale.ini", dir)
		if os.exists(cand) {
			return strings.clone(cand, alloc)
		}
		next := strings.last_index_byte(dir, '/')
		if next <= 0 {
			break
		}
		dir = dir[:next]
	}
	return ""
}

// prose_probe is the one place a missing vale is reported. The app stays fully
// usable without it; what it must never do is show an empty problems panel as
// if the document were clean.
prose_probe :: proc(alloc := context.allocator) -> (ok: bool, why: string) {
	if !kit.has_tool(PROSE_BIN) {
		return false, strings.clone(
			"vale is not installed, so nothing has been checked. Install it (mise use -g vale, or pacman -S vale) to lint this document. Nothing is downloaded either way.",
			alloc,
		)
	}
	out, good := kit.run({PROSE_BIN, "--version"}, context.temp_allocator)
	if !good {
		return false, fmt.aprintf("vale is on PATH but would not run: %s", out, allocator = alloc)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Serialisation, with the map back
// ---------------------------------------------------------------------------

// Prose_Line is one line of the generated markdown. `offs[i]` is the byte
// offset within `blk`'s text that output rune `i` came from, or -1 when the
// rune is syntax this app added (a heading's `#`, a list's `-`, the backslash
// of an escape).
Prose_Line :: struct {
	blk:   Blk,
	offs:  []i32,
	valid: bool,
}

Prose_Text :: struct {
	md:      string,
	lines:   []Prose_Line,
	// Blocks deliberately not handed to vale: a code paragraph, a picture, a
	// table's empty shell, or a paragraph indented far enough that markdown
	// would read it as a code block. Counted so the UI can say so rather than
	// imply the document was checked end to end.
	skipped: int,
}

prose_text_destroy :: proc(pt: ^Prose_Text) {
	delete(pt.md)
	for &l in pt.lines {
		delete(l.offs)
	}
	delete(pt.lines)
	pt^ = {}
}

// prose_prefix is the markup that makes vale see the block for what it is. The
// runes it contributes are mapped to -1, so an alert can never be attributed
// to a character the document does not contain.
prose_prefix :: proc(pa: ^Paragraph, alloc := context.temp_allocator) -> string {
	b := strings.builder_make(alloc)
	switch pa.kind {
	case .H1:
		strings.write_string(&b, "# ")
	case .H2:
		strings.write_string(&b, "## ")
	case .H3:
		strings.write_string(&b, "### ")
	case .Quote:
		strings.write_string(&b, "> ")
	case .Body, .Code, .Table, .Image:
	}
	if pa.list != .None && text_kind(pa.kind) {
		for _ in 0 ..< clamp(pa.depth, 0, 6) {
			strings.write_string(&b, "  ")
		}
		strings.write_string(&b, pa.list == .Numbered ? "1. " : "- ")
	}
	return strings.to_string(b)
}

// prose_serialize writes the document as markdown and the map back to it.
//
// Two lines are emitted per block: the block itself, then a blank one. The
// blank line is not decoration — without it markdown's lazy continuation folds
// the next block into this paragraph, and two blocks would then share a line.
prose_serialize :: proc(d: ^Doc, alloc := context.allocator) -> Prose_Text {
	b := strings.builder_make(alloc)
	lines := make([dynamic]Prose_Line, 0, 2 * len(d.paras) + 8, alloc)
	skipped := 0

	blank :: proc(b: ^strings.Builder, lines: ^[dynamic]Prose_Line) {
		strings.write_byte(b, '\n')
		append(lines, Prose_Line{})
	}

	for blk in doc_blocks(d, context.temp_allocator) {
		pa := blk_para(d, blk)
		if pa == nil || !text_kind(pa.kind) || pa.kind == .Code {
			// Code is not prose and a grid's shell has no text. Both still get
			// a line, so vale's line numbers keep lining up with this array.
			if pa != nil && (pa.kind == .Code || !text_kind(pa.kind)) {
				skipped += 1
			}
			blank(&b, &lines)
			blank(&b, &lines)
			continue
		}

		text := para_text(pa, context.temp_allocator)
		// A paragraph indented four spaces or more would be an indented code
		// block, and vale would skip its content without saying so. Rather
		// than shift the text — which would break the map — the block is
		// declared unchecked.
		lead := 0
		for lead < len(text) && text[lead] == ' ' {
			lead += 1
		}
		if lead >= 4 {
			skipped += 1
			blank(&b, &lines)
			blank(&b, &lines)
			continue
		}

		prefix := prose_prefix(pa)
		offs := make([dynamic]i32, 0, len(text) + 8, alloc)
		strings.write_string(&b, prefix)
		for _ in 0 ..< strings.rune_count(prefix) {
			append(&offs, i32(-1))
		}

		i := 0
		for i < len(text) {
			_, n := utf8.decode_rune_in_string(text[i:])
			n = max(1, n)
			c := text[i]
			switch {
			case n == 1 && (c == '\n' || c == '\r' || c == '\t'):
				// One byte in, one byte out, so the map stays exact. The model
				// should never hold these, but an importer could.
				strings.write_byte(&b, ' ')
				append(&offs, i32(i))
			case n == 1 && (c == '`' || c == '<'):
				// A backtick opens inline code or, at the head of a line, a
				// fence — either way vale stops reading and says nothing. `<`
				// opens raw HTML. Both are escaped; the backslash is a rune
				// the document does not have, so it maps to -1.
				strings.write_byte(&b, '\\')
				append(&offs, i32(-1))
				strings.write_byte(&b, c)
				append(&offs, i32(i))
			case:
				strings.write_string(&b, text[i:i + n])
				append(&offs, i32(i))
			}
			i += n
		}
		strings.write_byte(&b, '\n')
		append(&lines, Prose_Line{blk = blk, offs = offs[:], valid = true})
		blank(&b, &lines)
	}

	return Prose_Text{md = strings.to_string(b), lines = lines[:], skipped = skipped}
}

// prose_map turns one vale position into a model position.
//
// `line` is 1-based; `col` is a 1-based rune column. `clamped` says the column
// landed on syntax this app added rather than on the document's own text,
// which is a mapping the caller should distrust.
prose_map :: proc(
	pt: ^Prose_Text,
	line, col: int,
	forward: bool,
) -> (
	blk: Blk,
	off: int,
	ok: bool,
) {
	if line < 1 || line > len(pt.lines) {
		return {}, 0, false
	}
	l := &pt.lines[line - 1]
	if !l.valid || len(l.offs) == 0 {
		return {}, 0, false
	}
	i := clamp(col - 1, 0, len(l.offs) - 1)
	// A column on an inserted rune walks to the nearest real one, in the
	// direction the end of the span it belongs to should grow.
	if l.offs[i] < 0 {
		j := i
		for j >= 0 && j < len(l.offs) && l.offs[j] < 0 {
			j += forward ? 1 : -1
		}
		if j < 0 || j >= len(l.offs) {
			return {}, 0, false
		}
		i = j
	}
	return l.blk, int(l.offs[i]), true
}

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

Prose_Severity :: enum u8 {
	Suggestion,
	Warning,
	Error,
}

Prose_Alert :: struct {
	blk:      Blk,
	from, to: int, // byte offsets within the block
	sev:      Prose_Severity,
	check:    string,
	message:  string,
	match:    string,
	fix:      string, // vale's own replacement, "" when the rule has none
	line:     int, // vale's coordinates, kept so a mapping bug is reportable
	col:      int,
}

prose_alert_destroy :: proc(a: ^Prose_Alert) {
	delete(a.check)
	delete(a.message)
	delete(a.match)
	delete(a.fix)
}

prose_severity :: proc(s: string) -> Prose_Severity {
	switch s {
	case "error":
		return .Error
	case "warning":
		return .Warning
	}
	return .Suggestion
}

prose_sev_label :: proc(s: Prose_Severity) -> string {
	switch s {
	case .Error:
		return "error"
	case .Warning:
		return "warning"
	case .Suggestion:
		return "suggestion"
	}
	return "suggestion"
}

@(private = "file")
vstr :: proc(o: json.Object, key: string, def := "") -> string {
	if v, got := o[key]; got {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return def
}

@(private = "file")
vint :: proc(o: json.Object, key: string, def := 0) -> int {
	if v, got := o[key]; got {
		#partial switch n in v {
		case json.Integer:
			return int(n)
		case json.Float:
			return int(n)
		}
	}
	return def
}

// prose_parse reads `vale --output=JSON`.
//
// Two shapes come out of that flag and both are handled. The success shape is
// `{"<path>": [alert, ...]}`. A configuration error is a *different* shape
// entirely — a bare object with `Code`, `Text` and `Line` — and a parser that
// assumed the first would report a clean document on a broken style package,
// which is the one failure this feature must not have.
prose_parse :: proc(
	out: string,
	pt: ^Prose_Text,
	d: ^Doc,
	alloc := context.allocator,
) -> (
	alerts: []Prose_Alert,
	unmapped: int,
	err: string,
) {
	trimmed := strings.trim_space(out)
	if trimmed == "" {
		return nil, 0, strings.clone("vale produced no output", alloc)
	}
	root, perr := json.parse(trimmed, .JSON, false, context.temp_allocator)
	if perr != .None {
		short := trimmed
		if len(short) > 160 {
			short = short[:160]
		}
		return nil, 0, fmt.aprintf("vale did not produce JSON: %s", short, allocator = alloc)
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		return nil, 0, strings.clone("vale returned JSON that is not an object", alloc)
	}
	// The configuration-error shape.
	if code := vstr(obj, "Code"); code != "" {
		return nil, 0, fmt.aprintf(
			"vale %s: %s%s",
			code,
			vstr(obj, "Text", "configuration error"),
			vstr(obj, "Path") == "" ? "" : fmt.tprintf(" (%s)", vstr(obj, "Path")),
			allocator = alloc,
		)
	}

	list := make([dynamic]Prose_Alert, 0, 32, alloc)
	for _, file_v in obj {
		arr, is_arr := file_v.(json.Array)
		if !is_arr {
			// A key whose value is not an array means this is not the alert
			// shape at all. Say so rather than returning nothing.
			for &a in list {prose_alert_destroy(&a)}
			delete(list)
			return nil, 0, strings.clone("vale returned JSON in an unknown shape", alloc)
		}
		for av in arr {
			ao, is_ao := av.(json.Object)
			if !is_ao {
				continue
			}
			line := vint(ao, "Line")
			c0, c1 := 0, 0
			if sv, got := ao["Span"]; got {
				if sa, is := sv.(json.Array); is && len(sa) >= 2 {
					if n, isn := sa[0].(json.Integer); isn {c0 = int(n)}
					if n, isn := sa[1].(json.Integer); isn {c1 = int(n)}
					if n, isn := sa[0].(json.Float); isn {c0 = int(n)}
					if n, isn := sa[1].(json.Float); isn {c1 = int(n)}
				}
			}
			match := vstr(ao, "Match")
			if line <= 0 || c0 <= 0 || c1 < c0 {
				unmapped += 1
				continue
			}

			blk, from, ok0 := prose_map(pt, line, c0, true)
			blk1, last, ok1 := prose_map(pt, line, c1, false)
			if !ok0 || !ok1 || blk != blk1 || last < from {
				unmapped += 1
				continue
			}
			// A span's second column is the *last* rune, not one past it, so
			// the end offset is that rune's offset plus its own width — read
			// off the live block, and immediately checked by `prose_verify`,
			// which is what makes a stale or wrong mapping drop out rather
			// than point at the wrong word.
			to := last + 1
			if bpa := blk_para(d, blk); bpa != nil {
				bt := para_text(bpa, context.temp_allocator)
				if last < len(bt) {
					_, n := utf8.decode_rune_in_string(bt[last:])
					to = min(last + max(1, n), len(bt))
				} else {
					to = len(bt)
				}
			}

			fix := ""
			if sv, got := ao["Suggestions"]; got {
				if sa, is := sv.(json.Array); is && len(sa) > 0 {
					if s, iss := sa[0].(json.String); iss {
						fix = string(s)
					}
				}
			}
			if fix == "" {
				if av2, got := ao["Action"]; got {
					if aobj, is := av2.(json.Object); is {
						if pv, gp := aobj["Params"]; gp {
							if pa2, isp := pv.(json.Array); isp && len(pa2) > 0 {
								if s, iss := pa2[0].(json.String); iss {
									fix = string(s)
								}
							}
						}
					}
				}
			}

			append(
				&list,
				Prose_Alert {
					blk = blk,
					from = from,
					to = to,
					sev = prose_severity(vstr(ao, "Severity", "suggestion")),
					check = strings.clone(vstr(ao, "Check", "?"), alloc),
					message = strings.clone(vstr(ao, "Message"), alloc),
					match = strings.clone(match, alloc),
					fix = strings.clone(fix, alloc),
					line = line,
					col = c0,
				},
			)
		}
	}
	return list[:], unmapped, ""
}

// ---------------------------------------------------------------------------
// The checkable invariant
// ---------------------------------------------------------------------------

// prose_verify is the assertion this whole file is built around: **for every
// alert, the text at the mapped model position must equal the text vale
// flagged**. One comparison catches an off-by-one, a byte-versus-rune column,
// a prefix width that was not accounted for, and an escape that shifted the
// line — all of which are otherwise invisible until a highlight lands on the
// wrong word.
//
// It runs in the self-test over a generated corpus, and again at run time on
// every result, where it doubles as the staleness filter: an alert whose text
// no longer matches is an alert about a document the user has since changed,
// and dropping it is exactly right.
prose_verify :: proc(d: ^Doc, a: ^Prose_Alert) -> bool {
	pa := blk_para(d, a.blk)
	if pa == nil {
		return false
	}
	t := para_text(pa, context.temp_allocator)
	if a.from < 0 || a.to > len(t) || a.to <= a.from {
		return false
	}
	return t[a.from:a.to] == a.match
}

// ---------------------------------------------------------------------------
// Running it, off the frame
// ---------------------------------------------------------------------------

Prose_Job :: struct {
	// Set up by the frame before the thread starts; read by the thread.
	argv:     []string,
	md:       string,
	tmp:      string,

	// Written by the thread; read by the frame once `finished` is seen.
	out:      string,
	ok:       bool,
	ms:       int,

	// The handshake. Only these two are touched atomically.
	running:  bool,
	finished: bool,
}

g_prose_job: Prose_Job

prose_busy :: proc() -> bool {
	return sync.atomic_load(&g_prose_job.running)
}

@(private = "file")
prose_worker :: proc() {
	j := &g_prose_job
	started := time.tick_now()
	if e := os.write_entire_file(j.tmp, transmute([]u8)j.md); e != nil {
		j.out = strings.clone(fmt.tprintf("cannot write %s", j.tmp))
		j.ok = false
	} else {
		j.out, j.ok = kit.run(j.argv, context.allocator)
		os.remove(j.tmp)
	}
	j.ms = int(time.duration_milliseconds(time.tick_since(started)))
	sync.atomic_store(&j.finished, true)
}

// prose_start spawns one vale. It refuses while another is in flight, so there
// is never more than one process in the air and no queue to drain.
prose_start :: proc(md: string, config: string) -> bool {
	if prose_busy() {
		delete(md)
		return false
	}
	dir := prose_cache_dir()
	_ = os.make_directory_all(dir, os.perm(0o755))
	tmp := fmt.aprintf("%s/lint-%d.md", dir, os.get_pid())

	words := make([dynamic]string, 0, 8)
	append(&words, strings.clone(PROSE_BIN))
	// Never the user's global config: this app's rules, or a config the
	// document's own project carries, and nothing else.
	append(&words, strings.clone("--no-global"))
	append(&words, strings.clone("--no-exit"))
	append(&words, strings.clone("--output=JSON"))
	if config != "" {
		append(&words, fmt.aprintf("--config=%s", config))
	}
	append(&words, strings.clone(tmp))

	g_prose_job.argv = words[:]
	g_prose_job.md = md
	g_prose_job.tmp = tmp
	g_prose_job.out = ""
	g_prose_job.ok = false
	g_prose_job.ms = 0
	sync.atomic_store(&g_prose_job.finished, false)
	sync.atomic_store(&g_prose_job.running, true)
	thread.create_and_start(prose_worker, self_cleanup = true)
	return true
}

// prose_collect reports a finished run exactly once and clears it.
prose_collect :: proc() -> (out: string, ok: bool, ms: int, got: bool) {
	if !sync.atomic_load(&g_prose_job.running) || !sync.atomic_load(&g_prose_job.finished) {
		return
	}
	out, ok, ms, got = g_prose_job.out, g_prose_job.ok, g_prose_job.ms, true
	for s in g_prose_job.argv {delete(s)}
	delete(g_prose_job.argv)
	delete(g_prose_job.md)
	delete(g_prose_job.tmp)
	g_prose_job.argv = nil
	g_prose_job.md = ""
	g_prose_job.tmp = ""
	sync.atomic_store(&g_prose_job.finished, false)
	sync.atomic_store(&g_prose_job.running, false)
	return
}

// prose_lint_text is the whole pipeline without a window or a thread:
// serialise, run vale, parse, map, verify. The CLI and the self-test call it;
// the editor calls the threaded form so a 150ms process never lands inside a
// frame.
prose_lint_text :: proc(
	d: ^Doc,
	config: string,
	alloc := context.allocator,
) -> (
	alerts: []Prose_Alert,
	skipped: int,
	err: string,
) {
	pt := prose_serialize(d, context.temp_allocator)
	dir := prose_cache_dir()
	_ = os.make_directory_all(dir, os.perm(0o755))
	tmp := fmt.tprintf("%s/lint-cli-%d.md", dir, os.get_pid())
	if e := os.write_entire_file(tmp, transmute([]u8)pt.md); e != nil {
		return nil, pt.skipped, fmt.aprintf("cannot write %s", tmp, allocator = alloc)
	}
	defer os.remove(tmp)

	words := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&words, PROSE_BIN, "--no-global", "--no-exit", "--output=JSON")
	if config != "" {
		append(&words, fmt.tprintf("--config=%s", config))
	}
	append(&words, tmp)
	out, _ := kit.run(words[:], context.temp_allocator)

	list, unmapped, perr := prose_parse(out, &pt, d, alloc)
	if perr != "" {
		return nil, pt.skipped, perr
	}
	keep := make([dynamic]Prose_Alert, 0, len(list), alloc)
	for &a in list {
		if prose_verify(d, &a) {
			append(&keep, a)
		} else {
			unmapped += 1
			prose_alert_destroy(&a)
		}
	}
	// `list` is a slice over an array made with `alloc`, so it has to go back
	// to `alloc` -- `delete` on a slice defaults to context.allocator, and a
	// temp-allocated result freed through that is an invalid-pointer abort.
	delete(list, alloc)
	if unmapped > 0 {
		fmt.eprintfln(
			"docs --lint: %d of %d alerts could not be mapped back into the document",
			unmapped,
			unmapped + len(keep),
		)
	}
	prose_sort(keep[:])
	return keep[:], pt.skipped, ""
}

// prose_sort puts the alerts in reading order, which is what "next problem"
// and the panel both want.
prose_sort :: proc(list: []Prose_Alert) {
	for i in 1 ..< len(list) {
		a := list[i]
		j := i - 1
		for j >= 0 && prose_after(list[j], a) {
			list[j + 1] = list[j]
			j -= 1
		}
		list[j + 1] = a
	}
}

prose_after :: proc(x, y: Prose_Alert) -> bool {
	xa := blk_pos(x.blk, x.from)
	ya := blk_pos(y.blk, y.from)
	if pos_less(ya, xa) {
		return true
	}
	if pos_less(xa, ya) {
		return false
	}
	return x.check > y.check
}

// ---------------------------------------------------------------------------
// `docs --lint <file> [--json]`
//
// The shape PALM-CLI.md asks for: one command, a documented object behind
// `--json`, and an exit code that means something. Positions are reported in
// *both* coordinate systems — the model's (block, byte range), which is what an
// agent editing the document needs, and vale's (line, column), which is what
// makes a mapping bug reportable against the file vale actually read.
// ---------------------------------------------------------------------------

cli_lint :: proc(path: string, as_json: bool) -> bool {
	d, ok := cli_load(path)
	if !ok {
		if as_json {
			prose_json_error(path, "cannot read the file")
		} else {
			fmt.eprintfln("docs: cannot read %s", path)
		}
		return false
	}
	defer doc_destroy(&d)

	avail, why := prose_probe(context.temp_allocator)
	config := ""
	if avail {
		found := prose_project_config(path, context.temp_allocator)
		if found != "" {
			config = found
		} else {
			ini, err := prose_materialise(context.temp_allocator)
			if err != "" {
				avail, why = false, err
			} else {
				config = ini
			}
		}
	}
	if !avail {
		// The failure that matters: say the linter did not run. An empty list
		// here would read as a clean document, and that is the one answer this
		// command must never give by accident.
		if as_json {
			prose_json_error(path, why)
		} else {
			fmt.eprintfln("docs --lint: %s", why)
		}
		return false
	}

	alerts, skipped, err := prose_lint_text(&d, config, context.temp_allocator)
	if err != "" {
		if as_json {
			prose_json_error(path, err)
		} else {
			fmt.eprintfln("docs --lint: %s", err)
		}
		return false
	}

	errs, warns, sugs := 0, 0, 0
	for &a in alerts {
		switch a.sev {
		case .Error:
			errs += 1
		case .Warning:
			warns += 1
		case .Suggestion:
			sugs += 1
		}
	}

	if as_json {
		// Braces are written rather than formatted: Odin's `fmt` reads `{` as
		// the head of an argument spec, so a format string cannot carry one.
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "{\n")
		fmt.sbprintf(&b, "  \"ok\": true,\n  \"file\": %s,\n", prose_quote(path))
		fmt.sbprintf(&b, "  \"engine\": \"vale\",\n  \"config\": %s,\n", prose_quote(config))
		fmt.sbprintf(
			&b,
			"  \"style\": %s,\n  \"blocks\": %d,\n  \"blocks_unchecked\": %d,\n",
			strings.contains(config, "palmy-docs") ? "\"Palm\"" : "null",
			len(doc_blocks(&d, context.temp_allocator)),
			skipped,
		)
		fmt.sbprintf(&b, "  \"counts\": ")
		strings.write_string(&b, "{ ")
		fmt.sbprintf(&b, "\"error\": %d, \"warning\": %d, \"suggestion\": %d", errs, warns, sugs)
		strings.write_string(&b, " },\n")
		strings.write_string(&b, "  \"alerts\": [\n")
		for &a, i in alerts {
			strings.write_string(&b, "    { ")
			fmt.sbprintf(
				&b,
				"\"rule\": %s, \"severity\": %s, \"message\": %s, \"match\": %s,\n",
				prose_quote(a.check),
				prose_quote(prose_sev_label(a.sev)),
				prose_quote(a.message),
				prose_quote(a.match),
			)
			strings.write_string(&b, "      \"block\": { ")
			fmt.sbprintf(
				&b,
				"\"para\": %d, \"row\": %d, \"col\": %d, \"cpara\": %d",
				a.blk.para,
				a.blk.row,
				a.blk.col,
				a.blk.cpara,
			)
			strings.write_string(&b, " },\n")
			fmt.sbprintf(
				&b,
				"      \"from\": %d, \"to\": %d, \"line\": %d, \"column\": %d, \"replacement\": %s",
				a.from,
				a.to,
				a.line,
				a.col,
				a.fix == "" ? "null" : prose_quote(a.fix),
			)
			strings.write_string(&b, i + 1 < len(alerts) ? " },\n" : " }\n")
		}
		strings.write_string(&b, "  ]\n}\n")
		fmt.print(strings.to_string(b))
	} else {
		fmt.printfln(
			"%s — %s, %s, %s",
			path,
			prose_plural(errs, "error"),
			prose_plural(warns, "warning"),
			prose_plural(sugs, "suggestion"),
		)
		if skipped > 0 {
			fmt.printfln("  (%s not checked: code, a picture or a grid)", prose_plural(skipped, "block"))
		}
		for &a in alerts {
			fmt.printfln(
				"  %d:%d  %-10s  %-16s %s",
				a.line,
				a.col,
				prose_sev_label(a.sev),
				a.check,
				a.message,
			)
			fmt.printfln(
				"        block %d+%d..%d  %q%s",
				a.blk.para,
				a.from,
				a.to,
				a.match,
				a.fix == "" ? "" : fmt.tprintf("  →  %q", a.fix),
			)
		}
	}
	// Nonzero only for an error-level alert, so a warning does not fail a
	// script that only cares about the things that are plainly wrong.
	return errs == 0
}

// prose_quote is a JSON string literal. The document's own JSON writer keeps
// its escaper file-private, and this one has to handle a path as well as a
// message, so it is its own.
prose_quote :: proc(s: string, alloc := context.temp_allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(&b, "\\u%04x", int(c))
			} else {
				strings.write_byte(&b, c)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// prose_json_error is the one-line failure object. It exists so the four exit
// paths above cannot disagree about its shape.
prose_json_error :: proc(path, why: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{ ")
	fmt.sbprintf(
		&b,
		"\"ok\": false, \"file\": %s, \"engine\": \"vale\", \"error\": %s",
		prose_quote(path),
		prose_quote(why),
	)
	strings.write_string(&b, " }\n")
	fmt.print(strings.to_string(b))
}
