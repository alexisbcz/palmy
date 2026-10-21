// Tests for kit's command-line convention (apps/kit/cli.odin, cli_jobs.odin).
//
//	odin test apps/kit/cli_test -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn
//
// Like i18n_test, these live beside kit in their own package because kit
// needs palmy and shadcn, which the toolkit's own suite does not import.
//
// Every application on the `palm` convention tests its own commands; this
// tests the convention itself, one section per gap it used to have (TODO.md,
// C3), so a regression names the gap. The kit keeps process-wide state — the
// guard, the capture buffer, $PALM_AUDIT — so the tests take one lock and run
// one at a time whatever the runner's thread count.
package kit_cli_test

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import kit "kit:."

@(private = "file")
g_lock: sync.Mutex

SECRET :: "hunter2-synthetic-pw"
SECRET_INT :: "424242"

// ---------------------------------------------------------------------------
// The surface under test. Package variables, as the convention requires.
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "login",
		summary = "sign in",
		effect = .Mutate,
		flags = {
			{name = "user", kind = .String, help = "who"},
			{name = "password", kind = .String, secret = true, unless = {"password-file"}, help = "the password"},
			{name = "password-file", kind = .Path, help = "read it from here"},
			{name = "pin", kind = .Int, secret = true, help = "a numeric secret"},
		},
		out = {{name = "user", kind = .String}, {name = "echo", kind = .String, opt = true}},
		examples = {"tool login --user ada --password " + SECRET, "tool login --user ada --password=" + SECRET + " --json"},
		run = cmd_login,
	},
	{
		verb = "zap",
		summary = "power off, as an intent",
		effect = .Mutate,
		flags = {{name = "password", kind = .String, secret = true}},
		out = {{name = "ok", kind = .Bool}},
		run = cmd_zap,
	},
	{
		verb = "churn",
		summary = "frees the temp allocator, as a long loop has to",
		effect = .Mutate,
		args = {{name = "what", kind = .String, required = true}},
		out = {{name = "what", kind = .String}},
		run = cmd_churn,
	},
	{
		verb = "sync",
		summary = "repeatable flags",
		effect = .Idempotent,
		flags = {
			{name = "profile", kind = .String, repeat = true},
			{name = "level", kind = .String, def = "warn"},
		},
		out = {{name = "profiles", kind = .Array, of = {{kind = .String}}}, {name = "level", kind = .String}, {name = "data_dir", kind = .String}},
		examples = {"tool sync --profile a --profile b"},
		run = cmd_sync,
	},
	{
		verb = "drop",
		summary = "destructive, with its own reason",
		effect = .Destructive,
		args = {{name = "name", kind = .String, required = true}},
		out = {{name = "dropped", kind = .String}},
		run = cmd_drop,
		on_refuse = refuse_drop,
	},
	{
		verb = "wipe",
		summary = "destructive, without",
		effect = .Destructive,
		out = {{name = "wiped", kind = .Bool}},
		run = cmd_wipe,
	},
	{
		verb = "table",
		summary = "rows with accents and currency",
		effect = .Read,
		out = {{name = "rows", kind = .Array}},
		run = cmd_table,
	},
	{
		verb = "fetch",
		summary = "fails half way, with what it got",
		effect = .Mutate,
		out = {{name = "fetched", kind = .Array}},
		run = cmd_fetch,
	},
	{
		verb = "fields",
		summary = "structured refusal fields",
		effect = .Read,
		out = {{name = "x", kind = .Int}},
		run = cmd_fields,
	},
	{
		verb = "shared",
		summary = "a thing two identities own",
		effect = .Read,
		args = {{name = "owners", kind = .String, variadic = true}},
		out = {{name = "ok", kind = .Bool}},
		run = cmd_shared,
	},
	{
		verb = "clip",
		summary = "content that must not be logged",
		effect = .Mutate,
		args = {{name = "text", kind = .String, variadic = true, free = true}},
		flags = {{name = "kind", kind = .String}},
		private_args = true,
		out = {{name = "n", kind = .Int}},
		run = cmd_clip,
	},
	{
		verb = "unlock",
		summary = "a secret positional",
		effect = .Mutate,
		args = {{name = "passphrase", kind = .String, required = true, secret = true}},
		out = {{name = "ok", kind = .Bool}},
		run = cmd_ok,
	},
	{
		verb = "box",
		summary = "flags named like the base aliases",
		effect = .Destructive,
		args = {{name = "offset", kind = .Int}, {name = "label", kind = .String}},
		flags = {{name = "h", kind = .Int}, {name = "w", kind = .Int, short = "v"}},
		out = {{name = "h", kind = .Int}, {name = "w", kind = .Int}, {name = "offset", kind = .Int}, {name = "label", kind = .String}},
		run = cmd_box,
	},
	{
		verb = "wide",
		summary = "a table of ten columns",
		effect = .Read,
		out = {{name = "rows", kind = .Array}},
		run = cmd_wide,
	},
}

