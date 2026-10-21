package main

// The declaration of prose's command line, read by apps/kit/cli.odin.
//
// Every verb here is a read: prose never writes a file. `fix` prints the
// rewritten text and leaves the file alone, which is why it is a read and not
// a mutate. The measurements (`segment`, `syllables`, `bench`) kept their
// older spellings `--segment`, `--syllables` and `--bench` as aliases.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import prose ".."

// FIXTURE is the synthetic document the examples name, relative to the
// repository root, which is where `palm --selftest` runs them from.
FIXTURE :: "apps/prose/testdata/sample.md"

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "styles",
		summary = "the style packs, what each is for and how many rules it has",
		effect = .Read,
		flags = {{name = "styles-path", kind = .Path, help = "also load a Vale StylesPath from disk"}},
		out = {
			{
				name = "styles",
				kind = .Array,
				help = "one entry per pack",
				of = {
					{name = "name", kind = .String},
					{name = "about", kind = .String},
					{name = "rules", kind = .Int},
					{name = "source", kind = .String, help = "\"built-in\" or the directory it came from"},
					{name = "kinds", kind = .Object, help = "rule count by kind"},
				},
			},
			{name = "skipped_spelling", kind = .Int, help = "spelling rules loaded but inert: no dictionary here"},
		},
		examples = {"prose styles --json"},
		run = cmd_styles,
	},
	{
		verb = "lint",
		summary = "every problem in a file, with the rewrite where one is offered",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "a Markdown or plain-text file", required = true}},
		flags = {
			{name = "style", kind = .String, help = "the pack to lint with (see `prose styles`)"},
			{name = "level", kind = .Enum, values = {"suggestion", "warning", "error"}, def = "suggestion", help = "the least severe alert to report"},
			{name = "styles-path", kind = .Path, help = "also load a Vale StylesPath from disk"},
			{name = "front-matter", kind = .Bool, help = "lint the YAML front matter too"},
			{name = "vale", kind = .Bool, help = "print vale's own JSON shape, {FILE: [alerts]}, instead"},
		},
		out = {
			{name = "file", kind = .String},
			{name = "style", kind = .String},
			{name = "words", kind = .Int},
			{name = "count", kind = .Int, help = "how many alerts"},
			{
				name = "alerts",
				kind = .Array,
				help = "in vale's field names",
				of = {
					{name = "Line", kind = .Int},
					{name = "Span", kind = .Array, help = "first and last column", of = {{kind = .Int}}},
					{name = "Check", kind = .String, help = "the rule, Pack.Rule"},
					{name = "Severity", kind = .String},
					{name = "Match", kind = .String},
					{name = "Message", kind = .String},
					{name = "Fix", kind = .String, help = "the rewrite, or empty"},
				},
			},
		},
		examples = {
			"prose lint apps/prose/testdata/sample.md --json",
			"prose lint apps/prose/testdata/sample.md --style Plain --level warning --json",
			"prose lint apps/prose/testdata/sample.md --vale --json",
		},
		run = cmd_lint,
	},
	{
		verb = "report",
		summary = "the writing report: length, readability grades and what recurs",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "a Markdown or plain-text file", required = true}},
		flags = {
			{name = "style", kind = .String, help = "the pack whose alerts are tallied"},
			{name = "styles-path", kind = .Path, help = "also load a Vale StylesPath from disk"},
		},
		out = {
			{name = "words", kind = .Int},
			{name = "sentences", kind = .Int},
			{name = "paragraphs", kind = .Int},
			{name = "minutes", kind = .Float, help = "reading time"},
			{name = "grade_mean", kind = .Float},
			{name = "ease", kind = .Float, help = "Flesch reading ease"},
			{name = "sd", kind = .Float, help = "spread of sentence length"},
			{name = "caveat", kind = .String},
			{name = "metrics", kind = .Object, help = "each readability formula, or null where there is not enough text"},
			{name = "issues", kind = .Array, of = {{name = "rule", kind = .String}, {name = "n", kind = .Int}}},
		},
		examples = {"prose report apps/prose/testdata/sample.md --json", "prose report apps/prose/testdata/sample.md --style Plain --json"},
		run = cmd_report,
	},
	{
		verb = "explain",
		summary = "what a rule checks for, and why",
		effect = .Read,
		args = {{name = "rule", kind = .String, help = "a rule name, or part of one", required = true}},
		flags = {
			{name = "style", kind = .String, help = "only this pack"},
			{name = "styles-path", kind = .Path, help = "also load a Vale StylesPath from disk"},
		},
		out = {
			{name = "query", kind = .String},
			{
				name = "rules",
				kind = .Array,
				of = {
					{name = "name", kind = .String},
					{name = "style", kind = .String},
					{name = "kind", kind = .String},
					{name = "severity", kind = .String},
					{name = "message", kind = .String},
					{name = "description", kind = .String},
					{name = "link", kind = .String},
				},
			},
		},
		examples = {"prose explain Passive --json", "prose explain Wordy --style Plain --json"},
		run = cmd_explain,
	},
	{
		verb = "fix",
		summary = "the file with every offered rewrite taken, printed; the file is not touched",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "a Markdown or plain-text file", required = true}},
		flags = {
			{name = "style", kind = .String, help = "the pack whose rewrites are taken"},
			{name = "styles-path", kind = .Path, help = "also load a Vale StylesPath from disk"},
		},
		out = {
			{name = "file", kind = .String},
			{name = "applied", kind = .Int, help = "rewrites taken"},
			{name = "alerts", kind = .Int, help = "alerts found"},
			{name = "text", kind = .String, help = "the rewritten text"},
		},
		examples = {"prose fix apps/prose/testdata/sample.md --json", "prose fix apps/prose/testdata/sample.md --style Plain"},
		run = cmd_fix,
	},
	{
		verb = "segment",
		summary = "sentence segmentation measured against the hand-marked corpus",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "also count the sentences in this file"}},
		out = {
			{name = "cases", kind = .Int},
			{name = "boundaries", kind = .Int, help = "hand-marked"},
			{name = "found", kind = .Int},
			{name = "correct", kind = .Int},
			{name = "exact", kind = .Int, help = "cases with every boundary right"},
			{name = "precision", kind = .Float, help = "percent"},
			{name = "recall", kind = .Float, help = "percent"},
			{name = "f1", kind = .Float, help = "percent"},
			{name = "file", kind = .String, opt = true},
			{name = "file_sentences", kind = .Int, opt = true},
		},
		examples = {"prose segment --json", "prose segment apps/prose/testdata/sample.md --json"},
		aliases = {"--segment"},
		run = cmd_segment,
	},
	{
		verb = "syllables",
		summary = "the syllable counter's error rate against espeak-ng, over a word list",
		effect = .Read,
		args = {{name = "wordlist", kind = .Path, help = "one word per line", def = DEFAULT_WORDLIST}},
		flags = {{name = "n", kind = .Int, help = "how many words to sample", def = "2000"}},
		out = {
			{name = "list", kind = .String},
			{name = "words", kind = .Int},
			{name = "agree", kind = .Int},
			{name = "error_rate", kind = .Float, help = "percent"},
			{name = "off_by_one", kind = .Int},
			{name = "over", kind = .Int},
			{name = "under", kind = .Int},
			{
				name = "disagreements",
				kind = .Array,
				help = "the first 25",
				of = {
					{name = "word", kind = .String},
					{name = "mine", kind = .Int},
					{name = "espeak", kind = .Int},
					{name = "ipa", kind = .String},
				},
			},
		},
		examples = {"prose syllables --n 500 --json"},
		aliases = {"--syllables"},
		run = cmd_syllables,
	},
	{
		verb = "bench",
		summary = "how long a full pass and a one-paragraph pass take over a file",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "the document to time", required = true}},
		flags = {
			{name = "style", kind = .String, help = "the pack to time"},
			{name = "styles-path", kind = .Path, help = "also load a Vale StylesPath from disk"},
		},
		out = {
			{name = "file", kind = .String},
			{name = "bytes", kind = .Int},
			{name = "style", kind = .String},
			{name = "rules", kind = .Int},
			{name = "full_min_ms", kind = .Float},
			{name = "full_median_ms", kind = .Float},
			{name = "paragraph_min_ms", kind = .Float},
			{name = "paragraph_median_ms", kind = .Float},
			{name = "paragraph_bytes", kind = .Int},
		},
		examples = {"prose bench apps/prose/testdata/sample.md --json"},
		aliases = {"--bench"},
		run = cmd_bench,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "prose",
			summary  = "a Vale-compatible prose linter, and the engine behind the writing report",
			selftest = run_selftest,
			commands = COMMANDS,
			notes    = "Style packs ship inside the binary and work with no network and no `vale sync`.\n--styles-path adds a Vale StylesPath from disk. Nothing here writes a file.\nThe older spellings --segment, --syllables and --bench still work.",
		}
	}
	return &g_surface
}

