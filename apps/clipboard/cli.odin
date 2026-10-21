package main

// The command-line front end of the clipboard history.
//
// It works on the history file the window keeps (store.odin), through the
// procedures the window's keys call: `load`, `rank_locked` for the list and the
// search (the same fuzzy ranking, the same pinned-first order), `set_pinned_locked`
// for Ctrl+P, `delete_locked` for Del, `clear_all_locked` for Ctrl+L, `copy_entry`
// for Enter, and `ingest_selection` — the watcher's own decision — for `add`.
// An open window notices the file change and reloads, so `clipboard delete`
// in a terminal is not undone by the window's next save.
//
// It never reads the clipboard. Watching the selection needs a window (palmy's
// offer API) or wl-paste, and is the window's job; the command line is the
// history. The one command that touches the live clipboard is `copy`, which
// puts an entry back, and it refuses without a Wayland session.
//
// THE SENSITIVITY GATE. A selection whose owner flagged it as a secret is
// never read, so it is never stored. If a history file nonetheless holds an
// entry recorded under a password-manager type (`entry_secret`), no command
// prints its text: lists and searches show it redacted and never match it,
// `show` gives its metadata only, `copy` refuses it. `add` applies the same
// gate a copy does. The self-test asserts every one of those against a planted
// entry.
//
// Entries are named by id: sixteen hex digits, or any unique prefix of four
// or more. `list` prints them.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import kit "kit:."

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

LIST_FIELDS := []kit.Field {
	{name = "count", kind = .Int, help = "entries listed"},
	{name = "total", kind = .Int, help = "entries in the history"},
	{name = "filter", kind = .String},
	{
		name = "entries",
		kind = .Array,
		help = "pinned first, then newest first",
		of = {
			{name = "id", kind = .String, help = "16 hex digits; any unique prefix of 4 or more names it"},
			{name = "kind", kind = .String, help = "text or image"},
			{name = "preview", kind = .String, help = "one line, as the row shows it; redacted for a secret"},
			{name = "size", kind = .Int, help = "bytes as copied"},
			{name = "when", kind = .Int, help = "unix seconds"},
			{name = "ago", kind = .String, help = "as the row shows it"},
			{name = "pinned", kind = .Bool},
			{name = "secret", kind = .Bool, help = "flagged by its owner; its text is never printed"},
		},
	},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{name = "count", kind = .Int},
	{
		name = "entries",
		kind = .Array,
		help = "best match first, pinned ahead; a secret never matches",
		of = {
			{name = "id", kind = .String},
			{name = "kind", kind = .String},
			{name = "preview", kind = .String},
			{name = "size", kind = .Int},
			{name = "when", kind = .Int},
			{name = "ago", kind = .String},
			{name = "pinned", kind = .Bool},
			{name = "secret", kind = .Bool},
		},
	},
}

SHOW_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "kind", kind = .String},
	{name = "mime", kind = .String},
	{name = "size", kind = .Int},
	{name = "when", kind = .Int},
	{name = "ago", kind = .String},
	{name = "pinned", kind = .Bool},
	{name = "secret", kind = .Bool},
	{name = "text", kind = .String, opt = true, help = "the whole text; absent for an image and for a secret"},
	{name = "truncated", kind = .Bool, opt = true, help = "stored cut at 64 KB"},
	{name = "file", kind = .String, opt = true, help = "an image's stored file"},
	{name = "width", kind = .Int, opt = true},
	{name = "height", kind = .Int, opt = true},
}

CHANGE_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "action", kind = .String},
	{name = "pinned", kind = .Bool, opt = true},
	{name = "changed", kind = .Bool, help = "false when it was already so, or under --dry-run"},
	{name = "total", kind = .Int, help = "entries in the history now"},
}

CLEAR_FIELDS := []kit.Field {
	{name = "removed", kind = .Int},
	{name = "kept", kind = .Int, help = "pins spared by --keep-pinned"},
	{name = "written", kind = .Bool},
}

ADD_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "outcome", kind = .String, help = "stored or duplicate"},
	{name = "mime", kind = .String},
	{name = "size", kind = .Int},
	{name = "total", kind = .Int},
}

COPY_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "kind", kind = .String},
	{name = "copied", kind = .Bool},
	{name = "detail", kind = .String},
}

