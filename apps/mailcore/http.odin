package main

// A minimal HTTP/1.1 client, written because JMAP is JSON over HTTP and Odin's
// core:net is sockets only.
//
// WHAT IS IMPLEMENTED — and nothing more, because both ends of this
// conversation are in this repository:
//
//	requests   GET and POST, absolute-path request targets, Host (mandatory
//	           in 1.1), Content-Length bodies, Authorization, Accept,
//	           Content-Type, and keep-alive connection reuse.
//	responses  the status line, folded-header-free header block,
//	           Content-Length bodies, `Transfer-Encoding: chunked` bodies
//	           (including the trailer), and read-to-close when the server
//	           says `Connection: close` with no length.
//
// WHAT IS NOT: HTTP/2 and /3, redirects, cookies, content negotiation,
// compression, 100-continue, trailers' contents, proxies, pipelining, and
// chunk extensions (they are skipped, not parsed). A response with neither a
// length nor chunked encoding nor a close is an error rather than a hang.

import "core:fmt"
import "core:strconv"
import "core:strings"

Http_Header :: struct {
	name:  string, // lowercased
	value: string,
}

Http_Request :: struct {
	method:  string,
	target:  string, // "/jmap/api"
	host:    string, // "127.0.0.1:18143"
	headers: []Http_Header,
	body:    []u8,
}

Http_Response :: struct {
	status:  int,
	reason:  string,
	headers: []Http_Header,
	body:    []u8,
	close:   bool, // the server asked for the connection to be dropped
}

http_header :: proc(headers: []Http_Header, name: string) -> (string, bool) {
	for h in headers {
		if h.name == name {
			return h.value, true
		}
	}
	return "", false
}

// http_do writes a request and reads exactly one response off `c`.
http_do :: proc(
	c: ^Conn,
	req: Http_Request,
	allocator := context.allocator,
) -> (
	resp: Http_Response,
	err: string,
) {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s %s HTTP/1.1\r\n", req.method, req.target)
	fmt.sbprintf(&sb, "Host: %s\r\n", req.host)
	have_len := false
	for h in req.headers {
		// A header value with CR or LF in it is a request-splitting attempt.
		if strings.index_byte(h.value, '\r') >= 0 || strings.index_byte(h.value, '\n') >= 0 {
			return resp, fmt.aprintf("refusing a header value with a line break: %q", h.name)
		}
		if strings.equal_fold(h.name, "content-length") {
			have_len = true
		}
		fmt.sbprintf(&sb, "%s: %s\r\n", h.name, h.value)
	}
	if !have_len && (len(req.body) > 0 || req.method == "POST" || req.method == "PUT") {
		fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(req.body))
	}
	strings.write_string(&sb, "\r\n")
	if !conn_write_str(c, strings.to_string(sb)) {
		return resp, "short write sending an HTTP request"
	}
	if len(req.body) > 0 && !conn_write(c, req.body) {
		return resp, "short write sending an HTTP body"
	}

	// --- status line --------------------------------------------------------
	status_raw, ok := conn_read_line(c, 60_000)
	if !ok {
		return resp, "no HTTP response"
	}
	status_line := strings.clone(status_raw, context.temp_allocator)
	sp1 := strings.index_byte(status_line, ' ')
	if sp1 < 0 || !strings.has_prefix(status_line, "HTTP/1.") {
		return resp, fmt.aprintf("malformed HTTP status line %q", status_line)
	}
	rest := status_line[sp1 + 1:]
	code_end := strings.index_byte(rest, ' ')
	code_str := code_end < 0 ? rest : rest[:code_end]
	code, cok := strconv.parse_int(strings.trim_space(code_str), 10)
	if !cok {
		return resp, fmt.aprintf("malformed HTTP status code in %q", status_line)
	}
	resp.status = code
	resp.reason = strings.clone(code_end < 0 ? "" : strings.trim_space(rest[code_end + 1:]), allocator)

	// --- headers ------------------------------------------------------------
	hs := make([dynamic]Http_Header, 0, 16, allocator)
	content_length := -1
	chunked := false
	for i := 0; i < 256; i += 1 {
		raw, lok := conn_read_line(c, 60_000)
		if !lok {
			return resp, "HTTP connection closed inside the header block"
		}
		if raw == "" {
			break
		}
		line := strings.clone(raw, context.temp_allocator)
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue // a malformed header line is dropped, not fatal
		}
		name := strings.to_lower(strings.trim_space(line[:colon]), allocator)
		value := strings.clone(strings.trim_space(line[colon + 1:]), allocator)
		append(&hs, Http_Header{name = name, value = value})
		switch name {
		case "content-length":
			if n, nok := strconv.parse_int(value, 10); nok {content_length = n}
		case "transfer-encoding":
			if strings.contains(strings.to_lower(value, context.temp_allocator), "chunked") {
				chunked = true
			}
		case "connection":
			if strings.equal_fold(value, "close") {resp.close = true}
		}
	}
	resp.headers = hs[:]

	// --- body ---------------------------------------------------------------
	switch {
	case resp.status == 204 || resp.status == 304:
		resp.body = nil
	case chunked:
		out := make([dynamic]u8, 0, 4096, allocator)
		for i := 0; i < 1_000_000; i += 1 {
			size_raw, sok := conn_read_line(c, 60_000)
			if !sok {
				return resp, "HTTP connection closed inside a chunked body"
			}
			sl := strings.clone(size_raw, context.temp_allocator)
			// Chunk extensions after a ';' are skipped, not parsed.
			if semi := strings.index_byte(sl, ';'); semi >= 0 {
				sl = sl[:semi]
			}
			n, nok := strconv.parse_int(strings.trim_space(sl), 16)
			if !nok || n < 0 {
				return resp, fmt.aprintf("malformed chunk size %q", sl)
			}
			if n == 0 {
				// Consume the trailer section.
				for j := 0; j < 64; j += 1 {
					t, tok := conn_read_line(c, 60_000)
					if !tok || t == "" {
						break
					}
				}
				break
			}
			data, dok := conn_read_exact(c, n, allocator)
			if !dok {
				return resp, "short read of a chunk"
			}
			append(&out, ..data)
			// The CRLF that follows each chunk.
			conn_read_line(c, 60_000)
		}
		resp.body = out[:]
	case content_length >= 0:
		if content_length == 0 {
			resp.body = nil
		} else {
			data, dok := conn_read_exact(c, content_length, allocator)
			if !dok {
				return resp, fmt.aprintf("short read of a %d-octet body", content_length)
			}
			resp.body = data
		}
	case resp.close:
		out := make([dynamic]u8, 0, 4096, allocator)
		for {
			line, lok := conn_read_line(c, 60_000)
			if !lok {
				break
			}
			append(&out, ..transmute([]u8)line)
			append(&out, '\n')
		}
		resp.body = out[:]
	case:
		return resp, "HTTP response has no Content-Length, no chunked encoding and no close"
	}
	return resp, ""
}

