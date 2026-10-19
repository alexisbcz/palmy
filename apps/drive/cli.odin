package main

// The command-line front end of Drive, on the shared convention in
// apps/kit/cli.odin. Every command is a call into cloud/drive/core -- the
// same procedures the window uses -- so `drive share` and pressing S in the
// window are the same code.
//
// Scope: the identity is $PALM_IDENTITY, narrowed by --identity, and
// otherwise the first in the configuration. The token sent is the one scoped
// to that identity, so even a bug here could not reach another identity's
// drive: the database would refuse it.

import "core:fmt"
import "core:os"
import "core:strings"
import dc "drive:core"
import kit "kit:."

@(private = "file")
ITEM_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "name", kind = .String},
	{name = "kind", kind = .String},
	{name = "size", kind = .Int},
	{name = "modified", kind = .String},
	{name = "starred", kind = .Bool},
	{name = "hash", kind = .String, opt = true},
}

@(private = "file")
LIST_FIELDS := []kit.Field {
	{name = "identity", kind = .String},
	{name = "path", kind = .String},
	{name = "items", kind = .Array, of = ITEM_FIELDS},
	{name = "count", kind = .Int},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "identities",
		summary = "the identities this account has a drive for",
		effect = .Read,
		out = {{name = "identities", kind = .Array, of = {{name = "handle", kind = .String}, {name = "name", kind = .String}, {name = "kind", kind = .String}, {name = "id", kind = .String}}}},
		examples = {"drive identities --json"},
		run = cmd_identities,
	},
	{
		verb = "ls",
		summary = "a folder's contents",
		effect = .Read,
		args = {{name = "path", kind = .String, help = "a folder, from the root of the drive", def = "/"}},
		flags = {{name = "trash", kind = .Bool, help = "list the trash instead"}},
		out = LIST_FIELDS,
		examples = {"drive ls --json", "drive ls \"Q3 Board pack\" --identity alice-work --json", "drive ls --trash --json"},
		run = cmd_ls,
	},
	{
		verb = "stat",
		summary = "one item: its versions, who it is shared with, its links",
		effect = .Read,
		args = {{name = "path", kind = .String, required = true}},
		out = {{name = "item", kind = .Object, of = ITEM_FIELDS}, {name = "path", kind = .String}, {name = "versions", kind = .Array}, {name = "shares", kind = .Array}, {name = "links", kind = .Array}},
		examples = {"drive stat \"Q3 Board pack/Board deck.pptx\" --json"},
		run = cmd_stat,
	},
	{
		verb = "find",
		summary = "items whose name contains the text",
		effect = .Read,
		args = {{name = "query", kind = .String, required = true}},
		out = LIST_FIELDS,
		examples = {"drive find budget --json"},
		run = cmd_find,
	},
	{
		verb = "recent",
		summary = "files opened most recently",
		effect = .Read,
		out = LIST_FIELDS,
		examples = {"drive recent --json"},
		run = cmd_recent,
	},
	{
		verb = "starred",
		summary = "starred items",
		effect = .Read,
		out = LIST_FIELDS,
		examples = {"drive starred --json"},
		run = cmd_starred,
	},
	{
		verb = "shared",
		summary = "what other identities have shared with this one",
		effect = .Read,
		out = {{name = "identity", kind = .String}, {name = "shared", kind = .Array}},
		examples = {"drive shared --identity bob --json"},
		run = cmd_shared,
	},
	{
		verb = "usage",
		summary = "storage used against the quota",
		effect = .Read,
		out = {{name = "identity", kind = .String}, {name = "stored_bytes", kind = .Int}, {name = "file_bytes", kind = .Int}, {name = "version_bytes", kind = .Int}, {name = "trash_bytes", kind = .Int}, {name = "quota_bytes", kind = .Int}, {name = "files", kind = .Int}, {name = "folders", kind = .Int}},
		examples = {"drive usage --json"},
		run = cmd_usage,
	},
	{
		verb = "mkdir",
		summary = "create a folder (and any missing above it)",
		effect = .Idempotent,
		args = {{name = "path", kind = .String, required = true}},
		out = {{name = "path", kind = .String}, {name = "id", kind = .String}},
		examples = {"drive mkdir \"Q3 Board pack/Drafts\" --json"},
		run = cmd_mkdir,
	},
	{
		verb = "upload",
		summary = "upload a local file into a folder of the drive",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, required = true}, {name = "folder", kind = .String, help = "where in the drive", def = "/"}},
		out = {{name = "item", kind = .Object, of = ITEM_FIELDS}, {name = "chunks", kind = .Int}, {name = "chunks_sent", kind = .Int}, {name = "chunks_deduped", kind = .Int}},
		examples = {"drive upload ~/report.pdf \"Q3 Board pack\" --json"},
		run = cmd_upload,
	},
	{
		verb = "download",
		summary = "download a file, checking every chunk against its hash",
		effect = .Idempotent,
		args = {{name = "path", kind = .String, required = true}, {name = "dest", kind = .Path, help = "a file or a directory", def = "."}},
		out = {{name = "path", kind = .String}, {name = "size", kind = .Int}, {name = "hash", kind = .String}},
		examples = {"drive download \"Q3 Board pack/Board deck.pptx\" /tmp --json"},
		run = cmd_download,
	},
	{
		verb = "open",
		summary = "open a file in the Palmframe app for its kind",
		effect = .Mutate,
		args = {{name = "path", kind = .String, required = true}},
		out = {{name = "path", kind = .String}, {name = "app", kind = .String}},
		examples = {"drive open \"Q3 Board pack/Budget.xlsx\""},
		run = cmd_open,
	},
	{
		verb = "mv",
		summary = "move or rename",
		effect = .Mutate,
		args = {{name = "from", kind = .String, required = true}, {name = "to", kind = .String, required = true}},
		out = {{name = "item", kind = .Object, of = ITEM_FIELDS}, {name = "path", kind = .String}},
		examples = {"drive mv notes.md \"Q3 Board pack/notes.md\" --json"},
		run = cmd_mv,
	},
	{
		verb = "trash",
		summary = "move to the trash (restorable)",
		effect = .Mutate,
		args = {{name = "path", kind = .String, required = true}},
		out = {{name = "path", kind = .String}, {name = "items", kind = .Int}},
		examples = {"drive trash old.txt --json"},
		run = cmd_trash,
	},
	{
		verb = "restore",
		summary = "bring something back from the trash",
		effect = .Mutate,
		args = {{name = "path", kind = .String, required = true, help = "its path when it was trashed"}},
		out = {{name = "item", kind = .Object, of = ITEM_FIELDS}, {name = "path", kind = .String}},
		examples = {"drive restore old.txt --json"},
		run = cmd_restore,
	},
	{
		verb = "empty-trash",
		summary = "delete everything in the trash for good",
		effect = .Destructive,
		out = {{name = "deleted", kind = .Int}},
		examples = {"drive empty-trash --yes --json"},
		run = cmd_empty,
	},
	{
		verb = "star",
		summary = "star or unstar an item",
		effect = .Idempotent,
		args = {{name = "path", kind = .String, required = true}},
		flags = {{name = "off", kind = .Bool, help = "unstar"}},
		out = {{name = "path", kind = .String}, {name = "starred", kind = .Bool}},
		examples = {"drive star \"Q3 Board pack\" --json"},
		run = cmd_star,
	},
	{
		verb = "share",
		summary = "share an item with another identity",
		effect = .Idempotent,
		args = {{name = "path", kind = .String, required = true}, {name = "handle", kind = .String, required = true}},
		flags = {
			{name = "role", kind = .Enum, values = {"viewer", "editor"}, def = "viewer"},
			{name = "expires", kind = .String, help = "an ISO time after which the share stops working"},
		},
		out = {{name = "share", kind = .Object}},
		examples = {"drive share \"Q3 Board pack\" bob --role viewer --json"},
		run = cmd_share,
	},
	{
		verb = "unshare",
		summary = "take an identity's access away",
		effect = .Mutate,
		args = {{name = "path", kind = .String, required = true}, {name = "handle", kind = .String, required = true}},
		out = {{name = "revoked", kind = .Int}},
		examples = {"drive unshare \"Q3 Board pack\" bob --json"},
		run = cmd_unshare,
	},
	{
		verb = "link",
		summary = "mint a read-only link; the token is shown once",
		effect = .Mutate,
		args = {{name = "path", kind = .String, required = true}},
		flags = {{name = "expires", kind = .String, help = "a Postgres interval", def = "7 days"}, {name = "label", kind = .String}},
		out = {{name = "url", kind = .String}, {name = "token", kind = .String}, {name = "link_id", kind = .String}, {name = "expires_at", kind = .String}},
		examples = {"drive link \"Q3 Board pack/Board deck.pptx\" --expires \"2 days\" --json"},
		run = cmd_link,
	},
	{
		verb = "links",
		summary = "this identity's links, live and revoked",
		effect = .Read,
		out = {{name = "links", kind = .Array}},
		examples = {"drive links --json"},
		run = cmd_links,
	},
	{
		verb = "unlink",
		summary = "turn a link off",
		effect = .Mutate,
		args = {{name = "link", kind = .String, required = true, help = "the link id"}},
		out = {{name = "revoked", kind = .String}},
		examples = {"drive unlink 3f0c… --json"},
		run = cmd_unlink,
	},
	{
		verb = "resolve",
		summary = "what a link token gives access to, asked anonymously",
		effect = .Read,
		args = {{name = "token", kind = .String, required = true}},
		out = {{name = "items", kind = .Array}},
		examples = {"drive resolve 9fQ… --json"},
		run = cmd_resolve,
	},
	{
		verb = "versions",
		summary = "a file's versions, newest first",
		effect = .Read,
		args = {{name = "path", kind = .String, required = true}},
		out = {{name = "versions", kind = .Array}},
		examples = {"drive versions notes.md --json"},
		run = cmd_versions,
	},
	{
		verb = "gc",
		summary = "delete chunks no version refers to any more",
		effect = .Destructive,
		out = {{name = "deleted", kind = .Int}},
		examples = {"drive gc --yes --json"},
		run = cmd_gc,
	},
	{
		verb = "shots",
		summary = "render the window offscreen into PNGs, against the configured drive",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, required = true}},
		out = {{name = "dir", kind = .String}, {name = "count", kind = .Int}},
		examples = {"drive shots /tmp/drive-shots"},
		run = cmd_shots,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "drive",
			summary  = "an identity's cloud drive: files, sharing, links, trash",
			gui      = true,
			commands = COMMANDS,
			notes    = `Paths are from the root of the identity's drive: "Q3 Board pack/deck.pptx".
The identity is $PALM_IDENTITY, narrowed by --identity, else the first in
~/.config/palm-drive/drive.conf ($PALM_DRIVE_CONFIG). Each request carries
that identity's scoped token, so another identity's drive is refused by the
database, not merely hidden.`,
		}
	}
	return &g_surface
}

