package pcp

// The library's own checks. `palm-sfu --selftest` and `call --self-test`
// both run these, so a client and a server built from this tree agree on the
// protocol by construction and by test.

import "core:bytes"
import "core:fmt"
import "core:strings"

Tally :: struct {
	pass, fail: int,
	quiet:      bool,
}

check :: proc(t: ^Tally, ok: bool, what: string, args: ..any) {
	if ok {
		t.pass += 1
		if !t.quiet {
			fmt.printf("  ok    ")
			fmt.printfln(what, ..args)
		}
	} else {
		t.fail += 1
		fmt.printf("  FAIL  ")
		fmt.printfln(what, ..args)
	}
}

unhex :: proc(s: string, allocator := context.temp_allocator) -> []u8 {
	clean := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if c != ' ' && c != '\n' && c != '\t' {
			strings.write_byte(&clean, c)
		}
	}
	h := strings.to_string(clean)
	out := make([]u8, len(h) / 2, allocator)
	nib :: proc(c: u8) -> u8 {
		switch c {
		case '0' ..= '9':
			return c - '0'
		case 'a' ..= 'f':
			return c - 'a' + 10
		case 'A' ..= 'F':
			return c - 'A' + 10
		}
		return 0
	}
	for i in 0 ..< len(out) {
		out[i] = nib(h[2 * i]) << 4 | nib(h[2 * i + 1])
	}
	return out
}

