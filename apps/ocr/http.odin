package main

// A minimal HTTP/1.1 client, because Odin's core has no HTTP, and TLS over the
// system OpenSSL, because it has none of that either.
//
// It exists for one caller — the Mistral OCR backend — and it is deliberately
// small: no redirects, no keep-alive reuse, no compression, no cookies. What
// it does have is the two things that matter when you are uploading somebody's
// document to a stranger:
//
//   **a gate.** `http_connect` is the only place in this program that opens a
//   socket to anything, and it refuses every non-loopback address unless the
//   endpoint was explicitly marked `allow_remote`. Nothing sets that but the
//   consented remote path. During development it is never set, which is how
//   the real endpoint is kept unreachable by construction rather than by my
//   remembering not to call it.
//
//   **framing that does not assume read boundaries.** A `recv` can land in the
//   middle of a chunk-size line, between a `\r` and a `\n`, or halfway through
//   a UTF-8 sequence. The decoder is a byte-at-a-time state machine kept free
//   of sockets, so the self-test can drive it with deliberately cruel splits.

import sysc "core:c"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// ---------------------------------------------------------------------------
// OpenSSL, the parts a client needs
// ---------------------------------------------------------------------------

foreign import libssl "system:ssl"
foreign import libcrypto "system:crypto"

SSL_VERIFY_NONE :: 0
SSL_VERIFY_PEER :: 1
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
TLSEXT_NAMETYPE_host_name :: 0
TLS1_2_VERSION :: 0x0303

@(default_calling_convention = "c")
foreign libssl {
	TLS_client_method :: proc() -> rawptr ---
	SSL_CTX_new :: proc(method: rawptr) -> rawptr ---
	SSL_CTX_free :: proc(ctx: rawptr) ---
	SSL_CTX_ctrl :: proc(ctx: rawptr, cmd: sysc.int, larg: sysc.long, parg: rawptr) -> sysc.long ---
	SSL_CTX_set_verify :: proc(ctx: rawptr, mode: sysc.int, cb: rawptr) ---
	SSL_CTX_set_default_verify_paths :: proc(ctx: rawptr) -> sysc.int ---
	SSL_new :: proc(ctx: rawptr) -> rawptr ---
	SSL_free :: proc(ssl: rawptr) ---
	SSL_set_fd :: proc(ssl: rawptr, fd: sysc.int) -> sysc.int ---
	SSL_ctrl :: proc(ssl: rawptr, cmd: sysc.int, larg: sysc.long, parg: rawptr) -> sysc.long ---
	SSL_set1_host :: proc(ssl: rawptr, host: cstring) -> sysc.int ---
	SSL_connect :: proc(ssl: rawptr) -> sysc.int ---
	SSL_read :: proc(ssl: rawptr, buf: rawptr, num: sysc.int) -> sysc.int ---
	SSL_write :: proc(ssl: rawptr, buf: rawptr, num: sysc.int) -> sysc.int ---
	SSL_shutdown :: proc(ssl: rawptr) -> sysc.int ---
	SSL_get_verify_result :: proc(ssl: rawptr) -> sysc.long ---
	SSL_get_version :: proc(ssl: rawptr) -> cstring ---
}

@(default_calling_convention = "c")
foreign libcrypto {
	ERR_get_error :: proc() -> sysc.ulong ---
	ERR_error_string_n :: proc(e: sysc.ulong, buf: [^]u8, len: sysc.size_t) ---
	X509_verify_cert_error_string :: proc(n: sysc.long) -> cstring ---
}

