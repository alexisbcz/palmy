package main

// A Palmy account: one sign-in, several identities, each with its own
// mailbox.
//
//	mailcore palm login --email E --password P [--auth-port 55529]
//	mailcore palm sync  [--jmap-port 55580] [--submit-port 55587]
//	mailcore palm status
//	mailcore palm logout
//
// LOGIN signs in to the account's Supabase Auth (GoTrue) with a password grant
// and keeps the session — access token, refresh token, expiry — in
// <data>/.palmy/session, mode 0600. Nothing else holds the password; it is
// not written anywhere.
//
// SYNC talks JMAP to palm-maild with that token as a bearer credential. The
// session object lists, as JMAP accounts, exactly the identities the token
// can reach (RLS decides, not this program), and each becomes its own Maildir
// account under <data>/<address>/, which is what apps/mail reads. It also
// writes <data>/palmy.conf, naming each identity with its kind and colour
// so the UI can label it. Per identity, in this order:
//
//   1. Flags changed in the Maildir since the last sync (read, flagged,
//      answered...) are pushed to the server as Email/set keyword patches.
//      The ids come from <account>/.palm-ids, written by the previous sync.
//   2. Messages apps/mail queued in the account's Outbox (marked
//      `X-Palmy-Mail: queued-locally`) are submitted over SMTP submission
//      with AUTH PLAIN <address> / <access token>, and removed locally once
//      the server has taken them. Local recipients are delivered; any other
//      recipient comes back held in the server's Outbox, not sent.
//   3. Every mailbox is downloaded afresh into a new tree, which then
//      replaces the old one, so a second sync is not a second copy.
//
// Like every network path in mailcore, all of this refuses any host outside
// 127.0.0.0/8 (conn_dial) and resolves no names.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Palm_Session :: struct {
	email:         string,
	access_token:  string,
	refresh_token: string,
	expires_at:    i64,
	auth_port:     int,
	jmap_port:     int,
	submit_port:   int,
}

palm_dir :: proc() -> string {
	return strings.concatenate({maildir_default_root(context.temp_allocator), "/.palmy"}, context.allocator)
}

palm_session_path :: proc() -> string {
	return strings.concatenate({palm_dir(), "/session"}, context.allocator)
}

palm_load :: proc() -> (s: Palm_Session, ok: bool) {
	data, err := os.read_entire_file_from_path(palm_session_path(), context.allocator)
	if err != nil {
		return s, false
	}
	s.auth_port, s.jmap_port, s.submit_port = 55529, 55580, 55587
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		k, v := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
		switch k {
		case "email":
			s.email = v
		case "access_token":
			s.access_token = v
		case "refresh_token":
			s.refresh_token = v
		case "expires_at":
			s.expires_at, _ = strconv.parse_i64(v, 10)
		case "auth_port":
			s.auth_port, _ = strconv.parse_int(v, 10)
		case "jmap_port":
			s.jmap_port, _ = strconv.parse_int(v, 10)
		case "submit_port":
			s.submit_port, _ = strconv.parse_int(v, 10)
		}
	}
	return s, s.access_token != ""
}

palm_save :: proc(s: Palm_Session) -> string {
	if os.make_directory_all(palm_dir(), {.Read_User, .Write_User, .Execute_User}) != nil && !os.exists(palm_dir()) {
		return fmt.aprintf("cannot create %s", palm_dir())
	}
	body := fmt.tprintf(
		"# A Palmy session, written by `mailcore palm login`. Treat as a password.\nemail = %s\naccess_token = %s\nrefresh_token = %s\nexpires_at = %d\nauth_port = %d\njmap_port = %d\nsubmit_port = %d\n",
		s.email, s.access_token, s.refresh_token, s.expires_at, s.auth_port, s.jmap_port, s.submit_port,
	)
	path := palm_session_path()
	// Create it 0600 before a single byte of the token is in it.
	f, oerr := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if oerr != nil {
		return fmt.aprintf("cannot write %s", path)
	}
	defer os.close(f)
	os.chmod(path, {.Read_User, .Write_User})
	if _, werr := os.write_string(f, body); werr != nil {
		return fmt.aprintf("cannot write %s", path)
	}
	return ""
}

