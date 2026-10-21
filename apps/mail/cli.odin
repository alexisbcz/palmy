package main

// The command-line front end of Mail, the desktop Maildir client.
//
// Nothing below re-implements the client. A folder is listed by the same scan
// the sidebar is built from (`model_open`, `reload_all`); a message is read by
// the same `read_message` the reader pane shows; `search` is the window's own
// `matches_query`; `mark` is `set_flags`, the only place a flag ever changes;
// `move` is `move_message`, the M key; `archive` and `trash` are
// `archive_paths` and `trash_paths`, which the E and D keys call over the
// selection; `purge` is `purge_message`, Shift+D; and `send` fills the
// composer and calls `compose_send`, which writes into the account's own
// local Outbox and transmits nothing. So a message filed from here is
// indistinguishable from one filed in the window.
//
// The noun is `mailbox`, not `mail`: `palm mail` is the Palmy cloud's mail
// (`palm-mail`), and this is the local Maildir client beside it. The binary is
// still called `mail`, which is what the examples type.
//
// A read never writes. The window generates a fixture mailbox when it finds
// none; the command line does not, and an empty data directory is simply an
// empty answer (count 0), not an error.
//
// Scope: with $PALM_IDENTITY set, only that Palmy identity's mailbox exists
// for these commands — its handle, id or address. The test accounts and any
// discovered Maildir belong to no identity and are out of every scope, and
// naming one with --account inside a scope exits 5.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."

