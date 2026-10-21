package main

// prose — the engine half of the writing-improvement feature.
//
//	prose styles                       list the packs and what each is for
//	prose lint   FILE [--style NAME] [--json] [--level L] [--styles-path DIR]
//	prose report FILE [--style NAME] [--json]
//	prose explain RULE [--style NAME]
//	prose fix    FILE [--style NAME]   print the file with every suggestion taken
//	prose segment [FILE]               segmentation accuracy on the corpus
//	prose syllables [FILE] [--n N]     syllable error rate against espeak-ng
//	prose bench FILE                   per-keystroke and full-pass timings
//	prose --selftest [--verbose]
//
// The command line is declared in cli.odin and parsed by the shared
// convention in apps/kit/cli.odin, so `--json`, `--help`, `--schema` and the
// exit codes are the ones every other application has. The older spellings
// `--segment`, `--syllables` and `--bench` are aliases of the verbs.
//
// Every command is a read. Each prints the same thing it always printed for a
// person, and under --json a document of the declared shape instead; both are
// built from the same library calls the notes application makes.
//
// The same code the notes application runs. Nothing here reaches the network,
// and the only files it opens are the ones named on the command line.
//
// `vale` appears nowhere in this program. It is used by
// `apps/prose/oracle.sh`, which is a test, and the comparison is reported as
// agreement counts rather than asserted. `lint --vale` prints vale's own JSON
// shape for that comparison.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."
import prose ".."

main :: proc() {
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	// No arguments: there is no window to open, so the answer is the help.
	fmt.eprint(kit.cli_help_text(surface()))
	os.exit(kit.EXIT_USAGE)
}

// ---------------------------------------------------------------------------
// Shared steps
// ---------------------------------------------------------------------------

// build_engine loads the embedded packs, plus a StylesPath if one was named.
build_engine :: proc(c: ^kit.Call) -> prose.Engine {
	e := prose.engine_builtin()
	if p := kit.cli_str(c, "styles-path"); p != "" {
		n, err := prose.engine_load_dir(&e, p)
		if err != "" {
			kit.cli_note(c, "prose: %s", err)
		} else {
			kit.cli_note(c, "prose: loaded %d style(s) from %s", n, p)
		}
	}
	for err in e.errors {
		kit.cli_note(c, "prose: %s", err)
	}
	return e
}

// pick_pack resolves --style. An unknown name is "not found", with the names
// that do exist beside the refusal.
pick_pack :: proc(c: ^kit.Call, e: ^prose.Engine) -> (idx: int, code: int) {
	name := kit.cli_str(c, "style")
	if name == "" {
		return 0, kit.EXIT_OK
	}
	i := prose.pack_index(e, name)
	if i < 0 {
		names := make([dynamic]string, context.temp_allocator)
		for p in e.packs {
			append(&names, p.name)
		}
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no style named %q", name)
		kit.cli_err_field(c, "available", strings.join(names[:], ",", context.temp_allocator))
		return 0, code
	}
	return i, kit.EXIT_OK
}

read_file :: proc(c: ^kit.Call, path: string) -> (text: string, code: int) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return "", kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", path)
	}
	return string(data), kit.EXIT_OK
}

level_of :: proc(s: string) -> prose.Severity {
	switch s {
	case "error":
		return .Error
	case "warning":
		return .Warning
	}
	return .Suggestion
}

// ---------------------------------------------------------------------------
// styles
// ---------------------------------------------------------------------------

