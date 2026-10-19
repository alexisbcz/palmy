package call

// ---------------------------------------------------------------------------
// The headless self-test: `call --self-test`.
//
// No window, no compositor, no UI. It exercises the parts of the pipeline that
// can be wrong without being visibly wrong: the header, the fragmenter, the
// reassembler over a real loopback socket, the jitter buffer under reordering
// and loss, the MJPEG splitter against a stream ffmpeg actually produced, and
// the Opus round trip.
//
// Each check prints a line and bumps a counter, and the exit status is the
// number of failures, so this is usable from a script.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import pcp "../../cloud/rtc/pcp"

Tally :: struct {
	checks: int,
	fails:  int,
}

@(private = "file")
T: Tally

group :: proc(name: string) {
	fmt.printfln("\n── %s", name)
}

check :: proc(cond: bool, format: string, args: ..any) {
	T.checks += 1
	msg := fmt.tprintf(format, ..args)
	if cond {
		fmt.printfln("  ok    %s", msg)
	} else {
		T.fails += 1
		fmt.printfln("  FAIL  %s", msg)
	}
}

check_eq_int :: proc(got, want: int, format: string, args: ..any) {
	T.checks += 1
	msg := fmt.tprintf(format, ..args)
	if got == want {
		fmt.printfln("  ok    %s = %d", msg, got)
	} else {
		T.fails += 1
		fmt.printfln("  FAIL  %s = %d, wanted %d", msg, got, want)
	}
}

// ---------------------------------------------------------------------------

run_self_test :: proc() -> int {
	fmt.println("call: headless pipeline self-test")

	test_header()
	test_fragmentation()
	test_loopback_roundtrip()
	test_loopback_reordered()
	test_loopback_lossy()
	test_jitter()
	test_control()
	test_mjpeg_split()
	test_opus()
	test_bind_is_loopback()
	test_pipe_fds()
	test_duplex_child()
	test_device_parsing()
	test_codec_negotiation()
	test_keyframe_flag()
	test_h264_split()
	test_keyframe_loss_path()
	test_pcp2_library()
	test_room_e2ee()

	fmt.printfln("\n%d checks, %d failures", T.checks, T.fails)
	if T.fails == 0 {
		fmt.println("PASS")
	} else {
		fmt.println("FAIL")
	}
	return T.fails == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// 1. The header
// ---------------------------------------------------------------------------

test_header :: proc() {
	group("header round trip")

	want := Header {
		ptype = .Video_JPEG,
		flags = FLAG_MARKER,
		seq   = 0xBEEF,
		ts_us = 0x0123_4567_89AB_CDEF,
		frame = 0xDEAD_BEEF,
		frag  = 6,
		nfrag = 7,
	}
	buf: [HDR + 4]u8
	check(write_header(buf[:], want), "write_header accepted a full buffer")
	copy(buf[HDR:], []u8{1, 2, 3, 4})

	got, payload, ok := parse(buf[:])
	check(ok, "parse accepted the datagram")
	check(got.ptype == want.ptype, "payload type survives")
	check(got.seq == want.seq, "sequence survives (%d)", got.seq)
	check(got.ts_us == want.ts_us, "64-bit timestamp survives (%x)", got.ts_us)
	check(got.frame == want.frame, "frame id survives (%x)", got.frame)
	check(got.frag == want.frag && got.nfrag == want.nfrag, "fragment counters survive")
	check(marked(got), "marker bit survives")
	check(len(payload) == 4 && payload[0] == 1 && payload[3] == 4, "payload is the tail of the datagram")

	short: [HDR - 1]u8
	_, _, sok := parse(short[:])
	check(!sok, "a datagram shorter than the header is rejected")

	bad := buf
	bad[0] = 'X'
	_, _, bok := parse(bad[:])
	check(!bok, "a bad magic is rejected")

	badtype := buf
	badtype[4] = 99
	_, _, tok := parse(badtype[:])
	check(!tok, "an unknown payload type is rejected")

	// The marker bit must agree with the counters, or a receiver cannot trust
	// either of them.
	mismatch := buf
	mismatch[5] = 0 // clear the marker on the last fragment
	_, _, mok := parse(mismatch[:])
	check(!mok, "marker that disagrees with the fragment count is rejected")

	zero := buf
	put_u16(zero[22:24], 0) // nfrag = 0
	_, _, zok := parse(zero[:])
	check(!zok, "a zero fragment count is rejected")

	// Wrapping comparisons, which is what makes a 16-bit sequence usable.
	check(seq_newer_u16(0, 65535), "seq 0 is newer than 65535")
	check(!seq_newer_u16(65535, 0), "seq 65535 is not newer than 0")
	check(seq_newer_u32(2, 1), "frame 2 is newer than 1")
	check(seq_newer_u32(0, 0xFFFF_FFFF), "frame 0 is newer than 0xffffffff")
}

// ---------------------------------------------------------------------------
// 2. Fragmentation arithmetic
// ---------------------------------------------------------------------------

test_fragmentation :: proc() {
	group("fragmentation")

	check_eq_int(fragment_count(0), 1, "an empty payload is one packet")
	check_eq_int(fragment_count(1), 1, "one byte is one packet")
	check_eq_int(fragment_count(MTU_PAYLOAD), 1, "exactly one MTU is one packet")
	check_eq_int(fragment_count(MTU_PAYLOAD + 1), 2, "one byte over is two packets")
	check_eq_int(fragment_count(64 * 1024), 55, "64 KiB at 1200 B")

	// Every fragment but the last is a full payload, and only the last is
	// marked. A receiver depends on both.
	data := make([]u8, 3000)
	defer delete(data)
	for i in 0 ..< len(data) {
		data[i] = u8(i)
	}
	out: [MAX_PACKET]u8
	n := fragment_count(len(data))
	total := 0
	marks := 0
	for i in 0 ..< n {
		dg := fragment_into(out[:], data, i, .Video_JPEG, u16(i), 7, 1)
		h, payload, ok := parse(dg)
		check(ok, "fragment %d parses", i)
		total += len(payload)
		if marked(h) {
			marks += 1
		}
		if i < n - 1 {
			check_eq_int(len(payload), MTU_PAYLOAD, "fragment %d is a full payload", i)
		}
	}
	check_eq_int(total, len(data), "fragments add up to the payload")
	check_eq_int(marks, 1, "exactly one fragment is marked")
}

// ---------------------------------------------------------------------------
// 3-5. Real loopback sockets
// ---------------------------------------------------------------------------

TEST_PORT_A :: 47990
TEST_PORT_B :: 47991

@(private = "file")
Pair :: struct {
	a, b:   net.UDP_Socket,
	ep_a:   net.Endpoint,
	ep_b:   net.Endpoint,
	opened: bool,
}

@(private = "file")
open_pair :: proc() -> (pr: Pair, ok: bool) {
	sa, ea := net.make_bound_udp_socket(LOOPBACK, TEST_PORT_A)
	if ea != nil {
		fmt.printfln("  SKIP  cannot bind 127.0.0.1:%d (%v)", TEST_PORT_A, ea)
		return {}, false
	}
	sb, eb := net.make_bound_udp_socket(LOOPBACK, TEST_PORT_B)
	if eb != nil {
		net.close(sa)
		fmt.printfln("  SKIP  cannot bind 127.0.0.1:%d (%v)", TEST_PORT_B, eb)
		return {}, false
	}
	net.set_blocking(sb, false)
	net.set_option(sa, .Send_Buffer_Size, 1 << 21)
	net.set_option(sb, .Receive_Buffer_Size, 1 << 21)
	return Pair {
			a = sa,
			b = sb,
			ep_a = {LOOPBACK, TEST_PORT_A},
			ep_b = {LOOPBACK, TEST_PORT_B},
			opened = true,
		},
		true
}

@(private = "file")
close_pair :: proc(pr: ^Pair) {
	if pr.opened {
		net.close(pr.a)
		net.close(pr.b)
		pr.opened = false
	}
}

// drain pulls everything waiting on the socket into the reassembler and
// returns the first frame it completes. Loopback delivery is immediate but not
// synchronous, so it retries briefly rather than assuming.
@(private = "file")
drain :: proc(pr: ^Pair, r: ^Reassembler) -> (out: []u8, ok: bool) {
	rx: [MAX_PACKET + 64]u8
	for attempt in 0 ..< 200 {
		for {
			n, from, err := net.recv_udp(pr.b, rx[:])
			if err != nil || n == 0 {
				break
			}
			if from.port != TEST_PORT_A {
				continue
			}
			h, payload, good := parse(rx[:n])
			if !good {
				continue
			}
			frame, _, done := reasm_push(r, h, payload)
			if done {
				return frame, true
			}
		}
		if attempt > 0 {
			time.sleep(1 * time.Millisecond)
		}
	}
	return nil, false
}

@(private = "file")
known_buffer :: proc(n: int) -> []u8 {
	// A pattern, not noise: a mismatch then says where it went wrong.
	b := make([]u8, n)
	for i in 0 ..< n {
		b[i] = u8(i * 31 + (i >> 8) * 7)
	}
	return b
}

test_loopback_roundtrip :: proc() {
	group("loopback: packetise, send, reassemble")

	pr, ok := open_pair()
	if !ok {
		return
	}
	defer close_pair(&pr)

	src := known_buffer(64 * 1024)
	defer delete(src)

	out: [MAX_PACKET]u8
	n := fragment_count(len(src))
	sent := 0
	for i in 0 ..< n {
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 12345, 1)
		w, err := net.send_udp(pr.a, dg, pr.ep_b)
		if err == nil && w == len(dg) {
			sent += 1
		}
	}
	check_eq_int(sent, n, "every fragment left the socket")

	r: Reassembler
	reasm_init(&r)
	defer reasm_destroy(&r)

	got, done := drain(&pr, &r)
	check(done, "the frame reassembled")
	if done {
		check_eq_int(len(got), len(src), "reassembled length")
		check(slice.equal(got, src), "reassembled bytes are identical to the input")
	}
	check_eq_int(r.completed, 1, "reassembler completed count")
	check_eq_int(r.dropped, 0, "nothing was dropped")
}