// cli_maildir is `--maildir=PATH`, taken off the command line by main before
// the kit parses the rest.
cli_maildir: string

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "accounts",
		summary = "every account (or Palmy identity) this client reads, with folder and unread counts",
		effect = .Read,
		out = ACCOUNTS_FIELDS,
		examples = {"mail accounts --json"},
		run = cmd_accounts,
	},
	{
		verb = "folders",
		summary = "each account's folders with their role, total and unread counts",
		effect = .Read,
		flags = {{name = "account", kind = .String, help = "only this account: a name, an address or a Palmy handle"}},
		out = FOLDERS_FIELDS,
		examples = {"mail folders --json", "mail folders --account Work --json"},
		run = cmd_folders,
	},
	{
		verb = "list",
		summary = "the messages in one folder, newest first (the first inbox, as the window opens on)",
		effect = .Read,
		flags = {
			{name = "folder", kind = .String, help = "a folder name such as Inbox, Sent or Archive/2024", def = "Inbox"},
			{name = "account", kind = .String, help = "the account the folder belongs to; the first that has it otherwise"},
			{name = "unread", kind = .Bool, help = "only unread messages"},
			{name = "limit", kind = .Int, help = "how many at most; 0 is all", def = "0"},
		},
		out = LIST_FIELDS,
		examples = {"mail list --json", "mail list --folder Sent --account Work --limit 5 --json"},
		run = cmd_list,
	},
	{
		verb = "read",
		summary = "one message: headers, the text the reader pane shows, and its attachments (does not mark it read)",
		effect = .Read,
		args = {{name = "id", kind = .String, help = "the message's id from list or search, its Message-ID, or its path", required = true}},
		out = READ_FIELDS,
		examples = {"mail read 1760000000.M1P1.palmy --json"},
		run = cmd_read,
	},
	{
		verb = "search",
		summary = "messages matching a query across every account in scope, with from: to: subject: body: is: has: in:",
		effect = .Read,
		args = {{name = "query", kind = .String, help = "words and operators, e.g. \"from:ada is:unread\"", required = true}},
		flags = {{name = "limit", kind = .Int, help = "how many at most; 0 is all", def = "0"}},
		out = SEARCH_FIELDS,
		examples = {"mail search invoice --json", "mail search \"from:ada is:unread\" --json"},
		run = cmd_search,
	},
	{
		verb = "mark",
		summary = "set a message's read and flagged state; the Maildir file is renamed as the window does",
		effect = .Idempotent,
		args = {{name = "id", kind = .String, help = "a message id", required = true}},
		flags = {
			{name = "seen", kind = .Bool, help = "read (--no-seen: unread)"},
			{name = "flagged", kind = .Bool, help = "flagged (--no-flagged: not)"},
		},
		out = MARK_FIELDS,
		examples = {"mail mark 1760000000.M1P1.palmy --seen --json", "mail mark 1760000000.M1P1.palmy --no-seen --flagged --json"},
		run = cmd_mark,
	},
	{
		verb = "move",
		summary = "file a message into another folder of its own account (the M key)",
		effect = .Mutate,
		args = {
			{name = "id", kind = .String, help = "a message id", required = true},
			{name = "folder", kind = .String, help = "the folder to file it in", required = true},
		},
		out = FILED_FIELDS,
		examples = {"mail move 1760000000.M1P1.palmy Archive --json"},
		run = cmd_move,
	},
	{
		verb = "archive",
		summary = "file a message into Archive, creating the folder if the account has none (the E key)",
		effect = .Mutate,
		args = {{name = "id", kind = .String, help = "a message id", required = true}},
		out = FILED_FIELDS,
		examples = {"mail archive 1760000000.M1P1.palmy --json"},
		run = cmd_archive,
	},
	{
		verb = "trash",
		summary = "move a message to Trash, or for POP3 mark it deleted on this machine (the D key)",
		effect = .Mutate,
		args = {{name = "id", kind = .String, help = "a message id", required = true}},
		out = FILED_FIELDS,
		examples = {"mail trash 1760000000.M1P1.palmy --json"},
		run = cmd_trash,
	},
	{
		verb = "purge",
		summary = "delete a message's file from disk, which cannot be undone (Shift+D)",
		effect = .Destructive,
		args = {{name = "id", kind = .String, help = "a message id", required = true}},
		out = PURGE_FIELDS,
		examples = {"mail purge 1760000000.M1P1.palmy --yes --json"},
		run = cmd_purge,
	},
	{
		verb = "send",
		summary = "queue a message in the account's local Outbox; nothing is transmitted from here",
		effect = .Mutate,
		flags = {
			{name = "to", kind = .String, help = "recipients, comma-separated", required = true},
			{name = "subject", kind = .String, help = "the subject line"},
			{name = "text", kind = .String, help = "the body"},
			{name = "cc", kind = .String, help = "copy recipients"},
			{name = "account", kind = .String, help = "the account to send from; the first in scope otherwise"},
		},
		out = SEND_FIELDS,
		examples = {"mail send --to ada@work.test --subject Lunch --text \"Noon?\" --json"},
		run = cmd_send,
	},
	{
		verb = "fixtures",
		summary = "write the fixture accounts and Maildirs into a directory (bare --fixtures: the data directory)",
		effect = .Mutate,
		aliases = {"--fixtures"},
		args = {{name = "dir", kind = .Path, help = "where to write them", required = true}},
		out = FIXTURES_FIELDS,
		examples = {"mail fixtures /tmp/mail-fixtures --json"},
		run = cmd_fixtures,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "mailbox",
			summary    = "the desktop Maildir client: accounts, folders, reading, filing, a local Outbox",
			gui        = true,
			takes_path = false,
			selftest   = run_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Mail reads Maildirs under its data directory, ~/.local/share/palmy-mail.
$PALMY_MAIL_DIR or --data-dir=PATH points it at another one, --maildir=PATH
at a single tree. A read never writes; an empty directory is an empty answer.

<id> is a message's id as list and search print it (the Maildir file name
before ":2,", which survives moves and flag changes), its Message-ID, or its
path. Nothing matching exits 3.

There is no network code in this binary. send writes into the account's own
Outbox Maildir and nothing else; for a Palmy identity the next mailcore sync
hands it to the server.

With no command, the window opens. Its own options:
  mail --selftest            the headless assertions
  mail --fixtures            write the fixture mailbox into the data directory
  mail --save-dir=PATH       where the Save Attachment dialog opens
  mail --shots DIR | --uitest=DIR | --walkthrough=DIR   offscreen renders
  mail --palm-shots=DIR --data-dir=PATH   the identity views of a dev stack

