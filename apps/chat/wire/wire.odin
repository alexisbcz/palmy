// The palmy-chat wire protocol: framing, JSON encoding and the two shared
// record types. Both the client (`apps/chat`) and the server
// (`apps/chat/server`) are `package main`, so everything they must agree on
// lives here and is imported relatively from both.
//
// See ../PROTOCOL.md for the message catalogue.
package wire

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

PROTO_VERSION :: 1
DEFAULT_PORT :: 8787

// A frame is a 4-byte big-endian length followed by that many bytes of UTF-8
// JSON. One megabyte is far more than any message here needs; a peer that
// claims more is treated as corrupt and the connection is dropped.
MAX_FRAME :: 1 << 20

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

Presence :: enum u8 {
	Offline,
	Away,
	Online,
}

presence_name :: proc(s: Presence) -> string {
	switch s {
	case .Offline:
		return "offline"
	case .Away:
		return "away"
	case .Online:
		return "online"
	}
	return "offline"
}

presence_of :: proc(name: string) -> Presence {
	switch name {
	case "online":
		return .Online
	case "away":
		return .Away
	}
	return .Offline
}

Chan_Kind :: enum u8 {
	Channel,
	DM,
}

Chan :: struct {
	name:  string, // "general", or "alexis+sam" for a DM
	kind:  Chan_Kind,
	topic: string,
}

React :: struct {
	key:   string, // one of REACTIONS below
	nicks: [dynamic]string,
}

Msg :: struct {
	id:       i64,
	ch:       string,
	nick:     string,
	text:     string,
	ts:       i64, // unix seconds
	edited:   i64, // unix seconds, 0 when never edited
	deleted:  bool,
	reply_to: i64, // 0 when not a reply
	reacts:   [dynamic]React,
}

// The reaction vocabulary is fixed, and deliberately not emoji: the UI font
// here has no emoji coverage, so a reaction is a drawn icon keyed by name.
REACTIONS :: [6]string{"thumbsup", "heart", "party", "rocket", "fire", "grin"}

reaction_valid :: proc(key: string) -> bool {
	for k in REACTIONS {
		if k == key {
			return true
		}
	}
	return false
}

// dm_name is the canonical channel name for a direct message between two
// nicknames: both sides compute the same string, so neither has to be told.
dm_name :: proc(a, b: string, allocator := context.allocator) -> string {
	lo, hi := a, b
	if lo > hi {
		lo, hi = hi, lo
	}
	return strings.concatenate({lo, "+", hi}, allocator)
}

dm_other :: proc(name, me: string) -> string {
	plus := strings.index_byte(name, '+')
	if plus < 0 {
		return name
	}
	a, b := name[:plus], name[plus + 1:]
	return a == me ? b : a
}

dm_has :: proc(name, nick: string) -> bool {
	plus := strings.index_byte(name, '+')
	if plus < 0 {
		return false
	}
	return name[:plus] == nick || name[plus + 1:] == nick
}

now_unix :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

// send_frame writes one whole frame. The header and the body go out in a
// single `send`, so two threads writing to the same socket can never splice a
// header onto the wrong body. Returns false once the peer is gone, which is
// the caller's cue to reap the connection rather than retry.
send_frame :: proc(sock: net.TCP_Socket, payload: string) -> bool {
	n := len(payload)
	if n > MAX_FRAME {
		return false
	}
	buf := make([]u8, 4 + n, context.temp_allocator)
	buf[0] = u8(u32(n) >> 24)
	buf[1] = u8(u32(n) >> 16)
	buf[2] = u8(u32(n) >> 8)
	buf[3] = u8(u32(n))
	copy(buf[4:], payload)
	sent, err := net.send_tcp(sock, buf)
	return err == nil && sent == len(buf)
}

// Reader accumulates bytes off a socket and hands back whole frames. TCP has
// no message boundaries, so this is the only place that knows where one
// message ends.
Reader :: struct {
	buf: [dynamic]u8,
	bad: bool, // a length header past MAX_FRAME: the stream is unusable
}

reader_feed :: proc(r: ^Reader, data: []u8) {
	append(&r.buf, ..data)
}

