package main

// Slide transitions: fade, push and wipe, in the projector.
//
// A transition is a property of the slide being *entered*, as in PowerPoint:
// moving forward onto slide 4 plays slide 4's transition. Moving back plays the
// transition of the slide being left, mirrored — a push that brought slide 4 in
// from the right takes it back out to the right — which is what makes stepping
// back and forth through a deck read as one continuous strip rather than as
// two unrelated animations.
//
// HOW IT IS DRAWN. Both slides are rendered once, through `draw_slide`, into
// two buffers the size of the projector's slide box; every frame of the
// transition is then a pure function of those two buffers and the progress,
// `compose_transition`, which mixes them pixel by pixel into a third. Nothing
// is re-rendered while the transition runs, so a slide with a full-bleed
// photograph (whose sampler is the slowest thing the renderer does) animates
// as smoothly as a slide of text, and the composition can be tested headless
// without any timing in the test at all.
//
// The progress is eased (smoothstep), and a transition lasts `transition_ms`,
// TRANSITION_MS when the slide does not say.

import "core:math"
import p "palmy:."

TRANSITION_MS :: 600

transition_secs :: proc(s: ^Slide) -> f64 {
	ms := s.transition_ms > 0 ? s.transition_ms : TRANSITION_MS
	return f64(ms) / 1000
}

// transition_ease is smoothstep: a transition that starts and lands gently.
transition_ease :: proc(t: f32) -> f32 {
	x := clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
}

@(private = "file")
mix_px :: #force_inline proc(a, b: u32, k: u32) -> u32 {
	// k in 0..256: 0 is all a, 256 is all b.
	ik := 256 - k
	r := (((a >> 16) & 0xff) * ik + ((b >> 16) & 0xff) * k) >> 8
	g := (((a >> 8) & 0xff) * ik + ((b >> 8) & 0xff) * k) >> 8
	bl := ((a & 0xff) * ik + (b & 0xff) * k) >> 8
	return 0xff000000 | r << 16 | g << 8 | bl
}

// compose_transition writes one frame of a transition from `a` (the slide
// being left) to `b` (the slide arriving) into `out`. All three are w*h XRGB
// buffers. `t` is the raw progress, 0..1; `back` mirrors the direction.
compose_transition :: proc(out, a, b: []u32, w, h: int, kind: Transition, t: f32, back: bool) {
	n := w * h
	if len(out) < n || len(a) < n || len(b) < n {
		return
	}
	e := transition_ease(t)
	switch kind {
	case .None:
		copy(out[:n], b[:n])
	case .Fade:
		k := u32(math.round(e * 256))
		for i in 0 ..< n {
			out[i] = mix_px(a[i], b[i], k)
		}
	case .Push:
		// The new slide pushes the old one off: forward, both travel left
		// and the new one enters from the right edge.
		off := int(math.round(e * f32(w)))
		for y in 0 ..< h {
			row := y * w
			for x in 0 ..< w {
				if !back {
					sx := x + off
					out[row + x] = sx < w ? a[row + sx] : b[row + sx - w]
				} else {
					sx := x - off
					out[row + x] = sx >= 0 ? a[row + sx] : b[row + sx + w]
				}
			}
		}
	case .Wipe:
		// A soft edge sweeps across, revealing the new slide behind it:
		// left to right going forward.
		soft := max(f32(w) * 0.04, 1)
		edge := e * (f32(w) + soft) - soft // from just off one side to just off the other
		for y in 0 ..< h {
			row := y * w
			for x in 0 ..< w {
				fx := f32(x) + 0.5
				if back {
					fx = f32(w) - fx
				}
				// cover: 1 where the new slide shows, 0 where the old one does
				cov := clamp((edge + soft - fx) / soft, 0, 1)
				out[row + x] = mix_px(a[row + x], b[row + x], u32(math.round(cov * 256)))
			}
		}
	}
}