@(private = "file")
Ctx :: struct {
	cfg: dc.Config,
	id:  ^dc.Identity,
	c:   dc.Client,
}

@(private = "file")
open_ctx :: proc(c: ^kit.Call) -> (x: Ctx, code: int) {
	err: string
	x.cfg, err = dc.load_config(dc.config_path())
	if err != "" {
		return x, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	if len(x.cfg.identities) == 0 {
		return x, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no [identity] in the configuration")
	}
	x.id = &x.cfg.identities[0]
	if c.identity != "" {
		x.id = dc.find_identity(&x.cfg, c.identity)
		if x.id == nil {
			code = kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "this device has no drive for %q", c.identity)
			kit.cli_err_field(c, "requested", c.identity)
			return
		}
	}
	x.c = dc.client_for(&x.cfg, x.id)
	return x, kit.EXIT_OK
}

@(private = "file")
api_fail :: proc(c: ^kit.Call, e: dc.Error, what: string) -> int {
	if dc.offline(e) {
		return kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "%s: %s", what, e.message)
	}
	if e.status == 404 || e.code == "PT404" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s: %s", what, e.message)
	}
	if e.status == 403 || e.code == "42501" {
		return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "%s: refused by the database (%s)", what, e.message)
	}
	return kit.cli_failf(c, kit.EXIT_FAILED, "%s: %s", what, e.message)
}

