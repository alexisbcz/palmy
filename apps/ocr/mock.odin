package main

// A local Mistral OCR mock, on loopback, over real sockets.
//
// There is no Mistral API key on this machine, so the remote backend cannot be
// developed against the real service — and it must not be. That leaves two
// options: write the code and hope, or build the server it talks to. This is
// the second, and it is the same thing `apps/mailcore` does with its test
// server: implement the protocol, then ship something local that speaks the
// other half of it.
//
// What that buys, concretely. Every one of these was found and fixed by
// running against this mock, and none of them is visible by reading the code:
//
//   * the multipart body's terminating boundary needs its own trailing `--`,
//     and a server that does not find it waits for more body that never comes;
//   * `Content-Length` has to count the file's bytes and the framing's, and
//     the framing is CRLF even when the payload is not;
//   * a response with no `Content-Length` and no chunking is framed by the
//     close, so the client has to treat EOF as the end rather than an error;
//   * a 401 arrives with a JSON body whose message is in `detail`, not
//     `message`, and a client that only looks for one of them reports
//     "HTTP 401" and nothing a user can act on.
//
// It also makes the consent gate *assertable*. The mock counts what it
// received. The self-test runs the whole remote path with consent withheld and
// then asserts the count is still zero — which is a much stronger statement
// than "I read the code and there is a check".
//
// This is a mock, not a simulator. It does not recognise anything: it returns
// a fixed document. The point is the wire, not the OCR.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// MOCK_MARKDOWN is what the mock's /v1/ocr returns. It exercises the Markdown
// path through `markdown_to_doc`: two heading levels, a paragraph that was
// wrapped, a page separator and a figure reference.
MOCK_MARKDOWN ::
	"# The Weather of Small Islands\n" +
	"\n" +
	"A field account of nine summers spent watching\n" +
	"one stretch of water.\n" +
	"\n" +
	"## Reading the Cloud\n" +
	"\n" +
	"Low cloud over the mainland in the morning means nothing by itself.\n" +
	"\n" +
	"![](img-0.jpeg)\n" +
	"\n" +
	"---\n" +
	"\n" +
	"The second page is about the lifeboat.\n"

Mock_Fail :: enum u8 {
	None,
	Unauthorized, // 401 with the message in `detail`
	Rate_Limited, // 429
	Malformed, // 200 with a body that is not JSON
	No_Pages, // 200 with valid JSON and no pages
	Truncated, // a response that stops mid-body
}

Mock_Req :: struct {
	method:   string,
	path:     string,
	body_len: int,
	// Whether an Authorization header was present. The value is never stored:
	// a mock that logged the key would be the exact leak this program exists
	// to avoid, even on loopback.
	had_auth: bool,
	ctype:    string,
}

Mock :: struct {
	port:      int,
	listener:  net.TCP_Socket,
	bound:     bool,
	stop:      bool,
	done:      bool,
	th:        ^thread.Thread,
	fail:      Mock_Fail,
	verbose:   bool,
	mu:        sync.Mutex,
	reqs:      [dynamic]Mock_Req,
	bytes_in:  int,
	next_id:   int,
}

mock_init :: proc(m: ^Mock) {
	m.reqs = make([dynamic]Mock_Req)
}

mock_destroy :: proc(m: ^Mock) {
	mock_stop(m)
	for r in m.reqs {
		delete(r.method)
		delete(r.path)
		if r.ctype != "" {delete(r.ctype)}
	}
	delete(m.reqs)
	m^ = {}
}

// mock_start binds a loopback listener. Port 0 asks the kernel for a free one,
// which is what lets several self-tests run at once without a lock.
mock_start :: proc(m: ^Mock, port := 0) -> string {
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	sock, err := net.listen_tcp(ep)
	if err != nil {
		return fmt.aprintf("cannot listen on 127.0.0.1:%d (%v)", port, err)
	}
	m.listener = sock
	m.bound = true
	bound_ep, berr := net.bound_endpoint(net.Any_Socket(sock))
	if berr != nil {
		net.close(sock)
		m.bound = false
		return fmt.aprintf("cannot read back the bound port (%v)", berr)
	}
	m.port = bound_ep.port
	// A short accept timeout is what makes the stop flag effective: the
	// thread comes up for air a few times a second rather than parking in
	// accept until somebody connects.
	_ = net.set_option(sock, .Receive_Timeout, 200 * time.Millisecond)
	m.th = thread.create_and_start_with_poly_data(m, mock_loop)
	return ""
}