cmd_clip :: proc(c: ^kit.Call) -> int {
	kit.jset_int(c.out, "n", len(kit.cli_rest(c)))
	return kit.EXIT_OK
}

cmd_ok :: proc(c: ^kit.Call) -> int {
	kit.jset_bool(c.out, "ok", true)
	return kit.EXIT_OK
}

cmd_box :: proc(c: ^kit.Call) -> int {
	kit.jset_int(c.out, "h", kit.cli_int(c, "h"))
	kit.jset_int(c.out, "w", kit.cli_int(c, "w"))
	kit.jset_int(c.out, "offset", kit.cli_int(c, "offset"))
	kit.jset_str(c.out, "label", kit.cli_str(c, "label"))
	return kit.EXIT_OK
}

cmd_wide :: proc(c: ^kit.Call) -> int {
	rows := kit.jarr()
	for r in 0 ..< 2 {
		o := kit.jobj()
		for k in 0 ..< 10 {
			kit.jset_int(o, fmt.tprintf("c%d", k), r * 100 + k)
		}
		kit.jpush(rows, o)
	}
	kit.jset(c.out, "rows", rows)
	return kit.EXIT_OK
}

@(private = "file")
COMMON := []kit.Param {
	{name = "data-dir", kind = .Path, def = "/var/lib/tool", help = "where the data lives"},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "tool",
			summary  = "the kit's own test surface",
			commands = COMMANDS,
			flags    = COMMON,
		}
	}
	return &g_surface
}

@(private = "file")
g_window_surface: kit.Surface
@(private = "file")
g_open_surface: kit.Surface

// window is a GUI surface that checks a bare word; open lets every word
// through, as takes_path always has.
window :: proc(check: bool) -> ^kit.Surface {
	s := check ? &g_window_surface : &g_open_surface
	if s.noun == "" {
		s^ = kit.Surface {
			noun       = "viewer",
			summary    = "a window that opens files",
			commands   = COMMANDS[6:7],
			gui        = true,
			takes_path = true,
		}
		if check {
			s.takes_word = kit.cli_word_is_path
		}
	}
	return s
}

cmd_login :: proc(c: ^kit.Call) -> int {
	kit.jset_str(c.out, "user", kit.cli_str(c, "user"))
	// A careless command copying the secret into its result: the kit's net
	// must catch it.
	kit.jset_str(c.out, "echo", fmt.tprintf("logged in with %s", kit.cli_str(c, "password")))
	return kit.EXIT_OK
}

cmd_zap :: proc(c: ^kit.Call) -> int {
	// Reaches for something forbidden with the secret on its argv; the
	// guard refuses it and records the refusal, which must be scrubbed.
	_, _ = kit.run({"systemctl", "poweroff", kit.cli_str(c, "password")})
	kit.jset_bool(c.out, "ok", true)
	return kit.EXIT_OK
}

