// The collaborative window: joining a shared document, the per-frame sync,
// and everything on screen that is about other people — the identity this
// window acts as, who else is here and where their carets are, comments,
// suggestions, version history and sharing.
//
//	docs --collab <doc-id> [--as <handle>] [--link <token>] [--offline]
//	docs --collab new [--title T] [file]   create a shared document (seeded
//	                                        from the file, or the welcome text)
//
// The account comes from cloudkit's token store (the Accounts app signs in);
// PALM_IDENTITY=<handle> gives a scoped session, which is then the only
// identity this window can act as. The sync server is PALM_COLLAB_URL.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."
import ck "../cloudkit"
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"

COLLAB_PANEL_W :: f32(300)

Peer_View :: struct {
	name:   string,
	handle: string,
	color:  string,
	role:   string,
	caret:  Pos,
	anchor: Pos,
	has:    bool,
	suggesting: bool,
}

Author_Chip :: struct {
	name:  string,
	color: string,
}

History_Row :: struct {
	from, to: u64,
	n:        int,
	name:     string, // the version's name, or the authors joined
	when_:    string,
	named:    bool,
	authors:  [dynamic]Author_Chip,
}

Person_Row :: struct {
	handle: string,
	name:   string,
	color:  string,
	role:   string,
}

Collab_Extra :: struct {
	acct:       client.Account,
	have_acct:  bool,
	peers:      [dynamic]Peer_View,
	history:    [dynamic]History_Row,
	people:     [dynamic]Person_Row,
	sel:        int, // the highlighted row in the open panel
	preview:    bool, // showing an old version, read-only
	preview_seq: u64,
	live_doc:   ^crdt.Doc, // the live replica while previewing
	aware_last: string,
	token_at:   time.Tick,
	link_token: string,
	doc_id:     string,
}

collab_x: Collab_Extra

Collab_Args :: struct {
	doc:     string,
	as:      string,
	link:    string,
	title:   string,
	script:  string,
	offline: bool,
}

parse_collab_args :: proc(args: []string) -> (ca: Collab_Args, rest: [dynamic]string) {
	rest = make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		next :: proc(args: []string, i: ^int) -> string {
			if i^ + 1 < len(args) {
				i^ += 1
				return args[i^]
			}
			return ""
		}
		switch a {
		case "--collab":
			ca.doc = next(args, &i)
		case "--as":
			ca.as = next(args, &i)
		case "--link":
			ca.link = next(args, &i)
		case "--title":
			ca.title = next(args, &i)
		case "--offline":
			ca.offline = true
		case "--script":
			ca.script = next(args, &i)
		case:
			append(&rest, a)
		}
	}
	return
}

// collab_start joins (or creates) a shared document for this window.
collab_start :: proc(st: ^State, app: ^p.App, ca: Collab_Args) -> string {
	acct, err := client.account_open("", ca.as)
	if err != "" {
		return err
	}
	collab_x.acct = acct
	collab_x.have_acct = true
	doc := ca.doc
	creating := doc == "new"
	if creating {
		title := ca.title != "" ? ca.title : doc_title(st)
		id, cerr := client.doc_create(&collab_x.acct, "doc", title)
		if cerr != "" {
			return cerr
		}
		doc = id
		fmt.printfln("shared document %s (%s), owned by %s", id, title, acct.me.handle)
	}
	collab_x.doc_id = strings.clone(doc)
	host, port := client.server_address()
	sess := client.session_open(
		client.Config {
			host = host,
			port = port,
			doc_id = doc,
			as_id = acct.me.id,
			token = client.account_token(&collab_x.acct),
			link = ca.link,
			app = "docs",
			offline = ca.offline,
			wake = proc(ctx: rawptr) {p.wake((^p.App)(ctx))},
			wake_ctx = app,
		},
	)
	collab_init(&st.collab, sess.doc)
	st.collab.sess = sess
	st.collab.handle = strings.clone(acct.me.handle)
	st.collab.name = strings.clone(acct.me.display_name)
	st.collab.color = strings.clone(acct.me.color)
	collab_x.token_at = time.tick_now()
	if creating {
		// The new document starts as whatever this window has open.
		collab_note_edit(st, .Structural)
		collab_sync(st)
	} else {
		collab_materialise(st, {}, false)
	}
	st.modified = false
	return ""
}

