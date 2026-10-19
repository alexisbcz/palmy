package cloudkit

// JSON in and out. Parsing is core:encoding/json; these are the small
// conveniences every caller would otherwise write: reading a field without
// a type switch, and building a request body without hand-escaping.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

Value :: json.Value

parse :: proc(text: string, allocator := context.allocator) -> (v: Value, ok: bool) {
	if strings.trim_space(text) == "" {
		return nil, false
	}
	val, err := json.parse_string(text, json.Specification.JSON, true, allocator)
	if err != .None {
		return nil, false
	}
	return val, true
}

value_destroy :: proc(v: Value, allocator := context.allocator) {
	json.destroy_value(v, allocator)
}

// get walks object keys: get(v, "user", "email").
get :: proc(v: Value, keys: ..string) -> Value {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok {
			return nil
		}
		cur = obj[k] or_else nil
	}
	return cur
}

get_str :: proc(v: Value, keys: ..string) -> string {
	#partial switch x in get(v, ..keys) {
	case json.String:
		return string(x)
	}
	return ""
}

get_int :: proc(v: Value, keys: ..string) -> i64 {
	#partial switch x in get(v, ..keys) {
	case json.Integer:
		return i64(x)
	case json.Float:
		return i64(x)
	case json.String:
		n, _ := strconv.parse_i64(string(x))
		return n
	}
	return 0
}

get_bool :: proc(v: Value, keys: ..string) -> bool {
	#partial switch x in get(v, ..keys) {
	case json.Boolean:
		return bool(x)
	}
	return false
}

is_null :: proc(v: Value, keys: ..string) -> bool {
	x := get(v, ..keys)
	if x == nil {
		return true
	}
	_, null := x.(json.Null)
	return null
}

array :: proc(v: Value) -> []Value {
	if a, ok := v.(json.Array); ok {
		return a[:]
	}
	return nil
}

// quote returns s as a JSON string literal, quotes included.
quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_quoted(&b, s)
	return strings.to_string(b)
}

write_quoted :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(b, `\u%04x`, int(r))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}

// Obj builds a flat JSON object: obj := cloudkit.obj(); cloudkit.put(&obj,
// "handle", "alice"); body := cloudkit.obj_done(&obj).
Obj :: struct {
	b: strings.Builder,
	n: int,
}

obj :: proc(allocator := context.temp_allocator) -> Obj {
	o := Obj{b = strings.builder_make(allocator)}
	strings.write_byte(&o.b, '{')
	return o
}

@(private = "file")
obj_key :: proc(o: ^Obj, key: string) {
	if o.n > 0 {
		strings.write_byte(&o.b, ',')
	}
	o.n += 1
	write_quoted(&o.b, key)
	strings.write_byte(&o.b, ':')
}

put_str :: proc(o: ^Obj, key, value: string) {
	obj_key(o, key)
	write_quoted(&o.b, value)
}

put_int :: proc(o: ^Obj, key: string, value: i64) {
	obj_key(o, key)
	fmt.sbprintf(&o.b, "%d", value)
}

put_bool :: proc(o: ^Obj, key: string, value: bool) {
	obj_key(o, key)
	strings.write_string(&o.b, value ? "true" : "false")
}

put_null :: proc(o: ^Obj, key: string) {
	obj_key(o, key)
	strings.write_string(&o.b, "null")
}

// put_raw inserts already-encoded JSON.
put_raw :: proc(o: ^Obj, key, raw_json: string) {
	obj_key(o, key)
	strings.write_string(&o.b, raw_json)
}

put :: proc {
	put_str,
	put_int,
	put_bool,
}

obj_done :: proc(o: ^Obj) -> string {
	strings.write_byte(&o.b, '}')
	return strings.to_string(o.b)
}

// one and two are the common small bodies: {"key": "value"}. A JSON literal
// must never be a fmt format string: Odin's fmt reads `{` as the start of a
// placeholder and prints %!(MISSING CLOSE BRACE).
one :: proc(key, value: string) -> string {
	o := obj()
	put_str(&o, key, value)
	return obj_done(&o)
}

two :: proc(k1, v1, k2, v2: string) -> string {
	o := obj()
	put_str(&o, k1, v1)
	put_str(&o, k2, v2)
	return obj_done(&o)
}
