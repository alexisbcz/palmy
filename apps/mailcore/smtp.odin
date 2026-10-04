package main

// SMTP submission (RFC 5321), with ESMTP EHLO (RFC 1869), AUTH PLAIN/LOGIN
// (RFC 4954) and STARTTLS (RFC 3207).
//
// SAFETY: this client can only ever reach 127.0.0.1, because `conn_dial`
// refuses anything else and there is no name resolution in this program. There
// is no code path by which `smtp_send` can deliver to a real address: the
// envelope is handed to a loopback server which writes it into its own
// in-memory store. Sending is the one irreversible operation in mail, so the
// restriction is enforced at the socket, not by convention.
//
// The two things worth care here:
//
//  1. Dot-stuffing. A body line consisting of a single '.' terminates DATA, so
//     every line that begins with '.' gets one prepended (RFC 5321 4.5.2).
//     This is the mirror of POP3's un-stuffing, and the function that does it
//     is round-tripped against `pop3_read_multi` in the self-test.
//  2. Multiline replies. `250-SIZE 35882882` then `250 HELP` is one reply with
//     two lines; a reader that returns after the first line desynchronises the
//     whole session.

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

SMTP :: struct {
	conn:      Conn,
	greeting:  string,
	ehlo_lines: []string,
	max_size:  int,
	alloc:     mem.Allocator,
	trace:     bool,
	authenticated: bool,
	supports_8bitmime: bool,
	supports_pipelining: bool,
	auth_mechs: []string,
}

Smtp_Reply :: struct {
	code:  int,
	lines: []string,
}

smtp_connect :: proc(
	s: ^SMTP,
	host: string,
	port: int,
	opts: Dial_Opts = {},
	allocator := context.allocator,
) -> (
	err: string,
) {
	s.alloc = allocator
	s.trace = opts.trace
	if e := conn_dial(&s.conn, host, port, opts, "smtp"); e != "" {
		return e
	}
	r, re := smtp_read_reply(s)
	if re != "" {
		return re
	}
	if r.code != 220 {
		return fmt.aprintf("SMTP server did not greet us: %d %s", r.code, join_lines(r.lines))
	}
	s.greeting = join_lines(r.lines)
	return ""
}

smtp_close :: proc(s: ^SMTP) {
	conn_close(&s.conn)
}

smtp_log :: proc(s: ^SMTP, format: string, args: ..any) {
	if s.trace {
		fmt.eprintf("[smtp] ")
		fmt.eprintfln(format, ..args)
	}
}

@(private = "file")
join_lines :: proc(l: []string) -> string {
	return strings.join(l, " / ", context.temp_allocator)
}

// smtp_read_reply reads a complete reply, following `code-` continuations.
smtp_read_reply :: proc(s: ^SMTP) -> (reply: Smtp_Reply, err: string) {
	lines := make([dynamic]string, 0, 8, s.alloc)
	for i := 0; i < 256; i += 1 {
		raw, ok := conn_read_line(&s.conn, 60_000)
		if !ok {
			return reply, "SMTP server closed the connection"
		}
		line := strings.clone(raw, context.temp_allocator)
		smtp_log(s, "<- %s", line)
		if len(line) < 3 {
			return reply, fmt.aprintf("malformed SMTP reply %q", line)
		}
		code, cok := strconv.parse_int(line[:3], 10)
		if !cok {
			return reply, fmt.aprintf("malformed SMTP reply code in %q", line)
		}
		reply.code = code
		if len(line) > 4 {
			append(&lines, strings.clone(line[4:], s.alloc))
		} else {
			append(&lines, "")
		}
		if len(line) == 3 || line[3] != '-' {
			reply.lines = lines[:]
			return reply, ""
		}
	}
	return reply, "SMTP reply had too many continuation lines"
}

smtp_cmd :: proc(s: ^SMTP, line: string, display := "") -> (reply: Smtp_Reply, err: string) {
	if !conn_write_str(&s.conn, line) || !conn_write_str(&s.conn, "\r\n") {
		return reply, "short write sending an SMTP command"
	}
	smtp_log(s, "-> %s", display == "" ? line : display)
	return smtp_read_reply(s)
}