// collab_tick runs once a frame: remote updates in, local edits out,
// presence both ways.
collab_tick :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	if !cb.on || cb.sess == nil {
		return
	}
	s := cb.sess
	if collab_x.preview {
		return
	}
	// local edits first, so remote ones rebase onto a model the CRDT agrees with
	if cb.pending {
		if !collab_may_edit(st) {
			cb.pending = false
			crdt.commit(cb.doc)
			collab_materialise(st, {}, true)
			note(st, s.role == "" ? "Not connected yet: edits wait until the document has synced" : "View only: you can comment, not edit")
		} else {
			collab_sync(st)
		}
	}
	collab_save_carets(st)
	ev := client.poll(s)
	if ev.replaced {
		cb.doc = s.doc
	}
	if ev.changed {
		collab_materialise(st, {}, true)
		if ui != nil {p.redraw(ui)}
	} else {
		cb.saved = false
	}
	if ev.status {
		if s.role == "suggest" {
			cb.suggest = true
		}
		if ui != nil {p.redraw(ui)}
	}
	if ev.peers || ev.changed || ev.status {
		collab_refresh_peers(st)
		if ui != nil {p.redraw(ui)}
	}
	collab_publish(st)
	// keep the server's copy of the token fresh
	if time.duration_seconds(time.tick_since(collab_x.token_at)) > 600 && collab_x.have_acct {
		collab_x.token_at = time.tick_now()
		client.set_token(s, client.account_token(&collab_x.acct))
	}
}

collab_may_edit :: proc(st: ^State) -> bool {
	s := st.collab.sess
	if s == nil {return true}
	switch s.role {
	case "owner", "edit":
		return true
	case "suggest":
		return st.collab.suggest
	case "":
		// not yet welcomed: a local copy, edits queue and are checked later
		return s.status != .Refused
	}
	return false
}

// collab_publish sends this window's caret and selection when they change.
collab_publish :: proc(st: ^State) {
	cb := &st.collab
	c := sticky_encode(sticky_of(st, st.caret))
	a := sticky_encode(sticky_of(st, st.anchor))
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, `{"c":`)
	jq(&b, c)
	append(&b, `,"a":`)
	jq(&b, a)
	append(&b, cb.suggest ? `,"sg":true}` : `}`)
	s := string(b[:])
	if s != collab_x.aware_last {
		delete(collab_x.aware_last)
		collab_x.aware_last = strings.clone(s)
		client.set_awareness(cb.sess, s)
	}
}

jq :: proc(b: ^[dynamic]u8, s: string) {
	append(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '"' || c == '\\' {
			append(b, '\\')
		}
		if c >= 0x20 {
			append(b, c)
		}
	}
	append(b, '"')
}

// collab_refresh_peers resolves everyone's sticky carets into this model.
collab_refresh_peers :: proc(st: ^State) {
	for pv in collab_x.peers {
		delete(pv.name)
		delete(pv.handle)
		delete(pv.color)
		delete(pv.role)
	}
	clear(&collab_x.peers)
	s := st.collab.sess
	if s == nil {return}
	for &peer in s.peers {
		pv := Peer_View {
			name   = strings.clone(peer.identity.display_name),
			handle = strings.clone(peer.identity.handle),
			color  = strings.clone(peer.identity.color),
			role   = strings.clone(peer.role),
		}
		cs := client.jstr(peer.state, "c")
		as := client.jstr(peer.state, "a")
		if sc_, ok := sticky_decode(cs); ok {
			pv.caret = sticky_resolve(st, sc_)
			pv.anchor = pv.caret
			if sa, ok2 := sticky_decode(as); ok2 {
				pv.anchor = sticky_resolve(st, sa)
			}
			pv.has = true
		}
		if obj, ok := peer.state.(json.Object); ok {
			if b, ok2 := obj["sg"].(json.Boolean); ok2 {pv.suggesting = bool(b)}
		}
		append(&collab_x.peers, pv)
	}
}

// ---------------------------------------------------------------------------
// History and versions
// ---------------------------------------------------------------------------

// collab_load_history fetches the version list: editing sessions (each with
// everyone who edited in it) and named versions, newest first, in one list.
collab_load_history :: proc(st: ^State) {
	for &h in collab_x.history {history_row_free(&h)}
	clear(&collab_x.history)
	if !collab_x.have_acct {return}
	gap := os.get_env("PALM_COLLAB_HISTORY_GAP", context.temp_allocator)
	if gap == "" {gap = "300"}
	v, err := client.rpc_raw(&collab_x.acct, "collab_history", fmt.tprintf(`{{"p_doc":"%s","p_gap":%s}}`, collab_x.doc_id, gap))
	if err != "" {
		note(st, fmt.tprintf("History unavailable: %s", err))
		return
	}
	defer ck.value_destroy(v)
	for s in ck.array(ck.get(v, "sessions")) {
		row := History_Row {
			from  = u64(ck.get_int(s, "from")),
			to    = u64(ck.get_int(s, "to")),
			n     = int(ck.get_int(s, "n")),
			when_ = strings.clone(short_time(ck.get_str(s, "last_at"))),
		}
		names := strings.builder_make(context.temp_allocator)
		for a, i in ck.array(ck.get(s, "authors")) {
			append(&row.authors, Author_Chip{strings.clone(ck.get_str(a, "name")), strings.clone(ck.get_str(a, "color"))})
			if i > 0 {strings.write_string(&names, ", ")}
			strings.write_string(&names, ck.get_str(a, "name"))
		}
		row.name = strings.clone(strings.to_string(names))
		append(&collab_x.history, row)
	}
	for s in ck.array(ck.get(v, "versions")) {
		row := History_Row {
			to    = u64(ck.get_int(s, "seq")),
			name  = strings.clone(ck.get_str(s, "name")),
			when_ = strings.clone(short_time(ck.get_str(s, "at"))),
			named = true,
		}
		append(&row.authors, Author_Chip{strings.clone(ck.get_str(s, "by")), strings.clone(ck.get_str(s, "color"))})
		// in order: a named version sits above the session it closes
		at := len(collab_x.history)
		for h, i in collab_x.history {
			if h.to <= row.to {
				at = i
				break
			}
		}
		inject_at(&collab_x.history, at, row)
	}
}

