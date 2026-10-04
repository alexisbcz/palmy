package main

// The SMTP submission front end (RFC 5321), with EHLO, AUTH PLAIN/LOGIN,
// SIZE, 8BITMIME, PIPELINING and dot-unstuffed DATA.
//
// It is a submission server, not a relay: a RCPT TO for an address that is not
// one of this server's synthetic accounts is REFUSED with a 550. There is no
// code path out of this process, no next hop, and no DNS. A message accepted
// here is written into the in-memory store and becomes visible over IMAP,
// POP3 and JMAP; it goes nowhere else, ever.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

SMTP_MAX_SIZE :: 20 * 1024 * 1024

Smtp_Session :: struct {
	c:         ^SConn,
	helo:      string,
	authed_as: ^Account,
	from:      string,
	have_from: bool,
	rcpts:     [dynamic]^Account,
	rcpt_addrs: [dynamic]string,
}

store_now :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

smtpd_serve :: proc(c: ^SConn) {
	s := Smtp_Session {
		c          = c,
		rcpts      = make([dynamic]^Account),
		rcpt_addrs = make([dynamic]string),
	}
	defer delete(s.rcpts)
	defer delete(s.rcpt_addrs)

	sline(c, "220 mailcore.test ESMTP mailcore test server (loopback only, delivers nowhere)")
	for c.open {
		line, ok := sread_line(c)
		if !ok {
			return
		}
		slog(c, "<- %s", line)
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			sline(c, "500 Empty command")
			continue
		}
		verb := trimmed
		rest := ""
		if sp := strings.index_byte(trimmed, ' '); sp >= 0 {
			verb = trimmed[:sp]
			rest = strings.trim_space(trimmed[sp + 1:])
		}
		if !smtpd_dispatch(&s, strings.to_upper(verb, context.temp_allocator), rest) {
			return
		}
		free_all(context.temp_allocator)
	}
}

smtpd_reset :: proc(s: ^Smtp_Session) {
	s.from = ""
	s.have_from = false
	clear(&s.rcpts)
	clear(&s.rcpt_addrs)
}

