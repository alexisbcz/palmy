// The window's two connections to the cloud.
//
// **Background sync** is `notes sync`, run as a child process every half
// minute and after anything that changes where a note is (a move, the trash,
// a pin), with `--skip <open note>`: the same code the shell and an agent
// run, so the window cannot sync differently from the command line. Its JSON
// says whether the account answered and what moved, which becomes the status
// line ("Synced 14:02", "Offline · 2 waiting") and a reload of the list.
//
// **The open note** of a synced identity has a live session of its own with
// the sync server (cloud/collab/client): every edit becomes CRDT operations
// as it is typed, other people's edits and carets arrive within a frame, and
// when the network goes the edits queue in the session's outbox and the note
// keeps working. Undo in a live note is the CRDT's per-person undo, so it
// takes back your last change and never somebody else's.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import ck "../cloudkit"
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"

// ---------------------------------------------------------------------------
// Background sync
// ---------------------------------------------------------------------------

Sync_Proc :: struct {
	process:  os.Process,
	running:  bool,
	next_at:  f64, // when the next pass starts, in p.elapsed seconds
	soon:     bool,
	out_path: string,
	ran:      bool, // at least one pass finished
	account:  string, // "signed in", "not signed in", "unreachable", "offline"
	online:   bool,
	queued:   int,
	last_ok:  time.Time,
	any_bound: bool,
}

sync_bound :: proc(nt: ^Notes) -> bool {
	for id in nt.ids {
		if ident_bound(id) {return true}
	}
	return false
}

// sync_start runs one `notes sync` in the background, unless one is running.
sync_start :: proc(nt: ^Notes) {
	if nt.sync.running || os.get_env("PALM_NOTES_NO_SYNC", context.temp_allocator) != "" {
		return
	}
	// With no folder bound to an account yet, a pass still runs when someone
	// is signed in: it is what enrols the identities on first use.
	if !sync_bound(nt) && !signed_in_here() {
		nt.sync.account = "local"
		return
	}
	if nt.sync.out_path == "" {
		nt.sync.out_path = strings.clone(fmt.tprintf("/tmp/palm-notes-sync-%d.json", os.get_pid()))
	}
	f, err := os.open(nt.sync.out_path, {.Write, .Create, .Trunc}, os.perm_number(0o600))
	if err != nil {
		return
	}
	defer os.close(f)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, self_exe(), "sync", "--json")
	if nt.open_id != "" && nt.live.s != nil {
		append(&argv, "--skip", nt.open_id)
	}
	pr, perr := os.process_start({command = argv[:], stdout = f})
	if perr != nil {
		return
	}
	nt.sync.process = pr
	nt.sync.running = true
	nt.sync.soon = false
}

signed_in_here :: proc() -> bool {
	c, e := ck.open(app = "notes")
	if !ck.ok(e) {
		return false
	}
	defer ck.close(c)
	return ck.signed_in(c)
}

sync_soon :: proc(nt: ^Notes) {
	nt.sync.soon = true
}

sync_tick :: proc(ui: ^p.Ctx, nt: ^Notes) {
	now := f64(p.elapsed(ui))
	if nt.sync.running {
		p.wake_after(ui, 250 * time.Millisecond)
		st, err := os.process_wait(nt.sync.process, 0)
		if err != nil && err != os.General_Error.Timeout {
			nt.sync.running = false
			return
		}
		if !st.exited {
			return
		}
		nt.sync.running = false
		nt.sync.ran = true
		nt.sync.next_at = now + SYNC_EVERY
		sync_read_result(nt)
		return
	}
	if nt.sync.soon && now + 1 >= nt.sync.next_at - SYNC_EVERY + 1.5 {
		sync_start(nt)
		return
	}
	if now >= nt.sync.next_at && nt.sync.next_at > 0 {
		sync_start(nt)
		return
	}
	if nt.sync.next_at == 0 {
		nt.sync.next_at = now + SYNC_EVERY
	}
	p.wake_after(ui, time.Duration((nt.sync.next_at - now) * f64(time.Second)) + 50 * time.Millisecond)
}

sync_read_result :: proc(nt: ^Notes) {
	data, err := os.read_entire_file_from_path(nt.sync.out_path, context.temp_allocator)
	if err != nil {
		return
	}
	v, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != .None {
		return
	}
	acc := ck.get_str(v, "account")
	delete(nt.sync.account)
	nt.sync.account = strings.clone(acc)
	online := false
	queued := 0
	changed := false
	first_event := ""
	if arr, ok := ck.get(v, "identities").(json.Array); ok {
		for x in arr {
			if ck.get_bool(x, "online") {online = true}
			queued += int(ck.get_int(x, "queued"))
			if ck.get_int(x, "pulled") + ck.get_int(x, "arrived") + ck.get_int(x, "removed") > 0 {
				changed = true
			}
			if evs, eok := ck.get(x, "events").(json.Array); eok && len(evs) > 0 && first_event == "" {
				if s, sok := evs[0].(json.String); sok {
					first_event = s
				}
			}
		}
	}
	if ck.get_int(v, "enrolled") > 0 {
		changed = true
	}
	nt.sync.online = online
	nt.sync.queued = queued
	if online {
		nt.sync.last_ok = time.now()
	}
	if changed {
		reload(nt)
		// The open note may have been renamed or moved by the pass (it never
		// edits the open note's text: that is the live session's).
		if _, ok := open_note(nt); !ok && nt.open_id != "" {
			for n in nt.all {
				if n.meta.id == nt.open_id {
					delete(nt.open_path)
					nt.open_path = strings.clone(n.path)
				}
			}
		}
	}
	if first_event != "" {
		note(nt, first_event)
	}
}

