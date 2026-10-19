package web

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Request :: struct {
	method:  string,
	target:  string, // as sent: path and query
	path:    string, // percent-decoded, without the query
	query:   string,
	headers: []Header,
	body:    string,
	peer:    string,
}

Response :: struct {
	status:  int,
	headers: [dynamic]Header,
	body:    string,
	head:    bool, // HEAD: send the headers of the body without it
}

Handler :: proc(req: ^Request, res: ^Response)

set_header :: proc(res: ^Response, name, value: string) {
	for &h in res.headers {
		if strings.equal_fold(h[0], name) {
			h[1] = value
			return
		}
	}
	append(&res.headers, Header{name, value})
}

MAX_HEADER :: 64 * 1024
MAX_BODY :: 16 * 1024 * 1024

Server :: struct {
	handler:  Handler,
	sock:     net.TCP_Socket,
	log:      bool,
	stopping: bool,
	active:   int,
}

// listen binds and returns; run accepts until the process ends.
listen :: proc(host: string, port: int) -> (s: ^Server, err: string) {
	addr, ok := net.parse_ip4_address(host)
	if !ok {
		return nil, fmt.aprintf("not an IPv4 address: %s", host)
	}
	sock, lerr := net.listen_tcp(net.Endpoint{address = addr, port = port})
	if lerr != nil {
		return nil, fmt.aprintf("cannot listen on %s:%d (%v)", host, port, lerr)
	}
	s = new(Server)
	s.sock = sock
	return s, ""
}

Conn_Job :: struct {
	server: ^Server,
	sock:   net.TCP_Socket,
	peer:   string,
}

run :: proc(s: ^Server, handler: Handler) {
	s.handler = handler
	for !s.stopping {
		client, src, err := net.accept_tcp(s.sock)
		if err != nil {
			if s.stopping {
				break
			}
			continue
		}
		job := new(Conn_Job, runtime.heap_allocator())
		job.server = s
		job.sock = client
		job.peer = strings.clone(net.endpoint_to_string(src, context.temp_allocator), runtime.heap_allocator())
		thread.create_and_start_with_poly_data(job, serve_conn, self_cleanup = true)
	}
}

@(private)
send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

@(private)
serve_conn :: proc(job: ^Conn_Job) {
	sock := job.sock
	s := job.server
	defer {
		net.close(sock)
		delete(job.peer, runtime.heap_allocator())
		free(job, runtime.heap_allocator())
	}
	sync.atomic_add(&s.active, 1)
	defer sync.atomic_sub(&s.active, 1)
	_ = net.set_option(sock, .Receive_Timeout, 120 * time.Second)

	// Bytes read past the end of one request belong to the next.
	carry := make([dynamic]u8, 0, 4096, runtime.heap_allocator())
	defer delete(carry)
	buf := make([]u8, 16384, runtime.heap_allocator())
	defer delete(buf, runtime.heap_allocator())

	for {
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil {
			return
		}
		alloc := virtual.arena_allocator(&arena)
		context.allocator = alloc
		context.temp_allocator = alloc

		keep, ok := one_request(s, sock, job.peer, &carry, buf)
		virtual.arena_destroy(&arena)
		if !ok || !keep {
			return
		}
	}
}

