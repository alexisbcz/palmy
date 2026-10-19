package pcp

// Key distribution for SFrame.
//
// Each participant makes an X25519 keypair when it joins a call and throws it
// away when it leaves. Its public key rides in JOIN; the SFU repeats it to the
// room in PEER. Each *sender* then picks a random 16-byte SFrame base key per
// generation and seals it to every other participant separately:
//
//	shared = X25519(my_secret, their_public)
//	wrap   = HKDF-SHA256(salt = "palm-call-wrap-v1", ikm = shared,
//	                     info = sender_pub || recipient_pub || kid(8) || call, 32)
//	blob   = nonce(12) || ChaCha20-Poly1305(wrap, nonce, aad = kid(8) || call, base_key) || tag(16)
//
// The SFU relays `blob` and learns nothing from it. Binding both public keys,
// the KID and the call id into the derivation means a blob cannot be replayed
// into another call, another generation, or toward another recipient.
//
// Rotation: a sender makes a new generation whenever the roster changes —
// anyone joins or leaves — and seals it only to the people now in the room.
// So someone who has left cannot read what is said after, and someone who
// has just joined never had the key for what was said before. The previous
// key is kept for ROTATE_GRACE seconds at the receivers so frames already in
// flight still open, and a sender starts encrypting with a new key only
// ROTATE_DELAY after sending it out, so receivers have it first.
//
// **What this does not protect against, stated plainly.** The public keys
// arrive through the SFU (which got them from the clients, but could lie). An
// SFU — or whoever controls it — that substitutes its own public key for a
// participant's can sit in the middle and read everything. That is an active
// attack, and it is detectable: every participant computes the same *safety
// code* from the roster of (identity, public key) pairs it actually used, and
// a substitution makes the codes differ. Reading the code aloud is the check,
// as in Signal or Zoom. Binding public keys to device keys enrolled in the
// account (and then MLS, with identity credentials) is the upgrade that
// removes the need for it.

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"

ROTATE_DELAY :: 0.30 // seconds between distributing a key and encrypting with it
ROTATE_GRACE :: 2.0 // seconds a superseded key still decrypts

BASE_KEY_SIZE :: 16
SEALED_SIZE :: 12 + BASE_KEY_SIZE + 16

Keypair :: struct {
	secret: [32]u8,
	public: [32]u8,
}

keypair_generate :: proc() -> (kp: Keypair) {
	crypto.rand_bytes(kp.secret[:])
	x25519.scalarmult_basepoint(kp.public[:], kp.secret[:])
	return
}

@(private)
wrap_key :: proc(shared: []u8, sender_pub, recipient_pub: []u8, kid: u64, call: string) -> (k: [32]u8) {
	info := make([dynamic]u8, 0, 128, context.temp_allocator)
	append(&info, ..sender_pub)
	append(&info, ..recipient_pub)
	kb: [8]u8
	endian.put_u64(kb[:], .Big, kid)
	append(&info, ..kb[:])
	append(&info, ..transmute([]u8)call)
	salt := "palm-call-wrap-v1"
	hkdf.extract_and_expand(.SHA256, transmute([]u8)salt, shared, info[:], k[:])
	return
}

@(private)
wrap_aad :: proc(kid: u64, call: string) -> []u8 {
	aad := make([]u8, 8 + len(call), context.temp_allocator)
	endian.put_u64(aad[:8], .Big, kid)
	copy(aad[8:], call)
	return aad
}

// seal_base_key seals `base` for `recipient_pub`. Returns false only when the
// shared secret is all zeros, i.e. the recipient's "public key" was a
// low-order point chosen to force a known secret.
seal_base_key :: proc(
	me: ^Keypair,
	recipient_pub: []u8,
	kid: u64,
	call: string,
	base: []u8,
	out: ^[SEALED_SIZE]u8,
) -> bool {
	shared: [32]u8
	x25519.scalarmult(shared[:], me.secret[:], recipient_pub)
	if all_zero(shared[:]) {
		return false
	}
	k := wrap_key(shared[:], me.public[:], recipient_pub, kid, call)
	crypto.rand_bytes(out[:12])
	aead.seal_oneshot(.CHACHA20POLY1305, out[12:12 + BASE_KEY_SIZE], out[12 + BASE_KEY_SIZE:], k[:], out[:12], wrap_aad(kid, call), base)
	return true
}

