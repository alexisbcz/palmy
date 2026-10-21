package main

// Sound out, and the clock that comes back.
//
//   ffmpeg -ss T -i FILE -vn -f s16le -ar 48000 -ac 2 -   → PCM
//   pw-cat -p --raw --format s16 --rate 48000 -           → the speakers
//   (or `audio --null-sink`, a paced stand-in for a device: sink.odin)
//
// A pump thread moves bytes between them, scaling by the volume on the way. It
// blocks when PipeWire is full, so the running total of bytes handed over is
// how much audio the device has actually taken: `bytes / (rate · 2 · 2)` is the
// playing position, with the sink's own buffering measured once and subtracted.
// Everything the UI shows — elapsed, remaining, the playhead on the waveform,
// the window the spectrum is computed over — comes off that one number.
//
// Gapless
// -------
// The sink outlives the track. `pw-cat` is started once and kept alive for as
// long as the app is playing anything; only the decoder is per-track. Two
// seconds before the end of a track the *next* track's ffmpeg is started into
// its own pipe, enlarged with F_SETPIPE_SZ so the decoder can run ahead and
// then block harmlessly instead of being started cold at the boundary. When
// the current decoder's pipe hits EOF the pump promotes the one already
// running and writes its first bytes in the same iteration — no sleep, no
// process start, nothing for the sink to starve on.
//
// That makes `bytes` a running total across several tracks, so the clock is no
// longer one subtraction. The engine keeps a short list of segments —
// `{byte_start, media_base, track, duration}` — and `seg_locate` finds the one
// that `bytes - lat_est·BPS` falls in. That is both the media time *and* the
// answer to "which track is audible", which is the moment the UI should flip
// the title, the cover and the waveform: the pump is ~60 ms ahead of the
// speakers, so switching when the pump switched would be visibly early.

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

RATE :: 48000
CH :: 2
BPS :: RATE * CH * 2
CHUNK :: 2048 // 10.6 ms per write
PIPE_BYTES :: 4096 // 21 ms, the smallest a Linux pipe can be
// The decoder pipe is the opposite problem: it wants to be big, so a track
// started early can run ahead and park. 384 KB is two seconds of 48 kHz
// stereo, which is exactly the head start the prefetch is after.
DEC_PIPE_BYTES :: 384 * 1024
PW_LATENCY :: "40ms"
// How much of the current track may be left unwritten before the next one's
// decoder is started.
PREFETCH_LEAD :: 2.0
MAX_SEGS :: 8
MAX_DEAD :: 4

// A Segment is one track's worth of the byte stream handed to the sink.
Segment :: struct {
	byte_start: i64, // running total when this track's first byte went out
	media_base: f64, // media time at that byte (non-zero after a seek)
	track:      int, // index into the playlist
	duration:   f64,
}

// A Dec is one decoder: the process, the pipe to read it from, and the segment
// it will contribute once it starts feeding the sink.
Dec :: struct {
	ps:   os.Process,
	pipe: ^os.File,
	live: bool,
	seg:  Segment,
}

