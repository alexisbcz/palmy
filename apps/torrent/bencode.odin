package main

// Bencode, exactly.
//
// The info-hash of a torrent is SHA-1 over the bencoded `info` dictionary, so
// this codec is not allowed to be approximately right. Two properties matter
// more than anything else here:
//
//   1. On encode, dictionary keys come out in ascending raw-byte order. A
//      dictionary that round-trips in the order it happened to be written in
//      silently produces a different info-hash than every other client in the
//      world computes for the same torrent.
//
//   2. On decode, every value remembers the byte range it occupied in the
//      source. That is what lets `metainfo.odin` hash the ORIGINAL bytes of the
//      `info` dictionary rather than its own re-encoding of it. Those two differ
//      whenever the file on disk has a key order, or an integer spelling, this
//      encoder would not have produced — and the correct hash is the one over
//      the original bytes.
//
// The decoder is strict on purpose. `i-0e`, `i03e`, `03:abc`, a dictionary with
// a non-string key, a duplicate key, a truncated string and trailing garbage
// are all errors rather than best-effort guesses, because a torrent file is
// hostile input: it arrives from a stranger.

import "base:runtime"
import "core:slice"
import "core:strings"

Ben_Kind :: enum u8 {
	Int,
	Str,
	List,
	Dict,
}

// Ben is one bencoded value. `str`, `list` and `dict` alias the source buffer
// (strings) or the parse allocator (containers); the source must outlive the
// tree.
Ben :: struct {
	kind:  Ben_Kind,
	num:   i64,
	str:   []u8,
	list:  []Ben,
	dict:  []Ben_Pair,
	start: int, // offset of the first byte of this value in the source
	end:   int, // one past its last byte
}

Ben_Pair :: struct {
	key: []u8,
	val: Ben,
}

// Limits. A torrent for a terabyte of data has a `pieces` string of about
// 20 MB, so the string cap has to be generous; everything else is small.
BEN_MAX_DEPTH :: 64
BEN_MAX_STR :: 64 << 20
BEN_MAX_ITEMS :: 1 << 21

@(private = "file")
Ben_Parser :: struct {
	src:   []u8,
	pos:   int,
	depth: int,
	alloc: runtime.Allocator,
	err:   string,
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

// ben_decode parses one value and insists the whole input was consumed.
ben_decode :: proc(src: []u8, allocator := context.allocator) -> (v: Ben, err: string) {
	out, n, e := ben_decode_prefix(src, allocator)
	if e != "" {
		return {}, e
	}
	if n != len(src) {
		return {}, tsprint("trailing garbage: %d byte(s) after the top-level value", len(src) - n)
	}
	return out, ""
}

// ben_decode_prefix parses one value and reports how many bytes it used, which
// is what a stream of concatenated values needs.
ben_decode_prefix :: proc(
	src: []u8,
	allocator := context.allocator,
) -> (
	v: Ben,
	consumed: int,
	err: string,
) {
	p := Ben_Parser {
		src   = src,
		alloc = allocator,
	}
	out, ok := ben_value(&p)
	if !ok {
		return {}, p.pos, p.err == "" ? "malformed bencoding" : p.err
	}
	return out, p.pos, ""
}

@(private = "file")
pfail :: proc(p: ^Ben_Parser, format: string, args: ..any) -> bool {
	if p.err == "" {
		p.err = tsprint("at byte %d: %s", p.pos, tsprint(format, ..args))
	}
	return false
}

@(private = "file")
ben_value :: proc(p: ^Ben_Parser) -> (v: Ben, ok: bool) {
	if p.pos >= len(p.src) {
		return {}, pfail(p, "unexpected end of input")
	}
	if p.depth >= BEN_MAX_DEPTH {
		return {}, pfail(p, "nested deeper than %d", BEN_MAX_DEPTH)
	}
	switch p.src[p.pos] {
	case 'i':
		return ben_int(p)
	case 'l':
		return ben_list(p)
	case 'd':
		return ben_dict(p)
	case '0' ..= '9':
		return ben_str(p)
	}
	return {}, pfail(p, "%q begins no bencoded value", rune(p.src[p.pos]))
}

// ben_digits reads a run of ASCII digits with the no-leading-zero rule. `0`
// alone is legal; `00`, `01` and `0123` are not.
@(private = "file")
ben_digits :: proc(p: ^Ben_Parser) -> (val: i64, ok: bool) {
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		d := i64(p.src[p.pos] - '0')
		if val > (max(i64) - d) / 10 {
			return 0, pfail(p, "integer overflows i64")
		}
		val = val * 10 + d
		p.pos += 1
	}
	n := p.pos - start
	if n == 0 {
		return 0, pfail(p, "expected a digit")
	}
	if n > 1 && p.src[start] == '0' {
		return 0, pfail(p, "leading zero in %q", string(p.src[start:p.pos]))
	}
	return val, true
}

