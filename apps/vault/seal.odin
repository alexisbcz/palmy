package main

// The vault's cryptography, and nothing else.
//
// Everything here is a primitive out of `core:crypto` with the parameters
// written down: Argon2id for the key, an AEAD for the body, a fresh nonce for
// every save, and a header that is bound into the authentication tag so a
// single flipped bit anywhere in the file is refused rather than survived.
//
// The rule this file exists to enforce: there is no partial decryption. Either
// `vault_unseal` returns a plaintext whose tag verified, or it returns an
// error and nothing else. There is no "best effort" path and no salvage mode,
// because a password manager that hands back half a plaintext it could not
// authenticate is handing back whatever an attacker wrote into it.

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/argon2id"

// ---------------------------------------------------------------------------
// Sizes
// ---------------------------------------------------------------------------

MAGIC :: "PLMYVLT1"

KEY_LEN :: 32
SALT_LEN :: 16
NONCE_LEN :: 12
TAG_LEN :: 16

FORMAT_VERSION :: u16(1)

// The file header. `AAD_LEN` bytes of it are the additional authenticated
// data, so the KDF parameters, the salt, the nonce and the length are all
// covered by the tag. The tag itself sits after the AAD -- it cannot
// authenticate itself -- and the ciphertext follows.
//
//    off  size  field
//      0     8  magic "PLMYVLT1"
//      8     2  format version   u16 LE
//     10     1  kdf id           u8   (1 = Argon2id)
//     11     1  aead id          u8   (1 = ChaCha20-Poly1305, 2 = AES-256-GCM)
//     12     4  argon2 m (KiB)   u32 LE
//     16     4  argon2 t         u32 LE
//     20     4  argon2 p         u32 LE
//     24     4  flags, reserved  u32 LE
//     28    16  salt
//     44    12  nonce
//     56     8  ciphertext len   u64 LE
//     --        AAD ends here, at 64
//     64    16  tag
//     80     n  ciphertext
HEADER_LEN :: 80
AAD_LEN :: 64

KDF_ARGON2ID :: u8(1)

Aead_Id :: enum u8 {
	ChaCha20Poly1305 = 1,
	Aes256Gcm        = 2,
}

AEAD_ALGO := [Aead_Id]aead.Algorithm {
	.ChaCha20Poly1305 = .CHACHA20POLY1305,
	.Aes256Gcm        = .AES_GCM_256,
}

AEAD_NAME := [Aead_Id]string {
	.ChaCha20Poly1305 = "ChaCha20-Poly1305",
	.Aes256Gcm        = "AES-256-GCM",
}

// ---------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------

Kdf :: struct {
	m:   u32, // memory, KiB
	t:   u32, // passes
	par: u32, // lanes
}

// KDF_DEFAULT is what a vault created today is given. Measured on this
// machine at 0.59 s per derivation; see SECURITY.md for the reasoning.
//
// These numbers live in the header of every file, never only here, so raising
// them later cannot strand a vault that was written with the old ones.
KDF_DEFAULT :: Kdf {
	m   = 256 * 1024, // 256 MiB
	t   = 3,
	par = 4,
}

// A header is data from disk, so its parameters are an attacker's choice.
// Refusing absurd ones turns "open a hostile file" into an error message
// instead of a 64 GiB allocation.
KDF_MAX_M :: u32(4 * 1024 * 1024) // 4 GiB
KDF_MAX_T :: u32(64)
KDF_MAX_P :: u32(64)

kdf_valid :: proc(k: Kdf) -> bool {
	if k.t < 1 || k.t > KDF_MAX_T {
		return false
	}
	if k.par < 1 || k.par > KDF_MAX_P {
		return false
	}
	if k.m > KDF_MAX_M {
		return false
	}
	// Argon2 requires at least 8 blocks per lane.
	return k.m >= 8 * k.par
}

// derive_key runs Argon2id. `dst` is exactly KEY_LEN and is left untouched on
// failure.
derive_key :: proc(password: string, salt: []byte, k: Kdf, dst: []byte) -> bool {
	if len(dst) != KEY_LEN || len(salt) != SALT_LEN {
		return false
	}
	if !kdf_valid(k) {
		return false
	}
	ps := argon2id.Parameters {
		memory_size = k.m,
		passes      = k.t,
		parallelism = k.par,
	}
	err := argon2id.derive(&ps, transmute([]byte)password, salt, dst)
	return err == nil
}

