package main

// A minimal HTTP/1.1 client for one server on the loopback interface.
//
// This is the same shape as `apps/ai/http.odin`, and deliberately so: that
// decoder was written against the one thing every streaming ollama client
// gets wrong, and rediscovering it here would be a waste. `apps/ai` is a
// different `package main`, so it cannot be imported; this file is this app's
// own copy, kept small and kept honest by the same kind of split-replay test.
//
// The problem it solves: ollama answers `/api/chat` with
// `Transfer-Encoding: chunked` carrying `application/x-ndjson`. Two framings
// are stacked, and a `recv` can land anywhere at all — in the middle of a
// chunk-size line, between the `\r` and the `\n` of a chunk terminator,
// halfway through a UTF-8 sequence, halfway through a JSON string. So the
// framing is a byte-at-a-time state machine that assumes nothing about read
// boundaries, and it is kept free of sockets so the self-test can drive it
// with deliberately cruel splits.
//
// `Decoder` turns raw socket bytes into body bytes. `Line_Splitter` turns body
// bytes into whole NDJSON lines. Neither one has ever seen a socket.

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// The loopback gate
// ---------------------------------------------------------------------------

// ollama is reachable at exactly one address and there is no parameter to
// change it. `is_loopback` exists so that the rule is a value the self-test
// can interrogate rather than a comment, and `ollama_endpoint` asserts it on
// every dial: if somebody ever adds a `--ollama-host`, the assert fires before
// a byte of a channel's conversation leaves this machine.
OLLAMA_HOST :: "127.0.0.1"
OLLAMA_PORT :: 11434
OLLAMA_START_HINT :: "OLLAMA_HOST=127.0.0.1:11434 ollama serve"

// is_loopback accepts only a literal loopback IPv4 or IPv6 address. A
// hostname — even "localhost" — is refused, because resolving a name is the
// step that can be made to point somewhere else.
is_loopback :: proc(host: string) -> bool {
	switch host {
	case "::1", "[::1]", "0:0:0:0:0:0:0:1":
		return true
	}
	addr, ok := net.parse_ip4_address(host)
	if !ok {
		return false
	}
	return addr[0] == 127
}

ollama_endpoint :: proc() -> net.Endpoint {
	assert(is_loopback(OLLAMA_HOST), "ollama must be reached on the loopback interface only")
	return net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = OLLAMA_PORT}
}

// ---------------------------------------------------------------------------
// Response framing
// ---------------------------------------------------------------------------

Decode_Stage :: enum u8 {
	Status, // the status line
	Headers, // header lines, until a blank one
	Chunk_Size, // a chunked body's size line
	Chunk_Data, // `left` bytes of chunk payload
	Chunk_CRLF, // the CRLF that follows a chunk's payload
	Length_Body, // a Content-Length body
	Until_Close, // neither framing was given: read to EOF
	Done,
}

Decoder :: struct {
	stage:       Decode_Stage,
	pending:     [dynamic]u8, // bytes of the current line, not yet terminated
	status:      int,
	chunked:     bool,
	content_len: int, // -1 when absent
	left:        int, // bytes still owed by the current chunk / body
	headers:     [dynamic]string,
	bad:         string, // non-empty once the response is malformed
}

decoder_make :: proc() -> Decoder {
	return Decoder {
		stage = .Status,
		content_len = -1,
		pending = make([dynamic]u8),
		headers = make([dynamic]string),
	}
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.pending)
	for h in d.headers {
		delete(h)
	}
	delete(d.headers)
}

decoder_header :: proc(d: ^Decoder, name: string) -> string {
	for h in d.headers {
		colon := strings.index_byte(h, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(h[:colon]), name) {
			return strings.trim_space(h[colon + 1:])
		}
	}
	return ""
}

// decoder_feed consumes raw bytes from the socket and appends decoded body
// bytes to `out`. It is safe to call with one byte, with a megabyte, or with a
// slice that ends mid-frame; the state lives in the Decoder, not in the call.
decoder_feed :: proc(d: ^Decoder, data: []u8, out: ^[dynamic]u8) {
	i := 0
	for i < len(data) && d.stage != .Done && d.bad == "" {
		switch d.stage {
		case .Status, .Headers, .Chunk_Size, .Chunk_CRLF:
			// Line-oriented stages: accumulate until an LF, then interpret.
			// Nothing here cares that the `\r` may have arrived in a previous
			// call and the `\n` in this one.
			b := data[i]
			i += 1
			if b != '\n' {
				append(&d.pending, b)
				continue
			}
			line := string(d.pending[:])
			if len(line) > 0 && line[len(line) - 1] == '\r' {
				line = line[:len(line) - 1]
			}
			decoder_line(d, line)
			clear(&d.pending)

		case .Chunk_Data, .Length_Body:
			n := min(d.left, len(data) - i)
			append(out, ..data[i:i + n])
			i += n
			d.left -= n
			if d.left == 0 {
				d.stage = d.stage == .Chunk_Data ? .Chunk_CRLF : .Done
			}

		case .Until_Close:
			append(out, ..data[i:])
			i = len(data)

		case .Done:
		}
	}
}