@(private)
one_request :: proc(s: ^Server, sock: net.TCP_Socket, peer: string, carry: ^[dynamic]u8, buf: []u8) -> (keep: bool, ok: bool) {
	// Read until the end of the headers.
	head_end := -1
	for {
		if i := strings.index(string(carry[:]), "\r\n\r\n"); i >= 0 {
			head_end = i
			break
		}
		if len(carry) > MAX_HEADER {
			return false, false
		}
		n, err := net.recv_tcp(sock, buf)
		if err != nil || n <= 0 {
			return false, false
		}
		append(carry, ..buf[:n])
	}
	head := strings.clone(string(carry[:head_end]))
	remove_range(carry, 0, head_end + 4)

	lines := strings.split(head, "\r\n")
	if len(lines) == 0 {
		return false, false
	}
	parts := strings.split(lines[0], " ")
	if len(parts) < 3 {
		reply_simple(sock, 400, "bad request line")
		return false, false
	}
	req := Request {
		method = strings.to_upper(parts[0]),
		target = parts[1],
		peer   = peer,
	}
	http10 := parts[2] == "HTTP/1.0"
	hs := make([dynamic]Header, 0, len(lines))
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		append(&hs, Header{strings.trim_space(line[:colon]), strings.trim_space(line[colon + 1:])})
	}
	req.headers = hs[:]
	path := req.target
	if strings.has_prefix(path, "http://") || strings.has_prefix(path, "https://") {
		// Absolute-form target: keep the path.
		if u, good := parse_url(path); good {
			path = u.path
		}
	}
	if q := strings.index_byte(path, '?'); q >= 0 {
		req.query = path[q + 1:]
		path = path[:q]
	}
	req.path = percent_decode(path)

	// Body: Content-Length or chunked.
	te := strings.to_lower(header(req.headers, "Transfer-Encoding"))
	cl_s := header(req.headers, "Content-Length")
	if strings.equal_fold(header(req.headers, "Expect"), "100-continue") {
		send_all(sock, transmute([]u8)string("HTTP/1.1 100 Continue\r\n\r\n"))
	}
	if strings.contains(te, "chunked") {
		body := make([dynamic]u8, 0, 4096)
		for {
			// size line
			line_end := -1
			for {
				if i := strings.index(string(carry[:]), "\r\n"); i >= 0 {
					line_end = i
					break
				}
				n, err := net.recv_tcp(sock, buf)
				if err != nil || n <= 0 {
					return false, false
				}
				append(carry, ..buf[:n])
			}
			size_s := string(carry[:line_end])
			if semi := strings.index_byte(size_s, ';'); semi >= 0 {
				size_s = size_s[:semi]
			}
			size, good := strconv.parse_int(strings.trim_space(size_s), 16)
			if !good || size < 0 || len(body) + size > MAX_BODY {
				reply_simple(sock, 413, "body too large or malformed")
				return false, false
			}
			remove_range(carry, 0, line_end + 2)
			for len(carry) < size + 2 {
				n, err := net.recv_tcp(sock, buf)
				if err != nil || n <= 0 {
					return false, false
				}
				append(carry, ..buf[:n])
			}
			if size == 0 {
				// Trailers until a blank line; usually just CRLF.
				if i := strings.index(string(carry[:]), "\r\n"); i >= 0 {
					remove_range(carry, 0, i + 2)
				}
				break
			}
			append(&body, ..carry[:size])
			remove_range(carry, 0, size + 2)
		}
		req.body = string(body[:])
	} else if cl_s != "" {
		cl, good := strconv.parse_int(cl_s)
		if !good || cl < 0 {
			reply_simple(sock, 400, "bad Content-Length")
			return false, false
		}
		if cl > MAX_BODY {
			reply_simple(sock, 413, "body too large")
			return false, false
		}
		for len(carry) < cl {
			n, err := net.recv_tcp(sock, buf)
			if err != nil || n <= 0 {
				return false, false
			}
			append(carry, ..buf[:n])
		}
		req.body = strings.clone(string(carry[:cl]))
		remove_range(carry, 0, cl)
	}

	res := Response {
		status  = 200,
		headers = make([dynamic]Header, 0, 8),
	}
	start := time.tick_now()
	s.handler(&req, &res)
	if req.method == "HEAD" {
		res.head = true
	}

	conn_hdr := strings.to_lower(header(req.headers, "Connection"))
	keep = !http10 && conn_hdr != "close"
	if http10 && conn_hdr == "keep-alive" {
		keep = true
	}

	sb := strings.builder_make()
	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\n", res.status, status_text(res.status))
	has_len := false
	for h in res.headers {
		if strings.equal_fold(h[0], "Content-Length") {
			has_len = true
		}
		fmt.sbprintf(&sb, "%s: %s\r\n", h[0], h[1])
	}
	if !has_len && res.status != 204 && res.status != 304 && res.status >= 200 {
		fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(res.body))
	}
	fmt.sbprintf(&sb, "Server: palmy-dav\r\n")
	if !keep {
		strings.write_string(&sb, "Connection: close\r\n")
	}
	strings.write_string(&sb, "\r\n")
	if !res.head {
		strings.write_string(&sb, res.body)
	}
	if !send_all(sock, transmute([]u8)strings.to_string(sb)) {
		return false, false
	}
	if s.log {
		ms := time.duration_milliseconds(time.tick_since(start))
		fmt.eprintfln("%s %s %s -> %d (%d bytes, %.1f ms)", peer, req.method, req.target, res.status, len(res.body), ms)
	}
	return keep, true
}

@(private)
reply_simple :: proc(sock: net.TCP_Socket, code: int, msg: string) {
	out := fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", code, status_text(code), len(msg), msg)
	send_all(sock, transmute([]u8)out)
}
