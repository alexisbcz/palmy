package main

// RFC 8620 3.7 result references, RFC 6901 JSON pointers with JMAP's `*`, and
// rendering a parsed json.Value back to text. Taken unchanged from
// apps/mailcore/testserver/jmapd.odin, where mailcore's client is tested
// against it.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Back-references (RFC 8620 3.7)
// ---------------------------------------------------------------------------

// resolve_backrefs rewrites `{"#ids": {resultOf, name, path}}` into
// `{"ids": <the pointed-at value>}`.
//
// The rules it enforces, all of which RFC 8620 3.7 requires and all of which
// are easy to skip:
//
//   - `resultOf` must name an EARLIER call in the same request;
//   - `name` must match that call's method name, so a reference cannot
//     silently read the wrong result when the server reorders;
//   - the pointer must resolve, or the whole call fails with
//     `invalidResultReference` rather than with a missing argument;
//   - both `#x` and `x` present for the same `x` is an error.
resolve_backrefs :: proc(
	args: json.Value,
	ids: []string,
	names: []string,
	vals: []json.Value,
) -> (
	out: string,
	err: string,
) {
	obj, is := args.(json.Object)
	if !is {
		return render_json(args), ""
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	first := true
	for k, v in obj {
		if !strings.has_prefix(k, "#") {
			if !first {strings.write_byte(&sb, ',')}
			first = false
			fmt.sbprintf(&sb, "%s:%s", jq(k), render_json(v))
			continue
		}
		plain := k[1:]
		if _, clash := obj[plain]; clash {
			return "", fmt.tprintf("both %q and %q were given", k, plain)
		}
		result_of := jas_get(v, "resultOf")
		want_name := jas_get(v, "name")
		path := jas_get(v, "path")
		if result_of == "" || want_name == "" {
			return "", fmt.tprintf("the ResultReference for %q is incomplete", k)
		}
		idx := -1
		for id, i in ids {
			if id == result_of {
				idx = i
			}
		}
		if idx < 0 {
			return "", fmt.tprintf("%q refers to call %q, which has not run", k, result_of)
		}
		if names[idx] != want_name {
			return "", fmt.tprintf(
				"%q expects call %q to be %q but it was %q",
				k,
				result_of,
				want_name,
				names[idx],
			)
		}
		pointed, pok := json_pointer_eval(vals[idx], path)
		if !pok {
			return "", fmt.tprintf("the pointer %q does not resolve in the result of %q", path, result_of)
		}
		if !first {strings.write_byte(&sb, ',')}
		first = false
		fmt.sbprintf(&sb, "%s:%s", jq(plain), render_json(pointed))
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb), ""
}

jas_get :: proc(v: json.Value, key: string) -> string {
	o, is := v.(json.Object)
	if !is {
		return ""
	}
	e, has := o[key]
	if !has {
		return ""
	}
	return jas(e)
}

// json_pointer_eval is RFC 6901 plus JMAP's `*`.
json_pointer_eval :: proc(root: json.Value, pointer: string) -> (out: json.Value, ok: bool) {
	if pointer == "" {
		return root, true
	}
	if pointer[0] != '/' {
		return nil, false
	}
	cur := root
	rest := pointer[1:]
	for {
		slash := strings.index_byte(rest, '/')
		token := slash < 0 ? rest : rest[:slash]
		tail := slash < 0 ? "" : rest[slash:]
		tok := pointer_unescape(token)

		if tok == "*" {
			arr, is := cur.(json.Array)
			if !is {
				return nil, false
			}
			flat := make(json.Array, 0, len(arr), context.temp_allocator)
			for e in arr {
				sub, sok := json_pointer_eval(e, tail)
				if !sok {
					continue
				}
				if sa, isa := sub.(json.Array); isa {
					for x in sa {
						append(&flat, x)
					}
				} else {
					append(&flat, sub)
				}
			}
			return flat, true
		}

		switch t in cur {
		case json.Object:
			e, has := t[tok]
			if !has {
				return nil, false
			}
			cur = e
		case json.Array:
			i, iok := strconv.parse_int(tok, 10)
			if !iok || i < 0 || i >= len(t) {
				return nil, false
			}
			cur = t[i]
		case json.Null, json.Integer, json.Float, json.Boolean, json.String:
			return nil, false
		}
		if tail == "" {
			return cur, true
		}
		rest = tail[1:]
	}
}

pointer_unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '~') < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '~' && i + 1 < len(s) {
			if s[i + 1] == '0' {strings.write_byte(&sb, '~');i += 1;continue}
			if s[i + 1] == '1' {strings.write_byte(&sb, '/');i += 1;continue}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// render_json writes a parsed Value back out.
render_json :: proc(v: json.Value) -> string {
	sb := strings.builder_make(context.temp_allocator)
	render_into(&sb, v)
	return strings.to_string(sb)
}

render_into :: proc(sb: ^strings.Builder, v: json.Value) {
	switch t in v {
	case json.Null:
		strings.write_string(sb, "null")
	case json.Integer:
		strings.write_i64(sb, i64(t))
	case json.Float:
		fmt.sbprintf(sb, "%v", f64(t))
	case json.Boolean:
		strings.write_string(sb, bool(t) ? "true" : "false")
	case json.String:
		strings.write_string(sb, jq(string(t)))
	case json.Array:
		strings.write_byte(sb, '[')
		for e, i in t {
			if i > 0 {strings.write_byte(sb, ',')}
			render_into(sb, e)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		strings.write_byte(sb, '{')
		first := true
		for k, e in t {
			if !first {strings.write_byte(sb, ',')}
			first = false
			strings.write_string(sb, jq(k))
			strings.write_byte(sb, ':')
			render_into(sb, e)
		}
		strings.write_byte(sb, '}')
	case:
		strings.write_string(sb, "null")
	}
}