cmd_churn :: proc(c: ^kit.Call) -> int {
	// What a long loop (or `shots`) does: reset the temp allocator, then
	// fill it — and only then read its arguments, without having copied them.
	free_all(context.temp_allocator)
	for i in 0 ..< 2000 {
		_ = fmt.tprintf("garbage %d %s", i, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
	}
	kit.jset_str(c.out, "what", kit.cli_str(c, "what"))
	return kit.EXIT_OK
}

cmd_sync :: proc(c: ^kit.Call) -> int {
	a := kit.jarr()
	for v in kit.cli_all(c, "profile") {
		kit.jpush(a, kit.jstr(v))
	}
	kit.jset(c.out, "profiles", a)
	kit.jset_str(c.out, "level", kit.cli_str(c, "level"))
	kit.jset_str(c.out, "data_dir", kit.cli_str(c, "data-dir"))
	return kit.EXIT_OK
}

g_refuse_guard: string

refuse_drop :: proc(c: ^kit.Call) {
	kit.cli_err_field(c, "reason", "has-dependants")
	kit.cli_err_field(c, "dependants", []string{"app-a", "app-b"})
	kit.cli_err_detail(c, fmt.tprintf("%s is needed by app-a and app-b", kit.cli_str(c, "name")))
	// It cannot execute anything while it explains itself.
	_, _ = kit.run({"true"})
	g_refuse_guard = kit.cli_guard_reason()
}

cmd_drop :: proc(c: ^kit.Call) -> int {
	kit.jset_str(c.out, "dropped", kit.cli_str(c, "name"))
	return kit.EXIT_OK
}

cmd_wipe :: proc(c: ^kit.Call) -> int {
	kit.jset_bool(c.out, "wiped", !c.dry_run)
	return kit.EXIT_OK
}

cmd_table :: proc(c: ^kit.Call) -> int {
	rows := kit.jarr()
	add :: proc(rows: ^kit.Json, label, amount: string) {
		r := kit.jobj()
		kit.jset_str(r, "label", label)
		kit.jset_str(r, "amount", amount)
		kit.jset_str(r, "end", "|")
		kit.jpush(rows, r)
	}
	add(rows, "Café crème", "3,50 €")
	add(rows, "Bread", "2 €")
	add(rows, "Épicerie générale", "120,00 €")
	add(rows, "東京", "1 €")
	kit.jset(c.out, "rows", rows)
	return kit.EXIT_OK
}

cmd_fetch :: proc(c: ^kit.Call) -> int {
	got := kit.jarr()
	kit.jpush(got, kit.jstr("INBOX"))
	kit.jpush(got, kit.jstr("Sent"))
	kit.jset(c.out, "fetched", got)
	kit.cli_partial(c)
	return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "the server went away at Archive")
}

cmd_fields :: proc(c: ^kit.Call) -> int {
	code := kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such thing")
	kit.cli_err_field(c, "given", "x")
	kit.cli_err_field(c, "line", 12)
	kit.cli_err_field(c, "retry", false)
	kit.cli_err_field(c, "near", []string{"y", "z"})
	o := kit.jobj()
	kit.jset_int(o, "from", 3)
	kit.cli_err_field(c, "range", o)
	return code
}