@(private = "file")
ben_int :: proc(p: ^Ben_Parser) -> (v: Ben, ok: bool) {
	start := p.pos
	p.pos += 1 // 'i'
	neg := false
	if p.pos < len(p.src) && p.src[p.pos] == '-' {
		neg = true
		p.pos += 1
	}
	n, good := ben_digits(p)
	if !good {
		return {}, false
	}
	if neg && n == 0 {
		return {}, pfail(p, "i-0e is not a bencoded integer")
	}
	if p.pos >= len(p.src) || p.src[p.pos] != 'e' {
		return {}, pfail(p, "unterminated integer")
	}
	p.pos += 1
	return Ben{kind = .Int, num = neg ? -n : n, start = start, end = p.pos}, true
}

@(private = "file")
ben_str :: proc(p: ^Ben_Parser) -> (v: Ben, ok: bool) {
	start := p.pos
	n, good := ben_digits(p)
	if !good {
		return {}, false
	}
	if p.pos >= len(p.src) || p.src[p.pos] != ':' {
		return {}, pfail(p, "expected ':' after a string length")
	}
	p.pos += 1
	if n > BEN_MAX_STR {
		return {}, pfail(p, "string of %d bytes exceeds the %d byte cap", n, BEN_MAX_STR)
	}
	if int(n) > len(p.src) - p.pos {
		return {}, pfail(
			p,
			"string claims %d bytes but only %d remain",
			n,
			len(p.src) - p.pos,
		)
	}
	s := p.src[p.pos:p.pos + int(n)]
	p.pos += int(n)
	return Ben{kind = .Str, str = s, start = start, end = p.pos}, true
}

@(private = "file")
ben_list :: proc(p: ^Ben_Parser) -> (v: Ben, ok: bool) {
	start := p.pos
	p.pos += 1 // 'l'
	p.depth += 1
	defer p.depth -= 1

	items := make([dynamic]Ben, 0, 8, p.alloc)
	for {
		if p.pos >= len(p.src) {
			return {}, pfail(p, "unterminated list")
		}
		if p.src[p.pos] == 'e' {
			p.pos += 1
			break
		}
		if len(items) >= BEN_MAX_ITEMS {
			return {}, pfail(p, "list longer than %d items", BEN_MAX_ITEMS)
		}
		item, good := ben_value(p)
		if !good {
			return {}, false
		}
		append(&items, item)
	}
	return Ben{kind = .List, list = items[:], start = start, end = p.pos}, true
}

@(private = "file")
ben_dict :: proc(p: ^Ben_Parser) -> (v: Ben, ok: bool) {
	start := p.pos
	p.pos += 1 // 'd'
	p.depth += 1
	defer p.depth -= 1

	pairs := make([dynamic]Ben_Pair, 0, 8, p.alloc)
	for {
		if p.pos >= len(p.src) {
			return {}, pfail(p, "unterminated dictionary")
		}
		if p.src[p.pos] == 'e' {
			p.pos += 1
			break
		}
		if len(pairs) >= BEN_MAX_ITEMS {
			return {}, pfail(p, "dictionary larger than %d keys", BEN_MAX_ITEMS)
		}
		if p.src[p.pos] < '0' || p.src[p.pos] > '9' {
			return {}, pfail(p, "a dictionary key must be a byte string")
		}
		k, kok := ben_str(p)
		if !kok {
			return {}, false
		}
		for existing in pairs {
			if slice.equal(existing.key, k.str) {
				return {}, pfail(p, "duplicate dictionary key %q", string(k.str))
			}
		}
		val, vok := ben_value(p)
		if !vok {
			return {}, false
		}
		append(&pairs, Ben_Pair{key = k.str, val = val})
	}
	return Ben{kind = .Dict, dict = pairs[:], start = start, end = p.pos}, true
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

// ben_encode writes `v` as bencoding, with every dictionary's keys in
// ascending raw-byte order. This is the property the info-hash rests on.
ben_encode :: proc(v: Ben, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 256, allocator)
	ben_write(&out, v)
	return out[:]
}

ben_encode_string :: proc(v: Ben, allocator := context.allocator) -> string {
	return string(ben_encode(v, allocator))
}

ben_write :: proc(out: ^[dynamic]u8, v: Ben) {
	switch v.kind {
	case .Int:
		append(out, 'i')
		write_i64(out, v.num)
		append(out, 'e')
	case .Str:
		write_i64(out, i64(len(v.str)))
		append(out, ':')
		append(out, ..v.str)
	case .List:
		append(out, 'l')
		for item in v.list {
			ben_write(out, item)
		}
		append(out, 'e')
	case .Dict:
		append(out, 'd')
		// Sort by raw bytes. `slice.sort_by` is not stable, but duplicate keys
		// are rejected on decode and refused by the builders, so the order is
		// total and the result is deterministic.
		keys := make([]Ben_Pair, len(v.dict), context.temp_allocator)
		copy(keys, v.dict)
		slice.sort_by(keys, proc(a, b: Ben_Pair) -> bool {
			return ben_key_less(a.key, b.key)
		})
		for pr in keys {
			write_i64(out, i64(len(pr.key)))
			append(out, ':')
			append(out, ..pr.key)
			ben_write(out, pr.val)
		}
		append(out, 'e')
	}
}

