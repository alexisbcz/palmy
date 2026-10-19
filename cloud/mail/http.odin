package main

// HTTP/1.1, both directions, in the subset this server needs.
//
// SERVER: GET, POST and OPTIONS; absolute-path targets; Content-Length request
// bodies (chunked requests are refused with 501); keep-alive, with
// `Connection: close` honoured; Content-Length responses. Taken from the JMAP
// front end of apps/mailcore/testserver.
//
// CLIENT: one request per connection to 127.0.0.1 (PostgREST and GoTrue on
// the dev stack), Content-Length or chunked responses. It never takes a host:
// the port is the whole address, so it cannot be pointed off the machine.

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

Http_Req :: struct {
	method:  string,
	target:  string,
	path:    string,
	query:   string,
	headers: [][2]string,
	body:    []u8,
	close:   bool,
}

HTTP_MAX_BODY :: 64 * 1024 * 1024

httpd_read :: proc(c: ^SConn) -> (req: Http_Req, ok: bool) {
	line, lok := sread_line(c)
	if !lok {
		return req, false
	}
	start := strings.clone(line, context.temp_allocator)
	f := strings.fields(start, context.temp_allocator)
	if len(f) < 3 {
		httpd_error(c, 400, "Bad Request", "malformed request line")
		return req, false
	}
	req.method = strings.to_upper(f[0], context.temp_allocator)
	req.target = f[1]
	req.path = req.target
	if q := strings.index_byte(req.target, '?'); q >= 0 {
		req.path = req.target[:q]
		req.query = req.target[q + 1:]
	}
	if f[2] == "HTTP/1.0" {
		req.close = true
	}
	hs := make([dynamic][2]string, 0, 16, context.temp_allocator)
	content_length := 0
	for i := 0; i < 128; i += 1 {
		hl, hok := sread_line(c)
		if !hok {
			return req, false
		}
		if hl == "" {
			break
		}
		h := strings.clone(hl, context.temp_allocator)
		colon := strings.index_byte(h, ':')
		if colon <= 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(h[:colon]), context.temp_allocator)
		val := strings.trim_space(h[colon + 1:])
		append(&hs, [2]string{name, val})
		switch name {
		case "content-length":
			content_length, _ = strconv.parse_int(val, 10)
		case "connection":
			if strings.equal_fold(val, "close") {req.close = true}
		case "transfer-encoding":
			httpd_error(c, 501, "Not Implemented", "this server does not accept chunked requests")
			return req, false
		}
	}
	req.headers = hs[:]
	if content_length > 0 {
		if content_length > HTTP_MAX_BODY {
			httpd_error(c, 413, "Payload Too Large", "request body too large")
			return req, false
		}
		body, bok := sread_exact(c, content_length, context.temp_allocator)
		if !bok {
			return req, false
		}
		req.body = body
	}
	return req, true
}

httpd_get :: proc(req: ^Http_Req, name: string) -> (string, bool) {
	for h in req.headers {
		if h[0] == name {
			return h[1], true
		}
	}
	return "", false
}

httpd_respond :: proc(
	c: ^SConn,
	status: int,
	reason: string,
	content_type: string,
	body: []u8,
	close := false,
	extra := "",
) {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\n", status, reason)
	fmt.sbprintf(&sb, "Content-Type: %s\r\n", content_type)
	fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(body))
	strings.write_string(&sb, "Cache-Control: no-store\r\n")
	strings.write_string(&sb, extra)
	fmt.sbprintf(&sb, "Connection: %s\r\n", close ? "close" : "keep-alive")
	strings.write_string(&sb, "\r\n")
	swrite_str(c, strings.to_string(sb))
	swrite(c, body)
	slog(c, "-> %d %s (%d octets)", status, reason, len(body))
}

