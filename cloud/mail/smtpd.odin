package main

// SMTP, in two roles on two ports.
//
// MX (the receiver, RFC 5321 subset). Mail arriving for this server's own
// domains. There is no AUTH and no relaying: RCPT TO for any domain that is
// not local is refused with 550 5.7.1, and an unknown local mailbox with
// 550 5.1.1. Accepted mail is handed to `mail_deliver`, a definer function
// that only ever inserts into inboxes, called with the service-role token.
//
// SUBMISSION (RFC 6409 subset). A person sending as one of their identities.
// AUTH PLAIN or LOGIN, where the username is the identity's address and the
// password is the Supabase access token; the session is then that token, and
// `mail_submit` runs as it, so RLS decides whether the token may send as that
// identity. MAIL FROM must be the identity's address. Any recipient is
// accepted, but only local ones are delivered: every other recipient is put
// in the sender's Outbox as `held — outbound delivery is not enabled`, and the
// final reply says so. Nothing in this file, or anywhere in this server, opens
// a connection to another mail server.
//
// IMPLEMENTED: EHLO, HELO, MAIL (with SIZE), RCPT, DATA (dot-unstuffing,
// size cap), RSET, NOOP, VRFY (252), HELP, QUIT, AUTH PLAIN/LOGIN on the
// submission port, ENHANCEDSTATUSCODES, 8BITMIME, PIPELINING (by virtue of
// reading line by line).
// NOT IMPLEMENTED: STARTTLS (TLS terminates in front, see cloud/docs/mail.md),
// BDAT/CHUNKING, SMTPUTF8, DSN, BURL; SPF/DKIM/DMARC checks on inbound (the
// Resend plan does those before mail reaches this schema).

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

SMTP_MAX_SIZE :: 25 * 1024 * 1024

Smtp_Role :: enum {
	MX,
	Submission,
}

Smtp_Session :: struct {
	c:         ^SConn,
	role:      Smtp_Role,
	helo:      string,
	// Submission: who is sending.
	token:     string,
	identity:  string, // uuid
	address:   string, // the identity's address
	from:      string,
	have_from: bool,
	rcpts:     [dynamic]string,
}

smtpd_serve :: proc(c: ^SConn, role: Smtp_Role) {
	s := Smtp_Session {
		c     = c,
		role  = role,
		rcpts = make([dynamic]string),
	}
	defer delete(s.rcpts)
	defer delete(s.token)
	defer delete(s.identity)
	defer delete(s.address)
	sline(c, "220 %s ESMTP Palmframe mail (%s; local delivery only, no relay)", cfg.domain, role == .MX ? "MX" : "submission")
	for c.open {
		line, ok := sread_line(c)
		if !ok {
			return
		}
		slog(c, "<- %s", strings.has_prefix(strings.to_upper(line, context.temp_allocator), "AUTH") ? "AUTH ..." : line)
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			sline(c, "500 5.5.2 Empty command")
			continue
		}
		verb := trimmed
		rest := ""
		if sp := strings.index_byte(trimmed, ' '); sp >= 0 {
			verb = trimmed[:sp]
			rest = strings.trim_space(trimmed[sp + 1:])
		}
		keep := smtpd_dispatch(&s, strings.to_upper(verb, context.temp_allocator), rest)
		free_all(context.temp_allocator)
		if !keep {
			return
		}
	}
}

smtpd_reset :: proc(s: ^Smtp_Session) {
	delete(s.from)
	s.from = ""
	s.have_from = false
	for r in s.rcpts {delete(r)}
	clear(&s.rcpts)
}