Engine :: struct {
	m:            Media,
	live:         bool, // a decode pipeline is loaded
	sink_live:    bool, // pw-cat is running
	err:          string,

	sproc:        os.Process,
	spipe:        ^os.File,
	pump:         ^thread.Thread,

	mu:           sync.Mutex,
	quit:         bool,
	paused:       bool,
	eof:          bool,

	// The decoder being read, the one started early for the next track, and
	// the finished ones waiting for the main thread to reap them. The pump
	// never closes a pipe or waits on a process, so the boundary cannot block.
	cur:          Dec,
	nxt:          Dec,
	dead:         [MAX_DEAD]Dec,
	ndead:        int,

	segs:         [MAX_SEGS]Segment,
	nseg:         int,
	joins:        int, // gapless track changes since the last hard start

	base:         f64,
	bytes:        i64,
	lat_est:      f64,
	lat_locked:   bool,
	lat_sum:      f64,
	lat_n:        int,
	started:      time.Time,

	// When the first PCM byte was handed over. The sink's buffering is
	// measured from there, not from process start: otherwise however long
	// ffmpeg took to open the file would be subtracted from it.
	first_write:  time.Time,
	// When the last one was, which is where a starvation interval begins.
	w_last:       time.Time,

	// The gap instrument (`--gap-test`). Three stopwatches on one boundary,
	// all starting at `gap_from` — the moment the last byte of the outgoing
	// track completed its write. See gaptest.odin for why one number is not
	// enough to be honest about this.
	gap_watch:      bool,
	gap_from:       time.Time,
	// ...to the pump offering the next track's first byte. This is the real
	// starvation: the only interval in which the sink has nothing available.
	starve_pending: bool,
	starve_s:       f64,
	// ...to that byte being accepted. Blocking here means the pipe was full,
	// which is the opposite of starvation, so this one reads 21 ms in healthy
	// steady state and is kept only as a cross-check.
	gap_pending:    bool,
	gap_s:          f64,
	// ...to more than a pipeful having gone through, which cannot happen until
	// pw-cat has really consumed something. A write into an empty pipe
	// succeeds whether or not the process on the other end has finished
	// starting, so this is what catches a sink started from cold.
	sink_pending:   bool,
	sink_written:   i64,
	sink_s:         f64,

	// Forces the old tear-down-and-restart route, so the same instrument can
	// measure the behaviour this replaced.
	hard_restart: bool,

	volume:       f32,
	muted:        bool,
	// Peak of the last chunk written, which is what makes a level meter
	// respond to the sound rather than to the clock.
	peak:         f32,
}

engine_init :: proc(e: ^Engine) {
	libc.signal(13, transmute(proc "c" (i32))libc.SIG_IGN)
	e.volume = 0.7
	e.lat_est = 0.1
	e.gap_s = -1
	e.sink_s = -1
	e.starve_s = -1
}

// ---------------------------------------------------------------------------
// The clock
// ---------------------------------------------------------------------------

// seg_locate answers the one question the clock asks. The pump has handed
// `bytes` to the sink and the sink is still holding `lat_bytes` of them
// unplayed, so: which segment is coming out of the speakers, and at what point
// in its track?
//
// A byte before the first segment clamps to its start rather than running the
// clock negative, and a byte past a boundary belongs to the later segment —
// which is why subtracting the sink's buffering can pull the answer back into
// the previous track for the ~60 ms the pump runs ahead.
seg_locate :: proc(segs: []Segment, bytes: i64, lat_bytes: i64) -> (idx: int, media: f64) {
	if len(segs) == 0 {
		return -1, 0
	}
	a := bytes - lat_bytes
	if a < segs[0].byte_start {
		a = segs[0].byte_start
	}
	idx = 0
	for i in 1 ..< len(segs) {
		if segs[i].byte_start <= a {
			idx = i
		} else {
			break
		}
	}
	s := segs[idx]
	media = s.media_base + f64(a - s.byte_start) / f64(BPS)
	if s.duration > 0 && media > s.duration {
		media = s.duration
	}
	return idx, media
}

// prefetch_due decides whether the next track's decoder should be started: it
// is time once less than `lead` seconds of the segment being fed to the sink
// are still unwritten. A track of unknown length never triggers it.
prefetch_due :: proc(bytes: i64, seg: Segment, lead: f64) -> bool {
	if seg.duration <= 0 {
		return false
	}
	pos := seg.media_base + f64(bytes - seg.byte_start) / f64(BPS)
	return seg.duration - pos <= lead
}

engine_position :: proc(e: ^Engine) -> (media: f64, track: int) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if e.nseg == 0 {
		return e.base, -1
	}
	i, t := seg_locate(e.segs[:e.nseg], e.bytes, i64(e.lat_est * f64(BPS)))
	return t, e.segs[i].track
}

engine_clock :: proc(e: ^Engine) -> f64 {
	t, _ := engine_position(e)
	return t
}

