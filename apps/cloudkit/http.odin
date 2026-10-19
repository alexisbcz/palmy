package cloudkit

// HTTP/1.1, written against core:net, because Odin's core has no HTTP.
//
// It speaks to one Supabase API gateway. What it needs is the framing, done
// properly — Content-Length, chunked and read-to-close bodies, with a read
// landing anywhere — and streaming in both directions, so a Storage upload or
// download of a large file never sits in memory whole.
//
// The transport is a seam. A `Conn` is four procedures; `dial_plain` makes one
// over a TCP socket. An `https://` URL goes through `tls_dial`, which is nil
// until a TLS implementation sets it (the distro's package manager is growing
// one). Until then an https URL is refused with a clear error rather than
// silently sent in the clear.

import "core:fmt"
import "core:io"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// The transport seam
// ---------------------------------------------------------------------------

Conn :: struct {
	ctx:   rawptr,
	send:  proc(ctx: rawptr, data: []u8) -> (n: int, err: string),
	recv:  proc(ctx: rawptr, buf: []u8) -> (n: int, err: string), // n == 0: closed
	close: proc(ctx: rawptr),
}

Dial_Proc :: proc(host: string, port: int, timeout_ms: int) -> (c: Conn, err: string)

// tls_dial is what an https:// URL dials through. Set it once at startup from
// whatever provides TLS; it must verify the certificate against `host`.
tls_dial: Dial_Proc = nil

@(private = "file")
Plain :: struct {
	sock: net.TCP_Socket,
}

dial_plain :: proc(host: string, port: int, timeout_ms: int) -> (c: Conn, err: string) {
	ep: net.Endpoint
	if addr, ok := net.parse_ip4_address(host); ok {
		ep = net.Endpoint{address = addr, port = port}
	} else if host == "localhost" {
		ep = net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	} else {
		e4, rerr := net.resolve_ip4(host)
		if rerr != nil {
			return {}, fmt.aprintf("cannot resolve %s (%v)", host, rerr)
		}
		ep = net.Endpoint{address = e4.address, port = port}
	}
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		return {}, fmt.aprintf("cannot reach %s:%d (%v)", host, port, derr)
	}
	_ = net.set_option(sock, .Receive_Timeout, time.Duration(timeout_ms) * time.Millisecond)
	_ = net.set_option(sock, .Send_Timeout, time.Duration(timeout_ms) * time.Millisecond)
	_ = net.set_option(sock, .TCP_Nodelay, true)
	p := new(Plain)
	p.sock = sock
	return Conn {
			ctx = p,
			send = proc(ctx: rawptr, data: []u8) -> (int, string) {
				p := cast(^Plain)ctx
				n, e := net.send_tcp(p.sock, data)
				if e != nil {
					return 0, fmt.aprintf("send failed (%v)", e)
				}
				return n, ""
			},
			recv = proc(ctx: rawptr, buf: []u8) -> (int, string) {
				p := cast(^Plain)ctx
				n, e := net.recv_tcp(p.sock, buf)
				if e != nil {
					if e == .Timeout || e == .Would_Block {
						return 0, "timed out waiting for the server"
					}
					return 0, fmt.aprintf("receive failed (%v)", e)
				}
				return n, ""
			},
			close = proc(ctx: rawptr) {
				p := cast(^Plain)ctx
				net.close(p.sock)
				free(p)
			},
		},
		""
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

Url :: struct {
	tls:  bool,
	host: string,
	port: int,
	base: string, // path prefix with no trailing slash, usually ""
}