cmd_shared :: proc(c: ^kit.Call) -> int {
	if !kit.cli_scope_require(c, ..kit.cli_rest(c)) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	kit.jset_bool(c.out, "ok", true)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
scratch :: proc() -> string {
	dir := fmt.tprintf("/tmp/kit-cli-test-%d", os.get_pid())
	os.make_directory_all(dir)
	return dir
}

// fresh_audit points $PALM_AUDIT at an empty file of its own and returns it.
@(private = "file")
fresh_audit :: proc(name: string) -> string {
	path := fmt.aprintf("%s/%s.jsonl", scratch(), name)
	os.remove(path)
	os.set_env("PALM_AUDIT", path)
	return path
}

@(private = "file")
read_file :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

@(private = "file")
obj :: proc(v: json.Value) -> json.Object {
	o, _ := v.(json.Object)
	return o
}

@(private = "file")
str :: proc(v: json.Value, key: string) -> string {
	s, _ := obj(v)[key].(json.String)
	return string(s)
}

@(private = "file")
run :: proc(args: ..string) -> (code: int, doc: json.Value, text: string) {
	return kit.cli_capture_json(surface(), args)
}

// ---------------------------------------------------------------------------
// 1. Secret flags
// ---------------------------------------------------------------------------

@(test)
secret_flags :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	os.unset_env("PALM_IDENTITY")
	audit := fresh_audit("secrets")

	// Both spellings, through a mutating command, which is audited.
	code, doc, text := run("login", "--user", "ada", "--password", SECRET)
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect(t, !strings.contains(text, SECRET), "the --json result does not hold the secret, even when the command copied it in")
	testing.expect(t, strings.contains(str(doc, "echo"), kit.CLI_REDACTED), "it holds the placeholder where the command put it")
	code, _, text = run("login", "--user", "ada", "--password=" + SECRET)
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect(t, !strings.contains(text, SECRET), "nor with --password=VALUE")

	// A refusal later on the same line, after the secret was read.
	code, doc, text = run("login", "--password", SECRET, "--nope")
	testing.expect_value(t, code, kit.EXIT_USAGE)
	testing.expect(t, !strings.contains(text, SECRET), "a refusal does not hold it")

	// A secret that fails validation is refused without being quoted.
	code, _, text = run("login", "--password", SECRET, "--pin", "x" + SECRET_INT)
	testing.expect_value(t, code, kit.EXIT_USAGE)
	testing.expect(t, !strings.contains(text, "x" + SECRET_INT), "an invalid secret is not quoted back")

	// --parse-only echoes the line it parsed.
	code, doc, text = run("login", "--user", "ada", "--password", SECRET, "--parse-only")
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect(t, !strings.contains(text, SECRET), "--parse-only's echo does not hold it")
	testing.expect_value(t, str(obj(doc)["flags"], "password"), kit.CLI_REDACTED)
	testing.expect_value(t, str(obj(doc)["flags"], "user"), "ada")

	// The guard's refusal record, written while the command runs.
	code, _, _ = run("zap", "--password", SECRET)
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect(t, strings.contains(kit.cli_guard_reason(), "poweroff"), "the guard refused the poweroff")

	// THE assertion: grep the audit log for the secret.
	log := read_file(audit)
	testing.expect(t, len(log) > 0, "the audit log was written")
	testing.expect(t, strings.count(log, "\n") >= 5, "one record per command and one for the guard's refusal")
	testing.expect(t, !strings.contains(log, SECRET), "THE AUDIT LOG DOES NOT CONTAIN THE SECRET")
	testing.expect(t, !strings.contains(log, SECRET_INT), "nor the invalid numeric one")
	testing.expect(t, strings.contains(log, kit.CLI_REDACTED), "it holds the placeholder instead")
	testing.expect(t, strings.contains(log, `"--password=<redacted>"`), "the --flag=VALUE spelling keeps its flag")
	testing.expect(t, strings.contains(log, `"ada"`), "and everything that is not secret, as it was")

	// The schema and the help show the examples redacted.
	schema := kit.json_text(kit.cli_schema_json(surface()), 2, context.temp_allocator)
	testing.expect(t, !strings.contains(schema, SECRET), "the schema's examples do not hold it")
	testing.expect(t, strings.contains(schema, `"secret": true`), "the schema says which flag is secret")
	help := kit.cli_help_text(surface(), "login")
	testing.expect(t, !strings.contains(help, SECRET), "--help's examples do not hold it")
	testing.expect(t, strings.contains(help, "secret"), "--help says it is secret")

	// The redacted example still parses as one word for the flag.
	ex := kit.cli_redact_example(surface(), &COMMANDS[0], COMMANDS[0].examples[0])
	words := kit.cli_split_example(ex)
	testing.expect_value(t, len(words), 6)
	testing.expect_value(t, words[5], kit.CLI_REDACTED)
	_, bind := kit.cli_bind(surface(), words[1:])
	testing.expect_value(t, bind, kit.EXIT_OK)

	// A private_args example keeps its noun and verb; only the text goes.
	for &c in COMMANDS {
		if c.verb != "clip" {
			continue
		}
		pex := kit.cli_redact_example(surface(), &c, "tool clip hello world --kind note")
		pw := kit.cli_split_example(pex)
		testing.expect_value(t, len(pw), 6)
		testing.expect_value(t, pw[0], "tool")
		testing.expect_value(t, pw[1], "clip")
		testing.expect_value(t, pw[2], kit.CLI_REDACTED)
		testing.expect_value(t, pw[3], kit.CLI_REDACTED)
		testing.expect_value(t, pw[5], "note")
		_, pbind := kit.cli_bind(surface(), pw[1:])
		testing.expect_value(t, pbind, kit.EXIT_OK)
	}
}

// ---------------------------------------------------------------------------
// 2. The kit owns its memory
// ---------------------------------------------------------------------------

@(test)
owned_memory :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	audit := fresh_audit("memory")

	// The argv itself built in the temp allocator, as an application that
	// rewrites its command line does — and then the command frees it.
	argv := make([]string, 3, context.temp_allocator)
	argv[0] = strings.clone("churn", context.temp_allocator)
	argv[1] = strings.clone("the-word-that-must-survive", context.temp_allocator)
	argv[2] = strings.clone("--json", context.temp_allocator)
	code, text, _ := kit.cli_capture(surface(), argv)
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect(t, strings.contains(text, "the-word-that-must-survive"), "the result printed after the free")

	log := read_file(audit)
	testing.expect(t, strings.contains(log, `"argv":["churn","the-word-that-must-survive","--json"]`), "the audit record, written after the free, holds the argv intact")
}

// ---------------------------------------------------------------------------
// 3. Repeatable flags, required-unless, common flags, structured fields, scope
// ---------------------------------------------------------------------------

