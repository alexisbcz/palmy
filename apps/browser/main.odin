// browser: a web browser whose chrome is Palmframe's own (palmy + shadcn) and
// whose pages are drawn by the engine each profile chooses -- Chromium (Blink,
// through CEF) or Firefox (Gecko, Firefox itself in a private compositor).
//
//	browser                         open a window (the identity in
//	                                $PALM_IDENTITY, else "personal")
//	browser example.com             open it in the running window, or a new one
//	browser --identity work         a window for another identity
//	browser open URL                the same, as a command, with --json
//	browser bookmarks --json        and the rest: `browser --help`
//
// The command line and the window share one implementation: bookmarks,
// history and settings are the same files read by the same procedures, and a
// running window is reached over its control socket.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "open",
		summary = "open a URL (or search) in this identity's window, starting one if needed",
		effect = .Mutate,
		args = {{name = "url", kind = .String, help = "an address, or words to search for", required = true, variadic = true}},
		flags = {{name = "new-window", kind = .Bool, help = "always start a separate window"}},
		out = {{name = "url", kind = .String}, {name = "identity", kind = .String}, {name = "running", kind = .Bool, help = "a window was already open and took it"}},
		examples = {"browser open example.com", "browser open 'odin language' --json", "PALM_IDENTITY=work browser open https://intranet.example"},
		run = cmd_open,
	},
	{
		verb = "tabs",
		summary = "the tabs open in this identity's window",
		effect = .Read,
		out = {
			{name = "identity", kind = .String},
			{name = "running", kind = .Bool},
			{name = "tabs", kind = .Array, of = []kit.Field{{name = "url", kind = .String}, {name = "title", kind = .String}, {name = "active", kind = .Bool}, {name = "loading", kind = .Bool}}},
		},
		examples = {"browser tabs --json"},
		run = cmd_tabs,
	},
	{
		verb = "bookmarks",
		summary = "list bookmarks, depth first, with their folders",
		effect = .Read,
		flags = {
			{name = "folder", kind = .String, help = "only this folder (id, title, 'toolbar' or 'other')"},
			{name = "query", short = "q", kind = .String, help = "only those whose title or address contains this"},
			{name = "deleted", kind = .Bool, help = "include tombstones, for inspecting sync state"},
		},
		out = {
			{name = "identity", kind = .String},
			{name = "count", kind = .Int},
			{name = "bookmarks", kind = .Array, of = []kit.Field{
				{name = "id", kind = .String},
				{name = "kind", kind = .String},
				{name = "title", kind = .String},
				{name = "url", kind = .String},
				{name = "folder", kind = .String},
				{name = "parent", kind = .String},
				{name = "deleted", kind = .Bool},
			}},
		},
		examples = {"browser bookmarks --json", "browser bookmarks --folder toolbar", "browser bookmarks -q odin --json"},
		run = cmd_bookmarks,
	},
	{
		verb = "bookmark-add",
		summary = "add a bookmark (or a folder, with --folder-name)",
		effect = .Mutate,
		args = {{name = "url", kind = .String, help = "the address", required = true}},
		flags = {
			{name = "title", kind = .String, help = "defaults to the address"},
			{name = "folder", kind = .String, help = "where: id, title, 'toolbar' or 'other'", def = "toolbar"},
		},
		out = {{name = "id", kind = .String}, {name = "title", kind = .String}, {name = "url", kind = .String}, {name = "parent", kind = .String}},
		examples = {"browser bookmark-add https://odin-lang.org --title Odin", "browser bookmark-add https://example.com --folder other --json"},
		run = cmd_bookmark_add,
	},
	{
		verb = "bookmark-edit",
		summary = "rename, re-address or move a bookmark; each change syncs on its own",
		effect = .Mutate,
		args = {{name = "id", kind = .String, help = "the bookmark's id (or a unique prefix), or its exact address", required = true}},
		flags = {
			{name = "title", kind = .String, help = "a new name"},
			{name = "url", kind = .String, help = "a new address"},
			{name = "folder", kind = .String, help = "move it here: id, title, 'toolbar' or 'other'"},
		},
		out = {{name = "id", kind = .String}, {name = "title", kind = .String}, {name = "url", kind = .String}, {name = "parent", kind = .String}},
		examples = {"browser bookmark-edit 3f0c1a --title 'Odin language'", "browser bookmark-edit https://lwn.net --folder toolbar"},
		run = cmd_bookmark_edit,
	},
	{
		verb = "bookmark-remove",
		summary = "delete a bookmark or folder (a tombstone, so the delete syncs)",
		effect = .Destructive,
		args = {{name = "id", kind = .String, help = "the bookmark's id, or its exact address", required = true}},
		out = {{name = "id", kind = .String}, {name = "removed", kind = .Bool}},
		examples = {"browser bookmark-remove 3f0c…  --yes"},
		run = cmd_bookmark_remove,
	},
	{
		verb = "history",
		summary = "visits, newest first",
		effect = .Read,
		flags = {
			{name = "limit", short = "n", kind = .Int, help = "at most this many", def = "50"},
			{name = "query", short = "q", kind = .String, help = "only titles or addresses containing this"},
		},
		out = {
			{name = "identity", kind = .String},
			{name = "count", kind = .Int},
			{name = "visits", kind = .Array, of = []kit.Field{{name = "url", kind = .String}, {name = "title", kind = .String}, {name = "at", kind = .Int}}},
		},
		examples = {"browser history -n 10 --json"},
		run = cmd_history,
	},
	{
		verb = "history-clear",
		summary = "forget every visit in this profile",
		effect = .Destructive,
		out = {{name = "forgotten", kind = .Int}},
		examples = {"browser history-clear --yes"},
		run = cmd_history_clear,
	},
	{
		verb = "engines",
		summary = "which engines are installed, and which this profile uses",
		effect = .Read,
		out = {
			{name = "identity", kind = .String},
			{name = "chosen", kind = .String},
			{name = "engines", kind = .Array, of = []kit.Field{{name = "name", kind = .String}, {name = "available", kind = .Bool}, {name = "host", kind = .String}, {name = "runtime", kind = .String}, {name = "detail", kind = .String}}},
		},
		examples = {"browser engines --json"},
		run = cmd_engines,
	},
	{
		verb = "engine",
		summary = "choose this profile's engine; a running window switches after a restart",
		effect = .Idempotent,
		args = {{name = "name", kind = .Enum, values = {"chromium", "firefox"}, help = "the engine", required = true}},
		out = {{name = "identity", kind = .String}, {name = "engine", kind = .String}, {name = "changed", kind = .Bool}, {name = "available", kind = .Bool}},
		examples = {"browser engine firefox", "PALM_IDENTITY=work browser engine chromium --json"},
		run = cmd_engine,
	},
	{
		verb = "profiles",
		summary = "the browser profiles on this machine, one per identity",
		effect = .Read,
		out = {{name = "profiles", kind = .Array, of = []kit.Field{{name = "identity", kind = .String}, {name = "engine", kind = .String}, {name = "dir", kind = .String}, {name = "color", kind = .String}, {name = "running", kind = .Bool}}}},
		examples = {"browser profiles --json"},
		run = cmd_profiles,
	},
	{
		verb = "export",
		summary = "write the bookmarks as a Netscape bookmark file every browser imports",
		effect = .Read,
		flags = {{name = "out", short = "o", kind = .Path, help = "write here instead of stdout"}},
		out = {{name = "path", kind = .String}, {name = "bookmarks", kind = .Int}},
		examples = {"browser export -o bookmarks.html"},
		run = cmd_export,
	},
	{
		verb = "import",
		summary = "add the bookmarks from a Netscape bookmark file (Firefox, Chrome, Safari exports)",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, help = "the exported .html", required = true}},
		out = {{name = "added", kind = .Int}},
		examples = {"browser import ~/Downloads/bookmarks.html"},
		run = cmd_import,
	},
	{
		verb = "sync",
		summary = "push and pull bookmarks through the Palmframe account, scoped to this identity",
		effect = .Idempotent,
		out = {{name = "ok", kind = .Bool}, {name = "pushed", kind = .Int}, {name = "pulled", kind = .Int}, {name = "merged", kind = .Int}, {name = "message", kind = .String}},
		examples = {"PALM_IDENTITY=work browser sync --json"},
		run = cmd_sync,
	},
	{
		verb = "sync-status",
		summary = "what a sync would send",
		effect = .Read,
		out = {{name = "identity", kind = .String}, {name = "enabled", kind = .Bool}, {name = "pending", kind = .Int}, {name = "pushed_through", kind = .String}, {name = "pulled_seq", kind = .Int}},
		examples = {"browser sync-status --json"},
		run = cmd_sync_status,
	},
	{
		verb = "shot",
		summary = "render the browser offscreen, with a real page from the profile's engine, to a PNG",
		effect = .Mutate,
		args = {{name = "out", kind = .Path, help = "the PNG to write", required = true}, {name = "url", kind = .String, help = "the page, or palm://newtab, palm://settings, ..."}},
		flags = {
			{name = "engine", kind = .Enum, values = {"chromium", "firefox"}, help = "override the profile's engine"},
			{name = "theme", kind = .Enum, values = {"light", "dark"}, def = "light"},
			{name = "width", kind = .Int, def = "1360"},
			{name = "height", kind = .Int, def = "860"},
			{name = "wait", kind = .Float, help = "seconds to let the page settle after it loads", def = "1.5"},
			{name = "omnibox", kind = .String, help = "type this into the address bar, to show its suggestions"},
			{name = "overlay", kind = .Enum, values = {"none", "menu", "identity", "bookmark", "downloads", "shortcuts"}, def = "none"},
		},
		out = {{name = "path", kind = .String}, {name = "engine", kind = .String}, {name = "version", kind = .String}, {name = "frames", kind = .Int}},
		examples = {"browser shot shot.png https://example.com", "browser shot dark.png palm://newtab --theme dark"},
		run = cmd_shot,
	},
}

