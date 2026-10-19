package pcp

// SFrame (RFC 9605) — end-to-end encryption of each media frame.
//
// A frame is encrypted *before* it is fragmented, so what crosses the SFU is
// an SFrame ciphertext cut into PCP2 fragments: the SFU sees sizes, timing,
// the keyframe bit and the audio level (all in the clear PCP2 header), and
// nothing of the picture or the voice.
//
// Cipher suite AES_128_GCM_SHA256_128 (0x0004): HKDF-SHA256, AES-128-GCM, a
// 16-byte tag. Key and salt are derived from a per-sender `base_key` exactly
// as §4.4.2 says, and the implementation is checked against the RFC's own
// Appendix C test vectors in the self-test (header encodings from C.1 and the
// 0x0004 case of C.3), so "SFrame" here means byte-for-byte SFrame.
//
// What this file does *not* decide is where base keys come from. That is
// keys.odin: one random key per sender per generation, sealed pairwise to
// every other participant's X25519 key and relayed by the SFU as an opaque
// blob. MLS would be the stronger answer and is the documented upgrade path;
// see apps/call/PROTOCOL.md, "E2EE".
//
// The KID names the sender and the generation: KID = src << 16 | generation.
// `src` is the SFU-assigned source id (the same one stamped into every
// datagram), so a receiver that decrypts a frame with KID k knows which
// participant's key opened it — and a datagram whose PCP2 `src` disagrees
// with its KID's sender is rejected by the client, so the SFU cannot relabel
// one participant's media as another's either.

import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/endian"

SUITE_AES_128_GCM_SHA256_128 :: u16(0x0004)
SF_NK :: 16
SF_NN :: 12
SF_NT :: 16
SF_MAX_HEADER :: 17 // config byte + 8 + 8

kid_of :: proc(src: u16, generation: u16) -> u64 {
	return u64(src) << 16 | u64(generation)
}

kid_src :: proc(kid: u64) -> u16 {
	return u16(kid >> 16)
}

kid_gen :: proc(kid: u64) -> u16 {
	return u16(kid)
}

// min_bytes is the length of `v`'s minimal big-endian encoding.
@(private)
min_bytes :: proc(v: u64) -> int {
	n := 1
	for x := v >> 8; x != 0; x >>= 8 {
		n += 1
	}
	return n
}

// sframe_header_encode writes the header for (kid, ctr) and returns its
// length. `b` must hold SF_MAX_HEADER bytes.
sframe_header_encode :: proc(b: []u8, kid, ctr: u64) -> int {
	cfg: u8
	n := 1
	if kid < 8 {
		cfg |= u8(kid) << 4
	} else {
		kl := min_bytes(kid)
		cfg |= 0x80 | u8(kl - 1) << 4
		for i in 0 ..< kl {
			b[n + i] = u8(kid >> u64(8 * (kl - 1 - i)))
		}
		n += kl
	}
	if ctr < 8 {
		cfg |= u8(ctr)
	} else {
		cl := min_bytes(ctr)
		cfg |= 0x08 | u8(cl - 1)
		for i in 0 ..< cl {
			b[n + i] = u8(ctr >> u64(8 * (cl - 1 - i)))
		}
		n += cl
	}
	b[0] = cfg
	return n
}

sframe_header_decode :: proc(b: []u8) -> (kid, ctr: u64, n: int, ok: bool) {
	if len(b) < 1 {
		return
	}
	cfg := b[0]
	n = 1
	if cfg & 0x80 == 0 {
		kid = u64(cfg >> 4 & 7)
	} else {
		kl := int(cfg >> 4 & 7) + 1
		if len(b) < n + kl {
			return
		}
		for i in 0 ..< kl {
			kid = kid << 8 | u64(b[n + i])
		}
		n += kl
	}
	if cfg & 0x08 == 0 {
		ctr = u64(cfg & 7)
	} else {
		cl := int(cfg & 7) + 1
		if len(b) < n + cl {
			return
		}
		for i in 0 ..< cl {
			ctr = ctr << 8 | u64(b[n + i])
		}
		n += cl
	}
	return kid, ctr, n, true
}

// sframe_derive is §4.4.2 for suite 0x0004.
sframe_derive :: proc(kid: u64, base_key: []u8) -> (key: [SF_NK]u8, salt: [SF_NN]u8) {
	secret: [32]u8
	hkdf.extract(.SHA256, nil, base_key, secret[:])

	label: [40]u8
	klabel := "SFrame 1.0 Secret key "
	n := copy(label[:], klabel)
	endian.put_u64(label[n:], .Big, kid)
	endian.put_u16(label[n + 8:], .Big, SUITE_AES_128_GCM_SHA256_128)
	hkdf.expand(.SHA256, secret[:], label[:n + 10], key[:])

	slabel := "SFrame 1.0 Secret salt "
	n = copy(label[:], slabel)
	endian.put_u64(label[n:], .Big, kid)
	endian.put_u16(label[n + 8:], .Big, SUITE_AES_128_GCM_SHA256_128)
	hkdf.expand(.SHA256, secret[:], label[:n + 10], salt[:])
	return
}

_ :: hash.Algorithm

