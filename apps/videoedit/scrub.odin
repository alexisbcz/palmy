package main

// Scrubbing with sound.
//
// Dragging the playhead along the ruler, or stepping it with the arrow keys
// while stopped, plays the stretch of sound the playhead moved across, at the
// speed it moved — the way a tape machine sounds when the reels are turned by
// hand. Standing still is silence.
//
// Why not the mixer
// -----------------
// The mixer is a pipeline from a position: every jump is a kill and a restart,
// ~80 ms before the first sample, and a drag is sixty jumps a second. So the
// scrubber does not decode on demand at all. When it starts, it renders the
// timeline's sound around the playhead into memory — the *same* stem graph
// the mixer plays (`mix_graph`), summed at the same gains (`stem_gains`), so
// what you hear while scrubbing is what plays and what exports — and a pump
// thread reads that buffer at a moving read head. 20 s of 48 kHz stereo is
// 7.7 MB. The render does the stretch from the playhead forwards first and
// the six seconds behind it second, so the sound under the playhead is the
// first thing decoded.
// Leaving the window renders a new one around the new position.
//
// The read head
// -------------
// The head follows the playhead as a first-order lag: each sample it moves at
// `(target − head) / SCRUB_TAU` timeline-seconds per second, clamped to
// ±SCRUB_MAX_SPEED. Dragging at a steady speed v therefore plays at v (the
// head trails by v·τ); a single frame step plays that frame's sound once,
// slowing to a stop over about a hundred milliseconds; a jump further than
// SCRUB_JUMP is a seek, not a scrub, and the head lands on it silently. The
// loudness follows the speed through a short envelope, so starting and
// stopping do not click. `scrub_head_fill` is that whole rule, and it is a
// pure procedure so the self-test can drive it sample by sample.
//
// Locking (one mutex, `Scrub.mu`)
// -------------------------------
// The UI thread writes `target` and swaps buffers; the render thread appends
// to the buffer of its own generation; the pump reads the buffer to fill one
// 10.6 ms chunk. All three do that under the lock, and none of them does a
// blocking read or write while holding it.

import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import p "palmy:."

SCRUB_TAU :: 0.045 // seconds for the head to close 63 % of the distance
SCRUB_MAX_SPEED :: 4.0 // timeline seconds per second
SCRUB_JUMP :: 0.5 // farther than this is a seek: land silently
SCRUB_WINDOW :: 20.0 // seconds of timeline rendered around the playhead
SCRUB_BEHIND :: 6.0 // of which this much is behind it
SCRUB_IDLE :: 1.5 // seconds without a move before the sink is closed
SCRUB_ENV_SPEED :: 0.25 // speed at which the envelope is fully open
SCRUB_MIN_SPEED :: 0.05 // slower than this is standing still: the envelope closes

// Scrub_Head is the read head's state. Owned by whoever is filling.
Scrub_Head :: struct {
	pos:   f64, // timeline seconds
	env:   f32, // loudness envelope, 0..1
	voice: i64, // frames written with the envelope open, for the stats
}

// Scrub_Fill says which frames of the buffer have been rendered. The render
// does the stretch from the playhead onwards first (segment A, starting at
// frame a0) and the stretch behind it second (segment B, from frame 0), so
// the sound under the playhead is ready after the shortest possible decode.
Scrub_Fill :: struct {
	a0, a, b: int,
}

fill_has :: proc(f: Scrub_Fill, i: int) -> bool {
	return (i >= f.a0 && i < f.a0 + f.a) || (i >= 0 && i < f.b)
}

