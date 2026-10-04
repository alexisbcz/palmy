package main

// The remote backend: Mistral OCR.
//
// This is a hosted API. Using it means **uploading the user's document to a
// third party**, and that is a trade the application has to present as one
// rather than make on the user's behalf. So:
//
//   * it is **off unless explicitly chosen**. There is no code path in this
//     program that reaches it because tesseract was missing, because a page
//     scored badly, or because anything failed. `convert_images` reports a
//     missing local backend and stops; it does not look for a second one.
//   * it needs a key, and the key comes from the environment or a file the
//     user creates. Nothing here embeds one, prints one, logs one or writes
//     one, and `redact_header` strips it from the trace before the trace
//     exists.
//   * before the first upload in a session the user is shown exactly what
//     will be sent and to whom, and has to confirm. `consent_check` is called
//     first in `mistral_recognize`, before the key is even read.
//
// THE DOCUMENTED FLOW, which is what is implemented here:
//
//   1. POST /v1/files            multipart/form-data: purpose=ocr, file=<bytes>
//                                -> {"id": "...", "filename": ..., ...}
//   2. GET  /v1/files/{id}/url?expiry=24
//                                -> {"url": "https://.../signed"}
//   3. POST /v1/ocr              {"model":"mistral-ocr-latest",
//                                 "document":{"type":"document_url",
//                                             "document_url":"<signed>"}}
//                                -> {"pages":[{"index":0,"markdown":"..."}],
//                                    "usage_info":{"pages_processed":1}}
//
// A single image can skip steps 1 and 2 with an inline data URI, which is one
// request instead of three and leaves nothing on their disk. That is the
// default for images; PDFs go through the upload, because a 40 MB base64 blob
// in a JSON body is not a reasonable request.
//
// THERE IS NO KEY ON THIS MACHINE, so none of this has been run against the
// real service. It was developed against the mock server in mock.odin, which
// speaks the three endpoints above over real sockets on loopback — same
// multipart writer, same JSON parser, same error handling. What that cannot
// prove is that the real service agrees with its documentation; what it does
// prove is that the request this program builds is the request it intends to
// build, byte for byte.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

MISTRAL_MODEL :: "mistral-ocr-latest"

// ---------------------------------------------------------------------------
// The key
// ---------------------------------------------------------------------------

// Key_Source says where a key came from, so the UI can tell the user which
// file to edit without ever showing the key.
Key_Source :: enum u8 {
	None,
	Env,
	File,
}

Key_Info :: struct {
	source: Key_Source,
	from:   string, // heap-owned: "$MISTRAL_API_KEY" or a path
	length: int, // the only thing about the key itself that is ever reported
}

key_info_destroy :: proc(k: ^Key_Info) {
	if k.from != "" {delete(k.from)}
	k^ = {}
}

// mistral_key_path is the file a user creates to supply a key. It is read, is
// never written, and its contents never leave this procedure except as a
// return value that goes straight into an Authorization header.
mistral_key_path :: proc(allocator := context.temp_allocator) -> string {
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		base = fmt.tprintf("%s/.config", home)
	}
	return fmt.aprintf("%s/palmy-ocr/mistral.key", base, allocator = allocator)
}

// mistral_key returns the key and where it came from. The key is in the temp
// allocator: it lives for one frame or one request and is never cloned into
// application state, so there is no long-lived copy to leak.
mistral_key :: proc() -> (key: string, info: Key_Info) {
	if v := os.get_env("MISTRAL_API_KEY", context.temp_allocator); strings.trim_space(v) != "" {
		k := strings.trim_space(v)
		return k, Key_Info{source = .Env, from = strings.clone("$MISTRAL_API_KEY"), length = len(k)}
	}
	path := mistral_key_path(context.temp_allocator)
	if data, rerr := os.read_entire_file_from_path(path, context.temp_allocator); rerr == nil {
		k := strings.trim_space(string(data))
		if k != "" {
			return k, Key_Info{source = .File, from = strings.clone(path), length = len(k)}
		}
	}
	return "", Key_Info{source = .None, from = strings.clone(path)}
}

