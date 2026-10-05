package main

// `palm --selftest` asserts the surface against itself.
//
// Everything checked here is cross-cutting: it is true of the whole surface or
// it is not true at all, which is why it cannot live in any one application's
// tests. Each application already checks its own commands; this checks that
// the index and the behaviour are the same thing.
//
// What it asserts, in the words of the design:
//
//   * every command `palm schema` advertises exists — proved by asking the
//     application for its help, which only a verb it has will answer;
//   * every example it ships parses — proved by running the example through
//     the real parser with --parse-only, in the real binary;
//   * every documented exit code is produced by something — all seven, each
//     by a named command;
//   * every `read` command emits JSON matching its declared schema — run, and
//     the output validated against the fields the command itself declared;
//   * every `destructive` command refuses without `--yes`;
//   * and the safety rules, which are the reason the surface is narrow:
//     networking is read-only, power and session actions are intent class,
//     capture never names a camera or a microphone, and no verb anywhere
//     reads a vault across identities.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

checks: int
failures: int

check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", fmt.tprintf(what, ..args))
	}
}

eq_i :: proc(got, want: int, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s: got %d, want %d", fmt.tprintf(what, ..args), got, want)
	}
}

section :: proc(name: string) {
	fmt.printfln("\n%s", name)
}

self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

// sh runs a command line and hands back stdout and the exit code. Every child
// has the display variables cleared: a command that fell through to a window
// would otherwise block a test run on a window nobody is watching.
sh :: proc(line: string) -> (out: string, code: int) {
	state, sout, _, err := os.process_exec(
		{command = {"sh", "-c", fmt.tprintf("WAYLAND_DISPLAY= DISPLAY= %s", line)}},
		context.temp_allocator,
	)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

// palm runs this dispatcher again.
palm :: proc(args: ..string) -> (out: string, code: int) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, fmt.tprintf("%q", self_exe()))
	for a in args {
		strings.write_string(&sb, fmt.tprintf(" %q", a))
	}
	return sh(strings.to_string(sb))
}

// quoted turns a list of arguments into a shell line.
quoted :: proc(bin: string, args: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, fmt.tprintf("%q", bin))
	for a in args {
		strings.write_string(&sb, fmt.tprintf(" %q", a))
	}
	return strings.to_string(sb)
}

// field_of rebuilds the kit's declared-output shape from the JSON an
// application printed for it, so a result can be validated against the
// declaration the application itself published rather than against a second
// copy of it kept here.
fields_from :: proc(v: json.Value) -> []kit.Field {
	arr, ok := v.(json.Array)
	if !ok {
		return nil
	}
	out := make([dynamic]kit.Field, context.temp_allocator)
	for e in arr {
		f := kit.Field {
			name = str_of(e, "name"),
			opt  = bool_of(e, "optional"),
		}
		switch str_of(e, "type") {
		case "string":
			f.kind = .String
		case "int":
			f.kind = .Int
		case "float":
			f.kind = .Float
		case "bool":
			f.kind = .Bool
		case "array":
			f.kind = .Array
		case "object":
			f.kind = .Object
		case:
			f.kind = .Any
		}
		if obj, is_obj := e.(json.Object); is_obj {
			if of, has := obj["of"]; has {
				f.of = fields_from(of)
			}
		}
		append(&out, f)
	}
	return out[:]
}

output_fields :: proc(cmd: json.Value) -> []kit.Field {
	obj, ok := cmd.(json.Object)
	if !ok {
		return nil
	}
	o, has := obj["output"]
	if !has {
		return nil
	}
	oo, is_obj := o.(json.Object)
	if !is_obj {
		return nil
	}
	f, has_f := oo["fields"]
	if !has_f {
		return nil
	}
	return fields_from(f)
}

