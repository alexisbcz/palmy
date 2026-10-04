package main

// Sockets, line framing, and TLS.
//
// SAFETY GATE
//
// `conn_dial` is the only place in this program that opens a socket, and it
// refuses any address that is not IPv4 loopback. There is no DNS resolution
// anywhere in mailcore: `localhost` is mapped to 127.0.0.1 by a literal string
// comparison, and every other name is rejected without a lookup. A mail engine
// that cannot accidentally reach a real provider is the only kind worth
// developing against.
//
// TLS
//
// Odin's core has no TLS, so this FFIs to the system OpenSSL (3.6.4 here).
// What is implemented: TLS 1.2+ client handshake, SNI, X.509 chain
// verification against a CA file or the system trust store, and RFC 6125
// hostname verification via SSL_set1_host. What is not: client certificates,
// OCSP/CRL, session resumption, and non-blocking handshakes. See the comment
// on `Tls_Mode` for the honest limits.

import sysc "core:c"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

CONN_BUF :: 64 * 1024
MAX_LINE :: 1 << 20 // an IMAP line longer than a megabyte is an attack

// ---------------------------------------------------------------------------
// OpenSSL FFI
// ---------------------------------------------------------------------------

foreign import libssl "system:ssl"
foreign import libcrypto "system:crypto"

SSL_VERIFY_NONE :: 0
SSL_VERIFY_PEER :: 1
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
TLSEXT_NAMETYPE_host_name :: 0
TLS1_2_VERSION :: 0x0303
SSL_ERROR_NONE :: 0
SSL_ERROR_ZERO_RETURN :: 6

@(default_calling_convention = "c")
foreign libssl {
	TLS_client_method :: proc() -> rawptr ---
	SSL_CTX_new :: proc(method: rawptr) -> rawptr ---
	SSL_CTX_free :: proc(ctx: rawptr) ---
	SSL_CTX_ctrl :: proc(ctx: rawptr, cmd: sysc.int, larg: sysc.long, parg: rawptr) -> sysc.long ---
	SSL_CTX_set_verify :: proc(ctx: rawptr, mode: sysc.int, cb: rawptr) ---
	SSL_CTX_load_verify_locations :: proc(ctx: rawptr, ca_file: cstring, ca_path: cstring) -> sysc.int ---
	SSL_CTX_set_default_verify_paths :: proc(ctx: rawptr) -> sysc.int ---
	SSL_new :: proc(ctx: rawptr) -> rawptr ---
	SSL_free :: proc(ssl: rawptr) ---
	SSL_set_fd :: proc(ssl: rawptr, fd: sysc.int) -> sysc.int ---
	SSL_ctrl :: proc(ssl: rawptr, cmd: sysc.int, larg: sysc.long, parg: rawptr) -> sysc.long ---
	SSL_set1_host :: proc(ssl: rawptr, host: cstring) -> sysc.int ---
	SSL_connect :: proc(ssl: rawptr) -> sysc.int ---
	SSL_read :: proc(ssl: rawptr, buf: rawptr, num: sysc.int) -> sysc.int ---
	SSL_write :: proc(ssl: rawptr, buf: rawptr, num: sysc.int) -> sysc.int ---
	SSL_pending :: proc(ssl: rawptr) -> sysc.int ---
	SSL_shutdown :: proc(ssl: rawptr) -> sysc.int ---
	SSL_get_error :: proc(ssl: rawptr, ret: sysc.int) -> sysc.int ---
	SSL_get_verify_result :: proc(ssl: rawptr) -> sysc.long ---
	SSL_get_version :: proc(ssl: rawptr) -> cstring ---
	SSL_get_current_cipher :: proc(ssl: rawptr) -> rawptr ---
	SSL_CIPHER_get_name :: proc(ci: rawptr) -> cstring ---
}

@(default_calling_convention = "c")
foreign libcrypto {
	ERR_get_error :: proc() -> sysc.ulong ---
	ERR_error_string_n :: proc(e: sysc.ulong, buf: [^]u8, len: sysc.size_t) ---
	X509_verify_cert_error_string :: proc(n: sysc.long) -> cstring ---
}

// Tls_Mode says exactly how much the client checks.
//
//	.None      plaintext; nothing is encrypted. This is what the local test
//	           server speaks, and it is honest about it.
//	.Verify    full TLS: chain verified against `ca_file` (or the system store
//	           when empty) and the hostname checked against the certificate.
//	.Insecure  the handshake happens and the traffic is encrypted, but the
//	           certificate is not checked. Only for a throwaway self-signed
//	           cert on loopback; it provides no authentication whatsoever.
Tls_Mode :: enum u8 {
	None,
	Verify,
	Insecure,
}

