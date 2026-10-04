package main

// prose — the engine half of the writing-improvement feature.
//
//	prose styles                       list the packs and what each is for
//	prose lint   FILE [--style NAME] [--json] [--level L] [--styles-path DIR]
//	prose report FILE [--style NAME] [--json]
//	prose explain RULE [--style NAME]
//	prose fix    FILE [--style NAME]   print the file with every suggestion taken
//	prose --selftest [--verbose]
//	prose --segment [FILE]             segmentation accuracy on the corpus
//	prose --syllables [FILE] [--n N]   syllable error rate against espeak-ng
//	prose --bench FILE                 per-keystroke and full-pass timings
//
// The same code the notes application runs. Nothing here reaches the network,
// and the only files it opens are the ones named on the command line.
//
// `vale` appears nowhere in this program. It is used by
// `apps/prose/oracle.sh`, which is a test, and the comparison is reported as
// agreement counts rather than asserted.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import prose ".."

EXIT_OK :: 0
EXIT_USAGE :: 2
EXIT_NOTFOUND :: 3
EXIT_FAILED :: 7

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(EXIT_USAGE)
	}
	switch args[0] {
	case "--selftest":
		os.exit(prose.selftest(has(args, "--verbose")) == 0 ? EXIT_OK : EXIT_FAILED)
	case "--segment":
		os.exit(cmd_segment(args[1:]))
	case "--syllables":
		os.exit(cmd_syllables(args[1:]))
	case "--bench":
		os.exit(cmd_bench(args[1:]))
	case "styles":
		os.exit(cmd_styles(args[1:]))
	case "lint":
		os.exit(cmd_lint(args[1:]))
	case "report":
		os.exit(cmd_report(args[1:]))
	case "explain":
		os.exit(cmd_explain(args[1:]))
	case "fix":
		os.exit(cmd_fix(args[1:]))
	case "-h", "--help":
		usage()
		os.exit(EXIT_OK)
	}
	fmt.eprintfln("prose: unknown command %q", args[0])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.eprintln(
		`prose — a native Vale-compatible prose linter, and the engine behind
the writing report in apps/notes.

  prose styles [--styles-path DIR]
  prose lint   FILE [--style NAME] [--level suggestion|warning|error]
                    [--json] [--styles-path DIR] [--front-matter]
  prose report FILE [--style NAME] [--json]
  prose explain RULE [--style NAME]
  prose fix    FILE [--style NAME]
  prose --selftest [--verbose]
  prose --segment [FILE]
  prose --syllables [WORDLIST] [--n N]
  prose --bench FILE

Style packs ship inside the binary and work with no network and no
`+"`vale sync`"+`. --styles-path adds a Vale StylesPath from disk.`,
	)
}

has :: proc(args: []string, flag: string) -> bool {
	for a in args {
		if a == flag {
			return true
		}
	}
	return false
}

opt :: proc(args: []string, flag: string, def := "") -> string {
	for a, i in args {
		if a == flag && i + 1 < len(args) {
			return args[i + 1]
		}
		if strings.has_prefix(a, flag) && len(a) > len(flag) && a[len(flag)] == '=' {
			return a[len(flag) + 1:]
		}
	}
	return def
}

first_positional :: proc(args: []string) -> string {
	skip := false
	for a in args {
		if skip {
			skip = false
			continue
		}
		if strings.has_prefix(a, "--") {
			if !strings.contains(a, "=") &&
			   (a == "--style" || a == "--level" || a == "--styles-path" || a == "--n") {
				skip = true
			}
			continue
		}
		return a
	}
	return ""
}

// build_engine loads the embedded packs, plus a StylesPath if one was named.
build_engine :: proc(args: []string) -> prose.Engine {
	e := prose.engine_builtin()
	if p := opt(args, "--styles-path"); p != "" {
		n, err := prose.engine_load_dir(&e, p)
		if err != "" {
			fmt.eprintfln("prose: %s", err)
		} else {
			fmt.eprintfln("prose: loaded %d style(s) from %s", n, p)
		}
	}
	for err in e.errors {
		fmt.eprintfln("prose: %s", err)
	}
	return e
}

pick_pack :: proc(e: ^prose.Engine, name: string) -> int {
	if name == "" {
		return 0
	}
	i := prose.pack_index(e, name)
	if i < 0 {
		fmt.eprintfln("prose: no style named %q", name)
		fmt.eprint("prose: available:")
		for p in e.packs {
			fmt.eprintf(" %s", p.name)
		}
		fmt.eprintln()
		os.exit(EXIT_NOTFOUND)
	}
	return i
}

read_file :: proc(path: string) -> string {
	if path == "" {
		fmt.eprintln("prose: no file given")
		os.exit(EXIT_USAGE)
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("prose: cannot read %s", path)
		os.exit(EXIT_NOTFOUND)
	}
	return string(data)
}

// ---------------------------------------------------------------------------

