// A small blocking HTTP/1.1 client over core:net, enough for PostgREST and
// Supabase Storage on a local stack.
//
// REPLACE WITH apps/cloudkit. The accounts area owns the Odin Supabase client
// (auth, token refresh, PostgREST, Storage). This exists only so the drive
// could be built and tested before that landed. What it does not do, and
// cloudkit must: TLS (so it cannot talk to a hosted project at all), keep-alive,
// redirects, token refresh. Every call in this package goes through `request`,
// so the swap is one file.
package drivecore

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

Response :: struct {
	status: int, // 0 when the server could not be reached
	body:   []u8,
	err:    string, // transport error, when status is 0
}

Header :: struct {
	name, value: string,
}

Url :: struct {
	host: string,
	port: int,
	path: string, // the base path, without a trailing slash
}

parse_url :: proc(u: string) -> (out: Url, ok: bool) {
	s := u
	if strings.has_prefix(s, "https://") {
		// No TLS here; see the note at the top.
		return {}, false
	}
	s = strings.trim_prefix(s, "http://")
	slash := strings.index_byte(s, '/')
	hostport := slash < 0 ? s : s[:slash]
	out.path = slash < 0 ? "" : strings.trim_right(s[slash:], "/")
	colon := strings.last_index_byte(hostport, ':')
	out.port = 80
	out.host = hostport
	if colon >= 0 {
		out.host = hostport[:colon]
		p, pok := strconv.parse_int(hostport[colon + 1:])
		if !pok {
			return {}, false
		}
		out.port = p
	}
	return out, out.host != ""
}

// request performs one call and reads the whole response. The body is
// allocated with `allocator`; everything else is temporary.
request :: proc(
	method, base, path: string,
	headers: []Header,
	body: []u8 = nil,
	timeout := 30 * time.Second,
	allocator := context.allocator,
) -> (
	r: Response,
) {
	u, ok := parse_url(base)
	if !ok {
		r.err = fmt.tprintf("cannot use %q (plain http only until cloudkit)", base)
		return
	}
	addr: net.Address
	if ip4, is4 := net.parse_ip4_address(u.host); is4 {
		addr = ip4
	} else if u.host == "localhost" {
		addr = net.IP4_Loopback
	} else {
		ep, rerr := net.resolve_ip4(u.host)
		if rerr != nil {
			r.err = fmt.tprintf("cannot resolve %s", u.host)
			return
		}
		addr = ep.address
	}
	sock, derr := net.dial_tcp_from_endpoint({address = addr, port = u.port})
	if derr != nil {
		r.err = fmt.tprintf("cannot reach %s:%d (%v)", u.host, u.port, derr)
		return
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	_ = net.set_option(sock, .Send_Timeout, timeout)
	_ = net.set_option(sock, .TCP_Nodelay, true)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %s%s HTTP/1.1\r\nHost: %s:%d\r\n", method, u.path, path, u.host, u.port)
	fmt.sbprint(&b, "User-Agent: palm-drive/0.1\r\nConnection: close\r\n")
	for h in headers {
		fmt.sbprintf(&b, "%s: %s\r\n", h.name, h.value)
	}
	if body != nil || method == "POST" || method == "PATCH" || method == "PUT" {
		fmt.sbprintf(&b, "Content-Length: %d\r\n", len(body))
	}
	fmt.sbprint(&b, "\r\n")
	if !send_all(sock, transmute([]u8)strings.to_string(b)) || (len(body) > 0 && !send_all(sock, body)) {
		r.err = "the connection closed while sending"
		return
	}

	raw := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	buf: [64 * 1024]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if rerr != nil {
			r.err = fmt.tprintf("reading the response failed (%v)", rerr)
			return
		}
		if n == 0 {
			break
		}
		append(&raw, ..buf[:n])
		// Stop as soon as a Content-Length body is complete, rather than
		// waiting for the server to close.
		if done, _ := response_complete(raw[:]); done {
			break
		}
	}
	status, payload, perr := parse_response(raw[:], allocator)
	if perr != "" {
		r.err = perr
		return
	}
	r.status = status
	r.body = payload
	return
}

@(private)
send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

@(private)
header_end :: proc(raw: []u8) -> int {
	for i in 0 ..< min(len(raw), 65536) - 3 {
		if raw[i] == '\r' && raw[i + 1] == '\n' && raw[i + 2] == '\r' && raw[i + 3] == '\n' {
			return i
		}
	}
	return -1
}

@(private)
find_header :: proc(head: string, name: string) -> string {
	for line in strings.split_lines(head, context.temp_allocator) {
		colon := strings.index_byte(line, ':')
		if colon > 0 && strings.equal_fold(strings.trim_space(line[:colon]), name) {
			return strings.trim_space(line[colon + 1:])
		}
	}
	return ""
}

@(private)
response_complete :: proc(raw: []u8) -> (bool, int) {
	if len(raw) < 4 {
		return false, 0
	}
	he := header_end(raw)
	if he < 0 {
		return false, 0
	}
	head := string(raw[:he])
	if cl := find_header(head, "content-length"); cl != "" {
		n, _ := strconv.parse_int(cl)
		return len(raw) - (he + 4) >= n, n
	}
	if strings.contains(strings.to_lower(find_header(head, "transfer-encoding"), context.temp_allocator), "chunked") {
		// Complete when the terminating zero-size chunk has arrived.
		return strings.has_suffix(string(raw[he + 4:]), "0\r\n\r\n"), 0
	}
	status := status_of(head)
	return status == 204 || status == 304, 0
}

@(private)
status_of :: proc(head: string) -> int {
	sp := strings.index_byte(head, ' ')
	if sp < 0 {
		return 0
	}
	rest := head[sp + 1:]
	end := strings.index_byte(rest, ' ')
	if end < 0 {
		end = min(3, len(rest))
	}
	n, _ := strconv.parse_int(rest[:end])
	return n
}

@(private)
parse_response :: proc(raw: []u8, allocator := context.allocator) -> (status: int, body: []u8, err: string) {
	he := header_end(raw)
	if he < 0 {
		return 0, nil, "the response ended inside its headers"
	}
	head := string(raw[:he])
	status = status_of(head)
	rest := raw[he + 4:]
	te := strings.to_lower(find_header(head, "transfer-encoding"), context.temp_allocator)
	if strings.contains(te, "chunked") {
		out := make([dynamic]u8, 0, len(rest), allocator)
		i := 0
		for i < len(rest) {
			eol := strings.index(string(rest[i:]), "\r\n")
			if eol < 0 {
				break
			}
			size_s := string(rest[i:i + eol])
			if semi := strings.index_byte(size_s, ';'); semi >= 0 {
				size_s = size_s[:semi]
			}
			n, ok := strconv.parse_int(strings.trim_space(size_s), 16)
			if !ok {
				return 0, nil, "bad chunk size in response"
			}
			i += eol + 2
			if n == 0 {
				break
			}
			if i + n > len(rest) {
				return 0, nil, "the response ended inside a chunk"
			}
			append(&out, ..rest[i:i + n])
			i += n + 2
		}
		return status, out[:], ""
	}
	if cl := find_header(head, "content-length"); cl != "" {
		n, _ := strconv.parse_int(cl)
		if len(rest) < n {
			return 0, nil, "the response ended early"
		}
		rest = rest[:n]
	}
	out := make([]u8, len(rest), allocator)
	copy(out, rest)
	return status, out, ""
}