Keys: J K move · Enter open · C compose · / search · T select · E archive ·
M move · D Trash · Z undo a move · Shift+D delete from disk · P Palmy sign-in ·
1-9 one identity · 0 all · Shift+I unified inbox (prototype).`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

ACCOUNTS_FIELDS := []kit.Field {
	{
		name = "accounts",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "address", kind = .String},
			{name = "protocol", kind = .String, help = "IMAP, JMAP, POP3, or Maildir for a discovered tree"},
			{name = "root", kind = .String, help = "the Maildir on disk"},
			{name = "palm", kind = .Bool, help = "a Palmy identity"},
			{name = "handle", kind = .String, help = "the identity's handle, \"\" when not Palmy"},
			{name = "kind", kind = .String},
			{name = "folders", kind = .Int},
			{name = "unread", kind = .Int},
		},
	},
	{name = "count", kind = .Int},
	{name = "data_dir", kind = .String},
}

FOLDERS_FIELDS := []kit.Field {
	{
		name = "folders",
		kind = .Array,
		of = {
			{name = "account", kind = .String},
			{name = "name", kind = .String},
			{name = "role", kind = .String, help = "inbox, sent, drafts, outbox, archive, trash, junk or other"},
			{name = "total", kind = .Int},
			{name = "unread", kind = .Int},
			{name = "path", kind = .String},
		},
	},
	{name = "count", kind = .Int},
}

MESSAGE_FIELDS :: []kit.Field {
	{name = "id", kind = .String, help = "the Maildir file name before \":2,\""},
	{name = "account", kind = .String},
	{name = "folder", kind = .String},
	{name = "subject", kind = .String},
	{name = "from", kind = .String},
	{name = "date", kind = .String},
	{name = "flags", kind = .String, help = "Maildir letters: S seen, F flagged, R answered, D draft, T trashed"},
	{name = "unread", kind = .Bool},
	{name = "attachments", kind = .Int},
	{name = "snippet", kind = .String},
}

LIST_FIELDS := []kit.Field {
	{name = "account", kind = .String, help = "\"\" when nothing in scope has the folder"},
	{name = "folder", kind = .String},
	{name = "messages", kind = .Array, of = MESSAGE_FIELDS},
	{name = "count", kind = .Int},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{name = "messages", kind = .Array, of = MESSAGE_FIELDS},
	{name = "count", kind = .Int},
}

READ_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "account", kind = .String},
	{name = "folder", kind = .String},
	{name = "path", kind = .String},
	{name = "message_id", kind = .String},
	{name = "subject", kind = .String},
	{name = "from", kind = .String},
	{name = "to", kind = .Array, of = {{kind = .String}}},
	{name = "cc", kind = .Array, of = {{kind = .String}}},
	{name = "date", kind = .String},
	{name = "flags", kind = .String},
	{name = "from_html", kind = .Bool, help = "the text was recovered from an HTML part"},
	{name = "text", kind = .String},
	{name = "attachments", kind = .Array, of = {{name = "name", kind = .String}, {name = "mime", kind = .String}, {name = "size", kind = .Int}}},
}

MARK_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "flags", kind = .String},
	{name = "seen", kind = .Bool},
	{name = "flagged", kind = .Bool},
	{name = "path", kind = .String},
}

FILED_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "from", kind = .String, help = "the folder it was in"},
	{name = "to", kind = .String, help = "the folder it is in now"},
	{name = "path", kind = .String},
	{name = "local", kind = .Bool, help = "POP3: marked deleted on this machine, the file not moved"},
}

PURGE_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "path", kind = .String},
	{name = "deleted", kind = .Bool},
}

SEND_FIELDS := []kit.Field {
	{name = "account", kind = .String},
	{name = "to", kind = .String},
	{name = "subject", kind = .String},
	{name = "path", kind = .String, help = "the file queued in the Outbox"},
	{name = "transmitted", kind = .Bool, help = "always false: this client has no network code"},
}

FIXTURES_FIELDS := []kit.Field {
	{name = "dir", kind = .String},
	{name = "accounts", kind = .Int},
	{name = "folders", kind = .Int},
	{name = "messages", kind = .Int},
}

// ---------------------------------------------------------------------------
// The model, headless
// ---------------------------------------------------------------------------

// cli_open loads every account the way the window does, without the window's
// one write (fixtures for an empty data directory) and without its draft.
@(private = "file")
cli_open :: proc() -> ^State {
	st := new(State)
	model_open(st, cli_maildir)
	reload_all(st)
	return st
}

// in_scope: unscoped, everything; inside $PALM_IDENTITY, only that identity's
// Palmy mailbox.
@(private = "file")
in_scope :: proc(c: ^kit.Call, a: Account) -> bool {
	if c.identity == "" {
		return true
	}
	return a.palm && (a.handle == c.identity || a.identity_id == c.identity || a.address == c.identity)
}

@(private = "file")
account_matches :: proc(a: Account, ref: string) -> bool {
	r := strings.to_lower(ref, context.temp_allocator)
	return(
		strings.to_lower(a.name, context.temp_allocator) == r ||
		strings.to_lower(a.address, context.temp_allocator) == r ||
		(a.handle != "" && strings.to_lower(a.handle, context.temp_allocator) == r) ||
		strings.to_lower(basename_of(a.root), context.temp_allocator) == r \
	)
}

// find_account resolves --account. -1 with no error code means "not given".
@(private = "file")
find_account :: proc(c: ^kit.Call, st: ^State) -> (ai: int, code: int) {
	ref := kit.cli_str(c, "account")
	if ref == "" {
		return -1, kit.EXIT_OK
	}
	for a, i in st.accounts {
		if !account_matches(a, ref) {
			continue
		}
		if !in_scope(c, a) {
			owner := a.handle != "" ? a.handle : a.name
			kit.cli_scope_require(c, owner)
			return -1, kit.EXIT_OUT_OF_SCOPE
		}
		return i, kit.EXIT_OK
	}
	code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no account matching %q", ref)
	kit.cli_err_field(c, "account", ref)
	return -1, code
}

msg_key :: proc(m: Message) -> string {
	if i := strings.index(m.file, ":2,"); i >= 0 {
		return m.file[:i]
	}
	return m.file
}

// find_message resolves an <id> within scope.
@(private = "file")
find_message :: proc(c: ^kit.Call, st: ^State, ref: string) -> (mi: int, code: int) {
	want := strings.trim(ref, "<> ")
	for m, i in st.messages {
		if msg_hidden(st, m) || !in_scope(c, st.accounts[m.account]) {
			continue
		}
		if msg_key(m) == ref || m.file == ref || m.path == ref {
			return i, kit.EXIT_OK
		}
	}
	for m, i in st.messages {
		if msg_hidden(st, m) || !in_scope(c, st.accounts[m.account]) {
			continue
		}
		if want != "" && m.id == want {
			return i, kit.EXIT_OK
		}
	}
	code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no message matching %q", ref)
	kit.cli_err_field(c, "id", ref)
	return -1, code
}

// message_by_key finds a message again after a reload renumbered everything.
@(private = "file")
message_by_key :: proc(st: ^State, key: string) -> int {
	for m, i in st.messages {
		if msg_key(m) == key {
			return i
		}
	}
	return -1
}

@(private = "file")
role_word :: proc(r: Folder_Role) -> string {
	switch r {
	case .Inbox:
		return "inbox"
	case .Sent:
		return "sent"
	case .Drafts:
		return "drafts"
	case .Outbox:
		return "outbox"
	case .Archive:
		return "archive"
	case .Trash:
		return "trash"
	case .Junk:
		return "junk"
	case .Other:
		return "other"
	}
	return "other"
}

@(private = "file")
flag_letters :: proc(fl: Flags) -> string {
	b := strings.builder_make(context.temp_allocator)
	// Maildir's own order, ASCII.
	for ch in ([?]u8{'D', 'F', 'P', 'R', 'S', 'T'}) {
		if f, ok := flag_of_char(ch); ok && f in fl {
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
iso :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

@(private = "file")
addr_text :: proc(a: Address) -> string {
	if a.name == "" {
		return a.email
	}
	if a.email == "" {
		return a.name
	}
	return fmt.tprintf("%s <%s>", a.name, a.email)
}

@(private = "file")
folder_name :: proc(st: ^State, fi: int) -> string {
	if fi < 0 || fi >= len(st.folders) {
		return ""
	}
	return st.folders[fi].name
}

@(private = "file")
msg_json :: proc(st: ^State, m: Message) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", msg_key(m))
	kit.jset_str(o, "account", st.accounts[m.account].name)
	kit.jset_str(o, "folder", folder_name(st, m.folder))
	kit.jset_str(o, "subject", m.subject)
	kit.jset_str(o, "from", addr_text(m.from))
	kit.jset_str(o, "date", iso(m.date))
	kit.jset_str(o, "flags", flag_letters(m.flags))
	kit.jset_bool(o, "unread", msg_unread(m))
	kit.jset_int(o, "attachments", len(m.attachments))
	kit.jset_str(o, "snippet", m.snippet)
	return o
}

// newest_first orders message indices the way the list shows them.
@(private = "file")
newest_first :: proc(st: ^State, xs: []int) {
	for i in 1 ..< len(xs) {
		j := i
		for j > 0 && st.messages[xs[j]].date._nsec > st.messages[xs[j - 1]].date._nsec {
			xs[j], xs[j - 1] = xs[j - 1], xs[j]
			j -= 1
		}
	}
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_accounts :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	arr := kit.jarr()
	for a, ai in st.accounts {
		if !in_scope(c, a) {
			continue
		}
		unread := 0
		folders := 0
		for f in st.folders {
			if f.account == ai {
				folders += 1
				unread += f.unread
			}
		}
		o := kit.jobj()
		kit.jset_str(o, "name", a.name)
		kit.jset_str(o, "address", a.address)
		kit.jset_str(o, "protocol", a.discovered ? "Maildir" : protocol_name(a.protocol))
		kit.jset_str(o, "root", a.root)
		kit.jset_bool(o, "palm", a.palm)
		kit.jset_str(o, "handle", a.handle)
		kit.jset_str(o, "kind", a.kind)
		kit.jset_int(o, "folders", folders)
		kit.jset_int(o, "unread", unread)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "accounts", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	kit.jset_str(c.out, "data_dir", st.data_dir)
	return kit.EXIT_OK
}

@(private = "file")
cmd_folders :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	only, code := find_account(c, st)
	if code != kit.EXIT_OK {
		return code
	}
	arr := kit.jarr()
	for f in st.folders {
		if !in_scope(c, st.accounts[f.account]) || (only >= 0 && f.account != only) {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "account", st.accounts[f.account].name)
		kit.jset_str(o, "name", f.name)
		kit.jset_str(o, "role", role_word(f.role))
		kit.jset_int(o, "total", f.total)
		kit.jset_int(o, "unread", f.unread)
		kit.jset_str(o, "path", f.path)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "folders", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

// find_folder resolves a folder name in an account (or the first account in
// scope that has one by that name). Inbox matches by role as well as by name,
// since that is how the window opens on it.
@(private = "file")
find_folder :: proc(c: ^kit.Call, st: ^State, ai: int, name: string) -> int {
	for f, fi in st.folders {
		if (ai >= 0 && f.account != ai) || !in_scope(c, st.accounts[f.account]) {
			continue
		}
		if strings.equal_fold(f.name, name) || (strings.equal_fold(name, "inbox") && f.role == .Inbox && f.depth == 0) {
			return fi
		}
	}
	return -1
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	ai, code := find_account(c, st)
	if code != kit.EXIT_OK {
		return code
	}
	name := kit.cli_str(c, "folder")
	fi := find_folder(c, st, ai, name)
	if fi < 0 && (ai >= 0 || kit.cli_has(c, "folder")) {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no folder %q", name)
		kit.cli_err_field(c, "folder", name)
		return code
	}
	arr := kit.jarr()
	if fi >= 0 {
		// The same set the window's list holds for this folder.
		select_folder(st, fi)
		idx := make([dynamic]int, context.temp_allocator)
		for t in st.threads {
			for mi in t.msgs {
				append(&idx, mi)
			}
		}
		newest_first(st, idx[:])
		limit := kit.cli_int(c, "limit", 0)
		for mi in idx {
			m := st.messages[mi]
			if kit.cli_bool(c, "unread") && !msg_unread(m) {
				continue
			}
			if limit > 0 && kit.jlen(arr) >= limit {
				break
			}
			kit.jpush(arr, msg_json(st, m))
		}
	}
	kit.jset_str(c.out, "account", fi >= 0 ? st.accounts[st.folders[fi].account].name : "")
	kit.jset_str(c.out, "folder", fi >= 0 ? st.folders[fi].name : name)
	kit.jset(c.out, "messages", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_read :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	mi, code := find_message(c, st, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	m := st.messages[mi]
	kit.jset_str(c.out, "id", msg_key(m))
	kit.jset_str(c.out, "account", st.accounts[m.account].name)
	kit.jset_str(c.out, "folder", folder_name(st, m.folder))
	kit.jset_str(c.out, "path", m.path)
	kit.jset_str(c.out, "message_id", m.id)
	kit.jset_str(c.out, "subject", m.subject)
	kit.jset_str(c.out, "from", addr_text(m.from))
	to := kit.jarr()
	for a in m.to {
		kit.jpush(to, kit.jstr(addr_text(a)))
	}
	kit.jset(c.out, "to", to)
	cc := kit.jarr()
	for a in m.cc {
		kit.jpush(cc, kit.jstr(addr_text(a)))
	}
	kit.jset(c.out, "cc", cc)
	kit.jset_str(c.out, "date", iso(m.date))
	kit.jset_str(c.out, "flags", flag_letters(m.flags))
	kit.jset_bool(c.out, "from_html", m.from_html)
	// The text the reader pane draws: the body read_message decoded, plain
	// part first, HTML reduced to text with every attribute (and so every
	// remote resource) discarded.
	kit.jset_str(c.out, "text", m.body)
	atts := kit.jarr()
	for at in m.attachments {
		o := kit.jobj()
		kit.jset_str(o, "name", at.name)
		kit.jset_str(o, "mime", at.mime)
		kit.jset_int(o, "size", at.size)
		kit.jpush(atts, o)
	}
	kit.jset(c.out, "attachments", atts)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	q := kit.cli_str(c, "query")
	idx := make([dynamic]int, context.temp_allocator)
	for m, i in st.messages {
		if msg_hidden(st, m) || !in_scope(c, st.accounts[m.account]) {
			continue
		}
		if matches_query(st, m, q) {
			append(&idx, i)
		}
	}
	newest_first(st, idx[:])
	limit := kit.cli_int(c, "limit", 0)
	arr := kit.jarr()
	for mi in idx {
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		kit.jpush(arr, msg_json(st, st.messages[mi]))
	}
	kit.jset_str(c.out, "query", q)
	kit.jset(c.out, "messages", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_mark :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	mi, code := find_message(c, st, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	if !kit.cli_has(c, "seen") && !kit.cli_has(c, "flagged") {
		return kit.cli_fail(c, kit.EXIT_USAGE, "say what to set: --seen, --no-seen, --flagged or --no-flagged")
	}
	fl := st.messages[mi].flags
	if kit.cli_has(c, "seen") {
		if kit.cli_bool(c, "seen") {fl |= {.Seen}} else {fl &~= {.Seen}}
	}
	if kit.cli_has(c, "flagged") {
		if kit.cli_bool(c, "flagged") {fl |= {.Flagged}} else {fl &~= {.Flagged}}
	}
	if !c.dry_run {
		set_flags(st, mi, fl)
	}
	m := st.messages[mi]
	kit.jset_str(c.out, "id", msg_key(m))
	kit.jset_str(c.out, "flags", flag_letters(fl))
	kit.jset_bool(c.out, "seen", .Seen in fl)
	kit.jset_bool(c.out, "flagged", .Flagged in fl)
	kit.jset_str(c.out, "path", m.path)
	return kit.EXIT_OK
}

@(private = "file")
filed :: proc(c: ^kit.Call, st: ^State, key, from: string, local: bool) -> int {
	kit.jset_str(c.out, "id", key)
	kit.jset_str(c.out, "from", from)
	if mi := message_by_key(st, key); mi >= 0 {
		kit.jset_str(c.out, "to", folder_name(st, st.messages[mi].folder))
		kit.jset_str(c.out, "path", st.messages[mi].path)
	} else {
		kit.jset_str(c.out, "to", "")
		kit.jset_str(c.out, "path", "")
	}
	kit.jset_bool(c.out, "local", local)
	return kit.EXIT_OK
}

@(private = "file")
cmd_move :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	mi, code := find_message(c, st, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	m := st.messages[mi]
	name := kit.cli_str(c, "folder")
	target := find_folder(c, st, m.account, name)
	if target < 0 {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s has no folder %q", st.accounts[m.account].name, name)
		kit.cli_err_field(c, "folder", name)
		return code
	}
	key := strings.clone(msg_key(m), context.temp_allocator)
	from := strings.clone(folder_name(st, m.folder), context.temp_allocator)
	if c.dry_run {
		kit.jset_str(c.out, "id", key)
		kit.jset_str(c.out, "from", from)
		kit.jset_str(c.out, "to", st.folders[target].name)
		kit.jset_str(c.out, "path", m.path)
		kit.jset_bool(c.out, "local", false)
		return kit.EXIT_OK
	}
	if err := move_message(st, mi, target); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	return filed(c, st, key, from, false)
}

@(private = "file")
cmd_archive :: proc(c: ^kit.Call) -> int {
	return file_away(c, true)
}

@(private = "file")
cmd_trash :: proc(c: ^kit.Call) -> int {
	return file_away(c, false)
}

@(private = "file")
file_away :: proc(c: ^kit.Call, archive: bool) -> int {
	st := cli_open()
	mi, code := find_message(c, st, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	m := st.messages[mi]
	key := strings.clone(msg_key(m), context.temp_allocator)
	from := strings.clone(folder_name(st, m.folder), context.temp_allocator)
	if c.dry_run {
		// POP3 has no folders: a trash there is the local flag, in place.
		has_folders, _ := can_file(st, m.account)
		kit.jset_str(c.out, "id", key)
		kit.jset_str(c.out, "from", from)
		kit.jset_str(c.out, "to", archive ? "Archive" : (has_folders ? "Trash" : from))
		kit.jset_str(c.out, "path", m.path)
		kit.jset_bool(c.out, "local", !has_folders)
		return kit.EXIT_OK
	}
	paths := []string{strings.clone(m.path, context.temp_allocator)}
	local := false
	err := ""
	if archive {
		_, err = archive_paths(st, paths)
	} else {
		_, local, err = trash_paths(st, paths)
	}
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	return filed(c, st, key, from, local)
}

@(private = "file")
cmd_purge :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	mi, code := find_message(c, st, kit.cli_str(c, "id"))
	if code != kit.EXIT_OK {
		return code
	}
	m := st.messages[mi]
	kit.jset_str(c.out, "id", msg_key(m))
	kit.jset_str(c.out, "path", m.path)
	if c.dry_run {
		kit.jset_bool(c.out, "deleted", false)
		return kit.EXIT_OK
	}
	path := strings.clone(m.path, context.temp_allocator)
	if err := purge_message(st, mi); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_bool(c.out, "deleted", true)
	return kit.EXIT_OK
}

@(private = "file")
cmd_send :: proc(c: ^kit.Call) -> int {
	st := cli_open()
	ai, code := find_account(c, st)
	if code != kit.EXIT_OK {
		return code
	}
	if ai < 0 {
		for a, i in st.accounts {
			if in_scope(c, a) {
				ai = i
				break
			}
		}
	}
	if ai < 0 {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no account to send from")
	}
	// The composer, filled as typing would fill it, and the window's own Send.
	comp := &st.comp
	compose_reset(comp)
	comp.mode = .New
	comp.account = ai
	le_set(&comp.to, kit.cli_str(c, "to"))
	le_set(&comp.cc, kit.cli_str(c, "cc"))
	le_set(&comp.subject, kit.cli_str(c, "subject"))
	text, _ := strings.replace_all(kit.cli_str(c, "text"), "\\n", "\n", context.temp_allocator)
	buf_set_text(&comp.body, text)

	kit.jset_str(c.out, "account", st.accounts[ai].name)
	kit.jset_str(c.out, "to", kit.cli_str(c, "to"))
	kit.jset_str(c.out, "subject", kit.cli_str(c, "subject"))
	kit.jset_bool(c.out, "transmitted", false)
	if c.dry_run {
		kit.jset_str(c.out, "path", send_destination(st, ai, context.temp_allocator))
		return kit.EXIT_OK
	}
	path, ok := compose_send(st)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_FAILED, st.toast)
	}
	kit.jset_str(c.out, "path", path)
	return kit.EXIT_OK
}

@(private = "file")
cmd_fixtures :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	kit.jset_str(c.out, "dir", dir)
	if c.dry_run {
		kit.jset_int(c.out, "accounts", 0)
		kit.jset_int(c.out, "folders", 0)
		kit.jset_int(c.out, "messages", 0)
		return kit.EXIT_OK
	}
	accounts, folders, messages := write_fixtures(dir)
	kit.jset_int(c.out, "accounts", accounts)
	kit.jset_int(c.out, "folders", folders)
	kit.jset_int(c.out, "messages", messages)
	return kit.EXIT_OK
}