mistral_probe :: proc(b: ^Backend) -> (ok: bool, why: string) {
	// A probe must not touch the network, so all it can check is the key.
	_, info := mistral_key()
	defer {
		i := info
		key_info_destroy(&i)
	}
	if info.source == .None {
		return false, fmt.aprintf(
			"Mistral OCR needs an API key. Set $MISTRAL_API_KEY, or put the key in %s. Nothing is uploaded until you confirm.",
			info.from,
		)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// What consent is being asked for
//
// This text is the whole point of the consent step, so it is generated from
// the actual payload rather than written once as a reassuring paragraph. It
// names the host, the bytes, the page count and the file, because those are
// the four things a person needs to decide.
// ---------------------------------------------------------------------------

Upload_Plan :: struct {
	host:   string, // heap-owned
	file:   string, // heap-owned: the base name only
	bytes:  int,
	pages:  int,
	inline: bool, // true: a data URI in one request; false: the file upload
	text:   string, // heap-owned: the sentence the user is shown
}

plan_destroy :: proc(p: ^Upload_Plan) {
	if p.host != "" {delete(p.host)}
	if p.file != "" {delete(p.file)}
	if p.text != "" {delete(p.text)}
	p^ = {}
}

mistral_plan :: proc(paths: []string, ep: Endpoint, pages: int) -> Upload_Plan {
	total := 0
	for pth in paths {
		if fi, ferr := os.stat(pth, context.temp_allocator); ferr == nil {
			total += int(fi.size)
		}
	}
	host := ep.host == "" ? MISTRAL_HOST : ep.host
	name := len(paths) == 1 ? base_name(paths[0]) : fmt.tprintf("%d page images", len(paths))
	inline := len(paths) == 1 && total < 6 * 1024 * 1024
	pl := Upload_Plan {
		host   = strings.clone(host),
		file   = strings.clone(name),
		bytes  = total,
		pages  = max(pages, len(paths)),
		inline = inline,
	}
	pl.text = fmt.aprintf(
		"This will upload %s (%s, %d page%s) to %s, a service run by Mistral AI in France. " +
		"The image of every page you convert leaves this machine and is processed on their servers; " +
		"their retention and training policy is theirs, not this program's. " +
		"Your API key is sent with it. Nothing has been sent yet.",
		pl.file,
		human_bytes(pl.bytes, context.temp_allocator),
		pl.pages,
		pl.pages == 1 ? "" : "s",
		pl.host,
	)
	return pl
}

human_bytes :: proc(n: int, allocator := context.allocator) -> string {
	switch {
	case n >= 1 << 20:
		return fmt.aprintf("%.1f MB", f64(n) / f64(1 << 20), allocator = allocator)
	case n >= 1 << 10:
		return fmt.aprintf("%.0f kB", f64(n) / f64(1 << 10), allocator = allocator)
	}
	return fmt.aprintf("%d bytes", n, allocator = allocator)
}

// ---------------------------------------------------------------------------
// multipart/form-data
//
// Hand-written, because there is nothing to reach for. Two things are easy to
// get wrong: the terminating boundary carries a trailing `--`, and every line
// break in the framing is CRLF even though the file's own bytes are not
// touched. A boundary that appears inside the payload would corrupt the
// request, so it carries a nanosecond counter — not random, but unguessable
// enough for a body this program assembled itself.
// ---------------------------------------------------------------------------

multipart_build :: proc(
	boundary: string,
	fields: []([2]string),
	file_field, filename, file_type: string,
	file_bytes: []u8,
	allocator := context.allocator,
) -> []u8 {
	b := strings.builder_make(allocator)
	for f in fields {
		fmt.sbprintf(&b, "--%s\r\n", boundary)
		fmt.sbprintf(&b, "Content-Disposition: form-data; name=\"%s\"\r\n\r\n", f[0])
		fmt.sbprintf(&b, "%s\r\n", f[1])
	}
	fmt.sbprintf(&b, "--%s\r\n", boundary)
	fmt.sbprintf(
		&b,
		"Content-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n",
		file_field,
		filename,
	)
	fmt.sbprintf(&b, "Content-Type: %s\r\n\r\n", file_type)
	strings.write_bytes(&b, file_bytes)
	fmt.sbprintf(&b, "\r\n--%s--\r\n", boundary)
	return transmute([]u8)strings.to_string(b)
}

multipart_boundary :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"----palmyocr%016x",
		u64(time.to_unix_nanoseconds(time.now())),
		allocator = allocator,
	)
}