// ---------------------------------------------------------------------------
// Session: a derived key plus the parameters it was derived under
//
// The salt is per vault and never changes while the master password does not,
// because re-deriving costs half a second and a save must not. The nonce is
// per save and always fresh -- that is the invariant that keeps the AEAD safe
// under a fixed key.
// ---------------------------------------------------------------------------

Session :: struct {
	key:    [KEY_LEN]byte,
	salt:   [SALT_LEN]byte,
	kdf:    Kdf,
	algo:   Aead_Id,
	unlocked: bool,
}

session_new :: proc(password: string, k := KDF_DEFAULT, algo := Aead_Id.ChaCha20Poly1305) -> (s: Session, ok: bool) {
	s.kdf = k
	s.algo = algo
	crypto.rand_bytes(s.salt[:])
	if !derive_key(password, s.salt[:], s.kdf, s.key[:]) {
		session_zero(&s)
		return {}, false
	}
	s.unlocked = true
	return s, true
}

// session_zero overwrites the key with zeroes using `zero_explicit`, which the
// compiler is not allowed to elide. What it cannot do is reach copies the
// kernel made: see SECURITY.md.
session_zero :: proc(s: ^Session) {
	crypto.zero_explicit(raw_data(s.key[:]), KEY_LEN)
	s.unlocked = false
}

// ---------------------------------------------------------------------------
// Header encode / decode
// ---------------------------------------------------------------------------

Header :: struct {
	version: u16,
	kdf_id:  u8,
	aead_id: Aead_Id,
	kdf:     Kdf,
	flags:   u32,
	salt:    [SALT_LEN]byte,
	nonce:   [NONCE_LEN]byte,
	ct_len:  u64,
	tag:     [TAG_LEN]byte,
}

put_u16le :: proc(b: []byte, v: u16) {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
}

put_u32le :: proc(b: []byte, v: u32) {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}

put_u64le :: proc(b: []byte, v: u64) {
	for i in 0 ..< 8 {
		b[i] = u8(v >> uint(8 * i))
	}
}

get_u16le :: proc(b: []byte) -> u16 {
	return u16(b[0]) | u16(b[1]) << 8
}

get_u32le :: proc(b: []byte) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

get_u64le :: proc(b: []byte) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v |= u64(b[i]) << uint(8 * i)
	}
	return v
}

header_encode :: proc(hh: Header, out: []byte) {
	assert(len(out) >= HEADER_LEN)
	h := hh
	copy(out[0:8], transmute([]byte)string(MAGIC))
	put_u16le(out[8:10], h.version)
	out[10] = h.kdf_id
	out[11] = u8(h.aead_id)
	put_u32le(out[12:16], h.kdf.m)
	put_u32le(out[16:20], h.kdf.t)
	put_u32le(out[20:24], h.kdf.par)
	put_u32le(out[24:28], h.flags)
	copy(out[28:44], h.salt[:])
	copy(out[44:56], h.nonce[:])
	put_u64le(out[56:64], h.ct_len)
	copy(out[64:80], h.tag[:])
}

// header_decode checks only what must be true before a key can be derived at
// all. Everything else -- including the flags word, which is reserved and
// deliberately not interpreted -- is left to the authentication tag.
header_decode :: proc(blob: []byte) -> (h: Header, err: string) {
	if len(blob) < HEADER_LEN {
		return {}, "the file is too short to be a vault"
	}
	if string(blob[0:8]) != MAGIC {
		return {}, "that file is not a palmy vault"
	}
	h.version = get_u16le(blob[8:10])
	if h.version != FORMAT_VERSION {
		return {}, "the vault was written by a newer version of this app"
	}
	h.kdf_id = blob[10]
	if h.kdf_id != KDF_ARGON2ID {
		return {}, "the vault uses a key derivation function this build does not have"
	}
	switch Aead_Id(blob[11]) {
	case .ChaCha20Poly1305, .Aes256Gcm:
		h.aead_id = Aead_Id(blob[11])
	case:
		return {}, "the vault uses a cipher this build does not have"
	}
	h.kdf = Kdf {
		m   = get_u32le(blob[12:16]),
		t   = get_u32le(blob[16:20]),
		par = get_u32le(blob[20:24]),
	}
	if !kdf_valid(h.kdf) {
		return {}, "the vault header asks for key derivation parameters outside the allowed range"
	}
	h.flags = get_u32le(blob[24:28])
	copy(h.salt[:], blob[28:44])
	copy(h.nonce[:], blob[44:56])
	h.ct_len = get_u64le(blob[56:64])
	copy(h.tag[:], blob[64:80])
	if u64(len(blob) - HEADER_LEN) != h.ct_len {
		return {}, "the vault's recorded length does not match the file"
	}
	return h, ""
}

