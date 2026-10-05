// track — a project and issue tracker whose issues are files, whose edges
// mean something, and which tells you when it is lying.
//
//	track ready                     what is unblocked right now
//	track list   [--state S] [--label L] [--project P] [--assignee A]
//	track show   <id>
//	track prompt <id>               the brief, ready to hand to an agent
//	track new    <title> [--dep X] [--verify CMD] ...
//	track set    <id> [--state S] [--assignee A] [--verify CMD] ...
//	track dep    <id> <on> [--remove]
//	track rm     <id> --yes
//	track graph  [--json]           the dependency graph, layered
//	track board  [--json]           grouped by state
//	track stale  [--run]            which issues are lying — see verify.odin
//	track check                     cycles, dangling edges, unknown states
//	track import <file> [--dry-run] TODO.md in, issues out
//	track states / where / init
//	track --selftest
//
// Three things this is not, each of which was a deliberate subtraction:
//
//   * **Not a database.** One Markdown file per issue, in a directory, in the
//     repository. `git log` on a file is that issue's history. Two people
//     editing different issues cannot conflict. There is no index to drift.
//   * **Not a todo list.** Dependencies are load-bearing: the default view is
//     "what is unblocked", a cycle is refused rather than warned about, and
//     the graph view draws the real DAG.
//   * **Not a planning instrument.** No sprints, no velocity, no burndown,
//     and the states are a text file you edit rather than an enum in here.
//
// Everything is reachable from the command line with `--json`, through the
// shared convention in `apps/kit/cli.odin`, because the point is that an
// agent can drive it. The GUI and the CLI go through the same procedures in
// store.odin and graph.odin; there is no second path that can rot.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

tfmt :: fmt.tprintf

// ---------------------------------------------------------------------------
// Shared field shapes, declared once so `--schema` and the code agree
// ---------------------------------------------------------------------------

ISSUE_FIELDS := []kit.Field {
	{name = "id", kind = .String, help = "the stable identifier"},
	{name = "title", kind = .String, help = "one line"},
	{name = "state", kind = .String, help = "one of the configured states"},
	{name = "project", kind = .String, help = "the `#` section it came from", opt = true},
	{name = "assignee", kind = .String, help = "a person, or `agent:name`", opt = true},
	{name = "labels", kind = .Array, help = "free-form tags", of = []kit.Field{{kind = .String}}},
	{name = "deps", kind = .Array, help = "the ids this one is blocked by", of = []kit.Field{{kind = .String}}},
	{name = "blockers", kind = .Array, help = "the deps still in the way", of = []kit.Field{{kind = .String}}},
	{name = "ready", kind = .Bool, help = "nothing open is in front of it"},
	{name = "depth", kind = .Int, help = "longest chain of open work ahead of it"},
	{name = "verification", kind = .String, help = "verified-true, verified-stale or unverified"},
	{name = "verify", kind = .String, help = "the command, when it declares one", opt = true},
	{name = "has_prompt", kind = .Bool, help = "carries an agent brief"},
	{name = "path", kind = .String, help = "the file it lives in"},
}

STALE_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "verification", kind = .String, help = "verified-true, verified-stale or unverified"},
	{name = "command", kind = .String, help = "the declared verification"},
	{name = "ran", kind = .Bool, help = "false unless --run was given"},
	{name = "exit", kind = .Int, help = "its exit status, when it ran", opt = true},
	{name = "note", kind = .String, help = "why it did not run, or what it said", opt = true},
}

