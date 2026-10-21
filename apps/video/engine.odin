package main

// The decoder, the sink and the clock.
//
// Three processes do the work palmy cannot:
//
//   ffmpeg … -f rawvideo -pix_fmt bgra -vf scale=W:H -r FPS -    → RGBA frames
//   ffmpeg … -vn -f s16le -ar 48000 -ac 2 -                      → PCM
//   pw-cat -p --raw --format s16 --rate 48000 --channels 2 -     → the speakers
//   (or `video --null-sink`, a paced stand-in for a device: sink.odin)
//
// Two threads keep them fed: one reads whole frames into a small ring, the
// other pumps PCM from ffmpeg into pw-cat, scaling it by the volume on the way
// through and counting every byte it hands over.
//
// That byte count is the clock. pw-cat only takes bytes as fast as the sound
// card consumes them, so `bytes_written / (rate · channels · 2)` is how much
// audio the device has accepted — a real audio clock with back-pressure, not a
// wall-clock guess. Video frames are presented against it. The one unknown is
// how much sound is still sitting in the pipe and in PipeWire's own buffer when
// a byte is counted; that constant is measured at startup (see `lat_est`) and
// subtracted, and the UI shows what it measured.

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

AUDIO_RATE :: 48000
AUDIO_CH :: 2
AUDIO_BPS :: AUDIO_RATE * AUDIO_CH * 2 // bytes of PCM per second
PCM_CHUNK :: 2048 // bytes per write to pw-cat: 10.6 ms
PIPE_BYTES :: 4096 // one page, the smallest a Linux pipe can be: 21 ms
PW_LATENCY :: "40ms"
RING :: 6

Frame :: struct {
	px:  []u32,
	pts: f64,
}

