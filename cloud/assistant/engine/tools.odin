// Package engine is the assistant's runtime: the tools, the rules, and the
// loop. It runs inside the sandbox (cloud/assistant/sandbox), holding a
// session delegated to one identity, and talks to its parent — the person's
// own process — over a pipe. See cloud/docs/assistant.md.
package engine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import ck "../../../apps/cloudkit"

// ---------------------------------------------------------------------------
// Classes
//
// What a tool may do decides who runs it:
//
//   Read     the assistant runs it, freely, inside its identity; logged
//   Draft    the assistant runs it: it writes inside the identity and
//            sends nothing (a mail draft, a new note); logged
//   Confirm  the assistant may only propose it; the person sees the exact
//            arguments and confirms, and the *person's* session runs it.
//            The database refuses these acts to an assistant session in
//            any case (20261020100000_assistant.sql)
//   Never    not offered at all
// ---------------------------------------------------------------------------

Class :: enum u8 {
	Never,
	Read,
	Draft,
	Confirm,
}

class_name :: proc(c: Class) -> string {
	switch c {
	case .Never:
		return "never"
	case .Read:
		return "read"
	case .Draft:
		return "draft"
	case .Confirm:
		return "confirm"
	}
	return "never"
}

// POLICY is the whole surface, by noun and verb. A verb not listed is not
// offered; a verb listed more permissively than its own --schema declares
// (Read here, `mutate` there) is treated as Confirm, so an application that
// grows a side effect cannot slip it past this table.
@(private)
Rule :: struct {
	noun, verb: string,
	class:      Class,
}

POLICY := [?]Rule {
	// The local search index (apps/home's `index`, cloud/docs/search.md):
	// one identity's mail, files, events, notes and chats, offline.
	{"index", "search", .Read},
	{"index", "status", .Read},
	{"mail", "unread", .Read},
	{"mail", "search", .Read},
	{"mail", "read", .Read},
	{"mail", "drafts", .Read},
	{"mail", "draft", .Draft},
	{"mail", "send", .Confirm},
	{"drive", "ls", .Read},
	{"drive", "find", .Read},
	{"drive", "stat", .Read},
	{"drive", "recent", .Read},
	{"drive", "starred", .Read},
	{"drive", "versions", .Read},
	{"drive", "share", .Confirm},
	{"drive", "link", .Confirm},
	{"drive", "trash", .Confirm},
	{"calendar", "events", .Read},
	{"calendar", "next", .Read},
	{"calendar", "invitations", .Read},
	{"calendar", "add", .Confirm},
	{"calendar", "accept", .Confirm},
	{"calendar", "decline", .Confirm},
	{"contacts", "list", .Read},
	{"contacts", "show", .Read},
	{"contacts", "add", .Confirm},
	{"notes", "list", .Read},
	{"notes", "read", .Read},
	{"notes", "search", .Read},
	{"notes", "new", .Draft},
	{"notes", "append", .Confirm},
	{"chat", "spaces", .Read},
	{"chat", "channels", .Read},
	{"chat", "history", .Read},
	{"chat", "search", .Read},
	{"chat", "post", .Confirm},
	{"forge", "repo-list", .Read},
	{"forge", "issue-list", .Read},
	{"forge", "issue-show", .Read},
	{"forge", "pr-list", .Read},
	{"forge", "pr-show", .Read},
	{"forge", "activity", .Read},
	{"forge", "issue-comment", .Confirm},
	{"forge", "issue-create", .Confirm},
}

policy_of :: proc(noun, verb, effect: string) -> Class {
	cls := Class.Never
	for r in POLICY {
		if r.noun == noun && r.verb == verb {
			cls = r.class
		}
	}
	if cls == .Read && effect != "read" {
		cls = .Confirm
	}
	if effect == "destructive" && cls != .Never {
		cls = .Confirm
	}
	return cls
}

// The flags every convention binary takes, which are the runtime's to set
// and never the model's: scope, output, confirmation.
@(private)
BASE_FLAGS := [?]string{"json", "dry-run", "yes", "help", "identity", "verbose"}

// ---------------------------------------------------------------------------
// The registry, generated from --schema
// ---------------------------------------------------------------------------

Param :: struct {
	name:       string,
	kind:       string, // string | int | bool | enum | path | float
	help:       string,
	required:   bool,
	positional: bool,
	values:     []string,
	def:        string,
}

Tool :: struct {
	name:      string, // what the model calls it: mail_unread, drive_find
	noun:      string,
	verb:      string,
	bin:       string,
	summary:   string,
	effect:    string, // as the binary declares it
	class:     Class,
	params:    [dynamic]Param,
	composite: bool, // made by the engine out of other verbs
}

Registry :: struct {
	tools:   [dynamic]Tool,
	skipped: [dynamic]string, // verbs present but not offered, for the report
	bins:    map[string]string, // noun -> binary
}

tool_name :: proc(noun, verb: string, allocator := context.allocator) -> string {
	s, _ := strings.replace_all(fmt.tprintf("%s_%s", noun, verb), "-", "_", allocator)
	return s
}

