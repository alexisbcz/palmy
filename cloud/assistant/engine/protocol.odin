package engine

// The pipe between the person's process (the parent: `ai ask`, the window)
// and the assistant (the child, in the sandbox). One JSON document per line
// in each direction.
//
// Parent -> child, once:
//
//	{"request": "...", "conversation_id": "...", "today": "2026-10-19",
//	 "identity": {"handle","name","kind","address"}, "history": [{"role","content"}],
//	 "max_steps": 5}
//
// Child -> parent, as things happen:
//
//	{"t":"sandbox", ...}            what confinement is in force
//	{"t":"tools", "names":[...]}   what the registry offers
//	{"t":"step", "n", "tool", "args"}
//	{"t":"result", "tool", "ok", "summary", "data", "untrusted", "source", "hidden_removed"}
//	{"t":"refused", "tool", "why"}
//	{"t":"draft", "tool", "summary", "action_id"}
//	{"t":"proposal", "action_id", "tool", "args", "summary", "warnings":[...]}
//	{"t":"model", "id", "purpose", "messages":[...], "format": {...}|null, "max_tokens"}
//	{"t":"answer", "text"}
//	{"t":"done", "steps", "model_calls", "ms"}
//	{"t":"error", "message"}
//
// Parent -> child, in reply to each "model":
//
//	{"t":"model_result", "id", "text", "error", "ms"}
//
// Model calls go through the parent so that the sandbox needs no route to a
// model at all, and so that a remote provider's API key never enters the
// sandbox: the assistant cannot read the key, and cannot change which model
// answers it.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import ck "../../../apps/cloudkit"

Turn :: struct {
	role:    string,
	content: string,
}

Identity_Info :: struct {
	handle:  string,
	name:    string,
	kind:    string,
	address: string,
}

Request :: struct {
	request:         string,
	conversation_id: string,
	today:           string, // YYYY-MM-DD
	identity:        Identity_Info,
	history:         []Turn,
	max_steps:       int,
}

Model_Call :: struct {
	purpose:    string, // choose | args | answer
	messages:   []Turn,
	format:     string, // a JSON schema, or ""
	max_tokens: int,
}

Model_Reply :: struct {
	text: string,
	err:  string,
	ms:   i64,
}

// IO is how the engine reaches the outside: events out, model calls brokered.
IO :: struct {
	emit:  proc(io: ^IO, line: string),
	model: proc(io: ^IO, call: Model_Call) -> Model_Reply,
	data:  rawptr,
	calls: int,
}

parse_request :: proc(line: string, allocator := context.allocator) -> (r: Request, ok: bool) {
	v, pok := ck.parse(line, context.temp_allocator)
	if !pok {return {}, false}
	r.request = strings.clone(ck.get_str(v, "request"), allocator)
	r.conversation_id = strings.clone(ck.get_str(v, "conversation_id"), allocator)
	r.today = strings.clone(ck.get_str(v, "today"), allocator)
	r.identity = Identity_Info {
		handle  = strings.clone(ck.get_str(v, "identity", "handle"), allocator),
		name    = strings.clone(ck.get_str(v, "identity", "name"), allocator),
		kind    = strings.clone(ck.get_str(v, "identity", "kind"), allocator),
		address = strings.clone(ck.get_str(v, "identity", "address"), allocator),
	}
	r.max_steps = int(ck.get_int(v, "max_steps"))
	if r.max_steps <= 0 {r.max_steps = 5}
	hist := make([dynamic]Turn, allocator)
	for t in ck.array(ck.get(v, "history")) {
		append(&hist, Turn{strings.clone(ck.get_str(t, "role"), allocator), strings.clone(ck.get_str(t, "content"), allocator)})
	}
	r.history = hist[:]
	return r, r.request != ""
}

request_json :: proc(r: Request, allocator := context.allocator) -> string {
	o := ck.obj(allocator)
	ck.put(&o, "request", r.request)
	ck.put(&o, "conversation_id", r.conversation_id)
	ck.put(&o, "today", r.today)
	id := ck.obj(context.temp_allocator)
	ck.put(&id, "handle", r.identity.handle)
	ck.put(&id, "name", r.identity.name)
	ck.put(&id, "kind", r.identity.kind)
	ck.put(&id, "address", r.identity.address)
	ck.put_raw(&o, "identity", ck.obj_done(&id))
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for t, i in r.history {
		if i > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"role\":%s,\"content\":%s}}", ck.quote(t.role), ck.quote(t.content))
	}
	strings.write_byte(&b, ']')
	ck.put_raw(&o, "history", strings.to_string(b))
	ck.put(&o, "max_steps", i64(r.max_steps))
	return ck.obj_done(&o)
}

model_call_json :: proc(id: int, c: Model_Call, allocator := context.temp_allocator) -> string {
	o := ck.obj(allocator)
	ck.put(&o, "t", "model")
	ck.put(&o, "id", i64(id))
	ck.put(&o, "purpose", c.purpose)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for t, i in c.messages {
		if i > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"role\":%s,\"content\":%s}}", ck.quote(t.role), ck.quote(t.content))
	}
	strings.write_byte(&b, ']')
	ck.put_raw(&o, "messages", strings.to_string(b))
	if c.format != "" {
		ck.put_raw(&o, "format", c.format)
	} else {
		ck.put_null(&o, "format")
	}
	ck.put(&o, "max_tokens", i64(c.max_tokens))
	return ck.obj_done(&o)
}

parse_model_call :: proc(v: ck.Value, allocator := context.allocator) -> Model_Call {
	c := Model_Call {
		purpose    = strings.clone(ck.get_str(v, "purpose"), allocator),
		max_tokens = int(ck.get_int(v, "max_tokens")),
	}
	msgs := make([dynamic]Turn, allocator)
	for m in ck.array(ck.get(v, "messages")) {
		append(&msgs, Turn{strings.clone(ck.get_str(m, "role"), allocator), strings.clone(ck.get_str(m, "content"), allocator)})
	}
	c.messages = msgs[:]
	if f := ck.get(v, "format"); f != nil {
		c.format = raw_json(f, allocator)
	}
	return c
}

// raw_json re-serialises a parsed value.
raw_json :: proc(v: ck.Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_json(&b, v)
	return strings.to_string(b)
}

@(private)
write_json :: proc(b: ^strings.Builder, v: json.Value) {
	switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		fmt.sbprintf(b, "%d", x)
	case json.Float:
		fmt.sbprintf(b, "%v", x)
	case json.Boolean:
		strings.write_string(b, x ? "true" : "false")
	case json.String:
		strings.write_string(b, ck.quote(x))
	case json.Array:
		strings.write_byte(b, '[')
		for item, i in x {
			if i > 0 {strings.write_byte(b, ',')}
			write_json(b, item)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		i := 0
		for k, item in x {
			if i > 0 {strings.write_byte(b, ',')}
			strings.write_string(b, ck.quote(k))
			strings.write_byte(b, ':')
			write_json(b, item)
			i += 1
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

model_reply_json :: proc(id: int, r: Model_Reply, allocator := context.temp_allocator) -> string {
	o := ck.obj(allocator)
	ck.put(&o, "t", "model_result")
	ck.put(&o, "id", i64(id))
	ck.put(&o, "text", r.text)
	ck.put(&o, "error", r.err)
	ck.put(&o, "ms", r.ms)
	return ck.obj_done(&o)
}
