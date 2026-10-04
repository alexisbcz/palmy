package main

// Published test vectors, transcribed from the standards documents.
//
// This file exists because round-tripping proves nothing. A vault sealed and
// opened by the same wrong implementation opens perfectly; the only way to
// find out whether these are really Argon2id, really ChaCha20-Poly1305 and
// really TOTP is to feed them inputs somebody else published the answers to.
//
// Sources, and nothing paraphrased from memory of them:
//
//   RFC 9106 section 5.3 -- Argon2id test vector
//   RFC 8439 section 2.8.2 -- AEAD_CHACHA20_POLY1305 encryption
//   NIST GCM spec (McGrew/Viega submission) test case 16 -- AES-256-GCM
//   RFC 4231 sections 4.2-4.7 -- HMAC-SHA-1 and HMAC-SHA-256
//   RFC 6238 appendix B -- TOTP, seed 12345678901234567890, 8 digits
//
// Anything that disagrees with these is a bug here, not in the RFC.

// ---------------------------------------------------------------------------
// RFC 9106 section 5.3: Argon2id
//
//   password        32 bytes of 0x01
//   salt            16 bytes of 0x02
//   secret          8 bytes of 0x03
//   associated data 12 bytes of 0x04
//   m = 32 KiB, t = 3, p = 4, tag length 32
// ---------------------------------------------------------------------------

RFC9106_TAG := [32]u8 {
	0x0d, 0x64, 0x0d, 0xf5, 0x8d, 0x78, 0x76, 0x6c,
	0x08, 0xc0, 0x37, 0xa3, 0x4a, 0x8b, 0x53, 0xc9,
	0xd0, 0x1e, 0xf0, 0x45, 0x2d, 0x75, 0xb6, 0x5e,
	0xb5, 0x25, 0x20, 0xe9, 0x6b, 0x01, 0xe6, 0x59,
}

// ---------------------------------------------------------------------------
// RFC 8439 section 2.8.2: AEAD_CHACHA20_POLY1305
// ---------------------------------------------------------------------------

RFC8439_PLAIN :: "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."

RFC8439_AAD := [12]u8{0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7}

RFC8439_KEY := [32]u8 {
	0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
	0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
	0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
	0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
}

RFC8439_IV := [12]u8{0x07, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47}

RFC8439_CT := [114]u8 {
	0xd3, 0x1a, 0x8d, 0x34, 0x64, 0x8e, 0x60, 0xdb,
	0x7b, 0x86, 0xaf, 0xbc, 0x53, 0xef, 0x7e, 0xc2,
	0xa4, 0xad, 0xed, 0x51, 0x29, 0x6e, 0x08, 0xfe,
	0xa9, 0xe2, 0xb5, 0xa7, 0x36, 0xee, 0x62, 0xd6,
	0x3d, 0xbe, 0xa4, 0x5e, 0x8c, 0xa9, 0x67, 0x12,
	0x82, 0xfa, 0xfb, 0x69, 0xda, 0x92, 0x72, 0x8b,
	0x1a, 0x71, 0xde, 0x0a, 0x9e, 0x06, 0x0b, 0x29,
	0x05, 0xd6, 0xa5, 0xb6, 0x7e, 0xcd, 0x3b, 0x36,
	0x92, 0xdd, 0xbd, 0x7f, 0x2d, 0x77, 0x8b, 0x8c,
	0x98, 0x03, 0xae, 0xe3, 0x28, 0x09, 0x1b, 0x58,
	0xfa, 0xb3, 0x24, 0xe4, 0xfa, 0xd6, 0x75, 0x94,
	0x55, 0x85, 0x80, 0x8b, 0x48, 0x31, 0xd7, 0xbc,
	0x3f, 0xf4, 0xde, 0xf0, 0x8e, 0x4b, 0x7a, 0x9d,
	0xe5, 0x76, 0xd2, 0x65, 0x86, 0xce, 0xc6, 0x4b,
	0x61, 0x16,
}

