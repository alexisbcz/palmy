package main

// palm-sfu --selftest: the protocol library's checks, then a real SFU on a
// loopback port with fake participants that speak PCP2 over real sockets.
// Nothing is mocked except the people.

import "core:bytes"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import pcp "../pcp"
import w "../../../apps/chat/wire"

Got :: struct {
	h:       pcp.Header,
	kind:    pcp.Kind,
	body:    string,
	payload: []u8,
}

Fake :: struct {
	name: string,
	sock: net.UDP_Socket,
	kp:   pcp.Keypair,
	src:  u16,
	got:  [dynamic]Got,
	seq:  u16,
	buf:  [pcp.MAX_PACKET + 64]u8,
}

fake_open :: proc(name: string) -> ^Fake {
	f := new(Fake)
	f.name = name
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	assert(err == nil)
	net.set_blocking(sock, false)
	f.sock = sock
	f.kp = pcp.keypair_generate()
	return f
}

fake_close :: proc(f: ^Fake) {
	net.close(f.sock)
	for g in f.got {
		delete(g.body)
		delete(g.payload)
	}
	delete(f.got)
	free(f)
}

fake_ctl :: proc(f: ^Fake, to: net.Endpoint, kind: pcp.Kind, body: string) {
	f.seq += 1
	dg := pcp.control_into(f.buf[:], kind, body, f.seq, 0)
	net.send_udp(f.sock, dg, to)
}

fake_drain :: proc(f: ^Fake) {
	rx: [pcp.MAX_PACKET + 64]u8
	for {
		n, _, err := net.recv_udp(f.sock, rx[:])
		if err != nil || n <= 0 {
			return
		}
		h, payload, ok := pcp.parse(rx[:n])
		if !ok {
			continue
		}
		g := Got{h = h}
		if h.ptype == .Control {
			k, _, cok := pcp.control_parse(payload)
			if cok {
				g.kind = k
				g.body = strings.clone(string(payload[1:]))
			}
		} else {
			g.payload = bytes.clone(payload)
		}
		append(&f.got, g)
	}
}

pump :: proc(s: ^Sfu, fakes: []^Fake, rounds := 20) {
	for _ in 0 ..< rounds {
		sfu_step(s)
		for f in fakes {
			fake_drain(f)
		}
	}
}

fake_clear :: proc(f: ^Fake) {
	for g in f.got {
		delete(g.body)
		delete(g.payload)
	}
	clear(&f.got)
}

last_ctl :: proc(f: ^Fake, kind: pcp.Kind) -> (o: json.Object, ok: bool) {
	for i := len(f.got) - 1; i >= 0; i -= 1 {
		if f.got[i].kind == kind && f.got[i].h.ptype == .Control {
			v, err := json.parse(transmute([]u8)f.got[i].body, allocator = context.temp_allocator)
			if err != nil {
				return nil, false
			}
			obj, is := v.(json.Object)
			return obj, is
		}
	}
	return nil, false
}

count_media :: proc(f: ^Fake, pt: pcp.Ptype, layer := -1) -> int {
	n := 0
	for g in f.got {
		if g.h.ptype == pt && (layer < 0 || int(g.h.layer) == layer) {
			n += 1
		}
	}
	return n
}

join_body :: proc(token: string, kp: ^pcp.Keypair) -> string {
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_str(&o, "token", token)
	pcp.obj_str(&o, "pub", base64.encode(kp.public[:], allocator = context.temp_allocator))
	return pcp.obj_end(&o)
}

send_frame :: proc(f: ^Fake, to: net.Endpoint, pt: pcp.Ptype, data: []u8, layer: u8, keyframe: bool, frame: u32, level: u8 = pcp.LEVEL_SILENT, spoof_src: u16 = 0) {
	h := pcp.Header{ptype = pt, flags = pcp.FLAG_E2EE | (keyframe ? pcp.FLAG_KEYFRAME : 0), ts_us = 1, frame = frame, src = spoof_src, layer = layer, level = level}
	nf := pcp.fragment_count(len(data))
	for i in 0 ..< nf {
		f.seq += 1
		h.seq = f.seq
		dg := pcp.fragment_into(f.buf[:], data, i, h)
		net.send_udp(f.sock, dg, to)
	}
}