// ---------------------------------------------------------------------------
// The surface
//
// COMMANDS is a package-level variable rather than a slice literal inside the
// procedure below. A composite literal for a slice field is backed by an
// array whose lifetime is the enclosing scope, so building the declaration on
// a stack frame and keeping a pointer to it gives a surface that works for
// exactly as long as that frame lives and then reads freed stack. It cost an
// afternoon: every verb worked when called straight from `main`, and the
// self-test segfaulted inside the kit's `find_command`, comparing a token
// against a verb string that was no longer there.
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "ready",
		summary = "what is unblocked right now",
		effect = .Read,
		flags = {
			{name = "assignee", kind = .String, help = "only this person or agent"},
			{name = "label", kind = .String, help = "only this label"},
			{name = "limit", kind = .Int, help = "at most this many", def = "0"},
		},
		out = {{name = "ready", kind = .Array, of = ISSUE_FIELDS}, {name = "count", kind = .Int}},
		examples = {"track ready --json", "track ready --assignee agent:claude"},
		run = cmd_ready,
	},
	{
		verb = "list",
		summary = "every issue, with filters",
		effect = .Read,
		flags = {
			{name = "state", kind = .String, help = "only this state"},
			{name = "label", kind = .String, help = "only this label"},
			{name = "project", kind = .String, help = "only this project"},
			{name = "assignee", kind = .String, help = "only this person or agent"},
			{name = "blocked", kind = .Bool, help = "only what is waiting on something"},
			{name = "open", kind = .Bool, help = "hide the closed states"},
		},
		out = {{name = "issues", kind = .Array, of = ISSUE_FIELDS}, {name = "count", kind = .Int}},
		examples = {"track list --json", "track list --state todo --label toolkit"},
		run = cmd_list,
	},
	{
		verb = "show",
		summary = "one issue, whole",
		effect = .Read,
		args = {{name = "id", kind = .String, help = "the issue id", required = true}},
		out = {
			{name = "id", kind = .String},
			{name = "title", kind = .String},
			{name = "state", kind = .String},
			{name = "project", kind = .String, opt = true},
			{name = "assignee", kind = .String, opt = true},
			{name = "labels", kind = .Array, of = []kit.Field{{kind = .String}}},
			{name = "deps", kind = .Array, of = []kit.Field{{kind = .String}}},
			{name = "blockers", kind = .Array, of = []kit.Field{{kind = .String}}},
			{name = "dependants", kind = .Array, of = []kit.Field{{kind = .String}}},
			{name = "ready", kind = .Bool},
			{name = "depth", kind = .Int},
			{name = "verification", kind = .String},
			{name = "verify", kind = .String, opt = true},
			{name = "verified_at", kind = .String, opt = true},
			{name = "body", kind = .String, opt = true},
			{name = "prompt", kind = .String, opt = true},
			{name = "path", kind = .String},
		},
		examples = {"track show T7", "track show T7 --json"},
		run = cmd_show,
	},
	{
		verb = "prompt",
		summary = "the agent brief, ready to hand over",
		effect = .Read,
		args = {{name = "id", kind = .String, help = "the issue id", required = true}},
		flags = {{name = "bare", kind = .Bool, help = "the prompt alone, with no header"}},
		out = {
			{name = "id", kind = .String},
			{name = "title", kind = .String},
			{name = "prompt", kind = .String},
			{name = "has_prompt", kind = .Bool},
		},
		examples = {"track prompt T7", "track prompt T7 --bare"},
		run = cmd_prompt,
	},
	{
		verb = "new",
		summary = "create an issue",
		effect = .Mutate,
		args = {{name = "title", kind = .String, help = "one line", required = true}},
		flags = {
			{name = "id", kind = .String, help = "choose the id rather than generating one"},
			{name = "prefix", kind = .String, help = "id prefix when generating", def = "I"},
			{name = "state", kind = .String, help = "the starting state"},
			{name = "project", kind = .String},
			{name = "assignee", kind = .String, help = "a person, or `agent:name`"},
			{name = "label", kind = .String, help = "comma-separated"},
			{name = "dep", kind = .String, help = "comma-separated ids this is blocked by"},
			{name = "verify", kind = .String, help = "a command that exits zero while this is true"},
			{name = "body", kind = .String},
			{name = "prompt", kind = .String, help = "the agent brief"},
			{name = "prompt-file", kind = .Path, help = "read the brief from a file, or - for stdin"},
		},
		out = {{name = "id", kind = .String}, {name = "path", kind = .String}, {name = "created", kind = .Bool}},
		examples = {
			`track new "Wire bidi into the text path" --prefix T --label toolkit`,
			`track new "Ship it" --dep T1,T2 --verify "! grep -q TODO palmy/font.odin"`,
		},
		run = cmd_new,
	},
	{
		verb = "set",
		summary = "change a field on an issue",
		effect = .Mutate,
		args = {{name = "id", kind = .String, required = true}},
		flags = {
			{name = "state", kind = .String},
			{name = "title", kind = .String},
			{name = "project", kind = .String},
			{name = "assignee", kind = .String},
			{name = "verify", kind = .String, help = `the command; "" clears it`},
			{name = "label", kind = .String, help = "replace the labels, comma-separated"},
			{name = "body", kind = .String},
			{name = "prompt", kind = .String},
			{name = "prompt-file", kind = .Path, help = "read the brief from a file, or - for stdin"},
		},
		out = {{name = "id", kind = .String}, {name = "changed", kind = .Array, of = []kit.Field{{kind = .String}}}},
		examples = {"track set T7 --state done", "track set T7 --assignee agent:claude"},
		run = cmd_set,
	},
	{
		verb = "dep",
		summary = "add or remove a dependency edge",
		effect = .Mutate,
		args = {
			{name = "id", kind = .String, help = "the blocked issue", required = true},
			{name = "on", kind = .String, help = "what it waits for", required = true},
		},
		flags = {{name = "remove", kind = .Bool, help = "take the edge away instead"}},
		out = {
			{name = "id", kind = .String},
			{name = "deps", kind = .Array, of = []kit.Field{{kind = .String}}},
		},
		examples = {"track dep C2 C1", "track dep C2 C1 --remove"},
		run = cmd_dep,
	},
	{
		verb = "rm",
		summary = "delete an issue file",
		effect = .Destructive,
		args = {{name = "id", kind = .String, required = true}},
		out = {
			{name = "id", kind = .String},
			{name = "path", kind = .String},
			{name = "orphaned", kind = .Array, help = "issues now pointing at nothing", of = []kit.Field{{kind = .String}}},
		},
		examples = {"track rm T9 --yes"},
		run = cmd_rm,
	},
	{
		verb = "graph",
		summary = "the dependency graph, layered",
		effect = .Read,
		flags = {{name = "open", kind = .Bool, help = "hide the closed states", def = "true"}},
		out = {
			{name = "layers", kind = .Array, of = []kit.Field{
				{name = "depth", kind = .Int},
				{name = "issues", kind = .Array, of = ISSUE_FIELDS},
			}},
			{name = "edges", kind = .Array, of = []kit.Field{
				{name = "from", kind = .String, help = "the blocked issue"},
				{name = "to", kind = .String, help = "what it waits for"},
			}},
			{name = "cycle", kind = .Array, help = "non-empty means the graph is broken", of = []kit.Field{{kind = .String}}},
		},
		examples = {"track graph", "track graph --json"},
		run = cmd_graph,
	},
	{
		verb = "board",
		summary = "issues grouped by state",
		effect = .Read,
		flags = {{name = "project", kind = .String, help = "only this project"}},
		out = {
			{name = "columns", kind = .Array, of = []kit.Field{
				{name = "state", kind = .String},
				{name = "closed", kind = .Bool},
				{name = "count", kind = .Int},
				{name = "issues", kind = .Array, of = ISSUE_FIELDS},
			}},
		},
		examples = {"track board", "track board --json"},
		run = cmd_board,
	},
	{
		verb = "stale",
		summary = "which issues are lying; executes nothing without --run",
		// Declared `mutate` rather than `read` because --run records
		// each verdict back into the issue file. Without --run this
		// command reads and spawns nothing, and the audit record
		// carries the argv, so a reader can tell the two apart.
		effect = .Mutate,
		flags = {
			{name = "run", kind = .Bool, help = "EXECUTE the declared commands — see the note below"},
			{name = "only", kind = .String, help = "one id, rather than every issue"},
			{name = "no-write", kind = .Bool, help = "with --run: report but do not record the verdicts"},
			{name = "all", kind = .Bool, help = "include issues with no verification"},
		},
		out = {
			{name = "issues", kind = .Array, of = STALE_FIELDS},
			{name = "verified_true", kind = .Int},
			{name = "verified_stale", kind = .Int},
			{name = "unverified", kind = .Int},
			{name = "executed", kind = .Bool, help = "whether anything was run at all"},
		},
		examples = {"track stale", "track stale --run", "track stale --run --only T7"},
		run = cmd_stale,
	},
	{
		verb = "check",
		summary = "cycles, dangling edges, unknown states",
		effect = .Read,
		out = {
			{name = "ok", kind = .Bool},
			{name = "problems", kind = .Array, of = []kit.Field{
				{name = "kind", kind = .String},
				{name = "id", kind = .String},
				{name = "detail", kind = .String},
			}},
		},
		examples = {"track check --json"},
		run = cmd_check,
	},
	{
		verb = "import",
		summary = "parse a TODO.md into issues; the source is never written",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, help = "the Markdown to read", required = true}},
		flags = {
			{name = "link-refs", kind = .Bool, help = "draw an edge where one issue names another's id", def = "true"},
			{name = "overwrite", kind = .Bool, help = "replace issues whose id already exists"},
		},
		out = {
			{name = "source", kind = .String},
			{name = "dir", kind = .String},
			{name = "written", kind = .Int},
			{name = "skipped_existing", kind = .Int},
			{name = "projects", kind = .Int},
			{name = "issues", kind = .Int},
			{name = "prompts", kind = .Int},
			{name = "wontfix", kind = .Int},
			{name = "links", kind = .Int},
			{name = "with_verify", kind = .Int},
			{name = "ids", kind = .Array, of = []kit.Field{{kind = .String}}},
		},
		examples = {"track import TODO.md --dry-run", "track import TODO.md --json"},
		run = cmd_import,
	},
	{
		verb = "states",
		summary = "the configured states, which are a text file",
		effect = .Read,
		out = {
			{name = "file", kind = .String},
			{name = "states", kind = .Array, of = []kit.Field{
				{name = "name", kind = .String},
				{name = "closed", kind = .Bool},
			}},
		},
		examples = {"track states --json"},
		run = cmd_states,
	},
	{
		verb = "where",
		summary = "which directory is in force, and why",
		effect = .Read,
		out = {
			{name = "dir", kind = .String},
			{name = "scope", kind = .String, help = "repo, personal or override"},
			{name = "identity", kind = .String, opt = true},
			{name = "exists", kind = .Bool},
			{name = "issues", kind = .Int},
		},
		examples = {"track where --json"},
		run = cmd_where,
	},
	{
		verb = "init",
		summary = "create the directory and its states.txt",
		effect = .Idempotent,
		out = {{name = "dir", kind = .String}, {name = "created", kind = .Bool}},
		examples = {"track init"},
		run = cmd_init,
	},
	{
		verb = "shots",
		summary = "render the window offscreen to PNGs",
		effect = .Mutate,
		hidden = true,
		args = {{name = "dir", kind = .Path, help = "where to write them", required = true}},
		out = {{name = "written", kind = .Int}, {name = "dir", kind = .String}},
		run = cmd_shots,
	},
}

