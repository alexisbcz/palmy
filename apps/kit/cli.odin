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
import "core:mem/virtual"
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

	// secret says the value must never be repeated back: the audit log, the
	// --json result, a refusal, --help and the schema's examples all show
	// `<redacted>` where it was. `cli_str` still returns the real value.
	secret:   bool,
	// repeat says a flag may be given more than once. `cli_str` is the last
	// value, as for any flag; `cli_all` is every value, in order.
	repeat:   bool,
	// unless makes the parameter required unless one of these other
	// parameters (flag or argument names) was given: `--password` unless
	// `--password-file`. A refusal names both.
	unless:   []string,
	// free marks a positional as free text: a word starting with '-' that
	// names no flag is taken as its value (`slides add-text "- One"`
	// already is, having a space; `-draft` needs this). Words with a space
	// and negative numbers are always values, free or not.
	free:     bool,
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
	// keyed declares an Object whose keys are data — package names, dates,
	// account ids — rather than a fixed set. Every value has the shape `of`
	// describes: a single unnamed `of` is a scalar, anything else an object
	// with those fields.
	keyed: bool,
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
	// on_refuse is asked for the specific reason when the kit refuses this
	// destructive command for want of --yes — `pkg remove` names the
	// dependants. It runs with the guard armed as for an intent command, so
	// it can execute nothing, and it can only add to the refusal: it may set
	// fields (`cli_err_field`), replace the detail (`cli_err_detail`) or
	// replace `c.err` outright, and the kit then puts the documented token,
	// code and `pass` back. The exit code is 4 whatever it does.
	on_refuse: proc(c: ^Call),
	// private_args says this command's positional arguments are content
	// that must not be recorded — `clipboard add <text>` — so the audit log
	// and the --parse-only echo show <redacted> for each of them. The
	// command's own result is the command's business; a `secret` argument
	// is also scrubbed from that.
	private_args: bool,
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
	// flags every command of this surface takes, beside the base flags:
	// `mail --data-dir PATH`. They are listed in each command's schema and
	// help, so they are discoverable rather than stripped out of argv.
	flags:    []Param,
	// takes_word narrows takes_path: when set, a bare word that is not a verb
	// opens the window only if this says so, and is otherwise a usage error.
	// `cli_word_is_path` (exists on disk, or is a URI) is the usual answer.
	// Unset, a takes_path surface lets every bare word through, as it always
	// has — `settings network` names a page, not a file.
	takes_word: proc(word: string) -> bool,
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

	// every value of every flag, in order, for `cli_all` (a `repeat` flag)
	multi:    map[string][dynamic]string,
	// partial says `out` is worth printing although the command failed:
	// the refusal carries it as `partial`. Set it with `cli_partial`.
	partial:  bool,
	// the values of this call's secret parameters, scrubbed from everything
	// the kit prints or records
	secrets:  []string,
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

// cli_all is every value a flag was given, in order: `--profile a --profile
// b` is {"a", "b"}. A flag given once is one value; one never given is its
// declared default, if it has one, and nothing otherwise. Meant for a
// `repeat` flag, and correct for any.
cli_all :: proc(c: ^Call, name: string) -> []string {
	if vs, ok := c.multi[name]; ok && len(vs) > 0 {
		return vs[:]
	}
	if v, ok := c.vals[name]; ok && v != "" && !c.seen[name] {
		out := make([]string, 1, cli_mem())
		out[0] = v
		return out
	}
	return nil
}

// cli_partial says the command's `out` is worth having although it failed:
// the refusal then carries it as `partial` (under --json), or it is printed
// on stdout before the refusal (without). A sync that fetched three folders
// of five says which three.
cli_partial :: proc(c: ^Call) {
	c.partial = true
}

// cli_note writes progress or a warning. It goes to stderr, always, so a
// pipeline reading stdout under --json never sees it. A secret parameter's
// value is scrubbed from it like from everything else the kit prints.
cli_note :: proc(c: ^Call, format: string, args: ..any) {
	line := fmt.tprintf(format, ..args)
	if c != nil {
		line = scrub_text(line, c.secrets)
	}
	fmt.eprintln(line)
}

