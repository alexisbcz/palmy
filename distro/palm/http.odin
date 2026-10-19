package palm

// An HTTP/1.1 client, enough for a package repository: GET over http:// or
// https:// (tls.odin), keep-alive, redirects, Range resumes, and bodies
// streamed to disk with their sha256 computed on the way.
//
// Plain http stays supported because the index signature, not the transport,
// is what makes a download trustworthy (apk's argument, and still true); the
// QEMU guest reaches its build host that way. https adds privacy and a check
// on who is answering -- see tls.odin.
//
// Connections are kept open between requests to the same scheme, host and
// port (Connection: keep-alive is HTTP/1.1's default) in a pool that belongs
// to the calling thread, so the parallel download workers in repo.odin each
// have their own and never share a socket. A pooled connection the server has
// since closed is noticed on the next request and replaced once, the way
// every keep-alive client must. Bodies are framed by Content-Length, by
// Transfer-Encoding: chunked, or by the server closing; only the first two
// leave the connection reusable.
//
// Redirects are followed up to five times, to any host, except from https to
// plain http: a downgrade is refused. No compression (Accept-Encoding:
// identity, so Content-Length is the file's size), no proxies, no cookies.

import "core:crypto/hash"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

HTTP_MAX_BODY :: 1 << 31

@(private = "file")
HTTP_MAX_HEADER :: 64 * 1024

Http_Url :: struct {
	https: bool,
	host:  string,
	port:  int,
	path:  string,
}

is_remote_url :: proc(s: string) -> bool {
	return strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://")
}

parse_http_url :: proc(url: string) -> (u: Http_Url, okk: bool) {
	rest: string
	switch {
	case strings.has_prefix(url, "http://"):
		rest = url[len("http://"):]
		u.port = 80
	case strings.has_prefix(url, "https://"):
		rest = url[len("https://"):]
		u.https = true
		u.port = 443
	case:
		return u, false
	}
	slash := strings.index_byte(rest, '/')
	hostport := rest
	u.path = "/"
	if slash >= 0 {
		hostport = rest[:slash]
		u.path = rest[slash:]
	}
	u.host = hostport
	if strings.has_prefix(hostport, "[") {
		// [v6]:port
		close := strings.index_byte(hostport, ']')
		if close < 0 {
			return u, false
		}
		u.host = hostport[1:close]
		if close + 1 < len(hostport) && hostport[close + 1] == ':' {
			p, okp := strconv.parse_int(hostport[close + 2:])
			if !okp {
				return u, false
			}
			u.port = p
		}
	} else if colon := strings.last_index_byte(hostport, ':'); colon >= 0 {
		p, okp := strconv.parse_int(hostport[colon + 1:])
		if !okp || p <= 0 || p > 65535 {
			return u, false
		}
		u.host = hostport[:colon]
		u.port = p
	}
	return u, u.host != ""
}

@(private = "file")
url_string :: proc(u: Http_Url) -> string {
	scheme := u.https ? "https" : "http"
	def := u.https ? 443 : 80
	host := strings.contains_rune(u.host, ':') ? fmt.tprintf("[%s]", u.host) : u.host
	if u.port == def {
		return fmt.tprintf("%s://%s%s", scheme, host, u.path)
	}
	return fmt.tprintf("%s://%s:%d%s", scheme, host, u.port, u.path)
}