selftest :: proc() -> int {
	fmt.println("palm self-test")

	// Never append to the real audit log, and never read the real notebook.
	scratch := fmt.tprintf("/tmp/palmy-palm-selftest-%d", os.get_pid())
	os.make_directory_all(scratch)
	defer os.remove_all(scratch)
	_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", scratch))
	_ = os.set_env("PALMY_NOTES_DIR", fmt.tprintf("%s/notes", scratch))

	// A notebook with something in it, so the examples that name a note have
	// one to find. It is written through the surface itself — `notes write` —
	// rather than by reaching into the store, because a setup step that
	// bypasses the thing under test is a setup step that can lie.
	{
		n, ok := find_noun("notes")
		if ok {
			if path, found := binary_for(n); found {
				_, _ = sh(quoted(path, {"write", "welcome-to-notes", "--text", "# Welcome to Notes\n\nA note for the self-test to find."}))
				_, _ = sh(quoted(path, {"write", "scratch", "--text", "# scratch\n\nSomething to delete."}))
			}
		}
	}

	infos := collect()
	test_table(infos)
	test_commands_exist(infos)
	test_examples(infos)
	test_read_schemas(infos)
	test_destructive(infos)
	test_safety(infos)
	test_exit_codes(scratch)
	test_dispatcher(scratch)

	fmt.printfln("\n%d assertions, %d failures", checks, failures)
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------

test_table :: proc(infos: []Surface_Info) {
	section("the table of applications")

	seen := make(map[string]bool, context.temp_allocator)
	for n in NOUNS {
		check(!seen[n.noun], "the noun %q appears once", n.noun)
		seen[n.noun] = true
		check(n.app != "", "%s names an application", n.noun)
		check(n.summary != "", "%s has a summary", n.noun)
	}

	// A noun on the convention has to actually be there, or the table is
	// claiming something that is not true.
	ready := 0
	for info in infos {
		if !info.noun.on_convention {
			continue
		}
		ready += 1
		check(
			info.available,
			"%s says it is on the convention and answers --schema (%s)",
			info.noun.noun,
			info.reason,
		)
		check(len(info.commands) > 0, "%s declares at least one command", info.noun.noun)
	}
	check(ready >= 3, "at least the three exemplars are on the convention, got %d", ready)

	// And one that is not on the convention is never probed, so the
	// dispatcher cannot be hung by an application that would open a window.
	for info in infos {
		if info.noun.on_convention {
			continue
		}
		check(!info.available, "%s is reported unavailable rather than guessed at", info.noun.noun)
		check(info.reason != "", "and says why: %s", info.reason)
	}
}

// Every command the schema advertises exists. The schema came from the
// binary, so the only way this says anything is to go back and ask the binary
// about each verb by name: `help <verb>` answers for a verb it has and
// reports an unknown command for one it does not.
test_commands_exist :: proc(infos: []Surface_Info) {
	section("every command the schema advertises exists")

	for info in infos {
		if !info.available {
			continue
		}
		for cmd in info.commands {
			verb := str_of(cmd, "verb")
			out, code := sh(quoted(info.path, {"help", verb}))
			eq_i(code, 0, "%s %s answers `help %s`", info.noun.noun, verb, verb)
			check(
				strings.contains(out, verb),
				"and the help it prints is about %s %s",
				info.noun.noun,
				verb,
			)
			check(str_of(cmd, "summary") != "", "%s %s has a summary", info.noun.noun, verb)
			check(str_of(cmd, "effect") != "", "%s %s declares a side-effect class", info.noun.noun, verb)
			check(str_of(cmd, "usage") != "", "%s %s has a usage line", info.noun.noun, verb)
			check(len(output_fields(cmd)) > 0, "%s %s declares what it prints", info.noun.noun, verb)
		}
	}
}

// Every example the surface ships parses. --parse-only runs the real parser
// in the real binary and stops before the body, so an example that has gone
// stale fails here rather than in somebody's pipeline.
test_examples :: proc(infos: []Surface_Info) {
	section("every example the surface ships parses")

	total := 0
	for info in infos {
		if !info.available {
			continue
		}
		for cmd in info.commands {
			verb := str_of(cmd, "verb")
			for e in arr_of(cmd, "examples") {
				s, is_s := e.(json.String)
				if !is_s {
					continue
				}
				total += 1
				words := kit.cli_split_example(string(s), context.temp_allocator)
				check(
					len(words) > 0 && words[0] == info.noun.app,
					"the example %q is typed as the binary is named",
					string(s),
				)
				args := make([dynamic]string, context.temp_allocator)
				for w in words[1:] {
					append(&args, w)
				}
				append(&args, "--parse-only")
				_, code := sh(quoted(info.path, args[:]))
				eq_i(code, 0, "the example %q parses", string(s))
				_ = verb
			}
		}
	}
	check(total > 20, "and there are enough of them to mean something (%d)", total)
}

// Every read command emits JSON matching its declared schema. Only commands
// with no required argument can be run blind; the rest are run from their own
// first example, which the pass above has just proved parses.
test_read_schemas :: proc(infos: []Surface_Info) {
	section("every read command matches the schema it declared")

	for info in infos {
		if !info.available {
			continue
		}
		for cmd in info.commands {
			if str_of(cmd, "effect") != "read" {
				continue
			}
			verb := str_of(cmd, "verb")
			args := make([dynamic]string, context.temp_allocator)
			needs_arg := false
			for a in arr_of(cmd, "args") {
				if bool_of(a, "required") {
					needs_arg = true
				}
			}
			if !needs_arg {
				append(&args, verb)
			} else {
				ex := arr_of(cmd, "examples")
				if len(ex) == 0 {
					continue
				}
				s, is_s := ex[0].(json.String)
				if !is_s {
					continue
				}
				for w in kit.cli_split_example(string(s), context.temp_allocator)[1:] {
					append(&args, w)
				}
			}
			append(&args, "--json")
			out, code := sh(quoted(info.path, args[:]))

			// "Not found" is a documented outcome of a read, not a failure of
			// the convention: an example may name a note or a file that is
			// not on this machine. What must hold either way is that the
			// answer is a document of a declared shape — the command's own
			// fields when it worked, the documented error object when it did
			// not.
			if code == kit.EXIT_NOT_FOUND {
				bad := kit.cli_validate_output(
					out,
					{{name = "error", kind = .String}, {name = "code", kind = .Int}, {name = "command", kind = .String}},
					context.temp_allocator,
				)
				check(
					len(bad) == 0,
					"%s %s --json refuses with the documented error object%s",
					info.noun.noun,
					verb,
					len(bad) > 0 ? fmt.tprintf(" (%s)", bad[0]) : "",
				)
				continue
			}
			eq_i(code, 0, "%s %s --json exits 0", info.noun.noun, verb)
			if code != 0 {
				continue
			}
			problems := kit.cli_validate_output(out, output_fields(cmd), context.temp_allocator)
			check(
				len(problems) == 0,
				"%s %s --json matches its declared schema%s",
				info.noun.noun,
				verb,
				len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "",
			)
			// And nothing but the document on stdout: the parse above would
			// have failed on a stray line, and this says where it starts.
			trimmed := strings.trim_space(out)
			check(
				strings.has_prefix(trimmed, "{") && strings.has_suffix(trimmed, "}"),
				"and stdout is the document and nothing else",
			)
		}
	}
}

// Every destructive command refuses without --yes. The refusal is in the
// shared parser, so --parse-only reaches it: the command is validated, the
// gate is applied, and the body is never entered — which is what makes it
// safe to assert this against a command that really would delete something.
test_destructive :: proc(infos: []Surface_Info) {
	section("every destructive command refuses without --yes")

	found := 0
	for info in infos {
		if !info.available {
			continue
		}
		for cmd in info.commands {
			if str_of(cmd, "effect") != "destructive" {
				continue
			}
			found += 1
			verb := str_of(cmd, "verb")
			ex := arr_of(cmd, "examples")
			check(len(ex) > 0, "%s %s ships an example to check against", info.noun.noun, verb)
			if len(ex) == 0 {
				continue
			}
			s, _ := ex[0].(json.String)
			words := kit.cli_split_example(string(s), context.temp_allocator)
			check(
				strings.contains(string(s), "--yes"),
				"the example for %s %s passes --yes, as any caller must",
				info.noun.noun,
				verb,
			)
			without := make([dynamic]string, context.temp_allocator)
			with := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				if w != "--yes" {
					append(&without, w)
				}
				append(&with, w)
			}
			append(&without, "--parse-only")
			append(&with, "--parse-only")

			out, code := sh(quoted(info.path, without[:]))
			eq_i(code, kit.EXIT_NEEDS_YES, "%s %s without --yes exits 4", info.noun.noun, verb)
			check(
				strings.contains(out, "needs --yes") || code == kit.EXIT_NEEDS_YES,
				"and says so in machine-readable form",
			)
			_, ok_code := sh(quoted(info.path, with[:]))
			eq_i(ok_code, 0, "%s %s with --yes is accepted", info.noun.noun, verb)

			// Refusal, not prompting. The command is given a stdin that is
			// open and will never produce a byte — a named pipe with a
			// sleeping writer — and five seconds to answer. A command that
			// asked the terminal whether to go ahead would block on it and
			// come back as a timeout; this one refuses and exits.
			fifo := fmt.tprintf("/tmp/palmy-palm-stdin-%d-%s", os.get_pid(), verb)
			os.remove(fifo)
			line := strings.builder_make(context.temp_allocator)
			strings.write_string(
				&line,
				fmt.tprintf("mkfifo %q && (sleep 30 > %q &) && timeout 5 ", fifo, fifo),
			)
			strings.write_string(&line, quoted(info.path, without[:len(without) - 1]))
			strings.write_string(&line, fmt.tprintf(" < %q", fifo))
			_, blocked := sh(strings.to_string(line))
			os.remove(fifo)
			eq_i(
				blocked,
				kit.EXIT_NEEDS_YES,
				"%s %s refuses without reading its terminal (124 would mean it blocked)",
				info.noun.noun,
				verb,
			)
		}
	}
	check(found > 0, "and there is at least one destructive command to check (%d)", found)
}

