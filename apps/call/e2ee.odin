package call

// ---------------------------------------------------------------------------
// End-to-end encryption of the two-party call (PCP1).
//
// Multi-party calls through palm-sfu have been end-to-end encrypted since PCP2
// (SFrame, keys sealed pairwise; PROTOCOL.md, "End-to-end encryption"). The
// direct call was not: anyone who could read the UDP between the two ends —
// on this machine, anyone with CAP_NET_RAW on loopback; on a network, every
// router — read the voice and the picture. This closes that, with the same
// primitives and the same library (cloud/rtc/pcp), and nothing invented:
//
//	key agreement   X25519 (RFC 7748), one ephemeral keypair per call per end
//	key schedule    HKDF-SHA256 (RFC 5869)
//	media           SFrame (RFC 9605), AES_128_GCM_SHA256_128 — the RFC's
//	                own test vectors pass in `call --self-test`
//
// all from Odin's core:crypto.
//
//	shared  = X25519(my_secret, peer_public)          refused if all-zero
//	base_tx = HKDF-SHA256(salt "palm-call-pcp1-v1", shared,
//	                      info "media" || my_public || peer_public, 16)
//	base_rx = the same with the two public keys swapped
//	SFrame key and salt from each base key as RFC 9605 §4.4.2, KID 1
//
// Two directions, two keys, so the (key, counter) pair — the one thing AES-GCM
// cannot survive repeating — is unique by construction: each sender counts its
// own frames from 0 under a key nobody else encrypts with.
//
// THE THREAT MODEL, which is the part to read.
//
// Protected against:
//  - A passive observer of the datagrams (on loopback, a packet capture; on a
//    network, anyone on the path; in a relayed deployment, the relay). It
//    sees the PCP1 header in the clear — payload type, sizes, timing,
//    sequence numbers, frame ids, the keyframe bit, the capture timestamp —
//    and the SFrame header (KID and counter). It does not see one sample of
//    audio or one pixel of video. Asserted in the self-test: the plaintext
//    is absent from every byte that crossed the relay.
//  - Tampering in flight. Every frame is authenticated (AES-GCM, 16-byte
//    tag) over the SFrame header plus metadata bound from the clear PCP1
//    header: payload type, keyframe bit, capture timestamp and frame id. So
//    a relay that flips the keyframe bit to make a receiver reset its
//    decoder onto a predicted frame, or rewrites a timestamp, makes the
//    frame fail to open, and it is dropped and counted.
//  - Replay. Each receive key keeps SRTP's 64-frame sliding window: a frame
//    already opened is refused, and so is one older than the window.
//  - Injection and downgrade. Once a call has keys, a media datagram
//    without FLAG_E2EE is refused at the receiver, and the sender never
//    sends media in the clear: before the peer's key has arrived, frames are
//    dropped (and counted), not sent unencrypted. A relay that strips the
//    public key out of the signalling gets a call with no media, not a call
//    in the clear.
//  - Reuse of keys across calls, and the past. The keypair is made when a
//    call begins and discarded when it ends; the peer's key is pinned for the
//    length of the call, so a replayed old INVITE cannot drag the session back
//    onto an old key (and a counter back to zero). Recording a call and later
//    stealing the device opens nothing: the secrets that could have opened it
//    no longer exist (forward secrecy, per call).
//
// Not protected against, stated plainly:
//  - An active man in the middle during key agreement. The public keys ride in
//    unauthenticated signalling; an attacker who can rewrite datagrams can
//    substitute its own key in each direction and re-encrypt. This is the same
//    limit as the multi-party call and has the same detection: both ends
//    show a *safety code* — SHA-256 over the two public keys, as five groups
//    of five digits — and a substituted key makes the two codes differ. Read
//    it aloud. Binding keys to device identities enrolled in the account is
//    the fix that makes the comparison unnecessary, and it is not built.
//  - Metadata. Who calls whom, when, for how long, how loudly (packet sizes
//    track speech), and the clear header fields listed above.
//  - Signalling. INVITE/ACCEPT/BYE/STATE/FEEDBACK are not authenticated, so an
//    active attacker can end a call or lie about mute state or loss. That is
//    denial of service, which an attacker on the path has anyway by dropping
//    packets; it never yields media.
//  - The endpoints themselves: malware on either machine, or the other
//    person, sees everything.
// ---------------------------------------------------------------------------

import "core:crypto"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import pcp "../../cloud/rtc/pcp"

E2EE_KID :: u64(1)
E2EE_SALT :: "palm-call-pcp1-v1"
// Room for the SFrame header and tag around a frame.
E2EE_OVERHEAD :: pcp.SF_MAX_HEADER + pcp.SF_NT

E2ee :: struct {
	// Whether this end insists on encryption. On by default; only the
	// self-test's raw sessions run without it.
	required: bool,

	kp:        pcp.Keypair,
	peer_pub:  [32]u8,
	have_peer: bool,
	// Heap-allocated so an AEAD context never moves after it is set up.
	tx, rx:    ^pcp.Sframe_Key,
	safety:    string,
	// The last call's code, kept for the summary after its keys are gone.
	last_safety: string,

	// Scratch for one sealed or opened frame.
	buf: [dynamic]u8,

	// Counters, each the answer to "what happened to the frames that did not
	// play".
	sealed:        int,
	opened:        int,
	tx_no_key:     int, // media held back: no peer key yet
	rx_clear:      int, // media without FLAG_E2EE, refused
	rx_no_key:     int, // ciphertext before we had the peer's key
	rx_auth:       int, // failed authentication: tampered, or the wrong key
	rx_replay:     int, // refused by the replay window
	rx_malformed:  int,
	peer_key_changes_ignored: int,
}