mock_stop :: proc(m: ^Mock) {
	if !m.bound {
		return
	}
	sync.atomic_store(&m.stop, true)
	// Poke the listener so a blocked accept returns at once.
	if t, err := net.dial_tcp_from_endpoint(
		net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = m.port},
	); err == nil {
		net.close(t)
	}
	for i in 0 ..< 100 {
		if sync.atomic_load(&m.done) {
			break
		}
		time.sleep(10 * time.Millisecond)
		_ = i
	}
	net.close(m.listener)
	m.bound = false
	if m.th != nil {
		thread.destroy(m.th)
		m.th = nil
	}
}

mock_count :: proc(m: ^Mock) -> int {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	return len(m.reqs)
}

mock_bytes :: proc(m: ^Mock) -> int {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	return m.bytes_in
}

// mock_paths copies the request lines seen so far, for assertions.
mock_paths :: proc(m: ^Mock, allocator := context.allocator) -> []string {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	out := make([dynamic]string, allocator)
	for r in m.reqs {
		append(&out, fmt.aprintf("%s %s", r.method, r.path, allocator = allocator))
	}
	return out[:]
}

mock_reset :: proc(m: ^Mock) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	for r in m.reqs {
		delete(r.method)
		delete(r.path)
		if r.ctype != "" {delete(r.ctype)}
	}
	clear(&m.reqs)
	m.bytes_in = 0
}

@(private = "file")
mock_loop :: proc(m: ^Mock) {
	for !sync.atomic_load(&m.stop) {
		client, _, err := net.accept_tcp(m.listener)
		if err != nil {
			continue // the accept timeout, or the poke from mock_stop
		}
		if sync.atomic_load(&m.stop) {
			net.close(client)
			break
		}
		mock_serve(m, client)
		net.close(client)
	}
	sync.atomic_store(&m.done, true)
}