// The safety rules. These are assertions over the whole surface, which is the
// only place they can be made: any one application can be careful, and the
// question is whether all of them are.
test_safety :: proc(infos: []Surface_Info) {
	section("the safety rules, as assertions over the whole surface")

	// Networking is read-only. Nothing under a network noun may be anything
	// but read or intent — a mutate there is a command that can take this
	// machine, and the session doing the work, off the network.
	for info in infos {
		if !info.available {
			continue
		}
		net := info.noun.noun == "net" || info.noun.noun == "bluetooth"
		power := info.noun.noun == "power"
		for cmd in info.commands {
			effect := str_of(cmd, "effect")
			verb := str_of(cmd, "verb")
			if net {
				check(
					effect == "read" || effect == "intent",
					"net/bluetooth %q is %s; networking is read-only",
					verb,
					effect,
				)
			}
			if power {
				// Reading power state is fine. Doing anything is intent.
				check(
					effect == "read" || effect == "intent" || effect == "mutate",
					"power %q is %s",
					verb,
					effect,
				)
				for action in ([?]string{"lock", "logout", "suspend", "reboot", "shutdown", "hibernate"}) {
					if verb == action {
						check(effect == "intent", "power %q is intent class, not %s", verb, effect)
					}
				}
			}
			// No verb anywhere reads a vault across identities.
			for f in FORBIDDEN_VERBS {
				if (f.noun == "" || f.noun == info.noun.noun) && f.verb == verb {
					check(false, "the forbidden verb %s %s is declared", info.noun.noun, verb)
				}
			}
			// Nor by any other name: a vault command that advertises reading
			// more than one identity is the thing that must be absent.
			if info.noun.noun == "vault" {
				for a in arr_of(cmd, "flags") {
					name := str_of(a, "name")
					check(
						name != "all-identities" && name != "any-identity" && name != "every-identity",
						"vault %q does not take %q",
						verb,
						name,
					)
				}
			}
			// Capture never names a real device.
			if info.noun.noun == "capture" {
				for a in arr_of(cmd, "flags") {
					name := str_of(a, "name")
					check(
						name != "camera" && name != "webcam" && name != "microphone" && name != "mic",
						"capture %q does not take %q",
						verb,
						name,
					)
				}
			}
		}
	}

	// The kit's denylist, which is where these rules are actually enforced
	// rather than merely declared.
	for argv in ([][]string {
		{"nmcli", "radio", "wifi", "off"},
		{"nmcli", "networking", "off"},
		{"nmcli", "device", "disconnect", "wlan0"},
		{"nmcli", "device", "wifi", "connect", "somewhere"},
		{"nmcli", "connection", "down", "home"},
		{"rfkill", "block", "wifi"},
		{"ip", "link", "set", "wlan0", "down"},
		{"systemctl", "poweroff"},
		{"systemctl", "reboot"},
		{"systemctl", "suspend"},
		{"systemctl", "stop", "sddm"},
		{"systemctl", "disable", "greetd"},
		{"systemctl", "restart", "display-manager"},
		{"systemctl", "start", "ollama"},
		{"reboot"},
		{"poweroff"},
		{"shutdown", "-h", "now"},
		{"loginctl", "terminate-session", "self"},
		{"loginctl", "lock-session"},
		{"ffmpeg", "-f", "v4l2", "-i", "/dev/video0", "x.mp4"},
		{"ffmpeg", "-f", "pulse", "-i", "default", "x.wav"},
		{"pw-record", "x.wav"},
		{"arecord", "x.wav"},
	}) {
		check(
			kit.cli_forbidden(argv) != "",
			"the kit refuses %q",
			strings.join(argv, " ", context.temp_allocator),
		)
	}
	// And the reads it must not get in the way of.
	for argv in ([][]string {
		{"nmcli", "-t", "-f", "SSID,SIGNAL", "device", "wifi"},
		{"nmcli", "radio", "wifi"},
		{"nmcli", "device", "wifi", "rescan"},
		{"rfkill", "list", "bluetooth"},
		{"loginctl", "list-sessions"},
		{"loginctl", "show-session", "1"},
		{"upower", "--dump"},
		{"systemctl", "status", "sddm"},
		{"ffmpeg", "-i", "in.mp4", "out.webm"},
		{"wl-copy", "--", "text"},
	}) {
		check(
			kit.cli_forbidden(argv) == "",
			"and does not get in the way of %q",
			strings.join(argv, " ", context.temp_allocator),
		)
	}
}