@(private = "file")
g_surface: kit.Surface
@(private = "file")
g_built: bool

// surface is a procedure rather than a package variable for the reason
// kit/cli.odin gives: a declaration whose field slices are themselves package
// variables cannot rely on Odin's initialisation order, and a half-built
// schema is a schema that lies.
surface :: proc() -> ^kit.Surface {
	if g_built {
		return &g_surface
	}
	g_surface = kit.Surface {
		noun     = "track",
		summary  = "a project and issue tracker whose issues are files",
		gui      = true,
		selftest = selftest,
		notes    = NOTES,
		commands = COMMANDS,
	}
	g_built = true
	return &g_surface
}

NOTES :: `Issues are Markdown files with frontmatter, one per issue, under
  ./.palm/issues/                         inside a git work tree
  $XDG_DATA_HOME/palmy-track/<identity>/  otherwise
$PALM_TRACK_DIR overrides both. The states are a text file in that directory.

A dependency means "blocked by". A cycle is refused, not warned about.

VERIFICATION IS ARBITRARY CODE FROM A DATA FILE. An issue may carry a
` + "`verify:`" + ` command; exit zero means it is still true. Nothing runs it on
open, on import, or from the window. ` + "`track stale`" + ` lists the commands and
executes none of them; only ` + "`track stale --run`" + ` executes, it prints each
command before running it, and PALM_TRACK_NO_VERIFY=1 refuses regardless.`

main :: proc() {
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	gui_main()
}

// ---------------------------------------------------------------------------
// Rendering an issue into the declared shape
// ---------------------------------------------------------------------------

issue_json :: proc(it: ^Issue, g: ^Graph, i: int) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", it.id)
	kit.jset_str(o, "title", it.title)
	kit.jset_str(o, "state", it.state)
	kit.jset_str(o, "project", it.project)
	kit.jset_str(o, "assignee", it.assignee)
	kit.jset(o, "labels", str_array(it.labels))
	kit.jset(o, "deps", str_array(it.deps))
	kit.jset(o, "blockers", str_array(graph_blockers(g, i)))
	kit.jset_bool(o, "ready", g.ready[i])
	kit.jset_int(o, "depth", g.depth[i])
	kit.jset_str(o, "verification", verdict_name(it.verdict))
	kit.jset_str(o, "verify", it.verify)
	kit.jset_bool(o, "has_prompt", it.prompt != "")
	kit.jset_str(o, "path", it.path)
	return o
}

// issue_row is the flat shape the human table renderer turns into columns. An
// eight-key object with no nested values is what `kit.cli`'s table renderer
// needs, and a list of issues is the one place that is worth having.
issue_row :: proc(it: ^Issue, g: ^Graph, i: int) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", it.id)
	kit.jset_str(o, "state", it.state)
	kit.jset_str(o, "title", ellipsis(it.title, 54))
	kit.jset_str(o, "blocked by", len(graph_blockers(g, i)) == 0 ? "—" : strings.join(graph_blockers(g, i), " ", context.temp_allocator))
	kit.jset_str(o, "verify", verdict_short(it))
	kit.jset_str(o, "assignee", it.assignee == "" ? "—" : it.assignee)
	return o
}