@(test)
repeatable_and_friends :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	fresh_audit("repeat")
	os.unset_env("PALM_IDENTITY")

	code, doc, _ := run("sync", "--profile", "a", "--profile=b", "--level", "x", "--level", "y")
	testing.expect_value(t, code, kit.EXIT_OK)
	profiles, _ := obj(doc)["profiles"].(json.Array)
	testing.expect_value(t, len(profiles), 2)
	if len(profiles) == 2 {
		testing.expect_value(t, string(profiles[0].(json.String)), "a")
		testing.expect_value(t, string(profiles[1].(json.String)), "b")
	}
	testing.expect_value(t, str(doc, "level"), "y") // the last value wins, as before

	// cli_all on a flag never given is its default.
	c, bc := kit.cli_bind(surface(), {"sync"})
	testing.expect_value(t, bc, kit.EXIT_OK)
	testing.expect_value(t, len(kit.cli_all(&c, "level")), 1)
	testing.expect_value(t, len(kit.cli_all(&c, "profile")), 0)

	// Required unless.
	code, doc, _ = run("login", "--user", "ada")
	testing.expect_value(t, code, kit.EXIT_USAGE)
	testing.expect_value(t, str(doc, "missing"), "password")
	unless, _ := obj(doc)["unless"].(json.Array)
	testing.expect_value(t, len(unless), 1)
	testing.expect(t, strings.contains(str(doc, "detail"), "--password-file"), "the refusal names the alternative")
	code, _, _ = run("login", "--user", "ada", "--password-file", "/dev/null")
	testing.expect_value(t, code, kit.EXIT_OK)

	// A flag every command takes.
	code, doc, _ = run("sync")
	testing.expect_value(t, str(doc, "data_dir"), "/var/lib/tool")
	code, doc, _ = run("sync", "--data-dir", "/srv/x")
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect_value(t, str(doc, "data_dir"), "/srv/x")
	code, _, _ = run("table", "--data-dir=/srv/y")
	testing.expect_value(t, code, kit.EXIT_OK)
	schema := kit.json_text(kit.cli_schema_json(surface()), 2, context.temp_allocator)
	testing.expect_value(t, strings.count(schema, `"name": "data-dir"`), len(COMMANDS) + 1)
	testing.expect(t, strings.contains(schema, `"common": true`), "marked common in each command")
	testing.expect(t, strings.contains(schema, `"repeat": true`), "repeat is published")
	testing.expect(t, strings.contains(schema, `"required_unless"`), "required_unless is published")
	testing.expect(t, strings.contains(kit.cli_help_text(surface(), "table"), "--data-dir"), "and in each command's help")

	// Structured refusal fields.
	code, doc, _ = run("fields")
	testing.expect_value(t, code, kit.EXIT_NOT_FOUND)
	o := obj(doc)
	_, is_int := o["line"].(json.Integer)
	_, is_bool := o["retry"].(json.Boolean)
	near, is_arr := o["near"].(json.Array)
	_, is_obj := o["range"].(json.Object)
	testing.expect(t, is_int && is_bool && is_arr && len(near) == 2 && is_obj, "an int, a bool, a list and an object, each as itself")
	testing.expect_value(t, str(doc, "given"), "x")

	// Scope with several owners.
	os.set_env("PALM_IDENTITY", "work")
	defer os.unset_env("PALM_IDENTITY")
	code, _, _ = run("shared", "home", "work")
	testing.expect_value(t, code, kit.EXIT_OK)
	code, doc, _ = run("shared", "home", "family")
	testing.expect_value(t, code, kit.EXIT_OUT_OF_SCOPE)
	req, req_arr := obj(doc)["requested"].(json.Array)
	testing.expect(t, req_arr && len(req) == 2, "several owners are named as a list")
	code, doc, _ = run("shared", "home")
	testing.expect_value(t, code, kit.EXIT_OUT_OF_SCOPE)
	testing.expect_value(t, str(doc, "requested"), "home") // one owner: a string, as it always was
}

// ---------------------------------------------------------------------------
// 4. takes_path and the bare word
// ---------------------------------------------------------------------------

@(test)
bare_words :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	fresh_audit("bare")

	file := fmt.tprintf("%s/doc.txt", scratch())
	_ = os.write_entire_file(file, transmute([]u8)string("x"))

	code, handled := kit.cli_args(window(true), {"tabel"})
	testing.expect(t, handled && code == kit.EXIT_USAGE, "a typo is a usage error, not a window")
	_, handled = kit.cli_args(window(true), {file})
	testing.expect(t, !handled, "an existing file opens the window")
	_, handled = kit.cli_args(window(true), {"magnet:?xt=urn:btih:abc"})
	testing.expect(t, !handled, "so does a URI")
	_, handled = kit.cli_args(window(true), {"https://example.org/a"})
	testing.expect(t, !handled, "and a URL")
	code, handled = kit.cli_args(window(true), {"table", "--json"})
	testing.expect(t, handled && code == kit.EXIT_OK, "a verb is still a verb")
	_, handled = kit.cli_args(window(false), {"tabel"})
	testing.expect(t, !handled, "without takes_word every bare word still opens the window, as before")

	testing.expect(t, !kit.cli_word_is_path("no-such-file-here"), "a missing file is not a path")
	testing.expect(t, !kit.cli_word_is_path("1:2"), "nor is a word with a colon that is not a scheme")
	testing.expect(t, kit.cli_word_is_path("mailto:a@b.c"), "a scheme is")
}

