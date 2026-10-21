package main

// `palm` — one command surface over every application.
//
// The design is docs/PALM-CLI.md. The short of it: every application is a
// library with two front ends, the window and the command line, and `palm` is
// the door the second one is reached through.
//
// It is a dispatcher of separate binaries rather than one binary with
// subcommands, which is the question the design left open and this answers.
// Separate binaries keep each application independently runnable and
// independently testable — `notes list --json` works with no `palm` installed
// at all — and leave the dispatcher with the two jobs it is actually good at:
// discovery, and enforcing the rules that have to hold across applications.
//
//	palm schema              the whole surface as JSON
//	palm commands            the index, one line per command
//	palm audit               what has been run, and under which identity
//	palm identity            the scope in force
//	palm <noun> <verb> ...   routed to that application's own binary
//
// Nothing is re-implemented here. `palm notes list` runs `notes list`, with
// its stdout passed through byte for byte, because anything else would be a
// second implementation of the thing the whole exercise exists to avoid.
//
// What `palm` adds over running the binary directly:
//
//   - **Discovery.** `palm schema` collects every application's own
//     declaration — the same data the application parses its arguments from —
//     so the index cannot drift from the behaviour.
//   - **Scope.** The identity in force is read from the environment and may
//     only ever be narrowed. A refusal happens here as well as in the
//     application, so the rule holds even against an application that forgot
//     it.
//   - **The verbs that must not exist.** There is no `palm vault` verb that
//     reads across identities, and `palm` refuses to route one even if an
//     application grows it. See FORBIDDEN_VERBS.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

VERSION :: "0.1.0"

// ---------------------------------------------------------------------------
// The nouns
//
// Nouns follow the system, not the source tree: `palm mail` is `palm-mail`
// (the mail area's command line, cloud/mail/palm-mail), `palm net` is the
// network applet, `palm capture` is the screenshot tool.
//
// `on_convention` is the honest statement of where the conversion has got to,
// and `palm --selftest` holds it to that: a noun marked on it must answer
// `--schema` and pass every check below. The rest are listed because the
// surface is the plan, and `palm schema` reports them as unavailable rather
// than pretending. An application is probed for its
// declaration only once this says it has one — a binary that does not know
// `--schema` would open a window instead of answering, and a dispatcher that
// hangs is worse than one that says it does not know yet.
// ---------------------------------------------------------------------------

Noun :: struct {
	noun:          string,
	app:           string, // the directory and binary name under apps/
	summary:       string,
	on_convention: bool,
	src:           string, // where the working tree builds it, when not apps/<app>/
}

NOUNS := []Noun {
	{"notes", "notes", "a notebook of real Markdown files", true, ""},
	{"sheets", "sheets", "a spreadsheet, and the formula engine underneath it", true, ""},
	{"power", "power", "power and session state; session actions are intent only", true, ""},
	{"drive", "drive", "an identity's cloud drive: files, sharing, links, trash", true, ""},
	{"calendar", "calendar", "calendars per identity, on this device and over CalDAV", true, ""},
	{"contacts", "contacts", "address books per identity, over CardDAV", true, ""},
	{"chat", "chat", "team chat: spaces, channels, threads, calls", true, ""},
	{"forge", "forge", "repositories, issues and pull requests owned by identities", true, ""},
	{"ai", "ai", "the assistant: one per identity, confined to it", true, ""},
	{"notify", "notify", "notifications per identity, under a policy written in words", true, ""},
	{"index", "index", "the local search index, one per identity", true, ""},
	{"settings", "settings", "the system's settings", true, ""},
	{"accounts", "accounts", "one account, several identities", true, ""},
	{"welcome", "welcome", "first run: account, identities, what syncs", true, ""},
	{"vault", "vault", "secrets, scoped to one identity", true, ""},
	{"browser", "browser", "a web browser, bookmarks synced per identity", true, ""},
	{"mail", "palm-mail", "an identity's mail in the Palmy cloud: unread, search, read, drafts, send", true, "cloud/mail/palm-mail"},
	{"mailcore", "mailcore", "the mail engine: Maildir, IMAP, POP3, JMAP, SMTP", true, ""},
	{"torrent", "torrent", "a BitTorrent client, loopback only", true, ""},
	{"docs", "docs", "a word processor with a headless converter", true, ""},
	{"slides", "slides", "a presentation editor", true, ""},
	{"money", "money", "accounts, imports and budgets", true, ""},
	{"files", "files", "a file browser", true, ""},
	{"reader", "reader", "an e-book reader", true, ""},
	{"maps", "maps", "a map viewer", true, ""},
	{"shop", "shop", "shopping: search, compare, a basket, lists and price alerts", true, ""},
	{"audio", "audio", "a music player: library, probe, analysis", true, ""},
	{"mixer", "mixer", "output and input levels", true, ""},
	{"net", "network", "network state — read-only, by rule", true, ""},
	{"bluetooth", "bluetooth", "bluetooth devices — read-only, by rule", true, ""},
	{"sysmon", "sysmon", "processes, memory and load", true, ""},
	{"capture", "screenshot", "screenshots, on a private headless compositor", true, ""},
	{"clipboard", "clipboard", "the clipboard history", true, ""},
	{"editor", "editor", "a text editor", true, ""},
	{"image", "image", "an image viewer", true, ""},
	{"prose", "prose", "a Vale-compatible prose linter", true, ""},
	{"pkg", "pkg", "packages: list, search, install, sync, rollback", true, ""},
	{"captions", "captions", "local speech to text, and caption files: show, lint, convert, shift, burn in", true, ""},
	{"videoedit", "videoedit", "a non-linear video editor over project files, exporting through ffmpeg", true, ""},
}