history_row_free :: proc(h: ^History_Row) {
	delete(h.name)
	delete(h.when_)
	for a in h.authors {
		delete(a.name)
		delete(a.color)
	}
	delete(h.authors)
}

// collab_preview_label names what is being viewed, in words.
collab_preview_label :: proc() -> string {
	for h in collab_x.history {
		if h.to == collab_x.preview_seq {
			return h.named ? tfmt("“%s”", h.name) : h.when_
		}
	}
	return tfmt("edit %d", collab_x.preview_seq)
}

// short_time turns an ISO timestamp into "Oct 19, 14:02".
short_time :: proc(iso: string) -> string {
	if len(iso) < 16 {return iso}
	months := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	m := int(iso[5] - '0') * 10 + int(iso[6] - '0')
	day := iso[8:10]
	if day[0] == '0' {day = day[1:]}
	return fmt.tprintf("%s %s, %s", months[clamp(m - 1, 0, 11)], day, iso[11:16])
}

// collab_preview shows the document as it was after update `seq`,
// read-only, until collab_leave_preview or collab_restore.
collab_preview :: proc(st: ^State, seq: u64) {
	cb := &st.collab
	v, err := client.rpc_raw(&collab_x.acct, "collab_state_at", fmt.tprintf(`{{"p_doc":"%s","p_seq":%d}}`, collab_x.doc_id, seq))
	if err != "" {
		note(st, fmt.tprintf("Cannot load that version: %s", err))
		return
	}
	defer ck.value_destroy(v)
	old := crdt.doc_make(1)
	if snap := ck.get_str(v, "snapshot"); snap != "" {
		data, _ := base64.decode(snap, allocator = context.temp_allocator)
		if d, ok := crdt.doc_load(1, data); ok {
			crdt.doc_destroy(old)
			old = d
		}
	}
	for u in ck.array(ck.get(v, "updates")) {
		if s, ok := u.(json.String); ok {
			data, _ := base64.decode(s, allocator = context.temp_allocator)
			crdt.apply_update(old, data)
		}
	}
	if collab_x.preview {
		crdt.doc_destroy(cb.doc)
	} else {
		collab_x.live_doc = cb.doc
	}
	cb.doc = old
	collab_x.preview = true
	collab_x.preview_seq = seq
	collab_materialise(st, {}, false)
	note(st, "Read-only. Enter restores this version, Escape returns to now.")
}

collab_leave_preview :: proc(st: ^State) {
	cb := &st.collab
	if !collab_x.preview {return}
	crdt.doc_destroy(cb.doc)
	cb.doc = collab_x.live_doc
	collab_x.preview = false
	collab_materialise(st, {}, false)
}

// collab_restore makes the previewed version the current one — as a new
// edit on top, so nothing is lost and the restore itself can be undone.
collab_restore :: proc(st: ^State) {
	cb := &st.collab
	if !collab_x.preview {return}
	old_model := st.doc
	st.doc = {}
	crdt.doc_destroy(cb.doc)
	cb.doc = collab_x.live_doc
	collab_x.preview = false
	collab_materialise(st, {}, false) // the live model, to diff against
	collab_note_edit(st, .Structural)
	doc_destroy(&st.doc)
	st.doc = old_model
	clear(&cb.tables)
	clear(&cb.images)
	collab_sync(st)
	collab_materialise(st, {}, false)
	note(st, tfmt("Restored %s, as a new edit you can undo", collab_preview_label()))
}

collab_name_version :: proc(st: ^State, name: string) {
	if !collab_x.have_acct || strings.trim_space(name) == "" {return}
	s := st.collab.sess
	o := ck.obj()
	ck.put(&o, "doc_id", collab_x.doc_id)
	ck.put(&o, "identity_id", s.doc_kind != "" ? "" : "")
	_ = o
	body := fmt.tprintf(
		`{{"doc_id":"%s","identity_id":"%s","seq":%d,"name":%s,"created_by":"%s"}}`,
		collab_x.doc_id,
		collab_owner_id(),
		s.last_seq,
		json_string(name),
		collab_x.acct.me.id,
	)
	v, e := ck.insert(collab_x.acct.c, "collab_versions", body)
	ck.value_destroy(v)
	note(st, ck.ok(e) ? fmt.tprintf("Named this version %q", name) : fmt.tprintf("Could not name it: %s", e.message))
	collab_load_history(st)
}

