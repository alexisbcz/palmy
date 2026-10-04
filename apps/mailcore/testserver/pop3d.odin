package main

// The POP3 front end (RFC 1939), with CAPA, UIDL, TOP and APOP.
//
// It is implemented strictly, because a lenient POP3 server hides the two bugs
// that matter in clients:
//
//  - every multiline response is byte-stuffed: a body line starting with '.'
//    gets an extra '.', so a client that does not un-stuff produces a
//    corrupted message and will not notice;
//  - DELE only marks. RETR, TOP and DELE on an already-marked message are
//    answered with -ERR, and nothing is removed until QUIT reaches the UPDATE
//    state. A client that assumes otherwise desynchronises, and this server
//    makes that visible instead of forgiving it.
//
// POP3 exposes INBOX only. There is no command here that can see another
// folder, which is the honest shape of the protocol.

import "core:crypto/legacy/md5"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Pop_Session :: struct {
	c:        ^SConn,
	acct:     ^Account,
	// A snapshot of INBOX taken at authentication, as RFC 1939 requires: the
	// message numbers must not change for the life of the session.
	msgs:     []^Message,
	marked:   map[int]bool,
	challenge: string,
	authed:   bool,
	user:     string,
}

pop3_serve :: proc(c: ^SConn) {
	s := Pop_Session {
		c      = c,
		marked = make(map[int]bool),
	}
	defer delete(s.marked)
	// The APOP timestamp. It must be unique per connection.
	s.challenge = fmt.aprintf("<%d.%d@mailcore.test>", time.to_unix_nanoseconds(time.now()), int(c.fd))
	defer delete(s.challenge)

	sline(c, "+OK mailcore test POP3 server ready %s", s.challenge)
	for c.open {
		line, ok := sread_line(c)
		if !ok {
			// A dropped connection never reaches UPDATE, so nothing is
			// deleted. That is RFC 1939 8, and it is the behaviour a client
			// has to be tested against.
			slog(c, "connection dropped without QUIT: %d marks discarded", len(s.marked))
			return
		}
		slog(c, "<- %s", line)
		fields := strings.fields(strings.trim_space(line), context.temp_allocator)
		if len(fields) == 0 {
			sline(c, "-ERR empty command")
			continue
		}
		cmd := strings.to_upper(fields[0], context.temp_allocator)
		args := fields[1:]
		if !pop3_dispatch(&s, cmd, args) {
			return
		}
		free_all(context.temp_allocator)
	}
}

