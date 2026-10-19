package install_core

// COPIED from distro/login/crypt.odin (package login), unchanged but for the
// package name and this note. palm-login verifies the hashes this writes,
// so the two must stay the same algorithm; importing across the two packages
// would mean a collection for distro/login just for one file, and the
// selftest checks this copy against the same Drepper vectors.

// SHA-512 crypt, the `$6$` hashes in /etc/shadow.
//
// The algorithm is Ulrich Drepper's "Unix crypt using SHA-256 and SHA-512"
// (2007), the one glibc's crypt(3) implements and `openssl passwd -6`
// produces. Only the digest comes from core:crypto/sha2; everything around it
// — the salt and rounds parsing, the twenty-one steps that mix key, salt and
// intermediate digests, the custom base-64 with its byte permutation — is
// here, because that is the part a login manager must get exactly right and
// the part nobody ships for Odin.
//
// It is deliberately slow (5000 rounds of SHA-512 by default). That is the
// point of it, and the reason a failed attempt costs the attacker as much as
// it costs us.

import "core:crypto"
import "core:crypto/sha2"
import "core:fmt"
import "core:strconv"
import "core:strings"

ROUNDS_DEFAULT :: 5000
ROUNDS_MIN :: 1000
ROUNDS_MAX :: 999_999_999
SALT_MAX :: 16

// The crypt alphabet. Not RFC 4648: it starts at '.', and the bits are taken
// least significant first.
@(private = "file")
B64 := "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// sha512_crypt hashes `key` with the settings in `setting`, which is either a
// full hash (`$6$salt$...`) or just its prefix (`$6$rounds=N$salt`). The
// result is the complete `$6$...` string, so verifying a password is
// comparing it with what /etc/shadow holds.
sha512_crypt :: proc(key: string, setting: string, allocator := context.allocator) -> (out: string, ok: bool) {
	if !strings.has_prefix(setting, "$6$") {
		return "", false
	}
	rest := setting[3:]

	rounds := ROUNDS_DEFAULT
	rounds_custom := false
	if strings.has_prefix(rest, "rounds=") {
		end := strings.index_byte(rest, '$')
		if end < 0 {
			return "", false
		}
		n, nok := strconv.parse_u64_of_base(rest[len("rounds="):end], 10)
		if !nok {
			return "", false
		}
		// Out-of-range counts are clamped rather than refused: that is what the
		// specification says, and what every implementation does.
		rounds = int(clamp(n, ROUNDS_MIN, ROUNDS_MAX))
		rounds_custom = true
		rest = rest[end + 1:]
	}

	// The salt runs to the next '$' (or the end) and is cut at 16 bytes.
	salt := rest
	if d := strings.index_byte(salt, '$'); d >= 0 {
		salt = salt[:d]
	}
	if len(salt) > SALT_MAX {
		salt = salt[:SALT_MAX]
	}

	K := transmute([]u8)key
	S := transmute([]u8)salt

	ctx: sha2.Context_512

	// B = H(K S K)
	B: [64]u8
	sha2.init_512(&ctx)
	sha2.update(&ctx, K)
	sha2.update(&ctx, S)
	sha2.update(&ctx, K)
	sha2.final(&ctx, B[:])

	// A = H(K S, then B once per 64 bytes of key and the remainder, then B or
	// K for each bit of the key's length, lowest bit first).
	A: [64]u8
	sha2.init_512(&ctx)
	sha2.update(&ctx, K)
	sha2.update(&ctx, S)
	cnt := len(K)
	for ; cnt > 64; cnt -= 64 {
		sha2.update(&ctx, B[:])
	}
	sha2.update(&ctx, B[:cnt])
	for cnt = len(K); cnt > 0; cnt >>= 1 {
		if cnt & 1 != 0 {
			sha2.update(&ctx, B[:])
		} else {
			sha2.update(&ctx, K)
		}
	}
	sha2.final(&ctx, A[:])

	// P: H(K repeated len(K) times), stretched or cut to len(K) bytes.
	DP: [64]u8
	sha2.init_512(&ctx)
	for _ in 0 ..< len(K) {
		sha2.update(&ctx, K)
	}
	sha2.final(&ctx, DP[:])
	P := make([]u8, len(K), context.temp_allocator)
	defer crypto.zero_explicit(raw_data(P), len(P))
	for i in 0 ..< len(P) {
		P[i] = DP[i % 64]
	}

	// S': H(S repeated 16 + A[0] times), cut to len(S) bytes.
	DS: [64]u8
	sha2.init_512(&ctx)
	for _ in 0 ..< 16 + int(A[0]) {
		sha2.update(&ctx, S)
	}
	sha2.final(&ctx, DS[:])
	Sp := DS[:len(S)]

	// The rounds. Each one alternates the order of P and the previous digest
	// and folds in S' and P on a 3- and 7-cycle, so no two consecutive rounds
	// hash the same shape of input.
	for i in 0 ..< rounds {
		sha2.init_512(&ctx)
		if i & 1 != 0 {
			sha2.update(&ctx, P)
		} else {
			sha2.update(&ctx, A[:])
		}
		if i % 3 != 0 {
			sha2.update(&ctx, Sp)
		}
		if i % 7 != 0 {
			sha2.update(&ctx, P)
		}
		if i & 1 != 0 {
			sha2.update(&ctx, A[:])
		} else {
			sha2.update(&ctx, P)
		}
		sha2.final(&ctx, A[:])
	}

	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "$6$")
	if rounds_custom {
		strings.write_string(&sb, "rounds=")
		strings.write_int(&sb, rounds)
		strings.write_byte(&sb, '$')
	}
	strings.write_string(&sb, salt)
	strings.write_byte(&sb, '$')

	// The final digest is written as 22 groups of three bytes taken in this
	// fixed, scattered order, then the last byte alone.
	@(static, rodata)
	ORDER := [21][3]u8 {
		{0, 21, 42}, {22, 43, 1}, {44, 2, 23}, {3, 24, 45}, {25, 46, 4},
		{47, 5, 26}, {6, 27, 48}, {28, 49, 7}, {50, 8, 29}, {9, 30, 51},
		{31, 52, 10}, {53, 11, 32}, {12, 33, 54}, {34, 55, 13}, {56, 14, 35},
		{15, 36, 57}, {37, 58, 16}, {59, 17, 38}, {18, 39, 60}, {40, 61, 19},
		{62, 20, 41},
	}
	for g in ORDER {
		b64_24(&sb, A[g[0]], A[g[1]], A[g[2]], 4)
	}
	b64_24(&sb, 0, 0, A[63], 2)

	crypto.zero_explicit(&B, size_of(B))
	crypto.zero_explicit(&DP, size_of(DP))
	return strings.to_string(sb), true
}