Engine :: struct {
	m:            Media,
	w, h:         int, // the size frames are decoded at
	fps:          f64,

	// Processes and their pipes.
	vproc:        os.Process,
	aproc:        os.Process,
	sproc:        os.Process,
	vpipe:        ^os.File, // read end: raw frames
	apipe:        ^os.File, // read end: raw PCM
	spipe:        ^os.File, // write end: pw-cat's stdin
	have_video:   bool,
	have_audio:   bool,
	audio_err:    string,

	// The frame ring. `free` counts empty slots, `count` full ones.
	mu:           sync.Mutex,
	free:         sync.Sema,
	ring:         [RING]Frame,
	head:         int, // producer writes here
	tail:         int, // consumer reads here
	count:        int,
	held:         int, // slot the UI is drawing, released when the next arrives

	// Threads.
	vthread:      ^thread.Thread,
	athread:      ^thread.Thread,
	quit:         bool,
	paused:       bool,
	veof:         bool,
	aeof:         bool,

	// The clock.
	base:         f64, // media time the pipelines were started at
	speed:        f64, // playback rate, 0.5 … 2.0
	bytes:        i64, // PCM bytes handed to pw-cat
	wall_t0:      time.Time,
	wall_accum:   f64, // seconds played, for the silent clock
	lat_est:      f64, // measured sink buffering, seconds
	lat_locked:   bool,
	lat_sum:      f64,
	lat_n:        int,

	volume:       f32,
	muted:        bool,

	// What is on screen, and how well it is keeping up.
	cur_pts:      f64,
	shown:        int,
	dropped:      int,
	decoded:      int,
	decode_t0:    time.Time,
	err_sum:      f64,
	err_max:      f64,
	err_n:        int,
	// The same three again, counted only once the sink's buffering has been
	// measured. Before that the clock is running on a guessed `lat_est` and
	// every frame is presented against the wrong number, which would otherwise
	// drag the mean down for the rest of the session.
	errl_sum:     f64,
	errl_max:     f64,
	errl_n:       int,
	last_err:     f64,
	seek_ms:      f64,
	started_at:   time.Time,
	first_frame:  bool,
	// When the first PCM byte was handed over, which is where the sink's
	// buffering is measured from: before that, the number would be polluted
	// by however long ffmpeg took to start.
	first_write:  time.Time,
	// When the most recent byte was accepted, and how much media time the
	// picture is allowed to coast past it. See `engine_clock`.
	last_write:   time.Time,
	fill_max:     f64,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

engine_init :: proc(e: ^Engine, m: Media) {
	// Killing pw-cat while the pump thread is mid-write would otherwise take
	// the whole process down.
	libc.signal(13, transmute(proc "c" (i32))libc.SIG_IGN)
	e.m = m
	e.fps = m.fps
	e.volume = 0.8
	e.speed = 1
	e.held = -1
}

// engine_open starts the pipelines at `at` seconds, decoding frames `w` × `h`.
engine_open :: proc(e: ^Engine, at: f64, w, h: int) {
	engine_close(e)

	e.w = max(2, w & ~int(1))
	e.h = max(2, h & ~int(1))
	e.base = clamp(at, 0, max(0, e.m.duration - 0.05))
	if e.speed <= 0 {
		e.speed = 1
	}
	e.bytes = 0
	e.veof = false
	e.aeof = false
	e.quit = false
	e.head, e.tail, e.count, e.held = 0, 0, 0, -1
	// The sink's buffering does not change when the stream does, so a seek
	// keeps whatever was measured: re-measuring would make the clock jump at
	// every seek and never settle in a session full of them.
	if e.lat_est <= 0 {
		e.lat_est = 0.10
	}
	e.wall_accum = 0
	e.wall_t0 = time.now()
	e.decode_t0 = time.now()
	e.started_at = time.now()
	e.first_write = {}
	e.last_write = {}
	// One frame interval. Coasting cannot put the picture more than one frame
	// ahead of the sound, by construction.
	e.fill_max = e.fps > 0 ? 1 / e.fps : 0.016
	e.decoded = 0
	e.first_frame = false
	e.cur_pts = e.base

	for i in 0 ..< RING {
		if len(e.ring[i].px) != e.w * e.h {
			delete(e.ring[i].px)
			e.ring[i].px = make([]u32, e.w * e.h)
		}
	}
	e.free = {}
	sync.sema_post(&e.free, RING)

	if e.m.has_video {
		e.have_video = start_video(e)
	}
	if e.m.has_audio {
		e.have_audio = start_audio(e)
	}

	if e.have_video {
		e.vthread = thread.create(video_main)
		e.vthread.data = rawptr(e)
		thread.start(e.vthread)
	}
	if e.have_audio {
		e.athread = thread.create(audio_main)
		e.athread.data = rawptr(e)
		thread.start(e.athread)
	}
}

@(private)
start_video :: proc(e: ^Engine) -> bool {
	r, w, err := os.pipe()
	if err != nil {
		return false
	}
	argv := []string {
		"ffmpeg",
		"-hide_banner",
		"-loglevel",
		"error",
		"-ss",
		fmt.tprintf("%.3f", e.base),
		"-i",
		e.m.path,
		"-an",
		"-sn",
		"-vf",
		fmt.tprintf("scale=%d:%d:flags=bilinear", e.w, e.h),
		// Forcing a constant rate is what makes `index / fps` an exact
		// presentation time: ffmpeg does the duplication against the real
		// timestamps, so a variable-rate source still lands on the audio clock.
		"-r",
		fmt.tprintf("%.6f", e.fps),
		"-f",
		"rawvideo",
		// palmy's canvas words are 0xAARRGGBB, which on a little-endian
		// machine is the byte order ffmpeg calls bgra. Asking for rgba here
		// would mean swapping every pixel by hand on the way in.
		"-pix_fmt",
		"bgra",
		"-",
	}
	proc_, perr := os.process_start({command = argv, stdout = w, stderr = nil, stdin = nil})
	os.close(w)
	if perr != nil {
		os.close(r)
		return false
	}
	e.vproc = proc_
	e.vpipe = r
	return true
}

@(private)
start_audio :: proc(e: ^Engine) -> bool {
	e.audio_err = ""

	// The sink first, so ffmpeg has somewhere to go.
	sr, sw, serr := os.pipe()
	if serr != nil {
		e.audio_err = "could not create the audio pipe"
		return false
	}
	// A one-page pipe holds 21 ms. Every byte sitting in it is latency between
	// the clock and the speaker, so it is worth making it as small as Linux
	// allows.
	_, _ = linux.fcntl(linux.Fd(os.fd(sw)), linux.F_SETPIPE_SZ, i32(PIPE_BYTES))
	sargv, why, have := sink_argv(AUDIO_RATE, AUDIO_CH, PW_LATENCY)
	if !have {
		os.close(sr)
		os.close(sw)
		e.audio_err = why
		return false
	}
	sink, perr := os.process_start({command = sargv, stdin = sr, stdout = nil, stderr = nil})
	os.close(sr)
	if perr != nil {
		os.close(sw)
		e.audio_err = "the audio sink could not be started"
		return false
	}

	ar, aw, aerr := os.pipe()
	if aerr != nil {
		os.close(sw)
		_ = os.process_kill(sink)
		e.audio_err = "could not create the decode pipe"
		return false
	}
	// atempo changes the tempo without touching the pitch, and leaves the
	// output rate at 48 kHz. That is the whole reason the clock has to scale:
	// a second of PCM now carries `speed` seconds of media.
	argv := make([dynamic]string, context.temp_allocator)
	append(
		&argv,
		"ffmpeg",
		"-hide_banner",
		"-loglevel",
		"error",
		"-ss",
		fmt.tprintf("%.3f", e.base),
		"-i",
		e.m.path,
		"-vn",
		"-sn",
	)
	if abs(e.speed - 1) > 1e-9 {
		append(&argv, "-filter:a", fmt.tprintf("atempo=%.6f", e.speed))
	}
	append(
		&argv,
		"-f",
		"s16le",
		"-acodec",
		"pcm_s16le",
		"-ar",
		fmt.tprintf("%d", AUDIO_RATE),
		"-ac",
		fmt.tprintf("%d", AUDIO_CH),
		"-",
	)
	dec, derr := os.process_start(
		{command = argv[:], stdout = aw, stderr = nil, stdin = nil},
	)
	os.close(aw)
	if derr != nil {
		os.close(ar)
		os.close(sw)
		_ = os.process_kill(sink)
		e.audio_err = "ffmpeg could not decode the audio"
		return false
	}

	e.sproc = sink
	e.aproc = dec
	e.apipe = ar
	e.spipe = sw
	return true
}

engine_close :: proc(e: ^Engine) {
	if !e.have_video && !e.have_audio {
		return
	}
	sync.lock(&e.mu)
	e.quit = true
	e.paused = false
	sync.unlock(&e.mu)
	// Unblock a producer parked on a full ring.
	sync.sema_post(&e.free, RING * 2)

	// Killing ffmpeg closes the write end, so a blocked read returns 0 and the
	// thread falls out of its loop by itself.
	if e.have_video {
		_ = os.process_kill(e.vproc)
	}
	if e.have_audio {
		_ = os.process_kill(e.aproc)
	}

	if e.vthread != nil {
		thread.join(e.vthread)
		thread.destroy(e.vthread)
		e.vthread = nil
	}
	if e.athread != nil {
		thread.join(e.athread)
		thread.destroy(e.athread)
		e.athread = nil
	}

	// The pump is gone, so nothing is writing to pw-cat any more.
	if e.have_audio {
		_ = os.process_kill(e.sproc)
		_, _ = os.process_wait(e.sproc)
		_, _ = os.process_wait(e.aproc)
		if e.spipe != nil {os.close(e.spipe)}
		if e.apipe != nil {os.close(e.apipe)}
		e.spipe, e.apipe = nil, nil
	}
	if e.have_video {
		_, _ = os.process_wait(e.vproc)
		if e.vpipe != nil {os.close(e.vpipe)}
		e.vpipe = nil
	}
	e.have_video = false
	e.have_audio = false
	e.held = -1
	e.count = 0
	e.head, e.tail = 0, 0
}

engine_destroy :: proc(e: ^Engine) {
	engine_close(e)
	for i in 0 ..< RING {
		delete(e.ring[i].px)
		e.ring[i].px = nil
	}
}

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------

@(private)
video_main :: proc(t: ^thread.Thread) {
	e := (^Engine)(t.data)
	idx := 0
	nbytes := e.w * e.h * 4
	for {
		sync.sema_wait(&e.free)
		sync.lock(&e.mu)
		if e.quit {
			sync.unlock(&e.mu)
			return
		}
		slot := e.head
		sync.unlock(&e.mu)

		buf := (transmute([^]u8)raw_data(e.ring[slot].px))[:nbytes]
		if !read_full(e.vpipe, buf) {
			sync.lock(&e.mu)
			e.veof = true
			sync.unlock(&e.mu)
			return
		}
		e.ring[slot].pts = e.base + f64(idx) / e.fps
		idx += 1

		sync.lock(&e.mu)
		if e.quit {
			sync.unlock(&e.mu)
			return
		}
		e.head = (e.head + 1) % RING
		e.count += 1
		e.decoded += 1
		sync.unlock(&e.mu)
	}
}

@(private)
read_full :: proc(f: ^os.File, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		n, err := os.read(f, buf[off:])
		if n <= 0 || err != nil {
			return false
		}
		off += n
	}
	return true
}