pop3_dispatch :: proc(s: ^Pop_Session, cmd: string, args: []string) -> bool {
	c := s.c
	switch cmd {
	case "CAPA":
		sline(c, "+OK Capability list follows")
		sline(c, "TOP")
		sline(c, "UIDL")
		sline(c, "USER")
		sline(c, "RESP-CODES")
		sline(c, "PIPELINING")
		sline(c, "IMPLEMENTATION mailcore-testserver")
		sline(c, ".")

	case "STLS":
		sline(c, "-ERR This server is plaintext; TLS is provided by a socat tunnel in front of it")

	case "USER":
		if s.authed {
			sline(c, "-ERR already authenticated")
			return true
		}
		if len(args) < 1 {
			sline(c, "-ERR USER needs a name")
			return true
		}
		// Cloned into the session allocator: the temp allocator is reset at the
		// end of every command loop iteration.
		s.user = strings.clone(args[0])
		sline(c, "+OK send PASS")

	case "PASS":
		if s.authed {
			sline(c, "-ERR already authenticated")
			return true
		}
		if s.user == "" {
			sline(c, "-ERR send USER first")
			return true
		}
		if len(args) < 1 {
			sline(c, "-ERR PASS needs a password")
			return true
		}
		sync.mutex_lock(&store.mu)
		a := store_account(s.user)
		good := a != nil && a.password == args[0]
		if good {
			pop3_snapshot(s, a)
		}
		sync.mutex_unlock(&store.mu)
		if !good {
			sline(c, "-ERR [AUTH] invalid credentials")
			return true
		}
		sline(c, "+OK mailbox ready, %d messages", len(s.msgs))

	case "APOP":
		if len(args) < 2 {
			sline(c, "-ERR APOP needs a name and a digest")
			return true
		}
		sync.mutex_lock(&store.mu)
		a := store_account(args[0])
		good := false
		if a != nil {
			ctx: md5.Context
			md5.init(&ctx)
			md5.update(&ctx, transmute([]u8)s.challenge)
			md5.update(&ctx, transmute([]u8)a.password)
			digest: [md5.DIGEST_SIZE]u8
			md5.final(&ctx, digest[:])
			hex := strings.builder_make(context.temp_allocator)
			for b in digest {
				fmt.sbprintf(&hex, "%02x", b)
			}
			good = strings.equal_fold(strings.to_string(hex), args[1])
			if good {
				pop3_snapshot(s, a)
			}
		}
		sync.mutex_unlock(&store.mu)
		if !good {
			sline(c, "-ERR [AUTH] APOP digest did not match")
			return true
		}
		sline(c, "+OK mailbox ready, %d messages", len(s.msgs))

	case "QUIT":
		// The UPDATE state. This is the only place a deletion happens.
		n := 0
		sync.mutex_lock(&store.mu)
		for idx in s.marked {
			if idx >= 1 && idx <= len(s.msgs) {
				s.msgs[idx - 1].expunged = true
				account_bump(s.acct, s.msgs[idx - 1].jid, .Destroyed)
				n += 1
			}
		}
		if n > 0 && s.acct != nil {
			if b := account_box(s.acct, "INBOX"); b != nil {
				b.version += 1
			}
		}
		sync.mutex_unlock(&store.mu)
		sline(c, "+OK mailcore signing off, %d message(s) deleted", n)
		return false

	case:
		if !s.authed {
			sline(c, "-ERR authenticate first")
			return true
		}
		return pop3_dispatch_authed(s, cmd, args)
	}
	return true
}

pop3_snapshot :: proc(s: ^Pop_Session, a: ^Account) {
	s.acct = a
	b := account_box(a, "INBOX")
	if b == nil {
		s.msgs = nil
		s.authed = true
		return
	}
	// A stable snapshot, held for the session. POP3 message numbers must not
	// move under the client's feet.
	live := box_live(b, context.allocator)
	s.msgs = live
	s.authed = true
}

pop3_live :: proc(s: ^Pop_Session, idx: int) -> ^Message {
	if idx < 1 || idx > len(s.msgs) {
		return nil
	}
	m := s.msgs[idx - 1]
	if m.expunged {
		return nil
	}
	return m
}