test_loopback_reordered :: proc() {
	group("loopback: deliberately reordered fragments")

	pr, ok := open_pair()
	if !ok {
		return
	}
	defer close_pair(&pr)

	src := known_buffer(24 * 1024)
	defer delete(src)
	n := fragment_count(len(src))

	order := make([]int, n)
	defer delete(order)
	for i in 0 ..< n {
		order[i] = i
	}
	// Shuffled with a fixed seed, so a failure is reproducible and does not
	// depend on whatever core:math/rand's generator API looks like today.
	shuffle_fixed(order)
	check(order[0] != 0 || n == 1, "the send order really is shuffled (first=%d)", order[0])

	out: [MAX_PACKET]u8
	for i in order {
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 777, 2)
		net.send_udp(pr.a, dg, pr.ep_b)
	}

	r: Reassembler
	reasm_init(&r)
	defer reasm_destroy(&r)

	got, done := drain(&pr, &r)
	check(done, "a frame delivered out of order still reassembles")
	if done {
		check_eq_int(len(got), len(src), "reassembled length after reordering")
		check(slice.equal(got, src), "reassembled bytes identical after reordering")
	}
}

test_loopback_lossy :: proc() {
	group("loopback: dropped and duplicated fragments")

	pr, ok := open_pair()
	if !ok {
		return
	}
	defer close_pair(&pr)

	src := known_buffer(12 * 1024)
	defer delete(src)
	n := fragment_count(len(src))
	check(n >= 4, "the test frame is worth fragmenting (%d fragments)", n)

	r: Reassembler
	reasm_init(&r)
	defer reasm_destroy(&r)
	out: [MAX_PACKET]u8

	// Frame 10: drop fragment 2 outright. It must never complete, and the
	// slot must not be mistaken for a complete frame.
	for i in 0 ..< n {
		if i == 2 {
			continue
		}
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 1000, 10)
		net.send_udp(pr.a, dg, pr.ep_b)
	}
	got, done := drain(&pr, &r)
	check(!done, "a frame missing a fragment does not complete")
	check_eq_int(r.completed, 0, "nothing completed on the lossy frame")
	_ = got

	// Frame 11: send every fragment twice. It must complete exactly once, and
	// the duplicates must not corrupt it.
	for i in 0 ..< n {
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(100 + i), 2000, 11)
		net.send_udp(pr.a, dg, pr.ep_b)
		net.send_udp(pr.a, dg, pr.ep_b)
	}
	got2, done2 := drain(&pr, &r)
	check(done2, "a frame with every fragment duplicated completes")
	if done2 {
		check(slice.equal(got2, src), "duplicated fragments do not corrupt the frame")
	}
	check_eq_int(r.completed, 1, "it completed exactly once")

	// Everything still queued for frame 11 is now late, and frame 10's slot
	// is still half-open; neither may complete anything.
	again, done3 := drain(&pr, &r)
	check(!done3, "the duplicate tail does not complete a second frame")
	_ = again
	check(r.late > 0, "late fragments were counted (%d)", r.late)

	// And the oldest incomplete frame is evicted rather than held forever.
	for f in u32(12) ..= u32(20) {
		for i in 0 ..< n {
			dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 3000, f)
			net.send_udp(pr.a, dg, pr.ep_b)
			drain(&pr, &r)
		}
	}
	check(r.completed >= 2, "later frames keep completing (%d total)", r.completed)

	// A straggler close behind the last delivered frame is still a straggler.
	before_late := r.late
	for i in 0 ..< n {
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 4000, 15)
		net.send_udp(pr.a, dg, pr.ep_b)
	}
	_, done4 := drain(&pr, &r)
	check(!done4, "a frame a few behind the last delivered is rejected as late")
	check(r.late > before_late, "and counted (%d)", r.late - before_late)

	// A peer that restarts, though, begins its frame ids at 1 again from a
	// long way up. Without the restart check that reads as "forever late" and
	// the video never comes back.
	for i in 0 ..< n {
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 5000, 9000)
		net.send_udp(pr.a, dg, pr.ep_b)
	}
	_, done5 := drain(&pr, &r)
	check(done5, "a long call reaches frame 9000")

	before_late = r.late
	for i in 0 ..< n {
		dg := fragment_into(out[:], src, i, .Video_JPEG, u16(i), 6000, 1)
		net.send_udp(pr.a, dg, pr.ep_b)
	}
	got6, done6 := drain(&pr, &r)
	check(done6, "a peer whose frame ids restart at 1 is picked up again")
	if done6 {
		check(slice.equal(got6, src), "and its first frame after the restart is intact")
	}
	check_eq_int(r.late - before_late, 0, "the restart was not counted as late")
}

// ---------------------------------------------------------------------------
// 6. The jitter buffer
// ---------------------------------------------------------------------------

@(private = "file")
payload_for :: proc(seq: u16, b: []u8) -> []u8 {
	for i in 0 ..< len(b) {
		b[i] = u8(int(seq) + i)
	}
	return b
}