@(private = "file")
g_surface: kit.Surface
@(private = "file")
g_built: bool

surface :: proc() -> ^kit.Surface {
	if g_built {
		return &g_surface
	}
	g_surface = kit.Surface {
		noun       = "browser",
		summary    = "a web browser: Palmframe's chrome, Chromium's or Firefox's engine",
		gui        = true,
		takes_path = true,
		selftest   = selftest,
		notes      = NOTES,
		commands   = COMMANDS,
	}
	g_built = true
	return &g_surface
}

NOTES :: `One profile per identity: $PALM_IDENTITY (or --identity) chooses it, and
cookies, storage, history and bookmarks never cross between profiles.
Profiles live under $XDG_DATA_HOME/palmframe/browser/<identity>/;
$PALM_BROWSER_HOME moves them.

Engines: palm-browser-cef (Chromium via CEF) and palm-browser-gecko (Firefox),
found next to this binary, under /usr/lib/palm-browser, or through
$PALM_BROWSER_CEF_HOST, $PALM_BROWSER_GECKO_HOST and $PALM_BROWSER_FIREFOX.

Window flags: browser [--identity NAME] [--new-window] [URL ...]`

main :: proc() {
	args := os.args[1:]
	// The window's own flags come before kit sees the line: `--identity`
	// alone, with no verb, opens a window rather than being a usage error.
	if gui, opt := gui_line(args); gui {
		os.exit(gui_main(opt))
	}
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	os.exit(gui_main({urls = args}))
}