@(private = "file")
find :: proc(c: ^kit.Call, x: ^Ctx, path: string, trashed := false) -> (it: dc.Item, code: int) {
	found, ok, e := dc.resolve_path(&x.c, path, trashed)
	if dc.failed(e) {
		return {}, api_fail(c, e, path)
	}
	if !ok {
		return {}, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no %q in %s's drive", path, x.id.handle)
	}
	return found, kit.EXIT_OK
}

@(private = "file")
item_json :: proc(it: dc.Item) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", it.id)
	kit.jset_str(o, "name", it.name)
	kit.jset_str(o, "kind", it.kind)
	kit.jset_int(o, "size", int(it.size))
	kit.jset_str(o, "modified", it.modified_at)
	kit.jset_bool(o, "starred", it.starred)
	if it.content_hash != "" {
		kit.jset_str(o, "hash", it.content_hash)
	}
	return o
}

@(private = "file")
list_out :: proc(c: ^kit.Call, x: ^Ctx, path: string, items: []dc.Item) -> int {
	arr := kit.jarr()
	for it in items {
		kit.jpush(arr, item_json(it))
	}
	kit.jset_str(c.out, "identity", x.id.handle)
	kit.jset_str(c.out, "path", path)
	kit.jset(c.out, "items", arr)
	kit.jset_int(c.out, "count", len(items))
	return kit.EXIT_OK
}

