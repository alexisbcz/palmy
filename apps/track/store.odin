// The store: issues are real Markdown files.
//
// One file per issue, with YAML-ish frontmatter, under a directory. The same
// bargain `apps/notes` makes — the directory is browsable with `ls`, editable
// with any editor, greppable, and diffable — with two things added that a
// notebook does not need: an id, and edges to other issues.
//
// Two scopes, chosen by where you are rather than by a flag:
//
//   * **Repo-local.** Inside a git work tree, `./.palm/issues/` next to the
//     code. Issues travel with the branch and merge like code; a `git log` on
//     one file is that issue's history, and nothing else's.
//   * **Personal.** Otherwise `$XDG_DATA_HOME/palmy-track/<identity>/`, with
//     `--identity` choosing among the work self, the personal self, the
//     company — the sub-identity design in the README, and the convention
//     `apps/pkg` established.
//
// No database, no lock file, no server, and deliberately nothing that
// aggregates: the index is the directory listing. Two people editing
// different issues touch different files and cannot conflict. Two people
// editing the *same* issue conflict exactly as they would in any other text
// file, which is the right amount of help.
//
// THE FILE
//
//	---
//	id: T7
//	title: Wire bidi and shaping into the text path
//	state: todo
//	project: Toolkit
//	assignee: agent:claude
//	labels: toolkit, text, rtl
//	deps: T1, T6
//	verify: ! grep -q bidi_resolve palmy/font.odin
//	verified: stale
//	verified-at: 2026-10-05T14:03:11Z
//	created: 2026-10-05T13:58:02Z
//	updated: 2026-10-05T14:03:11Z
//	---
//
//	Body prose. Markdown, free-form, whatever you like.
//
//	## Prompt
//
//	Everything after that heading is the prompt: a self-contained brief an
//	agent can be handed without further context. It may hold fenced code,
//	several paragraphs, and `## headings` of its own.
//
// Frontmatter is one `key: value` per line, split at the FIRST colon, so a
// `verify:` command may contain as many colons as it likes. Lists are
// comma-separated. The prompt is last in the file, which is what lets it hold
// arbitrary Markdown including fences; the `## Prompt` separator is only
// honoured outside a fence, so a body that quotes one does not truncate.
//
// The file name is `<id>-<slug>.md`, fixed when the issue is created and
// never rewritten afterwards even if the title changes, because the point of
// a file per issue is that `git log <file>` reads as that issue's history and
// a rename interrupts it. Issues are found by the `id:` inside, never by the
// name outside.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

DIR_REPO :: ".palm/issues"
DIR_PERSONAL :: "palmy-track"

// Verdict is the verification state, and the three values are deliberately
// distinct. `Unverified` is the common case: it must never be reported as
// either of the other two, because a plan made from "we never checked" is a
// different plan from one made from "we checked and it held".
Verdict :: enum u8 {
	Unverified, // no command, or a command that has not been run
	True, // ran, exit zero: the issue is still describing reality
	Stale, // ran, non-zero: the issue is lying
}

verdict_name :: proc(v: Verdict) -> string {
	switch v {
	case .Unverified:
		return "unverified"
	case .True:
		return "verified-true"
	case .Stale:
		return "verified-stale"
	}
	return "unverified"
}

Issue :: struct {
	id:        string,
	title:     string,
	state:     string,
	project:   string,
	assignee:  string, // a person or an agent; `agent:` prefixed when it is one
	labels:    []string,
	deps:      []string, // the ids this one is blocked by
	verify:    string, // the command that says whether this is still true
	verdict:   Verdict,
	checked:   string, // when the verdict was taken, or ""
	created:   string,
	updated:   string,
	body:      string, // prose before `## Prompt`
	prompt:    string, // everything after it
	path:      string,
	// Frontmatter keys the parser did not recognise, kept verbatim and
	// written back out. A tracker that silently eats a field somebody added
	// by hand is a tracker people stop editing by hand.
	extra_k:   []string,
	extra_v:   []string,
}