collab_owner_id :: proc() -> string {
	v, e := ck.select(collab_x.acct.c, "collab_documents", fmt.tprintf("select=identity_id&id=eq.%s", collab_x.doc_id))
	defer ck.value_destroy(v)
	if !ck.ok(e) || len(ck.array(v)) == 0 {return ""}
	return strings.clone(ck.get_str(ck.array(v)[0], "identity_id"), context.temp_allocator)
}

json_string :: proc(s: string) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	jq(&b, s)
	return string(b[:])
}

// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

collab_load_people :: proc(st: ^State) {
	for pr in collab_x.people {delete(pr.handle); delete(pr.name); delete(pr.color); delete(pr.role)}
	clear(&collab_x.people)
	if !collab_x.have_acct {return}
	v, err := client.rpc_raw(&collab_x.acct, "collab_people", fmt.tprintf(`{{"p_doc":"%s"}}`, collab_x.doc_id))
	if err != "" {return}
	defer ck.value_destroy(v)
	for r in ck.array(v) {
		append(&collab_x.people, Person_Row{
			handle = strings.clone(ck.get_str(r, "handle")),
			name = strings.clone(ck.get_str(r, "display_name")),
			color = strings.clone(ck.get_str(r, "color")),
			role = strings.clone(ck.get_str(r, "role")),
		})
	}
}

// collab_share_cmd takes "handle role" from the share prompt.
collab_share_cmd :: proc(st: ^State, spec: string) {
	parts := strings.fields(spec, context.temp_allocator)
	if len(parts) == 0 {return}
	role := len(parts) > 1 ? parts[1] : "edit"
	if parts[0] == "link" {
		tok, err := client.doc_make_link(&collab_x.acct, collab_x.doc_id, role == "edit" ? "comment" : role)
		if err != "" {
			note(st, err)
			return
		}
		delete(collab_x.link_token)
		collab_x.link_token = tok
		note(st, "Link created: anyone signed in who has it can join")
		return
	}
	if err := client.doc_share(&collab_x.acct, collab_x.doc_id, parts[0], role); err != "" {
		note(st, err)
	} else {
		note(st, fmt.tprintf("Shared with %s (%s)", parts[0], role))
	}
	collab_load_people(st)
}