@(private = "file")
ssl_err :: proc() -> string {
	e := ERR_get_error()
	if e == 0 {
		return "no OpenSSL error queued"
	}
	buf: [256]u8
	ERR_error_string_n(e, raw_data(buf[:]), len(buf))
	return fmt.aprintf("%s", cstring(raw_data(buf[:])))
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

// is_loopback_literal parses an IPv4 literal and reports whether it is in
// 127/8. It does not resolve names: `localhost` is matched as a string,
// because a resolver can be told that `localhost` is anything at all.
is_loopback_literal :: proc(host: string) -> (net.IP4_Address, bool) {
	h := strings.trim_space(host)
	if h == "localhost" || h == "localhost.localdomain" || h == "127.0.0.1" {
		return net.IP4_Address{127, 0, 0, 1}, true
	}
	parts := strings.split(h, ".", context.temp_allocator)
	if len(parts) != 4 {
		return {}, false
	}
	out: net.IP4_Address
	for p, i in parts {
		v, ok := strconv.parse_int(p, 10)
		if !ok || v < 0 || v > 255 {
			return {}, false
		}
		out[i] = u8(v)
	}
	return out, out[0] == 127
}

Transport :: struct {
	sock:     net.TCP_Socket,
	fd:       linux.Fd,
	ssl:      rawptr,
	ssl_ctx:  rawptr,
	open:     bool,
	tls_desc: string, // heap-owned when TLS is up
}

// http_connect is the only socket this program opens.
//
// The refusal order matters: the gate is checked *before* any name resolution,
// so a hostname that is not loopback never even reaches a resolver when remote
// access is off. That is what makes "the real Mistral endpoint was never
// contacted" a property of the code and not a claim about my behaviour.
http_connect :: proc(ep: Endpoint, timeout_ms := 5000) -> (t: Transport, err: string) {
	if ep.port <= 0 || ep.port > 65535 {
		return {}, fmt.aprintf("implausible port %d", ep.port)
	}
	addr, loop := is_loopback_literal(ep.host)
	if !ep.allow_remote {
		if !loop {
			return {}, fmt.aprintf(
				"refusing to connect to %q: remote access is off, so only 127.0.0.0/8 is reachable. Nothing was sent.",
				ep.host,
			)
		}
	} else if !loop {
		eps, rerr := net.resolve_ip4(ep.host)
		if rerr != nil {
			return {}, fmt.aprintf("cannot resolve %s: %v", ep.host, rerr)
		}
		addr = eps.address.(net.IP4_Address) or_else net.IP4_Address{}
		if addr == {} {
			return {}, fmt.aprintf("%s resolved to no IPv4 address", ep.host)
		}
	}

	sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = addr, port = ep.port})
	if derr != nil {
		return {}, fmt.aprintf("cannot reach %s:%d (%v)", ep.host, ep.port, derr)
	}
	t.sock = sock
	t.fd = linux.Fd(i32(sock))
	t.open = true
	_ = net.set_option(sock, .Receive_Timeout, time.Duration(timeout_ms) * time.Millisecond)
	_ = net.set_option(sock, .TCP_Nodelay, true)

	if ep.tls {
		if terr := tls_up(&t, ep); terr != "" {
			http_disconnect(&t)
			return {}, terr
		}
	}
	return t, ""
}

@(private = "file")
tls_up :: proc(t: ^Transport, ep: Endpoint) -> string {
	method := TLS_client_method()
	if method == nil {
		return "OpenSSL: TLS_client_method() returned null"
	}
	ctx := SSL_CTX_new(method)
	if ctx == nil {
		return fmt.aprintf("OpenSSL: SSL_CTX_new: %s", ssl_err())
	}
	SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)
	if ep.tls_insecure {
		// Only ever set for the mock server's throwaway self-signed
		// certificate on loopback. It encrypts and authenticates nothing.
		SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
	} else {
		SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
		if SSL_CTX_set_default_verify_paths(ctx) != 1 {
			SSL_CTX_free(ctx)
			return fmt.aprintf("OpenSSL: cannot load the system trust store: %s", ssl_err())
		}
	}
	ssl := SSL_new(ctx)
	if ssl == nil {
		SSL_CTX_free(ctx)
		return fmt.aprintf("OpenSSL: SSL_new: %s", ssl_err())
	}
	if SSL_set_fd(ssl, sysc.int(t.fd)) != 1 {
		SSL_free(ssl);SSL_CTX_free(ctx)
		return fmt.aprintf("OpenSSL: SSL_set_fd: %s", ssl_err())
	}
	cname := strings.clone_to_cstring(ep.host, context.temp_allocator)
	SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(cname))
	if !ep.tls_insecure {
		// The function form of what used to be done by hand with
		// X509_check_host. Skipping it is how "verified TLS" ends up verifying
		// that the certificate was signed by somebody, for someone.
		if SSL_set1_host(ssl, cname) != 1 {
			SSL_free(ssl);SSL_CTX_free(ctx)
			return fmt.aprintf("OpenSSL: SSL_set1_host(%q) failed", ep.host)
		}
	}
	if rc := SSL_connect(ssl); rc != 1 {
		detail := ssl_err()
		if vr := SSL_get_verify_result(ssl); vr != 0 {
			detail = fmt.aprintf("%s (certificate: %s)", detail, X509_verify_cert_error_string(vr))
		}
		SSL_free(ssl);SSL_CTX_free(ctx)
		return fmt.aprintf("TLS handshake with %s:%d failed: %s", ep.host, ep.port, detail)
	}
	if !ep.tls_insecure {
		if vr := SSL_get_verify_result(ssl); vr != 0 {
			msg := fmt.aprintf("certificate rejected: %s", X509_verify_cert_error_string(vr))
			SSL_shutdown(ssl);SSL_free(ssl);SSL_CTX_free(ctx)
			return msg
		}
	}
	t.ssl = ssl
	t.ssl_ctx = ctx
	t.tls_desc = fmt.aprintf(
		"%s%s",
		SSL_get_version(ssl),
		ep.tls_insecure ? " (certificate NOT verified)" : " (certificate verified)",
	)
	return ""
}