// dfree frees a string only if there is one. A zero-length string may be a
// literal with a pointer into read-only memory, and handing that to free()
// aborts the process — which is exactly how this was found.
@(private)
dfree :: proc(s: string) {
	if len(s) > 0 {
		delete(s)
	}
}

// Everything an Issue owns comes from `context.allocator`. A caller that puts
// a temp-allocated string into a field that will later be freed here is
// mixing allocators, and the abort happens somewhere else entirely, so the
// CLI clones into the heap even when the value is about to be written out and
// forgotten.
issue_free :: proc(it: ^Issue) {
	dfree(it.id);dfree(it.title);dfree(it.state);dfree(it.project)
	dfree(it.assignee);dfree(it.verify);dfree(it.checked)
	dfree(it.created);dfree(it.updated);dfree(it.body);dfree(it.prompt)
	dfree(it.path)
	for s in it.labels {dfree(s)}
	delete(it.labels)
	for s in it.deps {dfree(s)}
	delete(it.deps)
	for s in it.extra_k {dfree(s)}
	delete(it.extra_k)
	for s in it.extra_v {dfree(s)}
	delete(it.extra_v)
}

// ---------------------------------------------------------------------------
// States, which are configuration rather than code
// ---------------------------------------------------------------------------

// A state is a name plus whether it is terminal. `closed` is the only
// property the graph needs: a dependency in a closed state stops blocking.
// Everything else about a state — what it means, what order it sits in on the
// board — is the file's business, not this program's. No sprints, no
// velocity, no burndown, and no hardcoded five.
State_Def :: struct {
	name:   string,
	closed: bool,
}

DEFAULT_STATES := [?]State_Def {
	{"todo", false},
	{"doing", false},
	{"blocked", false},
	{"review", false},
	{"done", true},
	{"wontfix", true},
}

STATES_FILE :: "states.txt"

STATES_TEMPLATE :: `# The states this tracker uses, in board order.
#
# One per line. A trailing "closed" marks a terminal state: an issue that
# depends on one in a closed state is no longer blocked by it. Rename these,
# reorder them, add your own — nothing in the program knows these six names.
todo
doing
blocked
review
done     closed
wontfix  closed
`

// states_load reads states.txt from the scope directory, falling back to the
// built-in list. An unreadable or empty file is the built-in list too: a
// tracker that refuses to open because its configuration has a typo in it is
// worse than one that tells you and carries on.
states_load :: proc(dir: string, allocator := context.allocator) -> []State_Def {
	path := fmt.tprintf("%s/%s", dir, STATES_FILE)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return states_default(allocator)
	}
	out := make([dynamic]State_Def, allocator)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" || strings.has_prefix(t, "#") {
			continue
		}
		fields := strings.fields(t, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		closed := false
		for f in fields[1:] {
			if f == "closed" || f == "terminal" {
				closed = true
			}
		}
		append(&out, State_Def{strings.clone(fields[0], allocator), closed})
	}
	if len(out) == 0 {
		delete(out)
		return states_default(allocator)
	}
	return out[:]
}

states_default :: proc(allocator := context.allocator) -> []State_Def {
	out := make([]State_Def, len(DEFAULT_STATES), allocator)
	for d, i in DEFAULT_STATES {
		out[i] = State_Def{strings.clone(d.name, allocator), d.closed}
	}
	return out
}

state_is_closed :: proc(states: []State_Def, name: string) -> bool {
	for s in states {
		if s.name == name {
			return s.closed
		}
	}
	return false
}

state_known :: proc(states: []State_Def, name: string) -> bool {
	for s in states {
		if s.name == name {
			return true
		}
	}
	return false
}

state_index :: proc(states: []State_Def, name: string) -> int {
	for s, i in states {
		if s.name == name {
			return i
		}
	}
	return len(states) // unknown states sort last rather than vanish
}

// ---------------------------------------------------------------------------
// Where the issues live
// ---------------------------------------------------------------------------

Scope :: struct {
	dir:      string,
	kind:     string, // "repo" or "personal"
	identity: string, // "" when repo-local
	root:     string, // the git work tree, for a repo scope; else ""
}