collab_unshare_sel :: proc(st: ^State) {
	i := collab_x.sel
	if i < 0 || i >= len(collab_x.people) || collab_x.people[i].role == "owner" {return}
	h := collab_x.people[i].handle
	v, err := client.rpc_raw(&collab_x.acct, "collab_unshare", fmt.tprintf(`{{"p_doc":"%s","p_handle":"%s"}}`, collab_x.doc_id, h))
	ck.value_destroy(v)
	note(st, err == "" ? fmt.tprintf("%s no longer has access", h) : err)
	collab_load_people(st)
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

collab_keys :: proc(ui: ^p.Ctx, st: ^State) -> bool {
	cb := &st.collab
	if !cb.on {return false}
	ca := p.Modifiers{.Ctrl, .Alt}
	if collab_x.preview {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			collab_leave_preview(st)
		} else if p.key_pressed(ui, p.KEY_RETURN) {
			collab_restore(st)
		} else if p.key_pressed(ui, p.KEY_DOWN) || p.key_pressed(ui, p.KEY_UP) {
			n := len(collab_x.history)
			if n > 0 {
				collab_x.sel = clamp(collab_x.sel + (p.key_pressed(ui, p.KEY_DOWN) ? 1 : -1), 0, n - 1)
				collab_preview(st, collab_x.history[collab_x.sel].to)
			}
		}
		return true // nothing else while previewing
	}
	if p.shortcut(ui, 'm', ca) {
		if has_selection(st) {
			open_prompt(st, .Comment)
		} else {
			note(st, "Select the text to comment on first")
		}
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 's', ca) {
		if cb.sess != nil && cb.sess.role == "suggest" {
			note(st, "You can suggest, not edit, in this document")
		} else {
			cb.suggest = !cb.suggest
			note(st, cb.suggest ? "Suggesting: your edits become proposals" : "Editing")
		}
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'a', ca) {
		n := collab_decide(st, true)
		note(st, n > 0 ? "Suggestion accepted" : "No suggestion here")
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'd', ca) {
		n := collab_decide(st, false)
		note(st, n > 0 ? "Suggestion rejected" : "No suggestion here")
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'c', ca) {
		cb.panel = cb.panel == .Comments ? .None : .Comments
		collab_x.sel = 0
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'h', ca) {
		cb.panel = cb.panel == .History ? .None : .History
		if cb.panel == .History {collab_load_history(st)}
		collab_x.sel = 0
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'k', ca) {
		cb.panel = cb.panel == .Share ? .None : .Share
		if cb.panel == .Share {collab_load_people(st)}
		collab_x.sel = 0
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'v', ca) {
		open_prompt(st, .Name_Version)
		st.swallow = true
		return true
	}
	if p.shortcut(ui, 'o', ca) && cb.sess != nil {
		if cb.sess.thread != nil {
			client.go_offline(cb.sess)
			note(st, "Working offline: edits are kept and sent when you reconnect")
		} else {
			client.reconnect(cb.sess)
			note(st, "Reconnecting")
		}
		collab_refresh_peers(st)
		st.swallow = true
		return true
	}
	// panel navigation
	switch cb.panel {
	case .Comments:
		n := len(cb.comments)
		if p.shortcut(ui, 'n', ca) || p.shortcut(ui, 'p', ca) {
			if n > 0 {
				collab_x.sel = (collab_x.sel + (p.shortcut(ui, 'n', ca) ? 1 : n - 1)) % n
				c := cb.comments[collab_x.sel]
				cb.active_comment = c.id
				st.caret, st.anchor = c.anchor, c.anchor
				scroll_to_caret(st)
				collab_refresh_decos(st)
			}
			st.swallow = true
			return true
		}
		if p.shortcut(ui, 'y', ca) && n > 0 {
			open_prompt(st, .Reply)
			st.swallow = true
			return true
		}
		if p.shortcut(ui, 'r', ca) && n > 0 {
			c := cb.comments[clamp(collab_x.sel, 0, n - 1)]
			collab_resolve(st, c.id, !c.resolved)
			st.swallow = true
			return true
		}
	case .History:
		n := len(collab_x.history)
		if p.shortcut(ui, p.KEY_RETURN, ca) && n > 0 {
			collab_preview(st, collab_x.history[clamp(collab_x.sel, 0, n - 1)].to)
			st.swallow = true
			return true
		}
		if (p.shortcut(ui, p.KEY_DOWN, ca) || p.shortcut(ui, p.KEY_UP, ca)) && n > 0 {
			collab_x.sel = clamp(collab_x.sel + (p.shortcut(ui, p.KEY_DOWN, ca) ? 1 : -1), 0, n - 1)
			st.swallow = true
			return true
		}
	case .Share:
		if p.shortcut(ui, 'a', {.Ctrl, .Alt, .Shift}) {
			open_prompt(st, .Share)
			st.swallow = true
			return true
		}
		n := len(collab_x.people)
		if (p.shortcut(ui, p.KEY_DOWN, ca) || p.shortcut(ui, p.KEY_UP, ca)) && n > 0 {
			collab_x.sel = clamp(collab_x.sel + (p.shortcut(ui, p.KEY_DOWN, ca) ? 1 : -1), 0, n - 1)
			st.swallow = true
			return true
		}
		if p.shortcut(ui, p.KEY_DELETE, ca) {
			collab_unshare_sel(st)
			st.swallow = true
			return true
		}
	case .None:
	}
	return false
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

collab_side_w :: proc(st: ^State) -> f32 {
	return st.collab.on && st.collab.panel != .None ? COLLAB_PANEL_W + 1 : 0
}

// collab_band is the 3px identity band across the top of the window.
collab_band :: proc(ui: ^p.Ctx, st: ^State) {
	if !st.collab.on {return}
	p.div(ui, tfmt("h-[3] w-full shrink-0 bg-%s-500", st.collab.color))
	p.end(ui)
}

monogram :: proc(ui: ^p.Ctx, name, color: string, size := "size-6", ring := false) {
	initial := name != "" ? name[:1] : "?"
	if ring {
		p.div(ui, tfmt("%s shrink-0 rounded-full items-center justify-center bg-background p-[2]", size))
		p.div(ui, tfmt("w-full h-full rounded-full items-center justify-center bg-%s-500", color))
	} else {
		p.div(ui, tfmt("%s shrink-0 rounded-full items-center justify-center bg-%s-500", size, color))
	}
	p.text(ui, strings.to_upper(initial, context.temp_allocator), "text-[11] font-semibold text-white")
	p.end(ui)
	if ring {p.end(ui)}
}

// collab_identity_chip: who this window is acting as, always visible.
collab_identity_chip :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	if !cb.on {return}
	p.row(ui, tfmt("h-7 shrink-0 items-center gap-1.5 pl-1 pr-2.5 rounded-full bg-%s-500/15", cb.color))
	monogram(ui, cb.name, cb.color, "size-5")
	p.text(ui, cb.name, "text-[12] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

collab_status_text :: proc(st: ^State) -> (text: string, tone: string) {
	s := st.collab.sess
	if s == nil {return "Local", "text-muted-foreground"}
	if collab_x.preview {return tfmt("Viewing %s · read-only", collab_preview_label()), "text-amber-600"}
	waiting := client.pending_count(s)
	switch s.status {
	case .Live:
		if waiting > 0 {return tfmt("Saving %d", waiting), "text-muted-foreground"}
		return "Saved", "text-muted-foreground"
	case .Syncing, .Connecting:
		return "Connecting", "text-muted-foreground"
	case .Offline:
		if waiting > 0 {return tfmt("Offline, %d edit%s waiting", waiting, waiting == 1 ? "" : "s"), "text-amber-600"}
		return "Offline, everything is kept here", "text-amber-600"
	case .Refused:
		return tfmt("No access: %s", s.error), "text-red-600"
	}
	return "", ""
}

// collab_presence: the people here, then the role and the status.
collab_presence :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	if !cb.on {return}
	p.row(ui, "shrink-0 items-center gap-2")
	defer p.end(ui)
	seen := make(map[string]bool, 8, context.temp_allocator)
	p.row(ui, "shrink-0 items-center")
	for pv in collab_x.peers {
		if pv.handle in seen {continue}
		seen[pv.handle] = true
		monogram(ui, pv.name, pv.color, "size-7", true)
	}
	p.end(ui)
	text, tone := collab_status_text(st)
	p.text(ui, text, tfmt("text-[11.5] whitespace-nowrap %s", tone))
	p.style(ui).shrink = 0
	if cb.suggest {
		sc.badge(ui, "Suggesting", .Outline)
	} else if cb.sess != nil {
		switch cb.sess.role {
		case "view":
			sc.badge(ui, "View only", .Secondary)
		case "comment":
			sc.badge(ui, "Can comment", .Secondary)
		}
	}
}

collab_toolbar_buttons :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	if !cb.on {return}
	if tool_button(ui, "c-comment", ICON_MESSAGE_SQUARE, cb.panel == .Comments) {
		cb.panel = cb.panel == .Comments ? .None : .Comments
	}
	if tool_button(ui, "c-suggest", ICON_PENCIL_LINE, cb.suggest) {
		cb.suggest = !cb.suggest
	}
	if tool_button(ui, "c-history", ICON_HISTORY, cb.panel == .History) {
		cb.panel = cb.panel == .History ? .None : .History
		if cb.panel == .History {collab_load_history(st)}
	}
	p.key(ui, "c-share")
	idx := p.row(ui, tfmt("h-7 shrink-0 items-center gap-1.5 px-3 rounded-md bg-%s-600 text-white hover:bg-%s-500 transition cursor-pointer", cb.color, cb.color))
	if p.clickable(ui, idx) {
		cb.panel = cb.panel == .Share ? .None : .Share
		if cb.panel == .Share {collab_load_people(st)}
	}
	p.icon(ui, ICON_USERS, "size-3.5")
	p.text(ui, "Share", "text-[12.5] font-medium")
	p.end(ui)
}

