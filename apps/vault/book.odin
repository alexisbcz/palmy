package main

// The one engine both front ends use.
//
// A Book is either the local vault file (seal.odin, store.odin: one sealed
// file, no network) or the account vault (cloud.odin, sync.odin: identity
// vaults, end to end encrypted, synced). Either way it hands out the same
// thing -- Vault.entries -- and takes edits back through the same three
// calls. The window and `vault <verb>` both go through here, so a change made
// from the command line and one made in the window take the same path to
// disk and to the server (docs/PALM-CLI.md: "a thing is done when the GUI
// uses the same entry points the CLI does").

import "core:fmt"
import "core:os"
import "core:strings"

Book_Mode :: enum u8 {
	Local,
	Account,
}

Book :: struct {
	mode:  Book_Mode,
	path:  string, // the local vault file
	sess:  Session, // the local vault's key
	acct:  ^Acct, // the account, in account mode
	v:     Vault, // what is decrypted, in either mode
	scope: string, // in account mode, the identity handle the entries are limited to ("" for all)
}

// book_mode_for decides which vault a process opens: the account when this
// device is enrolled in one (a Secret Key and a synced cache), the local file
// otherwise or when asked.
book_mode_for :: proc(force_local: bool, acct: ^Acct) -> Book_Mode {
	if force_local || acct == nil {
		return .Local
	}
	return acct_set_up(acct) ? .Account : .Local
}

book_is_open :: proc(b: ^Book) -> bool {
	switch b.mode {
	case .Local:
		return b.sess.unlocked
	case .Account:
		return b.acct != nil && b.acct.unlocked
	}
	return false
}

book_unlock :: proc(b: ^Book, password: string) -> string {
	switch b.mode {
	case .Local:
		v, sess, err := store_load(b.path, password)
		if err != "" {
			return err
		}
		b.v = v
		b.sess = sess
		vault_sort(&b.v)
		return ""
	case .Account:
		if err := acct_unlock(b.acct, password); err != "" {
			return err
		}
		book_rebuild(b)
		return ""
	}
	return ""
}

book_lock :: proc(b: ^Book) {
	vault_free(&b.v)
	session_zero(&b.sess)
	if b.acct != nil {
		acct_lock(b.acct)
	}
}

// book_rebuild re-decrypts the account's entries (after a sync, a share, a
// revocation). In local mode the entries are the file and there is nothing to
// rebuild.
book_rebuild :: proc(b: ^Book) {
	if b.mode != .Account {
		return
	}
	vault_free(&b.v)
	b.v = Vault {
		entries = make([dynamic]Entry),
	}
	acct_entries(b.acct, &b.v)
	if b.scope != "" {
		id := ident_by_handle(b.acct, b.scope)
		for i := 0; i < len(b.v.entries); {
			src := &b.acct.sources[b.v.entries[i].src]
			if id == nil || src.viewer != id.id {
				entry_free(&b.v.entries[i])
				ordered_remove(&b.v.entries, i)
				continue
			}
			i += 1
		}
	}
	vault_sort(&b.v)
}

// book_commit persists the entry at `idx` after it was edited in place.
book_commit :: proc(b: ^Book, idx: int) -> string {
	switch b.mode {
	case .Local:
		return store_save(b.path, &b.v, &b.sess)
	case .Account:
		e := &b.v.entries[idx]
		o := origin_of(b.acct, e.id)
		vid := ""
		if o != nil {
			vid = o.vault_id
		} else if e.src >= 0 && e.src < len(b.acct.sources) {
			vid = b.acct.sources[e.src].vault_id
		}
		return acct_put(b.acct, e, vid)
	}
	return ""
}

