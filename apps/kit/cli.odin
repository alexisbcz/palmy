// The shared command-line convention.
//
// Every application here is a library with two front ends: the window, and
// this. The CLI is not a reduced version of the GUI — it is the same code
// reached a different way — and it is written for an agent first, a person
// second.
//
// An application does not parse its own arguments. It *declares* its commands
// — verb, side-effect class, arguments, flags, the shape of the object it
// prints, and examples — and hands the declaration to `kit.cli`. From that one
// declaration the kit parses and validates the command line, generates
// `--help`, emits `--json`, honours `--dry-run`, refuses a destructive command
// without `--yes`, enforces identity scope, writes the audit record, and
// produces the documented exit codes. `--schema` prints the declaration
// itself, which is what `palm schema` reads: the index and the behaviour
// cannot drift apart, because they are the same data.
//
//	// Two shapes matter here and both are the compiler's doing rather than
//	// taste. The commands are a *package* variable, because a slice literal
//	// written inside a procedure lives on that procedure's stack frame and is
//	// gone the moment it returns. And `surface` is a *procedure*, because
//	// package initialisers run in declaration order and one that pointed at a
//	// field list declared further down would capture it empty — a schema that
//	// lies, which is the one thing this convention exists to prevent. Keep the
//	// field lists self-contained literals and the order stops mattering.
//	@(private = "file")
//	COMMANDS := []kit.Command {
//		{
//			verb     = "list",
//			summary  = "every note, newest first",
//			effect   = .Read,
//			out      = LIST_FIELDS,
//			examples = {"notes list --json"},
//			run      = cmd_list,
//		},
//	}
//
//	@(private = "file")
//	g_surface: kit.Surface
//
//	surface :: proc() -> ^kit.Surface {
//		if g_surface.noun == "" {
//			g_surface = kit.Surface {
//				noun     = "notes",
//				summary  = "a notebook",
//				gui      = true,
//				selftest = cli_selftest,
//				commands = COMMANDS,
//			}
//		}
//		return &g_surface
//	}
//
//	main :: proc() {
//		if code, handled := kit.cli(surface()); handled {
//			os.exit(code)
//		}
//		... open the window ...
//	}
//
// Three rules matter more than the rest, and all three are here rather than in
// a document, because a document does not fail a build.
//
//  1. **Machine output goes to stdout and nothing else does.** Under `--json`
//     the kit writes exactly one JSON document to stdout. Progress, warnings
//     and prose go to stderr through `cli_note`. A pipeline never has to strip
//     chatter out of a document.
//
//  2. **Refusal, never prompting.** Nothing in this file reads standard input.
//     A `destructive` command without `--yes` exits 4 with a machine-readable
//     reason; it does not ask, so it cannot hang an agent on a TTY read.
//
//  3. **A declared side-effect class per command**, so a caller can decide
//     whether a retry is safe before it runs anything.
package kit

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Exit codes
//
// Stable, so a caller can branch on failure without reading English.
// ---------------------------------------------------------------------------

EXIT_OK :: 0 // ok
EXIT_USAGE :: 2 // usage error
EXIT_NOT_FOUND :: 3 // not found
EXIT_NEEDS_YES :: 4 // refused: needs --yes
EXIT_OUT_OF_SCOPE :: 5 // refused: out of scope for this identity
EXIT_UNAVAILABLE :: 6 // unavailable: the thing it talks to is not running
EXIT_FAILED :: 7 // failed

// The `error` token each code carries. The token is the stable thing; the
// `detail` beside it is for a person reading the transcript afterwards.
ERR_USAGE :: "usage"
ERR_NOT_FOUND :: "not found"
ERR_NEEDS_YES :: "needs --yes"
ERR_OUT_OF_SCOPE :: "out of scope"
ERR_UNAVAILABLE :: "unavailable"
ERR_FAILED :: "failed"

// cli_exit_reason maps an exit code to its token, so the self-tests can check
// that a refusal's code and its text agree.
cli_exit_reason :: proc(code: int) -> string {
	switch code {
	case EXIT_OK:
		return "ok"
	case EXIT_USAGE:
		return ERR_USAGE
	case EXIT_NOT_FOUND:
		return ERR_NOT_FOUND
	case EXIT_NEEDS_YES:
		return ERR_NEEDS_YES
	case EXIT_OUT_OF_SCOPE:
		return ERR_OUT_OF_SCOPE
	case EXIT_UNAVAILABLE:
		return ERR_UNAVAILABLE
	case EXIT_FAILED:
		return ERR_FAILED
	}
	return ERR_FAILED
}