// resolve_location turns a Location header into an absolute URL.
@(private = "file")
resolve_location :: proc(base: Http_Url, loc: string) -> string {
	if is_remote_url(loc) {
		return loc
	}
	b := base
	if strings.has_prefix(loc, "//") {
		return fmt.tprintf("%s:%s", b.https ? "https" : "http", loc)
	}
	if strings.has_prefix(loc, "/") {
		b.path = loc
		return url_string(b)
	}
	dir := b.path
	if q := strings.index_byte(dir, '?'); q >= 0 {dir = dir[:q]}
	b.path = strings.concatenate({dir[:strings.last_index_byte(dir, '/') + 1], loc}, context.temp_allocator)
	return url_string(b)
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

Conn :: struct {
	key:      string, // scheme://host:port, the pool's key
	host:     string,
	sock:     net.TCP_Socket,
	has_sock: bool,
	tls:      ^Tls,
	buf:      [dynamic]byte,
	off:      int,
	eof:      bool,
	used:     bool, // has carried a request before (so may be stale)
}

Http_Client :: struct {
	conns: map[string]^Conn,
}

// Each thread has its own pool; see the comment at the top.
@(thread_local)
tl_client: Http_Client

conn_open :: proc(u: Http_Url) -> (^Conn, Err) {
	c := new(Conn)
	c.key = strings.clone(fmt.tprintf("%s://%s:%d", u.https ? "https" : "http", u.host, u.port))
	c.host = strings.clone(u.host)
	sock, nerr := net.dial_tcp_from_hostname_with_port_override(u.host, u.port)
	if nerr != nil {
		free(c)
		return nil, fail(EXIT_UNAVAILABLE, "cannot connect to %s:%d (%v)", u.host, u.port, nerr)
	}
	c.sock = sock
	c.has_sock = true
	_ = net.set_option(sock, .Receive_Timeout, time.Second * 30)
	_ = net.set_option(sock, .Send_Timeout, time.Second * 30)
	_ = net.set_option(sock, .TCP_Nodelay, true)
	if u.https {
		t, e := tls_connect(sock, u.host)
		if !ok(e) {
			net.close(sock)
			free(t)
			free(c)
			return nil, e
		}
		c.tls = t
	}
	return c, Err{}
}

conn_close :: proc(c: ^Conn) {
	if c == nil {return}
	if c.tls != nil {
		tls_close(c.tls)
		c.tls = nil
	}
	if c.has_sock {
		net.close(c.sock)
		c.has_sock = false
	}
	delete(c.buf)
	free(c)
}

// http_close_all closes the calling thread's pooled connections.
http_close_all :: proc() {
	for _, c in tl_client.conns {
		conn_close(c)
	}
	clear(&tl_client.conns)
}

@(private = "file")
conn_write :: proc(c: ^Conn, data: []byte) -> Err {
	if c.tls != nil {
		return tls_write(c.tls, data)
	}
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(c.sock, data[sent:])
		if err != nil || n <= 0 {
			return fail(EXIT_UNAVAILABLE, "%s: send failed (%v)", c.host, err)
		}
		sent += n
	}
	return Err{}
}

// conn_fill reads more bytes into the buffer; 0 means the peer closed.
@(private = "file")
conn_fill :: proc(c: ^Conn) -> (int, Err) {
	if c.eof || !c.has_sock {
		c.eof = true
		return 0, Err{}
	}
	if c.off > 0 && c.off == len(c.buf) {
		clear(&c.buf)
		c.off = 0
	} else if c.off > 32 * 1024 {
		rem := len(c.buf) - c.off
		copy(c.buf[:rem], c.buf[c.off:])
		resize(&c.buf, rem)
		c.off = 0
	}
	tmp: [64 * 1024]byte
	n: int
	if c.tls != nil {
		e: Err
		n, e = tls_read(c.tls, tmp[:])
		if !ok(e) {
			return 0, e
		}
	} else {
		rerr: net.TCP_Recv_Error
		n, rerr = net.recv_tcp(c.sock, tmp[:])
		if rerr != nil {
			return 0, fail(EXIT_UNAVAILABLE, "%s: receive failed (%v)", c.host, rerr)
		}
	}
	if n == 0 {
		c.eof = true
		return 0, Err{}
	}
	append(&c.buf, ..tmp[:n])
	return n, Err{}
}