cmd_styles :: proc(c: ^kit.Call) -> int {
	e := build_engine(c)
	defer prose.engine_destroy(&e)
	if c.json {
		arr := kit.jarr()
		for p in e.packs {
			o := kit.jobj()
			kit.jset_str(o, "name", p.name)
			kit.jset_str(o, "about", p.about)
			kit.jset_int(o, "rules", len(p.rules))
			kit.jset_str(o, "source", p.source)
			kinds := kit.jobj()
			counts: [prose.Rule_Kind]int
			for r in p.rules {
				counts[r.kind] += 1
			}
			for k in prose.Rule_Kind {
				if counts[k] > 0 {
					kit.jset_int(kinds, prose.RULE_KIND_NAME[k], counts[k])
				}
			}
			kit.jset(o, "kinds", kinds)
			kit.jpush(arr, o)
		}
		kit.jset(c.out, "styles", arr)
		kit.jset_int(c.out, "skipped_spelling", e.skipped_spelling)
		return kit.EXIT_OK
	}
	for p in e.packs {
		fmt.printfln("%-14s %d rules", p.name, len(p.rules))
		fmt.printfln("               %s", p.about)
		kinds: [prose.Rule_Kind]int
		for r in p.rules {
			kinds[r.kind] += 1
		}
		fmt.printf("               ")
		first := true
		for k in prose.Rule_Kind {
			if kinds[k] == 0 {
				continue
			}
			if !first {
				fmt.printf(", ")
			}
			fmt.printf("%s %d", prose.RULE_KIND_NAME[k], kinds[k])
			first = false
		}
		fmt.println()
		fmt.println()
	}
	if e.skipped_spelling > 0 {
		fmt.printfln(
			"note: %d spelling rule(s) are loaded but produce nothing — no dictionary on this machine.",
			e.skipped_spelling,
		)
	}
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// lint
// ---------------------------------------------------------------------------

// alert_json is one alert in vale's own field names, so anything that already
// reads vale's output reads these.
alert_json :: proc(a: prose.Alert) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_int(o, "Line", a.line)
	span := kit.jarr()
	kit.jpush(span, kit.jint(a.col))
	kit.jpush(span, kit.jint(a.end_col))
	kit.jset(o, "Span", span)
	kit.jset_str(o, "Check", a.rule)
	kit.jset_str(o, "Severity", prose.SEVERITY_NAME[a.sev])
	kit.jset_str(o, "Match", a.match)
	kit.jset_str(o, "Message", a.message)
	kit.jset_str(o, "Fix", a.fix)
	return o
}

