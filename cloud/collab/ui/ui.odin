// Shared collaboration chrome for the office apps: the account and session a
// window joins with, the identity band and chip, presence avatars, the
// status line, and the share and version-history panels. Each app keeps its
// own binding (what its model means in the CRDT) and its own drawing of
// other people's cursors; everything about *people* lives here so Sheets and
// Slides look and behave the same.
//
// Built with the apps' own collections: palmy and shadcn.
package collabui

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."
import ck "../../../apps/cloudkit"
import client "../client"
import crdt "../crdt"

Panel :: enum u8 {
	None,
	Comments,
	History,
	Share,
}

Author_Chip :: struct {
	name:  string,
	color: string,
}

History_Row :: struct {
	from, to: u64,
	n:        int,
	name:     string,
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

Args :: struct {
	doc:     string,
	as:      string,
	link:    string,
	title:   string,
	script:  string,
	offline: bool,
}

State :: struct {
	on:          bool,
	acct:        client.Account,
	have_acct:   bool,
	sess:        ^client.Session,
	doc_id:      string,
	handle:      string,
	name:        string,
	color:       string,
	panel:       Panel,
	sel:         int,
	history:     [dynamic]History_Row,
	people:      [dynamic]Person_Row,
	preview:     bool,
	preview_seq: u64,
	live_doc:    ^crdt.Doc,
	link_token:  string,
	token_at:    time.Tick,
	aware_last:  string,
}

// parse_args pulls the collaboration flags out of a command line.
parse_args :: proc(args: []string) -> (a: Args, rest: [dynamic]string) {
	rest = make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			if i^ + 1 < len(args) {
				i^ += 1
				return args[i^]
			}
			return ""
		}
		switch args[i] {
		case "--collab":
			a.doc = next(args, &i)
		case "--as":
			a.as = next(args, &i)
		case "--link":
			a.link = next(args, &i)
		case "--title":
			a.title = next(args, &i)
		case "--script":
			a.script = next(args, &i)
		case "--offline":
			a.offline = true
		case:
			append(&rest, args[i])
		}
	}
	return
}

// start opens the account, creates the document when asked (`doc == "new"`),
// and opens the session. `created` says the window should seed the new
// document from what it has open.
start :: proc(s: ^State, kind: string, a: Args, app: ^p.App, default_title: string, client_name: string) -> (created: bool, err: string) {
	acct, aerr := client.account_open("", a.as)
	if aerr != "" {
		return false, aerr
	}
	s.acct = acct
	s.have_acct = true
	doc := a.doc
	if doc == "new" {
		title := a.title != "" ? a.title : default_title
		id, cerr := client.doc_create(&s.acct, kind, title)
		if cerr != "" {
			return false, cerr
		}
		doc = id
		created = true
		fmt.printfln("shared document %s (%s), owned by %s", id, title, acct.me.handle)
	}
	s.doc_id = strings.clone(doc)
	host, port := client.server_address()
	s.sess = client.session_open(
		client.Config {
			host = host,
			port = port,
			doc_id = doc,
			as_id = acct.me.id,
			token = client.account_token(&s.acct),
			link = a.link,
			app = client_name,
			offline = a.offline,
			wake = proc(ctx: rawptr) {p.wake((^p.App)(ctx))},
			wake_ctx = app,
		},
	)
	s.handle = strings.clone(acct.me.handle)
	s.name = strings.clone(acct.me.display_name)
	s.color = strings.clone(acct.me.color)
	s.token_at = time.tick_now()
	s.on = true
	return created, ""
}

// keep_token refreshes the server's copy of the access token now and then.
keep_token :: proc(s: ^State) {
	if s.sess == nil || !s.have_acct {return}
	if time.duration_seconds(time.tick_since(s.token_at)) > 600 {
		s.token_at = time.tick_now()
		client.set_token(s.sess, client.account_token(&s.acct))
	}
}

// publish sends this window's awareness JSON when it changed.
publish :: proc(s: ^State, state_json: string) {
	if s.sess == nil || state_json == s.aware_last {return}
	delete(s.aware_last)
	s.aware_last = strings.clone(state_json)
	client.set_awareness(s.sess, state_json)
}

// settle asks for one more frame shortly after a remote change. palmy drops a
// frame when the compositor has not released a buffer yet and does not retry
// it; a change that arrives alone (someone moving their cursor) would then
// sit unseen until the next input. One follow-up frame closes that gap.
settle :: proc(ui: ^p.Ctx) {
	if ui == nil {return}
	p.redraw(ui)
	p.wake_after(ui, 120 * time.Millisecond)
}

