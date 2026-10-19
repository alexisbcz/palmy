package main

// The key hierarchy for synced vaults. seal.odin is the local file; this is
// everything that lets the same secrets live on a server that cannot read
// them. cloud/docs/vault.md has the diagram; the short form:
//
//   master password ──Argon2id──┐
//                               ├─HKDF─► account unlock key (AUK)
//   Secret Key (on the device) ─┘            │ wraps
//                                            ▼
//                                       account key (random)
//                                            │ wraps
//                                            ▼
//                identity keyset: X25519 + ML-KEM-768 (encryption), Ed25519 (signing)
//                                            │ seals (hybrid KEM)
//                                            ▼
//                                       vault key (random, one per vault)
//                                            │ wraps
//                                            ▼
//                                       item key (random, one per item)
//                                            │ encrypts
//                                            ▼
//                                       the item: every field, padded
//
// Every symmetric layer is XChaCha20-Poly1305 with a random 192-bit nonce
// (no counter to keep in sync between devices, and no birthday bound worth
// the name), and every one carries a context string in its associated data
// naming what it is and which row it belongs to. A wrapped key copied from
// one row to another, or an item blob replayed under another id, fails to
// authenticate instead of decrypting into the wrong place.
//
// Nothing here talks to the network. cloud.odin moves these bytes around.

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/mlkem"
import "core:crypto/x25519"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"

XNONCE_LEN :: 24
KEYID_LEN :: 8

// The first byte of every blob this file produces.
WRAP_V1 :: u8(0x01) // symmetric: tag ‖ key id ‖ nonce ‖ ciphertext ‖ mac
SEAL_V1 :: u8(0x02) // hybrid KEM: tag ‖ eph X25519 ‖ ML-KEM ct ‖ nonce ‖ ciphertext ‖ mac

KEM_PARAMS :: mlkem.Parameters.ML_KEM_768
KEM_PUB_LEN :: 1184
KEM_CT_LEN :: 1088
KEM_SEED_LEN :: 64

// What an identity's private half is, serialized: X25519 scalar, ML-KEM seed
// (d ‖ z), Ed25519 seed.
PRIV_LEN :: 32 + KEM_SEED_LEN + 32

// ---------------------------------------------------------------------------
// Key ids
//
// Eight bytes of SHA-256 over a domain string and the key. Written in the
// clear at the front of every wrap, so a client can tell *which* key a blob
// needs (after a rotation, an offline device may hold several) without trying
// them all. It says nothing about the key: a 256-bit random key's hash is not
// something anyone can work backwards from.
// ---------------------------------------------------------------------------

key_id :: proc(key: []byte) -> (id: [KEYID_LEN]byte) {
	h: [32]byte
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	hash.update(&ctx, transmute([]byte)string("palm-vault/key-id/v1"))
	hash.update(&ctx, key)
	hash.final(&ctx, h[:])
	copy(id[:], h[:KEYID_LEN])
	return
}

// ---------------------------------------------------------------------------
// Symmetric wrap
// ---------------------------------------------------------------------------

wrap :: proc(key: []byte, plain: []byte, aad: string, allocator := context.allocator) -> []byte {
	assert(len(key) == KEY_LEN)
	out := make([]byte, 1 + KEYID_LEN + XNONCE_LEN + len(plain) + TAG_LEN, allocator)
	out[0] = WRAP_V1
	kid := key_id(key)
	copy(out[1:], kid[:])
	nonce := out[1 + KEYID_LEN:][:XNONCE_LEN]
	crypto.rand_bytes(nonce)
	ct := out[1 + KEYID_LEN + XNONCE_LEN:][:len(plain)]
	tag := out[len(out) - TAG_LEN:]
	aead.seal(.XCHACHA20POLY1305, ct, tag, key, nonce, transmute([]byte)aad, plain)
	return out
}

// wrap_key_id reads the key id off a wrap without opening it.
wrap_key_id :: proc(blob: []byte) -> (id: [KEYID_LEN]byte, ok: bool) {
	if len(blob) < 1 + KEYID_LEN || blob[0] != WRAP_V1 {
		return {}, false
	}
	copy(id[:], blob[1:1 + KEYID_LEN])
	return id, true
}