mime_for :: proc(path: string) -> string {
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".pdf"):
		return "application/pdf"
	case strings.has_suffix(lower, ".png"):
		return "image/png"
	case strings.has_suffix(lower, ".jpg"), strings.has_suffix(lower, ".jpeg"):
		return "image/jpeg"
	case strings.has_suffix(lower, ".webp"):
		return "image/webp"
	}
	return "application/octet-stream"
}

// ---------------------------------------------------------------------------
// The backend
// ---------------------------------------------------------------------------

mistral_recognize :: proc(
	b: ^Backend,
	req: Ocr_Request,
	allocator := context.allocator,
) -> (
	Ocr_Result,
	string,
) {
	started := time.tick_now()

	// FIRST. Before the key is read, before the file is opened, before a
	// socket exists.
	if refuse := consent_check(b, req); refuse != "" {
		trace_add(req.trace, "refused: %s", refuse)
		return {}, refuse
	}
	key, info := mistral_key()
	defer {
		i := info
		key_info_destroy(&i)
	}
	if key == "" {
		return {}, fmt.aprintf(
			"Mistral OCR needs an API key and none was found. Nothing was sent. Set $MISTRAL_API_KEY or create %s.",
			info.from,
		)
	}
	data, rerr := os.read_entire_file_from_path(req.image_path, context.temp_allocator)
	if rerr != nil {
		return {}, fmt.aprintf("cannot read %s: %v", req.image_path, rerr)
	}

	auth := fmt.tprintf("Authorization: Bearer %s", key)
	md: string
	err: string

	// An image goes inline: one request, and nothing of the user's is left
	// sitting in somebody's object store afterwards.
	if len(data) < 6 * 1024 * 1024 && mime_for(req.image_path) != "application/pdf" {
		md, err = mistral_ocr_inline(req, auth, data, mime_for(req.image_path), allocator)
	} else {
		id, uerr := mistral_upload(req, auth, data, allocator)
		if uerr != "" {
			return {}, uerr
		}
		defer delete(id)
		signed, serr := mistral_signed_url(req, auth, id, allocator)
		if serr != "" {
			return {}, serr
		}
		defer delete(signed)
		md, err = mistral_ocr_url(req, auth, signed, allocator)
	}
	if err != "" {
		return {}, err
	}

	res := Ocr_Result {
		kind     = .Blocks,
		words    = make([dynamic]Ocr_Word, allocator),
		markdown = md,
		page     = req.page,
		backend  = strings.clone("mistral-ocr", allocator),
		ms       = int(time.duration_milliseconds(time.tick_since(started))),
	}
	if w, h, _, ok := image_dims(req.image_path); ok {
		res.width, res.height = w, h
	}
	return res, ""
}

// mistral_upload is step 1: multipart POST /v1/files.
mistral_upload :: proc(
	req: Ocr_Request,
	auth: string,
	data: []u8,
	allocator := context.allocator,
) -> (
	id: string,
	err: string,
) {
	boundary := multipart_boundary(context.temp_allocator)
	body := multipart_build(
		boundary,
		{{"purpose", "ocr"}},
		"file",
		base_name(req.image_path),
		mime_for(req.image_path),
		data,
		context.temp_allocator,
	)
	headers := [?]string {
		auth,
		fmt.tprintf("Content-Type: multipart/form-data; boundary=%s", boundary),
	}
	res, herr := http_do(req.endpoint, "POST", "/v1/files", headers[:], body, req.trace, 120000, context.temp_allocator)
	if herr != "" {
		return "", herr
	}
	if res.status != 200 && res.status != 201 {
		return "", mistral_error("uploading the document", res, allocator)
	}
	v, jerr := json.parse_string(res.body, allocator = context.temp_allocator)
	if jerr != nil {
		return "", fmt.aprintf("the upload response was not JSON: %v", jerr)
	}
	obj, ok := v.(json.Object)
	if !ok {
		return "", strings.clone("the upload response was not a JSON object", allocator)
	}
	fid, fok := obj["id"]
	if !fok {
		return "", strings.clone("the upload response carried no file id", allocator)
	}
	s, sok := fid.(json.String)
	if !sok {
		return "", strings.clone("the upload response's file id was not a string", allocator)
	}
	return strings.clone(string(s), allocator), ""
}