// git_root walks up from `start` looking for a `.git`. Walking rather than
// shelling out to `git rev-parse`: it is the same answer, it works when git
// is not installed, and it cannot be slowed down by a cold index.
git_root :: proc(start: string, allocator := context.temp_allocator) -> (root: string, ok: bool) {
	cur := strings.clone(start, context.temp_allocator)
	for i in 0 ..< 64 {
		if cur == "" {
			break
		}
		if os.exists(fmt.tprintf("%s/.git", cur)) {
			return strings.clone(cur, allocator), true
		}
		slash := strings.last_index_byte(cur, '/')
		if slash <= 0 {
			if cur != "/" && slash == 0 {
				cur = "/"
				continue
			}
			break
		}
		cur = cur[:slash]
	}
	return "", false
}

// scope_resolve picks the directory, and says why it picked it. $PALM_TRACK_DIR
// overrides everything, which is what lets the self-test drive the real verbs
// — including the ones that write and delete — against a scratch directory.
// Testing a command that writes files against anything other than real files
// is testing a different program.
scope_resolve :: proc(identity: string, allocator := context.allocator) -> Scope {
	if over := os.get_env("PALM_TRACK_DIR", context.temp_allocator); over != "" {
		return Scope {
			dir = strings.clone(over, allocator),
			kind = strings.clone("override", allocator),
			identity = strings.clone(identity, allocator),
			root = "",
		}
	}
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err == nil {
		if root, ok := git_root(cwd); ok {
			return Scope {
				dir = strings.clone(fmt.tprintf("%s/%s", root, DIR_REPO), allocator),
				kind = strings.clone("repo", allocator),
				identity = strings.clone("", allocator),
				root = strings.clone(root, allocator),
			}
		}
	}
	base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			home = "/tmp"
		}
		base = fmt.tprintf("%s/.local/share", home)
	}
	who := identity
	if who == "" {
		who = os.get_env("PALM_IDENTITY", context.temp_allocator)
	}
	if who == "" {
		who = "default"
	}
	return Scope {
		dir = strings.clone(fmt.tprintf("%s/%s/%s", base, DIR_PERSONAL, who), allocator),
		kind = strings.clone("personal", allocator),
		identity = strings.clone(who, allocator),
		root = "",
	}
}

// Every field is cloned into the allocator, including the ones that look
// like constants: `kind = "repo"` would put a pointer to read-only memory in
// a struct this frees, and free() on a literal aborts the process on the
// first command anybody runs.
scope_free :: proc(s: ^Scope) {
	dfree(s.dir);dfree(s.kind);dfree(s.identity);dfree(s.root)
}

scope_ensure :: proc(s: ^Scope) -> bool {
	if !os.is_dir(s.dir) {
		if err := os.make_directory_all(s.dir, os.perm(0o700)); err != nil && !os.is_dir(s.dir) {
			return false
		}
	}
	// Seed states.txt whenever it is missing, not only when the directory is
	// new: `mkdir -p` and then `track import` is an ordinary thing to type,
	// and it left a tracker whose one piece of configuration was invisible
	// and whose states were therefore hardcoded by accident.
	sp := fmt.tprintf("%s/%s", s.dir, STATES_FILE)
	if !os.exists(sp) {
		_ = os.write_entire_file(sp, transmute([]u8)string(STATES_TEMPLATE))
	}
	return os.is_dir(s.dir)
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

PROMPT_HEADING :: "## Prompt"

// split_list parses `a, b, c` into its parts, dropping empties.
split_list :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for part in strings.split(s, ",", context.temp_allocator) {
		t := strings.trim_space(part)
		if t != "" {
			append(&out, strings.clone(t, allocator))
		}
	}
	return out[:]
}

join_list :: proc(v: []string, allocator := context.temp_allocator) -> string {
	return strings.join(v, ", ", allocator)
}