// book_add appends a new entry and persists it. In account mode `src` names
// the vault it goes into (an index into acct.sources); -1 picks the first
// writable vault of the identity in scope.
book_add :: proc(b: ^Book, e: Entry, src := -1) -> (idx: int, err: string) {
	ee := e
	if b.mode == .Account {
		s := src
		if s < 0 {
			s = book_default_target(b)
		}
		if s < 0 {
			entry_free(&ee)
			return -1, "there is no vault this identity can write to"
		}
		ee.src = s
		if err = acct_put(b.acct, &ee, b.acct.sources[s].vault_id); err != "" {
			entry_free(&ee)
			return -1, err
		}
		append(&b.v.entries, ee)
		return len(b.v.entries) - 1, ""
	}
	append(&b.v.entries, ee)
	return len(b.v.entries) - 1, store_save(b.path, &b.v, &b.sess)
}

book_remove :: proc(b: ^Book, idx: int) -> string {
	e := &b.v.entries[idx]
	if b.mode == .Account {
		o := origin_of(b.acct, e.id)
		vid := o != nil ? o.vault_id : ""
		if vid == "" && e.src >= 0 && e.src < len(b.acct.sources) {
			vid = b.acct.sources[e.src].vault_id
		}
		if err := acct_put(b.acct, e, vid, deleted = true); err != "" {
			return err
		}
		entry_free(e)
		ordered_remove(&b.v.entries, idx)
		return ""
	}
	entry_free(e)
	ordered_remove(&b.v.entries, idx)
	return store_save(b.path, &b.v, &b.sess)
}

// book_writable says whether an entry can be changed from here.
book_writable :: proc(b: ^Book, e: ^Entry) -> bool {
	if b.mode == .Local {
		return true
	}
	if e.src < 0 || e.src >= len(b.acct.sources) {
		return false
	}
	r := b.acct.sources[e.src].role
	return r == "owner" || r == "write"
}

book_default_target :: proc(b: ^Book) -> int {
	if b.mode != .Account {
		return 0
	}
	want := ""
	if b.scope != "" {
		if id := ident_by_handle(b.acct, b.scope); id != nil {
			want = id.id
		}
	}
	for s, i in b.acct.sources {
		if s.kind == .Own && (want == "" || s.viewer == want) {
			return i
		}
	}
	for s, i in b.acct.sources {
		if s.kind == .Shared_Vault && s.role == "write" && (want == "" || s.viewer == want) {
			return i
		}
	}
	return -1
}

// book_find_target resolves "--vault NAME" (and --identity) to a source.
book_find_target :: proc(b: ^Book, vault_name: string) -> int {
	if b.mode != .Account {
		return 0
	}
	if vault_name == "" {
		return book_default_target(b)
	}
	want := ""
	if b.scope != "" {
		if id := ident_by_handle(b.acct, b.scope); id != nil {
			want = id.id
		}
	}
	for s, i in b.acct.sources {
		if s.kind == .Shared_Items || (want != "" && s.viewer != want) {
			continue
		}
		if strings.equal_fold(s.name, vault_name) || s.vault_id == vault_name {
			return i
		}
	}
	return -1
}

book_sync :: proc(b: ^Book) -> (rep: Sync_Report, err: string) {
	if b.mode != .Account {
		return {}, "the local vault does not sync; it has no network code"
	}
	rep, err = acct_sync(b.acct)
	if err == "" && b.acct.unlocked {
		book_rebuild(b)
	}
	return
}

// book_label names where an entry lives, for the list and the CLI.
book_label :: proc(b: ^Book, e: ^Entry) -> (identity: string, vault: string) {
	if b.mode == .Local {
		return "", short_path(b.path)
	}
	if e.src < 0 || e.src >= len(b.acct.sources) {
		return "", ""
	}
	s := &b.acct.sources[e.src]
	return handle_of(b.acct, s.viewer), s.name
}

// book_describe is one line about the open book, for status output.
book_describe :: proc(b: ^Book) -> string {
	switch b.mode {
	case .Local:
		return fmt.tprintf("local file %s", short_path(b.path))
	case .Account:
		return fmt.tprintf("account %s, %d identities", b.acct.cache.email, len(b.acct.cache.idents))
	}
	return ""
}

book_exists :: proc(b: ^Book) -> bool {
	if b.mode == .Local {
		return os.exists(b.path)
	}
	return acct_set_up(b.acct)
}
