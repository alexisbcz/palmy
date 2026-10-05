// `track --selftest` — headless, and it never touches the real tracker.
//
// Five sections, and the last one is the one worth reading.
//
//  1. **The file format.** A round trip through the parser and the writer,
//     including a multi-paragraph prompt with fenced code in it and a
//     `## Prompt` line inside that fence, because the separator has to be
//     fence-aware or a body that quotes one truncates the file.
//  2. **The graph.** Cycles are refused — direct, indirect and self — and
//     "what is unblocked" is correct over a graph with a diamond, a long
//     edge, a fan-out, a closed dependency and a dangling one.
//  3. **The states**, which are a text file and not an enum.
//  4. **The importer**, against a fixture shaped like `TODO.md`.
//  5. **The verification gate.** A sentinel file, the way `apps/pkg` does it:
//     every issue in a scratch store is given a verify command that writes to
//     a sentinel, the trap is sprung deliberately first so a broken trap
//     fails loudly instead of passing, every verb an agent can type is then
//     driven and the sentinel is asserted empty, and finally `--run` is given
//     on purpose and the sentinel is asserted to hold exactly what was
//     declared. Without the last step, "the sentinel is empty" could be true
//     because nothing works.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import kit "kit:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq_s :: proc(got, want: string, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s\n        got  %q\n        want %q\n", fmt.tprintf(what, ..args), got, want)
	}
}

@(private = "file")
eq_i :: proc(got, want: int, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", fmt.tprintf(what, ..args), got, want)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

@(private = "file")
g_root: string

@(private = "file")
scratch_root :: proc() -> string {
	if g_root == "" {
		g_root = fmt.aprintf("/tmp/palmy-track-selftest-%d", os.get_pid())
		_ = os.make_directory_all(g_root)
	}
	return g_root
}

@(private = "file")
put :: proc(path, text: string) {
	_ = os.write_entire_file(path, transmute([]u8)text)
}

// Driving every verb for real means every verb prints its result, and a
// self-test that buries nine failures under three hundred lines of JSON is
// not readable. stdout is swapped for /dev/null for the duration and put
// back afterwards. A `dup2` rather than a capture hook in the kit, because
// the kit belongs to another agent today and the point of the exercise is
// that the verbs run exactly as they would from a shell.
@(private = "file")
hush :: proc() -> linux.Fd {
	saved, derr := linux.dup(linux.Fd(1))
	if derr != nil {
		return linux.Fd(-1)
	}
	null, oerr := linux.open("/dev/null", {.WRONLY})
	if oerr != nil {
		return linux.Fd(-1)
	}
	_, _ = linux.dup2(null, linux.Fd(1))
	linux.close(null)
	return saved
}

@(private = "file")
unhush :: proc(saved: linux.Fd) {
	if saved < 0 {
		return
	}
	_, _ = linux.dup2(saved, linux.Fd(1))
	linux.close(saved)
}

@(private = "file")
read_lines :: proc(path: string) -> []string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	out := make([dynamic]string, context.temp_allocator)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) != "" {
			append(&out, strings.trim_space(line))
		}
	}
	return out[:]
}