// palm_token_grant posts to GoTrue's /token with a password or refresh grant.
palm_token_grant :: proc(s: ^Palm_Session, grant, body: string) -> string {
	c: Conn
	if e := conn_dial(&c, "127.0.0.1", s.auth_port, {}, "auth"); e != "" {
		return e
	}
	defer conn_close(&c)
	resp, he := http_do(
		&c,
		Http_Request {
			method = "POST",
			target = fmt.tprintf("/token?grant_type=%s", grant),
			host = fmt.tprintf("127.0.0.1:%d", s.auth_port),
			headers = {{name = "Content-Type", value = "application/json"}, {name = "Connection", value = "close"}},
			body = transmute([]u8)body,
		},
	)
	if he != "" {
		return he
	}
	v, pe := json.parse(resp.body, .JSON, true, context.allocator)
	if resp.status != 200 || pe != nil {
		msg := jv_str(v, "error_description")
		if msg == "" {msg = jv_str(v, "msg")}
		if msg == "" {msg = string(resp.body)}
		return fmt.aprintf("sign-in refused (%d): %s", resp.status, msg)
	}
	s.access_token = strings.clone(jv_str(v, "access_token"))
	s.refresh_token = strings.clone(jv_str(v, "refresh_token"))
	s.expires_at = i64(jv_int(v, "expires_at"))
	if s.expires_at == 0 {
		s.expires_at = time.time_to_unix(time.now()) + i64(jv_int(v, "expires_in"))
	}
	if u, ok := jv_get(v, "user"); ok {
		if e := jv_str(u, "email"); e != "" {
			s.email = strings.clone(e)
		}
	}
	return ""
}

// palm_fresh refreshes the access token when it is within a minute of expiry.
palm_fresh :: proc(s: ^Palm_Session) -> string {
	if time.time_to_unix(time.now()) < s.expires_at - 60 {
		return ""
	}
	if s.refresh_token == "" {
		return "the session has expired; sign in again"
	}
	if e := palm_token_grant(s, "refresh_token", fmt.tprintf(`{{"refresh_token":%s}}`, json_quote(s.refresh_token, context.temp_allocator))); e != "" {
		return e
	}
	return palm_save(s^)
}

// palm_login signs in with a password grant and keeps the session. It is
// what `mailcore login` (and the older `mailcore palm login`, which apps/mail
// runs from its sign-in sheet) calls; nothing else signs in.
palm_login :: proc(s: ^Palm_Session, password: string) -> string {
	if s.email == "" || password == "" {
		return "--email and --password (or --password-file) are required"
	}
	if e := palm_token_grant(s, "password", fmt.tprintf(`{{"email":%s,"password":%s}}`, json_quote(s.email, context.temp_allocator), json_quote(password, context.temp_allocator))); e != "" {
		return e
	}
	return palm_save(s^)
}

// palm_logout forgets the session. The synced Maildirs are left where they
// are. `removed` says whether there was a session to forget.
palm_logout :: proc() -> (removed: bool) {
	path := palm_session_path()
	removed = os.exists(path)
	os.remove(path)
	return removed
}

// Palm_Sync_Row is one identity's outcome of a sync.
Palm_Sync_Row :: struct {
	address:   string,
	kind:      string,
	handle:    string,
	messages:  int,
	pushed:    int,
	submitted: int,
	held:      int,
	error:     string,
}