// ---------------------------------------------------------------------------
// 5. Destructive refusal with the application's reason
// ---------------------------------------------------------------------------

@(test)
destructive_reason :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	audit := fresh_audit("refuse")

	g_refuse_guard = ""
	code, doc, _ := run("drop", "libfoo")
	testing.expect_value(t, code, kit.EXIT_NEEDS_YES)
	testing.expect_value(t, str(doc, "error"), kit.ERR_NEEDS_YES)
	testing.expect_value(t, str(doc, "reason"), "has-dependants")
	testing.expect_value(t, str(doc, "pass"), "--yes")
	deps, _ := obj(doc)["dependants"].(json.Array)
	testing.expect_value(t, len(deps), 2)
	testing.expect(t, strings.contains(str(doc, "detail"), "app-a"), "the detail names them")
	testing.expect(t, g_refuse_guard != "", "and nothing could run while it explained itself")

	code, doc, _ = run("drop", "libfoo", "--yes")
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect_value(t, str(doc, "dropped"), "libfoo")

	code, doc, _ = run("wipe")
	testing.expect_value(t, code, kit.EXIT_NEEDS_YES)
	testing.expect(t, strings.contains(str(doc, "detail"), "destructive"), "without a hook, the generic reason")

	log := read_file(audit)
	testing.expect(t, strings.contains(log, `"error":"needs --yes"`), "the refusal is audited with its token")
}

// ---------------------------------------------------------------------------
// 6. Text output
// ---------------------------------------------------------------------------

@(test)
text_output :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	fresh_audit("text")

	testing.expect_value(t, kit.cli_display_width("abc"), 3)
	testing.expect_value(t, kit.cli_display_width("é€"), 2)
	testing.expect_value(t, kit.cli_display_width("é"), 1)
	testing.expect_value(t, kit.cli_display_width("東京"), 4)

	code, text, _ := kit.cli_capture(surface(), {"table"})
	testing.expect_value(t, code, kit.EXIT_OK)
	lines := strings.split_lines(strings.trim_space(text), context.temp_allocator)
	testing.expect_value(t, len(lines), 6) // "rows:", the header, four rows
	col := -1
	for l in lines[1:] {
		i := strings.index_byte(l, '|')
		if i < 0 && strings.contains(l, "end") {
			i = strings.index(l, "end")
		}
		w := kit.cli_display_width(l[:i])
		if col < 0 {
			col = w
		}
		testing.expectf(t, w == col, "the last column starts at display column %d in every row: %q", col, l)
	}

	code, text, _ = kit.cli_capture(surface(), {"wipe", "--dry-run"})
	testing.expect_value(t, code, kit.EXIT_OK)
	testing.expect(t, !strings.contains(text, "dry_run"), "a dry run in text mode does not print dry_run")
	code, text, _ = kit.cli_capture(surface(), {"wipe", "--dry-run", "--json"})
	testing.expect(t, strings.contains(text, `"dry_run": true`), "under --json it still says so")
}

// ---------------------------------------------------------------------------
// 7. The guard
// ---------------------------------------------------------------------------