// decoder_eof is the close of the connection, which is itself a frame
// terminator when the server gave neither a length nor chunking.
decoder_eof :: proc(d: ^Decoder) {
	if d.stage == .Until_Close {
		d.stage = .Done
	}
	if d.stage != .Done && d.bad == "" {
		d.bad = "the connection closed before the response ended"
	}
}

decoder_done :: proc(d: ^Decoder) -> bool {
	return d.stage == .Done
}

@(private = "file")
decoder_line :: proc(d: ^Decoder, line: string) {
	switch d.stage {
	case .Status:
		// "HTTP/1.1 200 OK"
		sp := strings.index_byte(line, ' ')
		if sp < 0 || !strings.has_prefix(line, "HTTP/") {
			d.bad = "the response did not start with a status line"
			return
		}
		rest := strings.trim_space(line[sp + 1:])
		end := strings.index_byte(rest, ' ')
		if end < 0 {
			end = len(rest)
		}
		code, ok := strconv.parse_int(rest[:end])
		if !ok {
			d.bad = "the status line had no status code"
			return
		}
		d.status = code
		d.stage = .Headers

	case .Headers:
		if line == "" {
			te := decoder_header(d, "transfer-encoding")
			if strings.contains(strings.to_lower(te, context.temp_allocator), "chunked") {
				d.chunked = true
				d.stage = .Chunk_Size
				return
			}
			if cl := decoder_header(d, "content-length"); cl != "" {
				if n, ok := strconv.parse_int(cl); ok {
					d.content_len = n
					d.left = n
					d.stage = n == 0 ? .Done : .Length_Body
					return
				}
			}
			if d.status == 204 || d.status == 304 {
				d.stage = .Done
				return
			}
			d.stage = .Until_Close
			return
		}
		append(&d.headers, strings.clone(line))

	case .Chunk_Size:
		// "1f3" or "1f3;ext=value"
		size := line
		if semi := strings.index_byte(size, ';'); semi >= 0 {
			size = size[:semi]
		}
		size = strings.trim_space(size)
		if size == "" {
			// A stray blank line between chunks; tolerate it.
			return
		}
		n, ok := strconv.parse_int(size, 16)
		if !ok {
			d.bad = fmt.aprintf("bad chunk size %q", size)
			return
		}
		if n == 0 {
			// The last chunk. Trailers may follow, but the body is complete
			// either way and ollama sends none.
			d.stage = .Done
			return
		}
		d.left = n
		d.stage = .Chunk_Data

	case .Chunk_CRLF:
		d.stage = .Chunk_Size

	case .Chunk_Data, .Length_Body, .Until_Close, .Done:
	}
}

// ---------------------------------------------------------------------------
// Newline-delimited JSON
// ---------------------------------------------------------------------------

Line_Splitter :: struct {
	pending: [dynamic]u8,
}

splitter_make :: proc() -> Line_Splitter {
	return Line_Splitter{pending = make([dynamic]u8)}
}

splitter_destroy :: proc(s: ^Line_Splitter) {
	delete(s.pending)
}

// splitter_feed appends every complete line in `data` to `out`, cloned with
// `allocator`. A line is only emitted once its LF has arrived, which is the
// whole point: a JSON object cut in half by a read boundary must not be
// handed to a parser.
splitter_feed :: proc(
	s: ^Line_Splitter,
	data: []u8,
	out: ^[dynamic]string,
	allocator := context.allocator,
) {
	for b in data {
		if b == '\n' {
			line := strings.trim_space(string(s.pending[:]))
			if line != "" {
				append(out, strings.clone(line, allocator))
			}
			clear(&s.pending)
			continue
		}
		append(&s.pending, b)
	}
}

// splitter_flush emits whatever is left when the stream ends without a final
// newline.
splitter_flush :: proc(s: ^Line_Splitter, out: ^[dynamic]string, allocator := context.allocator) {
	line := strings.trim_space(string(s.pending[:]))
	if line != "" {
		append(out, strings.clone(line, allocator))
	}
	clear(&s.pending)
}

// ---------------------------------------------------------------------------
// The socket
// ---------------------------------------------------------------------------