parse_url :: proc(s: string) -> (u: Url, ok: bool) {
	rest := s
	switch {
	case strings.has_prefix(rest, "http://"):
		rest = rest[len("http://"):]
		u.port = 80
	case strings.has_prefix(rest, "https://"):
		rest = rest[len("https://"):]
		u.tls = true
		u.port = 443
	case:
		return {}, false
	}
	slash := strings.index_byte(rest, '/')
	hostport := rest
	if slash >= 0 {
		hostport = rest[:slash]
		u.base = strings.trim_right(rest[slash:], "/")
	}
	if colon := strings.last_index_byte(hostport, ':'); colon >= 0 {
		p, pok := strconv.parse_int(hostport[colon + 1:])
		if !pok || p <= 0 || p > 65535 {
			return {}, false
		}
		u.port = p
		hostport = hostport[:colon]
	}
	if hostport == "" {
		return {}, false
	}
	u.host = hostport
	return u, true
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

Header :: struct {
	name, value: string,
}

Request :: struct {
	method:  string,
	path:    string, // absolute path with query, e.g. /rest/v1/identities?select=*
	headers: []Header,
	body:    []u8,
	// A streamed body: `body_len` bytes read from `body_from`. Used instead of
	// `body` for uploads, so a large file is never held in memory.
	body_from: Maybe(io.Reader),
	body_len:  i64,
	// A streamed response: the body is written here instead of returned.
	sink:    Maybe(io.Writer),
	timeout_ms: int,
}

Response :: struct {
	status:  int,
	headers: [dynamic]Header,
	body:    string, // empty when a sink took it
}

response_destroy :: proc(r: ^Response) {
	for h in r.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(r.headers)
	delete(r.body)
	r^ = {}
}

response_header :: proc(r: ^Response, name: string) -> string {
	for h in r.headers {
		if strings.equal_fold(h.name, name) {
			return h.value
		}
	}
	return ""
}

USER_AGENT_DEFAULT :: "palm-cloudkit/0.1"

// http_do sends one request on a fresh connection and reads the whole
// response. Transport failures come back as `err`; an HTTP error status is
// not an err, it is a response.
http_do :: proc(u: Url, req: Request, user_agent := USER_AGENT_DEFAULT) -> (resp: Response, err: string) {
	timeout := req.timeout_ms > 0 ? req.timeout_ms : 15000
	conn: Conn
	derr: string
	if u.tls {
		if tls_dial == nil {
			return {}, strings.clone("https needs a TLS transport; set cloudkit.tls_dial")
		}
		conn, derr = tls_dial(u.host, u.port, timeout)
	} else {
		conn, derr = dial_plain(u.host, u.port, timeout)
	}
	if derr != "" {
		return {}, derr
	}
	defer conn.close(conn.ctx)

	// The head.
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %s%s HTTP/1.1\r\n", req.method, u.base, req.path)
	default_port := u.tls ? 443 : 80
	if u.port == default_port {
		fmt.sbprintf(&b, "Host: %s\r\n", u.host)
	} else {
		fmt.sbprintf(&b, "Host: %s:%d\r\n", u.host, u.port)
	}
	fmt.sbprintf(&b, "User-Agent: %s\r\n", user_agent)
	fmt.sbprint(&b, "Connection: close\r\n")
	for h in req.headers {
		fmt.sbprintf(&b, "%s: %s\r\n", h.name, h.value)
	}
	_, streaming := req.body_from.?
	if streaming {
		fmt.sbprintf(&b, "Content-Length: %d\r\n", req.body_len)
	} else if len(req.body) > 0 || req.method == "POST" || req.method == "PATCH" || req.method == "PUT" {
		fmt.sbprintf(&b, "Content-Length: %d\r\n", len(req.body))
	}
	fmt.sbprint(&b, "\r\n")
	if e := send_all(conn, transmute([]u8)strings.to_string(b)); e != "" {
		return {}, e
	}

	// The body.
	if r, ok := req.body_from.?; ok {
		buf: [64 * 1024]u8
		left := req.body_len
		for left > 0 {
			want := min(i64(len(buf)), left)
			n, rerr := io.read(r, buf[:want])
			if n > 0 {
				if e := send_all(conn, buf[:n]); e != "" {
					return {}, e
				}
				left -= i64(n)
			}
			if rerr != nil && rerr != .None {
				if rerr == .EOF && left == 0 {
					break
				}
				return {}, fmt.aprintf("reading the upload failed (%v)", rerr)
			}
		}
	} else if len(req.body) > 0 {
		if e := send_all(conn, req.body); e != "" {
			return {}, e
		}
	}

	// The response.
	dec := decoder_make()
	defer decoder_destroy(&dec)
	body := make([dynamic]u8)
	sink, sinking := req.sink.?
	buf: [64 * 1024]u8
	for !decoder_done(&dec) {
		n, rerr := conn.recv(conn.ctx, buf[:])
		if rerr != "" {
			delete(body)
			return {}, rerr
		}
		if n == 0 {
			decoder_eof(&dec)
			break
		}
		decoder_feed(&dec, buf[:n], &body)
		if dec.bad != "" {
			break
		}
		if sinking && len(body) > 0 {
			if _, werr := io.write(sink, body[:]); werr != nil && werr != .None {
				delete(body)
				return {}, fmt.aprintf("writing the download failed (%v)", werr)
			}
			clear(&body)
		}
	}
	if dec.bad != "" {
		delete(body)
		return {}, strings.clone(dec.bad)
	}
	if sinking && len(body) > 0 {
		io.write(sink, body[:])
		clear(&body)
	}
	resp.status = dec.status
	resp.headers = dec.headers
	dec.headers = nil
	if sinking {
		delete(body)
	} else {
		resp.body = string(body[:])
	}
	return resp, ""
}

@(private = "file")
send_all :: proc(c: Conn, data: []u8) -> string {
	sent := 0
	for sent < len(data) {
		n, e := c.send(c.ctx, data[sent:])
		if e != "" {
			return e
		}
		if n <= 0 {
			return strings.clone("the connection closed while sending")
		}
		sent += n
	}
	return ""
}

// ---------------------------------------------------------------------------
// Response framing: a byte-at-a-time state machine that never assumes a read
// boundary means anything, kept free of sockets so the self-test can feed it
// cruel splits.
// ---------------------------------------------------------------------------

Decode_Stage :: enum u8 {
	Status,
	Headers,
	Chunk_Size,
	Chunk_Data,
	Chunk_CRLF,
	Trailers,
	Length_Body,
	Until_Close,
	Done,
}

Decoder :: struct {
	stage:       Decode_Stage,
	pending:     [dynamic]u8,
	status:      int,
	chunked:     bool,
	content_len: i64,
	left:        i64,
	headers:     [dynamic]Header,
	bad:         string,
	head_only:   bool, // a HEAD response, or 204/304: no body whatever the headers say
}

decoder_make :: proc() -> Decoder {
	return Decoder{stage = .Status, content_len = -1}
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.pending)
	for h in d.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(d.headers)
}