may_edit :: proc(s: ^State) -> bool {
	if s.sess == nil {return true}
	switch s.sess.role {
	case "owner", "edit":
		return true
	case "":
		return s.sess.status != .Refused
	}
	return false
}

// ---------------------------------------------------------------------------
// Data: history, people, sharing
// ---------------------------------------------------------------------------

load_history :: proc(s: ^State) -> string {
	for &h in s.history {history_row_free(&h)}
	clear(&s.history)
	if !s.have_acct {return "not signed in"}
	gap := os.get_env("PALM_COLLAB_HISTORY_GAP", context.temp_allocator)
	if gap == "" {gap = "300"}
	v, err := client.rpc_raw(&s.acct, "collab_history", fmt.tprintf(`{{"p_doc":"%s","p_gap":%s}}`, s.doc_id, gap))
	if err != "" {
		return err
	}
	defer ck.value_destroy(v)
	for x in ck.array(ck.get(v, "sessions")) {
		row := History_Row {
			from  = u64(ck.get_int(x, "from")),
			to    = u64(ck.get_int(x, "to")),
			n     = int(ck.get_int(x, "n")),
			when_ = strings.clone(short_time(ck.get_str(x, "last_at"))),
		}
		names := strings.builder_make(context.temp_allocator)
		for au, i in ck.array(ck.get(x, "authors")) {
			append(&row.authors, Author_Chip{strings.clone(ck.get_str(au, "name")), strings.clone(ck.get_str(au, "color"))})
			if i > 0 {strings.write_string(&names, ", ")}
			strings.write_string(&names, ck.get_str(au, "name"))
		}
		row.name = strings.clone(strings.to_string(names))
		append(&s.history, row)
	}
	for x in ck.array(ck.get(v, "versions")) {
		row := History_Row {
			to    = u64(ck.get_int(x, "seq")),
			name  = strings.clone(ck.get_str(x, "name")),
			when_ = strings.clone(short_time(ck.get_str(x, "at"))),
			named = true,
		}
		append(&row.authors, Author_Chip{strings.clone(ck.get_str(x, "by")), strings.clone(ck.get_str(x, "color"))})
		at := len(s.history)
		for h, i in s.history {
			if h.to <= row.to {
				at = i
				break
			}
		}
		inject_at(&s.history, at, row)
	}
	return ""
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

short_time :: proc(iso: string) -> string {
	if len(iso) < 16 {return iso}
	months := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	m := int(iso[5] - '0') * 10 + int(iso[6] - '0')
	day := iso[8:10]
	if day[0] == '0' {day = day[1:]}
	return fmt.tprintf("%s %s, %s", months[clamp(m - 1, 0, 11)], day, iso[11:16])
}

preview_label :: proc(s: ^State) -> string {
	for h in s.history {
		if h.to == s.preview_seq {
			return h.named ? fmt.tprintf("“%s”", h.name) : h.when_
		}
	}
	return fmt.tprintf("edit %d", s.preview_seq)
}

// state_at rebuilds the document as it was after update `seq`.
state_at :: proc(s: ^State, seq: u64) -> (d: ^crdt.Doc, err: string) {
	v, e := client.rpc_raw(&s.acct, "collab_state_at", fmt.tprintf(`{{"p_doc":"%s","p_seq":%d}}`, s.doc_id, seq))
	if e != "" {
		return nil, e
	}
	defer ck.value_destroy(v)
	d = crdt.doc_make(1)
	if snap := ck.get_str(v, "snapshot"); snap != "" {
		data, _ := base64.decode(snap, allocator = context.temp_allocator)
		if loaded, ok := crdt.doc_load(1, data); ok {
			crdt.doc_destroy(d)
			d = loaded
		}
	}
	for u in ck.array(ck.get(v, "updates")) {
		if x, ok := u.(json.String); ok {
			data, _ := base64.decode(x, allocator = context.temp_allocator)
			crdt.apply_update(d, data)
		}
	}
	return d, ""
}

name_version :: proc(s: ^State, name: string) -> string {
	if !s.have_acct || strings.trim_space(name) == "" {return "nothing to name"}
	owner := ""
	{
		v, e := ck.select(s.acct.c, "collab_documents", fmt.tprintf("select=identity_id&id=eq.%s", s.doc_id))
		if ck.ok(e) && len(ck.array(v)) > 0 {
			owner = strings.clone(ck.get_str(ck.array(v)[0], "identity_id"), context.temp_allocator)
		}
		ck.value_destroy(v)
	}
	o := ck.obj()
	ck.put(&o, "doc_id", s.doc_id)
	ck.put(&o, "identity_id", owner)
	ck.put(&o, "seq", i64(s.sess.last_seq))
	ck.put(&o, "name", name)
	ck.put(&o, "created_by", s.acct.me.id)
	v, e := ck.insert(s.acct.c, "collab_versions", ck.obj_done(&o))
	ck.value_destroy(v)
	if !ck.ok(e) {
		return fmt.tprintf("could not name it: %s", e.message)
	}
	load_history(s)
	return ""
}

load_people :: proc(s: ^State) {
	for pr in s.people {delete(pr.handle); delete(pr.name); delete(pr.color); delete(pr.role)}
	clear(&s.people)
	if !s.have_acct {return}
	v, err := client.rpc_raw(&s.acct, "collab_people", fmt.tprintf(`{{"p_doc":"%s"}}`, s.doc_id))
	if err != "" {return}
	defer ck.value_destroy(v)
	for r in ck.array(v) {
		append(&s.people, Person_Row{
			handle = strings.clone(ck.get_str(r, "handle")),
			name = strings.clone(ck.get_str(r, "display_name")),
			color = strings.clone(ck.get_str(r, "color")),
			role = strings.clone(ck.get_str(r, "role")),
		})
	}
}

// share_cmd takes "<handle> <role>" or "link <role>"; returns a note.
share_cmd :: proc(s: ^State, spec: string) -> string {
	parts := strings.fields(spec, context.temp_allocator)
	if len(parts) == 0 {return ""}
	role := len(parts) > 1 ? parts[1] : "edit"
	if parts[0] == "link" {
		tok, err := client.doc_make_link(&s.acct, s.doc_id, role == "edit" ? "comment" : role)
		if err != "" {return err}
		delete(s.link_token)
		s.link_token = tok
		return "Link created: anyone signed in who has it can join"
	}
	defer load_people(s)
	if err := client.doc_share(&s.acct, s.doc_id, parts[0], role); err != "" {
		return err
	}
	return fmt.tprintf("Shared with %s (%s)", parts[0], role)
}

unshare_sel :: proc(s: ^State) -> string {
	i := s.sel
	if i < 0 || i >= len(s.people) || s.people[i].role == "owner" {return ""}
	h := s.people[i].handle
	v, err := client.rpc_raw(&s.acct, "collab_unshare", fmt.tprintf(`{{"p_doc":"%s","p_handle":"%s"}}`, s.doc_id, h))
	ck.value_destroy(v)
	load_people(s)
	return err == "" ? fmt.tprintf("%s no longer has access", h) : err
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

identity_rgb :: proc(name: string) -> u32 {
	switch name {
	case "red":
		return 0xef4444
	case "orange":
		return 0xf97316
	case "amber":
		return 0xf59e0b
	case "yellow":
		return 0xeab308
	case "lime":
		return 0x84cc16
	case "green":
		return 0x22c55e
	case "emerald":
		return 0x10b981
	case "teal":
		return 0x14b8a6
	case "cyan":
		return 0x06b6d4
	case "sky":
		return 0x0ea5e9
	case "blue":
		return 0x3b82f6
	case "violet":
		return 0x8b5cf6
	case "purple":
		return 0xa855f7
	case "fuchsia":
		return 0xd946ef
	case "pink":
		return 0xec4899
	case "rose":
		return 0xf43f5e
	}
	return 0x6366f1
}

monogram :: proc(ui: ^p.Ctx, name, color: string, size := "size-6", ring := false) {
	initial := name != "" ? name[:1] : "?"
	if ring {
		p.div(ui, fmt.tprintf("%s shrink-0 rounded-full items-center justify-center bg-background p-[2]", size))
		p.div(ui, fmt.tprintf("w-full h-full rounded-full items-center justify-center bg-%s-500", color))
	} else {
		p.div(ui, fmt.tprintf("%s shrink-0 rounded-full items-center justify-center bg-%s-500", size, color))
	}
	p.text(ui, strings.to_upper(initial, context.temp_allocator), "text-[11] font-semibold text-white")
	p.end(ui)
	if ring {p.end(ui)}
}

// band is the 3px identity band across the top of the window.
band :: proc(ui: ^p.Ctx, s: ^State) {
	if !s.on {return}
	p.div(ui, fmt.tprintf("h-[3] w-full shrink-0 bg-%s-500", s.color))
	p.end(ui)
}

chip :: proc(ui: ^p.Ctx, s: ^State) {
	if !s.on {return}
	p.row(ui, fmt.tprintf("h-7 shrink-0 items-center gap-1.5 pl-1 pr-2.5 rounded-full bg-%s-500/15", s.color))
	monogram(ui, s.name, s.color, "size-5")
	p.text(ui, s.name, "text-[12] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

status_text :: proc(s: ^State) -> (text: string, tone: string) {
	if s.sess == nil {return "Local", "text-muted-foreground"}
	if s.preview {return fmt.tprintf("Viewing %s · read-only", preview_label(s)), "text-amber-600"}
	waiting := client.pending_count(s.sess)
	switch s.sess.status {
	case .Live:
		if waiting > 0 {return fmt.tprintf("Saving %d", waiting), "text-muted-foreground"}
		return "Saved", "text-muted-foreground"
	case .Syncing, .Connecting:
		return "Connecting", "text-muted-foreground"
	case .Offline:
		if waiting > 0 {return fmt.tprintf("Offline, %d edit%s waiting", waiting, waiting == 1 ? "" : "s"), "text-amber-600"}
		return "Offline, everything is kept here", "text-amber-600"
	case .Refused:
		return fmt.tprintf("No access: %s", s.sess.error), "text-red-600"
	}
	return "", ""
}

// presence draws everyone else here, the status and the role.
presence :: proc(ui: ^p.Ctx, s: ^State) {
	if !s.on || s.sess == nil {return}
	p.row(ui, "shrink-0 items-center gap-2")
	defer p.end(ui)
	seen := make(map[string]bool, 8, context.temp_allocator)
	p.row(ui, "shrink-0 items-center")
	for &peer in s.sess.peers {
		h := peer.identity.handle
		if h in seen {continue}
		seen[h] = true
		monogram(ui, peer.identity.display_name, peer.identity.color, "size-7", true)
	}
	p.end(ui)
	text, tone := status_text(s)
	p.text(ui, text, fmt.tprintf("text-[11.5] whitespace-nowrap %s", tone))
	p.style(ui).shrink = 0
	switch s.sess.role {
	case "view":
		sc.badge(ui, "View only", .Secondary)
	case "comment":
		sc.badge(ui, "Can comment", .Secondary)
	case "suggest":
		sc.badge(ui, "Can suggest", .Secondary)
	}
}

// share_button is the primary action, in the identity's colour.
share_button :: proc(ui: ^p.Ctx, s: ^State) -> bool {
	p.key(ui, "c-share")
	idx := p.row(ui, fmt.tprintf("h-7 shrink-0 items-center gap-1.5 px-3 rounded-md bg-%s-600 text-white hover:bg-%s-500 transition cursor-pointer", s.color, s.color))
	fired := p.clickable(ui, idx)
	p.text(ui, "Share", "text-[12.5] font-medium")
	p.end(ui)
	return fired
}

panel_head :: proc(ui: ^p.Ctx, title, hint: string) {
	p.col(ui, "w-full shrink-0 gap-0.5 px-4 pt-3 pb-2")
	p.text(ui, title, "text-[13] font-semibold")
	p.text(ui, hint, "text-[11] text-muted-foreground")
	p.end(ui)
	sc.separator(ui)
}

panel_history :: proc(ui: ^p.Ctx, s: ^State) {
	panel_head(ui, "Version history", "Ctrl+Alt+↑↓ select · Ctrl+Alt+Enter view · Ctrl+Alt+V name this version")
	p.col(ui, "w-full flex-1 min-h-0 gap-1 p-2 overflow-hidden")
	defer p.end(ui)
	if len(s.history) == 0 {
		p.text(ui, "No history yet.", "text-[12] text-muted-foreground px-2")
	}
	for h, i in s.history {
		on := i == s.sel
		p.row(ui, on ? "w-full shrink-0 items-center gap-2.5 px-2 py-2 rounded-md bg-accent" : "w-full shrink-0 items-center gap-2.5 px-2 py-2 rounded-md")
		if h.named {
			p.div(ui, "size-7 shrink-0 rounded-full items-center justify-center bg-primary/10")
			p.text(ui, "★", "text-[12] text-primary")
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
			p.text(ui, fmt.tprintf("%s · named by %s", h.when_, len(h.authors) > 0 ? h.authors[0].name : ""), "text-[11] text-muted-foreground")
		} else {
			p.text(ui, h.when_, "text-[12.5] font-medium")
			p.text(ui, fmt.tprintf("%s · %d edit%s", h.name, h.n, h.n == 1 ? "" : "s"), "text-[11] text-muted-foreground")
		}
		p.end(ui)
		if s.preview && s.preview_seq == h.to {
			sc.badge(ui, "Viewing", .Default)
		} else if i == 0 && !h.named {
			sc.badge(ui, "Current", .Secondary)
		}
		p.end(ui)
	}
}

panel_share :: proc(ui: ^p.Ctx, s: ^State) {
	panel_head(ui, "Share", "Ctrl+Alt+Shift+A add · Ctrl+Alt+Del remove")
	p.col(ui, "w-full flex-1 min-h-0 gap-2 p-3 overflow-hidden")
	defer p.end(ui)
	p.row(ui, fmt.tprintf("w-full shrink-0 items-center gap-2 p-2 rounded-lg bg-%s-500/10 border border-%s-500/30", s.color, s.color))
	monogram(ui, s.name, s.color, "size-6")
	p.col(ui, "flex-1 gap-0")
	p.text(ui, fmt.tprintf("You are %s", s.name), "text-[12] font-semibold")
	p.text(ui, s.sess != nil && s.sess.role != "" ? fmt.tprintf("Role here: %s", s.sess.role) : "Not connected", "text-[11] text-muted-foreground")
	p.end(ui)
	p.end(ui)
	p.text(ui, "People with access", "text-[11] font-semibold text-muted-foreground pt-1")
	for pr, i in s.people {
		on := i == s.sel
		p.row(ui, on ? "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-md bg-accent" : "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-md")
		monogram(ui, pr.name, pr.color, "size-6")
		p.col(ui, "flex-1 gap-0")
		p.text(ui, pr.name, "text-[12.5] font-medium")
		p.text(ui, fmt.tprintf("@%s", pr.handle), "text-[11] text-muted-foreground")
		p.end(ui)
		sc.badge(ui, pr.role == "owner" ? "Owner" : pr.role, pr.role == "owner" ? .Default : .Secondary)
		p.end(ui)
	}
	if s.link_token != "" {
		p.text(ui, "Link (shown once)", "text-[11] font-semibold text-muted-foreground pt-2")
		p.text(ui, fmt.tprintf("--collab %s --link %s", s.doc_id, s.link_token), "text-[10.5] font-mono")
	}
	p.text(ui, "Sharing crosses identities only through a grant you make here; it is listed on both sides and can be revoked.", "text-[11] text-muted-foreground pt-2")
}

// Panel_Key is what the panel keys asked for; the app acts on it.
Panel_Key :: enum u8 {
	None,
	Handled,
	Preview, // view s.history[s.sel]
	Add_Person, // open the share prompt
	Name_Version,
}

// panel_keys handles the keys shared by every app's panels.
panel_keys :: proc(ui: ^p.Ctx, s: ^State) -> Panel_Key {
	ca := p.Modifiers{.Ctrl, .Alt}
	if p.shortcut(ui, 'h', ca) {
		s.panel = s.panel == .History ? .None : .History
		if s.panel == .History {load_history(s)}
		s.sel = 0
		return .Handled
	}
	if p.shortcut(ui, 'k', ca) {
		s.panel = s.panel == .Share ? .None : .Share
		if s.panel == .Share {load_people(s)}
		s.sel = 0
		return .Handled
	}
	if p.shortcut(ui, 'v', ca) {
		return .Name_Version
	}
	if p.shortcut(ui, 'o', ca) && s.sess != nil {
		if s.sess.thread != nil {
			client.go_offline(s.sess)
		} else {
			client.reconnect(s.sess)
		}
		return .Handled
	}
	#partial switch s.panel {
	case .History:
		n := len(s.history)
		if (p.shortcut(ui, p.KEY_DOWN, ca) || p.shortcut(ui, p.KEY_UP, ca)) && n > 0 {
			s.sel = clamp(s.sel + (p.shortcut(ui, p.KEY_DOWN, ca) ? 1 : -1), 0, n - 1)
			return .Handled
		}
		if p.shortcut(ui, p.KEY_RETURN, ca) && n > 0 {
			return .Preview
		}
	case .Share:
		if p.shortcut(ui, 'a', {.Ctrl, .Alt, .Shift}) {
			return .Add_Person
		}
		n := len(s.people)
		if (p.shortcut(ui, p.KEY_DOWN, ca) || p.shortcut(ui, p.KEY_UP, ca)) && n > 0 {
			s.sel = clamp(s.sel + (p.shortcut(ui, p.KEY_DOWN, ca) ? 1 : -1), 0, n - 1)
			return .Handled
		}
		if p.shortcut(ui, p.KEY_DELETE, ca) {
			unshare_sel(s)
			return .Handled
		}
	}
	return .None
}

destroy :: proc(s: ^State) {
	if s.sess != nil {
		client.session_close(s.sess)
		s.sess = nil
	}
	for &h in s.history {history_row_free(&h)}
	delete(s.history)
	for pr in s.people {delete(pr.handle); delete(pr.name); delete(pr.color); delete(pr.role)}
	delete(s.people)
}
