package main

// The preview pipeline.
//
// Measured, not guessed
// ---------------------
// Seeking and grabbing one frame costs about 128 ms on this machine
// (`ffmpeg -ss T -i f.mp4 -frames:v 1`, averaged over five seeks). That is
// 7.8 fps, so decoding per-frame on demand cannot play anything back and makes
// even scrubbing feel like treacle.
//
// A *streamed* decode is two orders of magnitude cheaper: a 4-second window at
// 480x270 and 15 fps — 60 frames — comes out of
// `ffmpeg -ss T -t 4 -i f.mp4 -vf fps=15,scale=480:-2 -f rawvideo -pix_fmt rgba -`
// in 137 ms, i.e. ~440 decoded frames per second. Decoding a whole 8-second
// clip at that size takes 190 ms.
//
// So the preview is a cache, not a decoder. The UI thread works out which
// source frames the next few seconds of timeline need and hands that plan to a
// worker; the worker streams them in and pushes finished frames back; the UI
// draws whatever is in the cache and advances the playhead from its own clock.
// Playback is then limited by palmy's frame loop (60 Hz) rather than by
// ffmpeg, and the cache grid (15 fps) is what actually shows.
//
// Locking (one mutex, `Preview.mu`)
// ---------------------------------
// Three fields are shared and nothing else is: `pending` (a plan the UI wants
// run), `done` (finished frames waiting to be collected) and `gen`/`busy`
// (bookkeeping). The worker decodes and allocates images with the lock
// released, takes the lock only to move a finished frame onto `done`, and
// never touches the cache. The cache belongs to the UI thread alone, so
// eviction — the only place an image is destroyed — happens on one thread with
// no lock involved at all. No procedure in this file locks while calling
// another that locks.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import p "palmy:."

PREVIEW_FPS :: 15.0
PREVIEW_WINDOW :: 3.0 // seconds decoded ahead of the plan start
CACHE_N :: 160

Preview_Quality :: enum u8 {
	Draft, // 480 wide: the measured numbers above
	Fine,  // 854 wide, roughly 2.5x the pixels
}

preview_width :: proc(q: Preview_Quality) -> int {
	return q == .Draft ? 480 : 854
}

// A piece of work: decode `dur` seconds of `path` starting at source time
// `src_at`, which lands on the timeline at `tl_at`.
Decode_Seg :: struct {
	clip_id: int,
	path:    string, // owned by the plan
	src_at:  f64,
	tl_at:   f64,
	dur:     f64,
	w, h:    int,
}

Plan :: struct {
	gen:  int,
	segs: [dynamic]Decode_Seg,
}

plan_destroy :: proc(pl: ^Plan) {
	for s in pl.segs {
		delete(s.path)
	}
	delete(pl.segs)
	pl.segs = nil
}

Frame :: struct {
	clip_id: int,
	t:       f64, // timeline seconds
	gen:     int,
	img:     p.Image,
}

Preview :: struct {
	mu:        sync.Mutex,
	sem:       sync.Sema,
	quit:      bool,
	worker:    ^thread.Thread,

	// Shared, guarded by mu.
	pending:   Plan,
	has_plan:  bool,
	done:      [dynamic]Frame,
	gen:       int,
	busy:      bool,
	decoded:   int, // total frames pushed, for the stats line
	decode_ms: f64,

	// UI thread only, no lock.
	cache:     [CACHE_N]Frame,
	used:      [CACHE_N]bool,
	plan_from: f64,
	plan_gen:  int,
	planned:   bool,
	quality:   Preview_Quality,
	hits:      int,
	misses:    int,
}

preview_start :: proc(pv: ^Preview) {
	pv.quality = .Draft
	pv.worker = thread.create(preview_main)
	pv.worker.data = rawptr(pv)
	thread.start(pv.worker)
}

preview_stop :: proc(pv: ^Preview) {
	sync.lock(&pv.mu)
	pv.quit = true
	sync.unlock(&pv.mu)
	sync.sema_post(&pv.sem)
	if pv.worker != nil {
		thread.join(pv.worker)
		thread.destroy(pv.worker)
		pv.worker = nil
	}
	// Drain anything the worker left behind, then the cache.
	for f in pv.done {
		img := f.img
		p.image_destroy(&img)
	}
	delete(pv.done)
	if pv.has_plan {
		plan_destroy(&pv.pending)
	}
	for i in 0 ..< CACHE_N {
		if pv.used[i] {
			p.image_destroy(&pv.cache[i].img)
			pv.used[i] = false
		}
	}
}

// preview_submit hands a plan to the worker, replacing any plan not yet
// started. The caller gives up ownership of `pl`.
preview_submit :: proc(pv: ^Preview, pl: Plan) {
	old: Plan
	had := false
	sync.lock(&pv.mu)
	if pv.has_plan {
		old = pv.pending
		had = true
	}
	pv.pending = pl
	pv.has_plan = true
	pv.gen = pl.gen
	sync.unlock(&pv.mu)
	// Freeing happens outside the lock.
	if had {
		plan_destroy(&old)
	}
	sync.sema_post(&pv.sem)
}