// FORBIDDEN_VERBS are the verbs that must not exist anywhere, and that `palm`
// will not route even if an application grows one.
//
// The README's identity model says a secret belongs to one identity and that
// there is no way to ask for another's. "Not gated, absent" is only true if
// something checks, so this is the check: a refusal here, and an assertion in
// the self-test that no application declares any of them.
Forbidden :: struct {
	noun: string, // "" means any noun
	verb: string,
	why:  string,
}

FORBIDDEN_VERBS := []Forbidden {
	{"vault", "list-all", "a secret is returned only inside its own identity's scope"},
	{"vault", "dump", "a secret is returned only inside its own identity's scope"},
	{"vault", "export-all", "a secret is returned only inside its own identity's scope"},
	{"vault", "all", "a secret is returned only inside its own identity's scope"},
	{"", "list-identities-secrets", "there is no verb that reads across identities"},
}

// ---------------------------------------------------------------------------
// Finding an application's binary
// ---------------------------------------------------------------------------

// bin_dir is where the application binaries are. $PALM_BIN_DIR overrides it,
// which is both how a test points `palm` at a directory with nothing in it to
// see the unavailable path, and how a packaged build would point it at a real
// bindir.
bin_dir :: proc() -> string {
	return os.get_env("PALM_BIN_DIR", context.temp_allocator)
}

// binary_for resolves a noun to a path. Without $PALM_BIN_DIR it looks beside
// this binary, where `apps/<app>/<app>.bin` is what every build script in this
// repository writes.
binary_for :: proc(n: Noun) -> (path: string, found: bool) {
	if over := bin_dir(); over != "" {
		p := fmt.tprintf("%s/%s.bin", over, n.app)
		if os.exists(p) {
			return p, true
		}
		p2 := fmt.tprintf("%s/%s", over, n.app)
		if os.exists(p2) {
			return p2, true
		}
		return p, false
	}
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		self = os.args[0]
	}
	dir := self
	if i := strings.last_index_byte(dir, '/'); i > 0 {
		dir = dir[:i]
	}
	// Beside this binary first, then flat in the same directory, and last the
	// working tree — so `palm` found on $PATH, `apps/palm/palm.bin` run in
	// place, and a copy built into a scratch directory while standing in the
	// repository all find the same applications.
	for cand in ([?]string {
		fmt.tprintf("%s/../%s/%s.bin", dir, n.app, n.app),
		fmt.tprintf("%s/%s.bin", dir, n.app),
		fmt.tprintf("apps/%s/%s.bin", n.app, n.app),
		// An application built outside apps/ (palm-mail, in the mail area).
		fmt.tprintf("%s/%s.bin", n.src == "" ? fmt.tprintf("apps/%s", n.app) : n.src, n.app),
	}) {
		if os.exists(cand) {
			return cand, true
		}
	}
	// An installed system names binaries without the suffix, side by side.
	if flat := fmt.tprintf("%s/%s", dir, n.app); n.app != "palm" && os.exists(flat) && !os.is_dir(flat) {
		return flat, true
	}
	return fmt.tprintf("%s/../%s/%s.bin", dir, n.app, n.app), false
}