// scrub_head_fill writes `len(out)/2` stereo frames. `buf` is interleaved
// stereo at MIX_RATE starting at timeline second `from`; frames `fill` does
// not cover are silence.
scrub_head_fill :: proc(h: ^Scrub_Head, buf: []f32, from: f64, fill: Scrub_Fill, target: f64, out: []f32) {
	frames := len(out) / 2
	dt := 1.0 / f64(MIX_RATE)
	if abs(target - h.pos) > SCRUB_JUMP {
		h.pos = target // a seek: no sound for the distance
	}
	// The envelope moves at most this much per sample: ~3 ms from closed to
	// open, which is fast enough to keep a frame step's attack and slow
	// enough not to click.
	env_step := f32(1.0 / (0.003 * f64(MIX_RATE)))
	for f in 0 ..< frames {
		v := (target - h.pos) / SCRUB_TAU
		v = clamp(v, -SCRUB_MAX_SPEED, SCRUB_MAX_SPEED)
		// An exponential approach never arrives, and a head creeping the last
		// millisecond at 1 % speed would be heard as a long faint tail. Below
		// SCRUB_MIN_SPEED it is standing still: the envelope closes, and once
		// it has, the head lands on the target.
		still := abs(v) < SCRUB_MIN_SPEED
		if still && h.env <= 0 {
			h.pos = target
			v = 0
		}
		h.pos += v * dt
		want := still ? 0 : f32(math.min(1, abs(v) / SCRUB_ENV_SPEED))
		if want > h.env {
			h.env = math.min(want, h.env + env_step)
		} else {
			h.env = math.max(want, h.env - env_step)
		}
		l, r := f32(0), f32(0)
		if h.env > 1e-4 {
			x := (h.pos - from) * f64(MIX_RATE)
			i := int(math.floor(x))
			if fill_has(fill, i) && fill_has(fill, i + 1) && 2 * i + 3 < len(buf) {
				fr := f32(x - f64(i))
				l = buf[2 * i] * (1 - fr) + buf[2 * i + 2] * fr
				r = buf[2 * i + 1] * (1 - fr) + buf[2 * i + 3] * fr
			}
			h.voice += 1
		}
		out[2 * f] = l * h.env
		out[2 * f + 1] = r * h.env
	}
}

Scrub :: struct {
	mu:        sync.Mutex,

	// UI thread only.
	live:      bool,
	sproc:     os.Process, // pw-cat
	spipe:     ^os.File,
	pump:      ^thread.Thread,
	render:    ^thread.Thread,
	job:       ^Scrub_Job, // the render in flight, if any
	key:       u64, // layout + gains the buffer was rendered for
	last_move: time.Time,
	moves:     int,
	renders:   int,
	err:       string,

	// Shared, guarded by mu.
	quit:      bool,
	target:    f64,
	buf:       []f32, // interleaved stereo, MIX_RATE
	from:      f64, // timeline second of buf[0]
	fill:      Scrub_Fill, // which frames are rendered so far
	gen:       int, // bumped on every new buffer; a render of an older one stops
	head:      Scrub_Head,
	bytes:     i64,
	sum:       u64, // |sample| before `silent` zeroes it, as in the mixer
	silent:    bool,
}

// Scrub_Seg is one ffmpeg run of a render: a graph, and where in the buffer
// its frames go.
Scrub_Seg :: struct {
	argv:   []string, // owned
	chans:  int,
	float:  bool,
	gains:  [MIX_MAX_STEMS + 1]f32,
	at:     int, // first buffer frame
	frames: int, // how many it may write
	is_a:   bool, // counts into fill.a (else fill.b)
}

// Scrub_Job is one render, owned by the render thread once started.
Scrub_Job :: struct {
	sc:    ^Scrub,
	segs:  [2]Scrub_Seg,
	nseg:  int,
	gen:   int,
	proc_: os.Process, // the ffmpeg running now; guarded by sc.mu
}

scrub_live :: proc(sc: ^Scrub) -> bool {
	return sc.live
}

scrub_ready :: proc(sc: ^Scrub) -> bool {
	sync.lock(&sc.mu)
	defer sync.unlock(&sc.mu)
	return sc.fill.a > 0
}

// scrub_stats is how much sound the scrubber has actually played since it
// started, and how many times it was moved.
scrub_stats :: proc(sc: ^Scrub) -> (heard: f64, moves: int) {
	sync.lock(&sc.mu)
	defer sync.unlock(&sc.mu)
	return f64(sc.head.voice) / f64(MIX_RATE), sc.moves
}

// scrub_settled is true once the head has landed on the playhead and the
// envelope has closed: from here until the next move, the scrubber is silent.
scrub_settled :: proc(sc: ^Scrub) -> bool {
	sync.lock(&sc.mu)
	defer sync.unlock(&sc.mu)
	return sc.head.env <= 0 && abs(sc.head.pos - sc.target) < 1e-9
}

