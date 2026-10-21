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
//   ffmpeg -i A -i B … -filter_complex <one stem per clip> -f f32le -
//   pw-cat -p [--raw] --format s16 --rate 48000 --channels 2 -
//
// A pump thread sums the stems at their gains, moves the result between the
// two and counts every byte it hands over. Why the gains are in the pump and
// not in the graph is under "The graph" below.
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
	all_tracks := false,
) -> []Mix_Src {
	out := make([dynamic]Mix_Src, alloc)
	for &t, ti in pr.tracks {
		if t.kind != .Audio {
			continue
		}
		// `all_tracks` is the live mixer asking for every clip that *could*
		// be heard, so that a mute or a solo is a gain of zero it can change
		// while playing rather than a different graph. The gain it is given
		// here is still this function's answer: zero on a disabled track.
		enabled := track_enabled(pr, ti)
		if !enabled && !all_tracks {
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
					gain = enabled ? c.gain : 0,
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
// The graph: stems, so a gain is not a rebuild
// ---------------------------------------------------------------------------
//
// The live mixer used to bake every gain into the ffmpeg graph (`volume=` per
// contribution, then `amix`), which meant that the only way to honour a gain
// change, a mute or a solo while playing was to kill the pipeline and start a
// new one. That is a flush, and a flush is a hole in the sound: ~87 ms of
// silence per change, measured, and a gain slider dragged across its range
// was throttled to four rebuilds a second to keep it from being nothing but
// holes.
//
// Now ffmpeg does what only ffmpeg can do — decode, trim, resample, delay —
// and hands back each contribution as its own stereo pair: every one is padded
// to the length of the bed and `amerge`d into one stream of 2·(n+1) float
// channels (the bed is pair 0). The pump sums those pairs with gains it reads
// under its lock on every 10.6 ms chunk, so a gain change is one store into
// an array and is heard on the next chunk, with a ramp across that chunk so it
// does not click. Mute and solo are gains of zero: the graph is built from
// every audio clip that could be heard (`resolve_audio_mix(…, all_tracks =
// true)`) and the gains come from the same function, so a muted track is
// still exactly as silent as the exporter makes it.
//
// What still rebuilds is a change to *what* plays: a clip moved, trimmed,
// split, added or deleted. `mix_layout_key` hashes exactly those properties
// and nothing else, so the editor can tell the two kinds of edit apart without
// knowing which key was pressed.
//
// Two limits, both honest fallbacks rather than failures:
//   - amerge takes at most 64 inputs, so past MIX_MAX_STEMS contributions the
//     graph is the old baked one (`mix_argv`), and a gain change there still
//     rebuilds. The stats line says which kind of graph is running.
//   - the bandwidth is 2·(n+1)·4 bytes per sample frame: 64 stems at 48 kHz
//     is 25 MB/s through a pipe, which a pipe does without noticing.

MIX_MAX_STEMS :: 63 // + the bed = amerge's 64-input limit

// Mix_Graph is one invocation and what the pump needs to know to read it.
Mix_Graph :: struct {
	argv:      []string,
	srcs:      int, // contributions, not counting the bed
	stem_clip: []int, // per stereo pair: the clip id it carries, -1 for the bed; nil when baked
	chans:     int, // channels in the stream ffmpeg writes
	float:     bool, // f32le stems (true) or the baked s16le mix (false)
	rate:      f64, // playback rate: timeline seconds per second of sound
	span:      f64, // timeline seconds the graph covers
}

// atempo_chain is the filter for a playback rate. atempo is pitch-preserving
// and, in the ffmpeg builds that matter here, takes 0.5–2.0 per instance, so
// rates outside that are a chain of two.
atempo_chain :: proc(rate: f64, alloc := context.temp_allocator) -> string {
	r := rate
	sb := strings.builder_make(alloc)
	for r < 0.5 - 1e-9 {
		strings.write_string(&sb, "atempo=0.5,")
		r /= 0.5
	}
	for r > 2.0 + 1e-9 {
		strings.write_string(&sb, "atempo=2.0,")
		r /= 2.0
	}
	fmt.sbprintf(&sb, "atempo=%.6f", r)
	return strings.to_string(sb)
}

// mix_graph builds the preview's graph from `from` for `span` timeline
// seconds at `rate`. Stems unless there are too many of them (or `baked` is
// asked for, which the self-test does to compare the two).
mix_graph :: proc(
	pr: ^Project,
	from, span: f64,
	rate := 1.0,
	alloc := context.temp_allocator,
	baked := false,
) -> Mix_Graph {
	context.allocator = alloc
	rate := rate > 0 ? rate : 1
	srcs := resolve_audio_mix(pr, from, alloc, true)
	if baked || len(srcs) > MIX_MAX_STEMS {
		argv, n := mix_argv(pr, from, span, alloc, rate)
		return Mix_Graph{argv = argv, srcs = n, chans = MIX_CH, float = false, rate = rate, span = span}
	}

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
	stem_clip := make([]int, len(srcs) + 1, alloc)
	stem_clip[0] = -1

	g := strings.builder_make(alloc)
	fmt.sbprintf(
		&g,
		"anullsrc=channel_layout=stereo:sample_rate=%d:d=%.4f[bed];",
		MIX_RATE,
		span,
	)
	for s, k in srcs {
		ii := input_of(&inputs, pr.media[s.media].path)
		stem_clip[k + 1] = s.clip
		// No `volume`: the gain is the pump's. Each stem is padded out to the
		// bed's length because amerge stops at its shortest input.
		fmt.sbprintf(
			&g,
			"[%d:a]atrim=start=%.4f:end=%.4f,asetpts=PTS-STARTPTS," +
			"aresample=%d,aformat=sample_fmts=fltp:channel_layouts=stereo," +
			"adelay=%d:all=1,apad=whole_dur=%.4f[m%d];",
			ii,
			s.src_in,
			s.src_out,
			MIX_RATE,
			int(s.delay * 1000 + 0.5),
			span,
			k,
		)
	}
	tail := abs(rate - 1) > 1e-6 ? fmt.tprintf(",%s", atempo_chain(rate, alloc)) : ""
	if len(srcs) == 0 {
		fmt.sbprintf(&g, "[bed]anull%s[aout]", tail)
	} else {
		fmt.sbprintf(&g, "[bed]")
		for k in 0 ..< len(srcs) {
			fmt.sbprintf(&g, "[m%d]", k)
		}
		fmt.sbprintf(&g, "amerge=inputs=%d%s[aout]", len(srcs) + 1, tail)
	}

	argv := make([dynamic]string, alloc)
	append(&argv, "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error")
	for path in inputs {
		append(&argv, "-i", path)
	}
	append(&argv, "-filter_complex", strings.to_string(g))
	append(&argv, "-map", "[aout]")
	// No -ac: that would down-mix the stems. Every stem is already at MIX_RATE.
	append(&argv, "-f", "f32le", "-acodec", "pcm_f32le")
	append(&argv, "-t", fmt.tprintf("%.4f", span / rate))
	append(&argv, "-")
	return Mix_Graph {
		argv = argv[:],
		srcs = len(srcs),
		stem_clip = stem_clip,
		chans = 2 * (len(srcs) + 1),
		float = true,
		rate = rate,
		span = span,
	}
}

// mix_layout_key hashes what decides the *shape* of the graph — which clips
// are on which audio track, where, and which window of which source — and
// deliberately not gains, mutes or solos. Two projects with the same key can
// share a running graph and differ only in what the pump multiplies by.
mix_layout_key :: proc(pr: ^Project) -> u64 {
	h := u64(0xcbf29ce484222325)
	mixin :: proc(h: ^u64, v: u64) {
		x := v
		for _ in 0 ..< 8 {
			h^ = (h^ ~ (x & 0xff)) * 0x100000001b3
			x >>= 8
		}
	}
	for &t, ti in pr.tracks {
		if t.kind != .Audio {
			continue
		}
		mixin(&h, u64(ti) | 0xA0000000)
		for c in t.clips {
			mixin(&h, u64(c.id))
			mixin(&h, u64(c.media + 1))
			mixin(&h, transmute(u64)c.start)
			mixin(&h, transmute(u64)c.src_in)
			mixin(&h, transmute(u64)c.src_out)
			if c.media >= 0 && c.media < len(pr.media) {
				mixin(&h, pr.media[c.media].has_audio ? 1 : 2)
			}
		}
	}
	mixin(&h, u64(len(pr.media)))
	return h
}

// stem_gains is what the pump should multiply each stem by now. The answer
// comes from `resolve_audio_mix`, the same function the exporter asks, so a
// live mute cannot mean something different in the speakers and in the file.
// It returns false if a stem's clip is no longer there, which means the graph
// is stale and has to be rebuilt.
stem_gains :: proc(pr: ^Project, stem_clip: []int, out: []f32) -> bool {
	for &g in out {
		g = 0
	}
	if len(stem_clip) > len(out) {
		return false
	}
	all := resolve_audio_mix(pr, 0, context.temp_allocator, true)
	for id, k in stem_clip {
		if id < 0 {
			continue // the bed is silence; its gain is irrelevant
		}
		found := false
		for s in all {
			if s.clip == id {
				out[k] = s.gain
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// mix_stems sums `frames` frames of interleaved stems into interleaved stereo,
// with each stem's gain moving linearly from `g0` to `g1` across the block.
// The ramp is what keeps a gain change from clicking: a step from 1.0 to 0.2
// in one sample is a click, the same step across 512 samples is not.
mix_stems :: proc(src: []f32, chans: int, g0, g1: []f32, out: []f32) {
	frames := len(out) / 2
	for &v in out {
		v = 0
	}
	if frames == 0 || chans < 2 {
		return
	}
	inv := 1.0 / f32(frames)
	for k in 0 ..< chans / 2 {
		a, b := g0[k], g1[k]
		if a == 0 && b == 0 {
			continue
		}
		step := (b - a) * inv
		g := a
		for f in 0 ..< frames {
			base := f * chans + 2 * k
			out[2 * f] += src[base] * g
			out[2 * f + 1] += src[base + 1] * g
			g += step
		}
	}
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

	// The running graph's shape. UI thread only, set by mixer_start.
	stem_clip:   [dynamic]int,
	chans:       int,
	float:       bool,
	layout:      u64,
	rate:        f64,

	// Shared, guarded by mu.
	quit:        bool,
	eof:         bool,
	bytes:       i64, // PCM bytes handed to pw-cat since the last start
	peak:        f32,
	sum:         u64, // |sample| summed, so a headless test can see the mix is not silence
	first_write: time.Time,
	gains:       [MIX_MAX_STEMS + 1]f32, // per stem; the pump reads them every chunk
	gain_sets:   int, // live gain changes since the last start
	max_gap_ms:  f64, // the longest wait between two writes to pw-cat since the last start
	last_write:  time.Time,

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
	live_gains:  int, // gain/mute/solo changes honoured without a rebuild, ever
	silent:      bool, // zero the samples: identical byte flow, no sound
}

// ignore_sigpipe: killing pw-cat while a pump is mid-write would otherwise
// take the whole process down with SIGPIPE.
ignore_sigpipe :: proc() {
	libc.signal(13, transmute(proc "c" (i32))libc.SIG_IGN)
}

mixer_init :: proc(mx: ^Mixer) {
	ignore_sigpipe()
	mx.lat_est = 0.10
	mx.rate = 1
}

mixer_live :: proc(mx: ^Mixer) -> bool {
	return mx.live
}

// pw_cat_argv is the sink. PipeWire 1.2 added `--raw` and requires it for a
// headerless stream on stdin; 1.0 (Ubuntu 24.04's) has no such flag, refuses
// the whole command line if it is given, and already treats `-` as a raw
// pipe. So the flag is asked about once rather than assumed.
pw_cat_argv :: proc(alloc := context.temp_allocator) -> []string {
	@(static) probed: bool
	@(static) has_raw: bool
	if !probed {
		probed = true
		_, out, serr, err := os.process_exec({command = {"pw-cat", "--help"}}, context.temp_allocator)
		has_raw = err == nil && (strings.contains(string(out), "--raw") || strings.contains(string(serr), "--raw"))
	}
	a := make([dynamic]string, alloc)
	append(&a, "pw-cat", "-p")
	if has_raw {
		append(&a, "--raw")
	}
	append(
		&a,
		"--format",
		"s16",
		"--rate",
		fmt.aprintf("%d", MIX_RATE, allocator = alloc),
		"--channels",
		fmt.aprintf("%d", MIX_CH, allocator = alloc),
		"--latency",
		MIX_PW_LATENCY,
		"-",
	)
	return a[:]
}

// mixer_start builds the graph for the timeline from `at` and opens the
// pipeline. `total` is where the timeline ends, which is how long the silent
// bed is made. `rate` is timeline seconds per second of sound.
mixer_start :: proc(mx: ^Mixer, pr: ^Project, at, total: f64, rate := 1.0) -> bool {
	mixer_stop(mx)

	span := total - at
	if span <= 0.02 {
		return false
	}
	mx.base = math.max(0, at)
	mx.span = span
	mx.rate = rate > 0 ? rate : 1
	mx.bytes = 0
	mx.sum = 0
	mx.eof = false
	mx.quit = false
	mx.first_write = {}
	mx.last_write = {}
	mx.max_gap_ms = 0
	mx.gain_sets = 0
	mx.started = time.now()
	mx.start_ms = 0
	delete(mx.err)
	mx.err = ""

	gr := mix_graph(pr, mx.base, span, mx.rate, context.temp_allocator)
	mx.srcs = gr.srcs
	mx.chans = gr.chans
	mx.float = gr.float
	mx.layout = mix_layout_key(pr)
	clear(&mx.stem_clip)
	append(&mx.stem_clip, ..gr.stem_clip)
	if gr.float {
		_ = stem_gains(pr, gr.stem_clip, mx.gains[:])
	}

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
	sink, perr := os.process_start({command = pw_cat_argv(), stdin = sr, stdout = nil, stderr = nil})
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
	dec, derr := os.process_start({command = gr.argv, stdout = aw, stderr = nil, stdin = nil})
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

// mixer_set_gains is the live path: if the running graph has the project's
// layout, the new gains (and mutes and solos, which are gains of zero) are
// stored for the pump and nothing is restarted. It returns false when the
// graph cannot honour the change — it is baked, or a clip moved — and the
// caller rebuilds.
mixer_set_gains :: proc(mx: ^Mixer, pr: ^Project) -> bool {
	if !mx.live || !mx.float || mix_layout_key(pr) != mx.layout {
		return false
	}
	g: [MIX_MAX_STEMS + 1]f32
	if !stem_gains(pr, mx.stem_clip[:], g[:]) {
		return false
	}
	sync.lock(&mx.mu)
	mx.gains = g
	mx.gain_sets += 1
	sync.unlock(&mx.mu)
	mx.live_gains += 1
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
	delete(mx.stem_clip)
	mx.stem_clip = nil
}

// mix_argv is the *baked* graph: one `-i` per distinct path in first-use
// order, then a silent bed the length of what is left of the timeline with
// every contribution mixed onto it at its gain, out as one stereo s16 pair.
// It is what the preview ran before stems, and it is still what runs past
// MIX_MAX_STEMS contributions; the self-test also renders it to check the
// stems sum to the same sound.
//
// The bed is not decoration. It gives the clock something to run on across a
// gap in the timeline and over a timeline with no audio at all, and its
// explicit duration is what ends the graph exactly at the end of the timeline
// — measured: a 9-second bed produces 1,728,000 bytes and stops.
mix_argv :: proc(
	pr: ^Project,
	from, span: f64,
	alloc := context.temp_allocator,
	rate := 1.0,
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
		"amix=inputs=%d:normalize=0:dropout_transition=0",
		len(labels) + 1,
	)
	if abs(rate - 1) > 1e-6 {
		fmt.sbprintf(&g, ",%s", atempo_chain(rate, alloc))
	}
	fmt.sbprintf(&g, "[aout]")

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
	append(&argv, "-t", fmt.tprintf("%.4f", span / (rate > 0 ? rate : 1)))
	append(&argv, "-")
	return argv[:], len(srcs)
}

// ---------------------------------------------------------------------------
// The pump
// ---------------------------------------------------------------------------

MIX_FRAMES :: MIX_CHUNK / (MIX_CH * 2) // 512 stereo frames per write

@(private = "file")
mix_pump :: proc(t: ^thread.Thread) {
	mx := (^Mixer)(t.data)
	raw: [MIX_CHUNK]u8
	chans := max(mx.chans, MIX_CH)
	float := mx.float
	// A stem block: MIX_FRAMES frames of `chans` floats. Read whole, so a
	// partial read never splits a frame across two mixes.
	stem := make([]f32, float ? MIX_FRAMES * chans : 0)
	defer delete(stem)
	mixed: [MIX_FRAMES * MIX_CH]f32
	prev: [MIX_MAX_STEMS + 1]f32
	sync.lock(&mx.mu)
	prev = mx.gains
	sync.unlock(&mx.mu)

	for {
		sync.lock(&mx.mu)
		if mx.quit {
			sync.unlock(&mx.mu)
			return
		}
		silent := mx.silent
		cur := mx.gains
		sync.unlock(&mx.mu)

		n := 0
		if float {
			if !read_full(mx.apipe, slice_to_bytes(stem)) {
				sync.lock(&mx.mu)
				mx.eof = true
				sync.unlock(&mx.mu)
				return
			}
			mix_stems(stem, chans, prev[:], cur[:], mixed[:])
			prev = cur
			out := (transmute([^]i16)raw_data(raw[:]))[:MIX_FRAMES * MIX_CH]
			for v, i in mixed {
				out[i] = i16(clamp(v, -1, 1) * 32767)
			}
			n = MIX_CHUNK
		} else {
			// The baked graph: gains are already in the samples.
			r, rerr := os.read(mx.apipe, raw[:])
			if r <= 0 || rerr != nil {
				sync.lock(&mx.mu)
				mx.eof = true
				sync.unlock(&mx.mu)
				return
			}
			n = r & ~int(1) // whole samples only
		}

		// The pump only measures. `silent` is the measurement mode: the byte
		// flow and therefore the clock are identical, there is simply nothing
		// to hear, which is what lets the latency be measured without filling
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
			now := time.now()
			sync.lock(&mx.mu)
			if mx.first_write == {} {
				mx.first_write = now
			} else {
				mx.max_gap_ms = math.max(mx.max_gap_ms, time.duration_milliseconds(time.diff(mx.last_write, now)))
			}
			mx.last_write = now
			mx.bytes += i64(w)
			sync.unlock(&mx.mu)
		}
		sync.lock(&mx.mu)
		mx.peak = max(pk, mx.peak * 0.75)
		mx.sum += acc
		sync.unlock(&mx.mu)
	}
}

slice_to_bytes :: proc(s: []f32) -> []u8 {
	return (transmute([^]u8)raw_data(s))[:len(s) * 4]
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
// At a rate other than 1× each second of sound is `rate` seconds of timeline.
mixer_clock :: proc(mx: ^Mixer) -> f64 {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	if !mx.live {
		return mx.base
	}
	heard := math.max(0, f64(mx.bytes) / f64(MIX_BPS) - mx.lat_est)
	return mx.base + heard * (mx.rate > 0 ? mx.rate : 1)
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

// mixer_max_gap is the longest the pump waited between two writes since the
// last start: a hole in the sound shows up here as a number, which is what
// lets the self-test say a live gain change cost none.
mixer_max_gap :: proc(mx: ^Mixer) -> f64 {
	sync.lock(&mx.mu)
	defer sync.unlock(&mx.mu)
	return mx.max_gap_ms
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
// rebuild is a kill and a restart, so it costs a short silence. Gains, mutes
// and solos no longer rebuild at all (see `mixer_set_gains`); this throttle
// is for the edits that change what plays — a clip dragged along the
// timeline would otherwise rebuild sixty times a second.
MIX_REBUILD_GAP :: 0.25

// RATES are the playback rates `<` and `>` step through. Pitch is kept
// (atempo), so 2× is a faster talker rather than a chipmunk.
RATES := [?]f64{0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4}

rate_step :: proc(rate: f64, dir: int) -> f64 {
	i := 3
	for r, k in RATES {
		if abs(r - rate) < 1e-6 {
			i = k
		}
	}
	return RATES[clamp(i + dir, 0, len(RATES) - 1)]
}

// audio_follow is the whole of the transport. It runs once a frame, before
// input, and it owns `ed.playhead` while the timeline is playing.
//
// The order matters. While the playhead is being dragged, or stepped with the
// arrow keys while stopped, the mixer is down and the *scrubber* has the
// speakers (scrub.odin): it plays the stretch of sound the playhead moved
// across, at the speed it moved. A deliberate seek (`seek_req`) or an edit
// that changed what plays restarts the pipeline, and restarting *is* the
// flush: the pipe, ffmpeg's buffer and pw-cat's queue all go with the
// processes, so there is no stale audio left to come out. An edit that only
// changed gains, mutes or solos is handed to the running pump instead.
audio_follow :: proc(ed: ^Editor, ui: ^p.Ctx) {
	total := project_duration(&ed.pr)

	if ed.drag == .Scrub || !ed.playing {
		mixer_stop(&ed.mx)
		ed.seek_req = true
		if !ed.playing {
			ed.mix_dirty = false
		}
		scrub_follow(ed, ui, total)
		return
	}
	scrub_stop(&ed.sc)

	want_restart := ed.seek_req || !mixer_live(&ed.mx)
	if ed.mix_dirty && !want_restart && mixer_set_gains(&ed.mx, &ed.pr) {
		// Heard on the next 10.6 ms chunk; nothing was torn down.
		ed.mix_dirty = false
	}
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
		if !mixer_start(&ed.mx, &ed.pr, math.max(0, at), total, ed_rate(ed)) {
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
		ed.playhead += f64(p.delta_time(ui)) * ed_rate(ed)
		if ed.playhead >= total {
			ed.playhead = total
			ed.playing = false
		}
	}
	// The scrubber measures movement from here, so stopping does not count
	// as a jump to wherever playback ended.
	ed.scrub_at = ed.playhead
	p.redraw(ui)
}

ed_rate :: proc(ed: ^Editor) -> f64 {
	return ed.rate > 0 ? ed.rate : 1
}

// audio_stat_line is what the transport shows. Everything in it is measured.
audio_stat_line :: proc(ed: ^Editor, alloc := context.temp_allocator) -> string {
	lat, locked := mixer_latency(&ed.mx)
	if !mixer_live(&ed.mx) {
		if scrub_live(&ed.sc) {
			heard, grains := scrub_stats(&ed.sc)
			return fmt.aprintf(
				"scrub audio  ·  %.0f ms heard over %d moves  ·  window %s",
				heard * 1000,
				grains,
				scrub_ready(&ed.sc) ? "rendered" : "rendering",
				allocator = alloc,
			)
		}
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
		"audio %d %s  ·  %gx  ·  live gains %d, starts %d  ·  sink %.0f ms%s  ·  start %.0f ms  ·  present %+.0f/%.0f ms",
		ed.mx.srcs,
		ed.mx.float ? "stems" : "baked",
		ed_rate(ed),
		ed.mx.live_gains,
		ed.mx.starts,
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