// engine_current_track is which track is *audible*, not which one the pump is
// reading. The UI follows this one.
engine_current_track :: proc(e: ^Engine) -> int {
	_, tr := engine_position(e)
	return tr
}

// engine_feeding_track is which track the pump is reading, which is what
// "what comes after this?" has to be asked about when deciding a prefetch.
engine_feeding_track :: proc(e: ^Engine) -> int {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if e.nseg == 0 {
		return -1
	}
	return e.segs[e.nseg - 1].track
}

engine_stats :: proc(e: ^Engine) -> (written: f64, joins: int) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return f64(e.bytes) / f64(BPS), e.joins
}

// ---------------------------------------------------------------------------
// The sink, which outlives the track
// ---------------------------------------------------------------------------

@(private)
engine_ensure_sink :: proc(e: ^Engine) -> bool {
	if e.sink_live {
		return true
	}
	sr, sw, serr := os.pipe()
	if serr != nil {
		e.err = "could not create the audio pipe"
		return false
	}
	_, _ = linux.fcntl(linux.Fd(os.fd(sw)), linux.F_SETPIPE_SZ, i32(PIPE_BYTES))
	argv, why, have := sink_argv(RATE, CH, PW_LATENCY)
	if !have {
		os.close(sr)
		os.close(sw)
		e.err = why
		return false
	}
	sink, perr := os.process_start({command = argv, stdin = sr, stdout = nil, stderr = nil})
	os.close(sr)
	if perr != nil {
		os.close(sw)
		e.err = "the audio sink could not be started — no sound output"
		return false
	}
	e.sproc = sink
	e.spipe = sw
	e.sink_live = true
	return true
}

@(private)
engine_sink_down :: proc(e: ^Engine) {
	if !e.sink_live {
		return
	}
	_ = os.process_kill(e.sproc)
	_, _ = os.process_wait(e.sproc)
	if e.spipe != nil {
		os.close(e.spipe)
	}
	e.spipe = nil
	e.sink_live = false
}

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

@(private)
dec_spawn :: proc(m: Media, at: f64, track: int) -> (d: Dec, ok: bool) {
	ar, aw, aerr := os.pipe()
	if aerr != nil {
		return {}, false
	}
	// The one line that makes a prefetch worth anything: a pipe that holds a
	// couple of seconds means the decoder started early actually gets ahead,
	// rather than being throttled to the sink and arriving at the boundary no
	// further along than a cold start would have been.
	_, _ = linux.fcntl(linux.Fd(os.fd(aw)), linux.F_SETPIPE_SZ, i32(DEC_PIPE_BYTES))
	ps, derr := os.process_start(
		{
			command = {
				"ffmpeg",
				"-hide_banner",
				"-loglevel",
				"error",
				"-ss",
				fmt.tprintf("%.3f", at),
				"-i",
				m.path,
				"-vn",
				"-sn",
				"-f",
				"s16le",
				"-acodec",
				"pcm_s16le",
				"-ar",
				fmt.tprintf("%d", RATE),
				"-ac",
				fmt.tprintf("%d", CH),
				"-",
			},
			stdout = aw,
			stderr = nil,
			stdin = nil,
		},
	)
	os.close(aw)
	if derr != nil {
		os.close(ar)
		return {}, false
	}
	return Dec {
			ps = ps,
			pipe = ar,
			live = true,
			seg = {media_base = at, track = track, duration = m.duration},
		},
		true
}

// dec_kill is for the main thread only: it waits, which the pump must never do.
@(private)
dec_kill :: proc(d: ^Dec) {
	if !d.live {
		return
	}
	_ = os.process_kill(d.ps)
	_, _ = os.process_wait(d.ps)
	if d.pipe != nil {
		os.close(d.pipe)
	}
	d^ = {}
}