// fence_toggle reports whether a line opens or closes a fenced code block.
// Both ``` and ~~~ count, and indentation up to three spaces is allowed, the
// same as CommonMark. Getting this wrong is how a `## Prompt` inside a code
// sample eats the rest of the file.
fence_toggle :: proc(line: string) -> bool {
	t := line
	for len(t) > 0 && t[0] == ' ' {
		t = t[1:]
	}
	return strings.has_prefix(t, "```") || strings.has_prefix(t, "~~~")
}

// split_prompt cuts a body at the `## Prompt` heading, honouring fences.
split_prompt :: proc(text: string) -> (body, prompt: string, found: bool) {
	in_fence := false
	at := 0
	i := 0
	for i <= len(text) {
		end := strings.index_byte(text[i:], '\n')
		line_end := end < 0 ? len(text) : i + end
		line := text[i:line_end]
		if fence_toggle(line) {
			in_fence = !in_fence
		} else if !in_fence && strings.trim_right_space(line) == PROMPT_HEADING {
			// The body is everything before the heading; the prompt is
			// everything after the heading's own newline.
			next := line_end < len(text) ? line_end + 1 : len(text)
			return text[:at], text[next:], true
		}
		if end < 0 {
			break
		}
		at = i
		i = line_end + 1
	}
	return text, "", false
}

// issue_parse reads one file's text. It never fails: a file with no
// frontmatter is still an issue, with the first heading as its title, because
// a tracker that refuses a hand-written file is a tracker nobody hand-writes
// a file for.
issue_parse :: proc(text: string, path: string, allocator := context.allocator) -> Issue {
	it := Issue {
		path = strings.clone(path, allocator),
	}
	ek := make([dynamic]string, allocator)
	ev := make([dynamic]string, allocator)
	labels: []string
	deps: []string

	rest := text
	if strings.has_prefix(text, "---\n") {
		after := text[4:]
		if close_at := strings.index(after, "\n---"); close_at >= 0 {
			front := after[:close_at]
			tail := after[close_at + 4:]
			if strings.has_prefix(tail, "\n") {
				tail = tail[1:]
			}
			rest = tail
			scan := front
			for line in strings.split_lines_iterator(&scan) {
				t := strings.trim_space(line)
				if t == "" || strings.has_prefix(t, "#") {
					continue
				}
				colon := strings.index_byte(t, ':')
				if colon < 0 {
					continue
				}
				// Split at the FIRST colon only. `verify: sh -c 'a: b'` is one
				// value, and so is a title with a colon in it.
				key := strings.trim_space(t[:colon])
				val := strings.trim_space(t[colon + 1:])
				switch key {
				case "id":
					it.id = strings.clone(val, allocator)
				case "title":
					it.title = strings.clone(val, allocator)
				case "state", "status":
					it.state = strings.clone(val, allocator)
				case "project":
					it.project = strings.clone(val, allocator)
				case "assignee", "owner":
					it.assignee = strings.clone(val, allocator)
				case "labels", "label", "tags":
					labels = split_list(val, allocator)
				case "deps", "depends-on", "blocked-by":
					deps = split_list(val, allocator)
				case "verify":
					it.verify = strings.clone(val, allocator)
				case "verified":
					switch val {
					case "true", "ok", "yes":
						it.verdict = .True
					case "stale", "false", "no":
						it.verdict = .Stale
					case:
						it.verdict = .Unverified
					}
				case "verified-at", "verified_at":
					it.checked = strings.clone(val, allocator)
				case "created":
					it.created = strings.clone(val, allocator)
				case "updated":
					it.updated = strings.clone(val, allocator)
				case:
					append(&ek, strings.clone(key, allocator))
					append(&ev, strings.clone(val, allocator))
				}
			}
		}
	}

	body, prompt, _ := split_prompt(rest)
	it.body = strings.clone(strings.trim_space(body), allocator)
	it.prompt = strings.clone(strings.trim_space(prompt), allocator)

	if it.title == "" {
		// No frontmatter title: the first `# heading` or the first non-empty
		// line, the way a note is titled by its first line.
		scan := it.body
		for line in strings.split_lines_iterator(&scan) {
			t := strings.trim_space(line)
			if t == "" {
				continue
			}
			t = strings.trim_space(strings.trim_left(t, "#"))
			if t != "" {
				it.title = strings.clone(t, allocator)
				break
			}
		}
	}
	if it.title == "" {
		it.title = strings.clone("Untitled issue", allocator)
	}
	if it.state == "" {
		it.state = strings.clone("todo", allocator)
	}
	if it.id == "" {
		base := path
		if sl := strings.last_index_byte(base, '/'); sl >= 0 {
			base = base[sl + 1:]
		}
		base = strings.trim_suffix(base, ".md")
		it.id = strings.clone(base, allocator)
	}
	if labels == nil {
		labels = make([]string, 0, allocator)
	}
	if deps == nil {
		deps = make([]string, 0, allocator)
	}
	it.labels = labels
	it.deps = deps
	it.extra_k = ek[:]
	it.extra_v = ev[:]
	// A verdict with nothing to verify is meaningless, and a verdict carried
	// over from a command that was since deleted is worse than meaningless.
	if it.verify == "" {
		it.verdict = .Unverified
		// Not freed: `allocator` may be the temp allocator, and a delete
		// against the wrong allocator aborts the process. Dropping the
		// reference is enough; the arena or the issue's own free handles it.
		it.checked = ""
	}
	return it
}