// unwrap returns a plaintext whose tag verified, or nothing. Same rule as
// vault_unseal: no partial result, ever.
unwrap :: proc(key: []byte, blob: []byte, aad: string, allocator := context.allocator) -> (plain: []byte, ok: bool) {
	if len(key) != KEY_LEN || len(blob) < 1 + KEYID_LEN + XNONCE_LEN + TAG_LEN || blob[0] != WRAP_V1 {
		return nil, false
	}
	kid := key_id(key)
	if crypto.compare_constant_time(kid[:], blob[1:1 + KEYID_LEN]) != 1 {
		return nil, false
	}
	nonce := blob[1 + KEYID_LEN:][:XNONCE_LEN]
	ct := blob[1 + KEYID_LEN + XNONCE_LEN:len(blob) - TAG_LEN]
	tag := blob[len(blob) - TAG_LEN:]
	out := make([]byte, len(ct), allocator)
	if !aead.open(.XCHACHA20POLY1305, out, key, nonce, transmute([]byte)aad, ct, tag) {
		if len(out) > 0 {
			crypto.zero_explicit(raw_data(out), len(out))
		}
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

// ---------------------------------------------------------------------------
// Identity keys
// ---------------------------------------------------------------------------

Public_Keys :: struct {
	enc:  [32]byte, // X25519
	kem:  [KEM_PUB_LEN]byte, // ML-KEM-768 encapsulation key
	sign: [32]byte, // Ed25519
}

Identity_Keys :: struct {
	priv:  [PRIV_LEN]byte, // the serialized private half, kept to re-wrap
	x:     [32]byte,
	kem:   mlkem.Decapsulation_Key,
	sign:  ed25519.Private_Key,
	pub:   Public_Keys,
	ready: bool,
}

identity_keys_generate :: proc() -> (k: Identity_Keys) {
	crypto.rand_bytes(k.priv[:])
	ok := identity_keys_load(&k, k.priv[:])
	assert(ok)
	return
}

identity_keys_load :: proc(k: ^Identity_Keys, priv: []byte) -> bool {
	if len(priv) != PRIV_LEN {
		return false
	}
	if raw_data(k.priv[:]) != raw_data(priv) {
		copy(k.priv[:], priv)
	}
	copy(k.x[:], priv[0:32])
	x25519.scalarmult_basepoint(k.pub.enc[:], k.x[:])
	if !mlkem.decapsulation_key_set_bytes(&k.kem, KEM_PARAMS, priv[32:32 + KEM_SEED_LEN]) {
		return false
	}
	mlkem.decapsulation_key_encaps_bytes(&k.kem, k.pub.kem[:])
	if !ed25519.private_key_set_bytes(&k.sign, priv[32 + KEM_SEED_LEN:]) {
		return false
	}
	ed25519.private_key_public_bytes(&k.sign, k.pub.sign[:])
	k.ready = true
	return true
}

identity_keys_clear :: proc(k: ^Identity_Keys) {
	crypto.zero_explicit(&k.priv, size_of(k.priv))
	crypto.zero_explicit(&k.x, size_of(k.x))
	mlkem.decapsulation_key_clear(&k.kem)
	ed25519.private_key_clear(&k.sign)
	k.ready = false
}

// ---------------------------------------------------------------------------
// Sealing to an identity: X25519 and ML-KEM-768 together
//
// A key sealed today sits on a server for years. X25519 alone would be read
// by anyone who records it now and owns a large quantum computer later; ML-KEM
// alone is young. Both, combined so that breaking either one is not enough --
// the shape of X-Wing (draft-connolly-cfrg-xwing-kem), with HKDF-SHA256 as the
// combiner and the X25519 ciphertext and public key in the transcript, since
// X25519 is not binding on its own (ML-KEM is, so its ciphertext is not).
//
//   ss_x  = X25519(eph, recipient.enc)
//   ss_k, ct_k = ML-KEM-768.Encaps(recipient.kem)
//   key   = HKDF-SHA256(ikm = ss_k ‖ ss_x, salt = "",
//                       info = "palm-vault/seal/v1" ‖ eph_pub ‖ recipient.enc)
//   blob  = 0x02 ‖ eph_pub ‖ ct_k ‖ nonce ‖ XChaCha20-Poly1305(key, nonce, aad, plain)
// ---------------------------------------------------------------------------

SEAL_LABEL :: "palm-vault/seal/v1"

@(private = "file")
seal_kdf :: proc(ss_k, ss_x, eph_pub, rcpt_enc: []byte, out: []byte) {
	ikm: [64]byte
	defer crypto.zero_explicit(&ikm, size_of(ikm))
	copy(ikm[0:32], ss_k)
	copy(ikm[32:64], ss_x)
	info: [len(SEAL_LABEL) + 64]byte
	copy(info[:], SEAL_LABEL)
	copy(info[len(SEAL_LABEL):], eph_pub)
	copy(info[len(SEAL_LABEL) + 32:], rcpt_enc)
	hkdf.extract_and_expand(.SHA256, nil, ikm[:], info[:], out)
}

SEAL_OVERHEAD :: 1 + 32 + KEM_CT_LEN + XNONCE_LEN + TAG_LEN

seal_to :: proc(rcpt: ^Public_Keys, plain: []byte, aad: string, allocator := context.allocator) -> (blob: []byte, ok: bool) {
	eph: [32]byte
	defer crypto.zero_explicit(&eph, size_of(eph))
	crypto.rand_bytes(eph[:])
	out := make([]byte, SEAL_OVERHEAD + len(plain), allocator)
	out[0] = SEAL_V1
	eph_pub := out[1:33]
	x25519.scalarmult_basepoint(eph_pub, eph[:])

	ss_x: [32]byte
	defer crypto.zero_explicit(&ss_x, size_of(ss_x))
	x25519.scalarmult(ss_x[:], eph[:], rcpt.enc[:])
	if is_zero(ss_x[:]) {
		delete(out, allocator)
		return nil, false // a low-order point: refuse rather than seal to nobody
	}
	ss_k: [32]byte
	defer crypto.zero_explicit(&ss_k, size_of(ss_k))
	ct_k := out[33:33 + KEM_CT_LEN]
	if !mlkem.encaps(KEM_PARAMS, rcpt.kem[:], ss_k[:], ct_k) {
		delete(out, allocator)
		return nil, false
	}
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	seal_kdf(ss_k[:], ss_x[:], eph_pub, rcpt.enc[:], key[:])

	at := 33 + KEM_CT_LEN
	nonce := out[at:at + XNONCE_LEN]
	crypto.rand_bytes(nonce)
	ct := out[at + XNONCE_LEN:][:len(plain)]
	tag := out[len(out) - TAG_LEN:]
	aead.seal(.XCHACHA20POLY1305, ct, tag, key[:], nonce, transmute([]byte)aad, plain)
	return out, true
}

open_sealed :: proc(me: ^Identity_Keys, blob: []byte, aad: string, allocator := context.allocator) -> (plain: []byte, ok: bool) {
	if !me.ready || len(blob) < SEAL_OVERHEAD || blob[0] != SEAL_V1 {
		return nil, false
	}
	eph_pub := blob[1:33]
	ct_k := blob[33:33 + KEM_CT_LEN]
	ss_x: [32]byte
	defer crypto.zero_explicit(&ss_x, size_of(ss_x))
	x25519.scalarmult(ss_x[:], me.x[:], eph_pub)
	if is_zero(ss_x[:]) {
		return nil, false
	}
	ss_k: [32]byte
	defer crypto.zero_explicit(&ss_k, size_of(ss_k))
	if !mlkem.decaps(&me.kem, ct_k, ss_k[:]) {
		return nil, false
	}
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	seal_kdf(ss_k[:], ss_x[:], eph_pub, me.pub.enc[:], key[:])

	at := 33 + KEM_CT_LEN
	nonce := blob[at:at + XNONCE_LEN]
	ct := blob[at + XNONCE_LEN:len(blob) - TAG_LEN]
	tag := blob[len(blob) - TAG_LEN:]
	out := make([]byte, len(ct), allocator)
	if !aead.open(.XCHACHA20POLY1305, out, key[:], nonce, transmute([]byte)aad, ct, tag) {
		if len(out) > 0 {
			crypto.zero_explicit(raw_data(out), len(out))
		}
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

is_zero :: proc(b: []byte) -> bool {
	acc: byte
	for v in b {
		acc |= v
	}
	return acc == 0
}

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

sign_bytes :: proc(me: ^Identity_Keys, msg: []byte) -> (sig: [64]byte) {
	ed25519.sign(&me.sign, msg, sig[:])
	return
}

verify_bytes :: proc(sign_pub: []byte, msg: []byte, sig: []byte) -> bool {
	if len(sign_pub) != 32 || len(sig) != 64 {
		return false
	}
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, sign_pub) {
		return false
	}
	return ed25519.verify(&pk, msg, sig)
}

// share_transcript is what a share's signature covers: every field of the row
// that decides what the grantee will trust, plus a hash of the wrapped key, so
// a server cannot pair a genuine signature with a key of its own choosing.
share_transcript :: proc(
	share_id, source_identity, vault_id, item_id, grantee_identity, role: string,
	key_version: int,
	wrapped_key: []byte,
	allocator := context.temp_allocator,
) -> []byte {
	h: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, wrapped_key, h[:])
	s := fmt.aprintf(
		"palm-vault/share/v1\n%s\n%s\n%s\n%s\n%s\n%s\n%d\n%s",
		share_id, source_identity, vault_id, item_id, grantee_identity, role, key_version,
		hex_lower(h[:], context.temp_allocator),
		allocator = allocator,
	)
	return transmute([]byte)s
}

hex_lower :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, len(b) * 2, allocator)
	for v, i in b {
		out[i * 2] = digits[v >> 4]
		out[i * 2 + 1] = digits[v & 15]
	}
	return string(out)
}

