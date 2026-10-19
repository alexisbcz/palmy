// Package web is HTTP/1.1 over core:net: a threaded server for cloud/dav and
// a small client for PostgREST, GoTrue and the DAV server itself.
//
// Plain HTTP only. In production the server sits behind the same TLS
// terminator as the Supabase gateway; on a laptop it listens on loopback.
// The client refuses https:// rather than sending credentials in the clear
// (apps/cloudkit is growing a TLS seam; when it lands, this client should be
// replaced by cloudkit's — see cloud/docs/calendar-contacts.md).
package web

import "core:encoding/base64"
import "core:strconv"
import "core:strings"

Header :: [2]string

header :: proc(hs: []Header, name: string) -> string {
	for h in hs {
		if strings.equal_fold(h[0], name) {
			return h[1]
		}
	}
	return ""
}

status_text :: proc(code: int) -> string {
	switch code {
	case 100: return "Continue"
	case 200: return "OK"
	case 201: return "Created"
	case 204: return "No Content"
	case 207: return "Multi-Status"
	case 301: return "Moved Permanently"
	case 302: return "Found"
	case 304: return "Not Modified"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 409: return "Conflict"
	case 411: return "Length Required"
	case 412: return "Precondition Failed"
	case 413: return "Payload Too Large"
	case 415: return "Unsupported Media Type"
	case 422: return "Unprocessable Entity"
	case 423: return "Locked"
	case 500: return "Internal Server Error"
	case 501: return "Not Implemented"
	case 502: return "Bad Gateway"
	case 503: return "Service Unavailable"
	case 507: return "Insufficient Storage"
	}
	return "Status"
}

// ---------------------------------------------------------------------------
// URLs and paths
// ---------------------------------------------------------------------------

URL :: struct {
	scheme: string,
	host:   string,
	port:   int,
	path:   string, // with query
}

parse_url :: proc(u: string) -> (out: URL, ok: bool) {
	rest := u
	if i := strings.index(rest, "://"); i >= 0 {
		out.scheme = strings.to_lower(rest[:i], context.temp_allocator)
		rest = rest[i + 3:]
	} else {
		return {}, false
	}
	slash := strings.index_byte(rest, '/')
	hostport := slash < 0 ? rest : rest[:slash]
	out.path = slash < 0 ? "/" : rest[slash:]
	out.port = out.scheme == "https" ? 443 : 80
	if colon := strings.last_index_byte(hostport, ':'); colon >= 0 {
		p, good := strconv.parse_int(hostport[colon + 1:])
		if !good {
			return {}, false
		}
		out.port = p
		out.host = hostport[:colon]
	} else {
		out.host = hostport
	}
	return out, out.host != ""
}

// percent_decode decodes %XX. '+' is left alone: in a path it is a plus.
percent_decode :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '%') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			v, ok := strconv.parse_u64_of_base(s[i + 1:i + 3], 16)
			if ok {
				strings.write_byte(&sb, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// percent_encode encodes one path segment (RFC 3986 unreserved kept).
percent_encode :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '@', '+', '=', ',', '!', '$', '\'', '(', ')', '*', ':':
			strings.write_byte(&sb, c)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 15])
		}
	}
	return strings.to_string(sb)
}

// query_encode encodes a PostgREST query value.
query_encode :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~':
			strings.write_byte(&sb, c)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 15])
		}
	}
	return strings.to_string(sb)
}

// basic_auth decodes "Basic base64(user:pass)".
basic_auth :: proc(value: string) -> (user, pass: string, ok: bool) {
	v := strings.trim_space(value)
	if len(v) < 6 || !strings.equal_fold(v[:6], "basic ") {
		return
	}
	raw, err := base64.decode(strings.trim_space(v[6:]))
	if err != nil {
		return
	}
	s := string(raw)
	colon := strings.index_byte(s, ':')
	if colon < 0 {
		return
	}
	return s[:colon], s[colon + 1:], true
}

basic_header :: proc(user, pass: string, allocator := context.allocator) -> string {
	enc := base64.encode(transmute([]u8)strings.concatenate({user, ":", pass}, context.temp_allocator), allocator = context.temp_allocator)
	return strings.concatenate({"Basic ", enc}, allocator)
}

bearer :: proc(value: string) -> (string, bool) {
	v := strings.trim_space(value)
	if len(v) > 7 && strings.equal_fold(v[:7], "bearer ") {
		return strings.trim_space(v[7:]), true
	}
	return "", false
}

// json_string writes a JSON string literal.
json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"': strings.write_string(sb, `\"`)
		case '\\': strings.write_string(sb, `\\`)
		case '\n': strings.write_string(sb, `\n`)
		case '\r': strings.write_string(sb, `\r`)
		case '\t': strings.write_string(sb, `\t`)
		case:
			if c < 0x20 {
				HEX := "0123456789abcdef"
				strings.write_string(sb, `\u00`)
				strings.write_byte(sb, HEX[c >> 4])
				strings.write_byte(sb, HEX[c & 15])
			} else {
				strings.write_byte(sb, c)
			}
		}
	}
	strings.write_byte(sb, '"')
}

json_quote :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	json_string(&sb, s)
	return strings.to_string(sb)
}