http_disconnect :: proc(t: ^Transport) {
	if t.ssl != nil {
		SSL_shutdown(t.ssl)
		SSL_free(t.ssl)
		t.ssl = nil
	}
	if t.ssl_ctx != nil {
		SSL_CTX_free(t.ssl_ctx)
		t.ssl_ctx = nil
	}
	if t.open {
		net.close(t.sock)
		t.open = false
	}
	if t.tls_desc != "" {
		delete(t.tls_desc)
		t.tls_desc = ""
	}
}

http_send :: proc(t: ^Transport, data: []u8) -> string {
	sent := 0
	for sent < len(data) {
		n: int
		if t.ssl != nil {
			r := SSL_write(t.ssl, raw_data(data[sent:]), sysc.int(len(data) - sent))
			if r <= 0 {
				return fmt.aprintf("TLS write failed: %s", ssl_err())
			}
			n = int(r)
		} else {
			m, serr := net.send_tcp(t.sock, data[sent:])
			if serr != nil {
				return fmt.aprintf("send failed: %v", serr)
			}
			if m <= 0 {
				return "the connection closed while sending"
			}
			n = m
		}
		sent += n
	}
	return ""
}

// http_recv returns 0 with no error at end of stream.
http_recv :: proc(t: ^Transport, buf: []u8) -> (int, string) {
	if t.ssl != nil {
		r := SSL_read(t.ssl, raw_data(buf), sysc.int(len(buf)))
		if r > 0 {
			return int(r), ""
		}
		return 0, "" // close_notify, or a closed socket: treat as EOF
	}
	n, rerr := net.recv_tcp(t.sock, buf)
	if rerr != nil {
		if rerr == .Would_Block || rerr == .Timeout || rerr == .Interrupted {
			return 0, "the server stopped responding"
		}
		return 0, fmt.aprintf("recv failed: %v", rerr)
	}
	return n, ""
}

// ---------------------------------------------------------------------------
// Response framing
// ---------------------------------------------------------------------------

Decode_Stage :: enum u8 {
	Status,
	Headers,
	Chunk_Size,
	Chunk_Data,
	Chunk_CRLF,
	Length_Body,
	Until_Close,
	Done,
}

Decoder :: struct {
	stage:       Decode_Stage,
	pending:     [dynamic]u8,
	status:      int,
	reason:      string,
	chunked:     bool,
	content_len: int,
	left:        int,
	headers:     [dynamic]string,
	bad:         string,
}

decoder_make :: proc() -> Decoder {
	return Decoder {
		stage = .Status,
		content_len = -1,
		pending = make([dynamic]u8),
		headers = make([dynamic]string),
	}
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.pending)
	for h in d.headers {
		delete(h)
	}
	delete(d.headers)
	if d.reason != "" {delete(d.reason)}
}

decoder_header :: proc(d: ^Decoder, name: string) -> string {
	for h in d.headers {
		colon := strings.index_byte(h, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(h[:colon]), name) {
			return strings.trim_space(h[colon + 1:])
		}
	}
	return ""
}

decoder_done :: proc(d: ^Decoder) -> bool {return d.stage == .Done}