Dial_Opts :: struct {
	tls:        Tls_Mode,
	ca_file:    string, // PEM bundle for .Verify; empty = system trust store
	verify_name: string, // name checked against the cert; defaults to the host
	trace:      bool,
	timeout_ms: i32,
}

Conn :: struct {
	sock:      net.TCP_Socket,
	fd:        linux.Fd,
	ssl:       rawptr,
	ssl_ctx:   rawptr,
	open:      bool,
	host:      string,
	port:      int,
	tls:       Tls_Mode,
	tls_desc:  string, // "TLSv1.3 / TLS_AES_256_GCM_SHA384"
	trace:     bool,
	label:     string,
	buf:       []u8,
	r, w:      int,
	line:      [dynamic]u8,
	eof:       bool,
	bytes_in:  int,
	bytes_out: int,
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
// The loopback-only gate
// ---------------------------------------------------------------------------

// loopback_address parses `host` as an IPv4 literal and insists on 127/8.
//
// This does not resolve names. "localhost" is special-cased by string compare
// because that is the only hostname a loopback test server is ever called, and
// it has to work for TLS hostname verification. Everything else is refused —
// which is what keeps this program away from a real mail provider by
// construction rather than by discipline.
loopback_address :: proc(host: string) -> (addr: net.IP4_Address, err: string) {
	h := strings.trim_space(host)
	if h == "localhost" || h == "localhost.localdomain" {
		return net.IP4_Address{127, 0, 0, 1}, ""
	}
	parts := strings.split(h, ".", context.temp_allocator)
	if len(parts) != 4 {
		return {}, fmt.aprintf(
			"refusing to connect to %q: mailcore only ever speaks to IPv4 loopback, and it does not resolve names",
			host,
		)
	}
	out: net.IP4_Address
	for p, i in parts {
		v, ok := strconv.parse_int(p, 10)
		if !ok || v < 0 || v > 255 {
			return {}, fmt.aprintf("refusing to connect to %q: not an IPv4 literal", host)
		}
		out[i] = u8(v)
	}
	if out[0] != 127 {
		return {}, fmt.aprintf(
			"refusing to connect to %q: %d.%d.%d.%d is not loopback. mailcore never contacts a real mail host.",
			host,
			out[0],
			out[1],
			out[2],
			out[3],
		)
	}
	return out, ""
}

// ---------------------------------------------------------------------------
// Dialling
// ---------------------------------------------------------------------------

conn_dial :: proc(
	c: ^Conn,
	host: string,
	port: int,
	opts: Dial_Opts = {},
	label := "conn",
) -> (
	err: string,
) {
	addr, aerr := loopback_address(host)
	if aerr != "" {
		return aerr
	}
	if port <= 0 || port > 65535 {
		return fmt.aprintf("implausible port %d", port)
	}

	sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = addr, port = port})
	if derr != nil {
		return fmt.aprintf("connect %s:%d: %v", host, port, derr)
	}
	c.sock = sock
	c.fd = linux.Fd(i32(sock))
	c.open = true
	c.host = strings.clone(host)
	c.port = port
	c.trace = opts.trace
	c.label = strings.clone(label)
	c.buf = make([]u8, CONN_BUF)
	c.line = make([dynamic]u8, 0, 1024)
	c.tls = .None

	if opts.tls != .None {
		if terr := conn_start_tls(c, opts); terr != "" {
			conn_close(c)
			return terr
		}
	}
	conn_trace(c, "connected to %s:%d%s", host, port, c.tls == .None ? " (plaintext)" : "")
	return ""
}