RFC8439_TAG := [16]u8 {
	0x1a, 0xe1, 0x0b, 0x59, 0x4f, 0x09, 0xe2, 0x6a,
	0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60, 0x06, 0x91,
}

// ---------------------------------------------------------------------------
// NIST GCM specification, test case 16: AES-256-GCM
// ---------------------------------------------------------------------------

GCM16_KEY := [32]u8 {
	0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c,
	0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08,
	0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c,
	0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08,
}

GCM16_IV := [12]u8{0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce, 0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88}

GCM16_AAD := [20]u8 {
	0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef,
	0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef,
	0xab, 0xad, 0xda, 0xd2,
}

GCM16_PLAIN := [60]u8 {
	0xd9, 0x31, 0x32, 0x25, 0xf8, 0x84, 0x06, 0xe5,
	0xa5, 0x59, 0x09, 0xc5, 0xaf, 0xf5, 0x26, 0x9a,
	0x86, 0xa7, 0xa9, 0x53, 0x15, 0x34, 0xf7, 0xda,
	0x2e, 0x4c, 0x30, 0x3d, 0x8a, 0x31, 0x8a, 0x72,
	0x1c, 0x3c, 0x0c, 0x95, 0x95, 0x68, 0x09, 0x53,
	0x2f, 0xcf, 0x0e, 0x24, 0x49, 0xa6, 0xb5, 0x25,
	0xb1, 0x6a, 0xed, 0xf5, 0xaa, 0x0d, 0xe6, 0x57,
	0xba, 0x63, 0x7b, 0x39,
}

GCM16_CT := [60]u8 {
	0x52, 0x2d, 0xc1, 0xf0, 0x99, 0x56, 0x7d, 0x07,
	0xf4, 0x7f, 0x37, 0xa3, 0x2a, 0x84, 0x42, 0x7d,
	0x64, 0x3a, 0x8c, 0xdc, 0xbf, 0xe5, 0xc0, 0xc9,
	0x75, 0x98, 0xa2, 0xbd, 0x25, 0x55, 0xd1, 0xaa,
	0x8c, 0xb0, 0x8e, 0x48, 0x59, 0x0d, 0xbb, 0x3d,
	0xa7, 0xb0, 0x8b, 0x10, 0x56, 0x82, 0x88, 0x38,
	0xc5, 0xf6, 0x1e, 0x63, 0x93, 0xba, 0x7a, 0x0a,
	0xbc, 0xc9, 0xf6, 0x62,
}

GCM16_TAG := [16]u8 {
	0x76, 0xfc, 0x6e, 0xce, 0x0f, 0x4e, 0x17, 0x68,
	0xcd, 0xdf, 0x88, 0x53, 0xbb, 0x2d, 0x55, 0x1b,
}

// ---------------------------------------------------------------------------
// RFC 4231: HMAC-SHA-1 and HMAC-SHA-256
//
// Test case 5 is omitted: it is the only one with a truncated tag, and this
// app never truncates a MAC.
// ---------------------------------------------------------------------------

// An empty `sha1` or `sha256` means that RFC does not publish a digest for
// that case, and nothing is asserted.
Hmac_Vector :: struct {
	name:   string,
	key:    []u8,
	data:   []u8,
	sha1:   string, // hex, RFC 2202
	sha256: string, // hex, RFC 4231
}

@(private = "file")
rep :: proc(b: u8, n: int) -> []u8 {
	out := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = b
	}
	return out
}

@(private = "file")
seq :: proc(from: u8, n: int) -> []u8 {
	out := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = from + u8(i)
	}
	return out
}