// cli_trace is cli_note, but only under --verbose.
cli_trace :: proc(c: ^Call, format: string, args: ..any) {
	if c != nil && c.verbose {
		cli_note(c, format, ..args)
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
// The value may be a string, an int, a bool, a list of strings, or any
// `^Json` the kit's builders made — a refusal is data, not only text.
cli_err_field :: proc {
	cli_err_field_str,
	cli_err_field_int,
	cli_err_field_bool,
	cli_err_field_strs,
	cli_err_field_json,
}

cli_err_field_str :: proc(c: ^Call, key, value: string) {
	cli_err_field_json(c, key, jstr(value))
}

cli_err_field_int :: proc(c: ^Call, key: string, value: int) {
	cli_err_field_json(c, key, jint(value))
}

cli_err_field_bool :: proc(c: ^Call, key: string, value: bool) {
	cli_err_field_json(c, key, jbool(value))
}

cli_err_field_strs :: proc(c: ^Call, key: string, values: []string) {
	a := jarr()
	for v in values {
		jpush(a, jstr(v))
	}
	cli_err_field_json(c, key, a)
}

cli_err_field_json :: proc(c: ^Call, key: string, value: ^Json) {
	if c.err == nil {
		c.err = jobj()
	}
	jset(c.err, key, value)
}

// cli_err_detail replaces the refusal's `detail`, the sentence for a person.
cli_err_detail :: proc(c: ^Call, detail: string) {
	cli_err_field_str(c, "detail", detail)
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
//   - the camera and the microphone are never opened;
//   - nothing asks for root (sudo needs a password a command cannot have),
//     and the package manager and the snapshot tool are read-only: `pkg`'s
//     planner is the one door through which they change the machine, and it
//     execs its plan itself, after --yes, rather than through these helpers.
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
	case "sudo", "doas", "pkexec", "run0", "su":
		return "nothing run from a command may ask for root; a person runs that line"
	case "pacman", "yay", "paru":
		if why := pacman_forbidden(exe, argv); why != "" {
			return why
		}
	case "snapper":
		if why := snapper_forbidden(argv); why != "" {
			return why
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

// pacman_forbidden lets the read-only operations through — -Q, -T, -F
// without a refresh, and -S used only to look (-Si, -Ss, -Sl, -Sg, -Sp) —
// and refuses everything that changes the machine: -S that installs,
// refreshes or cleans, -R, -U, -D, and yay or paru with no operation, which
// is their interactive search-and-install.
@(private = "file")
pacman_forbidden :: proc(exe: string, argv: []string) -> string {
	op: u8 = 0
	mods := make(map[u8]bool, context.temp_allocator)
	for a in argv[1:] {
		if a == "--" {
			break
		}
		if strings.has_prefix(a, "--") {
			long := a[2:]
			if eq := strings.index_byte(long, '='); eq >= 0 {
				long = long[:eq]
			}
			switch long {
			case "query":
				op = 'Q'
			case "sync":
				op = 'S'
			case "remove":
				op = 'R'
			case "upgrade":
				op = 'U'
			case "database":
				op = 'D'
			case "files":
				op = 'F'
			case "deptest":
				op = 'T'
			case "getpkgbuild":
				op = 'G'
			case "show":
				op = 'P'
			case "refresh":
				mods['y'] = true
			case "sysupgrade":
				mods['u'] = true
			case "clean":
				mods['c'] = true
			case "downloadonly":
				mods['w'] = true
			case "info":
				mods['i'] = true
			case "search":
				mods['s'] = true
			case "list":
				mods['l'] = true
			case "groups":
				mods['g'] = true
			case "print":
				mods['p'] = true
			}
			continue
		}
		if strings.has_prefix(a, "-") && len(a) > 1 {
			for ch in transmute([]u8)a[1:] {
				if ch >= 'A' && ch <= 'Z' {
					op = ch
				} else {
					mods[ch] = true
				}
			}
		}
	}
	changes := "the package manager is read-only from a command; pkg plans the change and a person runs it"
	switch op {
	case 'Q', 'T', 'P', 'G':
		return ""
	case 'F':
		if mods['y'] {
			return changes
		}
		return ""
	case 'S':
		if mods['y'] || mods['u'] || mods['c'] || mods['w'] {
			return changes
		}
		if mods['i'] || mods['s'] || mods['l'] || mods['g'] || mods['p'] {
			return ""
		}
		return changes
	case 0:
		if exe == "pacman" {
			return "" // pacman with no operation only prints its usage
		}
		return changes // `yay` alone is -Syu; `yay word` searches and installs
	}
	return changes
}

// snapper_forbidden lets the reading subcommands through and refuses the
// ones that create, delete or roll back.
@(private = "file")
snapper_forbidden :: proc(argv: []string) -> string {
	for i := 1; i < len(argv); i += 1 {
		a := argv[i]
		if strings.has_prefix(a, "-") {
			// The global options that take a value as the next word.
			switch a {
			case "-c", "--config", "-r", "--root", "--machine-readable", "--csvout-separator":
				i += 1
			}
			continue
		}
		switch a {
		case "list", "ls", "list-configs", "get-config", "status", "diff", "xadiff", "help":
			return ""
		}
		return fmt.tprintf("snapper %s changes the machine; pkg plans it and a person runs it", a)
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
	line := scrub_text(strings.join(argv, " ", context.temp_allocator), g_secrets)
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
	// Compact, one record per line. The keys and tokens are the ones --json
	// prints; the spacing is not, deliberately: applications' self-tests grep
	// this file for `"verb":"purge"`, and a log format is a contract.
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
	jset_str(rec, "command", scrub_text(command, g_secrets), context.temp_allocator)
	if detail != "" {
		jset_str(rec, "detail", scrub_text(detail, g_secrets), context.temp_allocator)
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
	if code != EXIT_OK {
		// The same token the --json refusal carries, so a reader of the log
		// branches on the same word a caller of the command does.
		jset_str(rec, "error", cli_exit_reason(code), context.temp_allocator)
	}
	av := jarr(context.temp_allocator)
	for a in cli_redact_argv(c.surface, c.cmd, c.argv, c.secrets, context.temp_allocator) {
		jpush(av, jstr(a, context.temp_allocator))
	}
	jset(rec, "argv", av, context.temp_allocator)
	audit_append(rec)
}

// ---------------------------------------------------------------------------
// Secrets
//
// A parameter declared `secret` is never repeated back. The kit knows the
// values a call was given and scrubs them out of everything it prints or
// records — the audit log, the --json result and refusal, a guard refusal,
// cli_note — and the declaration's own examples are redacted wherever the
// kit shows them (--help, --schema). Removing the value at the source is the
// application's job (do not copy it into `out`); this is the net under that.
// ---------------------------------------------------------------------------

CLI_REDACTED :: "<redacted>"

// the secrets of the call in progress, for the paths that have no Call in
// hand (the guard, an intent record)
@(private = "file")
g_secrets: []string

// cli_is_secret reports whether `name` is a secret parameter of `cmd` or a
// secret surface-wide flag. With no command, any command's secret counts:
// a line that failed to bind is redacted by every name it could have meant.
cli_is_secret :: proc(s: ^Surface, cmd: ^Command, name: string) -> bool {
	check :: proc(ps: []Param, name: string) -> bool {
		for p in ps {
			if p.secret && (p.name == name || (p.short != "" && p.short == name)) {
				return true
			}
		}
		return false
	}
	if s != nil && check(s.flags, name) {
		return true
	}
	if cmd != nil {
		return check(cmd.flags, name) || check(cmd.args, name)
	}
	if s != nil {
		for &c in s.commands {
			if check(c.flags, name) {
				return true
			}
		}
	}
	return false
}

// cli_redact_argv is argv with every secret value replaced by <redacted>:
// the word after a secret flag, the part after `=` in `--secret=value`, any
// word that is exactly a known secret value (a secret positional), and —
// when the command declares `private_args` — every positional argument.
cli_redact_argv :: proc(
	s: ^Surface,
	cmd: ^Command,
	argv: []string,
	secrets: []string = nil,
	allocator := context.allocator,
) -> []string {
	out := make([]string, len(argv), allocator)
	private := cmd != nil && cmd.private_args
	next_secret := false
	next_value := false
	no_more_flags := false
	for a, i in argv {
		out[i] = a
		if next_secret || next_value {
			if next_secret {
				out[i] = CLI_REDACTED
			}
			next_secret, next_value = false, false
			continue
		}
		for v in secrets {
			if v != "" && a == v {
				out[i] = CLI_REDACTED
			}
		}
		positional := i > 0 && (no_more_flags || !strings.has_prefix(a, "-") || a == "-" || strings.contains_any(a, " \t"))
		if positional {
			if private {
				out[i] = CLI_REDACTED
			}
			continue
		}
		if i == 0 {
			continue
		}
		if a == "--" {
			no_more_flags = true
			continue
		}
		bare := strings.trim_left(a, "-")
		if eq := strings.index_byte(bare, '='); eq >= 0 {
			if cli_is_secret(s, cmd, bare[:eq]) {
				out[i] = strings.concatenate({a[:len(a) - len(bare) + eq + 1], CLI_REDACTED}, allocator)
			}
			continue
		}
		if cli_is_secret(s, cmd, bare) {
			next_secret = true
			continue
		}
		// A flag that takes a value: its value is not a positional.
		if cmd != nil {
			if p := find_flag(s, cmd, bare); p != nil {
				next_value = p.kind != .Bool
				continue
			}
			if strings.has_prefix(bare, "no-") && find_flag(s, cmd, bare[3:]) != nil {
				continue
			}
		}
		if bare == "identity" {
			next_value = true
			continue
		}
		// An unknown dash word in a free slot is a positional too; redact it
		// when in doubt.
		if private && cmd != nil && !is_base_flag(bare) {
			out[i] = CLI_REDACTED
		}
	}
	return out
}

@(private = "file")
is_base_flag :: proc(bare: string) -> bool {
	switch bare {
	case "json", "dry-run", "dryrun", "yes", "verbose", "help", "identity", "y", "v", "h", "parse-only", "selftest", "self-test", "schema":
		return true
	}
	return false
}

// scrub_text replaces every occurrence of a secret value in `text`. A value
// shorter than three bytes is replaced only where it is the whole text, since
// scrubbing every "a" out of a result would destroy it and protect nothing.
@(private)
scrub_text :: proc(text: string, secrets: []string, allocator := context.temp_allocator) -> string {
	out := text
	for v in secrets {
		if v == "" {
			continue
		}
		if out == v {
			out = CLI_REDACTED
			continue
		}
		if len(v) >= 3 && strings.contains(out, v) {
			out, _ = strings.replace_all(out, v, CLI_REDACTED, allocator)
		}
	}
	return out
}

// scrub_json does scrub_text to every string (and key) in a tree, in place.
@(private = "file")
scrub_json :: proc(v: ^Json, secrets: []string) {
	if v == nil || len(secrets) == 0 {
		return
	}
	switch v.kind {
	case .String:
		if t := scrub_text(v.s, secrets); t != v.s {
			v.s = strings.clone(t)
		}
	case .Array, .Object:
		for it in v.items {
			scrub_json(it, secrets)
		}
		for &k in v.keys {
			if t := scrub_text(k, secrets); t != k {
				k = strings.clone(t)
			}
		}
	case .Null, .Bool, .Int, .Float:
	}
}

// cli_redact_example is an example command line with each secret flag's value
// replaced, as --help and --schema show it. The placeholder is quoted so the
// redacted example still parses as one word.
cli_redact_example :: proc(s: ^Surface, cmd: ^Command, line: string, allocator := context.allocator) -> string {
	words := cli_split_example(line, context.temp_allocator)
	any_secret := false
	red := cli_redact_argv(s, cmd, words, nil, context.temp_allocator)
	for w, i in red {
		if w != words[i] {
			any_secret = true
		}
	}
	if !any_secret {
		return strings.clone(line, allocator)
	}
	sb := strings.builder_make(allocator)
	for w, i in red {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		needs_quote := strings.contains_any(w, " \t'\"<>|&;$`()*?")
		if needs_quote {
			strings.write_byte(&sb, '\'')
			strings.write_string(&sb, w)
			strings.write_byte(&sb, '\'')
		} else {
			strings.write_string(&sb, w)
		}
	}
	return strings.to_string(sb)
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

// cli_scope_require refuses unless the caller is already inside the scope of
// one of `owners`. A secret, or anything else belonging to one identity, goes
// through this; a thing shared between identities (a calendar two people
// edit) names each of them. There is no argument that widens the scope: the
// only outcomes are the caller's own identity and a refusal. With one owner
// the refusal's `requested` is that name, as it always was; with several it
// is the list.
cli_scope_require :: proc(c: ^Call, owners: ..string) -> (ok: bool) {
	if c.identity == "" {
		return true
	}
	for o in owners {
		if c.identity == o {
			return true
		}
	}
	if len(owners) == 1 {
		cli_fail(c, EXIT_OUT_OF_SCOPE, fmt.tprintf("this belongs to %q", owners[0]))
		cli_err_field(c, "identity", c.identity)
		cli_err_field(c, "requested", owners[0])
		return false
	}
	cli_fail(
		c,
		EXIT_OUT_OF_SCOPE,
		fmt.tprintf("this belongs to %s", strings.join(owners, ", ", context.temp_allocator)),
	)
	cli_err_field(c, "identity", c.identity)
	cli_err_field(c, "requested", owners)
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
find_flag :: proc(s: ^Surface, cmd: ^Command, name: string) -> ^Param {
	for &f in cmd.flags {
		if f.name == name || (f.short != "" && f.short == name) {
			return &f
		}
	}
	if s != nil {
		for &f in s.flags {
			if f.name == name || (f.short != "" && f.short == name) {
				return &f
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// The kit's own memory
//
// What the kit parses lives here, not in the temp allocator: a command is
// free to `free_all(context.temp_allocator)` — a long loop has to — and the
// kit still reads the argv afterwards, to print the result and write the
// audit record. That used to crash after printing (exit 133). The arena only
// grows; a process runs one command, and a self-test that runs hundreds in
// process holds a few kilobytes each.
// ---------------------------------------------------------------------------

@(private = "file")
g_cli_arena: virtual.Arena
@(private = "file")
g_cli_arena_ok: bool

// cli_mem is the allocator the kit's parse lives in.
cli_mem :: proc() -> mem.Allocator {
	if !g_cli_arena_ok {
		if virtual.arena_init_growing(&g_cli_arena) == nil {
			g_cli_arena_ok = true
		} else {
			return context.allocator
		}
	}
	return virtual.arena_allocator(&g_cli_arena)
}

// clone_argv copies the words and the slice holding them, so an argv built in
// the caller's temp allocator (one with secrets taken out, or a prefix
// stripped) survives whatever the command does with that allocator.
@(private = "file")
clone_argv :: proc(argv: []string) -> []string {
	a := cli_mem()
	out := make([]string, len(argv), a)
	for w, i in argv {
		out[i] = strings.clone(w, a)
	}
	return out
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
cli_bind :: proc(s: ^Surface, argv_in: []string) -> (c: Call, code: int) {
	own := cli_mem()
	argv := clone_argv(argv_in)
	c.surface = s
	c.argv = argv
	c.vals = make(map[string]string, own)
	c.seen = make(map[string]bool, own)
	c.multi = make(map[string][dynamic]string, own)
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
	defaults :: proc(c: ^Call, ps: []Param) {
		for p in ps {
			if p.kind == .Bool {
				c.vals[p.name] = p.def == "true" ? "true" : "false"
			} else if p.def != "" {
				c.vals[p.name] = p.def
			}
		}
	}
	defaults(&c, s.flags)
	defaults(&c, c.cmd.flags)

	// A secret value is known as soon as it is read, so a refusal later in
	// this same line is already scrubbed of it.
	remember :: proc(c: ^Call, p: ^Param, v: string) {
		if p.secret && v != "" {
			list := make([dynamic]string, 0, len(c.secrets) + 1, cli_mem())
			append(&list, ..c.secrets)
			append(&list, v)
			c.secrets = list[:]
		}
	}
	// checked is value_ok, with a secret's refusal worded without its value.
	checked :: proc(p: ^Param, v: string) -> string {
		why := value_ok(p, v)
		if why != "" && p.secret {
			return fmt.tprintf("%s is not a valid %s", p.name, val_kind_name(p.kind))
		}
		return why
	}

	pos := make([dynamic]string, own)
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

		// The base flags, which every command accepts — unless the command
		// declares a flag of exactly that name or short alias, which wins:
		// `sheets ... --h 12` is a height. The one-letter aliases are only
		// ever single-dash (`-y`, `-v`, `-h`): `--y` used to read as `--yes`,
		// and a typo should not be able to confirm a destructive command.
		base := ""
		if find_flag(s, c.cmd, bare) == nil {
			switch bare {
			case "json", "dry-run", "dryrun", "yes", "verbose", "help", "identity":
				base = bare
			case "y", "v", "h":
				if name == fmt.tprintf("-%s", bare) {
					base = bare
				}
			}
		}
		switch base {
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
		p := find_flag(s, c.cmd, lookup)
		if p == nil && neg {
			p = find_flag(s, c.cmd, bare)
			neg = false
			lookup = bare
		}
		if p == nil {
			// Not a flag at all, but a value that happens to start with a
			// dash: one with a space in it ("- One", which no flag has), a
			// negative number, or anything in a slot declared `free`.
			if dash_value(&c, len(pos), a) {
				append(&pos, a)
				continue
			}
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
		remember(&c, p, val)
		if why := checked(p, val); why != "" {
			return c, cli_fail(&c, EXIT_USAGE, why)
		}
		c.vals[p.name] = val
		c.seen[p.name] = true
		list, have := c.multi[p.name]
		if !have {
			list = make([dynamic]string, own)
		}
		append(&list, val)
		c.multi[p.name] = list
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
				tail := make([]string, len(pos) - at, own)
				copy(tail, pos[at:])
				c.rest = tail
				c.vals[p.name] = pos[at]
				c.seen[p.name] = true
				for t in tail {
					remember(&c, &c.cmd.args[pi], t)
				}
				at = len(pos)
			} else {
				c.rest = nil
			}
			continue
		}
		if at < len(pos) {
			remember(&c, &c.cmd.args[pi], pos[at])
			if why := checked(&c.cmd.args[pi], pos[at]); why != "" {
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

	// Required things. `unless` relaxes either kind: the parameter is needed
	// only when none of the named alternatives was given.
	excused :: proc(c: ^Call, p: Param) -> bool {
		for alt in p.unless {
			if c.seen[alt] || (c.vals[alt] != "" && c.vals[alt] != "false") {
				return true
			}
		}
		return false
	}
	needed :: proc(p: Param) -> bool {
		return p.required || len(p.unless) > 0
	}
	missing :: proc(c: ^Call, p: Param, spelled: string) -> int {
		code: int
		if len(p.unless) > 0 {
			alts := make([dynamic]string, context.temp_allocator)
			for a in p.unless {
				append(&alts, fmt.tprintf("--%s", a))
			}
			code = cli_fail(
				c,
				EXIT_USAGE,
				fmt.tprintf(
					"%s %s needs %s or %s",
					c.surface.noun,
					c.cmd.verb,
					spelled,
					strings.join(alts[:], " or ", context.temp_allocator),
				),
			)
			cli_err_field(c, "missing", p.name)
			cli_err_field(c, "unless", p.unless)
			return code
		}
		code = cli_fail(c, EXIT_USAGE, fmt.tprintf("%s %s needs %s", c.surface.noun, c.cmd.verb, spelled))
		cli_err_field(c, "missing", p.name)
		return code
	}
	for p in c.cmd.args {
		if needed(p) && cli_str(&c, p.name) == "" && !excused(&c, p) {
			return c, missing(&c, p, fmt.tprintf("<%s>", p.name))
		}
	}
	for ps in ([2][]Param{c.cmd.flags, s.flags}) {
		for p in ps {
			if needed(p) && cli_str(&c, p.name) == "" && !excused(&c, p) {
				return c, missing(&c, p, fmt.tprintf("--%s", p.name))
			}
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

// dash_value says whether a word starting with '-' that names no flag is the
// value of the positional slot `slot` instead.
@(private = "file")
dash_value :: proc(c: ^Call, slot: int, word: string) -> bool {
	if strings.contains_any(word, " \t") {
		return true
	}
	p: ^Param
	if slot < len(c.cmd.args) {
		p = &c.cmd.args[slot]
	} else if n := len(c.cmd.args); n > 0 && c.cmd.args[n - 1].variadic {
		p = &c.cmd.args[n - 1]
	}
	if p == nil {
		return false
	}
	if p.free {
		return true
	}
	if _, ok := strconv.parse_f64(word); ok && len(word) > 1 {
		return true
	}
	return false
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

// While set, what the kit would print on stdout is appended here instead:
// cli_capture's doing, so a self-test can run a command in process and read
// the document it printed.
@(private = "file")
g_stdout: ^strings.Builder

@(private = "file")
say :: proc(text: string) {
	if g_stdout != nil {
		strings.write_string(g_stdout, text)
		return
	}
	fmt.print(text)
}

@(private = "file")
emit :: proc(c: ^Call, v: ^Json) {
	scrub_json(v, c.secrets)
	if c.json {
		say(json_text(v, 2, context.temp_allocator))
		say("\n")
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	text_render(&sb, v, 0)
	s := strings.to_string(sb)
	if strings.trim_space(s) != "" {
		say(s)
		if !strings.has_suffix(s, "\n") {
			say("\n")
		}
	}
}

// cli_display_width is how many terminal columns `s` takes: one per
// character, not per byte — `é` and `€` are one column though two and three
// bytes — none for a combining mark, and two for a wide East Asian character
// or an emoji. It is what the text tables pad by.
cli_display_width :: proc(s: string) -> int {
	w := 0
	for r in s {
		w += rune_width(r)
	}
	return w
}

@(private = "file")
rune_width :: proc(r: rune) -> int {
	switch {
	case r == 0:
		return 0
	case r < 0x20 || (r >= 0x7f && r < 0xa0):
		return 0
	case r == 0x200b || r == 0x200c || r == 0x200d || r == 0xfeff:
		return 0
	case (r >= 0x0300 && r <= 0x036f) ||
	     (r >= 0x0483 && r <= 0x0489) ||
	     (r >= 0x0591 && r <= 0x05bd) ||
	     (r >= 0x0610 && r <= 0x061a) ||
	     (r >= 0x064b && r <= 0x065f) ||
	     (r >= 0x1ab0 && r <= 0x1aff) ||
	     (r >= 0x1dc0 && r <= 0x1dff) ||
	     (r >= 0x20d0 && r <= 0x20ff) ||
	     (r >= 0xfe00 && r <= 0xfe0f) ||
	     (r >= 0xfe20 && r <= 0xfe2f):
		return 0
	case (r >= 0x1100 && r <= 0x115f) ||
	     (r >= 0x2e80 && r <= 0x303e) ||
	     (r >= 0x3041 && r <= 0x33ff) ||
	     (r >= 0x3400 && r <= 0x4dbf) ||
	     (r >= 0x4e00 && r <= 0x9fff) ||
	     (r >= 0xa000 && r <= 0xa4cf) ||
	     (r >= 0xac00 && r <= 0xd7a3) ||
	     (r >= 0xf900 && r <= 0xfaff) ||
	     (r >= 0xfe30 && r <= 0xfe4f) ||
	     (r >= 0xff00 && r <= 0xff60) ||
	     (r >= 0xffe0 && r <= 0xffe6) ||
	     (r >= 0x1f300 && r <= 0x1f64f) ||
	     (r >= 0x1f900 && r <= 0x1f9ff) ||
	     (r >= 0x20000 && r <= 0x3fffd):
		return 2
	}
	return 1
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
			w = max(w, cli_display_width(k))
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
			for _ in 0 ..< w - cli_display_width(k) + 1 {
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
	if first == nil || first.kind != .Object || len(first.keys) == 0 || len(first.keys) > 16 {
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
		w[i] = cli_display_width(k)
	}
	for it in arr.items {
		for e, i in it.items {
			w[i] = max(w[i], cli_display_width(json_scalar(e)))
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
			for _ in 0 ..< w - cli_display_width(s) + 2 {
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
		if f.kind == .Object && f.keyed && len(f.of) > 0 {
			// Keys are data; every value has the declared shape.
			scalar := len(f.of) == 1 && f.of[0].name == ""
			for k, e in v.(json.Object) {
				at := fmt.tprintf("%s[%q]", path, k)
				if scalar {
					if !kind_matches(e, f.of[0].kind) {
						append(
							out,
							fmt.aprintf("%s is declared %s but is not", at, schema_kind_name(f.of[0].kind), allocator = allocator),
						)
					}
					continue
				}
				eo, is_obj := e.(json.Object)
				if !is_obj {
					append(out, fmt.aprintf("%s is not an object", at, allocator = allocator))
					continue
				}
				check_fields(out, eo, f.of, at, allocator)
			}
		} else if f.kind == .Object && len(f.of) > 0 {
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
		more := f.repeat ? "..." : ""
		if f.kind == .Bool {
			strings.write_string(sb, fmt.tprintf(" %s--%s%s%s", open, f.name, close, more))
		} else {
			strings.write_string(sb, fmt.tprintf(" %s--%s %s%s%s", open, f.name, strings.to_upper(f.name, context.temp_allocator), close, more))
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
		if len(cmd.flags) > 0 || len(s.flags) > 0 {
			strings.write_string(&sb, "\nOptions:\n")
			option :: proc(sb: ^strings.Builder, f: Param, common: bool) {
				extra := ""
				if f.kind == .Enum {
					extra = fmt.tprintf(" [%s]", strings.join(f.values, "|", context.temp_allocator))
				}
				if f.def != "" && !f.secret {
					extra = fmt.tprintf("%s (default %s)", extra, f.def)
				}
				if len(f.unless) > 0 {
					alts := make([dynamic]string, context.temp_allocator)
					for a in f.unless {
						append(&alts, fmt.tprintf("--%s", a))
					}
					extra = fmt.tprintf("%s (required unless %s)", extra, strings.join(alts[:], " or ", context.temp_allocator))
				}
				if f.repeat {
					extra = fmt.tprintf("%s (may repeat)", extra)
				}
				if f.secret {
					extra = fmt.tprintf("%s (secret: never echoed or logged)", extra)
				}
				if common {
					extra = fmt.tprintf("%s (every command)", extra)
				}
				strings.write_string(sb, fmt.tprintf("  --%-16s %s%s\n", f.name, f.help, extra))
			}
			for f in cmd.flags {
				option(&sb, f, false)
			}
			for f in s.flags {
				option(&sb, f, true)
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
				strings.write_string(&sb, fmt.tprintf("  %s\n", cli_redact_example(s, cmd, e, context.temp_allocator)))
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
	if p.def != "" && !p.secret {
		jset_str(o, "default", p.def)
	}
	jset_str(o, "help", p.help)
	// Only where set, so a declaration that uses none of these prints the
	// same schema it always did.
	if p.secret {
		jset_bool(o, "secret", true)
	}
	if p.repeat {
		jset_bool(o, "repeat", true)
	}
	if len(p.unless) > 0 {
		u := jarr()
		for n in p.unless {
			jpush(u, jstr(n))
		}
		jset(o, "required_unless", u)
	}
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
		if f.keyed {
			jset_bool(o, "keyed", true)
		}
		jpush(a, o)
	}
	return a
}

// cli_command_json is one command's declaration.
cli_command_json :: proc(noun: string, cmd: Command) -> ^Json {
	s := Surface {
		noun = noun,
	}
	return cli_command_json_of(&s, cmd)
}

// cli_command_json_of is one command's declaration as its surface publishes
// it: with the surface-wide flags among its own, and its examples redacted.
cli_command_json_of :: proc(s: ^Surface, cmd: Command) -> ^Json {
	noun := s.noun
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
	for f in s.flags {
		pj := param_json(f, false)
		jset_bool(pj, "common", true)
		jpush(flags, pj)
	}
	jset(o, "flags", flags)
	out := jobj()
	jset_str(out, "type", "object")
	jset(out, "fields", fields_json(cmd.out))
	jset(o, "output", out)
	ex := jarr()
	c0 := cmd
	for e in cmd.examples {
		jpush(ex, jstr(cli_redact_example(s, &c0, e, context.temp_allocator)))
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
		jpush(cmds, cli_command_json_of(s, cmd))
	}
	jset(o, "commands", cmds)
	if len(s.flags) > 0 {
		common := jarr()
		for f in s.flags {
			jpush(common, param_json(f, false))
		}
		jset(o, "flags", common)
	}
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
		say(json_text(cli_schema_json(s), 2, context.temp_allocator))
		say("\n")
		return EXIT_OK, true
	}
	head := argv[0]
	if head == "--help" || head == "-h" {
		say(cli_help_text(s))
		return EXIT_OK, true
	}
	if head == "help" {
		verb := len(argv) > 1 ? argv[1] : ""
		say(cli_help_text(s, verb))
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
				if s.takes_word == nil || s.takes_word(head) {
					return 0, false
				}
				c, _ := cli_bind(s, argv)
				code = cli_fail(&c, EXIT_USAGE, fmt.tprintf("%q is neither a command nor a file", head))
				cli_err_field(&c, "given", head)
				report(&c, code)
				return code, true
			}
			c, bad := cli_bind(s, argv)
			report(&c, bad)
			return bad, true
		}
	}

	parse_only := false
	kept := make([dynamic]string, cli_mem())
	for a in argv {
		if a == "--parse-only" {
			parse_only = true
			continue
		}
		append(&kept, a)
	}

	c, bind_code := cli_bind(s, kept[:])
	g_secrets = c.secrets
	defer g_secrets = nil
	if bind_code == EXIT_NEEDS_YES && !parse_only && c.cmd != nil && c.cmd.on_refuse != nil {
		// The application's own reason, asked for with nothing able to run:
		// the guard is armed as for an intent command while it answers.
		guard_arm(true)
		c.cmd.on_refuse(&c)
		guard_disarm()
		if c.err == nil {
			c.err = jobj()
		}
		jset_str(c.err, "error", ERR_NEEDS_YES)
		jset_int(c.err, "code", EXIT_NEEDS_YES)
		if _, has := jget(c.err, "command"); !has {
			jset_str(c.err, "command", fmt.tprintf("%s %s", s.noun, c.cmd.verb))
		}
		if _, has := jget(c.err, "pass"); !has {
			jset_str(c.err, "pass", "--yes")
		}
	}
	if bind_code != EXIT_OK {
		report(&c, bind_code)
		// A refusal is worth a record too: `palm audit` should be able to
		// show that something tried to delete a thing and was turned away,
		// not only the deletions that went through.
		audit_call(&c, bind_code)
		return bind_code, true
	}
	if c.want_help {
		say(cli_help_text(s, c.cmd.verb))
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
				jset_str(args, p.name, p.secret || c.cmd.private_args ? CLI_REDACTED : v)
			}
		}
		jset(ok, "args", args)
		flags := jobj()
		echo :: proc(c: ^Call, flags: ^Json, ps: []Param) {
			for p in ps {
				if !c.seen[p.name] {
					continue
				}
				if p.secret {
					jset_str(flags, p.name, CLI_REDACTED)
				} else if p.repeat {
					all := jarr()
					for v in cli_all(c, p.name) {
						jpush(all, jstr(v))
					}
					jset(flags, p.name, all)
				} else {
					jset_str(flags, p.name, c.vals[p.name])
				}
			}
		}
		echo(&c, flags, c.cmd.flags)
		echo(&c, flags, s.flags)
		jset(ok, "flags", flags)
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
			if c.json {
				jset_bool(c.out, "dry_run", true)
			} else {
				// A person reading text is told on stderr, where the
				// result's own lines are not.
				cli_note(&c, "%s %s: dry run, nothing was changed", s.noun, c.cmd.verb)
			}
		}
		emit(&c, c.out)
	} else {
		report(&c, code)
	}
	audit_call(&c, code)
	return code, true
}

// cli_capture runs a command line in process, as cli_args does, and returns
// what it printed on stdout instead of printing it — the in-process "run this
// and give me its JSON" a self-test wants. Add `--json` to the argv for the
// document; `cli_capture_json` does that and parses it. Only what the kit
// prints is captured: a command that writes to stdout itself bypasses it.
cli_capture :: proc(
	s: ^Surface,
	argv: []string,
	allocator := context.allocator,
) -> (
	code: int,
	stdout: string,
	handled: bool,
) {
	sb := strings.builder_make(allocator)
	prev := g_stdout
	g_stdout = &sb
	code, handled = cli_args(s, argv)
	g_stdout = prev
	return code, strings.to_string(sb), handled
}

// cli_capture_json is cli_capture with --json, parsed. `doc` is nil when the
// command printed nothing that parses.
cli_capture_json :: proc(
	s: ^Surface,
	argv: []string,
	allocator := context.allocator,
) -> (
	code: int,
	doc: json.Value,
	text: string,
) {
	line := make([dynamic]string, 0, len(argv) + 1, context.temp_allocator)
	append(&line, ..argv)
	has := false
	for a in argv {
		if a == "--json" {
			has = true
		}
	}
	if !has {
		append(&line, "--json")
	}
	code, text, _ = cli_capture(s, line[:], allocator)
	v, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, allocator)
	if err == nil {
		doc = v
	}
	return code, doc, text
}

// report prints a refusal. Under --json it is a document on stdout, because a
// refusal is a result an agent parses; otherwise it is a line on stderr.
@(private = "file")
report :: proc(c: ^Call, code: int) -> int {
	if c.err == nil {
		cli_fail(c, code)
	}
	if c.partial && c.out != nil && len(c.out.items) > 0 {
		if c.json {
			jset(c.err, "partial", c.out)
		} else {
			emit(c, c.out)
		}
	}
	scrub_json(c.err, c.secrets)
	if c.json {
		say(json_text(c.err, 2, context.temp_allocator))
		say("\n")
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

// cli_word_is_path is the usual `takes_word`: a bare word opens the window if
// it names something on disk, or is a URI (`magnet:?…`, `https://…`). A typo
// of a verb is neither, and is a usage error instead of a window.
cli_word_is_path :: proc(word: string) -> bool {
	if word == "" {
		return false
	}
	if os.exists(word) {
		return true
	}
	if strings.contains(word, "://") {
		return true
	}
	// scheme:rest, as in magnet:?xt=… or mailto:a@b — letters first, then
	// letters, digits, + - . up to the colon.
	colon := strings.index_byte(word, ':')
	if colon <= 1 {
		return false
	}
	for ch, i in transmute([]u8)word[:colon] {
		alpha := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
		if i == 0 && !alpha {
			return false
		}
		if !alpha && !(ch >= '0' && ch <= '9') && ch != '+' && ch != '-' && ch != '.' {
			return false
		}
	}
	return true
}