gui_line :: proc(args: []string) -> (gui: bool, opt: Gui_Options) {
	urls := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--identity" && i + 1 < len(args):
			opt.identity = args[i + 1]
			i += 1
		case strings.has_prefix(a, "--identity="):
			opt.identity = a[len("--identity="):]
		case a == "--new-window":
			opt.new_window = true
		case a == "--restarted":
			opt.restarted = true
		case strings.has_prefix(a, "-"):
			return false, {}
		case:
			for c in COMMANDS {
				if c.verb == a {
					return false, {}
				}
			}
			if a == "help" {
				return false, {}
			}
			append(&urls, a)
		}
	}
	opt.urls = urls[:]
	return true, opt
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

@(private = "file")
cli_profile :: proc(c: ^kit.Call) -> (p: Profile, ok: bool) {
	id := identity_of(c.identity)
	p, ok = profile_open(id)
	if !ok {
		kit.cli_fail(c, kit.EXIT_USAGE, fmt.tprintf("%q is not a usable identity name", id))
	}
	return
}

@(private = "file")
cmd_open :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	text := strings.join(kit.cli_rest(c), " ", context.temp_allocator)
	if text == "" {
		text = kit.cli_str(c, "url")
	}
	url, _ := resolve_input(text, search_engine(prof.settings.search), context.temp_allocator)
	kit.jset_str(c.out, "url", url)
	kit.jset_str(c.out, "identity", prof.identity)
	if c.dry_run {
		kit.jset_bool(c.out, "running", false)
		return kit.EXIT_OK
	}
	if !kit.cli_bool(c, "new-window") {
		if reply, ok := remote_send(prof.identity, fmt.tprintf("open %s", url)); ok && reply == "ok" {
			kit.jset_bool(c.out, "running", true)
			return kit.EXIT_OK
		}
	}
	kit.jset_bool(c.out, "running", false)
	argv := []string{own_binary(), "--identity", prof.identity, url}
	if kit.cli_bool(c, "new-window") {
		argv = []string{own_binary(), "--identity", prof.identity, "--new-window", url}
	}
	if !kit.launch(argv) {
		return kit.cli_fail(c, kit.EXIT_FAILED, "could not start the browser")
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_tabs :: proc(c: ^kit.Call) -> int {
	id := identity_of(c.identity)
	kit.jset_str(c.out, "identity", id)
	reply, ok := remote_send(id, "tabs")
	kit.jset_bool(c.out, "running", ok)
	arr := kit.jarr()
	if ok {
		if v, pok := kit_parse_array(reply); pok {
			arr = v
		}
	}
	kit.jset(c.out, "tabs", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_bookmarks :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	folder := ""
	if f := kit.cli_str(c, "folder"); f != "" {
		folder = find_folder(&b, f)
		if folder == "" {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no folder %q", f))
		}
	}
	q := strings.to_lower(kit.cli_str(c, "query"), context.temp_allocator)
	with_deleted := kit.cli_bool(c, "deleted")
	paths := make(map[string]string, context.temp_allocator)
	for f in folders(&b, context.temp_allocator) {
		paths[f.id] = f.path
	}
	arr := kit.jarr()
	rows := kit.jarr()
	n := 0
	emit_one :: proc(arr, rows: ^kit.Json, r: Bookmark, folder_path: string) {
		o := kit.jobj()
		kit.jset_str(o, "id", r.id)
		kit.jset_str(o, "kind", r.kind)
		kit.jset_str(o, "title", r.title)
		kit.jset_str(o, "url", r.url)
		kit.jset_str(o, "folder", folder_path)
		kit.jset_str(o, "parent", r.parent)
		kit.jset_bool(o, "deleted", r.deleted)
		kit.jpush(arr, o)
		row := kit.jobj()
		kit.jset_str(row, "title", r.kind == "folder" ? fmt.tprintf("%s/", r.title) : r.title)
		kit.jset_str(row, "url", r.url)
		kit.jset_str(row, "folder", folder_path)
		kit.jset_str(row, "id", r.id[:8])
		kit.jpush(rows, row)
	}
	walk :: proc(b: ^Bookmarks, parent: string, paths: map[string]string, q: string, arr, rows: ^kit.Json, n: ^int) {
		for k in children(b, parent, context.temp_allocator) {
			if k.kind != "separator" {
				if q == "" || strings.contains(strings.to_lower(k.title, context.temp_allocator), q) || strings.contains(strings.to_lower(k.url, context.temp_allocator), q) {
					emit_one(arr, rows, k, paths[parent])
					n^ += 1
				}
			}
			if k.kind == "folder" {
				walk(b, k.id, paths, q, arr, rows, n)
			}
		}
	}
	if folder != "" {
		walk(&b, folder, paths, q, arr, rows, &n)
	} else {
		walk(&b, ROOT_TOOLBAR, paths, q, arr, rows, &n)
		walk(&b, ROOT_OTHER, paths, q, arr, rows, &n)
	}
	if with_deleted {
		for r in b.file.items {
			if r.deleted {
				emit_one(arr, rows, r, "(deleted)")
				n += 1
			}
		}
	}
	kit.jset_str(c.out, "identity", prof.identity)
	kit.jset_int(c.out, "count", n)
	kit.jset(c.out, "bookmarks", c.json ? arr : rows)
	return kit.EXIT_OK
}

@(private = "file")
cmd_bookmark_add :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	profile_ensure(&prof)
	settings_save(&prof)
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	url, _ := resolve_input(kit.cli_str(c, "url"), search_engine(prof.settings.search), context.temp_allocator)
	folder := find_folder(&b, kit.cli_str(c, "folder"))
	if folder == "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no folder %q", kit.cli_str(c, "folder")))
	}
	title := kit.cli_str(c, "title")
	if title == "" {
		title = display_url(url)
	}
	r := bookmark_add(&b, folder, title, url)
	kit.jset_str(c.out, "id", r.id)
	kit.jset_str(c.out, "title", r.title)
	kit.jset_str(c.out, "url", r.url)
	kit.jset_str(c.out, "parent", r.parent)
	if !c.dry_run && !bookmarks_save(&b) {
		return kit.cli_fail(c, kit.EXIT_FAILED, "could not write bookmarks.json")
	}
	return kit.EXIT_OK
}

