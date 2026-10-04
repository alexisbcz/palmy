package main

// The IMAP4rev1 front end.
//
// It emits literals on purpose and often: every body fetch comes back as
// `{n}` plus raw octets, including for messages whose bodies contain CRLF
// sequences that look like other responses. A client with a line-based parser
// fails here immediately, which is exactly what this server is for.
//
// Command parsing on this side also has to handle literals, because APPEND
// sends the message that way, so there is a `+ Ready for additional command
// text` handshake in `imap_read_command`.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

IMAP_CAPS :: "IMAP4rev1 LITERAL+ IDLE UIDPLUS CHILDREN NAMESPACE UNSELECT"

Imap_Session :: struct {
	c:         ^SConn,
	acct:      ^Account,
	box:       ^Mailbox,
	read_only: bool,
	box_version: int,
	// Sequence numbers are 1-based positions in the live message list, and
	// they shift on expunge, so the snapshot is taken per command.
	logged_in: bool,
}

imap_serve :: proc(c: ^SConn) {
	s := Imap_Session {
		c = c,
	}
	sline(c, "* OK [CAPABILITY %s] mailcore test IMAP server ready", IMAP_CAPS)
	for c.open {
		toks, ok := imap_read_command(c)
		if !ok {
			return
		}
		if len(toks) < 2 {
			sline(c, "* BAD empty command")
			continue
		}
		tag := toks[0]
		cmd := strings.to_upper(toks[1], context.temp_allocator)
		args := toks[2:]
		if !imap_dispatch(&s, tag, cmd, args) {
			return
		}
		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------
// Command tokenising, with literals
// ---------------------------------------------------------------------------

// imap_read_command returns the command as a flat token list. Parentheses are
// returned as their own tokens so a FETCH item list can be walked; a
// `BODY[HEADER.FIELDS (DATE)]` section stays glued to its atom.
imap_read_command :: proc(c: ^SConn) -> (toks: []string, ok: bool) {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	line, lok := sread_line(c)
	if !lok {
		return nil, false
	}
	cur := strings.clone(line, context.temp_allocator)
	slog(c, "<- %s", cur)
	pos := 0
	for {
		// Skip whitespace.
		for pos < len(cur) && (cur[pos] == ' ' || cur[pos] == '\t') {
			pos += 1
		}
		if pos >= len(cur) {
			break
		}
		switch cur[pos] {
		case '(', ')':
			append(&out, cur[pos:pos + 1])
			pos += 1
			continue
		case '"':
			sb := strings.builder_make(context.temp_allocator)
			pos += 1
			for pos < len(cur) {
				if cur[pos] == '\\' && pos + 1 < len(cur) {
					pos += 1
					strings.write_byte(&sb, cur[pos])
					pos += 1
					continue
				}
				if cur[pos] == '"' {
					pos += 1
					break
				}
				strings.write_byte(&sb, cur[pos])
				pos += 1
			}
			append(&out, strings.to_string(sb))
			continue
		case '{':
			close := strings.index_byte(cur[pos:], '}')
			if close < 0 {
				sline(c, "* BAD malformed literal")
				return nil, false
			}
			inner := strings.trim_right(cur[pos + 1:pos + close], "+")
			nonsync := strings.has_suffix(cur[pos + 1:pos + close], "+")
			n, nok := strconv.parse_int(strings.trim_space(inner), 10)
			if !nok || n < 0 || n > 32 * 1024 * 1024 {
				sline(c, "* BAD implausible literal length")
				return nil, false
			}
			// LITERAL+ (RFC 7888) means the client did not wait for us.
			if !nonsync {
				sline(c, "+ Ready for %d octets", n)
			}
			data, dok := sread_exact(c, n, context.temp_allocator)
			if !dok {
				return nil, false
			}
			append(&out, string(data))
			nl, nlok := sread_line(c)
			if !nlok {
				return out[:], true
			}
			cur = strings.clone(nl, context.temp_allocator)
			slog(c, "<- (after literal) %s", cur)
			pos = 0
			continue
		}
		// An atom, absorbing a balanced [...] and a trailing <n.m>.
		start := pos
		for pos < len(cur) {
			ch := cur[pos]
			if ch == '[' {
				depth := 0
				for pos < len(cur) {
					if cur[pos] == '[' {depth += 1} else if cur[pos] == ']' {
						depth -= 1
						if depth == 0 {pos += 1;break}
					}
					pos += 1
				}
				if pos < len(cur) && cur[pos] == '<' {
					for pos < len(cur) && cur[pos] != '>' {pos += 1}
					if pos < len(cur) {pos += 1}
				}
				continue
			}
			if ch == ' ' || ch == '\t' || ch == '(' || ch == ')' || ch == '"' {
				break
			}
			pos += 1
		}
		append(&out, cur[start:pos])
	}
	return out[:], true
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

imap_dispatch :: proc(s: ^Imap_Session, tag, cmd: string, args: []string) -> bool {
	c := s.c
	switch cmd {
	case "CAPABILITY":
		sline(c, "* CAPABILITY %s", IMAP_CAPS)
		sline(c, "%s OK CAPABILITY completed", tag)

	case "NOOP":
		// RFC 3501 6.1.2: NOOP is the polling mechanism, so it is where a
		// client that is not IDLEing learns the mailbox changed.
		sync.mutex_lock(&store.mu)
		if s.box != nil && s.box.version != s.box_version {
			s.box_version = s.box.version
			n := box_count(s.box)
			r := imap_recent(s.box)
			sync.mutex_unlock(&store.mu)
			sline(c, "* %d EXISTS", n)
			sline(c, "* %d RECENT", r)
		} else {
			sync.mutex_unlock(&store.mu)
		}
		sline(c, "%s OK NOOP completed", tag)

	case "LOGOUT":
		sline(c, "* BYE mailcore test server signing off")
		sline(c, "%s OK LOGOUT completed", tag)
		return false

	case "LOGIN":
		if len(args) < 2 {
			sline(c, "%s BAD LOGIN needs a user and a password", tag)
			return true
		}
		sync.mutex_lock(&store.mu)
		a := store_account(args[0])
		ok := a != nil && a.password == args[1]
		sync.mutex_unlock(&store.mu)
		if !ok {
			// A deliberate, constant message: a server that distinguishes
			// "no such user" from "wrong password" leaks the user list.
			sline(c, "%s NO [AUTHENTICATIONFAILED] Invalid credentials", tag)
			return true
		}
		s.acct = a
		s.logged_in = true
		sline(c, "%s OK [CAPABILITY %s] LOGIN completed", tag, IMAP_CAPS)

	case "AUTHENTICATE":
		sline(c, "%s NO AUTHENTICATE is not implemented by this test server; use LOGIN", tag)

	case "STARTTLS":
		// Stated plainly rather than faked: TLS in front of this server is a
		// socat OPENSSL-LISTEN tunnel, so the server itself cannot upgrade.
		sline(c, "%s NO This server is plaintext; TLS is provided by a socat tunnel in front of it", tag)

	case:
		if !s.logged_in {
			sline(c, "%s NO Authenticate first", tag)
			return true
		}
		return imap_dispatch_authed(s, tag, cmd, args)
	}
	return true
}

imap_dispatch_authed :: proc(s: ^Imap_Session, tag, cmd: string, args: []string) -> bool {
	c := s.c
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)

	switch cmd {
	case "LIST", "LSUB":
		if len(args) < 2 {
			sline(c, "%s BAD %s needs a reference and a pattern", tag, cmd)
			return true
		}
		pattern := args[1]
		if pattern == "" {
			// RFC 3501 6.3.8: an empty pattern asks for the delimiter only.
			sline(c, "* %s (\\Noselect) \"%s\" \"\"", cmd, HIERARCHY_DELIM)
			sline(c, "%s OK %s completed", tag, cmd)
			return true
		}
		for i in 0 ..< len(s.acct.boxes) {
			b := &s.acct.boxes[i]
			if !imap_match(pattern, b.name) {
				continue
			}
			attrs := imap_box_attrs(s.acct, b)
			sline(c, "* %s (%s) \"%s\" \"%s\"", cmd, attrs, HIERARCHY_DELIM, b.name)
		}
		sline(c, "%s OK %s completed", tag, cmd)

	case "STATUS":
		if len(args) < 2 {
			sline(c, "%s BAD STATUS needs a mailbox and items", tag)
			return true
		}
		b := account_box(s.acct, args[0])
		if b == nil {
			sline(c, "%s NO [TRYCREATE] No such mailbox", tag)
			return true
		}
		parts := make([dynamic]string, 0, 6, context.temp_allocator)
		for it in args[1:] {
			switch strings.to_upper(it, context.temp_allocator) {
			case "MESSAGES":
				append(&parts, fmt.tprintf("MESSAGES %d", box_count(b)))
			case "UNSEEN":
				append(&parts, fmt.tprintf("UNSEEN %d", box_unseen(b)))
			case "UIDNEXT":
				append(&parts, fmt.tprintf("UIDNEXT %d", b.uidnext))
			case "UIDVALIDITY":
				append(&parts, fmt.tprintf("UIDVALIDITY %d", b.uidvalidity))
			case "RECENT":
				append(&parts, fmt.tprintf("RECENT %d", imap_recent(b)))
			}
		}
		sline(c, "* STATUS \"%s\" (%s)", b.name, strings.join(parts[:], " ", context.temp_allocator))
		sline(c, "%s OK STATUS completed", tag)

	case "SELECT", "EXAMINE":
		if len(args) < 1 {
			sline(c, "%s BAD %s needs a mailbox", tag, cmd)
			return true
		}
		b := account_box(s.acct, args[0])
		if b == nil {
			sline(c, "%s NO Mailbox does not exist", tag)
			return true
		}
		s.box = b
		s.read_only = cmd == "EXAMINE"
		s.box_version = b.version
		live := box_live(b, context.temp_allocator)
		sline(c, "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
		sline(c, "* %d EXISTS", len(live))
		sline(c, "* %d RECENT", imap_recent(b))
		for m, i in live {
			if .Seen not_in m.flags {
				sline(c, "* OK [UNSEEN %d] First unseen message", i + 1)
				break
			}
		}
		sline(c, "* OK [UIDVALIDITY %d] UIDs are valid", b.uidvalidity)
		sline(c, "* OK [UIDNEXT %d] Predicted next UID", b.uidnext)
		if s.read_only {
			sline(c, "* OK [PERMANENTFLAGS ()] Read-only mailbox")
			sline(c, "%s OK [READ-ONLY] EXAMINE completed", tag)
		} else {
			sline(c, "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft \\*)] Limited")
			sline(c, "%s OK [READ-WRITE] SELECT completed", tag)
		}

	case "CLOSE", "UNSELECT":
		if s.box != nil && !s.read_only && cmd == "CLOSE" {
			// RFC 3501 6.4.2: CLOSE expunges silently.
			imap_expunge_box(s.acct, s.box, nil)
		}
		s.box = nil
		sline(c, "%s OK %s completed", tag, cmd)

	case "FETCH":
		return imap_fetch_cmd(s, tag, args, false)

	case "STORE":
		return imap_store_cmd(s, tag, args, false)

	case "SEARCH":
		return imap_search_cmd(s, tag, args, false)

	case "UID":
		if len(args) < 1 {
			sline(c, "%s BAD UID needs a subcommand", tag)
			return true
		}
		sub := strings.to_upper(args[0], context.temp_allocator)
		switch sub {
		case "FETCH":
			return imap_fetch_cmd(s, tag, args[1:], true)
		case "STORE":
			return imap_store_cmd(s, tag, args[1:], true)
		case "SEARCH":
			return imap_search_cmd(s, tag, args[1:], true)
		case "EXPUNGE":
			return imap_expunge_cmd(s, tag, args[1:], true)
		}
		sline(c, "%s BAD UID %s is not supported", tag, sub)

	case "EXPUNGE":
		return imap_expunge_cmd(s, tag, nil, false)

	case "APPEND":
		return imap_append_cmd(s, tag, args)

	case "CREATE":
		if len(args) < 1 {
			sline(c, "%s BAD CREATE needs a name", tag)
			return true
		}
		if account_box(s.acct, args[0]) != nil {
			sline(c, "%s NO Mailbox already exists", tag)
			return true
		}
		append(
			&s.acct.boxes,
			Mailbox {
				name = strings.clone(args[0]),
				jid = fmt.aprintf("MB-%s", args[0]),
				uidnext = 1,
				uidvalidity = 1000 + u32(len(s.acct.boxes)),
				msgs = make([dynamic]Message),
			},
		)
		sline(c, "%s OK CREATE completed", tag)

	case "SUBSCRIBE", "UNSUBSCRIBE":
		sline(c, "%s OK %s completed (this server does not track subscriptions)", tag, cmd)

	case "NAMESPACE":
		sline(c, "* NAMESPACE ((\"\" \"%s\")) NIL NIL", HIERARCHY_DELIM)
		sline(c, "%s OK NAMESPACE completed", tag)

	case "IDLE":
		sync.mutex_unlock(&store.mu)
		r := imap_idle_cmd(s, tag)
		sync.mutex_lock(&store.mu)
		return r

	case:
		sline(c, "%s BAD %s is not implemented by this test server", tag, cmd)
	}
	return true
}

imap_recent :: proc(b: ^Mailbox) -> (n: int) {
	for m in b.msgs {
		if !m.expunged && .Recent in m.flags {
			n += 1
		}
	}
	return
}

imap_box_attrs :: proc(a: ^Account, b: ^Mailbox) -> string {
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	switch strings.to_lower(b.role, context.temp_allocator) {
	case "sent":
		append(&parts, "\\Sent")
	case "trash":
		append(&parts, "\\Trash")
	case "drafts":
		append(&parts, "\\Drafts")
	case "archive":
		append(&parts, "\\Archive")
	case "junk":
		append(&parts, "\\Junk")
	}
	has_kids := false
	prefix := strings.concatenate({b.name, HIERARCHY_DELIM}, context.temp_allocator)
	for i in 0 ..< len(a.boxes) {
		if a.boxes[i].name != b.name && strings.has_prefix(a.boxes[i].name, prefix) {
			has_kids = true
		}
	}
	append(&parts, has_kids ? "\\HasChildren" : "\\HasNoChildren")
	return strings.join(parts[:], " ", context.temp_allocator)
}

// imap_match implements the '*' and '%' wildcards of RFC 3501 6.3.8.
imap_match :: proc(pattern, name: string) -> bool {
	return imap_match_at(pattern, name, 0, 0)
}

@(private = "file")
imap_match_at :: proc(p, n: string, pi_in, ni_in: int) -> bool {
	pi, ni := pi_in, ni_in
	for pi < len(p) {
		switch p[pi] {
		case '*':
			for k := ni; k <= len(n); k += 1 {
				if imap_match_at(p, n, pi + 1, k) {
					return true
				}
			}
			return false
		case '%':
			// '%' matches anything except the hierarchy delimiter.
			for k := ni; k <= len(n); k += 1 {
				if k > ni && n[k - 1] == HIERARCHY_DELIM[0] {
					break
				}
				if imap_match_at(p, n, pi + 1, k) {
					return true
				}
			}
			return false
		case:
			if ni >= len(n) || n[ni] != p[pi] {
				return false
			}
			pi += 1
			ni += 1
		}
	}
	return ni == len(n)
}

// ---------------------------------------------------------------------------
// Sequence sets
// ---------------------------------------------------------------------------

// imap_seq_match reports whether `value` is in a set like "1,3:5,8:*".
imap_seq_match :: proc(set: string, value: u32, max_value: u32) -> bool {
	for part in strings.split(set, ",", context.temp_allocator) {
		p := strings.trim_space(part)
		if p == "" {
			continue
		}
		if colon := strings.index_byte(p, ':'); colon >= 0 {
			lo_s := p[:colon]
			hi_s := p[colon + 1:]
			lo := lo_s == "*" ? max_value : u32(parse_u32(lo_s))
			hi := hi_s == "*" ? max_value : u32(parse_u32(hi_s))
			if lo > hi {lo, hi = hi, lo}
			if value >= lo && value <= hi {
				return true
			}
			continue
		}
		if p == "*" {
			if value == max_value {
				return true
			}
			continue
		}
		if u32(parse_u32(p)) == value {
			return true
		}
	}
	return false
}

parse_u32 :: proc(s: string) -> int {
	n, _ := strconv.parse_int(strings.trim_space(s), 10)
	return n
}

// imap_selected gathers the messages a command applies to, with their sequence
// numbers, resolving either a UID set or a sequence set.
Sel :: struct {
	seq: int,
	m:   ^Message,
}

imap_selected :: proc(b: ^Mailbox, set: string, by_uid: bool) -> []Sel {
	live := box_live(b, context.temp_allocator)
	out := make([dynamic]Sel, 0, len(live), context.temp_allocator)
	max_seq := u32(len(live))
	max_uid: u32 = 0
	for m in live {
		if m.uid > max_uid {max_uid = m.uid}
	}
	for m, i in live {
		v := by_uid ? m.uid : u32(i + 1)
		if imap_seq_match(set, v, by_uid ? max_uid : max_seq) {
			append(&out, Sel{seq = i + 1, m = m})
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// FETCH
// ---------------------------------------------------------------------------

imap_fetch_cmd :: proc(s: ^Imap_Session, tag: string, args: []string, by_uid: bool) -> bool {
	c := s.c
	if s.box == nil {
		sline(c, "%s BAD No mailbox selected", tag)
		return true
	}
	if len(args) < 2 {
		sline(c, "%s BAD FETCH needs a set and items", tag)
		return true
	}
	set := args[0]
	// The item list arrives either as a bare atom or as ( ... ).
	items := make([dynamic]string, 0, 8, context.temp_allocator)
	if args[1] == "(" {
		for a in args[2:] {
			if a == ")" {
				break
			}
			append(&items, a)
		}
	} else {
		append(&items, args[1])
	}
	// The RFC 3501 macros.
	if len(items) == 1 {
		switch strings.to_upper(items[0], context.temp_allocator) {
		case "ALL":
			clear(&items)
			append(&items, "FLAGS", "INTERNALDATE", "RFC822.SIZE", "ENVELOPE")
		case "FAST":
			clear(&items)
			append(&items, "FLAGS", "INTERNALDATE", "RFC822.SIZE")
		case "FULL":
			clear(&items)
			append(&items, "FLAGS", "INTERNALDATE", "RFC822.SIZE", "ENVELOPE", "BODY")
		}
	}

	sel := imap_selected(s.box, set, by_uid)
	for e in sel {
		imap_emit_fetch(s, e, items[:], by_uid)
	}
	sline(c, "%s OK %sFETCH completed", tag, by_uid ? "UID " : "")
	return true
}

imap_emit_fetch :: proc(s: ^Imap_Session, e: Sel, items: []string, by_uid: bool) {
	c := s.c
	m := e.m
	// Responses are assembled into one buffer so that a literal and its
	// surrounding text go out together.
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "* %d FETCH (", e.seq)
	first := true
	// A UID FETCH must include the UID whether or not it was asked for
	// (RFC 3501 6.4.8).
	need_uid := by_uid
	for it in items {
		if strings.equal_fold(it, "UID") {need_uid = false}
	}
	sep :: proc(sb: ^strings.Builder, first: ^bool) {
		if !first^ {strings.write_byte(sb, ' ')}
		first^ = false
	}
	if need_uid {
		sep(&sb, &first)
		fmt.sbprintf(&sb, "UID %d", m.uid)
	}

	mark_seen := false
	for it in items {
		up := strings.to_upper(it, context.temp_allocator)
		sep(&sb, &first)
		switch {
		case up == "UID":
			fmt.sbprintf(&sb, "UID %d", m.uid)
		case up == "FLAGS":
			fmt.sbprintf(&sb, "FLAGS (%s)", flags_to_imap(m.flags, context.temp_allocator))
		case up == "INTERNALDATE":
			fmt.sbprintf(&sb, "INTERNALDATE \"%s\"", m.internaldate)
		case up == "RFC822.SIZE":
			fmt.sbprintf(&sb, "RFC822.SIZE %d", len(m.raw))
		case up == "ENVELOPE":
			strings.write_string(&sb, "ENVELOPE ")
			mm_envelope(m.raw, &sb)
		case up == "BODYSTRUCTURE", up == "BODY":
			root := mm_parse(m.raw, "", 0, context.temp_allocator)
			strings.write_string(&sb, up == "BODY" ? "BODY " : "BODYSTRUCTURE ")
			mm_bodystructure(&root, &sb, up == "BODYSTRUCTURE")
		case up == "RFC822":
			imap_write_literal(&sb, "RFC822", m.raw)
			mark_seen = true
		case up == "RFC822.HEADER":
			hdr := imap_headers_of(m.raw)
			imap_write_literal(&sb, "RFC822.HEADER", hdr)
		case up == "RFC822.TEXT":
			body := imap_body_of(m.raw)
			imap_write_literal(&sb, "RFC822.TEXT", body)
			mark_seen = true
		case strings.has_prefix(up, "BODY["), strings.has_prefix(up, "BODY.PEEK["):
			peek := strings.has_prefix(up, "BODY.PEEK[")
			open := strings.index_byte(it, '[')
			close := strings.last_index_byte(it, ']')
			if open < 0 || close < open {
				strings.write_string(&sb, "NIL")
				break
			}
			section := it[open + 1:close]
			data, label := imap_section_data(m, section, peek)
			imap_write_literal(&sb, label, data)
			if !peek {
				mark_seen = true
			}
		case:
			fmt.sbprintf(&sb, "%s NIL", up)
		}
	}
	strings.write_byte(&sb, ')')
	slog(c, "-> %s", "(fetch response with literals)")
	swrite_str(c, strings.to_string(sb))
	swrite_str(c, "\r\n")

	if mark_seen && !s.read_only && .Seen not_in m.flags {
		m.flags |= {.Seen}
		s.box.version += 1
		account_bump(s.acct, m.jid, .Updated)
		sline(c, "* %d FETCH (FLAGS (%s))", e.seq, flags_to_imap(m.flags, context.temp_allocator))
	}
}

// imap_write_literal is the whole reason this server exists: every piece of
// message data goes out as a counted literal, never as a quoted string.
imap_write_literal :: proc(sb: ^strings.Builder, name: string, data: []u8) {
	fmt.sbprintf(sb, "%s {{%d}}\r\n", name, len(data))
	strings.write_bytes(sb, data)
}

imap_headers_of :: proc(raw: []u8) -> []u8 {
	for i in 0 ..< len(raw) {
		if raw[i] == '\n' {
			if i + 1 < len(raw) && raw[i + 1] == '\n' {
				return raw[:i + 2]
			}
			if i + 2 < len(raw) && raw[i + 1] == '\r' && raw[i + 2] == '\n' {
				return raw[:i + 3]
			}
		}
	}
	return raw
}

imap_body_of :: proc(raw: []u8) -> []u8 {
	h := imap_headers_of(raw)
	if len(h) >= len(raw) {
		return raw[len(raw):]
	}
	return raw[len(h):]
}

// imap_section_data resolves a BODY[...] section specifier.
imap_section_data :: proc(m: ^Message, section: string, peek: bool) -> (data: []u8, label: string) {
	name := peek ? "BODY" : "BODY" // the response always says BODY, never BODY.PEEK
	up := strings.to_upper(strings.trim_space(section), context.temp_allocator)
	switch {
	case up == "":
		return m.raw, fmt.tprintf("%s[]", name)
	case up == "HEADER":
		return imap_headers_of(m.raw), fmt.tprintf("%s[HEADER]", name)
	case up == "TEXT":
		return imap_body_of(m.raw), fmt.tprintf("%s[TEXT]", name)
	case strings.has_prefix(up, "HEADER.FIELDS.NOT"):
		fields := imap_field_list(section)
		return imap_filter_headers(m.raw, fields, true), fmt.tprintf("%s[%s]", name, section)
	case strings.has_prefix(up, "HEADER.FIELDS"):
		fields := imap_field_list(section)
		return imap_filter_headers(m.raw, fields, false), fmt.tprintf("%s[%s]", name, section)
	}
	// A numeric part specifier, possibly with .MIME / .HEADER / .TEXT.
	root := mm_parse(m.raw, "", 0, context.temp_allocator)
	spec := strings.trim_space(section)
	suffix := ""
	for sfx in ([?]string{".MIME", ".HEADER", ".TEXT"}) {
		if strings.has_suffix(up, sfx) {
			suffix = sfx
			spec = spec[:len(spec) - len(sfx)]
			break
		}
	}
	p := mm_find(&root, spec)
	if p == nil {
		return []u8{}, fmt.tprintf("%s[%s]", name, section)
	}
	switch suffix {
	case ".TEXT":
		return p.raw_body, fmt.tprintf("%s[%s]", name, section)
	case ".HEADER", ".MIME":
		// The part's own MIME headers. Recovering them from the raw bytes
		// would need offsets this minimal parser does not keep, so the server
		// returns the part body's headers when it is a message/rfc822 and an
		// empty section otherwise. Documented, not hidden.
		if p.main == "message" && len(p.parts) > 0 {
			return imap_headers_of(p.decoded), fmt.tprintf("%s[%s]", name, section)
		}
		return []u8{}, fmt.tprintf("%s[%s]", name, section)
	}
	return p.raw_body, fmt.tprintf("%s[%s]", name, section)
}

mm_find :: proc(p: ^MM_Part, spec: string) -> ^MM_Part {
	if p.section == spec {
		return p
	}
	for i in 0 ..< len(p.parts) {
		if r := mm_find(&p.parts[i], spec); r != nil {
			return r
		}
	}
	return nil
}

imap_field_list :: proc(section: string) -> []string {
	open := strings.index_byte(section, '(')
	close := strings.last_index_byte(section, ')')
	if open < 0 || close < open {
		return nil
	}
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	for f in strings.fields(section[open + 1:close], context.temp_allocator) {
		append(&out, strings.to_lower(strings.trim(f, "\""), context.temp_allocator))
	}
	return out[:]
}

imap_filter_headers :: proc(raw: []u8, fields: []string, invert: bool) -> []u8 {
	hdr := imap_headers_of(raw)
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(hdr) {
		start := i
		// One logical header, including continuations.
		for {
			for i < len(hdr) && hdr[i] != '\n' {i += 1}
			if i < len(hdr) {i += 1}
			if i >= len(hdr) || (hdr[i] != ' ' && hdr[i] != '\t') {
				break
			}
		}
		chunk := string(hdr[start:i])
		trimmed := strings.trim_space(chunk)
		if trimmed == "" {
			continue
		}
		colon := strings.index_byte(chunk, ':')
		if colon <= 0 {
			continue
		}
		nm := strings.to_lower(strings.trim_space(chunk[:colon]), context.temp_allocator)
		found := false
		for f in fields {
			if f == nm {found = true;break}
		}
		if found != invert {
			strings.write_string(&sb, chunk)
		}
	}
	strings.write_string(&sb, "\r\n")
	return transmute([]u8)strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// STORE / EXPUNGE / SEARCH / APPEND
// ---------------------------------------------------------------------------

imap_store_cmd :: proc(s: ^Imap_Session, tag: string, args: []string, by_uid: bool) -> bool {
	c := s.c
	if s.box == nil {
		sline(c, "%s BAD No mailbox selected", tag)
		return true
	}
	if s.read_only {
		sline(c, "%s NO Mailbox is read-only", tag)
		return true
	}
	if len(args) < 3 {
		sline(c, "%s BAD STORE needs a set, an item and flags", tag)
		return true
	}
	set := args[0]
	op := strings.to_upper(args[1], context.temp_allocator)
	silent := strings.has_suffix(op, ".SILENT")
	if silent {
		op = op[:len(op) - len(".SILENT")]
	}
	flag_args := args[2:]
	if len(flag_args) > 0 && flag_args[0] == "(" {
		end := len(flag_args)
		for a, i in flag_args {
			if a == ")" {end = i;break}
		}
		flag_args = flag_args[1:end]
	}
	newf: Flags
	for f in flag_args {
		if fl, ok := flag_from_imap(f); ok {
			newf |= {fl}
		}
	}

	sel := imap_selected(s.box, set, by_uid)
	for e in sel {
		switch op {
		case "FLAGS":
			// \Recent is never settable by a client.
			keep := e.m.flags & {.Recent}
			e.m.flags = newf - {.Recent} + keep
		case "+FLAGS":
			e.m.flags |= newf - {.Recent}
		case "-FLAGS":
			e.m.flags &~= newf - {.Recent}
		case:
			sline(c, "%s BAD Unknown STORE item %s", tag, op)
			return true
		}
		s.box.version += 1
		account_bump(s.acct, e.m.jid, .Updated)
		if !silent {
			if by_uid {
				sline(
					c,
					"* %d FETCH (UID %d FLAGS (%s))",
					e.seq,
					e.m.uid,
					flags_to_imap(e.m.flags, context.temp_allocator),
				)
			} else {
				sline(c, "* %d FETCH (FLAGS (%s))", e.seq, flags_to_imap(e.m.flags, context.temp_allocator))
			}
		}
	}
	sline(c, "%s OK %sSTORE completed", tag, by_uid ? "UID " : "")
	return true
}

imap_expunge_cmd :: proc(s: ^Imap_Session, tag: string, args: []string, by_uid: bool) -> bool {
	c := s.c
	if s.box == nil {
		sline(c, "%s BAD No mailbox selected", tag)
		return true
	}
	if s.read_only {
		sline(c, "%s NO Mailbox is read-only", tag)
		return true
	}
	limit := by_uid && len(args) > 0 ? args[0] : ""
	seqs := imap_expunge_box(s.acct, s.box, limit == "" ? nil : &limit)
	// RFC 3501 6.4.3: the untagged EXPUNGE responses renumber as they go, so
	// they must be sent highest-first or the client's own renumbering breaks.
	#reverse for sq in seqs {
		sline(c, "* %d EXPUNGE", sq)
	}
	sline(c, "* %d EXISTS", box_count(s.box))
	sline(c, "%s OK %sEXPUNGE completed", tag, by_uid ? "UID " : "")
	return true
}

imap_expunge_box :: proc(a: ^Account, b: ^Mailbox, uid_set: ^string) -> []int {
	live := box_live(b, context.temp_allocator)
	out := make([dynamic]int, 0, 8, context.temp_allocator)
	max_uid: u32 = 0
	for m in live {
		if m.uid > max_uid {max_uid = m.uid}
	}
	for m, i in live {
		if .Deleted not_in m.flags {
			continue
		}
		if uid_set != nil && !imap_seq_match(uid_set^, m.uid, max_uid) {
			continue
		}
		m.expunged = true
		append(&out, i + 1)
		account_bump(a, m.jid, .Destroyed)
	}
	if len(out) > 0 {
		b.version += 1
	}
	return out[:]
}

imap_search_cmd :: proc(s: ^Imap_Session, tag: string, args: []string, by_uid: bool) -> bool {
	c := s.c
	if s.box == nil {
		sline(c, "%s BAD No mailbox selected", tag)
		return true
	}
	live := box_live(s.box, context.temp_allocator)
	hits := make([dynamic]u32, 0, len(live), context.temp_allocator)

	// The supported keys: ALL, UNSEEN, SEEN, FLAGGED, UNFLAGGED, ANSWERED,
	// DELETED, NEW, RECENT, SUBJECT <s>, FROM <s>, TO <s>, BODY <s>, TEXT <s>,
	// HEADER <name> <s>, LARGER <n>, SMALLER <n>, UID <set>, and a bare set.
	// Keys are ANDed, which is the RFC 3501 default.
	for m, i in live {
		if imap_search_match(m, args) {
			append(&hits, by_uid ? m.uid : u32(i + 1))
		}
	}
	parts := make([dynamic]string, 0, len(hits), context.temp_allocator)
	for h in hits {
		append(&parts, fmt.tprintf("%d", h))
	}
	if len(parts) == 0 {
		sline(c, "* SEARCH")
	} else {
		sline(c, "* SEARCH %s", strings.join(parts[:], " ", context.temp_allocator))
	}
	sline(c, "%s OK %sSEARCH completed", tag, by_uid ? "UID " : "")
	return true
}

imap_search_match :: proc(m: ^Message, args: []string) -> bool {
	lower_raw := strings.to_lower(string(m.raw), context.temp_allocator)
	hdr := strings.to_lower(string(imap_headers_of(m.raw)), context.temp_allocator)
	body := strings.to_lower(string(imap_body_of(m.raw)), context.temp_allocator)
	i := 0
	for i < len(args) {
		key := strings.to_upper(args[i], context.temp_allocator)
		need :: proc(args: []string, i: int) -> string {
			return i + 1 < len(args) ? args[i + 1] : ""
		}
		switch key {
		case "ALL":
			i += 1
		case "CHARSET":
			i += 2 // the charset name is accepted and ignored (we only do UTF-8)
		case "SEEN":
			if .Seen not_in m.flags {return false}
			i += 1
		case "UNSEEN":
			if .Seen in m.flags {return false}
			i += 1
		case "FLAGGED":
			if .Flagged not_in m.flags {return false}
			i += 1
		case "UNFLAGGED":
			if .Flagged in m.flags {return false}
			i += 1
		case "ANSWERED":
			if .Answered not_in m.flags {return false}
			i += 1
		case "UNANSWERED":
			if .Answered in m.flags {return false}
			i += 1
		case "DELETED":
			if .Deleted not_in m.flags {return false}
			i += 1
		case "UNDELETED":
			if .Deleted in m.flags {return false}
			i += 1
		case "DRAFT":
			if .Draft not_in m.flags {return false}
			i += 1
		case "RECENT":
			if .Recent not_in m.flags {return false}
			i += 1
		case "NEW":
			if .Recent not_in m.flags || .Seen in m.flags {return false}
			i += 1
		case "SUBJECT":
			if !strings.contains(hdr, strings.to_lower(need(args, i), context.temp_allocator)) {return false}
			i += 2
		case "FROM", "TO", "CC", "BCC":
			if !strings.contains(hdr, strings.to_lower(need(args, i), context.temp_allocator)) {return false}
			i += 2
		case "BODY":
			if !strings.contains(body, strings.to_lower(need(args, i), context.temp_allocator)) {return false}
			i += 2
		case "TEXT":
			if !strings.contains(lower_raw, strings.to_lower(need(args, i), context.temp_allocator)) {return false}
			i += 2
		case "HEADER":
			nm := i + 1 < len(args) ? strings.to_lower(args[i + 1], context.temp_allocator) : ""
			val := i + 2 < len(args) ? strings.to_lower(args[i + 2], context.temp_allocator) : ""
			if !strings.contains(hdr, nm) || (val != "" && !strings.contains(hdr, val)) {return false}
			i += 3
		case "LARGER":
			if len(m.raw) <= parse_u32(need(args, i)) {return false}
			i += 2
		case "SMALLER":
			if len(m.raw) >= parse_u32(need(args, i)) {return false}
			i += 2
		case "UID":
			if !imap_seq_match(need(args, i), m.uid, m.uid) {return false}
			i += 2
		case "NOT":
			// One-key NOT.
			if i + 1 < len(args) && imap_search_match(m, args[i + 1:i + 2]) {return false}
			i += 2
		case:
			// A bare sequence set, or something unsupported: a set matches,
			// anything else is skipped rather than failing the whole search.
			if len(key) > 0 && (key[0] >= '0' && key[0] <= '9' || key[0] == '*') {
				if !imap_seq_match(args[i], m.uid, m.uid) {return false}
			}
			i += 1
		}
	}
	return true
}

imap_append_cmd :: proc(s: ^Imap_Session, tag: string, args: []string) -> bool {
	c := s.c
	if len(args) < 2 {
		sline(c, "%s BAD APPEND needs a mailbox and a message", tag)
		return true
	}
	box_name := args[0]
	b := account_box(s.acct, box_name)
	if b == nil {
		sline(c, "%s NO [TRYCREATE] No such mailbox", tag)
		return true
	}
	// The literal is the last token; flags, if any, are between.
	msg := args[len(args) - 1]
	flags: Flags
	for a in args[1:len(args) - 1] {
		if fl, ok := flag_from_imap(a); ok {
			flags |= {fl}
		}
	}
	raw := make([]u8, len(msg))
	copy(raw, transmute([]u8)msg)
	now := store_now()
	m := store_deliver(s.acct, b, raw, flags - {.Recent}, mm_derive_decomp(raw, now))
	sline(c, "%s OK [APPENDUID %d %d] APPEND completed", tag, b.uidvalidity, m.uid)
	return true
}

// ---------------------------------------------------------------------------
// IDLE
// ---------------------------------------------------------------------------

// imap_idle_cmd is a real IDLE: the session watches the mailbox's version
// counter, which every other front end bumps when it changes anything, and
// pushes untagged responses as they happen. It returns when the client sends
// DONE.
imap_idle_cmd :: proc(s: ^Imap_Session, tag: string) -> bool {
	c := s.c
	sline(c, "+ idling")
	for c.open {
		// Watch for changes with a short poll so that both the socket and the
		// store get attention.
		if sconn_readable(c, 100) {
			line, ok := sread_line(c, 1000)
			if !ok {
				return false
			}
			if strings.equal_fold(strings.trim_space(line), "DONE") {
				sline(c, "%s OK IDLE terminated", tag)
				return true
			}
			sline(c, "%s BAD Expected DONE", tag)
			return true
		}
		sync.mutex_lock(&store.mu)
		if s.box != nil && s.box.version != s.box_version {
			s.box_version = s.box.version
			n := box_count(s.box)
			r := imap_recent(s.box)
			sync.mutex_unlock(&store.mu)
			sline(c, "* %d EXISTS", n)
			sline(c, "* %d RECENT", r)
			continue
		}
		sync.mutex_unlock(&store.mu)
	}
	return false
}
