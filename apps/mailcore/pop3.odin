package main

// POP3 (RFC 1939), with CAPA (RFC 2449), UIDL, TOP and APOP.
//
// POP3 is a small protocol with two traps, and this client is built around
// both of them.
//
// TRAP 1 — the multiline response. RETR, LIST, UIDL, CAPA and TOP end with a
// line containing a single '.'. Any data line that *starts* with '.' had an
// extra '.' prepended by the server (byte-stuffing, RFC 1939 3), so the client
// must strip exactly one. Get that wrong and every message whose body has a
// line starting with a period is silently corrupted — and in mail, that is
// quoted text and ASCII art, so it happens constantly.
//
// TRAP 2 — deletion is not immediate. DELE only *marks* a message; the server
// does not remove anything until QUIT moves it from the TRANSACTION state to
// UPDATE. A client that treats DELE as done, or that sends RSET after DELE
// expecting the deletion to stick, or that drops the connection instead of
// sending QUIT, will leave the mailbox in a state that does not match its own
// idea of it. So this client tracks the marks itself (`marked_deleted`),
// refuses to RETR a marked message, and `pop3_quit` is the only thing that
// reports a deletion as having happened.
//
// POP3 has no folders and no server-side flags. That is reflected honestly in
// what gets written to disk: a POP3 sync only ever fills INBOX, and the only
// flag it can justify is none at all — every retrieved message lands in `new/`
// with no info field, because POP3 cannot tell us whether anyone has read it.

import "core:crypto/legacy/md5"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

POP3 :: struct {
	conn:           Conn,
	greeting:       string,
	apop_challenge: string, // the <...> timestamp from the greeting, if any
	caps:           []string,
	alloc:          mem.Allocator,
	trace:          bool,
	marked_deleted: map[int]bool,
	authenticated:  bool,
	committed:      bool, // QUIT acknowledged: the marks have been applied
}

Pop_Entry :: struct {
	num:  int, // the message number for this session only
	size: int,
	uid:  string, // from UIDL: stable across sessions, which `num` is not
}

pop3_connect :: proc(
	p: ^POP3,
	host: string,
	port: int,
	opts: Dial_Opts = {},
	allocator := context.allocator,
) -> (
	err: string,
) {
	p.alloc = allocator
	p.trace = opts.trace
	p.marked_deleted = make(map[int]bool, 8, allocator)
	if e := conn_dial(&p.conn, host, port, opts, "pop3"); e != "" {
		return e
	}
	line, ok := conn_read_line(&p.conn, 30_000)
	if !ok {
		return "no POP3 greeting"
	}
	g := strings.clone(line, allocator)
	p.greeting = g
	pop3_log(p, "<- %s", g)
	if !strings.has_prefix(g, "+OK") {
		return fmt.aprintf("POP3 server refused the connection: %s", g)
	}
	// An APOP-capable server ends its greeting with <process.clock@host>.
	if lt := strings.last_index_byte(g, '<'); lt >= 0 {
		if gt := strings.index_byte(g[lt:], '>'); gt > 0 {
			p.apop_challenge = g[lt:lt + gt + 1]
		}
	}
	return ""
}

pop3_close :: proc(p: ^POP3) {
	conn_close(&p.conn)
	delete(p.marked_deleted)
}