// palm_sync syncs every identity the session can reach — or, when `only` is
// set, the one identity in scope (by handle or by address) — and reports each
// one. It prints nothing: the caller decides what the outcome looks like.
palm_sync :: proc(s: ^Palm_Session, only := "") -> (rows: []Palm_Sync_Row, conf_path: string, err: string) {
	out := make([dynamic]Palm_Sync_Row, 0, 4, context.allocator)
	j: JMAP
	if e := jmap_connect_bearer(&j, "127.0.0.1", s.jmap_port, s.access_token, {}, context.allocator); e != "" {
		return nil, "", e
	}
	defer jmap_close(&j)
	base := maildir_default_root(context.allocator)
	conf := strings.builder_make()
	fmt.sbprintf(&conf, "# Written by `mailcore palm sync`. The identities this session can reach.\n[session]\nemail = %s\njmap = 127.0.0.1:%d\n\n", s.email, s.jmap_port)

	// Personal first, then work, public, project; by address within a kind.
	// The session's accounts are a JSON object, so their order is nobody's.
	rank :: proc(k: string) -> int {
		switch k {
		case "personal":
			return 0
		case "work":
			return 1
		case "public":
			return 2
		}
		return 3
	}
	slice.sort_by(j.session.accounts, proc(a, b: Jmap_Account) -> bool {
		if rank(a.kind) != rank(b.kind) {
			return rank(a.kind) < rank(b.kind)
		}
		return a.name < b.name
	})
	for a in j.session.accounts {
		addr := a.address != "" ? a.address : a.name
		if addr == "" || strings.contains(addr, "/") || strings.contains(addr, "..") {
			continue
		}
		if only != "" && only != a.handle && only != addr {
			continue
		}
		row := Palm_Sync_Row {
			address = addr,
			kind    = a.kind,
			handle  = a.handle,
		}
		j.session.primary_mail_account = a.id
		root := strings.concatenate({base, "/", addr}, context.allocator)
		pushed := palm_push_flags(&j, root)
		sent, held, serr := palm_submit_outbox(s, root, addr)
		row.pushed, row.submitted, row.held = pushed, sent, held
		if serr != "" {
			row.error = serr
		}
		n, ferr := palm_fetch_all(&j, root)
		row.messages = n
		if ferr != "" {
			row.error = ferr
			append(&out, row)
			continue
		}
		append(&out, row)
		fmt.sbprintf(
			&conf,
			"[identity]\nid = %s\nhandle = %s\nname = %s\nkind = %s\ncolor = %s\naddress = %s\npath = %s\n\n",
			a.id, a.handle, a.display_name, a.kind, a.color, addr, addr,
		)
	}
	conf_path = strings.concatenate({base, "/palmy.conf"}, context.allocator)
	// A sync narrowed to one identity knows only that identity, and writing
	// the file from it would make the others vanish from apps/mail.
	if only == "" {
		if os.write_entire_file(conf_path, transmute([]u8)strings.to_string(conf)) != nil {
			return out[:], conf_path, fmt.aprintf("cannot write %s", conf_path)
		}
	}
	return out[:], conf_path, ""
}

// palm_push_flags compares each message's Maildir flags with the flags it had
// when it was synced, and pushes the difference.
palm_push_flags :: proc(j: ^JMAP, root: string) -> (pushed: int) {
	ids_path := strings.concatenate({root, "/.palm-ids"}, context.temp_allocator)
	data, err := os.read_entire_file_from_path(ids_path, context.temp_allocator)
	if err != nil {
		return 0
	}
	md, oerr := maildir_open(root, context.temp_allocator)
	if oerr != "" {
		return 0
	}
	now := make(map[string]Maildir_Flags, 64, context.temp_allocator)
	for folder in maildir_folders(&md, context.temp_allocator) {
		for e in maildir_list(&md, folder, context.temp_allocator) {
			now[e.unique] = e.flags
		}
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		// unique <TAB> email id <TAB> flags at sync time
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 {
			continue
		}
		cur, still := now[f[0]]
		if !still {
			continue // deleted locally: not propagated (a deliberate gap; see the report)
		}
		was := maildir_flags_parse(fmt.tprintf(":2,%s", f[2]))
		if cur == was {
			continue
		}
		add := maildir_flags_to_keywords(cur - was, context.temp_allocator)
		rem := maildir_flags_to_keywords(was - cur, context.temp_allocator)
		if jmap_email_set_keywords(j, f[1], add, rem, "", context.temp_allocator) == "" {
			pushed += 1
		}
	}
	return
}

