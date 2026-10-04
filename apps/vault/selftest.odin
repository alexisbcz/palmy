package main

// `vault --selftest`: the headless checks, and the only reason to believe any
// of this works.
//
// The published vectors come first and carry the most weight. A vault that is
// sealed and opened by the same implementation opens whether or not that
// implementation is ChaCha20-Poly1305; the RFC 8439 ciphertext is the thing
// that says it is. Likewise for Argon2id against RFC 9106, HMAC against
// RFC 4231 and TOTP against RFC 6238: those are answers somebody else
// published, and matching them is a fact rather than a round trip.
//
// Nothing here touches the real clipboard (`g_test` redirects it), the real
// vault directory (XDG_DATA_HOME is redirected to a scratch path first), or
// any other file on the machine.

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/argon2id"
import "core:crypto/hmac"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import p "palmy:."

@(private = "file")
checks: int
@(private = "file")
fails: int

@(private = "file")
ok :: proc(cond: bool, format: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.printf("FAIL  ")
		fmt.printfln(format, ..args)
	}
}

@(private = "file")
sect_name: string
@(private = "file")
sect_at: int

// section closes the previous one by printing how many assertions it carried,
// so the report says where the weight of the test actually is rather than only
// quoting one total.
@(private = "file")
section :: proc(name: string) {
	close_section()
	sect_name = name
	sect_at = checks
	fmt.printfln("\n== %s", name)
}

@(private = "file")
close_section :: proc() {
	if sect_name != "" {
		fmt.printfln("      %d checks", checks - sect_at)
	}
	sect_name = ""
}

@(private = "file")
hexstr :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, len(b) * 2, allocator)
	for v, i in b {
		out[i * 2] = digits[v >> 4]
		out[i * 2 + 1] = digits[v & 15]
	}
	return string(out)
}

// A cheap parameter set, used everywhere a check is about the file format
// rather than about the KDF. The default costs 0.6 s a derivation, and this
// file derives dozens of times. That the parameters live in the header is
// exactly what makes this possible.
@(private = "file")
KDF_FAST :: Kdf {
	m   = 64,
	t   = 1,
	par = 1,
}

SCRATCH :: "/tmp/palmy-vault-selftest"