@(private)
audio_main :: proc(t: ^thread.Thread) {
	e := (^Engine)(t.data)
	raw: [PCM_CHUNK]u8
	for {
		sync.lock(&e.mu)
		if e.quit {
			sync.unlock(&e.mu)
			return
		}
		paused := e.paused
		vol := e.muted ? 0 : e.volume
		sync.unlock(&e.mu)

		if paused {
			time.sleep(8 * time.Millisecond)
			continue
		}

		n, rerr := os.read(e.apipe, raw[:])
		if n <= 0 || rerr != nil {
			sync.lock(&e.mu)
			e.aeof = true
			sync.unlock(&e.mu)
			return
		}
		n &= ~int(1) // whole samples only

		// Volume is applied here rather than passed to pw-cat, so a change is
		// heard on the next 10 ms chunk instead of needing a new sink.
		if vol != 1 {
			s := (transmute([^]i16)raw_data(raw[:]))[:n / 2]
			for i in 0 ..< len(s) {
				s[i] = i16(clamp(f32(s[i]) * vol, -32768, 32767))
			}
		}

		off := 0
		for off < n {
			w, werr := os.write(e.spipe, raw[off:n])
			if w <= 0 || werr != nil {
				sync.lock(&e.mu)
				e.aeof = true
				sync.unlock(&e.mu)
				return
			}
			off += w
			sync.lock(&e.mu)
			if e.first_write == {} {
				e.first_write = time.now()
			}
			e.last_write = time.now()
			e.bytes += i64(w)
			sync.unlock(&e.mu)
		}
	}
}

