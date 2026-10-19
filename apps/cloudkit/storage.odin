package cloudkit

// Storage: files in buckets, streamed. An upload reads from disk as it
// sends and a download writes to disk as it arrives, so a file's size is
// bounded by the bucket's limit and not by memory.
//
// Object names start with the identity's id — `<identity_id>/avatar.png` —
// because that first segment is what the Storage policies hand to
// can_access_identity(). An object outside any identity folder is refused.
//
//	e := cloudkit.upload_file(c, "avatars", fmt.tprintf("%s/avatar.png", id), "/tmp/me.png", upsert = true)
//	e  = cloudkit.download_file(c, "avatars", fmt.tprintf("%s/avatar.png", id), "/tmp/copy.png")
//	ls, e := cloudkit.list(c, "avatars", id)

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

upload_file :: proc(c: ^Client, bucket, name, path: string, content_type := "", upsert := false) -> Error {
	f, oerr := os.open(path)
	if oerr != nil {
		return Error{kind = .Not_Found, message = fmt.aprintf("cannot open %s (%v)", path, oerr)}
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil {
		return Error{kind = .Failed, message = fmt.aprintf("cannot size %s (%v)", path, serr)}
	}
	ct := content_type != "" ? content_type : guess_content_type(path)
	return upload_stream(c, bucket, name, os.to_reader(f), size, ct, upsert)
}

upload_bytes :: proc(c: ^Client, bucket, name: string, data: []u8, content_type: string, upsert := false) -> Error {
	if fe := ensure_fresh(c); !ok(fe) {
		return fe
	}
	return storage_send(c, "POST", object_path(bucket, name), data, nil, 0, content_type, upsert)
}

// upload_stream sends exactly `size` bytes from `r`.
upload_stream :: proc(c: ^Client, bucket, name: string, r: io.Reader, size: i64, content_type: string, upsert := false) -> Error {
	if fe := ensure_fresh(c); !ok(fe) {
		return fe
	}
	return storage_send(c, "POST", object_path(bucket, name), nil, r, size, content_type, upsert)
}

// download_file writes the object to `dest`, through a temporary file that
// is renamed into place only when the whole object arrived.
download_file :: proc(c: ^Client, bucket, name, dest: string) -> Error {
	if fe := ensure_fresh(c); !ok(fe) {
		return fe
	}
	tmp := fmt.tprintf("%s.part.%d", dest, os.get_pid())
	f, oerr := os.open(tmp, {.Write, .Create, .Trunc}, os.perm_number(0o600))
	if oerr != nil {
		return Error{kind = .Failed, message = fmt.aprintf("cannot write %s (%v)", tmp, oerr)}
	}
	resp, terr := storage_get(c, bucket, name, os.to_writer(f))
	os.close(f)
	defer response_destroy(&resp)
	if terr != "" {
		os.remove(tmp)
		return Error{kind = .Unavailable, message = terr}
	}
	if resp.status < 200 || resp.status >= 300 {
		// The error body went to the file; read it back for the message.
		data, _ := os.read_entire_file_from_path(tmp, context.temp_allocator)
		os.remove(tmp)
		v, _ := parse(string(data), context.temp_allocator)
		return error_from(resp.status, v)
	}
	if err := os.rename(tmp, dest); err != nil {
		os.remove(tmp)
		return Error{kind = .Failed, message = fmt.aprintf("cannot write %s (%v)", dest, err)}
	}
	return {}
}

download_bytes :: proc(c: ^Client, bucket, name: string, allocator := context.allocator) -> (data: []u8, e: Error) {
	if fe := ensure_fresh(c); !ok(fe) {
		return nil, fe
	}
	resp, terr := storage_get(c, bucket, name, nil)
	defer response_destroy(&resp)
	if terr != "" {
		return nil, Error{kind = .Unavailable, message = terr}
	}
	if resp.status < 200 || resp.status >= 300 {
		v, _ := parse(resp.body, context.temp_allocator)
		return nil, error_from(resp.status, v)
	}
	return transmute([]u8)strings.clone(resp.body, allocator), {}
}

// list returns the objects directly under `prefix` (one level, like ls),
// as Storage's array of {name, id, updated_at, metadata: {size, mimetype}}.
list :: proc(c: ^Client, bucket: string, prefix := "", limit := 100, offset := 0, allocator := context.allocator) -> (items: Value, e: Error) {
	o := obj()
	put(&o, "prefix", prefix)
	put(&o, "limit", i64(limit))
	put(&o, "offset", i64(offset))
	put_raw(&o, "sortBy", `{"column":"name","order":"asc"}`)
	return call(c, "POST", fmt.tprintf("/storage/v1/object/list/%s", escape(bucket)), obj_done(&o), allocator = allocator)
}

// remove deletes objects by full name and returns how many went.
remove :: proc(c: ^Client, bucket: string, names: []string) -> (n: int, e: Error) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"prefixes":[`)
	for name, i in names {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		write_quoted(&b, name)
	}
	strings.write_string(&b, "]}")
	v: Value
	v, e = call(c, "DELETE", fmt.tprintf("/storage/v1/object/%s", escape(bucket)), strings.to_string(b))
	defer value_destroy(v)
	return len(array(v)), e
}

@(private)
object_path :: proc(bucket, name: string) -> string {
	return fmt.tprintf("/storage/v1/object/%s/%s", escape(bucket), escape(name, keep_slash = true))
}

@(private)
storage_headers :: proc(c: ^Client) -> [dynamic]Header {
	h := make([dynamic]Header, context.temp_allocator)
	append(&h, Header{"apikey", c.anon_key})
	append(&h, Header{"Authorization", fmt.tprintf("Bearer %s", c.has_session ? c.session.access_token : c.anon_key)})
	return h
}

@(private)
storage_send :: proc(c: ^Client, method, path: string, data: []u8, r: Maybe(io.Reader), size: i64, content_type: string, upsert: bool) -> Error {
	h := storage_headers(c)
	append(&h, Header{"Content-Type", content_type != "" ? content_type : "application/octet-stream"})
	append(&h, Header{"x-upsert", upsert ? "true" : "false"})
	append(&h, Header{"Cache-Control", "max-age=3600"})
	req := Request{method = method, path = path, headers = h[:], body = data, timeout_ms = 120000}
	if _, streaming := r.?; streaming {
		req.body_from = r
		req.body_len = size
	}
	resp, terr := http_do(c.url, req, c.user_agent)
	defer response_destroy(&resp)
	if terr != "" {
		return Error{kind = .Unavailable, message = terr}
	}
	if resp.status >= 200 && resp.status < 300 {
		return {}
	}
	v, _ := parse(resp.body, context.temp_allocator)
	return error_from(resp.status, v)
}

@(private)
storage_get :: proc(c: ^Client, bucket, name: string, sink: Maybe(io.Writer)) -> (Response, string) {
	h := storage_headers(c)
	path := fmt.tprintf("/storage/v1/object/authenticated/%s/%s", escape(bucket), escape(name, keep_slash = true))
	return http_do(c.url, Request{method = "GET", path = path, headers = h[:], sink = sink, timeout_ms = 120000}, c.user_agent)
}

guess_content_type :: proc(path: string) -> string {
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".png"):
		return "image/png"
	case strings.has_suffix(lower, ".jpg"), strings.has_suffix(lower, ".jpeg"):
		return "image/jpeg"
	case strings.has_suffix(lower, ".webp"):
		return "image/webp"
	case strings.has_suffix(lower, ".gif"):
		return "image/gif"
	case strings.has_suffix(lower, ".pdf"):
		return "application/pdf"
	case strings.has_suffix(lower, ".txt"), strings.has_suffix(lower, ".md"):
		return "text/plain; charset=utf-8"
	case strings.has_suffix(lower, ".json"):
		return "application/json"
	case strings.has_suffix(lower, ".html"):
		return "text/html; charset=utf-8"
	}
	return "application/octet-stream"
}
