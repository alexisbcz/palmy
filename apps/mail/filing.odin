// Filing: moving a message to another folder, archiving it, deleting it, and
// undoing the last move.
//
// Maildir makes this honest, and that is the whole reason the model is shaped
// the way it is. A message is a file; a folder is a directory; moving a
// message between folders of one account is `rename(2)`, which is atomic
// within a filesystem, and the `:2,FLAGS` suffix travels with the name so the
// read and flagged state arrives with it. There is no index to update and no
// second source of truth to drift out of step.
//
// WHAT EACH PROTOCOL CAN HONESTLY EXPRESS
//
//   IMAP, JMAP  a server-side folder tree and server-side flags. A move is a
//               rename into the target folder's cur/, which is what the next
//               sync will push back as a real IMAP MOVE or a JMAP mailbox
//               change. The message leaves new/ on the way, because a message
//               somebody has filed is a message somebody has looked at.
//
//   POP3        neither folders nor flags. There is nowhere to file to and
//               nothing to set, so filing is local and says so: a delete
//               writes the Trashed flag into this account's local sidecar,
//               the file stays exactly where the engine put it, and the list
//               stops showing it. The sidebar already says POP3 has one inbox
//               and keeps its state on this machine; this keeps that true
//               instead of inventing a Trash folder the protocol cannot have.
//
// Nothing in this file opens a socket. It renames files inside the app's own
// data directory and nowhere else.
package main

import "core:os"
import "core:strings"

// Move_Undo remembers one move, which is all the undo a rename needs: putting
// it back is the same rename in the other direction.
Move_Undo :: struct {
	valid:       bool,
	from_folder: int,
	to_folder:   int,
	from_path:   string,
	to_path:     string,
	subject:     string,
}

// ---------------------------------------------------------------------------
// Where a message may go
// ---------------------------------------------------------------------------

// can_file answers whether this account's messages can be filed into folders
// at all, and if not, says why in the words the sidebar already uses.
can_file :: proc(st: ^State, ai: int) -> (ok: bool, why: string) {
	if ai < 0 || ai >= len(st.accounts) {
		return false, "no account"
	}
	if !has_server_folders(st.accounts[ai].protocol) {
		return false, "POP3 has no folders. Delete files it away on this machine instead."
	}
	return true, ""
}

// move_targets lists the folders a message could be filed into: every folder
// of its own account except the one it is already in.
//
// Across accounts is deliberately not offered. Two accounts are two mailboxes
// on two servers; moving between them is a copy and a delete, the flags and
// the Message-ID would have to be rewritten, and neither protocol has a word
// for it. A client that pretended otherwise would be losing mail quietly.
move_targets :: proc(st: ^State, mi: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, 8, allocator)
	if mi < 0 || mi >= len(st.messages) {
		return out[:]
	}
	m := st.messages[mi]
	if ok, _ := can_file(st, m.account); !ok {
		return out[:]
	}
	for f, fi in st.folders {
		if f.account != m.account || fi == m.folder {
			continue
		}
		append(&out, fi)
	}
	return out[:]
}

// folder_of_role finds an account's folder for a role, or -1.
folder_of_role :: proc(st: ^State, ai: int, role: Folder_Role) -> int {
	for f, fi in st.folders {
		if f.account == ai && f.role == role && f.depth == 0 {
			return fi
		}
	}
	return -1
}

// ensure_role_folder finds an account's folder for a role and creates it on
// disk if it is not there yet — a Maildir++ subfolder, which is what the
// engine writes and what every other Maildir tool reads.
//
// Trash and Archive have to be creatable, because a mailbox the engine has
// only ever synced an inbox from does not have them, and "you cannot delete
// anything here" would be a strange thing for a mail client to say.
ensure_role_folder :: proc(st: ^State, ai: int, role: Folder_Role, name: string) -> int {
	if fi := folder_of_role(st, ai, role); fi >= 0 {
		return fi
	}
	if ok, _ := can_file(st, ai); !ok {
		return -1
	}
	root := st.accounts[ai].root
	dir := tfmt("%s/.%s", root, name)
	if !make_folder_dir(dir) {
		return -1
	}
	// Reloading is the honest way to pick a new folder up: it is the same code
	// path that notices a folder the engine created, and it keeps the sidebar,
	// the roles and the sort order consistent with everything else.
	reload_all(st)
	return folder_of_role(st, ai, role)
}