// mistral_signed_url is step 2: GET /v1/files/{id}/url?expiry=24.
mistral_signed_url :: proc(
	req: Ocr_Request,
	auth, id: string,
	allocator := context.allocator,
) -> (
	url: string,
	err: string,
) {
	headers := [?]string{auth}
	path := fmt.tprintf("/v1/files/%s/url?expiry=24", url_escape(id, context.temp_allocator))
	res, herr := http_do(req.endpoint, "GET", path, headers[:], nil, req.trace, 30000, context.temp_allocator)
	if herr != "" {
		return "", herr
	}
	if res.status != 200 {
		return "", mistral_error("asking for a signed URL", res, allocator)
	}
	v, jerr := json.parse_string(res.body, allocator = context.temp_allocator)
	if jerr != nil {
		return "", fmt.aprintf("the signed-URL response was not JSON: %v", jerr)
	}
	obj, ok := v.(json.Object)
	if !ok {
		return "", strings.clone("the signed-URL response was not a JSON object", allocator)
	}
	u, uok := obj["url"]
	if !uok {
		return "", strings.clone("the signed-URL response carried no url", allocator)
	}
	s, sok := u.(json.String)
	if !sok {
		return "", strings.clone("the signed-URL response's url was not a string", allocator)
	}
	return strings.clone(string(s), allocator), ""
}

// mistral_ocr_url is step 3 with a document_url.
mistral_ocr_url :: proc(
	req: Ocr_Request,
	auth, signed: string,
	allocator := context.allocator,
) -> (
	md: string,
	err: string,
) {
	body := ocr_body("document_url", signed, context.temp_allocator)
	return mistral_post_ocr(req, auth, transmute([]u8)body, allocator)
}

// mistral_ocr_inline is the one-request path: the image as a data URI.
mistral_ocr_inline :: proc(
	req: Ocr_Request,
	auth: string,
	data: []u8,
	mime: string,
	allocator := context.allocator,
) -> (
	md: string,
	err: string,
) {
	b64 := base64.encode(data, base64.ENC_TABLE, context.temp_allocator)
	uri := fmt.tprintf("data:%s;base64,%s", mime, b64)
	body := ocr_body("image_url", uri, context.temp_allocator)
	return mistral_post_ocr(req, auth, transmute([]u8)body, allocator)
}