@(private = "file")
mock_serve :: proc(m: ^Mock, client: net.TCP_Socket) {
	_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
	buf := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	chunk: [32 * 1024]u8

	// Read until the headers are complete, then until the declared body is.
	head_end := -1
	want := -1
	for {
		if head_end < 0 {
			if i := bytes_index(buf[:], "\r\n\r\n"); i >= 0 {
				head_end = i + 4
				want = head_end + mock_content_length(string(buf[:head_end]))
			}
		}
		if head_end >= 0 && len(buf) >= want {
			break
		}
		n, rerr := net.recv_tcp(client, chunk[:])
		if rerr != nil || n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
		if len(buf) > 64 * 1024 * 1024 {
			break // nothing this program sends is that big
		}
	}
	if head_end < 0 {
		return
	}
	head := string(buf[:head_end])
	body_len := max(0, len(buf) - head_end)

	method, path := mock_request_line(head)
	had_auth := mock_has_header(head, "authorization")
	ctype := mock_header(head, "content-type")

	sync.mutex_lock(&m.mu)
	append(
		&m.reqs,
		Mock_Req {
			method = strings.clone(method),
			path = strings.clone(path),
			body_len = body_len,
			had_auth = had_auth,
			ctype = strings.clone(ctype),
		},
	)
	m.bytes_in += body_len
	id := m.next_id
	m.next_id += 1
	sync.mutex_unlock(&m.mu)

	if m.verbose {
		fmt.eprintfln(
			"[mock] %s %s  body=%d auth=%v type=%s",
			method,
			path,
			body_len,
			had_auth,
			ctype,
		)
	}

	// Authorization is mandatory on every endpoint, exactly as the real API
	// has it, so a client that forgets it fails here rather than in
	// production.
	if !had_auth {
		mock_reply(client, 401, `{"detail":"No API key provided"}`)
		return
	}
	switch m.fail {
	case .Unauthorized:
		mock_reply(client, 401, `{"detail":"Unauthorized: invalid api key"}`)
		return
	case .Rate_Limited:
		mock_reply(client, 429, `{"message":"Requests rate limit exceeded"}`)
		return
	case .Malformed:
		mock_reply(client, 200, `this is not json at all`)
		return
	case .No_Pages:
		mock_reply(client, 200, `{"model":"mistral-ocr-latest","pages":[],"usage_info":{"pages_processed":0}}`)
		return
	case .Truncated:
		// A Content-Length that overstates the body, then a close. This is the
		// case a client gets wrong by treating EOF as success.
		msg := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 400\r\n\r\n{\"pages\":[{\"index\":0,\"mark"
		mock_send(client, transmute([]u8)msg)
		return
	case .None:
	}

	switch {
	case method == "POST" && path == "/v1/files":
		if !strings.contains(strings.to_lower(ctype, context.temp_allocator), "multipart/form-data") {
			mock_reply(client, 422, `{"detail":"Expected multipart/form-data"}`)
			return
		}
		// Check the multipart body actually terminates, which is the mistake
		// a hand-written encoder makes.
		if !mock_multipart_ok(string(buf[head_end:]), ctype) {
			mock_reply(client, 422, `{"detail":"Malformed multipart body: no terminating boundary"}`)
			return
		}
		// Concatenated, not formatted: `fmt` reads `{` as the start of a
		// verb, so a JSON literal in a format string comes out mangled.
		ub := strings.builder_make(context.temp_allocator)
		strings.write_string(&ub, `{"id":"file-mock-`)
		fmt.sbprintf(&ub, "%04d", id)
		strings.write_string(&ub, `","object":"file","bytes":`)
		fmt.sbprintf(&ub, "%d", body_len)
		strings.write_string(&ub, `,"purpose":"ocr","filename":"upload"}`)
		mock_reply(client, 200, strings.to_string(ub))

	case method == "GET" && strings.has_prefix(path, "/v1/files/") && strings.contains(path, "/url"):
		fid := path[len("/v1/files/"):]
		if i := strings.index_byte(fid, '/'); i >= 0 {
			fid = fid[:i]
		}
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, `{"url":"https://mock.invalid/signed/`)
		strings.write_string(&sb, fid)
		strings.write_string(&sb, `?sig=deadbeef"}`)
		mock_reply(client, 200, strings.to_string(sb))

	case method == "POST" && path == "/v1/ocr":
		if !strings.contains(strings.to_lower(ctype, context.temp_allocator), "application/json") {
			mock_reply(client, 422, `{"detail":"Expected application/json"}`)
			return
		}
		body := string(buf[head_end:])
		if !strings.contains(body, `"model"`) || !strings.contains(body, `"document"`) {
			mock_reply(client, 422, `{"detail":"document and model are required"}`)
			return
		}
		pages := strings.contains(body, `"document_url"`) ? 2 : 1
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"model":"mistral-ocr-latest","pages":[`)
		halves := strings.split(MOCK_MARKDOWN, "\n\n---\n\n", context.temp_allocator)
		for i in 0 ..< pages {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			text := i < len(halves) ? halves[i] : halves[len(halves) - 1]
			strings.write_string(&b, `{"index":`)
			fmt.sbprintf(&b, "%d", i)
			strings.write_string(&b, `,"markdown":`)
			strings.write_string(&b, json_string(text, context.temp_allocator))
			strings.write_string(&b, `,"images":[],"dimensions":{"dpi":200,"height":2200,"width":1600}}`)
		}
		strings.write_string(&b, `],"usage_info":{"pages_processed":`)
		fmt.sbprintf(&b, "%d", pages)
		strings.write_string(&b, `,"doc_size_bytes":`)
		fmt.sbprintf(&b, "%d", body_len)
		strings.write_string(&b, `}}`)
		mock_reply(client, 200, strings.to_string(b))

	case:
		mock_reply(client, 404, `{"detail":"Not Found"}`)
	}
}

// ---------------------------------------------------------------------------
// The little bit of HTTP a mock needs
// ---------------------------------------------------------------------------

@(private = "file")
bytes_index :: proc(hay: []u8, needle: string) -> int {
	if len(needle) == 0 || len(hay) < len(needle) {
		return -1
	}
	for i in 0 ..= len(hay) - len(needle) {
		if string(hay[i:i + len(needle)]) == needle {
			return i
		}
	}
	return -1
}

@(private = "file")
mock_request_line :: proc(head: string) -> (method, path: string) {
	nl := strings.index_byte(head, '\n')
	if nl < 0 {
		return "", ""
	}
	line := strings.trim_space(head[:nl])
	f := strings.fields(line, context.temp_allocator)
	if len(f) < 2 {
		return "", ""
	}
	return f[0], f[1]
}

@(private = "file")
mock_header :: proc(head, name: string) -> string {
	for line in strings.split_lines(head, context.temp_allocator) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(line[:colon]), name) {
			return strings.trim_space(line[colon + 1:])
		}
	}
	return ""
}

@(private = "file")
mock_has_header :: proc(head, name: string) -> bool {
	return mock_header(head, name) != ""
}

@(private = "file")
mock_content_length :: proc(head: string) -> int {
	v := mock_header(head, "content-length")
	if v == "" {
		return 0
	}
	n, _ := strconv.parse_int(v, 10)
	return n
}

// mock_multipart_ok checks the two things a hand-written encoder gets wrong:
// the boundary announced in the header is the one used in the body, and the
// body ends with the closing `--boundary--`.
@(private = "file")
mock_multipart_ok :: proc(body, ctype: string) -> bool {
	at := strings.index(ctype, "boundary=")
	if at < 0 {
		return false
	}
	b := strings.trim_space(ctype[at + len("boundary="):])
	b = strings.trim(b, "\"")
	if b == "" {
		return false
	}
	if !strings.has_prefix(body, fmt.tprintf("--%s\r\n", b)) {
		return false
	}
	return strings.contains(body, fmt.tprintf("\r\n--%s--", b))
}

@(private = "file")
mock_reply :: proc(client: net.TCP_Socket, status: int, body: string) {
	reason := "OK"
	switch status {
	case 401:
		reason = "Unauthorized"
	case 404:
		reason = "Not Found"
	case 422:
		reason = "Unprocessable Entity"
	case 429:
		reason = "Too Many Requests"
	}
	msg := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status,
		reason,
		len(body),
		body,
	)
	mock_send(client, transmute([]u8)msg)
}

@(private = "file")
mock_send :: proc(client: net.TCP_Socket, data: []u8) {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(client, data[sent:])
		if err != nil || n <= 0 {
			return
		}
		sent += n
	}
}

// ---------------------------------------------------------------------------
// --mock
// ---------------------------------------------------------------------------

cmd_mock :: proc(args: []string) -> int {
	port := 0
	m: Mock
	mock_init(&m)
	m.verbose = true
	defer mock_destroy(&m)

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--port":
			i += 1
			if i < len(args) {port, _ = strconv.parse_int(args[i], 10)}
		case "--fail":
			i += 1
			if i < len(args) {
				switch args[i] {
				case "401":
					m.fail = .Unauthorized
				case "429":
					m.fail = .Rate_Limited
				case "malformed":
					m.fail = .Malformed
				case "nopages":
					m.fail = .No_Pages
				case "truncated":
					m.fail = .Truncated
				}
			}
		case "--quiet":
			m.verbose = false
		}
		i += 1
	}
	if err := mock_start(&m, port); err != "" {
		fmt.eprintfln("ocr --mock: %s", err)
		return 1
	}
	fmt.printfln("mock Mistral OCR on 127.0.0.1:%d — three endpoints, no recognition", m.port)
	fmt.println("  POST /v1/files            multipart upload")
	fmt.println("  GET  /v1/files/{id}/url   a signed URL")
	fmt.println("  POST /v1/ocr              a fixed document as Markdown")
	fmt.println("ctrl-c to stop")
	for {
		time.sleep(250 * time.Millisecond)
		if sync.atomic_load(&m.done) {
			break
		}
	}
	_ = os.args
	return 0
}