@(private = "file")
b64_24 :: proc(sb: ^strings.Builder, b2, b1, b0: u8, n: int) {
	w := u32(b2) << 16 | u32(b1) << 8 | u32(b0)
	for _ in 0 ..< n {
		strings.write_byte(sb, B64[w & 0x3f])
		w >>= 6
	}
}

// verify_password reports whether `password` matches the shadow field
// `stored`. Locked (`!...`, `*`) and empty fields never match: Palmy has
// no passwordless graphical login, an account without a hash is a locked one.
// Only `$6$` is understood; anything else is refused rather than guessed at.
verify_password :: proc(password: string, stored: string) -> bool {
	if stored == "" || strings.has_prefix(stored, "!") || strings.has_prefix(stored, "*") {
		return false
	}
	if !strings.has_prefix(stored, "$6$") {
		return false
	}
	got, ok := sha512_crypt(password, stored, context.temp_allocator)
	if !ok {
		return false
	}
	return crypto.compare_constant_time(transmute([]u8)got, transmute([]u8)stored) == 1
}

// make_hash produces a fresh `$6$` hash: a random 16-character salt unless
// one is given, and the default rounds unless asked otherwise.
make_hash :: proc(password: string, salt := "", rounds := 0, allocator := context.allocator) -> (string, bool) {
	s := salt
	if s == "" {
		raw: [SALT_MAX]u8
		crypto.rand_bytes(raw[:])
		buf := make([]u8, SALT_MAX, context.temp_allocator)
		for b, i in raw {
			buf[i] = B64[b & 0x3f]
		}
		s = string(buf)
	}
	if len(s) > SALT_MAX {
		return "", false
	}
	for ch in transmute([]u8)s {
		if strings.index_byte(B64, ch) < 0 {
			return "", false
		}
	}
	setting := rounds > 0 ? fmt.tprintf("$6$rounds=%d$%s", rounds, s) : fmt.tprintf("$6$%s", s)
	return sha512_crypt(password, setting, allocator)
}