// sync_line is the status line's sentence about sync, always true.
sync_line :: proc(nt: ^Notes) -> (text: string, tone: string) {
	if nt.live.s != nil {
		switch nt.live.s.status {
		case .Live:
			if len(nt.live.s.peers) > 0 {
				return tfmt("Live · %d editing", len(nt.live.s.peers) + 1), "ok"
			}
		case .Offline:
			n := client.pending_count(nt.live.s)
			if n > 0 {
				return tfmt("Offline · %d edit%s waiting", n, n == 1 ? "" : "s"), "warn"
			}
			return "Offline · editing locally", "warn"
		case .Refused:
			return "Refused by the sync server", "bad"
		case .Connecting, .Syncing:
		}
	}
	switch {
	case nt.sync.account == "local" || (!sync_bound(nt) && nt.sync.account == ""):
		return "On this device only", "muted"
	case nt.sync.running && !nt.sync.ran:
		return "Syncing…", "muted"
	case nt.sync.account == "not signed in":
		return "Not signed in · on this device only", "muted"
	case !nt.sync.online && nt.sync.ran:
		if nt.sync.queued > 0 {
			return tfmt("Offline · %d waiting", nt.sync.queued), "warn"
		}
		return "Offline · everything here works", "warn"
	case nt.sync.ran:
		lt := time.Time{_nsec = nt.sync.last_ok._nsec + nt.tz * 1_000_000_000}
		h, m, _ := time.clock(lt)
		return tfmt("Synced %02d:%02d", h, m), "ok"
	}
	return "Syncing…", "muted"
}

// ---------------------------------------------------------------------------
// The open note's live session
// ---------------------------------------------------------------------------

Live :: struct {
	s:          ^client.Session,
	acct:       Acct,
	acct_tried: f64, // when the account was last opened, to retry sparingly
	sent_caret: int,
	app:        ^p.App, // to wake the window when something arrives
	off:        bool, // the person took this window offline (Ctrl+Alt+O)
}

live_account :: proc(nt: ^Notes) -> bool {
	if nt.live.acct.ok {
		_ = ck.ensure_fresh(nt.live.acct.c)
		return true
	}
	now := f64(time.duration_seconds(time.since(time.Time{})))
	if now - nt.live.acct_tried < 30 {
		return false
	}
	nt.live.acct_tried = now
	acct_close(&nt.live.acct)
	nt.live.acct = acct_open()
	return nt.live.acct.ok
}

live_open :: proc(nt: ^Notes) {
	if os.get_env("PALM_NOTES_NO_SYNC", context.temp_allocator) != "" {
		return
	}
	if nt.open_ident < 0 || nt.open_ident >= len(nt.ids) || nt.open_id == "" {
		return
	}
	id := nt.ids[nt.open_ident]
	if !ident_bound(id) {
		return
	}
	idx := index_load(id.root, context.temp_allocator)
	if e, ok := idx[nt.open_id]; !ok || !e.remote {
		return // not in the cloud yet: the next background pass creates it
	}
	if !live_account(nt) {
		return
	}
	host, port := client.server_address()
	cfg := client.Config {
		host    = host,
		port    = port,
		doc_id  = nt.open_id,
		as_id   = id.id,
		token   = nt.live.acct.c.session.access_token,
		app     = "notes",
		dir     = sync_dir(id.root),
		offline = nt.live.off,
	}
	if nt.live.app != nil {
		cfg.wake = proc(ctx: rawptr) {p.wake((^p.App)(ctx))}
		cfg.wake_ctx = nt.live.app
	}
	nt.live.s = client.session_open(cfg)
	// The file is the truth for edits made while no session was open (another
	// editor, the command line): fold them in before anything else.
	if !read_only(nt) {
		text := buffer_text(nt)
		if doc_body(nt.live.s.doc) != text {
			crdt.begin(nt.live.s.doc)
			doc_set_body(nt.live.s.doc, text)
			crdt.commit(nt.live.s.doc)
			crdt.close_group(nt.live.s.doc)
			client.flush(nt.live.s)
		}
	}
	nt.live.sent_caret = -1
}