verdict_short :: proc(it: ^Issue) -> string {
	if it.verify == "" {
		return "—"
	}
	switch it.verdict {
	case .True:
		return "true"
	case .Stale:
		return "STALE"
	case .Unverified:
		return "unchecked"
	}
	return "—"
}

str_array :: proc(v: []string) -> ^kit.Json {
	a := kit.jarr()
	for s in v {
		kit.jpush(a, kit.jstr(s))
	}
	return a
}

ellipsis :: proc(s: string, n: int, allocator := context.temp_allocator) -> string {
	if len(s) <= n {
		return s
	}
	cut := n - 1
	for cut > 0 && (s[cut] & 0xC0) == 0x80 {
		cut -= 1
	}
	return strings.clone(tfmt("%s…", s[:cut]), allocator)
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

// open_store is the one place a command gets at the files, so --identity is
// honoured identically everywhere and nothing can read a different scope by
// accident.
open_store :: proc(c: ^kit.Call) -> Store {
	return store_open(c.identity)
}

cmd_ready :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	g := graph_build(&st)
	defer graph_free(&g)

	if len(g.cycle) > 0 {
		kit.cli_err_field(c, "cycle", cycle_text(g.cycle))
		return kit.cli_failf(
			c,
			kit.EXIT_FAILED,
			"the graph has a cycle, so nothing can be called ready: %s",
			cycle_text(g.cycle),
		)
	}

	want_assignee := kit.cli_str(c, "assignee")
	want_label := kit.cli_str(c, "label")
	limit := kit.cli_int(c, "limit", 0)

	arr := kit.jarr()
	rows := kit.jarr()
	n := 0
	// Shallowest first: an issue nothing waits on is less urgent than one
	// with a queue behind it, so within equal depth the one with the most
	// dependants comes first.
	order := ready_order(&st, &g)
	for i in order {
		it := &st.issues[i]
		if !g.ready[i] {
			continue
		}
		if want_assignee != "" && it.assignee != want_assignee {
			continue
		}
		if want_label != "" && !has_label(it, want_label) {
			continue
		}
		if limit > 0 && n >= limit {
			break
		}
		kit.jpush(arr, issue_json(it, &g, i))
		kit.jpush(rows, ready_row(it, &g, i))
		n += 1
	}
	if c.json {
		kit.jset(c.out, "ready", arr)
		kit.jset_int(c.out, "count", n)
	} else {
		kit.jset(c.out, "ready", rows)
		kit.jset_int(c.out, "count", n)
	}
	return kit.EXIT_OK
}

ready_row :: proc(it: ^Issue, g: ^Graph, i: int) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", it.id)
	kit.jset_str(o, "state", it.state)
	kit.jset_str(o, "title", ellipsis(it.title, 52))
	kit.jset_int(o, "unblocks", len(g.dependants[i]))
	kit.jset_str(o, "verify", verdict_short(it))
	kit.jset_str(o, "assignee", it.assignee == "" ? "—" : it.assignee)
	return o
}

// ready_order sorts the ready set by how much it unblocks, descending, then
// by id. "What should I do next" is better answered by the thing that frees
// the most work than by whatever sorts first.
ready_order :: proc(st: ^Store, g: ^Graph) -> []int {
	idx := make([dynamic]int, 0, len(st.issues), context.temp_allocator)
	for i in 0 ..< len(st.issues) {
		append(&idx, i)
	}
	for a in 1 ..< len(idx) {
		j := a
		for j > 0 {
			x, y := idx[j], idx[j - 1]
			better := len(g.dependants[x]) > len(g.dependants[y])
			same := len(g.dependants[x]) == len(g.dependants[y])
			if better || (same && id_less(g.ids[x], g.ids[y])) {
				idx[j], idx[j - 1] = idx[j - 1], idx[j]
				j -= 1
			} else {
				break
			}
		}
	}
	return idx[:]
}

has_label :: proc(it: ^Issue, want: string) -> bool {
	for l in it.labels {
		if strings.equal_fold(l, want) {
			return true
		}
	}
	return false
}

cmd_list :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	g := graph_build(&st)
	defer graph_free(&g)

	want_state := kit.cli_str(c, "state")
	want_label := kit.cli_str(c, "label")
	want_project := kit.cli_str(c, "project")
	want_assignee := kit.cli_str(c, "assignee")
	only_blocked := kit.cli_bool(c, "blocked")
	only_open := kit.cli_bool(c, "open")

	arr := kit.jarr()
	rows := kit.jarr()
	n := 0
	for &it, i in st.issues {
		if want_state != "" && it.state != want_state {
			continue
		}
		if want_label != "" && !has_label(&it, want_label) {
			continue
		}
		if want_project != "" && !strings.equal_fold(it.project, want_project) {
			continue
		}
		if want_assignee != "" && it.assignee != want_assignee {
			continue
		}
		if only_open && g.closed[i] {
			continue
		}
		if only_blocked && (g.ready[i] || g.closed[i]) {
			continue
		}
		kit.jpush(arr, issue_json(&it, &g, i))
		kit.jpush(rows, issue_row(&it, &g, i))
		n += 1
	}
	kit.jset(c.out, "issues", c.json ? arr : rows)
	kit.jset_int(c.out, "count", n)
	return kit.EXIT_OK
}