smtpd_dispatch :: proc(s: ^Smtp_Session, verb, rest: string) -> bool {
	c := s.c
	switch verb {
	case "EHLO":
		delete(s.helo)
		s.helo = strings.clone(rest)
		smtpd_reset(s)
		sline(c, "250-%s greets %s", cfg.domain, rest == "" ? "an anonymous client" : rest)
		sline(c, "250-SIZE %d", SMTP_MAX_SIZE)
		sline(c, "250-8BITMIME")
		sline(c, "250-PIPELINING")
		if s.role == .Submission {
			sline(c, "250-AUTH PLAIN LOGIN")
		}
		sline(c, "250 ENHANCEDSTATUSCODES")

	case "HELO":
		delete(s.helo)
		s.helo = strings.clone(rest)
		smtpd_reset(s)
		sline(c, "250 %s", cfg.domain)

	case "STARTTLS":
		sline(c, "454 4.7.0 TLS is terminated in front of this server, not by it")

	case "AUTH":
		if s.role != .Submission {
			sline(c, "503 5.5.1 AUTH is offered on the submission port only")
			return true
		}
		if s.token != "" {
			sline(c, "503 5.5.1 Already authenticated")
			return true
		}
		return smtpd_auth(s, rest)

	case "MAIL":
		if s.role == .Submission && s.token == "" {
			sline(c, "530 5.7.0 Authentication required")
			return true
		}
		if !strings.has_prefix(strings.to_upper(rest, context.temp_allocator), "FROM:") {
			sline(c, "501 5.5.4 Syntax: MAIL FROM:<address>")
			return true
		}
		addr, params := smtpd_path(rest[5:])
		for p in params {
			if strings.has_prefix(strings.to_upper(p, context.temp_allocator), "SIZE=") {
				if n, ok := strconv.parse_int(p[5:], 10); ok && n > SMTP_MAX_SIZE {
					sline(c, "552 5.3.4 Message size exceeds the %d octet limit", SMTP_MAX_SIZE)
					return true
				}
			}
		}
		if s.role == .Submission && addr != s.address {
			sline(c, "550 5.7.1 <%s> is not the address of the authenticated identity <%s>", addr, s.address)
			return true
		}
		smtpd_reset(s)
		s.from = strings.clone(addr)
		s.have_from = true
		sline(c, "250 2.1.0 Sender ok")

	case "RCPT":
		if !s.have_from {
			sline(c, "503 5.5.1 Need MAIL before RCPT")
			return true
		}
		if !strings.has_prefix(strings.to_upper(rest, context.temp_allocator), "TO:") {
			sline(c, "501 5.5.4 Syntax: RCPT TO:<address>")
			return true
		}
		addr, _ := smtpd_path(rest[3:])
		at := strings.last_index_byte(addr, '@')
		if addr == "" || at <= 0 || at == len(addr) - 1 {
			sline(c, "501 5.1.3 Bad recipient address syntax")
			return true
		}
		if len(s.rcpts) >= 100 {
			sline(c, "452 4.5.3 Too many recipients")
			return true
		}
		local, lerr := addr_is_local(addr)
		if lerr != "" {
			sline(c, "451 4.3.0 Temporary failure: %s", lerr)
			return true
		}
		if !local {
			if s.role == .MX {
				// The safety behaviour: this server is the destination for
				// its own domains and nothing else.
				sline(c, "550 5.7.1 <%s>: relaying denied; this server delivers to %s only", addr, cfg.domain)
				return true
			}
			append(&s.rcpts, strings.clone(addr))
			sline(c, "250 2.1.5 <%s> accepted, but will be HELD in your Outbox: outbound delivery is not enabled", addr)
			return true
		}
		known, kerr := addr_exists(addr)
		if kerr != "" {
			sline(c, "451 4.3.0 Temporary failure: %s", kerr)
			return true
		}
		if !known {
			sline(c, "550 5.1.1 <%s>: no such mailbox here", addr)
			return true
		}
		append(&s.rcpts, strings.clone(addr))
		sline(c, "250 2.1.5 Recipient ok")

	case "DATA":
		if !s.have_from {
			sline(c, "503 5.5.1 Need MAIL before DATA")
			return true
		}
		if len(s.rcpts) == 0 {
			sline(c, "503 5.5.1 Need RCPT before DATA")
			return true
		}
		sline(c, "354 End data with <CR><LF>.<CR><LF>")
		raw, too_big, ok := smtpd_read_data(c)
		if !ok {
			return false
		}
		defer delete(raw)
		if too_big {
			sline(c, "552 5.3.4 Message too large")
			smtpd_reset(s)
			return true
		}
		smtpd_finish(s, raw)
		smtpd_reset(s)

	case "RSET":
		smtpd_reset(s)
		sline(c, "250 2.0.0 Reset")

	case "NOOP":
		sline(c, "250 2.0.0 OK")

	case "VRFY", "EXPN":
		sline(c, "252 2.5.2 Cannot VRFY, but will accept RCPT and attempt delivery")

	case "HELP":
		sline(c, "214 2.0.0 EHLO HELO %sMAIL RCPT DATA RSET NOOP VRFY QUIT", s.role == .Submission ? "AUTH " : "")

	case "QUIT":
		sline(c, "221 2.0.0 %s closing connection", cfg.domain)
		return false

	case:
		sline(c, "500 5.5.2 Unrecognised command %s", verb)
	}
	return true
}