@(private = "file")
conn_line :: proc(c: ^Conn) -> (string, Err) {
	for {
		avail := string(c.buf[c.off:])
		if nl := strings.index(avail, "\r\n"); nl >= 0 {
			line := strings.clone(avail[:nl], context.temp_allocator)
			c.off += nl + 2
			return line, Err{}
		}
		if len(avail) > HTTP_MAX_HEADER {
			return "", fail(EXIT_UNAVAILABLE, "%s: header line too long", c.host)
		}
		n, e := conn_fill(c)
		if !ok(e) {
			return "", e
		}
		if n == 0 {
			return "", fail(EXIT_UNAVAILABLE, "%s: connection closed mid-response", c.host)
		}
	}
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

Http_Response :: struct {
	status:   int,
	location: string,
	length:   i64, // Content-Length, or -1
	chunked:  bool,
	close:    bool, // the server will close after this response
	range_at: i64, // the first byte of a 206 response, else 0
}

@(private = "file")
read_head :: proc(c: ^Conn, url: string) -> (r: Http_Response, e: Err) {
	r.length = -1
	line: string
	line, e = conn_line(c)
	if !ok(e) {
		return
	}
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 || !strings.has_prefix(fields[0], "HTTP/1.") {
		return r, fail(EXIT_UNAVAILABLE, "%s: malformed status line %q", url, line)
	}
	r.status, _ = strconv.parse_int(fields[1])
	r.close = fields[0] == "HTTP/1.0"
	for {
		line, e = conn_line(c)
		if !ok(e) {
			return
		}
		if line == "" {
			break
		}
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		k := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		v := strings.trim_space(line[colon + 1:])
		switch k {
		case "content-length":
			n, okn := strconv.parse_i64(v)
			if !okn || n < 0 {
				return r, fail(EXIT_UNAVAILABLE, "%s: bad Content-Length %q", url, v)
			}
			r.length = n
		case "transfer-encoding":
			r.chunked = strings.contains(strings.to_lower(v, context.temp_allocator), "chunked")
		case "connection":
			lv := strings.to_lower(v, context.temp_allocator)
			if strings.contains(lv, "close") {r.close = true}
			if strings.contains(lv, "keep-alive") {r.close = false}
		case "location":
			r.location = strings.clone(v)
		case "content-range":
			// bytes 100-999/1000
			s := strings.trim_prefix(v, "bytes ")
			if dash := strings.index_byte(s, '-'); dash > 0 {
				r.range_at, _ = strconv.parse_i64(s[:dash])
			}
		}
	}
	if r.chunked {
		r.length = -1
	}
	return r, Err{}
}

// Body is a response body being read.
Body :: struct {
	c:        ^Conn,
	r:        Http_Response,
	url:      string,
	left:     i64, // bytes left in the body (sized) or the current chunk
	done:     bool,
	reusable: bool,
}

@(private = "file")
body_start :: proc(c: ^Conn, r: Http_Response, url: string, head_only := false) -> Body {
	b := Body {
		c   = c,
		r   = r,
		url = url,
	}
	switch {
	case head_only || r.status == 204 || r.status == 304 || (r.status >= 100 && r.status < 200):
		b.done = true
		b.reusable = !r.close
	case r.chunked:
		b.left = 0
	case r.length >= 0:
		b.left = r.length
		if r.length == 0 {
			b.done = true
			b.reusable = !r.close
		}
	case:
		b.left = -1 // until the server closes
	}
	return b
}

// body_read fills out with body bytes; 0 means the body is complete.
body_read :: proc(b: ^Body, out: []byte) -> (int, Err) {
	if b.done || len(out) == 0 {
		return 0, Err{}
	}
	c := b.c
	if b.r.chunked && b.left == 0 {
		line, e := conn_line(c)
		if !ok(e) {
			return 0, fail(EXIT_UNAVAILABLE, "%s: truncated chunked body", b.url)
		}
		if semi := strings.index_byte(line, ';'); semi >= 0 {
			line = line[:semi]
		}
		size, okc := strconv.parse_i64_of_base(strings.trim_space(line), 16)
		if !okc || size < 0 {
			return 0, fail(EXIT_UNAVAILABLE, "%s: bad chunk size %q", b.url, line)
		}
		if size == 0 {
			// trailers, then the blank line
			for {
				t, te := conn_line(c)
				if !ok(te) {
					return 0, fail(EXIT_UNAVAILABLE, "%s: truncated chunked body", b.url)
				}
				if t == "" {break}
			}
			b.done = true
			b.reusable = !b.r.close
			return 0, Err{}
		}
		b.left = size
	}
	for c.off == len(c.buf) {
		n, e := conn_fill(c)
		if !ok(e) {
			return 0, e
		}
		if n == 0 {
			if b.left < 0 {
				b.done = true
				return 0, Err{}
			}
			return 0, fail(EXIT_UNAVAILABLE, "%s: body truncated", b.url)
		}
	}
	avail := len(c.buf) - c.off
	want := len(out)
	if b.left >= 0 && i64(want) > b.left {
		want = int(b.left)
	}
	n := copy(out[:min(want, avail)], c.buf[c.off:])
	c.off += n
	if b.left >= 0 {
		b.left -= i64(n)
		if b.left == 0 {
			if b.r.chunked {
				crlf, e := conn_line(c)
				if !ok(e) || crlf != "" {
					return 0, fail(EXIT_UNAVAILABLE, "%s: malformed chunk", b.url)
				}
			} else {
				b.done = true
				b.reusable = !b.r.close
			}
		}
	}
	return n, Err{}
}

// body_all reads the rest of the body into memory.
@(private = "file")
body_all :: proc(b: ^Body, allocator := context.allocator) -> ([]byte, Err) {
	out := make([dynamic]byte, 0, b.r.length > 0 ? int(min(b.r.length, 1 << 26)) : 4096, allocator)
	buf: [64 * 1024]byte
	for {
		n, e := body_read(b, buf[:])
		if !ok(e) {
			delete(out)
			return nil, e
		}
		if n == 0 {
			break
		}
		append(&out, ..buf[:n])
		if len(out) > HTTP_MAX_BODY {
			delete(out)
			return nil, fail(EXIT_FAILED, "%s: response too large", b.url)
		}
	}
	return out[:], Err{}
}

// body_finish puts the connection back in the pool if it can be reused,
// otherwise closes it. A body not read to its end is drained when small.
@(private = "file")
body_finish :: proc(b: ^Body) {
	if !b.done && b.r.length >= 0 && b.left >= 0 && b.left <= 64 * 1024 {
		buf: [16 * 1024]byte
		for !b.done {
			n, e := body_read(b, buf[:])
			if !ok(e) || n == 0 {break}
		}
	}
	c := b.c
	if b.done && b.reusable && !c.eof {
		c.used = true
		if old, has := tl_client.conns[c.key]; has && old != c {
			conn_close(old)
		}
		tl_client.conns[c.key] = c
		return
	}
	if cur, has := tl_client.conns[c.key]; has && cur == c {
		delete_key(&tl_client.conns, c.key)
	}
	conn_close(c)
}

// http_open sends one GET and reads the response head. The connection comes
// from the pool when one is open; a stale pooled one is replaced once.
http_open :: proc(url: string, range_from: i64 = 0) -> (Body, Err) {
	u, okk := parse_http_url(url)
	if !okk {
		return {}, fail(EXIT_USAGE, "not an http:// or https:// URL: %s", url)
	}
	host_header := u.host
	if strings.contains_rune(u.host, ':') {host_header = fmt.tprintf("[%s]", u.host)}
	if u.port != (u.https ? 443 : 80) {
		host_header = fmt.tprintf("%s:%d", host_header, u.port)
	}
	req := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&req, "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: palm/%s\r\nAccept: */*\r\nAccept-Encoding: identity\r\n", u.path, host_header, VERSION)
	if range_from > 0 {
		fmt.sbprintf(&req, "Range: bytes=%d-\r\n", range_from)
	}
	strings.write_string(&req, "\r\n")
	key := fmt.tprintf("%s://%s:%d", u.https ? "https" : "http", u.host, u.port)
	for attempt in 0 ..< 2 {
		c: ^Conn
		pooled := false
		if pc, has := tl_client.conns[key]; has && attempt == 0 {
			c = pc
			pooled = true
			delete_key(&tl_client.conns, key)
		} else {
			e: Err
			c, e = conn_open(u)
			if !ok(e) {
				return {}, e
			}
		}
		if e := conn_write(c, transmute([]byte)strings.to_string(req)); !ok(e) {
			conn_close(c)
			if pooled {continue}
			return {}, e
		}
		before := c.off
		r, e := read_head(c, url)
		if !ok(e) {
			// A kept-alive connection the server dropped answers with
			// nothing at all; that is worth one more try on a new one.
			stale := pooled && c.off == before && len(c.buf) == c.off
			conn_close(c)
			if stale {continue}
			return {}, e
		}
		return body_start(c, r, url), Err{}
	}
	return {}, fail(EXIT_UNAVAILABLE, "%s: the connection failed twice", url)
}

