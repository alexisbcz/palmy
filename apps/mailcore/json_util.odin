package main

// A JSON writer with comma/colon bookkeeping, plus navigation helpers over
// core:encoding/json's Value tree, including RFC 6901 pointers (which JMAP
// needs for back-references).
//
// The writer exists because JMAP requests are nested four deep and hand-rolled
// comma placement is where hand-written JSON goes wrong.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

JW :: struct {
	sb:    strings.Builder,
	// `first` tracks, per nesting level, whether a separator is needed.
	first: [32]bool,
	depth: int,
}

jw_make :: proc(allocator := context.allocator) -> JW {
	w := JW {
		sb = strings.builder_make(allocator),
	}
	w.first[0] = true
	return w
}

jw_string :: proc(w: ^JW) -> string {
	return strings.to_string(w.sb)
}

@(private = "file")
jw_sep :: proc(w: ^JW) {
	if w.first[w.depth] {
		w.first[w.depth] = false
		return
	}
	strings.write_byte(&w.sb, ',')
}

@(private = "file")
jw_push :: proc(w: ^JW) {
	if w.depth < 31 {
		w.depth += 1
	}
	w.first[w.depth] = true
}

@(private = "file")
jw_pop :: proc(w: ^JW) {
	if w.depth > 0 {
		w.depth -= 1
	}
}

jw_obj :: proc(w: ^JW) {
	jw_sep(w)
	strings.write_byte(&w.sb, '{')
	jw_push(w)
}

jw_obj_end :: proc(w: ^JW) {
	jw_pop(w)
	strings.write_byte(&w.sb, '}')
}

jw_arr :: proc(w: ^JW) {
	jw_sep(w)
	strings.write_byte(&w.sb, '[')
	jw_push(w)
}

jw_arr_end :: proc(w: ^JW) {
	jw_pop(w)
	strings.write_byte(&w.sb, ']')
}

// jw_key writes `"name":` and suppresses the separator for the value that
// follows, so values do not need to know whether they are in an object.
jw_key :: proc(w: ^JW, name: string) {
	jw_sep(w)
	json_quote_into(&w.sb, name)
	strings.write_byte(&w.sb, ':')
	w.first[w.depth] = true
}

jw_str :: proc(w: ^JW, v: string) {
	jw_sep(w)
	json_quote_into(&w.sb, v)
}

jw_int :: proc(w: ^JW, v: int) {
	jw_sep(w)
	strings.write_int(&w.sb, v)
}

jw_bool :: proc(w: ^JW, v: bool) {
	jw_sep(w)
	strings.write_string(&w.sb, v ? "true" : "false")
}

jw_null :: proc(w: ^JW) {
	jw_sep(w)
	strings.write_string(&w.sb, "null")
}

// jw_raw splices in already-valid JSON, which is how pre-built argument blobs
// and back-reference objects get in.
jw_raw :: proc(w: ^JW, v: string) {
	jw_sep(w)
	strings.write_string(&w.sb, v)
}

jw_kstr :: proc(w: ^JW, k, v: string) {jw_key(w, k);jw_str(w, v)}
jw_kint :: proc(w: ^JW, k: string, v: int) {jw_key(w, k);jw_int(w, v)}
jw_kbool :: proc(w: ^JW, k: string, v: bool) {jw_key(w, k);jw_bool(w, v)}
jw_knull :: proc(w: ^JW, k: string) {jw_key(w, k);jw_null(w)}
jw_kraw :: proc(w: ^JW, k, v: string) {jw_key(w, k);jw_raw(w, v)}

jw_str_array :: proc(w: ^JW, items: []string) {
	jw_arr(w)
	for s in items {
		jw_str(w, s)
	}
	jw_arr_end(w)
}

// json_quote_into escapes per RFC 8259. Control characters become \u escapes;
// everything else (including UTF-8) goes through untouched.
json_quote_into :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case '\b':
			strings.write_string(sb, "\\b")
		case '\f':
			strings.write_string(sb, "\\f")
		case:
			if ch < 0x20 {
				fmt.sbprintf(sb, "\\u%04x", int(ch))
			} else {
				strings.write_byte(sb, ch)
			}
		}
	}
	strings.write_byte(sb, '"')
}

json_quote :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	json_quote_into(&sb, s)
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

jv_obj :: proc(v: json.Value) -> (json.Object, bool) {
	o, ok := v.(json.Object)
	return o, ok
}

jv_get :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	o, ok := v.(json.Object)
	if !ok {
		return nil, false
	}
	e, has := o[key]
	return e, has
}

jv_str :: proc(v: json.Value, key: string) -> string {
	e, ok := jv_get(v, key)
	if !ok {
		return ""
	}
	if s, is := e.(json.String); is {
		return string(s)
	}
	return ""
}