// Sframe_Key is one derived key, for one direction: a sender's own current
// key (which encrypts, and whose `ctr` counts), or a received one (which
// decrypts, and whose replay window remembers what it has opened).
Sframe_Key :: struct {
	kid:     u64,
	key:     [SF_NK]u8,
	salt:    [SF_NN]u8,
	ctx:     aead.Context,
	live:    bool,
	ctr:     u64, // next counter to encrypt with

	// Replay window, as SRTP keeps one: the highest counter accepted and a
	// bitmap of the 64 below it.
	top:     u64,
	window:  u64,
	any:     bool,

	expires: f64, // when a superseded key stops being accepted; 0 = current
}

sframe_key_init :: proc(k: ^Sframe_Key, kid: u64, base_key: []u8) {
	sframe_key_clear(k)
	k.kid = kid
	k.key, k.salt = sframe_derive(kid, base_key)
	aead.init(&k.ctx, .AES_GCM_128, k.key[:])
	k.live = true
}

sframe_key_clear :: proc(k: ^Sframe_Key) {
	if k.live {
		aead.reset(&k.ctx)
	}
	k^ = {}
}

@(private)
nonce_of :: proc(k: ^Sframe_Key, ctr: u64) -> (n: [SF_NN]u8) {
	n = k.salt
	c: [8]u8
	endian.put_u64(c[:], .Big, ctr)
	for i in 0 ..< 8 {
		n[SF_NN - 8 + i] ~= c[i]
	}
	return
}

// sframe_seal encrypts `pt` under `k` with counter `ctr` and `metadata` as
// extra AAD, writing header || ciphertext || tag into `out`, which must hold
// len(pt) + SF_MAX_HEADER + SF_NT bytes.
sframe_seal_ctr :: proc(k: ^Sframe_Key, ctr: u64, metadata, pt, out: []u8) -> []u8 {
	hn := sframe_header_encode(out, k.kid, ctr)
	aad := make([]u8, hn + len(metadata), context.temp_allocator)
	copy(aad, out[:hn])
	copy(aad[hn:], metadata)
	nonce := nonce_of(k, ctr)
	ct := out[hn:hn + len(pt)]
	tag := out[hn + len(pt):hn + len(pt) + SF_NT]
	aead.seal_ctx(&k.ctx, ct, tag, nonce[:], aad, pt)
	return out[:hn + len(pt) + SF_NT]
}

// sframe_seal uses and advances the key's own counter. A (KID, CTR) pair is
// used for exactly one encryption, which is the one rule SFrame cannot
// survive breaking.
sframe_seal :: proc(k: ^Sframe_Key, metadata, pt, out: []u8) -> []u8 {
	r := sframe_seal_ctr(k, k.ctr, metadata, pt, out)
	k.ctr += 1
	return r
}

// sframe_peek returns the KID of a ciphertext, so the caller can find a key.
sframe_peek :: proc(ct: []u8) -> (kid: u64, ok: bool) {
	kid, _, _, ok = sframe_header_decode(ct)
	return
}

Open_Error :: enum {
	None,
	Malformed,
	Replay,
	Auth, // the tag did not verify: wrong key, or tampered in flight
}

// sframe_open decrypts into `out` (len(ct) bytes is always enough) and
// returns the plaintext. The replay window is updated only on success.
sframe_open :: proc(k: ^Sframe_Key, metadata, ct, out: []u8) -> (pt: []u8, err: Open_Error) {
	kid, ctr, hn, ok := sframe_header_decode(ct)
	if !ok || kid != k.kid || len(ct) < hn + SF_NT {
		return nil, .Malformed
	}
	if k.any {
		if ctr <= k.top {
			d := k.top - ctr
			if d >= 64 || k.window & (u64(1) << d) != 0 {
				return nil, .Replay
			}
		}
	}
	aad := make([]u8, hn + len(metadata), context.temp_allocator)
	copy(aad, ct[:hn])
	copy(aad[hn:], metadata)
	nonce := nonce_of(k, ctr)
	body := ct[hn:len(ct) - SF_NT]
	tag := ct[len(ct) - SF_NT:]
	dst := out[:len(body)]
	if !aead.open_ctx(&k.ctx, dst, nonce[:], aad, body, tag) {
		return nil, .Auth
	}
	// Accept: slide the window.
	if !k.any {
		k.any = true
		k.top = ctr
		k.window = 1
	} else if ctr > k.top {
		shift := ctr - k.top
		k.window = shift >= 64 ? 1 : (k.window << shift) | 1
		k.top = ctr
	} else {
		k.window |= u64(1) << (k.top - ctr)
	}
	return dst, .None
}

// frame_metadata is the SFrame metadata PCP2 binds into every frame's AAD:
// the payload type, the keyframe bit, the layer and the capture timestamp.
// The SFU can read all four, and can change none of them without the frame
// failing to open — so it cannot, for instance, mark a predicted frame as a
// keyframe and have a receiver reset its decoder onto it.
frame_metadata :: proc(buf: []u8, ptype: Ptype, keyframe: bool, layer: u8, ts_us: u64) -> []u8 {
	buf[0] = u8(ptype)
	buf[1] = keyframe ? 1 : 0
	buf[2] = layer
	endian.put_u64(buf[3:11], .Big, ts_us)
	return buf[:11]
}