run_selftest :: proc(t: ^Tally) {
	fmt.println("pcp: PCP2 header")
	{
		buf: [MAX_PACKET]u8
		h := Header{ptype = .Video_H264, flags = FLAG_KEYFRAME | FLAG_E2EE, seq = 65535, ts_us = 0x0102030405060708, frame = 77, src = 9, layer = 1, level = 0x80 | 23}
		data := make([]u8, 2500, context.temp_allocator)
		for i in 0 ..< len(data) {
			data[i] = u8(i * 7)
		}
		check(t, fragment_count(len(data)) == 3, "2500 bytes is three fragments")
		dg := fragment_into(buf[:], data, 2, h)
		g, payload, ok := parse(dg)
		check(t, ok, "a fragment parses")
		check(t, g.frag == 2 && g.nfrag == 3 && g.flags & FLAG_MARKER != 0, "the last fragment carries the marker")
		check(t, g.src == 9 && g.layer == 1 && g.level == 0x80 | 23 && g.ts_us == 0x0102030405060708, "src, layer, level and timestamp round-trip")
		check(t, len(payload) == 100 && payload[0] == data[2400], "the payload is the tail of the frame")
		stamp_src(dg, 4242)
		g2, _, _ := parse(dg)
		check(t, g2.src == 4242, "the SFU can restamp the source in place")
		dg[5] &= ~FLAG_MARKER
		_, _, bad := parse(dg)
		check(t, !bad, "a marker that disagrees with the counters is rejected")
		dg[5] |= FLAG_MARKER
		dg[3] = '1'
		_, _, bad2 := parse(dg)
		check(t, !bad2, "a PCP1 datagram is not a PCP2 one")
		check(t, level_byte(0) == LEVEL_SILENT, "digital silence is level 127 without VAD")
		lb := level_byte(0.1) // -20 dBov
		check(t, level_vad(lb) && lb & 0x7f == 20, "0.1 of full scale is -20 dBov with VAD (got %d)", lb & 0x7f)
		check(t, !level_vad(level_byte(0.002)), "-54 dBov is below the VAD threshold")
	}

	fmt.println("pcp: control framing")
	{
		buf: [MAX_PACKET]u8
		o: Obj
		obj_begin(&o)
		obj_str(&o, "token", "abc\"def")
		obj_int(&o, "src", 3)
		obj_bool(&o, "muted", true)
		dg := control_into(buf[:], .Join, obj_end(&o), 1, 5)
		h, payload, ok := parse(dg)
		check(t, ok && h.ptype == .Control, "a control datagram parses")
		k, obj, cok := control_parse(payload)
		check(t, cok && k == .Join, "kind round-trips")
		check(t, ostr(obj, "token") == "abc\"def" && oint(obj, "src") == 3 && obool(obj, "muted"), "the body round-trips, quotes included")
		big := strings.repeat("x", 1300, context.temp_allocator)
		check(t, control_into(buf[:], .Peer, big, 0, 0) == nil, "a body that cannot fit one datagram is refused")
		bogus := [?]u8{99, '{', '}'}
		_, _, bk := control_parse(bogus[:])
		check(t, !bk, "an unknown kind is rejected")
	}

	fmt.println("pcp: SFrame header encodings (RFC 9605 Appendix C.1)")
	{
		n_ok := 0
		for c in RFC9605_HEADERS {
			want := unhex(c.hdr)
			b: [SF_MAX_HEADER]u8
			n := sframe_header_encode(b[:], c.kid, c.ctr)
			kid, ctr, m, ok := sframe_header_decode(want)
			if bytes.equal(b[:n], want) && ok && kid == c.kid && ctr == c.ctr && m == len(want) {
				n_ok += 1
			} else {
				check(t, false, "kid %x ctr %x should encode as %s", c.kid, c.ctr, c.hdr)
			}
		}
		check(t, n_ok == len(RFC9605_HEADERS), "all %d header vectors encode and decode exactly", len(RFC9605_HEADERS))
	}

	fmt.println("pcp: SFrame AES_128_GCM_SHA256_128 (RFC 9605 Appendix C.3, suite 0x0004)")
	{
		base := unhex("000102030405060708090a0b0c0d0e0f")
		key, salt := sframe_derive(0x123, base)
		check(t, bytes.equal(key[:], unhex("d34f547f4ca4f9a7447006fe7fcbf768")), "sframe_key matches the RFC")
		check(t, bytes.equal(salt[:], unhex("75234edefe07819026751816")), "sframe_salt matches the RFC")
		k: Sframe_Key
		sframe_key_init(&k, 0x123, base)
		defer sframe_key_clear(&k)
		metadata := unhex("4945544620534672616d65205747")
		pt := unhex("64726166742d696574662d736672616d652d656e63")
		want := unhex("9901234567b7412c2513a1b66dbb48841bbaf17f598751176ad847681a69c6d0b091c07018ce4adb34eb")
		out := make([]u8, len(pt) + SF_MAX_HEADER + SF_NT, context.temp_allocator)
		ct := sframe_seal_ctr(&k, 0x4567, metadata, pt, out)
		check(t, bytes.equal(ct, want), "encrypt(ctr, kid, metadata, pt) == ct, byte for byte")
		rx: Sframe_Key
		sframe_key_init(&rx, 0x123, base)
		defer sframe_key_clear(&rx)
		dst := make([]u8, len(want), context.temp_allocator)
		got, err := sframe_open(&rx, metadata, want, dst)
		check(t, err == .None && bytes.equal(got, pt), "decrypt(metadata, ct) == pt")
		_, err2 := sframe_open(&rx, metadata, want, dst)
		check(t, err2 == .Replay, "the same ciphertext twice is a replay")
		bad := make([]u8, len(want), context.temp_allocator)
		copy(bad, want)
		bad[8] ~= 1
		rx2: Sframe_Key
		sframe_key_init(&rx2, 0x123, base)
		defer sframe_key_clear(&rx2)
		_, err3 := sframe_open(&rx2, metadata, bad, dst)
		check(t, err3 == .Auth, "one flipped bit in flight fails authentication")
		md2 := unhex("4945544620534672616d65205748")
		_, err4 := sframe_open(&rx2, md2, want, dst)
		check(t, err4 == .Auth, "changed metadata (e.g. a forged keyframe bit) fails authentication")
	}

	fmt.println("pcp: what the SFU sees is ciphertext")
	{
		base := [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
		k: Sframe_Key
		sframe_key_init(&k, kid_of(7, 1), base[:])
		defer sframe_key_clear(&k)
		// A JPEG's SOI and a JFIF marker, and an H.264 IDR with SPS/PPS: the
		// byte patterns a forwarder could recognise in a plaintext frame.
		jpeg := unhex("ffd8ffe000104a46494600010101004800480000ffdb004300080606070605080707070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c2837292c30313434341f27393d38323c2e333432")
		h264 := unhex("00000001091000000001674d401fe8802802dd80b501010140000003004000000c83c60c448000000001")
		mbuf: [16]u8
		for pt, i in ([?][]u8{jpeg, h264}) {
			md := frame_metadata(mbuf[:], .Video_H264, true, 0, 12345)
			out := make([]u8, len(pt) + SF_MAX_HEADER + SF_NT, context.temp_allocator)
			ct := sframe_seal(&k, md, pt, out)
			check(t, !bytes.contains(ct, pt[:4]) && !bytes.contains(ct, pt[4:12]), "frame %d: no plaintext marker survives encryption", i)
			check(t, len(ct) <= len(pt) + SF_MAX_HEADER + SF_NT, "frame %d: overhead is at most header + 16-byte tag (%d bytes)", i, len(ct) - len(pt))
		}
	}

	fmt.println("pcp: sealing base keys, rotation, safety code")
	{
		a, b, c := keypair_generate(), keypair_generate(), keypair_generate()
		base := [BASE_KEY_SIZE]u8{9, 9, 9, 9, 9, 9, 9, 9, 1, 2, 3, 4, 5, 6, 7, 8}
		kid := kid_of(1, 3)
		sealed: [SEALED_SIZE]u8
		check(t, seal_base_key(&a, b.public[:], kid, "call-1", base[:], &sealed), "Alice seals her key to Bob")
		got: [BASE_KEY_SIZE]u8
		check(t, open_base_key(&b, a.public[:], kid, "call-1", sealed[:], &got) && got == base, "Bob opens it")
		check(t, !open_base_key(&c, a.public[:], kid, "call-1", sealed[:], &got), "Carol, who it was not sealed to, cannot")
		check(t, !open_base_key(&b, a.public[:], kid, "call-2", sealed[:], &got), "it does not open in another call")
		check(t, !open_base_key(&b, a.public[:], kid_of(1, 4), "call-1", sealed[:], &got), "nor as another generation")
		check(t, !open_base_key(&b, c.public[:], kid, "call-1", sealed[:], &got), "nor as if another sender sent it")
		zero: [32]u8
		check(t, !seal_base_key(&a, zero[:], kid, "call-1", base[:], &sealed), "a low-order public key is refused")
		check(t, !bytes.contains(sealed[:], base[:8]), "the sealed blob does not contain the key")

		ring: Keyring
		defer keyring_destroy(&ring)
		keyring_add(&ring, kid_of(1, 1), base[:], 10)
		base2 := base
		base2[0] = 1
		keyring_add(&ring, kid_of(1, 2), base2[:], 11)
		check(t, keyring_find(&ring, kid_of(1, 1)) != nil && keyring_find(&ring, kid_of(1, 2)) != nil, "after rotation both generations decrypt for a while")
		keyring_prune(&ring, 11 + ROTATE_GRACE + 0.1)
		check(t, keyring_find(&ring, kid_of(1, 1)) == nil && keyring_find(&ring, kid_of(1, 2)) != nil, "the old one expires after the grace period")
		keyring_prune(&ring, 20, []u16{2, 3})
		check(t, len(ring.keys) == 0, "a source that left loses all its keys")

		roster := []Safety_Entry{{"id-a", a.public}, {"id-b", b.public}, {"id-c", c.public}}
		shuffled := []Safety_Entry{{"id-c", c.public}, {"id-a", a.public}, {"id-b", b.public}}
		s1 := safety_code(roster, context.temp_allocator)
		s2 := safety_code(shuffled, context.temp_allocator)
		check(t, s1 == s2, "every participant computes the same safety code (%s)", s1)
		check(t, len(s1) == 29, "it is five groups of five digits")
		mitm := keypair_generate()
		forged := []Safety_Entry{{"id-a", a.public}, {"id-b", mitm.public}, {"id-c", c.public}}
		check(t, safety_code(forged, context.temp_allocator) != s1, "a substituted public key changes the code")
	}

	fmt.println("pcp: dominant speaker")
	{
		d: Speaker_Detector
		defer delete(d.parts)
		loud := level_byte(0.15) // about -16 dBov
		quiet := level_byte(0.002)
		tt := 0.0
		changes := make([dynamic]u16, context.temp_allocator)
		times := make([dynamic]f64, context.temp_allocator)
		// A talks 0-2 s, B 2-4 s, C 4-6 s; everyone sends a packet every 20 ms.
		for step in 0 ..< 300 {
			tt = f64(step) * 0.02
			for src in u16(1) ..= 3 {
				talking := int(tt / 2) == int(src) - 1
				speaker_feed(&d, src, talking ? loud : quiet, tt)
			}
			if speaker_tick(&d, tt) {
				append(&changes, d.current)
				append(&times, tt)
			}
		}
		check(t, len(changes) == 3 && changes[0] == 1 && changes[1] == 2 && changes[2] == 3, "the speaker goes A, B, C and nowhere else (%v)", changes[:])
		if len(times) == 3 {
			check(t, times[1] - 2.0 < 0.8 && times[2] - 4.0 < 0.8, "each switch lands within 0.8 s of the turn (%.2f, %.2f)", times[1], times[2])
		}
		// A cough from B while A talks must not take the floor.
		e: Speaker_Detector
		defer delete(e.parts)
		flaps := 0
		for step in 0 ..< 150 {
			tt = f64(step) * 0.02
			cough := step >= 60 && step < 66 // 120 ms
			speaker_feed(&e, 1, loud, tt)
			speaker_feed(&e, 2, cough ? loud : quiet, tt)
			if speaker_tick(&e, tt) {
				flaps += 1
			}
		}
		check(t, flaps == 1 && e.current == 1, "a 120 ms interjection does not steal the floor")
	}

	fmt.println("pcp: tier selection")
	{
		s: Tier_State
		tier_init(&s)
		check(t, s.tier == .High, "a receiver starts on the high layer")
		check(t, !tier_update(&s, 0, 700, 0, 2, 0.5), "clean reports keep it there")
		// A link that carries 400 kbit/s, two senders: High needs 750.
		ch := tier_update(&s, 30, 400, 0, 2, 1.0)
		check(t, ch && s.tier == .Low, "heavy loss drops it to the low layer (est %.0f)", s.est)
		ups := 0
		for i in 0 ..< 40 {
			if tier_update(&s, 0, 300, 0, 2, 1.5 + f64(i) * 0.5) && s.tier == .High {
				ups += 1
			}
		}
		check(t, s.tier == .Low || ups <= 2, "it does not flap back up every report (ups %d)", ups)
		s2: Tier_State
		tier_init(&s2)
		tier_update(&s2, 40, 120, 0, 2, 1.0)
		check(t, s2.tier == .Audio, "a 120 kbit/s link for two senders is audio only")
		s3: Tier_State
		tier_init(&s3)
		tier_update(&s3, 0, 0, 200, 1, 1.0)
		check(t, s3.tier == .Low, "a declared 200 kbit/s ceiling for one sender selects low")
		s4: Tier_State
		tier_init(&s4)
		tier_update(&s4, 30, 300, 0, 1, 0)
		check(t, s4.tier == .Low, "one sender, 300 kbit/s under loss: low")
		for i in 0 ..< 30 {
			tier_update(&s4, 0, 700, 0, 1, 1 + f64(i) * 0.5)
		}
		check(t, s4.tier == .High, "and when the link recovers it climbs back to high")
	}

	fmt.println("pcp: join tokens")
	{
		secret := transmute([]u8)string("test-secret-not-for-production")
		tok := token_mint(secret, Join{call = "c1", ch = "ch1", id = "id1", handle = "alice", name = "Alice \"A\" Martin", color = "indigo", e2ee = true}, context.temp_allocator)
		j, err := token_verify(secret, tok, allocator = context.temp_allocator)
		check(t, err == .None && j.call == "c1" && j.name == "Alice \"A\" Martin" && j.e2ee, "a fresh token verifies and round-trips")
		_, err2 := token_verify(transmute([]u8)string("other"), tok, allocator = context.temp_allocator)
		check(t, err2 == .Bad_Mac, "another secret rejects it")
		_, err3 := token_verify(secret, tok, now = j.exp + 1, allocator = context.temp_allocator)
		check(t, err3 == .Expired, "an expired token is refused")
		forged := strings.concatenate({b64url_encode(transmute([]u8)string(`{"v":1,"call":"c2","id":"id1","exp":9999999999}`), context.temp_allocator), tok[strings.last_index_byte(tok, '.'):]}, context.temp_allocator)
		_, err4 := token_verify(secret, forged, allocator = context.temp_allocator)
		check(t, err4 == .Bad_Mac, "a payload swapped under an old MAC is refused")
		pj, pok := token_peek(tok, context.temp_allocator)
		check(t, pok && pj.handle == "alice", "a client can read its own token's claims")
	}
}
