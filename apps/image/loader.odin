package main

// Decoding off the critical path.
//
// A 4K PNG costs a couple of hundred milliseconds through stb_image, which at
// 60 Hz is a dozen dropped frames every time you press Right. So nothing is
// decoded on the UI thread: one worker thread owns stb_image, the UI asks it
// for what it wants to show, and draws a skeleton until the answer arrives.
//
// Ownership is the whole design. The worker fills `full` and the UI *moves* the
// image out of the slot under the lock; after that the UI owns those pixels and
// the worker will never touch them. Anything still sitting in the slot was
// never handed out, so the worker is free to destroy it. Thumbnails are
// different: once a thumb is Ready it is immutable until shutdown, so the UI
// can read it with only the state flag locked.

import "core:sync"
import "core:thread"
import "core:time"
import p "palmy:."

// Longest edge of a thumbnail. 240 keeps the strip crisp on a HiDPI output and
// a folder of 500 images inside about 100 MB.
THUMB_MAX :: 240

Slot :: enum u8 {
	Empty,
	Queued,
	Ready,
	Failed,
}

Thumb :: struct {
	state: Slot,
	img:   p.Image,
}

Loader :: struct {
	mu:        sync.Mutex,
	sem:       sync.Sema,
	quit:      bool,
	worker:    ^thread.Thread,

	// Immutable after start: the worker only ever reads these paths.
	paths:     []string,
	thumbs:    []Thumb,

	// Full-size handoff.
	want:      int, // index the UI is asking for, -1 for none
	have:      int, // index sitting in `full`, -1 for none
	full:      p.Image,
	full_ok:   bool,
	full_ms:   f64,

	// Where the UI is looking, so the nearest thumbnails are decoded first.
	hint:      int,
	working:   bool,

	// Instrumentation, reported in the properties panel.
	thumbs_done: int,
	thumb_ms:    f64,
	full_decodes: int,
}

loader_start :: proc(l: ^Loader, shots: []Shot) {
	l.paths = make([]string, len(shots))
	for s, i in shots {
		l.paths[i] = s.path
	}
	l.thumbs = make([]Thumb, len(shots))
	l.want = -1
	l.have = -1
	l.worker = thread.create(loader_main)
	l.worker.data = rawptr(l)
	thread.start(l.worker)
}

loader_stop :: proc(l: ^Loader) {
	sync.lock(&l.mu)
	l.quit = true
	sync.unlock(&l.mu)
	sync.sema_post(&l.sem)
	if l.worker != nil {
		thread.join(l.worker)
		thread.destroy(l.worker)
		l.worker = nil
	}
}

// loader_want asks for a full-size decode. Idempotent: asking for what is
// already in the slot costs nothing.
loader_want :: proc(l: ^Loader, idx: int) {
	sync.lock(&l.mu)
	if l.have != idx && l.want != idx {
		l.want = idx
	}
	sync.unlock(&l.mu)
	sync.sema_post(&l.sem)
}

// loader_take moves a finished decode out of the slot. After this the caller
// owns the pixels.
loader_take :: proc(l: ^Loader, idx: int) -> (img: p.Image, ok: bool, failed: bool, ms: f64) {
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)
	if l.have != idx {
		return {}, false, false, 0
	}
	img = l.full
	ms = l.full_ms
	failed = !l.full_ok
	l.full = {}
	l.have = -1
	return img, true, failed, ms
}

loader_set_hint :: proc(l: ^Loader, idx: int) {
	sync.lock(&l.mu)
	changed := l.hint != idx
	l.hint = idx
	sync.unlock(&l.mu)
	if changed {
		sync.sema_post(&l.sem)
	}
}

// loader_thumb reads a thumbnail. A Ready thumb's pixels are immutable, so the
// returned image stays valid for as long as the loader lives.
loader_thumb :: proc(l: ^Loader, idx: int) -> (img: p.Image, state: Slot) {
	if idx < 0 || idx >= len(l.thumbs) {
		return {}, .Failed
	}
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)
	t := l.thumbs[idx]
	return t.img, t.state
}

// loader_busy is what keeps the frame loop awake while anything is in flight.
loader_busy :: proc(l: ^Loader) -> bool {
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)
	return l.working || l.want >= 0 || l.have >= 0
}