Http :: struct {
	sock: net.TCP_Socket,
	live: bool,
	dec:  Decoder,
}

// http_open dials the loopback address. There is no hostname resolution and
// no way to pass one in.
http_open :: proc(recv_timeout_ms: int = RECV_TIMEOUT_MS) -> (h: Http, err: string) {
	ep := ollama_endpoint()
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		return {}, fmt.aprintf("cannot reach %s:%d (%v)", OLLAMA_HOST, OLLAMA_PORT, derr)
	}
	// The receive timeout is what makes cancellation possible: the reader
	// wakes up five times a second to look at the stop flag instead of
	// parking in `recv` until the model is finished.
	_ = net.set_option(sock, .Receive_Timeout, time.Duration(recv_timeout_ms) * time.Millisecond)
	_ = net.set_option(sock, .TCP_Nodelay, true)
	return Http{sock = sock, live = true, dec = decoder_make()}, ""
}

http_close :: proc(h: ^Http) {
	if h.live {
		net.close(h.sock)
		h.live = false
	}
	decoder_destroy(&h.dec)
}

http_request :: proc(h: ^Http, method, path, body: string) -> (err: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %s HTTP/1.1\r\n", method, path)
	fmt.sbprintf(&b, "Host: %s:%d\r\n", OLLAMA_HOST, OLLAMA_PORT)
	fmt.sbprint(&b, "User-Agent: palmy-chatbot/1.0\r\n")
	fmt.sbprint(&b, "Accept: application/x-ndjson, application/json\r\n")
	fmt.sbprint(&b, "Connection: close\r\n")
	if body != "" {
		fmt.sbprint(&b, "Content-Type: application/json\r\n")
		fmt.sbprintf(&b, "Content-Length: %d\r\n", len(body))
	}
	fmt.sbprint(&b, "\r\n")
	fmt.sbprint(&b, body)

	out := transmute([]u8)strings.to_string(b)
	sent := 0
	for sent < len(out) {
		n, serr := net.send_tcp(h.sock, out[sent:])
		if serr != nil {
			return fmt.aprintf("sending the request failed (%v)", serr)
		}
		if n <= 0 {
			return "the connection closed while sending the request"
		}
		sent += n
	}
	return ""
}

Recv_State :: enum u8 {
	Data, // bytes were decoded into `out`
	Idle, // the read timed out; nothing arrived, nothing is wrong
	End, // the response is complete
	Error, // `err` says what went wrong
}

// http_pump does one bounded read and feeds whatever arrived to the decoder.
// It returns as soon as the socket goes quiet, so the caller stays responsive
// to a cancel request and to its own chat socket.
http_pump :: proc(h: ^Http, out: ^[dynamic]u8) -> (state: Recv_State, err: string) {
	if !h.live {
		return .Error, "the socket is closed"
	}
	buf: [16 * 1024]u8
	n, rerr := net.recv_tcp(h.sock, buf[:])
	if rerr != nil {
		if rerr == .Would_Block || rerr == .Timeout || rerr == .Interrupted {
			return .Idle, ""
		}
		return .Error, fmt.aprintf("reading the response failed (%v)", rerr)
	}
	if n == 0 {
		decoder_eof(&h.dec)
		if h.dec.bad != "" {
			return .Error, strings.clone(h.dec.bad)
		}
		return .End, ""
	}
	before := len(out)
	decoder_feed(&h.dec, buf[:n], out)
	if h.dec.bad != "" {
		return .Error, strings.clone(h.dec.bad)
	}
	if decoder_done(&h.dec) {
		return .End, ""
	}
	return len(out) > before ? .Data : .Idle, ""
}

// http_json is the blocking one-shot call, for the endpoints that answer at
// once: /api/version and /api/tags.
http_json :: proc(
	method, path, body: string,
	timeout_ms := 4000,
	allocator := context.allocator,
) -> (
	status: int,
	text: string,
	err: string,
) {
	h, oerr := http_open(200)
	if oerr != "" {
		return 0, "", oerr
	}
	defer http_close(&h)

	if rerr := http_request(&h, method, path, body); rerr != "" {
		return 0, "", rerr
	}

	out := make([dynamic]u8, allocator)
	start := time.tick_now()
	for {
		st, perr := http_pump(&h, &out)
		switch st {
		case .Data, .Idle:
		case .End:
			return h.dec.status, string(out[:]), ""
		case .Error:
			delete(out)
			return 0, "", perr
		}
		if int(time.duration_milliseconds(time.tick_since(start))) > timeout_ms {
			delete(out)
			return 0, "", fmt.aprintf("%s timed out after %dms", path, timeout_ms)
		}
	}
}