smtpd_finish :: proc(s: ^Smtp_Session, raw_in: []u8) {
	c := s.c
	raw := raw_in
	if s.role == .Submission {
		// RFC 6409 8: a submission server may add a missing Date and
		// Message-ID. Bcc is removed from what recipients see.
		raw = submission_fixup(raw, s.address)
	}
	full := add_received(raw, s.helo, s.role == .Submission ? "ESMTPA" : "ESMTP", s.rcpts[0])
	sum := summarise(full)
	meta := summary_meta(sum)
	rc := strings.builder_make(context.temp_allocator)
	strings.write_byte(&rc, '[')
	for r, i in s.rcpts {
		if i > 0 {strings.write_byte(&rc, ',')}
		strings.write_string(&rc, jq(r))
	}
	strings.write_byte(&rc, ']')

	if s.role == .MX {
		args := fmt.tprintf(`{{"p_raw":%s,"p_meta":%s,"p_rcpts":%s}}`, jq(bytea_encode(full)), meta, strings.to_string(rc))
		r := rest_rpc(cfg.service_token, "mail_deliver", args)
		if !rest_ok(r) {
			sline(c, "451 4.3.0 Delivery failed: %s", r.err)
			return
		}
		n := 0
		for e in r.value.(json.Array) or_else nil {
			if jstr(e, "status") == "delivered" {n += 1}
		}
		sline(c, "250 2.0.0 Delivered to %d local recipient(s)", n)
		log_line("mx: %d octets from <%s>, delivered to %d", len(full), s.from, n)
		return
	}

	args := fmt.tprintf(
		`{{"p_identity":%s,"p_raw":%s,"p_meta":%s,"p_rcpts":%s}}`,
		jq(s.identity),
		jq(bytea_encode(full)),
		meta,
		strings.to_string(rc),
	)
	r := rest_rpc(s.token, "mail_submit", args)
	if !rest_ok(r) {
		code := r.code == "42501" ? "550 5.7.1" : (r.code == "54000" ? "451 4.7.1" : "451 4.3.0")
		sline(c, "%s Submission refused: %s", code, r.err)
		return
	}
	delivered, held := 0, 0
	for e in jarr(r.value, "recipients") {
		switch jstr(e, "status") {
		case "delivered":
			delivered += 1
		case "held":
			held += 1
		}
	}
	if held > 0 {
		sline(c, "250 2.0.0 Delivered to %d local recipient(s); %d HELD in Outbox, NOT SENT: outbound delivery is not enabled", delivered, held)
	} else {
		sline(c, "250 2.0.0 Delivered to %d local recipient(s)", delivered)
	}
	log_line("submit: %s -> %d delivered, %d held", s.address, delivered, held)
}

// submission_fixup adds Date and Message-ID when missing and drops Bcc.
submission_fixup :: proc(raw: []u8, from: string) -> []u8 {
	headers, body := mm_split(raw, context.temp_allocator)
	_, has_date := mm_get(headers, "date")
	_, has_id := mm_get(headers, "message-id")
	hdr_end := len(raw) - len(body)
	sb := strings.builder_make(context.temp_allocator)
	if !has_date {
		fmt.sbprintf(&sb, "Date: %s\r\n", rfc5322_date_now())
	}
	if !has_id {
		fmt.sbprintf(&sb, "Message-ID: <%s@%s>\r\n", new_token_hex(12), cfg.domain)
	}
	// Copy the header block line by line, skipping Bcc and its folds.
	head := string(raw[:hdr_end])
	skipping := false
	rest := head
	for line in strings.split_after_iterator(&rest, "\n") {
		if len(line) > 0 && (line[0] == ' ' || line[0] == '\t') {
			if !skipping {strings.write_string(&sb, line)}
			continue
		}
		skipping = strings.has_prefix(strings.to_lower(line, context.temp_allocator), "bcc:")
		if !skipping {strings.write_string(&sb, line)}
	}
	strings.write_bytes(&sb, body)
	return transmute([]u8)strings.to_string(sb)
}

add_received :: proc(raw: []u8, helo, with: string, rcpt: string) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		"Received: from %s (localhost [127.0.0.1])\r\n\tby %s (palm-maild) with %s\r\n\tfor <%s>; %s\r\n",
		helo == "" ? "unknown" : helo,
		cfg.domain,
		with,
		rcpt,
		rfc5322_date_now(),
	)
	strings.write_bytes(&sb, raw)
	return transmute([]u8)strings.to_string(sb)
}

// smtpd_path pulls the address out of `<addr> PARAM=value ...`, lowercased.
smtpd_path :: proc(s: string) -> (addr: string, params: []string) {
	t := strings.trim_space(s)
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	if strings.has_prefix(t, "<") {
		if close := strings.index_byte(t, '>'); close > 0 {
			addr = strings.trim_space(t[1:close])
			for p in strings.fields(t[close + 1:], context.temp_allocator) {
				append(&out, p)
			}
			return strings.to_lower(addr, context.temp_allocator), out[:]
		}
	}
	f := strings.fields(t, context.temp_allocator)
	if len(f) == 0 {
		return "", out[:]
	}
	for p in f[1:] {
		append(&out, p)
	}
	return strings.to_lower(strings.trim(f[0], "<>"), context.temp_allocator), out[:]
}