// resolve_bookmark finds a bookmark by id, unique id prefix (as the table
// prints them) or exact address.
@(private = "file")
resolve_bookmark :: proc(c: ^kit.Call, b: ^Bookmarks, key: string) -> (id: string, code: int) {
	if r := find(b, key); r != nil {
		return r.id, kit.EXIT_OK
	}
	if r := bookmarked(b, key); r != nil {
		return r.id, kit.EXIT_OK
	}
	for r in b.file.items {
		if strings.has_prefix(r.id, key) && len(key) >= 6 && !r.deleted {
			if id != "" {
				return "", kit.cli_fail(c, kit.EXIT_USAGE, fmt.tprintf("%q matches more than one bookmark", key))
			}
			id = r.id
		}
	}
	if id == "" || is_root(id) {
		return "", kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no bookmark %q", key))
	}
	return id, kit.EXIT_OK
}

@(private = "file")
cmd_bookmark_edit :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	id, code := resolve_bookmark(c, &b, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	r := find(&b, id)
	if kit.cli_has(c, "title") || kit.cli_has(c, "url") {
		title := kit.cli_has(c, "title") ? kit.cli_str(c, "title") : r.title
		url := kit.cli_has(c, "url") ? kit.cli_str(c, "url") : r.url
		bookmark_edit(&b, id, title, url)
	}
	if f := kit.cli_str(c, "folder"); f != "" {
		folder := find_folder(&b, f)
		if folder == "" {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no folder %q", f))
		}
		kids := children(&b, folder, context.temp_allocator)
		after := len(kids) > 0 ? kids[len(kids) - 1].id : ""
		if !bookmark_move(&b, id, folder, after) {
			return kit.cli_fail(c, kit.EXIT_USAGE, "it cannot go there")
		}
	}
	r = find(&b, id)
	kit.jset_str(c.out, "id", r.id)
	kit.jset_str(c.out, "title", r.title)
	kit.jset_str(c.out, "url", r.url)
	kit.jset_str(c.out, "parent", r.parent)
	if !c.dry_run && !bookmarks_save(&b) {
		return kit.cli_fail(c, kit.EXIT_FAILED, "could not write bookmarks.json")
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_bookmark_remove :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	id, code := resolve_bookmark(c, &b, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	kit.jset_str(c.out, "id", id)
	ok := bookmark_delete(&b, id)
	kit.jset_bool(c.out, "removed", ok)
	if ok && !c.dry_run {
		bookmarks_save(&b)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_history :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	h := history_open(profile_path(&prof, "history.jsonl"), prof.settings.device)
	limit := kit.cli_int(c, "limit", 50)
	q := strings.to_lower(kit.cli_str(c, "query"), context.temp_allocator)
	arr := kit.jarr()
	rows := kit.jarr()
	n := 0
	#reverse for v in h.visits {
		if n >= limit {break}
		if q != "" && !strings.contains(strings.to_lower(v.title, context.temp_allocator), q) && !strings.contains(strings.to_lower(v.url, context.temp_allocator), q) {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "url", v.url)
		kit.jset_str(o, "title", v.title)
		kit.jset_i64(o, "at", v.at)
		kit.jpush(arr, o)
		row := kit.jobj()
		kit.jset_str(row, "when", time_ago(v.at))
		kit.jset_str(row, "title", v.title)
		kit.jset_str(row, "url", v.url)
		kit.jpush(rows, row)
		n += 1
	}
	kit.jset_str(c.out, "identity", prof.identity)
	kit.jset_int(c.out, "count", n)
	kit.jset(c.out, "visits", c.json ? arr : rows)
	return kit.EXIT_OK
}

@(private = "file")
cmd_history_clear :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	h := history_open(profile_path(&prof, "history.jsonl"), prof.settings.device)
	n := len(h.visits)
	if !c.dry_run {
		history_forget_all(&h)
		history_compact(&h)
	}
	kit.jset_int(c.out, "forgotten", n)
	return kit.EXIT_OK
}

@(private = "file")
cmd_engines :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	arr := kit.jarr()
	for k in Engine_Kind {
		info := engine_info(k)
		o := kit.jobj()
		kit.jset_str(o, "name", engine_name(k))
		kit.jset_bool(o, "available", info.available)
		kit.jset_str(o, "host", info.host)
		kit.jset_str(o, "runtime", info.runtime)
		kit.jset_str(o, "detail", info.detail)
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "identity", prof.identity)
	kit.jset_str(c.out, "chosen", engine_name(profile_engine(&prof)))
	kit.jset(c.out, "engines", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_engine :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	k, _ := engine_parse(kit.cli_str(c, "name"))
	changed := profile_engine(&prof) != k
	prof.settings.engine = engine_name(k)
	if changed && !c.dry_run {
		profile_ensure(&prof)
		if !settings_save(&prof) {
			return kit.cli_fail(c, kit.EXIT_FAILED, "could not write settings.json")
		}
	}
	kit.jset_str(c.out, "identity", prof.identity)
	kit.jset_str(c.out, "engine", engine_name(k))
	kit.jset_bool(c.out, "changed", changed)
	kit.jset_bool(c.out, "available", engine_info(k).available)
	if changed {
		if _, running := remote_send(prof.identity, "ping"); running {
			kit.cli_note(c, "the open window switches engines after a restart")
		}
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_profiles :: proc(c: ^kit.Call) -> int {
	arr := kit.jarr()
	for id in profile_list(context.temp_allocator) {
		prof, ok := profile_open(id, context.temp_allocator)
		if !ok {continue}
		o := kit.jobj()
		kit.jset_str(o, "identity", id)
		kit.jset_str(o, "engine", engine_name(profile_engine(&prof)))
		kit.jset_str(o, "dir", prof.dir)
		kit.jset_str(o, "color", hex(prof.color))
		_, running := remote_send(id, "ping")
		kit.jset_bool(o, "running", running)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "profiles", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_export :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	text := export_html(&b, context.temp_allocator)
	path := kit.cli_str(c, "out")
	kit.jset_int(c.out, "bookmarks", len(all_visible(&b, context.temp_allocator)))
	if path == "" {
		if !c.json {
			fmt.print(text)
			c.out = nil
			os.exit(0)
		}
		kit.jset_str(c.out, "path", "")
		return kit.EXIT_OK
	}
	if !c.dry_run && !write_atomic(path, transmute([]u8)text) {
		return kit.cli_fail(c, kit.EXIT_FAILED, fmt.tprintf("could not write %s", path))
	}
	kit.jset_str(c.out, "path", path)
	return kit.EXIT_OK
}

@(private = "file")
cmd_import :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	path := kit.cli_str(c, "file")
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("cannot read %s", path))
	}
	profile_ensure(&prof)
	settings_save(&prof)
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	n := import_html(&b, string(data))
	if !c.dry_run {
		bookmarks_save(&b)
	}
	kit.jset_int(c.out, "added", n)
	return kit.EXIT_OK
}

@(private = "file")
cmd_sync :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	if c.dry_run {
		kit.jset_bool(c.out, "ok", true)
		kit.jset_int(c.out, "pushed", len(pending(&b, context.temp_allocator)))
		kit.jset_int(c.out, "pulled", 0)
		kit.jset_int(c.out, "merged", 0)
		kit.jset_str(c.out, "message", "dry run: nothing sent")
		return kit.EXIT_OK
	}
	r := sync_bookmarks(&b, prof.identity)
	if b.dirty {
		bookmarks_save(&b)
	}
	kit.jset_bool(c.out, "ok", r.ok)
	kit.jset_int(c.out, "pushed", r.pushed)
	kit.jset_int(c.out, "pulled", r.pulled)
	kit.jset_int(c.out, "merged", r.merged)
	kit.jset_str(c.out, "message", r.message)
	if !r.ok {
		return kit.cli_fail(c, strings.contains(r.message, "not signed in") ? kit.EXIT_UNAVAILABLE : kit.EXIT_FAILED, r.message)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_sync_status :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	b := bookmarks_open(profile_path(&prof, "bookmarks.json"), prof.settings.device)
	kit.jset_str(c.out, "identity", prof.identity)
	kit.jset_bool(c.out, "enabled", prof.settings.sync_bookmarks)
	kit.jset_int(c.out, "pending", len(pending(&b, context.temp_allocator)))
	kit.jset_str(c.out, "pushed_through", b.file.pushed_through)
	kit.jset_i64(c.out, "pulled_seq", b.file.pulled_seq)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	prof, pok := cli_profile(c)
	if !pok {return kit.EXIT_USAGE}
	opt := Shot_Options {
		out      = kit.cli_str(c, "out"),
		url      = kit.cli_str(c, "url"),
		dark     = kit.cli_str(c, "theme") == "dark",
		width    = kit.cli_int(c, "width", 1360),
		height   = kit.cli_int(c, "height", 860),
		wait     = kit.cli_f64(c, "wait", 1.5),
		omnibox  = kit.cli_str(c, "omnibox"),
		overlay  = kit.cli_str(c, "overlay"),
	}
	if e := kit.cli_str(c, "engine"); e != "" {
		k, _ := engine_parse(e)
		opt.engine = k
		opt.engine_set = true
	}
	res := shot(&prof, opt)
	if res.error != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, res.error)
	}
	kit.jset_str(c.out, "path", opt.out)
	kit.jset_str(c.out, "engine", res.engine)
	kit.jset_str(c.out, "version", res.version)
	kit.jset_int(c.out, "frames", res.frames)
	return kit.EXIT_OK
}
