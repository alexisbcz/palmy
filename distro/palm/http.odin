package palm

// A minimal HTTP/1.1 GET client, enough for a package repository.
//
// Plain http only, deliberately: the index signature is what makes a
// download trustworthy, not the transport, so TLS would add a library and
// prove nothing palm does not already check (the same argument apk makes).
//
// One request per connection with `Connection: close`, so the response is
// simply everything until the server hangs up; the body is then cut by
// Content-Length, or un-chunked for Transfer-Encoding: chunked. Redirects are
// followed a few times when they stay on http://. Nothing else: no keep-alive,
// no compression, no proxies.

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

HTTP_MAX_BODY :: 1 << 31

Http_Url :: struct {
	host: string,
	port: int,
	path: string,
}

parse_http_url :: proc(url: string) -> (u: Http_Url, okk: bool) {
	if !strings.has_prefix(url, "http://") {
		return u, false
	}
	rest := url[len("http://"):]
	slash := strings.index_byte(rest, '/')
	hostport := rest
	u.path = "/"
	if slash >= 0 {
		hostport = rest[:slash]
		u.path = rest[slash:]
	}
	u.port = 80
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

// http_get fetches a URL. A non-200 status is reported in `status` with a nil
// error, so the caller can treat 404 as "not here" rather than as a failure.
http_get :: proc(url: string, allocator := context.allocator) -> (body: []byte, status: int, e: Err) {
	target := url
	for _ in 0 ..< 4 {
		location: string
		body, status, location, e = http_get_once(target, allocator)
		if !ok(e) {
			return
		}
		if (status == 301 || status == 302 || status == 307 || status == 308) && location != "" {
			if strings.has_prefix(location, "/") {
				u, _ := parse_http_url(target)
				location = fmt.tprintf("http://%s:%d%s", u.host, u.port, location)
			}
			if !strings.has_prefix(location, "http://") {
				return nil, status, fail(EXIT_UNAVAILABLE, "%s redirects to %s, which is not http://", target, location)
			}
			target = location
			continue
		}
		return
	}
	return nil, status, fail(EXIT_UNAVAILABLE, "%s: too many redirects", url)
}

@(private = "file")
http_get_once :: proc(url: string, allocator := context.allocator) -> (body: []byte, status: int, location: string, e: Err) {
	u, okk := parse_http_url(url)
	if !okk {
		return nil, 0, "", fail(EXIT_USAGE, "not an http:// URL: %s", url)
	}
	sock, nerr := net.dial_tcp_from_hostname_with_port_override(u.host, u.port)
	if nerr != nil {
		return nil, 0, "", fail(EXIT_UNAVAILABLE, "cannot connect to %s:%d (%v)", u.host, u.port, nerr)
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, time.Second * 30)
	_ = net.set_option(sock, .Send_Timeout, time.Second * 30)

	host_header := u.port == 80 ? u.host : fmt.tprintf("%s:%d", u.host, u.port)
	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: palm/%s\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n",
		u.path,
		host_header,
		VERSION,
	)
	sent := 0
	for sent < len(req) {
		n, serr := net.send_tcp(sock, transmute([]byte)req[sent:])
		if serr != nil || n <= 0 {
			return nil, 0, "", fail(EXIT_UNAVAILABLE, "%s: send failed (%v)", url, serr)
		}
		sent += n
	}

	resp := make([dynamic]byte, 0, 64 * 1024, context.temp_allocator)
	buf: [64 * 1024]byte
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if rerr != nil {
			return nil, 0, "", fail(EXIT_UNAVAILABLE, "%s: receive failed (%v)", url, rerr)
		}
		if n == 0 {
			break
		}
		append(&resp, ..buf[:n])
		if len(resp) > HTTP_MAX_BODY {
			return nil, 0, "", fail(EXIT_FAILED, "%s: response too large", url)
		}
	}
	return http_parse_response(resp[:], url, allocator)
}

// http_parse_response is separate from the socket so the selftest can feed it
// chunked and truncated responses directly.
http_parse_response :: proc(resp: []byte, url: string, allocator := context.allocator) -> (body: []byte, status: int, location: string, e: Err) {
	text := string(resp)
	end := strings.index(text, "\r\n\r\n")
	if end < 0 {
		return nil, 0, "", fail(EXIT_UNAVAILABLE, "%s: malformed response (no header end)", url)
	}
	head := text[:end]
	raw := resp[end + 4:]
	lines := strings.split(head, "\r\n", context.temp_allocator)
	status_line := strings.fields(lines[0], context.temp_allocator)
	if len(status_line) < 2 || !strings.has_prefix(status_line[0], "HTTP/1.") {
		return nil, 0, "", fail(EXIT_UNAVAILABLE, "%s: malformed status line %q", url, lines[0])
	}
	status, _ = strconv.parse_int(status_line[1])
	content_length := -1
	chunked := false
	for l in lines[1:] {
		colon := strings.index_byte(l, ':')
		if colon < 0 {
			continue
		}
		k := strings.to_lower(strings.trim_space(l[:colon]), context.temp_allocator)
		v := strings.trim_space(l[colon + 1:])
		switch k {
		case "content-length":
			content_length, _ = strconv.parse_int(v)
		case "transfer-encoding":
			chunked = strings.contains(strings.to_lower(v, context.temp_allocator), "chunked")
		case "location":
			location = strings.clone(v, allocator)
		}
	}
	if chunked {
		out := make([dynamic]byte, 0, len(raw), allocator)
		r := raw
		for {
			nl := strings.index(string(r), "\r\n")
			if nl < 0 {
				return nil, status, location, fail(EXIT_UNAVAILABLE, "%s: truncated chunked body", url)
			}
			size_s := string(r[:nl])
			if semi := strings.index_byte(size_s, ';'); semi >= 0 {
				size_s = size_s[:semi]
			}
			size, okc := strconv.parse_int(strings.trim_space(size_s), 16)
			if !okc || size < 0 {
				return nil, status, location, fail(EXIT_UNAVAILABLE, "%s: bad chunk size %q", url, size_s)
			}
			r = r[nl + 2:]
			if size == 0 {
				break
			}
			if len(r) < size + 2 {
				return nil, status, location, fail(EXIT_UNAVAILABLE, "%s: truncated chunk", url)
			}
			append(&out, ..r[:size])
			r = r[size + 2:]
		}
		return out[:], status, location, Err{}
	}
	if content_length >= 0 {
		if len(raw) < content_length {
			return nil, status, location, fail(EXIT_UNAVAILABLE, "%s: body truncated (%d of %d bytes)", url, len(raw), content_length)
		}
		raw = raw[:content_length]
	}
	out := make([]byte, len(raw), allocator)
	copy(out, raw)
	return out, status, location, Err{}
}
