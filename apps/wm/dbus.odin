// A D-Bus client, hand-rolled onto a unix socket.
//
// The compositor needs logind, and logind only speaks D-Bus, so this is the
// second protocol in the tree that is spoken directly rather than through a C
// library. It is the same shape as wire.odin: a socket, a byte buffer, and
// descriptors riding in SCM_RIGHTS control messages. Only what logind uses is
// implemented -- the EXTERNAL SASL handshake, the header-field table, the
// alignment rules, the type-signature system, method calls with replies, and
// match rules for signals -- but within that, it is complete and symmetric:
// anything this file can marshal it can also unmarshal.
//
// Descriptor passing is not optional here. Session.TakeDevice answers with an
// 'h', which is an index into the control message, so NEGOTIATE_UNIX_FD has to
// succeed before anything useful can happen.
package wm

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

DBUS_MSG_CALL :: u8(1)
DBUS_MSG_RETURN :: u8(2)
DBUS_MSG_ERROR :: u8(3)
DBUS_MSG_SIGNAL :: u8(4)

DBUS_FLAG_NO_REPLY :: u8(0x01)
DBUS_FLAG_NO_AUTOSTART :: u8(0x02)

DBUS_FIELD_PATH :: u8(1)
DBUS_FIELD_INTERFACE :: u8(2)
DBUS_FIELD_MEMBER :: u8(3)
DBUS_FIELD_ERROR_NAME :: u8(4)
DBUS_FIELD_REPLY_SERIAL :: u8(5)
DBUS_FIELD_DESTINATION :: u8(6)
DBUS_FIELD_SENDER :: u8(7)
DBUS_FIELD_SIGNATURE :: u8(8)
DBUS_FIELD_UNIX_FDS :: u8(9)

DBUS_MAX_MESSAGE :: 16 * 1024 * 1024
DBUS_MAX_QUEUE :: 256

DBUS_SOL_SOCKET :: 1
DBUS_SCM_RIGHTS :: 1