// CLI_EXIT_CODES is every code the convention documents, for the assertion
// that says each one is produced by something.
CLI_EXIT_CODES := [?]int {
	EXIT_OK,
	EXIT_USAGE,
	EXIT_NOT_FOUND,
	EXIT_NEEDS_YES,
	EXIT_OUT_OF_SCOPE,
	EXIT_UNAVAILABLE,
	EXIT_FAILED,
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

// Effect is the question a caller asks before running anything: can I retry
// this, and what does it touch.
Effect :: enum u8 {
	Read, // no state changes; always safe
	Idempotent, // converges on a state; safe to repeat
	Mutate, // changes state; repeating is not the same as running once
	Destructive, // loses data or is hard to undo; refuses without --yes
	Intent, // deliberately does nothing but log what it would have done
}

effect_name :: proc(e: Effect) -> string {
	switch e {
	case .Read:
		return "read"
	case .Idempotent:
		return "idempotent"
	case .Mutate:
		return "mutate"
	case .Destructive:
		return "destructive"
	case .Intent:
		return "intent"
	}
	return "read"
}

effect_meaning :: proc(e: Effect) -> string {
	switch e {
	case .Read:
		return "no state changes; always safe"
	case .Idempotent:
		return "converges on a state; safe to repeat"
	case .Mutate:
		return "changes state; repeating is not the same as running once"
	case .Destructive:
		return "loses data or is hard to undo; refuses without --yes"
	case .Intent:
		return "logs what it would have done and executes nothing"
	}
	return ""
}

// Val_Kind is an argument's type, so an agent planning from the schema knows
// what to put there.
Val_Kind :: enum u8 {
	String,
	Int,
	Float,
	Bool, // a flag with no value; --no-NAME turns it off again
	Enum, // one of `values`
	Path,
}

val_kind_name :: proc(k: Val_Kind) -> string {
	switch k {
	case .String:
		return "string"
	case .Int:
		return "int"
	case .Float:
		return "float"
	case .Bool:
		return "bool"
	case .Enum:
		return "enum"
	case .Path:
		return "path"
	}
	return "string"
}

// Param is one positional argument or one flag.
Param :: struct {
	name:     string, // `note` → <note>, or --note
	short:    string, // a one-letter alias, flags only
	kind:     Val_Kind,
	help:     string,
	required: bool,
	variadic: bool, // the last positional may swallow the rest
	values:   []string, // Enum only
	def:      string, // the default, as it would be typed
}

// Schema_Kind describes the shape of a field in a command's output.
Schema_Kind :: enum u8 {
	Any,
	String,
	Int,
	Float,
	Bool,
	Array,
	Object,
}

schema_kind_name :: proc(k: Schema_Kind) -> string {
	switch k {
	case .Any:
		return "any"
	case .String:
		return "string"
	case .Int:
		return "int"
	case .Float:
		return "float"
	case .Bool:
		return "bool"
	case .Array:
		return "array"
	case .Object:
		return "object"
	}
	return "any"
}

// Field declares one key of the object a command prints. An Array's `of`
// describes its elements: a one-element `of` whose name is empty means an
// array of that scalar, and anything else means an array of objects with
// those fields.
Field :: struct {
	name: string,
	kind: Schema_Kind,
	help: string,
	opt:  bool, // may be absent
	of:   []Field,
}

// Command is one verb of one noun.
Command :: struct {
	verb:     string,
	summary:  string,
	effect:   Effect,
	args:     []Param, // positional, in order
	flags:    []Param,
	out:      []Field, // the fields of the object this prints
	examples: []string,
	aliases:  []string, // kept so an old spelling such as `--export` still works
	hidden:   bool, // works, but stays out of the index
	run:      proc(c: ^Call) -> int,
}

// Surface is everything one binary offers.
Surface :: struct {
	noun:     string, // `notes`, the name `palm notes ...` routes on
	summary:  string,
	commands: []Command,
	selftest: proc() -> int, // --selftest, the one existing convention kept
	gui:      bool, // opens a window when given no command
	// takes_path says a bare word that is not a verb is a document for the
	// window — `sheets book.csv`. Without it an unrecognised word is a usage
	// error, because silently opening a window is the wrong answer to a typo
	// and, worse, a command that never returns to whatever ran it.
	takes_path: bool,
	notes:    string, // extra paragraph for --help
}

// ---------------------------------------------------------------------------
// A call in progress
// ---------------------------------------------------------------------------

Call :: struct {
	surface:  ^Surface,
	cmd:      ^Command,
	argv:     []string, // everything after the binary name

	// the base flags, parsed by the kit for every command
	json:     bool,
	dry_run:  bool,
	yes:      bool,
	verbose:  bool,
	identity: string, // the scope in force, after narrowing

	// parsed values, keyed by parameter name
	vals:     map[string]string,
	seen:     map[string]bool,
	rest:     []string, // a variadic positional's tail

	// --help was given: the binding stops as soon as it is seen, so that
	// `notes read --help` describes the command rather than complaining that
	// <note> is missing.
	want_help: bool,

	// what the command fills in and what it failed with
	out:      ^Json,
	err:      ^Json,
}

// cli_has reports whether a flag or argument was given explicitly.
cli_has :: proc(c: ^Call, name: string) -> bool {
	return c.seen[name]
}

// cli_str is a parameter's value, or its declared default, or "".
cli_str :: proc(c: ^Call, name: string) -> string {
	if v, ok := c.vals[name]; ok {
		return v
	}
	return ""
}

cli_int :: proc(c: ^Call, name: string, def := 0) -> int {
	s := cli_str(c, name)
	if s == "" {
		return def
	}
	if n, ok := strconv.parse_int(s); ok {
		return n
	}
	return def
}

cli_f64 :: proc(c: ^Call, name: string, def := 0.0) -> f64 {
	s := cli_str(c, name)
	if s == "" {
		return def
	}
	if n, ok := strconv.parse_f64(s); ok {
		return n
	}
	return def
}

// cli_bool is a Bool flag's state, with --no-NAME having turned it off again.
cli_bool :: proc(c: ^Call, name: string) -> bool {
	return cli_str(c, name) == "true"
}

// cli_rest is a variadic positional's tail.
cli_rest :: proc(c: ^Call) -> []string {
	return c.rest
}

// cli_note writes progress or a warning. It goes to stderr, always, so a
// pipeline reading stdout under --json never sees it.
cli_note :: proc(c: ^Call, format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
}

// cli_trace is cli_note, but only under --verbose.
cli_trace :: proc(c: ^Call, format: string, args: ..any) {
	if c != nil && c.verbose {
		fmt.eprintfln(format, ..args)
	}
}

// cli_fail records a refusal or a failure and returns the exit code, so a
// command body reads `return kit.cli_fail(c, kit.EXIT_NOT_FOUND, ...)`.
cli_fail :: proc(c: ^Call, code: int, detail := "") -> int {
	c.err = jobj()
	jset_str(c.err, "error", cli_exit_reason(code))
	jset_int(c.err, "code", code)
	verb := c.cmd != nil ? c.cmd.verb : ""
	jset_str(c.err, "command", strings.trim_space(fmt.tprintf("%s %s", c.surface.noun, verb)))
	if detail != "" {
		jset_str(c.err, "detail", detail)
	}
	return code
}

// cli_failf is cli_fail with a formatted detail.
cli_failf :: proc(c: ^Call, code: int, format: string, args: ..any) -> int {
	return cli_fail(c, code, fmt.tprintf(format, ..args))
}

// cli_err_field adds a machine-readable field to the refusal, next to the
// token: `{"error":"out of scope","identity":"work","requested":"personal"}`.
cli_err_field :: proc(c: ^Call, key, value: string) {
	if c.err == nil {
		c.err = jobj()
	}
	jset_str(c.err, key, value)
}

// ---------------------------------------------------------------------------
// The execution guard
//
// While a CLI command is running, the kit's own process helpers refuse the
// things this project has decided no command may do. This is the enforcement
// the safety rules asked for: it is a check in the code, not a line in a
// document, and every application that reaches a subprocess through `kit.run`,
// `kit.run_lines` or `kit.launch` inherits it.
//
// The guard is armed by the dispatcher and is off everywhere else, so the GUI
// paths of the other applications behave exactly as they did.
// ---------------------------------------------------------------------------

@(private = "file")
g_guard_on: bool
@(private = "file")
g_guard_intent: bool
@(private = "file")
g_guard_last: string

// cli_guard_reason is why the guard refused the last command it stopped, which
// is how an application turns a refusal into a message and how the self-tests
// check the guard without spawning anything.
cli_guard_reason :: proc() -> string {
	return g_guard_last
}

// cli_guard_active reports whether a CLI command is running under the guard.
cli_guard_active :: proc() -> bool {
	return g_guard_on
}

// cli_guard_check is the predicate `run`, `run_lines` and `launch` consult.
// It returns "" when the command may proceed.
cli_guard_check :: proc(argv: []string) -> (why: string) {
	if !g_guard_on || len(argv) == 0 {
		return ""
	}
	if g_guard_intent {
		return "an intent-class command executes nothing"
	}
	return cli_forbidden(argv)
}

// cli_forbidden is the denylist itself, separated out so a test can read it
// without arming the guard.
//
// Every entry is a decision this project already made somewhere else, moved
// into one place:
//
//   - networking is read-only: nothing may drop this machine's connection,
//     which would take the session doing the work offline with it;
//   - power and session actions are intent-only;
//   - the login and model daemons are never started or stopped;
//   - the camera and the microphone are never opened.
cli_forbidden :: proc(argv: []string) -> (why: string) {
	if len(argv) == 0 {
		return ""
	}
	exe := argv[0]
	if i := strings.last_index_byte(exe, '/'); i >= 0 {
		exe = exe[i + 1:]
	}
	has :: proc(argv: []string, word: string) -> bool {
		for a in argv[1:] {
			if a == word {
				return true
			}
		}
		return false
	}
	has_sub :: proc(argv: []string, word: string) -> bool {
		for a in argv {
			if strings.contains(a, word) {
				return true
			}
		}
		return false
	}

	switch exe {
	case "reboot", "poweroff", "halt", "shutdown", "kexec":
		return "power actions are intent-only"
	case "systemctl":
		for verb in ([?]string{"poweroff", "reboot", "halt", "suspend", "hibernate", "hybrid-sleep", "kexec", "emergency", "rescue"}) {
			if has(argv, verb) {
				return "power and session actions are intent-only"
			}
		}
		lifecycle := false
		for verb in ([?]string{"enable", "disable", "start", "stop", "restart", "mask", "unmask", "isolate"}) {
			if has(argv, verb) {
				lifecycle = true
			}
		}
		if lifecycle {
			for unit in ([?]string{"sddm", "greetd", "display-manager", "ollama", "NetworkManager", "systemd-networkd", "iwd", "wpa_supplicant"}) {
				if has_sub(argv, unit) {
					return fmt.tprintf("%s is never started or stopped from here", unit)
				}
			}
		}
	case "loginctl":
		for verb in ([?]string{"terminate-session", "terminate-user", "kill-session", "kill-user", "lock-session", "lock-sessions", "poweroff", "reboot", "suspend", "hibernate"}) {
			if has(argv, verb) {
				return "session actions are intent-only"
			}
		}
	case "nmcli":
		if has(argv, "radio") && has(argv, "off") {
			return "networking is read-only: this would take the machine offline"
		}
		if has(argv, "networking") && has(argv, "off") {
			return "networking is read-only: this would take the machine offline"
		}
		if has(argv, "device") && (has(argv, "disconnect") || has(argv, "connect")) {
			return "networking is read-only: this would drop the current connection"
		}
		if has(argv, "connection") && (has(argv, "down") || has(argv, "delete") || has(argv, "up")) {
			return "networking is read-only: this would change the active connection"
		}
	case "rfkill":
		if has(argv, "block") {
			return "networking is read-only: blocking a radio would take the machine offline"
		}
	case "ip", "iw", "ifconfig", "iwconfig":
		if has(argv, "down") {
			return "networking is read-only: this would take an interface down"
		}
	case "arecord", "parecord", "pw-record", "pactl":
		if exe != "pactl" || has(argv, "load-module") {
			return "the microphone is never captured; synthetic sources only"
		}
	case "ffmpeg", "ffplay", "gst-launch-1.0", "wf-recorder", "obs":
		if has_sub(argv, "/dev/video") ||
		   has(argv, "v4l2") ||
		   has(argv, "alsa") ||
		   has(argv, "pulse") ||
		   has(argv, "avfoundation") ||
		   has(argv, "dshow") {
			return "the camera and microphone are never captured; synthetic sources only"
		}
	}
	return ""
}

@(private = "file")
guard_arm :: proc(intent: bool) {
	g_guard_on = true
	g_guard_intent = intent
}

@(private = "file")
guard_disarm :: proc() {
	g_guard_on = false
	g_guard_intent = false
}

// cli_guard_refuse is called by the process helpers when the guard bites. It
// records the reason and reports it on stderr, never stdout.
@(private)
cli_guard_refuse :: proc(argv: []string, why: string) {
	line := strings.join(argv, " ", context.temp_allocator)
	g_guard_last = fmt.aprintf("%s: %s", line, why)
	fmt.eprintfln("[kit] REFUSED, not executed: %s   (%s)", line, why)
	audit_write_raw("refused", line, why)
}

// ---------------------------------------------------------------------------
// Intent
// ---------------------------------------------------------------------------

// cli_intent is the whole implementation of an intent-class command: it
// records what would have run and runs nothing. The guard above is armed for
// the duration of such a command, so the kit's process helpers would refuse
// even if a body tried.
// `quiet` is for an application that already has its own intent log and has
// just written the same line itself; the record and the refusal are the same
// either way.
cli_intent :: proc(c: ^Call, command: string, label: string, quiet := false) -> int {
	jset_str(c.out, "intent", command)
	if label != "" {
		jset_str(c.out, "label", label)
	}
	jset_bool(c.out, "executed", false)
	jset_str(c.out, "effect", "intent")
	if !quiet {
		fmt.eprintfln("[%s] INTENT ONLY, not executed: %s   (%s)", c.surface.noun, command, label)
	}
	audit_write_raw("intent", command, label)
	return EXIT_OK
}

// ---------------------------------------------------------------------------
// The audit log
//
// Every command that is not `read` leaves a line behind: what ran, under which
// identity, and what it exited with. `palm audit` reads it back. Append-only
// JSONL, one object per line, so a tail is a valid read of the end of it.
// ---------------------------------------------------------------------------

// cli_audit_path is where the log lives. $PALM_AUDIT overrides it, which is
// what the self-tests use so a test run never touches the real log.
cli_audit_path :: proc(allocator := context.temp_allocator) -> string {
	if p := os.get_env("PALM_AUDIT", context.temp_allocator); p != "" {
		return strings.clone(p, allocator)
	}
	base := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			return ""
		}
		base = fmt.tprintf("%s/.local/state", home)
	}
	return strings.clone(fmt.tprintf("%s/palm/audit.jsonl", base), allocator)
}