// reader_next pops the next complete payload, cloned into `allocator` so the
// caller may hold it after the buffer shifts.
reader_next :: proc(r: ^Reader, allocator := context.temp_allocator) -> (payload: string, ok: bool) {
	if r.bad || len(r.buf) < 4 {
		return "", false
	}
	n := int(r.buf[0]) << 24 | int(r.buf[1]) << 16 | int(r.buf[2]) << 8 | int(r.buf[3])
	if n < 0 || n > MAX_FRAME {
		r.bad = true
		return "", false
	}
	if len(r.buf) < 4 + n {
		return "", false
	}
	payload = strings.clone(string(r.buf[4:4 + n]), allocator)
	remove_range(&r.buf, 0, 4 + n)
	return payload, true
}

// ---------------------------------------------------------------------------
// JSON out
//
// Hand-rolled rather than `json.marshal`, because the messages are flat and
// polymorphic: a struct per message type would be more code than this, and
// `marshal` cannot express "this field is already-encoded JSON".
// ---------------------------------------------------------------------------

Enc :: struct {
	b: strings.Builder,
	n: int,
}

enc_open :: proc(e: ^Enc, allocator := context.temp_allocator) {
	e.b = strings.builder_make(allocator)
	e.n = 0
	strings.write_byte(&e.b, '{')
}

// enc_begin opens an object already carrying its type tag.
enc_begin :: proc(e: ^Enc, t: string, allocator := context.temp_allocator) {
	enc_open(e, allocator)
	kv_str(e, "t", t)
}

@(private)
comma :: proc(e: ^Enc) {
	if e.n > 0 {
		strings.write_byte(&e.b, ',')
	}
	e.n += 1
}

@(private)
key_out :: proc(e: ^Enc, k: string) {
	comma(e)
	write_json_string(&e.b, k)
	strings.write_byte(&e.b, ':')
}

kv_str :: proc(e: ^Enc, k, v: string) {
	key_out(e, k)
	write_json_string(&e.b, v)
}

kv_int :: proc(e: ^Enc, k: string, v: i64) {
	key_out(e, k)
	fmt.sbprintf(&e.b, "%d", v)
}

kv_bool :: proc(e: ^Enc, k: string, v: bool) {
	key_out(e, k)
	strings.write_string(&e.b, v ? "true" : "false")
}

// kv_raw splices in an already-encoded value: an array of objects, usually.
kv_raw :: proc(e: ^Enc, k: string, raw: string) {
	key_out(e, k)
	strings.write_string(&e.b, raw)
}

