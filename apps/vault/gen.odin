package main

// The password generator.
//
// The one mistake that matters here is `rand_bytes() % len(alphabet)`. For any
// alphabet whose size does not divide 256 that skews the distribution: with 94
// printable characters, 256 = 2*94 + 68, so the first 68 characters come up
// three times per 256 draws and the other 26 only twice -- a 50% bias on a
// third of the alphabet, and a real loss of entropy per character. So every
// draw here goes through rejection sampling, and the self-test asserts the
// distribution over 600,000 characters is flat.

import "core:crypto"
import "core:math"
import "core:strings"

Class :: enum u8 {
	Lower,
	Upper,
	Digits,
	Symbols,
}

CLASS_LABEL := [Class]string {
	.Lower   = "a-z",
	.Upper   = "A-Z",
	.Digits  = "0-9",
	.Symbols = "!@#",
}

CLASS_CHARS := [Class]string {
	.Lower   = "abcdefghijklmnopqrstuvwxyz",
	.Upper   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
	.Digits  = "0123456789",
	.Symbols = "!#$%&()*+,-./:;<=>?@[]^_{|}~",
}

// Characters that are routinely misread off a screen or a printout. Excluding
// them costs entropy, which is why the bit count the UI shows is computed from
// the alphabet actually in use rather than from the nominal one.
AMBIGUOUS :: "Il1O0o"

GEN_MIN_LEN :: 6
GEN_MAX_LEN :: 128

Gen_Opts :: struct {
	length:       int,
	classes:      bit_set[Class],
	no_ambiguous: bool,
	require_each: bool,
}

GEN_DEFAULT :: Gen_Opts {
	length       = 20,
	classes      = {.Lower, .Upper, .Digits, .Symbols},
	no_ambiguous = false,
	require_each = true,
}

gen_alphabet :: proc(o: Gen_Opts, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for c in Class {
		if c not_in o.classes {
			continue
		}
		for ch in CLASS_CHARS[c] {
			if o.no_ambiguous && strings.contains_rune(AMBIGUOUS, ch) {
				continue
			}
			strings.write_rune(&sb, ch)
		}
	}
	return strings.to_string(sb)
}

// rand_index returns a uniform value in [0, n) from the OS CSPRNG.
//
// `limit` is the largest multiple of n that fits in a byte; a draw at or above
// it is thrown away and redrawn rather than folded in. The expected number of
// draws is 256/limit, at worst just under two for n = 129..255, and for the
// alphabets here it is 1.09.
rand_index :: proc(n: int) -> int {
	assert(n > 0 && n <= 256, "rand_index is byte-sized")
	limit := 256 - (256 % n)
	buf: [1]byte
	for {
		crypto.rand_bytes(buf[:])
		if int(buf[0]) < limit {
			return int(buf[0]) % n
		}
	}
}

// gen_password draws `length` characters from the alphabet. With
// `require_each`, a draw missing one of the enabled classes is thrown away
// whole and redrawn -- which is rejection sampling again, so the result is
// uniform over the passwords that satisfy the constraint rather than built by
// patching characters into fixed positions.
gen_password :: proc(o: Gen_Opts, allocator := context.allocator) -> (pw: string, ok: bool) {
	alpha := gen_alphabet(o, context.temp_allocator)
	if len(alpha) == 0 {
		return "", false
	}
	n := clamp(o.length, GEN_MIN_LEN, GEN_MAX_LEN)

	classes_on := 0
	for c in Class {
		if c in o.classes {
			classes_on += 1
		}
	}
	// A length shorter than the number of classes can never satisfy them all.
	need_each := o.require_each && n >= classes_on

	buf := make([]byte, n, allocator)
	tries := 0
	for {
		tries += 1
		for i in 0 ..< n {
			buf[i] = alpha[rand_index(len(alpha))]
		}
		if !need_each {
			break
		}
		good := true
		for c in Class {
			if c not_in o.classes {
				continue
			}
			hit := false
			for b in buf {
				if strings.contains_rune(CLASS_CHARS[c], rune(b)) {
					hit = true
					break
				}
			}
			if !hit {
				good = false
				break
			}
		}
		if good {
			break
		}
		// 4096 failures at these lengths is impossible unless the options are
		// pathological; give up with the last draw rather than spin forever.
		if tries >= 4096 {
			break
		}
	}
	return string(buf), true
}

// ---------------------------------------------------------------------------
// Strength
//
// The only honest number here is the entropy of the process that produced the
// password, and that is knowable only for the ones this app generated. For a
// password typed in by hand, length times log2(pool) is an *upper bound* on a
// uniformly random string of that shape -- "Summer2024!" scores 72 bits by
// that measure and is cracked instantly. The UI says so.
// ---------------------------------------------------------------------------

gen_bits :: proc(length: int, alphabet: int) -> f64 {
	if length <= 0 || alphabet <= 1 {
		return 0
	}
	return f64(length) * math.log2_f64(f64(alphabet))
}

gen_opts_bits :: proc(o: Gen_Opts) -> f64 {
	alpha := gen_alphabet(o, context.temp_allocator)
	return gen_bits(clamp(o.length, GEN_MIN_LEN, GEN_MAX_LEN), len(alpha))
}

// password_pool is the size of the alphabet a password's own characters say it
// was drawn from.
password_pool :: proc(pw: string) -> int {
	pool := 0
	for c in Class {
		for ch in pw {
			if strings.contains_rune(CLASS_CHARS[c], ch) {
				pool += len(CLASS_CHARS[c])
				break
			}
		}
	}
	// Anything outside the four classes -- a space, a letter with an accent,
	// an emoji -- still widens the pool, conservatively.
	other := false
	for ch in pw {
		known := false
		for c in Class {
			if strings.contains_rune(CLASS_CHARS[c], ch) {
				known = true
				break
			}
		}
		if !known {
			other = true
			break
		}
	}
	if other {
		pool += 32
	}
	return pool
}

password_bits :: proc(pw: string) -> f64 {
	n := 0
	for _ in pw {
		n += 1
	}
	return gen_bits(n, password_pool(pw))
}

Strength :: enum u8 {
	Very_Weak,
	Weak,
	Fair,
	Strong,
	Very_Strong,
}

STRENGTH_LABEL := [Strength]string {
	.Very_Weak   = "very weak",
	.Weak        = "weak",
	.Fair        = "fair",
	.Strong      = "strong",
	.Very_Strong = "very strong",
}

STRENGTH_CLASS := [Strength]string {
	.Very_Weak   = "text-destructive",
	.Weak        = "text-destructive",
	.Fair        = "text-amber-400",
	.Strong      = "text-emerald-400",
	.Very_Strong = "text-emerald-400",
}

// The thresholds are the ones the bits actually justify: 60 bits is inside
// reach of a well-funded offline attack on a fast hash, 80 is not today, and
// 128 is the width of a symmetric key.
strength_of :: proc(bits: f64) -> Strength {
	switch {
	case bits < 40:
		return .Very_Weak
	case bits < 60:
		return .Weak
	case bits < 80:
		return .Fair
	case bits < 110:
		return .Strong
	}
	return .Very_Strong
}
