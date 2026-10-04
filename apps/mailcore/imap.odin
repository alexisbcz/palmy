package main

// An IMAP4rev1 client (RFC 3501), with the UID commands, IDLE (RFC 2177) and
// STARTTLS (RFC 2595).
//
// PARSER ARCHITECTURE — why this is not line-based
//
// IMAP is *not* a line protocol. Any string in a response may arrive as a
// literal: a line ending in `{123}` followed by exactly 123 raw octets, which
// may themselves contain CRLF, parentheses, quotes, or a byte sequence that
// looks exactly like another response. A parser that splits the stream into
// lines and then tokenises each one will mis-parse the first message whose
// body contains `\r\n* 2 EXPUNGE\r\n`, and that is a correctness hole, not a
// cosmetic one.
//
// So the tokeniser and the transport are interleaved. `IReader` holds the
// *current line* and a cursor into it. `ir_value` is a recursive-descent
// parser over that line. When it meets `{n}` it does three things in order:
// read exactly n octets from the socket (bypassing line framing entirely),
// take them as the token's value, and then pull the *next* line in as the
// continuation of the same response — because RFC 3501 guarantees a literal
// count is the last thing on its line. Parsing then resumes at column 0 of
// that new line. Nothing in the literal is ever looked at as protocol.
//
// The second subtlety is `BODY[HEADER.FIELDS (DATE FROM)]`. That is one atom
// in IMAP's grammar even though it contains spaces and parentheses, so
// `ir_atom` absorbs a balanced `[...]` (and a trailing `<partial>`) into the
// atom rather than treating `[` as a delimiter. Without that the FETCH item
// name splits into five tokens and nothing matches.
//
// Values come out as an `IVal` tree: Atom, Str, Nil, List. Numbers are atoms;
// callers convert. That keeps one parser for every response shape instead of
// one per command.

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

IVal_Kind :: enum u8 {
	Nil,
	Atom, // unquoted token, including numbers and `BODY[...]`
	Str, // quoted string or literal; the bytes are the value
	List, // ( ... )
	Bracket, // [ ... ] appearing where a value was expected (a resp-text-code)
}

IVal :: struct {
	kind: IVal_Kind,
	s:    string,
	list: []IVal,
}

ival_is :: proc(v: IVal, name: string) -> bool {
	return (v.kind == .Atom || v.kind == .Str) && strings.equal_fold(v.s, name)
}

ival_int :: proc(v: IVal) -> (int, bool) {
	if v.kind != .Atom && v.kind != .Str {
		return 0, false
	}
	return strconv.parse_int(v.s, 10)
}

ival_text :: proc(v: IVal) -> string {
	switch v.kind {
	case .Atom, .Str:
		return v.s
	case .Nil:
		return ""
	case .List, .Bracket:
		return ""
	}
	return ""
}

// ival_dump renders a value back into IMAP-ish syntax, for traces and for the
// self-test's expected-output comparisons.
ival_dump :: proc(v: IVal, sb: ^strings.Builder) {
	switch v.kind {
	case .Nil:
		strings.write_string(sb, "NIL")
	case .Atom:
		strings.write_string(sb, v.s)
	case .Str:
		strings.write_byte(sb, '"')
		for i in 0 ..< len(v.s) {
			switch v.s[i] {
			case '"', '\\':
				strings.write_byte(sb, '\\')
				strings.write_byte(sb, v.s[i])
			case '\r':
				strings.write_string(sb, "\\r")
			case '\n':
				strings.write_string(sb, "\\n")
			case:
				strings.write_byte(sb, v.s[i])
			}
		}
		strings.write_byte(sb, '"')
	case .List, .Bracket:
		strings.write_byte(sb, v.kind == .List ? '(' : '[')
		for e, i in v.list {
			if i > 0 {
				strings.write_byte(sb, ' ')
			}
			ival_dump(e, sb)
		}
		strings.write_byte(sb, v.kind == .List ? ')' : ']')
	}
}