Dbus_Error :: enum u8 {
	None,
	No_Address,
	Connect,
	Auth,
	No_Fd_Passing,
	Io,
	Protocol,
	Timeout,
	Call_Failed, // the peer answered with an error message
	Not_Ready,
	Gated, // refused locally: PALMY_WM_SEAT_LIVE is not set
	Not_Found,
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

// Dbus_Value is one marshalled value of any type. It is flat rather than a
// recursive union so that containers can be built and walked without a pile of
// pointer types; `items` carries the children of an array, struct, dict entry
// or variant.
Dbus_Value :: struct {
	kind:  u8, // the signature type code this value was read as
	sig:   string, // element signature (arrays) or contained signature (variants)
	num:   u64, // y n q b i u x t h -- integers, booleans, fd index
	f:     f64, // d
	str:   string, // s o g
	fd:    linux.Fd, // h, resolved against the message's descriptor table
	items: []Dbus_Value,
}

dbus_y :: proc(v: u8) -> Dbus_Value {return {kind = 'y', num = u64(v)}}
dbus_b :: proc(v: bool) -> Dbus_Value {return {kind = 'b', num = v ? 1 : 0}}
dbus_n :: proc(v: i16) -> Dbus_Value {return {kind = 'n', num = u64(u16(v))}}
dbus_q :: proc(v: u16) -> Dbus_Value {return {kind = 'q', num = u64(v)}}
dbus_i :: proc(v: i32) -> Dbus_Value {return {kind = 'i', num = u64(u32(v))}}
dbus_u :: proc(v: u32) -> Dbus_Value {return {kind = 'u', num = u64(v)}}
dbus_x :: proc(v: i64) -> Dbus_Value {return {kind = 'x', num = u64(v)}}
dbus_t :: proc(v: u64) -> Dbus_Value {return {kind = 't', num = v}}
dbus_d :: proc(v: f64) -> Dbus_Value {return {kind = 'd', f = v}}
dbus_s :: proc(v: string) -> Dbus_Value {return {kind = 's', str = v}}
dbus_o :: proc(v: string) -> Dbus_Value {return {kind = 'o', str = v}}
dbus_g :: proc(v: string) -> Dbus_Value {return {kind = 'g', str = v}}
dbus_h :: proc(v: linux.Fd) -> Dbus_Value {return {kind = 'h', fd = v}}

dbus_array :: proc(elem_sig: string, items: ..Dbus_Value) -> Dbus_Value {
	return {kind = 'a', sig = elem_sig, items = slice_of(items)}
}

dbus_struct :: proc(items: ..Dbus_Value) -> Dbus_Value {
	return {kind = '(', items = slice_of(items)}
}

dbus_entry :: proc(k, v: Dbus_Value) -> Dbus_Value {
	pair := make([]Dbus_Value, 2)
	pair[0] = k
	pair[1] = v
	return {kind = '{', items = pair}
}

dbus_variant :: proc(sig: string, v: Dbus_Value) -> Dbus_Value {
	one := make([]Dbus_Value, 1)
	one[0] = v
	return {kind = 'v', sig = sig, items = one}
}

@(private = "file")
slice_of :: proc(items: []Dbus_Value) -> []Dbus_Value {
	out := make([]Dbus_Value, len(items))
	copy(out, items)
	return out
}

dbus_as_bool :: proc(v: Dbus_Value) -> bool {return v.num != 0}
dbus_as_u32 :: proc(v: Dbus_Value) -> u32 {return u32(v.num)}
dbus_as_i32 :: proc(v: Dbus_Value) -> i32 {return i32(u32(v.num))}
dbus_as_u64 :: proc(v: Dbus_Value) -> u64 {return v.num}
dbus_as_str :: proc(v: Dbus_Value) -> string {return v.str}

// dbus_inner unwraps a variant. Non-variants are returned unchanged, so it is
// safe to call on a value whose wrapping is not known.
dbus_inner :: proc(v: Dbus_Value) -> Dbus_Value {
	if v.kind == 'v' && len(v.items) == 1 {
		return v.items[0]
	}
	return v
}

// dbus_dict_get looks a key up in an unmarshalled a{sv} (or any a{s?}).
dbus_dict_get :: proc(dict: Dbus_Value, key: string) -> (Dbus_Value, bool) {
	if dict.kind != 'a' {
		return {}, false
	}
	for e in dict.items {
		if e.kind == '{' && len(e.items) == 2 && e.items[0].str == key {
			return dbus_inner(e.items[1]), true
		}
	}
	return {}, false
}

dbus_free_values :: proc(vs: []Dbus_Value) {
	for v in vs {
		if len(v.items) > 0 {
			dbus_free_values(v.items)
		}
	}
	if vs != nil {
		delete(vs)
	}
}

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

dbus_align_of :: proc(c: u8) -> int {
	switch c {
	case 'y', 'g', 'v':
		return 1
	case 'n', 'q':
		return 2
	case 'b', 'i', 'u', 'h', 's', 'o', 'a':
		return 4
	case 'x', 't', 'd', '(', ')', '{', '}':
		return 8
	}
	return 1
}

// dbus_sig_next returns the single complete type starting at `i`, and the
// index just past it. "a{sv}s" at 0 gives "a{sv}"; at 5 it gives "s".
dbus_sig_next :: proc(sig: string, i: int) -> (ct: string, next: int, ok: bool) {
	if i < 0 || i >= len(sig) {
		return "", i, false
	}
	j := i
	for j < len(sig) && sig[j] == 'a' {
		j += 1
	}
	if j >= len(sig) {
		return "", i, false
	}
	if sig[j] == '(' || sig[j] == '{' {
		depth := 0
		for j < len(sig) {
			c := sig[j]
			if c == '(' || c == '{' {
				depth += 1
			} else if c == ')' || c == '}' {
				depth -= 1
				if depth == 0 {
					j += 1
					return sig[i:j], j, true
				}
			}
			j += 1
		}
		return "", i, false // unbalanced
	}
	j += 1
	return sig[i:j], j, true
}

// dbus_sig_count returns how many complete types a signature holds, or -1 if
// it does not parse.
dbus_sig_count :: proc(sig: string) -> int {
	n, i := 0, 0
	for i < len(sig) {
		_, next, ok := dbus_sig_next(sig, i)
		if !ok {
			return -1
		}
		i = next
		n += 1
	}
	return n
}

// ---------------------------------------------------------------------------
// Marshalling
// ---------------------------------------------------------------------------

Dbus_Writer :: struct {
	b:   [dynamic]u8,
	fds: [dynamic]linux.Fd,
}

dbus_writer_destroy :: proc(w: ^Dbus_Writer) {
	delete(w.b)
	delete(w.fds)
}

// Alignment is relative to the start of the message. Every buffer this writer
// is used for begins at an eight-byte boundary within the message (the header
// field array at offset 16, the body after the padded header), so counting
// from zero here gives the same answer.
dbus_w_pad :: proc(w: ^Dbus_Writer, a: int) {
	for len(w.b) % a != 0 {
		append(&w.b, 0)
	}
}

dbus_w_u8 :: proc(w: ^Dbus_Writer, v: u8) {
	append(&w.b, v)
}

dbus_w_u16 :: proc(w: ^Dbus_Writer, v: u16) {
	dbus_w_pad(w, 2)
	b := transmute([2]u8)v
	append(&w.b, ..b[:])
}

dbus_w_u32 :: proc(w: ^Dbus_Writer, v: u32) {
	dbus_w_pad(w, 4)
	b := transmute([4]u8)v
	append(&w.b, ..b[:])
}

dbus_w_u64 :: proc(w: ^Dbus_Writer, v: u64) {
	dbus_w_pad(w, 8)
	b := transmute([8]u8)v
	append(&w.b, ..b[:])
}

dbus_w_f64 :: proc(w: ^Dbus_Writer, v: f64) {
	dbus_w_pad(w, 8)
	b := transmute([8]u8)v
	append(&w.b, ..b[:])
}

// s and o: a u32 length, the bytes, a NUL that the length does not count.
dbus_w_str :: proc(w: ^Dbus_Writer, s: string) {
	dbus_w_u32(w, u32(len(s)))
	append(&w.b, s)
	append(&w.b, 0)
}

// g: the same, but the length is a single byte.
dbus_w_sig :: proc(w: ^Dbus_Writer, s: string) {
	dbus_w_u8(w, u8(len(s)))
	append(&w.b, s)
	append(&w.b, 0)
}

dbus_marshal :: proc(w: ^Dbus_Writer, sig: string, v: Dbus_Value) -> bool {
	if len(sig) == 0 {
		return false
	}
	switch sig[0] {
	case 'y':
		dbus_w_u8(w, u8(v.num))
	case 'b':
		dbus_w_u32(w, v.num != 0 ? 1 : 0)
	case 'n', 'q':
		dbus_w_u16(w, u16(v.num))
	case 'i', 'u':
		dbus_w_u32(w, u32(v.num))
	case 'x', 't':
		dbus_w_u64(w, v.num)
	case 'd':
		dbus_w_f64(w, v.f)
	case 'h':
		// The value on the wire is an index into the control message; the
		// descriptor itself travels out of band.
		idx := u32(len(w.fds))
		append(&w.fds, v.fd)
		dbus_w_u32(w, idx)
	case 's', 'o':
		dbus_w_str(w, v.str)
	case 'g':
		dbus_w_sig(w, v.str)
	case 'v':
		if len(v.items) != 1 || len(v.sig) == 0 {
			return false
		}
		dbus_w_sig(w, v.sig)
		return dbus_marshal(w, v.sig, v.items[0])
	case 'a':
		elem := sig[1:]
		if len(elem) == 0 {
			return false
		}
		dbus_w_u32(w, 0)
		lenpos := len(w.b) - 4
		// The padding to the element alignment is written even when the array
		// is empty, and is not counted in the length.
		dbus_w_pad(w, dbus_align_of(elem[0]))
		start := len(w.b)
		for it in v.items {
			if !dbus_marshal(w, elem, it) {
				return false
			}
		}
		n := u32(len(w.b) - start)
		nb := transmute([4]u8)n
		copy(w.b[lenpos:][:4], nb[:])
	case '(', '{':
		if len(sig) < 2 {
			return false
		}
		dbus_w_pad(w, 8)
		inner := sig[1:len(sig) - 1]
		i, k := 0, 0
		for i < len(inner) {
			ct, next, ok := dbus_sig_next(inner, i)
			if !ok || k >= len(v.items) {
				return false
			}
			if !dbus_marshal(w, ct, v.items[k]) {
				return false
			}
			i = next
			k += 1
		}
		if k != len(v.items) {
			return false
		}
	case:
		return false
	}
	return true
}

dbus_marshal_all :: proc(w: ^Dbus_Writer, sig: string, args: []Dbus_Value) -> bool {
	i, k := 0, 0
	for i < len(sig) {
		ct, next, ok := dbus_sig_next(sig, i)
		if !ok || k >= len(args) {
			return false
		}
		if !dbus_marshal(w, ct, args[k]) {
			return false
		}
		i = next
		k += 1
	}
	return k == len(args)
}

// ---------------------------------------------------------------------------
// Unmarshalling
// ---------------------------------------------------------------------------

Dbus_Reader :: struct {
	b:   []u8,
	p:   int,
	fds: []linux.Fd,
	be:  bool, // the sender used big-endian
	bad: bool,
}

@(private = "file")
swap16 :: proc(v: u16) -> u16 {return (v >> 8) | (v << 8)}

@(private = "file")
swap32 :: proc(v: u32) -> u32 {
	return(
		(v >> 24) |
		((v >> 8) & 0x0000ff00) |
		((v << 8) & 0x00ff0000) |
		(v << 24) \
	)
}

@(private = "file")
swap64 :: proc(v: u64) -> u64 {
	return u64(swap32(u32(v))) << 32 | u64(swap32(u32(v >> 32)))
}

dbus_r_pad :: proc(r: ^Dbus_Reader, a: int) {
	for r.p % a != 0 {
		if r.p >= len(r.b) {
			r.bad = true
			return
		}
		r.p += 1
	}
}

dbus_r_u8 :: proc(r: ^Dbus_Reader) -> u8 {
	if r.p + 1 > len(r.b) {
		r.bad = true
		return 0
	}
	v := r.b[r.p]
	r.p += 1
	return v
}

dbus_r_u16 :: proc(r: ^Dbus_Reader) -> u16 {
	dbus_r_pad(r, 2)
	if r.bad || r.p + 2 > len(r.b) {
		r.bad = true
		return 0
	}
	v := (^u16)(raw_data(r.b[r.p:]))^
	r.p += 2
	return r.be ? swap16(v) : v
}

dbus_r_u32 :: proc(r: ^Dbus_Reader) -> u32 {
	dbus_r_pad(r, 4)
	if r.bad || r.p + 4 > len(r.b) {
		r.bad = true
		return 0
	}
	v := (^u32)(raw_data(r.b[r.p:]))^
	r.p += 4
	return r.be ? swap32(v) : v
}

dbus_r_u64 :: proc(r: ^Dbus_Reader) -> u64 {
	dbus_r_pad(r, 8)
	if r.bad || r.p + 8 > len(r.b) {
		r.bad = true
		return 0
	}
	v := (^u64)(raw_data(r.b[r.p:]))^
	r.p += 8
	return r.be ? swap64(v) : v
}

dbus_r_f64 :: proc(r: ^Dbus_Reader) -> f64 {
	return transmute(f64)dbus_r_u64(r)
}

// The returned string is a view into the message buffer; it stops being valid
// when the message is freed, so anything kept has to be cloned.
dbus_r_str :: proc(r: ^Dbus_Reader) -> string {
	n := int(dbus_r_u32(r))
	if r.bad || n < 0 || r.p + n + 1 > len(r.b) {
		r.bad = true
		return ""
	}
	s := string(r.b[r.p:r.p + n])
	r.p += n + 1
	return s
}

dbus_r_sig :: proc(r: ^Dbus_Reader) -> string {
	n := int(dbus_r_u8(r))
	if r.bad || r.p + n + 1 > len(r.b) {
		r.bad = true
		return ""
	}
	s := string(r.b[r.p:r.p + n])
	r.p += n + 1
	return s
}

dbus_unmarshal :: proc(r: ^Dbus_Reader, sig: string) -> Dbus_Value {
	if len(sig) == 0 {
		r.bad = true
		return {}
	}
	v := Dbus_Value {
		kind = sig[0],
	}
	switch sig[0] {
	case 'y':
		v.num = u64(dbus_r_u8(r))
	case 'b':
		v.num = dbus_r_u32(r) != 0 ? 1 : 0
	case 'n', 'q':
		v.num = u64(dbus_r_u16(r))
	case 'i', 'u':
		v.num = u64(dbus_r_u32(r))
	case 'x', 't':
		v.num = dbus_r_u64(r)
	case 'd':
		v.f = dbus_r_f64(r)
	case 'h':
		idx := dbus_r_u32(r)
		v.num = u64(idx)
		v.fd = -1
		if int(idx) < len(r.fds) {
			v.fd = r.fds[idx]
		}
	case 's', 'o':
		v.str = dbus_r_str(r)
	case 'g':
		v.str = dbus_r_sig(r)
	case 'v':
		inner := dbus_r_sig(r)
		if r.bad || dbus_sig_count(inner) != 1 {
			r.bad = true
			return v
		}
		v.sig = inner
		one := make([]Dbus_Value, 1)
		one[0] = dbus_unmarshal(r, inner)
		v.items = one
	case 'a':
		elem := sig[1:]
		if len(elem) == 0 {
			r.bad = true
			return v
		}
		v.sig = elem
		n := int(dbus_r_u32(r))
		dbus_r_pad(r, dbus_align_of(elem[0]))
		if r.bad || n < 0 || r.p + n > len(r.b) {
			r.bad = true
			return v
		}
		end := r.p + n
		out: [dynamic]Dbus_Value
		for r.p < end && !r.bad {
			append(&out, dbus_unmarshal(r, elem))
		}
		if r.p != end {
			r.bad = true
		}
		v.items = out[:]
	case '(', '{':
		if len(sig) < 2 {
			r.bad = true
			return v
		}
		dbus_r_pad(r, 8)
		inner := sig[1:len(sig) - 1]
		out: [dynamic]Dbus_Value
		i := 0
		for i < len(inner) && !r.bad {
			ct, next, ok := dbus_sig_next(inner, i)
			if !ok {
				r.bad = true
				break
			}
			append(&out, dbus_unmarshal(r, ct))
			i = next
		}
		v.items = out[:]
	case:
		r.bad = true
	}
	return v
}

dbus_unmarshal_all :: proc(r: ^Dbus_Reader, sig: string) -> []Dbus_Value {
	out: [dynamic]Dbus_Value
	i := 0
	for i < len(sig) && !r.bad {
		ct, next, ok := dbus_sig_next(sig, i)
		if !ok {
			r.bad = true
			break
		}
		append(&out, dbus_unmarshal(r, ct))
		i = next
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

Dbus_Msg :: struct {
	type:         u8,
	flags:        u8,
	serial:       u32,
	reply_serial: u32,
	path:         string,
	iface:        string,
	member:       string,
	err_name:     string,
	dest:         string,
	sender:       string,
	signature:    string,
	fd_count:     u32,
	body:         []u8,
	fds:          []linux.Fd,
	args:         []Dbus_Value,
	raw:          []u8, // owns the storage the strings above point into
}

dbus_msg_free :: proc(m: ^Dbus_Msg) {
	if m == nil {
		return
	}
	dbus_free_values(m.args)
	if m.raw != nil {
		delete(m.raw)
	}
	if m.fds != nil {
		delete(m.fds)
	}
	free(m)
}

// dbus_msg_close_fds closes every descriptor the message carried. Callers that
// keep one must take it out of m.fds (or dup it) before calling this.
dbus_msg_close_fds :: proc(m: ^Dbus_Msg) {
	for fd in m.fds {
		if fd >= 0 {
			linux.close(fd)
		}
	}
}

@(private = "file")
Dbus_Field :: struct {
	code: u8,
	sig:  string,
	val:  Dbus_Value,
}

// dbus_encode lays out one complete message. The body is marshalled first
// because its descriptor count and signature both have to appear in the
// header.
dbus_encode :: proc(
	type: u8,
	flags: u8,
	serial: u32,
	path, iface, member, dest, err_name: string,
	reply_serial: u32,
	sig: string,
	args: []Dbus_Value,
) -> (
	out: []u8,
	fds: []linux.Fd,
	ok: bool,
) {
	bw: Dbus_Writer
	defer delete(bw.b)
	if !dbus_marshal_all(&bw, sig, args) {
		delete(bw.fds)
		return nil, nil, false
	}

	fields: [dynamic]Dbus_Field
	defer delete(fields)
	if path != "" {
		append(&fields, Dbus_Field{DBUS_FIELD_PATH, "o", dbus_o(path)})
	}
	if iface != "" {
		append(&fields, Dbus_Field{DBUS_FIELD_INTERFACE, "s", dbus_s(iface)})
	}
	if member != "" {
		append(&fields, Dbus_Field{DBUS_FIELD_MEMBER, "s", dbus_s(member)})
	}
	if err_name != "" {
		append(&fields, Dbus_Field{DBUS_FIELD_ERROR_NAME, "s", dbus_s(err_name)})
	}
	if reply_serial != 0 {
		append(&fields, Dbus_Field{DBUS_FIELD_REPLY_SERIAL, "u", dbus_u(reply_serial)})
	}
	if dest != "" {
		append(&fields, Dbus_Field{DBUS_FIELD_DESTINATION, "s", dbus_s(dest)})
	}
	if sig != "" {
		append(&fields, Dbus_Field{DBUS_FIELD_SIGNATURE, "g", dbus_g(sig)})
	}
	if len(bw.fds) > 0 {
		append(&fields, Dbus_Field{DBUS_FIELD_UNIX_FDS, "u", dbus_u(u32(len(bw.fds)))})
	}

	// The field array lives at message offset 16, which is 8-aligned, so a
	// writer that starts at zero produces identical padding.
	hw: Dbus_Writer
	defer delete(hw.b)
	for f in fields {
		dbus_w_pad(&hw, 8) // each (yv) is a struct
		dbus_w_u8(&hw, f.code)
		dbus_w_sig(&hw, f.sig)
		if !dbus_marshal(&hw, f.sig, f.val) {
			delete(bw.fds)
			return nil, nil, false
		}
	}

	msg: [dynamic]u8
	append(&msg, 'l') // little-endian; this is an x86-64 tree
	append(&msg, type)
	append(&msg, flags)
	append(&msg, 1) // protocol version
	blen := transmute([4]u8)u32(len(bw.b))
	append(&msg, ..blen[:])
	sb := transmute([4]u8)serial
	append(&msg, ..sb[:])
	fl := transmute([4]u8)u32(len(hw.b))
	append(&msg, ..fl[:])
	append(&msg, ..hw.b[:])
	for len(msg) % 8 != 0 {
		append(&msg, 0)
	}
	append(&msg, ..bw.b[:])

	return msg[:], bw.fds[:], true
}

// dbus_decode reads one message out of `buf`, which must hold at least a whole
// message. It returns the number of bytes consumed.
dbus_decode :: proc(buf: []u8, fds: []linux.Fd) -> (m: ^Dbus_Msg, used: int, ok: bool) {
	if len(buf) < 16 {
		return nil, 0, false
	}
	be := buf[0] == 'B'
	if buf[0] != 'l' && buf[0] != 'B' {
		return nil, 0, false
	}

	r := Dbus_Reader {
		b   = buf,
		p   = 1,
		be  = be,
		fds = fds,
	}
	type := dbus_r_u8(&r)
	flags := dbus_r_u8(&r)
	version := dbus_r_u8(&r)
	if version != 1 {
		return nil, 0, false
	}
	body_len := int(dbus_r_u32(&r))
	serial := dbus_r_u32(&r)

	m = new(Dbus_Msg)
	m.type = type
	m.flags = flags
	m.serial = serial

	fields := dbus_unmarshal(&r, "a(yv)")
	defer dbus_free_values(fields.items)
	if r.bad {
		free(m)
		return nil, 0, false
	}
	for f in fields.items {
		if len(f.items) != 2 {
			continue
		}
		code := u8(f.items[0].num)
		val := dbus_inner(f.items[1])
		switch code {
		case DBUS_FIELD_PATH:
			m.path = val.str
		case DBUS_FIELD_INTERFACE:
			m.iface = val.str
		case DBUS_FIELD_MEMBER:
			m.member = val.str
		case DBUS_FIELD_ERROR_NAME:
			m.err_name = val.str
		case DBUS_FIELD_REPLY_SERIAL:
			m.reply_serial = u32(val.num)
		case DBUS_FIELD_DESTINATION:
			m.dest = val.str
		case DBUS_FIELD_SENDER:
			m.sender = val.str
		case DBUS_FIELD_SIGNATURE:
			m.signature = val.str
		case DBUS_FIELD_UNIX_FDS:
			m.fd_count = u32(val.num)
		}
	}

	body_start := (r.p + 7) & ~int(7)
	total := body_start + body_len
	if total > len(buf) {
		free(m)
		return nil, 0, false
	}
	m.body = buf[body_start:total]
	return m, total, true
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

Dbus_Conn :: struct {
	fd:      linux.Fd,
	serial:  u32,
	unique:  string, // our bus name, from Hello
	rx:      [dynamic]u8,
	rx_fds:  [dynamic]linux.Fd,
	queue:   [dynamic]^Dbus_Msg, // signals and calls seen while awaiting a reply
	dropped: int,
	dead:    bool, // the peer hung up; the fd must leave the poll set
	be:      bool,
	err:     string, // last peer error, for reporting
}

dbus_verbose: bool

dbus_log :: proc(format: string, args: ..any) {
	if !dbus_verbose {
		return
	}
	fmt.eprintf("[dbus] ")
	fmt.eprintf(format, ..args)
	fmt.eprintf("\n")
}

// dbus_system_address resolves the system bus address the way the reference
// implementation does: the environment first, then the well-known path.
dbus_system_address :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("DBUS_SYSTEM_BUS_ADDRESS", allocator); v != "" {
		return v
	}
	return strings.clone("unix:path=/run/dbus/system_bus_socket", allocator)
}

// dbus_parse_address pulls the first unix transport out of a (possibly
// semicolon-separated) address list.
dbus_parse_address :: proc(addr: string) -> (path: string, abstract: bool, ok: bool) {
	rest := addr
	for len(rest) > 0 {
		entry := rest
		if idx := strings.index_byte(rest, ';'); idx >= 0 {
			entry = rest[:idx]
			rest = rest[idx + 1:]
		} else {
			rest = ""
		}
		if !strings.has_prefix(entry, "unix:") {
			continue
		}
		kv := entry[5:]
		for len(kv) > 0 {
			pair := kv
			if idx := strings.index_byte(kv, ','); idx >= 0 {
				pair = kv[:idx]
				kv = kv[idx + 1:]
			} else {
				kv = ""
			}
			if strings.has_prefix(pair, "path=") {
				return pair[5:], false, true
			}
			if strings.has_prefix(pair, "abstract=") {
				return pair[9:], true, true
			}
		}
	}
	return "", false, false
}

@(private = "file")
dbus_connect_unix :: proc(path: string, abstract: bool) -> (linux.Fd, Dbus_Error) {
	fd, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0))
	if serr != .NONE {
		return -1, .Connect
	}
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	n := len(path)
	if abstract {
		if n + 1 > len(addr.sun_path) {
			linux.close(fd)
			return -1, .Connect
		}
		addr.sun_path[0] = 0
		copy(addr.sun_path[1:], path)
		n += 1
	} else {
		if n + 1 > len(addr.sun_path) {
			linux.close(fd)
			return -1, .Connect
		}
		copy(addr.sun_path[:], path)
	}
	// connect(2) is issued directly so the address length is exact, which is
	// what abstract sockets need; the core wrapper always passes sizeof.
	addrlen := uintptr(size_of(linux.Address_Family) + n)
	ret := int(intrinsics.syscall(linux.SYS_connect, uintptr(fd), uintptr(rawptr(&addr)), addrlen))
	if ret < 0 {
		linux.close(fd)
		return -1, .Connect
	}
	return fd, .None
}

@(private = "file")
dbus_write_all :: proc(fd: linux.Fd, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		remaining := uint(len(data)) - uint(sent)
		iov := [1]linux.IO_Vec{{base = raw_data(data[sent:]), len = remaining}}
		hdr := linux.Msg_Hdr {
			iov = iov[:],
		}
		n, err := linux.sendmsg(fd, &hdr, {.NOSIGNAL})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

@(private = "file")
dbus_read_line :: proc(fd: linux.Fd, buf: []u8) -> (string, bool) {
	n := 0
	for n < len(buf) {
		// A bus that stops talking mid-handshake must not wedge the
		// compositor's startup, so each byte is waited for with a deadline.
		pfd := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		pn, perr := linux.poll(pfd[:], 5000)
		if perr == .EINTR {
			continue
		}
		if perr != .NONE || pn == 0 {
			return "", false
		}
		got, err := linux.read(fd, buf[n:n + 1])
		if err == .EINTR {
			continue
		}
		if err != .NONE || got != 1 {
			return "", false
		}
		n += 1
		if n >= 2 && buf[n - 2] == '\r' && buf[n - 1] == '\n' {
			return string(buf[:n - 2]), true
		}
	}
	return "", false
}

// dbus_connect opens the bus, performs the EXTERNAL SASL handshake, negotiates
// descriptor passing and says Hello. `address` empty means the system bus.
dbus_connect :: proc(address: string = "") -> (^Dbus_Conn, Dbus_Error) {
	addr := address
	if addr == "" {
		addr = dbus_system_address(context.temp_allocator)
	}
	path, abstract, ok := dbus_parse_address(addr)
	if !ok {
		return nil, .No_Address
	}

	fd, cerr := dbus_connect_unix(path, abstract)
	if cerr != .None {
		return nil, cerr
	}

	// The nul byte is the credentials-passing preamble; without it the daemon
	// will not even start the SASL conversation.
	zero := [1]u8{0}
	if !dbus_write_all(fd, zero[:]) {
		linux.close(fd)
		return nil, .Io
	}

	// EXTERNAL carries the uid as its decimal spelling, hex-encoded a nibble
	// at a time -- uid 1000 becomes "31303030".
	uid := u64(linux.getuid())
	dec: [24]u8
	dn := len(dec)
	if uid == 0 {
		dn -= 1
		dec[dn] = '0'
	}
	for v := uid; v > 0; v /= 10 {
		dn -= 1
		dec[dn] = '0' + u8(v % 10)
	}
	hex: [48]u8
	hn := 0
	digits := "0123456789abcdef"
	for ch in dec[dn:] {
		hex[hn] = digits[ch >> 4]
		hex[hn + 1] = digits[ch & 0xf]
		hn += 2
	}
	line := fmt.tprintf("AUTH EXTERNAL %s\r\n", string(hex[:hn]))
	if !dbus_write_all(fd, transmute([]u8)line) {
		linux.close(fd)
		return nil, .Io
	}

	lb: [512]u8
	reply, lok := dbus_read_line(fd, lb[:])
	if !lok || !strings.has_prefix(reply, "OK ") {
		dbus_log("auth rejected: %s", reply)
		linux.close(fd)
		return nil, .Auth
	}
	dbus_log("auth ok, server guid %s", reply[3:])

	if !dbus_write_all(fd, transmute([]u8)string("NEGOTIATE_UNIX_FD\r\n")) {
		linux.close(fd)
		return nil, .Io
	}
	lb2: [512]u8
	reply2, lok2 := dbus_read_line(fd, lb2[:])
	if !lok2 || reply2 != "AGREE_UNIX_FD" {
		dbus_log("fd passing refused: %s", reply2)
		linux.close(fd)
		return nil, .No_Fd_Passing
	}

	if !dbus_write_all(fd, transmute([]u8)string("BEGIN\r\n")) {
		linux.close(fd)
		return nil, .Io
	}

	c := new(Dbus_Conn)
	c.fd = fd
	c.serial = 0

	hello, herr := dbus_call(
		c,
		"org.freedesktop.DBus",
		"/org/freedesktop/DBus",
		"org.freedesktop.DBus",
		"Hello",
		"",
		nil,
	)
	if herr != .None {
		if hello != nil {
			dbus_msg_free(hello)
		}
		dbus_close(c)
		return nil, herr
	}
	if len(hello.args) == 1 {
		c.unique = strings.clone(hello.args[0].str)
	}
	dbus_msg_free(hello)
	dbus_log("connected as %s", c.unique)
	return c, .None
}

dbus_close :: proc(c: ^Dbus_Conn) {
	if c == nil {
		return
	}
	for m in c.queue {
		dbus_msg_close_fds(m)
		dbus_msg_free(m)
	}
	delete(c.queue)
	for fd in c.rx_fds {
		linux.close(fd)
	}
	delete(c.rx_fds)
	delete(c.rx)
	if c.unique != "" {
		delete(c.unique)
	}
	if c.fd >= 0 {
		linux.close(c.fd)
	}
	free(c)
}

// dbus_fd is the descriptor to put in the compositor's poll set.
dbus_fd :: proc(c: ^Dbus_Conn) -> linux.Fd {
	if c == nil || c.dead {
		return -1
	}
	return c.fd
}

// dbus_alive is false once the bus has hung up on us.
dbus_alive :: proc(c: ^Dbus_Conn) -> bool {
	return c != nil && !c.dead
}

@(private = "file")
dbus_send :: proc(c: ^Dbus_Conn, data: []u8, fds: []linux.Fd) -> bool {
	ctrl: [256]u8
	ctrl_len := 0
	if n := len(fds); n > 0 {
		payload := n * size_of(i32)
		if size_of(Cmsg_Hdr) + payload > len(ctrl) {
			return false
		}
		hdr := Cmsg_Hdr {
			len   = uint(size_of(Cmsg_Hdr) + payload),
			level = DBUS_SOL_SOCKET,
			type  = DBUS_SCM_RIGHTS,
		}
		hb := transmute([size_of(Cmsg_Hdr)]u8)hdr
		copy(ctrl[:], hb[:])
		for fd, i in fds {
			fb := transmute([4]u8)i32(fd)
			copy(ctrl[size_of(Cmsg_Hdr) + i * 4:][:4], fb[:])
		}
		ctrl_len = (size_of(Cmsg_Hdr) + payload + 7) & ~int(7)
	}

	sent := 0
	for sent < len(data) {
		remaining := uint(len(data)) - uint(sent)
		iov := [1]linux.IO_Vec{{base = raw_data(data[sent:]), len = remaining}}
		hdr := linux.Msg_Hdr {
			iov = iov[:],
		}
		if sent == 0 && ctrl_len > 0 {
			hdr.control = ctrl[:ctrl_len]
		}
		n, err := linux.sendmsg(c.fd, &hdr, {.NOSIGNAL})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// dbus_fill drains the socket into the receive buffer, harvesting descriptors
// out of the control messages exactly as wire.odin does. It never blocks; it
// stops at EAGAIN, or once it has taken enough in one pass that a flooding
// peer cannot grow the buffer without bound.
@(private = "file")
DBUS_FILL_CAP :: 4 * 1024 * 1024

@(private = "file")
dbus_fill :: proc(c: ^Dbus_Conn) -> Dbus_Error {
	staging: [16384]u8
	ctrl: [512]u8
	taken := 0
	for taken < DBUS_FILL_CAP {
		iov := [1]linux.IO_Vec{{base = &staging[0], len = len(staging)}}
		hdr := linux.Msg_Hdr {
			iov     = iov[:],
			control = ctrl[:],
		}
		n, err := linux.recvmsg(c.fd, &hdr, {.DONTWAIT, .CMSG_CLOEXEC})
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			return .None
		}
		if err != .NONE || n == 0 {
			// EOF on the system bus is terminal. Mark it so the main loop
			// stops polling a descriptor that is permanently readable.
			c.dead = true
			return .Io
		}
		append(&c.rx, ..staging[:n])
		taken += n

		off := 0
		for off + size_of(Cmsg_Hdr) <= len(hdr.control) {
			cm := (^Cmsg_Hdr)(raw_data(hdr.control[off:]))
			if cm.len < size_of(Cmsg_Hdr) || off + int(cm.len) > len(hdr.control) {
				break
			}
			if cm.level == DBUS_SOL_SOCKET && cm.type == DBUS_SCM_RIGHTS {
				count := (int(cm.len) - size_of(Cmsg_Hdr)) / 4
				for i in 0 ..< count {
					v := (^i32)(raw_data(hdr.control[off + size_of(Cmsg_Hdr) + i * 4:]))^
					append(&c.rx_fds, linux.Fd(v))
				}
			}
			off += (int(cm.len) + 7) & ~int(7)
		}
		if n < len(staging) {
			return .None
		}
	}
	return .None
}

// dbus_take parses one whole message out of the receive buffer, if there is
// one, and hands it the descriptors its UNIX_FDS field claims.
@(private = "file")
dbus_take :: proc(c: ^Dbus_Conn) -> (^Dbus_Msg, bool) {
	if len(c.rx) < 16 {
		return nil, false
	}
	be := c.rx[0] == 'B'
	rd := dbus_peek_u32(c.rx[:], 4, be)
	fl := dbus_peek_u32(c.rx[:], 12, be)
	total := 16 + int((fl + 7) & ~u32(7)) + int(rd)
	if total < 16 || total > DBUS_MAX_MESSAGE {
		// Unrecoverable: the stream is no longer framed.
		clear(&c.rx)
		return nil, false
	}
	if len(c.rx) < total {
		return nil, false
	}

	raw := make([]u8, total)
	copy(raw, c.rx[:total])
	remaining := len(c.rx) - total
	if remaining > 0 {
		copy(c.rx[:remaining], c.rx[total:])
	}
	resize(&c.rx, remaining)

	m, used, ok := dbus_decode(raw, nil)
	if !ok {
		delete(raw)
		return nil, false
	}
	_ = used
	m.raw = raw

	if m.fd_count > 0 {
		take := int(m.fd_count)
		if take > len(c.rx_fds) {
			take = len(c.rx_fds)
		}
		fds := make([]linux.Fd, take)
		copy(fds, c.rx_fds[:take])
		for _ in 0 ..< take {
			ordered_remove(&c.rx_fds, 0)
		}
		m.fds = fds
	}

	if m.signature != "" {
		r := Dbus_Reader {
			b   = m.body,
			p   = 0,
			be  = be,
			fds = m.fds,
		}
		m.args = dbus_unmarshal_all(&r, m.signature)
		if r.bad {
			dbus_log("body of %s.%s did not parse as %s", m.iface, m.member, m.signature)
		}
	}
	return m, true
}

@(private = "file")
dbus_peek_u32 :: proc(b: []u8, off: int, be: bool) -> u32 {
	v := (^u32)(raw_data(b[off:]))^
	if be {
		return(
			(v >> 24) |
			((v >> 8) & 0x0000ff00) |
			((v << 8) & 0x00ff0000) |
			(v << 24) \
		)
	}
	return v
}

@(private = "file")
dbus_enqueue :: proc(c: ^Dbus_Conn, m: ^Dbus_Msg) {
	if len(c.queue) >= DBUS_MAX_QUEUE {
		old := c.queue[0]
		ordered_remove(&c.queue, 0)
		dbus_msg_close_fds(old)
		dbus_msg_free(old)
		c.dropped += 1
	}
	append(&c.queue, m)
}

// dbus_dispatch drains the socket without blocking, queueing everything that
// is not a reply we are waiting for. The main loop calls this when poll() says
// the bus fd is readable.
dbus_dispatch :: proc(c: ^Dbus_Conn) -> Dbus_Error {
	if c == nil || c.dead {
		return .Not_Ready
	}
	if e := dbus_fill(c); e != .None {
		return e
	}
	for {
		m, ok := dbus_take(c)
		if !ok {
			break
		}
		dbus_enqueue(c, m)
	}
	return .None
}

// dbus_next takes the oldest queued incoming message. The caller owns it and
// must free it.
dbus_next :: proc(c: ^Dbus_Conn) -> (^Dbus_Msg, bool) {
	if c == nil || len(c.queue) == 0 {
		return nil, false
	}
	m := c.queue[0]
	ordered_remove(&c.queue, 0)
	return m, true
}

// dbus_call sends a method call and waits for its reply, queueing anything
// else that arrives in the meantime.
dbus_call :: proc(
	c: ^Dbus_Conn,
	dest, path, iface, member: string,
	sig: string,
	args: []Dbus_Value,
	timeout_ms := 25000,
) -> (
	^Dbus_Msg,
	Dbus_Error,
) {
	if c == nil {
		return nil, .Not_Ready
	}
	c.serial += 1
	serial := c.serial
	data, fds, ok := dbus_encode(
		DBUS_MSG_CALL,
		0,
		serial,
		path,
		iface,
		member,
		dest,
		"",
		0,
		sig,
		args,
	)
	if !ok {
		return nil, .Protocol
	}
	defer delete(data)
	defer delete(fds)

	if !dbus_send(c, data, fds) {
		return nil, .Io
	}

	left := timeout_ms
	for {
		for {
			m, got := dbus_take(c)
			if !got {
				break
			}
			if (m.type == DBUS_MSG_RETURN || m.type == DBUS_MSG_ERROR) &&
			   m.reply_serial == serial {
				if m.type == DBUS_MSG_ERROR {
					c.err = m.err_name
					dbus_log(
						"%s.%s failed: %s (%s)",
						iface,
						member,
						m.err_name,
						len(m.args) > 0 ? m.args[0].str : "",
					)
					return m, .Call_Failed
				}
				return m, .None
			}
			dbus_enqueue(c, m)
		}

		if left <= 0 {
			return nil, .Timeout
		}
		slice := min(left, 200)
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		n, perr := linux.poll(pfd[:], i32(slice))
		if perr == .EINTR {
			continue
		}
		if perr != .NONE {
			return nil, .Io
		}
		if n == 0 {
			left -= slice
			continue
		}
		if e := dbus_fill(c); e != .None {
			return nil, e
		}
	}
}

// dbus_send_noreply is for calls whose answer we do not want -- notably
// PauseDeviceComplete, which logind expects promptly and does not reply to.
dbus_send_noreply :: proc(
	c: ^Dbus_Conn,
	dest, path, iface, member: string,
	sig: string,
	args: []Dbus_Value,
) -> Dbus_Error {
	if c == nil {
		return .Not_Ready
	}
	c.serial += 1
	data, fds, ok := dbus_encode(
		DBUS_MSG_CALL,
		DBUS_FLAG_NO_REPLY,
		c.serial,
		path,
		iface,
		member,
		dest,
		"",
		0,
		sig,
		args,
	)
	if !ok {
		return .Protocol
	}
	defer delete(data)
	defer delete(fds)
	return dbus_send(c, data, fds) ? .None : .Io
}

// dbus_add_match installs a signal match rule on the bus.
dbus_add_match :: proc(c: ^Dbus_Conn, rule: string) -> Dbus_Error {
	args := [1]Dbus_Value{dbus_s(rule)}
	m, e := dbus_call(
		c,
		"org.freedesktop.DBus",
		"/org/freedesktop/DBus",
		"org.freedesktop.DBus",
		"AddMatch",
		"s",
		args[:],
	)
	if m != nil {
		dbus_msg_free(m)
	}
	return e
}

dbus_remove_match :: proc(c: ^Dbus_Conn, rule: string) -> Dbus_Error {
	args := [1]Dbus_Value{dbus_s(rule)}
	m, e := dbus_call(
		c,
		"org.freedesktop.DBus",
		"/org/freedesktop/DBus",
		"org.freedesktop.DBus",
		"RemoveMatch",
		"s",
		args[:],
	)
	if m != nil {
		dbus_msg_free(m)
	}
	return e
}

// ---------------------------------------------------------------------------
// org.freedesktop.DBus.Properties
// ---------------------------------------------------------------------------

// dbus_get_property reads one property and unwraps the variant. The returned
// message owns the value's storage, so it is handed back too.
dbus_get_property :: proc(
	c: ^Dbus_Conn,
	dest, path, iface, name: string,
) -> (
	Dbus_Value,
	^Dbus_Msg,
	Dbus_Error,
) {
	args := [2]Dbus_Value{dbus_s(iface), dbus_s(name)}
	m, e := dbus_call(
		c,
		dest,
		path,
		"org.freedesktop.DBus.Properties",
		"Get",
		"ss",
		args[:],
	)
	if e != .None {
		return {}, m, e
	}
	if len(m.args) != 1 {
		return {}, m, .Protocol
	}
	return dbus_inner(m.args[0]), m, .None
}

// dbus_get_all reads every property of an interface as an a{sv}.
dbus_get_all :: proc(
	c: ^Dbus_Conn,
	dest, path, iface: string,
) -> (
	Dbus_Value,
	^Dbus_Msg,
	Dbus_Error,
) {
	args := [1]Dbus_Value{dbus_s(iface)}
	m, e := dbus_call(
		c,
		dest,
		path,
		"org.freedesktop.DBus.Properties",
		"GetAll",
		"s",
		args[:],
	)
	if e != .None {
		return {}, m, e
	}
	if len(m.args) != 1 {
		return {}, m, .Protocol
	}
	return m.args[0], m, .None
}