cmd_show :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	id := kit.cli_str(c, "id")
	it := store_find(&st, id)
	if it == nil {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no issue %q in %s", id, st.scope.dir)
	}
	g := graph_build(&st)
	defer graph_free(&g)
	i := g.index[it.id]

	kit.jset_str(c.out, "id", it.id)
	kit.jset_str(c.out, "title", it.title)
	kit.jset_str(c.out, "state", it.state)
	kit.jset_str(c.out, "project", it.project)
	kit.jset_str(c.out, "assignee", it.assignee)
	kit.jset(c.out, "labels", str_array(it.labels))
	kit.jset(c.out, "deps", str_array(it.deps))
	kit.jset(c.out, "blockers", str_array(graph_blockers(&g, i)))
	deps_of := make([dynamic]string, context.temp_allocator)
	for d in g.dependants[i] {
		append(&deps_of, g.ids[d])
	}
	kit.jset(c.out, "dependants", str_array(deps_of[:]))
	kit.jset_bool(c.out, "ready", g.ready[i])
	kit.jset_int(c.out, "depth", g.depth[i])
	kit.jset_str(c.out, "verification", verdict_name(it.verdict))
	kit.jset_str(c.out, "verify", it.verify)
	kit.jset_str(c.out, "verified_at", it.checked)
	kit.jset_str(c.out, "body", it.body)
	kit.jset_str(c.out, "prompt", it.prompt)
	kit.jset_str(c.out, "path", it.path)
	return kit.EXIT_OK
}

cmd_prompt :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	id := kit.cli_str(c, "id")
	it := store_find(&st, id)
	if it == nil {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no issue %q", id)
	}
	if it.prompt == "" {
		kit.cli_err_field(c, "id", it.id)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s carries no prompt", it.id)
	}
	// `--bare` prints the brief and nothing else, on stdout, so it can be
	// piped straight into whatever is being handed the work. Everything the
	// convention would otherwise add is suppressed rather than tolerated:
	// an agent brief with a table header on top of it is a different brief.
	if kit.cli_bool(c, "bare") && !c.json {
		fmt.println(it.prompt)
		return kit.EXIT_OK
	}
	kit.jset_str(c.out, "id", it.id)
	kit.jset_str(c.out, "title", it.title)
	kit.jset_str(c.out, "prompt", it.prompt)
	kit.jset_bool(c.out, "has_prompt", true)
	return kit.EXIT_OK
}

read_prompt_arg :: proc(c: ^kit.Call) -> (text: string, ok: bool, given: bool) {
	if kit.cli_has(c, "prompt") {
		return kit.cli_str(c, "prompt"), true, true
	}
	path := kit.cli_str(c, "prompt-file")
	if path == "" {
		return "", true, false
	}
	if path == "-" {
		data, err := os.read_entire_file_from_file(os.stdin, context.temp_allocator)
		if err != nil {
			return "", false, true
		}
		return string(data), true, true
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "", false, true
	}
	return string(data), true, true
}

cmd_new :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)

	title := kit.cli_str(c, "title")
	id := kit.cli_str(c, "id")
	if id == "" {
		id = next_id(&st, kit.cli_str(c, "prefix"), context.temp_allocator)
	}
	if !id_ok(id) {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a usable id", id)
	}
	if store_find(&st, id) != nil {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s already exists", id)
	}
	state := kit.cli_str(c, "state")
	if state == "" {
		state = st.states[0].name
	}
	if !state_known(st.states, state) {
		kit.cli_err_field(c, "state", state)
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not one of the configured states", state)
	}
	deps := split_list(kit.cli_str(c, "dep"), context.temp_allocator)
	for d in deps {
		if store_find(&st, d) == nil {
			kit.cli_err_field(c, "dep", d)
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot depend on %q, which does not exist", d)
		}
	}
	prompt_text, read_ok, _ := read_prompt_arg(c)
	if !read_ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", kit.cli_str(c, "prompt-file"))
	}

	stamp := now_stamp(context.temp_allocator)
	it := Issue {
		id       = id,
		title    = title,
		state    = state,
		project  = kit.cli_str(c, "project"),
		assignee = kit.cli_str(c, "assignee"),
		labels   = split_list(kit.cli_str(c, "label"), context.temp_allocator),
		deps     = deps,
		verify   = kit.cli_str(c, "verify"),
		body     = kit.cli_str(c, "body"),
		prompt   = strings.trim_space(prompt_text),
		created  = stamp,
		updated  = stamp,
	}
	// Creating an issue that already depends on something cannot close a
	// loop — nothing points at it yet — but check anyway, because a future
	// --id reusing a live id would make it possible and a refusal that only
	// holds by accident is not a refusal.
	for d in deps {
		if cyc, yes := would_cycle(&st, id, d); yes {
			kit.cli_err_field(c, "cycle", cycle_text(cyc))
			return kit.cli_failf(c, kit.EXIT_FAILED, "that would make a cycle: %s", cycle_text(cyc))
		}
	}

	path := tfmt("%s/%s-%s.md", st.scope.dir, id, slug(title))
	if c.dry_run {
		kit.jset_str(c.out, "id", id)
		kit.jset_str(c.out, "path", path)
		kit.jset_bool(c.out, "created", false)
		return kit.EXIT_OK
	}
	it.path = strings.clone(path, context.temp_allocator)
	if !issue_save(&st, &it) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", it.path)
	}
	kit.jset_str(c.out, "id", id)
	kit.jset_str(c.out, "path", it.path)
	kit.jset_bool(c.out, "created", true)
	return kit.EXIT_OK
}