@(private = "file")
audit_now :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

@(private = "file")
audit_append :: proc(rec: ^Json) {
	path := cli_audit_path()
	if path == "" {
		return
	}
	if i := strings.last_index_byte(path, '/'); i > 0 {
		dir := path[:i]
		if !os.is_dir(dir) {
			// One level is enough for ~/.local/state/palm; make the parent too
			// in case the state directory itself is missing.
			if j := strings.last_index_byte(dir, '/'); j > 0 && !os.is_dir(dir[:j]) {
				os.make_directory(dir[:j])
			}
			if os.make_directory(dir) != nil && !os.is_dir(dir) {
				return
			}
		}
	}
	line := fmt.tprintf("%s\n", json_text(rec, 0, context.temp_allocator))
	f, oerr := os.open(path, {.Write, .Create, .Append}, os.perm(0o600))
	if oerr != nil {
		return
	}
	defer os.close(f)
	data := transmute([]u8)line
	off := 0
	for off < len(data) {
		n, werr := os.write(f, data[off:])
		if werr != nil || n == 0 {
			break
		}
		off += n
	}
}

// audit_write_raw records something that happened outside a command's own
// result: an intent, or a refusal by the guard.
@(private)
audit_write_raw :: proc(kind, command, detail: string) {
	rec := jobj(context.temp_allocator)
	jset_str(rec, "at", audit_now(), context.temp_allocator)
	jset_str(rec, "kind", kind, context.temp_allocator)
	jset_str(rec, "command", command, context.temp_allocator)
	if detail != "" {
		jset_str(rec, "detail", detail, context.temp_allocator)
	}
	jset_bool(rec, "executed", false, context.temp_allocator)
	audit_append(rec)
}