// fingerprint is the "safety number" a person can read aloud to check that
// the identity they are sharing with is the one they think: twenty digits from
// SHA-256 over the three public keys. Shown beside a cross-account share,
// because that is the one place the server picks which key you encrypt to.
fingerprint :: proc(pk: ^Public_Keys, allocator := context.temp_allocator) -> string {
	ctx: hash.Context
	h: [32]byte
	hash.init(&ctx, .SHA256)
	hash.update(&ctx, transmute([]byte)string("palm-vault/fingerprint/v1"))
	hash.update(&ctx, pk.enc[:])
	hash.update(&ctx, pk.kem[:])
	hash.update(&ctx, pk.sign[:])
	hash.final(&ctx, h[:])
	sb := strings.builder_make(allocator)
	for g in 0 ..< 4 {
		v := u32(h[g * 3]) << 16 | u32(h[g * 3 + 1]) << 8 | u32(h[g * 3 + 2])
		if g > 0 {
			strings.write_byte(&sb, ' ')
		}
		fmt.sbprintf(&sb, "%05d", v % 100000)
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// The Secret Key and the account unlock key
//
// 128 random bits generated on the first device and never sent to the server.
// It is half of what derives the AUK, so a copy of the database plus a guess
// at the master password opens nothing: an attacker who stole the server has
// to guess 128 bits too. That is the whole point of it, and 1Password's
// two-secret key derivation is where the idea comes from.
//
// Written as PV1-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XX: 26 base32 characters (130
// bits, the top two always zero), grouped to be copied by hand from an
// emergency kit.
// ---------------------------------------------------------------------------

SECRET_LEN :: 16
SECRET_PREFIX :: "PV1"

secret_format :: proc(secret: []byte, allocator := context.allocator) -> string {
	assert(len(secret) == SECRET_LEN)
	// 16 bytes = 128 bits; base32 of 17 bytes (a leading zero byte) would be
	// 28 chars. Instead take the 128 bits as 26 groups of 5 from the top,
	// padding two zero bits at the end.
	b32 := base32_encode(secret, context.temp_allocator) // 26 chars, last carries 3 bits
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, SECRET_PREFIX)
	for i := 0; i < len(b32); i += 6 {
		strings.write_byte(&sb, '-')
		strings.write_string(&sb, b32[i:min(i + 6, len(b32))])
	}
	return strings.to_string(sb)
}

secret_parse :: proc(text: string) -> (secret: [SECRET_LEN]byte, ok: bool) {
	t := strings.trim_space(text)
	up := strings.to_upper(t, context.temp_allocator)
	if !strings.has_prefix(up, SECRET_PREFIX) {
		return {}, false
	}
	body := up[len(SECRET_PREFIX):]
	clean := make([dynamic]u8, 0, 32, context.temp_allocator)
	for c in transmute([]u8)body {
		switch c {
		case '-', ' ':
			continue
		case:
			append(&clean, c)
		}
	}
	if len(clean) != 26 {
		return {}, false
	}
	raw, good := base32_decode(string(clean[:]), context.temp_allocator)
	if !good || len(raw) != SECRET_LEN {
		return {}, false
	}
	copy(secret[:], raw)
	return secret, true
}

// derive_auk combines the two secrets. Argon2id carries the cost (the same
// parameters as the local vault); the Secret Key enters through HKDF, bound
// to the account it belongs to, and both go into one more HKDF so neither can
// be peeled off the other.
derive_auk :: proc(password: string, secret: []byte, salt: []byte, kdf: Kdf, account_id: string, out: []byte) -> bool {
	assert(len(out) == KEY_LEN)
	pw_key: [KEY_LEN]byte
	defer crypto.zero_explicit(&pw_key, size_of(pw_key))
	if !derive_key(password, salt, kdf, pw_key[:]) {
		return false
	}
	sk_key: [KEY_LEN]byte
	defer crypto.zero_explicit(&sk_key, size_of(sk_key))
	hkdf.extract_and_expand(.SHA256, transmute([]byte)account_id, secret, transmute([]byte)string("palm-vault/secret-key/v1"), sk_key[:])
	ikm: [2 * KEY_LEN]byte
	defer crypto.zero_explicit(&ikm, size_of(ikm))
	copy(ikm[:KEY_LEN], pw_key[:])
	copy(ikm[KEY_LEN:], sk_key[:])
	hkdf.extract_and_expand(.SHA256, salt, ikm[:], transmute([]byte)string("palm-vault/auk/v1"), out)
	return true
}

// ---------------------------------------------------------------------------
// The contexts every wrap is bound to
// ---------------------------------------------------------------------------

aad_account_key :: proc() -> string {
	return "palm-vault/account-key/v1"
}
aad_identity_keys :: proc(identity_id: string) -> string {
	return fmt.tprintf("palm-vault/identity-keys/v1|%s", identity_id)
}
aad_vault_key :: proc(vault_id: string, key_version: int, grantee: string) -> string {
	return fmt.tprintf("palm-vault/vault-key/v1|%s|%d|%s", vault_id, key_version, grantee)
}
aad_vault_meta :: proc(vault_id: string) -> string {
	return fmt.tprintf("palm-vault/vault-meta/v1|%s", vault_id)
}
aad_item_key :: proc(vault_id, item_id: string, key_version: int) -> string {
	return fmt.tprintf("palm-vault/item-key/v1|%s|%s|%d", vault_id, item_id, key_version)
}
aad_item_share :: proc(item_id, grantee: string) -> string {
	return fmt.tprintf("palm-vault/item-share/v1|%s|%s", item_id, grantee)
}
aad_item :: proc(vault_id, item_id: string, revision: i64) -> string {
	return fmt.tprintf("palm-vault/item/v1|%s|%s|%d", vault_id, item_id, revision)
}
aad_device_secret :: proc(device_id: string) -> string {
	return fmt.tprintf("palm-vault/device-secret/v1|%s", device_id)
}

// ---------------------------------------------------------------------------
// base64 at the edge
// ---------------------------------------------------------------------------

b64 :: proc(b: []byte, allocator := context.allocator) -> string {
	s, _ := base64.encode(b, allocator = allocator)
	return s
}

unb64 :: proc(s: string, allocator := context.allocator) -> (out: []byte, ok: bool) {
	if len(s) % 4 != 0 {
		return nil, false
	}
	for c in transmute([]u8)s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/', '=':
		case:
			return nil, false
		}
	}
	d, err := base64.decode(s, allocator = allocator)
	if err != nil {
		return nil, false
	}
	return d, true
}

