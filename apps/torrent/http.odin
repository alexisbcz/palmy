package main

// Just enough HTTP/1.1 for a tracker announce, plus the percent-encoding rule
// that every new BitTorrent client gets wrong once.
//
// THE PERCENT-ENCODING
//
// `info_hash` and `peer_id` are twenty **raw bytes**. They are not text, they
// are not UTF-8, and they are not hex. BEP 3 says they go into the query string
// percent-encoded, which means: the characters in the unreserved set
// (A-Z a-z 0-9 - _ . ~) pass through as themselves and every other byte becomes
// `%XX`. A client that runs those bytes through a string escaper that assumes
// UTF-8 mangles anything above 0x7f — each invalid byte becomes U+FFFD, three
// bytes, and the tracker sees a 20-byte hash as something longer and files you
// under a swarm of one. `url_encode_bytes` below works on bytes and is tested
// against a hand-computed expected string in `selftest.odin`.
//
// Note also that `+` is NOT a space here and a space is `%20`: the query is
// percent-encoding, not form encoding.

import "core:strconv"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Percent-encoding
// ---------------------------------------------------------------------------

@(private = "file")
unreserved :: proc(c: u8) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~':
		return true
	}
	return false
}

// url_encode_bytes is the one that matters: it takes bytes, not a string, and
// it has no notion of character encoding at all.
url_encode_bytes :: proc(b: []u8, allocator := context.allocator) -> string {
	hex := HEX_UPPER
	out := make([dynamic]u8, 0, len(b) * 3, allocator)
	for c in b {
		if unreserved(c) {
			append(&out, c)
		} else {
			append(&out, '%', hex[c >> 4], hex[c & 15])
		}
	}
	return string(out[:])
}

url_encode :: proc(s: string, allocator := context.allocator) -> string {
	return url_encode_bytes(transmute([]u8)s, allocator)
}

url_decode :: proc(s: string, allocator := context.allocator) -> string {
	out := make([dynamic]u8, 0, len(s), allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi, ok1 := hex_nibble(s[i + 1])
			lo, ok2 := hex_nibble(s[i + 2])
			if ok1 && ok2 {
				append(&out, hi << 4 | lo)
				i += 3
				continue
			}
		}
		// A query string produced by a browser form uses '+' for a space. A
		// tracker announce never does, but a URL pasted by a human might, and
		// decoding it the lenient way loses nothing.
		if c == '+' {
			append(&out, ' ')
			i += 1
			continue
		}
		append(&out, c)
		i += 1
	}
	return string(out[:])
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

Url :: struct {
	scheme: string, // "http" or "udp"
	host:   string,
	port:   int,
	target: string, // path plus query, always starting with '/'
}

url_split :: proc(raw: string) -> (u: Url, err: string) {
	s := strings.trim_space(raw)
	sep := strings.index(s, "://")
	if sep < 0 {
		return {}, tsprint("%q has no scheme", raw)
	}
	u.scheme = s[:sep]
	rest := s[sep + 3:]
	switch u.scheme {
	case "http":
		u.port = 80
	case "udp":
		u.port = 0
	case "https":
		return {}, "https trackers are not supported by this client: there is no TLS here, and the only tracker it is allowed to reach is on loopback"
	case:
		return {}, tsprint("unsupported tracker scheme %q", u.scheme)
	}
	slash := strings.index_byte(rest, '/')
	authority := rest
	if slash >= 0 {
		authority = rest[:slash]
		u.target = rest[slash:]
	} else {
		u.target = "/"
	}
	if authority == "" {
		return {}, tsprint("%q has no host", raw)
	}
	if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		u.host = authority[:colon]
		p, ok := strconv.parse_int(authority[colon + 1:], 10)
		if !ok || p <= 0 || p > 65535 {
			return {}, tsprint("%q has a bad port", raw)
		}
		u.port = p
	} else {
		u.host = authority
	}
	if u.host == "" {
		return {}, tsprint("%q has no host", raw)
	}
	if u.port == 0 {
		return {}, tsprint("%q needs an explicit port", raw)
	}
	return u, ""
}

// ---------------------------------------------------------------------------
// A request
// ---------------------------------------------------------------------------

HTTP_MAX_BODY :: 8 << 20

