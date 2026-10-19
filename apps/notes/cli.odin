package main

// The command-line front end of Notes.
//
// Nothing below re-implements anything: `store_*`, `title_of`, `search_notes`,
// `links_in`, `sync_ident` and the carry are the same procedures the window
// calls, so a note written here is indistinguishable from a note typed in the
// editor, and the two front ends cannot drift because there is only one store.
//
// Scope follows docs/PALM-CLI.md: $PALM_IDENTITY narrows everything to one
// identity's folder (and the account to that identity's scoped token), and
// --identity can narrow further but never widen. A command that has to act in
// two identities — `carry` — therefore refuses inside a scope, which is the
// point of the scope.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import ck "../cloudkit"
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "list",
		summary = "every note, pinned first, then newest, with its identity",
		effect = .Read,
		flags = {
			{name = "limit", kind = .Int, help = "how many, newest first", def = "0"},
			{name = "match", kind = .String, help = "only notes whose title or body contains this"},
			{name = "notebook", kind = .String, help = "only this notebook (folder)"},
			{name = "tag", kind = .String, help = "only notes with this tag"},
			{name = "trash", kind = .Bool, help = "the trash instead of the notes"},
		},
		out = LIST_FIELDS,
		examples = {"notes list --json", "notes list --limit 5 --json", "notes list --notebook Travel --json"},
		run = cmd_list,
	},
	{
		verb = "read",
		summary = "one note's text",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = READ_FIELDS,
		examples = {"notes read welcome-to-notes --json"},
		run = cmd_read,
	},
	{
		verb = "search",
		summary = "notes matching a query, across every identity on this device, each labelled",
		effect = .Read,
		args = {{name = "query", kind = .String, help = "words, plus in: tag: notebook: is:pinned is:shared is:trashed", required = true}},
		flags = {{name = "limit", kind = .Int, help = "how many notes at most", def = "0"}},
		out = SEARCH_FIELDS,
		examples = {"notes search markdown --json", "notes search \"lisbon in:camille\" --json", "notes search \"#travel\" --json"},
		run = cmd_search,
	},
	{
		verb = "path",
		summary = "where a note's file is, and where its identity's notes are",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path"}},
		out = PATH_FIELDS,
		examples = {"notes path --json", "notes path welcome-to-notes --json"},
		run = cmd_path,
	},
	{
		verb = "new",
		summary = "create a note in one identity",
		effect = .Mutate,
		args = {{name = "title", kind = .String, help = "its first line"}},
		flags = {
			{name = "text", kind = .String, help = "the body under the title"},
			{name = "notebook", kind = .String, help = "a folder to file it in"},
			{name = "tags", kind = .String, help = "comma-separated tags"},
		},
		out = WROTE_FIELDS,
		examples = {"notes new \"Shopping list\" --json", "notes new Groceries --text \"milk\\neggs\" --json", "notes new \"Q4 plan\" --identity northwind --notebook Projects --json"},
		run = cmd_new,
	},
	{
		verb = "capture",
		summary = "quick capture: a note from one line, or the capture window with no text",
		effect = .Mutate,
		args = {{name = "text", kind = .String, help = "what to write down; omit it to open the capture window"}},
		out = WROTE_FIELDS,
		examples = {"notes capture \"call the plumber about the boiler\" --json", "notes capture"},
		run = cmd_capture,
	},
	{
		verb = "write",
		summary = "replace a note's text, creating it if it is not there",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		flags = {
			{name = "text", kind = .String, help = "the new text"},
			{name = "file", kind = .Path, help = "read the new text from this file instead"},
		},
		out = WROTE_FIELDS,
		examples = {"notes write shopping-list --text \"# Shopping list\\n\\nmilk\" --json"},
		run = cmd_write,
	},
	{
		verb = "append",
		summary = "add a line to the end of a note",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		flags = {{name = "text", kind = .String, help = "the line to add", required = true}},
		out = WROTE_FIELDS,
		examples = {"notes append shopping-list --text \"- bread\" --json"},
		run = cmd_append,
	},
	{
		verb = "rename",
		summary = "change a note's title, which renames its file",
		effect = .Mutate,
		args = {
			{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true},
			{name = "title", kind = .String, help = "the new title", required = true},
		},
		out = WROTE_FIELDS,
		examples = {"notes rename shopping-list \"Groceries\" --json"},
		run = cmd_rename,
	},
	{
		verb = "move",
		summary = "file a note in a notebook (a folder of its identity); \"\" is the inbox",
		effect = .Mutate,
		args = {
			{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true},
			{name = "notebook", kind = .String, help = "the folder, e.g. Travel or Projects/Halcyon", required = true},
		},
		out = WROTE_FIELDS,
		examples = {"notes move lisbon Travel --json"},
		run = cmd_move,
	},
	{
		verb = "pin",
		summary = "pin a note to the top of its identity, or --off to unpin it",
		effect = .Idempotent,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		flags = {{name = "off", kind = .Bool, help = "unpin instead"}},
		out = WROTE_FIELDS,
		examples = {"notes pin lisbon --json", "notes pin lisbon --off --json"},
		run = cmd_pin,
	},
	{
		verb = "tag",
		summary = "add or remove front matter tags",
		effect = .Idempotent,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		flags = {
			{name = "add", kind = .String, help = "comma-separated tags to add"},
			{name = "remove", kind = .String, help = "comma-separated tags to remove"},
		},
		out = WROTE_FIELDS,
		examples = {"notes tag lisbon --add travel,2026 --json"},
		run = cmd_tag,
	},
	{
		verb = "trash",
		summary = "move a note to its identity's trash (restore brings it back), synced to every device",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = WROTE_FIELDS,
		examples = {"notes trash scratch --json"},
		run = cmd_trash,
	},
	{
		verb = "restore",
		summary = "take a note out of the trash, back into the notebook it was in",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = WROTE_FIELDS,
		examples = {"notes restore scratch --json"},
		run = cmd_restore,
	},
	{
		verb = "delete",
		summary = "remove a note for good, from this device and (once synced) every other",
		effect = .Destructive,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = DELETED_FIELDS,
		examples = {"notes delete scratch --yes --json"},
		run = cmd_delete,
	},
	{
		verb = "notebooks",
		summary = "each identity's notebooks (folders) with counts",
		effect = .Read,
		out = NOTEBOOKS_FIELDS,
		examples = {"notes notebooks --json"},
		run = cmd_notebooks,
	},
	{
		verb = "tags",
		summary = "every tag in use, per identity, with counts",
		effect = .Read,
		out = TAGS_FIELDS,
		examples = {"notes tags --json"},
		run = cmd_tags,
	},
	{
		verb = "links",
		summary = "a note's [[links]] (resolved, unresolved, or to another identity) and its backlinks",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = LINKS_FIELDS,
		examples = {"notes links lisbon --json"},
		run = cmd_links,
	},
	{
		verb = "identities",
		summary = "the identities whose notes are on this device, and where",
		effect = .Read,
		out = IDENTITIES_FIELDS,
		examples = {"notes identities --json"},
		run = cmd_identities,
	},
	{
		verb = "sync",
		summary = "sync every identity on this device (or one): push local edits, merge, pull",
		effect = .Idempotent,
		flags = {
			{name = "offline", kind = .Bool, help = "only queue local edits; do not touch the network"},
			{name = "skip", kind = .String, help = "a note id a window holds open with its own live session"},
			{name = "device", kind = .String, help = "the name the carry log records for this device"},
		},
		out = SYNC_FIELDS,
		examples = {"notes sync --json", "notes sync --identity northwind --json", "notes sync --offline --json"},
		run = cmd_sync,
	},
	{
		verb = "status",
		summary = "account, sync server and per-identity sync state",
		effect = .Read,
		out = STATUS_FIELDS,
		examples = {"notes status --json"},
		run = cmd_status,
	},
	{
		verb = "share",
		summary = "share a note with another identity, to read or to edit (an explicit, revocable row)",
		effect = .Mutate,
		args = {
			{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true},
			{name = "with", kind = .String, help = "the identity's handle", required = true},
		},
		flags = {{name = "access", kind = .Enum, values = {"read", "edit"}, def = "read", help = "what they may do"}},
		out = SHARE_FIELDS,
		examples = {"notes share lisbon bob.okafor --access edit --json"},
		run = cmd_share,
	},
	{
		verb = "unshare",
		summary = "revoke a share; the other identity's devices drop their copy at their next sync",
		effect = .Mutate,
		args = {
			{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true},
			{name = "with", kind = .String, help = "the identity's handle", required = true},
		},
		out = SHARE_FIELDS,
		examples = {"notes unshare lisbon bob.okafor --json"},
		run = cmd_unshare,
	},
	{
		verb = "people",
		summary = "who a note is shared with",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = PEOPLE_FIELDS,
		examples = {"notes people lisbon --json"},
		run = cmd_people,
	},
	{
		verb = "carry",
		summary = "copy a note into another of your identities, recorded in both identities' carry logs",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		flags = {
			{name = "to", kind = .String, help = "the identity to carry it into (a handle)", required = true},
			{name = "device", kind = .String, help = "the name the carry log records for this device"},
		},
		out = CARRY_FIELDS,
		examples = {"notes carry \"Packing list\" --to camille --json"},
		run = cmd_carry,
	},
	{
		verb = "log",
		summary = "an identity's carry log: what was carried in and out, when, from which device",
		effect = .Read,
		flags = {{name = "limit", kind = .Int, help = "how many, newest first", def = "50"}},
		out = LOG_FIELDS,
		examples = {"notes log --identity camille --json"},
		run = cmd_log,
	},
	{
		verb = "history",
		summary = "a note's revisions, grouped into editing sessions, with who edited",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true}},
		out = HISTORY_FIELDS,
		examples = {"notes history lisbon --json"},
		run = cmd_history,
	},
	{
		verb = "attach",
		summary = "attach a file to a note: copied under attachments/, linked, synced",
		effect = .Mutate,
		args = {
			{name = "note", kind = .String, help = "a title, a slug, an id or a path", required = true},
			{name = "file", kind = .Path, help = "the file to attach", required = true},
		},
		out = ATTACH_FIELDS,
		examples = {"notes attach lisbon ~/Pictures/map.png --json"},
		run = cmd_attach,
	},
	{
		verb = "coedit",
		summary = "join a note's live session and type a script into it (a second collaborator for demos)",
		effect = .Mutate,
		hidden = true,
		args = {{name = "note", kind = .String, help = "the note's id", required = true}},
		flags = {{name = "script", kind = .Path, help = "lines: wait <s> | type <text> | line <text> | at <text-to-find>", required = true}},
		out = {{name = "note", kind = .String}, {name = "text", kind = .String}},
		examples = {"notes coedit 7f3c2a1e-0000-4000-8000-000000000000 --script bob.txt"},
		run = cmd_coedit,
	},
	{
		verb = "shots",
		summary = "render the interface offscreen into a directory of PNGs, light and dark",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, help = "where to write the PNGs", required = true}},
		out = {{name = "dir", kind = .String}},
		examples = {"notes shots /tmp/notes-shots"},
		run = cmd_shots,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "notes",
			summary    = "Markdown notes you own, per identity, synced across devices",
			gui        = true,
			takes_path = false,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Notes are Markdown files: ~/Notes/<identity>/ holds one identity's notes