// http_get fetches a URL into memory, following redirects. A non-200 status
// is reported in `status` with a nil error, so the caller can treat 404 as
// "not here" rather than as a failure.
http_get :: proc(url: string, allocator := context.allocator) -> (body: []byte, status: int, e: Err) {
	target := url
	for _ in 0 ..< 6 {
		b: Body
		b, e = http_open(target)
		if !ok(e) {
			return nil, 0, e
		}
		status = b.r.status
		if is_redirect(status) && b.r.location != "" {
			next, re := follow(target, b.r.location)
			body_finish(&b)
			if !ok(re) {
				return nil, status, re
			}
			target = next
			continue
		}
		if status != 200 {
			body_finish(&b)
			return nil, status, Err{}
		}
		body, e = body_all(&b, allocator)
		body_finish(&b)
		return
	}
	return nil, status, fail(EXIT_UNAVAILABLE, "%s: too many redirects", url)
}

@(private = "file")
is_redirect :: proc(s: int) -> bool {
	return s == 301 || s == 302 || s == 303 || s == 307 || s == 308
}

@(private = "file")
follow :: proc(from, location: string) -> (string, Err) {
	u, _ := parse_http_url(from)
	next := resolve_location(u, location)
	if !is_remote_url(next) {
		return "", fail(EXIT_UNAVAILABLE, "%s redirects to %s, which is not http(s)://", from, next)
	}
	if u.https && !strings.has_prefix(next, "https://") {
		return "", fail(EXIT_REFUSED, "%s redirects to %s: a downgrade from https, refused", from, next)
	}
	return strings.clone(next), Err{}
}