// ocr_body assembles the /v1/ocr request.
//
// It is concatenated rather than formatted, and that is not a style choice.
// Odin's `fmt` uses braces for its verbs, so a format string containing a JSON
// object turns `{"model"` into a malformed verb and the body goes out as
// `%!(MISSING CLOSE BRACE)model":...`. The mock rejected it with a 422 and the
// error read like a protocol disagreement rather than a printf bug; it cost
// an hour. No JSON in this program goes through a format string.
ocr_body :: proc(doc_type, value: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"model":`)
	strings.write_string(&b, json_string(MISTRAL_MODEL, context.temp_allocator))
	strings.write_string(&b, `,"document":{"type":`)
	strings.write_string(&b, json_string(doc_type, context.temp_allocator))
	strings.write_byte(&b, ',')
	strings.write_string(&b, json_string(doc_type, context.temp_allocator))
	strings.write_byte(&b, ':')
	strings.write_string(&b, json_string(value, context.temp_allocator))
	strings.write_string(&b, `},"include_image_base64":false}`)
	return strings.to_string(b)
}

@(private = "file")
mistral_post_ocr :: proc(
	req: Ocr_Request,
	auth: string,
	body: []u8,
	allocator := context.allocator,
) -> (
	md: string,
	err: string,
) {
	headers := [?]string{auth, "Content-Type: application/json"}
	res, herr := http_do(req.endpoint, "POST", "/v1/ocr", headers[:], body, req.trace, 180000, context.temp_allocator)
	if herr != "" {
		return "", herr
	}
	if res.status != 200 {
		return "", mistral_error("running OCR", res, allocator)
	}
	return mistral_parse_ocr(res.body, allocator)
}

// mistral_parse_ocr pulls the per-page Markdown out of an OCR response. It is
// separate from the socket so the self-test can feed it the documented shape,
// a truncated one, and an empty one.
mistral_parse_ocr :: proc(body: string, allocator := context.allocator) -> (md: string, err: string) {
	v, jerr := json.parse_string(body, allocator = context.temp_allocator)
	if jerr != nil {
		return "", fmt.aprintf("the OCR response was not JSON: %v", jerr)
	}
	obj, ok := v.(json.Object)
	if !ok {
		return "", strings.clone("the OCR response was not a JSON object", allocator)
	}
	pages, pok := obj["pages"]
	if !pok {
		return "", strings.clone("the OCR response carried no pages", allocator)
	}
	arr, aok := pages.(json.Array)
	if !aok {
		return "", strings.clone("the OCR response's pages was not an array", allocator)
	}
	b := strings.builder_make(allocator)
	n := 0
	for pv in arr {
		po, ook := pv.(json.Object)
		if !ook {
			continue
		}
		mv, mok := po["markdown"]
		if !mok {
			continue
		}
		s, sok := mv.(json.String)
		if !sok {
			continue
		}
		if n > 0 {
			strings.write_string(&b, "\n\n---\n\n")
		}
		strings.write_string(&b, string(s))
		n += 1
	}
	if n == 0 {
		return "", strings.clone("the OCR response had no page carrying markdown", allocator)
	}
	return strings.to_string(b), ""
}

// mistral_error turns a non-200 into a sentence. The API returns either
// {"detail": "..."} or {"message": "..."} depending on which layer rejected
// the request, and a 401 is worth naming specially because it is the one a
// user can fix.
mistral_error :: proc(doing: string, res: Http_Response, allocator := context.allocator) -> string {
	detail := ""
	if v, jerr := json.parse_string(res.body, allocator = context.temp_allocator); jerr == nil {
		if obj, ok := v.(json.Object); ok {
			for k in ([?]string{"detail", "message", "error"}) {
				if dv, dok := obj[k]; dok {
					if s, sok := dv.(json.String); sok {
						detail = string(s)
						break
					}
					if o2, ook := dv.(json.Object); ook {
						if mv, mok := o2["message"]; mok {
							if s, sok := mv.(json.String); sok {
								detail = string(s)
								break
							}
						}
					}
				}
			}
		}
	}
	switch res.status {
	case 401, 403:
		return fmt.aprintf(
			"Mistral rejected the API key while %s (HTTP %d). The document was sent but not processed.%s%s",
			doing,
			res.status,
			detail == "" ? "" : " ",
			detail,
			allocator = allocator,
		)
	case 429:
		return fmt.aprintf("Mistral rate-limited this account while %s (HTTP 429). %s", doing, detail, allocator = allocator)
	}
	if detail != "" {
		return fmt.aprintf("Mistral failed while %s (HTTP %d): %s", doing, res.status, detail, allocator = allocator)
	}
	return fmt.aprintf("Mistral failed while %s (HTTP %d)", doing, res.status, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Small encoders
// ---------------------------------------------------------------------------

// json_string writes a quoted JSON string. The bodies here are built by
// hand — they are three fields — and that is only safe if every value that
// goes into one is escaped, which is what this is for. A signed URL carries
// `&` and `=` and a base64 payload carries `+` and `/`; neither needs escaping
// in JSON, but a filename can carry a quote and that would be an injected
// field.
json_string :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if r < 0x20 {
				fmt.sbprintf(&b, "\\u%04x", int(r))
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// url_escape percent-encodes a path segment. A file id is opaque and could
// contain anything, and splicing it into a request line unescaped is how a
// path becomes two paths.
url_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for c in transmute([]u8)s {
		unreserved :=
			(c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '-' ||
			c == '_' ||
			c == '.' ||
			c == '~'
		if unreserved {
			strings.write_byte(&b, c)
		} else {
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}