($PALM_NOTES_ROOT moves it), a folder is a notebook, .trash/ is the trash and
Shared/<owner>/ what other identities shared with this one. $PALMY_NOTES_DIR
points everything at one folder with no identities, which is how the self-test
runs without going near real notes.

<note> is matched against a path, an id, a file name, a slug, and then a title,
case-insensitively; an unambiguous prefix of a title is enough. Nothing
matching exits 3.

Crossing identities is explicit: share (a revocable row, read or edit) or carry
(an independent copy, logged on both sides). [[other-handle:Title]] links name
another identity on purpose and are never resolved silently.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

LIST_FIELDS := []kit.Field {
	{
		name = "notes",
		kind = .Array,
		of = {
			{name = "title", kind = .String},
			{name = "slug", kind = .String},
			{name = "path", kind = .String},
			{name = "id", kind = .String},
			{name = "identity", kind = .String, help = "the handle of the identity it belongs to"},
			{name = "notebook", kind = .String},
			{name = "tags", kind = .Array, of = {{kind = .String}}},
			{name = "pinned", kind = .Bool},
			{name = "shared", kind = .Bool, help = "someone else's note, shared with this identity"},
			{name = "preview", kind = .String},
			{name = "words", kind = .Int},
			{name = "bytes", kind = .Int},
			{name = "modified", kind = .String},
		},
	},
	{name = "count", kind = .Int},
	{name = "dir", kind = .String, help = "the first identity's folder"},
}

READ_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "slug", kind = .String},
	{name = "path", kind = .String},
	{name = "id", kind = .String},
	{name = "identity", kind = .String},
	{name = "notebook", kind = .String},
	{name = "tags", kind = .Array, of = {{kind = .String}}},
	{name = "words", kind = .Int},
	{name = "bytes", kind = .Int},
	{name = "modified", kind = .String},
	{name = "text", kind = .String, help = "the Markdown, without its front matter"},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{
		name = "matches",
		kind = .Array,
		of = {
			{name = "title", kind = .String},
			{name = "slug", kind = .String},
			{name = "path", kind = .String},
			{name = "id", kind = .String},
			{name = "identity", kind = .String, help = "its identity's handle"},
			{name = "identity_name", kind = .String, help = "and display name, for the label"},
			{name = "notebook", kind = .String},
			{name = "shared", kind = .Bool},
			{name = "in_title", kind = .Bool},
			{name = "hits", kind = .Int, help = "matching lines in the body"},
			{name = "first_line", kind = .String, help = "the first matching line, trimmed"},
		},
	},
	{name = "count", kind = .Int},
	{name = "searched", kind = .Int, help = "notes read, all on this device"},
	{name = "identities", kind = .Array, of = {{kind = .String}}, help = "the identities searched"},
	{name = "unknown", kind = .Array, of = {{kind = .String}}, help = "operators not understood"},
}

PATH_FIELDS := []kit.Field {
	{name = "dir", kind = .String, help = "the identity's folder"},
	{name = "path", kind = .String, opt = true, help = "the note, when one was named"},
	{name = "exists", kind = .Bool},
}

WROTE_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "slug", kind = .String},
	{name = "path", kind = .String},
	{name = "id", kind = .String},
	{name = "identity", kind = .String},
	{name = "words", kind = .Int},
	{name = "bytes", kind = .Int},
	{name = "created", kind = .Bool, help = "true when the note did not exist before"},
}

DELETED_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "path", kind = .String},
	{name = "deleted", kind = .Bool},
	{name = "cloud", kind = .String, help = "deleted, queued (until the next sync), or local (never synced)"},
}

NOTEBOOKS_FIELDS := []kit.Field {
	{
		name = "identities",
		kind = .Array,
		of = {
			{name = "identity", kind = .String},
			{name = "inbox", kind = .Int},
			{name = "trash", kind = .Int},
			{name = "shared", kind = .Int},
			{name = "notebooks", kind = .Array, of = {{name = "name", kind = .String}, {name = "count", kind = .Int}}},
		},
	},
}

TAGS_FIELDS := []kit.Field {
	{name = "tags", kind = .Array, of = {{name = "tag", kind = .String}, {name = "identity", kind = .String}, {name = "count", kind = .Int}}},
}

LINKS_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "identity", kind = .String},
	{
		name = "links",
		kind = .Array,
		of = {
			{name = "text", kind = .String, help = "as written"},
			{name = "kind", kind = .String, help = "resolved, unresolved, or elsewhere (another identity)"},
			{name = "target", kind = .String},
			{name = "identity", kind = .String, help = "the identity it points into"},
			{name = "path", kind = .String, opt = true},
		},
	},
	{name = "backlinks", kind = .Array, of = {{name = "title", kind = .String}, {name = "path", kind = .String}, {name = "context", kind = .String}}},
}

IDENTITIES_FIELDS := []kit.Field {
	{
		name = "identities",
		kind = .Array,
		of = {
			{name = "handle", kind = .String},
			{name = "name", kind = .String},
			{name = "kind", kind = .String},
			{name = "color", kind = .String},
			{name = "dir", kind = .String},
			{name = "synced", kind = .Bool, help = "bound to a cloud identity"},
			{name = "notes", kind = .Int},
		},
	},
	{name = "scope", kind = .String, help = "the identity this process is limited to, or unscoped"},
}

