package main

// A tiny JSON builder with the comma and colon bookkeeping done for you.
//
// `palm pkg` has one hard output rule, from docs/PALM-CLI.md: machine output
// goes to stdout and nothing else does. The verbs describe their result with
// the calls below, and what those calls build is the kit's own JSON tree —
// the object `kit.cli` prints under --json, validates against the declared
// `out` fields, and renders for a person otherwise. There is one result per
// command, not a hand-written string next to a schema that describes it.

import kit "kit:."

JW :: struct {
	root:   ^kit.Json,
	stack:  [32]^kit.Json,
	depth:  int,
	key:    string,
	in_key: bool,
}

jw_make :: proc(allocator := context.allocator) -> JW {
	return JW{}
}

// jw_text is the compact rendering, `{"op":"list",...}`.
jw_text :: proc(w: ^JW) -> string {
	return kit.json_text(w.root, 0, context.temp_allocator)
}

@(private = "file")
attach :: proc(w: ^JW, v: ^kit.Json) {
	if w.depth == 0 {
		if w.root == nil {
			w.root = v
		}
		return
	}
	top := w.stack[w.depth - 1]
	if top.kind == .Object {
		if w.in_key {
			kit.jset(top, w.key, v)
			w.in_key = false
		}
	} else {
		kit.jpush(top, v)
	}
}

@(private = "file")
push :: proc(w: ^JW, v: ^kit.Json) {
	attach(w, v)
	if w.depth < len(w.stack) {
		w.stack[w.depth] = v
	}
	w.depth += 1
}

@(private = "file")
pop :: proc(w: ^JW) {
	if w.depth > 0 {
		w.depth -= 1
	}
}

jw_obj :: proc(w: ^JW) {push(w, kit.jobj())}
jw_obj_end :: proc(w: ^JW) {pop(w)}
jw_arr :: proc(w: ^JW) {push(w, kit.jarr())}
jw_arr_end :: proc(w: ^JW) {pop(w)}

jw_key :: proc(w: ^JW, k: string) {
	w.key = k
	w.in_key = true
}

jw_str :: proc(w: ^JW, s: string) {attach(w, kit.jstr(s))}
jw_int :: proc(w: ^JW, v: int) {attach(w, kit.jint(v))}
jw_bool :: proc(w: ^JW, v: bool) {attach(w, kit.jbool(v))}

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
