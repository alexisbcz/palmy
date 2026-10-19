package pcp

// Call join tokens.
//
// The chat gateway decides who may join a call: it checks, as the caller's
// identity-scoped Postgres session, that the identity can post in the call's
// channel, records the participation, and then mints one of these. The SFU
// never talks to the database. It checks the MAC and the expiry and admits
// exactly the identity the token names, into exactly the call it names.
//
//	token   = b64url(payload) "." b64url(HMAC-SHA256(secret, b64url(payload)))
//	payload = {"v":1,"call":…,"ch":…,"id":…,"handle":…,"name":…,"color":…,
//	           "exp":<unix seconds>,"e2ee":true}
//
// The MAC is over the *encoded* payload, so verifying never depends on how a
// JSON encoder orders keys. Tokens are short-lived (TOKEN_TTL) because they
// are bearer credentials: one that leaks is useless a minute later. A joined
// participant's session in the SFU outlives its token; the token only opens
// the door.
//
// The secret is shared between the gateway and the SFU and nobody else. It
// is not the Supabase JWT key: the gateway cannot mint account tokens, and
// the SFU cannot read the database.

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

TOKEN_TTL :: 60 // seconds

Join :: struct {
	call:   string, // rtc_calls.id
	ch:     string, // rtc_channels.id
	id:     string, // identities.id of the participant
	handle: string,
	name:   string,
	color:  string,
	exp:    i64,
	e2ee:   bool,
}