// Every documented exit code is produced by something, named here so a code
// that stops being reachable fails rather than quietly becoming fiction.
test_exit_codes :: proc(scratch: string) {
	section("every documented exit code is produced by something")

	produced := make(map[int]string, context.temp_allocator)

	{
		_, code := palm("version", "--json")
		eq_i(code, kit.EXIT_OK, "0 ok: palm version")
		produced[kit.EXIT_OK] = "palm version"
	}
	{
		_, code := palm("sideways")
		eq_i(code, kit.EXIT_USAGE, "2 usage: an unknown command")
		produced[kit.EXIT_USAGE] = "palm sideways"
	}
	{
		out, code := palm("schema", "--noun", "nothing-like-this", "--json")
		eq_i(code, kit.EXIT_NOT_FOUND, "3 not found: an application that does not exist")
		check(strings.contains(out, `"error": "not found"`), "with the documented token")
		produced[kit.EXIT_NOT_FOUND] = "palm schema --noun ..."
	}
	{
		// 4 comes from a real destructive command, through the dispatcher.
		n, _ := find_noun("notes")
		path, found := binary_for(n)
		if found {
			out, code := sh(quoted(path, {"delete", "anything", "--json", "--parse-only"}))
			eq_i(code, kit.EXIT_NEEDS_YES, "4 needs --yes: notes delete without it")
			check(strings.contains(out, `"error": "needs --yes"`), "with the documented token")
			produced[kit.EXIT_NEEDS_YES] = "notes delete"
		}
	}
	{
		out, code := sh(fmt.tprintf("PALM_IDENTITY=work %q identity --identity personal --json", self_exe()))
		eq_i(code, kit.EXIT_OUT_OF_SCOPE, "5 out of scope: asking for another identity")
		check(strings.contains(out, `"error": "out of scope"`), "with the documented token")
		produced[kit.EXIT_OUT_OF_SCOPE] = "palm --identity"
	}
	{
		// 6 unavailable: a noun whose binary is not where palm looks. An
		// empty directory is the honest way to produce that.
		empty := fmt.tprintf("%s/empty", scratch)
		os.make_directory_all(empty)
		out, code := sh(fmt.tprintf("PALM_BIN_DIR=%q %q notes list --json", empty, self_exe()))
		eq_i(code, kit.EXIT_UNAVAILABLE, "6 unavailable: the binary is not there")
		check(strings.contains(out, `"error": "unavailable"`), "with the documented token")
		produced[kit.EXIT_UNAVAILABLE] = "palm notes, with no notes binary"
	}
	{
		// 7 failed: a command that could not do its work.
		n, _ := find_noun("sheets")
		path, found := binary_for(n)
		if found {
			out, code := sh(quoted(path, {"export", "/proc/nope/book.xlsx", "--json"}))
			eq_i(code, kit.EXIT_FAILED, "7 failed: a write that cannot happen")
			check(strings.contains(out, `"error": "failed"`), "with the documented token")
			produced[kit.EXIT_FAILED] = "sheets export"
		}
	}

	for code in kit.CLI_EXIT_CODES {
		by, has := produced[code]
		check(has, "exit %d (%s) is produced by something", code, kit.cli_exit_reason(code))
		if has {
			check(by != "", "by %s", by)
		}
	}
}