test_jitter :: proc() {
	group("jitter buffer")

	body: [40]u8
	out: [A_MAX_PACKET]u8

	// In order.
	{
		j: Jitter
		for s in u16(0) ..< 8 {
			jb_push(&j, s, u64(s) * 20_000, payload_for(s, body[:]))
		}
		played := 0
		for s in u16(0) ..< 8 {
			n, _, res := jb_pop(&j, out[:])
			if res != .Frame {
				break
			}
			check(out[0] == u8(s), "in-order pop %d is frame %d", played, s)
			check_eq_int(n, len(body), "pop %d length", played)
			played += 1
		}
		check_eq_int(played, 8, "every in-order frame played")
		check_eq_int(j.concealed, 0, "nothing concealed in order")
		check_eq_int(j.too_late, 0, "nothing was late in order")
	}

	// Reordered within the window: pushed 3,1,2,0 and played 0,1,2,3. Note
	// that the *first* packet to arrive is the newest one, which is the case a
	// buffer that pins its cursor on arrival order gets wrong.
	{
		j: Jitter
		for s in ([?]u16{3, 1, 2, 0}) {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		seen: [4]u8
		for i in 0 ..< 4 {
			_, _, res := jb_pop(&j, out[:])
			check(res == .Frame, "reordered pop %d is a real frame", i)
			seen[i] = out[0]
		}
		check(
			seen == [4]u8{0, 1, 2, 3},
			"packets arriving 3,1,2,0 play back 0,1,2,3 (got %v)",
			seen,
		)
		check_eq_int(j.concealed, 0, "reordering within the window conceals nothing")
	}

	// A hole: 0,1,3,4 — frame 2 never arrives, so the cursor must conceal it
	// exactly once and then carry on with 3.
	{
		j: Jitter
		for s in ([?]u16{0, 1, 3, 4}) {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		res0: Jitter_Result
		_, _, res0 = jb_pop(&j, out[:])
		check(res0 == .Frame && out[0] == 0, "frame 0 plays")
		_, _, res0 = jb_pop(&j, out[:])
		check(res0 == .Frame && out[0] == 1, "frame 1 plays")
		_, _, res0 = jb_pop(&j, out[:])
		check(res0 == .Concealed, "the missing frame 2 is concealed, not skipped silently")
		_, _, res0 = jb_pop(&j, out[:])
		check(res0 == .Frame && out[0] == 3, "frame 3 plays after the concealment")
		check_eq_int(j.concealed, 1, "exactly one concealment for one hole")
	}

	// Duplicates are absorbed, not played twice.
	{
		j: Jitter
		for _ in 0 ..< 4 {
			jb_push(&j, 5, 0, payload_for(5, body[:]))
		}
		jb_push(&j, 6, 0, payload_for(6, body[:]))
		jb_push(&j, 7, 0, payload_for(7, body[:]))
		check_eq_int(j.duplicates, 3, "three duplicates of one packet counted")
		check_eq_int(j.pushed, 3, "only three distinct packets stored")
	}

	// A packet behind the cursor is discarded: playing it would be playing
	// audio out of order, which is worse than a gap.
	{
		j: Jitter
		for s in u16(10) ..< 14 {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		jb_pop(&j, out[:]) // plays 10, cursor is now 11
		jb_pop(&j, out[:]) // plays 11, cursor is now 12
		ok := jb_push(&j, 10, 0, payload_for(10, body[:]))
		check(!ok, "a packet behind the playout cursor is refused")
		check_eq_int(j.too_late, 1, "it is counted as too late")
	}

	// Beyond the ring: resynchronise rather than conceal hundreds of frames.
	{
		j: Jitter
		for s in u16(0) ..< 4 {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		jb_push(&j, 9000, 0, payload_for(99, body[:]))
		check_eq_int(j.resyncs, 1, "a jump past the ring resynchronises once")
		check(j.cursor == 9000, "the cursor moved to the new sequence (%d)", int(j.cursor))
	}

	// Sequence wrap. 65534, 65535, 0, 1 is a contiguous run.
	{
		j: Jitter
		for s in ([?]u16{65534, 65535, 0, 1}) {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		seen: [4]int
		for i in 0 ..< 4 {
			_, _, res := jb_pop(&j, out[:])
			seen[i] = res == .Frame ? 1 : 0
		}
		check(seen == [4]int{1, 1, 1, 1}, "the run across the 16-bit wrap plays in full")
		check_eq_int(j.concealed, 0, "wrapping conceals nothing")
	}

	// Starvation: an empty buffer reports .Starved and holds its cursor,
	// rather than concealing its way through silence.
	{
		j: Jitter
		_, _, res := jb_pop(&j, out[:])
		check(res == .Starved, "an empty buffer starves rather than conceals")
		jb_push(&j, 0, 0, payload_for(0, body[:]))
		_, _, res2 := jb_pop(&j, out[:])
		check(res2 == .Starved, "below the %d-frame target it still waits", JB_TARGET)
		jb_push(&j, 1, 0, payload_for(1, body[:]))
		jb_push(&j, 2, 0, payload_for(2, body[:]))
		_, _, res3 := jb_pop(&j, out[:])
		check(res3 == .Frame, "at the target depth it starts playing")
	}

	// The stated depth is the stated depth.
	{
		j: Jitter
		check_eq_int(JB_DEPTH * A_FRAME_MS, 320, "ring capacity in ms")
		check_eq_int(JB_TARGET * A_FRAME_MS, 40, "target buffering delay in ms")
		check_eq_int(JB_MAX_HOLD * A_FRAME_MS, 60, "hard ceiling in ms")
		for s in u16(0) ..< 4 {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		check(jb_depth_ms(&j, A_FRAME_MS) == 80, "four frames held is 80 ms")
	}

	// The ceiling: a buffer that has crept past JB_MAX_HOLD is trimmed from
	// the oldest end, so latency cannot accumulate for the life of a call.
	{
		j: Jitter
		for s in u16(0) ..< 9 {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		check_eq_int(j.count, 9, "nine frames queued, over the ceiling")
		jb_trim(&j)
		check(j.count <= JB_MAX_HOLD, "trimming brings the hold back to %d frames", JB_MAX_HOLD)
		check_eq_int(j.trimmed, 9 - JB_MAX_HOLD, "the oldest frames are discarded")
		_, _, res := jb_pop(&j, out[:])
		check(res == .Frame, "the next pop is a real frame, not a concealment")
		check(
			out[0] == u8(9 - JB_MAX_HOLD),
			"the frames kept are the newest: next out is %d, not 0",
			int(out[0]),
		)
	}

	// At or under the ceiling, trimming does nothing at all.
	{
		j: Jitter
		for s in u16(0) ..< u16(JB_MAX_HOLD) {
			jb_push(&j, s, 0, payload_for(s, body[:]))
		}
		jb_trim(&j)
		check_eq_int(j.trimmed, 0, "a buffer at the ceiling is left alone")
		check_eq_int(j.count, JB_MAX_HOLD, "and keeps everything")
	}
}

// ---------------------------------------------------------------------------
// 7. Control messages
// ---------------------------------------------------------------------------

test_control :: proc() {
	group("control messages")

	buf: [128]u8
	for kind in Control_Kind {
		body := write_control(buf[:], {kind = kind, flags = CTRL_MUTED, name = "Alice"})
		check(body != nil, "%v serialises", kind)
		c, ok := read_control(body)
		check(ok && c.kind == kind, "%v round trips", kind)
		check(c.flags & CTRL_MUTED != 0, "%v carries the mute flag", kind)
		check(c.name == "Alice", "%v carries the name", kind)
	}

	_, bad := read_control(buf[:2])
	check(!bad, "a truncated control message is rejected")

	trunc: [8]u8
	trunc[0] = u8(Control_Kind.State)
	put_u16(trunc[2:4], 200) // claims a 200-byte name in an 8-byte message
	_, lie := read_control(trunc[:])
	check(!lie, "a control message lying about its name length is rejected")
}

// ---------------------------------------------------------------------------
// 8. The MJPEG splitter, against a stream ffmpeg really produced
// ---------------------------------------------------------------------------

test_mjpeg_split :: proc() {
	group("MJPEG splitter")

	if !kit.has_tool("ffmpeg") {
		fmt.println("  SKIP  ffmpeg is not installed")
		return
	}
	// One second of the synthetic pattern, which is 30 frames.
	out, ok := kit.run(
		{
			"sh",
			"-c",
			"ffmpeg -nostdin -hide_banner -loglevel error -f lavfi " +
			"-i testsrc2=size=160x120:rate=30 -frames:v 30 -q:v 8 -f mjpeg - | cat",
		},
		context.temp_allocator,
	)
	if !ok || len(out) == 0 {
		fmt.println("  SKIP  ffmpeg produced nothing")
		return
	}

	v: Video
	video_init(&v)
	defer video_destroy(&v)

	// kit.run trims trailing whitespace, which can clip the final EOI, so the
	// last frame is not required to be found.
	append(&v.accum, ..transmute([]u8)out)
	frames := 0
	sizes := 0
	for {
		n, got := next_jpeg(&v)
		if !got {
			break
		}
		jpeg := v.accum[:n]
		check(
			jpeg[0] == 0xFF && jpeg[1] == 0xD8 && jpeg[n - 2] == 0xFF && jpeg[n - 1] == 0xD9,
			"split frame %d is bracketed by SOI and EOI",
			frames,
		)
		// And it must actually decode through the same path the receiver uses.
		if frames == 0 {
			img, dok := p.decode_image(jpeg)
			check(dok, "the first split frame decodes through stb_image")
			if dok {
				check(img.w == 160 && img.h == 120, "decoded %dx%d", img.w, img.h)
				p.image_destroy(&img)
			}
		}
		sizes += n
		frames += 1
		remove_range(&v.accum, 0, n)
	}
	check(frames >= 29, "the splitter found %d of 30 frames", frames)
	check(frames > 0 && sizes / max(1, frames) > 500, "average frame is %d bytes", sizes / max(1, frames))

	// A partial stream must yield nothing rather than a torn frame.
	{
		v2: Video
		video_init(&v2)
		defer video_destroy(&v2)
		append(&v2.accum, ..([]u8{0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4}))
		_, got := next_jpeg(&v2)
		check(!got, "a JPEG without its end marker is not emitted")
	}
	// Leading garbage must be resynchronised past, not fed to the decoder.
	{
		v3: Video
		video_init(&v3)
		defer video_destroy(&v3)
		append(&v3.accum, ..([]u8{9, 9, 9, 9, 0xFF, 0xD8, 0xFF, 0xD9}))
		_, got := next_jpeg(&v3)
		check(!got, "the first call resynchronises on the SOI")
		n, got2 := next_jpeg(&v3)
		check(got2 && n == 4, "the second call returns the recovered frame")
	}
}

// ---------------------------------------------------------------------------
// 9. Opus
// ---------------------------------------------------------------------------

test_opus :: proc() {
	group("Opus codec")

	a: Audio
	audio_init(&a)
	defer audio_destroy(&a)

	check(a.use_opus, "libopus is available: %s", opus_version())
	if !a.use_opus {
		return
	}

	// A 440 Hz tone at -6 dBFS, the same thing the synthetic source produces.
	pcm: [A_FRAME_SAMPLES]i16
	for i in 0 ..< A_FRAME_SAMPLES {
		ph := f32(i) * 2 * 3.14159265 * 440 / f32(A_RATE)
		pcm[i] = i16(16000 * sin01(ph))
	}
	in_level := frame_rms(pcm[:])
	check(in_level > 0.4, "the test tone registers on the meter (%.2f)", in_level)

	packet: [A_MAX_PACKET]u8
	nb := opus_encode(a.enc, raw_data(pcm[:]), A_FRAME_SAMPLES, raw_data(packet[:]), A_MAX_PACKET)
	check(nb > 0, "a 20 ms frame encodes to %d bytes", int(nb))
	check(
		int(nb) < A_FRAME_BYTES,
		"%d bytes of Opus beats %d bytes of PCM",
		int(nb),
		A_FRAME_BYTES,
	)
	check(int(nb) + HDR <= MAX_PACKET, "an audio frame is never fragmented")

	decoded: [A_FRAME_SAMPLES]i16
	got := opus_decode(a.dec, raw_data(packet[:nb]), nb, raw_data(decoded[:]), A_FRAME_SAMPLES, 0)
	check_eq_int(int(got), A_FRAME_SAMPLES, "decoded sample count")
	out_level := frame_rms(decoded[:])
	check(
		abs(out_level - in_level) < 0.12,
		"the decoded level matches the input (%.2f vs %.2f)",
		out_level,
		in_level,
	)

	// Concealment. This is the strategy the jitter buffer documents, so it has
	// to actually produce a frame.
	conceal: [A_FRAME_SAMPLES]i16
	plc := opus_decode(a.dec, nil, 0, raw_data(conceal[:]), A_FRAME_SAMPLES, 0)
	check_eq_int(int(plc), A_FRAME_SAMPLES, "packet-loss concealment produces a full frame")
	check(
		frame_rms(conceal[:]) > 0,
		"concealment extrapolates signal rather than silence (%.2f)",
		frame_rms(conceal[:]),
	)

	// And the PCM fallback's concealment does not leave a step.
	fallback: [A_FRAME_SAMPLES]i16
	fallback[0] = 12000
	conceal_silence(fallback[:])
	check(fallback[0] == 12000, "the fallback concealment starts at the previous sample")
	check(fallback[A_FRAME_SAMPLES - 1] == 0, "and ends in silence")
}

// ---------------------------------------------------------------------------
// 10. The binding really is loopback-only
// ---------------------------------------------------------------------------

test_bind_is_loopback :: proc() {
	group("socket is bound to 127.0.0.1, not 0.0.0.0")

	s: Session
	e := session_open(&s, 47992, 47993, "Test")
	check(e == "", "session opened (%s)", e == "" ? "ok" : e)
	if e != "" {
		return
	}
	defer session_close(&s)

	ep, err := net.bound_endpoint(s.sock)
	check(err == nil, "the bound endpoint is readable")
	if err == nil {
		addr, is4 := ep.address.(net.IP4_Address)
		check(is4, "it is an IPv4 endpoint")
		check(
			addr == net.IP4_Address{127, 0, 0, 1},
			"bound to %d.%d.%d.%d",
			int(addr[0]),
			int(addr[1]),
			int(addr[2]),
			int(addr[3]),
		)
		check(addr != net.IP4_Address{0, 0, 0, 0}, "not bound to every interface")
		check_eq_int(ep.port, 47992, "bound port")
	}
	paddr, _ := s.peer.address.(net.IP4_Address)
	check(paddr == net.IP4_Address{127, 0, 0, 1}, "the peer is on loopback too")
}

// ---------------------------------------------------------------------------
// 10b. Pipe descriptors are out of the range palmy recycles
// ---------------------------------------------------------------------------

test_pipe_fds :: proc() {
	group("capture pipes sit above the descriptor floor")

	if !kit.has_tool("ffmpeg") {
		fmt.println("  SKIP  ffmpeg is not installed")
		return
	}
	c, err := spawn_reader(
		[]string{"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
			"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
			"-t", "1", "-f", "s16le", "-ar", "48000", "-ac", "1", "-"},
		8192,
	)
	check(err == "", "a capture child starts (%s)", err == "" ? "ok" : err)
	if err != "" {
		return
	}
	defer child_stop(&c)

	// Resizing a palmy window makes palmy close a descriptor it no longer
	// owns. If one of these pipes has been given that number, the next read is
	// EBADF and the microphone is gone with no other symptom. Keeping them
	// above the floor is the whole of the workaround, so it is worth an
	// assertion.
	check(
		c.read_fd >= FD_FLOOR,
		"the read end is fd %d, at or above the floor of %d",
		int(c.read_fd),
		int(FD_FLOOR),
	)

	got := pipe_size(c.read_fd)
	check(got >= 4096, "the pipe was resized to %d bytes", got)

	buf: [4096]u8
	total := 0
	for _ in 0 ..< 400 {
		n, eof := child_read(&c, buf[:])
		total += n
		if eof {
			break
		}
		if n == 0 {
			time.sleep(5 * time.Millisecond)
		}
	}
	check(total > 0, "and it carries data (%d bytes)", total)
	check(c.last_errno == .NONE, "with no descriptor error (%v)", c.last_errno)
}

// ---------------------------------------------------------------------------
// 11. Device enumeration parsers
// ---------------------------------------------------------------------------

test_device_parsing :: proc() {
	group("device enumeration")

	id, name, ok := parse_node_row("*   46. Brio 100 Mono                       [vol: 0.83]")
	check(ok, "a wpctl source row parses")
	check_eq_int(id, 46, "node id")
	check(name == "Brio 100 Mono", "node name is %q", name)

	id2, name2, ok2 := parse_node_row("34. Ryzen HD Audio Controller Analog Stereo [vol: 0.55]")
	check(ok2 && id2 == 34, "a non-default row parses")
	check(name2 == "Ryzen HD Audio Controller Analog Stereo", "name is %q", name2)

	_, _, ok3 := parse_node_row("Devices:")
	check(!ok3, "a heading is not a node row")
	_, _, ok4 := parse_node_row("")
	check(!ok4, "an empty line is not a node row")

	check(strip_tree(" ├─ Sinks:") == "Sinks:", "box drawing is stripped")
	check(strings.has_suffix(strip_tree(" │      34. Thing [vol: 1]"), "[vol: 1]"), "rows survive stripping")

	// The real-device command lines. Building them is not opening them, and
	// asserting them here is how the camera/microphone path stays correct
	// without ever being run against the hardware in a test.
	{
		mic := Device{kind = .Audio_Source, id = 46, name = "Brio 100 Mono", real = true}
		argv := audio_capture_argv(mic)
		check(argv[0] == "pw-record", "a real microphone is captured with pw-record")
		found := false
		for a in argv {
			if a == "--target=46" {
				found = true
			}
		}
		check(found, "and is targeted by its wpctl node id")
		check(argv[len(argv) - 1] == "-", "writing raw PCM to stdout")

		cam := Device{kind = .Camera, path = "/dev/video0", name = "Brio 100", real = true}
		vargv := video_capture_argv(cam, .MJPEG)
		check(vargv[0] == "ffmpeg", "a real camera is captured with ffmpeg")
		has_v4l2, has_path, has_mjpeg := false, false, false
		for a in vargv {
			switch a {
			case "v4l2":
				has_v4l2 = true
			case "/dev/video0":
				has_path = true
			case "mjpeg":
				has_mjpeg = true
			}
		}
		check(has_v4l2, "through the v4l2 demuxer")
		check(has_path, "on the enumerated /dev path")
		check(has_mjpeg, "producing the same MJPEG the synthetic source does")

		// The same device, asked for H.264: the demuxer and the path must not
		// move, because the codec is an encoder setting and nothing else.
		h264argv := video_capture_argv(cam, .H264)
		hcmd := strings.join(h264argv, " ", context.temp_allocator)
		check(strings.contains(hcmd, "v4l2"), "the H.264 camera command uses the same demuxer")
		check(strings.contains(hcmd, "/dev/video0"), "and the same /dev path")
		check(strings.contains(hcmd, "libx264"), "and encodes with libx264")
		check(!strings.contains(hcmd, "-f mjpeg"), "and does not also emit MJPEG")

		// And the synthetic default opens nothing at all.
		syn := Device{kind = .Synthetic, name = SYNTH_VIDEO_NAME}
		sargv := video_capture_argv(syn, .MJPEG)
		for a in sargv {
			check(
				!strings.has_prefix(a, "/dev/video"),
				"the synthetic camera command names no device node",
			)
			break
		}
		lavfi := false
		for a in sargv {
			if a == "lavfi" {
				lavfi = true
			}
		}
		check(lavfi, "it is lavfi, which is why it is safe to record")
	}

	// The privacy guarantee, asserted rather than asserted-in-prose: without
	// --allow-real-devices, nothing that touches the camera or the microphone
	// can reach a command line.
	{
		mic := Device{kind = .Audio_Source, id = 46, name = "Brio 100 Mono", real = true}
		cam := Device{kind = .Camera, path = "/dev/video0", name = "Brio 100", real = true}

		src, vid := resolve_capture(false, mic, cam)
		check(!src.real && src.kind == .Synthetic, "a real microphone is refused without the flag")
		check(!vid.real && vid.kind == .Synthetic, "a real camera is refused without the flag")

		acmd := strings.join(audio_capture_argv(src), " ", context.temp_allocator)
		check(
			!strings.contains(acmd, "pw-record") && !strings.contains(acmd, "--target="),
			"the resolved audio command names no device: %s",
			acmd,
		)
		check(strings.contains(acmd, "lavfi"), "it is a lavfi source")
		// Both codecs, because adding one must not add a path to the hardware.
		for codec in Video_Codec {
			vcmd := strings.join(video_capture_argv(vid, codec), " ", context.temp_allocator)
			check(
				!strings.contains(vcmd, "/dev/video") && !strings.contains(vcmd, "v4l2"),
				"the resolved %s command names no device: %s",
				video_codec_name(codec),
				vcmd,
			)
			check(
				strings.contains(vcmd, "lavfi"),
				"the resolved %s command is a lavfi source",
				video_codec_name(codec),
			)
		}
		// The decoder is a pure byte pump with no input of its own, which is
		// what makes it safe no matter what arrives on the socket.
		dcmd := strings.join(h264_decoder_argv(320, 180), " ", context.temp_allocator)
		check(
			!strings.contains(dcmd, "/dev/") && !strings.contains(dcmd, "v4l2") &&
			!strings.contains(dcmd, "pulse") && !strings.contains(dcmd, "alsa"),
			"the H.264 decoder command opens no device: %s",
			dcmd,
		)

		// And with the flag, they are honoured — the lock is a policy, not an
		// inability.
		rsrc, rvid := resolve_capture(true, mic, cam)
		check(rsrc.real && rvid.real, "with --allow-real-devices the real devices are kept")

		// And the path a keyframe request opens. `video_on_keyframe_request`
		// respawns the encoder, so it is the one place in this application
		// where a capture command line is built *after* the device picker has
		// had its say — which would be exactly the place for a resolved
		// device to be quietly swapped back for the real one. It is not: the
		// resolved kind and path are what `video_start` stored, and the
		// restart can only rebuild the command it already had.
		{
			rv: Video
			video_init(&rv)
			defer video_destroy(&rv)
			video_start(&rv, vid, .H264)
			check(
				!strings.contains(rv.cap.argv, "/dev/video") &&
				!strings.contains(rv.cap.argv, "v4l2"),
				"the started encoder opens no camera",
			)
			check(rv.src_kind == .Synthetic, "and remembers a synthetic source for a restart")
			check(video_on_keyframe_request(&rv, 100.0), "a keyframe request restarts it")
			check(
				!strings.contains(rv.cap.argv, "/dev/video") &&
				!strings.contains(rv.cap.argv, "v4l2") &&
				strings.contains(rv.cap.argv, "lavfi"),
				"and the restarted encoder still opens no camera: %s",
				rv.cap.argv,
			)
		}

		// A PipeWire video node has an id but no /dev path, so it is not
		// openable even when real devices are unlocked.
		pw := Device{kind = .Camera, id = 72, name = "Brio 100 (V4L2) [pipewire]", real = true}
		_, pwv := resolve_capture(true, mic, pw)
		check(
			pwv.kind == .Synthetic,
			"a camera node with no /dev path falls back instead of running ffmpeg with an empty -i",
		)
	}

	// And the live machine: the real lists, which is the point of the picker.
	d: Devices
	devices_init(&d)
	defer devices_destroy(&d)
	devices_scan(&d)
	check(len(d.sources) >= 1, "%d audio sources listed (synthetic plus real)", len(d.sources))
	check(len(d.cameras) >= 1, "%d cameras listed", len(d.cameras))
	check(d.sources[0].kind == .Synthetic, "the default microphone is the synthetic one")
	check(d.cameras[0].kind == .Synthetic, "the default camera is the synthetic one")
	check(!d.sources[0].real, "the default source touches no hardware")
	check(!d.cameras[0].real, "the default camera touches no hardware")
	fmt.printfln("        %s", d.note)
	for dev in d.sources[1:] {
		fmt.printfln("        mic    #%d %s", dev.id, dev.name)
	}
	for dev in d.cameras[1:] {
		fmt.printfln("        camera #%d %s %s", dev.id, dev.name, dev.path)
	}
	for dev in d.sinks[1:] {
		fmt.printfln("        output #%d %s", dev.id, dev.name)
	}
}

// ---------------------------------------------------------------------------
// 13. Video codec negotiation
//
// The whole of it is a bitmask intersection and a preference order, which is
// exactly the kind of thing that is obviously right and wrong in one
// direction. Every pair is checked, including the pairs that cannot happen.
// ---------------------------------------------------------------------------

test_codec_negotiation :: proc() {
	group("video codec negotiation")

	check(negotiate_video(CODEC_ALL, CODEC_ALL) == .H264, "two modern peers pick H.264")
	check(
		negotiate_video(CODEC_ALL, CODEC_MJPEG) == .MJPEG,
		"a peer that only offers MJPEG gets MJPEG",
	)
	check(
		negotiate_video(CODEC_MJPEG, CODEC_ALL) == .MJPEG,
		"and so does the other way round, which is what makes it one answer",
	)
	check(negotiate_video(CODEC_H264, CODEC_H264) == .H264, "two H.264-only peers pick H.264")
	check(
		negotiate_video(CODEC_H264, CODEC_MJPEG) == .MJPEG,
		"an empty intersection falls back to MJPEG rather than to no video",
	)
	check(negotiate_video(0, 0) == .MJPEG, "and so does an offer of nothing at all")
	check(negotiate_video(CODEC_ALL, 0xFF) == .H264, "unknown bits in an offer are ignored")

	// Symmetry is the property the design rests on: both ends run this over
	// the same two masks and must not disagree, because there is no answer
	// message to correct them with.
	symmetric := true
	for a in u8(0) ..= 3 {
		for b in u8(0) ..= 3 {
			if negotiate_video(a, b) != negotiate_video(b, a) {
				symmetric = false
			}
		}
	}
	check(symmetric, "negotiation is symmetric over every pair of offers")

	check(video_codec_payload(.H264) == .Video_H264, "H.264 rides payload type 4")
	check(video_codec_payload(.MJPEG) == .Video_JPEG, "MJPEG stays on payload type 3")
	check(is_video(.Video_H264) && is_video(.Video_JPEG), "both are video to the fragmenter")
	check(!is_video(.Control) && !is_video(.Audio_Opus), "and audio and control are not")

	// Payload type 4 must parse and type 5 must not: an unknown type is a
	// stray packet, and this port receives strays.
	{
		buf: [HDR + 4]u8
		write_header(buf[:], {ptype = .Video_H264, flags = FLAG_MARKER, nfrag = 1})
		_, _, ok := parse(buf[:])
		check(ok, "a payload type 4 datagram parses")
		buf[4] = 5
		_, _, bad := parse(buf[:])
		check(!bad, "a payload type 5 datagram is still rejected")
	}

	// The offer on the wire, and what silence means.
	{
		out: [128]u8
		body := write_control(out[:], {kind = .Invite, name = "Alice", codecs = CODEC_ALL})
		c, ok := read_control(body)
		check(ok && c.codecs == CODEC_ALL, "the codec offer round trips (%02x)", c.codecs)
		check(c.name == "Alice", "and the name still reads correctly after it")

		// An older peer's message: the same bytes without the trailing offer.
		old := body[:len(body) - 1]
		c2, ok2 := read_control(old)
		check(ok2, "a control message with no offer byte still parses")
		check(
			c2.codecs == CODEC_MJPEG,
			"and reads as MJPEG-only, which is what a peer that never mentioned a codec is",
		)
		check(c2.name == "Alice", "with the name intact")

		// And the keyframe request, which is the eighth kind.
		kf := write_control(out[:], {kind = .Keyframe, name = "Bob", codecs = CODEC_ALL})
		c3, ok3 := read_control(kf)
		check(ok3 && c3.kind == .Keyframe, "a keyframe request round trips")
		bad := out[:4]
		out[0] = u8(Control_Kind.Keyframe) + 1
		put_u16(out[2:4], 0)
		_, ok4 := read_control(bad)
		check(!ok4, "a control kind above Keyframe is rejected")
	}

	// The flag's three spellings, because a typo here is a peer that silently
	// speaks the wrong codec.
	for spec in ([?]string{"auto", "both", ""}) {
		m, e := parse_codec_offer(spec)
		check(e == "" && m == CODEC_ALL, "--video-codec %q offers both", spec)
	}
	for spec in ([?]string{"h264", "h.264", "avc"}) {
		m, e := parse_codec_offer(spec)
		check(e == "" && m == CODEC_H264, "--video-codec %q offers H.264 only", spec)
	}
	for spec in ([?]string{"mjpeg", "jpeg", "mjpg"}) {
		m, e := parse_codec_offer(spec)
		check(e == "" && m == CODEC_MJPEG, "--video-codec %q offers MJPEG only", spec)
	}
	_, e := parse_codec_offer("vp9")
	check(e != "", "an unknown codec name is refused rather than ignored")
}

// ---------------------------------------------------------------------------
// 14. The keyframe flag in the header
// ---------------------------------------------------------------------------

test_keyframe_flag :: proc() {
	group("keyframe flag")

	want := Header {
		ptype = .Video_H264,
		flags = FLAG_MARKER | FLAG_KEYFRAME,
		seq   = 11,
		ts_us = 99,
		frame = 7,
		frag  = 1,
		nfrag = 2,
	}
	buf: [HDR + 4]u8
	write_header(buf[:], want)
	got, _, ok := parse(buf[:])
	check(ok, "a keyframe datagram parses")
	check(keyframed(got), "the keyframe flag survives")
	check(marked(got), "alongside the marker bit")

	// The marker check must still bite: the two flags are independent and one
	// must not excuse the other.
	buf[5] = FLAG_KEYFRAME
	_, _, bad := parse(buf[:])
	check(!bad, "a keyframe fragment whose marker disagrees with the counters is still rejected")

	// Every fragment of a keyframe carries the flag, because losing the first
	// one must not lose the fact that the frame was a keyframe.
	{
		data := make([]u8, 3 * MTU_PAYLOAD + 7)
		defer delete(data)
		out: [MAX_PACKET]u8
		n := fragment_count(len(data))
		check_eq_int(n, 4, "the test frame fragments")
		all_kf, markers := true, 0
		for i in 0 ..< n {
			dg := fragment_into(out[:], data, i, .Video_H264, u16(i), 5, 1, FLAG_KEYFRAME)
			h, _, pok := parse(dg)
			if !pok || !keyframed(h) {
				all_kf = false
			}
			if pok && marked(h) {
				markers += 1
			}
		}
		check(all_kf, "every fragment of a keyframe is flagged as one")
		check_eq_int(markers, 1, "and exactly one of them carries the marker")

		dg := fragment_into(out[:], data, 0, .Video_H264, 0, 5, 1, 0)
		h, _, _ := parse(dg)
		check(!keyframed(h), "a predicted frame is not flagged")
	}
}

// ---------------------------------------------------------------------------
// 15. The H.264 access-unit splitter, against a stream x264 really produced
//
// This is the H.264 twin of the MJPEG splitter test, and it does the same
// thing: run the encoder arguments this application actually uses, then cut the
// result up with the code the application actually cuts it up with. It also
// measures, because "H.264 is smaller" is the entire reason the codec is here
// and a test is a better place to find out it is not than a demo is.
// ---------------------------------------------------------------------------

H264_TEST_FILE :: "/tmp/call-selftest.h264"
MJPEG_TEST_FILE :: "/tmp/call-selftest.mjpeg"

test_h264_split :: proc() {
	group("H.264 access-unit splitter")

	if !kit.has_tool("ffmpeg") {
		fmt.println("  SKIP  ffmpeg is not installed")
		return
	}

	// A small, short clip at the real settings. The resolution is dropped so
	// the test costs a second rather than ten; everything else — profile,
	// preset, GOP, the access-unit delimiters, the repeated parameter sets —
	// is exactly what a call uses, because that is the point.
	ow, oh, ofps := v_width, v_height, v_fps
	v_width, v_height, v_fps = 160, 120, 30
	defer {v_width, v_height, v_fps = ow, oh, ofps}

	FRAMES :: 90 // three seconds, so the keyframe interval is visible twice
	enc := strings.join(h264_encode_args(), " ", context.temp_allocator)
	cmd := fmt.tprintf(
		"ffmpeg -y -nostdin -hide_banner -loglevel error -f lavfi -i %s -frames:v %d %s",
		synth_pattern(),
		FRAMES,
		strings.trim_suffix(enc, " -"),
	)
	_, _ = kit.run({"sh", "-c", fmt.tprintf("%s %s", cmd, H264_TEST_FILE)}, context.temp_allocator)
	stream, rerr := os.read_entire_file_from_path(H264_TEST_FILE, context.temp_allocator)
	if rerr != nil || len(stream) == 0 {
		fmt.println("  SKIP  libx264 produced nothing")
		return
	}
	defer os.remove(H264_TEST_FILE)

	v: Video
	video_init(&v)
	defer video_destroy(&v)
	v.codec = .H264
	append(&v.accum, ..stream)

	frames, keys, total, biggest := 0, 0, 0, 0
	key_at := make([dynamic]int, context.temp_allocator)
	first_au: []u8
	for {
		n, kf, ok := next_frame(&v)
		if !ok {
			break
		}
		au := v.accum[:n]
		if frames == 0 {
			first_au = slice.clone(au, context.temp_allocator)
			check(
				au[0] == 0 && au[1] == 0 && au[2] == 0 && au[3] == 1 && (au[4] & 0x1F) == 9,
				"the first access unit opens with a four-byte start code and an AUD",
			)
			check(kf, "and it is a keyframe, because a stream has to start on one")
		}
		if kf {
			keys += 1
			append(&key_at, frames)
		}
		total += n
		biggest = max(biggest, n)
		frames += 1
		remove_range(&v.accum, 0, n)
	}

	// The last access unit has no successor to delimit it, so it stays in the
	// accumulator: FRAMES - 1 is the right answer, not FRAMES.
	check(frames >= FRAMES - 2, "the splitter found %d of %d access units", frames, FRAMES)
	// One at the head of the stream, then one every interval after it.
	check_eq_int(
		keys,
		1 + (frames - 1) / (v_fps * V_GOP_SECONDS),
		"keyframes in %d frames",
		frames,
	)
	gaps_even := true
	for i in 1 ..< len(key_at) {
		if key_at[i] - key_at[i - 1] != v_fps * V_GOP_SECONDS {
			gaps_even = false
		}
	}
	check(gaps_even, "and they are exactly %d frames apart", v_fps * V_GOP_SECONDS)

	mean := total / max(1, frames)
	check(mean > 0 && mean < 4 * MTU_PAYLOAD, "the mean access unit is %d bytes", mean)
	check(
		biggest < REASM_MAX_FRAGS * MTU_PAYLOAD,
		"the largest is %d bytes, inside the reassembler's %d",
		biggest,
		REASM_MAX_FRAGS * MTU_PAYLOAD,
	)

	// And the measurement that justifies the whole codec: the same source,
	// the same frame count, through the MJPEG arguments.
	{
		mcmd := strings.join(mjpeg_encode_args(), " ", context.temp_allocator)
		_, _ = kit.run(
			{
				"sh",
				"-c",
				fmt.tprintf(
					"ffmpeg -y -nostdin -hide_banner -loglevel error -f lavfi -i %s -frames:v %d %s %s",
					synth_pattern(),
					FRAMES,
					strings.trim_suffix(mcmd, " -"),
					MJPEG_TEST_FILE,
				),
			},
			context.temp_allocator,
		)
		mjpeg, merr := os.read_entire_file_from_path(MJPEG_TEST_FILE, context.temp_allocator)
		if merr == nil && len(mjpeg) > 0 {
			defer os.remove(MJPEG_TEST_FILE)
			// Three times, not the thirteen the report quotes, and the
			// difference is the point: H.264 here is rate-targeted, so it
			// spends 300 kbit/s whether the picture is 160x120 or 640x360,
			// while MJPEG's cost falls with the pixel count. The ratio in the
			// report is the ratio at the call resolution; this assertion only
			// has to catch an encoder that has stopped compressing at all.
			check(
				len(stream) * 3 < len(mjpeg),
				"H.264 is %.1fx smaller than MJPEG over the same %d frames at %dx%d (%d vs %d bytes)",
				f64(len(mjpeg)) / f64(max(1, len(stream))),
				FRAMES,
				v_width,
				v_height,
				len(stream),
				len(mjpeg),
			)
		}
	}

	// Keyframe detection, against real NAL units rather than a fabrication.
	check(au_has_idr(first_au), "au_has_idr finds the IDR slice in a real keyframe")
	{
		v2: Video
		video_init(&v2)
		defer video_destroy(&v2)
		v2.codec = .H264
		append(&v2.accum, ..stream)
		// Skip the keyframe; the second access unit is predicted.
		n1, _, _ := next_frame(&v2)
		remove_range(&v2.accum, 0, n1)
		n2, kf2, ok2 := next_frame(&v2)
		check(ok2 && !kf2, "the second access unit is predicted, not a keyframe")
		check(!au_has_idr(v2.accum[:n2]), "and au_has_idr says so")
	}

	// A partial access unit must not be emitted, and garbage in front of one
	// must be resynchronised past rather than handed to a decoder.
	{
		v3: Video
		video_init(&v3)
		defer video_destroy(&v3)
		v3.codec = .H264
		append(&v3.accum, ..first_au)
		_, _, got := next_frame(&v3)
		check(!got, "an access unit with no successor is not emitted")

		v4: Video
		video_init(&v4)
		defer video_destroy(&v4)
		v4.codec = .H264
		append(&v4.accum, ..([]u8{7, 7, 7, 7, 7, 7, 7, 7, 7}))
		append(&v4.accum, ..first_au)
		append(&v4.accum, ..([]u8{0, 0, 0, 1, 9, 0x10}))
		_, _, g1 := next_frame(&v4)
		check(!g1, "the first call resynchronises on the delimiter")
		n4, kf4, g2 := next_frame(&v4)
		check(g2 && n4 == len(first_au), "the second returns the recovered access unit")
		check(kf4, "still recognised as a keyframe after the resynchronisation")
	}

	// The decoder output size: capped so a frame fits the pipe it has to cross.
	{
		dw, dh := decoder_output_size(640, 360)
		check(dw == 640 && dh == 360, "the call resolution is decoded at full size")
		bw, bh := decoder_output_size(1280, 720)
		check(bw * bh * 4 <= DEC_PIPE_BYTES, "a 720p frame is capped to %dx%d to fit the pipe", bw, bh)
		check(bw % 2 == 0 && bh % 2 == 0, "and the capped size stays even")
		check(abs(f64(bw) / f64(bh) - 16.0 / 9.0) < 0.05, "and keeps the aspect ratio")
	}
}

// ---------------------------------------------------------------------------
// 16. Loss, and the keyframe request
//
// MJPEG needed none of this: a lost frame was a lost frame. H.264 predicts, so
// a frame that never arrived leaves every frame after it referring to a
// picture the decoder has not got. The receiver therefore has to notice, ask,
// and wait — and all three are driven here with deliberately dropped frames,
// because loopback will never drop one.
// ---------------------------------------------------------------------------

test_keyframe_loss_path :: proc() {
	group("H.264 loss and keyframe requests")

	v: Video
	video_init(&v)
	defer video_destroy(&v)
	v.codec = .H264
	// What video_start would have set: nothing is decodable until an IDR.
	v.need_keyframe = true

	// A session that is not open: send_control writes a datagram into its own
	// buffer and `send_datagram` drops it, so the counters are exercised
	// without a socket.
	s: Session
	s.codecs = CODEC_ALL
	check(!s.open, "the test session has no socket, so nothing leaves the process")

	payload := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	out: [MAX_PACKET]u8
	seq: u16
	deliver :: proc(
		v: ^Video,
		s: ^Session,
		out: []u8,
		payload: []u8,
		seq: ^u16,
		frame: u32,
		kf: bool,
		t: f64,
	) {
		flags: u8 = kf ? FLAG_KEYFRAME : 0
		dg := fragment_into(out, payload, 0, .Video_H264, seq^, u64(frame) * 1000, frame, flags)
		seq^ += 1
		h, pl, ok := parse(dg)
		if !ok {
			return
		}
		video_receive(v, s, h, pl, t)
	}

	// 1. A predicted frame, with no keyframe yet seen.
	deliver(&v, &s, out[:], payload, &seq, 1, false, 1.0)
	check_eq_int(v.frames_skipped, 1, "a predicted frame before any keyframe is skipped")
	check(v.need_keyframe, "and the receiver is still waiting")
	check_eq_int(v.pli_sent, 1, "and it has asked for a keyframe")
	check_eq_int(v.dec.pushed, 0, "nothing was handed to the decoder")

	// 2. The rate limit: asking again immediately must not ask again.
	deliver(&v, &s, out[:], payload, &seq, 2, false, 1.0)
	check_eq_int(v.frames_skipped, 2, "the next predicted frame is skipped too")
	check_eq_int(v.pli_sent, 1, "but the request is rate limited to one per %.1f s", V_PLI_GAP)

	// 3. A keyframe resumes decoding.
	deliver(&v, &s, out[:], payload, &seq, 3, true, 1.0)
	check(!v.need_keyframe, "a keyframe clears the wait")
	check_eq_int(v.keyframes_rx, 1, "and is counted")
	check(v.dec.pushed >= 1 || v.dec.starts >= 1, "and reaches the decoder")

	// 4. Frames that follow it are accepted.
	before := v.frames_skipped
	deliver(&v, &s, out[:], payload, &seq, 4, false, 1.1)
	deliver(&v, &s, out[:], payload, &seq, 5, false, 1.2)
	check_eq_int(v.frames_skipped, before, "predicted frames after a keyframe are not skipped")
	check_eq_int(v.loss_events, 0, "and a dense frame-id sequence is not mistaken for loss")

	// 5. A hole in the frame-id sequence is loss, and is handled as loss.
	deliver(&v, &s, out[:], payload, &seq, 7, false, 2.0) // 6 never arrived
	check_eq_int(v.loss_events, 1, "a gap in the frame ids is detected")
	check(v.need_keyframe, "and stops the receiver feeding predicted frames")
	check_eq_int(v.pli_sent, 2, "and asks the sender for a keyframe")
	check_eq_int(v.frames_skipped, before + 1, "the frame that revealed the gap is itself skipped")

	// 6. And it waits for a real keyframe, not merely for the next frame.
	deliver(&v, &s, out[:], payload, &seq, 8, false, 2.01)
	check_eq_int(v.frames_skipped, before + 2, "a predicted frame during the wait is skipped")
	check(v.need_keyframe, "and the wait continues")
	deliver(&v, &s, out[:], payload, &seq, 9, true, 2.02)
	check(!v.need_keyframe, "the next keyframe ends it")

	// 7. `--no-keyframe-request` really stops the asking.
	{
		pli := v.pli_sent
		v.ask_keyframes = false
		deliver(&v, &s, out[:], payload, &seq, 11, false, 3.0) // another gap
		check(v.need_keyframe, "a gap still stops the decoder being fed")
		check_eq_int(v.pli_sent, pli, "but with --no-keyframe-request nothing is asked for")
		v.ask_keyframes = true
	}

	// 8. MJPEG never waits, because every MJPEG frame is a keyframe. The same
	//    gap, the same code path, a different answer.
	{
		m: Video
		video_init(&m)
		defer video_destroy(&m)
		m.codec = .MJPEG
		ms: Session
		mseq: u16
		jpeg := []u8{0xFF, 0xD8, 0xFF, 0xD9}
		deliver(&m, &ms, out[:], jpeg, &mseq, 1, true, 1.0)
		deliver(&m, &ms, out[:], jpeg, &mseq, 5, true, 1.1) // a gap of three
		check_eq_int(m.loss_events, 1, "MJPEG still counts the gap")
		check(!m.need_keyframe, "but never waits, because every frame stands alone")
		check_eq_int(m.frames_skipped, 0, "so no frame is skipped")
	}

	// 9. The sender's half: a request is counted, honoured once, then rate
	//    limited — and under MJPEG it is a no-op, because there is nothing to
	//    force.
	{
		e: Video
		video_init(&e)
		defer video_destroy(&e)
		e.codec = .MJPEG
		check(!video_on_keyframe_request(&e, 1.0), "MJPEG does not cycle an encoder for a request")
		check_eq_int(e.pli_rx, 1, "but the request is counted")

		e.codec = .H264
		e.src_kind = .Synthetic
		check(video_on_keyframe_request(&e, 10.0), "H.264 honours the first request")
		check_eq_int(e.keyframes_forced, 1, "and says it forced one")
		check(
			strings.contains(e.cap.argv, "lavfi") && !strings.contains(e.cap.argv, "/dev/video"),
			"the respawned encoder is still the synthetic source: %s",
			e.cap.argv,
		)
		check(
			!video_on_keyframe_request(&e, 10.1),
			"a second request inside %.2f s is refused",
			V_FORCE_GAP,
		)
		check_eq_int(e.pli_rx, 3, "though every request is still counted")
		check(video_on_keyframe_request(&e, 10.0 + V_FORCE_GAP + 0.01), "and after the gap, honoured")
		check_eq_int(e.keyframes_forced, 2, "twice in total")
	}
}

// ---------------------------------------------------------------------------
// 17. A duplex child
//
// The decoder is the first child in this application with pipes in both
// directions, and the thing that makes it safe is that neither of them can
// block the frame loop.
// ---------------------------------------------------------------------------

test_duplex_child :: proc() {
	group("duplex child process")

	c, err := spawn_duplex({"cat"}, 64 * 1024, 64 * 1024)
	check(err == "", "a duplex child starts (%s)", err == "" ? "ok" : err)
	if err != "" {
		return
	}
	defer child_stop(&c)

	check(c.read_fd >= FD_FLOOR, "its read end is above FD_FLOOR (%d)", int(c.read_fd))
	check(c.write_fd >= FD_FLOOR, "its write end is above FD_FLOOR (%d)", int(c.write_fd))
	check(pipe_size(c.write_fd) >= 4096, "the input pipe is %d bytes", pipe_size(c.write_fd))
	check(pipe_size(c.read_fd) >= 4096, "the output pipe is %d bytes", pipe_size(c.read_fd))

	msg := "PCP1 duplex"
	n, broken := child_write(&c, transmute([]u8)msg)
	check(!broken && n == len(msg), "a write of %d bytes is accepted", n)

	buf: [64]u8
	got := 0
	for _ in 0 ..< 400 {
		k, eof := child_read(&c, buf[got:])
		got += k
		if eof || got >= len(msg) {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	check(got == len(msg), "and comes back through the child (%d bytes)", got)
	check(string(buf[:got]) == msg, "unchanged")

	// A pipe size above /proc/sys/fs/pipe-max-size must degrade rather than
	// leave the pipe at its 64 KiB default, which was the bug behind a 30 fps
	// stream arriving at 17 fps.
	big, berr := spawn_duplex({"cat"}, 4096, 1 << 26)
	check(berr == "", "a child asking for an absurd output pipe still starts")
	if berr == "" {
		defer child_stop(&big)
		check(
			pipe_size(big.read_fd) >= 1 << 16,
			"and gets the largest the kernel allows (%d bytes), not the 64 KiB default",
			pipe_size(big.read_fd),
		)
	}
}

// shuffle_fixed is a Fisher-Yates with a fixed-seed xorshift, so "deliberately
// reordered" means the same order on every run.
shuffle_fixed :: proc(a: []int) {
	state: u64 = 0xC0FFEE_1234_5678
	next :: proc(s: ^u64) -> u64 {
		s^ ~= s^ << 13
		s^ ~= s^ >> 7
		s^ ~= s^ << 17
		return s^
	}
	for i := len(a) - 1; i > 0; i -= 1 {
		j := int(next(&state) % u64(i + 1))
		a[i], a[j] = a[j], a[i]
	}
}

// ---------------------------------------------------------------------------
// SFU mode
//
// The protocol library's own checks (PCP2, the RFC 9605 vectors, sealing,
// the safety code, dominant speaker, tier choice, tokens), then the client's
// half of SFU mode over real sockets: two rooms and a relay standing in for
// the SFU, which stamps sources and turns KEY{to} into KEY{from} exactly as
// palm-sfu does. The SFU itself is tested by `palm-sfu --selftest`.
// ---------------------------------------------------------------------------

test_pcp2_library :: proc() {
	group("PCP2 library (cloud/rtc/pcp), as palm-sfu runs it")
	pt: pcp.Tally
	pt.quiet = true
	pcp.run_selftest(&pt)
	T.checks += pt.pass + pt.fail
	T.fails += pt.fail
	fmt.printfln("  ok    %d library checks, %d failures (RFC 9605 header and AES-GCM vectors included)", pt.pass + pt.fail, pt.fail)
}

relay_forward :: proc(relay: net.UDP_Socket, to: net.Endpoint, src: u16, mutate: proc(b: []u8) = nil) -> (n: int, last: [pcp.MAX_PACKET]u8, last_n: int) {
	buf: [pcp.MAX_PACKET + 64]u8
	for _ in 0 ..< 200 {
		k, _, err := net.recv_udp(relay, buf[:])
		if err != nil || k <= 0 {
			break
		}
		h, payload, ok := pcp.parse(buf[:k])
		if !ok {
			continue
		}
		out := buf[:k]
		if h.ptype == .Control {
			kind, o, cok := pcp.control_parse(payload)
			if !cok {
				continue
			}
			if kind == .Key {
				// What the SFU does with a KEY: forward it to `to`, saying who
				// it came from.
				ob: pcp.Obj
				pcp.obj_begin(&ob)
				pcp.obj_int(&ob, "from", i64(src))
				pcp.obj_int(&ob, "kid", pcp.oint(o, "kid"))
				pcp.obj_str(&ob, "sealed", pcp.ostr(o, "sealed"))
				tmp: [pcp.MAX_PACKET]u8
				dg := pcp.control_into(tmp[:], .Key, pcp.obj_end(&ob), 1, 0)
				net.send_udp(relay, dg, to)
				n += 1
			}
			continue
		}
		pcp.stamp_src(out, src)
		if mutate != nil {
			mutate(out)
		}
		copy(last[:], out)
		last_n = k
		net.send_udp(relay, out, to)
		n += 1
	}
	return
}

test_room_e2ee :: proc() {
	group("SFU mode: the client's PCP2 + SFrame path, through a relay")

	talk := talk_expression("0-4,12-16", 24, 554, 0)
	check(strings.contains(talk, "between(mod(") && strings.contains(talk, "554*t"), "a talk schedule builds an aevalsrc expression")
	check(strings.count(talk, "between(") == 2, "with one window per range")

	relay, rerr := net.make_bound_udp_socket(LOOPBACK, 0)
	check(rerr == nil, "a relay socket stands in for the SFU")
	if rerr != nil {
		return
	}
	defer net.close(relay)
	net.set_blocking(relay, false)
	rep, _ := net.bound_endpoint(relay)
	secret := transmute([]u8)string("room-test")
	tok_a := pcp.token_mint(secret, pcp.Join{call = "call-x", id = "id-a", handle = "alice", name = "Alice", color = "indigo", e2ee = true}, context.temp_allocator)
	tok_b := pcp.token_mint(secret, pcp.Join{call = "call-x", id = "id-b", handle = "bob", name = "Bob", color = "emerald", e2ee = true}, context.temp_allocator)
	app_a, app_b := new(App), new(App)
	defer free(app_a)
	defer free(app_b)
	ra, ea := room_open(app_a, net.endpoint_to_string(rep), tok_a, 0)
	rb, eb := room_open(app_b, net.endpoint_to_string(rep), tok_b, 0)
	check(ea == "" && eb == "", "two rooms open")
	if ea != "" || eb != "" {
		return
	}
	check(ra.me.name == "Alice" && rb.me.handle == "bob", "each reads its own name from its token")
	bep, _ := net.bound_endpoint(rb.sock)
	aep, _ := net.bound_endpoint(ra.sock)
	b_at := net.Endpoint{LOOPBACK, bep.port}
	a_at := net.Endpoint{LOOPBACK, aep.port}

	// As if the SFU had welcomed both and introduced them to each other.
	for pair in ([?]struct {
		r:   ^Room,
		src: u16,
	}{{ra, 1}, {rb, 2}}) {
		pair.r.state = .Joined
		pair.r.src = pair.src
		pair.r.call = strings.clone("call-x")
		pair.r.e2ee = true
	}
	ma := remote_new(1)
	ma.present, ma.has_pub, ma.pub = true, true, ra.kp.public
	delete(ma.id)
	ma.id = strings.clone("id-a")
	append(&rb.remotes, ma)
	mb := remote_new(2)
	mb.present, mb.has_pub, mb.pub = true, true, rb.kp.public
	delete(mb.id)
	mb.id = strings.clone("id-b")
	append(&ra.remotes, mb)
	// The relay talks to rb from its own port; the room only accepts the SFU's.
	rb.sfu = rep
	ra.sfu = rep

	ra.t = 10
	room_keys_tick(ra)
	check(ra.next != nil && ra.gen == 1, "Alice makes generation 1 and seals it to Bob")
	ra.t = 10 + pcp.ROTATE_DELAY + 0.01
	room_keys_tick(ra)
	check(ra.cur != nil && ra.cur.kid == pcp.kid_of(1, 1), "after the delay she encrypts with it (KID src 1, generation 1)")
	time.sleep(5 * time.Millisecond)
	n, _, _ := relay_forward(relay, b_at, 1)
	check(n >= 1, "the sealed key crosses the relay (%d messages)", n)
	time.sleep(5 * time.Millisecond)
	rb.t = 10
	room_pump_receive(rb)
	check(pcp.keyring_find(&rb.ring, pcp.kid_of(1, 1)) != nil, "Bob opens it and can now decrypt Alice")

	room_update_safety(ra)
	room_update_safety(rb)
	check(ra.safety != "" && ra.safety == rb.safety, "both compute the same safety code (%s)", ra.safety)

	// Audio, encrypted, through the relay.
	plain := transmute([]u8)string("OPUS-PLAINTEXT-FOR-THE-TEST")
	room_send_media(ra, .Audio_Opus, plain, now_us(), 0, 0, pcp.level_byte(0.1))
	time.sleep(5 * time.Millisecond)
	_, last, last_n := relay_forward(relay, b_at, 1)
	wire := last[:last_n]
	h, payload, pok := pcp.parse(wire)
	check(pok && h.flags & pcp.FLAG_E2EE != 0, "what crosses the relay is flagged as an SFrame ciphertext")
	check(!bytes_contains(payload, plain[:12]), "and does not contain the plaintext")
	check(level_vad_byte(h.level), "while the audio level rides in the clear for the SFU (%d)", h.level & 0x7f)
	time.sleep(5 * time.Millisecond)
	room_pump_receive(rb)
	check_eq_int(ma.a_rx, 1, "Bob decrypts one audio frame")
	check_eq_int(ma.bad_auth + ma.no_key + ma.wrong_src, 0, "with no failures")

	// The same datagram again: a replay.
	net.send_udp(relay, wire, b_at)
	time.sleep(5 * time.Millisecond)
	room_pump_receive(rb)
	check_eq_int(ma.replays, 1, "a replayed frame is refused")

	// Tampered in flight.
	room_send_media(ra, .Audio_Opus, plain, now_us(), 0, 0, 127)
	time.sleep(5 * time.Millisecond)
	relay_forward(relay, b_at, 1, proc(b: []u8) {b[len(b) - 3] ~= 0x10})
	time.sleep(5 * time.Millisecond)
	room_pump_receive(rb)
	check_eq_int(ma.bad_auth, 1, "a frame altered in flight fails authentication")

	// Relabelled as someone else.
	mc := remote_new(3)
	mc.present = true
	append(&rb.remotes, mc)
	room_send_media(ra, .Audio_Opus, plain, now_us(), 0, 0, 127)
	time.sleep(5 * time.Millisecond)
	relay_forward(relay, b_at, 3)
	time.sleep(5 * time.Millisecond)
	room_pump_receive(rb)
	check_eq_int(mc.wrong_src, 1, "a frame stamped with another source is refused: its KID names Alice")

	// A clear frame in an encrypted call.
	{
		hh := pcp.Header{ptype = .Audio_Opus, nfrag = 1, src = 1, seq = 900, ts_us = now_us()}
		buf: [pcp.MAX_PACKET]u8
		dg := pcp.fragment_into(buf[:], plain, 0, hh)
		net.send_udp(relay, dg, b_at)
		time.sleep(5 * time.Millisecond)
		room_pump_receive(rb)
		check_eq_int(ma.bad_auth, 2, "a clear frame injected into an encrypted call is refused")
	}

	// Video: a three-fragment keyframe on layer 0, then the layer switch.
	frame := make([]u8, 3000, context.temp_allocator)
	for i in 0 ..< len(frame) {
		frame[i] = u8(i)
	}
	room_send_media(ra, .Video_JPEG, frame, now_us(), FLAG_KEYFRAME, 0, 127)
	time.sleep(5 * time.Millisecond)
	relay_forward(relay, b_at, 1)
	time.sleep(5 * time.Millisecond)
	room_pump_receive(rb)
	check_eq_int(ma.v_layer_frames[0], 1, "a fragmented video frame reassembles and decrypts")
	room_send_media(ra, .Video_JPEG, frame[:900], now_us(), FLAG_KEYFRAME, 1, 127)
	time.sleep(5 * time.Millisecond)
	relay_forward(relay, b_at, 1)
	time.sleep(5 * time.Millisecond)
	room_pump_receive(rb)
	check(ma.layer == 1 && ma.v_layer_frames[1] == 1, "the switch to the low layer is followed at its keyframe")

	// Someone leaves: Alice rotates, and the new key goes to nobody.
	mb.present = false
	ra.t = 20
	room_keys_tick(ra)
	check(ra.gen == 2, "a leave starts a new key generation")
	room_keys_tick(ra)
	check(ra.cur != nil && ra.cur.kid == pcp.kid_of(1, 2) && len(ra.keyed_srcs) == 0, "alone, she switches at once and sealed it to no one")

	room_close(ra)
	room_close(rb)

	group("echo cancellation is PipeWire's: --echo-cancel targets its nodes")
	aec_nodes = true
	cap := audio_capture_argv(Device{kind = .Audio_Source, id = 42, real = true})
	play := audio_playback_argv(Device{kind = .Audio_Sink, id = 43, real = true}, 0.5)
	synth := audio_capture_argv(Device{kind = .Synthetic})
	aec_nodes = false
	has :: proc(argv: []string, want: string) -> bool {
		for x in argv {
			if x == want {
				return true
			}
		}
		return false
	}
	check(has(cap, "--target=echo-cancel-source"), "a real microphone is recorded through echo-cancel-source")
	check(has(play, "--target=echo-cancel-sink"), "playback goes into echo-cancel-sink, so AEC3 hears the far end")
	check(synth[0] == "ffmpeg", "the synthetic microphone is untouched")
	plain_cap := audio_capture_argv(Device{kind = .Audio_Source, id = 42, real = true})
	check(has(plain_cap, "--target=42"), "without the flag the chosen device is used as before")
}

bytes_contains :: proc(hay, needle: []u8) -> bool {
	if len(needle) == 0 || len(needle) > len(hay) {
		return false
	}
	outer: for i in 0 ..= len(hay) - len(needle) {
		for j in 0 ..< len(needle) {
			if hay[i + j] != needle[j] {
				continue outer
			}
		}
		return true
	}
	return false
}

level_vad_byte :: proc(l: u8) -> bool {
	return pcp.level_vad(l)
}
