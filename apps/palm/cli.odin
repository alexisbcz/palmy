package main

// palm's own commands. They are declared with the same kit convention every
// application uses, which is deliberate: the dispatcher is not a special case,
// and `palm --schema` describes palm the way `notes --schema` describes notes.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "schema",
		summary = "the whole command surface as JSON, collected from the applications",
		effect = .Read,
		flags = {
			{name = "noun", kind = .String, help = "just this application"},
			{name = "all", kind = .Bool, help = "include the applications that are not on the convention yet"},
		},
		out = SCHEMA_FIELDS,
		examples = {"palm schema --json", "palm schema --noun notes --json"},
		run = cmd_schema,
	},
	{
		verb = "commands",
		summary = "the index, one entry per command",
		effect = .Read,
		flags = {
			{name = "noun", kind = .String, help = "just this application"},
			{name = "effect", kind = .Enum, help = "only commands of this class", values = {"read", "idempotent", "mutate", "destructive", "intent"}},
		},
		out = COMMANDS_FIELDS,
		examples = {"palm commands --json", "palm commands --effect destructive --json"},
		run = cmd_commands,
	},
	{
		verb = "audit",
		summary = "what has been run, and under which identity",
		effect = .Read,
		flags = {{name = "limit", kind = .Int, help = "the newest N entries", def = "50"}},
		out = AUDIT_FIELDS,
		examples = {"palm audit --json", "palm audit --limit 10 --json"},
		run = cmd_audit,
	},
	{
		verb = "identity",
		summary = "the scope in force, and what it allows",
		effect = .Read,
		out = IDENTITY_FIELDS,
		examples = {"palm identity --json"},
		run = cmd_identity,
	},
	{
		verb = "version",
		summary = "the dispatcher's version and where it looks for applications",
		effect = .Read,
		out = VERSION_FIELDS,
		examples = {"palm version --json"},
		run = cmd_version,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "palm",
			summary  = "one command surface over every application, designed for agents",
			gui      = false,
			selftest = selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `palm <noun> <verb> runs that application's own binary and passes its
stdout through unchanged. Every application is independently runnable, so
` + "`notes list --json`" + ` works with no palm at all; the dispatcher exists for
discovery and for the rules that have to hold across applications.

$PALM_BIN_DIR says where the application binaries are; without it palm looks
beside itself for apps/<name>/<name>.bin.
$PALM_IDENTITY is the scope in force. --identity may narrow it and can never
widen it: asking for another identity exits 5.
$PALM_AUDIT is the audit log; the default is $XDG_STATE_HOME/palm/audit.jsonl.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

SCHEMA_FIELDS := []kit.Field {
	{name = "version", kind = .Int},
	{
		name = "exit_codes",
		kind = .Object,
		help = "the documented codes and the token each one carries",
	},
	{name = "base_flags", kind = .Array, of = {{kind = .String}}},
	{
		name = "nouns",
		kind = .Array,
		of = {
			{name = "noun", kind = .String},
			{name = "app", kind = .String, help = "the directory under apps/"},
			{name = "summary", kind = .String},
			{name = "binary", kind = .String},
			{name = "available", kind = .Bool},
			{name = "reason", kind = .String, opt = true, help = "why not, when it is not"},
			{name = "schema", kind = .Object, opt = true, help = "the application's own declaration"},
		},
	},
	{name = "available", kind = .Int},
	{name = "total", kind = .Int},
	{name = "command_count", kind = .Int},
}

COMMANDS_FIELDS := []kit.Field {
	{
		name = "commands",
		kind = .Array,
		of = {
			{name = "command", kind = .String, help = "how it is typed: palm notes list"},
			{name = "noun", kind = .String},
			{name = "verb", kind = .String},
			{name = "summary", kind = .String},
			{name = "effect", kind = .String},
			{name = "usage", kind = .String},
			{name = "examples", kind = .Array, of = {{kind = .String}}},
		},
	},
	{name = "count", kind = .Int},
}

AUDIT_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "entries", kind = .Array, of = {{name = "at", kind = .String}, {name = "kind", kind = .String}}},
	{name = "count", kind = .Int},
}

IDENTITY_FIELDS := []kit.Field {
	{name = "identity", kind = .String, help = "the scope in force, or \"unscoped\""},
	{name = "scoped", kind = .Bool},
	{name = "source", kind = .String, help = "PALM_IDENTITY, or none"},
	{name = "rule", kind = .String},
}

VERSION_FIELDS := []kit.Field {
	{name = "version", kind = .String},
	{name = "binary_dir", kind = .String},
	{name = "nouns", kind = .Int},
	{name = "on_convention", kind = .Int},
	{name = "audit", kind = .String},
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_schema :: proc(c: ^kit.Call) -> int {
	only := kit.cli_str(c, "noun")
	if only != "" {
		if _, ok := find_noun(only); !ok {
			code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no application called %q", only)
			kit.cli_err_field(c, "noun", only)
			return code
		}
	}
	want_all := kit.cli_bool(c, "all")

	kit.jset_int(c.out, "version", 1)
	codes := kit.jobj()
	for code in kit.CLI_EXIT_CODES {
		kit.jset_str(codes, fmt.tprintf("%d", code), kit.cli_exit_reason(code))
	}
	kit.jset(c.out, "exit_codes", codes)
	base := kit.jarr()
	for b in ([?]string{"--json", "--dry-run", "--yes", "--identity", "--verbose", "--help", "--schema", "--parse-only", "--selftest"}) {
		kit.jpush(base, kit.jstr(b))
	}
	kit.jset(c.out, "base_flags", base)

	arr := kit.jarr()
	ready, total := 0, 0
	for info in collect(only) {
		if !info.available && !want_all && only == "" && !info.noun.on_convention {
			total += 1
			continue
		}
		total += 1
		o := kit.jobj()
		kit.jset_str(o, "noun", info.noun.noun)
		kit.jset_str(o, "app", info.noun.app)
		kit.jset_str(o, "summary", info.noun.summary)
		kit.jset_str(o, "binary", info.path)
		kit.jset_bool(o, "available", info.available)
		if info.available {
			ready += 1
			kit.jset(o, "schema", jfrom(info.doc))
		} else {
			kit.jset_str(o, "reason", info.reason)
		}
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "nouns", arr)
	kit.jset_int(c.out, "available", ready)
	kit.jset_int(c.out, "total", total)
	n := 0
	for info in collect(only) {
		n += len(info.commands)
	}
	kit.jset_int(c.out, "command_count", n)
	return kit.EXIT_OK
}

@(private = "file")
cmd_commands :: proc(c: ^kit.Call) -> int {
	only := kit.cli_str(c, "noun")
	if only != "" {
		if _, ok := find_noun(only); !ok {
			code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no application called %q", only)
			kit.cli_err_field(c, "noun", only)
			return code
		}
	}
	want_effect := kit.cli_str(c, "effect")
	arr := kit.jarr()
	for info in collect(only) {
		if !info.available {
			continue
		}
		for cmd in info.commands {
			if bool_of(cmd, "hidden") {
				continue
			}
			if want_effect != "" && str_of(cmd, "effect") != want_effect {
				continue
			}
			o := kit.jobj()
			kit.jset_str(o, "command", fmt.tprintf("palm %s %s", info.noun.noun, str_of(cmd, "verb")))
			kit.jset_str(o, "noun", info.noun.noun)
			kit.jset_str(o, "verb", str_of(cmd, "verb"))
			kit.jset_str(o, "summary", str_of(cmd, "summary"))
			kit.jset_str(o, "effect", str_of(cmd, "effect"))
			kit.jset_str(o, "usage", fmt.tprintf("palm %s", str_of(cmd, "usage")))
			ex := kit.jarr()
			for e in arr_of(cmd, "examples") {
				if s, ok := e.(json.String); ok {
					kit.jpush(ex, kit.jstr(fmt.tprintf("palm %s", string(s))))
				}
			}
			kit.jset(o, "examples", ex)
			kit.jpush(arr, o)
		}
	}
	kit.jset(c.out, "commands", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_audit :: proc(c: ^kit.Call) -> int {
	path := kit.cli_audit_path(context.allocator)
	kit.jset_str(c.out, "path", path)
	arr := kit.jarr()
	kit.jset(c.out, "entries", arr)
	kit.jset_int(c.out, "count", 0)
	if path == "" || !os.exists(path) {
		return kit.EXIT_OK
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot read %s", path)
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	limit := kit.cli_int(c, "limit", 50)
	keep := make([dynamic]string, context.temp_allocator)
	for l in lines {
		if strings.trim_space(l) != "" {
			append(&keep, l)
		}
	}
	from := 0
	if limit > 0 && len(keep) > limit {
		from = len(keep) - limit
	}
	for l in keep[from:] {
		v, perr := json.parse_string(l, json.DEFAULT_SPECIFICATION, true, context.allocator)
		if perr != nil {
			continue
		}
		kit.jpush(arr, jfrom(v))
	}
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_identity :: proc(c: ^kit.Call) -> int {
	scope := kit.cli_scope()
	kit.jset_str(c.out, "identity", scope == "" ? "unscoped" : scope)
	kit.jset_bool(c.out, "scoped", scope != "")
	kit.jset_str(c.out, "source", scope == "" ? "none" : "PALM_IDENTITY")
	kit.jset_str(
		c.out,
		"rule",
		"scope is read from the environment and may only be narrowed by --identity, never widened",
	)
	return kit.EXIT_OK
}

@(private = "file")
cmd_version :: proc(c: ^kit.Call) -> int {
	kit.jset_str(c.out, "version", VERSION)
	dir := bin_dir()
	if dir == "" {
		self, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			self = os.args[0]
		}
		if i := strings.last_index_byte(self, '/'); i > 0 {
			dir = fmt.tprintf("%s/..", self[:i])
		}
	}
	kit.jset_str(c.out, "binary_dir", dir)
	kit.jset_int(c.out, "nouns", len(NOUNS))
	ready := 0
	for n in NOUNS {
		if n.on_convention {
			ready += 1
		}
	}
	kit.jset_int(c.out, "on_convention", ready)
	kit.jset_str(c.out, "audit", kit.cli_audit_path(context.allocator))
	return kit.EXIT_OK
}