// smtp_ehlo also records the extensions, which decide what the rest of the
// session may do.
smtp_ehlo :: proc(s: ^SMTP, domain := "localhost") -> (err: string) {
	r, e := smtp_cmd(s, fmt.tprintf("EHLO %s", domain))
	if e != "" {
		return e
	}
	if r.code != 250 {
		// RFC 5321 4.1.4: fall back to HELO for a server that predates ESMTP.
		hr, he := smtp_cmd(s, fmt.tprintf("HELO %s", domain))
		if he != "" {
			return he
		}
		if hr.code != 250 {
			return fmt.aprintf("HELO refused: %d %s", hr.code, join_lines(hr.lines))
		}
		s.ehlo_lines = hr.lines
		return ""
	}
	s.ehlo_lines = r.lines
	mechs := make([dynamic]string, 0, 4, s.alloc)
	for l in r.lines {
		up := strings.to_upper(strings.trim_space(l), context.temp_allocator)
		switch {
		case up == "8BITMIME":
			s.supports_8bitmime = true
		case up == "PIPELINING":
			s.supports_pipelining = true
		case strings.has_prefix(up, "SIZE"):
			if f := strings.fields(up, context.temp_allocator); len(f) > 1 {
				s.max_size, _ = strconv.parse_int(f[1], 10)
			}
		case strings.has_prefix(up, "AUTH"):
			for m in strings.fields(up[4:], context.temp_allocator) {
				append(&mechs, strings.clone(m, s.alloc))
			}
		}
	}
	s.auth_mechs = mechs[:]
	return ""
}

smtp_has_ext :: proc(s: ^SMTP, name: string) -> bool {
	for l in s.ehlo_lines {
		up := strings.to_upper(strings.trim_space(l), context.temp_allocator)
		if up == strings.to_upper(name, context.temp_allocator) ||
		   strings.has_prefix(up, strings.concatenate({strings.to_upper(name, context.temp_allocator), " "}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

smtp_has_auth :: proc(s: ^SMTP, mech: string) -> bool {
	for m in s.auth_mechs {
		if strings.equal_fold(m, mech) {
			return true
		}
	}
	return false
}

smtp_starttls :: proc(s: ^SMTP, opts: Dial_Opts) -> (err: string) {
	if !smtp_has_ext(s, "STARTTLS") {
		return "the server does not advertise STARTTLS"
	}
	r, e := smtp_cmd(s, "STARTTLS")
	if e != "" {
		return e
	}
	if r.code != 220 {
		return fmt.aprintf("STARTTLS refused: %d %s", r.code, join_lines(r.lines))
	}
	o := opts
	if o.tls == .None {
		o.tls = .Verify
	}
	if te := conn_start_tls(&s.conn, o); te != "" {
		return te
	}
	// RFC 3207 4.2: discard everything learned before the handshake and EHLO
	// again. Trusting the pre-TLS extension list is how STARTTLS downgrades
	// become invisible.
	s.ehlo_lines = nil
	s.auth_mechs = nil
	s.supports_8bitmime = false
	return smtp_ehlo(s)
}

// ---------------------------------------------------------------------------
// AUTH
// ---------------------------------------------------------------------------

// smtp_auth_plain sends RFC 4616's single blob: \0user\0pass, base64'd.
smtp_auth_plain :: proc(s: ^SMTP, user, password: string) -> (err: string) {
	blob := strings.builder_make(context.temp_allocator)
	strings.write_byte(&blob, 0)
	strings.write_string(&blob, user)
	strings.write_byte(&blob, 0)
	strings.write_string(&blob, password)
	enc := base64_encode(transmute([]u8)strings.to_string(blob), 0, context.temp_allocator)
	r, e := smtp_cmd(s, fmt.tprintf("AUTH PLAIN %s", enc), "AUTH PLAIN <withheld>")
	if e != "" {
		return e
	}
	if r.code != 235 {
		return fmt.aprintf("AUTH PLAIN refused: %d %s", r.code, join_lines(r.lines))
	}
	s.authenticated = true
	return ""
}

// smtp_auth_login is the two-prompt Microsoft mechanism: not an RFC, but
// universally supported, and the server challenges with base64 "Username:".
smtp_auth_login :: proc(s: ^SMTP, user, password: string) -> (err: string) {
	r, e := smtp_cmd(s, "AUTH LOGIN")
	if e != "" {
		return e
	}
	if r.code != 334 {
		return fmt.aprintf("AUTH LOGIN refused: %d %s", r.code, join_lines(r.lines))
	}
	ur, ue := smtp_cmd(
		s,
		base64_encode(transmute([]u8)user, 0, context.temp_allocator),
		"<username>",
	)
	if ue != "" {
		return ue
	}
	if ur.code != 334 {
		return fmt.aprintf("AUTH LOGIN username rejected: %d %s", ur.code, join_lines(ur.lines))
	}
	pr, pe := smtp_cmd(
		s,
		base64_encode(transmute([]u8)password, 0, context.temp_allocator),
		"<password>",
	)
	if pe != "" {
		return pe
	}
	if pr.code != 235 {
		return fmt.aprintf("AUTH LOGIN failed: %d %s", pr.code, join_lines(pr.lines))
	}
	s.authenticated = true
	return ""
}

// ---------------------------------------------------------------------------
// The envelope
// ---------------------------------------------------------------------------

// dot_stuff prepares a message body for DATA: CRLF line endings and a '.'
// prepended to any line that already starts with one.
dot_stuff :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(data) + len(data) / 64 + 16, allocator)
	at_line_start := true
	for i := 0; i < len(data); i += 1 {
		ch := data[i]
		if at_line_start && ch == '.' {
			append(&out, '.')
		}
		if ch == '\r' {
			// Normalise: a lone CR becomes CRLF, CRLF stays CRLF.
			append(&out, '\r', '\n')
			if i + 1 < len(data) && data[i + 1] == '\n' {
				i += 1
			}
			at_line_start = true
			continue
		}
		if ch == '\n' {
			append(&out, '\r', '\n')
			at_line_start = true
			continue
		}
		append(&out, ch)
		at_line_start = false
	}
	return out[:]
}

// dot_unstuff is the inverse, used by the self-test to prove the round trip.
dot_unstuff :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(data), allocator)
	at_line_start := true
	for i := 0; i < len(data); i += 1 {
		ch := data[i]
		if at_line_start && ch == '.' {
			// Drop exactly one.
			at_line_start = false
			continue
		}
		append(&out, ch)
		at_line_start = ch == '\n'
	}
	return out[:]
}