// palm_submit_outbox submits what apps/mail queued, over SMTP submission.
palm_submit_outbox :: proc(s: ^Palm_Session, root, addr: string) -> (sent, held: int, err: string) {
	md, oerr := maildir_open(root, context.temp_allocator)
	if oerr != "" {
		return 0, 0, oerr
	}
	queued := make([dynamic]Maildir_Entry, 0, 4, context.temp_allocator)
	for e in maildir_list(&md, "Outbox", context.temp_allocator) {
		raw, rerr := maildir_read(e, context.temp_allocator)
		if rerr == "" && strings.contains(string(raw[:min(len(raw), 8192)]), "X-Palmy-Mail: queued-locally") {
			append(&queued, e)
		}
	}
	if len(queued) == 0 {
		return 0, 0, ""
	}
	sm: SMTP
	if e := smtp_connect(&sm, "127.0.0.1", s.submit_port, {}, context.temp_allocator); e != "" {
		return 0, 0, e
	}
	defer smtp_close(&sm)
	if e := smtp_ehlo(&sm, "mailcore"); e != "" {
		return 0, 0, e
	}
	if e := smtp_auth_plain(&sm, addr, s.access_token); e != "" {
		return 0, 0, e
	}
	for e in queued {
		raw, _ := maildir_read(e, context.temp_allocator)
		// The local "never transmitted" marker is about to stop being true.
		body := strip_header(raw, "x-palmy-mail")
		m := parse_message(body, context.temp_allocator)
		rcpts := make([dynamic]string, 0, 4, context.temp_allocator)
		for group in ([][]Address{m.to, m.cc, m.bcc}) {
			for a in group {
				if a.email != "" {append(&rcpts, a.email)}
			}
		}
		if len(rcpts) == 0 {
			continue
		}
		_, se := smtp_send(&sm, Envelope{from = addr, to = rcpts[:], body = body})
		if se != "" {
			return sent, held, se
		}
		for r in rcpts {
			if at := strings.last_index_byte(r, '@'); at >= 0 && !strings.equal_fold(r[at + 1:], addr[strings.last_index_byte(addr, '@') + 1:]) {
				held += 1
			}
		}
		maildir_remove(e)
		sent += 1
	}
	smtp_quit(&sm)
	return sent, held, ""
}

strip_header :: proc(raw: []u8, name: string) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)
	text := string(raw)
	in_head := true
	skipping := false
	for line in strings.split_after_iterator(&text, "\n") {
		if in_head {
			if line == "\r\n" || line == "\n" {
				in_head = false
			} else if len(line) > 0 && (line[0] == ' ' || line[0] == '\t') {
				if skipping {continue}
			} else {
				skipping = strings.has_prefix(strings.to_lower(line, context.temp_allocator), strings.concatenate({name, ":"}, context.temp_allocator))
				if skipping {continue}
			}
		}
		strings.write_string(&sb, line)
	}
	return transmute([]u8)strings.to_string(sb)
}

// palm_fetch_all downloads every mailbox of the current account into a new
// tree beside the old one, then swaps it in.
palm_fetch_all :: proc(j: ^JMAP, root: string) -> (n: int, err: string) {
	fresh := strings.concatenate({root, ".syncing"}, context.temp_allocator)
	os.remove_all(fresh)
	md, oerr := maildir_open(fresh, context.temp_allocator)
	if oerr != "" {
		return 0, oerr
	}
	boxes, berr := jmap_mailbox_get(j, context.temp_allocator)
	if berr != "" {
		return 0, berr
	}
	ids := strings.builder_make(context.temp_allocator)
	for b in boxes {
		folder := strings.equal_fold(b.role, "inbox") ? INBOX : b.name
		if e := maildir_ensure_folder(&md, folder); e != "" {
			return n, e
		}
		emails, _, qe := jmap_query_then_get(j, b.id, false, 0, context.temp_allocator)
		if qe != "" {
			return n, qe
		}
		for em in emails {
			raw, de := jmap_download(j, em.blob_id, "message.eml", "message/rfc822", context.temp_allocator)
			if de != "" {
				return n, de
			}
			flags := jmap_keywords_to_flags(em.keywords)
			name, we := maildir_deliver(&md, folder, raw, flags, flags == {}, context.temp_allocator)
			if we != "" {
				return n, we
			}
			unique, _, _ := maildir_parse_name(name)
			fmt.sbprintf(&ids, "%s\t%s\t%s\n", unique, em.id, maildir_flags_string(flags, context.temp_allocator))
			n += 1
		}
	}
	if os.write_entire_file(strings.concatenate({fresh, "/.palm-ids"}, context.temp_allocator), transmute([]u8)strings.to_string(ids)) != nil {
		return n, "cannot write the id map"
	}
	os.remove_all(root)
	if os.rename(fresh, root) != nil {
		return n, fmt.aprintf("cannot move %s into place", fresh)
	}
	return n, ""
}