// preview_collect moves finished frames into the UI's cache. Frames from a
// superseded generation are thrown away here, on the UI thread, so the worker
// never has to know what the cache contains.
preview_collect :: proc(pv: ^Preview, playhead: f64) -> int {
	batch: [dynamic]Frame
	batch.allocator = context.temp_allocator
	gen := 0
	sync.lock(&pv.mu)
	gen = pv.gen
	for f in pv.done {
		append(&batch, f)
	}
	clear(&pv.done)
	sync.unlock(&pv.mu)

	n := 0
	for f in batch {
		if f.gen != gen {
			img := f.img
			p.image_destroy(&img)
			continue
		}
		cache_insert(pv, f, playhead)
		n += 1
	}
	return n
}

@(private)
cache_insert :: proc(pv: ^Preview, f: Frame, playhead: f64) {
	// Replace an identical slot if one somehow exists.
	for i in 0 ..< CACHE_N {
		if pv.used[i] && pv.cache[i].clip_id == f.clip_id && math.abs(pv.cache[i].t - f.t) < 1e-6 {
			p.image_destroy(&pv.cache[i].img)
			pv.cache[i] = f
			return
		}
	}
	for i in 0 ..< CACHE_N {
		if !pv.used[i] {
			pv.cache[i] = f
			pv.used[i] = true
			return
		}
	}
	// Full: evict whatever is furthest from the playhead.
	worst := 0
	worstd := f64(-1)
	for i in 0 ..< CACHE_N {
		d := math.abs(pv.cache[i].t - playhead)
		if d > worstd {
			worstd = d
			worst = i
		}
	}
	if worstd <= math.abs(f.t - playhead) {
		// The new frame is less useful than everything we hold; drop it.
		img := f.img
		p.image_destroy(&img)
		return
	}
	p.image_destroy(&pv.cache[worst].img)
	pv.cache[worst] = f
}

// cache_lookup finds the best cached frame for a clip at a time. `tol` is how
// far off the grid a frame may be and still count.
cache_lookup :: proc(pv: ^Preview, clip_id: int, t: f64, tol: f64) -> (img: p.Image, ok: bool) {
	best := -1
	bestd := tol
	for i in 0 ..< CACHE_N {
		if !pv.used[i] || pv.cache[i].clip_id != clip_id {
			continue
		}
		d := math.abs(pv.cache[i].t - t)
		if d < bestd {
			bestd = d
			best = i
		}
	}
	if best < 0 {
		pv.misses += 1
		return {}, false
	}
	pv.hits += 1
	return pv.cache[best].img, true
}

// cache_drop_all is what a timeline edit calls: every cached frame may now be
// at the wrong timeline position, so none of them can be trusted.
cache_drop_all :: proc(pv: ^Preview) {
	for i in 0 ..< CACHE_N {
		if pv.used[i] {
			p.image_destroy(&pv.cache[i].img)
			pv.used[i] = false
		}
	}
	pv.planned = false
}

preview_stats :: proc(pv: ^Preview) -> (decoded: int, ms: f64, busy: bool) {
	sync.lock(&pv.mu)
	defer sync.unlock(&pv.mu)
	return pv.decoded, pv.decode_ms, pv.busy
}

// ---------------------------------------------------------------------------
// Planning, on the UI thread
// ---------------------------------------------------------------------------

// build_plan decides what to decode for the window starting at `from`. Every
// video clip that overlaps the window gets a segment, not just the visible
// one, because a cross-dissolve needs both sides of the join to composite.
build_plan :: proc(pr: ^Project, pv: ^Preview, from: f64, gen: int) -> Plan {
	pl := Plan {
		gen = gen,
	}
	w0 := math.max(0, from)
	w1 := w0 + PREVIEW_WINDOW
	pw := preview_width(pv.quality)
	ph := int(f64(pw) * f64(pr.out_h) / f64(math.max(1, pr.out_w)))
	ph -= ph % 2

	for &t, ti in pr.tracks {
		if t.kind != .Video || !track_enabled(pr, ti) {
			continue
		}
		for c in t.clips {
			if c.media < 0 || c.media >= len(pr.media) {
				continue // titles have no frames to decode
			}
			a := math.max(c.start, w0)
			b := math.min(clip_end(c), w1)
			if b - a < 1.0 / PREVIEW_FPS {
				continue
			}
			append(
				&pl.segs,
				Decode_Seg {
					clip_id = c.id,
					path = strings.clone(pr.media[c.media].path),
					src_at = c.src_in + (a - c.start),
					tl_at = a,
					dur = b - a,
					w = pw,
					h = ph,
				},
			)
		}
	}
	return pl
}

