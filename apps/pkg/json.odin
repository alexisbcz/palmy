package main

// A tiny JSON writer with the comma and colon bookkeeping done for you.
//
// `palm pkg` has one hard output rule, from docs/PALM-CLI.md: machine output
// goes to stdout and nothing else does. Hand-placed commas are where
// hand-written JSON goes wrong, so the separator is the writer's problem.

import "core:strconv"
import "core:strings"

JW :: struct {
	sb:     strings.Builder,
	first:  [32]bool,
	depth:  int,
	in_key: bool,
}

jw_make :: proc(allocator := context.allocator) -> JW {
	w := JW {
		sb = strings.builder_make(allocator),
	}
	w.first[0] = true
	return w
}

jw_text :: proc(w: ^JW) -> string {
	return strings.to_string(w.sb)
}

@(private = "file")
sep :: proc(w: ^JW) {
	if w.in_key {
		w.in_key = false
		return
	}
	if w.first[w.depth] {
		w.first[w.depth] = false
		return
	}
	strings.write_byte(&w.sb, ',')
}

@(private = "file")
push :: proc(w: ^JW) {
	w.depth += 1
	if w.depth < len(w.first) {
		w.first[w.depth] = true
	}
}

@(private = "file")
pop :: proc(w: ^JW) {
	if w.depth > 0 {
		w.depth -= 1
	}
}

jw_obj :: proc(w: ^JW) {
	sep(w)
	strings.write_byte(&w.sb, '{')
	push(w)
}

jw_obj_end :: proc(w: ^JW) {
	pop(w)
	strings.write_byte(&w.sb, '}')
}

jw_arr :: proc(w: ^JW) {
	sep(w)
	strings.write_byte(&w.sb, '[')
	push(w)
}

jw_arr_end :: proc(w: ^JW) {
	pop(w)
	strings.write_byte(&w.sb, ']')
}

jw_key :: proc(w: ^JW, k: string) {
	sep(w)
	jw_quote(w, k)
	strings.write_byte(&w.sb, ':')
	w.in_key = true
}

@(private = "file")
jw_quote :: proc(w: ^JW, s: string) {
	strings.write_byte(&w.sb, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(&w.sb, "\\\"")
		case '\\':
			strings.write_string(&w.sb, "\\\\")
		case '\n':
			strings.write_string(&w.sb, "\\n")
		case '\r':
			strings.write_string(&w.sb, "\\r")
		case '\t':
			strings.write_string(&w.sb, "\\t")
		case:
			if c < 0x20 {
				buf: [8]byte
				strings.write_string(&w.sb, "\\u00")
				hex := "0123456789abcdef"
				buf[0] = hex[c >> 4]
				buf[1] = hex[c & 0xf]
				strings.write_bytes(&w.sb, buf[:2])
			} else {
				strings.write_byte(&w.sb, c)
			}
		}
	}
	strings.write_byte(&w.sb, '"')
}

jw_str :: proc(w: ^JW, s: string) {
	sep(w)
	jw_quote(w, s)
}

jw_int :: proc(w: ^JW, v: int) {
	sep(w)
	buf: [24]byte
	strings.write_string(&w.sb, strconv.write_int(buf[:], i64(v), 10))
}

jw_bool :: proc(w: ^JW, v: bool) {
	sep(w)
	strings.write_string(&w.sb, v ? "true" : "false")
}

jw_kstr :: proc(w: ^JW, k, v: string) {
	jw_key(w, k)
	jw_str(w, v)
}

jw_kint :: proc(w: ^JW, k: string, v: int) {
	jw_key(w, k)
	jw_int(w, v)
}

jw_kbool :: proc(w: ^JW, k: string, v: bool) {
	jw_key(w, k)
	jw_bool(w, v)
}

jw_kstrs :: proc(w: ^JW, k: string, vs: []string) {
	jw_key(w, k)
	jw_arr(w)
	for v in vs {
		jw_str(w, v)
	}
	jw_arr_end(w)
}
