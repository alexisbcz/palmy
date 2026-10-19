package wire

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// q quotes and escapes a string as a JSON string literal.
q :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(&sb, `\"`)
		case '\\':
			strings.write_string(&sb, `\\`)
		case '\n':
			strings.write_string(&sb, `\n`)
		case '\r':
			strings.write_string(&sb, `\r`)
		case '\t':
			strings.write_string(&sb, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(&sb, `\u%04x`, int(r))
			} else {
				strings.write_rune(&sb, r)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// qn is q, or `null` for the empty string.
qn :: proc(s: string, allocator := context.temp_allocator) -> string {
	return "null" if s == "" else q(s, allocator)
}

parse :: proc(data: []u8, allocator := context.allocator) -> (json.Value, bool) {
	v, err := json.parse(data, json.DEFAULT_SPECIFICATION, true, allocator)
	return v, err == nil
}

get :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok {
		return o[key]
	}
	return nil
}

str :: proc(v: json.Value, key: string = "") -> string {
	x := v if key == "" else get(v, key)
	#partial switch t in x {
	case json.String:
		return string(t)
	case json.Integer:
		return fmt.tprintf("%d", t)
	case json.Float:
		return fmt.tprintf("%v", t)
	case json.Boolean:
		return "true" if t else "false"
	}
	return ""
}

num :: proc(v: json.Value, key: string = "") -> int {
	x := v if key == "" else get(v, key)
	#partial switch t in x {
	case json.Integer:
		return int(t)
	case json.Float:
		return int(t)
	case json.String:
		n, _ := strconv.parse_int(string(t))
		return n
	}
	return 0
}

flag :: proc(v: json.Value, key: string) -> bool {
	b, ok := get(v, key).(json.Boolean)
	return ok && bool(b)
}

arr :: proc(v: json.Value, key: string = "") -> json.Array {
	x := v if key == "" else get(v, key)
	a, _ := x.(json.Array)
	return a
}

is_null :: proc(v: json.Value, key: string) -> bool {
	x := get(v, key)
	if x == nil {
		return true
	}
	_, n := x.(json.Null)
	return n
}

// first returns the first element of a JSON array (PostgREST answers lists).
first :: proc(v: json.Value) -> (json.Value, bool) {
	a, ok := v.(json.Array)
	if !ok || len(a) == 0 {
		return nil, false
	}
	return a[0], true
}

// strs reads a JSON array of strings.
strs :: proc(v: json.Value, key: string, allocator := context.temp_allocator) -> []string {
	a := arr(v, key)
	out := make([]string, len(a), allocator)
	for x, i in a {
		out[i] = str(x)
	}
	return out
}