// preview_follow keeps the plan ahead of the playhead. It re-plans only when
// the playhead has left the part of the window that is already covered, so a
// playing timeline re-plans about once every two seconds rather than every
// frame.
preview_follow :: proc(pr: ^Project, pv: ^Preview, playhead: f64, force: bool) {
	want_from := math.max(0, playhead - 0.3)
	need := force || !pv.planned
	if !need {
		// Still inside the comfortable part of the decoded window?
		if playhead < pv.plan_from || playhead > pv.plan_from + PREVIEW_WINDOW - 1.0 {
			need = true
		}
	}
	if !need {
		return
	}
	pv.plan_gen += 1
	pv.plan_from = want_from
	pv.planned = true
	preview_submit(pv, build_plan(pr, pv, want_from, pv.plan_gen))
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

@(private)
preview_main :: proc(th: ^thread.Thread) {
	pv := (^Preview)(th.data)
	for {
		free_all(context.temp_allocator)

		sync.lock(&pv.mu)
		if pv.quit {
			sync.unlock(&pv.mu)
			return
		}
		if !pv.has_plan {
			pv.busy = false
			sync.unlock(&pv.mu)
			sync.sema_wait(&pv.sem)
			continue
		}
		pl := pv.pending
		pv.pending = {}
		pv.has_plan = false
		pv.busy = true
		sync.unlock(&pv.mu)

		// Decoding happens with no lock held.
		for seg in pl.segs {
			if !decode_segment(pv, seg, pl.gen) {
				break // superseded or asked to quit
			}
		}
		plan_destroy(&pl)
	}
}

// superseded reports whether a newer plan has arrived, which is the only
// reason to abandon a decode half-way.
@(private)
superseded :: proc(pv: ^Preview, gen: int) -> bool {
	sync.lock(&pv.mu)
	defer sync.unlock(&pv.mu)
	return pv.quit || pv.has_plan || pv.gen != gen
}

@(private)
push_frame :: proc(pv: ^Preview, f: Frame) {
	sync.lock(&pv.mu)
	append(&pv.done, f)
	pv.decoded += 1
	sync.unlock(&pv.mu)
}

// decode_segment streams raw RGBA out of ffmpeg and turns each frame into a
// palmy Image. Returns false when it stopped early.
@(private)
decode_segment :: proc(pv: ^Preview, seg: Decode_Seg, gen: int) -> bool {
	if seg.w <= 0 || seg.h <= 0 {
		return true
	}
	rd, wr, perr := os.pipe()
	if perr != nil {
		return true
	}
	// -ss before -i is the fast (keyframe-accurate then decode-to-target)
	// seek; ffmpeg then decodes forward, which is what makes a window cheap.
	argv := []string {
		"ffmpeg",
		"-v",
		"error",
		"-ss",
		fmt.tprintf("%.4f", seg.src_at),
		"-t",
		fmt.tprintf("%.4f", seg.dur + 1.0 / PREVIEW_FPS),
		"-i",
		seg.path,
		"-an",
		"-sn",
		"-vf",
		fmt.tprintf("fps=%g,scale=%d:%d", PREVIEW_FPS, seg.w, seg.h),
		"-f",
		"rawvideo",
		"-pix_fmt",
		"rgba",
		"-",
	}
	proc_, serr := os.process_start({command = argv, stdout = wr, stderr = nil, stdin = nil})
	os.close(wr)
	if serr != nil {
		os.close(rd)
		return true
	}

	t0 := time.now()
	nbytes := seg.w * seg.h * 4
	buf := make([]u8, nbytes, context.temp_allocator)
	idx := 0
	alive := true
	for {
		if !read_full(rd, buf) {
			break
		}
		if superseded(pv, gen) {
			alive = false
			break
		}
		img := p.Image {
			px              = make([]u32, seg.w * seg.h),
			w               = seg.w,
			h               = seg.h,
			source_channels = 4,
		}
		for i in 0 ..< seg.w * seg.h {
			r := u32(buf[i * 4 + 0])
			g := u32(buf[i * 4 + 1])
			b := u32(buf[i * 4 + 2])
			img.px[i] = 0xff00_0000 | (r << 16) | (g << 8) | b
		}
		push_frame(
			pv,
			Frame {
				clip_id = seg.clip_id,
				t = seg.tl_at + f64(idx) / PREVIEW_FPS,
				gen = gen,
				img = img,
			},
		)
		idx += 1
	}
	os.close(rd)
	if !alive {
		_ = os.process_kill(proc_)
	}
	_, _ = os.process_wait(proc_)

	ms := time.duration_milliseconds(time.since(t0))
	sync.lock(&pv.mu)
	pv.decode_ms += ms
	sync.unlock(&pv.mu)
	return alive
}

// read_full fills the buffer or reports the stream ended. A pipe read returns
// whatever is available, which for a 518 KB frame is almost never the lot.
@(private)
read_full :: proc(f: ^os.File, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n, err := os.read(f, buf[got:])
		if n <= 0 || err != nil {
			return false
		}
		got += n
	}
	return true
}