run_selftest :: proc() -> int {
	t: pcp.Tally
	t.quiet = false
	pcp.run_selftest(&t)

	fmt.println("sfu: a real SFU on loopback, with fake participants")
	s := new(Sfu)
	s.quiet = true
	s.secret = transmute([]u8)string("selftest-secret")
	err := sfu_open(s, net.IP4_Loopback, 0)
	pcp.check(&t, err == "", "the SFU binds a loopback port")
	bep, _ := net.bound_endpoint(s.sock)
	s.port = bep.port
	to := net.Endpoint{net.IP4_Loopback, bep.port}
	a4, is4 := bep.address.(net.IP4_Address)
	pcp.check(&t, is4 && a4 == net.IP4_Loopback, "and it is 127.0.0.1, not 0.0.0.0")

	a, b, c := fake_open("alice"), fake_open("bob"), fake_open("carol")
	d, e := fake_open("dave"), fake_open("eve")
	all := []^Fake{a, b, c, d, e}
	defer for f in all {
		fake_close(f)
	}
	mint :: proc(s: ^Sfu, call, id, handle: string, exp: i64 = 0) -> string {
		return pcp.token_mint(s.secret, pcp.Join{call = call, ch = "ch-1", id = id, handle = handle, name = handle, color = "indigo", e2ee = true, exp = exp}, context.temp_allocator)
	}
	fake_ctl(a, to, .Join, join_body(mint(s, "call-1", "id-a", "alice"), &a.kp))
	pump(s, all)
	fake_ctl(b, to, .Join, join_body(mint(s, "call-1", "id-b", "bob"), &b.kp))
	pump(s, all)
	fake_ctl(c, to, .Join, join_body(mint(s, "call-1", "id-c", "carol"), &c.kp))
	fake_ctl(d, to, .Join, join_body(mint(s, "call-2", "id-d", "dave"), &d.kp))
	pump(s, all)
	for f in ([]^Fake{a, b, c, d}) {
		o, ok := last_ctl(f, .Welcome)
		f.src = u16(pcp.oint(o, "src"))
		pcp.check(&t, ok && f.src != 0, "%s is welcomed as src %d", f.name, f.src)
	}
	pcp.check(&t, a.src != b.src && b.src != c.src && a.src != c.src, "sources are distinct in a room")
	ro, _ := last_ctl(a, .Roster)
	pcp.check(&t, len(pcp.oarr(ro, "srcs")) == 3, "Alice's roster has three people")
	dro, _ := last_ctl(d, .Roster)
	pcp.check(&t, len(pcp.oarr(dro, "srcs")) == 1, "a different call is a different room (Dave is alone)")
	peers := 0
	for g in c.got {
		if g.kind == .Peer {
			peers += 1
		}
	}
	pcp.check(&t, peers >= 3, "Carol learns everyone's name and public key (%d PEER messages)", peers)

	// Refused joins.
	bad := mint(s, "call-1", "id-e", "eve")
	bad_b := transmute([]u8)strings.clone(bad, context.temp_allocator)
	bad_b[10] = bad_b[10] == 'A' ? 'B' : 'A'
	fake_ctl(e, to, .Join, join_body(string(bad_b), &e.kp))
	pump(s, all)
	eo, eok := last_ctl(e, .Error)
	pcp.check(&t, eok && pcp.ostr(eo, "code") == "bad_token", "a tampered token is refused")
	fake_ctl(e, to, .Join, join_body(mint(s, "call-1", "id-e", "eve", time.time_to_unix(time.now()) - 5), &e.kp))
	pump(s, all)
	eo, eok = last_ctl(e, .Error)
	pcp.check(&t, eok && pcp.ostr(eo, "code") == "token_expired", "an expired token is refused")
	ro, _ = last_ctl(a, .Roster)
	pcp.check(&t, len(pcp.oarr(ro, "srcs")) == 3, "and Eve is in nobody's roster")
	send_frame(e, to, .Audio_Opus, transmute([]u8)string("let me in"), 0, false, 1)
	pump(s, all)
	pcp.check(&t, count_media(a, .Audio_Opus) == 0, "media from an address that never joined goes nowhere")

	// Keys: Alice seals her base key to Bob, through the SFU.
	base := [pcp.BASE_KEY_SIZE]u8{0xa1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	kid := pcp.kid_of(a.src, 1)
	sealed: [pcp.SEALED_SIZE]u8
	pcp.seal_base_key(&a.kp, b.kp.public[:], kid, "call-1", base[:], &sealed)
	{
		o: pcp.Obj
		pcp.obj_begin(&o)
		pcp.obj_int(&o, "to", i64(b.src))
		pcp.obj_int(&o, "kid", i64(kid))
		pcp.obj_str(&o, "sealed", base64.encode(sealed[:], allocator = context.temp_allocator))
		fake_ctl(a, to, .Key, pcp.obj_end(&o))
	}
	pump(s, all)
	ko, kok := last_ctl(b, .Key)
	pcp.check(&t, kok && u16(pcp.oint(ko, "from")) == a.src, "Bob receives a KEY stamped as from Alice")
	_, ck := last_ctl(c, .Key)
	pcp.check(&t, !ck, "Carol does not receive a key addressed to Bob")
	sealed_rx, _ := base64.decode(pcp.ostr(ko, "sealed"), allocator = context.temp_allocator)
	opened: [pcp.BASE_KEY_SIZE]u8
	pcp.check(&t, pcp.open_base_key(&b.kp, a.kp.public[:], u64(pcp.oint(ko, "kid")), "call-1", sealed_rx, &opened) && opened == base, "and opens it")

	// An encrypted audio frame, with a forged source.
	send_key: pcp.Sframe_Key
	pcp.sframe_key_init(&send_key, kid, base[:])
	defer pcp.sframe_key_clear(&send_key)
	plain := transmute([]u8)string("OPUS-FRAME-PLAINTEXT-HELLO-BOB")
	mb: [16]u8
	md := pcp.frame_metadata(mb[:], .Audio_Opus, false, 0, 1)
	ct_buf: [256]u8
	ct := pcp.sframe_seal(&send_key, md, plain, ct_buf[:])
	ct_copy := bytes.clone(ct)
	defer delete(ct_copy)
	send_frame(a, to, .Audio_Opus, ct, 0, false, 1, pcp.level_byte(0.2), spoof_src = 99)
	pump(s, all)
	got_b: ^Got
	for &g in b.got {
		if g.h.ptype == .Audio_Opus {
			got_b = &g
		}
	}
	pcp.check(&t, got_b != nil && got_b.h.src == a.src, "the SFU restamps the source: Bob sees src %d, not the forged 99", a.src)
	pcp.check(&t, count_media(c, .Audio_Opus) == 1 && count_media(a, .Audio_Opus) == 0, "Carol gets it too, and Alice does not get her own audio back")
	pcp.check(&t, count_media(d, .Audio_Opus) == 0, "nobody in another call hears it")
	if got_b != nil {
		pcp.check(&t, bytes.equal(got_b.payload, ct_copy), "what was forwarded is the sender's ciphertext, byte for byte")
		pcp.check(&t, !bytes.contains(got_b.payload, plain[:10]), "and the plaintext appears nowhere in it")
		rk: pcp.Sframe_Key
		pcp.sframe_key_init(&rk, kid, opened[:])
		out: [256]u8
		pt, oerr := pcp.sframe_open(&rk, md, got_b.payload, out[:])
		pcp.check(&t, oerr == .None && bytes.equal(pt, plain), "Bob decrypts it with the key Alice sealed to him")
		tampered := bytes.clone(got_b.payload, context.temp_allocator)
		tampered[len(tampered) - 20] ~= 0x40
		rk2: pcp.Sframe_Key
		pcp.sframe_key_init(&rk2, kid, opened[:])
		_, terr := pcp.sframe_open(&rk2, md, tampered, out[:])
		pcp.check(&t, terr == .Auth, "a frame altered in flight does not decrypt")
		pcp.sframe_key_clear(&rk)
		pcp.sframe_key_clear(&rk2)
	}

	// Dominant speaker: Alice talks.
	for i in 0 ..< 30 {
		send_frame(a, to, .Audio_Opus, ct, 0, false, u32(2 + i), pcp.level_byte(0.2))
		send_frame(b, to, .Audio_Opus, ct, 0, false, u32(2 + i), pcp.level_byte(0.001))
		pump(s, all, 2)
	}
	so, sok := last_ctl(c, .Speaker)
	pcp.check(&t, sok && u16(pcp.oint(so, "src")) == a.src, "the SFU names Alice the dominant speaker")

	// Simulcast: Alice sends both layers; Bob and Carol start on high.
	for f in ([]^Fake{a, b, c}) {
		fake_clear(f)
	}
	big := make([]u8, 3000, context.temp_allocator) // three fragments
	small := make([]u8, 800, context.temp_allocator)
	send_frame(a, to, .Video_H264, big, 0, true, 1)
	send_frame(a, to, .Video_H264, small, 1, true, 1)
	pump(s, all)
	pcp.check(&t, count_media(b, .Video_H264, 0) == 3 && count_media(b, .Video_H264, 1) == 0, "a high-tier receiver gets layer 0 only (all three fragments)")
	// Carol reports a bad link.
	{
		o: pcp.Obj
		pcp.obj_begin(&o)
		pcp.obj_f(&o, "loss", 35)
		pcp.obj_f(&o, "kbps", 400)
		fake_ctl(c, to, .Feedback, pcp.obj_end(&o))
	}
	pump(s, all)
	to_o, tok := last_ctl(c, .Tier)
	pcp.check(&t, tok && pcp.ostr(to_o, "tier") == "low", "35%% loss at 400 kbit/s (two senders) moves Carol to the low tier")
	_, akf := last_ctl(a, .Keyframe)
	pcp.check(&t, akf, "and the SFU asks Alice for a keyframe")
	fake_clear(c)
	send_frame(a, to, .Video_H264, big, 0, false, 2)
	send_frame(a, to, .Video_H264, small, 1, false, 2)
	pump(s, all)
	pcp.check(&t, count_media(c, .Video_H264, 0) == 3 && count_media(c, .Video_H264, 1) == 0, "until a low-layer keyframe arrives, Carol keeps the old layer (no gap)")
	fake_clear(c)
	send_frame(a, to, .Video_H264, small, 1, true, 3)
	send_frame(a, to, .Video_H264, big, 0, false, 3)
	send_frame(a, to, .Video_H264, small, 1, false, 4)
	pump(s, all)
	pcp.check(&t, count_media(c, .Video_H264, 1) == 2 && count_media(c, .Video_H264, 0) == 0, "then switches at the keyframe and gets only layer 1")
	pcp.check(&t, count_media(b, .Video_H264, 0) > 0, "while Bob stays on layer 0")
	{
		o: pcp.Obj
		pcp.obj_begin(&o)
		pcp.obj_f(&o, "loss", 50)
		pcp.obj_f(&o, "kbps", 60)
		fake_ctl(c, to, .Feedback, pcp.obj_end(&o))
	}
	pump(s, all)
	to_o, tok = last_ctl(c, .Tier)
	pcp.check(&t, tok && pcp.ostr(to_o, "tier") == "audio", "at 60 kbit/s she drops to audio only")
	fake_clear(c)
	send_frame(a, to, .Video_H264, small, 1, true, 5)
	send_frame(a, to, .Audio_Opus, ct, 0, false, 99, pcp.level_byte(0.2))
	pump(s, all)
	pcp.check(&t, count_media(c, .Video_H264) == 0 && count_media(c, .Audio_Opus) == 1, "and gets audio but no video at all")

	// The gateway link: authenticated, told the roster, able to kick.
	fmt.println("sfu: the gateway control link")
	gl, lerr := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	pcp.check(&t, lerr == nil, "a fake gateway listens")
	gep, _ := net.bound_endpoint(gl)
	s.gw.addr = fmt.aprintf("127.0.0.1:%d", gep.port)
	s.gw.backoff = 1
	sfu_step(s)
	gc, _, aerr := net.accept_tcp(gl)
	pcp.check(&t, aerr == nil && s.gw.up, "the SFU dials it")
	net.set_option(gc, .Receive_Timeout, 500 * time.Millisecond)
	frames := read_frames(gc)
	hello, hok := find_frame(frames, "sfu_hello")
	pcp.check(&t, hok && w.ostr(hello, "mac") == pcp.sfu_hello_mac(s.secret, w.oint(hello, "ts")), "its hello carries a valid MAC")
	room, rok := find_frame(frames, "sfu_room", "call-1")
	pcp.check(&t, rok && len(w.oarr(room, "ids")) == 3, "and it reports the current roster (%d ids)", len(w.oarr(room, "ids")))
	{
		e2: w.Enc
		w.enc_begin(&e2, "sfu_welcome")
		w.send_frame(gc, w.enc_done(&e2))
		e3: w.Enc
		w.enc_begin(&e3, "sfu_kick")
		w.kv_str(&e3, "call", "call-1")
		w.kv_str(&e3, "id", "id-c")
		w.send_frame(gc, w.enc_done(&e3))
	}
	fake_clear(c)
	for _ in 0 ..< 10 {
		pump(s, all, 2)
		time.sleep(2 * time.Millisecond)
	}
	ko2, kicked := last_ctl(c, .Error)
	pcp.check(&t, kicked && pcp.ostr(ko2, "code") == "kicked", "a kick from the gateway reaches Carol")
	ro, _ = last_ctl(a, .Roster)
	pcp.check(&t, len(pcp.oarr(ro, "srcs")) == 2, "and she is gone from Alice's roster")
	frames = read_frames(gc)
	room, rok = find_frame(frames, "sfu_room", "call-1")
	pcp.check(&t, rok && len(w.oarr(room, "ids")) == 2, "the gateway is told the new roster")
	fake_clear(c)
	send_frame(a, to, .Audio_Opus, ct, 0, false, 100, pcp.level_byte(0.2))
	pump(s, all)
	pcp.check(&t, count_media(c, .Audio_Opus) == 0, "and Carol hears nothing more")

	fake_ctl(b, to, .Leave, "{}")
	fake_ctl(a, to, .Leave, "{}")
	pump(s, all)
	frames = read_frames(gc)
	_, eok2 := find_frame(frames, "sfu_end")
	pcp.check(&t, eok2, "when the last person leaves, the gateway hears the call ended")
	net.close(gc)
	net.close(gl)

	fmt.printfln("\n%d checks, %d failures", t.pass, t.fail)
	if t.fail == 0 {
		fmt.println("PASS")
		return 0
	}
	fmt.println("FAIL")
	return 1
}

read_frames :: proc(sock: net.TCP_Socket) -> []json.Object {
	out := make([dynamic]json.Object, context.temp_allocator)
	rd: w.Reader
	buf: [16 * 1024]u8
	deadline := time.tick_now()
	for time.duration_seconds(time.tick_since(deadline)) < 0.3 {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 {
			break
		}
		w.reader_feed(&rd, buf[:n])
		for {
			p, ok := w.reader_next(&rd, context.temp_allocator)
			if !ok {
				break
			}
			if o, good := w.parse_obj(p, context.temp_allocator); good {
				append(&out, o)
			}
		}
	}
	return out[:]
}

find_frame :: proc(frames: []json.Object, t: string, call := "") -> (json.Object, bool) {
	for i := len(frames) - 1; i >= 0; i -= 1 {
		if w.ostr(frames[i], "t") == t && (call == "" || w.ostr(frames[i], "call") == call) {
			return frames[i], true
		}
	}
	return nil, false
}