@(test)
guard_packages :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)

	refused := [][]string {
		{"sudo", "pacman", "-S", "--", "ripgrep"},
		{"sudo", "true"},
		{"/usr/bin/sudo", "-n", "ls"},
		{"doas", "ls"},
		{"pkexec", "ls"},
		{"pacman", "-S", "ripgrep"},
		{"pacman", "-Syu"},
		{"pacman", "-Sy"},
		{"pacman", "-Sc"},
		{"pacman", "--sync", "--refresh"},
		{"pacman", "-R", "htop"},
		{"pacman", "-Rs", "htop"},
		{"pacman", "-U", "x.pkg.tar.zst"},
		{"pacman", "-D", "--asdeps", "x"},
		{"pacman", "-Fy"},
		{"yay"},
		{"yay", "ripgrep"},
		{"yay", "-S", "ripgrep"},
		{"paru", "-Syu"},
		{"snapper", "create", "-d", "x"},
		{"snapper", "-c", "root", "create"},
		{"snapper", "delete", "7"},
		{"snapper", "rollback", "7"},
		{"snapper", "undochange", "1..2"},
	}
	allowed := [][]string {
		{"pacman", "-Q"},
		{"pacman", "-Qq"},
		{"pacman", "-Qi", "git"},
		{"pacman", "-Si", "git"},
		{"pacman", "-Ss", "ripgrep"},
		{"pacman", "-Sl"},
		{"pacman", "-F", "bin/ls"},
		{"pacman", "-T", "git"},
		{"pacman", "--query", "--info", "git"},
		{"yay", "-Ss", "ripgrep"},
		{"yay", "-Qm"},
		{"snapper", "list"},
		{"snapper", "-c", "root", "list"},
		{"snapper", "--machine-readable", "json", "list"},
		{"snapper", "status", "1..2"},
	}
	for argv in refused {
		testing.expectf(t, kit.cli_forbidden(argv) != "", "refused: %v", argv)
	}
	for argv in allowed {
		testing.expectf(t, kit.cli_forbidden(argv) == "", "allowed: %v (%s)", argv, kit.cli_forbidden(argv))
	}
}

// ---------------------------------------------------------------------------
// 8. The rest: partial results, capture, keyed shapes, the audit format, jobs
// ---------------------------------------------------------------------------

@(test)
partial_results :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	fresh_audit("partial")

	code, doc, _ := run("fetch")
	testing.expect_value(t, code, kit.EXIT_UNAVAILABLE)
	testing.expect_value(t, str(doc, "error"), kit.ERR_UNAVAILABLE)
	part, has := obj(doc)["partial"].(json.Object)
	testing.expect(t, has, "the refusal carries what was done")
	got, _ := part["fetched"].(json.Array)
	testing.expect_value(t, len(got), 2)

	// Without cli_partial a failure is the refusal alone, as before.
	code, doc, _ = run("fields")
	_, has = obj(doc)["partial"]
	testing.expect(t, !has, "no partial unless asked for")
}

@(test)
keyed_shapes :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)

	SHAPE :: []kit.Field {
		{name = "versions", kind = .Object, keyed = true, of = {{kind = .String}}},
		{name = "by_day", kind = .Object, keyed = true, of = {{name = "count", kind = .Int}}},
	}
	good := `{"versions": {"git": "2.47", "htop": "3.3"}, "by_day": {"2026-10-20": {"count": 3}, "2026-10-21": {"count": 0}}}`
	testing.expect_value(t, len(kit.cli_validate_output(good, SHAPE, context.temp_allocator)), 0)
	bad := `{"versions": {"git": 2}, "by_day": {"2026-10-20": {"count": "three"}, "x": 1}}`
	problems := kit.cli_validate_output(bad, SHAPE, context.temp_allocator)
	testing.expectf(t, len(problems) == 3, "three problems, got %v", problems)
	empty := `{"versions": {}, "by_day": {}}`
	testing.expect_value(t, len(kit.cli_validate_output(empty, SHAPE, context.temp_allocator)), 0)
}

@(test)
audit_format :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	audit := fresh_audit("format")

	run("sync", "--profile", "a")
	run("wipe")
	log := read_file(audit)
	lines := strings.split_lines(strings.trim_space(log), context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	for l in lines {
		_, err := json.parse_string(l, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		testing.expectf(t, err == nil, "each line is one JSON document: %q", l)
		testing.expect(t, strings.has_prefix(l, `{"at":"`), "compact, as applications' self-tests grep it")
	}
	testing.expect(t, strings.contains(lines[1], `"error":"needs --yes"`), "a refusal carries the --json token")
	testing.expect(t, !strings.contains(lines[0], `"error"`), "a success does not")
}

@(test)
jobs_and_progress :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	dir := fmt.tprintf("%s/jobs", scratch())
	os.remove_all(dir)
	os.set_env("PALM_JOBS", dir)
	defer os.unset_env("PALM_JOBS")

	c, _ := kit.cli_bind(surface(), {"sync", "--json"})
	job := kit.cli_job_begin(&c, "three things")
	testing.expect(t, job.path != "" && os.exists(job.path), "a job leaves a record")
	running := kit.cli_jobs("tool")
	testing.expect_value(t, kit.jlen(running), 1)
	for i in 1 ..= 3 {
		kit.cli_job_progress(&job, i, 3)
	}
	kit.cli_job_end(&job, kit.EXIT_OK)
	all := kit.cli_jobs("tool")
	testing.expect_value(t, kit.jlen(all), 1)
	if kit.jlen(all) == 1 {
		rec := all.items[0]
		state, _ := kit.jget(rec, "state")
		done, _ := kit.jget(rec, "done")
		code, _ := kit.jget(rec, "code")
		testing.expect_value(t, state.s, "done")
		testing.expect_value(t, done.i, 3)
		testing.expect_value(t, code.i, 0)
	}
	testing.expect_value(t, kit.jlen(kit.cli_jobs("another-noun")), 0)
	kit.cli_job_forget(&job)
	testing.expect_value(t, kit.jlen(kit.cli_jobs("tool")), 0)
}