e2ee_init :: proc(e: ^E2ee) {
	e.required = true
	e.buf = make([dynamic]u8, 0, 64 * 1024)
	e2ee_new_call(e)
}

e2ee_destroy :: proc(e: ^E2ee) {
	e2ee_forget(e)
	delete(e.last_safety)
	e.last_safety = ""
	delete(e.buf)
	e.buf = nil
	crypto.zero_explicit(&e.kp, size_of(e.kp))
}

@(private = "file")
e2ee_forget :: proc(e: ^E2ee) {
	if e.tx != nil {
		pcp.sframe_key_clear(e.tx)
		free(e.tx)
		e.tx = nil
	}
	if e.rx != nil {
		pcp.sframe_key_clear(e.rx)
		free(e.rx)
		e.rx = nil
	}
	if e.safety != "" {
		delete(e.last_safety)
		e.last_safety = e.safety
		e.safety = ""
	}
	e.have_peer = false
	e.peer_pub = {}
}

// e2ee_new_call discards every key and makes a fresh keypair. Called when a
// session opens and whenever a call ends, so no two calls share a secret.
e2ee_new_call :: proc(e: ^E2ee) {
	e2ee_forget(e)
	crypto.zero_explicit(&e.kp, size_of(e.kp))
	e.kp = pcp.keypair_generate()
}

e2ee_ready :: proc(e: ^E2ee) -> bool {
	return e.tx != nil && e.rx != nil
}

// e2ee_derive is the key schedule above, for one direction.
e2ee_derive :: proc(shared: []u8, from_pub, to_pub: []u8) -> (base: [pcp.BASE_KEY_SIZE]u8) {
	info: [5 + 64]u8
	copy(info[:5], "media")
	copy(info[5:37], from_pub)
	copy(info[37:69], to_pub)
	salt := E2EE_SALT
	hkdf.extract_and_expand(.SHA256, transmute([]u8)salt, shared, info[:], base[:])
	return
}

// e2ee_on_peer_key takes the peer's public key from a signalling message.
// The first one of a call is pinned; a different one later in the same call
// is ignored and counted (see the threat model: an old INVITE replayed
// mid-call must not move the session onto another key). Returns false when
// the key is unusable — a low-order point, which forces a known secret.
e2ee_on_peer_key :: proc(e: ^E2ee, pub: [32]u8) -> bool {
	if e.have_peer {
		if pub != e.peer_pub {
			e.peer_key_changes_ignored += 1
		}
		return true
	}
	pub := pub
	shared: [32]u8
	x25519.scalarmult(shared[:], e.kp.secret[:], pub[:])
	zero := true
	for b in shared {
		if b != 0 {
			zero = false
		}
	}
	if zero {
		return false
	}
	tx := e2ee_derive(shared[:], e.kp.public[:], pub[:])
	rx := e2ee_derive(shared[:], pub[:], e.kp.public[:])
	crypto.zero_explicit(&shared, size_of(shared))
	e.tx = new(pcp.Sframe_Key)
	e.rx = new(pcp.Sframe_Key)
	pcp.sframe_key_init(e.tx, E2EE_KID, tx[:])
	pcp.sframe_key_init(e.rx, E2EE_KID, rx[:])
	crypto.zero_explicit(&tx, size_of(tx))
	crypto.zero_explicit(&rx, size_of(rx))
	e.peer_pub = pub
	e.have_peer = true
	entries := [2]pcp.Safety_Entry{{id = "", pub = e.kp.public}, {id = "", pub = pub}}
	e.safety = pcp.safety_code(entries[:])
	return true
}

// e2ee_metadata is what each frame's tag also covers, from the clear header:
// payload type, keyframe bit, capture timestamp, frame id.
e2ee_metadata :: proc(buf: []u8, ptype: Payload_Type, keyframe: bool, ts_us: u64, frame: u32) -> []u8 {
	buf[0] = u8(ptype)
	buf[1] = keyframe ? 1 : 0
	put_u64(buf[2:10], ts_us)
	put_u32(buf[10:14], frame)
	return buf[:14]
}

// e2ee_seal encrypts one whole frame (before fragmentation). The result
// borrows the session's scratch buffer until the next call.
e2ee_seal :: proc(e: ^E2ee, ptype: Payload_Type, keyframe: bool, ts_us: u64, frame: u32, pt: []u8) -> []u8 {
	resize(&e.buf, len(pt) + E2EE_OVERHEAD)
	md: [16]u8
	out := pcp.sframe_seal(e.tx, e2ee_metadata(md[:], ptype, keyframe, ts_us, frame), pt, e.buf[:])
	e.sealed += 1
	return out
}

// e2ee_open authenticates and decrypts one reassembled frame. The result
// borrows the session's scratch buffer until the next call.
e2ee_open :: proc(e: ^E2ee, h: Header, ts_us: u64, ct: []u8) -> (pt: []u8, ok: bool) {
	if e.rx == nil {
		e.rx_no_key += 1
		return nil, false
	}
	resize(&e.buf, len(ct))
	md: [16]u8
	out, err := pcp.sframe_open(e.rx, e2ee_metadata(md[:], h.ptype, keyframed(h), ts_us, h.frame), ct, e.buf[:])
	switch err {
	case .None:
		e.opened += 1
		return out, true
	case .Auth:
		e.rx_auth += 1
	case .Replay:
		e.rx_replay += 1
	case .Malformed:
		e.rx_malformed += 1
	}
	return nil, false
}

// e2ee_status is one line for the statistics panel and the summary.
e2ee_status :: proc(e: ^E2ee) -> string {
	if !e.required {
		return "off"
	}
	if !e2ee_ready(e) {
		return "waiting for the peer's key"
	}
	return "SFrame AES-128-GCM, X25519"
}