// open_base_key reverses seal_base_key at the recipient.
open_base_key :: proc(
	me: ^Keypair,
	sender_pub: []u8,
	kid: u64,
	call: string,
	sealed: []u8,
	base: ^[BASE_KEY_SIZE]u8,
) -> bool {
	if len(sealed) != SEALED_SIZE || len(sender_pub) != 32 {
		return false
	}
	shared: [32]u8
	x25519.scalarmult(shared[:], me.secret[:], sender_pub)
	if all_zero(shared[:]) {
		return false
	}
	k := wrap_key(shared[:], sender_pub, me.public[:], kid, call)
	return aead.open_oneshot(.CHACHA20POLY1305, base[:], k[:], sealed[:12], wrap_aad(kid, call), sealed[12:12 + BASE_KEY_SIZE], sealed[12 + BASE_KEY_SIZE:])
}

@(private)
all_zero :: proc(b: []u8) -> bool {
	acc: u8
	for x in b {
		acc |= x
	}
	return acc == 0
}

// Safety_Entry is one participant as a client sees it: who the token said
// it is, and the public key the SFU said it has.
Safety_Entry :: struct {
	id:  string, // identity id
	pub: [32]u8,
}

// safety_code is SHA-256 over the sorted "id:pubkey-hex" lines of everyone
// in the call, the caller included, shown as five groups of five digits.
// Everyone who sees the same roster gets the same code; a substituted key at
// any participant makes it differ.
safety_code :: proc(entries: []Safety_Entry, allocator := context.allocator) -> string {
	lines := make([]string, len(entries), context.temp_allocator)
	for e, i in entries {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, e.id)
		strings.write_byte(&b, ':')
		for x in e.pub {
			fmt.sbprintf(&b, "%02x", x)
		}
		lines[i] = strings.to_string(b)
	}
	slice.sort(lines)
	all := strings.join(lines, "\n", context.temp_allocator)
	digest: [32]u8
	hash.hash_string_to_buffer(.SHA256, all, digest[:])
	out := strings.builder_make(allocator)
	for g in 0 ..< 5 {
		v, _ := endian.get_u32(digest[g * 4:g * 4 + 4], .Big)
		if g > 0 {
			strings.write_byte(&out, ' ')
		}
		fmt.sbprintf(&out, "%05d", v % 100000)
	}
	return strings.to_string(out)
}

// ---------------------------------------------------------------------------
// The receiving key ring: every key a participant can currently decrypt
// with, by KID.
// ---------------------------------------------------------------------------

// Keys are heap-allocated so an AEAD context never moves after init.
Keyring :: struct {
	keys: [dynamic]^Sframe_Key,
}

keyring_find :: proc(r: ^Keyring, kid: u64) -> ^Sframe_Key {
	for k in r.keys {
		if k.live && k.kid == kid {
			return k
		}
	}
	return nil
}

// keyring_add installs a key for `kid`. Every older key of the same sender is
// marked to expire ROTATE_GRACE from `now`, rather than at once, so frames
// already in flight under it still open.
keyring_add :: proc(r: ^Keyring, kid: u64, base: []u8, now: f64) {
	if keyring_find(r, kid) != nil {
		return
	}
	src := kid_src(kid)
	for k in r.keys {
		if k.live && kid_src(k.kid) == src && k.expires == 0 {
			k.expires = now + ROTATE_GRACE
		}
	}
	nk := new(Sframe_Key)
	sframe_key_init(nk, kid, base)
	append(&r.keys, nk)
}

// keyring_prune forgets expired keys, and every key of a source that is no
// longer in the room.
keyring_prune :: proc(r: ^Keyring, now: f64, present: []u16 = nil) {
	for i := len(r.keys) - 1; i >= 0; i -= 1 {
		k := r.keys[i]
		gone := k.expires != 0 && now > k.expires
		if present != nil && !slice.contains(present, kid_src(k.kid)) {
			gone = true
		}
		if gone {
			sframe_key_clear(k)
			free(k)
			unordered_remove(&r.keys, i)
		}
	}
}

keyring_destroy :: proc(r: ^Keyring) {
	for k in r.keys {
		sframe_key_clear(k)
		free(k)
	}
	delete(r.keys)
	r.keys = nil
}