live_close :: proc(nt: ^Notes) {
	if nt.live.s == nil {
		return
	}
	// The file now matches the CRDT, so the next background pass has nothing
	// to fold in: record that, or it would diff an unchanged note.
	if nt.open_ident >= 0 && nt.open_ident < len(nt.ids) && nt.open_path != "" {
		id := nt.ids[nt.open_ident]
		if data, err := os.read_entire_file_from_path(nt.open_path, context.temp_allocator); err == nil {
			idx := index_load(id.root, context.temp_allocator)
			if e, ok := idx[nt.open_id]; ok {
				e.hash = fnv(string(data))
				e.rel = strings.trim_prefix(strings.trim_prefix(nt.open_path, id.root), "/")
				idx[nt.open_id] = e
				index_save(id.root, idx)
			}
		}
	}
	client.session_close(nt.live.s)
	nt.live.s = nil
}

// live_edit turns the buffer's change into CRDT operations and sends them.
// Typing coalesces into one undo step per word, as the buffer's own undo did.
live_edit :: proc(nt: ^Notes) {
	s := nt.live.s
	if s == nil || read_only(nt) {
		return
	}
	crdt.begin(s.doc, 1)
	doc_set_body(s.doc, buffer_text(nt))
	crdt.commit(s.doc)
	client.flush(s)
}

live_word_break :: proc(nt: ^Notes) {
	if nt.live.s != nil {
		crdt.close_group(nt.live.s.doc)
	}
}

// live_tick applies whatever arrived and publishes this window's caret.
live_tick :: proc(ui: ^p.Ctx, nt: ^Notes) {
	s := nt.live.s
	if s == nil {
		return
	}
	ev := client.poll(s)
	if ev.changed {
		live_adopt(ui, nt)
	}
	if ev.peers || ev.status || ev.changed {
		p.redraw(ui)
		// palmy drops a frame when no buffer is free; ask for one more so a
		// presence-only change is never stuck behind it.
		p.wake_after(ui, 120 * time.Millisecond)
	}
	caret := doc_offset(nt, nt.cur)
	if caret != nt.live.sent_caret && s.status == .Live {
		nt.live.sent_caret = caret
		anchor := nt.has_sel ? doc_offset(nt, nt.anchor) : caret
		client.set_awareness(s, tfmt(`{{"caret":%d,"anchor":%d}}`, caret, anchor))
	}
}

// live_adopt rebuilds the buffer from the CRDT after a remote change,
// carrying the caret and selection across the edit.
live_adopt :: proc(ui: ^p.Ctx, nt: ^Notes) {
	s := nt.live.s
	remote := doc_body(s.doc)
	local := buffer_text(nt)
	if remote == local {
		return
	}
	hs := diff_text(local, remote)
	shift :: proc(off: int, hs: []Hunk) -> int {
		d := 0
		for h in hs {
			if h.at + h.remove <= off {
				d += len(h.insert) - h.remove
			} else if h.at < off {
				// The caret was inside replaced text: it lands after it.
				d += h.at + len(h.insert) - off
			}
		}
		return off + d
	}
	caret := shift(doc_offset(nt, nt.cur), hs)
	anchor := shift(doc_offset(nt, nt.anchor), hs)
	path := strings.clone(nt.buf.path, context.temp_allocator)
	buf_load_text(&nt.buf, path, remote)
	nt.cur = doc_pos(nt, caret)
	nt.anchor = doc_pos(nt, anchor)
	nt.rev += 1
	nt.pending = true
	nt.dirty_since = f64(p.elapsed(ui))
	prose_invalidate(ui, nt)
}

// live_undo is per-person undo in a shared note.
live_undo :: proc(ui: ^p.Ctx, nt: ^Notes, redo: bool) -> bool {
	s := nt.live.s
	if s == nil {
		return false
	}
	if redo {
		crdt.redo(s.doc)
	} else {
		crdt.undo(s.doc)
	}
	client.flush(s)
	live_adopt(ui, nt)
	return true
}

live_toggle_offline :: proc(nt: ^Notes) {
	nt.live.off = !nt.live.off
	if nt.live.s == nil {
		return
	}
	if nt.live.off {
		client.go_offline(nt.live.s)
		note(nt, "Offline: edits queue here and merge when you reconnect")
	} else {
		client.reconnect(nt.live.s)
		note(nt, "Reconnecting")
	}
}

Peer_Caret :: struct {
	name, color: string,
	caret:       int,
	anchor:      int,
}

live_peers :: proc(nt: ^Notes, allocator := context.temp_allocator) -> []Peer_Caret {
	out := make([dynamic]Peer_Caret, allocator)
	s := nt.live.s
	if s == nil {
		return out[:]
	}
	for pe in s.peers {
		c := int(ck.get_int(pe.state, "caret"))
		a := int(ck.get_int(pe.state, "anchor"))
		name := pe.identity.display_name != "" ? pe.identity.display_name : pe.identity.handle
		append(&out, Peer_Caret{name, pe.identity.color, c, a})
	}
	return out[:]
}
