package main

// Sound in the preview, and the clock that comes back from it.
//
// What is audible
// ---------------
// `resolve_audio_mix` is the single answer to that question. It walks the
// audio tracks, applies the M/S resolution and each clip's gain, and returns a
// flat list of contributions. The exporter builds its `atrim`+`adelay`+`amix`
// chain from that list and so does this file, which is the whole point: a
// muted track, a soloed track or a clip at 40 % cannot mean one thing in the
// speakers and another in the written file, because there is only one function
// that decides.
//
// The pipeline
// ------------
//   ffmpeg -i A -i B … -filter_complex <the mix> -f s16le -ar 48000 -ac 2 -
//   pw-cat -p --raw --format s16 --rate 48000 --channels 2 -
//
// A pump thread moves bytes between them and counts every one it hands over.
//
// The clock
// ---------
// That byte count *is* the clock. pw-cat accepts bytes only as fast as the
// device consumes them, so `bytes / (48000 · 2 · 2)` is how much audio has
// actually been taken — a real clock with back-pressure rather than a
// wall-clock guess, which is what `ed.playhead += delta_time` used to be. The
// playhead is read off it and video frames are presented against it.
//
// What is left between the counter and the speaker — the pipe, pw-cat's own
// buffer, PipeWire's graph — is measured rather than assumed: at steady state
// the pump can only be ahead of the ear by exactly what is stored between
// them, so `bytes/BPS − (wall seconds since the first write)` converges on it.
// `mixer_latency` reports that number and the UI prints it.
//
// Why there is no pacing flag
// ---------------------------
// A sibling app measured `ffmpeg -re` at 5.9 % fast — 8.48 s of audio produced
// in 8.01 s — and paid for it with about twenty audible skips every thirty
// seconds, because something downstream has to throw the surplus away. Nothing
// here uses `-re`. Nor does it need `arealtime`: that filter exists to pace an
// *infinite live* source, and the only thing pacing this graph is pw-cat
// refusing bytes, which is the sound card itself. The silent bed below is
// given an explicit duration for the same reason — an endless `anullsrc` would
// be a live source with no clock, and the graph would never end.
//
// Locking (one mutex, `Mixer.mu`)
// -------------------------------
// Same rule as the other three workers: the pump does its blocking reads and
// writes with the lock released and takes it only to add to a byte counter, and
// no procedure in this file holds the lock while calling one that takes it.
// `mixer_start`/`mixer_stop` run on the UI thread and are the only places that
// touch the processes.

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import p "palmy:."

MIX_RATE :: 48000
MIX_CH :: 2
MIX_BPS :: MIX_RATE * MIX_CH * 2 // bytes of PCM per second
MIX_CHUNK :: 2048 // bytes per write to pw-cat: 10.6 ms
MIX_PIPE :: 4096 // one page, the smallest a Linux pipe can be: 21 ms
MIX_PW_LATENCY :: "40ms"

// ---------------------------------------------------------------------------
// What is audible — shared with the exporter
// ---------------------------------------------------------------------------

// Mix_Src is one audio contribution: a window of one source file, placed at a
// delay from the start of the mix, at a gain.
Mix_Src :: struct {
	media:   int, // index into Project.media
	clip:    int, // clip id, so a caller can name what it is hearing
	track:   int,
	src_in:  f64, // source seconds
	src_out: f64,
	gain:    f32,
	delay:   f64, // seconds after `from` that this contribution starts
}