// load_registry runs `<bin> --schema` for every executable in `dir` and keeps
// the verbs the policy offers. The binaries are the only things the sandbox
// lets the assistant execute, so this is the whole of what it can do.
load_registry :: proc(dir: string, allocator := context.allocator) -> (r: Registry) {
	r.tools = make([dynamic]Tool, allocator)
	r.skipped = make([dynamic]string, allocator)
	r.bins = make(map[string]string, allocator = allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for e in entries {
		if e.type == .Directory || strings.has_suffix(e.name, ".log") {
			continue
		}
		bin := fmt.aprintf("%s/%s", dir, e.name, allocator = allocator)
		state, out, _, perr := os.process_exec({command = {bin, "--schema"}, env = tool_env()}, context.temp_allocator)
		if perr != nil || state.exit_code != 0 {
			append(&r.skipped, fmt.aprintf("%s (no --schema)", e.name, allocator = allocator))
			continue
		}
		v, ok := ck.parse(string(out), context.temp_allocator)
		if !ok {
			continue
		}
		noun := strings.clone(ck.get_str(v, "noun"), allocator)
		r.bins[noun] = bin
		for c in ck.array(ck.get(v, "commands")) {
			verb := ck.get_str(c, "verb")
			effect := ck.get_str(c, "effect")
			cls := policy_of(noun, verb, effect)
			if cls == .Never || ck.get_bool(c, "hidden") {
				append(&r.skipped, fmt.aprintf("%s %s", noun, verb, allocator = allocator))
				continue
			}
			t := Tool {
				name    = tool_name(noun, verb, allocator),
				noun    = noun,
				verb    = strings.clone(verb, allocator),
				bin     = bin,
				summary = strings.clone(ck.get_str(c, "summary"), allocator),
				effect  = strings.clone(effect, allocator),
				class   = cls,
				params  = make([dynamic]Param, allocator),
			}
			for a in ck.array(ck.get(c, "args")) {
				append(&t.params, param_from(a, true, allocator))
			}
			for f in ck.array(ck.get(c, "flags")) {
				name := ck.get_str(f, "name")
				if slice.contains(BASE_FLAGS[:], name) {continue}
				append(&t.params, param_from(f, false, allocator))
			}
			append(&r.tools, t)
		}
	}
	add_composites(&r, allocator)
	return
}

@(private)
param_from :: proc(v: ck.Value, positional: bool, allocator := context.allocator) -> Param {
	p := Param {
		name       = strings.clone(ck.get_str(v, "name"), allocator),
		kind       = strings.clone(ck.get_str(v, "type"), allocator),
		help       = strings.clone(ck.get_str(v, "help"), allocator),
		required   = ck.get_bool(v, "required"),
		positional = positional,
		def        = strings.clone(ck.get_str(v, "default"), allocator),
	}
	vals := make([dynamic]string, allocator)
	for x in ck.array(ck.get(v, "values")) {
		if s, ok := x.(string); ok {append(&vals, strings.clone(s, allocator))}
	}
	p.values = vals[:]
	return p
}

// add_composites adds the tools the engine makes out of other verbs:
// drive_read is `drive download` into the assistant's own scratch directory
// followed by reading the file as untrusted content.
@(private)
add_composites :: proc(r: ^Registry, allocator := context.allocator) {
	if _, ok := r.bins["drive"]; ok {
		t := Tool {
			name      = strings.clone("drive_read", allocator),
			noun      = "drive",
			verb      = "read",
			bin       = r.bins["drive"],
			summary   = strings.clone("read a text file or document from the drive (its words, hidden text removed)", allocator),
			effect    = "read",
			class     = .Read,
			params    = make([dynamic]Param, allocator),
			composite = true,
		}
		append(&t.params, Param{name = "path", kind = "string", required = true, positional = true, help = "the file's path from the drive root"})
		append(&r.tools, t)
	}
}

find_tool :: proc(r: ^Registry, name: string) -> ^Tool {
	for &t in r.tools {
		if t.name == name {return &t}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Running a tool
// ---------------------------------------------------------------------------

Run :: struct {
	ok:     bool,
	code:   int,
	stdout: string,
	value:  ck.Value,
	err:    string, // a short reason when !ok
	ms:     i64,
}

// tool_env is the environment a tool runs with: exactly the variables the
// agent was started with that a tool needs, nothing inherited by accident.
tool_env :: proc(allocator := context.temp_allocator) -> []string {
	keep := [?]string {
		"HOME", "PATH", "PALM_CLOUD_URL", "PALM_CLOUD_ANON_KEY", "PALM_CLOUD_SESSION", "PALM_IDENTITY",
		"PALM_DAV_URL", "PALM_DAV_CACHE", "PALMY_NOTES_DIR", "PALM_ASSISTANT_STATE", "PALM_AUDIT", "TMPDIR", "XDG_DATA_HOME", "TZ", "LANG",
	}
	out := make([dynamic]string, allocator)
	for k in keep {
		if v, ok := os.lookup_env(k, context.temp_allocator); ok {
			append(&out, fmt.aprintf("%s=%s", k, v, allocator = allocator))
		}
	}
	append(&out, "WAYLAND_DISPLAY=", "DISPLAY=")
	return out[:]
}

// argv_for turns arguments the model filled (already validated) into a
// command line. Positionals in declaration order, then flags. Values are
// separate argv entries, never a shell string.
argv_for :: proc(t: ^Tool, args: map[string]string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	append(&out, t.bin, t.verb)
	for p in t.params {
		if p.positional {
			if v, ok := args[p.name]; ok && v != "" {append(&out, v)}
		}
	}
	for p in t.params {
		if p.positional {continue}
		v, ok := args[p.name]
		if !ok || v == "" {continue}
		if p.kind == "bool" {
			if v == "true" {append(&out, fmt.tprintf("--%s", p.name))}
			continue
		}
		append(&out, fmt.tprintf("--%s", p.name), v)
	}
	append(&out, "--json")
	return out[:]
}

run_argv :: proc(argv: []string, allocator := context.allocator) -> Run {
	start := time.tick_now()
	// Tools run in the assistant's state directory, with relative cache
	// paths. Under Landlock, creating a directory from an absolute path
	// fails: core:os (like `mkdir -p`) opens every ancestor from / down,
	// and the assistant may not open /tmp or $HOME. Granting it directory
	// listing there would show it the names of the other identities'
	// folders, so the paths are relative instead.
	wd := os.get_env("PALM_ASSISTANT_STATE", context.temp_allocator)
	state, out, errb, perr := os.process_exec({command = argv, env = tool_env(), working_dir = wd}, allocator)
	r := Run{ms = i64(time.duration_milliseconds(time.tick_since(start)))}
	if perr != nil {
		r.err = fmt.aprintf("could not run %s (%v)", argv[0], perr, allocator = allocator)
		r.code = 7
		return r
	}
	r.code = state.exit_code
	r.stdout = string(out)
	if os.get_env("PALM_ASSISTANT_TRACE", context.temp_allocator) != "" {
		fmt.eprintfln("--- tool %v -> %d (%d ms)\n%s\n%s", argv[1:], r.code, r.ms, string(out), string(errb))
	}
	v, ok := ck.parse(r.stdout, allocator)
	if ok {r.value = v}
	r.ok = state.exit_code == 0
	if !r.ok {
		detail := ck.get_str(v, "detail")
		if detail == "" {detail = ck.get_str(v, "error")}
		if detail == "" {detail = strings.trim_space(string(errb))}
		r.err = strings.clone(detail, allocator)
	}
	return r
}

// value_text renders a JSON value compactly for a model: one line per item of
// a list, `key: value` pairs, long strings kept whole up to a budget.
value_text :: proc(v: json.Value, budget := 3000, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_value(&b, v, 0)
	s := strings.to_string(b)
	if len(s) > budget {
		cut := budget
		for cut > 0 && (s[cut] & 0xC0) == 0x80 {cut -= 1}
		return fmt.aprintf("%s\n[… %d more characters not shown]", s[:cut], len(s) - cut, allocator = allocator)
	}
	return s
}

@(private)
SKIP_KEYS := [?]string{"hash", "etag", "uid", "seq", "starred", "kind", "identity", "untrusted", "slug", "in_title"}

@(private)
write_value :: proc(b: ^strings.Builder, v: json.Value, depth: int) {
	#partial switch x in v {
	case json.Object:
		keys := make([dynamic]string, context.temp_allocator)
		for k in x {append(&keys, k)}
		slice.sort(keys[:])
		// Lists first by their natural order of importance: id/name/from/subject.
		order := [?]string{"id", "path", "name", "title", "from", "to", "subject", "date", "start", "text", "preview"}
		done := make(map[string]bool, allocator = context.temp_allocator)
		first := true
		emit :: proc(b: ^strings.Builder, k: string, val: json.Value, depth: int, first: ^bool) {
			if slice.contains(SKIP_KEYS[:], k) {return}
			#partial switch y in val {
			case json.Null:
				return
			case json.String:
				if y == "" {return}
			case json.Array:
				if len(y) == 0 {return}
			}
			if !first^ {strings.write_string(b, "; ")}
			first^ = false
			fmt.sbprintf(b, "%s: ", k)
			write_value(b, val, depth + 1)
		}
		for k in order {
			if val, ok := x[k]; ok {
				emit(b, k, val, depth, &first)
				done[k] = true
			}
		}
		for k in keys {
			if done[k] {continue}
			emit(b, k, x[k], depth, &first)
		}
	case json.Array:
		if depth == 0 || depth == 1 {
			for item, i in x {
				fmt.sbprintf(b, "\n%d. ", i + 1)
				write_value(b, item, depth + 1)
			}
		} else {
			for item, i in x {
				if i > 0 {strings.write_string(b, ", ")}
				write_value(b, item, depth + 1)
			}
		}
	case json.String:
		strings.write_string(b, x)
	case json.Integer:
		fmt.sbprintf(b, "%d", x)
	case json.Float:
		fmt.sbprintf(b, "%v", x)
	case json.Boolean:
		strings.write_string(b, x ? "yes" : "no")
	}
}