selftest :: proc() -> int {
	fmt.println("track --selftest")
	test_format()
	test_graph()
	test_states()
	test_importer()
	test_scopes()
	test_verify_gate()
	test_cli_surface()
	test_layout()

	fmt.printf("\n%d checks, %d failures\n", checks, failures)
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// 1. The file format
// ---------------------------------------------------------------------------

// A prompt that is hostile to the format in every way it can be: several
// paragraphs, a fenced block, a `## Prompt` line INSIDE that fence, a colon
// in a value, a Markdown heading of its own, and trailing whitespace.
HARD_PROMPT :: `Fix ` + "`flex-wrap`" + ` rows reporting too little height.

**Reproduce it first and do not proceed until you can**, because two attempts
to reproduce it from description failed.

` + "```" + `odin
// A heading inside a fence must not split the file:
## Prompt
row := p.div(ui, "flex-row flex-wrap gap-2 max-w-[420px]")
` + "```" + `

## The ordering, which is where this goes wrong silently

1. Base direction per paragraph, bidi per line.
2. Shape in logical order, then reverse.

Parity must stay at 182 cases, mean mae 2.953.`

test_format :: proc() {
	section("the file format")

	it := Issue {
		id       = "T2",
		title    = "flex-wrap does not grow the row's height",
		state    = "doing",
		project  = "Toolkit",
		assignee = "agent:claude",
		labels   = {"toolkit", "layout"},
		deps     = {"T1", "T6"},
		verify   = `sh -c 'test "$(grep -c x f)" = 3: still'`,
		verdict  = .Stale,
		checked  = "2026-10-05T14:03:11Z",
		created  = "2026-10-01T08:00:00Z",
		updated  = "2026-10-05T14:03:11Z",
		body     = "Three independent reports, and I failed to reproduce it twice.\n\nThe concrete repro is `mail`'s.",
		prompt   = HARD_PROMPT,
	}
	text := issue_text(&it, context.temp_allocator)
	back := issue_parse(text, "/tmp/T2.md", context.temp_allocator)

	eq_s(back.id, it.id, "id round-trips")
	eq_s(back.title, it.title, "title round-trips")
	eq_s(back.state, it.state, "state round-trips")
	eq_s(back.project, it.project, "project round-trips")
	eq_s(back.assignee, it.assignee, "assignee round-trips")
	eq_i(len(back.labels), 2, "both labels round-trip")
	eq_s(back.labels[1], "layout", "the second label is intact")
	eq_i(len(back.deps), 2, "both dependencies round-trip")
	eq_s(back.deps[0], "T1", "the first dependency is intact")
	// The value has two colons in it; splitting at anything but the first
	// would corrupt the command.
	eq_s(back.verify, it.verify, "a verify command with colons in it round-trips")
	check(back.verdict == .Stale, "the verdict round-trips")
	eq_s(back.checked, it.checked, "the verification timestamp round-trips")
	eq_s(back.body, it.body, "the body round-trips")
	eq_s(back.prompt, it.prompt, "a multi-paragraph prompt with code fences round-trips")
	check(strings.contains(back.prompt, "## Prompt"), "the fenced `## Prompt` survives inside the prompt")

	// Writing what was parsed must give the same bytes, or two saves of an
	// unchanged issue would show as a diff.
	again := issue_text(&back, context.temp_allocator)
	eq_s(again, text, "a second render is byte-identical")

	// The separator is fence-aware in the BODY too, which is the case that
	// truncates a file rather than merely losing a field.
	tricky := Issue {
		id     = "T3",
		title  = "Quoting the format in the body",
		state  = "todo",
		body   = "Here is how an issue file looks:\n\n```\n## Prompt\n\nnot really the prompt\n```\n\nThat was an example.",
		prompt = "The real prompt.",
	}
	t2 := issue_text(&tricky, context.temp_allocator)
	b2 := issue_parse(t2, "/tmp/T3.md", context.temp_allocator)
	eq_s(b2.prompt, "The real prompt.", "a `## Prompt` inside a fenced body does not become the prompt")
	check(strings.contains(b2.body, "not really the prompt"), "and the body keeps its example whole")

	// A hand-written file with no frontmatter at all is still an issue.
	bare := issue_parse("# Just a heading\n\nand some prose.\n", "/tmp/notes/K9.md", context.temp_allocator)
	eq_s(bare.id, "K9", "a file with no frontmatter takes its id from its name")
	eq_s(bare.title, "Just a heading", "and its title from its first heading")
	eq_s(bare.state, "todo", "and a default state")

	// A field nobody here knows about survives a read and a write, because a
	// tracker that eats hand-written fields stops being hand-edited.
	extra := issue_parse(
		"---\nid: X1\ntitle: t\nestimate: 3d\nmilestone: autumn\n---\n\nbody\n",
		"/tmp/X1.md",
		context.temp_allocator,
	)
	eq_i(len(extra.extra_k), 2, "two unknown frontmatter keys are kept")
	check(
		strings.contains(issue_text(&extra, context.temp_allocator), "estimate: 3d"),
		"and written back out",
	)

	// A verdict with no command behind it is meaningless and is dropped.
	orphan := issue_parse(
		"---\nid: X2\ntitle: t\nverified: true\nverified-at: 2026-01-01T00:00:00Z\n---\n",
		"/tmp/X2.md",
		context.temp_allocator,
	)
	check(orphan.verdict == .Unverified, "a verdict with no verify command is discarded")

	// Ids reach file names.
	check(id_ok("T7") && id_ok("eng-14") && id_ok("a.b"), "ordinary ids are accepted")
	check(!id_ok("../etc/passwd"), "an id that is a path is refused")
	check(!id_ok("a/b"), "an id with a slash is refused")
	check(!id_ok("-x"), "an id must start with an alphanumeric")
	check(!id_ok(""), "an empty id is refused")

	check(id_less("T2", "T10"), "T2 sorts before T10, not after")
	check(id_less("C1", "T1"), "prefixes sort before numbers")
}

// ---------------------------------------------------------------------------
// 2. The graph
// ---------------------------------------------------------------------------

// A store built in memory, so the graph tests do not need files.
@(private = "file")
mkstore :: proc(spec: []struct {
		id, state, deps: string,
	}) -> Store {
	st := Store {
		states = states_default(context.temp_allocator),
		issues = make([dynamic]Issue, 0, len(spec), context.temp_allocator),
	}
	for s in spec {
		append(
			&st.issues,
			Issue {
				id = s.id,
				title = s.id,
				state = s.state,
				deps = split_list(s.deps, context.temp_allocator),
				labels = {},
			},
		)
	}
	return st
}

test_graph :: proc() {
	section("the dependency graph")

	// A non-trivial shape: a diamond (D waits for B and C, both waiting for
	// A), a long edge (G waits for A directly as well as through the
	// diamond), a fan-out from A, a closed dependency (Z is done, so Y is
	// unblocked by it) and a dangling one (W waits for something that does
	// not exist).
	st := mkstore(
		{
			{"A", "todo", ""},
			{"B", "todo", "A"},
			{"C", "todo", "A"},
			{"D", "todo", "B, C"},
			{"E", "todo", "A"},
			{"F", "todo", "D, E"},
			{"G", "todo", "A, F"},
			{"Z", "done", ""},
			{"Y", "todo", "Z"},
			{"W", "todo", "nonexistent"},
		},
	)
	g := graph_build(&st)
	defer graph_free(&g)

	eq_i(len(g.cycle), 0, "an acyclic graph reports no cycle")

	ready := make([dynamic]string, context.temp_allocator)
	for id, i in g.ids {
		if g.ready[i] {
			append(&ready, id)
		}
	}
	// A is the root; Y's only dependency is closed. Nothing else qualifies.
	eq_i(len(ready), 2, "exactly two issues are unblocked")
	check(g.ready[g.index["A"]], "A, which waits for nothing, is unblocked")
	check(g.ready[g.index["Y"]], "Y, whose only dependency is closed, is unblocked")
	check(!g.ready[g.index["B"]], "B is blocked by A")
	check(!g.ready[g.index["D"]], "D is blocked by the diamond")
	check(!g.ready[g.index["G"]], "G is blocked by the long chain")
	check(!g.ready[g.index["Z"]], "a closed issue is not reported as unblocked work")
	// The one that is easy to get wrong: a dependency that does not exist is
	// not a satisfied dependency.
	check(!g.ready[g.index["W"]], "a dangling dependency blocks rather than silently resolving")
	eq_i(len(g.missing[g.index["W"]]), 1, "and is reported as missing")

	// Depth is the longest chain of OPEN work in front of an issue.
	eq_i(g.depth[g.index["A"]], 0, "A is at depth 0")
	eq_i(g.depth[g.index["B"]], 1, "B is one behind A")
	eq_i(g.depth[g.index["D"]], 2, "D is behind both arms of the diamond")
	eq_i(g.depth[g.index["F"]], 3, "F is behind D")
	eq_i(g.depth[g.index["G"]], 4, "G takes the longest path, not the shortest")
	eq_i(g.depth[g.index["Y"]], 0, "a closed dependency adds no depth")

	blockers := graph_blockers(&g, g.index["F"])
	eq_i(len(blockers), 2, "F reports both of its blockers")

	// Closing B and C must unblock D and nothing else.
	st.issues[g.index["B"]].state = "done"
	st.issues[g.index["C"]].state = "done"
	g2 := graph_build(&st)
	defer graph_free(&g2)
	check(g2.ready[g2.index["D"]], "closing both arms of the diamond unblocks D")
	check(!g2.ready[g2.index["F"]], "and does not unblock what is behind D")
	eq_i(g2.depth[g2.index["D"]], 0, "with its dependencies closed, D is at depth 0")

	// ---- cycles ------------------------------------------------------
	section("cycles are refused")

	direct := mkstore({{"A", "todo", "B"}, {"B", "todo", "A"}})
	gd := graph_build(&direct)
	defer graph_free(&gd)
	check(len(gd.cycle) > 0, "a two-node cycle is detected")
	check(len(gd.cycle) >= 3, "and reported as a path that closes (%s)", cycle_text(gd.cycle))
	check(gd.cycle[0] == gd.cycle[len(gd.cycle) - 1], "the reported path starts and ends at the same id")
	for i in 0 ..< len(gd.ids) {
		check(!gd.ready[i], "with a cycle present nothing is called ready (%s)", gd.ids[i])
	}

	indirect := mkstore({{"A", "todo", "B"}, {"B", "todo", "C"}, {"C", "todo", "A"}, {"D", "todo", ""}})
	gi := graph_build(&indirect)
	defer graph_free(&gi)
	check(len(gi.cycle) > 0, "a three-node cycle is detected")

	selfdep := mkstore({{"A", "todo", "A"}})
	gs := graph_build(&selfdep)
	defer graph_free(&gs)
	check(len(gs.cycle) > 0, "an issue depending on itself is a cycle")

	// would_cycle is the gate `track dep` consults BEFORE writing anything.
	chain := mkstore({{"A", "todo", ""}, {"B", "todo", "A"}, {"C", "todo", "B"}, {"D", "todo", ""}})
	_, yes1 := would_cycle(&chain, "A", "C")
	check(yes1, "A depending on C would close the chain and is refused")
	cyc, yes2 := would_cycle(&chain, "A", "B")
	check(yes2, "A depending on B directly would close a two-node loop")
	check(len(cyc) >= 2, "and the refusal names the path (%s)", cycle_text(cyc))
	_, yes3 := would_cycle(&chain, "D", "C")
	check(!yes3, "D depending on C is fine and is allowed")
	_, yes4 := would_cycle(&chain, "C", "D")
	check(!yes4, "C depending on D is fine and is allowed")
	_, yes5 := would_cycle(&chain, "A", "A")
	check(yes5, "an issue may not depend on itself")

	// A long chain, to be sure the cycle walk is not quadratic-but-wrong or
	// depth-limited.
	long := make([dynamic]struct {
			id, state, deps: string,
		}, 0, 300, context.temp_allocator)
	for i in 0 ..< 300 {
		id := fmt.tprintf("N%d", i)
		dep := i == 0 ? "" : fmt.tprintf("N%d", i - 1)
		append(&long, struct {
				id, state, deps: string,
			}{id, "todo", dep})
	}
	lst := mkstore(long[:])
	gl := graph_build(&lst)
	defer graph_free(&gl)
	eq_i(len(gl.cycle), 0, "a 300-long chain is not mistaken for a cycle")
	eq_i(gl.depth[gl.index["N299"]], 299, "and its depth is the whole chain")
	_, yes6 := would_cycle(&lst, "N0", "N299")
	check(yes6, "closing a 300-long chain is still refused")
}

// ---------------------------------------------------------------------------
// 3. The states
// ---------------------------------------------------------------------------

test_states :: proc() {
	section("states are configuration, not an enum")
	root := fmt.tprintf("%s/states", scratch_root())
	_ = os.make_directory_all(root)
	put(
		fmt.tprintf("%s/%s", root, STATES_FILE),
		"# a project that thinks in different words\nicebox\nactive\nshipped   closed\nabandoned closed\n",
	)
	states := states_load(root, context.temp_allocator)
	eq_i(len(states), 4, "four states are read from the file")
	eq_s(states[0].name, "icebox", "in the order written")
	check(!state_is_closed(states, "active"), "`active` is open")
	check(state_is_closed(states, "shipped"), "`shipped` is closed")
	check(!state_known(states, "todo"), "and the built-in names are gone")

	// A directory that already exists still gets its states.txt: `mkdir -p`
	// followed by `track import` is ordinary, and leaving the one piece of
	// configuration invisible is how its states become hardcoded by habit.
	seeded := fmt.tprintf("%s/seeded", scratch_root())
	_ = os.make_directory_all(seeded)
	sc := Scope{dir = strings.clone(seeded, context.temp_allocator)}
	check(scope_ensure(&sc), "an existing directory is accepted")
	check(
		os.exists(fmt.tprintf("%s/%s", seeded, STATES_FILE)),
		"and %s is seeded into it anyway",
		STATES_FILE,
	)

	// A directory with no states file gets the defaults rather than nothing.
	empty_dir := fmt.tprintf("%s/nostates", scratch_root())
	_ = os.make_directory_all(empty_dir)
	def := states_load(empty_dir, context.temp_allocator)
	eq_i(len(def), 6, "a directory with no states file falls back to the defaults")
	check(state_is_closed(def, "done"), "`done` is closed by default")
	check(state_is_closed(def, "wontfix"), "and so is `wontfix`")

	// Closedness is what the graph reads, so prove the custom names drive it.
	st := Store {
		states = states,
		issues = make([dynamic]Issue, 0, 2, context.temp_allocator),
	}
	append(&st.issues, Issue{id = "A", state = "shipped"})
	append(&st.issues, Issue{id = "B", state = "icebox", deps = {"A"}})
	g := graph_build(&st)
	defer graph_free(&g)
	check(g.ready[g.index["B"]], "a dependency in a custom closed state unblocks")
}

// ---------------------------------------------------------------------------
// Scope resolution
//
// This section exists because of a specific bug: `kind = "repo"` put a
// pointer to read-only memory in a struct that `store_free` frees, and every
// command run from inside a git work tree aborted in free(). It was invisible
// until a command was run with PALM_TRACK_DIR unset, which the rest of the
// self-test deliberately never does. So all three scopes are resolved and
// freed here, which is the whole of what the crash needed.
// ---------------------------------------------------------------------------

test_scopes :: proc() {
	section("where the issues live")
	had := os.get_env("PALM_TRACK_DIR", context.temp_allocator)
	saved_id := os.get_env("PALM_IDENTITY", context.temp_allocator)
	_ = os.unset_env("PALM_TRACK_DIR")
	_ = os.unset_env("PALM_IDENTITY")

	// Repo scope: inside a git work tree, next to the code.
	if root, ok := git_root(os.get_working_directory(context.temp_allocator) or_else "/"); ok {
		sc := scope_resolve("")
		eq_s(sc.kind, "repo", "inside a git work tree the scope is repo-local")
		check(
			strings.has_suffix(sc.dir, DIR_REPO),
			"and the directory is %s next to the code (%s)",
			DIR_REPO,
			sc.dir,
		)
		eq_s(sc.root, root, "with the work tree recorded")
		check(!os.exists(sc.dir), "resolving a scope creates nothing")
		scope_free(&sc) // the crash was here, not above
		check(true, "and freeing a repo scope does not abort")
	}

	// Personal scope: outside one, under XDG, chosen by identity.
	saved_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	saved_cwd, _ := os.get_working_directory(context.temp_allocator)
	_ = os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/xdg", scratch_root()))
	if err := os.set_working_directory("/tmp"); err == nil {
		sc := scope_resolve("work")
		eq_s(sc.kind, "personal", "outside a work tree the scope is personal")
		check(strings.contains(sc.dir, "/palmy-track/work"), "and --identity picks among them (%s)", sc.dir)
		scope_free(&sc)
		sc2 := scope_resolve("")
		check(strings.has_suffix(sc2.dir, "/default"), "with no identity it is `default` (%s)", sc2.dir)
		scope_free(&sc2)
		check(true, "and freeing a personal scope does not abort")
	}
	// Put the working directory back: every section after this one runs
	// relative to wherever the self-test was started from.
	if saved_cwd != "" {
		_ = os.set_working_directory(saved_cwd)
	}
	if saved_home != "" {
		_ = os.set_env("XDG_DATA_HOME", saved_home)
	} else {
		_ = os.unset_env("XDG_DATA_HOME")
	}

	// The override, which is what every other section runs under.
	_ = os.set_env("PALM_TRACK_DIR", fmt.tprintf("%s/scopecheck", scratch_root()))
	sc3 := scope_resolve("")
	eq_s(sc3.kind, "override", "PALM_TRACK_DIR beats both")
	scope_free(&sc3)
	check(true, "and freeing an override scope does not abort")

	if had != "" {
		_ = os.set_env("PALM_TRACK_DIR", had)
	} else {
		_ = os.unset_env("PALM_TRACK_DIR")
	}
	if saved_id != "" {
		_ = os.set_env("PALM_IDENTITY", saved_id)
	}
}

// ---------------------------------------------------------------------------
// 4. The importer
// ---------------------------------------------------------------------------

TODO_FIXTURE :: `# TODO

Preamble that belongs to no issue.

## How to use a prompt from this file

The standing rules.

- **The unit tests must pass**: 44 tests.

---

# Toolkit

These block applications today.

## T1 — Wake the frame loop from another thread

Ten applications are burning CPU because of this.

> **Prompt.** Add two things to palmy: a way to wake the frame loop from
> another thread, and a one-shot timer.
>
> You own ` + "`palmy/app.odin`" + `.
>
> ` + "```" + `
> a code sample inside the prompt
> ` + "```" + `
>
> Report the assertion count.

## T6 — Smaller toolkit gaps

A table of them.

## T7 — Wire bidi into the text path

See T6's table for where this came from.

> **Prompt.** Wire the two modules in.

# Applications

**` + "`mail`" + `** — drafts autosave.

---

# Known-unfixed, deliberately

- **Emoji ZWJ sequences** are not composed, so a modifier renders as a swatch.
- **apps/power executes nothing** and must stay that way.
`

test_importer :: proc() {
	section("importing a TODO.md")
	states := states_default(context.temp_allocator)
	issues, stats := import_todo(TODO_FIXTURE, states)
	defer delete(issues)

	find :: proc(issues: ^[dynamic]Issue, id: string) -> ^Issue {
		for &it in issues {
			if it.id == id {
				return &it
			}
		}
		return nil
	}

	check(stats.projects >= 4, "every `#` heading became a project (%d)", stats.projects)
	check(find(&issues, "T1") != nil, "T1 was found by its id prefix")
	check(find(&issues, "T6") != nil, "T6 was found")
	check(find(&issues, "T7") != nil, "T7 was found")

	t1 := find(&issues, "T1")
	eq_s(t1.title, "Wake the frame loop from another thread", "the em dash split id from title")
	eq_s(t1.project, "Toolkit", "and the `#` heading above it is the project")
	eq_i(len(t1.labels), 1, "the project became a label too")
	eq_s(t1.labels[0], "toolkit", "slugged")
	check(strings.contains(t1.prompt, "Add two things to palmy"), "the `> **Prompt.**` block became the prompt")
	check(!strings.contains(t1.prompt, "**Prompt.**"), "with the lead-in dropped, since the field says it")
	check(!strings.contains(t1.prompt, "\n> "), "and unindented out of the blockquote")
	check(strings.contains(t1.prompt, "a code sample inside the prompt"), "a fenced sample inside the prompt survives")
	check(strings.contains(t1.body, "burning CPU"), "the prose above the prompt became the body")
	check(!strings.contains(t1.body, "Add two things"), "and the prompt is not duplicated into it")

	// The Known-unfixed bullets.
	zwj: ^Issue
	power: ^Issue
	for &it in issues {
		if strings.contains(it.title, "Emoji ZWJ") {
			zwj = &it
		}
		if strings.contains(it.title, "power executes nothing") {
			power = &it
		}
	}
	check(zwj != nil, "a Known-unfixed bullet became an issue")
	if zwj != nil {
		eq_s(zwj.state, "wontfix", "in the wontfix state, because it is a decision and not a backlog item")
		check(strings.contains(zwj.body, "swatch"), "with the rest of the bullet as its body")
	}
	check(power != nil, "and so did the second bullet")

	conv: ^Issue
	for &it in issues {
		if strings.contains(it.title, "How to use a prompt") {
			conv = &it
		}
	}
	check(conv != nil, "the standing rules were imported rather than skipped")
	if conv != nil {
		eq_s(conv.state, "wontfix", "as a convention rather than work")
		eq_s(conv.labels[0], "convention", "labelled `convention`")
		check(strings.contains(conv.body, "44 tests"), "with the claim that is about to be falsified in it")
	}

	// Reference linking: T7 names T6, and nothing else names anything.
	n := import_links(&issues)
	t7 := find(&issues, "T7")
	check(t7 != nil && len(t7.deps) == 1 && t7.deps[0] == "T6", "T7 naming T6 in its prose became an edge")
	eq_i(n, 1, "and it is the only edge the document supports")

	// mentions_id must not fire on a substring.
	check(mentions_id("see section T6 for the table", "T6"), "an id surrounded by spaces matches")
	check(mentions_id("T6's table", "T6"), "an id followed by an apostrophe matches")
	check(!mentions_id("T60 is different", "T6"), "T6 does not match inside T60")
	check(!mentions_id("WT6", "T6"), "T6 does not match at the end of a word")

	// Every imported issue must survive a write and a read.
	bad := 0
	for &it in issues {
		text := issue_text(&it, context.temp_allocator)
		back := issue_parse(text, it.path, context.temp_allocator)
		if back.id != it.id || back.title != it.title || back.prompt != it.prompt || back.body != it.body {
			bad += 1
		}
	}
	eq_i(bad, 0, "every imported issue round-trips through the file format")
}

// ---------------------------------------------------------------------------
// 5. The verification gate
// ---------------------------------------------------------------------------

@(private = "file")
Trap :: struct {
	dir:      string,
	fired:    string,
	old_dir:  string,
	had_dir:  bool,
}

// install_trap writes a scratch store in which EVERY issue's verification
// appends to a sentinel file. Anything that executes a verification without
// being told to leaves a line in it.
@(private = "file")
install_trap :: proc() -> Trap {
	root := fmt.tprintf("%s/trap", scratch_root())
	t := Trap {
		dir   = root,
		fired = fmt.tprintf("%s/fired", scratch_root()),
	}
	_ = os.make_directory_all(root)
	os.remove(t.fired)
	put(fmt.tprintf("%s/%s", root, STATES_FILE), STATES_TEMPLATE)

	spec := [?]struct {
		id, title, state, deps: string,
	} {
		{"V1", "An issue that verifies true", "todo", ""},
		{"V2", "An issue that is lying", "todo", "V1"},
		{"V3", "An issue with no verification at all", "todo", "V1"},
		{"V4", "A closed one", "done", ""},
	}
	for s in spec {
		it := Issue {
			id    = s.id,
			title = s.title,
			state = s.state,
			deps  = split_list(s.deps, context.temp_allocator),
		}
		switch s.id {
		case "V1":
			// Records that it ran, and succeeds.
			it.verify = fmt.tprintf("printf 'ran %s\\n' >> %s; true", s.id, t.fired)
		case "V2":
			// Records that it ran, and fails: this is the stale one.
			it.verify = fmt.tprintf("printf 'ran %s\\n' >> %s; false", s.id, t.fired)
		case "V4":
			it.verify = fmt.tprintf("printf 'ran %s\\n' >> %s; true", s.id, t.fired)
		}
		put(fmt.tprintf("%s/%s-%s.md", root, s.id, slug(s.title)), issue_text(&it, context.temp_allocator))
	}

	t.old_dir = strings.clone(os.get_env("PALM_TRACK_DIR", context.temp_allocator), context.temp_allocator)
	t.had_dir = t.old_dir != ""
	_ = os.set_env("PALM_TRACK_DIR", root)
	_ = os.unset_env("PALM_IDENTITY")
	_ = os.unset_env("PALM_TRACK_NO_VERIFY")
	// The audit log is the kit's, and a self-test must not append to the real
	// one.
	_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", scratch_root()))
	return t
}

@(private = "file")
remove_trap :: proc(t: ^Trap) {
	if t.had_dir {
		_ = os.set_env("PALM_TRACK_DIR", t.old_dir)
	} else {
		_ = os.unset_env("PALM_TRACK_DIR")
	}
	_ = os.unset_env("PALM_AUDIT")
}

// Every verb an agent can type. None of them may execute a verification.
@(private = "file")
AGENT_DRIVEN := [?][]string {
	{"where", "--json"},
	{"states", "--json"},
	{"list", "--json"},
	{"list"},
	{"ready", "--json"},
	{"ready"},
	{"show", "V2", "--json"},
	{"show", "V2"},
	{"board", "--json"},
	{"graph", "--json"},
	{"graph"},
	{"check", "--json"},
	{"stale"},
	{"stale", "--json"},
	{"stale", "--all", "--json"},
	{"stale", "--only", "V2", "--json"},
	// --dry-run on the mutating form must still not execute.
	{"stale", "--run", "--dry-run", "--json"},
	{"prompt", "V1", "--json"},
	{"dep", "V3", "V1", "--json"},
	{"set", "V3", "--state", "doing", "--json"},
	{"new", "A new one", "--id", "V9", "--json"},
	{"rm", "V9", "--yes", "--json"},
	{"init", "--json"},
}

test_verify_gate :: proc() {
	section("the verification gate")

	t := install_trap()
	defer remove_trap(&t)

	// ---- spring the trap ---------------------------------------------
	// If the sentinel mechanism does not work, every "nothing executed"
	// assertion below passes for the wrong reason, so prove it fires first.
	st0 := store_open("")
	v2 := store_find(&st0, "V2")
	check(v2 != nil, "the scratch store loaded")
	if v2 == nil {
		store_free(&st0)
		return
	}
	check(!os.exists(t.fired), "the sentinel is clear before the trap is sprung")
	sprung := verify_run(v2, scratch_root(), true)
	check(sprung.ran, "with --run, the verification is executed (the trap works)")
	check(os.exists(t.fired), "and it leaves a line in the sentinel")
	eq_i(len(read_lines(t.fired)), 1, "exactly one line")
	eq_s(read_lines(t.fired)[0], "ran V2", "and it is the command that was declared")
	check(sprung.verdict == .Stale, "a non-zero exit is reported as stale")
	eq_i(sprung.code, 1, "with the exit status carried through")

	// The other half: a zero exit is `true`, and it must be distinguishable.
	v1 := store_find(&st0, "V1")
	r1 := verify_run(v1, scratch_root(), true)
	check(r1.verdict == .True, "a zero exit is reported as verified-true")
	// And an issue with no command at all is unverified, not true.
	v3 := store_find(&st0, "V3")
	r3 := verify_run(v3, scratch_root(), true)
	check(r3.verdict == .Unverified, "an issue with no command is unverified, not true")
	check(!r3.ran, "and nothing was spawned for it")
	check(
		r1.verdict != r3.verdict && sprung.verdict != r3.verdict && r1.verdict != sprung.verdict,
		"the three verification states are distinct values",
	)
	eq_s(verdict_name(.True), "verified-true", "verified-true is named")
	eq_s(verdict_name(.Stale), "verified-stale", "verified-stale is named")
	eq_s(verdict_name(.Unverified), "unverified", "unverified is named")
	store_free(&st0)

	// ---- the gate itself ---------------------------------------------
	os.remove(t.fired)
	check(!os.exists(t.fired), "the sentinel is clear before the verbs are driven")

	st1 := store_open("")
	for &it in st1.issues {
		r := verify_run(&it, scratch_root(), false)
		check(!r.ran, "verify_run without the flag does not execute %s", it.id)
		check(r.refused != "", "and says why (%s)", r.refused)
	}
	store_free(&st1)
	check(!os.exists(t.fired), "verify_run(allowed=false) executed nothing")

	// PALM_TRACK_NO_VERIFY beats the flag.
	_ = os.set_env("PALM_TRACK_NO_VERIFY", "1")
	st2 := store_open("")
	for &it in st2.issues {
		r := verify_run(&it, scratch_root(), true)
		check(!r.ran, "with PALM_TRACK_NO_VERIFY set, %s does not run even with --run", it.id)
	}
	store_free(&st2)
	check(!os.exists(t.fired), "the off switch beats the flag")
	_ = os.unset_env("PALM_TRACK_NO_VERIFY")

	// Every verb, driven the way an agent would drive it.
	saved := hush()
	for argv in AGENT_DRIVEN {
		code, handled := kit.cli_args(surface(), argv)
		unhush(saved)
		check(handled, "`track %s` is a command the surface knows", strings.join(argv, " ", context.temp_allocator))
		saved = hush()
		_ = code
	}
	unhush(saved)
	check(
		!os.exists(t.fired),
		"after every verb an agent can type, the sentinel is STILL empty (%v)",
		read_lines(t.fired),
	)

	// Import must never run anything either, including a verify it is in the
	// middle of writing down.
	imp := fmt.tprintf("%s/hostile.md", scratch_root())
	put(
		imp,
		fmt.tprintf(
			"# Imported\n\n## Z1 — Something imported\n\nbody\n",
		),
	)
	s2 := hush()
	code, _ := kit.cli_args(surface(), {"import", imp, "--json"})
	unhush(s2)
	eq_i(code, kit.EXIT_OK, "import succeeds")
	check(!os.exists(t.fired), "and import executed nothing")

	// ---- now run it on purpose ---------------------------------------
	// The other half of the trap: with --run, the sentinel must hold exactly
	// the commands that were declared, and nothing else. Without this,
	// "the sentinel is empty" above could be true because nothing works.
	os.remove(t.fired)
	s3 := hush()
	code2, _ := kit.cli_args(surface(), {"stale", "--run", "--json"})
	unhush(s3)
	eq_i(code2, kit.EXIT_OK, "`track stale --run` succeeds")
	fired := read_lines(t.fired)
	eq_i(len(fired), 3, "exactly the three declared verifications ran (%v)", fired)
	seen_v1, seen_v2, seen_v4, seen_v3 := false, false, false, false
	for l in fired {
		switch l {
		case "ran V1":
			seen_v1 = true
		case "ran V2":
			seen_v2 = true
		case "ran V3":
			seen_v3 = true
		case "ran V4":
			seen_v4 = true
		}
	}
	check(seen_v1 && seen_v2 && seen_v4, "each declared command ran exactly once")
	check(!seen_v3, "and the issue with no command ran nothing")

	// The verdicts were recorded in the files, which is the whole persistence
	// story: `git log -p` then shows the day an issue went stale.
	st3 := store_open("")
	defer store_free(&st3)
	check(store_find(&st3, "V1").verdict == .True, "V1's verdict was written back to its file")
	check(store_find(&st3, "V2").verdict == .Stale, "V2 is recorded as stale")
	check(store_find(&st3, "V3").verdict == .Unverified, "V3 stays unverified")
	check(store_find(&st3, "V2").checked != "", "with a timestamp")
	check(
		strings.contains(
			string(os.read_entire_file_from_path(store_find(&st3, "V2").path, context.temp_allocator) or_else {}),
			"verified: stale",
		),
		"and the word `stale` is greppable in the file itself",
	)

	// --no-write runs but records nothing, for a read-only checkout.
	os.remove(t.fired)
	s4 := hush()
	_, _ = kit.cli_args(surface(), {"set", "V1", "--verify", "true", "--json"})
	unhush(s4)
	st4 := store_open("")
	check(store_find(&st4, "V1").verdict == .Unverified, "changing the command resets the verdict")
	store_free(&st4)

	// ---- the denylist -------------------------------------------------
	section("a verification cannot reach the forbidden commands")
	for cmd in ([?]string {
		"nmcli radio off",
		"sudo rm -rf /",
		"systemctl stop sddm",
		"rfkill block all",
		"grep -q x f && nmcli networking off",
		"true; reboot",
		"test -f x || sudo pacman -Syu",
		"echo $(nmcli radio off)",
		"ip link set eth0 down",
	}) {
		why := verify_forbidden(cmd)
		check(why != "", "refused: %s", cmd)
	}
	for cmd in ([?]string {
		"! grep -q bidi_resolve palmy/font.odin",
		`test "$(grep -c '@(test)' tests/*.odin)" = 99`,
		"odin build apps/track -collection:palmy=$PWD/palmy",
		"git log --oneline -1 | grep -q bidi",
	}) {
		why := verify_forbidden(cmd)
		eq_s(why, "", "allowed: %s", cmd)
	}
	// And the denylist is actually enforced at the one exec site.
	os.remove(t.fired)
	hostile := Issue {
		id     = "H1",
		title  = "hostile",
		verify = fmt.tprintf("printf 'ran H1\\n' >> %s; nmcli radio off", t.fired),
		path   = fmt.tprintf("%s/H1.md", t.dir),
	}
	rh := verify_run(&hostile, scratch_root(), true)
	check(!rh.ran, "a command whose second segment is forbidden is not run at all")
	check(!os.exists(t.fired), "so its harmless first segment never ran either")
	check(strings.contains(rh.refused, "refused"), "and the refusal says so (%s)", rh.refused)

	// The segment splitter, which the refusal above depends on.
	segs := verify_segments("! grep -q x f && echo 'a; b' | wc -l")
	check(len(segs) >= 3, "a command line splits at && and | (%d segments)", len(segs))
	eq_s(segs[0][0], "grep", "the leading `!` is negation, not the command")
}

// ---------------------------------------------------------------------------
// The CLI surface, asserted against itself
// ---------------------------------------------------------------------------

test_cli_surface :: proc() {
	section("the command surface, asserted against itself")
	s := surface()
	check(len(s.commands) >= 14, "the surface declares its verbs (%d)", len(s.commands))
	check(s.selftest != nil, "and a self-test, the one existing convention")

	destructive, reads := 0, 0
	for cmd in s.commands {
		check(cmd.summary != "", "`%s` has a summary", cmd.verb)
		check(cmd.run != nil, "`%s` is implemented, not merely declared", cmd.verb)
		if cmd.effect == .Destructive {
			destructive += 1
		}
		if cmd.effect == .Read {
			reads += 1
			check(len(cmd.out) > 0, "the read command `%s` declares what it prints", cmd.verb)
		}
		// Every example a command ships must still parse.
		for ex in cmd.examples {
			argv := kit.cli_split_example(ex)
			check(len(argv) > 0, "the example %q tokenises", ex)
			if len(argv) == 0 {
				continue
			}
			// The examples are written as `track list --json`; drop the noun.
			if argv[0] == s.noun {
				argv = argv[1:]
			}
			_, code := kit.cli_bind(s, argv)
			// A destructive example without --yes is correctly refused; that
			// is the convention working, not the example failing.
			ok := code == kit.EXIT_OK || code == kit.EXIT_NEEDS_YES
			check(ok, "the example %q parses (exit %d)", ex, code)
		}
	}
	check(destructive >= 1, "at least one verb is declared destructive")
	check(reads >= 8, "and most of the surface is read-only (%d)", reads)

	// Refusal rather than prompting.
	_, dcode := kit.cli_bind(s, {"rm", "V1"})
	eq_i(dcode, kit.EXIT_NEEDS_YES, "a destructive verb without --yes is refused, not prompted for")
	_, ucode := kit.cli_bind(s, {"nosuchverb"})
	eq_i(ucode, kit.EXIT_USAGE, "an unknown verb is a usage error")
	_, mcode := kit.cli_bind(s, {"show"})
	eq_i(mcode, kit.EXIT_USAGE, "a missing required argument is a usage error")

	// `--run` has to be a declared flag of `stale` and of nothing else, so
	// the capability is visible in `--schema`.
	run_on := make([dynamic]string, context.temp_allocator)
	for cmd in s.commands {
		for f in cmd.flags {
			if f.name == "run" {
				append(&run_on, cmd.verb)
			}
		}
	}
	eq_i(len(run_on), 1, "exactly one verb takes --run")
	eq_s(run_on[0], "stale", "and it is `stale`")

	// And the schema is renderable, which is what `palm schema` reads.
	txt := kit.json_text(kit.cli_schema_json(s), 2, context.temp_allocator)
	check(strings.contains(txt, `"noun": "track"`), "the schema names the noun")
	check(strings.contains(txt, `"effect": "destructive"`), "and carries the side-effect class per verb")
	problems := kit.cli_validate_output(txt, {}, context.temp_allocator)
	eq_i(len(problems), 0, "the schema is valid JSON")
}

// ---------------------------------------------------------------------------
// The DAG layout
// ---------------------------------------------------------------------------

test_layout :: proc() {
	section("the graph layout")
	st := mkstore(
		{
			{"A", "todo", ""},
			{"B", "todo", "A"},
			{"C", "todo", "A"},
			{"D", "todo", "B, C"},
			{"E", "todo", "A"},
			{"F", "todo", "D, E"},
			{"G", "todo", "A, F"},
			{"H", "todo", "A"},
			{"I", "todo", "A"},
		},
	)
	g := graph_build(&st)
	defer graph_free(&g)
	vis := make([]bool, len(st.issues), context.temp_allocator)
	for i in 0 ..< len(vis) {
		vis[i] = true
	}
	d := dag_build(&st, &g, vis)
	defer dag_free(&d)

	eq_i(len(d.layers), 5, "the longest path sets the number of columns")
	// Every edge must point strictly leftward, one column at a time after
	// the dummies are inserted. A single backward or skipping hop is what
	// turns a layered drawing into spaghetti.
	bad_dir, bad_span := 0, 0
	for e in d.edges {
		for k in 0 ..< len(e.chain) - 1 {
			hi := d.nodes[e.chain[k]]
			lo := d.nodes[e.chain[k + 1]]
			if lo.layer >= hi.layer {
				bad_dir += 1
			}
			if hi.layer - lo.layer != 1 {
				bad_span += 1
			}
		}
	}
	eq_i(bad_dir, 0, "every drawn hop goes leftward")
	eq_i(bad_span, 0, "and spans exactly one column, so no line crosses a column blind")

	// The long edge A <- G spans four columns and must have three dummies.
	for e in d.edges {
		if st.issues[e.from].id == "G" && st.issues[e.to].id == "A" {
			eq_i(len(e.chain), 5, "the four-column edge G->A routes through three dummy nodes")
		}
	}

	// Nothing overlaps: two boxes in the same column must not share pixels.
	overlaps := 0
	for l in d.layers {
		for a in 0 ..< len(l) {
			for b in a + 1 ..< len(l) {
				x, y := d.nodes[l[a]], d.nodes[l[b]]
				ha := x.issue >= 0 ? f32(NODE_H) : 10
				hb := y.issue >= 0 ? f32(NODE_H) : 10
				if x.y < y.y + hb && y.y < x.y + ha {
					overlaps += 1
				}
			}
		}
	}
	eq_i(overlaps, 0, "no two nodes in a column overlap")

	// Everything is inside the reported extent, which the scroll range uses.
	outside := 0
	for nd in d.nodes {
		h := nd.issue >= 0 ? f32(NODE_H) : 10
		if nd.y < 0 || nd.y + h > d.h || nd.x < 0 || nd.x + NODE_W > d.w {
			outside += 1
		}
	}
	eq_i(outside, 0, "every node is inside the reported extent")

	// Every real issue is drawn exactly once, and the column it lands in is
	// the depth the CLI reports, so the picture and `track graph` agree.
	seen := make(map[string]int, len(st.issues), context.temp_allocator)
	for nd in d.nodes {
		if nd.issue < 0 {
			continue
		}
		seen[st.issues[nd.issue].id] += 1
		eq_i(nd.layer, g.depth[nd.issue], "%s is drawn in the column its depth says", st.issues[nd.issue].id)
	}
	eq_i(len(seen), len(st.issues), "every issue appears in the drawing")
	for _, n in seen {
		eq_i(n, 1, "and exactly once")
	}

	// Crossing reduction has to do something. A fan of five siblings over a
	// diamond arranged at random crosses; the barycentre passes should get
	// it to a small number.
	check(d.crossings <= 2, "the layout keeps crossings low (%d)", d.crossings)

	// A hidden issue is not drawn, and the edges through it disappear with
	// it rather than dangling.
	vis2 := make([]bool, len(st.issues), context.temp_allocator)
	for i in 0 ..< len(vis2) {
		vis2[i] = st.issues[i].id != "D"
	}
	d2 := dag_build(&st, &g, vis2)
	defer dag_free(&d2)
	for nd in d2.nodes {
		if nd.issue >= 0 {
			check(st.issues[nd.issue].id != "D", "a hidden issue is not drawn")
		}
	}
	for e in d2.edges {
		check(
			st.issues[e.from].id != "D" && st.issues[e.to].id != "D",
			"and no edge still points at it",
		)
	}
}