// ---------------------------------------------------------------------------
// The clock
// ---------------------------------------------------------------------------

// clock_from_bytes is the clock, as arithmetic, with nothing locked and nothing
// measured — the one expression the whole player is scheduled against, kept
// separate so the selftest can assert it at every speed.
//
// `bytes / BPS` is output seconds: how much 48 kHz stereo PCM pw-cat has
// accepted. `lat` is also output seconds, because it was measured by comparing
// that same quantity against a wall clock. Their difference is how much sound
// has actually reached the speakers, still in output seconds — and one output
// second carries `speed` seconds of media, because atempo kept the sample rate
// and threw samples away (or made them up) instead.
//
// So the scale factor belongs outside the subtraction, not inside it. Putting
// `lat` outside — `base + bytes/BPS*speed - lat` — would subtract an output
// duration from a media time and leave the picture 100 ms × (speed−1) wrong,
// which is exactly the kind of error that looks fine at 1x and ruins 2x.
clock_from_bytes :: proc(base: f64, bytes: i64, lat, speed: f64) -> f64 {
	return base + (f64(bytes) / f64(AUDIO_BPS) - lat) * speed
}

// clock_coast is the bounded wall-clock fill between two byte-count updates,
// kept separate for the same reason as the expression above: it is three lines
// that decide whether the picture stutters, and it is far easier to assert than
// to watch.
//
// `gap` is wall seconds since the last accepted byte and becomes media seconds
// at `speed`; `fill_max` is the cap, in media seconds. The cap is what makes
// this safe — it adds a bounded offset and never a slope, so a clock left
// coasting for an hour is still exactly as wrong as one coasting for a frame.
clock_coast :: proc(t, gap, speed, fill_max: f64) -> f64 {
	return t + clamp(gap * speed, 0, max(fill_max, 0))
}