// ben_key_less is bencoding's key order: raw byte comparison, with a prefix
// sorting before the string it is a prefix of. `strings.compare` on the bytes
// would be the same thing, but spelling it out makes the rule checkable.
ben_key_less :: proc(a, b: []u8) -> bool {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

@(private = "file")
write_i64 :: proc(out: ^[dynamic]u8, v: i64) {
	if v == 0 {
		append(out, '0')
		return
	}
	n := v
	if n < 0 {
		append(out, '-')
	}
	digits: [24]u8
	i := len(digits)
	// Negate per digit so min(i64) does not overflow.
	for n != 0 {
		i -= 1
		d := n % 10
		if d < 0 {
			d = -d
		}
		digits[i] = u8('0' + d)
		n /= 10
	}
	append(out, ..digits[i:])
}

// ---------------------------------------------------------------------------
// Reading values out
// ---------------------------------------------------------------------------

ben_get :: proc(d: Ben, key: string) -> (v: Ben, ok: bool) {
	if d.kind != .Dict {
		return {}, false
	}
	kb := transmute([]u8)key
	for pr in d.dict {
		if slice.equal(pr.key, kb) {
			return pr.val, true
		}
	}
	return {}, false
}

ben_str_of :: proc(d: Ben, key: string) -> (s: string, ok: bool) {
	v, found := ben_get(d, key)
	if !found || v.kind != .Str {
		return "", false
	}
	return string(v.str), true
}

ben_bytes_of :: proc(d: Ben, key: string) -> (b: []u8, ok: bool) {
	v, found := ben_get(d, key)
	if !found || v.kind != .Str {
		return nil, false
	}
	return v.str, true
}

ben_int_of :: proc(d: Ben, key: string, dflt: i64 = 0) -> (n: i64, ok: bool) {
	v, found := ben_get(d, key)
	if !found || v.kind != .Int {
		return dflt, false
	}
	return v.num, true
}

ben_list_of :: proc(d: Ben, key: string) -> (l: []Ben, ok: bool) {
	v, found := ben_get(d, key)
	if !found || v.kind != .List {
		return nil, false
	}
	return v.list, true
}

// ben_dict_sorted reports whether a decoded dictionary's keys were already in
// bencoding order. Real torrents are; a torrent that is not is still legal to
// read, and is the case that proves the info-hash must come from the original
// bytes.
ben_dict_sorted :: proc(d: Ben) -> bool {
	if d.kind != .Dict {
		return true
	}
	for i in 1 ..< len(d.dict) {
		if !ben_key_less(d.dict[i - 1].key, d.dict[i].key) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

bnum :: proc(v: i64) -> Ben {
	return Ben{kind = .Int, num = v}
}

bstr :: proc(s: string) -> Ben {
	return Ben{kind = .Str, str = transmute([]u8)s}
}

bbytes :: proc(b: []u8) -> Ben {
	return Ben{kind = .Str, str = b}
}

blist :: proc(items: []Ben, allocator := context.temp_allocator) -> Ben {
	c := make([]Ben, len(items), allocator)
	copy(c, items)
	return Ben{kind = .List, list = c}
}

bdict :: proc(pairs: []Ben_Pair, allocator := context.temp_allocator) -> Ben {
	c := make([]Ben_Pair, len(pairs), allocator)
	copy(c, pairs)
	return Ben{kind = .Dict, dict = c}
}

bp :: proc(key: string, val: Ben) -> Ben_Pair {
	return Ben_Pair{key = transmute([]u8)key, val = val}
}

// ben_describe renders a value as a readable one-liner, for diagnostics.
ben_describe :: proc(v: Ben, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	ben_describe_into(&b, v)
	return strings.to_string(b)
}

@(private = "file")
ben_describe_into :: proc(b: ^strings.Builder, v: Ben) {
	switch v.kind {
	case .Int:
		strings.write_i64(b, v.num)
	case .Str:
		printable := true
		for c in v.str {
			if c < 0x20 || c > 0x7e {printable = false;break}
		}
		if printable && len(v.str) <= 64 {
			strings.write_quoted_string(b, string(v.str))
		} else {
			strings.write_string(b, "<")
			strings.write_int(b, len(v.str))
			strings.write_string(b, " bytes>")
		}
	case .List:
		strings.write_byte(b, '[')
		for item, i in v.list {
			if i > 0 {strings.write_string(b, ", ")}
			ben_describe_into(b, item)
		}
		strings.write_byte(b, ']')
	case .Dict:
		strings.write_byte(b, '{')
		for pr, i in v.dict {
			if i > 0 {strings.write_string(b, ", ")}
			strings.write_quoted_string(b, string(pr.key))
			strings.write_string(b, ": ")
			ben_describe_into(b, pr.val)
		}
		strings.write_byte(b, '}')
	}
}