@(private = "file")
audit_call :: proc(c: ^Call, code: int) {
	if c.cmd == nil || c.cmd.effect == .Read {
		return
	}
	rec := jobj(context.temp_allocator)
	jset_str(rec, "at", audit_now(), context.temp_allocator)
	jset_str(rec, "kind", "command", context.temp_allocator)
	jset_str(rec, "noun", c.surface.noun, context.temp_allocator)
	jset_str(rec, "verb", c.cmd.verb, context.temp_allocator)
	jset_str(rec, "effect", effect_name(c.cmd.effect), context.temp_allocator)
	jset_str(rec, "identity", c.identity == "" ? "unscoped" : c.identity, context.temp_allocator)
	jset_bool(rec, "dry_run", c.dry_run, context.temp_allocator)
	jset_int(rec, "code", code, context.temp_allocator)
	av := jarr(context.temp_allocator)
	for a in c.argv {
		jpush(av, jstr(a, context.temp_allocator))
	}
	jset(rec, "argv", av, context.temp_allocator)
	audit_append(rec)
}

// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------

// Reserved identity names. `--identity all` would be widening with extra
// steps, so it is refused rather than interpreted.
@(private = "file")
RESERVED_IDENTITIES := [?]string{"all", "any", "*", "every"}

// cli_scope is the identity in force: $PALM_IDENTITY, narrowed by --identity.
cli_scope :: proc() -> string {
	return os.get_env("PALM_IDENTITY", context.temp_allocator)
}