// engine_clock is where playback has reached, in seconds of media time.
// engine_clock is where playback has reached, in seconds of media time.
//
// The byte count is the clock, but it is a *stepped* one: pw-cat takes bytes in
// bursts, so `e.bytes` stands still for tens of milliseconds and then jumps
// several chunks at once. Scheduling a 60 fps picture directly against that
// means some polls find no frame due and the next finds three — which is not a
// decoder shortfall but looks exactly like one, and stutters exactly like one.
// Measured on a 1080p60 clip at 1x against a 60 Hz poll: 160 of 717 frames
// discarded, 46 fps presented out of 60, with the decoder comfortably
// delivering 60.2.
//
// So the picture is allowed to **coast** between updates: the wall clock fills
// the gap since the last accepted byte, capped at one frame interval of media.
// The rate is still entirely the byte count's — coasting adds a bounded offset,
// never a slope, so it cannot drift however long it runs, and the cap means the
// picture can never be more than one frame ahead of the sound. The moment a
// write lands, the byte count takes over again.
engine_clock :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if e.have_audio {
		t := clock_from_bytes(e.base, e.bytes, e.lat_est, e.speed)
		if !e.paused && e.last_write != {} {
			gap := time.duration_seconds(time.since(e.last_write))
			t = clock_coast(t, gap, e.speed, e.fill_max)
		}
		return t
	}
	// With no audio the wall clock is the clock, and media time runs `speed`
	// times faster than it. `wall_accum` is kept in media seconds so a pause
	// at one speed and a resume at another still add up.
	t := e.base + e.wall_accum
	if !e.paused {
		t += time.duration_seconds(time.since(e.wall_t0)) * e.speed
	}
	return t
}

// engine_tick measures the sink's buffering while it settles. At steady state
// the pump can only be ahead of the speakers by what is stored between them, so
// (bytes written) − (seconds since start) converges on exactly that.
//
// Both sides of that subtraction are output seconds — atempo does not change
// how fast the sound card drains 48 kHz — so this is speed independent and must
// not be scaled. The scaling happens once, in `clock_from_bytes`, where output
// seconds are turned into media time.
engine_tick :: proc(e: ^Engine) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if !e.have_audio || e.lat_locked || e.paused {
		return
	}
	elapsed := time.duration_seconds(time.since(e.first_write))
	if e.first_write == {} || elapsed < 0.6 {
		return
	}
	inst := f64(e.bytes) / f64(AUDIO_BPS) - elapsed
	if inst > 0 && inst < 2 {
		e.lat_sum += inst
		e.lat_n += 1
	}
	if elapsed > 2.0 && e.lat_n > 8 {
		e.lat_est = e.lat_sum / f64(e.lat_n)
		e.lat_locked = true
	}
}

engine_pause :: proc(e: ^Engine, on: bool) {
	sync.lock(&e.mu)
	if e.paused == on {
		sync.unlock(&e.mu)
		return
	}
	if !e.have_audio {
		if on {
			e.wall_accum += time.duration_seconds(time.since(e.wall_t0)) * e.speed
		} else {
			e.wall_t0 = time.now()
		}
	}
	e.paused = on
	sync.unlock(&e.mu)
}

engine_paused :: proc(e: ^Engine) -> bool {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.paused
}

engine_set_volume :: proc(e: ^Engine, v: f32) {
	sync.lock(&e.mu)
	e.volume = clamp(v, 0, 1)
	sync.unlock(&e.mu)
}

SPEED_MIN :: f64(0.5)
SPEED_MAX :: f64(2.0)
SPEED_STEP :: f64(0.25)

engine_speed :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	return e.speed <= 0 ? 1 : e.speed
}

// engine_set_speed restarts both pipelines at the current position, because the
// audio filter graph is built once when ffmpeg starts and there is no way to
// change `atempo` on a running process. It is a seek in everything but name.
engine_set_speed :: proc(e: ^Engine, s: f64) -> bool {
	want := clamp(s, SPEED_MIN, SPEED_MAX)
	// Snap to the step so repeated nudges cannot drift off the grid.
	want = f64(int(want / SPEED_STEP + 0.5)) * SPEED_STEP
	if abs(want - engine_speed(e)) < 1e-9 {
		return false
	}
	if !e.have_video && !e.have_audio {
		sync.lock(&e.mu)
		e.speed = want
		sync.unlock(&e.mu)
		return true
	}
	at := engine_clock(e)
	was := engine_paused(e)
	w, h := e.w, e.h
	e.speed = want
	engine_open(e, at, w, h)
	engine_pause(e, was)
	return true
}