selftest :: proc() -> int {
	g_test = true

	_ = os.remove_all(SCRATCH)
	_ = os.make_directory_all(SCRATCH, os.perm(0o700))
	_ = os.set_env("XDG_DATA_HOME", SCRATCH)

	{
		dir := data_dir(context.temp_allocator)
		ok(
			strings.has_prefix(dir, SCRATCH),
			"the self-test must never write to the real vault directory; data_dir is %s",
			dir,
		)
	}

	t_vectors_argon2id()
	t_vectors_chacha()
	t_vectors_gcm()
	t_vectors_hmac()
	t_vectors_hotp()
	t_vectors_totp()
	t_base32()
	t_constant_time()
	t_generator()
	t_header()
	t_body()
	t_roundtrip()
	t_nonce()
	t_tamper()
	t_wrong_password()
	t_rekey()
	t_ui()
	t_kdf_cost()

	// Nothing is left on the clipboard at the end of a run.
	ok(g_test_clip == "", "the test run left %d bytes on the clipboard", len(g_test_clip))
	close_section()

	fmt.printfln("\n%d checks, %d failures", checks, fails)
	return fails == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// RFC 9106: Argon2id
// ---------------------------------------------------------------------------

t_vectors_argon2id :: proc() {
	section("Argon2id against the RFC 9106 section 5.3 vector")

	password: [32]u8
	salt: [16]u8
	secret: [8]u8
	ad: [12]u8
	for i in 0 ..< 32 {password[i] = 0x01}
	for i in 0 ..< 16 {salt[i] = 0x02}
	for i in 0 ..< 8 {secret[i] = 0x03}
	for i in 0 ..< 12 {ad[i] = 0x04}

	params := argon2id.Parameters {
		memory_size = 32,
		passes      = 3,
		parallelism = 4,
	}
	got: [32]u8
	err := argon2id.derive(&params, password[:], salt[:], got[:], secret[:], ad[:])
	ok(err == nil, "argon2id.derive returned %v", err)
	ok(
		slice.equal(got[:], RFC9106_TAG[:]),
		"RFC 9106 Argon2id tag\n      want %s\n      got  %s",
		hexstr(RFC9106_TAG[:]),
		hexstr(got[:]),
	)

	// One pass more must give a different tag, or the passes parameter is
	// being ignored and the cost is a fiction.
	params.passes = 4
	other: [32]u8
	_ = argon2id.derive(&params, password[:], salt[:], other[:], secret[:], ad[:])
	ok(!slice.equal(other[:], got[:]), "raising the pass count did not change the Argon2id output")

	// derive_key, the wrapper this app actually uses, must agree with a direct
	// call at the same parameters.
	mine: [32]u8
	direct: [32]u8
	k := Kdf {
		m   = 1024,
		t   = 2,
		par = 1,
	}
	ok(derive_key("open sesame", salt[:], k, mine[:]), "derive_key failed at m=1024 t=2 p=1")
	dp := argon2id.Parameters {
		memory_size = k.m,
		passes      = k.t,
		parallelism = k.par,
	}
	_ = argon2id.derive(&dp, transmute([]u8)string("open sesame"), salt[:], direct[:])
	ok(slice.equal(mine[:], direct[:]), "derive_key does not match a direct argon2id call")

	// A header asking for parameters outside the allowed range is refused
	// rather than attempted.
	ok(!kdf_valid({m = 8, t = 0, par = 1}), "zero passes was accepted")
	ok(!kdf_valid({m = 8, t = 1, par = 0}), "zero parallelism was accepted")
	ok(!kdf_valid({m = 8, t = 1, par = 4}), "m below 8*p was accepted")
	ok(!kdf_valid({m = KDF_MAX_M + 1, t = 1, par = 1}), "an absurd memory cost was accepted")
	ok(kdf_valid(KDF_DEFAULT), "the default parameters are not considered valid")
}

// ---------------------------------------------------------------------------
// RFC 8439 section 2.8.2: ChaCha20-Poly1305
// ---------------------------------------------------------------------------

t_vectors_chacha :: proc() {
	section("ChaCha20-Poly1305 against the RFC 8439 section 2.8.2 vector")

	plain := transmute([]u8)string(RFC8439_PLAIN)
	ok(len(plain) == 114, "the RFC 8439 plaintext should be 114 bytes, got %d", len(plain))

	ct := make([]u8, len(plain), context.temp_allocator)
	tag: [16]u8
	aead.seal(
		aead.Algorithm.CHACHA20POLY1305,
		ct,
		tag[:],
		RFC8439_KEY[:],
		RFC8439_IV[:],
		RFC8439_AAD[:],
		plain,
	)
	ok(
		slice.equal(ct, RFC8439_CT[:]),
		"RFC 8439 ciphertext\n      want %s\n      got  %s",
		hexstr(RFC8439_CT[:]),
		hexstr(ct),
	)
	ok(
		slice.equal(tag[:], RFC8439_TAG[:]),
		"RFC 8439 tag\n      want %s\n      got  %s",
		hexstr(RFC8439_TAG[:]),
		hexstr(tag[:]),
	)

	// And the other direction: the published ciphertext and tag must open.
	back := make([]u8, len(RFC8439_CT), context.temp_allocator)
	good := aead.open(
		aead.Algorithm.CHACHA20POLY1305,
		back,
		RFC8439_KEY[:],
		RFC8439_IV[:],
		RFC8439_AAD[:],
		RFC8439_CT[:],
		RFC8439_TAG[:],
	)
	ok(good, "the RFC 8439 ciphertext did not authenticate")
	ok(good && string(back) == RFC8439_PLAIN, "the RFC 8439 ciphertext decrypted to the wrong plaintext")

	// A tag that is one bit out must fail.
	bad_tag := RFC8439_TAG
	bad_tag[0] ~= 0x01
	refused := !aead.open(
		aead.Algorithm.CHACHA20POLY1305,
		back,
		RFC8439_KEY[:],
		RFC8439_IV[:],
		RFC8439_AAD[:],
		RFC8439_CT[:],
		bad_tag[:],
	)
	ok(refused, "a tag with one flipped bit was accepted")

	// So must an aad that is one bit out.
	bad_aad := RFC8439_AAD
	bad_aad[0] ~= 0x80
	refused2 := !aead.open(
		aead.Algorithm.CHACHA20POLY1305,
		back,
		RFC8439_KEY[:],
		RFC8439_IV[:],
		bad_aad[:],
		RFC8439_CT[:],
		RFC8439_TAG[:],
	)
	ok(refused2, "altered additional data was accepted")
}

// ---------------------------------------------------------------------------
// NIST GCM test case 16: AES-256-GCM, the alternative cipher
// ---------------------------------------------------------------------------

t_vectors_gcm :: proc() {
	section("AES-256-GCM against NIST GCM specification test case 16")

	ct := make([]u8, len(GCM16_PLAIN), context.temp_allocator)
	tag: [16]u8
	aead.seal(
		aead.Algorithm.AES_GCM_256,
		ct,
		tag[:],
		GCM16_KEY[:],
		GCM16_IV[:],
		GCM16_AAD[:],
		GCM16_PLAIN[:],
	)
	ok(
		slice.equal(ct, GCM16_CT[:]),
		"GCM case 16 ciphertext\n      want %s\n      got  %s",
		hexstr(GCM16_CT[:]),
		hexstr(ct),
	)
	ok(
		slice.equal(tag[:], GCM16_TAG[:]),
		"GCM case 16 tag\n      want %s\n      got  %s",
		hexstr(GCM16_TAG[:]),
		hexstr(tag[:]),
	)

	back := make([]u8, len(GCM16_CT), context.temp_allocator)
	good := aead.open(
		aead.Algorithm.AES_GCM_256,
		back,
		GCM16_KEY[:],
		GCM16_IV[:],
		GCM16_AAD[:],
		GCM16_CT[:],
		GCM16_TAG[:],
	)
	ok(good, "the GCM case 16 ciphertext did not authenticate")
	ok(good && slice.equal(back, GCM16_PLAIN[:]), "the GCM case 16 ciphertext decrypted to the wrong plaintext")
}

// ---------------------------------------------------------------------------
// RFC 4231: HMAC-SHA-1 and HMAC-SHA-256
// ---------------------------------------------------------------------------

t_vectors_hmac :: proc() {
	section("HMAC against the RFC 4231 vectors")

	for v in hmac_vectors() {
		if v.sha1 != "" {
			mac1: [20]u8
			hmac.sum(.Insecure_SHA1, mac1[:], v.data, v.key)
			ok(
				hexstr(mac1[:]) == v.sha1,
				"%s HMAC-SHA-1\n      want %s\n      got  %s",
				v.name,
				v.sha1,
				hexstr(mac1[:]),
			)
		}
		if v.sha256 != "" {
			mac256: [32]u8
			hmac.sum(.SHA256, mac256[:], v.data, v.key)
			ok(
				hexstr(mac256[:]) == v.sha256,
				"%s HMAC-SHA-256\n      want %s\n      got  %s",
				v.name,
				v.sha256,
				hexstr(mac256[:]),
			)
		}
	}

	// HMAC-SHA-512 too, since the TOTP SHA-512 vectors rely on it:
	// RFC 4231 case 2, key "Jefe".
	{
		mac: [64]u8
		hmac.sum(
			.SHA512,
			mac[:],
			transmute([]u8)string("what do ya want for nothing?"),
			transmute([]u8)string("Jefe"),
		)
		want :=
			"164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554" +
			"9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"
		ok(hexstr(mac[:]) == want, "RFC 4231 case 2 HMAC-SHA-512\n      want %s\n      got  %s", want, hexstr(mac[:]))
	}
}

// ---------------------------------------------------------------------------
// RFC 4226 appendix D: HOTP
// ---------------------------------------------------------------------------

t_vectors_hotp :: proc() {
	section("HOTP against the RFC 4226 appendix D vectors")

	seed := transmute([]u8)string(RFC6238_SEED_SHA1)
	for want, counter in RFC4226_HOTP {
		got := totp_format(hotp(seed, u64(counter), 6, .SHA1), 6)
		ok(got == want, "HOTP counter %d\n      want %s\n      got  %s", counter, want, got)
	}
}

// ---------------------------------------------------------------------------
// RFC 6238 appendix B: TOTP
// ---------------------------------------------------------------------------

t_vectors_totp :: proc() {
	section("TOTP against the RFC 6238 appendix B vectors")

	s1 := transmute([]u8)string(RFC6238_SEED_SHA1)
	s256 := transmute([]u8)string(RFC6238_SEED_SHA256)
	s512 := transmute([]u8)string(RFC6238_SEED_SHA512)
	ok(len(s1) == 20 && len(s256) == 32 && len(s512) == 64, "the RFC 6238 seeds are the wrong lengths")

	for v in RFC6238_VECTORS {
		g1 := totp_format(totp_at(s1, v.unix_s, 30, 8, .SHA1), 8)
		ok(g1 == v.sha1, "TOTP SHA1 at T=%d\n      want %s\n      got  %s", v.unix_s, v.sha1, g1)

		g2 := totp_format(totp_at(s256, v.unix_s, 30, 8, .SHA256), 8)
		ok(g2 == v.sha256, "TOTP SHA256 at T=%d\n      want %s\n      got  %s", v.unix_s, v.sha256, g2)

		g3 := totp_format(totp_at(s512, v.unix_s, 30, 8, .SHA512), 8)
		ok(g3 == v.sha512, "TOTP SHA512 at T=%d\n      want %s\n      got  %s", v.unix_s, v.sha512, g3)
	}

	// The counters the RFC prints alongside those timestamps.
	ok(totp_counter(59, 30) == 1, "T=59 should be step 1, got %d", totp_counter(59, 30))
	ok(totp_counter(1111111109, 30) == 0x23523EC, "T=1111111109 should be step 0x23523EC")
	ok(totp_counter(20000000000, 30) == 0x27BC86AA, "T=20000000000 should be step 0x27BC86AA")

	// And the countdown that drives the ring in the UI.
	ok(totp_remaining(0, 30) == 30, "0 s into the epoch should have 30 s left")
	ok(totp_remaining(59, 30) == 1, "T=59 should have 1 s left, got %d", totp_remaining(59, 30))
	ok(totp_remaining(60, 30) == 30, "T=60 should start a fresh step")

	// The end-to-end path the UI calls, through base32.
	b32 := base32_encode(s1, context.temp_allocator)
	code, cok := totp_code(b32, 59, 30, 8, .SHA1, context.temp_allocator)
	ok(cok && code == "94287082", "totp_code through base32 gave %q", code)

	// A six-digit code is the eight-digit one modulo a million, zero-padded.
	six, _ := totp_code(b32, 1111111109, 30, 6, .SHA1, context.temp_allocator)
	ok(six == "081804", "six-digit TOTP at T=1111111109 should be 081804, got %q", six)
}

// ---------------------------------------------------------------------------
// base32
// ---------------------------------------------------------------------------

t_base32 :: proc() {
	section("base32")

	// RFC 4648 section 10.
	for pair in ([?][2]string {
		{"f", "MY"},
		{"fo", "MZXQ"},
		{"foo", "MZXW6"},
		{"foob", "MZXW6YQ"},
		{"fooba", "MZXW6YTB"},
		{"foobar", "MZXW6YTBOI"},
	}) {
		got := base32_encode(transmute([]u8)pair[0], context.temp_allocator)
		ok(got == pair[1], "base32(%q) should be %s, got %s", pair[0], pair[1], got)
		back, bok := base32_decode(pair[1], context.temp_allocator)
		ok(bok && string(back) == pair[0], "base32 decode of %s gave %q", pair[1], string(back))
	}

	// What an authenticator app actually hands you: lowercase, spaces, dashes
	// and padding.
	a, aok := base32_decode("mzxw 6ytb-OI==", context.temp_allocator)
	ok(aok && string(a) == "foobar", "a messy but valid base32 secret did not decode")

	// A character outside the alphabet is an error, not something to skip.
	_, bad := base32_decode("MZXW6YTB!", context.temp_allocator)
	ok(!bad, "base32 accepted a character outside the alphabet")
	_, bad2 := base32_decode("MZXW6Y18", context.temp_allocator)
	ok(!bad2, "base32 accepted the digits 0 and 1, which are not in the alphabet")

	ok(totp_secret_ok(""), "an empty TOTP secret should be allowed")
	ok(!totp_secret_ok("MY"), "a two-character secret is too short to be a TOTP seed")
	ok(totp_secret_ok(base32_encode(transmute([]u8)string(RFC6238_SEED_SHA1), context.temp_allocator)), "the RFC 6238 seed was rejected")
}

// ---------------------------------------------------------------------------
// Constant-time comparison
// ---------------------------------------------------------------------------

t_constant_time :: proc() {
	section("constant-time comparison")

	a := transmute([]u8)string("correct horse battery staple")
	b := transmute([]u8)string("correct horse battery staple")
	c := transmute([]u8)string("correct horse battery stapld")
	ok(crypto.compare_constant_time(a, b) == 1, "two equal secrets did not compare equal")
	ok(crypto.compare_constant_time(a, c) == 0, "two different secrets compared equal")

	ok(secret_eq("hunter2hunter2", "hunter2hunter2"), "secret_eq rejected two equal strings")
	ok(!secret_eq("hunter2hunter2", "hunter2hunter3"), "secret_eq accepted two different strings")
	ok(!secret_eq("short", "shorter"), "secret_eq accepted strings of different length")
	ok(secret_eq("", ""), "secret_eq rejected two empty strings")
}

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

t_generator :: proc() {
	section("the password generator")

	o := Gen_Opts {
		length       = 24,
		classes      = {.Lower, .Upper, .Digits, .Symbols},
		require_each = true,
	}
	alpha := gen_alphabet(o, context.temp_allocator)
	ok(len(alpha) == 26 + 26 + 10 + 28, "the full alphabet should be 90 characters, got %d", len(alpha))

	// Successive generations differ. Thirty-two identical draws from 90^24
	// would be a broken random source, not luck.
	seen := make(map[string]bool, context.temp_allocator)
	bad_len, failed := 0, 0
	for _ in 0 ..< 32 {
		pw, good := gen_password(o, context.temp_allocator)
		if !good {
			failed += 1
		}
		if len(pw) != 24 {
			bad_len += 1
		}
		seen[pw] = true
	}
	ok(failed == 0, "gen_password failed %d times out of 32", failed)
	ok(bad_len == 0, "%d of 32 passwords were not 24 characters long", bad_len)
	ok(len(seen) == 32, "32 draws produced only %d distinct passwords", len(seen))

	// Every requested class present in every draw.
	missing: [Class]int
	for _ in 0 ..< 64 {
		pw, _ := gen_password(o, context.temp_allocator)
		for c in Class {
			hit := false
			for ch in pw {
				if strings.contains_rune(CLASS_CHARS[c], ch) {
					hit = true
					break
				}
			}
			if !hit {
				missing[c] += 1
			}
		}
	}
	for c in Class {
		ok(missing[c] == 0, "%d of 64 generated passwords had no %s character", missing[c], CLASS_LABEL[c])
	}

	// Ambiguous characters really are excluded.
	o2 := o
	o2.no_ambiguous = true
	a2 := gen_alphabet(o2, context.temp_allocator)
	ok(len(a2) == len(alpha) - 6, "excluding Il1O0o should drop six characters, got %d", len(alpha) - len(a2))
	leaked := 0
	for _ in 0 ..< 32 {
		pw, _ := gen_password(o2, context.temp_allocator)
		for ch in pw {
			if strings.contains_rune(AMBIGUOUS, ch) {
				leaked += 1
			}
		}
	}
	ok(leaked == 0, "%d ambiguous characters survived the exclusion", leaked)

	// ----------------------------------------------------------------------
	// The distribution.
	//
	// `rand_bytes() % 90` would make the first 76 characters of the alphabet
	// come up three times per 256 draws and the last 14 only twice -- a 50%
	// excess on most of the alphabet. Rejection sampling does not. 600,000
	// characters over 90 bins puts 6,667 in each, with a standard deviation
	// of 81; a 10% tolerance is eight sigma, so this check does not flake and
	// would still have caught the modulo.
	// ----------------------------------------------------------------------
	flat := Gen_Opts {
		length       = 100,
		classes      = {.Lower, .Upper, .Digits, .Symbols},
		require_each = false,
	}
	SAMPLES :: 6000 // x 100 characters
	counts := make(map[u8]int, context.temp_allocator)
	total := 0
	for _ in 0 ..< SAMPLES {
		pw, _ := gen_password(flat, context.temp_allocator)
		for b in transmute([]u8)pw {
			counts[b] += 1
			total += 1
		}
	}
	ok(total == SAMPLES * 100, "expected %d characters, counted %d", SAMPLES * 100, total)
	ok(len(counts) == len(alpha), "only %d of %d alphabet characters ever appeared", len(counts), len(alpha))

	expected := f64(total) / f64(len(alpha))
	worst := 0.0
	worst_ch: u8
	chi2 := 0.0
	for ch in transmute([]u8)alpha {
		n := f64(counts[ch])
		d := abs(n - expected) / expected
		chi2 += (n - expected) * (n - expected) / expected
		if d > worst {
			worst = d
			worst_ch = ch
		}
	}
	ok(
		worst < 0.10,
		"the character distribution is not flat: %q is %.1f%% off the mean (expected %.0f)",
		rune(worst_ch),
		worst * 100,
		expected,
	)
	// 89 degrees of freedom: chi-square beyond ~160 is a one-in-a-million
	// event under a uniform draw, and the modulo bug scores in the thousands.
	ok(chi2 < 160, "chi-square over the alphabet is %.1f, which is not a uniform draw", chi2)
	fmt.printfln(
		"      %d characters over %d bins: worst bin %.2f%% off the mean, chi-square %.1f on 89 d.f.",
		total,
		len(alpha),
		worst * 100,
		chi2,
	)

	// rand_index itself, at a size that divides 256 and one that does not.
	for n in ([?]int{2, 16, 90, 94, 255, 256}) {
		lo, hi, out_of_range := 1 << 30, -1, 0
		for _ in 0 ..< 20000 {
			v := rand_index(n)
			if v < 0 || v >= n {
				out_of_range += 1
			}
			lo = min(lo, v)
			hi = max(hi, v)
		}
		ok(out_of_range == 0, "rand_index(%d) went outside [0,%d) %d times", n, n, out_of_range)
		ok(lo == 0, "rand_index(%d) never returned 0", n)
		ok(hi == n - 1, "rand_index(%d) never returned %d", n, n - 1)
	}

	// Entropy: a uniform draw of n characters from an alphabet of a is
	// exactly n*log2(a) bits, so the number beside a generated password is a
	// fact and not an estimate.
	ok(abs(gen_bits(20, 64) - 120.0) < 1e-9, "20 characters from 64 should be exactly 120 bits")
	ok(abs(gen_bits(24, 90) - 155.8045) < 0.001, "24 characters from 90 should be 155.8045 bits, got %.4f", gen_bits(24, 90))
	ok(password_pool("abc") == 26, "a lowercase-only password should score a pool of 26")
	ok(password_pool("abc123") == 36, "lowercase and digits should score a pool of 36")
	ok(password_pool("Abc123!") == 90, "all four classes should score a pool of 90")
	ok(strength_of(password_bits("password")) == .Very_Weak, "an eight-letter lowercase password should be very weak")
	ok(strength_of(gen_opts_bits(GEN_DEFAULT)) == .Very_Strong, "the default generator settings should be very strong")

	// The smallest allowed alphabet still works, and a length below the class
	// count does not spin forever trying to satisfy them all.
	tiny := Gen_Opts {
		length       = 6,
		classes      = {.Digits},
		require_each = true,
	}
	pw, tok := gen_password(tiny, context.temp_allocator)
	ok(tok && len(pw) == 6, "a digits-only password did not generate")
	short := Gen_Opts {
		length       = 6,
		classes      = {.Lower, .Upper, .Digits, .Symbols},
		require_each = true,
	}
	pw2, sok := gen_password(short, context.temp_allocator)
	ok(sok && len(pw2) == 6, "a six-character password with four classes required did not generate")
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

t_header :: proc() {
	section("the vault header")

	h := Header {
		version = FORMAT_VERSION,
		kdf_id  = KDF_ARGON2ID,
		aead_id = .ChaCha20Poly1305,
		kdf     = KDF_DEFAULT,
		flags   = 0,
		ct_len  = 8192,
	}
	for i in 0 ..< SALT_LEN {h.salt[i] = u8(i + 1)}
	for i in 0 ..< NONCE_LEN {h.nonce[i] = u8(0xa0 + i)}
	for i in 0 ..< TAG_LEN {h.tag[i] = u8(0x50 + i)}

	raw := make([]u8, HEADER_LEN + 8192, context.temp_allocator)
	header_encode(h, raw)
	ok(string(raw[0:8]) == MAGIC, "the magic is not at the front of the file")

	back, err := header_decode(raw)
	ok(err == "", "header_decode of a header this build wrote failed: %s", err)
	ok(back.version == h.version, "the version did not survive the round trip")
	ok(back.aead_id == h.aead_id, "the cipher id did not survive the round trip")
	ok(back.kdf == h.kdf, "the KDF parameters did not survive the round trip")
	ok(slice.equal(back.salt[:], h.salt[:]), "the salt did not survive the round trip")
	ok(slice.equal(back.nonce[:], h.nonce[:]), "the nonce did not survive the round trip")
	ok(slice.equal(back.tag[:], h.tag[:]), "the tag did not survive the round trip")
	ok(back.ct_len == h.ct_len, "the length did not survive the round trip")

	// Rejections that happen before a key is ever derived.
	short := raw[:HEADER_LEN - 1]
	_, e1 := header_decode(short)
	ok(e1 != "", "a file shorter than the header was accepted")

	wrong := slice.clone(raw, context.temp_allocator)
	wrong[0] = 'X'
	_, e2 := header_decode(wrong)
	ok(e2 != "", "a file with the wrong magic was accepted")

	newer := slice.clone(raw, context.temp_allocator)
	put_u16le(newer[8:10], FORMAT_VERSION + 1)
	_, e3 := header_decode(newer)
	ok(e3 != "", "a file claiming a newer format version was accepted")

	odd := slice.clone(raw, context.temp_allocator)
	odd[11] = 99
	_, e4 := header_decode(odd)
	ok(e4 != "", "a file naming an unknown cipher was accepted")

	huge := slice.clone(raw, context.temp_allocator)
	put_u32le(huge[12:16], KDF_MAX_M + 1)
	_, e5 := header_decode(huge)
	ok(e5 != "", "a file demanding an absurd amount of memory was accepted")

	lied := slice.clone(raw, context.temp_allocator)
	put_u64le(lied[56:64], 123)
	_, e6 := header_decode(lied)
	ok(e6 != "", "a file whose recorded length disagrees with its size was accepted")
}

// ---------------------------------------------------------------------------
// The body
// ---------------------------------------------------------------------------

t_body :: proc() {
	section("the vault body")

	v := Vault {
		entries = make([dynamic]Entry),
	}
	defer vault_free(&v)

	e := entry_new("Example Mail")
	replace_string(&e.username, "sample.user@example.com")
	replace_string(&e.url, "https://mail.example.com")
	replace_secret(&e.notes, "a note with a comma, a \"quote\" and a newline\nin it")
	entry_set_tags(&e, "email, sample, email")
	replace_secret(&e.totp, base32_encode(transmute([]u8)string(RFC6238_SEED_SHA1), context.temp_allocator))
	e.totp_digits = 8
	e.totp_algo = .SHA256
	entry_set_password(&e, "first-password-aaaa")
	entry_set_password(&e, "second-password-bbb")
	entry_set_password(&e, "third-password-cccc")
	append(&v.entries, e)

	ok(len(v.entries[0].tags) == 2, "a duplicate tag should be folded, got %d", len(v.entries[0].tags))
	ok(len(v.entries[0].history) == 2, "two rotations should leave two history rows, got %d", len(v.entries[0].history))

	empty := entry_new("Nothing Here")
	append(&v.entries, empty)

	plain := body_encode(&v, context.temp_allocator)
	ok(len(plain) % PAD_TO == 0, "the plaintext is not padded to a %d-byte boundary: %d", PAD_TO, len(plain))
	ok(string(plain[4:8]) == BODY_MAGIC, "the body magic is missing")

	back, err := body_decode(plain)
	ok(err == "", "body_decode failed: %s", err)
	defer vault_free(&back)

	ok(len(back.entries) == 2, "two entries in, %d out", len(back.entries))
	if len(back.entries) == 2 {
		a := &back.entries[0]
		ok(a.title == "Example Mail", "the title did not survive: %q", a.title)
		ok(a.username == "sample.user@example.com", "the username did not survive")
		ok(a.password == "third-password-cccc", "the password did not survive")
		ok(a.url == "https://mail.example.com", "the url did not survive")
		ok(strings.contains(a.notes, "\"quote\""), "the notes lost their quotes")
		ok(strings.contains(a.notes, "\n"), "the notes lost their newline")
		ok(len(a.tags) == 2 && a.tags[0] == "email", "the tags did not survive: %v", a.tags)
		ok(a.totp_digits == 8 && a.totp_algo == .SHA256, "the TOTP settings did not survive")
		ok(len(a.history) == 2, "the history did not survive: %d rows", len(a.history))
		ok(len(a.history) == 2 && a.history[0].password == "first-password-aaaa", "the history is in the wrong order")
		ok(a.created > 0 && a.modified >= a.created, "the timestamps are wrong")
	}

	// A truncated or scrambled plaintext is an error, not a half-built vault.
	_, e1 := body_decode(plain[:4])
	ok(e1 != "", "a truncated body was accepted")
	chopped := slice.clone(plain, context.temp_allocator)
	put_u32le(chopped[0:4], u32(len(plain)))
	_, e2 := body_decode(chopped)
	ok(e2 != "", "a body claiming to be longer than the plaintext was accepted")
	lying := slice.clone(plain, context.temp_allocator)
	lying[4] = 'Q'
	_, e3 := body_decode(lying)
	ok(e3 != "", "a body with the wrong magic was accepted")
	// A truncation inside the entry list, with the length word adjusted to
	// match, must be caught by the reader's bounds checks.
	cut := slice.clone(plain[:4 + 64], context.temp_allocator)
	put_u32le(cut[0:4], 60)
	_, e4 := body_decode(cut)
	ok(e4 != "", "a body cut off inside an entry was accepted")

	// Padding hides the size. Adding one short entry must not change the
	// ciphertext length until a whole block is crossed.
	v2 := Vault {
		entries = make([dynamic]Entry),
	}
	defer vault_free(&v2)
	append(&v2.entries, entry_new("One"))
	a := body_encode(&v2, context.temp_allocator)
	append(&v2.entries, entry_new("Two"))
	b := body_encode(&v2, context.temp_allocator)
	ok(len(a) == len(b), "adding a second small entry changed the sealed length from %d to %d", len(a), len(b))
}

// ---------------------------------------------------------------------------
// A vault round trip, on disk
// ---------------------------------------------------------------------------

@(private = "file")
sample_vault :: proc() -> Vault {
	v := Vault {
		entries = make([dynamic]Entry),
	}
	for title in ([?]string{"Example Mail", "Example Bank", "Example Forge"}) {
		e := entry_new(title)
		replace_string(&e.username, "sample-user")
		pw, _ := gen_password(GEN_DEFAULT, context.temp_allocator)
		entry_set_password(&e, pw)
		entry_set_tags(&e, "sample")
		append(&v.entries, e)
	}
	return v
}

PASS :: "a-generated-master-for-the-test-9f2c"
PASS2 :: "a-different-generated-master-4ab1"

t_roundtrip :: proc() {
	section("a vault round trip on disk")

	path := fmt.tprintf("%s/roundtrip.pvz", SCRATCH)
	sess, ok1 := session_new(PASS, KDF_FAST)
	ok(ok1, "session_new failed")
	defer session_zero(&sess)

	v := sample_vault()
	defer vault_free(&v)
	err := store_save(path, &v, &sess)
	ok(err == "", "store_save failed: %s", err)
	ok(os.exists(path), "the vault file was not created")

	// 0600, so no other account on the machine can read it.
	if st, serr := os.stat(path, context.temp_allocator); serr == nil {
		mode := transmute(u32)st.mode
		ok(mode & 0o077 == 0, "the vault file is mode %o, which is readable by somebody else", mode & 0o777)
	}

	// The ciphertext must not contain any plaintext that went into it.
	raw, _ := os.read_entire_file(path, context.temp_allocator)
	ok(len(raw) > HEADER_LEN, "the vault file is too short")
	ok(!strings.contains(string(raw), "Example Mail"), "an entry title is legible in the sealed file")
	ok(!strings.contains(string(raw), v.entries[0].password), "a password is legible in the sealed file")
	ok(!strings.contains(string(raw), "sample-user"), "a username is legible in the sealed file")

	back, sess2, lerr := store_load(path, PASS)
	ok(lerr == "", "store_load failed: %s", lerr)
	defer vault_free(&back)
	defer session_zero(&sess2)
	ok(sess2.kdf == KDF_FAST, "the KDF parameters were not read back out of the header")
	ok(len(back.entries) == len(v.entries), "%d entries in, %d out", len(v.entries), len(back.entries))
	same := true
	for e, i in back.entries {
		if i >= len(v.entries) {
			break
		}
		if e.title != v.entries[i].title || e.password != v.entries[i].password {
			same = false
		}
	}
	ok(same, "an entry did not survive the round trip")

	// store_create makes an empty vault that opens.
	cpath := fmt.tprintf("%s/created.pvz", SCRATCH)
	csess, cerr := store_create(cpath, PASS, KDF_FAST)
	ok(cerr == "", "store_create failed: %s", cerr)
	defer session_zero(&csess)
	cv, csess2, clerr := store_load(cpath, PASS)
	ok(clerr == "", "a freshly created vault did not open: %s", clerr)
	ok(len(cv.entries) == 0, "a freshly created vault is not empty")
	vault_free(&cv)
	session_zero(&csess2)

	// AES-256-GCM is the other cipher the format allows, and a vault written
	// with it must open from the header alone.
	gpath := fmt.tprintf("%s/gcm.pvz", SCRATCH)
	gsess, gerr := store_create(gpath, PASS, KDF_FAST, .Aes256Gcm)
	ok(gerr == "", "store_create with AES-256-GCM failed: %s", gerr)
	gv := sample_vault()
	ok(store_save(gpath, &gv, &gsess) == "", "saving an AES-256-GCM vault failed")
	gback, gsess2, glerr := store_load(gpath, PASS)
	ok(glerr == "", "an AES-256-GCM vault did not open: %s", glerr)
	ok(gsess2.algo == .Aes256Gcm, "the cipher was not read back out of the header")
	ok(len(gback.entries) == 3, "the AES-256-GCM vault lost entries")
	vault_free(&gv)
	vault_free(&gback)
	session_zero(&gsess)
	session_zero(&gsess2)

	// session_zero really zeroes.
	z, _ := session_new(PASS, KDF_FAST)
	nonzero := false
	for b in z.key {
		if b != 0 {
			nonzero = true
		}
	}
	ok(nonzero, "a derived key is all zeroes, which cannot be right")
	session_zero(&z)
	all_zero := true
	for b in z.key {
		if b != 0 {
			all_zero = false
		}
	}
	ok(all_zero, "session_zero left key material behind")
	ok(!z.unlocked, "session_zero left the session marked unlocked")
	{
		blob, serr := vault_seal(transmute([]u8)string("x"), &z, context.temp_allocator)
		ok(blob == nil && serr != "", "a zeroed session still sealed something")
	}
}

// ---------------------------------------------------------------------------
// Nonce uniqueness
// ---------------------------------------------------------------------------

t_nonce :: proc() {
	section("a fresh nonce for every save")

	path := fmt.tprintf("%s/nonce.pvz", SCRATCH)
	sess, _ := session_new(PASS, KDF_FAST)
	defer session_zero(&sess)
	v := sample_vault()
	defer vault_free(&v)

	// Two saves of the identical vault under the identical key.
	ok(store_save(path, &v, &sess) == "", "the first save failed")
	a, _ := os.read_entire_file(path, context.temp_allocator)
	ok(store_save(path, &v, &sess) == "", "the second save failed")
	b, _ := os.read_entire_file(path, context.temp_allocator)

	ha, _ := header_decode(a)
	hb, _ := header_decode(b)

	ok(slice.equal(ha.salt[:], hb.salt[:]), "the salt changed between two saves; the key would have to be re-derived")
	ok(
		!slice.equal(ha.nonce[:], hb.nonce[:]),
		"two consecutive saves reused the nonce %s -- under a fixed key that breaks the cipher outright",
		hexstr(ha.nonce[:]),
	)
	ok(
		!slice.equal(a[HEADER_LEN:], b[HEADER_LEN:]),
		"two saves of the same vault produced identical ciphertext",
	)
	ok(!slice.equal(ha.tag[:], hb.tag[:]), "two saves of the same vault produced identical tags")
	ok(len(a) == len(b), "two saves of the same vault produced different lengths")

	// And at scale: 256 nonces, all distinct.
	seen := make(map[string]bool, context.temp_allocator)
	for i in 0 ..< 256 {
		ok(store_save(path, &v, &sess) == "", "save %d failed", i)
		raw, _ := os.read_entire_file(path, context.temp_allocator)
		h, _ := header_decode(raw)
		key := hexstr(h.nonce[:])
		if key in seen {
			ok(false, "nonce %s was used twice in 256 saves", key)
			break
		}
		seen[key] = true
	}
	ok(len(seen) == 256, "only %d distinct nonces in 256 saves", len(seen))

	// A nonce from the OS CSPRNG, not a counter: 12 zero bytes would mean
	// rand_bytes never ran.
	raw, _ := os.read_entire_file(path, context.temp_allocator)
	h, _ := header_decode(raw)
	ok(crypto.is_zero_constant_time(h.nonce[:]) == 0, "the nonce is all zeroes")
}

// ---------------------------------------------------------------------------
// Tampering
// ---------------------------------------------------------------------------

t_tamper :: proc() {
	section("a tampered vault is refused")

	path := strings.clone(fmt.tprintf("%s/tamper.pvz", SCRATCH))
	sess, _ := session_new(PASS, KDF_FAST)
	defer session_zero(&sess)
	v := sample_vault()
	defer vault_free(&v)
	ok(store_save(path, &v, &sess) == "", "the save failed")

	good, _ := os.read_entire_file(path, context.allocator)
	defer delete(good)

	// The baseline: untouched, it opens.
	{
		plain, _, err := vault_unseal_key(good, sess.key[:], context.temp_allocator)
		ok(err == "" && plain != nil, "the untouched vault did not open: %s", err)
	}

	flip :: proc(src: []u8, at: int) -> []u8 {
		c := slice.clone(src, context.temp_allocator)
		c[at] ~= 0x01
		return c
	}

	// 1. One byte of ciphertext.
	{
		bad := flip(good, HEADER_LEN + len(good) / 2)
		plain, _, err := vault_unseal_key(bad, sess.key[:], context.temp_allocator)
		ok(err != "", "a vault with one flipped ciphertext byte was accepted")
		ok(plain == nil, "a vault with one flipped ciphertext byte returned a plaintext anyway")
	}

	// 2. One byte of the tag.
	{
		bad := flip(good, AAD_LEN)
		plain, _, err := vault_unseal_key(bad, sess.key[:], context.temp_allocator)
		ok(err != "", "a vault with one flipped tag byte was accepted")
		ok(plain == nil, "a vault with one flipped tag byte returned a plaintext anyway")
	}

	// 3. One byte of the header -- the reserved flags word, which no format
	//    check looks at and which does not feed the KDF. If it were not part
	//    of the additional authenticated data, this would open cleanly.
	{
		bad := flip(good, 24)
		h, herr := header_decode(bad)
		ok(herr == "", "the flags word should pass the format checks, so this proves the AAD binds it")
		ok(h.flags == 1, "the flipped flags word did not reach the header")
		plain, _, err := vault_unseal_key(bad, sess.key[:], context.temp_allocator)
		ok(err != "", "a vault with an altered header flags word was accepted")
		ok(plain == nil, "a vault with an altered header returned a plaintext anyway")
	}

	// 4. One byte of the nonce, which is also header.
	{
		bad := flip(good, 44)
		plain, _, err := vault_unseal_key(bad, sess.key[:], context.temp_allocator)
		ok(err != "", "a vault with an altered nonce was accepted")
		ok(plain == nil, "a vault with an altered nonce returned a plaintext anyway")
	}

	// 5. One byte of the salt. This one changes the derived key as well, so it
	//    is checked through the password path.
	{
		bad := flip(good, 28)
		bpath := strings.clone(fmt.tprintf("%s/tamper-salt.pvz", SCRATCH))
		_ = os.write_entire_file(bpath, bad)
		_, _, err := store_load(bpath, PASS)
		ok(err != "", "a vault with an altered salt was accepted")
	}

	// 6. One byte of the recorded KDF memory cost.
	{
		bad := flip(good, 12)
		plain, _, err := vault_unseal_key(bad, sess.key[:], context.temp_allocator)
		ok(err != "", "a vault with an altered memory cost was accepted")
		ok(plain == nil, "a vault with an altered memory cost returned a plaintext anyway")
	}

	// 7. Truncation: the last byte removed.
	{
		bad := slice.clone(good[:len(good) - 1], context.temp_allocator)
		_, _, err := vault_unseal_key(bad, sess.key[:], context.temp_allocator)
		ok(err != "", "a truncated vault was accepted")
	}

	// 8. Every single byte of the whole file, one at a time. There is no byte
	//    of a vault that can be changed without this being noticed.
	refused := 0
	scratch := slice.clone(good, context.allocator)
	defer delete(scratch)
	for i in 0 ..< len(good) {
		copy(scratch, good)
		scratch[i] ~= 0x80
		plain, _, err := vault_unseal_key(scratch, sess.key[:], context.allocator)
		if err != "" && plain == nil {
			refused += 1
		}
		if plain != nil {
			delete(plain)
		}
	}
	ok(
		refused == len(good),
		"only %d of %d single-byte alterations were refused",
		refused,
		len(good),
	)
	fmt.printfln("      all %d single-byte alterations of the file were refused", len(good))

	// The file on disk was never modified by any of that.
	after, _ := os.read_entire_file(path, context.temp_allocator)
	ok(slice.equal(after, good), "the tamper checks modified the vault on disk")
}

// ---------------------------------------------------------------------------
// The wrong master password
// ---------------------------------------------------------------------------

t_wrong_password :: proc() {
	section("the wrong master password is refused")

	path := fmt.tprintf("%s/wrong.pvz", SCRATCH)
	sess, _ := session_new(PASS, KDF_FAST)
	v := sample_vault()
	ok(store_save(path, &v, &sess) == "", "the save failed")
	session_zero(&sess)
	vault_free(&v)

	for bad in ([?]string {
		PASS2,
		"",
		"a-generated-master-for-the-test-9f2",  // one character short
		"a-generated-master-for-the-test-9f2d", // one character different
		"A-generated-master-for-the-test-9f2c", // case
		"a-generated-master-for-the-test-9f2c ", // a trailing space
	}) {
		_, s, err := store_load(path, bad)
		ok(err != "", "the vault opened with the wrong password %q", bad)
		ok(!s.unlocked, "a failed unlock left the session marked unlocked")
	}

	// And the right one still works afterwards.
	back, s, err := store_load(path, PASS)
	ok(err == "", "the vault did not open with the right password after six failures: %s", err)
	ok(len(back.entries) == 3, "the vault lost entries")
	vault_free(&back)
	session_zero(&s)
}

// ---------------------------------------------------------------------------
// Changing the master password, including an interrupted change
// ---------------------------------------------------------------------------

t_rekey :: proc() {
	section("changing the master password")

	path := fmt.tprintf("%s/rekey.pvz", SCRATCH)
	sess, _ := session_new(PASS, KDF_FAST)
	v := sample_vault()
	first_password := strings.clone(v.entries[0].password)
	defer delete(first_password)
	ok(store_save(path, &v, &sess) == "", "the save failed")
	before, _ := os.read_entire_file(path, context.temp_allocator)
	h_before, _ := header_decode(before)

	// ----------------------------------------------------------------------
	// Interrupted: the replacement file is written and fsynced, and the
	// process dies before the rename. The vault that is there must be exactly
	// the vault that was there, and must still open with the old password.
	// ----------------------------------------------------------------------
	g_fail_rename = true
	_, rerr := store_rekey(path, &v, &sess, PASS2)
	g_fail_rename = false
	ok(rerr != "", "the interrupted rekey reported success")

	after, _ := os.read_entire_file(path, context.temp_allocator)
	ok(slice.equal(before, after), "an interrupted master-password change modified the vault in place")

	h_after, _ := header_decode(after)
	ok(slice.equal(h_before.salt[:], h_after.salt[:]), "the interrupted change replaced the salt")

	old_v, old_s, oerr := store_load(path, PASS)
	ok(oerr == "", "after an interrupted change the vault no longer opens with the old password: %s", oerr)
	ok(len(old_v.entries) == 3, "after an interrupted change the vault lost entries")
	ok(
		len(old_v.entries) == 3 && old_v.entries[0].password == first_password,
		"after an interrupted change an entry's password changed",
	)
	vault_free(&old_v)
	session_zero(&old_s)

	// The new password must not work, because the new file was never moved
	// into place.
	_, _, nerr := store_load(path, PASS2)
	ok(nerr != "", "the new password opened the vault although the change was interrupted")

	// The leftover temporary file is a sibling, not the vault.
	tmp := temp_path_of(path, context.temp_allocator)
	ok(os.exists(tmp), "the interrupted change left no temporary file, so it was not interrupted where expected")
	ok(tmp != path, "the temporary file and the vault are the same path")
	_ = os.remove(tmp)

	// ----------------------------------------------------------------------
	// Completed.
	// ----------------------------------------------------------------------
	fresh, err := store_rekey(path, &v, &sess, PASS2)
	ok(err == "", "the master-password change failed: %s", err)
	session_zero(&sess)
	defer session_zero(&fresh)

	now_raw, _ := os.read_entire_file(path, context.temp_allocator)
	h_now, _ := header_decode(now_raw)
	ok(!slice.equal(h_before.salt[:], h_now.salt[:]), "the master-password change reused the salt")
	ok(h_now.kdf == KDF_DEFAULT, "the master-password change did not move the vault to the current KDF parameters")

	_, _, old_err := store_load(path, PASS)
	ok(old_err != "", "the old master password still opens the vault")

	back, s2, err2 := store_load(path, PASS2)
	ok(err2 == "", "the vault does not open with the new master password: %s", err2)
	ok(len(back.entries) == 3, "the re-encrypted vault lost entries")
	ok(
		len(back.entries) == 3 && back.entries[0].password == first_password,
		"the re-encrypted vault changed an entry's password",
	)
	vault_free(&back)
	session_zero(&s2)
	vault_free(&v)
}

// ---------------------------------------------------------------------------
// The UI, through palmy's offscreen renderer
// ---------------------------------------------------------------------------

@(private = "file")
drive :: proc(off: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(off)
	frame(ui, nil, st)
	p.offscreen_end(off)
}

t_ui :: proc() {
	section("the application, driven headless")

	path := strings.clone(fmt.tprintf("%s/ui.pvz", SCRATCH))
	// Build a vault the UI can open: fake entries, generated passwords, the
	// public RFC 6238 seed for the TOTP.
	{
		sess, _ := session_new(PASS, KDF_FAST)
		v := Vault {
			entries = make([dynamic]Entry),
		}
		seed := base32_encode(transmute([]u8)string(RFC6238_SEED_SHA1), context.temp_allocator)
		for spec in ([?][3]string {
			{"Example Forge", "sample-dev", "work"},
			{"Example Mail", "sample.user@example.com", "email"},
			{"Example Bank", "sample-00417", "finance"},
		}) {
			e := entry_new(spec[0])
			replace_string(&e.username, spec[1])
			entry_set_tags(&e, spec[2])
			pw, _ := gen_password(GEN_DEFAULT, context.temp_allocator)
			entry_set_password(&e, pw)
			if spec[0] != "Example Bank" {
				replace_secret(&e.totp, seed)
			}
			append(&v.entries, e)
		}
		vault_sort(&v)
		ok(store_save(path, &v, &sess) == "", "could not write the UI fixture")
		vault_free(&v)
		session_zero(&sess)
	}

	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	register_theme()

	st := St {
		path       = strings.clone(path),
		screen     = .Unlock,
		pw         = make([dynamic]u8),
		pw2        = make([dynamic]u8),
		query      = make([dynamic]u8),
		rows       = make([dynamic]int),
		mp_new     = make([dynamic]u8),
		mp_again   = make([dynamic]u8),
		gen        = GEN_DEFAULT,
		idle_limit = 4,
		clip_limit = 2,
		have_clip  = true,
	}
	for f in Field {
		st.ed[f] = make([dynamic]u8)
	}
	defer shutdown(&st)

	drive(off, &st)
	ok(st.screen == .Unlock, "the app should start on the lock screen")

	// The wrong password first.
	p.type_text(off, "not-the-master-password")
	drive(off, &st)
	p.press_key(off, p.KEY_RETURN)
	drive(off, &st) // paints "Deriving the key..."
	ok(st.busy == .Unlocking, "Enter on the lock screen did not start a derivation")
	drive(off, &st) // performs it
	ok(st.screen == .Unlock, "the wrong master password unlocked the vault")
	ok(st.lock_err != "", "the wrong master password produced no error")
	ok(len(st.pw) == 0, "the password buffer was not cleared after a failed unlock")

	// Then the right one.
	p.type_text(off, PASS)
	drive(off, &st)
	p.press_key(off, p.KEY_RETURN)
	drive(off, &st)
	drive(off, &st)
	ok(st.screen == .Open, "the right master password did not unlock the vault: %s", st.lock_err)
	ok(len(st.v.entries) == 3, "the unlocked vault has %d entries", len(st.v.entries))
	ok(len(st.pw) == 0, "the master password is still in the field buffer after unlocking")
	ok(st.sess.unlocked, "the session is not marked unlocked")

	// Search. The sorted vault is Bank, Forge, Mail; "mail" should leave one.
	p.press_key(off, 'f', {.Ctrl})
	drive(off, &st)
	ok(p.focus_id(&off.ctx) == st.query_id && st.query_id != 0, "Ctrl F did not move the keyboard into the search field")
	p.type_text(off, "mail")
	drive(off, &st)
	ok(string(st.query[:]) == "mail", "typing did not reach the search field: %q", string(st.query[:]))
	ok(len(st.rows) == 1, "searching for \"mail\" matched %d entries", len(st.rows))
	ok(len(st.rows) == 1 && current(&st).title == "Example Mail", "the wrong entry matched")

	// A search that matches a tag rather than a title.
	clear(&st.query)
	p.type_text(off, "finance")
	drive(off, &st)
	ok(len(st.rows) == 1 && current(&st).title == "Example Bank", "searching a tag did not work")

	clear(&st.query)
	drive(off, &st)
	ok(len(st.rows) == 3, "clearing the search did not restore every entry")

	// The generator.
	p.press_key(off, 'g', {.Ctrl})
	drive(off, &st)
	ok(st.gen_open, "Ctrl G did not open the generator")
	ok(len(st.gen_pw) == st.gen.length, "the generator produced %d characters, not %d", len(st.gen_pw), st.gen.length)
	first := strings.clone(st.gen_pw)
	defer delete(first)
	p.press_key(off, p.KEY_SPACE)
	drive(off, &st)
	ok(st.gen_pw != first, "redrawing produced the same password")

	// Copying, with the clearing timer armed.
	p.press_key(off, 'c', {.Ctrl})
	drive(off, &st)
	ok(secret_eq(g_test_clip, st.gen_pw), "Ctrl C did not put the generated password on the clipboard")
	ok(st.clip_until > 0, "copying did not arm the clearing timer")
	ok(st.clip_label != "", "copying did not say what was copied")

	// ... and it clears itself. The offscreen clock advances 1/60 s a frame,
	// so step it at half a second to keep this quick.
	off.dt = 0.5
	for _ in 0 ..< 10 {
		if st.clip_until == 0 {
			break
		}
		drive(off, &st)
	}
	ok(st.clip_until == 0, "the clipboard timer never expired")
	ok(g_test_clip == "", "the clipboard was not cleared when the timer expired")

	p.press_key(off, p.KEY_ESCAPE)
	drive(off, &st)
	ok(!st.gen_open, "Escape did not close the generator")

	// TOTP in the detail pane. Example Forge has the public RFC 6238 seed.
	st.sel = 1
	drive(off, &st)
	e := current(&st)
	ok(e != nil && e.title == "Example Forge", "the second row should be Example Forge")
	if e != nil {
		code, cok := totp_code(e.totp, 59, e.totp_period, int(e.totp_digits), e.totp_algo, context.temp_allocator)
		ok(cok, "the fixture's TOTP secret did not decode")
		ok(cok && code == "287082", "the fixture's TOTP at T=59 should be 287082 (the RFC 6238 seed), got %q", code)
		// And copying it.
		p.press_key(off, 't', {.Ctrl})
		drive(off, &st)
		live, _ := totp_code(e.totp, now_unix(), e.totp_period, int(e.totp_digits), e.totp_algo, context.temp_allocator)
		ok(secret_eq(g_test_clip, live), "Ctrl T did not copy the current code")
	}

	// Reveal is off by default and the list never shows a password.
	ok(!st.reveal, "passwords start revealed")
	p.press_key(off, 'r', {.Ctrl})
	drive(off, &st)
	ok(st.reveal, "Ctrl R did not reveal")
	p.press_key(off, 'r', {.Ctrl})
	drive(off, &st)
	ok(!st.reveal, "Ctrl R did not hide again")

	// Editing: add an entry, give it a generated password, save, reload.
	p.press_key(off, 'n', {.Ctrl})
	drive(off, &st)
	ok(st.editing && st.ed_new, "Ctrl N did not open a new entry")
	set_buf(&st.ed[.Title], "Example Added")
	set_buf(&st.ed[.Username], "sample-added")
	new_pw, _ := gen_password(GEN_DEFAULT)
	defer delete(new_pw)
	set_buf(&st.ed[.Password], new_pw)
	set_buf(&st.ed[.Tags], "sample, added")
	p.press_key(off, 's', {.Ctrl})
	drive(off, &st)
	ok(!st.editing, "Ctrl S did not close the editor")
	ok(len(st.v.entries) == 4, "the new entry was not added: %d entries", len(st.v.entries))
	{
		reload, s, err := store_load(path, PASS)
		ok(err == "", "the vault did not reopen after the edit: %s", err)
		found := false
		for &x in reload.entries {
			if x.title == "Example Added" && x.password == new_pw {
				found = true
			}
		}
		ok(found, "the new entry was not persisted")
		vault_free(&reload)
		session_zero(&s)
	}

	// A rotation records history.
	st.sel = 0
	for r, i in st.rows {
		if st.v.entries[r].title == "Example Added" {
			st.sel = i
		}
	}
	drive(off, &st)
	p.press_key(off, 'e', {.Ctrl})
	drive(off, &st)
	ok(st.editing && !st.ed_new, "Ctrl E did not open the editor")
	rotated, _ := gen_password(GEN_DEFAULT)
	defer delete(rotated)
	set_buf(&st.ed[.Password], rotated)
	p.press_key(off, 's', {.Ctrl})
	drive(off, &st)
	{
		cur := current(&st)
		ok(cur != nil && cur.password == rotated, "the rotation did not take")
		ok(cur != nil && len(cur.history) == 1, "the rotation did not record one history row")
		ok(cur != nil && len(cur.history) == 1 && cur.history[0].password == new_pw, "the history kept the wrong password")
	}

	// An entry with no title is refused rather than saved blank.
	p.press_key(off, 'n', {.Ctrl})
	drive(off, &st)
	set_buf(&st.ed[.Title], "   ")
	p.press_key(off, 's', {.Ctrl})
	drive(off, &st)
	ok(st.editing, "an entry with a blank title was saved")
	ok(len(st.v.entries) == 4, "a blank entry was added anyway")
	p.press_key(off, p.KEY_ESCAPE)
	drive(off, &st)
	ok(!st.editing, "Escape did not discard the edit")

	// An invalid TOTP secret is refused too.
	p.press_key(off, 'e', {.Ctrl})
	drive(off, &st)
	set_buf(&st.ed[.Totp], "not!base32")
	p.press_key(off, 's', {.Ctrl})
	drive(off, &st)
	ok(st.editing, "an entry with an invalid TOTP secret was saved")
	p.press_key(off, p.KEY_ESCAPE)
	drive(off, &st)

	// Deleting, with the confirmation.
	n_before := len(st.v.entries)
	p.press_key(off, p.KEY_DELETE)
	drive(off, &st)
	ok(st.confirm_del, "Delete did not ask for confirmation")
	p.press_key(off, 'n')
	drive(off, &st)
	ok(!st.confirm_del && len(st.v.entries) == n_before, "declining the confirmation deleted the entry anyway")
	p.press_key(off, p.KEY_DELETE)
	drive(off, &st)
	p.press_key(off, 'y')
	drive(off, &st)
	ok(len(st.v.entries) == n_before - 1, "confirming did not delete the entry")

	// Locking on demand drops the key and the plaintext.
	p.press_key(off, 'l', {.Ctrl})
	drive(off, &st)
	ok(st.screen == .Unlock, "Ctrl L did not lock the vault")
	ok(!st.sess.unlocked, "Ctrl L left the session unlocked")
	ok(len(st.v.entries) == 0, "Ctrl L left the decrypted entries in memory")
	all_zero := true
	for b in st.sess.key {
		if b != 0 {
			all_zero = false
		}
	}
	ok(all_zero, "Ctrl L left the key in memory")

	// ----------------------------------------------------------------------
	// The idle lock. Unlock again, then stop touching anything.
	// ----------------------------------------------------------------------
	off.dt = 1.0 / 60
	p.type_text(off, PASS)
	drive(off, &st)
	p.press_key(off, p.KEY_RETURN)
	drive(off, &st)
	drive(off, &st)
	ok(st.screen == .Open, "could not unlock again: %s", st.lock_err)

	// Copy something first, so the idle lock has a clipboard to clean up.
	p.press_key(off, 'c', {.Ctrl})
	drive(off, &st)
	ok(g_test_clip != "", "Ctrl C copied nothing")

	off.dt = 0.5
	locked_after := 0
	for i in 0 ..< 40 {
		drive(off, &st)
		if st.screen != .Open {
			locked_after = i
			break
		}
	}
	ok(st.screen == .Unlock, "the vault did not lock itself after %.0f idle seconds", st.idle_limit)
	ok(!st.sess.unlocked, "the idle lock left the session unlocked")
	ok(st.lock_note != "", "the idle lock did not say why it locked")
	ok(g_test_clip == "", "the idle lock left a secret on the clipboard")
	fmt.printfln("      locked itself after %.1f idle seconds (limit %.0f)", f64(locked_after) * 0.5, st.idle_limit)

	// Opening a file that is not a vault says so instead of asking for a
	// password that could never work.
	notvault := strings.clone(fmt.tprintf("%s/not-a-vault.txt", SCRATCH))
	_ = os.write_entire_file(notvault, transmute([]u8)string("this is not a vault"))
	ok(!vault_looks_like_one(notvault), "a text file was taken for a vault")
	ok(vault_looks_like_one(path), "a real vault was not recognised")
	ok(!vault_looks_like_one(strings.clone(fmt.tprintf("%s/does-not-exist.pvz", SCRATCH), context.allocator)), "a missing file was taken for a vault")

	// A frame with no vault open must still render, which is what the lock
	// screen is.
	drive(off, &st)
	ok(p.node_count(&off.ctx) > 10, "the lock screen rendered almost nothing")
}

// ---------------------------------------------------------------------------
// What the chosen parameters cost
// ---------------------------------------------------------------------------

t_kdf_cost :: proc() {
	section("the cost of the default KDF parameters")

	salt: [SALT_LEN]u8
	crypto.rand_bytes(salt[:])
	key: [KEY_LEN]u8

	best: f64 = 1e18
	for _ in 0 ..< 3 {
		t0 := time.now()
		ok(derive_key("a-generated-master-for-the-test-9f2c", salt[:], KDF_DEFAULT, key[:]), "the default derivation failed")
		ms := time.duration_milliseconds(time.since(t0))
		best = min(best, ms)
	}
	fmt.printfln(
		"      Argon2id m=%d KiB (%d MiB), t=%d, p=%d: %.0f ms per derivation",
		KDF_DEFAULT.m,
		KDF_DEFAULT.m / 1024,
		KDF_DEFAULT.t,
		KDF_DEFAULT.par,
		best,
	)
	// The point of a memory-hard KDF is the cost it imposes. Under 100 ms it
	// is not imposing one; over 3 s nobody would use the app.
	ok(best > 100, "the default derivation takes only %.0f ms, which is not a meaningful cost", best)
	ok(best < 3000, "the default derivation takes %.0f ms, which is too slow to live with", best)

	// A full unlock, end to end, at the real parameters.
	path := fmt.tprintf("%s/cost.pvz", SCRATCH)
	sess, cerr := store_create(path, "a-generated-master-for-the-test-9f2c", KDF_DEFAULT)
	ok(cerr == "", "creating a vault at the default parameters failed: %s", cerr)
	session_zero(&sess)
	t0 := time.now()
	v, s, lerr := store_load(path, "a-generated-master-for-the-test-9f2c")
	unlock_ms := time.duration_milliseconds(time.since(t0))
	ok(lerr == "", "opening a vault at the default parameters failed: %s", lerr)
	fmt.printfln("      a full unlock at those parameters: %.0f ms", unlock_ms)
	vault_free(&v)
	session_zero(&s)
}