// make_folder_dir creates a Maildir++ subfolder: cur/, new/, tmp/, and the
// `maildirfolder` marker other Maildir tools look for before they will treat a
// directory as a mailbox.
make_folder_dir :: proc(dir: string) -> bool {
	for sub in ([?]string{"cur", "new", "tmp"}) {
		os.make_directory_all(tfmt("%s/%s", dir, sub))
	}
	if !is_maildir(dir) {
		return false
	}
	marker := tfmt("%s/maildirfolder", dir)
	if !os.exists(marker) {
		write_file(marker, []u8{})
	}
	return true
}

// ---------------------------------------------------------------------------
// The move itself
// ---------------------------------------------------------------------------

// move_message renames one message into another folder of the same account.
//
// The destination is always `cur/` with the flag suffix attached, never `new/`:
// `new/` means "no client has ever seen this", and a message somebody has
// just filed has been seen by definition.
move_message :: proc(st: ^State, mi: int, target_fi: int) -> (err: string) {
	if mi < 0 || mi >= len(st.messages) {
		return "no message"
	}
	if target_fi < 0 || target_fi >= len(st.folders) {
		return "no such folder"
	}
	m := &st.messages[mi]
	if m.folder == target_fi {
		return "it is already there"
	}
	if st.folders[target_fi].account != m.account {
		return "a message cannot be moved between accounts: that is a copy and a delete, and neither protocol has a word for it"
	}
	if ok, why := can_file(st, m.account); !ok {
		return why
	}

	// The suffix travels, so read and flagged state arrives with the message.
	newname := maildir_name_with_flags(m.file, m.flags, context.temp_allocator)
	dest := tfmt("%s/cur/%s", st.folders[target_fi].path, newname)
	if dest == m.path {
		return ""
	}
	if os.rename(m.path, dest) != nil {
		return tfmt("could not move the file into %s", st.folders[target_fi].name)
	}

	undo_set(st, m.folder, target_fi, dest, m.path, m.subject)

	delete(m.path)
	delete(m.file)
	m.path = strings.clone(dest)
	m.file = strings.clone(newname)
	m.in_new = false
	m.folder = target_fi

	recount_folders(st)
	rebuild_list(st)
	return ""
}

// undo_set records a move. Only the last one is kept: a stack of undos over a
// tree that other tools can also rename under us would be a stack of stale
// paths, and offering to undo something that is no longer there is worse than
// not offering it at all.
undo_set :: proc(st: ^State, from_folder, to_folder: int, from_path, to_path, subject: string) {
	undo_clear(st)
	st.undo = Move_Undo {
		valid       = true,
		from_folder = from_folder,
		to_folder   = to_folder,
		from_path   = strings.clone(from_path),
		to_path     = strings.clone(to_path),
		subject     = strings.clone(subject),
	}
}

undo_clear :: proc(st: ^State) {
	if st.undo.valid {
		delete(st.undo.from_path)
		delete(st.undo.to_path)
		delete(st.undo.subject)
	}
	st.undo = {}
}

// undo_move puts the last moved message back. The rename is cheap and exact;
// what it checks first is that the file is still where the move left it, in
// case the engine or another Maildir tool has touched it since.
undo_move :: proc(st: ^State) -> (what: string, err: string) {
	u := st.undo
	if !u.valid {
		return "", "there is nothing to undo"
	}
	if !os.exists(u.from_path) {
		undo_clear(st)
		return "", "the message has moved again since; not touching it"
	}
	if os.exists(u.to_path) {
		undo_clear(st)
		return "", "something is already back at the old name; not touching it"
	}
	if os.rename(u.from_path, u.to_path) != nil {
		return "", "the file could not be moved back"
	}
	subject := strings.clone(u.subject, context.temp_allocator)
	for &m in st.messages {
		if m.path != u.from_path {
			continue
		}
		delete(m.path)
		delete(m.file)
		m.path = strings.clone(u.to_path)
		m.file = strings.clone(basename_of(u.to_path))
		m.folder = u.from_folder
		m.in_new = strings.contains(u.to_path, "/new/")
		break
	}
	undo_clear(st)
	recount_folders(st)
	rebuild_list(st)
	return subject, ""
}

basename_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

dirname_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i > 0 {
		return path[:i]
	}
	return "/"
}

// ---------------------------------------------------------------------------
// The three verbs a reader actually uses
// ---------------------------------------------------------------------------