// ---------------------------------------------------------------------------
// --selftest: the library's assertions, then the command line's
// ---------------------------------------------------------------------------

@(private = "file")
cli_checks, cli_failures: int

@(private = "file")
ck :: proc(ok: bool, what: string) {
	cli_checks += 1
	if !ok {
		cli_failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

run_selftest :: proc() -> int {
	verbose := false
	for a in os.args[1:] {
		if a == "--verbose" || a == "-v" {
			verbose = true
		}
	}
	lib := prose.selftest(verbose)
	cli_selftest()
	fmt.printfln("prose command line: %d checks, %d failed", cli_checks, cli_failures)
	return lib == 0 && cli_failures == 0 ? 0 : 7
}

// run_json runs one command line through the real binding and the real body,
// with --json, and returns the document it would print.
@(private = "file")
run_json :: proc(argv: []string) -> (text: string, code: int, cmd: ^kit.Command) {
	full := make([dynamic]string, context.temp_allocator)
	append(&full, ..argv)
	append(&full, "--json")
	c, bc := kit.cli_bind(surface(), full[:])
	if bc != kit.EXIT_OK {
		return "", bc, c.cmd
	}
	code = c.cmd.run(&c)
	if code != kit.EXIT_OK {
		return "", code, c.cmd
	}
	return kit.json_text(c.out, 2, context.temp_allocator), code, c.cmd
}

@(private = "file")
cli_selftest :: proc() {
	s := surface()
	ck(len(s.commands) >= 8, "the surface declares every verb")
	schema := kit.json_text(kit.cli_schema_json(s), 2, context.temp_allocator)
	ck(strings.contains(schema, `"noun": "prose"`), "--schema names the noun")

	for cmd in s.commands {
		ck(cmd.effect == .Read, fmt.tprintf("%s is a read: prose writes nothing", cmd.verb))
		ck(len(cmd.out) > 0, fmt.tprintf("%s declares what it prints", cmd.verb))
		ck(len(cmd.examples) > 0, fmt.tprintf("%s ships an example", cmd.verb))
		ck(strings.contains(kit.cli_help_text(s, cmd.verb), cmd.verb), fmt.tprintf("help %s is about %s", cmd.verb, cmd.verb))
		for ex in cmd.examples {
			words := kit.cli_split_example(ex)
			ck(len(words) > 0 && words[0] == "prose", fmt.tprintf("%q is typed as the binary is named", ex))
			_, code := kit.cli_bind(s, words[1:])
			ck(code == kit.EXIT_OK, fmt.tprintf("the example %q binds", ex))
		}
	}

	// The older spellings still reach the same verbs.
	for legacy in ([?][2]string{{"--segment", "segment"}, {"--syllables", "syllables"}, {"--bench", "bench"}}) {
		argv := legacy[0] == "--bench" ? []string{legacy[0], FIXTURE} : []string{legacy[0]}
		c, code := kit.cli_bind(s, argv)
		ck(code == kit.EXIT_OK && c.cmd != nil && c.cmd.verb == legacy[1], fmt.tprintf("the old spelling %s is still %s", legacy[0], legacy[1]))
	}
	{
		c, code := kit.cli_bind(s, {"lint", FIXTURE, "--style=Plain", "--level", "warning", "--json"})
		ck(code == kit.EXIT_OK && kit.cli_str(&c, "style") == "Plain" && kit.cli_str(&c, "level") == "warning", "lint FILE --style=NAME --level L still parses")
		_, bad := kit.cli_bind(s, {"lint", FIXTURE, "--level", "loud"})
		ck(bad == kit.EXIT_USAGE, "an unknown --level is a usage error")
		_, none := kit.cli_bind(s, {"lint"})
		ck(none == kit.EXIT_USAGE, "lint with no file is a usage error, not a crash")
	}

	// The documents, from the real bodies, against the declarations. The
	// fixture is read from the repository root or from apps/prose/cli, so the
	// self-test works from either.
	fixture := FIXTURE
	if !os.exists(fixture) {
		for cand in ([?]string{"../testdata/sample.md", "testdata/sample.md", "../../../" + FIXTURE}) {
			if os.exists(cand) {
				fixture = cand
				break
			}
		}
	}
	ck(os.exists(fixture), "the synthetic fixture is there to read")
	for argv in ([][]string {
		{"styles"},
		{"lint", fixture},
		{"report", fixture},
		{"explain", "Passive"},
		{"fix", fixture},
		{"segment"},
		{"segment", fixture},
	}) {
		text, code, cmd := run_json(argv)
		ck(code == kit.EXIT_OK, fmt.tprintf("%s --json runs", argv[0]))
		if code != kit.EXIT_OK || cmd == nil {
			continue
		}
		problems := kit.cli_validate_output(text, cmd.out, context.temp_allocator)
		ck(len(problems) == 0, fmt.tprintf("%s --json matches its declaration%s", argv[0], len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : ""))
	}
	{
		text, code, _ := run_json({"lint", fixture})
		ck(code == kit.EXIT_OK && strings.contains(text, `"Check"`), "lint finds something in a fixture written badly on purpose")
		vtext, vcode, _ := run_json({"lint", fixture, "--vale"})
		ck(vcode == kit.EXIT_OK && strings.has_prefix(strings.trim_space(vtext), fmt.tprintf("{{\n  %q: [", fixture)), "lint --vale keeps vale's {FILE: [alerts]} shape")
	}
	{
		_, code, _ := run_json({"lint", "/nonexistent/prose-fixture.md"})
		ck(code == kit.EXIT_NOT_FOUND, "a missing file is exit 3")
		_, scode, _ := run_json({"lint", fixture, "--style", "NoSuchPack"})
		ck(scode == kit.EXIT_NOT_FOUND, "an unknown style is exit 3")
		_, ecode, _ := run_json({"explain", "zzzz-no-such-rule"})
		ck(ecode == kit.EXIT_NOT_FOUND, "an unknown rule is exit 3")
	}
	{
		// fix never writes: the file is byte-for-byte what it was.
		before, _ := os.read_entire_file_from_path(fixture, context.temp_allocator)
		text, code, _ := run_json({"fix", fixture})
		after, _ := os.read_entire_file_from_path(fixture, context.temp_allocator)
		ck(code == kit.EXIT_OK && string(before) == string(after), "fix leaves the file alone")
		ck(strings.contains(text, `"applied"`), "and reports how many rewrites it took")
	}
}