// ---------------------------------------------------------------------------
// Building what the working tree does not build by default
//
// Every application under apps/ has its main package at its top, and every
// build script in the repository builds those. A few do not: prose is a
// library (docs imports it) whose command line lives in apps/prose/cli, so
// nothing produces apps/prose/prose.bin unless someone types the line. palm
// knows that line, says it when the binary is missing, and `palm --selftest`
// runs it rather than reporting the noun unavailable.
// ---------------------------------------------------------------------------

Build :: struct {
	app: string, // the noun's binary name
	src: string, // the package with its main, relative to the repository root
}

BUILDS := []Build{{"prose", "apps/prose/cli"}}

build_of :: proc(n: Noun) -> (b: Build, ok: bool) {
	for it in BUILDS {
		if it.app == n.app {
			return it, true
		}
	}
	return {}, false
}

// build_line is the command that builds a noun's binary from the repository
// root, or "" when the ordinary build covers it.
build_line :: proc(n: Noun, odin := "odin") -> string {
	b, ok := build_of(n)
	if !ok {
		return ""
	}
	return fmt.tprintf(
		"%s build %s -collection:palmy=palmy -collection:shadcn=shadcn -collection:kit=apps/kit -out:apps/%s/%s.bin",
		odin,
		b.src,
		b.app,
		b.app,
	)
}

// find_odin is the compiler: $ODIN, then `odin` on PATH, then the pinned one
// this project's machines install through mise.
find_odin :: proc() -> string {
	if o := os.get_env("ODIN", context.temp_allocator); o != "" && os.exists(o) {
		return o
	}
	if path := os.get_env("PATH", context.temp_allocator); path != "" {
		for d in strings.split(path, ":", context.temp_allocator) {
			if c := fmt.tprintf("%s/odin", d); d != "" && os.exists(c) {
				return c
			}
		}
	}
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		for v in ([?]string{"dev-2026-09"}) {
			if c := fmt.tprintf("%s/.local/share/mise/installs/odin/%s/odin", home, v); os.exists(c) {
				return c
			}
		}
	}
	return ""
}

// ensure_built builds a noun's binary in the working tree when it is missing
// and palm knows how. It is quiet about nouns the ordinary build covers, and
// about a tree that is not a checkout (an installed system).
ensure_built :: proc(n: Noun) -> (built: bool, why: string) {
	if _, found := binary_for(n); found {
		return false, ""
	}
	b, ok := build_of(n)
	if !ok || !os.is_dir(b.src) || !os.is_dir("apps/kit") {
		return false, ""
	}
	odin := find_odin()
	if odin == "" {
		return false, "no odin compiler to build it with"
	}
	line := build_line(n, odin)
	fmt.eprintfln("palm: building %s: %s", n.app, line)
	state, _, serr, err := os.process_exec(
		{command = {"sh", "-c", fmt.tprintf("WAYLAND_DISPLAY= DISPLAY= %s", line)}},
		context.temp_allocator,
	)
	if err != nil || state.exit_code != 0 {
		return false, strings.trim_space(string(serr))
	}
	return true, ""
}

find_noun :: proc(name: string) -> (n: Noun, ok: bool) {
	for it in NOUNS {
		if it.noun == name {
			return it, true
		}
	}
	return Noun{}, false
}

// ---------------------------------------------------------------------------
// Reading an application's declaration
// ---------------------------------------------------------------------------

// schema_of runs `<binary> --schema` and hands back what it printed. The
// display variables are cleared for the child: an application that is not on
// the convention yet would treat `--schema` as nothing it recognises and open
// a window, and a dispatcher that opens a window instead of answering is
// worse than one that says it does not know. Only applications marked
// on_convention are probed at all.
schema_of :: proc(n: Noun) -> (text: string, ok: bool) {
	if !n.on_convention {
		return "", false
	}
	path, found := binary_for(n)
	if !found {
		return "", false
	}
	line := fmt.tprintf("WAYLAND_DISPLAY= DISPLAY= exec %q --schema", path)
	state, sout, _, err := os.process_exec(
		{command = {"sh", "-c", line}},
		context.temp_allocator,
	)
	if err != nil || state.exit_code != 0 {
		return "", false
	}
	return string(sout), true
}