decoder_done :: proc(d: ^Decoder) -> bool {
	return d.stage == .Done
}

decoder_eof :: proc(d: ^Decoder) {
	if d.stage == .Until_Close {
		d.stage = .Done
	}
	if d.stage != .Done && d.bad == "" {
		d.bad = "the connection closed before the response ended"
	}
}

decoder_feed :: proc(d: ^Decoder, data: []u8, out: ^[dynamic]u8) {
	i := 0
	for i < len(data) && d.stage != .Done && d.bad == "" {
		switch d.stage {
		case .Status, .Headers, .Chunk_Size, .Chunk_CRLF, .Trailers:
			b := data[i]
			i += 1
			if b != '\n' {
				if len(d.pending) > 64 * 1024 {
					d.bad = "a header line is longer than 64 KiB"
					return
				}
				append(&d.pending, b)
				continue
			}
			line := string(d.pending[:])
			if len(line) > 0 && line[len(line) - 1] == '\r' {
				line = line[:len(line) - 1]
			}
			decoder_line(d, line)
			clear(&d.pending)
		case .Chunk_Data, .Length_Body:
			n := int(min(d.left, i64(len(data) - i)))
			append(out, ..data[i:i + n])
			i += n
			d.left -= i64(n)
			if d.left == 0 {
				d.stage = d.stage == .Chunk_Data ? .Chunk_CRLF : .Done
			}
		case .Until_Close:
			append(out, ..data[i:])
			i = len(data)
		case .Done:
		}
	}
}

@(private = "file")
decoder_line :: proc(d: ^Decoder, line: string) {
	switch d.stage {
	case .Status:
		if !strings.has_prefix(line, "HTTP/") {
			d.bad = "the response did not start with a status line"
			return
		}
		sp := strings.index_byte(line, ' ')
		rest := sp >= 0 ? strings.trim_space(line[sp + 1:]) : ""
		end := strings.index_byte(rest, ' ')
		if end < 0 {
			end = len(rest)
		}
		code, ok := strconv.parse_int(rest[:end])
		if !ok {
			d.bad = "the status line had no status code"
			return
		}
		d.status = code
		d.stage = .Headers
	case .Headers:
		if line == "" {
			// 1xx responses are interim (100 Continue): their headers end,
			// and the real status line follows.
			if d.status >= 100 && d.status < 200 {
				for h in d.headers {
					delete(h.name)
					delete(h.value)
				}
				clear(&d.headers)
				d.chunked = false
				d.content_len = -1
				d.stage = .Status
				return
			}
			switch {
			case d.head_only || d.status == 204 || d.status == 304:
				d.stage = .Done
			case d.chunked:
				d.stage = .Chunk_Size
			case d.content_len == 0:
				d.stage = .Done
			case d.content_len > 0:
				d.left = d.content_len
				d.stage = .Length_Body
			case:
				d.stage = .Until_Close
			}
			return
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			d.bad = "a header line had no colon"
			return
		}
		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])
		if strings.equal_fold(name, "Transfer-Encoding") && strings.contains(strings.to_lower(value, context.temp_allocator), "chunked") {
			d.chunked = true
		}
		if strings.equal_fold(name, "Content-Length") {
			n, ok := strconv.parse_i64(value)
			if !ok || n < 0 {
				d.bad = "the Content-Length header is not a number"
				return
			}
			d.content_len = n
		}
		append(&d.headers, Header{strings.clone(name), strings.clone(value)})
	case .Chunk_Size:
		size_text := line
		if semi := strings.index_byte(size_text, ';'); semi >= 0 {
			size_text = size_text[:semi]
		}
		size, ok := strconv.parse_i64_of_base(strings.trim_space(size_text), 16)
		if !ok || size < 0 {
			d.bad = "a chunk size was not hexadecimal"
			return
		}
		if size == 0 {
			d.stage = .Trailers
			return
		}
		d.left = size
		d.stage = .Chunk_Data
	case .Chunk_CRLF:
		if line != "" {
			d.bad = "a chunk was longer than its size said"
			return
		}
		d.stage = .Chunk_Size
	case .Trailers:
		if line == "" {
			d.stage = .Done
		}
	case .Chunk_Data, .Length_Body, .Until_Close, .Done:
	}
}