hmac_vectors :: proc() -> []Hmac_Vector {
	out := make([dynamic]Hmac_Vector, context.temp_allocator)
	append(&out, Hmac_Vector {
		name   = "RFC 4231 case 1",
		key    = rep(0x0b, 20),
		data   = transmute([]u8)string("Hi There"),
		sha1   = "b617318655057264e28bc0b6fb378c8ef146be00",
		sha256 = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
	})
	append(&out, Hmac_Vector {
		name   = "RFC 4231 case 2",
		key    = transmute([]u8)string("Jefe"),
		data   = transmute([]u8)string("what do ya want for nothing?"),
		sha1   = "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79",
		sha256 = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
	})
	append(&out, Hmac_Vector {
		name   = "RFC 4231 case 3",
		key    = rep(0xaa, 20),
		data   = rep(0xdd, 50),
		sha1   = "125d7342b9ac11cd91a39af48aa17b4f63f175d3",
		sha256 = "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
	})
	append(&out, Hmac_Vector {
		name   = "RFC 4231 case 4",
		key    = seq(0x01, 25),
		data   = rep(0xcd, 50),
		sha1   = "4c9007f4026250c6bc8414f9bf50c86c2d7235da",
		sha256 = "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
	})
	// Cases 6 and 7 are where the two documents part company. RFC 4231's
	// long-key cases use a 131-byte key and publish SHA-224 upwards only;
	// RFC 2202's use an 80-byte key and publish SHA-1. Asserting the RFC 2202
	// digest against the RFC 4231 key is the obvious mistake, and it fails.
	append(&out, Hmac_Vector {
		name   = "RFC 4231 case 6 (131-byte key)",
		key    = rep(0xaa, 131),
		data   = transmute([]u8)string("Test Using Larger Than Block-Size Key - Hash Key First"),
		sha256 = "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
	})
	append(&out, Hmac_Vector {
		name   = "RFC 4231 case 7 (131-byte key, long data)",
		key    = rep(0xaa, 131),
		data   = transmute([]u8)string(
			"This is a test using a larger than block-size key and a larger " +
			"than block-size data. The key needs to be hashed before being " +
			"used by the HMAC algorithm.",
		),
		sha256 = "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
	})
	append(&out, Hmac_Vector {
		name   = "RFC 2202 case 6 (80-byte key)",
		key    = rep(0xaa, 80),
		data   = transmute([]u8)string("Test Using Larger Than Block-Size Key - Hash Key First"),
		sha1   = "aa4ae5e15272d00e95705637ce8a3b55ed402112",
	})
	append(&out, Hmac_Vector {
		name   = "RFC 2202 case 7 (80-byte key, long data)",
		key    = rep(0xaa, 80),
		data   = transmute([]u8)string(
			"Test Using Larger Than Block-Size Key and Larger Than One Block-Size Data",
		),
		sha1   = "e8e99d0f45237d786d6bbaa7965c7808bbff1a91",
	})
	return out[:]
}

// ---------------------------------------------------------------------------
// RFC 6238 appendix B: TOTP
//
// The seeds are ASCII digits repeated to the hash's block size:
//   SHA1    "12345678901234567890"                                       (20)
//   SHA256  "12345678901234567890123456789012"                           (32)
//   SHA512  "1234567890123456789012345678901234567890123456789012345678901234" (64)
//
// T0 = 0, X = 30 s, 8 digits.
// ---------------------------------------------------------------------------

RFC6238_SEED_SHA1 :: "12345678901234567890"
RFC6238_SEED_SHA256 :: "12345678901234567890123456789012"
RFC6238_SEED_SHA512 :: "1234567890123456789012345678901234567890123456789012345678901234"

Totp_Vector :: struct {
	unix_s: i64,
	sha1:   string,
	sha256: string,
	sha512: string,
}

RFC6238_VECTORS := [?]Totp_Vector {
	{59, "94287082", "46119246", "90693936"},
	{1111111109, "07081804", "68084774", "25091201"},
	{1111111111, "14050471", "67062674", "99943326"},
	{1234567890, "89005924", "91819424", "93441116"},
	{2000000000, "69279037", "90698825", "38618901"},
	{20000000000, "65353130", "77737706", "47863826"},
}

// RFC 4226 appendix D: HOTP with the same 20-byte seed, 6 digits, counters 0-9.
RFC4226_HOTP := [?]string {
	"755224",
	"287082",
	"359152",
	"969429",
	"338314",
	"254676",
	"287922",
	"162583",
	"399871",
	"520489",
}
