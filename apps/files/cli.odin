package main

// The command-line front end of Files.
//
// Nothing below touches the filesystem itself. Listing, sorting, the kind
// labels, copy, move, rename, the trash — all of it is fs.odin, the same
// procedures the window calls from its context menu and its keys. A folder
// listed here is in the order the window shows it with the same Kind column,
// and a file trashed here can be restored from the window's trash (or from
// any other freedesktop file manager, since it is the standard trash).
//
// Every command acts only on the paths it is given. The one place it reaches
// for on its own is the trash, which is $XDG_DATA_HOME/Trash (else
// ~/.local/share/Trash) — and `--trash-dir` names another, which is what the
// self-test does so it never touches the real one.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

ENTRY_FIELDS :: []kit.Field {
	{name = "name", kind = .String},
	{name = "path", kind = .String},
	{name = "kind", kind = .String, help = "the Kind column: \"PNG image\", \"Folder\", …"},
	{name = "is_dir", kind = .Bool},
	{name = "is_link", kind = .Bool},
	{name = "hidden", kind = .Bool},
	{name = "size", kind = .Int, help = "bytes; a folder's own entry size"},
	{name = "size_text", kind = .String, help = "as the window shows it: \"4.2 KB\", \"--\" for a folder"},
	{name = "modified", kind = .String, help = "UTC, ISO 8601"},
}

LIST_FIELDS :: []kit.Field {
	{name = "dir", kind = .String},
	{name = "sort", kind = .String},
	{name = "count", kind = .Int, help = "entries shown"},
	{name = "total", kind = .Int, help = "entries in the folder, hidden ones included"},
	{name = "entries", kind = .Array, of = ENTRY_FIELDS},
}

STAT_FIELDS :: []kit.Field {
	{name = "name", kind = .String},
	{name = "path", kind = .String},
	{name = "kind", kind = .String},
	{name = "is_dir", kind = .Bool},
	{name = "is_link", kind = .Bool},
	{name = "hidden", kind = .Bool},
	{name = "size", kind = .Int},
	{name = "size_text", kind = .String},
	{name = "modified", kind = .String},
	{name = "mode", kind = .String, help = "as ls prints it: drwxr-xr-x"},
	{name = "link_target", kind = .String, opt = true},
	{name = "items", kind = .Int, opt = true, help = "a folder: files and folders under it, at any depth"},
	{name = "total_size", kind = .Int, opt = true, help = "a folder: bytes under it"},
}

FIND_FIELDS :: []kit.Field {
	{name = "root", kind = .String},
	{name = "pattern", kind = .String},
	{name = "count", kind = .Int},
	{name = "truncated", kind = .Bool, help = "--limit stopped the walk"},
	{name = "matches", kind = .Array, of = ENTRY_FIELDS},
}

MOVED_FIELDS :: []kit.Field {
	{name = "from", kind = .String},
	{name = "to", kind = .String},
}

MADE_FIELDS :: []kit.Field {{name = "path", kind = .String}}

TRASH_FIELDS :: []kit.Field {
	{name = "path", kind = .String, help = "where it was"},
	{name = "trashed_as", kind = .String, help = "its name in the trash, which restore takes"},
	{name = "trash", kind = .String},
}

TRASHED_ITEM :: []kit.Field {
	{name = "name", kind = .String},
	{name = "original", kind = .String},
	{name = "deleted", kind = .String, help = "local time, as the .trashinfo records it"},
	{name = "is_dir", kind = .Bool},
	{name = "size", kind = .Int},
}

TRASHED_FIELDS :: []kit.Field {
	{name = "trash", kind = .String},
	{name = "count", kind = .Int},
	{name = "items", kind = .Array, of = TRASHED_ITEM},
}

RESTORE_FIELDS :: []kit.Field {
	{name = "name", kind = .String},
	{name = "to", kind = .String},
}

EMPTY_FIELDS :: []kit.Field {
	{name = "trash", kind = .String},
	{name = "count", kind = .Int},
	{name = "removed", kind = .Array, of = TRASHED_ITEM},
}

OPEN_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "command", kind = .String},
	{name = "launched", kind = .Bool},
}