collab_panel :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	p.col(ui, tfmt("w-[%.0f] h-full shrink-0 bg-background overflow-hidden", COLLAB_PANEL_W))
	defer p.end(ui)
	switch cb.panel {
	case .Comments:
		panel_comments(ui, st)
	case .History:
		panel_history(ui, st)
	case .Share:
		panel_share(ui, st)
	case .None:
	}
}

panel_head :: proc(ui: ^p.Ctx, title, hint: string) {
	p.col(ui, "w-full shrink-0 gap-0.5 px-4 pt-3 pb-2")
	p.text(ui, title, "text-[13] font-semibold")
	p.text(ui, hint, "text-[11] text-muted-foreground")
	p.end(ui)
	sc.separator(ui)
}

panel_comments :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	panel_head(ui, "Comments and suggestions", "Ctrl+Alt+M comment · N/P next · Y reply · R resolve")
	p.col(ui, "w-full flex-1 min-h-0 gap-2 p-3 overflow-hidden")
	defer p.end(ui)
	// suggestions first: they wait on a decision
	sugg := 0
	seen := make(map[string]bool, 8, context.temp_allocator)
	for dc in cb.decos {
		if dc.kind != .Sugg_Ins && dc.kind != .Sugg_Del {continue}
		key := tfmt("%v/%s/%d/%d", dc.kind, dc.id, dc.blk.para, dc.blk.cpara)
		if key in seen {continue}
		seen[key] = true
		sugg += 1
		pa := blk_para(&st.doc, dc.blk)
		txt := pa != nil ? para_text(pa, context.temp_allocator) : ""
		frag := txt[clamp(dc.from, 0, len(txt)):clamp(dc.to, 0, len(txt))]
		p.col(ui, "w-full shrink-0 gap-1.5 p-2.5 rounded-lg border border-border bg-muted/30")
		p.row(ui, "items-center gap-1.5")
		who := peer_name_for(st, dc.id)
		monogram(ui, who, peer_color_for(st, dc.id), "size-5")
		p.text(ui, tfmt("%s suggested %s", who, dc.kind == .Sugg_Ins ? "adding" : "deleting"), "text-[11.5] font-medium")
		p.end(ui)
		p.text(ui, tfmt("“%s”", frag), dc.kind == .Sugg_Del ? "text-[12] text-muted-foreground line-through" : "text-[12]")
		p.text(ui, "Ctrl+Alt+A accept · Ctrl+Alt+D reject (at the caret)", "text-[10.5] text-muted-foreground")
		p.end(ui)
	}
	if len(cb.comments) == 0 && sugg == 0 {
		p.text(ui, "No comments yet. Select text and press Ctrl+Alt+M.", "text-[12] text-muted-foreground")
	}
	for c, i in cb.comments {
		active := c.id == cb.active_comment || i == collab_x.sel
		cls := "w-full shrink-0 gap-1.5 p-2.5 rounded-lg border bg-background"
		cls = active ? tfmt("%s border-amber-400 ring-2 ring-amber-200", cls) : tfmt("%s border-border", cls)
		if c.resolved {cls = tfmt("%s opacity-60", cls)}
		p.col(ui, cls)
		p.row(ui, "items-center gap-1.5")
		monogram(ui, c.name, c.color, "size-5")
		p.text(ui, c.name, "text-[11.5] font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		if c.resolved {sc.badge(ui, "Resolved", .Secondary)}
		p.end(ui)
		if c.quote != "" {
			q := c.quote
			if len(q) > 60 {q = tfmt("%s…", q[:57])}
			p.row(ui, "w-full gap-2")
			p.div(ui, "w-[2] self-stretch rounded-full bg-amber-400 shrink-0")
			p.end(ui)
			p.text(ui, q, "text-[11.5] text-muted-foreground")
			p.end(ui)
		} else if !c.alive {
			p.text(ui, "The text this was on was deleted", "text-[11] text-muted-foreground italic")
		}
		p.text(ui, c.text, "text-[12.5]")
		for r in c.replies {
			p.row(ui, "w-full gap-1.5 pl-2 pt-1")
			monogram(ui, r.name, r.color, "size-4")
			p.col(ui, "flex-1 gap-0.5")
			p.text(ui, r.name, "text-[11] font-semibold")
			p.text(ui, r.text, "text-[12]")
			p.end(ui)
			p.end(ui)
		}
		p.end(ui)
	}
}