// http_get performs one request and reads the whole response. The socket is
// non-blocking (everything from `sock_connect` is), so this polls; the deadline
// is in milliseconds and applies to the whole exchange.
//
// It goes through `sock_connect`, which is the gate. A tracker URL naming a
// real host never gets as far as a socket.
http_get :: proc(
	host: string,
	port: int,
	target: string,
	timeout_ms: i32 = 5000,
	allocator := context.allocator,
) -> (
	status: int,
	body: []u8,
	err: string,
) {
	s, cerr := sock_connect(host, port)
	if cerr != "" {
		return 0, nil, cerr
	}
	defer sock_close(s)

	req := tsprint(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUser-Agent: palmy-torrent/1.0\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n",
		target,
		host,
		port,
	)
	if werr := sock_write_all(s, transmute([]u8)req, timeout_ms); werr != "" {
		return 0, nil, werr
	}

	raw := make([dynamic]u8, 0, 4096, context.temp_allocator)
	deadline := now_s() + f64(timeout_ms) / 1000
	buf := make([]u8, 16 * 1024, context.temp_allocator)
	for {
		if now_s() > deadline {
			return 0, nil, tsprint("tracker at %s:%d did not answer in %dms", host, port, timeout_ms)
		}
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(s), events = {.IN}}}
		if poll_wait(fds[:], 200) <= 0 {
			continue
		}
		n, st := sock_read(s, buf)
		if st == .Again {
			continue
		}
		if st == .Closed {
			break
		}
		if st == .Error {
			return 0, nil, "the connection to the tracker failed mid-response"
		}
		append(&raw, ..buf[:n])
		if len(raw) > HTTP_MAX_BODY {
			return 0, nil, "the tracker's response is implausibly large"
		}
		// A Content-Length response can be complete before the close.
		if code, b, done := http_try_parse(raw[:]); done {
			return code, clone_bytes(b, allocator), ""
		}
	}
	code, b, done := http_try_parse(raw[:])
	if !done {
		// Connection: close with no Content-Length: the body is everything
		// after the header block, which is now complete because the peer went
		// away.
		hdr_end := bytes_index(raw[:], "\r\n\r\n")
		if hdr_end < 0 {
			return 0, nil, "the tracker sent no complete HTTP header"
		}
		code = http_status_of(string(raw[:hdr_end]))
		return code, clone_bytes(raw[hdr_end + 4:], allocator), ""
	}
	return code, clone_bytes(b, allocator), ""
}

sock_write_all :: proc(s: Sock, data: []u8, timeout_ms: i32) -> (err: string) {
	off := 0
	deadline := now_s() + f64(timeout_ms) / 1000
	for off < len(data) {
		n, st := sock_write(s, data[off:])
		if st == .Ok {
			off += n
			continue
		}
		if st != .Again {
			return "the connection closed while writing"
		}
		if now_s() > deadline {
			return "timed out writing"
		}
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(s), events = {.OUT}}}
		poll_wait(fds[:], 100)
	}
	return ""
}

// http_try_parse reports whether `raw` holds a complete response, using
// Content-Length only. Chunked transfer-encoding is not implemented: the only
// server this client talks to is the one in `trackerd.odin`, which always sends
// a length.
http_try_parse :: proc(raw: []u8) -> (status: int, body: []u8, done: bool) {
	hdr_end := bytes_index(raw, "\r\n\r\n")
	if hdr_end < 0 {
		return 0, nil, false
	}
	head := string(raw[:hdr_end])
	status = http_status_of(head)
	clen := -1
	for line in strings.split_lines_iterator(&head) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(line[:colon]), "content-length") {
			clen = parse_int_default(line[colon + 1:], -1)
		}
	}
	if clen < 0 {
		return status, nil, false
	}
	have := len(raw) - (hdr_end + 4)
	if have < clen {
		return status, nil, false
	}
	return status, raw[hdr_end + 4:hdr_end + 4 + clen], true
}

http_status_of :: proc(head: string) -> int {
	nl := strings.index_byte(head, '\n')
	first := nl < 0 ? head : head[:nl]
	fields := strings.fields(strings.trim_space(first), context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	return parse_int_default(fields[1], 0)
}

// ---------------------------------------------------------------------------
// Small byte helpers
// ---------------------------------------------------------------------------

bytes_index :: proc(haystack: []u8, needle: string) -> int {
	nb := transmute([]u8)needle
	if len(nb) == 0 || len(haystack) < len(nb) {
		return -1
	}
	outer: for i in 0 ..= len(haystack) - len(nb) {
		for j in 0 ..< len(nb) {
			if haystack[i + j] != nb[j] {
				continue outer
			}
		}
		return i
	}
	return -1
}

clone_bytes :: proc(b: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}

// query_param pulls one value out of `a=1&b=2`, percent-decoded. The value is
// returned as raw bytes because `info_hash` is twenty binary octets and
// treating it as a string is the bug this file is about.
query_param :: proc(query: string, key: string, allocator := context.allocator) -> (v: []u8, ok: bool) {
	q := query
	for field in strings.split_iterator(&q, "&") {
		eq := strings.index_byte(field, '=')
		if eq < 0 {
			if field == key {
				return nil, true
			}
			continue
		}
		if field[:eq] == key {
			return transmute([]u8)url_decode(field[eq + 1:], allocator), true
		}
	}
	return nil, false
}

query_param_str :: proc(query, key: string, allocator := context.allocator) -> (v: string, ok: bool) {
	b, found := query_param(query, key, allocator)
	return string(b), found
}

query_param_int :: proc(query, key: string, dflt: i64) -> i64 {
	s, ok := query_param_str(query, key, context.temp_allocator)
	if !ok {
		return dflt
	}
	v, good := strconv.parse_i64(strings.trim_space(s), 10)
	if !good {
		return dflt
	}
	return v
}