// jfrom converts a parsed JSON value into the kit's ordered tree, so a
// declaration read back from an application can be nested inside the
// aggregate `palm schema` prints.
jfrom :: proc(v: json.Value) -> ^kit.Json {
	switch t in v {
	case json.Null:
		return kit.jnull()
	case json.Boolean:
		return kit.jbool(bool(t))
	case json.Integer:
		return kit.ji64(i64(t))
	case json.Float:
		return kit.jnum(f64(t))
	case json.String:
		return kit.jstr(string(t))
	case json.Array:
		a := kit.jarr()
		for e in t {
			kit.jpush(a, jfrom(e))
		}
		return a
	case json.Object:
		// A parsed object is a map and has lost its order; the keys are sorted
		// so that two runs of `palm schema` are the same bytes and a diff of
		// them shows a change in the surface rather than a change in a hash.
		keys := make([dynamic]string, context.temp_allocator)
		for k in t {
			append(&keys, k)
		}
		for i in 1 ..< len(keys) {
			j := i
			for j > 0 && keys[j] < keys[j - 1] {
				keys[j], keys[j - 1] = keys[j - 1], keys[j]
				j -= 1
			}
		}
		o := kit.jobj()
		for k in keys {
			kit.jset(o, k, jfrom(t[k]))
		}
		return o
	}
	return kit.jnull()
}

// Surface_Info is one application's declaration, parsed.
Surface_Info :: struct {
	noun:      Noun,
	path:      string,
	available: bool,
	reason:    string,
	doc:       json.Value, // the whole --schema document
	commands:  []json.Value,
}

collect :: proc(only := "") -> []Surface_Info {
	out := make([dynamic]Surface_Info, context.temp_allocator)
	for n in NOUNS {
		if only != "" && n.noun != only {
			continue
		}
		info := Surface_Info {
			noun = n,
		}
		path, found := binary_for(n)
		info.path = path
		switch {
		case !n.on_convention:
			info.reason = "not yet on the shared convention"
		case !found:
			info.reason = "the binary is not built"
			if line := build_line(n); line != "" {
				info.reason = fmt.tprintf("the binary is not built (from the repository root: %s)", line)
			}
		case:
			text, got := schema_of(n)
			if !got {
				info.reason = "the binary did not answer --schema"
				break
			}
			doc, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.allocator)
			if err != nil {
				info.reason = "the binary's --schema is not JSON"
				break
			}
			info.doc = doc
			if obj, is_obj := doc.(json.Object); is_obj {
				if cmds, has := obj["commands"]; has {
					if arr, is_arr := cmds.(json.Array); is_arr {
						info.commands = arr[:]
					}
				}
			}
			info.available = true
		}
		append(&out, info)
	}
	return out[:]
}

// str_of pulls a string field out of a parsed command object.
str_of :: proc(v: json.Value, key: string) -> string {
	obj, ok := v.(json.Object)
	if !ok {
		return ""
	}
	f, has := obj[key]
	if !has {
		return ""
	}
	s, is_s := f.(json.String)
	return is_s ? string(s) : ""
}

arr_of :: proc(v: json.Value, key: string) -> []json.Value {
	obj, ok := v.(json.Object)
	if !ok {
		return nil
	}
	f, has := obj[key]
	if !has {
		return nil
	}
	a, is_a := f.(json.Array)
	return is_a ? a[:] : nil
}