@(private = "file")
cmd_identities :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	arr := kit.jarr()
	for id in x.cfg.identities {
		if c.identity != "" && id.handle != c.identity {
			continue // inside a scope, the others are not listed at all
		}
		o := kit.jobj()
		kit.jset_str(o, "handle", id.handle)
		kit.jset_str(o, "name", id.name)
		kit.jset_str(o, "kind", id.kind)
		kit.jset_str(o, "id", id.id)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "identities", arr)
	return 0
}

@(private = "file")
cmd_ls :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	if kit.cli_bool(c, "trash") {
		items, e := dc.list_trash(&x.c)
		if dc.failed(e) {
			return api_fail(c, e, "trash")
		}
		return list_out(c, &x, "trash", items)
	}
	path := kit.cli_str(c, "path")
	dir, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	if dir.id != "" && dir.kind != "folder" {
		return list_out(c, &x, path, {dir})
	}
	items, e := dc.list_children(&x.c, dir.id)
	if dc.failed(e) {
		return api_fail(c, e, path)
	}
	return list_out(c, &x, path, items)
}

@(private = "file")
cmd_stat :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	kit.jset(c.out, "item", item_json(it))
	kit.jset_str(c.out, "path", path)
	vs, _ := dc.versions(&x.c, it.id)
	va := kit.jarr()
	for v in vs {
		o := kit.jobj()
		kit.jset_str(o, "id", v.id)
		kit.jset_int(o, "size", int(v.size))
		kit.jset_str(o, "hash", v.content_hash)
		kit.jset_int(o, "chunks", len(v.chunks))
		kit.jset_str(o, "device", v.device)
		kit.jset_str(o, "created", v.created_at)
		kit.jpush(va, o)
	}
	kit.jset(c.out, "versions", va)
	ss, _ := dc.shares_of(&x.c, it.id)
	sa := kit.jarr()
	for s in ss {
		o := kit.jobj()
		kit.jset_str(o, "handle", s.grantee_handle)
		kit.jset_str(o, "role", s.role)
		kit.jset_str(o, "since", s.created_at)
		if s.expires_at != "" {
			kit.jset_str(o, "expires", s.expires_at)
		}
		kit.jpush(sa, o)
	}
	kit.jset(c.out, "shares", sa)
	ls, _ := dc.links_of(&x.c, it.id)
	la := kit.jarr()
	for l in ls {
		kit.jpush(la, link_json(l))
	}
	kit.jset(c.out, "links", la)
	return 0
}

@(private = "file")
link_json :: proc(l: dc.Link) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", l.id)
	kit.jset_str(o, "item", l.item_id)
	kit.jset_str(o, "created", l.created_at)
	kit.jset_str(o, "expires", l.expires_at)
	kit.jset_bool(o, "revoked", l.revoked_at != "")
	kit.jset_int(o, "opened", int(l.opened))
	return o
}

@(private = "file")
cmd_find :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	items, e := dc.search(&x.c, kit.cli_str(c, "query"))
	if dc.failed(e) {
		return api_fail(c, e, "find")
	}
	return list_out(c, &x, "", items)
}

@(private = "file")
cmd_recent :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	items, e := dc.list_recent(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "recent")
	}
	return list_out(c, &x, "", items)
}

