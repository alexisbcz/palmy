package wire

// The collaboration protocol, over one WebSocket per open document window.
//
// Control messages are JSON text frames, each with a field "t". Document
// data travels as binary frames whose first byte is the type:
//
//	client -> server
//	  {"t":"hello","doc":uuid,"as":identity-uuid,"token":jwt,"agent":hex,
//	   "since":seq,"link":token?,"client":"docs"}      first message, always
//	  {"t":"token","token":jwt}                         a refreshed access token
//	  {"t":"aware","state":{...}}                       cursor, selection, typing
//	  0x01 varint ref  update                           a local update
//
//	server -> client
//	  {"t":"welcome","role":r,"identity":{...},"peer":n,"head":seq,
//	   "doc":{...},"peers":[{peer,identity,name,color,state}...]}
//	  0x03 varint seq  snapshot                         state at `seq` (catch-up)
//	  0x02 varint seq  update                           an update, in log order
//	  {"t":"synced","head":seq}                         catch-up finished
//	  0x04 varint ref  varint seq                       your update `ref` is `seq`
//	  0x05 varint ref  reason                           your update was refused
//	  {"t":"aware","peer":n,"identity":{...},"state":{...}}
//	  {"t":"leave","peer":n}
//	  {"t":"role","role":r}                             your role changed
//	  {"t":"error","code":c,"message":m}                then the server closes
//
// Ordering: the server numbers updates (the per-document `seq` in
// collab_updates) and every client receives every update in that order, its
// own included as an ack. A client that reconnects says `since` — the last
// seq it applied — and receives only what follows, or a snapshot when that is
// shorter; it then resends whatever it sent that was never acknowledged.
// Applying an update twice is harmless (the CRDT ignores duplicates), so the
// resend needs no bookkeeping beyond "not yet acked".

MSG_UPDATE_UP :: u8(0x01)
MSG_UPDATE_DOWN :: u8(0x02)
MSG_SNAPSHOT :: u8(0x03)
MSG_ACK :: u8(0x04)
MSG_NACK :: u8(0x05)

Identity_Info :: struct {
	id:           string `json:"id"`,
	handle:       string `json:"handle"`,
	display_name: string `json:"display_name"`,
	color:        string `json:"color"`,
	kind:         string `json:"kind"`,
}

Hello :: struct {
	t:      string `json:"t"`,
	doc:    string `json:"doc"`,
	as:     string `json:"as"`,
	token:  string `json:"token"`,
	agent:  string `json:"agent"`,
	since:  u64 `json:"since"`,
	link:   string `json:"link"`,
	client: string `json:"client"`,
}

put_uv :: proc(b: ^[dynamic]u8, v: u64) {
	x := v
	for x >= 0x80 {
		append(b, u8(x) | 0x80)
		x >>= 7
	}
	append(b, u8(x))
}

get_uv :: proc(data: []u8, i: ^int) -> (v: u64, ok: bool) {
	shift: uint = 0
	for {
		if i^ >= len(data) || shift > 63 {
			return 0, false
		}
		c := data[i^]
		i^ += 1
		v |= u64(c & 0x7f) << shift
		if c < 0x80 {
			return v, true
		}
		shift += 7
	}
}

// frame builds a binary message: type byte, varints, then a payload.
frame :: proc(kind: u8, nums: []u64, payload: []u8, allocator := context.temp_allocator) -> []u8 {
	b := make([dynamic]u8, 0, 1 + 10 * len(nums) + len(payload), allocator)
	append(&b, kind)
	for n in nums {
		put_uv(&b, n)
	}
	append(&b, ..payload)
	return b[:]
}

// unframe splits a binary message into its type, `n` leading varints and the
// rest.
unframe :: proc(data: []u8, n: int) -> (kind: u8, nums: [4]u64, rest: []u8, ok: bool) {
	if len(data) < 1 || n > 4 {
		return
	}
	kind = data[0]
	i := 1
	for k in 0 ..< n {
		v, good := get_uv(data, &i)
		if !good {
			return
		}
		nums[k] = v
	}
	return kind, nums, data[i:], true
}

// json_quote writes `s` as a JSON string literal.
json_quote :: proc(b: ^[dynamic]u8, s: string) {
	append(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			append(b, '\\', '"')
		case '\\':
			append(b, '\\', '\\')
		case '\n':
			append(b, '\\', 'n')
		case '\r':
			append(b, '\\', 'r')
		case '\t':
			append(b, '\\', 't')
		case:
			if c < 0x20 {
				hex := "0123456789abcdef"
				append(b, '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15])
			} else {
				append(b, c)
			}
		}
	}
	append(b, '"')
}