cmd_styles :: proc(args: []string) -> int {
	e := build_engine(args)
	defer prose.engine_destroy(&e)
	if has(args, "--json") {
		fmt.print("[")
		for p, i in e.packs {
			if i > 0 {
				fmt.print(",")
			}
			fmt.printf(
				"\n  {{\"name\":%q,\"about\":%q,\"rules\":%d,\"source\":%q}}",
				p.name,
				p.about,
				len(p.rules),
				p.source,
			)
		}
		fmt.println("\n]")
		return EXIT_OK
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
	return EXIT_OK
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

cmd_lint :: proc(args: []string) -> int {
	e := build_engine(args)
	defer prose.engine_destroy(&e)
	path := first_positional(args)
	src := read_file(path)
	o := prose.Opts {
		pack              = pick_pack(&e, opt(args, "--style")),
		min_sev           = level_of(opt(args, "--level", "suggestion")),
		lint_front_matter = has(args, "--front-matter"),
	}
	res := prose.lint(&e, src, o)
	defer prose.result_destroy(&res)

	if has(args, "--json") {
		print_json(path, res.alerts)
		return len(res.alerts) == 0 ? EXIT_OK : EXIT_OK
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
	return EXIT_OK
}

print_json :: proc(path: string, alerts: []prose.Alert) {
	fmt.printf("{{\n  %q: [", path)
	for a, i in alerts {
		if i > 0 {
			fmt.print(",")
		}
		fmt.printf(
			"\n    {{\"Line\":%d,\"Span\":[%d,%d],\"Check\":%q,\"Severity\":%q,\"Match\":%q,\"Message\":%q,\"Fix\":%q}}",
			a.line,
			a.col,
			a.end_col,
			a.rule,
			prose.SEVERITY_NAME[a.sev],
			a.match,
			a.message,
			a.fix,
		)
	}
	fmt.println("\n  ]\n}")
}

cmd_report :: proc(args: []string) -> int {
	e := build_engine(args)
	defer prose.engine_destroy(&e)
	path := first_positional(args)
	src := read_file(path)
	o := prose.Opts {
		pack = pick_pack(&e, opt(args, "--style")),
	}
	res := prose.lint(&e, src, o)
	defer prose.result_destroy(&res)
	rp := prose.report_of(&res)
	defer prose.report_destroy(&rp)

	if has(args, "--json") {
		fmt.printf(
			"{{\"words\":%d,\"sentences\":%d,\"paragraphs\":%d,\"minutes\":%.2f,\"grade_mean\":%.2f,\"ease\":%.2f,\"sd\":%.2f,\"caveat\":%q,\"metrics\":{{",
			rp.words,
			rp.sentences,
			rp.paragraphs,
			rp.minutes,
			rp.grade_mean,
			rp.ease,
			rp.len_sd,
			rp.caveat,
		)
		for g, i in rp.grades {
			if i > 0 {
				fmt.print(",")
			}
			fmt.printf("%q:", prose.METRIC_NAME[g.metric])
			if g.ok {
				fmt.printf("%.2f", g.value)
			} else {
				fmt.print("null")
			}
		}
		fmt.print("},\"issues\":[")
		for t, i in rp.issues {
			if i > 0 {
				fmt.print(",")
			}
			fmt.printf("{{\"rule\":%q,\"n\":%d}}", t.rule, t.n)
		}
		fmt.println("]}")
		return EXIT_OK
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
	return EXIT_OK
}

cmd_explain :: proc(args: []string) -> int {
	e := build_engine(args)
	defer prose.engine_destroy(&e)
	want := first_positional(args)
	if want == "" {
		fmt.eprintln("prose explain RULE")
		return EXIT_USAGE
	}
	found := 0
	for p in e.packs {
		for r in p.rules {
			if !strings.contains(strings.to_lower(r.name, context.temp_allocator), strings.to_lower(want, context.temp_allocator)) {
				continue
			}
			found += 1
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
		fmt.eprintfln("prose: no rule matching %q", want)
		return EXIT_NOTFOUND
	}
	return EXIT_OK
}

cmd_fix :: proc(args: []string) -> int {
	e := build_engine(args)
	defer prose.engine_destroy(&e)
	path := first_positional(args)
	src := read_file(path)
	o := prose.Opts {
		pack = pick_pack(&e, opt(args, "--style")),
	}
	res := prose.lint(&e, src, o)
	defer prose.result_destroy(&res)

	// Applied back to front, so an earlier edit cannot move a later span.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, src)
	out := strings.to_string(sb)
	n := 0
	for i := len(res.alerts) - 1; i >= 0; i -= 1 {
		a := res.alerts[i]
		if !a.has_fix || a.fix == "" {
			continue
		}
		if a.from < 0 || a.to > len(out) {
			continue
		}
		out = strings.concatenate({out[:a.from], a.fix, out[a.to:]}, context.temp_allocator)
		n += 1
	}
	fmt.print(out)
	fmt.eprintfln("prose: applied %d of %d suggestion(s)", n, len(res.alerts))
	return EXIT_OK
}

// ---------------------------------------------------------------------------

cmd_segment :: proc(args: []string) -> int {
	return prose.segment_accuracy_report(first_positional(args))
}

cmd_syllables :: proc(args: []string) -> int {
	n := 2000
	if s := opt(args, "--n"); s != "" {
		if v, ok := strconv.parse_int(s); ok {
			n = v
		}
	}
	list := first_positional(args)
	if list == "" {
		list = "/usr/share/dict/cracklib-small"
	}
	return prose.syllable_error_report(list, n)
}

cmd_bench :: proc(args: []string) -> int {
	e := build_engine(args)
	defer prose.engine_destroy(&e)
	path := first_positional(args)
	src := read_file(path)
	o := prose.Opts{pack = pick_pack(&e, opt(args, "--style"))}

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
	return EXIT_OK
}
