// A small ordered JSON value tree, for the CLI convention in cli.odin.
//
// Why not `core:encoding/json`'s marshaller: it writes a Go-style map, whose
// key order is whatever the hash table happens to give, and a struct has to
// exist for every shape. A command's result is built once and read by an
// agent, so what matters is that the same command always prints its keys in
// the same order — a diff of two runs should show what changed, not where the
// hasher moved. This tree keeps insertion order and needs no type per shape.
//
// Reading JSON is still `core:encoding/json`'s job; see `json_validate` in
// cli.odin, which parses a command's own output back and checks it against the
// schema the command declared.
package kit

import "core:fmt"
import "core:strconv"
import "core:strings"

Json_Kind :: enum u8 {
	Null,
	Bool,
	Int,
	Float,
	String,
	Array,
	Object,
}

// Json is one node. Objects keep `keys` and `items` parallel, in insertion
// order; arrays leave `keys` empty.
Json :: struct {
	kind:  Json_Kind,
	b:     bool,
	i:     i64,
	f:     f64,
	s:     string,
	keys:  [dynamic]string,
	items: [dynamic]^Json,
}

@(private = "file")
jnode :: proc(kind: Json_Kind, allocator := context.allocator) -> ^Json {
	n := new(Json, allocator)
	n.kind = kind
	return n
}

jnull :: proc(allocator := context.allocator) -> ^Json {
	return jnode(.Null, allocator)
}

jbool :: proc(v: bool, allocator := context.allocator) -> ^Json {
	n := jnode(.Bool, allocator)
	n.b = v
	return n
}

jint :: proc(v: int, allocator := context.allocator) -> ^Json {
	n := jnode(.Int, allocator)
	n.i = i64(v)
	return n
}

ji64 :: proc(v: i64, allocator := context.allocator) -> ^Json {
	n := jnode(.Int, allocator)
	n.i = v
	return n
}

jnum :: proc(v: f64, allocator := context.allocator) -> ^Json {
	n := jnode(.Float, allocator)
	n.f = v
	return n
}

// jstr clones, so a value built with `fmt.tprintf` survives the next frame or
// the next temp-allocator reset.
jstr :: proc(v: string, allocator := context.allocator) -> ^Json {
	n := jnode(.String, allocator)
	n.s = strings.clone(v, allocator)
	return n
}

jarr :: proc(allocator := context.allocator) -> ^Json {
	n := jnode(.Array, allocator)
	n.items = make([dynamic]^Json, allocator)
	return n
}

jobj :: proc(allocator := context.allocator) -> ^Json {
	n := jnode(.Object, allocator)
	n.keys = make([dynamic]string, allocator)
	n.items = make([dynamic]^Json, allocator)
	return n
}

// jpush appends to an array and returns the value, so calls nest.
jpush :: proc(a: ^Json, v: ^Json) -> ^Json {
	if a == nil || a.kind != .Array {
		return v
	}
	append(&a.items, v)
	return v
}

// jset sets a key on an object, replacing it in place if it is already there
// so the order a result is built in is the order it prints in. Returns the
// value.
jset :: proc(o: ^Json, key: string, v: ^Json, allocator := context.allocator) -> ^Json {
	if o == nil || o.kind != .Object {
		return v
	}
	for k, i in o.keys {
		if k == key {
			o.items[i] = v
			return v
		}
	}
	append(&o.keys, strings.clone(key, allocator))
	append(&o.items, v)
	return v
}

jset_str :: proc(o: ^Json, key, v: string, allocator := context.allocator) -> ^Json {
	return jset(o, key, jstr(v, allocator), allocator)
}

jset_int :: proc(o: ^Json, key: string, v: int, allocator := context.allocator) -> ^Json {
	return jset(o, key, jint(v, allocator), allocator)
}

jset_i64 :: proc(o: ^Json, key: string, v: i64, allocator := context.allocator) -> ^Json {
	return jset(o, key, ji64(v, allocator), allocator)
}

jset_num :: proc(o: ^Json, key: string, v: f64, allocator := context.allocator) -> ^Json {
	return jset(o, key, jnum(v, allocator), allocator)
}

jset_bool :: proc(o: ^Json, key: string, v: bool, allocator := context.allocator) -> ^Json {
	return jset(o, key, jbool(v, allocator), allocator)
}