scrub_bytes :: proc(sc: ^Scrub) -> (bytes: i64, sum: u64) {
	sync.lock(&sc.mu)
	defer sync.unlock(&sc.mu)
	return sc.bytes, sc.sum
}

// scrub_key is what the rendered buffer depends on: the layout and every
// stem's gain. A change in either and the buffer is rendered again.
@(private = "file")
scrub_key :: proc(pr: ^Project) -> u64 {
	h := mix_layout_key(pr)
	for s in resolve_audio_mix(pr, 0, context.temp_allocator, true) {
		h = (h ~ u64(transmute(u32)s.gain)) * 0x100000001b3
		h = (h ~ u64(s.clip)) * 0x100000001b3
	}
	return h
}

// scrub_move points the read head somewhere new, starting the scrubber if it
// is not running and rendering a new window if the target is outside the one
// it has (or the project's sound has changed since it was rendered).
scrub_move :: proc(sc: ^Scrub, pr: ^Project, target, total: f64) -> bool {
	if !sc.live && !scrub_open(sc) {
		return false
	}
	sc.last_move = time.now()
	sc.moves += 1

	sync.lock(&sc.mu)
	sc.target = target
	from, n := sc.from, len(sc.buf) / 2
	sync.unlock(&sc.mu)

	key := scrub_key(pr)
	inside := n > 0 && target >= from && target < from + f64(n) / f64(MIX_RATE) - 0.25
	if key != sc.key || !inside {
		scrub_render(sc, pr, target, total, key)
	}
	return true
}

@(private = "file")
scrub_open :: proc(sc: ^Scrub) -> bool {
	libc_ignore_sigpipe()
	sr, sw, serr := os.pipe()
	if serr != nil {
		return false
	}
	_, _ = linux.fcntl(linux.Fd(os.fd(sw)), linux.F_SETPIPE_SZ, i32(MIX_PIPE))
	sink, perr := os.process_start({command = pw_cat_argv(), stdin = sr, stdout = nil, stderr = nil})
	os.close(sr)
	if perr != nil {
		os.close(sw)
		delete(sc.err)
		sc.err = strings.clone("pw-cat is not available — scrubbing is silent")
		return false
	}
	sc.sproc = sink
	sc.spipe = sw
	sync.lock(&sc.mu)
	sc.quit = false
	sc.bytes, sc.sum = 0, 0
	sc.head = {pos = sc.target}
	sync.unlock(&sc.mu)
	sc.moves = 0
	sc.live = true
	sc.pump = thread.create(scrub_pump)
	sc.pump.data = rawptr(sc)
	thread.start(sc.pump)
	return true
}

// scrub_render replaces the buffer with a new window around `at` and starts
// the render that fills it. A render already running for the old buffer is
// killed and joined first; it would stop on its own at its next block when it
// saw the generation change, but there is no reason to let it decode further.
@(private = "file")
scrub_render :: proc(sc: ^Scrub, pr: ^Project, at, total: f64, key: u64) {
	scrub_render_stop(sc)
	w0 := math.max(0, at - SCRUB_BEHIND)
	w1 := math.min(total, w0 + SCRUB_WINDOW)
	if w1 - w0 < 0.05 {
		return
	}
	job := new(Scrub_Job)
	job.sc = sc
	frames := int((w1 - w0) * f64(MIX_RATE)) + 1
	a0 := clamp(int((at - w0) * f64(MIX_RATE)), 0, frames - 1)
	// A first: from the playhead to the end of the window. B second: the
	// stretch behind it.
	parts := [2][2]f64{{w0 + f64(a0) / MIX_RATE, w1}, {w0, w0 + f64(a0) / MIX_RATE}}
	starts := [2]int{a0, 0}
	for part, k in parts {
		if part[1] - part[0] < 0.02 {
			continue
		}
		gr := mix_graph(pr, part[0], part[1] - part[0], 1, context.temp_allocator)
		sg := &job.segs[job.nseg]
		sg.chans = gr.chans
		sg.float = gr.float
		if gr.float {
			_ = stem_gains(pr, gr.stem_clip, sg.gains[:])
		}
		sg.argv = make([]string, len(gr.argv))
		for a, i in gr.argv {
			sg.argv[i] = strings.clone(a)
		}
		sg.at = starts[k]
		sg.frames = k == 0 ? frames - a0 : a0
		sg.is_a = k == 0
		job.nseg += 1
	}

	nbuf := make([]f32, frames * 2)
	sync.lock(&sc.mu)
	old := sc.buf
	sc.buf = nbuf
	sc.from = w0
	sc.fill = {a0 = a0}
	sc.gen += 1
	job.gen = sc.gen
	sync.unlock(&sc.mu)
	delete(old)

	sc.key = key
	sc.renders += 1
	sc.job = job
	sc.render = thread.create(scrub_render_main)
	sc.render.data = rawptr(job)
	thread.start(sc.render)
}