Envelope :: struct {
	from: string, // the return path; "" means the null sender <>
	to:   []string,
	body: []u8, // a complete RFC 5322 message
}

// smtp_send runs MAIL FROM / RCPT TO / DATA for one envelope.
smtp_send :: proc(s: ^SMTP, env: Envelope) -> (accepted: []string, err: string) {
	if len(env.to) == 0 {
		return nil, "no recipients"
	}
	if s.max_size > 0 && len(env.body) > s.max_size {
		return nil, fmt.aprintf(
			"message is %d octets, the server's limit is %d",
			len(env.body),
			s.max_size,
		)
	}
	mail_from := fmt.tprintf("MAIL FROM:<%s>", env.from)
	if s.supports_8bitmime {
		mail_from = fmt.tprintf("MAIL FROM:<%s> BODY=8BITMIME", env.from)
	}
	r, e := smtp_cmd(s, mail_from)
	if e != "" {
		return nil, e
	}
	if r.code != 250 {
		return nil, fmt.aprintf("MAIL FROM refused: %d %s", r.code, join_lines(r.lines))
	}

	ok_rcpts := make([dynamic]string, 0, len(env.to), s.alloc)
	for rcpt in env.to {
		rr, re := smtp_cmd(s, fmt.tprintf("RCPT TO:<%s>", rcpt))
		if re != "" {
			return ok_rcpts[:], re
		}
		if rr.code == 250 || rr.code == 251 {
			append(&ok_rcpts, strings.clone(rcpt, s.alloc))
			continue
		}
		smtp_log(s, "recipient %q refused: %d %s", rcpt, rr.code, join_lines(rr.lines))
	}
	if len(ok_rcpts) == 0 {
		// Leave the transaction clean rather than abandoning it mid-way.
		smtp_cmd(s, "RSET")
		return nil, "every recipient was refused"
	}

	dr, de := smtp_cmd(s, "DATA")
	if de != "" {
		return ok_rcpts[:], de
	}
	if dr.code != 354 {
		return ok_rcpts[:], fmt.aprintf("DATA refused: %d %s", dr.code, join_lines(dr.lines))
	}
	stuffed := dot_stuff(env.body, context.temp_allocator)
	if !conn_write(&s.conn, stuffed) {
		return ok_rcpts[:], "short write sending the message body"
	}
	// The terminator needs its own CRLF if the body did not end with one.
	if len(stuffed) >= 2 && string(stuffed[len(stuffed) - 2:]) == "\r\n" {
		if !conn_write_str(&s.conn, ".\r\n") {
			return ok_rcpts[:], "short write sending the DATA terminator"
		}
	} else if !conn_write_str(&s.conn, "\r\n.\r\n") {
		return ok_rcpts[:], "short write sending the DATA terminator"
	}
	smtp_log(s, "-> <%d octets> .", len(stuffed))

	fr, fe := smtp_read_reply(s)
	if fe != "" {
		return ok_rcpts[:], fe
	}
	if fr.code != 250 {
		return ok_rcpts[:], fmt.aprintf("message rejected: %d %s", fr.code, join_lines(fr.lines))
	}
	return ok_rcpts[:], ""
}

smtp_rset :: proc(s: ^SMTP) -> (err: string) {
	r, e := smtp_cmd(s, "RSET")
	if e != "" {
		return e
	}
	if r.code != 250 {
		return fmt.aprintf("RSET refused: %d", r.code)
	}
	return ""
}

smtp_quit :: proc(s: ^SMTP) -> (err: string) {
	r, e := smtp_cmd(s, "QUIT")
	if e != "" {
		return e
	}
	if r.code != 221 {
		return fmt.aprintf("QUIT refused: %d %s", r.code, join_lines(r.lines))
	}
	return ""
}
