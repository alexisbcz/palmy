// The drive's transport: apps/cloudkit's HTTP/1.1, which has the TLS seam
// (cloudkit.tls_dial), proper framing, and streaming.
//
// Every call in this package goes through `request`, so this file is the
// whole of the dependency. What is still the drive's own is the typed calls
// in api.odin; they could move onto cloudkit.select/rpc too, but they decode
// straight into structs with core:encoding/json, which cloudkit's Value tree
// would only add a step to.
package drivecore

import "core:fmt"
import "core:strings"
import "core:time"
import ck "../../../apps/cloudkit"

Response :: struct {
	status: int, // 0 when the server could not be reached
	body:   []u8,
	err:    string, // transport error, when status is 0
}

Header :: ck.Header

// request performs one call and reads the whole response. `base` is a URL
// whose path is a prefix (http://host:port/rest/v1); `path` is appended.
request :: proc(
	method, base, path: string,
	headers: []Header,
	body: []u8 = nil,
	timeout := 30 * time.Second,
	allocator := context.allocator,
) -> (
	r: Response,
) {
	u, ok := ck.parse_url(base)
	if !ok {
		r.err = fmt.tprintf("not an http(s) URL: %q", base)
		return
	}
	req := ck.Request {
		method     = method,
		path       = path, // http_do puts u.base in front
		headers    = headers,
		body       = body,
		timeout_ms = int(time.duration_milliseconds(timeout)),
	}
	resp, err := ck.http_do(u, req, "palm-drive/0.1")
	if err != "" {
		r.err = strings.clone(err, context.temp_allocator)
		delete(err)
		return
	}
	defer ck.response_destroy(&resp)
	r.status = resp.status
	r.body = transmute([]u8)strings.clone(resp.body, allocator)
	return
}