@(private = "file")
cmd_starred :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	items, e := dc.list_starred(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "starred")
	}
	return list_out(c, &x, "", items)
}

@(private = "file")
cmd_shared :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	rows, e := dc.shared_with_me(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "shared")
	}
	arr := kit.jarr()
	for r in rows {
		o := kit.jobj()
		kit.jset_str(o, "name", r.name)
		kit.jset_str(o, "kind", r.kind)
		kit.jset_str(o, "from", r.owner_handle)
		kit.jset_str(o, "role", r.role)
		kit.jset_str(o, "item", r.item_id)
		kit.jset_int(o, "size", int(r.size))
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "identity", x.id.handle)
	kit.jset(c.out, "shared", arr)
	return 0
}

@(private = "file")
cmd_usage :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	u, e := dc.usage(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "usage")
	}
	kit.jset_str(c.out, "identity", x.id.handle)
	kit.jset_int(c.out, "stored_bytes", int(u.stored_bytes))
	kit.jset_int(c.out, "file_bytes", int(u.file_bytes))
	kit.jset_int(c.out, "version_bytes", int(u.version_bytes))
	kit.jset_int(c.out, "trash_bytes", int(u.trash_bytes))
	kit.jset_int(c.out, "quota_bytes", int(u.quota_bytes))
	kit.jset_int(c.out, "files", int(u.files))
	kit.jset_int(c.out, "folders", int(u.folders))
	return 0
}

@(private = "file")
split :: proc(path: string) -> (dir, name: string) {
	t := strings.trim(path, "/")
	i := strings.last_index_byte(t, '/')
	if i < 0 {
		return "", t
	}
	return t[:i], t[i + 1:]
}

// ensure_folder walks a path, creating whatever folder is missing.
@(private = "file")
ensure_folder :: proc(c: ^kit.Call, x: ^Ctx, path: string) -> (id: string, code: int) {
	parent := ""
	for part in strings.split(strings.trim(path, "/"), "/", context.temp_allocator) {
		if part == "" {
			continue
		}
		kids, e := dc.list_children(&x.c, parent)
		if dc.failed(e) {
			return "", api_fail(c, e, path)
		}
		next := ""
		for k in kids {
			if k.name == part {
				if k.kind != "folder" {
					return "", kit.cli_failf(c, kit.EXIT_FAILED, "%q is a file", part)
				}
				next = k.id
			}
		}
		if next == "" {
			if c.dry_run {
				return "", 0
			}
			it, me := dc.mkdir(&x.c, parent, part)
			if dc.failed(me) {
				return "", api_fail(c, me, path)
			}
			next = it.id
		}
		parent = next
	}
	return parent, 0
}

@(private = "file")
cmd_mkdir :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	id, fc := ensure_folder(c, &x, path)
	if fc != 0 {
		return fc
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "id", id)
	return 0
}

@(private = "file")
cmd_upload :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	file := kit.cli_str(c, "file")
	if !os.exists(file) || os.is_dir(file) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no file %s", file)
	}
	folder := kit.cli_str(c, "folder")
	parent, fc := ensure_folder(c, &x, folder)
	if fc != 0 {
		return fc
	}
	name := file[strings.last_index_byte(file, '/') + 1:]
	// An existing file of that name gets a new version, not a duplicate.
	item := ""
	base: i64 = 0
	kids, _ := dc.list_children(&x.c, parent)
	for k in kids {
		if k.name == name && k.kind == "file" {
			item, base = k.id, k.seq
		}
	}
	if c.dry_run {
		h, _ := dc.hash_file(file)
		kit.jset_int(c.out, "chunks", len(h.chunks))
		return 0
	}
	prog: dc.Progress
	it, h, e := dc.upload_file(&x.c, file, parent, name, item, base, &prog)
	if dc.failed(e) {
		return api_fail(c, e, "upload")
	}
	kit.jset(c.out, "item", item_json(it))
	kit.jset_int(c.out, "chunks", len(h.chunks))
	kit.jset_int(c.out, "chunks_sent", prog.sent_chunks)
	kit.jset_int(c.out, "chunks_deduped", prog.skipped_chunks)
	return 0
}