// decoder_feed consumes raw bytes and appends body bytes to `out`. It is safe
// to call with one byte or a megabyte, and with a slice that ends mid-frame.
decoder_feed :: proc(d: ^Decoder, data: []u8, out: ^[dynamic]u8) {
	i := 0
	for i < len(data) && d.stage != .Done && d.bad == "" {
		switch d.stage {
		case .Status, .Headers, .Chunk_Size, .Chunk_CRLF:
			b := data[i]
			i += 1
			if b != '\n' {
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
			n := min(d.left, len(data) - i)
			append(out, ..data[i:i + n])
			i += n
			d.left -= n
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

decoder_eof :: proc(d: ^Decoder) {
	if d.stage == .Until_Close {
		d.stage = .Done
	}
	if d.stage != .Done && d.bad == "" {
		d.bad = "the connection closed before the response ended"
	}
}

@(private = "file")
decoder_line :: proc(d: ^Decoder, line: string) {
	switch d.stage {
	case .Status:
		sp := strings.index_byte(line, ' ')
		if sp < 0 || !strings.has_prefix(line, "HTTP/") {
			d.bad = "the response did not start with a status line"
			return
		}
		rest := strings.trim_space(line[sp + 1:])
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
		d.reason = strings.clone(strings.trim_space(rest[min(end + 1, len(rest)):]))
		d.stage = .Headers

	case .Headers:
		if line == "" {
			te := decoder_header(d, "transfer-encoding")
			if strings.contains(strings.to_lower(te, context.temp_allocator), "chunked") {
				d.chunked = true
				d.stage = .Chunk_Size
				return
			}
			if cl := decoder_header(d, "content-length"); cl != "" {
				if n, ok := strconv.parse_int(cl); ok {
					d.content_len = n
					d.left = n
					d.stage = n == 0 ? .Done : .Length_Body
					return
				}
			}
			if d.status == 204 || d.status == 304 {
				d.stage = .Done
				return
			}
			d.stage = .Until_Close
			return
		}
		append(&d.headers, strings.clone(line))

	case .Chunk_Size:
		size := line
		if semi := strings.index_byte(size, ';'); semi >= 0 {
			size = size[:semi]
		}
		size = strings.trim_space(size)
		if size == "" {
			return
		}
		n, ok := strconv.parse_int(size, 16)
		if !ok {
			d.bad = fmt.aprintf("bad chunk size %q", size)
			return
		}
		if n == 0 {
			d.stage = .Done
			return
		}
		d.left = n
		d.stage = .Chunk_Data

	case .Chunk_CRLF:
		d.stage = .Chunk_Size

	case .Chunk_Data, .Length_Body, .Until_Close, .Done:
	}
}

// ---------------------------------------------------------------------------
// One request, one response
// ---------------------------------------------------------------------------

Http_Response :: struct {
	status: int,
	body:   string, // heap-owned
	ctype:  string, // heap-owned
}

response_destroy :: proc(r: ^Http_Response) {
	if r.body != "" {delete(r.body)}
	if r.ctype != "" {delete(r.ctype)}
	r^ = {}
}

// http_do writes one request and reads the whole response. `headers` are
// complete "Name: value" lines; Host, Content-Length and Connection are added
// here so a caller cannot forget them or set them twice.
http_do :: proc(
	ep: Endpoint,
	method, path: string,
	headers: []string,
	body: []u8,
	trace: ^Trace,
	timeout_ms := 60000,
	allocator := context.allocator,
) -> (
	res: Http_Response,
	err: string,
) {
	// The trace is written before the socket is opened, so a refused
	// connection still records what would have been sent.
	trace_request(trace, method, path, headers, len(body))

	t, cerr := http_connect(ep, 5000)
	if cerr != "" {
		return {}, cerr
	}
	defer http_disconnect(&t)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %s HTTP/1.1\r\n", method, path)
	fmt.sbprintf(&b, "Host: %s\r\n", ep.port == 443 || ep.port == 80 ? ep.host : fmt.tprintf("%s:%d", ep.host, ep.port))
	fmt.sbprint(&b, "User-Agent: palmy-ocr/1.0\r\n")
	fmt.sbprint(&b, "Accept: application/json\r\n")
	fmt.sbprint(&b, "Connection: close\r\n")
	for h in headers {
		fmt.sbprintf(&b, "%s\r\n", h)
	}
	fmt.sbprintf(&b, "Content-Length: %d\r\n", len(body))
	fmt.sbprint(&b, "\r\n")
	head := transmute([]u8)strings.to_string(b)

	if serr := http_send(&t, head); serr != "" {
		return {}, serr
	}
	if len(body) > 0 {
		if serr := http_send(&t, body); serr != "" {
			return {}, serr
		}
	}

	dec := decoder_make()
	defer decoder_destroy(&dec)
	out := make([dynamic]u8, context.temp_allocator)
	buf: [32 * 1024]u8
	started := time.tick_now()
	for !decoder_done(&dec) {
		n, rerr := http_recv(&t, buf[:])
		if rerr != "" {
			return {}, rerr
		}
		if n == 0 {
			decoder_eof(&dec)
			break
		}
		decoder_feed(&dec, buf[:n], &out)
		if dec.bad != "" {
			return {}, strings.clone(dec.bad, allocator)
		}
		if int(time.duration_milliseconds(time.tick_since(started))) > timeout_ms {
			return {}, fmt.aprintf("%s %s timed out after %d ms", method, path, timeout_ms)
		}
	}
	if dec.bad != "" {
		return {}, strings.clone(dec.bad, allocator)
	}
	return Http_Response {
			status = dec.status,
			body = strings.clone(string(out[:]), allocator),
			ctype = strings.clone(decoder_header(&dec, "content-type"), allocator),
		},
		""
}