SYNC_FIELDS := []kit.Field {
	{
		name = "identities",
		kind = .Array,
		of = {
			{name = "identity", kind = .String},
			{name = "online", kind = .Bool},
			{name = "pushed", kind = .Int},
			{name = "pulled", kind = .Int},
			{name = "created", kind = .Int},
			{name = "arrived", kind = .Int},
			{name = "removed", kind = .Int},
			{name = "queued", kind = .Int, help = "notes with edits still waiting for the network"},
			{name = "readonly", kind = .Int},
			{name = "events", kind = .Array, of = {{kind = .String}}},
			{name = "error", kind = .String, opt = true},
		},
	},
	{name = "enrolled", kind = .Int, help = "identities newly given a folder on this device"},
	{name = "account", kind = .String, help = "signed in, not signed in, or unreachable"},
}

STATUS_FIELDS := []kit.Field {
	{name = "account", kind = .String},
	{name = "email", kind = .String, opt = true},
	{name = "sync_server", kind = .String},
	{
		name = "identities",
		kind = .Array,
		of = {
			{name = "identity", kind = .String},
			{name = "synced", kind = .Bool},
			{name = "notes", kind = .Int},
			{name = "waiting", kind = .Int, help = "notes with edits not yet acknowledged by the server"},
			{name = "carries_waiting", kind = .Int},
		},
	},
}

SHARE_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "id", kind = .String},
	{name = "with", kind = .String},
	{name = "access", kind = .String, help = "read, edit, or none after unshare"},
}

PEOPLE_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "people", kind = .Array, of = {{name = "handle", kind = .String}, {name = "name", kind = .String}, {name = "access", kind = .String}}},
}

CARRY_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "from", kind = .String, help = "the identity it was carried out of"},
	{name = "to", kind = .String, help = "the identity the copy now belongs to"},
	{name = "id", kind = .String, help = "the copy's id: a new note, independent of the original"},
	{name = "from_id", kind = .String},
	{name = "path", kind = .String, help = "the copy's file, when the target identity is on this device"},
	{name = "hash", kind = .String, help = "sha256 of the Markdown carried, as both logs record it"},
	{name = "recorded", kind = .Bool, help = "false when offline: recorded at the next sync"},
}

LOG_FIELDS := []kit.Field {
	{name = "identity", kind = .String},
	{
		name = "entries",
		kind = .Array,
		of = {
			{name = "direction", kind = .String, help = "in or out"},
			{name = "title", kind = .String},
			{name = "peer", kind = .String, help = "the other identity's handle"},
			{name = "note", kind = .String, help = "this side's note id"},
			{name = "peer_note", kind = .String},
			{name = "hash", kind = .String},
			{name = "device", kind = .String},
			{name = "at", kind = .String},
			{name = "pending", kind = .Bool, help = "made offline, not yet recorded in the account"},
		},
	},
}

HISTORY_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "id", kind = .String},
	{name = "revisions", kind = .Int},
	{name = "sessions", kind = .Array, of = {{name = "from", kind = .Int}, {name = "to", kind = .Int}, {name = "edits", kind = .Int}, {name = "at", kind = .String}, {name = "authors", kind = .Array, of = {{kind = .String}}}}},
}

ATTACH_FIELDS := []kit.Field {
	{name = "note", kind = .String},
	{name = "file", kind = .String, help = "where the copy is, under attachments/"},
	{name = "sha256", kind = .String},
	{name = "link", kind = .String, help = "the Markdown added to the note"},
}

// ---------------------------------------------------------------------------
// The book: every identity's notes on this device, within scope
// ---------------------------------------------------------------------------

Book :: struct {
	ids:   [dynamic]Ident,
	notes: [dynamic]Note,
}

book_load :: proc(c: ^kit.Call = nil) -> Book {
	b := Book{}
	b.ids = idents_load(context.temp_allocator)
	if c != nil && c.identity != "" {
		#reverse for &x, i in b.ids {
			if x.handle != c.identity {
				ordered_remove(&b.ids, i)
			}
		}
	}
	b.notes = make([dynamic]Note, context.temp_allocator)
	for id, i in b.ids {
		ns := store_load(id.root)
		for &n in ns {
			n.ident = i
			append(&b.notes, n)
		}
		delete(ns)
	}
	return b
}

handles_of :: proc(b: ^Book) -> []string {
	out := make([]string, len(b.ids), context.temp_allocator)
	for id, i in b.ids {
		out[i] = id.handle
	}
	return out
}

cli_selftest :: proc() -> int {
	run_selftest()
	return failures == 0 ? 0 : 1
}

@(private = "file")
iso :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

// slug_of_path is the file name without its extension, which is the stable
// short name a caller can hold on to between commands.
slug_of_path :: proc(path: string) -> string {
	return strings.trim_suffix(base_name(path), ".md")
}

@(private = "file")
tags_json :: proc(tags: []string) -> ^kit.Json {
	arr := kit.jarr()
	for t in tags {
		kit.jpush(arr, kit.jstr(t))
	}
	return arr
}

@(private = "file")
note_summary :: proc(b: ^Book, n: Note) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "title", n.title)
	kit.jset_str(o, "slug", slug_of_path(n.path))
	kit.jset_str(o, "path", n.path)
	kit.jset_str(o, "id", n.meta.id)
	kit.jset_str(o, "identity", b.ids[n.ident].handle)
	kit.jset_str(o, "notebook", n.notebook)
	kit.jset(o, "tags", tags_json(n.tags[:]))
	kit.jset_bool(o, "pinned", n.meta.pinned)
	kit.jset_bool(o, "shared", n.shared)
	kit.jset_str(o, "preview", n.preview)
	kit.jset_int(o, "words", n.words)
	kit.jset_int(o, "bytes", n.bytes)
	kit.jset_str(o, "modified", iso(n.mtime))
	return o
}

// resolve finds the note a caller meant. A path, an id, a file name, a slug,
// an exact title, then an unambiguous case-insensitive prefix of one — in
// that order, so a precise reference always beats a fuzzy one. Trashed notes
// are found only by a precise reference.
resolve :: proc(b: ^Book, ref: string) -> (n: Note, found: bool) {
	all := b.notes[:]
	if len(all) == 0 {
		return Note{}, false
	}
	want_slug := slug_of_path(ref)
	for it in all {
		if it.path == ref || it.meta.id == ref {
			return it, true
		}
	}
	for it in all {
		if slug_of_path(it.path) == want_slug {
			return it, true
		}
	}
	for it in all {
		if it.title == ref && !it.trashed {
			return it, true
		}
	}
	// A case-insensitive title match, and then a prefix of one, but only when
	// exactly one note matches. Two candidates is not found; it is ambiguous,
	// and guessing would be the wrong answer silently.
	hit := -1
	count := 0
	for it, i in all {
		if !it.trashed && len(it.title) == len(ref) && contains_fold(it.title, ref) {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return all[hit], true
	}
	hit, count = -1, 0
	for it, i in all {
		if !it.trashed && len(it.title) >= len(ref) && contains_fold(it.title[:len(ref)], ref) {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return all[hit], true
	}
	return Note{}, false
}

@(private = "file")
not_found :: proc(c: ^kit.Call, ref: string) -> int {
	code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no note matching %q", ref)
	kit.cli_err_field(c, "note", ref)
	return code
}

// target_ident is the identity a new note goes to: the scope, else the only
// identity, else refuse — with more than one identity on the device the
// command does not guess (product.md P3), it asks for --identity.
@(private = "file")
target_ident :: proc(c: ^kit.Call, b: ^Book) -> (int, int) {
	if len(b.ids) == 1 {
		return 0, kit.EXIT_OK
	}
	if len(b.ids) == 0 {
		return -1, kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "no identity's notes are on this device in this scope")
	}
	names := make([dynamic]string, context.temp_allocator)
	for id in b.ids {
		append(&names, id.handle)
	}
	return -1, kit.cli_failf(c, kit.EXIT_USAGE, "which identity? pass --identity (%s)", strings.join(names[:], ", ", context.temp_allocator))
}

// wrote_result is what every mutating command prints: the note as it now
// stands on disk, which is also exactly what a dry run would have produced.
@(private = "file")
wrote_result :: proc(c: ^kit.Call, path, body: string, created: bool, id := "", ident := "") {
	_, text, _ := split_front(body)
	title := title_of(text, context.temp_allocator)
	kit.jset_str(c.out, "title", title)
	kit.jset_str(c.out, "slug", slug_of_path(path))
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "id", id)
	kit.jset_str(c.out, "identity", ident)
	kit.jset_int(c.out, "words", word_count(text))
	kit.jset_int(c.out, "bytes", len(body))
	kit.jset_bool(c.out, "created", created)
}