// engine_reap closes out the decoders the pump finished with. Called from the
// frame loop, so a track boundary costs the pump one pointer copy.
engine_reap :: proc(e: ^Engine) {
	for {
		sync.lock(&e.mu)
		if e.ndead == 0 {
			sync.unlock(&e.mu)
			return
		}
		d := e.dead[0]
		for i in 1 ..< e.ndead {
			e.dead[i - 1] = e.dead[i]
		}
		e.ndead -= 1
		sync.unlock(&e.mu)
		dec_kill(&d)
	}
}

@(private)
seg_push :: proc(e: ^Engine, s: Segment) {
	if e.nseg == MAX_SEGS {
		for i in 1 ..< MAX_SEGS {
			e.segs[i - 1] = e.segs[i]
		}
		e.nseg -= 1
	}
	e.segs[e.nseg] = s
	e.nseg += 1
}

// ---------------------------------------------------------------------------
// Starting, stopping, prefetching
// ---------------------------------------------------------------------------

// engine_pump_down stops the pump without touching the sink. The pump may be
// blocked reading a decoder, so both decoders are killed to make that read
// return; the pump re-checks `quit` before it does anything with the result,
// so it cannot promote the prefetched decoder on its way out.
@(private)
engine_pump_down :: proc(e: ^Engine) {
	if e.pump == nil {
		return
	}
	sync.lock(&e.mu)
	e.quit = true
	e.paused = false
	cur_live, cur_ps := e.cur.live, e.cur.ps
	nxt_live, nxt_ps := e.nxt.live, e.nxt.ps
	sync.unlock(&e.mu)
	if cur_live {_ = os.process_kill(cur_ps)}
	if nxt_live {_ = os.process_kill(nxt_ps)}
	thread.join(e.pump)
	thread.destroy(e.pump)
	e.pump = nil
}

// engine_start is the hard path: a track chosen by hand, or a seek. It keeps
// the sink (unless `hard_restart` asks for the old behaviour) and resets the
// byte count, because the segment list it belongs to is being thrown away.
engine_start :: proc(e: ^Engine, m: Media, at: f64, track: int = -1) {
	engine_pump_down(e)
	if e.hard_restart {
		if e.gap_watch {engine_gap_arm(e)}
		engine_sink_down(e)
	}
	engine_reap(e)
	dec_kill(&e.cur)
	dec_kill(&e.nxt)

	e.m = m
	e.base = clamp(at, 0, max(0, m.duration - 0.05))
	e.bytes = 0
	e.nseg = 0
	e.joins = 0
	e.quit = false
	e.eof = false
	e.paused = false
	// The sink's buffering belongs to the sink, not to the track, so a seek
	// keeps what was already measured rather than making the clock jump.
	if e.lat_est <= 0 {
		e.lat_est = 0.1
	}
	e.started = time.now()
	e.first_write = {}
	e.err = ""

	if !engine_ensure_sink(e) {
		e.live = false
		return
	}

	d, ok := dec_spawn(m, e.base, track)
	if !ok {
		e.err = "ffmpeg could not decode this file"
		e.live = false
		return
	}
	e.cur = d
	seg_push(
		e,
		Segment{byte_start = 0, media_base = e.base, track = track, duration = m.duration},
	)
	e.live = true

	e.pump = thread.create(pump_main)
	e.pump.data = rawptr(e)
	thread.start(e.pump)
}

// engine_prefetch starts the next track's decoder now. Its output sits in the
// pipe until the pump reaches the boundary and promotes it.
engine_prefetch :: proc(e: ^Engine, m: Media, track: int, at: f64 = 0) -> bool {
	sync.lock(&e.mu)
	busy := e.nxt.live || !e.live || e.pump == nil
	sync.unlock(&e.mu)
	if busy {
		return false
	}
	d, ok := dec_spawn(m, at, track)
	if !ok {
		return false
	}
	sync.lock(&e.mu)
	taken := e.nxt.live
	if !taken {
		e.nxt = d
	}
	sync.unlock(&e.mu)
	if taken {
		dd := d
		dec_kill(&dd)
		return false
	}
	return true
}