// resolve_audio_mix lists every audio contribution from `from` onwards.
//
// Sound comes from the audio tracks and nowhere else: a video clip and its
// audio are placed as a pair, so counting a video clip's audio too would mix
// every take twice. One clip, one contribution.
//
// `from` is what lets the preview share this with the export. At `from = 0` it
// returns the whole timeline, which is what the exporter wants. Past that, a
// clip straddling `from` is clipped — its source in point moves forward by
// however much of it is already behind the playhead — so starting playback in
// the middle of a clip starts the sound in the middle of the clip too.
resolve_audio_mix :: proc(
	pr: ^Project,
	from: f64,
	alloc := context.temp_allocator,
) -> []Mix_Src {
	out := make([dynamic]Mix_Src, alloc)
	for &t, ti in pr.tracks {
		if t.kind != .Audio || !track_enabled(pr, ti) {
			continue
		}
		for c in t.clips {
			if c.media < 0 || c.media >= len(pr.media) || !pr.media[c.media].has_audio {
				continue
			}
			if clip_len(c) <= 0.01 {
				continue
			}
			if clip_end(c) <= from + 0.01 {
				continue // already behind the playhead
			}
			a := math.max(c.start, from)
			append(
				&out,
				Mix_Src {
					media = c.media,
					clip = c.id,
					track = ti,
					src_in = c.src_in + (a - c.start),
					src_out = c.src_out,
					gain = c.gain,
					delay = a - from,
				},
			)
		}
	}
	return out[:]
}

// mix_chain writes the filter chain for one contribution. The exporter and the
// preview differ only in the sample rate they resample to and the input index
// a path landed on, so they pass those in and share the rest.
mix_chain :: proc(sb: ^strings.Builder, s: Mix_Src, input: int, rate: int, label: string) {
	fmt.sbprintf(
		sb,
		"[%d:a]atrim=start=%.4f:end=%.4f,asetpts=PTS-STARTPTS,volume=%.4f," +
		"aresample=%d,aformat=sample_fmts=fltp:channel_layouts=stereo," +
		"adelay=%d:all=1[%s];",
		input,
		s.src_in,
		s.src_out,
		s.gain,
		rate,
		int(s.delay * 1000 + 0.5),
		label,
	)
}

// ---------------------------------------------------------------------------
// The mixer
// ---------------------------------------------------------------------------

Mixer :: struct {
	mu:          sync.Mutex,

	// Processes and pipes. UI thread only.
	live:        bool,
	aproc:       os.Process, // ffmpeg, the mix
	sproc:       os.Process, // pw-cat, the speakers
	apipe:       ^os.File, // read end: mixed PCM
	spipe:       ^os.File, // write end: pw-cat's stdin
	pump:        ^thread.Thread,
	err:         string, // owned

	// Shared, guarded by mu.
	quit:        bool,
	eof:         bool,
	bytes:       i64, // PCM bytes handed to pw-cat since the last start
	peak:        f32,
	sum:         u64, // |sample| summed, so a headless test can see the mix is not silence
	first_write: time.Time,

	// The clock's constants.
	base:        f64, // timeline second the pipeline was started at
	span:        f64, // seconds of timeline the pipeline will produce
	lat_est:     f64, // measured sink buffering, seconds
	lat_locked:  bool,
	lat_sum:     f64,
	lat_n:       int,

	// Instrumentation, written by the UI thread between starts.
	started:     time.Time,
	start_ms:    f64, // mixer_start to the first byte handed over
	srcs:        int, // contributions in the running graph
	starts:      int,
	flushes:     int,
	silent:      bool, // zero the samples: identical byte flow, no sound
}

mixer_init :: proc(mx: ^Mixer) {
	// Killing pw-cat while the pump is mid-write would otherwise take the
	// whole process down with SIGPIPE.
	libc.signal(13, transmute(proc "c" (i32))libc.SIG_IGN)
	mx.lat_est = 0.10
}

mixer_live :: proc(mx: ^Mixer) -> bool {
	return mx.live
}