engine_mute :: proc(e: ^Engine, on: bool) {
	sync.lock(&e.mu)
	e.muted = on
	sync.unlock(&e.mu)
}

engine_finished :: proc(e: ^Engine) -> bool {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if e.have_video {
		return e.first_frame && e.veof && e.count == 0
	}
	return e.aeof
}

// engine_take advances the picture to the newest frame that is due, dropping
// anything already late. The slot stays held until the next one replaces it, so
// the UI draws straight out of the ring without a copy.
//
// The counting is deliberately done after the loop rather than inside it. When
// more than one frame is due in a single tick, the one that ends up on screen is
// the *last* one taken and the earlier ones are what got thrown away — so the
// presentation error has to be the last frame's, and the earlier ones are the
// drops. Measuring the first frame of the burst instead (which is what this did
// before `--measure` was pointed at it) reports the error of a picture nobody
// ever saw, and inflates it by one clock tick per burst.
engine_take :: proc(e: ^Engine, now: f64) -> (changed: bool) {
	taken := 0
	last_pts := f64(0)
	for {
		sync.lock(&e.mu)
		if e.count == 0 {
			sync.unlock(&e.mu)
			break
		}
		pts := e.ring[e.tail].pts
		if pts > now + 0.0005 {
			sync.unlock(&e.mu)
			break
		}
		slot := e.tail
		e.tail = (e.tail + 1) % RING
		e.count -= 1
		prev := e.held
		e.held = slot
		e.cur_pts = pts
		sync.unlock(&e.mu)
		if prev >= 0 {
			sync.sema_post(&e.free)
		}
		taken += 1
		last_pts = pts
	}
	if taken == 0 {
		return false
	}

	sync.lock(&e.mu)
	e.shown += 1
	// Everything before the one now held was decoded and never displayed.
	e.dropped += taken - 1
	err := last_pts - now
	e.last_err = err
	// Stepping a paused player moves the picture without moving the clock,
	// which is not a sync error and must not be counted as one.
	if !e.paused {
		e.err_sum += abs(err)
		e.err_max = max(e.err_max, abs(err))
		e.err_n += 1
		if e.lat_locked || !e.have_audio {
			e.errl_sum += abs(err)
			e.errl_max = max(e.errl_max, abs(err))
			e.errl_n += 1
		}
	}
	if !e.first_frame {
		e.first_frame = true
		e.seek_ms = time.duration_milliseconds(time.since(e.started_at))
	}
	sync.unlock(&e.mu)
	return true
}

// engine_frame is the pixels to draw, or nil before the first frame lands.
engine_frame :: proc(e: ^Engine) -> ([]u32, int, int) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if e.held < 0 {
		return nil, 0, 0
	}
	return e.ring[e.held].px, e.w, e.h
}

engine_stats :: proc(
	e: ^Engine,
) -> (
	shown, dropped, decoded, queued: int,
	avg_err, max_err, last_err, lat: f64,
	locked: bool,
) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	avg := e.err_n > 0 ? e.err_sum / f64(e.err_n) : 0
	return e.shown,
		e.dropped,
		e.decoded,
		e.count,
		avg,
		e.err_max,
		e.last_err,
		e.lat_est,
		e.lat_locked
}

// engine_sync_stats is the honest version for a measurement: the error over
// every frame, and the error over only the frames presented after the sink
// buffering was measured. The second number is the one that describes steady
// state; the first includes the first couple of seconds, when the clock is
// running on a default guess and the picture is systematically off.
engine_sync_stats :: proc(
	e: ^Engine,
) -> (
	all_avg, all_max: f64,
	all_n: int,
	lk_avg, lk_max: f64,
	lk_n: int,
) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	all_avg = e.err_n > 0 ? e.err_sum / f64(e.err_n) : 0
	lk_avg = e.errl_n > 0 ? e.errl_sum / f64(e.errl_n) : 0
	return all_avg, e.err_max, e.err_n, lk_avg, e.errl_max, e.errl_n
}

// engine_decode_fps is how fast ffmpeg and the reader thread are actually
// delivering frames, which is the number that matters when a file is too big
// to play at rate.
engine_decode_fps :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	el := time.duration_seconds(time.since(e.decode_t0))
	return el > 0.25 ? f64(e.decoded) / el : 0
}