// file_selection moves everything the cursor covers — the message on a message
// row, the whole conversation on a thread row — into one folder.
//
// Filing a thread rather than a message is what a mail client means by
// "archive this": a conversation half in the inbox and half in the archive is
// not a thing anybody wants.
file_selection :: proc(st: ^State, target_fi: int) -> (moved: int, err: string) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		return 0, "nothing is selected"
	}
	first_err := ""
	for mi in msgs {
		if e := move_message(st, mi, target_fi); e != "" {
			if first_err == "" {
				first_err = e
			}
			continue
		}
		moved += 1
	}
	if moved == 0 {
		return 0, first_err == "" ? "nothing moved" : first_err
	}
	marks_clear(st)
	return moved, ""
}

// selection_paths captures what the cursor covers by path rather than by
// index.
//
// Creating a folder reloads the whole tree, and a reload renumbers every
// message and puts the cursor back at the top of the list. An index taken
// before that reload names a different message after it — which is how an
// "archive this" would quietly file the wrong mail. A path survives, because
// it is what the message *is*.
selection_paths :: proc(st: ^State, allocator := context.temp_allocator) -> []string {
	msgs := selection_messages(st, context.temp_allocator)
	out := make([dynamic]string, 0, len(msgs), allocator)
	for mi in msgs {
		append(&out, strings.clone(st.messages[mi].path, allocator))
	}
	return out[:]
}

// message_at_path is the single-message form, for the callers that keep hold
// of exactly one message across a reload.
message_at_path :: proc(st: ^State, want: string) -> int {
	for m, i in st.messages {
		if m.path == want {
			return i
		}
	}
	return -1
}

// messages_at_paths resolves those paths back to indices after a reload.
messages_at_paths :: proc(st: ^State, paths: []string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(paths), allocator)
	for want in paths {
		for m, i in st.messages {
			if m.path == want {
				append(&out, i)
				break
			}
		}
	}
	return out[:]
}

// selection_messages is what a verb acts on: everything marked when anything
// is marked, and otherwise the set the current row stands for. Every verb in
// this file goes through it, which is how one multi-select reaches archive,
// move, delete and the permanent delete without any of them knowing about it.
selection_messages :: proc(st: ^State, allocator := context.temp_allocator) -> []int {
	if len(st.marked) > 0 {
		return marked_messages(st, allocator)
	}
	return row_messages(st, st.row_sel, allocator)
}

// archive_selection files the selection into Archive, creating it if the
// account has never had one.
archive_selection :: proc(st: ^State) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		note(st, "Nothing to archive")
		return
	}
	ai := st.messages[msgs[0]].account
	if ok, why := can_file(st, ai); !ok {
		note(st, why)
		return
	}
	// Taken before the folder is created, because creating one reloads the
	// tree and renumbers everything in it.
	paths := selection_paths(st, context.temp_allocator)
	target := ensure_role_folder(st, ai, .Archive, "Archive")
	if target < 0 {
		note(st, "Could not create an Archive folder")
		return
	}
	n, err := file_selection_of(st, messages_at_paths(st, paths), target)
	if err != "" {
		note(st, err)
		return
	}
	note(st, tfmt("Archived %d message%s  ·  %s", n, plural(n), undo_phrase(n)))
}

// delete_selection is "move to Trash" for a protocol that has one, and the
// local Trashed flag for POP3, which does not.
delete_selection :: proc(st: ^State) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		note(st, "Nothing to delete")
		return
	}
	ai := st.messages[msgs[0]].account

	if ok, _ := can_file(st, ai); !ok {
		// POP3. There is no Trash on the server and no \Deleted to set, so the
		// delete is local and reversible: the flag goes in the sidecar and the
		// file is not touched.
		n := 0
		for mi in msgs {
			set_flags(st, mi, st.messages[mi].flags | {.Deleted})
			n += 1
		}
		recount_folders(st)
		rebuild_list(st)
		note(st, tfmt("Deleted %d message%s on this machine — POP3 has no server-side Trash", n, plural(n)))
		return
	}

	if st.folders[st.messages[msgs[0]].folder].role == .Trash {
		note(st, "Already in Trash. Shift+D deletes it from disk.")
		return
	}
	paths := selection_paths(st, context.temp_allocator)
	target := ensure_role_folder(st, ai, .Trash, "Trash")
	if target < 0 {
		note(st, "Could not create a Trash folder")
		return
	}
	n, err := file_selection_of(st, messages_at_paths(st, paths), target)
	if err != "" {
		note(st, err)
		return
	}
	note(st, tfmt("Moved %d message%s to Trash  ·  %s", n, plural(n), undo_phrase(n)))
}