@(private = "file")
scrub_render_stop :: proc(sc: ^Scrub) {
	if sc.render == nil {
		return
	}
	sync.lock(&sc.mu)
	sc.gen += 1 // the running render stops at its next block
	sync.unlock(&sc.mu)
	victim: os.Process
	if sc.job != nil {
		sync.lock(&sc.mu)
		victim = sc.job.proc_
		sync.unlock(&sc.mu)
	}
	if victim.pid != 0 {
		_ = os.process_kill(victim)
	}
	thread.join(sc.render)
	thread.destroy(sc.render)
	sc.render = nil
	if sc.job != nil {
		for k in 0 ..< sc.job.nseg {
			for a in sc.job.segs[k].argv {
				delete(a)
			}
			delete(sc.job.segs[k].argv)
		}
		free(sc.job)
		sc.job = nil
	}
}

@(private = "file")
scrub_render_main :: proc(t: ^thread.Thread) {
	job := (^Scrub_Job)(t.data)
	for k in 0 ..< job.nseg {
		if !scrub_render_seg(job, &job.segs[k]) {
			return
		}
	}
}

// scrub_render_seg runs one segment's ffmpeg and copies its frames into the
// buffer as they arrive. False means the buffer it was for has been replaced.
@(private = "file")
scrub_render_seg :: proc(job: ^Scrub_Job, sg: ^Scrub_Seg) -> bool {
	sc := job.sc
	rd, wr, perr := os.pipe()
	if perr != nil {
		return false
	}
	pr, serr := os.process_start({command = sg.argv, stdout = wr, stderr = nil, stdin = nil})
	os.close(wr)
	if serr != nil {
		os.close(rd)
		return false
	}
	sync.lock(&sc.mu)
	job.proc_ = pr
	sync.unlock(&sc.mu)
	defer {
		os.close(rd)
		_ = os.process_kill(pr)
		_, _ = os.process_wait(pr)
		sync.lock(&sc.mu)
		job.proc_ = {}
		sync.unlock(&sc.mu)
	}

	BLOCK :: 1024
	chans := max(sg.chans, MIX_CH)
	stems := make([]f32, BLOCK * chans)
	defer delete(stems)
	pcm := make([]i16, BLOCK * MIX_CH)
	defer delete(pcm)
	mixed: [BLOCK * MIX_CH]f32
	done := 0
	for done < sg.frames {
		// The last block of a graph is short; read what there is of it.
		want := min(BLOCK, sg.frames - done)
		got := 0
		if sg.float {
			got = read_frames(rd, slice_to_bytes(stems[:want * chans]), chans * 4)
			if got > 0 {
				mix_stems(stems[:got * chans], chans, sg.gains[:], sg.gains[:], mixed[:got * 2])
			}
		} else {
			got = read_frames(rd, (transmute([^]u8)raw_data(pcm))[:want * MIX_CH * 2], MIX_CH * 2)
			for i in 0 ..< got * 2 {
				mixed[i] = f32(pcm[i]) / 32768
			}
		}
		if got <= 0 {
			return true // the graph ended: the segment is as full as it gets
		}
		sync.lock(&sc.mu)
		if sc.gen != job.gen {
			sync.unlock(&sc.mu)
			return false
		}
		copy(sc.buf[(sg.at + done) * 2:], mixed[:got * 2])
		if sg.is_a {
			sc.fill.a += got
		} else {
			sc.fill.b += got
		}
		sync.unlock(&sc.mu)
		done += got
		if got < want {
			return true
		}
	}
	return true
}