smtpd_dispatch :: proc(s: ^Smtp_Session, verb, rest: string) -> bool {
	c := s.c
	switch verb {
	case "EHLO":
		s.helo = strings.clone(rest)
		sline(c, "250-mailcore.test greets %s", rest == "" ? "an anonymous client" : rest)
		sline(c, "250-SIZE %d", SMTP_MAX_SIZE)
		sline(c, "250-8BITMIME")
		sline(c, "250-PIPELINING")
		sline(c, "250-ENHANCEDSTATUSCODES")
		sline(c, "250-AUTH PLAIN LOGIN")
		sline(c, "250 HELP")

	case "HELO":
		s.helo = strings.clone(rest)
		sline(c, "250 mailcore.test")

	case "STARTTLS":
		sline(c, "454 4.7.0 This server is plaintext; TLS is a socat tunnel in front of it")

	case "AUTH":
		return smtpd_auth(s, rest)

	case "MAIL":
		if s.authed_as == nil {
			sline(c, "530 5.7.0 Authentication required")
			return true
		}
		up := strings.to_upper(rest, context.temp_allocator)
		if !strings.has_prefix(up, "FROM:") {
			sline(c, "501 5.5.4 Syntax: MAIL FROM:<address>")
			return true
		}
		addr, params := smtpd_path(rest[5:])
		// Honour the SIZE parameter if it is declared.
		for p in params {
			up2 := strings.to_upper(p, context.temp_allocator)
			if strings.has_prefix(up2, "SIZE=") {
				if n, ok := strconv.parse_int(p[5:], 10); ok && n > SMTP_MAX_SIZE {
					sline(c, "552 5.3.4 Message size exceeds the %d octet limit", SMTP_MAX_SIZE)
					return true
				}
			}
		}
		// Submission: the envelope sender must be the authenticated account.
		if addr != "" && !strings.equal_fold(addr, s.authed_as.email) {
			sline(
				c,
				"550 5.7.1 <%s> is not an address of the authenticated account <%s>",
				addr,
				s.authed_as.email,
			)
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
		up := strings.to_upper(rest, context.temp_allocator)
		if !strings.has_prefix(up, "TO:") {
			sline(c, "501 5.5.4 Syntax: RCPT TO:<address>")
			return true
		}
		addr, _ := smtpd_path(rest[3:])
		if addr == "" {
			sline(c, "550 5.1.3 Empty recipient")
			return true
		}
		sync.mutex_lock(&store.mu)
		a := store_account_by_email(addr)
		sync.mutex_unlock(&store.mu)
		if a == nil {
			// This is the safety behaviour, not a limitation: there is no
			// relay, so an address this server does not host is refused.
			sline(
				c,
				"550 5.1.1 <%s> does not exist here and this server does not relay anywhere",
				addr,
			)
			return true
		}
		append(&s.rcpts, a)
		append(&s.rcpt_addrs, strings.clone(addr))
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
		raw, ok := smtpd_read_data(s)
		if !ok {
			return false
		}
		if len(raw) > SMTP_MAX_SIZE {
			sline(c, "552 5.3.4 Message too large")
			smtpd_reset(s)
			return true
		}
		// Prepend a Received header, which is what a real MTA does and what
		// makes the client's duplicate-header handling matter.
		full := smtpd_add_received(s, raw)
		now := store_now()
		sync.mutex_lock(&store.mu)
		n := 0
		for a, i in s.rcpts {
			b := account_box(a, "INBOX")
			if b == nil {
				continue
			}
			copy_raw := make([]u8, len(full))
			copy(copy_raw, full)
			store_deliver(a, b, copy_raw, {}, mm_derive_decomp(copy_raw, now))
			n += 1
			slog(c, "delivered %d octets to %s (in-memory only)", len(full), s.rcpt_addrs[i])
		}
		// A copy in the sender's Sent folder, as a submission server does.
		if sent := account_box(s.authed_as, "Sent"); sent != nil {
			copy_raw := make([]u8, len(full))
			copy(copy_raw, full)
			store_deliver(s.authed_as, sent, copy_raw, {.Seen}, mm_derive_decomp(copy_raw, now))
		}
		sync.mutex_unlock(&store.mu)
		smtpd_reset(s)
		sline(c, "250 2.0.0 Accepted for %d recipient(s); stored in memory, delivered nowhere", n)

	case "RSET":
		smtpd_reset(s)
		sline(c, "250 2.0.0 Reset")

	case "NOOP":
		sline(c, "250 2.0.0 OK")

	case "VRFY", "EXPN":
		// RFC 5321 3.5.3 allows a flat refusal, and a test server should not
		// confirm which synthetic addresses exist before authentication.
		sline(c, "252 2.5.2 Cannot VRFY, but will accept RCPT and attempt delivery")

	case "HELP":
		sline(c, "214 2.0.0 EHLO AUTH MAIL RCPT DATA RSET NOOP QUIT")

	case "QUIT":
		sline(c, "221 2.0.0 mailcore.test closing connection")
		return false

	case:
		sline(c, "500 5.5.2 Unrecognised command %s", verb)
	}
	return true
}

// smtpd_path pulls the address out of `<addr> PARAM=value ...`.
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
	mech := strings.to_upper(f[0], context.temp_allocator)
	switch mech {
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
		// authzid \0 authcid \0 passwd
		parts := strings.split(string(raw), "\x00", context.temp_allocator)
		if len(parts) < 3 {
			sline(c, "501 5.5.2 Malformed AUTH PLAIN blob")
			return true
		}
		return smtpd_finish_auth(s, parts[1], parts[2])

	case "LOGIN":
		sline(c, "334 %s", mm_b64_encode(transmute([]u8)string("Username:"), context.temp_allocator))
		ul, ok1 := sread_line(c)
		if !ok1 {
			return false
		}
		user := string(mm_b64_decode(transmute([]u8)strings.clone(strings.trim_space(ul), context.temp_allocator), context.temp_allocator))
		sline(c, "334 %s", mm_b64_encode(transmute([]u8)string("Password:"), context.temp_allocator))
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

smtpd_finish_auth :: proc(s: ^Smtp_Session, user, pass: string) -> bool {
	c := s.c
	sync.mutex_lock(&store.mu)
	a := store_account(user)
	good := a != nil && a.password == pass
	sync.mutex_unlock(&store.mu)
	if !good {
		sline(c, "535 5.7.8 Authentication credentials invalid")
		return true
	}
	s.authed_as = a
	sline(c, "235 2.7.0 Authentication successful")
	return true
}

// smtpd_read_data reads the DATA block, undoing the dot-stuffing. This is the
// mirror of the client's `dot_stuff`, and the pair is round-tripped in the
// client's self-test.
smtpd_read_data :: proc(s: ^Smtp_Session) -> (raw: []u8, ok: bool) {
	c := s.c
	out := make([dynamic]u8, 0, 8192)
	for i := 0; i < 1_000_000; i += 1 {
		line, lok := sread_line(c)
		if !lok {
			delete(out)
			return nil, false
		}
		if line == "." {
			return out[:], true
		}
		if len(line) > 0 && line[0] == '.' {
			append(&out, ..transmute([]u8)line[1:])
		} else {
			append(&out, ..transmute([]u8)line)
		}
		append(&out, '\r', '\n')
		if len(out) > SMTP_MAX_SIZE {
			// Keep reading to the terminator so the session stays in sync,
			// but stop accumulating.
			clear(&out)
		}
	}
	return out[:], true
}

smtpd_add_received :: proc(s: ^Smtp_Session, raw: []u8) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		"Received: from %s (localhost [127.0.0.1])\r\n\tby mailcore.test with ESMTPA id %d\r\n\tfor <%s>; %s\r\n",
		s.helo == "" ? "unknown" : s.helo,
		store_now(),
		len(s.rcpt_addrs) > 0 ? s.rcpt_addrs[0] : "unknown",
		smtpd_rfc5322_now(),
	)
	strings.write_bytes(&sb, raw)
	return transmute([]u8)strings.to_string(sb)
}

smtpd_rfc5322_now :: proc() -> string {
	DOW := [7]string{"Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"}
	MON := [12]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}
	u := store_now()
	days := u / 86400
	secs := u % 86400
	if secs < 0 {secs += 86400;days -= 1}
	y, mo, d := civil_from_days(days)
	return fmt.tprintf(
		"%s, %d %s %d %02d:%02d:%02d +0000",
		DOW[((days % 7) + 7) % 7],
		d,
		MON[mo - 1],
		y,
		secs / 3600,
		secs / 60 % 60,
		secs % 60,
	)
}