cmd_set :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	id := kit.cli_str(c, "id")
	it := store_find(&st, id)
	if it == nil {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no issue %q", id)
	}
	changed := make([dynamic]string, context.temp_allocator)

	if kit.cli_has(c, "state") {
		v := kit.cli_str(c, "state")
		if !state_known(st.states, v) {
			kit.cli_err_field(c, "state", v)
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not one of the configured states", v)
		}
		it.state = strings.clone(v)
		append(&changed, "state")
	}
	if kit.cli_has(c, "title") {
		it.title = strings.clone(kit.cli_str(c, "title"))
		append(&changed, "title")
	}
	if kit.cli_has(c, "project") {
		it.project = strings.clone(kit.cli_str(c, "project"))
		append(&changed, "project")
	}
	if kit.cli_has(c, "assignee") {
		it.assignee = strings.clone(kit.cli_str(c, "assignee"))
		append(&changed, "assignee")
	}
	if kit.cli_has(c, "verify") {
		v := kit.cli_str(c, "verify")
		it.verify = strings.clone(v)
		// A new command invalidates the old verdict. Keeping it would be the
		// exact failure this feature exists to prevent: a confident answer
		// about a question nobody asked.
		it.verdict = .Unverified
		it.checked = ""
		append(&changed, "verify")
	}
	if kit.cli_has(c, "label") {
		it.labels = split_list(kit.cli_str(c, "label"))
		append(&changed, "labels")
	}
	if kit.cli_has(c, "body") {
		it.body = strings.clone(kit.cli_str(c, "body"))
		append(&changed, "body")
	}
	if text, ok, given := read_prompt_arg(c); given {
		if !ok {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", kit.cli_str(c, "prompt-file"))
		}
		it.prompt = strings.clone(strings.trim_space(text))
		append(&changed, "prompt")
	}

	if len(changed) == 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "nothing to change")
	}
	it.updated = now_stamp(context.allocator)
	if !c.dry_run && !issue_save(&st, it) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", it.path)
	}
	kit.jset_str(c.out, "id", it.id)
	kit.jset(c.out, "changed", str_array(changed[:]))
	return kit.EXIT_OK
}

cmd_dep :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	id := kit.cli_str(c, "id")
	on := kit.cli_str(c, "on")
	it := store_find(&st, id)
	if it == nil {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no issue %q", id)
	}
	remove := kit.cli_bool(c, "remove")
	if !remove && store_find(&st, on) == nil {
		kit.cli_err_field(c, "on", on)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no issue %q to depend on", on)
	}

	next := make([dynamic]string, context.temp_allocator)
	present := false
	for d in it.deps {
		if d == on {
			present = true
			if remove {
				continue
			}
		}
		append(&next, d)
	}
	if !remove {
		if !present {
			// THE REFUSAL. A dependency that closes a loop describes work
			// that can never start, so it is rejected before anything is
			// written rather than written and complained about later.
			if cyc, yes := would_cycle(&st, it.id, on); yes {
				kit.cli_err_field(c, "cycle", cycle_text(cyc))
				kit.cli_err_field(c, "from", it.id)
				kit.cli_err_field(c, "to", on)
				return kit.cli_failf(
					c,
					kit.EXIT_FAILED,
					"refusing: %s would depend on %s, closing the cycle %s",
					it.id,
					on,
					cycle_text(cyc),
				)
			}
			append(&next, on)
		}
	} else if !present {
		kit.cli_err_field(c, "on", on)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not depend on %s", it.id, on)
	}

	// Heap, not temp: this issue belongs to the store, which frees it.
	owned := make([]string, len(next))
	for d, k in next {
		owned[k] = strings.clone(d)
	}
	it.deps = owned
	it.updated = now_stamp(context.allocator)
	if !c.dry_run && !issue_save(&st, it) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", it.path)
	}
	kit.jset_str(c.out, "id", it.id)
	kit.jset(c.out, "deps", str_array(it.deps))
	return kit.EXIT_OK
}

cmd_rm :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	id := kit.cli_str(c, "id")
	it := store_find(&st, id)
	if it == nil {
		kit.cli_err_field(c, "id", id)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no issue %q", id)
	}
	// Who was waiting for this. Deleting an issue quietly unblocks everything
	// that depended on it, which would be the tracker changing its mind about
	// reality without telling anybody, so the dangling edges are named.
	orphaned := make([dynamic]string, context.temp_allocator)
	for other in st.issues {
		if other.id == it.id {
			continue
		}
		for d in other.deps {
			if d == it.id {
				append(&orphaned, other.id)
			}
		}
	}
	path := strings.clone(it.path, context.temp_allocator)
	if !c.dry_run {
		if err := os.remove(path); err != nil {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot remove %s: %v", path, err)
		}
	}
	kit.jset_str(c.out, "id", id)
	kit.jset_str(c.out, "path", path)
	kit.jset(c.out, "orphaned", str_array(orphaned[:]))
	return kit.EXIT_OK
}

cmd_graph :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	g := graph_build(&st)
	defer graph_free(&g)
	only_open := kit.cli_bool(c, "open")

	if c.json {
		layers := kit.jarr()
		maxd := 0
		for i in 0 ..< len(st.issues) {
			if g.depth[i] > maxd {
				maxd = g.depth[i]
			}
		}
		for d in 0 ..= maxd {
			issues := kit.jarr()
			any := false
			for &it, i in st.issues {
				if g.depth[i] != d {
					continue
				}
				if only_open && g.closed[i] {
					continue
				}
				kit.jpush(issues, issue_json(&it, &g, i))
				any = true
			}
			if !any {
				continue
			}
			lo := kit.jobj()
			kit.jset_int(lo, "depth", d)
			kit.jset(lo, "issues", issues)
			kit.jpush(layers, lo)
		}
		kit.jset(c.out, "layers", layers)
		edges := kit.jarr()
		for &it, i in st.issues {
			for d in g.deps[i] {
				if only_open && g.closed[i] && g.closed[d] {
					continue
				}
				e := kit.jobj()
				kit.jset_str(e, "from", it.id)
				kit.jset_str(e, "to", g.ids[d])
				kit.jpush(edges, e)
			}
		}
		kit.jset(c.out, "edges", edges)
		kit.jset(c.out, "cycle", str_array(g.cycle))
		return kit.EXIT_OK
	}

	// The human rendering is the same layering the window draws, in text: one
	// column per depth, the arrows written out. It is not a picture, and it
	// does not pretend to be — `track shots` draws the picture.
	sb := strings.builder_make(context.temp_allocator)
	if len(g.cycle) > 0 {
		strings.write_string(&sb, tfmt("CYCLE: %s\n\n", cycle_text(g.cycle)))
	}
	maxd := 0
	for i in 0 ..< len(st.issues) {
		if g.depth[i] > maxd {maxd = g.depth[i]}
	}
	for d in 0 ..= maxd {
		head := d == 0 ? "unblocked now" : tfmt("after %d", d)
		wrote := false
		for &it, i in st.issues {
			if g.depth[i] != d {
				continue
			}
			if only_open && g.closed[i] {
				continue
			}
			if !wrote {
				strings.write_string(&sb, tfmt("\n%s\n", head))
				wrote = true
			}
			mark := g.ready[i] ? "*" : " "
			if g.closed[i] {
				mark = "x"
			}
			strings.write_string(&sb, tfmt("  %s %-6s %-46s", mark, it.id, ellipsis(it.title, 46)))
			if len(g.deps[i]) > 0 {
				ids := make([dynamic]string, context.temp_allocator)
				for e in g.deps[i] {
					append(&ids, g.ids[e])
				}
				strings.write_string(&sb, tfmt("  <- %s", strings.join(ids[:], " ", context.temp_allocator)))
			}
			strings.write_byte(&sb, '\n')
		}
	}
	strings.write_string(&sb, "\n  * unblocked   x closed   <- waits for\n")
	kit.jset_str(c.out, "graph", strings.to_string(sb))
	return kit.EXIT_OK
}

