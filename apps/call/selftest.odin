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
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

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
	test_device_parsing()

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
		vargv := video_capture_argv(cam)
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

		// And the synthetic default opens nothing at all.
		syn := Device{kind = .Synthetic, name = SYNTH_VIDEO_NAME}
		sargv := video_capture_argv(syn)
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
		vcmd := strings.join(video_capture_argv(vid), " ", context.temp_allocator)
		check(
			!strings.contains(acmd, "pw-record") && !strings.contains(acmd, "--target="),
			"the resolved audio command names no device: %s",
			acmd,
		)
		check(strings.contains(acmd, "lavfi"), "it is a lavfi source")
		check(
			!strings.contains(vcmd, "/dev/video") && !strings.contains(vcmd, "v4l2"),
			"the resolved video command names no device: %s",
			vcmd,
		)
		check(strings.contains(vcmd, "lavfi"), "it is a lavfi source")

		// And with the flag, they are honoured — the lock is a policy, not an
		// inability.
		rsrc, rvid := resolve_capture(true, mic, cam)
		check(rsrc.real && rvid.real, "with --allow-real-devices the real devices are kept")

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