@(private = "file")
read_meta :: proc(path: string) -> Meta {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {}
	}
	f, _, _ := split_front(string(data))
	return parse_front(f, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	limit := kit.cli_int(c, "limit", 0)
	match := kit.cli_str(c, "match")
	nb := kit.cli_str(c, "notebook")
	tag := kit.cli_str(c, "tag")
	trash := kit.cli_bool(c, "trash")
	arr := kit.jarr()
	for n in b.notes {
		if n.trashed != trash {
			continue
		}
		if match != "" && !contains_fold(n.title, match) && !contains_fold(n.body, match) {
			continue
		}
		if kit.cli_has(c, "notebook") && !strings.equal_fold(n.notebook, nb) {
			continue
		}
		if tag != "" {
			has := false
			for t in n.tags {
				if t == strings.to_lower(strings.trim_left(tag, "#"), context.temp_allocator) {has = true}
			}
			if !has {continue}
		}
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		kit.jpush(arr, note_summary(&b, n))
	}
	kit.jset(c.out, "notes", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	kit.jset_str(c.out, "dir", len(b.ids) > 0 ? b.ids[0].root : notes_home(context.temp_allocator))
	return kit.EXIT_OK
}

@(private = "file")
cmd_read :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, ok := resolve(&b, ref)
	if !ok {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "slug", slug_of_path(n.path))
	kit.jset_str(c.out, "path", n.path)
	kit.jset_str(c.out, "id", n.meta.id)
	kit.jset_str(c.out, "identity", b.ids[n.ident].handle)
	kit.jset_str(c.out, "notebook", n.notebook)
	kit.jset(c.out, "tags", tags_json(n.tags[:]))
	kit.jset_int(c.out, "words", n.words)
	kit.jset_int(c.out, "bytes", n.bytes)
	kit.jset_str(c.out, "modified", iso(n.mtime))
	kit.jset_str(c.out, "text", n.body)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	q := kit.cli_str(c, "query")
	limit := kit.cli_int(c, "limit", 0)
	pq := parse_query(q)
	kit.jset_str(c.out, "query", q)
	hits := search_notes(b.notes[:], handles_of(&b), pq)
	arr := kit.jarr()
	for h in hits {
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		n := b.notes[h.note]
		o := kit.jobj()
		kit.jset_str(o, "title", n.title)
		kit.jset_str(o, "slug", slug_of_path(n.path))
		kit.jset_str(o, "path", n.path)
		kit.jset_str(o, "id", n.meta.id)
		kit.jset_str(o, "identity", b.ids[n.ident].handle)
		kit.jset_str(o, "identity_name", b.ids[n.ident].name)
		kit.jset_str(o, "notebook", n.notebook)
		kit.jset_bool(o, "shared", n.shared)
		kit.jset_bool(o, "in_title", h.in_title)
		kit.jset_int(o, "hits", h.hits)
		kit.jset_str(o, "first_line", h.line)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "matches", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	kit.jset_int(c.out, "searched", len(b.notes))
	kit.jset(c.out, "identities", tags_json(handles_of(&b)))
	kit.jset(c.out, "unknown", tags_json(pq.unknown[:]))
	if len(pq.unknown) > 0 {
		kit.cli_note(c, "not understood, so not applied: %s", strings.join(pq.unknown[:], " ", context.temp_allocator))
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_path :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	dir := len(b.ids) > 0 ? b.ids[0].root : notes_home(context.temp_allocator)
	ref := kit.cli_str(c, "note")
	if ref == "" {
		kit.jset_str(c.out, "dir", dir)
		kit.jset_bool(c.out, "exists", os.is_dir(dir))
		return kit.EXIT_OK
	}
	n, ok := resolve(&b, ref)
	if !ok {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "dir", b.ids[n.ident].root)
	kit.jset_str(c.out, "path", n.path)
	kit.jset_bool(c.out, "exists", os.exists(n.path))
	return kit.EXIT_OK
}

@(private = "file")
cmd_notebooks :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	arr := kit.jarr()
	for id, i in b.ids {
		o := kit.jobj()
		kit.jset_str(o, "identity", id.handle)
		inbox, trash, shared := 0, 0, 0
		for n in b.notes {
			if n.ident != i {continue}
			switch {
			case n.trashed:
				trash += 1
			case n.shared:
				shared += 1
			case n.notebook == "":
				inbox += 1
			}
		}
		kit.jset_int(o, "inbox", inbox)
		kit.jset_int(o, "trash", trash)
		kit.jset_int(o, "shared", shared)
		books := kit.jarr()
		for nb in notebooks_of(b.notes[:], i) {
			bo := kit.jobj()
			kit.jset_str(bo, "name", nb.name)
			kit.jset_int(bo, "count", nb.count)
			kit.jpush(books, bo)
		}
		kit.jset(o, "notebooks", books)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "identities", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_tags :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	Count :: struct {
		tag:   string,
		ident: int,
		n:     int,
	}
	counts := make([dynamic]Count, context.temp_allocator)
	for n in b.notes {
		if n.trashed {continue}
		for t in n.tags {
			found := false
			for &x in counts {
				if x.tag == t && x.ident == n.ident {
					x.n += 1
					found = true
				}
			}
			if !found {
				append(&counts, Count{t, n.ident, 1})
			}
		}
	}
	arr := kit.jarr()
	for x in counts {
		o := kit.jobj()
		kit.jset_str(o, "tag", x.tag)
		kit.jset_str(o, "identity", b.ids[x.ident].handle)
		kit.jset_int(o, "count", x.n)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "tags", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_links :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, ok := resolve(&b, ref)
	if !ok {
		return not_found(c, ref)
	}
	own := b.ids[n.ident].handle
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "identity", own)
	arr := kit.jarr()
	for l in links_in(n.body) {
		o := kit.jobj()
		kit.jset_str(o, "text", n.body[l.from:l.to])
		kind, at := link_resolve(b.notes[:], n.ident, own, l)
		kit.jset_str(o, "target", l.target)
		switch kind {
		case .Resolved:
			kit.jset_str(o, "kind", "resolved")
			kit.jset_str(o, "identity", own)
			kit.jset_str(o, "path", b.notes[at].path)
		case .Unresolved:
			kit.jset_str(o, "kind", "unresolved")
			kit.jset_str(o, "identity", own)
		case .Elsewhere:
			// Named on purpose, never resolved from here: the target belongs
			// to another identity, and this command runs in this one's scope.
			kit.jset_str(o, "kind", "elsewhere")
			kit.jset_str(o, "identity", l.handle)
		}
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "links", arr)
	back := kit.jarr()
	self := -1
	for x, i in b.notes {
		if x.path == n.path {self = i}
	}
	for i in backlinks(b.notes[:], self, own) {
		src := b.notes[i]
		o := kit.jobj()
		kit.jset_str(o, "title", src.title)
		kit.jset_str(o, "path", src.path)
		ctx := ""
		for l in links_in(src.body) {
			k, at := link_resolve(b.notes[:], src.ident, own, l)
			if k == .Resolved && at == self {
				ctx = link_context(src.body, l)
				break
			}
		}
		kit.jset_str(o, "context", ctx)
		kit.jpush(back, o)
	}
	kit.jset(c.out, "backlinks", back)
	return kit.EXIT_OK
}

@(private = "file")
cmd_identities :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	arr := kit.jarr()
	for id, i in b.ids {
		o := kit.jobj()
		kit.jset_str(o, "handle", id.handle)
		kit.jset_str(o, "name", id.name)
		kit.jset_str(o, "kind", id.kind)
		kit.jset_str(o, "color", id.color)
		kit.jset_str(o, "dir", id.root)
		kit.jset_bool(o, "synced", ident_bound(id))
		count := 0
		for n in b.notes {
			if n.ident == i && !n.trashed {count += 1}
		}
		kit.jset_int(o, "notes", count)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "identities", arr)
	kit.jset_str(c.out, "scope", c.identity == "" ? "unscoped" : c.identity)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

@(private = "file")
cmd_new :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ti, code := target_ident(c, &b)
	if code != kit.EXIT_OK {
		return code
	}
	id := b.ids[ti]
	title := kit.cli_str(c, "title")
	text := unescape_newlines(kit.cli_str(c, "text"))
	body := title == "" ? "New note\n\n" : fmt.tprintf("# %s\n\n%s", title, text)
	if text != "" && !strings.has_suffix(body, "\n") {
		body = fmt.tprintf("%s\n", body)
	}
	return create_note(c, id, kit.cli_str(c, "notebook"), body, kit.cli_str(c, "tags"))
}

@(private = "file")
create_note :: proc(c: ^kit.Call, id: Ident, notebook, body, tags: string) -> int {
	folder := notebook == "" ? id.root : fmt.tprintf("%s/%s", id.root, notebook)
	if strings.contains(notebook, "..") || strings.has_prefix(notebook, "/") || strings.has_prefix(notebook, ".") {
		return kit.cli_failf(c, kit.EXIT_USAGE, "a notebook is a folder inside the identity's notes: %q is not", notebook)
	}
	meta := Meta{id = new_id(context.temp_allocator)}
	meta.tags = make([dynamic]string, context.temp_allocator)
	for t in strings.split(tags, ",", context.temp_allocator) {
		add_tag(&meta.tags, t, context.temp_allocator)
	}
	whole := compose(meta, body)
	want := unique_path(folder, slug(title_of(body, context.temp_allocator)), "")
	if c.dry_run {
		wrote_result(c, want, whole, true, meta.id, id.handle)
		return kit.EXIT_OK
	}
	os.make_directory_all(folder)
	if err := os.write_entire_file(want, transmute([]u8)whole); err != nil {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", want)
	}
	wrote_result(c, want, whole, true, meta.id, id.handle)
	return kit.EXIT_OK
}

@(private = "file")
cmd_capture :: proc(c: ^kit.Call) -> int {
	text := unescape_newlines(kit.cli_str(c, "text"))
	if text == "" {
		if c.dry_run || c.json {
			return kit.cli_fail(c, kit.EXIT_USAGE, "the capture window needs a display; give the text to capture without one")
		}
		code := capture_window()
		if code != 0 {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "could not open the capture window")
		}
		kit.jset_str(c.out, "title", "")
		kit.jset_str(c.out, "slug", "")
		kit.jset_str(c.out, "path", "")
		kit.jset_str(c.out, "id", "")
		kit.jset_str(c.out, "identity", "")
		kit.jset_int(c.out, "words", 0)
		kit.jset_int(c.out, "bytes", 0)
		kit.jset_bool(c.out, "created", false)
		return kit.EXIT_OK
	}
	b := book_load(c)
	ti := capture_ident(&b)
	if ti < 0 {
		code: int
		ti, code = target_ident(c, &b)
		if code != kit.EXIT_OK {
			return code
		}
	}
	first, rest := text, ""
	if nl := strings.index_byte(text, '\n'); nl >= 0 {
		first, rest = text[:nl], text[nl + 1:]
	}
	body := rest == "" ? fmt.tprintf("%s\n", first) : fmt.tprintf("%s\n\n%s\n", first, rest)
	return create_note(c, b.ids[ti], "", body, "")
}

