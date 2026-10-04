package main

// The OCR seam.
//
// One interface, one direction: **an image path in, text with layout out.**
// Everything upstream (rasterising a PDF, loading a PNG) and everything
// downstream (lines, paragraphs, columns, EPUB) is backend-agnostic, so a
// third recogniser is a new file with one `Backend` value in it rather than a
// refactor.
//
// The seam has to be honest about one real asymmetry: not every recogniser
// returns the same *shape* of answer.
//
//   * tesseract returns **words with bounding boxes**. Structure is not given;
//     it has to be recovered, which is what structure.odin does.
//   * Mistral OCR returns **Markdown per page**. The structure is already
//     decided by somebody else's model, and the boxes are gone.
//
// Pretending both return boxes would mean fabricating boxes for the Markdown;
// pretending both return Markdown would mean throwing away the boxes that make
// column detection possible. So `Ocr_Result` carries a `kind` and the pipeline
// branches once, at the top, in `recognize_into_doc`.
//
// The second thing the seam carries is **consent**. A remote backend may not
// run without it, and that is enforced here rather than in the UI, so there is
// no code path — self-test, command line, demo — that can upload a document
// because somebody forgot to check a flag.

import "core:fmt"
import "core:strings"

Backend_Id :: enum u8 {
	Tesseract,
	Mistral,
}

backend_id_name :: proc(id: Backend_Id) -> string {
	switch id {
	case .Tesseract:
		return "tesseract"
	case .Mistral:
		return "mistral"
	}
	return "?"
}

// Ocr_Word is one recognised word in page-image pixel coordinates, origin top
// left. Every structure heuristic downstream works from these four numbers and
// nothing else.
Ocr_Word :: struct {
	text:       string, // heap-owned
	x, y, w, h: int,
	conf:       f32, // 0..100
	page:       int, // 1-based
}

word_right :: proc(w: Ocr_Word) -> int {return w.x + w.w}
word_bottom :: proc(w: Ocr_Word) -> int {return w.y + w.h}
word_cx :: proc(w: Ocr_Word) -> f32 {return f32(w.x) + f32(w.w) * 0.5}
word_cy :: proc(w: Ocr_Word) -> f32 {return f32(w.y) + f32(w.h) * 0.5}

Result_Kind :: enum u8 {
	Boxes, // words with geometry; structure must be recovered
	Blocks, // already-structured Markdown; structure was decided elsewhere
}

Ocr_Result :: struct {
	kind:          Result_Kind,
	words:         [dynamic]Ocr_Word, // .Boxes
	markdown:      string, // .Blocks, heap-owned
	width, height: int, // the page image, in pixels
	page:          int, // 1-based
	backend:       string, // heap-owned
	// What it cost, so the UI can say so and the self-test can report it.
	ms:            int,
}

result_destroy :: proc(r: ^Ocr_Result) {
	for w in r.words {
		delete(w.text)
	}
	delete(r.words)
	if r.markdown != "" {
		delete(r.markdown)
	}
	if r.backend != "" {
		delete(r.backend)
	}
	r^ = {}
}

// Ocr_Request is everything a backend is allowed to know. There is no handle
// to the application state in here on purpose: a backend cannot read the
// user's settings, cannot see other files, and cannot decide for itself that
// it is allowed to use the network.
Ocr_Request :: struct {
	image_path: string, // a file this process rasterised or the user picked
	page:       int, // 1-based, for the result
	lang:       string, // a tesseract traineddata name, or a Mistral language hint
	// Layout hint. `.Auto` lets the engine segment the page; `.Block` forbids
	// it, which is how the self-test puts the column work on our own
	// x-clustering instead of tesseract's.
	segment:    Segmentation,
	// Required for every remote backend. A nil consent is a refusal, not a
	// prompt: nothing in this program may ask for consent from inside the
	// recognise path.
	consent:    ^Consent,
	// Where a remote backend is allowed to send bytes. Empty means the
	// backend's own documented default; the self-test points it at the mock.
	endpoint:   Endpoint,
	trace:      ^Trace, // optional; records every byte a remote backend sends
}

Segmentation :: enum u8 {
	Auto, // tesseract --psm 3: the engine finds blocks and columns
	Block, // tesseract --psm 6: one uniform block, we do the columns
	Line, // tesseract --psm 7: a single line
}

Backend :: struct {
	id:        Backend_Id,
	name:      string, // what the UI calls it
	remote:    bool, // true means bytes leave this machine
	// probe reports whether this backend can run at all right now, and why
	// not when it cannot. It must not touch the network.
	probe:     proc(b: ^Backend) -> (ok: bool, why: string),
	// recognize is the whole seam.
	recognize: proc(b: ^Backend, req: Ocr_Request, allocator := context.allocator) -> (Ocr_Result, string),
}

// ---------------------------------------------------------------------------
// Consent
//
// A remote backend uploads the user's document to a third party. That is a
// decision, not a detail, so it is modelled as a value that has to be
// constructed with the thing being sent already named.
//
// `granted` is only ever set by `consent_grant`, which is called from exactly
// two places: the confirmation step in the UI (keys.odin) and the explicit
// `--i-consent-to-upload` command-line flag. The self-test calls neither until
// it has first asserted that the ungranted case refuses.
// ---------------------------------------------------------------------------

Consent :: struct {
	granted:  bool,
	// What the user was shown before they agreed. Kept so the UI can display
	// it afterwards and so a log line can say what was consented to, without
	// ever holding the key.
	host:     string, // heap-owned
	what:     string, // heap-owned: a human description of the payload
	bytes:    int, // how many bytes the payload is
	pages:    int,
	at:       f64, // app_elapsed when it was granted
}