@(private = "file")
cmd_download :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	if it.kind != "file" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "only files can be downloaded")
	}
	dest := kit.cli_str(c, "dest")
	if os.is_dir(dest) {
		dest = fmt.tprintf("%s/%s", strings.trim_right(dest, "/"), it.name)
	}
	v, e := dc.current_version(&x.c, it)
	if dc.failed(e) {
		return api_fail(c, e, "download")
	}
	if !c.dry_run {
		if de := dc.download_to(&x.c, it.identity_id, v, dest); dc.failed(de) {
			return api_fail(c, de, "download")
		}
	}
	kit.jset_str(c.out, "path", dest)
	kit.jset_int(c.out, "size", int(v.size))
	kit.jset_str(c.out, "hash", v.content_hash)
	return 0
}

@(private = "file")
cmd_open :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	st := State {
		cfg = x.cfg,
		c   = x.c,
	}
	r := Row {
		item = it,
	}
	local, ok := local_copy(&st, &r)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_FAILED, st.toast)
	}
	app := dc.app_for(it.name)
	bin, found := app_binary(app)
	if !c.dry_run {
		dc.touch(&x.c, it.id)
		if found {
			kit.launch({bin, local})
		} else {
			kit.launch({"xdg-open", local})
		}
	}
	kit.jset_str(c.out, "path", local)
	kit.jset_str(c.out, "app", found ? app : "xdg-open")
	return 0
}

@(private = "file")
cmd_mv :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	from, to := kit.cli_str(c, "from"), kit.cli_str(c, "to")
	it, fc := find(c, &x, from)
	if fc != 0 {
		return fc
	}
	dir, name := split(to)
	parent := ""
	if dir != "" {
		d, dfc := find(c, &x, dir)
		if dfc != 0 {
			return dfc
		}
		parent = d.id
	}
	if c.dry_run {
		kit.jset(c.out, "item", item_json(it))
		kit.jset_str(c.out, "path", to)
		return 0
	}
	moved, e := dc.move(&x.c, it.id, parent, name, it.seq)
	if dc.failed(e) {
		return api_fail(c, e, "mv")
	}
	kit.jset(c.out, "item", item_json(moved))
	kit.jset_str(c.out, "path", to)
	return 0
}

@(private = "file")
cmd_trash :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	if !c.dry_run {
		if e := dc.trash(&x.c, it.id); dc.failed(e) {
			return api_fail(c, e, "trash")
		}
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_int(c.out, "items", 1)
	return 0
}

@(private = "file")
cmd_restore :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	_, name := split(path)
	trashed, e := dc.list_trash(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "restore")
	}
	for t in trashed {
		if t.name == name || t.id == path {
			if c.dry_run {
				kit.jset(c.out, "item", item_json(t))
				kit.jset_str(c.out, "path", path)
				return 0
			}
			it, re := dc.restore(&x.c, t.id)
			if dc.failed(re) {
				return api_fail(c, re, "restore")
			}
			p, _ := dc.item_path(&x.c, it.id)
			kit.jset(c.out, "item", item_json(it))
			kit.jset_str(c.out, "path", p)
			return 0
		}
	}
	return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "nothing called %q in the trash", name)
}

@(private = "file")
cmd_empty :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	if c.dry_run {
		items, _ := dc.list_trash(&x.c)
		kit.jset_int(c.out, "deleted", len(items))
		return 0
	}
	n, e := dc.empty_trash(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "empty-trash")
	}
	kit.jset_int(c.out, "deleted", n)
	return 0
}

@(private = "file")
cmd_star :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	on := !kit.cli_bool(c, "off")
	if !c.dry_run {
		if e := dc.set_starred(&x.c, it.id, on); dc.failed(e) {
			return api_fail(c, e, "star")
		}
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_bool(c.out, "starred", on)
	return 0
}

@(private = "file")
cmd_share :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	handle := kit.cli_str(c, "handle")
	role := kit.cli_str(c, "role")
	o := kit.jobj()
	kit.jset_str(o, "item", it.id)
	kit.jset_str(o, "handle", handle)
	kit.jset_str(o, "role", role)
	if !c.dry_run {
		s, e := dc.share(&x.c, it.id, handle, role, kit.cli_str(c, "expires"))
		if dc.failed(e) {
			return api_fail(c, e, "share")
		}
		kit.jset_str(o, "id", s.id)
		if s.expires_at != "" {
			kit.jset_str(o, "expires", s.expires_at)
		}
	}
	kit.jset(c.out, "share", o)
	return 0
}