smtpd_auth :: proc(s: ^Smtp_Session, rest: string) -> bool {
	c := s.c
	f := strings.fields(rest, context.temp_allocator)
	if len(f) == 0 {
		sline(c, "501 5.5.4 AUTH needs a mechanism")
		return true
	}
	switch strings.to_upper(f[0], context.temp_allocator) {
	case "PLAIN":
		blob := ""
		if len(f) > 1 {
			blob = f[1]
		} else {
			sline(c, "334 ")
			line, ok := sread_line(c)
			if !ok {
				return false
			}
			blob = strings.clone(strings.trim_space(line), context.temp_allocator)
		}
		raw := mm_b64_decode(transmute([]u8)blob, context.temp_allocator)
		parts := strings.split(string(raw), "\x00", context.temp_allocator)
		if len(parts) < 3 {
			sline(c, "501 5.5.2 Malformed AUTH PLAIN blob")
			return true
		}
		return smtpd_finish_auth(s, parts[1], parts[2])
	case "LOGIN":
		user := ""
		if len(f) > 1 {
			// RFC 4954 initial response: the username came with the command.
			user = string(mm_b64_decode(transmute([]u8)f[1], context.temp_allocator))
		} else {
			sline(c, "334 VXNlcm5hbWU6")
			ul, ok1 := sread_line(c)
			if !ok1 {
				return false
			}
			user = string(mm_b64_decode(transmute([]u8)strings.clone(strings.trim_space(ul), context.temp_allocator), context.temp_allocator))
		}
		sline(c, "334 UGFzc3dvcmQ6")
		pl, ok2 := sread_line(c)
		if !ok2 {
			return false
		}
		pass := string(mm_b64_decode(transmute([]u8)strings.clone(strings.trim_space(pl), context.temp_allocator), context.temp_allocator))
		return smtpd_finish_auth(s, user, pass)
	case:
		sline(c, "504 5.5.4 Unrecognised authentication mechanism")
	}
	return true
}

// smtpd_finish_auth: the username is the identity's address, the password a
// Supabase access token. The identity must be one the token can reach.
smtpd_finish_auth :: proc(s: ^Smtp_Session, user, token: string) -> bool {
	c := s.c
	if _, verr := jwt_verify(token, cfg.jwt_secret); verr != "" {
		sline(c, "535 5.7.8 Authentication credentials invalid (%s)", verr)
		return true
	}
	ids, ierr := identities_of(token)
	if ierr != "" {
		sline(c, "454 4.7.0 Temporary authentication failure")
		return true
	}
	want := strings.to_lower(strings.trim_space(user), context.temp_allocator)
	for id in ids {
		if id.address == want {
			s.token = strings.clone(token)
			s.identity = strings.clone(id.id)
			s.address = strings.clone(id.address)
			sline(c, "235 2.7.0 Authenticated as %s", id.address)
			return true
		}
	}
	sline(c, "535 5.7.8 This token cannot send as <%s>", want)
	return true
}

// smtpd_read_data reads the DATA block, undoing dot-stuffing. Lines end in
// CRLF on the way out whatever they ended in on the way in.
smtpd_read_data :: proc(c: ^SConn) -> (raw: []u8, too_big: bool, ok: bool) {
	out := make([dynamic]u8, 0, 8192)
	for {
		line, lok := sread_line(c)
		if !lok {
			delete(out)
			return nil, false, false
		}
		if line == "." {
			return out[:], too_big, true
		}
		if too_big {
			continue
		}
		if len(line) > 0 && line[0] == '.' {
			append(&out, ..transmute([]u8)line[1:])
		} else {
			append(&out, ..transmute([]u8)line)
		}
		append(&out, '\r', '\n')
		if len(out) > SMTP_MAX_SIZE {
			too_big = true
			clear(&out)
		}
	}
}

// ---------------------------------------------------------------------------
// Addressing, through the service role
// ---------------------------------------------------------------------------

addr_is_local :: proc(addr: string) -> (bool, string) {
	r := rest_rpc(cfg.service_token, "mail_is_local", fmt.tprintf(`{{"p_addr":%s}}`, jq(addr)))
	if !rest_ok(r) {
		return false, r.err
	}
	b, _ := r.value.(json.Boolean)
	return bool(b), ""
}

addr_exists :: proc(addr: string) -> (bool, string) {
	r := rest_rpc(cfg.service_token, "mail_resolve", fmt.tprintf(`{{"p_addr":%s}}`, jq(addr)))
	if !rest_ok(r) {
		return false, r.err
	}
	_, is_null := r.value.(json.Null)
	return r.value != nil && !is_null, ""
}