cmd_lint :: proc(c: ^kit.Call) -> int {
	e := build_engine(c)
	defer prose.engine_destroy(&e)
	path := kit.cli_str(c, "file")
	src, rc := read_file(c, path)
	if rc != kit.EXIT_OK {
		return rc
	}
	pack, pc := pick_pack(c, &e)
	if pc != kit.EXIT_OK {
		return pc
	}
	o := prose.Opts {
		pack              = pack,
		min_sev           = level_of(kit.cli_str(c, "level")),
		lint_front_matter = kit.cli_bool(c, "front-matter"),
	}
	res := prose.lint(&e, src, o)
	defer prose.result_destroy(&res)

	if kit.cli_bool(c, "vale") {
		// vale's shape: one key, the file, holding its alerts. It has no
		// fixed field names, so it is an alternative to the declared document
		// rather than a form of it, and is only ever JSON.
		c.json = true
		arr := kit.jarr()
		for a in res.alerts {
			kit.jpush(arr, alert_json(a))
		}
		c.out = kit.jobj()
		kit.jset(c.out, path, arr)
		return kit.EXIT_OK
	}
	if c.json {
		kit.jset_str(c.out, "file", path)
		kit.jset_str(c.out, "style", e.packs[o.pack].name)
		kit.jset_int(c.out, "words", res.counts.words)
		kit.jset_int(c.out, "count", len(res.alerts))
		arr := kit.jarr()
		for a in res.alerts {
			kit.jpush(arr, alert_json(a))
		}
		kit.jset(c.out, "alerts", arr)
		return kit.EXIT_OK
	}
	for a in res.alerts {
		fmt.printfln(
			"%s:%d:%d: %-10s %s  [%s]",
			path,
			a.line,
			a.col,
			prose.SEVERITY_NAME[a.sev],
			a.message,
			a.rule,
		)
		if a.has_fix && a.fix != "" {
			fmt.printfln("    → %q", a.fix)
		}
	}
	fmt.printfln(
		"%d alert(s) from %s over %d words",
		len(res.alerts),
		e.packs[o.pack].name,
		res.counts.words,
	)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

cmd_report :: proc(c: ^kit.Call) -> int {
	e := build_engine(c)
	defer prose.engine_destroy(&e)
	path := kit.cli_str(c, "file")
	src, rc := read_file(c, path)
	if rc != kit.EXIT_OK {
		return rc
	}
	pack, pc := pick_pack(c, &e)
	if pc != kit.EXIT_OK {
		return pc
	}
	o := prose.Opts {
		pack = pack,
	}
	res := prose.lint(&e, src, o)
	defer prose.result_destroy(&res)
	rp := prose.report_of(&res)
	defer prose.report_destroy(&rp)

	if c.json {
		// The same keys this command has always printed under --json.
		kit.jset_int(c.out, "words", rp.words)
		kit.jset_int(c.out, "sentences", rp.sentences)
		kit.jset_int(c.out, "paragraphs", rp.paragraphs)
		kit.jset_num(c.out, "minutes", rp.minutes)
		kit.jset_num(c.out, "grade_mean", rp.grade_mean)
		kit.jset_num(c.out, "ease", rp.ease)
		kit.jset_num(c.out, "sd", rp.len_sd)
		kit.jset_str(c.out, "caveat", rp.caveat)
		metrics := kit.jobj()
		for g in rp.grades {
			kit.jset(metrics, prose.METRIC_NAME[g.metric], g.ok ? kit.jnum(g.value) : kit.jnull())
		}
		kit.jset(c.out, "metrics", metrics)
		issues := kit.jarr()
		for t in rp.issues {
			it := kit.jobj()
			kit.jset_str(it, "rule", t.rule)
			kit.jset_int(it, "n", t.n)
			kit.jpush(issues, it)
		}
		kit.jset(c.out, "issues", issues)
		return kit.EXIT_OK
	}

	fmt.printfln("%s — %s", path, e.packs[o.pack].name)
	fmt.printfln(
		"  %d words, %d sentences, %d paragraphs, %s",
		rp.words,
		rp.sentences,
		rp.paragraphs,
		rp.words == 0 \
		? "nothing to read" \
		: (rp.minutes < 1 ? "under a minute to read" : fmt.tprintf("about %d min to read", int(rp.minutes + 0.5))),
	)
	fmt.println()
	fmt.println("  Readability (estimates, see the note below)")
	for g in rp.grades {
		if !g.ok {
			fmt.printfln("    %-24s  —      (not enough text)", prose.METRIC_NAME[g.metric])
			continue
		}
		fmt.printfln("    %-24s  %6s  %s", prose.METRIC_NAME[g.metric], fmt.tprintf("%.1f", g.value), g.band)
	}
	if rp.grade_ok {
		fmt.printfln(
			"    %-24s  %6s  %s",
			"mean of the grades",
			fmt.tprintf("%.1f", rp.grade_mean),
			prose.band(rp.grade_mean),
		)
	}
	fmt.println()
	fmt.printfln(
		"  Sentence length  min %d, median %d, mean %.1f, max %d, sd %.1f",
		rp.len_min,
		rp.len_median,
		rp.len_mean,
		rp.len_max,
		rp.len_sd,
	)
	fmt.printfln("                   %s", prose.variance_note(&rp))
	for n, i in rp.buckets {
		if n == 0 {
			continue
		}
		bar := strings.repeat("#", min(n, 40), context.temp_allocator)
		fmt.printfln("    %-6s %3d  %s", prose.BUCKET_LABEL[i], n, bar)
	}
	if len(rp.openers) > 0 {
		fmt.println()
		fmt.println("  Sentences starting with the same word")
		for o2 in rp.openers {
			fmt.printfln("    %-14s %d times", o2.word, o2.n)
		}
	}
	if len(rp.issues) > 0 {
		fmt.println()
		fmt.println("  What recurs")
		for t in rp.issues {
			fmt.printfln(
				"    %-30s %3d  %s%s",
				t.rule,
				t.n,
				prose.SEVERITY_NAME[t.sev],
				t.fix ? "  (rewrite offered)" : "",
			)
		}
	}
	fmt.println()
	fmt.printfln("  %s", rp.caveat)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// explain
// ---------------------------------------------------------------------------

cmd_explain :: proc(c: ^kit.Call) -> int {
	e := build_engine(c)
	defer prose.engine_destroy(&e)
	want := kit.cli_str(c, "rule")
	only := kit.cli_str(c, "style")
	lw := strings.to_lower(want, context.temp_allocator)
	rules := kit.jarr()
	found := 0
	for p in e.packs {
		if only != "" && p.name != only {
			continue
		}
		for r in p.rules {
			if !strings.contains(strings.to_lower(r.name, context.temp_allocator), lw) {
				continue
			}
			found += 1
			if c.json {
				o := kit.jobj()
				kit.jset_str(o, "name", r.name)
				kit.jset_str(o, "style", p.name)
				kit.jset_str(o, "kind", prose.RULE_KIND_NAME[r.kind])
				kit.jset_str(o, "severity", prose.SEVERITY_NAME[r.sev])
				kit.jset_str(o, "message", r.message)
				kit.jset_str(o, "description", r.desc)
				kit.jset_str(o, "link", r.link)
				kit.jpush(rules, o)
				continue
			}
			fmt.printfln("%s  (%s, %s)", r.name, prose.RULE_KIND_NAME[r.kind], prose.SEVERITY_NAME[r.sev])
			if r.message != "" {
				fmt.printfln("  says: %s", r.message)
			}
			if r.desc != "" {
				rest := r.desc
				for line in strings.split_lines_iterator(&rest) {
					fmt.printfln("  %s", line)
				}
			}
			if r.link != "" {
				fmt.printfln("  see: %s", r.link)
			}
			fmt.println()
		}
	}
	if found == 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no rule matching %q", want)
	}
	if c.json {
		kit.jset_str(c.out, "query", want)
		kit.jset(c.out, "rules", rules)
	}
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// fix
// ---------------------------------------------------------------------------

// fixed_text is the file with every offered rewrite taken, applied back to
// front so an earlier edit cannot move a later span.
fixed_text :: proc(src: string, alerts: []prose.Alert) -> (out: string, applied: int) {
	out = src
	for i := len(alerts) - 1; i >= 0; i -= 1 {
		a := alerts[i]
		if !a.has_fix || a.fix == "" {
			continue
		}
		if a.from < 0 || a.to > len(out) {
			continue
		}
		out = strings.concatenate({out[:a.from], a.fix, out[a.to:]}, context.temp_allocator)
		applied += 1
	}
	return
}

cmd_fix :: proc(c: ^kit.Call) -> int {
	e := build_engine(c)
	defer prose.engine_destroy(&e)
	path := kit.cli_str(c, "file")
	src, rc := read_file(c, path)
	if rc != kit.EXIT_OK {
		return rc
	}
	pack, pc := pick_pack(c, &e)
	if pc != kit.EXIT_OK {
		return pc
	}
	res := prose.lint(&e, src, prose.Opts{pack = pack})
	defer prose.result_destroy(&res)

	out, n := fixed_text(src, res.alerts[:])
	if c.json {
		kit.jset_str(c.out, "file", path)
		kit.jset_int(c.out, "applied", n)
		kit.jset_int(c.out, "alerts", len(res.alerts))
		kit.jset_str(c.out, "text", out)
		return kit.EXIT_OK
	}
	fmt.print(out)
	kit.cli_note(c, "prose: applied %d of %d suggestion(s)", n, len(res.alerts))
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// segment, syllables, bench: the measurements
// ---------------------------------------------------------------------------

cmd_segment :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "file")
	if !c.json {
		code := prose.segment_accuracy_report(path)
		if code == kit.EXIT_NOT_FOUND {
			return kit.cli_failf(c, code, "cannot read %s", path)
		}
		return code
	}
	sc := prose.segment_score(false)
	prec := sc.predicted > 0 ? f64(sc.hits) / f64(sc.predicted) * 100 : 0
	rec := sc.expected > 0 ? f64(sc.hits) / f64(sc.expected) * 100 : 0
	f1 := (prec + rec) > 0 ? 2 * prec * rec / (prec + rec) : 0
	kit.jset_int(c.out, "cases", sc.cases)
	kit.jset_int(c.out, "boundaries", sc.expected)
	kit.jset_int(c.out, "found", sc.predicted)
	kit.jset_int(c.out, "correct", sc.hits)
	kit.jset_int(c.out, "exact", sc.exact)
	kit.jset_num(c.out, "precision", prec)
	kit.jset_num(c.out, "recall", rec)
	kit.jset_num(c.out, "f1", f1)
	if path != "" {
		n, ok := prose.segment_file_sentences(path)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", path)
		}
		kit.jset_str(c.out, "file", path)
		kit.jset_int(c.out, "file_sentences", n)
	}
	return kit.EXIT_OK
}

