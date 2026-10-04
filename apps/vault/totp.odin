package main

// RFC 4226 HOTP and RFC 6238 TOTP, over `core:crypto/hmac`.
//
// This is a feature that is either exactly right or useless, because a code
// that is off by one digit or one time step fails silently at the far end. The
// published vectors in vectors.odin are the only reason to believe this works:
// a TOTP that round-trips against itself proves nothing at all.

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:strings"

Totp_Algo :: enum u8 {
	SHA1   = 0,
	SHA256 = 1,
	SHA512 = 2,
}

TOTP_ALGO_NAME := [Totp_Algo]string {
	.SHA1   = "SHA1",
	.SHA256 = "SHA256",
	.SHA512 = "SHA512",
}

totp_hash :: proc(a: Totp_Algo) -> (alg: hash.Algorithm, size: int) {
	switch a {
	case .SHA1:
		return .Insecure_SHA1, 20
	case .SHA256:
		return .SHA256, 32
	case .SHA512:
		return .SHA512, 64
	}
	return .Insecure_SHA1, 20
}

// ---------------------------------------------------------------------------
// Base32, RFC 4648
//
// Authenticator secrets are handed out as base32 with spaces and dashes in
// them, in either case, sometimes without padding. All of that decodes; a
// character outside the alphabet does not, because silently skipping one would
// turn a typo into a code that is merely wrong.
// ---------------------------------------------------------------------------

B32_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

base32_decode :: proc(s: string, allocator := context.allocator) -> (out: []byte, ok: bool) {
	buf := make([dynamic]byte, 0, len(s) * 5 / 8 + 1, allocator)
	acc: u32
	bits: uint
	for ch in s {
		c := ch
		// Formatting a user pasted in, not data.
		if c == ' ' || c == '-' || c == '\t' || c == '\n' || c == '\r' {
			continue
		}
		// Padding: everything from here on is padding too.
		if c == '=' {
			break
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		v := -1
		if c >= 'A' && c <= 'Z' {
			v = int(c - 'A')
		} else if c >= '2' && c <= '7' {
			v = int(c - '2') + 26
		}
		if v < 0 {
			delete(buf)
			return nil, false
		}
		acc = acc << 5 | u32(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			append(&buf, u8(acc >> bits))
			acc &= (1 << bits) - 1
		}
	}
	// Leftover bits must be zero padding, not data.
	if bits > 0 && acc != 0 {
		delete(buf)
		return nil, false
	}
	return buf[:], true
}

base32_encode :: proc(data: []byte, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	acc: u32
	bits: uint
	for b in data {
		acc = acc << 8 | u32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			strings.write_byte(&sb, B32_ALPHABET[(acc >> bits) & 31])
		}
	}
	if bits > 0 {
		strings.write_byte(&sb, B32_ALPHABET[(acc << (5 - bits)) & 31])
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// HOTP / TOTP
// ---------------------------------------------------------------------------

POW10 := [?]u32{1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000}

// hotp is RFC 4226 section 5.3: HMAC the 8-byte big-endian counter, then
// dynamic truncation -- the low nibble of the last byte picks a 4-byte window,
// its top bit is cleared, and the result is taken modulo 10^digits.
hotp :: proc(secret: []byte, counter: u64, digits: int, algo: Totp_Algo) -> u32 {
	ctr: [8]byte
	c := counter
	for i := 7; i >= 0; i -= 1 {
		ctr[i] = u8(c)
		c >>= 8
	}
	alg, size := totp_hash(algo)
	mac: [64]byte
	hmac.sum(alg, mac[:size], ctr[:], secret)

	off := int(mac[size - 1] & 0x0f)
	bin :=
		(u32(mac[off]) & 0x7f) << 24 |
		u32(mac[off + 1]) << 16 |
		u32(mac[off + 2]) << 8 |
		u32(mac[off + 3])
	d := clamp(digits, 1, 8)
	return bin % POW10[d]
}

totp_counter :: proc(unix_s: i64, period: u32) -> u64 {
	p := i64(period == 0 ? 30 : period)
	// Floor division, so a pre-epoch timestamp does not round the wrong way.
	q := unix_s / p
	if unix_s < 0 && unix_s % p != 0 {
		q -= 1
	}
	return u64(q)
}

totp_at :: proc(secret: []byte, unix_s: i64, period: u32, digits: int, algo: Totp_Algo) -> u32 {
	return hotp(secret, totp_counter(unix_s, period), digits, algo)
}

// totp_format zero-pads to the digit count, which matters: a code of 51 is
// "000051" and typing "51" fails.
totp_format :: proc(code: u32, digits: int, allocator := context.temp_allocator) -> string {
	d := clamp(digits, 1, 8)
	buf := make([]byte, d, allocator)
	v := code
	for i := d - 1; i >= 0; i -= 1 {
		buf[i] = '0' + u8(v % 10)
		v /= 10
	}
	return string(buf)
}

// totp_code is the whole feature in one call: a base32 secret and a wall clock
// in, a display string out.
totp_code :: proc(
	b32: string,
	unix_s: i64,
	period: u32,
	digits: int,
	algo: Totp_Algo,
	allocator := context.temp_allocator,
) -> (
	code: string,
	ok: bool,
) {
	secret, good := base32_decode(b32, context.temp_allocator)
	if !good || len(secret) == 0 {
		return "", false
	}
	return totp_format(totp_at(secret, unix_s, period, digits, algo), digits, allocator), true
}

// totp_remaining is the seconds left in the current step, for the countdown.
totp_remaining :: proc(unix_s: i64, period: u32) -> int {
	p := i64(period == 0 ? 30 : period)
	r := unix_s % p
	if r < 0 {
		r += p
	}
	return int(p - r)
}

// totp_secret_ok is the cheap check the editor uses to tell you a pasted
// secret is unusable before you save it.
totp_secret_ok :: proc(b32: string) -> bool {
	if strings.trim_space(b32) == "" {
		return true // no TOTP is fine
	}
	secret, ok := base32_decode(b32, context.temp_allocator)
	return ok && len(secret) >= 10
}