// new_uuid is a random (version 4) UUID, the form every id in the schema takes.
new_uuid :: proc(allocator := context.allocator) -> string {
	b: [16]byte
	crypto.rand_bytes(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex_lower(b[:], context.temp_allocator)
	return fmt.aprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32], allocator = allocator)
}

// ---------------------------------------------------------------------------
// Sealing to a device: X25519 alone
//
// A device's enrollment key is X25519 only, and is used once, to carry the
// Secret Key from an enrolled device to a new one. It is the one place in
// the design without the ML-KEM half: what it protects is the Secret Key,
// which is useless without the master password, and the box lives in one
// row (vault.md, "Devices").
//
//   blob = 0x03 ‖ eph_pub ‖ nonce ‖ XChaCha20-Poly1305(HKDF(X25519(eph, pub)), ...)
// ---------------------------------------------------------------------------

SEALX_V1 :: u8(0x03)
SEALX_LABEL :: "palm-vault/seal-x/v1"

x25519_base :: proc(dst, scalar: []byte) {
	x25519.scalarmult_basepoint(dst, scalar)
}

@(private = "file")
sealx_kdf :: proc(ss, eph_pub, rcpt: []byte, out: []byte) {
	info: [len(SEALX_LABEL) + 64]byte
	copy(info[:], SEALX_LABEL)
	copy(info[len(SEALX_LABEL):], eph_pub)
	copy(info[len(SEALX_LABEL) + 32:], rcpt)
	hkdf.extract_and_expand(.SHA256, nil, ss, info[:], out)
}