// capture_ident is the identity quick capture writes into: the scope, or the
// identity the shell's switcher last chose (cloudkit's `current`), which is
// the identity the person is visibly in. Never the first one in a list.
capture_ident :: proc(b: ^Book) -> int {
	if len(b.ids) == 1 {
		return 0
	}
	if cur, e := ck.open(app = "notes"); ck.ok(e) {
		defer ck.close(cur)
		h := ck.current_identity(cur, context.temp_allocator)
		for id, i in b.ids {
			if h != "" && id.handle == h {
				return i
			}
		}
	}
	return -1
}

@(private = "file")
cmd_write :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	text := kit.cli_str(c, "text")
	file := kit.cli_str(c, "file")
	if text == "" && file == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "notes write needs --text or --file")
	}
	if file != "" {
		data, err := os.read_entire_file_from_path(file, context.temp_allocator)
		if err != nil {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", file)
		}
		text = string(data)
	}
	// A literal \n in a shell argument is almost always meant as a line break;
	// a note is line-oriented and a single-line note is rarely what was meant.
	text = unescape_newlines(text)
	if !strings.has_suffix(text, "\n") {
		text = fmt.tprintf("%s\n", text)
	}

	existing, found := resolve(&b, ref)
	if !found {
		ti, code := target_ident(c, &b)
		if code != kit.EXIT_OK {
			return code
		}
		_, body, _ := split_front(text)
		return create_note(c, b.ids[ti], "", body, "")
	}
	if existing.shared && existing.meta.access == "read" {
		return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "%q is shared with this identity to read, not to edit", existing.title)
	}
	root := b.ids[existing.ident].root
	if c.dry_run {
		want := unique_path(dir_of(existing.path), slug(title_of(text, context.temp_allocator)), existing.path)
		wrote_result(c, want, text, false, existing.meta.id, b.ids[existing.ident].handle)
		return kit.EXIT_OK
	}
	new_path, ok := store_write(root, existing.path, text)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write into %s", root)
	}
	wrote_result(c, new_path, text, false, existing.meta.id, b.ids[existing.ident].handle)
	return kit.EXIT_OK
}

@(private = "file")
cmd_append :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if n.shared && n.meta.access == "read" {
		return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "%q is shared with this identity to read, not to edit", n.title)
	}
	line := unescape_newlines(kit.cli_str(c, "text"))
	body := n.body
	if body != "" && !strings.has_suffix(body, "\n") {
		body = fmt.tprintf("%s\n", body)
	}
	body = fmt.tprintf("%s%s\n", body, line)
	if c.dry_run {
		wrote_result(c, n.path, body, false, n.meta.id, b.ids[n.ident].handle)
		return kit.EXIT_OK
	}
	new_path, ok := store_write(b.ids[n.ident].root, n.path, body)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", n.path)
	}
	wrote_result(c, new_path, body, false, n.meta.id, b.ids[n.ident].handle)
	return kit.EXIT_OK
}

@(private = "file")
cmd_rename :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	want := kit.cli_str(c, "title")

	// The title is the first line, so renaming is an edit to the text, which
	// is exactly what F2 does in the window. The heading marks are kept.
	rest := n.body
	first := ""
	for line in strings.split_lines_iterator(&rest) {
		first = line
		break
	}
	keep := ""
	t := strings.trim_left(first, " \t")
	if strings.has_prefix(t, "#") {
		h := 0
		for h < len(t) && t[h] == '#' {
			h += 1
		}
		keep = fmt.tprintf("%s ", t[:h])
	}
	tail := len(first) < len(n.body) ? n.body[len(first):] : "\n"
	body := fmt.tprintf("%s%s%s", keep, want, tail)

	if c.dry_run {
		wrote_result(c, unique_path(dir_of(n.path), slug(want), n.path), body, false, n.meta.id, b.ids[n.ident].handle)
		return kit.EXIT_OK
	}
	new_path, ok := store_write(b.ids[n.ident].root, n.path, body)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not rename %s", n.path)
	}
	wrote_result(c, new_path, body, false, n.meta.id, b.ids[n.ident].handle)
	return kit.EXIT_OK
}

@(private = "file")
moved_result :: proc(c: ^kit.Call, b: ^Book, n: Note, path: string) -> int {
	data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	wrote_result(c, path, string(data), false, n.meta.id, b.ids[n.ident].handle)
	return kit.EXIT_OK
}