// httpd_error returns an RFC 7807 problem-details object, which is what RFC
// 8620 3.6.1 asks for.
httpd_error :: proc(c: ^SConn, status: int, reason: string, detail: string, type := "about:blank") {
	body := fmt.tprintf(`{{"type":%s,"status":%d,"detail":%s}}`, jq(type), status, jq(detail))
	httpd_respond(c, status, reason, "application/problem+json", transmute([]u8)body, status >= 500)
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

Http_Resp :: struct {
	status:  int,
	headers: [][2]string,
	body:    []u8,
}

http_call :: proc(
	port: int,
	method, target: string,
	headers: [][2]string,
	body: []u8,
	allocator := context.temp_allocator,
) -> (
	resp: Http_Resp,
	err: string,
) {
	c, de := sdial_loopback(port, "http")
	if de != "" {
		return resp, de
	}
	defer sconn_close(&c)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n", method, target, port)
	for h in headers {
		if strings.index_any(h[1], "\r\n") >= 0 {
			return resp, "refusing a header value with a line break"
		}
		fmt.sbprintf(&sb, "%s: %s\r\n", h[0], h[1])
	}
	fmt.sbprintf(&sb, "Content-Length: %d\r\nConnection: close\r\n\r\n", len(body))
	if !swrite_str(&c, strings.to_string(sb)) || (len(body) > 0 && !swrite(&c, body)) {
		return resp, "short write"
	}
	status_line, sok := sread_line(&c, 60_000)
	if !sok {
		return resp, "no response"
	}
	sl := strings.clone(status_line, context.temp_allocator)
	parts := strings.fields(sl, context.temp_allocator)
	if len(parts) < 2 {
		return resp, fmt.tprintf("bad status line %q", sl)
	}
	resp.status, _ = strconv.parse_int(parts[1], 10)
	hs := make([dynamic][2]string, 0, 16, allocator)
	clen := -1
	chunked := false
	for {
		l, lok := sread_line(&c, 60_000)
		if !lok {
			return resp, "connection closed in headers"
		}
		if l == "" {
			break
		}
		colon := strings.index_byte(l, ':')
		if colon <= 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(l[:colon]), allocator)
		val := strings.clone(strings.trim_space(l[colon + 1:]), allocator)
		append(&hs, [2]string{name, val})
		if name == "content-length" {
			clen, _ = strconv.parse_int(val, 10)
		}
		if name == "transfer-encoding" && strings.contains(strings.to_lower(val, context.temp_allocator), "chunked") {
			chunked = true
		}
	}
	resp.headers = hs[:]
	switch {
	case chunked:
		out := make([dynamic]u8, 0, 4096, allocator)
		for {
			szl, zok := sread_line(&c, 60_000)
			if !zok {
				return resp, "connection closed in a chunked body"
			}
			z := strings.clone(szl, context.temp_allocator)
			if semi := strings.index_byte(z, ';'); semi >= 0 {
				z = z[:semi]
			}
			n, nok := strconv.parse_int(strings.trim_space(z), 16)
			if !nok || n < 0 {
				return resp, "bad chunk size"
			}
			if n == 0 {
				break
			}
			data, dok := sread_exact(&c, n, context.temp_allocator, 60_000)
			if !dok {
				return resp, "short chunk"
			}
			append(&out, ..data)
			sread_line(&c, 60_000)
		}
		resp.body = out[:]
	case clen >= 0:
		if clen > 0 {
			data, dok := sread_exact(&c, clen, allocator, 60_000)
			if !dok {
				return resp, "short body"
			}
			resp.body = data
		}
	case:
		out := make([dynamic]u8, 0, 4096, allocator)
		buf: [8192]u8
		for c.r < c.w {
			append(&out, ..c.buf[c.r:c.w])
			c.r = c.w
		}
		for {
			n, e := net.recv_tcp(c.sock, buf[:])
			if e != nil || n <= 0 {
				break
			}
			append(&out, ..buf[:n])
		}
		resp.body = out[:]
	}
	return resp, ""
}

// sdial_loopback connects to 127.0.0.1:port and nowhere else.
sdial_loopback :: proc(port: int, label: string) -> (c: SConn, err: string) {
	s, de := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port})
	if de != nil {
		return c, fmt.tprintf("dial 127.0.0.1:%d: %v", port, de)
	}
	return sconn_make(s, label, false), ""
}

// ---------------------------------------------------------------------------
// JSON text helpers
// ---------------------------------------------------------------------------

// jq quotes a JSON string. Bytes >= 0x80 pass through: the inputs are UTF-8.
jq :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&sb, "\\\"")
		case '\\':
			strings.write_string(&sb, "\\\\")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
			strings.write_string(&sb, "\\r")
		case '\t':
			strings.write_string(&sb, "\\t")
		case:
			if ch < 0x20 || ch == 0x7f {
				fmt.sbprintf(&sb, "\\u%04x", int(ch))
			} else {
				strings.write_byte(&sb, ch)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// jq_null quotes a string, or writes null for an empty one.
jq_null :: proc(s: string) -> string {
	return s == "" ? "null" : jq(s)
}

// jq_list renders a []string as a JSON array.
jq_list :: proc(xs: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	for x, i in xs {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(x))
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

// pg_array renders a []string as a Postgres array literal for PostgREST
// filters (`cs.{...}`) — every element double-quoted and escaped.
pg_array :: proc(xs: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	for x, i in xs {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_byte(&sb, '"')
		for k in 0 ..< len(x) {
			if x[k] == '"' || x[k] == '\\' {strings.write_byte(&sb, '\\')}
			strings.write_byte(&sb, x[k])
		}
		strings.write_byte(&sb, '"')
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

url_encode :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
		   ch == '-' || ch == '_' || ch == '.' || ch == '~' {
			strings.write_byte(&sb, ch)
		} else {
			fmt.sbprintf(&sb, "%%%02X", ch)
		}
	}
	return strings.to_string(sb)
}

url_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if s[i] == '%' && i + 2 < len(s) {
			hi, o1 := mm_hex(s[i + 1])
			lo, o2 := mm_hex(s[i + 2])
			if o1 && o2 {
				strings.write_byte(&sb, hi << 4 | lo)
				i += 3
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

// is_uuid: every id that reaches a PostgREST filter goes through this first,
// so a client-supplied id cannot smuggle filter syntax.
is_uuid :: proc(s: string) -> bool {
	if len(s) != 36 {
		return false
	}
	for i in 0 ..< 36 {
		ch := s[i]
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if ch != '-' {return false}
			continue
		}
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) {
			return false
		}
	}
	return true
}