cmd_board :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	g := graph_build(&st)
	defer graph_free(&g)
	want_project := kit.cli_str(c, "project")

	cols := kit.jarr()
	for s in st.states {
		issues := kit.jarr()
		n := 0
		for &it, i in st.issues {
			if it.state != s.name {
				continue
			}
			if want_project != "" && !strings.equal_fold(it.project, want_project) {
				continue
			}
			kit.jpush(issues, c.json ? issue_json(&it, &g, i) : issue_row(&it, &g, i))
			n += 1
		}
		co := kit.jobj()
		kit.jset_str(co, "state", s.name)
		kit.jset_bool(co, "closed", s.closed)
		kit.jset_int(co, "count", n)
		kit.jset(co, "issues", issues)
		kit.jpush(cols, co)
	}
	kit.jset(c.out, "columns", cols)
	return kit.EXIT_OK
}

// cmd_stale is the one command that can execute anything. Read verify.odin's
// header before changing it.
cmd_stale :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)

	run := kit.cli_bool(c, "run")
	only := kit.cli_str(c, "only")
	no_write := kit.cli_bool(c, "no-write")
	show_all := kit.cli_bool(c, "all")

	// --dry-run is not a way to half-execute. A mutating command's --dry-run
	// says what it would do, and what this would do is run commands, so
	// --dry-run turns execution off rather than on.
	if c.dry_run {
		run = false
	}

	cwd := st.scope.root
	if cwd == "" {
		wd, werr := os.get_working_directory(context.temp_allocator)
		cwd = werr == nil ? wd : "."
	}

	if run {
		// The banner is part of the gate: anyone reading a transcript sees
		// where the commands came from and where they ran, before the first
		// one is spawned.
		fmt.eprintfln(
			"[track] --run given: executing verification commands from %s, with %s as the working directory",
			st.scope.dir,
			cwd,
		)
	}

	arr := kit.jarr()
	rows := kit.jarr()
	n_true, n_stale, n_unver := 0, 0, 0
	executed := false

	for &it in st.issues {
		if only != "" && !strings.equal_fold(it.id, only) {
			continue
		}
		if it.verify == "" && !show_all {
			if it.verify == "" {
				n_unver += 1
			}
			continue
		}
		r := verify_run(&it, cwd, run)
		if r.ran {
			executed = true
			if !no_write {
				verify_apply(&it, r)
				if !issue_save(&st, &it) {
					fmt.eprintfln("[track] %s: could not record the verdict in %s", it.id, it.path)
				}
			} else {
				it.verdict = r.verdict
			}
		}
		switch it.verdict {
		case .True:
			n_true += 1
		case .Stale:
			n_stale += 1
		case .Unverified:
			n_unver += 1
		}

		o := kit.jobj()
		kit.jset_str(o, "id", it.id)
		kit.jset_str(o, "title", it.title)
		kit.jset_str(o, "verification", verdict_name(it.verdict))
		kit.jset_str(o, "command", it.verify)
		kit.jset_bool(o, "ran", r.ran)
		if r.ran {
			kit.jset_int(o, "exit", r.code)
		}
		note := r.refused
		if r.ran && r.output != "" {
			note = r.output
		}
		if note != "" {
			kit.jset_str(o, "note", note)
		}
		kit.jpush(arr, o)

		row := kit.jobj()
		kit.jset_str(row, "id", it.id)
		kit.jset_str(row, "verdict", verdict_name(it.verdict))
		kit.jset_str(row, "title", ellipsis(it.title, 40))
		kit.jset_str(row, "command", ellipsis(it.verify == "" ? "—" : it.verify, 58))
		kit.jpush(rows, row)
	}

	kit.jset(c.out, "issues", c.json ? arr : rows)
	kit.jset_int(c.out, "verified_true", n_true)
	kit.jset_int(c.out, "verified_stale", n_stale)
	kit.jset_int(c.out, "unverified", n_unver)
	kit.jset_bool(c.out, "executed", executed)
	if !run {
		kit.jset_str(
			c.out,
			"note",
			"nothing was executed; `track stale --run` would run the commands above",
		)
	}
	return kit.EXIT_OK
}