ival_to_string :: proc(v: IVal, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	ival_dump(v, &sb)
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// The reader
// ---------------------------------------------------------------------------

IReader :: struct {
	c:     ^Conn,
	line:  string, // the current line, owned by `alloc`
	pos:   int,
	alloc: mem.Allocator,
	err:   string,
	// A source of lines that is not a socket, used by the self-test to parse
	// canned responses (including literals) with no server at all.
	canned: []u8,
	canned_pos: int,
	use_canned: bool,
	literals_seen: int,
}

ireader_from_bytes :: proc(data: []u8, allocator := context.allocator) -> IReader {
	return IReader{canned = data, use_canned = true, alloc = allocator}
}

@(private = "file")
ir_raw_line :: proc(r: ^IReader) -> (string, bool) {
	if r.use_canned {
		if r.canned_pos >= len(r.canned) {
			return "", false
		}
		start := r.canned_pos
		i := start
		for i < len(r.canned) && r.canned[i] != '\n' {
			i += 1
		}
		end := i
		if end > start && r.canned[end - 1] == '\r' {
			end -= 1
		}
		r.canned_pos = i < len(r.canned) ? i + 1 : len(r.canned)
		return string(r.canned[start:end]), true
	}
	return conn_read_line(r.c, 60_000)
}

@(private = "file")
ir_raw_exact :: proc(r: ^IReader, n: int) -> ([]u8, bool) {
	if r.use_canned {
		if r.canned_pos + n > len(r.canned) {
			return nil, false
		}
		out := r.canned[r.canned_pos:r.canned_pos + n]
		r.canned_pos += n
		return out, true
	}
	return conn_read_exact(r.c, n, r.alloc)
}

// ir_next_line replaces the current line. The clone matters: `conn_read_line`
// hands back a view into the connection's scratch buffer, which the literal
// read below is about to overwrite.
@(private = "file")
ir_next_line :: proc(r: ^IReader) -> bool {
	l, ok := ir_raw_line(r)
	if !ok {
		return false
	}
	r.line = strings.clone(l, r.alloc)
	r.pos = 0
	return true
}

@(private = "file")
ir_skip_ws :: proc(r: ^IReader) {
	for r.pos < len(r.line) && (r.line[r.pos] == ' ' || r.line[r.pos] == '\t') {
		r.pos += 1
	}
}

@(private = "file")
ir_eol :: proc(r: ^IReader) -> bool {
	return r.pos >= len(r.line)
}

@(private = "file")
is_atom_delim :: proc(ch: u8) -> bool {
	switch ch {
	case ' ', '\t', '(', ')', ']', '"', '{':
		return true
	}
	return false
}

// ir_atom reads one unquoted token, absorbing a balanced `[...]` section and a
// trailing `<n.m>` partial specifier so that `BODY[HEADER.FIELDS (TO CC)]<0>`
// stays a single token.
@(private = "file")
ir_atom :: proc(r: ^IReader) -> IVal {
	start := r.pos
	for r.pos < len(r.line) {
		ch := r.line[r.pos]
		if ch == '[' {
			depth := 0
			for r.pos < len(r.line) {
				if r.line[r.pos] == '[' {
					depth += 1
				} else if r.line[r.pos] == ']' {
					depth -= 1
					if depth == 0 {
						r.pos += 1
						break
					}
				}
				r.pos += 1
			}
			// An optional <offset> or <offset.length> follows the section.
			if r.pos < len(r.line) && r.line[r.pos] == '<' {
				for r.pos < len(r.line) && r.line[r.pos] != '>' {
					r.pos += 1
				}
				if r.pos < len(r.line) {
					r.pos += 1
				}
			}
			continue
		}
		if is_atom_delim(ch) {
			break
		}
		r.pos += 1
	}
	tok := r.line[start:r.pos]
	if strings.equal_fold(tok, "NIL") {
		return IVal{kind = .Nil}
	}
	return IVal{kind = .Atom, s = tok}
}

@(private = "file")
ir_quoted :: proc(r: ^IReader) -> IVal {
	r.pos += 1 // the opening quote
	sb := strings.builder_make(r.alloc)
	for r.pos < len(r.line) {
		ch := r.line[r.pos]
		if ch == '\\' && r.pos + 1 < len(r.line) {
			strings.write_byte(&sb, r.line[r.pos + 1])
			r.pos += 2
			continue
		}
		if ch == '"' {
			r.pos += 1
			return IVal{kind = .Str, s = strings.to_string(sb)}
		}
		strings.write_byte(&sb, ch)
		r.pos += 1
	}
	r.err = "unterminated quoted string"
	return IVal{kind = .Str, s = strings.to_string(sb)}
}

// ir_literal is the whole point of this parser. See the file comment.
@(private = "file")
ir_literal :: proc(r: ^IReader) -> IVal {
	close := strings.index_byte(r.line[r.pos:], '}')
	if close < 0 {
		r.err = "literal with no closing brace"
		r.pos = len(r.line)
		return IVal{kind = .Nil}
	}
	inner := r.line[r.pos + 1:r.pos + close]
	// RFC 7888 non-synchronising literals end in '+'; RFC 3516 literal8 starts
	// with '~' (consumed by the caller as part of the atom scan).
	inner = strings.trim_right(inner, "+")
	n, ok := strconv.parse_int(strings.trim_space(inner), 10)
	if !ok || n < 0 || n > 64 * 1024 * 1024 {
		r.err = fmt.aprintf("implausible literal length %q", inner)
		r.pos = len(r.line)
		return IVal{kind = .Nil}
	}
	// The literal count must be the last thing on the line.
	if r.pos + close + 1 != len(r.line) {
		r.err = "literal count is not at the end of its line"
	}
	data, dok := ir_raw_exact(r, n)
	if !dok {
		r.err = fmt.aprintf("short read of a %d-octet literal", n)
		r.pos = len(r.line)
		return IVal{kind = .Nil}
	}
	r.literals_seen += 1
	val := IVal {
		kind = .Str,
		s    = strings.clone(string(data), r.alloc),
	}
	// Resume on the line that follows the literal's octets.
	if !ir_next_line(r) {
		r.line = ""
		r.pos = 0
	}
	return val
}

@(private = "file")
ir_group :: proc(r: ^IReader, open, close: u8, kind: IVal_Kind) -> IVal {
	r.pos += 1
	items := make([dynamic]IVal, 0, 8, r.alloc)
	for {
		ir_skip_ws(r)
		if ir_eol(r) {
			// A list may only continue across lines via a literal, which
			// ir_literal already handled by refilling. Reaching EOL here means
			// the response was truncated.
			r.err = "unterminated list"
			break
		}
		if r.line[r.pos] == close {
			r.pos += 1
			break
		}
		before := r.pos
		v := ir_value(r)
		append(&items, v)
		if r.err != "" {
			break
		}
		if r.pos == before && r.line != "" {
			r.err = "parser made no progress"
			break
		}
	}
	return IVal{kind = kind, list = items[:]}
}

ir_value :: proc(r: ^IReader) -> IVal {
	ir_skip_ws(r)
	if ir_eol(r) {
		return IVal{kind = .Nil}
	}
	switch r.line[r.pos] {
	case '(':
		return ir_group(r, '(', ')', .List)
	case '[':
		return ir_group(r, '[', ']', .Bracket)
	case '"':
		return ir_quoted(r)
	case '{':
		return ir_literal(r)
	case '~':
		// literal8: ~{n}
		if r.pos + 1 < len(r.line) && r.line[r.pos + 1] == '{' {
			r.pos += 1
			return ir_literal(r)
		}
		return ir_atom(r)
	}
	return ir_atom(r)
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

IResp_Kind :: enum u8 {
	Untagged, // * ...
	Tagged, // a001 ...
	Continuation, // + ...
}

IResp :: struct {
	kind:   IResp_Kind,
	tag:    string,
	items:  []IVal,
	status: string, // uppercased OK / NO / BAD / PREAUTH / BYE, when present
	text:   string, // the trailing human-readable text
}

// imap_read_response parses exactly one complete server response.
imap_read_response :: proc(r: ^IReader) -> (resp: IResp, err: string) {
	if !ir_next_line(r) {
		return {}, "connection closed while waiting for a response"
	}
	r.err = ""
	ir_skip_ws(r)
	if ir_eol(r) {
		return IResp{kind = .Untagged}, ""
	}

	switch r.line[r.pos] {
	case '*':
		r.pos += 1
		resp.kind = .Untagged
	case '+':
		r.pos += 1
		resp.kind = .Continuation
		resp.text = strings.clone(strings.trim_space(r.line[r.pos:]), r.alloc)
		return resp, ""
	case:
		resp.kind = .Tagged
		tag := ir_atom(r)
		resp.tag = tag.s
	}

	items := make([dynamic]IVal, 0, 8, r.alloc)
	guard := 0
	for {
		ir_skip_ws(r)
		if ir_eol(r) {
			break
		}
		before_line := r.line
		before := r.pos
		v := ir_value(r)
		append(&items, v)
		if r.err != "" {
			resp.items = items[:]
			return resp, r.err
		}
		if r.pos == before && raw_data(r.line) == raw_data(before_line) {
			break
		}
		guard += 1
		if guard > 4096 {
			resp.items = items[:]
			return resp, "response has an implausible number of tokens"
		}
	}
	resp.items = items[:]

	// Status responses: pull the status word and the trailing text out so
	// callers do not have to.
	if len(items) > 0 {
		first := items[0]
		if first.kind == .Atom {
			up := strings.to_upper(first.s, context.temp_allocator)
			switch up {
			case "OK", "NO", "BAD", "PREAUTH", "BYE":
				resp.status = strings.clone(up, r.alloc)
				sb := strings.builder_make(r.alloc)
				for v, i in items[1:] {
					if v.kind == .Bracket {
						continue
					}
					if i > 0 && strings.builder_len(sb) > 0 {
						strings.write_byte(&sb, ' ')
					}
					strings.write_string(&sb, ival_text(v))
				}
				resp.text = strings.to_string(sb)
			}
		}
	}
	return resp, ""
}

// resp_code returns the bracketed response code, e.g. [UIDNEXT 42].
resp_code :: proc(resp: IResp) -> (IVal, bool) {
	for v in resp.items {
		if v.kind == .Bracket {
			return v, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------

Mailbox :: struct {
	name:      string, // decoded from modified UTF-7
	raw_name:  string, // as the server spelled it
	delim:     string,
	attrs:     []string,
}

Mailbox_Status :: struct {
	name:         string,
	exists:       int,
	recent:       int,
	unseen:       int,
	uidnext:      u32,
	uidvalidity:  u32,
	flags:        []string,
	perm_flags:   []string,
	read_only:    bool,
	highestmodseq: u64,
}

IMAP :: struct {
	conn:      Conn,
	reader:    IReader,
	tag_n:     int,
	caps:      []string,
	greeting:  string,
	status:    Mailbox_Status,
	selected:  string,
	untagged:  [dynamic]IResp,
	alloc:     mem.Allocator,
	trace:     bool,
	// Counters the self-test asserts on, so "the literal path ran" is a fact
	// rather than a hope.
	literals_seen: int,
	commands_sent: int,
}

imap_connect :: proc(
	im: ^IMAP,
	host: string,
	port: int,
	opts: Dial_Opts = {},
	allocator := context.allocator,
) -> (
	err: string,
) {
	im.alloc = allocator
	im.trace = opts.trace
	im.untagged = make([dynamic]IResp, 0, 16, allocator)
	if e := conn_dial(&im.conn, host, port, opts, "imap"); e != "" {
		return e
	}
	im.reader = IReader {
		c     = &im.conn,
		alloc = allocator,
	}
	// The greeting.
	resp, rerr := imap_read_response(&im.reader)
	if rerr != "" {
		return fmt.aprintf("reading the IMAP greeting: %s", rerr)
	}
	if resp.kind != .Untagged || (resp.status != "OK" && resp.status != "PREAUTH") {
		return fmt.aprintf("unexpected IMAP greeting: %s", resp.text)
	}
	im.greeting = resp.text
	if code, ok := resp_code(resp); ok {
		if len(code.list) > 0 && ival_is(code.list[0], "CAPABILITY") {
			im.caps = caps_from(code.list[1:], allocator)
		}
	}
	imap_log(im, "greeting: %s", im.greeting)
	return ""
}

imap_close :: proc(im: ^IMAP) {
	conn_close(&im.conn)
}

imap_log :: proc(im: ^IMAP, format: string, args: ..any) {
	if im.trace {
		fmt.eprintf("[imap] ")
		fmt.eprintfln(format, ..args)
	}
}

imap_has_cap :: proc(im: ^IMAP, name: string) -> bool {
	for c in im.caps {
		if strings.equal_fold(c, name) {
			return true
		}
	}
	return false
}

@(private = "file")
caps_from :: proc(vals: []IVal, allocator: mem.Allocator) -> []string {
	out := make([dynamic]string, 0, len(vals), allocator)
	for v in vals {
		if t := ival_text(v); t != "" {
			append(&out, strings.clone(t, allocator))
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Sending commands
// ---------------------------------------------------------------------------

IArg_Kind :: enum u8 {
	Raw, // emitted verbatim: command words, sequence sets, flag lists
	Str, // a string: quoted when it can be, sent as a literal when it cannot
}

IArg :: struct {
	kind: IArg_Kind,
	s:    string,
}

araw :: proc(s: string) -> IArg {return IArg{kind = .Raw, s = s}}
astr :: proc(s: string) -> IArg {return IArg{kind = .Str, s = s}}

@(private = "file")
needs_literal :: proc(s: string) -> bool {
	if len(s) > 1024 {
		return true
	}
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == 0 || ch == '\r' || ch == '\n' || ch >= 0x80 {
			return true
		}
	}
	return false
}

@(private = "file")
write_quoted :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		if s[i] == '"' || s[i] == '\\' {
			strings.write_byte(sb, '\\')
		}
		strings.write_byte(sb, s[i])
	}
	strings.write_byte(sb, '"')
}

// imap_send writes one command, handling literal arguments with the `+`
// continuation handshake that RFC 3501 7.5 requires.
imap_send :: proc(im: ^IMAP, cmd: string, args: ..IArg) -> (tag: string, err: string) {
	im.tag_n += 1
	tag = fmt.aprintf("a%03d", im.tag_n, allocator = im.alloc)
	im.commands_sent += 1

	// Split the command into segments at each literal: everything before a
	// literal goes out, then we wait for `+`, then the octets.
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, tag)
	strings.write_byte(&sb, ' ')
	strings.write_string(&sb, cmd)

	for a in args {
		strings.write_byte(&sb, ' ')
		switch a.kind {
		case .Raw:
			strings.write_string(&sb, a.s)
		case .Str:
			if !needs_literal(a.s) {
				write_quoted(&sb, a.s)
				continue
			}
			// Flush up to and including the literal count, then wait.
			fmt.sbprintf(&sb, "{{%d}}\r\n", len(a.s))
			if !conn_write_str(&im.conn, strings.to_string(sb)) {
				return tag, "short write sending a command"
			}
			imap_log(im, "-> %s", strings.trim_right(strings.to_string(sb), "\r\n"))
			strings.builder_reset(&sb)
			resp, rerr := imap_read_response(&im.reader)
			if rerr != "" {
				return tag, fmt.aprintf("waiting for a literal continuation: %s", rerr)
			}
			if resp.kind != .Continuation {
				return tag, fmt.aprintf("server refused the literal: %s", resp.text)
			}
			strings.write_string(&sb, a.s)
		}
	}
	strings.write_string(&sb, "\r\n")
	if !conn_write_str(&im.conn, strings.to_string(sb)) {
		return tag, "short write sending a command"
	}
	imap_log(im, "-> %s", strings.trim_right(strings.to_string(sb), "\r\n"))
	return tag, ""
}

// imap_collect reads until the tagged response for `tag`, accumulating every
// untagged response in `im.untagged` and folding the well-known ones into
// `im.status` / `im.caps`.
imap_collect :: proc(im: ^IMAP, tag: string) -> (resp: IResp, err: string) {
	clear(&im.untagged)
	for i := 0; i < 100_000; i += 1 {
		r, rerr := imap_read_response(&im.reader)
		im.literals_seen = im.reader.literals_seen
		if rerr != "" {
			return r, rerr
		}
		switch r.kind {
		case .Tagged:
			if r.tag == tag {
				if r.status != "OK" {
					return r, fmt.aprintf("%s %s", r.status, r.text)
				}
				return r, ""
			}
			// A tagged response for a command we did not send. Record it.
			append(&im.untagged, r)
		case .Continuation:
			return r, "unexpected continuation request"
		case .Untagged:
			imap_absorb(im, r)
			append(&im.untagged, r)
		}
	}
	return {}, "server never sent a tagged response"
}

// imap_absorb folds the unsolicited responses every IMAP server may send at
// any time into the client's view of the mailbox.
imap_absorb :: proc(im: ^IMAP, r: IResp) {
	if len(r.items) == 0 {
		return
	}
	if r.status != "" {
		if code, ok := resp_code(r); ok && len(code.list) > 0 {
			switch {
			case ival_is(code.list[0], "CAPABILITY"):
				im.caps = caps_from(code.list[1:], im.alloc)
			case ival_is(code.list[0], "UIDNEXT") && len(code.list) > 1:
				if n, k := ival_int(code.list[1]); k {im.status.uidnext = u32(n)}
			case ival_is(code.list[0], "UIDVALIDITY") && len(code.list) > 1:
				if n, k := ival_int(code.list[1]); k {im.status.uidvalidity = u32(n)}
			case ival_is(code.list[0], "UNSEEN") && len(code.list) > 1:
				if n, k := ival_int(code.list[1]); k {im.status.unseen = n}
			case ival_is(code.list[0], "PERMANENTFLAGS") && len(code.list) > 1:
				im.status.perm_flags = caps_from(code.list[1].list, im.alloc)
			case ival_is(code.list[0], "READ-ONLY"):
				im.status.read_only = true
			case ival_is(code.list[0], "READ-WRITE"):
				im.status.read_only = false
			}
		}
		return
	}

	first := r.items[0]
	if ival_is(first, "CAPABILITY") {
		im.caps = caps_from(r.items[1:], im.alloc)
		return
	}
	if ival_is(first, "FLAGS") && len(r.items) > 1 {
		im.status.flags = caps_from(r.items[1].list, im.alloc)
		return
	}
	// `* 23 EXISTS`, `* 3 RECENT`, `* 4 EXPUNGE`
	if n, ok := ival_int(first); ok && len(r.items) > 1 {
		switch {
		case ival_is(r.items[1], "EXISTS"):
			im.status.exists = n
		case ival_is(r.items[1], "RECENT"):
			im.status.recent = n
		case ival_is(r.items[1], "EXPUNGE"):
			if im.status.exists > 0 {
				im.status.exists -= 1
			}
		}
	}
}

// imap_cmd is send + collect, which is every command that is not IDLE.
imap_cmd :: proc(im: ^IMAP, cmd: string, args: ..IArg) -> (resp: IResp, err: string) {
	tag, serr := imap_send(im, cmd, ..args)
	if serr != "" {
		return {}, serr
	}
	return imap_collect(im, tag)
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

imap_capability :: proc(im: ^IMAP) -> (caps: []string, err: string) {
	_, e := imap_cmd(im, "CAPABILITY")
	if e != "" {
		return nil, e
	}
	return im.caps, ""
}

imap_starttls :: proc(im: ^IMAP, opts: Dial_Opts) -> (err: string) {
	if !imap_has_cap(im, "STARTTLS") {
		return "the server does not advertise STARTTLS"
	}
	if _, e := imap_cmd(im, "STARTTLS"); e != "" {
		return e
	}
	o := opts
	if o.tls == .None {
		o.tls = .Verify
	}
	if e := conn_start_tls(&im.conn, o); e != "" {
		return e
	}
	// RFC 2595: the capability list must be re-fetched after the handshake,
	// because anything learned before it was unauthenticated.
	im.caps = nil
	_, e := imap_capability(im)
	return e
}

imap_login :: proc(im: ^IMAP, user, password: string) -> (err: string) {
	if imap_has_cap(im, "LOGINDISABLED") {
		return "the server has disabled LOGIN (it wants TLS first)"
	}
	// The password is sent as a string argument, so it is quoted or sent as a
	// literal as needed — and it is never written to the trace log.
	im.tag_n += 1
	tag := fmt.aprintf("a%03d", im.tag_n, allocator = im.alloc)
	im.commands_sent += 1
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s LOGIN ", tag)
	if needs_literal(user) || needs_literal(password) {
		return "LOGIN with 8-bit credentials is not supported; use AUTHENTICATE"
	}
	write_quoted(&sb, user)
	strings.write_byte(&sb, ' ')
	write_quoted(&sb, password)
	strings.write_string(&sb, "\r\n")
	if !conn_write_str(&im.conn, strings.to_string(sb)) {
		return "short write sending LOGIN"
	}
	imap_log(im, "-> %s LOGIN %q <password withheld>", tag, user)
	_, e := imap_collect(im, tag)
	return e
}

imap_logout :: proc(im: ^IMAP) -> (err: string) {
	_, e := imap_cmd(im, "LOGOUT")
	return e
}

imap_noop :: proc(im: ^IMAP) -> (err: string) {
	_, e := imap_cmd(im, "NOOP")
	return e
}

imap_list :: proc(
	im: ^IMAP,
	reference := "",
	pattern := "*",
	allocator := context.allocator,
) -> (
	boxes: []Mailbox,
	err: string,
) {
	_, e := imap_cmd(im, "LIST", astr(reference), astr(pattern))
	if e != "" {
		return nil, e
	}
	out := make([dynamic]Mailbox, 0, 8, allocator)
	for r in im.untagged {
		if len(r.items) < 4 || !ival_is(r.items[0], "LIST") {
			continue
		}
		raw := ival_text(r.items[3])
		append(
			&out,
			Mailbox {
				raw_name = strings.clone(raw, allocator),
				name = imap_utf7_decode(raw, allocator),
				delim = strings.clone(ival_text(r.items[2]), allocator),
				attrs = caps_from(r.items[1].list, allocator),
			},
		)
	}
	return out[:], ""
}

imap_select :: proc(im: ^IMAP, mailbox: string, read_only := false) -> (st: Mailbox_Status, err: string) {
	im.status = {}
	im.status.name = strings.clone(mailbox, im.alloc)
	cmd := read_only ? "EXAMINE" : "SELECT"
	enc := imap_utf7_encode(mailbox, context.temp_allocator)
	if _, e := imap_cmd(im, cmd, astr(enc)); e != "" {
		return im.status, e
	}
	im.selected = im.status.name
	im.status.read_only = im.status.read_only || read_only
	return im.status, ""
}

imap_close_mailbox :: proc(im: ^IMAP) -> (err: string) {
	_, e := imap_cmd(im, "CLOSE")
	if e == "" {
		im.selected = ""
	}
	return e
}

// ---------------------------------------------------------------------------
// FETCH
// ---------------------------------------------------------------------------

Fetch_Item :: struct {
	name:  string, // uppercased, with the section intact: `BODY[HEADER]`
	value: IVal,
}

Fetch_Result :: struct {
	seq:          int,
	uid:          u32,
	flags:        []string,
	internaldate: string,
	size:         int,
	items:        []Fetch_Item,
}

fetch_get :: proc(fr: Fetch_Result, name: string) -> (IVal, bool) {
	for it in fr.items {
		if strings.equal_fold(it.name, name) {
			return it.value, true
		}
	}
	return {}, false
}

fetch_bytes :: proc(fr: Fetch_Result, name: string) -> ([]u8, bool) {
	v, ok := fetch_get(fr, name)
	if !ok || (v.kind != .Str && v.kind != .Atom) {
		return nil, false
	}
	return transmute([]u8)v.s, true
}

// imap_fetch issues FETCH (or UID FETCH) and decodes the untagged results.
imap_fetch :: proc(
	im: ^IMAP,
	seq_set: string,
	items: string,
	by_uid := false,
	allocator := context.allocator,
) -> (
	out: []Fetch_Result,
	err: string,
) {
	cmd := by_uid ? "UID FETCH" : "FETCH"
	if _, e := imap_cmd(im, cmd, araw(seq_set), araw(items)); e != "" {
		return nil, e
	}
	res := make([dynamic]Fetch_Result, 0, 16, allocator)
	for r in im.untagged {
		if len(r.items) < 3 || !ival_is(r.items[1], "FETCH") {
			continue
		}
		seq, sok := ival_int(r.items[0])
		if !sok {
			continue
		}
		fr := Fetch_Result {
			seq = seq,
		}
		pairs := r.items[2].list
		its := make([dynamic]Fetch_Item, 0, len(pairs) / 2 + 1, allocator)
		for i := 0; i + 1 < len(pairs); i += 2 {
			name := strings.to_upper(ival_text(pairs[i]), allocator)
			val := pairs[i + 1]
			append(&its, Fetch_Item{name = name, value = val})
			switch {
			case name == "UID":
				if n, k := ival_int(val); k {fr.uid = u32(n)}
			case name == "FLAGS":
				fr.flags = caps_from(val.list, allocator)
			case name == "INTERNALDATE":
				fr.internaldate = strings.clone(ival_text(val), allocator)
			case name == "RFC822.SIZE":
				if n, k := ival_int(val); k {fr.size = n}
			}
		}
		fr.items = its[:]
		append(&res, fr)
	}
	return res[:], ""
}

imap_uid_fetch :: proc(
	im: ^IMAP,
	uid_set: string,
	items: string,
	allocator := context.allocator,
) -> (
	[]Fetch_Result,
	string,
) {
	return imap_fetch(im, uid_set, items, true, allocator)
}

// ---------------------------------------------------------------------------
// SEARCH / STORE / EXPUNGE
// ---------------------------------------------------------------------------

imap_search :: proc(
	im: ^IMAP,
	criteria: string,
	by_uid := false,
	allocator := context.allocator,
) -> (
	ids: []u32,
	err: string,
) {
	cmd := by_uid ? "UID SEARCH" : "SEARCH"
	if _, e := imap_cmd(im, cmd, araw(criteria)); e != "" {
		return nil, e
	}
	out := make([dynamic]u32, 0, 16, allocator)
	for r in im.untagged {
		if len(r.items) == 0 || !ival_is(r.items[0], "SEARCH") {
			continue
		}
		for v in r.items[1:] {
			if n, ok := ival_int(v); ok {
				append(&out, u32(n))
			}
		}
	}
	return out[:], ""
}

// imap_store changes flags. `op` is "FLAGS", "+FLAGS" or "-FLAGS", optionally
// with ".SILENT".
imap_store :: proc(
	im: ^IMAP,
	seq_set: string,
	op: string,
	flags: []string,
	by_uid := false,
	allocator := context.allocator,
) -> (
	out: []Fetch_Result,
	err: string,
) {
	list := strings.join(flags, " ", context.temp_allocator)
	arg := fmt.tprintf("(%s)", list)
	cmd := by_uid ? "UID STORE" : "STORE"
	if _, e := imap_cmd(im, cmd, araw(seq_set), araw(op), araw(arg)); e != "" {
		return nil, e
	}
	// The server reports the new flags as untagged FETCH responses.
	res := make([dynamic]Fetch_Result, 0, 8, allocator)
	for r in im.untagged {
		if len(r.items) < 3 || !ival_is(r.items[1], "FETCH") {
			continue
		}
		seq, sok := ival_int(r.items[0])
		if !sok {
			continue
		}
		fr := Fetch_Result {
			seq = seq,
		}
		pairs := r.items[2].list
		for i := 0; i + 1 < len(pairs); i += 2 {
			nm := strings.to_upper(ival_text(pairs[i]), context.temp_allocator)
			if nm == "FLAGS" {
				fr.flags = caps_from(pairs[i + 1].list, allocator)
			} else if nm == "UID" {
				if n, k := ival_int(pairs[i + 1]); k {fr.uid = u32(n)}
			}
		}
		append(&res, fr)
	}
	return res[:], ""
}

imap_expunge :: proc(im: ^IMAP, allocator := context.allocator) -> (seqs: []int, err: string) {
	if _, e := imap_cmd(im, "EXPUNGE"); e != "" {
		return nil, e
	}
	out := make([dynamic]int, 0, 8, allocator)
	for r in im.untagged {
		if len(r.items) >= 2 && ival_is(r.items[1], "EXPUNGE") {
			if n, ok := ival_int(r.items[0]); ok {
				append(&out, n)
			}
		}
	}
	return out[:], ""
}

imap_append :: proc(
	im: ^IMAP,
	mailbox: string,
	data: []u8,
	flags: []string = nil,
) -> (
	err: string,
) {
	enc := imap_utf7_encode(mailbox, context.temp_allocator)
	args := make([dynamic]IArg, 0, 4, context.temp_allocator)
	append(&args, astr(enc))
	if len(flags) > 0 {
		append(&args, araw(fmt.tprintf("(%s)", strings.join(flags, " ", context.temp_allocator))))
	}
	// The message always goes as a literal: it contains CRLF by definition.
	append(&args, astr(string(data)))
	_, e := imap_cmd(im, "APPEND", ..args[:])
	return e
}

// ---------------------------------------------------------------------------
// IDLE (RFC 2177)
// ---------------------------------------------------------------------------

// imap_idle enters IDLE, waits up to `timeout_ms` for the server to say
// something, and always leaves with DONE. It returns the untagged responses
// that arrived, so the caller can see what changed.
//
// The protocol trap here is that DONE must be sent before the tagged OK can be
// read, and that the server may have already queued untagged responses before
// the `+ idling` continuation. Both are handled.
imap_idle :: proc(
	im: ^IMAP,
	timeout_ms: i32,
	allocator := context.allocator,
) -> (
	events: []IResp,
	err: string,
) {
	if !imap_has_cap(im, "IDLE") {
		return nil, "the server does not advertise IDLE"
	}
	tag, serr := imap_send(im, "IDLE")
	if serr != "" {
		return nil, serr
	}
	// The server answers with a continuation request before it will idle.
	resp, rerr := imap_read_response(&im.reader)
	if rerr != "" {
		return nil, fmt.aprintf("entering IDLE: %s", rerr)
	}
	out := make([dynamic]IResp, 0, 4, allocator)
	if resp.kind == .Untagged {
		// Some servers flush pending news first. Keep it and read on.
		imap_absorb(im, resp)
		append(&out, resp)
		resp, rerr = imap_read_response(&im.reader)
		if rerr != "" {
			return out[:], fmt.aprintf("entering IDLE: %s", rerr)
		}
	}
	if resp.kind != .Continuation {
		return out[:], fmt.aprintf("IDLE was refused: %s", resp.text)
	}
	imap_log(im, "idling (up to %d ms)", timeout_ms)

	deadline_slices := 0
	for conn_readable(&im.conn, timeout_ms) {
		r, e := imap_read_response(&im.reader)
		if e != "" {
			break
		}
		if r.kind == .Untagged {
			imap_absorb(im, r)
			append(&out, r)
		}
		deadline_slices += 1
		if deadline_slices > 64 {
			break
		}
		// Once something has arrived, do not keep waiting for the full
		// timeout: drain whatever is immediately available and return.
		if !conn_readable(&im.conn, 50) {
			break
		}
	}

	if !conn_write_str(&im.conn, "DONE\r\n") {
		return out[:], "short write sending DONE"
	}
	imap_log(im, "-> DONE")
	for i := 0; i < 1000; i += 1 {
		r, e := imap_read_response(&im.reader)
		if e != "" {
			return out[:], e
		}
		if r.kind == .Tagged && r.tag == tag {
			if r.status != "OK" {
				return out[:], fmt.aprintf("%s %s", r.status, r.text)
			}
			return out[:], ""
		}
		if r.kind == .Untagged {
			imap_absorb(im, r)
			append(&out, r)
		}
	}
	return out[:], "no tagged response after DONE"
}

// ---------------------------------------------------------------------------
// BODYSTRUCTURE
// ---------------------------------------------------------------------------

Bodystructure :: struct {
	main:     string,
	sub:      string,
	params:   []Param,
	id:       string,
	desc:     string,
	encoding: string,
	size:     int,
	lines:    int,
	parts:    []Bodystructure,
	section:  string,
}

// parse_bodystructure reads RFC 3501 7.4.2's body structure.
//
// The shape is: a multipart is a list whose first element is itself a list
// (the children), followed by the subtype. A single part is a flat list
// starting with two strings (type, subtype). That one-token lookahead is the
// whole grammar.
parse_bodystructure :: proc(
	v: IVal,
	section := "",
	allocator := context.allocator,
) -> (
	bs: Bodystructure,
	ok: bool,
) {
	if v.kind != .List || len(v.list) == 0 {
		return {}, false
	}
	bs.section = strings.clone(section, allocator)
	if v.list[0].kind == .List {
		bs.main = "multipart"
		kids := make([dynamic]Bodystructure, 0, 4, allocator)
		i := 0
		for ; i < len(v.list) && v.list[i].kind == .List; i += 1 {
			sub_sec := section == "" ? fmt.aprintf("%d", i + 1, allocator = allocator) : fmt.aprintf("%s.%d", section, i + 1, allocator = allocator)
			if k, kok := parse_bodystructure(v.list[i], sub_sec, allocator); kok {
				append(&kids, k)
			}
		}
		bs.parts = kids[:]
		if i < len(v.list) {
			bs.sub = strings.to_lower(ival_text(v.list[i]), allocator)
			i += 1
		}
		if i < len(v.list) && v.list[i].kind == .List {
			bs.params = params_from_ival(v.list[i], allocator)
		}
		return bs, true
	}

	bs.main = strings.to_lower(ival_text(v.list[0]), allocator)
	if len(v.list) > 1 {
		bs.sub = strings.to_lower(ival_text(v.list[1]), allocator)
	}
	if len(v.list) > 2 {
		bs.params = params_from_ival(v.list[2], allocator)
	}
	if len(v.list) > 3 {
		bs.id = strings.trim(ival_text(v.list[3]), "<>")
	}
	if len(v.list) > 4 {
		bs.desc = strings.clone(ival_text(v.list[4]), allocator)
	}
	if len(v.list) > 5 {
		bs.encoding = strings.to_lower(ival_text(v.list[5]), allocator)
	}
	if len(v.list) > 6 {
		bs.size, _ = ival_int(v.list[6])
	}
	if bs.main == "text" && len(v.list) > 7 {
		bs.lines, _ = ival_int(v.list[7])
	}
	return bs, true
}

@(private = "file")
params_from_ival :: proc(v: IVal, allocator: mem.Allocator) -> []Param {
	if v.kind != .List {
		return nil
	}
	out := make([dynamic]Param, 0, len(v.list) / 2 + 1, allocator)
	for i := 0; i + 1 < len(v.list); i += 2 {
		append(
			&out,
			Param {
				name = strings.to_lower(ival_text(v.list[i]), allocator),
				value = strings.clone(ival_text(v.list[i + 1]), allocator),
			},
		)
	}
	return out[:]
}

bodystructure_count :: proc(bs: Bodystructure) -> (n: int) {
	n = 1
	for p in bs.parts {
		n += bodystructure_count(p)
	}
	return
}

// ---------------------------------------------------------------------------
// Modified UTF-7 (RFC 3501 5.1.3)
// ---------------------------------------------------------------------------

// IMAP spells non-ASCII mailbox names in a modified UTF-7: '&' introduces a
// base64 run (with ',' for '/'), and "&-" is a literal '&'.
imap_utf7_decode :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '&') < 0 {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] != '&' {
			strings.write_byte(&sb, s[i])
			i += 1
			continue
		}
		if i + 1 < len(s) && s[i + 1] == '-' {
			strings.write_byte(&sb, '&')
			i += 2
			continue
		}
		// Collect to the terminating '-'.
		j := i + 1
		for j < len(s) && s[j] != '-' {
			j += 1
		}
		run := s[i + 1:j]
		// Modified base64: ',' stands for '/'.
		fixed := strings.builder_make(context.temp_allocator)
		for k in 0 ..< len(run) {
			strings.write_byte(&fixed, run[k] == ',' ? '/' : run[k])
		}
		raw := base64_decode(transmute([]u8)strings.to_string(fixed), context.temp_allocator)
		// The payload is UTF-16BE.
		for k := 0; k + 1 < len(raw); k += 2 {
			u := u32(raw[k]) << 8 | u32(raw[k + 1])
			if u >= 0xD800 && u < 0xDC00 && k + 3 < len(raw) {
				lo := u32(raw[k + 2]) << 8 | u32(raw[k + 3])
				if lo >= 0xDC00 && lo < 0xE000 {
					strings.write_rune(&sb, rune(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)))
					k += 2
					continue
				}
			}
			strings.write_rune(&sb, rune(u))
		}
		i = j < len(s) ? j + 1 : len(s)
	}
	return strings.to_string(sb)
}

imap_utf7_encode :: proc(s: string, allocator := context.allocator) -> string {
	ascii := true
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 || s[i] == '&' {
			ascii = false
			break
		}
	}
	if ascii {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(allocator)
	pending := make([dynamic]u8, 0, 32, context.temp_allocator) // UTF-16BE
	flush :: proc(sb: ^strings.Builder, pending: ^[dynamic]u8) {
		if len(pending) == 0 {
			return
		}
		enc := base64_encode(pending[:], 0, context.temp_allocator)
		strings.write_byte(sb, '&')
		for k in 0 ..< len(enc) {
			if enc[k] == '=' {
				continue // modified base64 drops padding
			}
			strings.write_byte(sb, enc[k] == '/' ? ',' : enc[k])
		}
		strings.write_byte(sb, '-')
		clear(pending)
	}
	for r in s {
		if r == '&' {
			flush(&sb, &pending)
			strings.write_string(&sb, "&-")
			continue
		}
		if r >= 0x20 && r < 0x7f {
			flush(&sb, &pending)
			strings.write_rune(&sb, r)
			continue
		}
		if r < 0x10000 {
			append(&pending, u8(u32(r) >> 8), u8(u32(r)))
		} else {
			v := u32(r) - 0x10000
			hi := 0xD800 + (v >> 10)
			lo := 0xDC00 + (v & 0x3FF)
			append(&pending, u8(hi >> 8), u8(hi), u8(lo >> 8), u8(lo))
		}
	}
	flush(&sb, &pending)
	_ = utf8.RUNE_ERROR
	return strings.to_string(sb)
}

// imap_uid_search is UID SEARCH: the results are UIDs, not sequence numbers,
// which is the only form a sync can safely remember across sessions.
imap_uid_search :: proc(
	im: ^IMAP,
	criteria: string,
	allocator := context.allocator,
) -> (
	[]u32,
	string,
) {
	return imap_search(im, criteria, true, allocator)
}
