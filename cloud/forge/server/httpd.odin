package main

// The HTTP/1.1 server side: just enough for git's smart-HTTP client, the git
// LFS client and the forge's own JSON clients.
//
// Implemented: request line and headers, Content-Length and chunked request
// bodies, `Content-Encoding: gzip` request bodies (git compresses large
// upload-pack negotiations), responses with a length or streamed until close.
// Not implemented: keep-alive (every response closes the connection, which
// git handles by reconnecting), pipelining, Expect: 100-continue (git does not
// send it over HTTP/1.1 by default), TLS (put a TLS terminator in front).

import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import wire "forge:wire"

MAX_HEAD :: 64 * 1024
MAX_BODY :: 1 << 30 // a push larger than 1 GiB is refused

Request :: struct {
	sock:    net.TCP_Socket,
	method:  string,
	path:    string, // decoded path, no query
	query:   string,
	headers: []wire.Header,
	body:    []u8,
	peer:    string,
}

Reader :: struct {
	sock: net.TCP_Socket,
	buf:  [dynamic]u8,
	pos:  int,
	eof:  bool,
}

fill :: proc(r: ^Reader) -> bool {
	if r.eof {
		return false
	}
	tmp: [64 * 1024]u8
	n, err := net.recv_tcp(r.sock, tmp[:])
	if err != nil || n <= 0 {
		r.eof = true
		return false
	}
	append(&r.buf, ..tmp[:n])
	return true
}

read_line :: proc(r: ^Reader, limit := MAX_HEAD) -> (string, bool) {
	for {
		rest := string(r.buf[r.pos:])
		if i := strings.index(rest, "\r\n"); i >= 0 {
			line := rest[:i]
			r.pos += i + 2
			return line, true
		}
		if len(rest) > limit || !fill(r) {
			return "", false
		}
	}
}

read_n :: proc(r: ^Reader, n: int) -> ([]u8, bool) {
	for len(r.buf) - r.pos < n {
		if !fill(r) {
			return nil, false
		}
	}
	out := r.buf[r.pos:r.pos + n]
	r.pos += n
	return out, true
}

query_param :: proc(query, name: string) -> string {
	for part in strings.split(query, "&", context.temp_allocator) {
		k, _, v := strings.partition(part, "=")
		if k == name {
			return url_decode(v)
		}
	}
	return ""
}

url_decode :: proc(s: string) -> string {
	if strings.index_any(s, "%+") < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&sb, u8(v))
				i += 3
				continue
			}
		}
		strings.write_byte(&sb, ' ' if c == '+' else c)
		i += 1
	}
	return strings.to_string(sb)
}

read_request :: proc(sock: net.TCP_Socket) -> (req: Request, status: int) {
	r := Reader {
		sock = sock,
		buf  = make([dynamic]u8, 0, 16 * 1024),
	}
	req.sock = sock
	line, ok := read_line(&r)
	if !ok {
		return req, 0
	}
	parts := strings.split(line, " ")
	if len(parts) != 3 || !strings.has_prefix(parts[2], "HTTP/1.") {
		return req, 400
	}
	req.method = parts[0]
	target := parts[1]
	p, _, qs := strings.partition(target, "?")
	req.path = url_decode(p)
	req.query = qs

	hs := make([dynamic]wire.Header)
	total := 0
	for {
		l, lok := read_line(&r)
		if !lok {
			return req, 400
		}
		if l == "" {
			break
		}
		total += len(l)
		if total > MAX_HEAD {
			return req, 431
		}
		colon := strings.index_byte(l, ':')
		if colon <= 0 {
			return req, 400
		}
		append(&hs, wire.Header{strings.to_lower(l[:colon]), strings.trim_space(l[colon + 1:])})
	}
	req.headers = hs[:]

	if strings.equal_fold(wire.header_get(req.headers, "transfer-encoding"), "chunked") {
		body := make([dynamic]u8)
		for {
			size_line, sok := read_line(&r)
			if !sok {
				return req, 400
			}
			if semi := strings.index_byte(size_line, ';'); semi >= 0 {
				size_line = size_line[:semi]
			}
			n, nok := strconv.parse_int(strings.trim_space(size_line), 16)
			if !nok || n < 0 {
				return req, 400
			}
			if n == 0 {
				// trailers, then the blank line
				for {
					t, tok := read_line(&r)
					if !tok || t == "" {
						break
					}
				}
				break
			}
			if len(body) + n > MAX_BODY {
				return req, 413
			}
			chunk, cok := read_n(&r, n)
			if !cok {
				return req, 400
			}
			append(&body, ..chunk)
			if _, crlf := read_line(&r); !crlf {
				return req, 400
			}
		}
		req.body = body[:]
	} else if cl := wire.header_get(req.headers, "content-length"); cl != "" {
		n, nok := strconv.parse_int(cl)
		if !nok || n < 0 {
			return req, 400
		}
		if n > MAX_BODY {
			return req, 413
		}
		data, dok := read_n(&r, n)
		if !dok {
			return req, 400
		}
		req.body = data
	}

	if strings.equal_fold(wire.header_get(req.headers, "content-encoding"), "gzip") && len(req.body) > 0 {
		out: bytes.Buffer
		if err := gzip.load_from_bytes(req.body, &out); err != nil {
			return req, 400
		}
		req.body = bytes.buffer_to_bytes(&out)
	}
	return req, 200
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 204:
		return "No Content"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 409:
		return "Conflict"
	case 413:
		return "Payload Too Large"
	case 415:
		return "Unsupported Media Type"
	case 422:
		return "Unprocessable Entity"
	case 431:
		return "Request Header Fields Too Large"
	case 500:
		return "Internal Server Error"
	case 502:
		return "Bad Gateway"
	}
	return "Status"
}

write_head :: proc(sock: net.TCP_Socket, status: int, content_type: string, length: int, extra: []wire.Header = nil) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	reason := status_text(status)
	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\nServer: palmforge\r\nConnection: close\r\n", status, reason)
	if content_type != "" {
		fmt.sbprintf(&sb, "Content-Type: %s\r\n", content_type)
	}
	if length >= 0 {
		fmt.sbprintf(&sb, "Content-Length: %d\r\n", length)
	}
	for h in extra {
		fmt.sbprintf(&sb, "%s: %s\r\n", h.name, h.value)
	}
	strings.write_string(&sb, "\r\n")
	return wire.send_all(sock, transmute([]u8)strings.to_string(sb))
}

respond :: proc(req: ^Request, status: int, content_type: string, body: []u8, extra: []wire.Header = nil) {
	write_head(req.sock, status, content_type, len(body), extra)
	if req.method != "HEAD" && len(body) > 0 {
		wire.send_all(req.sock, body)
	}
}

respond_json :: proc(req: ^Request, status: int, body: string) {
	respond(req, status, "application/json; charset=utf-8", transmute([]u8)body)
}

respond_error :: proc(req: ^Request, status: int, message: string, extra: []wire.Header = nil) {
	body := fmt.tprintf(`{{"error":%s}}`, wire.q(message))
	respond(req, status, "application/json; charset=utf-8", transmute([]u8)body, extra)
}

respond_text :: proc(req: ^Request, status: int, text: string, extra: []wire.Header = nil) {
	respond(req, status, "text/plain; charset=utf-8", transmute([]u8)text, extra)
}