PLACES_FIELDS :: []kit.Field {
	{
		name = "places",
		kind = .Array,
		of = {{name = "label", kind = .String}, {name = "path", kind = .String}, {name = "group", kind = .String}},
	},
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "list",
		summary = "a folder, sorted and labelled the way the window shows it",
		effect = .Read,
		args = {{name = "dir", kind = .Path, help = "the folder; the working directory when omitted"}},
		flags = {
			{name = "all", short = "a", kind = .Bool, help = "include hidden files (Show Hidden Files)"},
			{name = "sort", kind = .Enum, values = {"name", "kind", "size", "date"}, def = "name", help = "the column to sort by"},
			{name = "reverse", short = "r", kind = .Bool, help = "the other direction"},
			{name = "filter", kind = .String, help = "only names containing this, folded (the search field)"},
			{name = "limit", kind = .Int, def = "0", help = "at most this many"},
		},
		out = LIST_FIELDS,
		examples = {"files list --json", "files list /etc --sort size --limit 5 --json"},
		run = cmd_list,
	},
	{
		verb = "stat",
		summary = "one path: kind, size, dates, permissions; a folder's total size",
		effect = .Read,
		args = {{name = "path", kind = .Path, required = true}},
		out = STAT_FIELDS,
		examples = {"files stat /etc/hostname --json"},
		run = cmd_stat,
	},
	{
		verb = "find",
		summary = "walk a folder for names matching a glob or a substring, shallowest first",
		effect = .Read,
		args = {
			{name = "root", kind = .Path, required = true, help = "the folder to search under"},
			{name = "pattern", kind = .String, help = "a glob (*.png) or a substring, folded; omit for everything"},
		},
		flags = {
			{name = "type", kind = .String, help = "file, dir, link, or a kind: image, video, audio, code, text, archive, …"},
			{name = "depth", kind = .Int, def = "0", help = "how many levels down; 0 is no limit"},
			{name = "limit", kind = .Int, def = "200", help = "stop after this many; 0 is no limit"},
			{name = "hidden", kind = .Bool, help = "look in hidden folders and report hidden names"},
			{name = "larger", kind = .Int, def = "0", help = "only files bigger than this many bytes"},
		},
		out = FIND_FIELDS,
		examples = {"files find /etc \"*.conf\" --depth 1 --json", "files find . report --type file --json"},
		run = cmd_find,
	},
	{
		verb = "copy",
		summary = "copy a file or folder; into <dest> when it is a folder. Never overwrites",
		effect = .Mutate,
		aliases = {"cp"},
		args = {{name = "src", kind = .Path, required = true}, {name = "dest", kind = .Path, required = true}},
		out = MOVED_FIELDS,
		examples = {"files copy notes.txt backup/ --json", "files copy photos photos-2026 --dry-run --json"},
		run = cmd_copy,
	},
	{
		verb = "move",
		summary = "move a file or folder; into <dest> when it is a folder. Never overwrites, never across Drive identities",
		effect = .Mutate,
		aliases = {"mv"},
		args = {{name = "src", kind = .Path, required = true}, {name = "dest", kind = .Path, required = true}},
		out = MOVED_FIELDS,
		examples = {"files move draft.md archive/ --json"},
		run = cmd_move,
	},
	{
		verb = "rename",
		summary = "give a file or folder a new name in the same folder",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, required = true}, {name = "name", kind = .String, required = true, help = "the new name, no /"}},
		out = MOVED_FIELDS,
		examples = {"files rename draft.md final.md --json"},
		run = cmd_rename,
	},
	{
		verb = "duplicate",
		summary = "copy a file or folder next to itself as \"name copy\", the way the window's Duplicate does",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, required = true}},
		out = MOVED_FIELDS,
		examples = {"files duplicate report.pdf --json"},
		run = cmd_duplicate,
	},
	{
		verb = "mkdir",
		summary = "make a folder",
		effect = .Idempotent,
		args = {{name = "path", kind = .Path, required = true}},
		flags = {{name = "parents", short = "p", kind = .Bool, help = "make the folders above it too, and accept one already there"}},
		out = MADE_FIELDS,
		examples = {"files mkdir projects/2026 --parents --json"},
		run = cmd_mkdir,
	},
	{
		verb = "trash",
		summary = "move a file or folder to the trash (freedesktop: restorable here or from any file manager)",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, required = true}},
		flags = {{name = "trash-dir", kind = .Path, help = "use this trash instead of $XDG_DATA_HOME/Trash"}},
		out = TRASH_FIELDS,
		examples = {"files trash old-draft.md --json"},
		run = cmd_trash,
	},
	{
		verb = "trashed",
		summary = "what is in the trash, newest first, with where each came from",
		effect = .Read,
		flags = {{name = "trash-dir", kind = .Path, help = "use this trash instead of $XDG_DATA_HOME/Trash"}},
		out = TRASHED_FIELDS,
		examples = {"files trashed --json"},
		run = cmd_trashed,
	},
	{
		verb = "restore",
		summary = "put something back from the trash, where it was or --to elsewhere. Never overwrites",
		effect = .Mutate,
		args = {{name = "item", kind = .String, required = true, help = "its name in the trash, or the path it had"}},
		flags = {
			{name = "to", kind = .Path, help = "restore here instead (a folder, or a new path)"},
			{name = "trash-dir", kind = .Path, help = "use this trash instead of $XDG_DATA_HOME/Trash"},
		},
		out = RESTORE_FIELDS,
		examples = {"files restore old-draft.md --json"},
		run = cmd_restore,
	},
	{
		verb = "empty-trash",
		summary = "delete everything in the trash for good — or only <item>",
		effect = .Destructive,
		args = {{name = "item", kind = .String, help = "only this one: its name in the trash, or the path it had"}},
		flags = {{name = "trash-dir", kind = .Path, help = "use this trash instead of $XDG_DATA_HOME/Trash"}},
		out = EMPTY_FIELDS,
		examples = {"files empty-trash --yes --json"},
		run = cmd_empty_trash,
	},
	{
		verb = "delete",
		summary = "remove a file or folder for good, skipping the trash",
		effect = .Destructive,
		aliases = {"rm"},
		args = {{name = "path", kind = .Path, required = true}},
		flags = {{name = "recursive", short = "R", kind = .Bool, help = "a folder with things in it"}},
		out = MADE_FIELDS,
		examples = {"files delete scratch.tmp --yes --json"},
		run = cmd_delete,
	},
	{
		verb = "open",
		summary = "open a file in its default application (xdg-open), as Enter does in the window",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, required = true}},
		out = OPEN_FIELDS,
		examples = {"files open report.pdf --dry-run --json"},
		run = cmd_open,
	},
	{
		verb = "places",
		summary = "the sidebar: Home, the usual folders that exist, Drive identities, the filesystem",
		effect = .Read,
		out = PLACES_FIELDS,
		examples = {"files places --json"},
		run = cmd_places,
	},
	{
		verb = "shots",
		summary = "render the browser offscreen into PNGs, over a fabricated tree (never the real home)",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, required = true, help = "where to write the PNGs"}},
		out = {{name = "dir", kind = .String}, {name = "written", kind = .Int}},
		examples = {"files shots /tmp/files-shots"},
		run = cmd_shots,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "files",
			summary    = "a file browser: list, find, copy, move, rename, trash and restore",
			gui        = true,
			takes_path = true,
			selftest   = selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Every command acts only on the paths it is given; the trash is the