// http_basic_auth builds an RFC 7617 credential. Basic is only acceptable over
// TLS or on loopback; both ends of this are on 127.0.0.1.
http_basic_auth :: proc(user, password: string, allocator := context.allocator) -> string {
	blob := strings.concatenate({user, ":", password}, context.temp_allocator)
	return strings.concatenate(
		{"Basic ", base64_encode(transmute([]u8)blob, 0, context.temp_allocator)},
		allocator,
	)
}

// url_split takes `http://127.0.0.1:18143/jmap/api` apart. Only http:// and
// https:// are understood, and the host must still pass the loopback gate when
// it reaches conn_dial.
url_split :: proc(
	url: string,
) -> (
	scheme, host: string,
	port: int,
	target: string,
	err: string,
) {
	rest := url
	switch {
	case strings.has_prefix(rest, "http://"):
		scheme = "http"
		port = 80
		rest = rest[7:]
	case strings.has_prefix(rest, "https://"):
		scheme = "https"
		port = 443
		rest = rest[8:]
	case:
		return "", "", 0, "", fmt.aprintf("not an http(s) URL: %q", url)
	}
	slash := strings.index_byte(rest, '/')
	authority := slash < 0 ? rest : rest[:slash]
	target = slash < 0 ? "/" : rest[slash:]
	if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		host = authority[:colon]
		p, ok := strconv.parse_int(authority[colon + 1:], 10)
		if !ok {
			return "", "", 0, "", fmt.aprintf("bad port in %q", url)
		}
		port = p
	} else {
		host = authority
	}
	return scheme, host, port, target, ""
}

// url_encode_component percent-encodes a path segment.
url_encode_component :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		if (ch >= 'A' && ch <= 'Z') ||
		   (ch >= 'a' && ch <= 'z') ||
		   (ch >= '0' && ch <= '9') ||
		   ch == '-' ||
		   ch == '_' ||
		   ch == '.' ||
		   ch == '~' {
			strings.write_byte(&sb, ch)
			continue
		}
		fmt.sbprintf(&sb, "%%%02X", ch)
	}
	return strings.to_string(sb)
}

url_decode :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '%') < 0 && strings.index_byte(s, '+') < 0 {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); {
		if s[i] == '%' && i + 2 < len(s) {
			hi, ok1 := hexval2(s[i + 1])
			lo, ok2 := hexval2(s[i + 2])
			if ok1 && ok2 {
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