pop3_log :: proc(p: ^POP3, format: string, args: ..any) {
	if p.trace {
		fmt.eprintf("[pop3] ")
		fmt.eprintfln(format, ..args)
	}
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

// pop3_cmd sends one command and reads the single status line.
pop3_cmd :: proc(p: ^POP3, line: string, display := "") -> (status: string, err: string) {
	if !conn_write_str(&p.conn, line) || !conn_write_str(&p.conn, "\r\n") {
		return "", "short write sending a POP3 command"
	}
	pop3_log(p, "-> %s", display == "" ? line : display)
	raw, ok := conn_read_line(&p.conn, 30_000)
	if !ok {
		return "", "POP3 server closed the connection"
	}
	status = strings.clone(raw, p.alloc)
	pop3_log(p, "<- %s", status)
	if strings.has_prefix(status, "-ERR") {
		return status, fmt.aprintf("%s", strings.trim_space(status[4:]))
	}
	if !strings.has_prefix(status, "+OK") {
		return status, fmt.aprintf("malformed POP3 status line %q", status)
	}
	return status, ""
}

// pop3_read_multi reads a dot-terminated body, undoing the byte-stuffing.
//
// The output uses CRLF, exactly as received, so a RETRieved message is byte
// identical to what the server stored — which is what makes the cross-protocol
// Maildir comparison meaningful.
pop3_read_multi :: proc(p: ^POP3, allocator := context.allocator) -> (data: []u8, err: string) {
	out := make([dynamic]u8, 0, 4096, allocator)
	for i := 0; i < 10_000_000; i += 1 {
		line, ok := conn_read_line(&p.conn, 60_000)
		if !ok {
			delete(out)
			return nil, "POP3 connection closed inside a multiline response"
		}
		if line == "." {
			return out[:], ""
		}
		if len(line) > 0 && line[0] == '.' {
			// Un-stuff: exactly one leading '.' was added by the sender.
			append(&out, ..transmute([]u8)line[1:])
		} else {
			append(&out, ..transmute([]u8)line)
		}
		append(&out, '\r', '\n')
	}
	return out[:], "multiline response did not terminate"
}

pop3_cmd_multi :: proc(
	p: ^POP3,
	line: string,
	allocator := context.allocator,
) -> (
	data: []u8,
	err: string,
) {
	if _, e := pop3_cmd(p, line); e != "" {
		return nil, e
	}
	return pop3_read_multi(p, allocator)
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

pop3_capa :: proc(p: ^POP3) -> (caps: []string, err: string) {
	data, e := pop3_cmd_multi(p, "CAPA", context.temp_allocator)
	if e != "" {
		return nil, e // CAPA is optional: a -ERR here is not fatal
	}
	out := make([dynamic]string, 0, 8, p.alloc)
	for l in strings.split_lines(string(data), context.temp_allocator) {
		t := strings.trim_space(l)
		if t != "" {
			append(&out, strings.clone(t, p.alloc))
		}
	}
	p.caps = out[:]
	return p.caps, ""
}

pop3_has_cap :: proc(p: ^POP3, name: string) -> bool {
	for c in p.caps {
		if strings.equal_fold(c, name) || strings.has_prefix(strings.to_upper(c, context.temp_allocator), strings.concatenate({strings.to_upper(name, context.temp_allocator), " "}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

pop3_stls :: proc(p: ^POP3, opts: Dial_Opts) -> (err: string) {
	if _, e := pop3_cmd(p, "STLS"); e != "" {
		return e
	}
	o := opts
	if o.tls == .None {
		o.tls = .Verify
	}
	return conn_start_tls(&p.conn, o)
}

// pop3_login does USER/PASS. The password never reaches the trace log.
pop3_login :: proc(p: ^POP3, user, password: string) -> (err: string) {
	if _, e := pop3_cmd(p, fmt.tprintf("USER %s", user)); e != "" {
		return e
	}
	if _, e := pop3_cmd(p, fmt.tprintf("PASS %s", password), "PASS <withheld>"); e != "" {
		return e
	}
	p.authenticated = true
	return ""
}

// pop3_apop is RFC 1939 7: the shared secret is never transmitted, only
// MD5(challenge || secret). MD5 is long broken for collision resistance, and
// APOP is a pre-image-style construction over a short string, so this is
// *weak* authentication — it is implemented because the protocol defines it
// and the test server offers it, not because it is good.
pop3_apop :: proc(p: ^POP3, user, password: string) -> (err: string) {
	if p.apop_challenge == "" {
		return "the server did not offer an APOP timestamp in its greeting"
	}
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, transmute([]u8)p.apop_challenge)
	md5.update(&ctx, transmute([]u8)password)
	digest: [md5.DIGEST_SIZE]u8
	md5.final(&ctx, digest[:])
	hex := strings.builder_make(context.temp_allocator)
	for b in digest {
		fmt.sbprintf(&hex, "%02x", b)
	}
	if _, e := pop3_cmd(
		p,
		fmt.tprintf("APOP %s %s", user, strings.to_string(hex)),
		fmt.tprintf("APOP %s <digest>", user),
	); e != "" {
		return e
	}
	p.authenticated = true
	return ""
}

// ---------------------------------------------------------------------------
// Transaction state
// ---------------------------------------------------------------------------

pop3_stat :: proc(p: ^POP3) -> (count, octets: int, err: string) {
	status, e := pop3_cmd(p, "STAT")
	if e != "" {
		return 0, 0, e
	}
	f := strings.fields(status, context.temp_allocator)
	if len(f) < 3 {
		return 0, 0, fmt.aprintf("malformed STAT response %q", status)
	}
	count, _ = strconv.parse_int(f[1], 10)
	octets, _ = strconv.parse_int(f[2], 10)
	return count, octets, ""
}

// pop3_list returns one entry per message, with the UIDL filled in when the
// server supports it. The UID is the only stable handle POP3 offers: message
// numbers are renumbered every session, so a sync keyed on them duplicates
// mail. That is why `pop3_sync` keys on `uid`.
pop3_list :: proc(p: ^POP3, allocator := context.allocator) -> (entries: []Pop_Entry, err: string) {
	data, e := pop3_cmd_multi(p, "LIST", context.temp_allocator)
	if e != "" {
		return nil, e
	}
	out := make([dynamic]Pop_Entry, 0, 16, allocator)
	for l in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(strings.trim_space(l), context.temp_allocator)
		if len(f) < 2 {
			continue
		}
		num, ok1 := strconv.parse_int(f[0], 10)
		size, ok2 := strconv.parse_int(f[1], 10)
		if !ok1 || !ok2 {
			continue
		}
		append(&out, Pop_Entry{num = num, size = size})
	}

	// UIDL is optional (RFC 2449). Without it, the best we can do is say so.
	udata, ue := pop3_cmd_multi(p, "UIDL", context.temp_allocator)
	if ue == "" {
		for l in strings.split_lines(string(udata), context.temp_allocator) {
			f := strings.fields(strings.trim_space(l), context.temp_allocator)
			if len(f) < 2 {
				continue
			}
			num, ok := strconv.parse_int(f[0], 10)
			if !ok {
				continue
			}
			for i in 0 ..< len(out) {
				if out[i].num == num {
					out[i].uid = strings.clone(f[1], allocator)
				}
			}
		}
	}
	return out[:], ""
}

pop3_uidl :: proc(p: ^POP3, num: int) -> (uid: string, err: string) {
	status, e := pop3_cmd(p, fmt.tprintf("UIDL %d", num))
	if e != "" {
		return "", e
	}
	f := strings.fields(status, context.temp_allocator)
	if len(f) < 3 {
		return "", fmt.aprintf("malformed UIDL response %q", status)
	}
	return strings.clone(f[2], p.alloc), ""
}

pop3_retr :: proc(p: ^POP3, num: int, allocator := context.allocator) -> (data: []u8, err: string) {
	if p.marked_deleted[num] {
		// RFC 1939: the server MUST answer -ERR here. Catching it client-side
		// turns a protocol error into a clear bug report.
		return nil, fmt.aprintf("message %d is marked deleted in this session", num)
	}
	return pop3_cmd_multi(p, fmt.tprintf("RETR %d", num), allocator)
}

// pop3_top fetches the headers plus `lines` lines of body — the cheap way to
// build a message list without downloading every attachment.
pop3_top :: proc(
	p: ^POP3,
	num, lines: int,
	allocator := context.allocator,
) -> (
	data: []u8,
	err: string,
) {
	if p.marked_deleted[num] {
		return nil, fmt.aprintf("message %d is marked deleted in this session", num)
	}
	return pop3_cmd_multi(p, fmt.tprintf("TOP %d %d", num, lines), allocator)
}

// pop3_dele marks a message. Nothing is gone until QUIT succeeds.
pop3_dele :: proc(p: ^POP3, num: int) -> (err: string) {
	if _, e := pop3_cmd(p, fmt.tprintf("DELE %d", num)); e != "" {
		return e
	}
	p.marked_deleted[num] = true
	return ""
}

// pop3_rset unmarks everything, which is the other half of trap 2.
pop3_rset :: proc(p: ^POP3) -> (err: string) {
	if _, e := pop3_cmd(p, "RSET"); e != "" {
		return e
	}
	clear(&p.marked_deleted)
	return ""
}

pop3_noop :: proc(p: ^POP3) -> (err: string) {
	_, e := pop3_cmd(p, "NOOP")
	return e
}

pop3_marked_count :: proc(p: ^POP3) -> int {
	return len(p.marked_deleted)
}

// pop3_quit is where deletions actually happen. Only after a +OK here may a
// caller believe that a DELEted message is gone.
pop3_quit :: proc(p: ^POP3) -> (deleted: int, err: string) {
	n := len(p.marked_deleted)
	if _, e := pop3_cmd(p, "QUIT"); e != "" {
		return 0, e
	}
	p.committed = true
	clear(&p.marked_deleted)
	return n, ""
}

// ---------------------------------------------------------------------------
// Syncing into a Maildir
// ---------------------------------------------------------------------------

Pop_Sync_Result :: struct {
	fetched:   int,
	skipped:   int, // already on disk, matched by UIDL
	bytes:     int,
	delivered: []string, // Maildir filenames, in the order they were written
}

// pop3_sync downloads every message into INBOX.
//
// It writes nothing but INBOX and sets no flags, because POP3 knows about
// neither. `uid_seen` lets the caller pass in the UIDLs it has already stored
// so a second run is a no-op; POP3 offers no other way to avoid duplicates.
pop3_sync :: proc(
	p: ^POP3,
	md: ^Maildir,
	uid_seen: map[string]bool = nil,
	allocator := context.allocator,
) -> (
	res: Pop_Sync_Result,
	err: string,
) {
	if ee := maildir_ensure_folder(md, INBOX); ee != "" {
		return res, ee
	}
	entries, le := pop3_list(p, context.temp_allocator)
	if le != "" {
		return res, le
	}
	names := make([dynamic]string, 0, len(entries), allocator)
	for e in entries {
		if e.uid != "" && uid_seen != nil && uid_seen[e.uid] {
			res.skipped += 1
			continue
		}
		data, re := pop3_retr(p, e.num, allocator)
		if re != "" {
			return res, re
		}
		// POP3 cannot say whether a message has been read, so it goes to new/
		// with no flags. Inventing \Seen here would be a lie.
		name, de := maildir_deliver(md, INBOX, data, {}, true, allocator)
		if de != "" {
			return res, de
		}
		append(&names, name)
		res.fetched += 1
		res.bytes += len(data)
	}
	res.delivered = names[:]
	return res, ""
}

// pop3_prefix returns the first `n` octets of a message, by RETRieving it.
// Used by the self-test to prove that TOP returns a real prefix rather than
// something merely shorter.
pop3_prefix :: proc(p: ^POP3, num, n: int, allocator := context.allocator) -> []u8 {
	data, err := pop3_retr(p, num, allocator)
	if err != "" {
		return nil
	}
	if n >= len(data) {
		return data
	}
	return data[:n]
}