STATUS_FIELDS := []kit.Field {
	{name = "dir", kind = .String, help = "where the history lives"},
	{name = "history_file", kind = .String},
	{name = "file_mode", kind = .String, help = "0600, or what it is if not"},
	{name = "entries", kind = .Int},
	{name = "text", kind = .Int},
	{name = "images", kind = .Int},
	{name = "pinned", kind = .Int},
	{name = "secrets", kind = .Int, help = "entries flagged as secrets, which are never printed"},
	{name = "cap", kind = .Int, help = "the oldest unpinned entry goes past this"},
	{name = "bytes", kind = .Int, help = "text and images together"},
	{name = "can_copy", kind = .Bool, help = "a Wayland session and wl-copy, so copy can work"},
}

SHOTS_FIELDS := []kit.Field {{name = "dir", kind = .String}, {name = "written", kind = .Bool}}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "list",
		summary = "the history, pinned first, then newest first",
		effect = .Read,
		flags = {
			{name = "filter", kind = .Enum, values = {"all", "text", "images", "pinned"}, def = "all", help = "the window's filter tabs"},
			{name = "limit", kind = .Int, def = "50", help = "at most this many; 0 for all"},
		},
		out = LIST_FIELDS,
		examples = {"clipboard list --json", "clipboard list --filter pinned"},
		run = cmd_list,
	},
	{
		verb = "search",
		summary = "the window's fuzzy search over the history",
		effect = .Read,
		args = {{name = "query", kind = .String, required = true}},
		flags = {
			{name = "filter", kind = .Enum, values = {"all", "text", "images", "pinned"}, def = "all"},
			{name = "limit", kind = .Int, def = "20"},
		},
		out = SEARCH_FIELDS,
		examples = {"clipboard search select --json", "clipboard search \"odin build\" --filter text"},
		run = cmd_search,
	},
	{
		verb = "show",
		summary = "one entry in full; never a secret's text",
		effect = .Read,
		args = {{name = "id", kind = .String, help = "an id or a unique prefix of 4 or more", required = true}},
		out = SHOW_FIELDS,
		examples = {"clipboard show 3f9a --json"},
		run = cmd_show,
	},
	{
		verb = "status",
		summary = "where the history is, what is in it, and whether its file is private",
		effect = .Read,
		out = STATUS_FIELDS,
		examples = {"clipboard status --json"},
		run = cmd_status,
	},
	{
		verb = "pin",
		summary = "keep an entry past the cap, at the top (Ctrl+P)",
		effect = .Idempotent,
		args = {{name = "id", kind = .String, required = true}},
		out = CHANGE_FIELDS,
		examples = {"clipboard pin 3f9a --json"},
		run = cmd_pin,
	},
	{
		verb = "unpin",
		summary = "let a pinned entry age out again (Ctrl+P)",
		effect = .Idempotent,
		args = {{name = "id", kind = .String, required = true}},
		out = CHANGE_FIELDS,
		examples = {"clipboard unpin 3f9a --json"},
		run = cmd_unpin,
	},
	{
		verb = "add",
		summary = "record text as if it had been copied, through the same gate",
		effect = .Mutate,
		args = {{name = "text", kind = .String, help = "\\n is a new line", required = true}},
		flags = {{name = "mime", kind = .String, def = "text/plain;charset=utf-8", help = "the type it is recorded under"}},
		out = ADD_FIELDS,
		examples = {"clipboard add \"ssh -L 8080:localhost:80 host\" --json"},
		run = cmd_add,
	},
	{
		verb = "copy",
		summary = "put an entry back on the clipboard (Enter); needs a Wayland session",
		effect = .Mutate,
		args = {{name = "id", kind = .String, required = true}},
		out = COPY_FIELDS,
		examples = {"clipboard copy 3f9a --json"},
		run = cmd_copy,
	},
	{
		verb = "delete",
		summary = "remove one entry, and its stored image (Del)",
		effect = .Destructive,
		args = {{name = "id", kind = .String, required = true}},
		out = CHANGE_FIELDS,
		examples = {"clipboard delete 3f9a --yes --json"},
		run = cmd_delete,
	},
	{
		verb = "clear",
		summary = "remove the whole history and every stored image (Ctrl+L)",
		effect = .Destructive,
		flags = {{name = "keep-pinned", kind = .Bool, help = "spare the pinned entries"}},
		out = CLEAR_FIELDS,
		examples = {"clipboard clear --yes --json", "clipboard clear --keep-pinned --yes"},
		run = cmd_clear,
	},
	{
		verb = "shots",
		summary = "render the window offscreen from a made-up history; reads no clipboard",
		effect = .Mutate,
		args = {{name = "dir", kind = .Path, required = true}},
		out = SHOTS_FIELDS,
		examples = {"clipboard shots /tmp/clipboard-shots --json", "clipboard --shots /tmp/clipboard-shots"},
		aliases = {"--shots"},
		run = cmd_shots,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "clipboard",
			summary  = "the clipboard history",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `With no command, clipboard opens the window, which watches the selection and
records it. The command line works on the recorded history and never reads
the clipboard; only copy writes to it, and only in a Wayland session.

A selection flagged as a secret by its owner (x-kde-passwordManagerHint and
the like) is never read or stored. An entry marked as one that turns up in a
history file anyway is never printed: listed redacted, never matched, never
copied. The history is $PALMY_CLIPBOARD_DIR, else ~/.local/share/palmy-clipboard,
mode 0700, its file 0600.`

cli_selftest :: proc() -> int {
	return selftest() == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Keeping what was copied out of the audit log
//
// The kit writes the argv of every command that is not a read into the audit
// log (TODO.md C3: no secret parameters), and the argument to `add` is
// clipboard content — the very thing this program keeps in a 0600 file and
// nowhere else. So it is lifted out before the kit sees the line, as mailcore
// does with --password, and the line carries a placeholder.
// ---------------------------------------------------------------------------

ADD_PLACEHOLDER :: "<text kept out of the audit log>"

@(private = "file")
g_add_text: string
@(private = "file")
g_add_have: bool

scrub_add_text :: proc(args: []string) -> []string {
	if len(args) < 2 || args[0] != "add" {
		return args
	}
	out := make([]string, len(args))
	copy(out, args)
	positional := false
	for i := 1; i < len(out); i += 1 {
		a := out[i]
		if !positional {
			if a == "--" {
				positional = true
				continue
			}
			if a == "--mime" || a == "--identity" {
				i += 1
				continue
			}
			if strings.has_prefix(a, "-") && a != "-" {
				continue
			}
		}
		g_add_text = a
		g_add_have = true
		out[i] = ADD_PLACEHOLDER
		break
	}
	return out
}

// add_text is `add`'s argument: the real one, not the placeholder.
@(private = "file")
add_text :: proc(c: ^kit.Call) -> string {
	v := kit.cli_str(c, "text")
	if v == ADD_PLACEHOLDER && g_add_have {
		return g_add_text
	}
	return v
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
cli_open :: proc() {
	sync.mutex_lock(&g.mu)
	load_locked(false)
}

@(private = "file")
cli_close :: proc() {
	sync.mutex_unlock(&g.mu)
}

@(private = "file")
filter_of :: proc(c: ^kit.Call) -> Filter {
	switch kit.cli_str(c, "filter") {
	case "text":
		return .Text
	case "images":
		return .Images
	case "pinned":
		return .Pinned
	}
	return .All
}

// entry_json is the one place an entry becomes output, so the one place the
// sensitivity gate has to hold for every listing. It never includes the text.
// Eight keys, no more, so that a person's `clipboard list` is a table (the
// kit tables at most eight); `show` has the type and the rest.
@(private = "file")
entry_json :: proc(e: ^Entry) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", entry_ref(e))
	kit.jset_str(o, "kind", e.kind == .Text ? "text" : "image")
	kit.jset_str(o, "preview", entry_secret(e) ? SECRET_PREVIEW : short(e.preview, 72))
	kit.jset_int(o, "size", e.size)
	kit.jset_int(o, "when", int(e.when_))
	kit.jset_str(o, "ago", ago(e.when_))
	kit.jset_bool(o, "pinned", e.pinned)
	kit.jset_bool(o, "secret", entry_secret(e))
	return o
}

// cli_find resolves an id argument, failing the call when it does not.
@(private = "file")
cli_find :: proc(c: ^kit.Call) -> (i: int, code: int) {
	ref := kit.cli_str(c, "id")
	idx, ambiguous := find_locked(ref)
	if ambiguous {
		code = kit.cli_failf(c, kit.EXIT_USAGE, "%q names more than one entry; give more of the id", ref)
		kit.cli_err_field(c, "id", ref)
		return -1, code
	}
	if idx < 0 {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no entry %q (ids are 16 hex digits; a prefix needs 4)", ref)
		kit.cli_err_field(c, "id", ref)
		return -1, code
	}
	return idx, kit.EXIT_OK
}

@(private = "file")
unescape_arg :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 1
				continue
			case 't':
				strings.write_byte(&b, '\t')
				i += 1
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

@(private = "file")
list_out :: proc(c: ^kit.Call, query: string, limit: int) {
	hits := make([dynamic]Ranked, context.temp_allocator)
	rank_locked(&hits, query, filter_of(c))
	list := kit.jarr()
	n := 0
	for r in hits {
		if limit > 0 && n >= limit {
			break
		}
		kit.jpush(list, entry_json(&g.items[r.idx]))
		n += 1
	}
	kit.jset_int(c.out, "count", n)
	kit.jset(c.out, "entries", list)
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	list_out(c, "", kit.cli_int(c, "limit", 50))
	kit.jset_int(c.out, "total", len(g.items))
	kit.jset_str(c.out, "filter", kit.cli_str(c, "filter"))
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	q := kit.cli_str(c, "query")
	kit.jset_str(c.out, "query", q)
	list_out(c, q, kit.cli_int(c, "limit", 20))
	return kit.EXIT_OK
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	i, code := cli_find(c)
	if code != kit.EXIT_OK {
		return code
	}
	e := &g.items[i]
	secret := entry_secret(e)
	kit.jset_str(c.out, "id", entry_ref(e))
	kit.jset_str(c.out, "kind", e.kind == .Text ? "text" : "image")
	kit.jset_str(c.out, "mime", e.mime)
	kit.jset_int(c.out, "size", e.size)
	kit.jset_int(c.out, "when", int(e.when_))
	kit.jset_str(c.out, "ago", ago(e.when_))
	kit.jset_bool(c.out, "pinned", e.pinned)
	kit.jset_bool(c.out, "secret", secret)
	switch e.kind {
	case .Text:
		if secret {
			kit.cli_note(c, "clipboard: %s is flagged as a secret; its text is never printed", entry_ref(e))
		} else {
			kit.jset_str(c.out, "text", e.text)
			kit.jset_bool(c.out, "truncated", e.truncated)
		}
	case .Image:
		kit.jset_str(c.out, "file", e.blob)
		kit.jset_int(c.out, "width", e.w)
		kit.jset_int(c.out, "height", e.h)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	dir := data_dir()
	hist := fmt.tprintf("%s/history", dir)
	mode := "absent"
	if fi, err := os.stat(hist, context.temp_allocator); err == nil {
		mode = fmt.tprintf("0%o", transmute(u32)fi.mode & 0o777)
	}
	text, images, pinned, secrets, bytes := 0, 0, 0, 0, 0
	for &e in g.items {
		if e.kind == .Text {text += 1} else {images += 1}
		if e.pinned {pinned += 1}
		if entry_secret(&e) {secrets += 1}
		bytes += e.size
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_str(c.out, "history_file", hist)
	kit.jset_str(c.out, "file_mode", mode)
	kit.jset_int(c.out, "entries", len(g.items))
	kit.jset_int(c.out, "text", text)
	kit.jset_int(c.out, "images", images)
	kit.jset_int(c.out, "pinned", pinned)
	kit.jset_int(c.out, "secrets", secrets)
	kit.jset_int(c.out, "cap", HISTORY_CAP)
	kit.jset_int(c.out, "bytes", bytes)
	kit.jset_bool(c.out, "can_copy", os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" && kit.has_tool("wl-copy"))
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Edits
// ---------------------------------------------------------------------------

@(private = "file")
set_pin :: proc(c: ^kit.Call, on: bool) -> int {
	cli_open()
	defer cli_close()
	i, code := cli_find(c)
	if code != kit.EXIT_OK {
		return code
	}
	e := &g.items[i]
	changed := e.pinned != on
	kit.jset_str(c.out, "id", entry_ref(e))
	if changed && !c.dry_run {
		set_pinned_locked(i, on)
	}
	kit.jset_str(c.out, "action", on ? "pin" : "unpin")
	kit.jset_bool(c.out, "pinned", c.dry_run ? e.pinned : on)
	kit.jset_bool(c.out, "changed", changed && !c.dry_run)
	kit.jset_int(c.out, "total", len(g.items))
	return kit.EXIT_OK
}

@(private = "file")
cmd_pin :: proc(c: ^kit.Call) -> int {return set_pin(c, true)}
@(private = "file")
cmd_unpin :: proc(c: ^kit.Call) -> int {return set_pin(c, false)}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	i, code := cli_find(c)
	if code != kit.EXIT_OK {
		return code
	}
	kit.jset_str(c.out, "id", entry_ref(&g.items[i]))
	if !c.dry_run {
		delete_locked(i)
	}
	kit.jset_str(c.out, "action", "delete")
	kit.jset_bool(c.out, "changed", !c.dry_run)
	kit.jset_int(c.out, "total", len(g.items))
	return kit.EXIT_OK
}

@(private = "file")
cmd_clear :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	keep := kit.cli_bool(c, "keep-pinned")
	removed, kept := 0, 0
	for &e in g.items {
		if keep && e.pinned {kept += 1} else {removed += 1}
	}
	if !c.dry_run {
		removed = clear_all_locked(keep)
	}
	kit.jset_int(c.out, "removed", removed)
	kit.jset_int(c.out, "kept", kept)
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

@(private = "file")
cmd_add :: proc(c: ^kit.Call) -> int {
	ensure_dirs()
	cli_open()
	text := unescape_arg(add_text(c))
	mime := kit.cli_str(c, "mime")
	// The watcher's own decision, given the type list a copy of this would
	// have advertised. A secret is refused before the payload is looked at.
	if secret, hint := is_sensitive(mime); secret {
		cli_close()
		code := kit.cli_failf(c, kit.EXIT_FAILED, "the type carries a password-manager hint (%s); a secret is never recorded", hint)
		kit.cli_err_field(c, "outcome", "secret")
		return code
	}
	if c.dry_run {
		kit.jset_str(c.out, "id", fmt.tprintf("%016x", fnv(transmute([]u8)text)))
		kit.jset_str(c.out, "outcome", "stored")
		kit.jset_str(c.out, "mime", mime)
		kit.jset_int(c.out, "size", len(text))
		kit.jset_int(c.out, "total", len(g.items))
		cli_close()
		return kit.EXIT_OK
	}
	// `push`, inside ingest_selection, takes the lock itself.
	if len(g.items) > 0 {
		g.last_id = g.items[0].id
	}
	cli_close()
	r := ingest_selection(mime, transmute([]u8)text)
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	switch r {
	case .Stored, .Duplicate:
	case .Secret:
		code := kit.cli_fail(c, kit.EXIT_FAILED, "flagged as a secret; never recorded")
		kit.cli_err_field(c, "outcome", "secret")
		return code
	case .Unusable:
		return kit.cli_failf(c, kit.EXIT_USAGE, "nothing to record: empty text, or %q is not a text type", mime)
	case .Failed:
		return kit.cli_fail(c, kit.EXIT_FAILED, "could not write the history")
	}
	id := fnv(transmute([]u8)text)
	kit.jset_str(c.out, "id", fmt.tprintf("%016x", id))
	kit.jset_str(c.out, "outcome", r == .Stored ? "stored" : "duplicate")
	kit.jset_str(c.out, "mime", mime)
	kit.jset_int(c.out, "size", len(text))
	kit.jset_int(c.out, "total", len(g.items))
	return kit.EXIT_OK
}

@(private = "file")
cmd_copy :: proc(c: ^kit.Call) -> int {
	cli_open()
	defer cli_close()
	i, code := cli_find(c)
	if code != kit.EXIT_OK {
		return code
	}
	e := &g.items[i]
	kit.jset_str(c.out, "id", entry_ref(e))
	kit.jset_str(c.out, "kind", e.kind == .Text ? "text" : "image")
	if entry_secret(e) {
		code := kit.cli_fail(c, kit.EXIT_FAILED, "flagged as a secret; never copied back out of the history")
		kit.cli_err_field(c, "outcome", "secret")
		return code
	}
	if !g_test && os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no Wayland session to put it on (WAYLAND_DISPLAY is unset)")
	}
	if c.dry_run {
		kit.jset_bool(c.out, "copied", false)
		kit.jset_str(c.out, "detail", "would copy it")
		return kit.EXIT_OK
	}
	msg, ok := copy_entry(e)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, msg)
	}
	kit.jset_bool(c.out, "copied", true)
	kit.jset_str(c.out, "detail", msg)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := strings.clone(kit.cli_str(c, "dir"))
	// The shots render offscreen frames, which free the temp allocator — where
	// the kit keeps the parsed command line it reads again for the audit
	// record (TODO.md C3). Move it out first.
	argv := make([]string, len(c.argv))
	for a, i in c.argv {
		argv[i] = strings.clone(a)
	}
	c.argv = argv
	if !c.dry_run && shots(dir) != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render the shots into %s", dir)
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}