jv_int :: proc(v: json.Value, key: string) -> int {
	e, ok := jv_get(v, key)
	if !ok {
		return 0
	}
	switch t in e {
	case json.Integer:
		return int(t)
	case json.Float:
		return int(t)
	case json.String:
		n, _ := strconv.parse_int(string(t), 10)
		return n
	case json.Null, json.Boolean, json.Array, json.Object:
		return 0
	}
	return 0
}

jv_bool :: proc(v: json.Value, key: string) -> bool {
	e, ok := jv_get(v, key)
	if !ok {
		return false
	}
	b, is := e.(json.Boolean)
	return is && bool(b)
}

jv_arr :: proc(v: json.Value, key: string) -> json.Array {
	e, ok := jv_get(v, key)
	if !ok {
		return nil
	}
	a, is := e.(json.Array)
	if !is {
		return nil
	}
	return a
}

jv_as_str :: proc(v: json.Value) -> string {
	if s, is := v.(json.String); is {
		return string(s)
	}
	return ""
}

jv_str_array :: proc(v: json.Value, key: string, allocator := context.allocator) -> []string {
	a := jv_arr(v, key)
	out := make([dynamic]string, 0, len(a), allocator)
	for e in a {
		if s, is := e.(json.String); is {
			append(&out, strings.clone(string(s), allocator))
		}
	}
	return out[:]
}

// jv_keys_true returns the keys of a `{"$seen": true}`-shaped JMAP set.
jv_keys_true :: proc(v: json.Value, key: string, allocator := context.allocator) -> []string {
	e, ok := jv_get(v, key)
	if !ok {
		return nil
	}
	o, is := e.(json.Object)
	if !is {
		return nil
	}
	out := make([dynamic]string, 0, len(o), allocator)
	for k, val in o {
		if b, isb := val.(json.Boolean); isb && bool(b) {
			append(&out, strings.clone(k, allocator))
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// RFC 6901 JSON pointers, with JMAP's `*` extension
// ---------------------------------------------------------------------------

// json_pointer resolves a pointer against a value.
//
// RFC 8620 3.7 extends RFC 6901 with one rule: a `*` path element maps the
// rest of the pointer over an array and flattens the results by one level.
// That is what makes `/list/*/id` — "the id of every item" — expressible, and
// it is exactly what a back-reference like
//
//	"#ids": {"resultOf": "c1", "name": "Email/query", "path": "/ids"}
//
// needs when the referenced result is a list of objects rather than a list of
// strings. Without `*`, back-references only work for the easy case.
json_pointer :: proc(
	root: json.Value,
	pointer: string,
	allocator := context.allocator,
) -> (
	out: json.Value,
	ok: bool,
) {
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
		tok := json_pointer_unescape(token, context.temp_allocator)

		if tok == "*" {
			arr, is := cur.(json.Array)
			if !is {
				return nil, false
			}
			flat := make(json.Array, 0, len(arr), allocator)
			for e in arr {
				sub, sok := json_pointer(e, tail, allocator)
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
			idx, iok := strconv.parse_int(tok, 10)
			if !iok || idx < 0 || idx >= len(t) {
				return nil, false
			}
			cur = t[idx]
		case json.Null, json.Integer, json.Float, json.Boolean, json.String:
			return nil, false
		}

		if tail == "" {
			return cur, true
		}
		rest = tail[1:]
	}
}

json_pointer_unescape :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '~') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '~' && i + 1 < len(s) {
			switch s[i + 1] {
			case '0':
				strings.write_byte(&sb, '~');i += 1;continue
			case '1':
				strings.write_byte(&sb, '/');i += 1;continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Rendering a parsed value back out
// ---------------------------------------------------------------------------

// json_render writes a json.Value as compact JSON. Used by the self-test to
// state an expected value for a pointer result, and by anything that needs to
// log what it actually received.
json_render :: proc(v: json.Value, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	json_render_into(&sb, v)
	return strings.to_string(sb)
}

json_render_into :: proc(sb: ^strings.Builder, v: json.Value) {
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
		json_quote_into(sb, string(t))
	case json.Array:
		strings.write_byte(sb, '[')
		for e, i in t {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			json_render_into(sb, e)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		strings.write_byte(sb, '{')
		first := true
		for k, e in t {
			if !first {
				strings.write_byte(sb, ',')
			}
			first = false
			json_quote_into(sb, k)
			strings.write_byte(sb, ':')
			json_render_into(sb, e)
		}
		strings.write_byte(sb, '}')
	case:
		strings.write_string(sb, "null")
	}
}