engine_prefetch_due :: proc(e: ^Engine) -> bool {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if !e.live || e.hard_restart || e.nseg == 0 || e.nxt.live || e.eof {
		return false
	}
	return prefetch_due(e.bytes, e.segs[e.nseg - 1], PREFETCH_LEAD)
}

// engine_cancel_prefetch throws away a queued decoder, for when whatever chose
// it has changed its mind — shuffle or repeat toggled, a manual skip, a seek.
engine_cancel_prefetch :: proc(e: ^Engine) {
	sync.lock(&e.mu)
	d := e.nxt
	e.nxt = {}
	sync.unlock(&e.mu)
	// If the pump promoted it a moment ago this is empty and kills nothing.
	dec_kill(&d)
}

engine_prefetched :: proc(e: ^Engine) -> (track: int, ok: bool) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.nxt.seg.track, e.nxt.live
}

// engine_stop is the full teardown: the sink too. Quit, an explicit stop, and
// the end of the playlist — never a normal track advance.
engine_stop :: proc(e: ^Engine) {
	if !e.live && !e.sink_live {
		return
	}
	engine_pump_down(e)
	if e.gap_watch {
		engine_gap_arm(e)
	}
	engine_reap(e)
	dec_kill(&e.cur)
	dec_kill(&e.nxt)
	engine_sink_down(e)
	e.live = false
	e.nseg = 0
	e.eof = false
}

// ---------------------------------------------------------------------------
// The pump
// ---------------------------------------------------------------------------

@(private)
pump_main :: proc(t: ^thread.Thread) {
	e := (^Engine)(t.data)
	raw: [CHUNK]u8
	for {
		sync.lock(&e.mu)
		if e.quit {
			sync.unlock(&e.mu)
			return
		}
		paused := e.paused
		vol := e.muted ? 0 : e.volume
		have := e.cur.live
		pipe := e.cur.pipe
		sync.unlock(&e.mu)

		if paused || !have {
			time.sleep(6 * time.Millisecond)
			continue
		}

		n, rerr := os.read(pipe, raw[:])
		if n <= 0 || rerr != nil {
			if pump_boundary(e) {
				// The next decoder was promoted; go straight back round and
				// read it. No sleep, no process start, nothing the sink can
				// run dry on.
				continue
			}
			return
		}
		n &= ~int(1)

		s := (transmute([^]i16)raw_data(raw[:]))[:n / 2]
		pk := f32(0)
		for i in 0 ..< len(s) {
			v := f32(s[i]) * vol
			s[i] = i16(clamp(v, -32768, 32767))
			a := abs(v) * (1.0 / 32768)
			if a > pk {pk = a}
		}

		off := 0
		for off < n {
			// Timed before the write, not after: a write that blocks is a sink
			// that is full, and a full sink is not a starved one.
			offered := time.now()
			sync.lock(&e.mu)
			if e.starve_pending && e.gap_from != {} {
				e.starve_s = time.duration_seconds(time.diff(e.gap_from, offered))
				e.starve_pending = false
			}
			sync.unlock(&e.mu)

			w, werr := os.write(e.spipe, raw[off:n])
			if w <= 0 || werr != nil {
				sync.lock(&e.mu)
				e.eof = true
				sync.unlock(&e.mu)
				return
			}
			off += w
			now := time.now()
			sync.lock(&e.mu)
			if e.first_write == {} {
				e.first_write = now
			}
			if e.gap_pending {
				if e.gap_from != {} {
					e.gap_s = time.duration_seconds(time.diff(e.gap_from, now))
				}
				e.gap_pending = false
			}
			if e.sink_pending {
				e.sink_written += i64(w)
				if e.sink_written > i64(PIPE_BYTES) && e.gap_from != {} {
					e.sink_s = time.duration_seconds(time.diff(e.gap_from, now))
					e.sink_pending = false
				}
			}
			e.w_last = now
			e.bytes += i64(w)
			sync.unlock(&e.mu)
		}
		sync.lock(&e.mu)
		e.peak = max(pk, e.peak * 0.75)
		sync.unlock(&e.mu)
	}
}