// jget looks a key up on an object.
jget :: proc(o: ^Json, key: string) -> (v: ^Json, ok: bool) {
	if o == nil || o.kind != .Object {
		return nil, false
	}
	for k, i in o.keys {
		if k == key {
			return o.items[i], true
		}
	}
	return nil, false
}

// jlen is the element count of an array or object, and 0 for a scalar.
jlen :: proc(v: ^Json) -> int {
	if v == nil {
		return 0
	}
	return len(v.items)
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// json_escape writes a JSON string literal, quotes included.
json_escape :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(sb, `\"`)
		case '\\':
			strings.write_string(sb, `\\`)
		case '\n':
			strings.write_string(sb, `\n`)
		case '\r':
			strings.write_string(sb, `\r`)
		case '\t':
			strings.write_string(sb, `\t`)
		case '\b':
			strings.write_string(sb, `\b`)
		case '\f':
			strings.write_string(sb, `\f`)
		case:
			if c < 0x20 {
				strings.write_string(sb, fmt.tprintf(`\u%04x`, int(c)))
			} else {
				strings.write_byte(sb, c)
			}
		}
	}
	strings.write_byte(sb, '"')
}

// json_write renders a node. `indent` of 0 is compact; anything larger is
// pretty-printed with that many spaces per level.
json_write :: proc(sb: ^strings.Builder, v: ^Json, indent := 2, depth := 0) {
	pad :: proc(sb: ^strings.Builder, indent, depth: int) {
		if indent <= 0 {
			return
		}
		for _ in 0 ..< indent * depth {
			strings.write_byte(sb, ' ')
		}
	}
	nl :: proc(sb: ^strings.Builder, indent: int) {
		if indent > 0 {
			strings.write_byte(sb, '\n')
		}
	}

	if v == nil {
		strings.write_string(sb, "null")
		return
	}
	switch v.kind {
	case .Null:
		strings.write_string(sb, "null")
	case .Bool:
		strings.write_string(sb, v.b ? "true" : "false")
	case .Int:
		buf: [24]byte
		strings.write_string(sb, strconv.write_int(buf[:], v.i, 10))
	case .Float:
		// Shortest round-trip decimal: 2781.05 rather than 2781.050000, and
		// still the exact value when it needs the digits. generic_ftoa signs
		// positive numbers with a leading '+', which JSON does not allow, so
		// that one character is dropped.
		fbuf: [40]byte
		t := string(strconv.generic_ftoa(fbuf[:], v.f, 'f', -1, 64))
		if len(t) > 0 && t[0] == '+' {
			t = t[1:]
		}
		strings.write_string(sb, t)
	case .String:
		json_escape(sb, v.s)
	case .Array:
		if len(v.items) == 0 {
			strings.write_string(sb, "[]")
			return
		}
		strings.write_byte(sb, '[')
		nl(sb, indent)
		for it, i in v.items {
			pad(sb, indent, depth + 1)
			json_write(sb, it, indent, depth + 1)
			if i < len(v.items) - 1 {
				strings.write_byte(sb, ',')
			}
			nl(sb, indent)
		}
		pad(sb, indent, depth)
		strings.write_byte(sb, ']')
	case .Object:
		if len(v.items) == 0 {
			strings.write_string(sb, "{}")
			return
		}
		strings.write_byte(sb, '{')
		nl(sb, indent)
		for it, i in v.items {
			pad(sb, indent, depth + 1)
			json_escape(sb, v.keys[i])
			strings.write_byte(sb, ':')
			if indent > 0 {
				strings.write_byte(sb, ' ')
			}
			json_write(sb, it, indent, depth + 1)
			if i < len(v.items) - 1 {
				strings.write_byte(sb, ',')
			}
			nl(sb, indent)
		}
		pad(sb, indent, depth)
		strings.write_byte(sb, '}')
	}
}

// json_text renders a node to a string.
json_text :: proc(v: ^Json, indent := 2, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	json_write(&sb, v, indent)
	return strings.to_string(sb)
}

// json_scalar is a node's value as a plain string, for the human rendering.
json_scalar :: proc(v: ^Json, allocator := context.temp_allocator) -> string {
	if v == nil {
		return "null"
	}
	switch v.kind {
	case .Null:
		return "—"
	case .Bool:
		return v.b ? "yes" : "no"
	case .Int:
		return fmt.tprintf("%d", v.i)
	case .Float:
		return fmt.tprintf("%g", v.f)
	case .String:
		return v.s
	case .Array, .Object:
		return json_text(v, 0, allocator)
	}
	return ""
}