// conn_start_tls performs the handshake on an already-connected socket. It is
// called both for implicit TLS (right after connect) and for STARTTLS (after
// the protocol says to).
conn_start_tls :: proc(c: ^Conn, opts: Dial_Opts) -> (err: string) {
	if !c.open {
		return "not connected"
	}
	if c.ssl != nil {
		return "TLS already established on this connection"
	}
	// Any plaintext still sitting in the read buffer at this point would be a
	// STARTTLS command-injection hole (CVE-2011-0411). Refuse rather than
	// discard, so a buggy caller is loud instead of insecure.
	if c.r != c.w {
		return "refusing to start TLS with unread plaintext buffered (possible command injection)"
	}

	method := TLS_client_method()
	if method == nil {
		return "OpenSSL: TLS_client_method() returned null"
	}
	ctx := SSL_CTX_new(method)
	if ctx == nil {
		return fmt.aprintf("OpenSSL: SSL_CTX_new: %s", ssl_err())
	}
	SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)

	name := opts.verify_name != "" ? opts.verify_name : c.host
	switch opts.tls {
	case .Verify:
		SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
		if opts.ca_file != "" {
			caf := strings.clone_to_cstring(opts.ca_file, context.temp_allocator)
			if SSL_CTX_load_verify_locations(ctx, caf, nil) != 1 {
				SSL_CTX_free(ctx)
				return fmt.aprintf("OpenSSL: cannot load CA file %q: %s", opts.ca_file, ssl_err())
			}
		} else if SSL_CTX_set_default_verify_paths(ctx) != 1 {
			SSL_CTX_free(ctx)
			return fmt.aprintf("OpenSSL: cannot load the system trust store: %s", ssl_err())
		}
	case .Insecure:
		SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
	case .None:
		SSL_CTX_free(ctx)
		return "conn_start_tls called with Tls_Mode.None"
	}

	ssl := SSL_new(ctx)
	if ssl == nil {
		SSL_CTX_free(ctx)
		return fmt.aprintf("OpenSSL: SSL_new: %s", ssl_err())
	}
	if SSL_set_fd(ssl, sysc.int(c.fd)) != 1 {
		SSL_free(ssl);SSL_CTX_free(ctx)
		return fmt.aprintf("OpenSSL: SSL_set_fd: %s", ssl_err())
	}
	// SNI, plus the actual hostname check. SSL_set1_host is the function form
	// of what everyone used to do by hand with X509_check_host, and getting it
	// wrong is how "verified TLS" ends up verifying nothing.
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(cname))
	if opts.tls == .Verify {
		if SSL_set1_host(ssl, cname) != 1 {
			SSL_free(ssl);SSL_CTX_free(ctx)
			return fmt.aprintf("OpenSSL: SSL_set1_host(%q) failed", name)
		}
	}

	if rc := SSL_connect(ssl); rc != 1 {
		detail := ssl_err()
		vr := SSL_get_verify_result(ssl)
		if vr != 0 {
			detail = fmt.aprintf(
				"%s (certificate: %s)",
				detail,
				X509_verify_cert_error_string(vr),
			)
		}
		SSL_free(ssl);SSL_CTX_free(ctx)
		return fmt.aprintf("TLS handshake with %s:%d failed: %s", c.host, c.port, detail)
	}
	if opts.tls == .Verify {
		if vr := SSL_get_verify_result(ssl); vr != 0 {
			msg := fmt.aprintf("certificate rejected: %s", X509_verify_cert_error_string(vr))
			SSL_shutdown(ssl);SSL_free(ssl);SSL_CTX_free(ctx)
			return msg
		}
	}

	c.ssl = ssl
	c.ssl_ctx = ctx
	c.tls = opts.tls
	ver := SSL_get_version(ssl)
	ciph := SSL_get_current_cipher(ssl)
	cn: cstring = ciph != nil ? SSL_CIPHER_get_name(ciph) : "?"
	c.tls_desc = fmt.aprintf(
		"%s / %s%s",
		ver,
		cn,
		opts.tls == .Insecure ? " (certificate NOT verified)" : " (certificate verified)",
	)
	conn_trace(c, "TLS up: %s", c.tls_desc)
	return ""
}

conn_close :: proc(c: ^Conn) {
	if c.ssl != nil {
		SSL_shutdown(c.ssl)
		SSL_free(c.ssl)
		c.ssl = nil
	}
	if c.ssl_ctx != nil {
		SSL_CTX_free(c.ssl_ctx)
		c.ssl_ctx = nil
	}
	if c.open {
		net.close(c.sock)
		c.open = false
	}
	if c.buf != nil {
		delete(c.buf)
		c.buf = nil
	}
	delete(c.line)
	c.line = nil
	c.r, c.w = 0, 0
}

conn_trace :: proc(c: ^Conn, format: string, args: ..any) {
	if !c.trace {
		return
	}
	fmt.eprintf("[%s] ", c.label)
	fmt.eprintfln(format, ..args)
}

// ---------------------------------------------------------------------------
// Raw I/O
// ---------------------------------------------------------------------------

conn_write :: proc(c: ^Conn, data: []u8) -> bool {
	if !c.open || len(data) == 0 {
		return c.open
	}
	off := 0
	for off < len(data) {
		n: int
		if c.ssl != nil {
			r := SSL_write(c.ssl, raw_data(data[off:]), sysc.int(len(data) - off))
			if r <= 0 {
				c.open = false
				return false
			}
			n = int(r)
		} else {
			r, e := net.send_tcp(c.sock, data[off:])
			if e != nil || r <= 0 {
				c.open = false
				return false
			}
			n = r
		}
		off += n
		c.bytes_out += n
	}
	return true
}