// mixer_start builds the graph for the timeline from `at` and opens the
// pipeline. `total` is where the timeline ends, which is how long the silent
// bed is made.
mixer_start :: proc(mx: ^Mixer, pr: ^Project, at, total: f64) -> bool {
	mixer_stop(mx)

	span := total - at
	if span <= 0.02 {
		return false
	}
	mx.base = math.max(0, at)
	mx.span = span
	mx.bytes = 0
	mx.sum = 0
	mx.eof = false
	mx.quit = false
	mx.first_write = {}
	mx.started = time.now()
	mx.start_ms = 0
	delete(mx.err)
	mx.err = ""

	argv, nsrc := mix_argv(pr, mx.base, span, context.temp_allocator)
	mx.srcs = nsrc

	// The sink first, so ffmpeg has somewhere to write.
	sr, sw, serr := os.pipe()
	if serr != nil {
		mx.err = strings.clone("could not create the audio pipe")
		return false
	}
	// Every byte sitting in this pipe is latency between the clock and the
	// speaker, so it is worth making it as small as Linux allows: one page
	// holds 21 ms.
	_, _ = linux.fcntl(linux.Fd(os.fd(sw)), linux.F_SETPIPE_SZ, i32(MIX_PIPE))
	sink, perr := os.process_start(
		{
			command = {
				"pw-cat",
				"-p",
				"--raw",
				"--format",
				"s16",
				"--rate",
				fmt.tprintf("%d", MIX_RATE),
				"--channels",
				fmt.tprintf("%d", MIX_CH),
				"--latency",
				MIX_PW_LATENCY,
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
		mx.err = strings.clone("pw-cat is not available — the preview is silent")
		return false
	}

	ar, aw, aerr := os.pipe()
	if aerr != nil {
		os.close(sw)
		_ = os.process_kill(sink)
		mx.err = strings.clone("could not create the mix pipe")
		return false
	}
	dec, derr := os.process_start({command = argv, stdout = aw, stderr = nil, stdin = nil})
	os.close(aw)
	if derr != nil {
		os.close(ar)
		os.close(sw)
		_ = os.process_kill(sink)
		mx.err = strings.clone("ffmpeg could not mix the timeline")
		return false
	}

	mx.sproc = sink
	mx.aproc = dec
	mx.apipe = ar
	mx.spipe = sw
	mx.live = true
	mx.starts += 1

	mx.pump = thread.create(mix_pump)
	mx.pump.data = rawptr(mx)
	thread.start(mx.pump)
	return true
}

// mixer_stop tears the pipeline down, which is also the flush: the pipe, the
// decoder's buffer and pw-cat's queue all go with the processes, so nothing
// stale can be heard after a seek. There is no way to flush a pipe that is
// cheaper and no way that is more certain.
mixer_stop :: proc(mx: ^Mixer) {
	if !mx.live {
		return
	}
	sync.lock(&mx.mu)
	mx.quit = true
	sync.unlock(&mx.mu)

	// Both processes go before the pump is joined, and that order is the
	// point. Killing ffmpeg alone makes a pump blocked on a *read* fall out of
	// its loop, but a pump blocked on a *write* is waiting for pw-cat to take
	// bytes — which is the normal state, since that back-pressure is the
	// clock — and would keep waiting. Killing the sink too turns that write
	// into EPIPE (SIGPIPE is ignored, see mixer_init), so the join is bounded
	// by one chunk rather than by whatever the audio device decides to do.
	_ = os.process_kill(mx.aproc)
	_ = os.process_kill(mx.sproc)
	if mx.pump != nil {
		thread.join(mx.pump)
		thread.destroy(mx.pump)
		mx.pump = nil
	}
	_, _ = os.process_wait(mx.sproc)
	_, _ = os.process_wait(mx.aproc)
	if mx.apipe != nil {os.close(mx.apipe)}
	if mx.spipe != nil {os.close(mx.spipe)}
	mx.apipe, mx.spipe = nil, nil
	mx.live = false
	mx.flushes += 1
}

mixer_destroy :: proc(mx: ^Mixer) {
	mixer_stop(mx)
	delete(mx.err)
	mx.err = ""
}

// mix_argv is the whole invocation, and the only place the preview's graph is
// written. One `-i` per distinct path in first-use order, then a silent bed the
// length of what is left of the timeline with every contribution mixed onto it.
//
// The bed is not decoration. It gives the clock something to run on across a
// gap in the timeline and over a timeline with no audio at all, and its
// explicit duration is what ends the graph exactly at the end of the timeline
// — measured: a 9-second bed produces 1,728,000 bytes and stops.
mix_argv :: proc(
	pr: ^Project,
	from, span: f64,
	alloc := context.temp_allocator,
) -> (
	[]string,
	int,
) {
	context.allocator = alloc
	srcs := resolve_audio_mix(pr, from, alloc)

	inputs := make([dynamic]string, alloc)
	input_of :: proc(inputs: ^[dynamic]string, path: string) -> int {
		for s, i in inputs {
			if s == path {
				return i
			}
		}
		append(inputs, path)
		return len(inputs) - 1
	}

	g := strings.builder_make(alloc)
	fmt.sbprintf(
		&g,
		"anullsrc=channel_layout=stereo:sample_rate=%d:d=%.4f[bed];",
		MIX_RATE,
		span,
	)
	labels := make([dynamic]string, alloc)
	for s in srcs {
		ii := input_of(&inputs, pr.media[s.media].path)
		label := fmt.tprintf("m%d", len(labels))
		mix_chain(&g, s, ii, MIX_RATE, label)
		append(&labels, label)
	}
	fmt.sbprintf(&g, "[bed]")
	for l in labels {
		fmt.sbprintf(&g, "[%s]", l)
	}
	fmt.sbprintf(
		&g,
		"amix=inputs=%d:normalize=0:dropout_transition=0[aout]",
		len(labels) + 1,
	)

	argv := make([dynamic]string, alloc)
	append(&argv, "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error")
	for path in inputs {
		append(&argv, "-i", path)
	}
	append(&argv, "-filter_complex", strings.to_string(g))
	append(&argv, "-map", "[aout]")
	append(&argv, "-f", "s16le", "-acodec", "pcm_s16le")
	append(&argv, "-ar", fmt.tprintf("%d", MIX_RATE), "-ac", fmt.tprintf("%d", MIX_CH))
	// The bed already ends the graph; `-t` is the belt to its braces, so a
	// filter that decides to run long cannot play past the timeline.
	append(&argv, "-t", fmt.tprintf("%.4f", span))
	append(&argv, "-")
	return argv[:], len(srcs)
}

// ---------------------------------------------------------------------------
// The pump
// ---------------------------------------------------------------------------

@(private = "file")
mix_pump :: proc(t: ^thread.Thread) {
	mx := (^Mixer)(t.data)
	raw: [MIX_CHUNK]u8
	for {
		sync.lock(&mx.mu)
		if mx.quit {
			sync.unlock(&mx.mu)
			return
		}
		silent := mx.silent
		sync.unlock(&mx.mu)

		n, rerr := os.read(mx.apipe, raw[:])
		if n <= 0 || rerr != nil {
			sync.lock(&mx.mu)
			mx.eof = true
			sync.unlock(&mx.mu)
			return
		}
		n &= ~int(1) // whole samples only

		// The gains are in the graph, where the exporter puts them too; the
		// pump only measures. `silent` is the measurement mode: the byte flow
		// and therefore the clock are identical, there is simply nothing to
		// hear, which is what lets the latency be measured without filling
		// the room.
		s := (transmute([^]i16)raw_data(raw[:]))[:n / 2]
		pk := f32(0)
		acc := u64(0)
		for i in 0 ..< len(s) {
			v := abs(f32(s[i])) * (1.0 / 32768)
			if v > pk {pk = v}
			acc += u64(abs(int(s[i])))
			if silent {
				s[i] = 0
			}
		}

		off := 0
		for off < n {
			w, werr := os.write(mx.spipe, raw[off:n])
			if w <= 0 || werr != nil {
				sync.lock(&mx.mu)
				mx.eof = true
				sync.unlock(&mx.mu)
				return
			}
			off += w
			sync.lock(&mx.mu)
			if mx.first_write == {} {
				mx.first_write = time.now()
			}
			mx.bytes += i64(w)
			sync.unlock(&mx.mu)
		}
		sync.lock(&mx.mu)
		mx.peak = max(pk, mx.peak * 0.75)
		mx.sum += acc
		sync.unlock(&mx.mu)
	}
}

// ---------------------------------------------------------------------------
// The clock
// ---------------------------------------------------------------------------

// mixer_clock is the timeline second the speakers have reached.
//
// It is clamped at `base` rather than allowed to start negative: at the
// instant playback begins, `lat_est` seconds of sound are in flight and have
// not been heard, so the honest playhead stands still until the first sample
// arrives at the ear instead of jumping backwards from where the user left it.
mixer_clock :: proc(mx: ^Mixer) -> f64 {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	if !mx.live {
		return mx.base
	}
	return math.max(mx.base, mx.base + f64(mx.bytes) / f64(MIX_BPS) - mx.lat_est)
}

// mixer_tick measures what sits between the byte counter and the ear while it
// settles, and is called once a frame. At steady state the pump can only be
// ahead of the speakers by what is stored between them, so
// (bytes handed over) − (seconds since the first byte) converges on exactly
// that. It is measured from the first *write*, not from process start:
// otherwise however long ffmpeg took to open four files would be subtracted
// from the sink's buffering.
mixer_tick :: proc(mx: ^Mixer) {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	if !mx.live || mx.first_write == {} {
		return
	}
	if mx.start_ms == 0 {
		mx.start_ms = time.duration_milliseconds(time.diff(mx.started, mx.first_write))
	}
	if mx.lat_locked {
		return
	}
	el := time.duration_seconds(time.since(mx.first_write))
	if el < 0.6 {
		return
	}
	inst := f64(mx.bytes) / f64(MIX_BPS) - el
	if inst > 0 && inst < 2 {
		mx.lat_sum += inst
		mx.lat_n += 1
	}
	if el > 2.0 && mx.lat_n > 8 {
		mx.lat_est = mx.lat_sum / f64(mx.lat_n)
		mx.lat_locked = true
	}
}

// mixer_done is true once the pipeline has run out, which — because the bed
// carries the timeline's own length — means the playhead reached the end.
mixer_done :: proc(mx: ^Mixer) -> bool {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	return mx.eof
}

mixer_level :: proc(mx: ^Mixer) -> f32 {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	return mx.live ? mx.peak : 0
}

mixer_latency :: proc(mx: ^Mixer) -> (sec: f64, locked: bool) {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	return mx.lat_est, mx.lat_locked
}

mixer_bytes :: proc(mx: ^Mixer) -> (bytes: i64, sum: u64) {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	return mx.bytes, mx.sum
}

mixer_startup_ms :: proc(mx: ^Mixer) -> f64 {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	return mx.start_ms
}

mixer_error :: proc(mx: ^Mixer) -> string {
	return mx.err
}

// ---------------------------------------------------------------------------
// The editor's side of it
// ---------------------------------------------------------------------------

// MIX_REBUILD_GAP is how often the graph may be rebuilt while playing. A
// rebuild is a kill and a restart, so it costs a short silence; a gain slider
// dragged across its range would otherwise rebuild sixty times a second and
// produce nothing but silences. An edit therefore sets `mix_dirty` and this is
// what decides when to act on it.
MIX_REBUILD_GAP :: 0.25

// audio_follow is the whole of the transport. It runs once a frame, before
// input, and it owns `ed.playhead` while the timeline is playing.
//
// The order matters. A scrub owns the playhead outright and must be silent —
// dragging the ruler across ten seconds would otherwise start and kill ten
// pipelines and play a burst of each. A deliberate seek (`seek_req`) or an
// edit that changed the mix (`mix_dirty`) restarts the pipeline, and
// restarting *is* the flush: the pipe, ffmpeg's buffer and pw-cat's queue all
// go with the processes, so there is no stale audio left to come out.
audio_follow :: proc(ed: ^Editor, ui: ^p.Ctx) {
	total := project_duration(&ed.pr)

	// Dragging the playhead: silence, and nothing to restart until the mouse
	// comes up.
	if ed.drag == .Scrub {
		mixer_stop(&ed.mx)
		ed.seek_req = true
		return
	}
	if !ed.playing {
		mixer_stop(&ed.mx)
		ed.seek_req = true
		ed.mix_dirty = false
		return
	}

	want_restart := ed.seek_req || !mixer_live(&ed.mx)
	if ed.mix_dirty &&
	   ed.drag == .None &&
	   time.duration_seconds(time.since(ed.mix_built)) > MIX_REBUILD_GAP {
		want_restart = true
	}
	if want_restart {
		ed.seek_req = false
		ed.mix_dirty = false
		ed.mix_built = time.now()
		// Restart from where the ear has got to, not from where the pipeline
		// was told to start, so an edit mid-playback does not rewind.
		at := mixer_live(&ed.mx) ? mixer_clock(&ed.mx) : ed.playhead
		if !mixer_start(&ed.mx, &ed.pr, math.max(0, at), total) {
			if e := mixer_error(&ed.mx); e != "" && !ed.audio_said {
				ed.audio_said = true
				status(ed, ui, e)
			}
		}
	}

	if mixer_live(&ed.mx) {
		ed.playhead = math.min(mixer_clock(&ed.mx), total)
		if mixer_done(&ed.mx) {
			// The bed carries the timeline's own length, so the pipeline
			// running out means the playhead reached the end.
			ed.playhead = total
			ed.playing = false
			mixer_stop(&ed.mx)
		}
	} else {
		// No sink: the old wall clock, which is better than a frozen playhead.
		ed.playhead += f64(p.delta_time(ui))
		if ed.playhead >= total {
			ed.playhead = total
			ed.playing = false
		}
	}
	p.redraw(ui)
}

// audio_stat_line is what the transport shows. Everything in it is measured.
audio_stat_line :: proc(ed: ^Editor, alloc := context.temp_allocator) -> string {
	lat, locked := mixer_latency(&ed.mx)
	if !mixer_live(&ed.mx) {
		if e := mixer_error(&ed.mx); e != "" {
			return fmt.aprintf("audio: %s", e, allocator = alloc)
		}
		return fmt.aprintf(
			"audio idle  ·  sink %.0f ms%s",
			lat * 1000,
			locked ? "" : " (est)",
			allocator = alloc,
		)
	}
	avg := ed.pres_n > 0 ? ed.pres_sum / f64(ed.pres_n) : 0
	return fmt.aprintf(
		"audio %d src  ·  sink %.0f ms%s  ·  start %.0f ms  ·  present %+.0f/%.0f ms",
		ed.mx.srcs,
		lat * 1000,
		locked ? "" : " est",
		mixer_startup_ms(&ed.mx),
		avg * 1000,
		ed.pres_max * 1000,
		allocator = alloc,
	)
}

// audio_note_presentation records how far the frame that was actually painted
// sat from the audio clock. This is the preview's presentation error, and it is
// dominated by the cache grid: a frame can only be at a multiple of
// 1/PREVIEW_FPS, so even a perfect decoder is up to half a grid step out.
audio_note_presentation :: proc(ed: ^Editor, frame_t, clock: f64, hit: bool) {
	if !ed.playing || !mixer_live(&ed.mx) {
		return
	}
	if !hit {
		ed.pres_miss += 1
		return
	}
	e := abs(frame_t - clock)
	ed.pres_sum += e
	ed.pres_max = math.max(ed.pres_max, e)
	ed.pres_n += 1
}

audio_reset_presentation :: proc(ed: ^Editor) {
	ed.pres_sum, ed.pres_max, ed.pres_n, ed.pres_miss = 0, 0, 0, 0
}