// http_download streams url into dest, computing the sha256 on the way. A
// `<dest>.part` left by an interrupted download is resumed with a Range
// request (and restarted if the server ignores the range). The file appears
// at dest only when its sha256 is want_sha; a mismatch deletes it, and a
// mismatch on a resumed file is retried once from the start, in case the
// part on disk was the bad half. progress, when given, is called with the
// bytes so far.
http_download :: proc(url, dest, want_sha: string, want_size: i64 = -1) -> Err {
	part := fmt.tprintf("%s.part", dest)
	for attempt in 0 ..< 2 {
		have: i64 = 0
		if attempt == 0 {
			if fi, err := os.stat(part, context.temp_allocator); err == nil && fi.size > 0 && (want_size < 0 || fi.size < want_size) {
				have = fi.size
			}
		}
		if have == 0 {
			_ = os.remove(part)
		}
		got, e := download_once(url, part, have)
		if !ok(e) {
			return e
		}
		if got != want_sha {
			_ = os.remove(part)
			if have > 0 {
				continue // the resumed half may have been the bad one
			}
			return fail(EXIT_REFUSED, "%s: sha256 mismatch -- the file does not match the signed index (want %s, got %s); refusing", base_name(dest), want_sha, got)
		}
		if os.rename(part, dest) != nil {
			_ = os.remove(part)
			return fail(EXIT_FAILED, "cannot move %s into place", dest)
		}
		return Err{}
	}
	return fail(EXIT_REFUSED, "%s: sha256 mismatch after a fresh download; refusing", base_name(dest))
}

@(private = "file")
download_once :: proc(url, part: string, have: i64) -> (sha: string, e: Err) {
	target := url
	for _ in 0 ..< 6 {
		b: Body
		b, e = http_open(target, have)
		if !ok(e) {
			return
		}
		status := b.r.status
		if is_redirect(status) && b.r.location != "" {
			next, re := follow(target, b.r.location)
			body_finish(&b)
			if !ok(re) {
				return "", re
			}
			target = next
			continue
		}
		resumed := have > 0 && status == 206 && b.r.range_at == have
		if status != 200 && !resumed {
			body_finish(&b)
			if status == 416 && have > 0 {
				// The part is already whole (or the server cannot range it):
				// start again from nothing.
				_ = os.remove(part)
				return download_once(url, part, 0)
			}
			return "", fail(EXIT_UNAVAILABLE, "%s: HTTP %d", target, status)
		}
		h: hash.Context
		hash.init(&h, .SHA256)
		flags := os.File_Flags{.Write, .Create}
		if resumed {
			// Hash what is already there, then append.
			if prev, perr := os.open(part, {.Read}); perr == nil {
				buf: [64 * 1024]byte
				for {
					n, rerr := os.read(prev, buf[:])
					if n > 0 {hash.update(&h, buf[:n])}
					if rerr != nil || n <= 0 {break}
				}
				os.close(prev)
			}
			flags += {.Append}
		} else {
			flags += {.Trunc}
		}
		f, ferr := os.open(part, flags, os.perm_number(0o644))
		if ferr != nil {
			body_finish(&b)
			return "", fail(EXIT_FAILED, "cannot write %s: %v", part, ferr)
		}
		buf: [64 * 1024]byte
		for {
			n, re := body_read(&b, buf[:])
			if !ok(re) {
				os.close(f)
				body_finish(&b)
				return "", re
			}
			if n == 0 {break}
			hash.update(&h, buf[:n])
			if _, werr := os.write(f, buf[:n]); werr != nil {
				os.close(f)
				body_finish(&b)
				return "", fail(EXIT_FAILED, "cannot write %s: %v", part, werr)
			}
		}
		os.close(f)
		body_finish(&b)
		digest: [32]byte
		hash.final(&h, digest[:])
		return hex_encode(digest[:]), Err{}
	}
	return "", fail(EXIT_UNAVAILABLE, "%s: too many redirects", url)
}

// http_parse_response parses a whole response held in memory. The selftest
// feeds it chunked, sized and truncated responses; it runs the same code a
// socket does.
http_parse_response :: proc(resp: []byte, url: string, allocator := context.allocator) -> (body: []byte, status: int, location: string, e: Err) {
	c := new(Conn, context.temp_allocator)
	c.host = url
	c.buf = make([dynamic]byte, len(resp), context.temp_allocator)
	copy(c.buf[:], resp)
	r, he := read_head(c, url)
	if !ok(he) {
		return nil, 0, "", he
	}
	b := body_start(c, r, url)
	body, e = body_all(&b, allocator)
	return body, r.status, r.location, e
}