DEFAULT_WORDLIST :: "/usr/share/dict/cracklib-small"

cmd_syllables :: proc(c: ^kit.Call) -> int {
	list := kit.cli_str(c, "wordlist")
	if list == "" {
		list = DEFAULT_WORDLIST
	}
	n := kit.cli_int(c, "n", 2000)
	if !c.json {
		code := prose.syllable_error_report(list, n)
		if code == prose.SYL_NOT_FOUND {
			return kit.cli_failf(c, code, "cannot read %s", list)
		}
		return code
	}
	r, code, why := prose.syllable_oracle(list, n)
	defer delete(r.disagreements)
	if code != 0 {
		return kit.cli_fail(c, code, why)
	}
	kit.jset_str(c.out, "list", list)
	kit.jset_int(c.out, "words", r.words)
	kit.jset_int(c.out, "agree", r.agree)
	kit.jset_num(c.out, "error_rate", f64(r.words - r.agree) / f64(r.words) * 100)
	kit.jset_int(c.out, "off_by_one", r.off_by_one)
	kit.jset_int(c.out, "over", r.over)
	kit.jset_int(c.out, "under", r.under)
	ds := kit.jarr()
	for d in r.disagreements {
		o := kit.jobj()
		kit.jset_str(o, "word", d.word)
		kit.jset_int(o, "mine", d.mine)
		kit.jset_int(o, "espeak", d.espeak)
		kit.jset_str(o, "ipa", d.ipa)
		kit.jpush(ds, o)
	}
	kit.jset(c.out, "disagreements", ds)
	return kit.EXIT_OK
}

