package web

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

Client_Response :: struct {
	status:  int,
	headers: []Header,
	body:    string,
}

// request sends one request on a fresh connection and reads the whole
// response. `err` is non-empty when the server could not be reached or the
// response was malformed; an HTTP error status is not an `err`.
request :: proc(
	method, url: string,
	headers: []Header = nil,
	body := "",
	timeout := 30 * time.Second,
) -> (
	res: Client_Response,
	err: string,
) {
	u, ok := parse_url(url)
	if !ok {
		return {}, fmt.tprintf("not a URL: %s", url)
	}
	if u.scheme != "http" {
		return {}, "https is not supported by this client yet (see cloud/docs/calendar-contacts.md)"
	}
	ep: net.Endpoint
	if addr, ok4 := net.parse_ip4_address(u.host); ok4 {
		ep = net.Endpoint{address = addr, port = u.port}
	} else if u.host == "localhost" {
		ep = net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = u.port}
	} else {
		e4, rerr := net.resolve_ip4(u.host)
		if rerr != nil {
			return {}, fmt.tprintf("cannot resolve %s", u.host)
		}
		ep = net.Endpoint{address = e4.address, port = u.port}
	}
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		return {}, fmt.tprintf("cannot reach %s:%d", u.host, u.port)
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	_ = net.set_option(sock, .Send_Timeout, timeout)

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n", method, u.path, u.host, u.port)
	has_ua := false
	for h in headers {
		if strings.equal_fold(h[0], "User-Agent") {
			has_ua = true
		}
		fmt.sbprintf(&sb, "%s: %s\r\n", h[0], h[1])
	}
	if !has_ua {
		strings.write_string(&sb, "User-Agent: palmy-dav\r\n")
	}
	if len(body) > 0 || method == "POST" || method == "PUT" || method == "PATCH" || method == "PROPFIND" || method == "REPORT" {
		fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(body))
	}
	strings.write_string(&sb, "\r\n")
	strings.write_string(&sb, body)
	if !send_all(sock, transmute([]u8)strings.to_string(sb)) {
		return {}, "the connection closed while sending"
	}

	raw := make([dynamic]u8, 0, 8192)
	buf: [16384]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if rerr != nil || n <= 0 {
			break
		}
		append(&raw, ..buf[:n])
	}
	text := string(raw[:])
	head_end := strings.index(text, "\r\n\r\n")
	if head_end < 0 {
		return {}, "no response"
	}
	lines := strings.split(text[:head_end], "\r\n", context.temp_allocator)
	sp := strings.split(lines[0], " ", context.temp_allocator)
	if len(sp) < 2 {
		return {}, "a malformed status line"
	}
	res.status, _ = strconv.parse_int(sp[1])
	hs := make([dynamic]Header, 0, len(lines))
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon > 0 {
			append(&hs, Header{strings.trim_space(line[:colon]), strings.trim_space(line[colon + 1:])})
		}
	}
	res.headers = hs[:]
	rest := text[head_end + 4:]
	if strings.contains(strings.to_lower(header(res.headers, "Transfer-Encoding"), context.temp_allocator), "chunked") {
		out := strings.builder_make()
		for {
			le := strings.index(rest, "\r\n")
			if le < 0 {
				break
			}
			sz := rest[:le]
			if semi := strings.index_byte(sz, ';'); semi >= 0 {
				sz = sz[:semi]
			}
			n, good := strconv.parse_int(strings.trim_space(sz), 16)
			if !good || n == 0 || le + 2 + n > len(rest) {
				break
			}
			strings.write_string(&out, rest[le + 2:le + 2 + n])
			rest = rest[le + 2 + n:]
			if strings.has_prefix(rest, "\r\n") {
				rest = rest[2:]
			}
		}
		res.body = strings.to_string(out)
	} else if cl := header(res.headers, "Content-Length"); cl != "" {
		n, _ := strconv.parse_int(cl)
		res.body = rest[:min(n, len(rest))]
	} else {
		res.body = rest
	}
	return res, ""
}