bool_of :: proc(v: json.Value, key: string) -> bool {
	obj, ok := v.(json.Object)
	if !ok {
		return false
	}
	f, has := obj[key]
	if !has {
		return false
	}
	b, is_b := f.(json.Boolean)
	return is_b ? bool(b) : false
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

// route_json reports a refusal in the form the caller asked for. palm's own
// output discipline is the same as everything else's: under --json a document
// on stdout, otherwise a line on stderr.
route_fail :: proc(wants_json: bool, code: int, fields: ..string) -> int {
	o := kit.jobj()
	kit.jset_str(o, "error", kit.cli_exit_reason(code))
	kit.jset_int(o, "code", code)
	for i := 0; i + 1 < len(fields); i += 2 {
		kit.jset_str(o, fields[i], fields[i + 1])
	}
	if wants_json {
		fmt.println(kit.json_text(o, 2, context.temp_allocator))
	} else {
		detail := ""
		if d, has := kit.jget(o, "detail"); has {
			detail = kit.json_scalar(d)
		}
		fmt.eprintfln("palm: %s%s", kit.cli_exit_reason(code), detail == "" ? "" : fmt.tprintf(" — %s", detail))
	}
	return code
}

// route runs an application's binary with the rest of the command line and
// passes its exit code back. stdio is inherited, so what the application
// writes to stdout is what the caller reads, byte for byte — `palm` adds
// nothing to it and strips nothing from it.
route :: proc(n: Noun, args: []string) -> int {
	wants_json := false
	for a in args {
		if a == "--json" {
			wants_json = true
		}
	}

	if len(args) == 0 {
		// Never fall through to the application with no arguments: that would
		// open its window, and a command that opens a window instead of
		// answering never returns to whatever ran it.
		fmt.eprint(noun_usage(n))
		return route_fail(wants_json, kit.EXIT_USAGE, "noun", n.noun, "detail", "no verb given")
	}

	// The verbs that must not exist, refused before anything is spawned.
	for f in FORBIDDEN_VERBS {
		if (f.noun == "" || f.noun == n.noun) && f.verb == args[0] {
			return route_fail(
				wants_json,
				kit.EXIT_OUT_OF_SCOPE,
				"noun",
				n.noun,
				"verb",
				args[0],
				"detail",
				f.why,
			)
		}
	}

	// Scope, enforced here as well as in the application. `palm` is the door;
	// a door that trusts the room behind it is not a door.
	scope := kit.cli_scope()
	for a, i in args {
		want := ""
		if strings.has_prefix(a, "--identity=") {
			want = a[len("--identity="):]
		} else if a == "--identity" && i + 1 < len(args) {
			want = args[i + 1]
		} else {
			continue
		}
		for r in ([?]string{"all", "any", "*", "every"}) {
			if want == r {
				return route_fail(
					wants_json,
					kit.EXIT_OUT_OF_SCOPE,
					"identity",
					scope == "" ? "unscoped" : scope,
					"requested",
					want,
					"detail",
					fmt.tprintf("%q is not an identity", want),
				)
			}
		}
		if scope != "" && want != scope {
			return route_fail(
				wants_json,
				kit.EXIT_OUT_OF_SCOPE,
				"identity",
				scope,
				"requested",
				want,
				"detail",
				"scope may be narrowed, never widened",
			)
		}
	}

	// An application that is not on the shared convention is never started.
	// It would not understand the verb, and what it would do instead is open
	// its window — on the user's screen, from a command that was supposed to
	// answer and exit. Unavailable is the honest answer and the safe one.
	if !n.on_convention {
		return route_fail(
			wants_json,
			kit.EXIT_UNAVAILABLE,
			"noun",
			n.noun,
			"detail",
			"not yet on the shared convention",
		)
	}

	path, found := binary_for(n)
	if !found {
		return route_fail(
			wants_json,
			kit.EXIT_UNAVAILABLE,
			"noun",
			n.noun,
			"binary",
			path,
			"detail",
			"the binary is not built",
		)
	}

	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, path)
	for a in args {
		append(&argv, a)
	}
	// stdin, stdout and stderr are handed to the child explicitly. Left nil,
	// os2 points them at /dev/null, and a dispatcher that swallows the
	// application's output would be worse than no dispatcher at all.
	child, err := os.process_start(
		{command = argv[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr},
	)
	if err != nil {
		return route_fail(wants_json, kit.EXIT_UNAVAILABLE, "noun", n.noun, "binary", path, "detail", "could not start it")
	}
	state, werr := os.process_wait(child)
	if werr != nil {
		return route_fail(wants_json, kit.EXIT_FAILED, "noun", n.noun, "detail", "could not wait for it")
	}
	return state.exit_code
}

noun_usage :: proc(n: Noun) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, fmt.tprintf("palm %s — %s\n\n", n.noun, n.summary))
	infos := collect(n.noun)
	if len(infos) == 1 && infos[0].available {
		strings.write_string(&sb, "Commands:\n")
		for c in infos[0].commands {
			if bool_of(c, "hidden") {
				continue
			}
			strings.write_string(
				&sb,
				fmt.tprintf("  palm %s %-12s %-46s [%s]\n", n.noun, str_of(c, "verb"), str_of(c, "summary"), str_of(c, "effect")),
			)
		}
	} else {
		strings.write_string(&sb, fmt.tprintf("Unavailable: %s\n", infos[0].reason))
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		if n, ok := find_noun(args[0]); ok {
			os.exit(route(n, args[1:]))
		}
	}
	code, handled := kit.cli(surface())
	if !handled {
		fmt.print(kit.cli_help_text(surface()))
		fmt.print(nouns_help())
		os.exit(kit.EXIT_USAGE)
	}
	os.exit(code)
}

nouns_help :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "\nApplications:\n")
	for n in NOUNS {
		mark := n.on_convention ? " " : "·"
		strings.write_string(&sb, fmt.tprintf("  %s palm %-11s %s\n", mark, n.noun, n.summary))
	}
	strings.write_string(
		&sb,
		"\n· not yet on the shared convention; `palm <noun> ...` reports it unavailable (exit 6).\n",
	)
	return strings.to_string(sb)
}
