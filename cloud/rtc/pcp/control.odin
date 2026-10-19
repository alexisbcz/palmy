package pcp

// PCP2 control messages.
//
// A control datagram is a PCP2 header with ptype Control, nfrag 1, and a
// payload of one kind byte followed by a small JSON object. JSON because
// control is a few messages a second and has to be readable on the wire
// (`tcpdump -X` shows what went wrong) and extensible without a version bump;
// media, which is thousands of datagrams a second, is binary.
//
// Every control message fits one datagram (1200 bytes). That is why the
// roster is not one message: each participant is described by its own PEER
// message, and ROSTER only lists which sources are current.
//
//	kind        dir    body
//	JOIN        c→s    {"token":…,"pub":<b64 X25519 public key>}
//	WELCOME     s→c    {"src":n,"call":…,"ch":…,"e2ee":bool,"gen":n}
//	PEER        s→c    {"src":n,"id":…,"handle":…,"name":…,"color":…,"pub":…,"muted":b,"cam_off":b}
//	ROSTER      s→c    {"gen":n,"srcs":[n,…],"speaker":n}
//	STATE       c→s    {"muted":b,"cam_off":b}           keepalive, every 500 ms
//	LEAVE       c→s    {}
//	KEYFRAME    c→s    {"src":n,"layer":n}            "I need a keyframe of src"
//	            s→c    {"layer":n}                    "send one of your layer n"
//	FEEDBACK    c→s    {"loss":pct,"kbps":n,"cap":n}  receiver report, every 500 ms
//	KEY         c→s    {"to":n,"kid":n,"sealed":b64}  a sealed SFrame base key
//	            s→c    {"from":n,"kid":n,"sealed":…}  the SFU stamps "from"
//	SPEAKER     s→c    {"src":n}
//	TIER        s→c    {"tier":"high"|"low"|"audio","est":kbps}
//	ERROR       s→c    {"code":…,"msg":…}             refused join, or kicked

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Kind :: enum u8 {
	Invalid  = 0,
	Join     = 1,
	Welcome  = 2,
	Peer     = 3,
	Roster   = 4,
	State    = 5,
	Leave    = 6,
	Keyframe = 7,
	Feedback = 8,
	Key      = 9,
	Speaker  = 10,
	Tier     = 11,
	Error    = 12,
}

// control_into writes a whole control datagram into `out`. `body` is a JSON
// object text. Returns nil when it does not fit.
control_into :: proc(out: []u8, kind: Kind, body: string, seq: u16, ts_us: u64) -> []u8 {
	n := HDR + 1 + len(body)
	if n > MAX_PACKET || n > len(out) {
		return nil
	}
	write_header(out, Header{ptype = .Control, flags = FLAG_MARKER, seq = seq, ts_us = ts_us, nfrag = 1})
	out[HDR] = u8(kind)
	copy(out[HDR + 1:], body)
	return out[:n]
}

// control_parse splits a control payload into its kind and JSON object.
// Objects are allocated in `allocator`, which is normally the temp allocator.
control_parse :: proc(payload: []u8, allocator := context.temp_allocator) -> (kind: Kind, o: json.Object, ok: bool) {
	if len(payload) < 1 || payload[0] == 0 || payload[0] > u8(Kind.Error) {
		return
	}
	kind = Kind(payload[0])
	body := payload[1:]
	if len(body) == 0 {
		return kind, nil, true
	}
	v, err := json.parse(body, allocator = allocator)
	if err != nil {
		return
	}
	obj, is := v.(json.Object)
	if !is {
		return
	}
	return kind, obj, true
}

// Tiny accessors, tolerant of missing keys and of numbers arriving as floats.

ostr :: proc(o: json.Object, k: string) -> string {
	if o == nil {
		return ""
	}
	if s, ok := o[k].(json.String); ok {
		return string(s)
	}
	return ""
}

oint :: proc(o: json.Object, k: string, def: i64 = 0) -> i64 {
	if o == nil {
		return def
	}
	#partial switch v in o[k] {
	case json.Integer:
		return i64(v)
	case json.Float:
		return i64(v)
	}
	return def
}

ofloat :: proc(o: json.Object, k: string, def: f64 = 0) -> f64 {
	if o == nil {
		return def
	}
	#partial switch v in o[k] {
	case json.Integer:
		return f64(v)
	case json.Float:
		return f64(v)
	}
	return def
}

obool :: proc(o: json.Object, k: string) -> bool {
	if o == nil {
		return false
	}
	if b, ok := o[k].(json.Boolean); ok {
		return bool(b)
	}
	return false
}

oarr :: proc(o: json.Object, k: string) -> json.Array {
	if o == nil {
		return nil
	}
	if a, ok := o[k].(json.Array); ok {
		return a
	}
	return nil
}

// A JSON object writer for control bodies, in the temp allocator.
Obj :: struct {
	b:     strings.Builder,
	first: bool,
}

obj_begin :: proc(o: ^Obj) {
	o.b = strings.builder_make(context.temp_allocator)
	o.first = true
	strings.write_byte(&o.b, '{')
}

@(private)
obj_key :: proc(o: ^Obj, k: string) {
	if !o.first {
		strings.write_byte(&o.b, ',')
	}
	o.first = false
	json_str(&o.b, k)
	strings.write_byte(&o.b, ':')
}

obj_str :: proc(o: ^Obj, k, v: string) {
	obj_key(o, k)
	json_str(&o.b, v)
}

obj_int :: proc(o: ^Obj, k: string, v: i64) {
	obj_key(o, k)
	fmt.sbprintf(&o.b, "%d", v)
}

obj_f :: proc(o: ^Obj, k: string, v: f64) {
	obj_key(o, k)
	fmt.sbprintf(&o.b, "%.2f", v)
}

obj_bool :: proc(o: ^Obj, k: string, v: bool) {
	obj_key(o, k)
	strings.write_string(&o.b, v ? "true" : "false")
}

obj_raw :: proc(o: ^Obj, k, raw: string) {
	obj_key(o, k)
	strings.write_string(&o.b, raw)
}

obj_end :: proc(o: ^Obj) -> string {
	strings.write_byte(&o.b, '}')
	return strings.to_string(o.b)
}