consent_destroy :: proc(c: ^Consent) {
	if c == nil {
		return
	}
	if c.host != "" {delete(c.host)}
	if c.what != "" {delete(c.what)}
	c^ = {}
}

consent_grant :: proc(c: ^Consent, host, what: string, bytes, pages: int, at: f64) {
	if c.host != "" {delete(c.host)}
	if c.what != "" {delete(c.what)}
	c.host = strings.clone(host)
	c.what = strings.clone(what)
	c.bytes = bytes
	c.pages = pages
	c.at = at
	c.granted = true
}

consent_revoke :: proc(c: ^Consent) {
	c.granted = false
}

// consent_check is the gate every remote backend calls first. It returns the
// refusal text, or "" when the upload may proceed.
consent_check :: proc(b: ^Backend, req: Ocr_Request) -> string {
	if !b.remote {
		return ""
	}
	if req.consent == nil {
		return fmt.aprintf(
			"%s is a remote service and no consent was given. Nothing was sent.",
			b.name,
		)
	}
	if !req.consent.granted {
		return fmt.aprintf(
			"%s would upload this document to %s. Consent has not been given, so nothing was sent.",
			b.name,
			req.endpoint.host == "" ? MISTRAL_HOST : req.endpoint.host,
		)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Endpoint
//
// A remote backend's address is data, not a constant, because the mock server
// in mock.odin has to be reachable from the same code path the real service
// would use. `allow_remote` is the second half of the gate: a non-loopback
// host is refused unless it is explicitly turned on, so a typo in a config
// file cannot send a document to a stranger.
// ---------------------------------------------------------------------------

Endpoint :: struct {
	host:         string,
	port:         int,
	tls:          bool,
	allow_remote: bool, // false: loopback only, whatever `host` says
	tls_insecure: bool, // for the mock's self-signed certificate on loopback
}

MISTRAL_HOST :: "api.mistral.ai"
MISTRAL_PORT :: 443

endpoint_default :: proc() -> Endpoint {
	return Endpoint{host = MISTRAL_HOST, port = MISTRAL_PORT, tls = true, allow_remote = false}
}

endpoint_mock :: proc(port: int, tls := false) -> Endpoint {
	return Endpoint {
		host = "127.0.0.1",
		port = port,
		tls = tls,
		allow_remote = false,
		tls_insecure = tls,
	}
}

// ---------------------------------------------------------------------------
// Trace
//
// Every byte a remote backend writes to a socket goes through here first. The
// self-test uses it to assert that the mock received nothing before consent,
// and `--trace-upload` prints it so a user can see exactly what would leave
// the machine. Secrets are redacted on the way in, not on the way out, so
// there is no window in which a key sits in a buffer.
// ---------------------------------------------------------------------------

Trace :: struct {
	lines: [dynamic]string,
	bytes: int,
	calls: int,
}

trace_init :: proc(t: ^Trace) {
	t.lines = make([dynamic]string)
}

trace_destroy :: proc(t: ^Trace) {
	for l in t.lines {
		delete(l)
	}
	delete(t.lines)
	t^ = {}
}

trace_add :: proc(t: ^Trace, format: string, args: ..any) {
	if t == nil {
		return
	}
	append(&t.lines, fmt.aprintf(format, ..args))
}

// trace_request records a request's head with the Authorization value
// replaced. The body is summarised by length, never copied: a document body is
// the user's document.
trace_request :: proc(t: ^Trace, method, path: string, headers: []string, body_len: int) {
	if t == nil {
		return
	}
	t.calls += 1
	t.bytes += body_len
	trace_add(t, "> %s %s", method, path)
	for h in headers {
		trace_add(t, "> %s", redact_header(h, context.temp_allocator))
	}
	if body_len > 0 {
		trace_add(t, "> [body: %d bytes]", body_len)
	}
}

redact_header :: proc(h: string, allocator := context.allocator) -> string {
	colon := strings.index_byte(h, ':')
	if colon < 0 {
		return strings.clone(h, allocator)
	}
	name := strings.trim_space(h[:colon])
	if strings.equal_fold(name, "authorization") ||
	   strings.equal_fold(name, "x-api-key") ||
	   strings.equal_fold(name, "api-key") {
		return fmt.aprintf("%s: <redacted>", name, allocator = allocator)
	}
	return strings.clone(h, allocator)
}

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

backend_tesseract :: proc() -> Backend {
	return Backend {
		id = .Tesseract,
		name = "tesseract (on this machine)",
		remote = false,
		probe = tess_probe,
		recognize = tess_recognize,
	}
}

backend_mistral :: proc() -> Backend {
	return Backend {
		id = .Mistral,
		name = "Mistral OCR (a hosted service)",
		remote = true,
		probe = mistral_probe,
		recognize = mistral_recognize,
	}
}

backend_by_id :: proc(id: Backend_Id) -> Backend {
	switch id {
	case .Tesseract:
		return backend_tesseract()
	case .Mistral:
		return backend_mistral()
	}
	return backend_tesseract()
}

// backend_from_name parses what the user typed. An unknown name is an error
// and never silently becomes the remote one.
backend_from_name :: proc(s: string) -> (Backend_Id, bool) {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "tesseract", "local":
		return .Tesseract, true
	case "mistral", "mistral-ocr", "remote":
		return .Mistral, true
	}
	return .Tesseract, false
}