enc_done :: proc(e: ^Enc) -> string {
	strings.write_byte(&e.b, '}')
	return strings.to_string(e.b)
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// msg_json encodes one message as a bare object, for embedding in `message`,
// `history` and `results`, and for the on-disk log.
msg_json :: proc(m: Msg, allocator := context.temp_allocator) -> string {
	e: Enc
	enc_open(&e, allocator)
	kv_int(&e, "id", m.id)
	kv_str(&e, "ch", m.ch)
	kv_str(&e, "nick", m.nick)
	kv_str(&e, "text", m.text)
	kv_int(&e, "ts", m.ts)
	if m.edited != 0 {
		kv_int(&e, "edited", m.edited)
	}
	if m.deleted {
		kv_bool(&e, "deleted", true)
	}
	if m.reply_to != 0 {
		kv_int(&e, "reply_to", m.reply_to)
	}
	if len(m.reacts) > 0 {
		rb := strings.builder_make(allocator)
		strings.write_byte(&rb, '[')
		first := true
		for r in m.reacts {
			if len(r.nicks) == 0 {
				continue
			}
			if !first {
				strings.write_byte(&rb, ',')
			}
			first = false
			strings.write_string(&rb, "{\"key\":")
			write_json_string(&rb, r.key)
			strings.write_string(&rb, ",\"nicks\":[")
			for n, i in r.nicks {
				if i > 0 {
					strings.write_byte(&rb, ',')
				}
				write_json_string(&rb, n)
			}
			strings.write_string(&rb, "]}")
		}
		strings.write_byte(&rb, ']')
		kv_raw(&e, "reacts", strings.to_string(rb))
	}
	return enc_done(&e)
}

// ---------------------------------------------------------------------------
// JSON in
// ---------------------------------------------------------------------------

// parse_obj parses a frame payload. The returned object owns its strings in
// `allocator`; the caller clones whatever it keeps.
parse_obj :: proc(
	payload: string,
	allocator := context.temp_allocator,
) -> (
	obj: json.Object,
	ok: bool,
) {
	v, err := json.parse(transmute([]u8)payload, .JSON, true, allocator)
	if err != .None && err != .EOF {
		return nil, false
	}
	o, is_obj := v.(json.Object)
	if !is_obj {
		return nil, false
	}
	return o, true
}

ostr :: proc(o: json.Object, key: string, def := "") -> string {
	if v, found := o[key]; found {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return def
}

oint :: proc(o: json.Object, key: string, def: i64 = 0) -> i64 {
	if v, found := o[key]; found {
		#partial switch x in v {
		case json.Integer:
			return i64(x)
		case json.Float:
			return i64(x)
		}
	}
	return def
}

obool :: proc(o: json.Object, key: string, def := false) -> bool {
	if v, found := o[key]; found {
		if b, is := v.(json.Boolean); is {
			return bool(b)
		}
	}
	return def
}

oarr :: proc(o: json.Object, key: string) -> json.Array {
	if v, found := o[key]; found {
		if a, is := v.(json.Array); is {
			return a
		}
	}
	return nil
}

as_obj :: proc(v: json.Value) -> (json.Object, bool) {
	o, ok := v.(json.Object)
	return o, ok
}

as_str :: proc(v: json.Value) -> string {
	if s, ok := v.(json.String); ok {
		return string(s)
	}
	return ""
}

// msg_from decodes a message object, cloning every string into `allocator`.
msg_from :: proc(o: json.Object, allocator := context.allocator) -> Msg {
	m := Msg {
		id       = oint(o, "id"),
		ch       = strings.clone(ostr(o, "ch"), allocator),
		nick     = strings.clone(ostr(o, "nick"), allocator),
		text     = strings.clone(ostr(o, "text"), allocator),
		ts       = oint(o, "ts"),
		edited   = oint(o, "edited"),
		deleted  = obool(o, "deleted"),
		reply_to = oint(o, "reply_to"),
	}
	m.reacts = make([dynamic]React, allocator)
	for rv in oarr(o, "reacts") {
		ro, ok := as_obj(rv)
		if !ok {
			continue
		}
		r := React {
			key   = strings.clone(ostr(ro, "key"), allocator),
			nicks = make([dynamic]string, allocator),
		}
		for nv in oarr(ro, "nicks") {
			append(&r.nicks, strings.clone(as_str(nv), allocator))
		}
		append(&m.reacts, r)
	}
	return m
}

// react_add / react_remove keep the reaction list canonical: one entry per
// key, no duplicate nicks, and empty entries dropped.
react_add :: proc(m: ^Msg, key, nick: string, allocator := context.allocator) -> bool {
	if m.reacts == nil {
		m.reacts = make([dynamic]React, allocator)
	}
	for &r in m.reacts {
		if r.key != key {
			continue
		}
		for n in r.nicks {
			if n == nick {
				return false
			}
		}
		append(&r.nicks, strings.clone(nick, allocator))
		return true
	}
	r := React {
		key   = strings.clone(key, allocator),
		nicks = make([dynamic]string, allocator),
	}
	append(&r.nicks, strings.clone(nick, allocator))
	append(&m.reacts, r)
	return true
}

react_remove :: proc(m: ^Msg, key, nick: string) -> bool {
	for &r, ri in m.reacts {
		if r.key != key {
			continue
		}
		for n, i in r.nicks {
			if n == nick {
				ordered_remove(&r.nicks, i)
				if len(r.nicks) == 0 {
					ordered_remove(&m.reacts, ri)
				}
				return true
			}
		}
		return false
	}
	return false
}

react_has :: proc(m: Msg, key, nick: string) -> bool {
	for r in m.reacts {
		if r.key != key {
			continue
		}
		for n in r.nicks {
			if n == nick {
				return true
			}
		}
	}
	return false
}