// issue_text renders an issue back to the file it came from. Key order is
// fixed, so two writes of the same issue differ only where the issue does —
// a diff shows what changed, not where a hash table moved.
issue_text :: proc(it: ^Issue, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	w :: proc(sb: ^strings.Builder, k, v: string) {
		if v == "" {
			return
		}
		strings.write_string(sb, k)
		strings.write_string(sb, ": ")
		strings.write_string(sb, v)
		strings.write_byte(sb, '\n')
	}
	strings.write_string(&sb, "---\n")
	w(&sb, "id", it.id)
	w(&sb, "title", it.title)
	w(&sb, "state", it.state)
	w(&sb, "project", it.project)
	w(&sb, "assignee", it.assignee)
	if len(it.labels) > 0 {
		w(&sb, "labels", join_list(it.labels))
	}
	if len(it.deps) > 0 {
		w(&sb, "deps", join_list(it.deps))
	}
	w(&sb, "verify", it.verify)
	if it.verify != "" && it.verdict != .Unverified {
		w(&sb, "verified", it.verdict == .True ? "true" : "stale")
		w(&sb, "verified-at", it.checked)
	}
	w(&sb, "created", it.created)
	w(&sb, "updated", it.updated)
	for k, i in it.extra_k {
		w(&sb, k, it.extra_v[i])
	}
	strings.write_string(&sb, "---\n")
	if it.body != "" {
		strings.write_string(&sb, "\n")
		strings.write_string(&sb, it.body)
		strings.write_string(&sb, "\n")
	}
	if it.prompt != "" {
		strings.write_string(&sb, "\n")
		strings.write_string(&sb, PROMPT_HEADING)
		strings.write_string(&sb, "\n\n")
		strings.write_string(&sb, it.prompt)
		strings.write_string(&sb, "\n")
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Loading and saving
// ---------------------------------------------------------------------------

Store :: struct {
	scope:  Scope,
	states: []State_Def,
	issues: [dynamic]Issue,
}

store_free :: proc(st: ^Store) {
	for &it in st.issues {
		issue_free(&it)
	}
	delete(st.issues)
	for s in st.states {
		delete(s.name)
	}
	delete(st.states)
	scope_free(&st.scope)
}

// store_open reads the whole directory. It is cheap enough to do on every
// command — a thousand issues is a megabyte — and the alternative is an index
// that can disagree with the files, which is the thing this design exists to
// avoid.
store_open :: proc(identity: string) -> Store {
	st := Store {
		scope  = scope_resolve(identity),
		issues = make([dynamic]Issue, 0, 64),
	}
	st.states = states_load(st.scope.dir)
	handle, err := os.open(st.scope.dir)
	if err != nil {
		return st
	}
	defer os.close(handle)
	infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		return st
	}
	for info in infos {
		if info.type == .Directory || !strings.has_suffix(info.name, ".md") {
			continue
		}
		path := fmt.tprintf("%s/%s", st.scope.dir, info.name)
		data, derr := os.read_entire_file_from_path(path, context.temp_allocator)
		if derr != nil {
			continue
		}
		append(&st.issues, issue_parse(string(data), path))
	}
	store_sort(&st)
	return st
}

// store_sort orders by id, numerically where the ids end in digits, so T2
// comes before T10 and the listing reads the way the ids were meant.
store_sort :: proc(st: ^Store) {
	for i in 1 ..< len(st.issues) {
		j := i
		for j > 0 && id_less(st.issues[j].id, st.issues[j - 1].id) {
			st.issues[j], st.issues[j - 1] = st.issues[j - 1], st.issues[j]
			j -= 1
		}
	}
}

id_split :: proc(id: string) -> (prefix: string, num: int, has_num: bool) {
	at := len(id)
	for at > 0 {
		c := id[at - 1]
		if c < '0' || c > '9' {
			break
		}
		at -= 1
	}
	if at == len(id) {
		return id, 0, false
	}
	n := 0
	for i in at ..< len(id) {
		n = n * 10 + int(id[i] - '0')
	}
	return id[:at], n, true
}

id_less :: proc(a, b: string) -> bool {
	pa, na, oka := id_split(a)
	pb, nb, okb := id_split(b)
	if pa != pb {
		return pa < pb
	}
	if oka && okb {
		return na < nb
	}
	return a < b
}

store_find :: proc(st: ^Store, id: string) -> ^Issue {
	for &it in st.issues {
		if it.id == id {
			return &it
		}
	}
	// A case-insensitive second pass, because `track show t7` is what gets
	// typed and refusing it teaches nothing.
	for &it in st.issues {
		if strings.equal_fold(it.id, id) {
			return &it
		}
	}
	return nil
}

now_stamp :: proc(allocator := context.temp_allocator) -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return strings.clone(
		fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s),
		allocator,
	)
}

