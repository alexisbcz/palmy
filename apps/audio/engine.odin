package main

// Sound out, and the clock that comes back.
//
//   ffmpeg -ss T -i FILE -vn -f s16le -ar 48000 -ac 2 -   → PCM
//   pw-cat -p --raw --format s16 --rate 48000 -           → the speakers
//
// A pump thread moves bytes between them, scaling by the volume on the way. It
// blocks when PipeWire is full, so the running total of bytes handed over is
// how much audio the device has actually taken: `bytes / (rate · 2 · 2)` is the
// playing position, with the sink's own buffering measured once and subtracted.
// Everything the UI shows — elapsed, remaining, the playhead on the waveform,
// the window the spectrum is computed over — comes off that one number.

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
PW_LATENCY :: "40ms"

Engine :: struct {
	m:          Media,
	live:       bool,
	err:        string,

	aproc:      os.Process,
	sproc:      os.Process,
	apipe:      ^os.File,
	spipe:      ^os.File,
	pump:       ^thread.Thread,

	mu:         sync.Mutex,
	quit:       bool,
	paused:     bool,
	eof:        bool,

	base:       f64,
	bytes:      i64,
	lat_est:    f64,
	lat_locked: bool,
	lat_sum:    f64,
	lat_n:      int,
	started:    time.Time,

	// When the first PCM byte was handed over. The sink's buffering is
	// measured from there, not from process start: otherwise however long
	// ffmpeg took to open the file would be subtracted from it.
	first_write: time.Time,

	volume:     f32,
	muted:      bool,
	// Peak of the last chunk written, which is what makes a level meter
	// respond to the sound rather than to the clock.
	peak:       f32,
}

engine_init :: proc(e: ^Engine) {
	libc.signal(13, transmute(proc "c" (i32))libc.SIG_IGN)
	e.volume = 0.7
	e.lat_est = 0.1
}

engine_start :: proc(e: ^Engine, m: Media, at: f64) {
	engine_stop(e)
	e.m = m
	e.base = clamp(at, 0, max(0, m.duration - 0.05))
	e.bytes = 0
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

	sr, sw, serr := os.pipe()
	if serr != nil {
		e.err = "could not create the audio pipe"
		return
	}
	_, _ = linux.fcntl(linux.Fd(os.fd(sw)), linux.F_SETPIPE_SZ, i32(PIPE_BYTES))
	sink, perr := os.process_start(
		{
			command = {
				"pw-cat",
				"-p",
				"--raw",
				"--format",
				"s16",
				"--rate",
				fmt.tprintf("%d", RATE),
				"--channels",
				fmt.tprintf("%d", CH),
				"--latency",
				PW_LATENCY,
				"-",
			},
			stdin = sr,
			stdout = nil,
			stderr = nil,
		},
	)
	os.close(sr)
	if perr != nil {
		os.close(sw)
		e.err = "pw-cat is not installed — no sound output"
		return
	}

	ar, aw, aerr := os.pipe()
	if aerr != nil {
		os.close(sw)
		_ = os.process_kill(sink)
		e.err = "could not create the decode pipe"
		return
	}
	dec, derr := os.process_start(
		{
			command = {
				"ffmpeg",
				"-hide_banner",
				"-loglevel",
				"error",
				"-ss",
				fmt.tprintf("%.3f", e.base),
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
		os.close(sw)
		_ = os.process_kill(sink)
		e.err = "ffmpeg could not decode this file"
		return
	}

	e.sproc = sink
	e.aproc = dec
	e.apipe = ar
	e.spipe = sw
	e.live = true

	e.pump = thread.create(pump_main)
	e.pump.data = rawptr(e)
	thread.start(e.pump)
}

engine_stop :: proc(e: ^Engine) {
	if !e.live {
		return
	}
	sync.lock(&e.mu)
	e.quit = true
	e.paused = false
	sync.unlock(&e.mu)

	_ = os.process_kill(e.aproc)
	if e.pump != nil {
		thread.join(e.pump)
		thread.destroy(e.pump)
		e.pump = nil
	}
	_ = os.process_kill(e.sproc)
	_, _ = os.process_wait(e.sproc)
	_, _ = os.process_wait(e.aproc)
	if e.apipe != nil {os.close(e.apipe)}
	if e.spipe != nil {os.close(e.spipe)}
	e.apipe, e.spipe = nil, nil
	e.live = false
}

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
		sync.unlock(&e.mu)

		if paused {
			time.sleep(8 * time.Millisecond)
			continue
		}

		n, rerr := os.read(e.apipe, raw[:])
		if n <= 0 || rerr != nil {
			sync.lock(&e.mu)
			e.eof = true
			sync.unlock(&e.mu)
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
			w, werr := os.write(e.spipe, raw[off:n])
			if w <= 0 || werr != nil {
				sync.lock(&e.mu)
				e.eof = true
				sync.unlock(&e.mu)
				return
			}
			off += w
			sync.lock(&e.mu)
			if e.first_write == {} {
				e.first_write = time.now()
			}
			e.bytes += i64(w)
			sync.unlock(&e.mu)
		}
		sync.lock(&e.mu)
		e.peak = max(pk, e.peak * 0.75)
		sync.unlock(&e.mu)
	}
}

engine_clock :: proc(e: ^Engine) -> f64 {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	if !e.live {
		return e.base
	}
	return e.base + f64(e.bytes) / f64(BPS) - e.lat_est
}

engine_tick :: proc(e: ^Engine) {
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