conn_write_str :: proc(c: ^Conn, s: string) -> bool {
	return conn_write(c, transmute([]u8)s)
}

// conn_fill pulls one chunk into the buffer. `timeout_ms < 0` blocks.
@(private = "file")
conn_fill :: proc(c: ^Conn, timeout_ms: i32 = -1) -> bool {
	if !c.open {
		return false
	}
	if c.r > 0 {
		// Compact rather than grow: the buffer is a window, not a log.
		copy(c.buf, c.buf[c.r:c.w])
		c.w -= c.r
		c.r = 0
	}
	if c.w == len(c.buf) {
		return false // caller must consume before more can arrive
	}
	// With TLS, bytes may already be decrypted and waiting inside OpenSSL, in
	// which case polling the fd would block forever.
	if timeout_ms >= 0 && !(c.ssl != nil && SSL_pending(c.ssl) > 0) {
		fds := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		n, e := linux.poll(fds[:], timeout_ms)
		if e != .NONE || n <= 0 {
			return false
		}
	}
	if c.ssl != nil {
		r := SSL_read(c.ssl, raw_data(c.buf[c.w:]), sysc.int(len(c.buf) - c.w))
		if r <= 0 {
			c.eof = true
			if SSL_get_error(c.ssl, r) != SSL_ERROR_ZERO_RETURN {
				c.open = false
			}
			return false
		}
		c.w += int(r)
		c.bytes_in += int(r)
		return true
	}
	n, e := net.recv_tcp(c.sock, c.buf[c.w:])
	if e != nil || n <= 0 {
		c.eof = true
		if n <= 0 {
			c.open = false
		}
		return false
	}
	c.w += n
	c.bytes_in += n
	return true
}

// conn_pending reports whether a byte is already available.
conn_readable :: proc(c: ^Conn, timeout_ms: i32 = 0) -> bool {
	if c.r != c.w {
		return true
	}
	if !c.open {
		return false
	}
	if c.ssl != nil && SSL_pending(c.ssl) > 0 {
		return true
	}
	fds := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
	n, e := linux.poll(fds[:], timeout_ms)
	if e != .NONE || n <= 0 {
		return false
	}
	return .IN in fds[0].revents || .HUP in fds[0].revents
}

// conn_read_line returns one CRLF-terminated line with the terminator removed.
//
// The returned slice points into a buffer owned by the connection and is only
// valid until the next read. Callers that keep it must clone it. This is on
// purpose: an IMAP FETCH of a mailbox is thousands of lines, and allocating
// each one is the difference between a sync that feels instant and one that
// does not.
conn_read_line :: proc(c: ^Conn, timeout_ms: i32 = 30_000) -> (line: string, ok: bool) {
	clear(&c.line)
	for {
		// Scan what we already have for a newline.
		for i := c.r; i < c.w; i += 1 {
			if c.buf[i] != '\n' {
				continue
			}
			end := i
			if end > c.r && c.buf[end - 1] == '\r' {
				end -= 1
			}
			append(&c.line, ..c.buf[c.r:end])
			c.r = i + 1
			return string(c.line[:]), true
		}
		// No newline: keep what we have and read more.
		append(&c.line, ..c.buf[c.r:c.w])
		c.r = c.w
		if len(c.line) > MAX_LINE {
			c.open = false
			return "", false
		}
		if !conn_fill(c, timeout_ms) {
			// A final line with no terminator is still a line.
			if len(c.line) > 0 {
				return string(c.line[:]), true
			}
			return "", false
		}
	}
}

// conn_read_exact reads exactly n octets, which is what an IMAP literal needs.
conn_read_exact :: proc(
	c: ^Conn,
	n: int,
	allocator := context.allocator,
	timeout_ms: i32 = 60_000,
) -> (
	data: []u8,
	ok: bool,
) {
	if n < 0 {
		return nil, false
	}
	out := make([]u8, n, allocator)
	off := 0
	for off < n {
		if c.r == c.w {
			if !conn_fill(c, timeout_ms) {
				delete(out, allocator)
				return nil, false
			}
		}
		avail := c.w - c.r
		take := min(avail, n - off)
		copy(out[off:], c.buf[c.r:c.r + take])
		c.r += take
		off += take
	}
	return out, true
}

// conn_discard throws away whatever is buffered, used when abandoning a
// protocol state we cannot recover.
conn_discard :: proc(c: ^Conn) {
	c.r, c.w = 0, 0
}