// issue_save writes one issue to its own file and nothing else. One file per
// write is the whole concurrency story: two agents working on two issues
// never touch the same bytes.
issue_save :: proc(st: ^Store, it: ^Issue) -> bool {
	if !scope_ensure(&st.scope) {
		return false
	}
	if it.path == "" {
		it.path = strings.clone(
			fmt.tprintf("%s/%s-%s.md", st.scope.dir, it.id, slug(it.title)),
		)
	}
	text := issue_text(it, context.temp_allocator)
	return os.write_entire_file(it.path, transmute([]u8)text) == nil
}

// slug turns a title into the human half of a file name.
slug :: proc(title: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	dash := false
	for i in 0 ..< len(title) {
		c := title[i]
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&sb, c + 32)
			dash = false
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			strings.write_byte(&sb, c)
			dash = false
		case:
			if !dash && strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, '-')
				dash = true
			}
		}
		if strings.builder_len(sb) >= 44 {
			break
		}
	}
	out := strings.trim_right(strings.to_string(sb), "-")
	if out == "" {
		return strings.clone("issue", allocator)
	}
	return out
}

// next_id is the lowest unused number for a prefix, so ids stay dense and a
// deleted issue's id is not reused while anything still points at it.
next_id :: proc(st: ^Store, prefix: string, allocator := context.allocator) -> string {
	high := 0
	for it in st.issues {
		p, n, ok := id_split(it.id)
		if ok && p == prefix && n > high {
			high = n
		}
	}
	return strings.clone(fmt.tprintf("%s%d", prefix, high + 1), allocator)
}

// id_ok is the gate on an id. Ids reach file names and argv, so the same
// reasoning `apps/pkg` applies to package names applies here: alphanumerics,
// `-`, `_` and `.`, starting with an alphanumeric. A `../` in an id would be
// a path, not an id.
id_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	c0 := s[0]
	if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || (c0 >= '0' && c0 <= '9')) {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-' || c == '_' || c == '.':
		case:
			return false
		}
	}
	// `..` would still be two legal characters in a row.
	return !strings.contains(s, "..")
}