pop3_dispatch_authed :: proc(s: ^Pop_Session, cmd: string, args: []string) -> bool {
	c := s.c
	switch cmd {
	case "NOOP":
		sline(c, "+OK")

	case "STAT":
		n, octets := 0, 0
		for m, i in s.msgs {
			if m.expunged || s.marked[i + 1] {
				continue
			}
			n += 1
			octets += len(m.raw)
		}
		sline(c, "+OK %d %d", n, octets)

	case "LIST":
		if len(args) >= 1 {
			idx, _ := strconv.parse_int(args[0], 10)
			m := pop3_live(s, idx)
			if m == nil || s.marked[idx] {
				sline(c, "-ERR no such message")
				return true
			}
			sline(c, "+OK %d %d", idx, len(m.raw))
			return true
		}
		sline(c, "+OK scan listing follows")
		for m, i in s.msgs {
			if m.expunged || s.marked[i + 1] {
				continue
			}
			sline(c, "%d %d", i + 1, len(m.raw))
		}
		sline(c, ".")

	case "UIDL":
		if len(args) >= 1 {
			idx, _ := strconv.parse_int(args[0], 10)
			m := pop3_live(s, idx)
			if m == nil || s.marked[idx] {
				sline(c, "-ERR no such message")
				return true
			}
			sline(c, "+OK %d %s", idx, pop3_uid(m))
			return true
		}
		sline(c, "+OK unique-id listing follows")
		for m, i in s.msgs {
			if m.expunged || s.marked[i + 1] {
				continue
			}
			sline(c, "%d %s", i + 1, pop3_uid(m))
		}
		sline(c, ".")

	case "RETR":
		if len(args) < 1 {
			sline(c, "-ERR RETR needs a message number")
			return true
		}
		idx, _ := strconv.parse_int(args[0], 10)
		if s.marked[idx] {
			sline(c, "-ERR message %d is marked deleted", idx)
			return true
		}
		m := pop3_live(s, idx)
		if m == nil {
			sline(c, "-ERR no such message")
			return true
		}
		sline(c, "+OK %d octets", len(m.raw))
		pop3_write_stuffed(c, m.raw)

	case "TOP":
		if len(args) < 2 {
			sline(c, "-ERR TOP needs a message number and a line count")
			return true
		}
		idx, _ := strconv.parse_int(args[0], 10)
		n, nok := strconv.parse_int(args[1], 10)
		if !nok || n < 0 {
			sline(c, "-ERR TOP line count must be non-negative")
			return true
		}
		if s.marked[idx] {
			sline(c, "-ERR message %d is marked deleted", idx)
			return true
		}
		m := pop3_live(s, idx)
		if m == nil {
			sline(c, "-ERR no such message")
			return true
		}
		sline(c, "+OK top of message follows")
		pop3_write_stuffed(c, pop3_top_bytes(m.raw, n))

	case "DELE":
		if len(args) < 1 {
			sline(c, "-ERR DELE needs a message number")
			return true
		}
		idx, _ := strconv.parse_int(args[0], 10)
		if s.marked[idx] {
			sline(c, "-ERR message %d is already marked deleted", idx)
			return true
		}
		if pop3_live(s, idx) == nil {
			sline(c, "-ERR no such message")
			return true
		}
		s.marked[idx] = true
		sline(c, "+OK message %d marked for deletion (nothing happens until QUIT)", idx)

	case "RSET":
		n := len(s.marked)
		clear(&s.marked)
		sline(c, "+OK %d mark(s) cleared", n)

	case:
		sline(c, "-ERR unknown command %s", cmd)
	}
	return true
}

// pop3_uid is the UIDL: stable across sessions, unlike the message number.
pop3_uid :: proc(m: ^Message) -> string {
	return fmt.tprintf("%s-%d", m.jid, m.uid)
}

// pop3_write_stuffed emits a multiline response body with byte-stuffing and
// the terminating '.' line.
pop3_write_stuffed :: proc(c: ^SConn, data: []u8) {
	sb := strings.builder_make(context.temp_allocator)
	at_line_start := true
	for i := 0; i < len(data); i += 1 {
		ch := data[i]
		if at_line_start && ch == '.' {
			strings.write_byte(&sb, '.') // the stuffing
		}
		if ch == '\r' {
			strings.write_string(&sb, "\r\n")
			if i + 1 < len(data) && data[i + 1] == '\n' {
				i += 1
			}
			at_line_start = true
			continue
		}
		if ch == '\n' {
			strings.write_string(&sb, "\r\n")
			at_line_start = true
			continue
		}
		strings.write_byte(&sb, ch)
		at_line_start = false
	}
	if !at_line_start {
		strings.write_string(&sb, "\r\n")
	}
	strings.write_string(&sb, ".\r\n")
	swrite_str(c, strings.to_string(sb))
	slog(c, "-> <%d octets + terminator>", len(data))
}

// pop3_top_bytes returns the headers plus the first `n` body lines.
pop3_top_bytes :: proc(raw: []u8, n: int) -> []u8 {
	hdr_end := len(raw)
	for i in 0 ..< len(raw) {
		if raw[i] == '\n' {
			if i + 1 < len(raw) && raw[i + 1] == '\n' {
				hdr_end = i + 2
				break
			}
			if i + 2 < len(raw) && raw[i + 1] == '\r' && raw[i + 2] == '\n' {
				hdr_end = i + 3
				break
			}
		}
	}
	if n == 0 {
		return raw[:hdr_end]
	}
	count := 0
	i := hdr_end
	for i < len(raw) {
		if raw[i] == '\n' {
			count += 1
			if count >= n {
				return raw[:i + 1]
			}
		}
		i += 1
	}
	return raw
}