panel_history :: proc(ui: ^p.Ctx, st: ^State) {
	panel_head(ui, "Version history", "Ctrl+Alt+↑↓ select · Ctrl+Alt+Enter view · Ctrl+Alt+V name this version")
	p.col(ui, "w-full flex-1 min-h-0 gap-1 p-2 overflow-hidden")
	defer p.end(ui)
	if len(collab_x.history) == 0 {
		p.text(ui, "No history yet.", "text-[12] text-muted-foreground px-2")
	}
	for h, i in collab_x.history {
		on := i == collab_x.sel
		p.row(ui, on ? "w-full shrink-0 items-center gap-2.5 px-2 py-2 rounded-md bg-accent" : "w-full shrink-0 items-center gap-2.5 px-2 py-2 rounded-md")
		if h.named {
			p.div(ui, "size-7 shrink-0 rounded-full items-center justify-center bg-primary/10")
			p.icon(ui, ICON_BOOKMARK, "size-3.5 text-primary")
			p.end(ui)
		} else {
			p.row(ui, "shrink-0 items-center")
			for a, k in h.authors {
				if k >= 3 {break}
				monogram(ui, a.name, a.color, "size-7", k > 0)
			}
			p.end(ui)
		}
		p.col(ui, "flex-1 gap-0 min-w-0")
		if h.named {
			p.text(ui, h.name, "text-[12.5] font-semibold")
			p.text(ui, tfmt("%s · named by %s", h.when_, len(h.authors) > 0 ? h.authors[0].name : ""), "text-[11] text-muted-foreground")
		} else {
			p.text(ui, h.when_, "text-[12.5] font-medium")
			p.text(ui, tfmt("%s · %d edit%s", h.name, h.n, h.n == 1 ? "" : "s"), "text-[11] text-muted-foreground")
		}
		p.end(ui)
		if collab_x.preview && collab_x.preview_seq == h.to {
			sc.badge(ui, "Viewing", .Default)
		} else if i == 0 && !h.named {
			sc.badge(ui, "Current", .Secondary)
		}
		p.end(ui)
	}
}

panel_share :: proc(ui: ^p.Ctx, st: ^State) {
	cb := &st.collab
	panel_head(ui, "Share", "Ctrl+Alt+Shift+A add · Ctrl+Alt+Del remove")
	p.col(ui, "w-full flex-1 min-h-0 gap-2 p-3 overflow-hidden")
	defer p.end(ui)
	// The identity this is shared *from*, in its colour, before anything else.
	p.row(ui, tfmt("w-full shrink-0 items-center gap-2 p-2 rounded-lg bg-%s-500/10 border border-%s-500/30", cb.color, cb.color))
	monogram(ui, cb.name, cb.color, "size-6")
	p.col(ui, "flex-1 gap-0")
	p.text(ui, tfmt("You are %s", cb.name), "text-[12] font-semibold")
	p.text(ui, cb.sess != nil && cb.sess.role != "" ? tfmt("Role here: %s", cb.sess.role) : "Not connected", "text-[11] text-muted-foreground")
	p.end(ui)
	p.end(ui)
	p.text(ui, "People with access", "text-[11] font-semibold text-muted-foreground pt-1")
	for pr, i in collab_x.people {
		on := i == collab_x.sel
		p.row(ui, on ? "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-md bg-accent" : "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-md")
		monogram(ui, pr.name, pr.color, "size-6")
		p.col(ui, "flex-1 gap-0")
		p.text(ui, pr.name, "text-[12.5] font-medium")
		p.text(ui, tfmt("@%s", pr.handle), "text-[11] text-muted-foreground")
		p.end(ui)
		sc.badge(ui, pr.role == "owner" ? "Owner" : pr.role, pr.role == "owner" ? .Default : .Secondary)
		p.end(ui)
	}
	if collab_x.link_token != "" {
		p.text(ui, "Link (shown once)", "text-[11] font-semibold text-muted-foreground pt-2")
		p.text(ui, tfmt("docs --collab %s --link %s", collab_x.doc_id, collab_x.link_token), "text-[10.5] font-mono break-all")
	}
	p.text(ui, "Sharing crosses identities only through a grant you make here; it is listed on both sides and can be revoked.", "text-[11] text-muted-foreground pt-2")
}