// pump_boundary handles a decoder reaching EOF. It returns true when the pump
// should carry on — either because the next track's decoder was promoted, or
// because the engine is now idle and waiting for the UI to choose something.
@(private)
pump_boundary :: proc(e: ^Engine) -> bool {
	sync.lock(&e.mu)
	if e.quit {
		sync.unlock(&e.mu)
		return false
	}
	// Hand the finished decoder to the main thread; close and wait are its job.
	finished := e.cur
	e.cur = {}
	if e.ndead < MAX_DEAD {
		e.dead[e.ndead] = finished
		e.ndead += 1
		finished = {}
	}
	// Arm the starvation timer: from the last byte handed over to the first
	// byte of whatever comes next.
	e.gap_from = e.w_last
	e.gap_pending = true
	e.starve_pending = true
	e.sink_pending = true
	e.sink_written = 0

	if e.nxt.live {
		e.cur = e.nxt
		e.nxt = {}
		e.cur.seg.byte_start = e.bytes
		seg_push(e, e.cur.seg)
		e.joins += 1
	} else {
		e.eof = true
	}
	sync.unlock(&e.mu)
	// Only reachable if the main thread has not reaped for four boundaries in
	// a row, which it cannot while it is drawing frames.
	if finished.live {
		dec_kill(&finished)
	}
	return true
}

// ---------------------------------------------------------------------------
// The gap instrument
// ---------------------------------------------------------------------------

engine_gap_arm :: proc(e: ^Engine) {
	sync.lock(&e.mu)
	e.gap_from = e.w_last
	e.gap_pending = true
	e.starve_pending = true
	e.sink_pending = true
	e.sink_written = 0
	sync.unlock(&e.mu)
}

// engine_starvation is the interval, in seconds, during which the sink had
// nothing available from the pump across the last track boundary. Negative
// until a boundary has been crossed.
engine_starvation :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.starve_s
}

// engine_gap is the same boundary measured to the first *completed* write, so
// it also counts time spent blocked on a full pipe.
engine_gap :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.gap_s
}

// engine_sink_gap is the same boundary measured to the point where the sink
// had demonstrably taken bytes, rather than to the point where the pump
// managed to put some in the pipe.
engine_sink_gap :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.sink_s
}

// engine_buffered is how much audio the sink is holding when the pump stops
// writing: what it measured for itself, plus the pipe between them. A stall
// shorter than this is covered; anything longer is silence you can hear.
engine_buffered :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.lat_est + f64(PIPE_BYTES) / f64(BPS)
}

// ---------------------------------------------------------------------------

engine_tick :: proc(e: ^Engine) {
	engine_reap(e)
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if !e.live || e.lat_locked || e.paused {
		return
	}
	if e.first_write == {} {
		return
	}
	el := time.duration_seconds(time.since(e.first_write))
	if el < 0.6 {
		return
	}
	inst := f64(e.bytes) / f64(BPS) - el
	if inst > 0 && inst < 2 {
		e.lat_sum += inst
		e.lat_n += 1
	}
	if el > 2.0 && e.lat_n > 8 {
		e.lat_est = e.lat_sum / f64(e.lat_n)
		e.lat_locked = true
	}
}

engine_pause :: proc(e: ^Engine, on: bool) {
	sync.lock(&e.mu)
	e.paused = on
	sync.unlock(&e.mu)
}

engine_paused :: proc(e: ^Engine) -> bool {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.paused
}

engine_eof :: proc(e: ^Engine) -> bool {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.eof
}

engine_set_volume :: proc(e: ^Engine, v: f32) {
	sync.lock(&e.mu)
	e.volume = clamp(v, 0, 1)
	sync.unlock(&e.mu)
}

engine_mute :: proc(e: ^Engine, on: bool) {
	sync.lock(&e.mu)
	e.muted = on
	sync.unlock(&e.mu)
}

engine_level :: proc(e: ^Engine) -> f32 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.peak
}

engine_latency :: proc(e: ^Engine) -> (f64, bool) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.lat_est, e.lat_locked
}