@(private = "file")
cmd_unshare :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	handle := kit.cli_str(c, "handle")
	rows, e := dc.shares_of(&x.c, it.id)
	if dc.failed(e) {
		return api_fail(c, e, "unshare")
	}
	n := 0
	for r in rows {
		if r.grantee_handle == handle {
			if !c.dry_run {
				if re := dc.revoke_share(&x.c, r.id); dc.failed(re) {
					return api_fail(c, re, "unshare")
				}
			}
			n += 1
		}
	}
	if n == 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s has no access to %s", handle, path)
	}
	kit.jset_int(c.out, "revoked", n)
	return 0
}

@(private = "file")
cmd_link :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	path := kit.cli_str(c, "path")
	it, fc := find(c, &x, path)
	if fc != 0 {
		return fc
	}
	if c.dry_run {
		kit.jset_str(c.out, "url", LINK_BASE + "…")
		return 0
	}
	m, e := dc.link_mint(&x.c, it.id, kit.cli_str(c, "expires"), kit.cli_str(c, "label"))
	if dc.failed(e) {
		return api_fail(c, e, "link")
	}
	kit.jset_str(c.out, "url", fmt.tprintf("%s%s", LINK_BASE, m.token))
	kit.jset_str(c.out, "token", m.token)
	kit.jset_str(c.out, "link_id", m.link_id)
	kit.jset_str(c.out, "expires_at", m.expires_at)
	return 0
}

@(private = "file")
cmd_links :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	ls, e := dc.links_of(&x.c, "")
	if dc.failed(e) {
		return api_fail(c, e, "links")
	}
	arr := kit.jarr()
	for l in ls {
		kit.jpush(arr, link_json(l))
	}
	kit.jset(c.out, "links", arr)
	return 0
}

@(private = "file")
cmd_unlink :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	id := kit.cli_str(c, "link")
	if !c.dry_run {
		if e := dc.revoke_link(&x.c, id); dc.failed(e) {
			return api_fail(c, e, "unlink")
		}
	}
	kit.jset_str(c.out, "revoked", id)
	return 0
}

@(private = "file")
cmd_resolve :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	tok := strings.trim_prefix(kit.cli_str(c, "token"), LINK_BASE)
	rs, e := dc.link_resolve(&x.c, tok)
	if dc.failed(e) {
		return api_fail(c, e, "resolve")
	}
	arr := kit.jarr()
	for r in rs {
		o := kit.jobj()
		kit.jset_str(o, "path", r.path)
		kit.jset_str(o, "kind", r.kind)
		kit.jset_int(o, "size", int(r.size))
		kit.jset_int(o, "chunks", len(r.chunks))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "items", arr)
	return 0
}

@(private = "file")
cmd_versions :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	it, fc := find(c, &x, kit.cli_str(c, "path"))
	if fc != 0 {
		return fc
	}
	vs, e := dc.versions(&x.c, it.id)
	if dc.failed(e) {
		return api_fail(c, e, "versions")
	}
	arr := kit.jarr()
	for v in vs {
		o := kit.jobj()
		kit.jset_str(o, "id", v.id)
		kit.jset_int(o, "size", int(v.size))
		kit.jset_str(o, "hash", v.content_hash)
		kit.jset_int(o, "chunks", len(v.chunks))
		kit.jset_str(o, "device", v.device)
		kit.jset_str(o, "created", v.created_at)
		kit.jset_bool(o, "current", v.id == it.version_id)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "versions", arr)
	return 0
}

@(private = "file")
cmd_gc :: proc(c: ^kit.Call) -> int {
	x, code := open_ctx(c)
	if code != 0 {
		return code
	}
	names, e := dc.unreferenced_chunks(&x.c)
	if dc.failed(e) {
		return api_fail(c, e, "gc")
	}
	n := 0
	for name in names {
		hash := name[strings.last_index_byte(name, '/') + 1:]
		if c.dry_run || !dc.failed(dc.delete_chunk(&x.c, hash)) {
			n += 1
		}
	}
	kit.jset_int(c.out, "deleted", n)
	return 0
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	n := shots(dir)
	if n < 0 {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "the drive could not be reached; start cloud/drive/dev/stack.sh and seed it")
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_int(c.out, "count", n)
	return 0
}