cmd_check :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	g := graph_build(&st)
	defer graph_free(&g)

	problems := kit.jarr()
	add :: proc(a: ^kit.Json, kind, id, detail: string) {
		o := kit.jobj()
		kit.jset_str(o, "kind", kind)
		kit.jset_str(o, "id", id)
		kit.jset_str(o, "detail", detail)
		kit.jpush(a, o)
	}
	if len(g.cycle) > 0 {
		add(problems, "cycle", g.cycle[0], cycle_text(g.cycle))
	}
	seen := make(map[string]int, len(st.issues), context.temp_allocator)
	for &it, i in st.issues {
		if prev, dup := seen[it.id]; dup {
			add(problems, "duplicate id", it.id, tfmt("also in %s", st.issues[prev].path))
		} else {
			seen[it.id] = i
		}
		for m in g.missing[i] {
			add(problems, "dangling dependency", it.id, tfmt("depends on %q, which does not exist", m))
		}
		if !state_known(st.states, it.state) {
			add(problems, "unknown state", it.id, tfmt("%q is not in %s", it.state, STATES_FILE))
		}
		if why := verify_forbidden(it.verify); why != "" {
			add(problems, "refused verification", it.id, why)
		}
	}
	kit.jset_bool(c.out, "ok", kit.jlen(problems) == 0)
	kit.jset(c.out, "problems", problems)
	if kit.jlen(problems) > 0 {
		// A broken graph is a failure, not a report: a caller that checks the
		// exit code should not have to parse the body to find out.
		kit.cli_err_field(c, "problems", tfmt("%d", kit.jlen(problems)))
		if c.json {
			fmt.println(kit.json_text(c.out, 2, context.temp_allocator))
			return kit.EXIT_FAILED
		}
		return kit.cli_failf(c, kit.EXIT_FAILED, "%d problem(s)", kit.jlen(problems))
	}
	return kit.EXIT_OK
}

cmd_import :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	src := kit.cli_str(c, "file")
	data, err := os.read_entire_file_from_path(src, context.temp_allocator)
	if err != nil {
		kit.cli_err_field(c, "file", src)
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", src)
	}
	issues, stats := import_todo(string(data), st.states)
	defer {
		for &it in issues {
			issue_free(&it)
		}
		delete(issues)
	}
	if kit.cli_bool(c, "link-refs") {
		stats.links = import_links(&issues)
	}

	overwrite := kit.cli_bool(c, "overwrite")
	written, skipped, with_verify := 0, 0, 0
	ids := make([dynamic]string, context.temp_allocator)
	for &it in issues {
		if it.verify != "" {
			with_verify += 1
		}
		if existing := store_find(&st, it.id); existing != nil && !overwrite {
			skipped += 1
			continue
		} else if existing != nil {
			// The document is authoritative for what it can express — title,
			// body, prompt, project, labels — and the file keeps everything
			// it cannot. Re-importing must not wipe a verification somebody
			// added by hand, move an issue back out of `doing`, or reset the
			// creation date that makes `git log` on the file read as that
			// issue's history.
			it.path = strings.clone(existing.path)
			it.created = strings.clone(existing.created)
			it.state = strings.clone(existing.state)
			it.assignee = strings.clone(existing.assignee)
			it.verify = strings.clone(existing.verify)
			it.verdict = existing.verdict
			it.checked = strings.clone(existing.checked)
			// Dependencies are an assertion about the world that this
			// document barely makes, so a locally drawn edge survives:
			// the union of what was there and what the document says.
			merged := make([dynamic]string, 0, len(existing.deps) + len(it.deps))
			for d in existing.deps {
				append(&merged, strings.clone(d))
			}
			for d in it.deps {
				dup := false
				for m in merged {
					if m == d {
						dup = true
					}
				}
				if !dup {
					append(&merged, strings.clone(d))
				}
			}
			for d in it.deps {
				dfree(d)
			}
			delete(it.deps)
			it.deps = merged[:]
			if it.updated == "" {
				it.updated = strings.clone(existing.updated)
			}
		}
		append(&ids, it.id)
		if c.dry_run {
			written += 1
			continue
		}
		if !issue_save(&st, &it) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", it.id)
		}
		written += 1
	}

	kit.jset_str(c.out, "source", src)
	kit.jset_str(c.out, "dir", st.scope.dir)
	kit.jset_int(c.out, "written", written)
	kit.jset_int(c.out, "skipped_existing", skipped)
	kit.jset_int(c.out, "projects", stats.projects)
	kit.jset_int(c.out, "issues", stats.issues)
	kit.jset_int(c.out, "prompts", stats.prompts)
	kit.jset_int(c.out, "wontfix", stats.wontfix)
	kit.jset_int(c.out, "links", stats.links)
	kit.jset_int(c.out, "with_verify", with_verify)
	kit.jset(c.out, "ids", str_array(ids[:]))
	// Said out loud rather than left to be noticed: import reads a data file
	// that may carry commands, and writes them down without running any.
	if with_verify > 0 {
		kit.cli_note(
			c,
			"[track] %d imported issue(s) declare a verification. None was executed; `track stale` lists them.",
			with_verify,
		)
	}
	return kit.EXIT_OK
}

cmd_states :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	kit.jset_str(c.out, "file", tfmt("%s/%s", st.scope.dir, STATES_FILE))
	a := kit.jarr()
	for s in st.states {
		o := kit.jobj()
		kit.jset_str(o, "name", s.name)
		kit.jset_bool(o, "closed", s.closed)
		kit.jpush(a, o)
	}
	kit.jset(c.out, "states", a)
	return kit.EXIT_OK
}

cmd_where :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	kit.jset_str(c.out, "dir", st.scope.dir)
	kit.jset_str(c.out, "scope", st.scope.kind)
	kit.jset_str(c.out, "identity", st.scope.identity)
	kit.jset_bool(c.out, "exists", os.is_dir(st.scope.dir))
	kit.jset_int(c.out, "issues", len(st.issues))
	return kit.EXIT_OK
}

cmd_init :: proc(c: ^kit.Call) -> int {
	st := open_store(c)
	defer store_free(&st)
	existed := os.is_dir(st.scope.dir)
	if !c.dry_run && !scope_ensure(&st.scope) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot create %s", st.scope.dir)
	}
	kit.jset_str(c.out, "dir", st.scope.dir)
	kit.jset_bool(c.out, "created", !existed)
	return kit.EXIT_OK
}

cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	n := shots(dir, c.identity)
	kit.jset_int(c.out, "written", n)
	kit.jset_str(c.out, "dir", dir)
	return n > 0 ? kit.EXIT_OK : kit.cli_fail(c, kit.EXIT_FAILED, "nothing written")
}

// A compile-time nudge: `p` is used by the window and the shots. Keeping the
// import here rather than only in ui.odin means a build that drops the GUI
// still fails loudly instead of silently shipping a CLI-only binary.
_ :: p