@(private = "file")
cmd_move :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if n.shared {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a shared note is filed by its owner")
	}
	nb := strings.trim(kit.cli_str(c, "notebook"), "/")
	if strings.contains(nb, "..") || strings.has_prefix(nb, ".") || nb == SHARED_DIR || strings.has_prefix(nb, SHARED_DIR + "/") || nb == ATTACH_DIR {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q cannot be a notebook", nb)
	}
	if c.dry_run {
		return moved_result(c, &b, n, n.path)
	}
	folder := n.trashed ? (nb == "" ? TRASH_DIR : fmt.tprintf("%s/%s", TRASH_DIR, nb)) : nb
	p, ok := store_move(b.ids[n.ident].root, n.path, folder)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not move %s", n.path)
	}
	return moved_result(c, &b, n, p)
}

@(private = "file")
cmd_pin :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if n.shared {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a shared note is pinned by its owner")
	}
	m := read_meta(n.path)
	m.pinned = !kit.cli_bool(c, "off")
	if !c.dry_run && !store_write_meta(n.path, m) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", n.path)
	}
	return moved_result(c, &b, n, n.path)
}

@(private = "file")
cmd_tag :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if n.shared {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a shared note is tagged by its owner")
	}
	m := read_meta(n.path)
	for t in strings.split(kit.cli_str(c, "add"), ",", context.temp_allocator) {
		add_tag(&m.tags, t, context.temp_allocator)
	}
	for t in strings.split(kit.cli_str(c, "remove"), ",", context.temp_allocator) {
		low := strings.to_lower(strings.trim_space(strings.trim_left(t, "#")), context.temp_allocator)
		#reverse for x, i in m.tags {
			if x == low {ordered_remove(&m.tags, i)}
		}
	}
	if !c.dry_run && !store_write_meta(n.path, m) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", n.path)
	}
	return moved_result(c, &b, n, n.path)
}

@(private = "file")
cmd_trash :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if n.shared {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a shared note is trashed by its owner; ask them, or they can unshare it")
	}
	if c.dry_run {
		return moved_result(c, &b, n, n.path)
	}
	p, ok := store_trash(b.ids[n.ident].root, n)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not move %s to the trash", n.path)
	}
	return moved_result(c, &b, n, p)
}

@(private = "file")
cmd_restore :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if c.dry_run {
		return moved_result(c, &b, n, n.path)
	}
	p, ok := store_restore(b.ids[n.ident].root, n)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not restore %s", n.path)
	}
	return moved_result(c, &b, n, p)
}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	// The kit has already refused this if --yes was not given; by the time a
	// destructive body runs, consent is a fact rather than a question, and
	// nothing here has read a terminal.
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "path", n.path)
	id := b.ids[n.ident]
	idx := index_load(id.root, context.temp_allocator)
	entry, synced := idx[n.meta.id]
	cloud := "local"
	if n.shared {
		cloud = "local"
	} else if synced && entry.remote {
		cloud = "queued"
	}
	if c.dry_run {
		kit.jset_bool(c.out, "deleted", false)
		kit.jset_str(c.out, "cloud", cloud)
		return kit.EXIT_OK
	}
	if cloud == "queued" {
		a := acct_open()
		defer acct_close(&a)
		if a.ok {
			_, e := ck.rpc(a.c, "notes_purge", fmt.tprintf(`{{"p_note":"%s"}}`, n.meta.id), context.temp_allocator)
			if ck.ok(e) {
				cloud = "deleted"
			}
		}
		if cloud == "queued" {
			// Offline: the cloud copy is purged at the next sync, which sees a
			// note it knows the cloud has and that is gone here.
			purge_queue_add(id.root, n.meta.id)
		}
	}
	if !store_delete(n.path) {
		kit.jset_bool(c.out, "deleted", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not delete %s", n.path)
	}
	if id.id != "" {
		os.remove(state_file(id.root, id.id, n.meta.id))
	}
	if cloud != "queued" {
		delete_key(&idx, n.meta.id)
		if id.id != "" {
			index_save(id.root, idx)
		}
	}
	kit.jset_bool(c.out, "deleted", true)
	kit.jset_str(c.out, "cloud", cloud)
	return kit.EXIT_OK
}

purge_queue_add :: proc(root, id: string) {
	path := fmt.tprintf("%s/.palm/purge.tsv", root)
	old, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	os.make_directory_all(fmt.tprintf("%s/.palm", root))
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("%s%s\n", string(old), id))
}

// ---------------------------------------------------------------------------
// Sync, sharing, carrying
// ---------------------------------------------------------------------------

@(private = "file")
cmd_sync :: proc(c: ^kit.Call) -> int {
	offline := kit.cli_bool(c, "offline")
	a: Acct
	if !offline {
		a = acct_open()
	}
	defer acct_close(&a)
	enrolled := enroll(&a)
	b := book_load(c)
	account := a.ok ? "signed in" : (a.kind == .Unavailable ? "unreachable" : (offline ? "offline" : "not signed in"))
	kit.jset_str(c.out, "account", account)
	kit.jset_int(c.out, "enrolled", enrolled)
	arr := kit.jarr()
	opts := Sync_Opts {
		offline = offline || !a.ok,
		skip    = kit.cli_str(c, "skip"),
		device  = kit.cli_str(c, "device"),
	}
	for id in b.ids {
		if !ident_bound(id) {
			continue
		}
		if a.ok {
			purge_queue_run(&a, id.root)
		}
		r := sync_ident(&a, id, opts)
		o := kit.jobj()
		kit.jset_str(o, "identity", id.handle)
		kit.jset_bool(o, "online", r.online)
		kit.jset_int(o, "pushed", r.pushed)
		kit.jset_int(o, "pulled", r.pulled)
		kit.jset_int(o, "created", r.created)
		kit.jset_int(o, "arrived", r.arrived)
		kit.jset_int(o, "removed", r.removed)
		kit.jset_int(o, "queued", r.queued)
		kit.jset_int(o, "readonly", r.readonly)
		kit.jset(o, "events", tags_json(r.events[:]))
		if r.error != "" {
			kit.jset_str(o, "error", r.error)
		}
		kit.jpush(arr, o)
		if !c.json {
			for e in r.events {
				kit.cli_note(c, "%s: %s", id.handle, e)
			}
		}
	}
	kit.jset(c.out, "identities", arr)
	return kit.EXIT_OK
}

@(private = "file")
purge_queue_run :: proc(a: ^Acct, root: string) {
	path := fmt.tprintf("%s/.palm/purge.tsv", root)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	idx := index_load(root, context.temp_allocator)
	still := strings.builder_make(context.temp_allocator)
	rest := string(data)
	for id in strings.split_lines_iterator(&rest) {
		if !is_uuid(id) {continue}
		_, e := ck.rpc(a.c, "notes_purge", fmt.tprintf(`{{"p_note":"%s"}}`, id), context.temp_allocator)
		if ck.ok(e) || e.kind == .Out_Of_Scope {
			delete_key(&idx, id)
		} else {
			fmt.sbprintf(&still, "%s\n", id)
		}
	}
	index_save(root, idx)
	if strings.builder_len(still) == 0 {
		os.remove(path)
	} else {
		_ = os.write_entire_file(path, transmute([]u8)strings.to_string(still))
	}
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	a := acct_open()
	defer acct_close(&a)
	b := book_load(c)
	kit.jset_str(c.out, "account", a.ok ? "signed in" : (a.kind == .Unavailable ? "unreachable" : "not signed in"))
	if a.ok {
		kit.jset_str(c.out, "email", a.c.session.email)
	}
	host, port := client.server_address()
	kit.jset_str(c.out, "sync_server", fmt.tprintf("ws://%s:%d", host, port))
	arr := kit.jarr()
	for id, i in b.ids {
		o := kit.jobj()
		kit.jset_str(o, "identity", id.handle)
		kit.jset_bool(o, "synced", ident_bound(id))
		count, waiting := 0, 0
		for n in b.notes {
			if n.ident != i {continue}
			count += 1
			if id.id != "" {
				_, out, exists := state_peek(state_file(id.root, id.id, n.meta.id))
				if out > 0 || !exists {
					waiting += 1
				}
			}
		}
		kit.jset_int(o, "notes", count)
		kit.jset_int(o, "waiting", waiting)
		kit.jset_int(o, "carries_waiting", len(carries_pending_load(id.root)))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "identities", arr)
	return kit.EXIT_OK
}