standard freedesktop one ($XDG_DATA_HOME/Trash, else ~/.local/share/Trash) unless
--trash-dir names another. Nothing overwrites: copy, move, rename and restore
refuse a destination that exists. A bare folder path opens the window there:
files ~/Pictures`

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
entry_json :: proc(e: Fs_Entry) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "name", e.name)
	kit.jset_str(o, "path", e.path)
	kit.jset_str(o, "kind", e.kind)
	kit.jset_bool(o, "is_dir", e.is_dir)
	kit.jset_bool(o, "is_link", e.is_link)
	kit.jset_bool(o, "hidden", e.hidden)
	kit.jset_int(o, "size", int(e.size))
	kit.jset_str(o, "size_text", e.is_dir ? "--" : human_size(e.size, context.temp_allocator))
	kit.jset_str(o, "modified", iso_utc(e.mtime))
	return o
}

@(private = "file")
trashed_json :: proc(tr: Trashed) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "name", tr.name)
	kit.jset_str(o, "original", tr.original)
	kit.jset_str(o, "deleted", tr.deleted)
	kit.jset_bool(o, "is_dir", tr.is_dir)
	kit.jset_int(o, "size", int(tr.size))
	return o
}

// fs_failed turns the core's refusal into the convention's exit code. A
// destination that exists, or a request that makes no sense, is a refusal
// with a `reason` beside the token; a missing source is "not found".
@(private = "file")
fs_failed :: proc(c: ^kit.Call, fail: Fs_Fail, why: string) -> int {
	switch fail {
	case .Not_Found:
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, why)
	case .Exists:
		code := kit.cli_fail(c, kit.EXIT_FAILED, why)
		kit.cli_err_field(c, "reason", "exists")
		return code
	case .Refused:
		code := kit.cli_fail(c, kit.EXIT_FAILED, why)
		kit.cli_err_field(c, "reason", "refused")
		return code
	case .Failed, .None:
	}
	return kit.cli_fail(c, kit.EXIT_FAILED, why)
}

@(private = "file")
moved :: proc(c: ^kit.Call, from, to: string) -> int {
	kit.jset_str(c.out, "from", absolute(from))
	kit.jset_str(c.out, "to", to)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	if dir == "" {
		dir = "."
	}
	dir = absolute(dir)
	if !is_dir_path(dir) {
		if exists_nofollow(dir) {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%s is not a folder (files stat describes one file)", dir)
		}
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", dir)
	}
	entries, err := fs_list(dir, context.temp_allocator)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	key, _ := sort_key_parse(kit.cli_str(c, "sort"))
	fs_sort(entries[:], key, kit.cli_bool(c, "reverse"))

	needle := strings.to_lower(kit.cli_str(c, "filter"), context.temp_allocator)
	all := kit.cli_bool(c, "all")
	limit := kit.cli_int(c, "limit")
	arr := kit.jarr()
	n := 0
	for e in entries {
		if !fs_shown(e, needle, all) {
			continue
		}
		if limit > 0 && n >= limit {
			break
		}
		kit.jpush(arr, entry_json(e))
		n += 1
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_str(c.out, "sort", kit.cli_str(c, "sort"))
	kit.jset_int(c.out, "count", n)
	kit.jset_int(c.out, "total", len(entries))
	kit.jset(c.out, "entries", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_stat :: proc(c: ^kit.Call) -> int {
	path := absolute(kit.cli_str(c, "path"))
	e, ok := fs_stat(path, context.temp_allocator)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	kit.jset_str(c.out, "name", e.name)
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "kind", e.kind)
	kit.jset_bool(c.out, "is_dir", e.is_dir)
	kit.jset_bool(c.out, "is_link", e.is_link)
	kit.jset_bool(c.out, "hidden", e.hidden)
	kit.jset_int(c.out, "size", int(e.size))
	kit.jset_str(c.out, "size_text", e.is_dir ? "--" : human_size(e.size, context.temp_allocator))
	kit.jset_str(c.out, "modified", iso_utc(e.mtime))
	kit.jset_str(c.out, "mode", fs_mode(path))
	if e.is_link {
		if t, err := os.read_link(path, context.temp_allocator); err == nil {
			kit.jset_str(c.out, "link_target", t)
		}
	}
	if e.is_dir && !e.is_link {
		bytes, files, dirs := fs_tree_size(path)
		kit.jset_int(c.out, "items", files + dirs)
		kit.jset_int(c.out, "total_size", int(bytes))
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_find :: proc(c: ^kit.Call) -> int {
	root := absolute(kit.cli_str(c, "root"))
	if !is_dir_path(root) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not a folder", root)
	}
	o := Find_Opts {
		pattern     = kit.cli_str(c, "pattern"),
		kind        = kit.cli_str(c, "type"),
		max_depth   = kit.cli_int(c, "depth"),
		limit       = kit.cli_int(c, "limit", 200),
		hidden      = kit.cli_bool(c, "hidden"),
		larger_than = i64(kit.cli_int(c, "larger")),
	}
	if fs_has_glob(o.pattern) {
		if _, err := os.match(o.pattern, "a"); err != nil {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a glob that can match anything", o.pattern)
		}
	}
	found, truncated := fs_find(root, o, context.temp_allocator)
	arr := kit.jarr()
	for e in found {
		kit.jpush(arr, entry_json(e))
	}
	kit.jset_str(c.out, "root", root)
	kit.jset_str(c.out, "pattern", o.pattern)
	kit.jset_int(c.out, "count", len(found))
	kit.jset_bool(c.out, "truncated", truncated)
	kit.jset(c.out, "matches", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_trashed :: proc(c: ^kit.Call) -> int {
	t := trash_dir(kit.cli_str(c, "trash-dir"))
	list := fs_trash_list(t)
	arr := kit.jarr()
	for tr in list {
		kit.jpush(arr, trashed_json(tr))
	}
	kit.jset_str(c.out, "trash", t)
	kit.jset_int(c.out, "count", len(list))
	kit.jset(c.out, "items", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_places :: proc(c: ^kit.Call) -> int {
	st := State{}
	build_places(&st)
	for id in drive_identities() {
		if is_dir_path(id.root) {
			append(&st.places, Place{label = id.name != "" ? id.name : id.handle, path = id.root, group = "Drive"})
		}
	}
	arr := kit.jarr()
	for pl in st.places {
		o := kit.jobj()
		kit.jset_str(o, "label", pl.label)
		kit.jset_str(o, "path", pl.path)
		kit.jset_str(o, "group", pl.group)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "places", arr)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Changing things
// ---------------------------------------------------------------------------

@(private = "file")
cmd_copy :: proc(c: ^kit.Call) -> int {
	src, dst := kit.cli_str(c, "src"), kit.cli_str(c, "dest")
	made, fail, why := fs_copy(src, dst, c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	return moved(c, src, made)
}

@(private = "file")
cmd_move :: proc(c: ^kit.Call) -> int {
	src, dst := kit.cli_str(c, "src"), kit.cli_str(c, "dest")
	// Across two identities' Drive folders a move is a share or a copy, never
	// a rename — the same rule the window's Paste keeps (drive.odin).
	ids := drive_identities()
	if len(ids) > 0 {
		d := Drive {
			ids = ids,
		}
		target := absolute(dst)
		if !is_dir_path(target) {
			target = parent_of(target)
		}
		if why := drive_move_refusal(&d, absolute(src), target); why != "" {
			code := kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, why)
			kit.cli_err_field(c, "reason", "across identities")
			return code
		}
	}
	made, fail, why := fs_move(src, dst, c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	return moved(c, src, made)
}

@(private = "file")
cmd_rename :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	made, fail, why := fs_rename(path, kit.cli_str(c, "name"), c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	return moved(c, path, made)
}

@(private = "file")
cmd_duplicate :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	made, fail, why := fs_duplicate(path, c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	return moved(c, path, made)
}

@(private = "file")
cmd_mkdir :: proc(c: ^kit.Call) -> int {
	made, fail, why := fs_mkdir(kit.cli_str(c, "path"), kit.cli_bool(c, "parents"), c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	kit.jset_str(c.out, "path", made)
	return kit.EXIT_OK
}

@(private = "file")
cmd_trash :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	t := trash_dir(kit.cli_str(c, "trash-dir"))
	name, fail, why := fs_trash(path, t, local_offset(), c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	kit.jset_str(c.out, "path", absolute(path))
	kit.jset_str(c.out, "trashed_as", name)
	kit.jset_str(c.out, "trash", t)
	return kit.EXIT_OK
}

@(private = "file")
cmd_restore :: proc(c: ^kit.Call) -> int {
	t := trash_dir(kit.cli_str(c, "trash-dir"))
	ref := kit.cli_str(c, "item")
	made, fail, why := fs_restore(ref, t, kit.cli_str(c, "to"), c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	kit.jset_str(c.out, "name", ref)
	kit.jset_str(c.out, "to", made)
	return kit.EXIT_OK
}

@(private = "file")
cmd_empty_trash :: proc(c: ^kit.Call) -> int {
	t := trash_dir(kit.cli_str(c, "trash-dir"))
	removed, fail, why := fs_trash_empty(t, kit.cli_str(c, "item"), c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	arr := kit.jarr()
	for tr in removed {
		kit.jpush(arr, trashed_json(tr))
	}
	kit.jset_str(c.out, "trash", t)
	kit.jset_int(c.out, "count", len(removed))
	kit.jset(c.out, "removed", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	removed, fail, why := fs_delete(kit.cli_str(c, "path"), kit.cli_bool(c, "recursive"), c.dry_run)
	if fail != .None {
		return fs_failed(c, fail, why)
	}
	kit.jset_str(c.out, "path", removed)
	return kit.EXIT_OK
}

@(private = "file")
cmd_open :: proc(c: ^kit.Call) -> int {
	path := absolute(kit.cli_str(c, "path"))
	if !exists_nofollow(path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "command", fmt.tprintf("xdg-open %s", path))
	launched := false
	if !c.dry_run {
		if !on_path("xdg-open") {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "xdg-open is not installed")
		}
		launched = kit.launch({"xdg-open", path})
		if !launched {
			return kit.cli_fail(c, kit.EXIT_FAILED, "xdg-open did not start")
		}
	}
	kit.jset_bool(c.out, "launched", launched)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	if c.dry_run {
		kit.jset_str(c.out, "dir", dir)
		kit.jset_int(c.out, "written", 0)
		return kit.EXIT_OK
	}
	n := shots(dir)
	if n < 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write PNGs into %s", dir)
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_int(c.out, "written", n)
	return kit.EXIT_OK
}