// undo_phrase is honest about what Z will do. Only the last move is
// remembered — a stack of undos over a tree other tools can rename under us
// would be a stack of stale paths — so a multiple move must not claim more.
undo_phrase :: proc(n: int) -> string {
	return n > 1 ? "Z puts the last one back" : "Z to undo"
}

// file_selection_of is `file_selection` over an explicit set, which is what
// the two verbs above need after a reload has renumbered things.
file_selection_of :: proc(st: ^State, msgs: []int, target_fi: int) -> (moved: int, err: string) {
	if len(msgs) == 0 {
		return 0, "nothing is selected"
	}
	first_err := ""
	for mi in msgs {
		if e := move_message(st, mi, target_fi); e != "" {
			if first_err == "" {
				first_err = e
			}
			continue
		}
		moved += 1
	}
	if moved == 0 {
		return 0, first_err == "" ? "nothing moved" : first_err
	}
	// The marks named files that have just been renamed. A selection that
	// survived the verb applied to it would be a selection of stale paths.
	marks_clear(st)
	return moved, ""
}

// ---------------------------------------------------------------------------
// Permanent deletion
//
// The one irreversible operation in this client. It names the file it is about
// to unlink, it says there is no undo, and its dialog starts on Cancel.
// ---------------------------------------------------------------------------

// purge_message unlinks one message's file. It refuses anything outside the
// account root it belongs to, which is the same rule the rest of the app
// follows: this client only ever touches mail it can see is its own.
purge_message :: proc(st: ^State, mi: int) -> (err: string) {
	if mi < 0 || mi >= len(st.messages) {
		return "no message"
	}
	m := st.messages[mi]
	root := st.accounts[m.account].root
	if !strings.has_prefix(m.path, tfmt("%s/", root)) {
		return tfmt("refusing to delete %s: it is not inside %s", m.path, root)
	}
	if os.remove(m.path) != nil {
		return "the file could not be removed"
	}
	// The undo would point at a file that no longer exists.
	if st.undo.valid && (st.undo.from_path == m.path || st.undo.to_path == m.path) {
		undo_clear(st)
	}
	free_message(m)
	remove_message_at(&st.messages, mi)

	// Every index above `mi` has just shifted down by one, so every structure
	// that holds one is now lying. They are all derived, so the honest move is
	// to drop them rather than patch them — and to drop them *before* the
	// rebuild, because `rebuild_rows` asks the current row which message it
	// stands for, and a row left over from before the removal can name a
	// message index that no longer exists.
	clear(&st.rows)
	clear(&st.row_y)
	st.row_sel = 0
	for &t in st.threads {
		clear(&t.msgs)
	}
	st.reader_msg = -1
	recount_folders(st)
	rebuild_list(st)
	return ""
}

// remove_message_at drops one message and keeps the order of the rest,
// because every folder's `first` index and the row cursor both assume the
// messages are still in scan order. (`core:runtime`'s own `ordered_remove` is
// already in scope from buffer.odin; this one is named for what it does.)
remove_message_at :: proc(xs: ^[dynamic]Message, at: int) {
	if at < 0 || at >= len(xs) {
		return
	}
	for i := at; i < len(xs) - 1; i += 1 {
		xs[i] = xs[i + 1]
	}
	resize(xs, len(xs) - 1)
}

// purge_selection removes every message under the cursor from disk.
purge_selection :: proc(st: ^State) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		note(st, "Nothing to delete")
		return
	}
	// Highest index first, so removing one does not renumber the next.
	sorted := make([dynamic]int, 0, len(msgs), context.temp_allocator)
	for mi in msgs {
		append(&sorted, mi)
	}
	for i in 0 ..< len(sorted) {
		for k in 0 ..< len(sorted) - 1 - i {
			if sorted[k] < sorted[k + 1] {
				sorted[k], sorted[k + 1] = sorted[k + 1], sorted[k]
			}
		}
	}
	n, failed := 0, ""
	for mi in sorted {
		if e := purge_message(st, mi); e != "" {
			if failed == "" {
				failed = e
			}
			continue
		}
		n += 1
	}
	marks_clear(st)
	if n == 0 {
		note(st, failed == "" ? "Nothing was deleted" : failed)
		return
	}
	note(st, tfmt("Deleted %d message%s from disk. There is no undo for that.", n, plural(n)))
}

// purge_label is what the confirmation dialog shows: the file it will unlink.
purge_label :: proc(st: ^State) -> (count: int, path: string) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		return 0, ""
	}
	return len(msgs), st.messages[msgs[0]].path
}