// need_cloud opens the account for a command that has no meaning offline,
// and refuses with exit 6 (unavailable) or 5 (a scope that cannot do it).
@(private = "file")
need_cloud :: proc(c: ^kit.Call) -> (a: Acct, ok: bool) {
	a = acct_open()
	if !a.ok {
		code := a.kind == .Unavailable ? kit.EXIT_UNAVAILABLE : kit.EXIT_UNAVAILABLE
		kit.cli_failf(c, code, "the account is not available: %s", a.err)
		return a, false
	}
	return a, true
}

@(private = "file")
share_target :: proc(c: ^kit.Call, b: ^Book) -> (n: Note, code: int) {
	ref := kit.cli_str(c, "note")
	found: bool
	n, found = resolve(b, ref)
	if !found {
		return {}, not_found(c, ref)
	}
	if n.shared {
		return {}, kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "only the owning identity can share this note")
	}
	if !ident_bound(b.ids[n.ident]) {
		return {}, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "this notebook is not synced to an account; run `notes sync` signed in first")
	}
	idx := index_load(b.ids[n.ident].root, context.temp_allocator)
	if e, has := idx[n.meta.id]; !has || !e.remote {
		return {}, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "the note has not reached the cloud yet; run `notes sync` first")
	}
	return n, kit.EXIT_OK
}

@(private = "file")
cmd_share :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	n, code := share_target(c, &b)
	if code != kit.EXIT_OK {
		return code
	}
	with := kit.cli_str(c, "with")
	access := kit.cli_str(c, "access")
	if access == "" {
		access = "read"
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "id", n.meta.id)
	kit.jset_str(c.out, "with", with)
	kit.jset_str(c.out, "access", access)
	if c.dry_run {
		return kit.EXIT_OK
	}
	a, aok := need_cloud(c)
	defer acct_close(&a)
	if !aok {
		return kit.EXIT_UNAVAILABLE
	}
	o := ck.obj()
	ck.put(&o, "p_note", n.meta.id)
	ck.put(&o, "p_handle", with)
	ck.put(&o, "p_access", access)
	_, e := ck.rpc(a.c, "notes_share", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		code := e.kind == .Out_Of_Scope ? kit.EXIT_OUT_OF_SCOPE : (e.kind == .Not_Found ? kit.EXIT_NOT_FOUND : kit.EXIT_FAILED)
		return kit.cli_failf(c, code, "could not share: %s", e.message)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_unshare :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	n, code := share_target(c, &b)
	if code != kit.EXIT_OK {
		return code
	}
	with := kit.cli_str(c, "with")
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "id", n.meta.id)
	kit.jset_str(c.out, "with", with)
	kit.jset_str(c.out, "access", "none")
	if c.dry_run {
		return kit.EXIT_OK
	}
	a, aok := need_cloud(c)
	defer acct_close(&a)
	if !aok {
		return kit.EXIT_UNAVAILABLE
	}
	o := ck.obj()
	ck.put(&o, "p_note", n.meta.id)
	ck.put(&o, "p_handle", with)
	_, e := ck.rpc(a.c, "notes_unshare", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not unshare: %s", e.message)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_people :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "title", n.title)
	arr := kit.jarr()
	kit.jset(c.out, "people", arr)
	a := acct_open()
	defer acct_close(&a)
	if !a.ok {
		return kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "the account is not available: %s", a.err)
	}
	v, e := ck.rpc(a.c, "notes_people", fmt.tprintf(`{{"p_note":"%s"}}`, n.meta.id), context.temp_allocator)
	if !ck.ok(e) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s", e.message)
	}
	for row in ck.array(v) {
		o := kit.jobj()
		kit.jset_str(o, "handle", ck.get_str(row, "handle"))
		kit.jset_str(o, "name", ck.get_str(row, "display_name"))
		kit.jset_str(o, "access", ck.get_str(row, "access"))
		kit.jpush(arr, o)
	}
	return kit.EXIT_OK
}

// carry_note is the carry, shared by the command and the window: the copy is
// written into the target identity's folder at once (with its own new id),
// and the account records it — now, or at the next sync if offline.
carry_note :: proc(b: ^Book, n: Note, to: int, device: string) -> (copy_path, copy_id, hash: string, recorded: bool, err: string) {
	src := b.ids[n.ident]
	dst := b.ids[to]
	copy_id = new_id(context.temp_allocator)
	hash = sha256_hex(n.body)
	meta := Meta{id = copy_id, carried_from = fmt.tprintf("%s/%s", src.handle, n.meta.id)}
	whole := compose(meta, n.body)
	want := unique_path(dst.root, slug(n.title), "")
	os.make_directory_all(dst.root)
	if os.write_entire_file(want, transmute([]u8)whole) != nil {
		return "", "", "", false, fmt.tprintf("could not write into %s", dst.root)
	}
	copy_path = want
	pc := Pending_Carry {
		new_id      = copy_id,
		from_id     = n.meta.id,
		from_handle = src.handle,
		to_handle   = dst.handle,
		hash        = hash,
		title       = n.title,
		bytes       = len(n.body),
	}
	a := acct_open()
	defer acct_close(&a)
	if a.ok && ident_bound(dst) {
		if _, e := carry_record(&a, pc, device); e == "" {
			recorded = true
			idx := index_load(dst.root, context.temp_allocator)
			idx[copy_id] = Index_Entry{remote = true, access = "owner"}
			index_save(dst.root, idx)
			// Push the copy's text now, so the target identity's other
			// devices see it at their next sync.
			r := sync_ident(&a, dst, {device = device})
			_ = r
			return
		} else {
			err = e
		}
	}
	if ident_bound(dst) {
		existing := carries_pending_load(dst.root)
		all := make([dynamic]Pending_Carry, context.temp_allocator)
		append(&all, ..existing)
		append(&all, pc)
		carries_pending_save(dst.root, all[:])
	}
	return
}

@(private = "file")
cmd_carry :: proc(c: ^kit.Call) -> int {
	if c.identity != "" {
		kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "carry acts in two identities, and this process is scoped to one")
		kit.cli_err_field(c, "identity", c.identity)
		return kit.EXIT_OUT_OF_SCOPE
	}
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	if n.shared {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a note shared with you is its owner's to carry")
	}
	to := ident_find(b.ids[:], kit.cli_str(c, "to"))
	if to < 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no identity %q on this device", kit.cli_str(c, "to"))
	}
	if to == n.ident {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is already in %s", n.title, b.ids[to].handle)
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "from", b.ids[n.ident].handle)
	kit.jset_str(c.out, "to", b.ids[to].handle)
	kit.jset_str(c.out, "from_id", n.meta.id)
	kit.jset_str(c.out, "hash", sha256_hex(n.body))
	if c.dry_run {
		kit.jset_str(c.out, "id", "")
		kit.jset_str(c.out, "path", "")
		kit.jset_bool(c.out, "recorded", false)
		return kit.EXIT_OK
	}
	path, id, _, recorded, err := carry_note(&b, n, to, kit.cli_str(c, "device"))
	if path == "" {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s", err)
	}
	if err != "" {
		kit.cli_note(c, "not recorded yet (%s); the next sync records it", err)
	}
	kit.jset_str(c.out, "id", id)
	kit.jset_str(c.out, "path", path)
	kit.jset_bool(c.out, "recorded", recorded)
	return kit.EXIT_OK
}