seal_x_to :: proc(pub: []byte, plain: []byte, aad: string, allocator := context.allocator) -> (blob: []byte, ok: bool) {
	if len(pub) != 32 {
		return nil, false
	}
	eph: [32]byte
	defer crypto.zero_explicit(&eph, size_of(eph))
	crypto.rand_bytes(eph[:])
	out := make([]byte, 1 + 32 + XNONCE_LEN + len(plain) + TAG_LEN, allocator)
	out[0] = SEALX_V1
	x25519.scalarmult_basepoint(out[1:33], eph[:])
	ss: [32]byte
	defer crypto.zero_explicit(&ss, size_of(ss))
	x25519.scalarmult(ss[:], eph[:], pub)
	if is_zero(ss[:]) {
		delete(out, allocator)
		return nil, false
	}
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	sealx_kdf(ss[:], out[1:33], pub, key[:])
	nonce := out[33:33 + XNONCE_LEN]
	crypto.rand_bytes(nonce)
	ct := out[33 + XNONCE_LEN:][:len(plain)]
	aead.seal(.XCHACHA20POLY1305, ct, out[len(out) - TAG_LEN:], key[:], nonce, transmute([]byte)aad, plain)
	return out, true
}

open_x_sealed :: proc(priv: []byte, blob: []byte, aad: string, allocator := context.allocator) -> (plain: []byte, ok: bool) {
	if len(priv) != 32 || len(blob) < 1 + 32 + XNONCE_LEN + TAG_LEN || blob[0] != SEALX_V1 {
		return nil, false
	}
	pub: [32]byte
	x25519.scalarmult_basepoint(pub[:], priv)
	ss: [32]byte
	defer crypto.zero_explicit(&ss, size_of(ss))
	x25519.scalarmult(ss[:], priv, blob[1:33])
	if is_zero(ss[:]) {
		return nil, false
	}
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	sealx_kdf(ss[:], blob[1:33], pub[:], key[:])
	nonce := blob[33:33 + XNONCE_LEN]
	ct := blob[33 + XNONCE_LEN:len(blob) - TAG_LEN]
	out := make([]byte, len(ct), allocator)
	if !aead.open(.XCHACHA20POLY1305, out, key[:], nonce, transmute([]byte)aad, ct, blob[len(blob) - TAG_LEN:]) {
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

// sha256_tagged hashes a domain label and some bytes.
sha256_tagged :: proc(label: string, data: []byte) -> (h: [32]byte) {
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	hash.update(&ctx, transmute([]byte)label)
	hash.update(&ctx, data)
	hash.final(&ctx, h[:])
	return
}
