// The non-visual half of the mail client: accounts, Maildir on disk, messages,
// threads, search and flags.
//
// Nothing in this file opens a socket. The only inputs are a config file and a
// Maildir tree, both under the app's own data directory.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."

import "../../cloud/mail/readable"

// ---------------------------------------------------------------------------
// Accounts
//
// An account has a protocol, and the protocol changes what the client may do.
// IMAP and JMAP have a server-side folder tree and server-side flags. POP3 has
// neither: one inbox, and read/flagged state that lives only on this machine.
// ---------------------------------------------------------------------------

Protocol :: enum {
	IMAP,
	JMAP,
	POP3,
}

protocol_name :: proc(pr: Protocol) -> string {
	switch pr {
	case .IMAP:
		return "IMAP"
	case .JMAP:
		return "JMAP"
	case .POP3:
		return "POP3"
	}
	return "?"
}

protocol_icon :: proc(pr: Protocol) -> p.Icon {
	switch pr {
	case .IMAP:
		return ICON_SERVER
	case .JMAP:
		return ICON_CLOUD
	case .POP3:
		return ICON_DOWNLOAD
	}
	return ICON_SERVER
}

protocol_tint :: proc(pr: Protocol) -> string {
	switch pr {
	case .IMAP:
		return "text-sky-600"
	case .JMAP:
		return "text-violet-600"
	case .POP3:
		return "text-amber-600"
	}
	return "text-muted-foreground"
}

// has_server_folders is the single place the folder question is asked. POP3
// defines no mailboxes beyond the inbox, so a POP3 account must never be shown
// a Sent/Drafts/Archive tree as though the server had one.
has_server_folders :: proc(pr: Protocol) -> bool {
	return pr != .POP3
}

// has_server_flags: POP3 has no \Seen, so read and flagged state is local.
has_server_flags :: proc(pr: Protocol) -> bool {
	return pr != .POP3
}

Account :: struct {
	name:        string,
	protocol:    Protocol,
	address:     string,
	host:        string,
	port:        int,
	root:        string, // the Maildir root for this account
	first:       int, // index of its first folder in State.folders
	count:       int, // how many folders it has
	collapsed:   bool,
	loopback:    bool, // the configured host is 127.0.0.1 / localhost

	// Found on disk rather than named in the config: a Maildir the engine
	// wrote that nothing points at yet. Its protocol is genuinely unknown, so
	// the UI says "Maildir" instead of guessing one.
	discovered:  bool,

	// A Palmy identity, read from palmy.conf (see palm.odin). Each
	// identity of the signed-in account is its own account here, with its
	// own Maildir, because it is its own mailbox on the server.
	palm:        bool,
	identity_id: string,
	handle:      string,
	kind:        string, // personal, work, public, project
	color:       string, // a Tailwind hue: indigo, emerald...
}

// LOOPBACK_HOSTS is the whole allow-list. A config naming anything else is
// loaded but marked unusable, and the UI says so: this client must not be
// pointed at a real provider.
LOOPBACK_HOSTS :: [?]string{"127.0.0.1", "::1", "localhost", ""}