// read_frames reads until `buf` is full or the stream ends, and returns how
// many whole frames of `frame_bytes` it got.
read_frames :: proc(f: ^os.File, buf: []u8, frame_bytes: int) -> int {
	got := 0
	for got < len(buf) {
		n, err := os.read(f, buf[got:])
		if n <= 0 || err != nil {
			break
		}
		got += n
	}
	return got / frame_bytes
}

@(private = "file")
scrub_pump :: proc(t: ^thread.Thread) {
	sc := (^Scrub)(t.data)
	out: [MIX_FRAMES * MIX_CH]f32
	raw: [MIX_CHUNK]u8
	for {
		sync.lock(&sc.mu)
		if sc.quit {
			sync.unlock(&sc.mu)
			return
		}
		scrub_head_fill(&sc.head, sc.buf, sc.from, sc.fill, sc.target, out[:])
		silent := sc.silent
		s := (transmute([^]i16)raw_data(raw[:]))[:MIX_FRAMES * MIX_CH]
		acc := u64(0)
		for v, i in out {
			x := i16(clamp(v, -1, 1) * 32767)
			acc += u64(abs(int(x)))
			s[i] = silent ? 0 : x
		}
		// Counted with the chunk it belongs to, under the same lock: a chunk
		// filled before the head settled must not be counted after it.
		sc.sum += acc
		sync.unlock(&sc.mu)

		off := 0
		for off < MIX_CHUNK {
			w, werr := os.write(sc.spipe, raw[off:])
			if w <= 0 || werr != nil {
				return
			}
			off += w
		}
		sync.lock(&sc.mu)
		sc.bytes += MIX_CHUNK
		sync.unlock(&sc.mu)
	}
}

// scrub_stop closes the sink and stops any render. The buffer is kept: a
// scrub that starts again at the same place with the same sound has nothing
// to render.
scrub_stop :: proc(sc: ^Scrub) {
	scrub_render_stop(sc)
	if !sc.live {
		return
	}
	sync.lock(&sc.mu)
	sc.quit = true
	sync.unlock(&sc.mu)
	_ = os.process_kill(sc.sproc)
	if sc.pump != nil {
		thread.join(sc.pump)
		thread.destroy(sc.pump)
		sc.pump = nil
	}
	_, _ = os.process_wait(sc.sproc)
	if sc.spipe != nil {
		os.close(sc.spipe)
		sc.spipe = nil
	}
	sc.live = false
}

scrub_destroy :: proc(sc: ^Scrub) {
	scrub_stop(sc)
	delete(sc.buf)
	sc.buf = nil
	delete(sc.err)
	sc.err = ""
}

// scrub_follow is the editor's side, called by audio_follow whenever the
// mixer is not playing. A move of the playhead is a scrub; standing still for
// SCRUB_IDLE closes the sink, so an editor left alone is not streaming
// silence into PipeWire.
scrub_follow :: proc(ed: ^Editor, ui: ^p.Ctx, total: f64) {
	sc := &ed.sc
	sync.lock(&sc.mu)
	sc.silent = ed.mx.silent
	sync.unlock(&sc.mu)

	moved := ed.playhead != ed.scrub_at
	if moved {
		jump := abs(ed.playhead - ed.scrub_at)
		ed.scrub_at = ed.playhead
		// A jump that is not part of a drag — Home, End, a click on the
		// ruler — is a seek. There is nothing to hear and no reason to open
		// a sink for it.
		if sc.live || ed.drag == .Scrub || jump <= SCRUB_JUMP {
			if !scrub_move(sc, &ed.pr, ed.playhead, total) && sc.err != "" && !ed.audio_said {
				ed.audio_said = true
				status(ed, ui, sc.err)
			}
		}
	}
	if sc.live {
		idle := time.duration_seconds(time.since(sc.last_move))
		if ed.drag != .Scrub && idle > SCRUB_IDLE {
			scrub_stop(sc)
		} else {
			// One more frame when the idle timeout is due, so the sink is
			// closed even if nothing else wakes the window; and the stats
			// line has something to say meanwhile.
			p.wake_after(ui, 100 * time.Millisecond)
		}
	}
}

@(private = "file")
libc_ignore_sigpipe :: proc() {
	// The same as mixer_init: killing pw-cat mid-write must be an EPIPE, not
	// the end of the editor.
	@(static) done: bool
	if !done {
		done = true
		ignore_sigpipe()
	}
}