cmd_bench :: proc(c: ^kit.Call) -> int {
	e := build_engine(c)
	defer prose.engine_destroy(&e)
	path := kit.cli_str(c, "file")
	src, rc := read_file(c, path)
	if rc != kit.EXIT_OK {
		return rc
	}
	pack, pc := pick_pack(c, &e)
	if pc != kit.EXIT_OK {
		return pc
	}
	o := prose.Opts {
		pack = pack,
	}

	// The minimum of many runs, not the mean. This machine runs other builds
	// while these are measured and the mean swung by a factor of two between
	// consecutive runs; the minimum is the cost when nothing is competing,
	// which is the number that says what the code does.
	stat :: proc(ms: []f64) -> (lo, mid: f64) {
		slice.sort(ms)
		return ms[0], ms[len(ms) / 2]
	}

	// Not the temp allocator: the loop below calls `free_all` on it, which
	// would free the array being written into. That bug printed 0.000 ms.
	// For the same reason nothing the result needs may live there: the
	// figures are copied out before the loops run.
	full := make([]f64, 40)
	defer delete(full)
	for k in 0 ..< len(full) {
		t := time.now()
		r := prose.lint(&e, src, o)
		full[k] = time.duration_milliseconds(time.since(t))
		prose.result_destroy(&r)
		free_all(context.temp_allocator)
	}
	full_lo, full_mid := stat(full)

	// A keystroke: the paragraph the caret is in, which is the window the
	// application re-analyses.
	mid := len(src) / 2
	from, to := mid, mid
	for from > 0 && !(src[from] == '\n' && from + 1 < len(src) && src[from + 1] == '\n') {
		from -= 1
	}
	for to < len(src) && !(src[to] == '\n' && to + 1 < len(src) && src[to + 1] == '\n') {
		to += 1
	}
	win := make([]f64, 400)
	defer delete(win)
	for k in 0 ..< len(win) {
		t := time.now()
		r := prose.lint_window(&e, src, from, to, o)
		win[k] = time.duration_milliseconds(time.since(t))
		prose.result_destroy(&r)
		free_all(context.temp_allocator)
	}
	win_lo, win_mid := stat(win)

	rules := len(e.packs[o.pack].rules)
	if c.json {
		kit.jset_str(c.out, "file", path)
		kit.jset_int(c.out, "bytes", len(src))
		kit.jset_str(c.out, "style", e.packs[o.pack].name)
		kit.jset_int(c.out, "rules", rules)
		kit.jset_num(c.out, "full_min_ms", full_lo)
		kit.jset_num(c.out, "full_median_ms", full_mid)
		kit.jset_num(c.out, "paragraph_min_ms", win_lo)
		kit.jset_num(c.out, "paragraph_median_ms", win_mid)
		kit.jset_int(c.out, "paragraph_bytes", to - from)
		return kit.EXIT_OK
	}
	fmt.printfln("%s  %d bytes, %s, %d rules", path, len(src), e.packs[o.pack].name, rules)
	// Odin's `fmt` pads numbers with zeros, not spaces, so the columns are
	// built as strings.
	fmt.printfln(
		"  full pass        min %7s ms   median %7s ms",
		fmt.tprintf("%.3f", full_lo),
		fmt.tprintf("%.3f", full_mid),
	)
	fmt.printfln(
		"  one paragraph    min %7s ms   median %7s ms   (%d bytes)",
		fmt.tprintf("%.3f", win_lo),
		fmt.tprintf("%.3f", win_mid),
		to - from,
	)
	return kit.EXIT_OK
}