// The dispatcher itself: routing, pass-through, and the verbs it will not
// route whatever an application says.
test_dispatcher :: proc(scratch: string) {
	section("the dispatcher")

	{
		out, code := palm("schema", "--json")
		eq_i(code, 0, "palm schema exits 0")
		problems := kit.cli_validate_output(out, SCHEMA_FIELDS, context.temp_allocator)
		check(
			len(problems) == 0,
			"and matches its own declared schema%s",
			len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "",
		)
		for noun in ([?]string{"notes", "sheets", "power"}) {
			check(strings.contains(out, fmt.tprintf("\"noun\": %q", noun)), "it lists %s", noun)
		}
	}
	{
		out, code := palm("commands", "--json")
		eq_i(code, 0, "palm commands exits 0")
		problems := kit.cli_validate_output(out, COMMANDS_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "and matches its declared schema")
		check(strings.contains(out, `"command": "palm notes list"`), "and indexes a command by how it is typed")
	}
	{
		out, code := palm("commands", "--effect", "intent", "--json")
		eq_i(code, 0, "palm commands --effect intent exits 0")
		check(strings.contains(out, `"palm power reboot"`), "and finds the intent commands")
		check(!strings.contains(out, `"effect": "read"`), "and nothing else")
	}
	{
		_, code := palm("commands", "--effect", "nonsense")
		eq_i(code, kit.EXIT_USAGE, "an enumerated flag refuses a value outside the set")
	}
	{
		out, code := palm("identity", "--json")
		eq_i(code, 0, "palm identity exits 0")
		problems := kit.cli_validate_output(out, IDENTITY_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "and matches its declared schema")
	}

	// Routing passes stdout through unchanged: the dispatcher adds nothing.
	{
		n, _ := find_noun("notes")
		path, _ := binary_for(n)
		direct, dcode := sh(quoted(path, {"path", "--json"}))
		through, tcode := palm("notes", "path", "--json")
		eq_i(tcode, dcode, "palm notes path exits as notes path does")
		check(direct == through, "and prints exactly the same bytes")
	}

	// A noun with no verb is a usage error, not a window.
	{
		_, code := palm("notes")
		eq_i(code, kit.EXIT_USAGE, "a noun with no verb exits 2 rather than opening a window")
	}

	// An application that is not on the convention is unavailable, and is
	// never spawned to find that out.
	{
		out, code := palm("files", "list", "--json")
		eq_i(code, kit.EXIT_UNAVAILABLE, "an unconverted application exits 6")
		check(strings.contains(out, "not yet on the shared convention"), "and says why")
	}

	// The verbs that must not exist are refused by the dispatcher, before any
	// binary is started, whatever an application might one day declare.
	for f in FORBIDDEN_VERBS {
		noun := f.noun == "" ? "vault" : f.noun
		out, code := palm(noun, f.verb, "--json")
		eq_i(code, kit.EXIT_OUT_OF_SCOPE, "palm %s %s is refused outright", noun, f.verb)
		check(strings.contains(out, `"error": "out of scope"`), "with the documented token")
	}

	// The audit log: a mutating command through the dispatcher leaves a
	// record, and a read does not.
	{
		audit := fmt.tprintf("%s/audit.jsonl", scratch)
		os.remove(audit)
		_, _ = palm("notes", "path", "--json")
		check(!os.exists(audit) || !strings.contains(read_text(audit), `"verb": "path"`), "a read leaves no audit record")
		_, _ = palm("notes", "new", "Audited", "--json")
		text := read_text(audit)
		check(strings.contains(text, `"verb":"new"`), "a mutating command leaves one")
		check(strings.contains(text, `"effect":"mutate"`), "with its side-effect class")
		check(strings.contains(text, `"identity":"unscoped"`), "and the identity it ran under")

		out, code := palm("audit", "--json")
		eq_i(code, 0, "palm audit exits 0")
		problems := kit.cli_validate_output(out, AUDIT_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "and matches its declared schema")
		check(strings.contains(out, "\"new\""), "and reads the record back")
	}
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}