loader_stats :: proc(l: ^Loader) -> (done, total: int, avg_ms: f64) {
	sync.lock(&l.mu)
	defer sync.unlock(&l.mu)
	avg := l.thumbs_done > 0 ? l.thumb_ms / f64(l.thumbs_done) : 0
	return l.thumbs_done, len(l.thumbs), avg
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

@(private)
loader_main :: proc(t: ^thread.Thread) {
	l := (^Loader)(t.data)
	for {
		free_all(context.temp_allocator)

		sync.lock(&l.mu)
		if l.quit {
			sync.unlock(&l.mu)
			return
		}

		// A full-size decode always wins: it is the thing the user is looking
		// at, and a thumbnail that arrives a frame later costs nobody anything.
		if want := l.want; want >= 0 {
			l.want = -1
			l.working = true
			sync.unlock(&l.mu)
			decode_full(l, want)
			continue
		}

		ti := pick_thumb(l)
		if ti < 0 {
			l.working = false
			sync.unlock(&l.mu)
			sync.sema_wait(&l.sem)
			continue
		}
		l.thumbs[ti].state = .Queued
		l.working = true
		sync.unlock(&l.mu)
		decode_thumb(l, ti)
	}
}

@(private)
decode_full :: proc(l: ^Loader, idx: int) {
	if idx < 0 || idx >= len(l.paths) {
		return
	}
	t0 := time.now()
	img, ok := p.load_image(l.paths[idx])
	ms := time.duration_milliseconds(time.since(t0))

	sync.lock(&l.mu)
	// Anything still in the slot was never handed to the UI, so it is ours.
	if l.have >= 0 {
		old := l.full
		l.full = {}
		l.have = -1
		sync.unlock(&l.mu)
		p.image_destroy(&old)
		sync.lock(&l.mu)
	}
	l.full = img
	l.full_ok = ok
	l.full_ms = ms
	l.have = idx
	l.full_decodes += 1
	sync.unlock(&l.mu)
}

// pick_thumb takes the undecoded thumbnail nearest to where the UI is looking.
// Called with the lock held.
@(private)
pick_thumb :: proc(l: ^Loader) -> int {
	n := len(l.thumbs)
	if n == 0 {
		return -1
	}
	h := clamp(l.hint, 0, n - 1)
	for d in 0 ..< n {
		if i := h + d; i < n && l.thumbs[i].state == .Empty {
			return i
		}
		if i := h - d; i >= 0 && l.thumbs[i].state == .Empty {
			return i
		}
	}
	return -1
}

@(private)
decode_thumb :: proc(l: ^Loader, idx: int) {
	t0 := time.now()
	src, ok := p.load_image(l.paths[idx], context.temp_allocator)
	small: p.Image
	if ok {
		small = downscale(src, THUMB_MAX)
	}
	ms := time.duration_milliseconds(time.since(t0))

	sync.lock(&l.mu)
	l.thumbs[idx].img = small
	l.thumbs[idx].state = ok ? .Ready : .Failed
	l.thumbs_done += 1
	l.thumb_ms += ms
	sync.unlock(&l.mu)
}

// downscale is a box filter, which is the right answer for a thumbnail: it
// averages every source pixel that lands in the target cell, so fine detail
// turns into tone instead of aliasing into noise.
@(private)
downscale :: proc(src: p.Image, longest: int) -> p.Image {
	if src.w <= 0 || src.h <= 0 {
		return {}
	}
	dw, dh := src.w, src.h
	if max(dw, dh) > longest {
		if dw >= dh {
			dh = max(1, src.h * longest / src.w)
			dw = longest
		} else {
			dw = max(1, src.w * longest / src.h)
			dh = longest
		}
	}
	out := p.Image {
		px              = make([]u32, dw * dh),
		w               = dw,
		h               = dh,
		source_channels = src.source_channels,
	}
	for y in 0 ..< dh {
		y0 := y * src.h / dh
		y1 := max(y0 + 1, (y + 1) * src.h / dh)
		for x in 0 ..< dw {
			x0 := x * src.w / dw
			x1 := max(x0 + 1, (x + 1) * src.w / dw)
			ar, ag, ab, aa: u32
			n: u32
			for sy in y0 ..< y1 {
				row := src.px[sy * src.w:]
				for sx in x0 ..< x1 {
					v := row[sx]
					a := (v >> 24) & 0xff
					// Weight colour by alpha so a transparent border does not
					// drag the edge pixels toward black.
					ar += ((v >> 16) & 0xff) * a
					ag += ((v >> 8) & 0xff) * a
					ab += (v & 0xff) * a
					aa += a
					n += 1
				}
			}
			if n == 0 || aa == 0 {
				out.px[y * dw + x] = 0
				continue
			}
			out.px[y * dw + x] =
				((aa / n) << 24) | ((ar / aa) << 16) | ((ag / aa) << 8) | (ab / aa)
		}
	}
	return out
}

// rotate90 turns an image a quarter turn clockwise. palmy's image element has
// no transform, so a viewer that rotates has to produce the rotated pixels.
rotate90 :: proc(src: p.Image) -> p.Image {
	if src.w <= 0 || src.h <= 0 {
		return {}
	}
	out := p.Image {
		px              = make([]u32, src.w * src.h),
		w               = src.h,
		h               = src.w,
		source_channels = src.source_channels,
	}
	for y in 0 ..< src.h {
		row := src.px[y * src.w:]
		// (x, y) -> (h-1-y, x)
		dx := src.h - 1 - y
		for x in 0 ..< src.w {
			out.px[x * out.w + dx] = row[x]
		}
	}
	return out
}

// rotated builds the image for a quarter-turn count, 0 returning the original
// untouched so the common case allocates nothing.
rotated :: proc(src: p.Image, quarters: int) -> (out: p.Image, owned: bool) {
	q := ((quarters % 4) + 4) % 4
	if q == 0 || src.w <= 0 {
		return src, false
	}
	cur := src
	mine := false
	for _ in 0 ..< q {
		nxt := rotate90(cur)
		if mine {
			p.image_destroy(&cur)
		}
		cur = nxt
		mine = true
	}
	return cur, mine
}
