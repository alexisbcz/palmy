// Package wire is what the forge server and the forge app share: a small
// HTTP/1.1 client, JSON helpers, and the handful of Supabase calls they make
// (GoTrue sign-in, PostgREST tables and RPCs, Storage objects).
//
// apps/cloudkit (owned by accounts) is the general Odin Supabase client and,
// once it is on main, the Supabase half of this package should become calls
// into it. Until then this is deliberately minimal: plain http only, one
// connection per request, bodies held in memory.
package wire

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

Header :: struct {
	name:  string,
	value: string,
}

Response :: struct {
	status:  int,
	headers: []Header,
	body:    []u8,
}

header_get :: proc(headers: []Header, name: string) -> string {
	for h in headers {
		if strings.equal_fold(h.name, name) {
			return h.value
		}
	}
	return ""
}

// cut_prefix is `s` without `prefix`, and whether it was there.
cut_prefix :: proc(s, prefix: string) -> (string, bool) {
	if strings.has_prefix(s, prefix) {
		return s[len(prefix):], true
	}
	return s, false
}

Url :: struct {
	host: string, // "127.0.0.1"
	port: int,
	path: string, // "/rest/v1/x?y=z"
}

parse_url :: proc(url: string) -> (u: Url, ok: bool) {
	rest, found := cut_prefix(url, "http://")
	if !found {
		return {}, false
	}
	slash := strings.index_byte(rest, '/')
	hostport := rest if slash < 0 else rest[:slash]
	u.path = "/" if slash < 0 else rest[slash:]
	colon := strings.last_index_byte(hostport, ':')
	if colon < 0 {
		u.host = hostport
		u.port = 80
	} else {
		u.host = hostport[:colon]
		p, pok := strconv.parse_int(hostport[colon + 1:])
		if !pok {
			return {}, false
		}
		u.port = p
	}
	if u.host == "localhost" {
		u.host = "127.0.0.1"
	}
	return u, u.host != ""
}

dial :: proc(host: string, port: int) -> (net.TCP_Socket, bool) {
	if ep, ok := net.parse_endpoint(fmt.tprintf("%s:%d", host, port)); ok {
		s, err := net.dial_tcp(ep)
		return s, err == nil
	}
	s, err := net.dial_tcp(fmt.tprintf("%s:%d", host, port))
	return s, err == nil
}

send_all :: proc(s: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(s, data[off:])
		if err != nil || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

// request performs one HTTP/1.1 exchange with `Connection: close` and reads
// the whole response. Errors are a status of 0 and a reason in `err`.
request :: proc(
	method, url: string,
	headers: []Header = nil,
	body: []u8 = nil,
	allocator := context.allocator,
) -> (
	resp: Response,
	err: string,
) {
	context.allocator = allocator
	u, ok := parse_url(url)
	if !ok {
		return {}, fmt.aprintf("not an http URL: %s", url)
	}
	sock, dok := dial(u.host, u.port)
	if !dok {
		return {}, fmt.aprintf("cannot connect to %s:%d", u.host, u.port)
	}
	defer net.close(sock)

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n", method, u.path, u.host, u.port)
	have_len := false
	for h in headers {
		if strings.contains_any(h.value, "\r\n") || strings.contains_any(h.name, "\r\n:") {
			return {}, fmt.aprintf("refusing a header with a line break: %s", h.name)
		}
		if strings.equal_fold(h.name, "content-length") {
			have_len = true
		}
		fmt.sbprintf(&sb, "%s: %s\r\n", h.name, h.value)
	}
	if !have_len && (len(body) > 0 || method == "POST" || method == "PUT" || method == "PATCH") {
		fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(body))
	}
	strings.write_string(&sb, "\r\n")
	if !send_all(sock, transmute([]u8)strings.to_string(sb)) || (len(body) > 0 && !send_all(sock, body)) {
		return {}, "send failed"
	}

	raw := make([dynamic]u8, 0, 16 * 1024)
	buf: [32 * 1024]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 {
			append(&raw, ..buf[:n])
		}
		if rerr != nil || n == 0 {
			break
		}
	}
	return parse_response(raw[:])
}

parse_response :: proc(raw: []u8, allocator := context.allocator) -> (resp: Response, err: string) {
	context.allocator = allocator
	text := string(raw)
	head_end := strings.index(text, "\r\n\r\n")
	if head_end < 0 {
		return {}, "truncated response"
	}
	lines := strings.split(text[:head_end], "\r\n", context.temp_allocator)
	status_parts := strings.split_n(lines[0], " ", 3, context.temp_allocator)
	if len(status_parts) < 2 {
		return {}, "bad status line"
	}
	resp.status, _ = strconv.parse_int(status_parts[1])
	hs := make([dynamic]Header)
	for l in lines[1:] {
		colon := strings.index_byte(l, ':')
		if colon > 0 {
			append(&hs, Header{strings.clone(strings.to_lower(l[:colon], context.temp_allocator)), strings.clone(strings.trim_space(l[colon + 1:]))})
		}
	}
	resp.headers = hs[:]
	body := raw[head_end + 4:]
	if strings.equal_fold(header_get(resp.headers, "transfer-encoding"), "chunked") {
		out, ok := dechunk(body)
		if !ok {
			return resp, "bad chunked body"
		}
		resp.body = out
	} else {
		if cl := header_get(resp.headers, "content-length"); cl != "" {
			n, _ := strconv.parse_int(cl)
			if n < len(body) {
				body = body[:n]
			}
		}
		resp.body = make([]u8, len(body))
		copy(resp.body, body)
	}
	return resp, ""
}

// dechunk decodes a complete `Transfer-Encoding: chunked` body.
dechunk :: proc(data: []u8, allocator := context.allocator) -> (out: []u8, ok: bool) {
	res := make([dynamic]u8, allocator)
	i := 0
	for {
		eol := strings.index(string(data[i:]), "\r\n")
		if eol < 0 {
			return res[:], false
		}
		size_text := string(data[i:i + eol])
		if semi := strings.index_byte(size_text, ';'); semi >= 0 {
			size_text = size_text[:semi]
		}
		size, sok := strconv.parse_int(strings.trim_space(size_text), 16)
		if !sok {
			return res[:], false
		}
		i += eol + 2
		if size == 0 {
			return res[:], true
		}
		if i + size > len(data) {
			return res[:], false
		}
		append(&res, ..data[i:i + size])
		i += size + 2
	}
}