@(test)
capture_helper :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	fresh_audit("capture")

	code, doc, text := kit.cli_capture_json(surface(), {"table"})
	testing.expect_value(t, code, kit.EXIT_OK)
	rows, _ := obj(doc)["rows"].(json.Array)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, len(kit.cli_validate_output(text, COMMANDS[6].out, context.temp_allocator)), 0)

	// The capture is undone afterwards: a nested or later call prints again.
	_, inner, _ := kit.cli_capture(surface(), {"--schema"})
	testing.expect(t, strings.contains(inner, `"noun": "tool"`), "--schema is captured too")
}

// ---------------------------------------------------------------------------
// The second round: private positionals, dashes, aliases, wide tables
// ---------------------------------------------------------------------------

@(test)
private_positionals :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	audit := fresh_audit("private")

	code, doc, _ := run("clip", "copied-text-one", "--kind", "plain", "copied text two", "-dash-text")
	testing.expect_value(t, code, kit.EXIT_OK)
	n, _ := obj(doc)["n"].(json.Integer)
	testing.expect_value(t, n, 3)
	code, doc, _ = run("clip", "copied-text-one", "--parse-only")
	testing.expect_value(t, str(obj(doc)["args"], "text"), kit.CLI_REDACTED)
	code, _, _ = run("unlock", "my-pass-phrase-9")
	testing.expect_value(t, code, kit.EXIT_OK)

	log := read_file(audit)
	for leak in ([?]string{"copied-text-one", "copied text two", "-dash-text", "my-pass-phrase-9"}) {
		testing.expectf(t, !strings.contains(log, leak), "the audit log does not hold %q", leak)
	}
	testing.expect(t, strings.contains(log, `"argv":["clip","<redacted>","--kind","plain","<redacted>","<redacted>","--json"]`), "the verb and the flags are kept; each positional is a placeholder")
}

@(test)
dashes_and_aliases :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_lock)
	defer sync.mutex_unlock(&g_lock)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	fresh_audit("dashes")

	// The command's own flags win over the base aliases.
	code, doc, _ := run("box", "--h", "12", "-v", "7", "--yes")
	testing.expect_value(t, code, kit.EXIT_OK)
	h, _ := obj(doc)["h"].(json.Integer)
	w, _ := obj(doc)["w"].(json.Integer)
	testing.expect_value(t, h, 12)
	testing.expect_value(t, w, 7)
	code, _, _ = run("box", "-h", "3", "-y")
	testing.expect_value(t, code, kit.EXIT_OK)

	// `--y` is no longer --yes; only `-y` is.
	code, _, _ = run("wipe", "--y")
	testing.expect_value(t, code, kit.EXIT_USAGE)
	code, _, _ = run("wipe", "-y")
	testing.expect_value(t, code, kit.EXIT_OK)
	code, _, _ = run("wipe", "--yes")
	testing.expect_value(t, code, kit.EXIT_OK)
	c, bc := kit.cli_bind(surface(), {"table", "-h"})
	testing.expect(t, bc == kit.EXIT_OK && c.want_help, "-h is still help where the command has no h")

	// Values that start with a dash.
	code, doc, _ = run("box", "-5", "- One", "--yes")
	testing.expect_value(t, code, kit.EXIT_OK)
	off, _ := obj(doc)["offset"].(json.Integer)
	testing.expect_value(t, off, -5)
	testing.expect_value(t, str(doc, "label"), "- One")
	code, _, _ = run("box", "--nope", "--yes")
	testing.expect_value(t, code, kit.EXIT_USAGE) // a mistyped flag is still refused

	// A table of more than eight columns is still a table.
	_, text, _ := kit.cli_capture(surface(), {"wide"})
	testing.expect(t, strings.contains(text, "c0   c1   c2"), "ten columns side by side")
}