// cli_scope_require refuses unless the caller is already inside `owner`'s
// scope. A secret, or anything else belonging to one identity, goes through
// this. There is no argument that widens the scope: the only outcomes are the
// caller's own identity and a refusal.
cli_scope_require :: proc(c: ^Call, owner: string) -> (ok: bool) {
	if c.identity == "" || c.identity == owner {
		return true
	}
	cli_fail(c, EXIT_OUT_OF_SCOPE, fmt.tprintf("this belongs to %q", owner))
	cli_err_field(c, "identity", c.identity)
	cli_err_field(c, "requested", owner)
	return false
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

@(private = "file")
find_command :: proc(s: ^Surface, token: string) -> ^Command {
	for &cmd in s.commands {
		if cmd.verb == token {
			return &cmd
		}
		for a in cmd.aliases {
			if a == token {
				return &cmd
			}
		}
	}
	return nil
}

@(private = "file")
find_flag :: proc(cmd: ^Command, name: string) -> ^Param {
	for &f in cmd.flags {
		if f.name == name || (f.short != "" && f.short == name) {
			return &f
		}
	}
	return nil
}

@(private = "file")
enum_ok :: proc(p: ^Param, v: string) -> bool {
	if p.kind != .Enum || len(p.values) == 0 {
		return true
	}
	for allowed in p.values {
		if allowed == v {
			return true
		}
	}
	return false
}

@(private = "file")
value_ok :: proc(p: ^Param, v: string) -> (why: string) {
	switch p.kind {
	case .Int:
		if _, ok := strconv.parse_int(v); !ok {
			return fmt.tprintf("%s wants a whole number, got %q", p.name, v)
		}
	case .Float:
		if _, ok := strconv.parse_f64(v); !ok {
			return fmt.tprintf("%s wants a number, got %q", p.name, v)
		}
	case .Enum:
		if !enum_ok(p, v) {
			return fmt.tprintf(
				"%s must be one of %s, got %q",
				p.name,
				strings.join(p.values, "|", context.temp_allocator),
				v,
			)
		}
	case .String, .Path, .Bool:
	}
	return ""
}

// cli_bind parses `argv` against the surface without running anything. It is
// the whole of the validation, which is why `--parse-only` can use it to prove
// an example in the schema still parses.
cli_bind :: proc(s: ^Surface, argv: []string) -> (c: Call, code: int) {
	c.surface = s
	c.argv = argv
	c.vals = make(map[string]string)
	c.seen = make(map[string]bool)
	c.out = jobj()
	c.identity = cli_scope()

	// --json is looked for before anything else is parsed. A refusal that
	// happens while reading the command line is still a result an agent has to
	// read, and whether it arrives as a document should not depend on where in
	// the line the flag happened to sit.
	for a in argv {
		if a == "--json" {
			c.json = true
		}
	}

	if len(argv) == 0 {
		return c, cli_fail(&c, EXIT_USAGE, "no command given")
	}

	head := argv[0]
	inline_val := ""
	have_inline := false
	if eq := strings.index_byte(head, '='); eq > 0 && strings.has_prefix(head, "--") {
		inline_val = head[eq + 1:]
		have_inline = true
		head = head[:eq]
	}
	c.cmd = find_command(s, head)
	if c.cmd == nil {
		code = cli_fail(&c, EXIT_USAGE, fmt.tprintf("unknown command %q", head))
		cli_err_field(&c, "given", head)
		return c, code
	}

	// Defaults first, so cli_str answers with the declared default for
	// anything the caller left out.
	for p in c.cmd.args {
		if p.def != "" {
			c.vals[p.name] = p.def
		}
	}
	for p in c.cmd.flags {
		if p.kind == .Bool {
			c.vals[p.name] = p.def == "true" ? "true" : "false"
		} else if p.def != "" {
			c.vals[p.name] = p.def
		}
	}

	pos := make([dynamic]string, context.temp_allocator)
	if have_inline {
		append(&pos, inline_val)
	}
	no_more_flags := false

	i := 1
	for i < len(argv) {
		a := argv[i]
		i += 1

		if no_more_flags || !strings.has_prefix(a, "-") || a == "-" {
			append(&pos, a)
			continue
		}
		if a == "--" {
			no_more_flags = true
			continue
		}

		name := a
		val := ""
		have_val := false
		if eq := strings.index_byte(a, '='); eq > 0 {
			name = a[:eq]
			val = a[eq + 1:]
			have_val = true
		}
		bare := strings.trim_left(name, "-")

		// The base flags, which every command accepts.
		switch bare {
		case "json":
			c.json = true
			continue
		case "dry-run", "dryrun":
			c.dry_run = true
			continue
		case "yes", "y":
			c.yes = true
			continue
		case "verbose", "v":
			c.verbose = true
			continue
		case "help", "h":
			c.want_help = true
			continue
		case "identity":
			want := val
			if !have_val {
				if i >= len(argv) {
					return c, cli_fail(&c, EXIT_USAGE, "--identity needs a name")
				}
				want = argv[i]
				i += 1
			}
			for r in RESERVED_IDENTITIES {
				if want == r {
					code = cli_fail(&c, EXIT_OUT_OF_SCOPE, fmt.tprintf("%q is not an identity", want))
					cli_err_field(&c, "identity", c.identity == "" ? "unscoped" : c.identity)
					cli_err_field(&c, "requested", want)
					return c, code
				}
			}
			// Scope may be narrowed, never widened: asking for another
			// identity from inside one is a refusal, not a switch.
			if c.identity != "" && want != c.identity {
				code = cli_fail(&c, EXIT_OUT_OF_SCOPE, "scope may be narrowed, never widened")
				cli_err_field(&c, "identity", c.identity)
				cli_err_field(&c, "requested", want)
				return c, code
			}
			c.identity = want
			c.seen["identity"] = true
			continue
		}

		neg := false
		lookup := bare
		if strings.has_prefix(bare, "no-") {
			neg = true
			lookup = bare[3:]
		}
		p := find_flag(c.cmd, lookup)
		if p == nil && neg {
			p = find_flag(c.cmd, bare)
			neg = false
			lookup = bare
		}
		if p == nil {
			code = cli_fail(&c, EXIT_USAGE, fmt.tprintf("unknown flag %q", name))
			cli_err_field(&c, "given", name)
			return c, code
		}
		if p.kind == .Bool {
			if have_val {
				c.vals[p.name] = val == "true" || val == "yes" || val == "1" ? "true" : "false"
			} else {
				c.vals[p.name] = neg ? "false" : "true"
			}
			c.seen[p.name] = true
			continue
		}
		if !have_val {
			if i >= len(argv) {
				return c, cli_fail(&c, EXIT_USAGE, fmt.tprintf("--%s needs a value", p.name))
			}
			val = argv[i]
			i += 1
		}
		if why := value_ok(p, val); why != "" {
			return c, cli_fail(&c, EXIT_USAGE, why)
		}
		c.vals[p.name] = val
		c.seen[p.name] = true
	}

	// Asking for help is not a failed command line: stop before the rules
	// that could reject it, since the point of asking is not knowing them.
	if c.want_help {
		return c, EXIT_OK
	}

	// Positionals, in declared order.
	at := 0
	for p, pi in c.cmd.args {
		if p.variadic {
			if at < len(pos) {
				tail := make([]string, len(pos) - at)
				copy(tail, pos[at:])
				c.rest = tail
				c.vals[p.name] = pos[at]
				c.seen[p.name] = true
				at = len(pos)
			} else {
				c.rest = nil
			}
			continue
		}
		if at < len(pos) {
			if why := value_ok(&c.cmd.args[pi], pos[at]); why != "" {
				return c, cli_fail(&c, EXIT_USAGE, why)
			}
			c.vals[p.name] = pos[at]
			c.seen[p.name] = true
			at += 1
		}
	}
	if at < len(pos) {
		code = cli_fail(
			&c,
			EXIT_USAGE,
			fmt.tprintf("%s %s takes %d argument(s), got %d", s.noun, c.cmd.verb, len(c.cmd.args), len(pos)),
		)
		cli_err_field(&c, "extra", pos[at])
		return c, code
	}

	// Required things.
	for p in c.cmd.args {
		if p.required && cli_str(&c, p.name) == "" {
			code = cli_fail(&c, EXIT_USAGE, fmt.tprintf("%s %s needs <%s>", s.noun, c.cmd.verb, p.name))
			cli_err_field(&c, "missing", p.name)
			return c, code
		}
	}
	for p in c.cmd.flags {
		if p.required && cli_str(&c, p.name) == "" {
			code = cli_fail(&c, EXIT_USAGE, fmt.tprintf("%s %s needs --%s", s.noun, c.cmd.verb, p.name))
			cli_err_field(&c, "missing", p.name)
			return c, code
		}
	}

	// Refusal rather than prompting: a destructive command without --yes stops
	// here, with a reason a caller can read, and nothing has read stdin.
	if c.cmd.effect == .Destructive && !c.yes && !c.dry_run {
		code = cli_fail(&c, EXIT_NEEDS_YES, fmt.tprintf("%s %s is destructive", s.noun, c.cmd.verb))
		cli_err_field(&c, "effect", "destructive")
		cli_err_field(&c, "pass", "--yes")
		return c, code
	}

	return c, EXIT_OK
}

// cli_split_example splits an example command line into arguments the way a
// shell would, honouring single and double quotes. The assertion that every
// example a command ships still parses has to tokenise it the same way the
// person reading it would, or `notes new "Shopping list"` becomes two
// arguments and the check fails for the wrong reason.
cli_split_example :: proc(line: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	cur := strings.builder_make(allocator)
	quote: u8 = 0
	have := false
	flush :: proc(out: ^[dynamic]string, cur: ^strings.Builder, have: ^bool, allocator: mem.Allocator) {
		if have^ {
			append(out, strings.clone(strings.to_string(cur^), allocator))
			strings.builder_reset(cur)
			have^ = false
		}
	}
	for i in 0 ..< len(line) {
		ch := line[i]
		switch {
		case quote != 0 && ch == quote:
			quote = 0
		case quote == 0 && (ch == '"' || ch == '\''):
			quote = ch
			have = true
		case quote == 0 && (ch == ' ' || ch == '\t'):
			flush(&out, &cur, &have, allocator)
		case:
			strings.write_byte(&cur, ch)
			have = true
		}
	}
	flush(&out, &cur, &have, allocator)
	return out[:]
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

@(private = "file")
emit :: proc(c: ^Call, v: ^Json) {
	if c.json {
		fmt.println(json_text(v, 2, context.temp_allocator))
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	text_render(&sb, v, 0)
	s := strings.to_string(sb)
	if strings.trim_space(s) != "" {
		fmt.print(s)
		if !strings.has_suffix(s, "\n") {
			fmt.println()
		}
	}
}

// text_render is the human rendering of the same object the machine gets, so
// a command produces one result and never two. An array of flat objects that
// all share the same keys becomes a table, because that is the one shape worth
// the extra code.
@(private = "file")
text_render :: proc(sb: ^strings.Builder, v: ^Json, depth: int) {
	pad :: proc(sb: ^strings.Builder, depth: int) {
		for _ in 0 ..< depth * 2 {
			strings.write_byte(sb, ' ')
		}
	}
	if v == nil {
		return
	}
	switch v.kind {
	case .Null, .Bool, .Int, .Float, .String:
		pad(sb, depth)
		strings.write_string(sb, json_scalar(v))
		strings.write_byte(sb, '\n')
	case .Array:
		if len(v.items) == 0 {
			pad(sb, depth)
			strings.write_string(sb, "(none)\n")
			return
		}
		if table_render(sb, v, depth) {
			return
		}
		for it, i in v.items {
			// A blank line between elements only where an element is itself
			// several lines; a list of strings reads as a list, not as a
			// column of paragraphs.
			nested := it != nil && (it.kind == .Array || it.kind == .Object)
			if i > 0 && nested {
				strings.write_byte(sb, '\n')
			}
			text_render(sb, it, depth)
		}
	case .Object:
		w := 0
		for k in v.keys {
			w = max(w, len(k))
		}
		for it, i in v.items {
			k := v.keys[i]
			if it != nil && (it.kind == .Array || it.kind == .Object) {
				pad(sb, depth)
				strings.write_string(sb, k)
				strings.write_string(sb, ":\n")
				text_render(sb, it, depth + 1)
				continue
			}
			pad(sb, depth)
			strings.write_string(sb, k)
			strings.write_byte(sb, ':')
			for _ in 0 ..< w - len(k) + 1 {
				strings.write_byte(sb, ' ')
			}
			strings.write_string(sb, json_scalar(it))
			strings.write_byte(sb, '\n')
		}
	}
}

@(private = "file")
table_render :: proc(sb: ^strings.Builder, arr: ^Json, depth: int) -> bool {
	first := arr.items[0]
	if first == nil || first.kind != .Object || len(first.keys) == 0 || len(first.keys) > 8 {
		return false
	}
	for it in arr.items {
		if it == nil || it.kind != .Object || len(it.keys) != len(first.keys) {
			return false
		}
		for k, i in it.keys {
			if k != first.keys[i] {
				return false
			}
			e := it.items[i]
			if e != nil && (e.kind == .Array || e.kind == .Object) {
				return false
			}
		}
	}
	cols := len(first.keys)
	w := make([]int, cols, context.temp_allocator)
	for k, i in first.keys {
		w[i] = len(k)
	}
	for it in arr.items {
		for e, i in it.items {
			w[i] = max(w[i], len(json_scalar(e)))
		}
	}
	pad :: proc(sb: ^strings.Builder, depth: int) {
		for _ in 0 ..< depth * 2 {
			strings.write_byte(sb, ' ')
		}
	}
	cell :: proc(sb: ^strings.Builder, s: string, w: int, last: bool) {
		strings.write_string(sb, s)
		if !last {
			for _ in 0 ..< w - len(s) + 2 {
				strings.write_byte(sb, ' ')
			}
		}
	}
	pad(sb, depth)
	for k, i in first.keys {
		cell(sb, k, w[i], i == cols - 1)
	}
	strings.write_byte(sb, '\n')
	for it in arr.items {
		pad(sb, depth)
		for e, i in it.items {
			cell(sb, json_scalar(e), w[i], i == cols - 1)
		}
		strings.write_byte(sb, '\n')
	}
	return true
}

// ---------------------------------------------------------------------------
// Validating a result against its declaration
// ---------------------------------------------------------------------------

// cli_validate_output checks a JSON document against a command's declared
// output fields and returns everything wrong with it. It parses the text
// rather than inspecting the tree, so what is checked is what a caller would
// actually receive.
cli_validate_output :: proc(
	text: string,
	fields: []Field,
	allocator := context.allocator,
) -> (problems: []string) {
	out := make([dynamic]string, allocator)
	v, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil {
		append(&out, fmt.aprintf("stdout is not JSON: %v", err, allocator = allocator))
		return out[:]
	}
	obj, ok := v.(json.Object)
	if !ok {
		append(&out, "the result is not a JSON object")
		return out[:]
	}
	check_fields(&out, obj, fields, "", allocator)
	return out[:]
}

@(private = "file")
kind_matches :: proc(v: json.Value, k: Schema_Kind) -> bool {
	switch k {
	case .Any:
		return true
	case .String:
		_, ok := v.(json.String)
		return ok
	case .Int:
		if _, ok := v.(json.Integer); ok {
			return true
		}
		_, ok := v.(json.Float)
		return ok
	case .Float:
		if _, ok := v.(json.Float); ok {
			return true
		}
		_, ok := v.(json.Integer)
		return ok
	case .Bool:
		_, ok := v.(json.Boolean)
		return ok
	case .Array:
		_, ok := v.(json.Array)
		return ok
	case .Object:
		_, ok := v.(json.Object)
		return ok
	}
	return false
}

@(private = "file")
check_fields :: proc(
	out: ^[dynamic]string,
	obj: json.Object,
	fields: []Field,
	prefix: string,
	allocator: mem.Allocator,
) {
	for f in fields {
		path := prefix == "" ? f.name : fmt.tprintf("%s.%s", prefix, f.name)
		v, present := obj[f.name]
		if !present {
			if !f.opt {
				append(out, fmt.aprintf("%s is declared but missing", path, allocator = allocator))
			}
			continue
		}
		if _, is_null := v.(json.Null); is_null {
			if !f.opt {
				append(out, fmt.aprintf("%s is null", path, allocator = allocator))
			}
			continue
		}
		if !kind_matches(v, f.kind) {
			append(
				out,
				fmt.aprintf(
					"%s is declared %s but is not",
					path,
					schema_kind_name(f.kind),
					allocator = allocator,
				),
			)
			continue
		}
		if f.kind == .Array && len(f.of) > 0 {
			arr := v.(json.Array)
			scalar := len(f.of) == 1 && f.of[0].name == ""
			for e, i in arr {
				if scalar {
					if !kind_matches(e, f.of[0].kind) {
						append(
							out,
							fmt.aprintf(
								"%s[%d] is declared %s but is not",
								path,
								i,
								schema_kind_name(f.of[0].kind),
								allocator = allocator,
							),
						)
					}
					continue
				}
				eo, is_obj := e.(json.Object)
				if !is_obj {
					append(out, fmt.aprintf("%s[%d] is not an object", path, i, allocator = allocator))
					continue
				}
				check_fields(out, eo, f.of, fmt.tprintf("%s[%d]", path, i), allocator)
			}
		}
		if f.kind == .Object && len(f.of) > 0 {
			check_fields(out, v.(json.Object), f.of, path, allocator)
		}
	}
}

// ---------------------------------------------------------------------------
// Help, generated from the declaration and never hand-written
// ---------------------------------------------------------------------------

@(private = "file")
usage_line :: proc(sb: ^strings.Builder, noun: string, cmd: ^Command) {
	strings.write_string(sb, fmt.tprintf("  %s %s", noun, cmd.verb))
	for a in cmd.args {
		if a.variadic {
			strings.write_string(sb, fmt.tprintf(" [%s...]", a.name))
		} else if a.required {
			strings.write_string(sb, fmt.tprintf(" <%s>", a.name))
		} else {
			strings.write_string(sb, fmt.tprintf(" [%s]", a.name))
		}
	}
	for f in cmd.flags {
		open, close := "[", "]"
		if f.required {
			open, close = "", ""
		}
		if f.kind == .Bool {
			strings.write_string(sb, fmt.tprintf(" %s--%s%s", open, f.name, close))
		} else {
			strings.write_string(sb, fmt.tprintf(" %s--%s %s%s", open, f.name, strings.to_upper(f.name, context.temp_allocator), close))
		}
	}
	if cmd.effect == .Destructive {
		strings.write_string(sb, " --yes")
	}
}

BASE_FLAGS_HELP :: `Base flags, accepted by every command:
  --json            structured output on stdout, and nothing else on stdout
  --dry-run         for anything that mutates: print what it would change
  --yes             required by a destructive command, which never prompts
  --identity NAME   narrow the scope; it can never be widened
  --verbose, -v     progress on stderr
  --help, -h        this, generated from the declaration
  --schema          the whole declaration as JSON, which palm schema reads
  --parse-only      validate the command line and exit without running it
  --selftest        the assertions this program ships with`

// cli_help_text is the whole help for a surface, or for one verb.
cli_help_text :: proc(s: ^Surface, verb := "", allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if verb != "" {
		cmd := find_command(s, verb)
		if cmd == nil {
			strings.write_string(&sb, fmt.tprintf("%s: unknown command %q\n", s.noun, verb))
			return strings.to_string(sb)
		}
		strings.write_string(&sb, fmt.tprintf("%s %s — %s\n\nUsage:\n", s.noun, cmd.verb, cmd.summary))
		usage_line(&sb, s.noun, cmd)
		strings.write_string(&sb, "\n")
		if len(cmd.args) > 0 {
			strings.write_string(&sb, "\nArguments:\n")
			for a in cmd.args {
				strings.write_string(
					&sb,
					fmt.tprintf("  %-18s %s (%s)\n", a.name, a.help, val_kind_name(a.kind)),
				)
			}
		}
		if len(cmd.flags) > 0 {
			strings.write_string(&sb, "\nOptions:\n")
			for f in cmd.flags {
				extra := ""
				if f.kind == .Enum {
					extra = fmt.tprintf(" [%s]", strings.join(f.values, "|", context.temp_allocator))
				}
				if f.def != "" {
					extra = fmt.tprintf("%s (default %s)", extra, f.def)
				}
				strings.write_string(&sb, fmt.tprintf("  --%-16s %s%s\n", f.name, f.help, extra))
			}
		}
		strings.write_string(
			&sb,
			fmt.tprintf("\nSide effect: %s — %s\n", effect_name(cmd.effect), effect_meaning(cmd.effect)),
		)
		if len(cmd.out) > 0 {
			strings.write_string(&sb, "\nPrints an object with:\n")
			for f in cmd.out {
				strings.write_string(
					&sb,
					fmt.tprintf("  %-18s %s  %s\n", f.name, schema_kind_name(f.kind), f.help),
				)
			}
		}
		if len(cmd.examples) > 0 {
			strings.write_string(&sb, "\nExamples:\n")
			for e in cmd.examples {
				strings.write_string(&sb, fmt.tprintf("  %s\n", e))
			}
		}
		return strings.to_string(sb)
	}

	strings.write_string(&sb, fmt.tprintf("%s — %s\n\nUsage:\n  %s <command> [options]\n", s.noun, s.summary, s.noun))
	if s.gui {
		strings.write_string(&sb, fmt.tprintf("  %s                      with no command, open the window\n", s.noun))
	}
	strings.write_string(&sb, "\nCommands:\n")
	w := 0
	for cmd in s.commands {
		if !cmd.hidden {
			w = max(w, len(cmd.verb))
		}
	}
	for cmd in s.commands {
		if cmd.hidden {
			continue
		}
		strings.write_string(
			&sb,
			fmt.tprintf("  %-*s  %-52s [%s]\n", w, cmd.verb, cmd.summary, effect_name(cmd.effect)),
		)
	}
	strings.write_string(&sb, "\n")
	strings.write_string(&sb, BASE_FLAGS_HELP)
	strings.write_string(&sb, "\n")
	if s.notes != "" {
		strings.write_string(&sb, fmt.tprintf("\n%s\n", s.notes))
	}
	strings.write_string(&sb, fmt.tprintf("\n`%s help <command>` describes one command.\n", s.noun))
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// The schema
// ---------------------------------------------------------------------------

@(private = "file")
param_json :: proc(p: Param, positional: bool) -> ^Json {
	o := jobj()
	jset_str(o, "name", p.name)
	jset_str(o, "type", val_kind_name(p.kind))
	jset_bool(o, "required", p.required)
	if positional {
		jset_bool(o, "variadic", p.variadic)
	} else if p.short != "" {
		jset_str(o, "short", p.short)
	}
	if len(p.values) > 0 {
		vs := jarr()
		for v in p.values {
			jpush(vs, jstr(v))
		}
		jset(o, "values", vs)
	}
	if p.def != "" {
		jset_str(o, "default", p.def)
	}
	jset_str(o, "help", p.help)
	return o
}

@(private = "file")
fields_json :: proc(fields: []Field) -> ^Json {
	a := jarr()
	for f in fields {
		o := jobj()
		jset_str(o, "name", f.name)
		jset_str(o, "type", schema_kind_name(f.kind))
		jset_bool(o, "optional", f.opt)
		if f.help != "" {
			jset_str(o, "help", f.help)
		}
		if len(f.of) > 0 {
			jset(o, "of", fields_json(f.of))
		}
		jpush(a, o)
	}
	return a
}

// cli_command_json is one command's declaration.
cli_command_json :: proc(noun: string, cmd: Command) -> ^Json {
	o := jobj()
	jset_str(o, "verb", cmd.verb)
	jset_str(o, "summary", cmd.summary)
	jset_str(o, "effect", effect_name(cmd.effect))
	jset_bool(o, "hidden", cmd.hidden)
	args := jarr()
	for a in cmd.args {
		jpush(args, param_json(a, true))
	}
	jset(o, "args", args)
	flags := jarr()
	for f in cmd.flags {
		jpush(flags, param_json(f, false))
	}
	jset(o, "flags", flags)
	out := jobj()
	jset_str(out, "type", "object")
	jset(out, "fields", fields_json(cmd.out))
	jset(o, "output", out)
	ex := jarr()
	for e in cmd.examples {
		jpush(ex, jstr(e))
	}
	jset(o, "examples", ex)
	al := jarr()
	for a in cmd.aliases {
		jpush(al, jstr(a))
	}
	jset(o, "aliases", al)
	usage := strings.builder_make(context.temp_allocator)
	c := cmd
	usage_line(&usage, noun, &c)
	jset_str(o, "usage", strings.trim_space(strings.to_string(usage)))
	return o
}

// cli_schema_json is the whole surface: what `--schema` prints and what
// `palm schema` collects.
cli_schema_json :: proc(s: ^Surface) -> ^Json {
	o := jobj()
	jset_str(o, "noun", s.noun)
	jset_str(o, "summary", s.summary)
	jset_bool(o, "gui", s.gui)
	jset_bool(o, "selftest", s.selftest != nil)
	cmds := jarr()
	for cmd in s.commands {
		jpush(cmds, cli_command_json(s.noun, cmd))
	}
	jset(o, "commands", cmds)
	base := jarr()
	for b in ([?]string{"--json", "--dry-run", "--yes", "--identity", "--verbose", "--help", "--schema", "--parse-only", "--selftest"}) {
		jpush(base, jstr(b))
	}
	jset(o, "base_flags", base)
	codes := jobj()
	for code in CLI_EXIT_CODES {
		jset_str(codes, fmt.tprintf("%d", code), cli_exit_reason(code))
	}
	jset(o, "exit_codes", codes)
	return o
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

// cli is the entry point an application calls from main. `handled` is false
// when there is nothing on the command line for the CLI — no arguments at all,
// or, for a GUI application, a bare path to open — so the caller goes on to
// open its window.
cli :: proc(s: ^Surface) -> (code: int, handled: bool) {
	return cli_args(s, os.args[1:])
}

// cli_args is `cli` with the arguments supplied, which is what makes the
// convention itself testable.
cli_args :: proc(s: ^Surface, argv: []string) -> (code: int, handled: bool) {
	if len(argv) == 0 {
		return 0, false
	}

	// --selftest is looked for anywhere on the line, because every
	// application in this repository already accepted it that way and a
	// convention that breaks forty invocations is not an improvement.
	// `--self-test` is tolerated because `call` has always taken both; `-t`
	// is only the first token, since one letter is too short to claim from
	// every command that might want it.
	for a in argv {
		if a == "--selftest" || a == "--self-test" {
			if s.selftest == nil {
				fmt.eprintfln("%s: no self-test", s.noun)
				return EXIT_USAGE, true
			}
			return s.selftest(), true
		}
	}
	if argv[0] == "-t" && s.selftest != nil {
		return s.selftest(), true
	}
	if argv[0] == "--schema" {
		fmt.println(json_text(cli_schema_json(s), 2, context.temp_allocator))
		return EXIT_OK, true
	}
	head := argv[0]
	if head == "--help" || head == "-h" {
		fmt.print(cli_help_text(s))
		return EXIT_OK, true
	}
	if head == "help" {
		verb := len(argv) > 1 ? argv[1] : ""
		fmt.print(cli_help_text(s, verb))
		return EXIT_OK, true
	}

	// A bare word that is not a verb belongs to the window only where the
	// window takes one: `sheets book.csv` opens the file. Everywhere else an
	// unrecognised token is a usage error. That matters more than it looks —
	// falling through would open a window, and a command that opens a window
	// instead of answering is a command that never returns to its caller.
	if find_command(s, head) == nil {
		inline_alias := false
		if eq := strings.index_byte(head, '='); eq > 0 && find_command(s, head[:eq]) != nil {
			inline_alias = true
		}
		if !inline_alias {
			if s.gui && s.takes_path && !strings.has_prefix(head, "-") {
				return 0, false
			}
			c, bad := cli_bind(s, argv)
			report(&c, bad)
			return bad, true
		}
	}

	parse_only := false
	kept := make([dynamic]string, context.temp_allocator)
	for a in argv {
		if a == "--parse-only" {
			parse_only = true
			continue
		}
		append(&kept, a)
	}

	c, bind_code := cli_bind(s, kept[:])
	if bind_code != EXIT_OK {
		report(&c, bind_code)
		// A refusal is worth a record too: `palm audit` should be able to
		// show that something tried to delete a thing and was turned away,
		// not only the deletions that went through.
		audit_call(&c, bind_code)
		return bind_code, true
	}
	if c.want_help {
		fmt.print(cli_help_text(s, c.cmd.verb))
		return EXIT_OK, true
	}
	if parse_only {
		ok := jobj()
		jset_bool(ok, "ok", true)
		jset_str(ok, "command", fmt.tprintf("%s %s", s.noun, c.cmd.verb))
		jset_str(ok, "effect", effect_name(c.cmd.effect))
		args := jobj()
		for p in c.cmd.args {
			if v, got := c.vals[p.name]; got {
				jset_str(args, p.name, v)
			}
		}
		jset(ok, "args", args)
		c.out = ok
		c.json = true
		emit(&c, ok)
		return EXIT_OK, true
	}

	if c.cmd.run == nil {
		return report(&c, cli_fail(&c, EXIT_UNAVAILABLE, "declared but not implemented")), true
	}

	guard_arm(c.cmd.effect == .Intent)
	code = c.cmd.run(&c)
	guard_disarm()

	if code == EXIT_OK {
		if c.dry_run && c.cmd.effect != .Read {
			jset_bool(c.out, "dry_run", true)
		}
		emit(&c, c.out)
	} else {
		report(&c, code)
	}
	audit_call(&c, code)
	return code, true
}

// report prints a refusal. Under --json it is a document on stdout, because a
// refusal is a result an agent parses; otherwise it is a line on stderr.
@(private = "file")
report :: proc(c: ^Call, code: int) -> int {
	if c.err == nil {
		cli_fail(c, code)
	}
	if c.json {
		fmt.println(json_text(c.err, 2, context.temp_allocator))
	} else {
		reason, _ := jget(c.err, "error")
		detail, has_detail := jget(c.err, "detail")
		if has_detail {
			fmt.eprintfln("%s: %s — %s", c.surface.noun, json_scalar(reason), json_scalar(detail))
		} else {
			fmt.eprintfln("%s: %s", c.surface.noun, json_scalar(reason))
		}
		if code == EXIT_USAGE && c.cmd != nil {
			fmt.eprint(cli_help_text(c.surface, c.cmd.verb))
		} else if code == EXIT_USAGE {
			fmt.eprint(cli_help_text(c.surface))
		}
	}
	return code
}