// ---------------------------------------------------------------------------
// Drawing other people on the page
// ---------------------------------------------------------------------------

// draw_collab_line paints comments and suggestions under one laid-out line.
draw_collab_line :: proc(c: ^p.Canvas, st: ^State, li: int, ox, ly, lh, base, k: f32) {
	l := st.lay.lines[li]
	b := line_blk(l)
	for dc in st.collab.decos {
		if dc.blk != b {continue}
		a := max(dc.from, l.start)
		e := min(dc.to, l.end)
		if e <= a {continue}
		x0 := ox + (l.x + caret_x(&st.lay, li, a) - l.x) * k
		x1 := ox + (l.x + caret_x(&st.lay, li, e) - l.x) * k
		col := p.hex(dc.color)
		switch dc.kind {
		case .Comment, .Comment_Active:
			col.a = dc.kind == .Comment_Active ? 150 : 95
			p.fill_rect(c, {x0, ly, x1 - x0, lh}, col)
		case .Sugg_Ins:
			wash := col
			wash.a = 40
			p.fill_rect(c, {x0, ly, x1 - x0, lh}, wash)
			p.fill_rect(c, {x0, base + 2 * k, x1 - x0, max(1.2, 1.6 * k)}, col)
		case .Sugg_Del:
			p.fill_rect(c, {x0, ly + lh * 0.52, x1 - x0, max(1.2, 1.4 * k)}, col)
		}
	}
	// other people's selections (not over an old version: they are in now)
	if collab_x.preview {return}
	for pv in collab_x.peers {
		if !pv.has || pv.caret == pv.anchor {continue}
		lo, hi := pos_order(pv.caret, pv.anchor)
		lb := line_blk(l)
		if pos_less(blk_pos(lb, l.end), lo) || pos_less(hi, blk_pos(lb, l.start)) {continue}
		a := pos_same_block(blk_pos(lb, 0), lo) ? max(l.start, lo.off) : l.start
		e := pos_same_block(blk_pos(lb, 0), hi) ? min(l.end, hi.off) : l.end
		if e <= a {continue}
		col := p.hex(identity_rgb(pv.color))
		col.a = 55
		x0 := caret_x(&st.lay, li, a)
		x1 := caret_x(&st.lay, li, e)
		p.fill_rect(c, {ox + x0 * k, ly, (x1 - x0) * k, lh}, col)
	}
}

// draw_remote_carets puts each collaborator's caret, with a name flag, on
// page `pi`.
draw_remote_carets :: proc(c: ^p.Canvas, st: ^State, pi: int, ox, oy, k: f32) {
	if collab_x.preview {return}
	for pv in collab_x.peers {
		if !pv.has {continue}
		li := line_of(&st.lay, pv.caret)
		if li < 0 || st.lay.lines[li].page != pi {continue}
		l := st.lay.lines[li]
		cx := caret_x(&st.lay, li, pv.caret.off)
		col := p.hex(identity_rgb(pv.color))
		x := ox + cx * k
		y := oy + l.y * k
		p.fill_rect(c, {x - max(0.6, 0.8 * k), y, max(1.6, 2 * k), l.h * k}, col)
		label := pv.suggesting ? tfmt("%s · suggesting", pv.name) : pv.name
		fs := 10.5 * k
		tw := p.text_width(layout_fonts, label, fs, .Sans, .Medium)
		fh := fs * 1.55
		p.fill_round_rect(c, {x - max(0.6, 0.8 * k), y - fh, tw + 8 * k, fh}, {3 * k, 3 * k, 3 * k, 0}, col)
		p.draw_text(c, layout_fonts, label, x + 3.5 * k, y - fh * 0.3, fs, p.hex(0xffffff), .Sans, .Medium)
	}
}

crdt_can_undo :: proc(st: ^State) -> bool {return crdt.can_undo(st.collab.doc)}
crdt_can_redo :: proc(st: ^State) -> bool {return crdt.can_redo(st.collab.doc)}