// token_mint returns a token for `j`. `j.exp` is filled in when zero.
token_mint :: proc(secret: []u8, j: Join, allocator := context.allocator) -> string {
	jj := j
	if jj.exp == 0 {
		jj.exp = time.time_to_unix(time.now()) + TOKEN_TTL
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"v":1,"call":`)
	json_str(&b, jj.call)
	strings.write_string(&b, `,"ch":`)
	json_str(&b, jj.ch)
	strings.write_string(&b, `,"id":`)
	json_str(&b, jj.id)
	strings.write_string(&b, `,"handle":`)
	json_str(&b, jj.handle)
	strings.write_string(&b, `,"name":`)
	json_str(&b, jj.name)
	strings.write_string(&b, `,"color":`)
	json_str(&b, jj.color)
	fmt.sbprintf(&b, `,"exp":%d,"e2ee":%s}`, jj.exp, jj.e2ee ? "true" : "false")

	body := b64url_encode(transmute([]u8)strings.to_string(b), context.temp_allocator)
	mac: [32]u8
	hmac.sum(.SHA256, mac[:], transmute([]u8)body, secret)
	return strings.concatenate({body, ".", b64url_encode(mac[:], context.temp_allocator)}, allocator)
}

Token_Error :: enum {
	None,
	Malformed,
	Bad_Mac,
	Expired,
}

// token_verify checks the MAC in constant time, then the expiry against
// `now` (unix seconds; 0 means the clock), then decodes. Strings in the
// returned Join are allocated with `allocator`.
token_verify :: proc(
	secret: []u8,
	token: string,
	now: i64 = 0,
	allocator := context.allocator,
) -> (
	j: Join,
	err: Token_Error,
) {
	dot := strings.last_index_byte(token, '.')
	if dot <= 0 || dot == len(token) - 1 || len(token) > 4096 {
		return {}, .Malformed
	}
	body, mac_s := token[:dot], token[dot + 1:]
	mac, ok := b64url_decode(mac_s, context.temp_allocator)
	if !ok || len(mac) != 32 {
		return {}, .Malformed
	}
	want: [32]u8
	hmac.sum(.SHA256, want[:], transmute([]u8)body, secret)
	if crypto.compare_constant_time(want[:], mac) != 1 {
		return {}, .Bad_Mac
	}
	raw, ok2 := b64url_decode(body, context.temp_allocator)
	if !ok2 {
		return {}, .Malformed
	}
	v, perr := json.parse(raw, allocator = context.temp_allocator)
	if perr != nil {
		return {}, .Malformed
	}
	o, is_obj := v.(json.Object)
	if !is_obj {
		return {}, .Malformed
	}
	get :: proc(o: json.Object, k: string, allocator: rawptr) -> string {
		if s, ok := o[k].(json.String); ok {
			return string(s)
		}
		return ""
	}
	j.call = strings.clone(get(o, "call", nil), allocator)
	j.ch = strings.clone(get(o, "ch", nil), allocator)
	j.id = strings.clone(get(o, "id", nil), allocator)
	j.handle = strings.clone(get(o, "handle", nil), allocator)
	j.name = strings.clone(get(o, "name", nil), allocator)
	j.color = strings.clone(get(o, "color", nil), allocator)
	#partial switch e in o["exp"] {
	case json.Integer:
		j.exp = i64(e)
	case json.Float:
		j.exp = i64(e)
	}
	if b, is_b := o["e2ee"].(json.Boolean); is_b {
		j.e2ee = bool(b)
	}
	if j.call == "" || j.id == "" || j.exp == 0 {
		return {}, .Malformed
	}
	t := now != 0 ? now : time.time_to_unix(time.now())
	if t > j.exp {
		return j, .Expired
	}
	return j, .None
}

// token_peek decodes a token's claims *without* checking the MAC. A client
// uses it to read its own token (its call id and display name); nothing that
// grants access may ever call it.
token_peek :: proc(token: string, allocator := context.allocator) -> (j: Join, ok: bool) {
	dot := strings.last_index_byte(token, '.')
	if dot <= 0 {
		return {}, false
	}
	raw, ok2 := b64url_decode(token[:dot], context.temp_allocator)
	if !ok2 {
		return {}, false
	}
	v, perr := json.parse(raw, allocator = context.temp_allocator)
	if perr != nil {
		return {}, false
	}
	o, is_obj := v.(json.Object)
	if !is_obj {
		return {}, false
	}
	get :: proc(o: json.Object, k: string) -> string {
		if s, ok := o[k].(json.String); ok {
			return string(s)
		}
		return ""
	}
	j.call = strings.clone(get(o, "call"), allocator)
	j.ch = strings.clone(get(o, "ch"), allocator)
	j.id = strings.clone(get(o, "id"), allocator)
	j.handle = strings.clone(get(o, "handle"), allocator)
	j.name = strings.clone(get(o, "name"), allocator)
	j.color = strings.clone(get(o, "color"), allocator)
	if b, is_b := o["e2ee"].(json.Boolean); is_b {
		j.e2ee = bool(b)
	}
	return j, j.call != ""
}

// sfu_hello_mac authenticates the SFU's control link to the gateway:
// hex(HMAC-SHA256(secret, "sfu-hello:" + ts)). The gateway refuses a ts more
// than 30 s away from its own clock.
sfu_hello_mac :: proc(secret: []u8, ts: i64, allocator := context.temp_allocator) -> string {
	msg := fmt.tprintf("sfu-hello:%d", ts)
	mac: [32]u8
	hmac.sum(.SHA256, mac[:], transmute([]u8)msg, secret)
	b := strings.builder_make(allocator)
	for x in mac {
		fmt.sbprintf(&b, "%02x", x)
	}
	return strings.to_string(b)
}

_ :: hash.Algorithm

// ---------------------------------------------------------------------------
// base64url without padding, as JWTs use it.
// ---------------------------------------------------------------------------

B64URL := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

b64url_encode :: proc(data: []u8, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for ; i + 3 <= len(data); i += 3 {
		n := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		strings.write_byte(&b, B64URL[n >> 18 & 63])
		strings.write_byte(&b, B64URL[n >> 12 & 63])
		strings.write_byte(&b, B64URL[n >> 6 & 63])
		strings.write_byte(&b, B64URL[n & 63])
	}
	switch len(data) - i {
	case 1:
		n := u32(data[i]) << 16
		strings.write_byte(&b, B64URL[n >> 18 & 63])
		strings.write_byte(&b, B64URL[n >> 12 & 63])
	case 2:
		n := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		strings.write_byte(&b, B64URL[n >> 18 & 63])
		strings.write_byte(&b, B64URL[n >> 12 & 63])
		strings.write_byte(&b, B64URL[n >> 6 & 63])
	}
	return strings.to_string(b)
}

// b64url_decode accepts the URL alphabet, and the standard one too, with or
// without padding.
b64url_decode :: proc(s: string, allocator := context.allocator) -> (out: []u8, ok: bool) {
	val :: proc(c: u8) -> int {
		switch c {
		case 'A' ..= 'Z':
			return int(c - 'A')
		case 'a' ..= 'z':
			return int(c - 'a') + 26
		case '0' ..= '9':
			return int(c - '0') + 52
		case '-', '+':
			return 62
		case '_', '/':
			return 63
		}
		return -1
	}
	t := strings.trim_right(s, "=")
	if len(t) % 4 == 1 {
		return nil, false
	}
	buf := make([dynamic]u8, 0, len(t) * 3 / 4 + 3, allocator)
	acc, bits := u32(0), 0
	for i in 0 ..< len(t) {
		v := val(t[i])
		if v < 0 {
			delete(buf)
			return nil, false
		}
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&buf, u8(acc >> u32(bits)))
		}
	}
	return buf[:], true
}

json_str :: proc(b: ^strings.Builder, s: string) {
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