@(private = "file")
cmd_log :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	if len(b.ids) == 0 {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "no identity's notes are on this device in this scope")
	}
	ti := 0
	if len(b.ids) > 1 {
		code: int
		ti, code = target_ident(c, &b)
		if code != kit.EXIT_OK {
			return code
		}
	}
	id := b.ids[ti]
	kit.jset_str(c.out, "identity", id.handle)
	arr := kit.jarr()
	kit.jset(c.out, "entries", arr)
	for pc in carries_pending_load(id.root) {
		o := kit.jobj()
		kit.jset_str(o, "direction", "in")
		kit.jset_str(o, "title", pc.title)
		kit.jset_str(o, "peer", pc.from_handle)
		kit.jset_str(o, "note", pc.new_id)
		kit.jset_str(o, "peer_note", pc.from_id)
		kit.jset_str(o, "hash", pc.hash)
		kit.jset_str(o, "device", "this device")
		kit.jset_str(o, "at", "")
		kit.jset_bool(o, "pending", true)
		kit.jpush(arr, o)
	}
	if !ident_bound(id) {
		return kit.EXIT_OK
	}
	a := acct_open()
	defer acct_close(&a)
	if !a.ok {
		kit.cli_note(c, "the account is not reachable; showing only carries waiting on this device")
		return kit.EXIT_OK
	}
	limit := max(1, kit.cli_int(c, "limit", 50))
	v, e := ck.select(a.c, "note_carries",
		fmt.tprintf("select=*&identity_id=eq.%s&order=carried_at.desc&limit=%d", id.id, limit), context.temp_allocator)
	if !ck.ok(e) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s", e.message)
	}
	for row in ck.array(v) {
		o := kit.jobj()
		kit.jset_str(o, "direction", ck.get_str(row, "direction"))
		kit.jset_str(o, "title", ck.get_str(row, "title"))
		kit.jset_str(o, "peer", ck.get_str(row, "peer_handle"))
		kit.jset_str(o, "note", ck.get_str(row, "note_id"))
		kit.jset_str(o, "peer_note", ck.get_str(row, "peer_note"))
		kit.jset_str(o, "hash", ck.get_str(row, "content_hash"))
		kit.jset_str(o, "device", ck.get_str(row, "device"))
		kit.jset_str(o, "at", ck.get_str(row, "carried_at"))
		kit.jset_bool(o, "pending", false)
		kit.jpush(arr, o)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_history :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "id", n.meta.id)
	arr := kit.jarr()
	kit.jset(c.out, "sessions", arr)
	kit.jset_int(c.out, "revisions", 0)
	a, ok := need_cloud(c)
	defer acct_close(&a)
	if !ok {
		return kit.EXIT_UNAVAILABLE
	}
	v, e := ck.rpc(a.c, "collab_history", fmt.tprintf(`{{"p_doc":"%s"}}`, n.meta.id), context.temp_allocator)
	if !ck.ok(e) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s", e.message)
	}
	total := 0
	if sessions, sok := ck.get(v, "sessions").(json.Array); sok {
		for s in sessions {
			o := kit.jobj()
			kit.jset_int(o, "from", int(ck.get_int(s, "from")))
			kit.jset_int(o, "to", int(ck.get_int(s, "to")))
			kit.jset_int(o, "edits", int(ck.get_int(s, "n")))
			kit.jset_str(o, "at", ck.get_str(s, "last_at"))
			total = max(total, int(ck.get_int(s, "to")))
			authors := kit.jarr()
			if aa, aok := ck.get(s, "authors").(json.Array); aok {
				for x in aa {
					kit.jpush(authors, kit.jstr(ck.get_str(x, "name")))
				}
			}
			kit.jset(o, "authors", authors)
			kit.jpush(arr, o)
		}
	}
	kit.jset_int(c.out, "revisions", total)
	return kit.EXIT_OK
}

@(private = "file")
cmd_attach :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	file := kit.cli_str(c, "file")
	data, err := os.read_entire_file_from_path(file, context.temp_allocator)
	if err != nil {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", file)
	}
	id := b.ids[n.ident]
	sha := sha256_hex(string(data))
	name := base_name(file)
	stored := attach_file_name(sha, name)
	image := strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".png") ||
		strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".jpg") ||
		strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".jpeg")
	link := fmt.tprintf("%s[%s](%s/%s)", image ? "!" : "", name, ATTACH_DIR, stored)
	kit.jset_str(c.out, "note", n.title)
	kit.jset_str(c.out, "file", fmt.tprintf("%s/%s/%s", id.root, ATTACH_DIR, stored))
	kit.jset_str(c.out, "sha256", sha)
	kit.jset_str(c.out, "link", link)
	if c.dry_run {
		return kit.EXIT_OK
	}
	os.make_directory_all(fmt.tprintf("%s/%s", id.root, ATTACH_DIR))
	_ = os.write_entire_file(fmt.tprintf("%s/%s/%s", id.root, ATTACH_DIR, stored), data)
	body := n.body
	if body != "" && !strings.has_suffix(body, "\n") {
		body = fmt.tprintf("%s\n", body)
	}
	store_write(id.root, n.path, fmt.tprintf("%s\n%s\n", body, link))
	if ident_bound(id) {
		q := attach_queue_load(id.root)
		append(&q, Pending_Attach{n.meta.id, sha, name, stored, i64(len(data))})
		attach_queue_save(id.root, q[:])
	}
	return kit.EXIT_OK
}

// cmd_coedit joins a note's live session as this account's identity and
// types a script into it, so a second, real collaborator can be filmed
// without a second window. Every edit goes through the same CRDT and server
// as the window's.
@(private = "file")
cmd_coedit :: proc(c: ^kit.Call) -> int {
	b := book_load(c)
	ref := kit.cli_str(c, "note")
	n, found := resolve(&b, ref)
	if !found {
		return not_found(c, ref)
	}
	id := b.ids[n.ident]
	script, err := os.read_entire_file_from_path(kit.cli_str(c, "script"), context.temp_allocator)
	if err != nil {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read the script")
	}
	a, ok := need_cloud(c)
	defer acct_close(&a)
	if !ok {
		return kit.EXIT_UNAVAILABLE
	}
	host, port := client.server_address()
	s := client.session_open({host = host, port = port, doc_id = n.meta.id, as_id = id.id,
		token = a.c.session.access_token, app = "notes", dir = sync_dir(id.root)})
	defer client.session_close(s)
	if !settle(s, 10 * time.Second) {
		return kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "could not join the note: %s", s.error)
	}
	caret := u64(len(doc_body(s.doc)))
	aware :: proc(s: ^client.Session, caret: u64) {
		client.set_awareness(s, fmt.tprintf(`{{"caret":%d}}`, caret))
	}
	aware(s, caret)
	rest := string(script)
	for line in strings.split_lines_iterator(&rest) {
		client.poll(s)
		switch {
		case strings.has_prefix(line, "wait "):
			secs, _ := strconv.parse_f64(strings.trim_space(line[5:]))
			end := time.tick_now()
			for time.duration_seconds(time.tick_since(end)) < secs {
				client.poll(s)
				time.sleep(20 * time.Millisecond)
			}
		case strings.has_prefix(line, "at "):
			body := doc_body(s.doc)
			if i := strings.index(body, line[3:]); i >= 0 {
				caret = u64(i + len(line[3:]))
				if nl := strings.index_byte(body[caret:], '\n'); nl >= 0 {
					caret += u64(nl)
				}
			}
			aware(s, caret)
		case strings.has_prefix(line, "line "):
			// A new line after the caret's line, typed a character at a time.
			txt := fmt.tprintf("\n%s", line[5:])
			for i := 0; i < len(txt); i += 1 {
				crdt.insert_text(s.doc, BODY_KEY, caret, txt[i:i + 1])
				caret += 1
				client.flush(s)
				aware(s, caret)
				client.poll(s)
				time.sleep(45 * time.Millisecond)
			}
		case strings.has_prefix(line, "type "):
			txt := line[5:]
			for i := 0; i < len(txt); i += 1 {
				crdt.insert_text(s.doc, BODY_KEY, caret, txt[i:i + 1])
				caret += 1
				client.flush(s)
				aware(s, caret)
				client.poll(s)
				time.sleep(45 * time.Millisecond)
			}
		}
	}
	settle(s, 5 * time.Second)
	kit.jset_str(c.out, "note", n.meta.id)
	kit.jset_str(c.out, "text", doc_body(s.doc))
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	kit.jset_str(c.out, "dir", dir)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if code := shots(dir); code != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render into %s", dir)
	}
	return kit.EXIT_OK
}

// unescape_newlines turns the two characters \n into a line break. A shell
// argument cannot carry a real one without quoting gymnastics, and a note is
// line-oriented, so the escape is worth honouring.
unescape_newlines :: proc(s: string) -> string {
	if !strings.contains(s, "\\n") && !strings.contains(s, "\\t") {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if i + 1 < len(s) && s[i] == '\\' {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&sb, '\n')
				i += 2
				continue
			case 't':
				strings.write_byte(&sb, '\t')
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}