// ---------------------------------------------------------------------------
// Seal and unseal
// ---------------------------------------------------------------------------

// vault_seal sealsplaintext under an unlocked session. A fresh 96-bit nonce is
// drawn from the OS CSPRNG on every call -- this is the only place a nonce is
// ever produced, and it never comes from a counter, a clock or the plaintext.
vault_seal :: proc(plain: []byte, s: ^Session, allocator := context.allocator) -> (blob: []byte, err: string) {
	if !s.unlocked {
		return nil, "the vault is locked"
	}
	h := Header {
		version = FORMAT_VERSION,
		kdf_id  = KDF_ARGON2ID,
		aead_id = s.algo,
		kdf     = s.kdf,
		flags   = 0,
		salt    = s.salt,
		ct_len  = u64(len(plain)),
	}
	crypto.rand_bytes(h.nonce[:])

	out := make([]byte, HEADER_LEN + len(plain), allocator)
	header_encode(h, out)
	aead.seal(
		AEAD_ALGO[s.algo],
		out[HEADER_LEN:],
		out[AAD_LEN:AAD_LEN + TAG_LEN],
		s.key[:],
		h.nonce[:],
		out[:AAD_LEN],
		plain,
	)
	return out, ""
}

// vault_unseal_key opens a blob with a key that has already been derived. The
// header's salt and parameters are still parsed and still authenticated; this
// only skips paying for Argon2id again.
vault_unseal_key :: proc(
	blob: []byte,
	key: []byte,
	allocator := context.allocator,
) -> (
	plain: []byte,
	h: Header,
	err: string,
) {
	h, err = header_decode(blob)
	if err != "" {
		return nil, h, err
	}
	if len(key) != KEY_LEN {
		return nil, h, "bad key length"
	}
	out := make([]byte, int(h.ct_len), allocator)
	ok := aead.open(
		AEAD_ALGO[h.aead_id],
		out,
		key,
		h.nonce[:],
		blob[:AAD_LEN],
		blob[HEADER_LEN:],
		blob[AAD_LEN:AAD_LEN + TAG_LEN],
	)
	if !ok {
		// Refused, not recovered. Wipe whatever the cipher wrote before the
		// tag check failed so no caller can reach it by accident.
		if len(out) > 0 {
			crypto.zero_explicit(raw_data(out), len(out))
		}
		delete(out, allocator)
		return nil, h, "the vault did not authenticate: the master password is wrong, or the file has been altered"
	}
	return out, h, ""
}

// vault_unseal derives the key from the password using the parameters the file
// itself records, then opens it. A single error string covers "wrong password"
// and "tampered file" because the AEAD genuinely cannot tell them apart, and
// pretending otherwise would be a lie in the UI.
vault_unseal :: proc(
	blob: []byte,
	password: string,
	allocator := context.allocator,
) -> (
	plain: []byte,
	s: Session,
	err: string,
) {
	h, herr := header_decode(blob)
	if herr != "" {
		return nil, {}, herr
	}
	s.kdf = h.kdf
	s.algo = h.aead_id
	s.salt = h.salt
	if !derive_key(password, s.salt[:], s.kdf, s.key[:]) {
		session_zero(&s)
		return nil, {}, "the key could not be derived from that password"
	}
	s.unlocked = true

	out, _, oerr := vault_unseal_key(blob, s.key[:], allocator)
	if oerr != "" {
		session_zero(&s)
		return nil, {}, oerr
	}
	return out, s, ""
}