// transition_kind is which transition a move from slide `from` to slide `to`
// plays, and in which direction: the arriving slide's going forward, the
// departing slide's mirrored going back.
transition_kind :: proc(d: ^Deck, from, to: int) -> (kind: Transition, back: bool, secs: f64) {
	if from == to || from < 0 || to < 0 || from >= len(d.slides) || to >= len(d.slides) {
		return .None, false, 0
	}
	if to > from {
		s := &d.slides[to]
		return s.transition, false, transition_secs(s)
	}
	s := &d.slides[from]
	return s.transition, true, transition_secs(s)
}

// transition_frame renders a whole frame headless: both slides through the
// projector's own options, then composed. The command line's
// `render --transition` and the test suite use it; the projector uses the same
// two steps with the slides cached across frames.
transition_frame :: proc(
	d: ^Deck,
	from, to: int,
	t: f32,
	w, h: int,
	fonts: ^p.Fonts,
	imgs: ^Img_Cache,
	allocator := context.allocator,
) -> []u32 {
	kind, back, _ := transition_kind(d, from, to)
	a := render_slide_buffer(d, from, w, h, fonts, imgs, context.temp_allocator)
	b := render_slide_buffer(d, to, w, h, fonts, imgs, context.temp_allocator)
	out := make([]u32, w * h, allocator)
	compose_transition(out, a, b, w, h, kind, t, back)
	return out
}

// ---------------------------------------------------------------------------
// The projector's side
// ---------------------------------------------------------------------------

// Pres_Trans is a transition in flight in the projector.
Pres_Trans :: struct {
	on:       bool,
	from, to: int,
	kind:     Transition,
	back:     bool,
	t0:       f64,
	secs:     f64,
	t:        f32, // progress this frame, set by build_present
	// The two slides, rendered once at the box size the projector draws at.
	a, b, out: []u32,
	w, h:     int,
}

// pres_begin_transition starts one, or does nothing when the move has none.
pres_begin_transition :: proc(st: ^St, from, to: int, now: f64) {
	kind, back, secs := transition_kind(&st.deck, from, to)
	pt := &st.pres_trans
	if kind == .None {
		pt.on = false
		return
	}
	pt.on = true
	pt.from = from
	pt.to = to
	pt.kind = kind
	pt.back = back
	pt.t0 = now
	pt.secs = secs
	pt.t = 0
	pt.w = 0 // forces a re-render at the next draw
}

// pres_draw_transition draws the frame in flight into `box` and reports
// whether it did; false means draw the slide as usual.
pres_draw_transition :: proc(c: ^p.Canvas, box: p.Rect, st: ^St, o: Opts) -> bool {
	pt := &st.pres_trans
	if !pt.on {
		return false
	}
	w := int(box.w)
	h := int(box.h)
	if w <= 0 || h <= 0 {
		return false
	}
	if pt.w != w || pt.h != h {
		delete(pt.a)
		delete(pt.b)
		delete(pt.out)
		pt.a = make([]u32, w * h)
		pt.b = make([]u32, w * h)
		pt.out = make([]u32, w * h)
		pt.w = w
		pt.h = h
		for which in 0 ..< 2 {
			buf := which == 0 ? pt.a : pt.b
			si := which == 0 ? pt.from : pt.to
			cc := p.canvas_from(buf, w, h, c.scale)
			oo := o
			oo.number = si + 1
			draw_slide(&cc, {0, 0, f32(w), f32(h)}, &st.deck, si, oo)
			p.canvas_destroy(&cc)
		}
	}
	compose_transition(pt.out, pt.a, pt.b, w, h, pt.kind, pt.t, pt.back)
	x0 := int(box.x)
	y0 := int(box.y)
	lo := max(0, -x0)
	hi := min(w, c.w - x0)
	if lo >= hi {
		return true
	}
	for y in 0 ..< h {
		cy := y0 + y
		if cy < 0 || cy >= c.h {
			continue
		}
		copy(c.px[cy * c.w + x0 + lo:cy * c.w + x0 + hi], pt.out[y * w + lo:y * w + hi])
	}
	return true
}