is_loopback :: proc(host: string) -> bool {
	h := strings.to_lower(strings.trim_space(host), context.temp_allocator)
	for ok in LOOPBACK_HOSTS {
		if h == ok {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Folders
// ---------------------------------------------------------------------------

Folder_Role :: enum {
	Inbox,
	Sent,
	Drafts,
	Outbox,
	Archive,
	Trash,
	Junk,
	Other,
}

// role_of_name reads the *first* path component, so Archive/2024 keeps the
// archive's role and sorts under it rather than drifting to the bottom of the
// list among the ordinary folders. A nested folder still draws a plain folder
// icon; that is what `Folder.depth` is for.
role_of_name :: proc(name: string) -> Folder_Role {
	root := name
	if i := strings.index_byte(name, '/'); i >= 0 {
		root = name[:i]
	}
	switch strings.to_lower(root, context.temp_allocator) {
	case "inbox":
		return .Inbox
	case "sent", "sent items", "sent mail":
		return .Sent
	case "drafts", "draft":
		return .Drafts
	case "outbox", "queue":
		return .Outbox
	case "archive", "all mail", "archives":
		return .Archive
	case "trash", "deleted", "deleted items", "bin":
		return .Trash
	case "junk", "spam":
		return .Junk
	}
	return .Other
}

role_icon :: proc(r: Folder_Role) -> p.Icon {
	switch r {
	case .Inbox:
		return ICON_INBOX
	case .Sent:
		return ICON_SEND
	case .Drafts:
		return ICON_PENCIL
	case .Outbox:
		return ICON_CLOCK
	case .Archive:
		return ICON_ARCHIVE
	case .Trash:
		return ICON_TRASH
	case .Junk:
		return ICON_BAN
	case .Other:
		return ICON_FOLDER
	}
	return ICON_FOLDER
}

// ROLE_ORDER is the order a mail client always shows: inbox first, the special
// folders in their familiar sequence, then everything else alphabetically.
role_order :: proc(r: Folder_Role) -> int {
	switch r {
	case .Inbox:
		return 0
	case .Drafts:
		return 1
	case .Outbox:
		return 2
	case .Sent:
		return 3
	case .Archive:
		return 4
	case .Junk:
		return 5
	case .Trash:
		return 6
	case .Other:
		return 7
	}
	return 7
}

Folder :: struct {
	account: int,
	name:    string, // "Archive/2024"
	display: string, // "2024"
	depth:   int,
	path:    string,
	role:    Folder_Role,
	total:   int,
	unread:  int,
	first:   int, // index into State.messages
	count:   int,
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

Flag :: enum {
	Seen,
	Answered,
	Flagged,
	Draft,
	Deleted,
	Passed,
}

Flags :: bit_set[Flag]

// MAILDIR_FLAG_CHARS maps the `:2,` suffix, in the order Maildir defines.
flag_of_char :: proc(c: u8) -> (Flag, bool) {
	switch c {
	case 'D':
		return .Draft, true
	case 'F':
		return .Flagged, true
	case 'P':
		return .Passed, true
	case 'R':
		return .Answered, true
	case 'S':
		return .Seen, true
	case 'T':
		return .Deleted, true
	}
	return .Seen, false
}

char_of_flag :: proc(f: Flag) -> u8 {
	switch f {
	case .Draft:
		return 'D'
	case .Flagged:
		return 'F'
	case .Passed:
		return 'P'
	case .Answered:
		return 'R'
	case .Seen:
		return 'S'
	case .Deleted:
		return 'T'
	}
	return '?'
}

// parse_maildir_flags reads the `:2,FLAGS` info suffix of a Maildir filename.
// A file in `new/` has no suffix at all, and is unread by definition.
parse_maildir_flags :: proc(filename: string) -> Flags {
	out: Flags
	i := strings.last_index(filename, ":2,")
	if i < 0 {
		return out
	}
	for c in transmute([]u8)filename[i + 3:] {
		if f, ok := flag_of_char(c); ok {
			out |= {f}
		}
	}
	return out
}

// maildir_name_with_flags rewrites a filename's info suffix. Flag characters
// are stored in ASCII order, which is what the spec asks for.
maildir_name_with_flags :: proc(filename: string, fl: Flags, allocator := context.allocator) -> string {
	base := filename
	if i := strings.last_index(filename, ":2,"); i >= 0 {
		base = filename[:i]
	} else if colon := strings.last_index_byte(filename, ':'); colon >= 0 {
		base = filename[:colon]
	}
	chars := make([dynamic]u8, 0, 6, context.temp_allocator)
	for f in Flag {
		if f in fl {
			append(&chars, char_of_flag(f))
		}
	}
	slice.sort(chars[:])
	return fmt.aprintf("%s:2,%s", base, string(chars[:]), allocator = allocator)
}

Message :: struct {
	account:      int,
	folder:       int,
	path:         string,
	file:         string, // basename, where the flags live
	in_new:       bool,

	id:           string, // Message-ID, angle brackets stripped
	in_reply_to:  string,
	refs:         []string,

	subject:      string,
	base_subject: string, // Re:/Fwd: stripped and folded, for the subject fallback
	from:         Address,
	to:           []Address,
	cc:           []Address,
	reply_to:     Address,
	date:         time.Time,

	flags:        Flags,
	snippet:      string,
	body:         string,
	from_html:    bool,
	had_plain:    bool,
	had_html:     bool,
	parts_differ: bool, // see Body_Result.parts_differ
	attachments:  []Attachment,
	size:         int,

	blob:         string, // lowercased sender + subject + body, for search
	thread:       int,
	parent:       int,
	depth:        int,
}

msg_unread :: proc(m: Message) -> bool {
	return .Seen not_in m.flags
}

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------

Thread :: struct {
	msgs:       [dynamic]int, // in reply order, parents before children
	subject:    string,
	newest:     time.Time,
	oldest:     time.Time,
	unread:     int,
	flagged:    bool,
	has_attach: bool,
	expanded:   bool,
	senders:    string, // "Ada, Linus, Grace"
}

// ---------------------------------------------------------------------------
// The list, flattened
//
// A threaded list is a tree the keyboard has to walk linearly, so it is
// flattened once per rebuild into rows: a thread row, and, when the thread is
// expanded, one row per message under it.
// ---------------------------------------------------------------------------

Row_Kind :: enum {
	Thread,
	Message,
}

Row :: struct {
	kind:   Row_Kind,
	thread: int,
	msg:    int, // -1 on a thread row
	depth:  int,
}

Pane :: enum {
	Sidebar,
	List,
	Reader,
	Search,
	Compose,
}

// Compose_Field is also the Tab order. `Send` is a field rather than a button
// handled elsewhere so that the keyboard alone can reach it: the recorder can
// type and press named keys but cannot hold a modifier or click, and a Send
// that needs the mouse is a Send that cannot be demonstrated or tested.
Compose_Field :: enum {
	To,
	Cc,
	Subject,
	Body,
	Send,
}

Compose_Mode :: enum {
	New,
	Reply,
	Reply_All,
	Forward,
}

Composer :: struct {
	open:        bool,
	mode:        Compose_Mode,
	field:       Compose_Field,
	to:          Line_Edit,
	cc:          Line_Edit,
	subject:     Line_Edit,
	body:        Buffer, // the multi-line editor
	in_reply_to: string,
	references:  string,
	account:     int,
	sent_to:     string, // the outbox path, after a send
	confirm:     bool, // the Send confirmation step is showing

	// Autosave. `open_hash` is what the composer held the moment it was
	// filled, so a reply nobody typed into is not a draft; `saved_hash` is
	// what is on disk. Both are content hashes, which is cheap enough to
	// take once a second and exact enough that a save only happens when
	// something really changed.
	open_hash:   u64,
	saved_hash:  u64,
	saved_at:    time.Time,
	saved_any:   bool, // this composition has a slot on disk
	last_tick:   time.Time,

	// The Maildir file this composition was loaded from, when it was opened
	// out of the Drafts folder. Sending or discarding unlinks it; parking
	// rewrites it. Empty for a composition that started in the composer.
	origin_path: string,

	// Address autocomplete, for To and Cc.
	ac_open:     bool,
	ac_sel:      int,
	ac_prefix:   string, // the fragment being completed, lowercased
	ac_hits:     [dynamic]int, // indices into State.book
}

State :: struct {
	data_dir:   string,
	accounts:   [dynamic]Account,
	folders:    [dynamic]Folder,
	messages:   [dynamic]Message,
	threads:    [dynamic]Thread,
	rows:       [dynamic]Row,

	folder_sel: int, // index into folders
	row_sel:    int, // index into rows
	side_sel:   int, // index into the flattened sidebar
	pane:       Pane,

	query:      Line_Edit,
	searching:  bool, // a query is active, so the list is search results
	swallow:    bool, // ignore this frame's typed text; it opened the field

	comp:       Composer,

	toast:      string,
	toast_at:   f64,
	status:     string,

	now:        time.Time,
	tz_offset:  i64,

	reader_msg: int, // the message the reader is showing
	show_raw:   bool, // show source headers in the reader

	// Attachments. `att_sel` indexes the *saveable* attachments of the message
	// the reader is showing, not `Message.attachments`, because an inline
	// image the HTML references is not something to save and a cursor that
	// could land on one would be a cursor that could do nothing.
	att_sel:    int,
	saver:      Saver,
	save_dir:   string, // where the Save dialog opens

	// Filing. The move sheet is drawn in-window, like every other overlay
	// here: Wayland gives this toolkit no xdg_popup.
	move_open:  bool,
	move_sel:   int,
	confirm_purge: bool,
	undo:       Move_Undo,
	warn:       string, // a configuration problem worth saying out loud

	list_scroll_to: int, // a row to bring into view on the next frame
	list_scroll_home: bool, // the folder changed, so the list goes back to the top

	// Row geometry, recomputed whenever the rows change. The list is
	// virtualised — only the rows inside the viewport are built — so the
	// keyboard cannot rely on a node existing to scroll to, and asks the model
	// where the row is instead.
	row_y:      [dynamic]f32,
	list_h:     f32,

	// Layout, recomputed each frame. Hyprland tiles, so the window is
	// whatever the compositor decides and three fixed panes do not fit at
	// every width; below a threshold the folder list becomes a drawer.
	narrow:     bool,
	list_w:     f32,

	// A draft slot was found on disk at startup and nothing has picked it up
	// yet. The composer takes it on the next C.
	draft_waiting: bool,
	draft_label:   string, // "Subject — 14:03", for the toast and the status bar

	// Multi-select. Marks are kept by path rather than by index, for the
	// reason `selection_paths` gives: creating a folder reloads the tree and
	// renumbers every message, and an index taken before that reload names a
	// different message after it.
	marked:      map[string]bool,

	// The address book, built from every message on disk. Autocomplete reads
	// it; nothing else does.
	book:        [dynamic]Contact,

	// `--maildir=PATH` was given: one tree, and no discovery of others.
	single_tree: bool,
	read_scroll_home: bool,
	side_rows:  [dynamic]Side_Row,

	// Ids captured while building the frame, so the scroll API can be driven
	// after the tree exists. See `p.scroll_into_view`, which acts on the
	// geometry of the frame that has already been laid out.
	list_id:     u64,
	sel_row_id:  u64,
	read_id:     u64,
	side_id:     u64,
	side_row_id: u64,
	side_scroll: bool,

	// The attachment chips, for the same reason: the wrapping row's geometry
	// only exists after the tree has been laid out, and `--uitest` checks
	// that the row is as tall as the lines it laid out instead of trusting a
	// screenshot. 24 is `MAX_ATTACHMENT_CHIPS`.
	att_box_id:   u64,
	att_chip_ids: [24]u64,
	att_chip_n:   int,

	// Palmy. `id_view` is the identity being looked at: 1 + an index into
	// `accounts`, or 0 for all of them (so a zeroed State shows everything).
	// `unified_on` is the prototype toggle
	// that adds the "All inboxes" view; `unified` is that view being shown.
	palm_email:  string, // the signed-in account, from palmy.conf
	id_view:     int,
	unified_on:  bool,
	unified:     bool,
	signin:      Signin,
}

// Side_Row flattens the sidebar the same way Row flattens the list, so one
// index can walk accounts and folders together.
Side_Row_Kind :: enum {
	Account,
	Folder,
	Unified, // "All inboxes": every identity's inbox, the prototype view
}

Side_Row :: struct {
	kind:    Side_Row_Kind,
	account: int,
	folder:  int,
}

tfmt :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

// read_file is `os.read_entire_file` with a boolean, because every caller here
// wants "did it work" rather than which errno it was.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file(path, allocator)
	return d, err == nil
}

// write_file likewise. A failed write is reported, never ignored.
write_file :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

DEFAULT_CONFIG ::
`# palmy-mail accounts.
#
# Every host here must be loopback. This client reads a Maildir from disk and
# never dials anything; the host and port are recorded only so the UI can show
# which local test server an account belongs to.

[account]
name = Work
protocol = imap
address = alex@work.test
host = 127.0.0.1
port = 10143
path = work

[account]
name = Personal
protocol = jmap
address = alex@personal.test
host = 127.0.0.1
port = 10843
path = personal

[account]
name = Newsletters
protocol = pop3
address = alex@lists.test
host = 127.0.0.1
port = 10110
path = lists
`

// data_dir_override points the whole app at a tree other than the default.
// Only the offscreen harness sets it, and it sets it so that a run which files
// messages, deletes them and saves an attachment cannot touch the mailbox
// somebody is actually reading.
data_dir_override: string
data_dir_explicit: bool // --data-dir= was given

default_data_dir :: proc(allocator := context.allocator) -> string {
	if data_dir_override != "" {
		return strings.clone(data_dir_override, allocator)
	}
	// $PALMY_MAIL_DIR does the same from the environment, which is how the
	// command line's self-test and any agent driving it keep every run inside
	// a scratch tree: a variable reaches every child, a flag only one.
	if env := os.get_env("PALMY_MAIL_DIR", context.temp_allocator); env != "" {
		return strings.clone(env, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	return fmt.aprintf("%s/.local/share/palmy-mail", home, allocator = allocator)
}

config_path :: proc(dir: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/accounts.conf", dir, allocator = allocator)
}

// load_config reads `accounts.conf`. Anything missing falls back to the built
// in defaults, which are themselves loopback-only test values.
load_config :: proc(st: ^State) {
	path := config_path(st.data_dir, context.temp_allocator)
	raw, ok := read_file(path, context.temp_allocator)
	text := DEFAULT_CONFIG
	if ok && len(raw) > 0 {
		text = string(raw)
	} else if data_dir_explicit || os.exists(palm_conf_path(st.data_dir, context.temp_allocator)) {
		// Signed in to Palmy and nothing else configured, or a data
		// directory named on the command line: the identities are the
		// accounts, and the built-in test accounts would only be noise.
		text = ""
	}
	parse_config(st, text)
	load_palmy(st)
}

parse_config :: proc(st: ^State, text: string) {
	clear(&st.accounts)
	cur := -1
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || l[0] == ';' {
			continue
		}
		if l[0] == '[' {
			append(&st.accounts, Account{protocol = .IMAP, port = 0, loopback = true})
			cur = len(st.accounts) - 1
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 || cur < 0 {
			continue
		}
		k := strings.to_lower(strings.trim_space(l[:eq]), context.temp_allocator)
		v := strings.trim_space(l[eq + 1:])
		a := &st.accounts[cur]
		switch k {
		case "name":
			a.name = strings.clone(v)
		case "protocol":
			switch strings.to_lower(v, context.temp_allocator) {
			case "imap":
				a.protocol = .IMAP
			case "jmap":
				a.protocol = .JMAP
			case "pop3", "pop":
				a.protocol = .POP3
			}
		case "address":
			a.address = strings.clone(v)
		case "host":
			a.host = strings.clone(v)
		case "port":
			a.port, _ = strconv.parse_int(v)
		case "path":
			// A relative path stays inside the data directory; that is the
			// only place this app is allowed to read mail from.
			if strings.has_prefix(v, "/") {
				a.root = strings.clone(v)
			} else {
				a.root = fmt.aprintf("%s/%s", st.data_dir, v)
			}
		}
	}

	// Validate. A non-loopback host is not an error to crash on, it is a
	// configuration the UI refuses to treat as usable.
	bad := 0
	for &a in st.accounts {
		a.loopback = is_loopback(a.host)
		if !a.loopback {
			bad += 1
		}
		if a.name == "" {
			a.name = strings.clone("Account")
		}
		if a.root == "" {
			a.root = fmt.aprintf("%s/%s", st.data_dir, strings.to_lower(a.name))
		}
	}
	if bad > 0 {
		st.warn = fmt.aprintf(
			"%d account(s) name a host that is not loopback; they are shown offline and nothing is ever dialled.",
			bad,
		)
	}
}

// discover_accounts picks up Maildir trees sitting in the data directory that
// no configured account points at.
//
// The engine writes its mailboxes under the same `~/.local/share/palmy-mail`
// and does not write a config, so without this its output would be on disk and
// invisible. The protocol of a discovered tree is unknowable from the files, so
// it is labelled a Maildir rather than guessed at.
discover_accounts :: proc(st: ^State) {
	f, oerr := os.open(st.data_dir)
	if oerr != nil {
		return
	}
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	os.close(f)
	if rerr != nil && len(infos) == 0 {
		return
	}

	for info in infos {
		if info.type != .Directory || (len(info.name) > 0 && info.name[0] == '.') {
			continue
		}
		if !is_maildir(info.fullpath) {
			continue
		}
		known := false
		for a in st.accounts {
			if a.root == info.fullpath {
				known = true
				break
			}
		}
		if known {
			continue
		}
		append(
			&st.accounts,
			Account {
				name = strings.clone(info.name),
				protocol = .IMAP,
				address = strings.clone(""),
				host = strings.clone("127.0.0.1"),
				root = strings.clone(info.fullpath),
				loopback = true,
				discovered = true,
			},
		)
	}
}

// ---------------------------------------------------------------------------
// Scanning a Maildir
//
// A Maildir folder is a directory with `cur`, `new` and `tmp` inside it. Both
// conventions are read: Maildir++ (`.Sent`, `.Archive.2024` beside the root
// inbox) and plain nested directories (`Sent/`, `Archive/2024/`). Whichever
// the engine writes, the same tree comes out.
// ---------------------------------------------------------------------------

is_maildir :: proc(path: string) -> bool {
	return os.is_dir(tfmt("%s/cur", path)) && os.is_dir(tfmt("%s/new", path))
}

// free_message releases everything one message owns. A rescan happens every
// time the refresh button is pressed, so leaking a megabyte each time is not
// an option.
free_message :: proc(m: Message) {
	delete(m.path)
	delete(m.file)
	delete(m.id)
	delete(m.in_reply_to)
	for r in m.refs {
		delete(r)
	}
	delete(m.refs)
	delete(m.subject)
	delete(m.base_subject)
	delete(m.from.name)
	delete(m.from.email)
	delete(m.reply_to.name)
	delete(m.reply_to.email)
	for a in m.to {
		delete(a.name)
		delete(a.email)
	}
	delete(m.to)
	for a in m.cc {
		delete(a.name)
		delete(a.email)
	}
	delete(m.cc)
	delete(m.snippet)
	delete(m.body)
	for at in m.attachments {
		delete(at.name)
		delete(at.mime)
		delete(at.inline_cid)
		delete(at.section)
	}
	delete(m.attachments)
	delete(m.blob)
}

free_folder :: proc(f: Folder) {
	delete(f.name)
	delete(f.display)
	delete(f.path)
}

scan_accounts :: proc(st: ^State) {
	for f in st.folders {
		free_folder(f)
	}
	clear(&st.folders)
	for m in st.messages {
		free_message(m)
	}
	clear(&st.messages)
	for &t in st.threads {
		delete(t.msgs)
		delete(t.senders)
	}
	clear(&st.threads)
	clear(&st.rows)

	for &a, ai in st.accounts {
		a.first = len(st.folders)
		scan_account(st, ai)
		a.count = len(st.folders) - a.first
	}

	// Load the local flag sidecars for the POP3 accounts, whose read state
	// cannot live on a server.
	apply_local_flags(st)

	recount_folders(st)
}

// recount_folders recomputes every folder's totals from the messages. It runs
// after a scan and again after anything that moves a message between folders,
// so the sidebar's counts are never a stale memory of where mail used to be.
recount_folders :: proc(st: ^State) {
	for &f in st.folders {
		f.total, f.unread, f.count = 0, 0, 0
		f.first = -1
	}
	for m, i in st.messages {
		if m.folder < 0 || m.folder >= len(st.folders) {
			continue
		}
		if msg_hidden(st, m) {
			continue
		}
		f := &st.folders[m.folder]
		if f.first < 0 {
			f.first = i
		}
		f.count += 1
		f.total += 1
		if msg_unread(m) {
			f.unread += 1
		}
	}
}

// msg_hidden is the one case where a message in a folder is not shown in it: a
// POP3 message the user has deleted.
//
// POP3 has no folders to move it to and no server-side flag to set, so
// "deleted" can only be a local fact. It is recorded as the Maildir Trashed
// flag in this account's local sidecar, the file itself is left exactly where
// the engine put it, and the list stops showing it. Nothing is pretended about
// the server, and nothing is destroyed.
msg_hidden :: proc(st: ^State, m: Message) -> bool {
	if .Deleted not_in m.flags {
		return false
	}
	if m.account < 0 || m.account >= len(st.accounts) {
		return false
	}
	return !has_server_folders(st.accounts[m.account].protocol)
}

scan_account :: proc(st: ^State, ai: int) {
	a := &st.accounts[ai]
	root := a.root
	if !os.is_dir(root) {
		return
	}

	found := make([dynamic]Folder, 0, 8, context.temp_allocator)

	// The root itself is the inbox when it is a Maildir.
	if is_maildir(root) {
		append(
			&found,
			Folder {
				account = ai,
				name = strings.clone("Inbox"),
				display = strings.clone("Inbox"),
				path = strings.clone(root),
				role = .Inbox,
			},
		)
	}

	walk_folders(st, ai, root, "", 0, &found)

	// POP3 has one mailbox. Should a stray folder be on disk under a POP3
	// account, it is not presented as a server mailbox: the protocol has none.
	if !has_server_folders(a.protocol) {
		keep := make([dynamic]Folder, 0, 2, context.temp_allocator)
		for f in found {
			// Only the top-level inbox, plus the local Outbox a queued message
			// goes into. POP3 has nothing else, and showing more would be a
			// lie about what the protocol can do.
			if strings.index_byte(f.name, '/') < 0 && (f.role == .Inbox || f.role == .Outbox) {
				append(&keep, f)
			}
		}
		found = keep
	}

	slice.sort_by(found[:], proc(x, y: Folder) -> bool {
		ox, oy := role_order(x.role), role_order(y.role)
		if ox != oy {
			return ox < oy
		}
		return x.name < y.name
	})

	for f in found {
		fi := len(st.folders)
		ff := f
		ff.depth = strings.count(f.name, "/")
		append(&st.folders, ff)
		load_folder_messages(st, ai, fi, f.path)
	}
}

// walk_folders descends looking for Maildir directories, handling both the
// Maildir++ dotted names and plain nesting.
walk_folders :: proc(
	st: ^State,
	ai: int,
	dir: string,
	prefix: string,
	depth: int,
	out: ^[dynamic]Folder,
) {
	if depth > 6 {
		return
	}
	f, oerr := os.open(dir)
	if oerr != nil {
		return
	}
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	os.close(f)
	if rerr != nil && len(infos) == 0 {
		return
	}

	for fi in infos {
		if fi.type != .Directory {
			continue
		}
		nm := fi.name
		if nm == "cur" || nm == "new" || nm == "tmp" || nm == "." || nm == ".." {
			continue
		}

		// Maildir++ spells a subfolder `.Sent` and a nested one `.Archive.2024`.
		logical := nm
		dotted := false
		if len(nm) > 1 && nm[0] == '.' {
			logical, _ = strings.replace_all(nm[1:], ".", "/", context.temp_allocator)
			dotted = true
		} else if nm[0] == '.' {
			continue // a real dotfile
		}

		full := tfmt("%s/%s", dir, nm)
		name := prefix == "" ? logical : tfmt("%s/%s", prefix, logical)

		if is_maildir(full) {
			append(
				out,
				Folder {
					account = ai,
					name = strings.clone(name),
					display = strings.clone(leaf_of(name)),
					path = strings.clone(full),
					role = role_of_name(name),
				},
			)
		}
		// Maildir++ names are flat, so a dotted directory is never descended
		// into; plain nesting is.
		if !dotted {
			walk_folders(st, ai, full, name, depth + 1, out)
		}
	}
}

leaf_of :: proc(name: string) -> string {
	if i := strings.last_index_byte(name, '/'); i >= 0 {
		return name[i + 1:]
	}
	return name
}

load_folder_messages :: proc(st: ^State, ai, fi: int, path: string) {
	for sub in ([?]string{"new", "cur"}) {
		dir := tfmt("%s/%s", path, sub)
		f, oerr := os.open(dir)
		if oerr != nil {
			continue
		}
		infos, rerr := os.read_dir(f, -1, context.temp_allocator)
		os.close(f)
		if rerr != nil && len(infos) == 0 {
			continue
		}
		for info in infos {
			if info.type == .Directory || (len(info.name) > 0 && info.name[0] == '.') {
				continue
			}
			if m, ok := read_message(info.fullpath, info.name, sub == "new", ai, fi); ok {
				append(&st.messages, m)
			}
		}
	}
}

// read_message parses one Maildir file into the model. The decoded body is
// kept because search wants it and a few hundred messages is a megabyte or
// two; attachment bytes are not kept, only their names and sizes.
read_message :: proc(
	path, file: string,
	in_new: bool,
	ai, fi: int,
) -> (
	m: Message,
	ok: bool,
) {
	raw, rok := read_file(path, context.temp_allocator)
	if !rok {
		return {}, false
	}
	head, body := split_message(string(raw))
	hs := parse_headers(head, context.temp_allocator)

	m.account = ai
	m.folder = fi
	m.path = strings.clone(path)
	m.file = strings.clone(file)
	m.in_new = in_new
	m.size = len(raw)
	m.flags = in_new ? Flags{} : parse_maildir_flags(file)

	m.id = strings.clone(strings.trim(header_of(hs, "message-id"), "<> "))
	m.in_reply_to = strings.clone(first_msgid(header_of(hs, "in-reply-to")))
	m.refs = split_msgids(header_of(hs, "references"))

	m.subject = decode_encoded_words(header_of(hs, "subject"))
	if m.subject == "" {
		m.subject = strings.clone("(no subject)")
	}
	m.base_subject = base_subject(m.subject)
	m.from = parse_address(header_of(hs, "from"))
	m.reply_to = parse_address(header_of(hs, "reply-to"))
	m.to = parse_addresses(header_of(hs, "to"))
	m.cc = parse_addresses(header_of(hs, "cc"))

	if t, dok := parse_rfc5322_date(header_of(hs, "date")); dok {
		m.date = t
	} else if info, serr := os.stat(path, context.temp_allocator); serr == nil {
		m.date = info.modification_time
	}

	res := extract_body(head, body)
	m.body = res.text
	m.from_html = res.from_html
	m.had_plain = res.had_plain
	m.had_html = res.had_html
	m.parts_differ = res.parts_differ
	m.attachments = res.attachments
	// The snippet is cut from the text this reader shows (the plain part when
	// there is one), invisible characters removed: the list never shows what
	// the reader would not (cloud/mail/readable).
	m.snippet = make_snippet(readable.clean_plain(m.body, context.temp_allocator))

	b := strings.builder_make()
	strings.write_string(&b, strings.to_lower(m.from.name, context.temp_allocator))
	strings.write_byte(&b, ' ')
	strings.write_string(&b, strings.to_lower(m.from.email, context.temp_allocator))
	strings.write_byte(&b, ' ')
	for a in m.to {
		strings.write_string(&b, strings.to_lower(a.email, context.temp_allocator))
		strings.write_byte(&b, ' ')
		strings.write_string(&b, strings.to_lower(a.name, context.temp_allocator))
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, strings.to_lower(m.subject, context.temp_allocator))
	strings.write_byte(&b, '\n')
	strings.write_string(&b, strings.to_lower(m.body, context.temp_allocator))
	m.blob = strings.to_string(b)

	m.thread = -1
	m.parent = -1
	return m, true
}

// make_snippet is the one line of body a list row shows: quoted lines and
// signatures are skipped, because a reply whose snippet is the quote above it
// tells the reader nothing.
make_snippet :: proc(body: string, limit := 180) -> string {
	b := strings.builder_make()
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '>' || l == "--" || strings.has_prefix(l, "-- ") {
			continue
		}
		if strings.has_prefix(l, "On ") && strings.has_suffix(l, "wrote:") {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, l)
		if strings.builder_len(b) >= limit {
			break
		}
	}
	s := strings.to_string(b)
	if len(s) > limit {
		// Cut on a rune boundary.
		cut := limit
		for cut > 0 && s[cut] & 0xc0 == 0x80 {
			cut -= 1
		}
		return fmt.aprintf("%s…", s[:cut])
	}
	return s
}

first_msgid :: proc(s: string) -> string {
	if lt := strings.index_byte(s, '<'); lt >= 0 {
		if gt := strings.index_byte(s[lt:], '>'); gt > 0 {
			return s[lt + 1:lt + gt]
		}
	}
	return strings.trim_space(s)
}

split_msgids :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	rest := s
	for {
		lt := strings.index_byte(rest, '<')
		if lt < 0 {
			break
		}
		gt := strings.index_byte(rest[lt:], '>')
		if gt < 0 {
			break
		}
		id := strings.trim_space(rest[lt + 1:lt + gt])
		if id != "" {
			append(&out, strings.clone(id, allocator))
		}
		rest = rest[lt + gt:]
	}
	return out[:]
}

// looks_like_reply is true when the subject still carries a Re:/Fwd: prefix,
// which is the only evidence an orphaned message gives that it belongs to a
// conversation that started elsewhere.
looks_like_reply :: proc(subject: string) -> bool {
	t := strings.trim_space(subject)
	for pre in ([?]string{"re:", "re :", "fwd:", "fw:", "aw:", "antw:", "sv:", "vs:", "rif:"}) {
		if len(t) >= len(pre) && strings.equal_fold(t[:len(pre)], pre) {
			return true
		}
	}
	return false
}

// base_subject strips any number of Re:/Fwd:/Fw:/Aw:/Antw: prefixes and the
// `[list]` tag some mailing lists prepend, then folds case. Two messages with
// no References in common but the same base subject are the same conversation
// often enough that every client does this.
base_subject :: proc(s: string, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	for {
		changed := false
		// A leading [tag].
		if len(t) > 0 && t[0] == '[' {
			if close := strings.index_byte(t, ']'); close > 0 {
				t = strings.trim_space(t[close + 1:])
				changed = true
			}
		}
		for pre in ([?]string{"re:", "re :", "fwd:", "fw:", "aw:", "antw:", "sv:", "vs:", "rif:"}) {
			if len(t) >= len(pre) && strings.equal_fold(t[:len(pre)], pre) {
				t = strings.trim_space(t[len(pre):])
				changed = true
				break
			}
		}
		if !changed {
			break
		}
	}
	// Collapse internal whitespace so "a  b" and "a b" thread together.
	fields := strings.fields(strings.to_lower(t, context.temp_allocator), context.temp_allocator)
	return strings.join(fields, " ", allocator)
}

// ---------------------------------------------------------------------------
// Local flags, for POP3
//
// POP3 has no server-side flag store, so the read and flagged state of a POP3
// account is kept here, in a sidecar file keyed by Message-ID. IMAP and JMAP
// accounts keep their flags where the protocol does: in the Maildir filename.
// ---------------------------------------------------------------------------

local_flags_path :: proc(st: ^State, ai: int, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/local-flags-%d.tsv", st.data_dir, ai, allocator = allocator)
}

apply_local_flags :: proc(st: ^State) {
	for a, ai in st.accounts {
		if has_server_flags(a.protocol) {
			continue
		}
		path := local_flags_path(st, ai, context.temp_allocator)
		raw, ok := read_file(path, context.temp_allocator)
		if !ok {
			continue
		}
		rest := string(raw)
		for line in strings.split_lines_iterator(&rest) {
			tab := strings.index_byte(line, '\t')
			if tab <= 0 {
				continue
			}
			id := line[:tab]
			fl: Flags
			for c in transmute([]u8)line[tab + 1:] {
				if f, fok := flag_of_char(c); fok {
					fl |= {f}
				}
			}
			for &m in st.messages {
				if m.account == ai && m.id == id {
					m.flags = fl
				}
			}
		}
	}
}

save_local_flags :: proc(st: ^State, ai: int) {
	b := strings.builder_make(context.temp_allocator)
	for m in st.messages {
		if m.account != ai || m.id == "" {
			continue
		}
		chars := make([dynamic]u8, 0, 6, context.temp_allocator)
		for f in Flag {
			if f in m.flags {
				append(&chars, char_of_flag(f))
			}
		}
		slice.sort(chars[:])
		fmt.sbprintf(&b, "%s\t%s\n", m.id, string(chars[:]))
	}
	write_file(local_flags_path(st, ai, context.temp_allocator), transmute([]u8)strings.to_string(b))
}

// set_flags is the only place a flag changes. For IMAP and JMAP it renames the
// Maildir file, moving it out of `new/` the way a real client does the moment
// a message is read; for POP3 it writes the local sidecar instead.
set_flags :: proc(st: ^State, mi: int, fl: Flags) {
	if mi < 0 || mi >= len(st.messages) {
		return
	}
	m := &st.messages[mi]
	if m.flags == fl && !m.in_new {
		return
	}
	was_unread := msg_unread(m^)
	m.flags = fl

	a := st.accounts[m.account]
	if has_server_flags(a.protocol) {
		folder := st.folders[m.folder].path
		newname := maildir_name_with_flags(m.file, fl, context.temp_allocator)
		dest := tfmt("%s/cur/%s", folder, newname)
		if dest != m.path {
			if os.rename(m.path, dest) == nil {
				delete(m.path)
				delete(m.file)
				m.path = strings.clone(dest)
				m.file = strings.clone(newname)
				m.in_new = false
			}
		}
	} else {
		save_local_flags(st, m.account)
	}

	now_unread := msg_unread(m^)
	if was_unread != now_unread {
		f := &st.folders[m.folder]
		f.unread += now_unread ? 1 : -1
		if f.unread < 0 {
			f.unread = 0
		}
	}
	recount_thread(st, m.thread)
}

recount_thread :: proc(st: ^State, ti: int) {
	if ti < 0 || ti >= len(st.threads) {
		return
	}
	t := &st.threads[ti]
	t.unread = 0
	t.flagged = false
	for mi in t.msgs {
		m := st.messages[mi]
		if msg_unread(m) {
			t.unread += 1
		}
		if .Flagged in m.flags {
			t.flagged = true
		}
	}
}

// ---------------------------------------------------------------------------
// Threading
//
// A reduced JWZ: resolve each message's parent from References (last
// resolvable id) or In-Reply-To, union the resulting forest into conversations,
// and fall back to the folded base subject for messages whose headers give
// nothing. Threads are then ordered newest-first and the messages inside each
// one are ordered parents-before-children, oldest-first.
// ---------------------------------------------------------------------------

build_threads :: proc(st: ^State, indices: []int) {
	for &t in st.threads {
		delete(t.msgs)
		delete(t.senders)
	}
	clear(&st.threads)

	// Keys are scoped to the account. Two accounts are two mailboxes: a
	// message that happens to share a Message-ID or a subject with one in
	// another account is not the same conversation, and threading them
	// together would mark both read at once.
	scoped :: proc(account: int, key: string) -> string {
		return fmt.tprintf("%d\x00%s", account, key)
	}

	by_id := make(map[string]int, len(indices), context.temp_allocator)
	for mi in indices {
		m := st.messages[mi]
		if m.id != "" {
			k := scoped(m.account, m.id)
			if _, seen := by_id[k]; !seen {
				by_id[k] = mi
			}
		}
	}

	// parent[mi] within this set, or -1.
	parent := make(map[int]int, len(indices), context.temp_allocator)
	for mi in indices {
		m := st.messages[mi]
		pi := -1
		// The last entry in References that is present here is the closest
		// ancestor we actually have.
		for k := len(m.refs) - 1; k >= 0; k -= 1 {
			if cand, ok := by_id[scoped(m.account, m.refs[k])]; ok && cand != mi {
				pi = cand
				break
			}
		}
		if pi < 0 && m.in_reply_to != "" {
			if cand, ok := by_id[scoped(m.account, m.in_reply_to)]; ok && cand != mi {
				pi = cand
			}
		}
		parent[mi] = pi
	}

	// Union-find over the set, so a conversation is one group however the
	// References happen to point.
	root := make(map[int]int, len(indices), context.temp_allocator)
	for mi in indices {
		root[mi] = mi
	}
	find :: proc(root: ^map[int]int, x: int) -> int {
		r := x
		for root[r] != r {
			r = root[r]
		}
		// Path compression, so a long reply chain stays cheap.
		c := x
		for root[c] != r {
			nxt := root[c]
			root[c] = r
			c = nxt
		}
		return r
	}
	union_ :: proc(root: ^map[int]int, a, b: int) {
		ra, rb := find(root, a), find(root, b)
		if ra != rb {
			root[rb] = ra
		}
	}

	for mi in indices {
		if pi := parent[mi]; pi >= 0 {
			union_(&root, pi, mi)
		}
	}

	// The subject fallback, and it is deliberately timid.
	//
	// Grouping everything that shares a subject is how a mail client ends up
	// with one forty-message "Lunch?" conversation spanning three months of
	// unrelated lunches. The fallback exists for one case — a client that
	// replied without writing In-Reply-To or References — so it only applies
	// to messages that carry no reference at all, and only joins them when one
	// of the pair is visibly a reply to the other.
	by_subject := make(map[string]int, len(indices), context.temp_allocator)
	for mi in indices {
		m := st.messages[mi]
		if m.base_subject == "" || len(m.refs) > 0 || m.in_reply_to != "" {
			continue
		}
		k := scoped(m.account, m.base_subject)
		first, seen := by_subject[k]
		if !seen {
			by_subject[k] = mi
			continue
		}
		if looks_like_reply(m.subject) || looks_like_reply(st.messages[first].subject) {
			union_(&root, first, mi)
		}
	}

	// Collect groups.
	groups := make(map[int][dynamic]int, 16, context.temp_allocator)
	for mi in indices {
		r := find(&root, mi)
		if _, ok := groups[r]; !ok {
			groups[r] = make([dynamic]int, 0, 4, context.temp_allocator)
		}
		g := &groups[r]
		append(g, mi)
	}

	for _, g in groups {
		t := Thread {
			msgs = make([dynamic]int, 0, len(g)),
		}
		ordered := order_thread(st, g[:], &parent)
		for mi in ordered {
			append(&t.msgs, mi)
		}
		ti := len(st.threads)
		for mi, d in ordered {
			_ = d
			st.messages[mi].thread = ti
		}
		// Depths come out of the ordering pass.
		t.newest = st.messages[ordered[0]].date
		t.oldest = st.messages[ordered[0]].date
		for mi in ordered {
			m := st.messages[mi]
			if m.date._nsec > t.newest._nsec {
				t.newest = m.date
			}
			if m.date._nsec < t.oldest._nsec {
				t.oldest = m.date
			}
			if msg_unread(m) {
				t.unread += 1
			}
			if .Flagged in m.flags {
				t.flagged = true
			}
			if len(m.attachments) > 0 {
				t.has_attach = true
			}
		}
		// The thread's subject is its earliest message's, which is the one
		// nobody has prefixed with Re: yet.
		earliest := ordered[0]
		for mi in ordered {
			if st.messages[mi].date._nsec < st.messages[earliest].date._nsec {
				earliest = mi
			}
		}
		t.subject = st.messages[earliest].subject
		t.senders = thread_senders(st, ordered)
		append(&st.threads, t)
	}

	slice.sort_by(st.threads[:], proc(x, y: Thread) -> bool {
		return x.newest._nsec > y.newest._nsec
	})
	// The sort moved them, so the back-references have to be redone.
	for t, ti in st.threads {
		for mi in t.msgs {
			st.messages[mi].thread = ti
		}
	}
}

// order_thread walks the reply forest so a parent is always listed before its
// children, with siblings oldest-first — the order a conversation reads in.
order_thread :: proc(st: ^State, group: []int, parent: ^map[int]int, allocator := context.temp_allocator) -> []int {
	in_group := make(map[int]bool, len(group), context.temp_allocator)
	for mi in group {
		in_group[mi] = true
	}
	kids := make(map[int][dynamic]int, len(group), context.temp_allocator)
	roots := make([dynamic]int, 0, len(group), context.temp_allocator)
	for mi in group {
		pi := parent[mi]
		if pi >= 0 && in_group[pi] && pi != mi {
			if _, ok := kids[pi]; !ok {
				kids[pi] = make([dynamic]int, 0, 2, context.temp_allocator)
			}
			k := &kids[pi]
			append(k, mi)
		} else {
			append(&roots, mi)
		}
	}
	// Siblings oldest-first. Odin's sort_by takes no capture, so the dates are
	// compared through a small keyed copy.
	sort_indices_by_date(st, roots[:])
	for k, &v in kids {
		_ = k
		sort_indices_by_date(st, v[:])
	}

	out := make([dynamic]int, 0, len(group), allocator)
	walk :: proc(st: ^State, kids: ^map[int][dynamic]int, mi, depth: int, out: ^[dynamic]int) {
		st.messages[mi].depth = depth
		append(out, mi)
		if ch, ok := kids[mi]; ok {
			for c in ch {
				// A cycle in References would otherwise loop forever.
				if c == mi || depth > 32 {
					continue
				}
				walk(st, kids, c, depth + 1, out)
			}
		}
	}
	for r in roots {
		walk(st, &kids, r, 0, &out)
	}
	// Anything unreachable (a cycle) is appended so no message is lost.
	if len(out) < len(group) {
		seen := make(map[int]bool, len(out), context.temp_allocator)
		for mi in out {
			seen[mi] = true
		}
		for mi in group {
			if !seen[mi] {
				st.messages[mi].depth = 0
				append(&out, mi)
			}
		}
	}
	return out[:]
}

// sort_indices_by_date sorts message indices oldest-first. The comparator
// cannot close over state, so the dates are lifted into a temporary pair array.
sort_indices_by_date :: proc(st: ^State, xs: []int) {
	Pair :: struct {
		key: i64,
		idx: int,
	}
	pairs := make([]Pair, len(xs), context.temp_allocator)
	for x, i in xs {
		pairs[i] = {st.messages[x].date._nsec, x}
	}
	slice.sort_by(pairs, proc(a, b: Pair) -> bool {
		if a.key != b.key {
			return a.key < b.key
		}
		return a.idx < b.idx
	})
	for pr, i in pairs {
		xs[i] = pr.idx
	}
}

// thread_senders is the participant line a threaded list shows: first names in
// order, deduplicated, truncated with a count.
thread_senders :: proc(st: ^State, ordered: []int, allocator := context.allocator) -> string {
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	for mi in ordered {
		n := addr_label(st.messages[mi].from)
		if n == "" {
			continue
		}
		dup := false
		for e in names {
			if e == n {
				dup = true
				break
			}
		}
		if !dup {
			append(&names, n)
		}
	}
	if len(names) == 0 {
		return strings.clone("(unknown)", allocator)
	}
	if len(names) <= 3 {
		return strings.join(names[:], ", ", allocator)
	}
	return fmt.aprintf(
		"%s, %s … +%d",
		names[0],
		names[1],
		len(names) - 2,
		allocator = allocator,
	)
}
