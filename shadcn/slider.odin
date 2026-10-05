package shadcn

// Slider, from app/components/ui/slider.tsx, with Base UI's
// `thumbAlignment="edge"`.
//
// Edge alignment means a thumb's *box* travels the whole track: for value v its
// left edge is v*(W-12) and its centre is 6+v*(W-12). The indicator runs
// between thumb centres, or — for a single value — from the track's own start
// to that thumb's centre.
//
// Neither of those is a single percentage of W, so each gets a transparent
// layer whose content box is already inset by the thumb size. Inside such a
// layer a percentage is exact at any width, so the component never has to know
// how wide the browser made it.
//
//   thumb layer   left 0,  right 12  -> content box (0 .. W-12)
//   range layer   left 6,  right 6   -> content box (6 .. W-6)
//
// palmy resolves an absolutely positioned child against its parent's *content*
// box (CSS uses the padding box); the layers are padding-free, so the two agree
// here.

import p "palmy:."

@(private)
THUMB :: f32(12)
@(private)
TRACK :: f32(4)

// slider draws the control and, unless it is disabled, drags.
//
// `values` is written in place — one value for a plain slider, two for a
// range — and the return says what it settled on and whether this frame moved
// it. A display-only call ignores both and renders exactly as it always did:
//
//	sc.slider(ui, {0.5})                       // a picture of a slider
//	if v, moved := sc.slider(ui, vol[:]); moved { set_volume(v) }
//
// The pointer is read at the end of the body, against the rectangle layout
// settled on last frame — the same frame of latency every `rect_of` caller in
// this toolkit has, and the reason the geometry below can stay untouched.
slider :: proc(
	ui: ^p.Ctx,
	values: []f32,
	vertical := false,
	st := State{},
) -> (value: f32, changed: bool) {
	if len(values) == 0 {
		return 0, false
	}
	ranged := len(values) > 1
	lo := ranged ? min(values[0], values[1]) : 0
	hi := ranged ? max(values[0], values[1]) : values[0]

	// Root: the element the case sizes. `data-horizontal:w-full` /
	// `data-vertical:h-full` wins over the case's own w-72 / h-48.
	p.div(ui, vertical ? "h-full" : "w-full")
	defer p.end(ui)

	// Control. This is the element the pointer and the keyboard talk to; the
	// classes on it are unchanged, and `interactive`/`focusable` are flags on
	// the node, not styling, so nothing it draws moves.
	ctrl := p.div(
		ui,
		vertical \
		? "relative flex-col h-full items-center" \
		: "relative flex-row w-full items-center",
	)
	if st.disabled {
		p.apply(ui, "opacity-50")
	}
	defer p.end(ui)

	// Track, with the indicator inside it.
	p.div(ui, "relative grow overflow-hidden rounded-full bg-muted")
	p.apply(ui, vertical ? "h-full w-1" : "h-1 w-full")
	{
		p.div(ui, "absolute")
		rl := p.style(ui)
		if vertical {
			rl.inset = {p.px(THUMB / 2), p.px(0), p.px(THUMB / 2), p.px(0)}
		} else {
			rl.inset = {p.px(0), p.px(THUMB / 2), p.px(0), p.px(THUMB / 2)}
		}
		{
			// The track clips with `overflow-hidden` + `rounded-full`;
			// palmy clips to a rectangle, so the one end of the indicator
			// that sits on a rounded track end carries the radius itself.
			p.div(ui, "absolute bg-primary")
			if !ranged {
				p.apply(ui, vertical ? "rounded-b-full" : "rounded-l-full")
			}
			s := p.style(ui)
			if vertical {
				s.inset[p.LEFT] = p.px(0)
				s.inset[p.RIGHT] = p.px(0)
				s.inset[p.TOP] = p.pct((1 - hi) * 100)
				s.inset[p.BOTTOM] = ranged ? p.pct(lo * 100) : p.px(-THUMB / 2)
			} else {
				s.inset[p.TOP] = p.px(0)
				s.inset[p.BOTTOM] = p.px(0)
				s.inset[p.LEFT] = ranged ? p.pct(lo * 100) : p.px(-THUMB / 2)
				s.inset[p.RIGHT] = p.pct((1 - hi) * 100)
			}
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	// Thumbs.
	p.div(ui, "absolute")
	tl := p.style(ui)
	if vertical {
		tl.inset = {p.px(0), p.px(0), p.px(THUMB), p.px(0)}
	} else {
		tl.inset = {p.px(0), p.px(THUMB), p.px(0), p.px(0)}
	}
	// A thumb is a grab handle as well as a picture of one. The control's own
	// box is the 4px track and nothing more -- the thumbs overhang it by four
	// pixels top and bottom -- so without this a drag could only be started on
	// a strip four pixels tall, which is the browser's geometry but not its
	// behaviour: there each thumb is a button with its own hit area.
	thumbs: [2]int = {-1, -1}
	for v, i in values {
		p.key(ui, i == 0 ? "thumb-0" : "thumb-1")
		ti := p.div(ui, "absolute size-3 rounded-full border border-ring bg-white")
		if i < len(thumbs) {
			thumbs[i] = ti
		}
		s := p.style(ui)
		if vertical {
			s.inset[p.TOP] = p.pct((1 - v) * 100)
			s.inset[p.LEFT] = p.px((TRACK - THUMB) / 2)
		} else {
			s.inset[p.LEFT] = p.pct(v * 100)
			s.inset[p.TOP] = p.px((TRACK - THUMB) / 2)
		}
		p.end(ui)
	}
	p.end(ui)

	// Last, with the control still on the stack — which is what keys the drag
	// state to this slider and nothing else — and with every rectangle this
	// needs already measured on the previous frame.
	if !st.disabled {
		changed = slider_interact(ui, values, vertical, ctrl, thumbs[:min(len(values), 2)])
	}
	return values[0], changed
}

// ---------------------------------------------------------------------------
// Dragging
//
// The geometry at the top of this file is also the inverse the pointer needs.
// A thumb's box travels the whole control, so for value v its centre sits at
// THUMB/2 + v*(L-THUMB) along the control's length L; solving that for v is
// the whole of the hit arithmetic, and it is exact at any width because it is
// the expression the layout already used.
//
// Nothing below creates a node or touches a style. `interactive` and
// `focusable` are flags on the control, and the control carries no `hover:`,
// `active:` or `focus:` utility, so a slider that is only drawn — the parity
// cases, a read-out in a status bar — renders identically whether this runs
// or not.
// ---------------------------------------------------------------------------

// SLIDER_STEP is one arrow key; Page Up and Page Down move ten times as far.
SLIDER_STEP :: f32(0.01)
SLIDER_PAGE :: f32(0.1)

@(private)
Slider_Drag :: struct {
	// Which thumb the pointer took, held for the whole press so that two
	// thumbs cannot swap places under it, and -1 between drags.
	grab: int,
	// Which thumb the arrow keys move, which outlives the drag.
	key:  int,
}

@(private)
slider_interact :: proc(
	ui: ^p.Ctx,
	values: []f32,
	vertical: bool,
	ctrl: int,
	thumbs: []int,
) -> (changed: bool) {
	p.focusable(ui, ctrl)
	_ = p.clickable(ui, ctrl)
	for t in thumbs {
		p.focusable(ui, t)
		_ = p.clickable(ui, t)
	}

	d := p.state(ui, "sc-slider", Slider_Drag{grab = -1, key = 0})
	d.key = clamp(d.key, 0, len(values) - 1)

	r := p.rect_of(ui, p.node_id(ui, ctrl))
	span := (vertical ? r.h : r.w) - THUMB

	// A press that landed on a thumb owns that thumb outright; one on the
	// bare track takes whichever thumb is nearest.
	held := -1
	for t, i in thumbs {
		if p.is_active(ui, t) {
			held = i
		}
	}

	if (held >= 0 || p.is_active(ui, ctrl)) && span > 0 {
		m := p.mouse_pos(ui)
		t := vertical ? 1 - (m.y - r.y - THUMB / 2) / span : (m.x - r.x - THUMB / 2) / span
		t = clamp(t, 0, 1)
		if d.grab < 0 || d.grab >= len(values) {
			d.grab = held >= 0 ? held : slider_nearest(values, t)
			d.key = d.grab
		}
		if values[d.grab] != t {
			values[d.grab] = t
			changed = true
		}
	} else {
		d.grab = -1
	}

	// The keyboard answers to the control or to either thumb, since any of
	// the three can be the thing that took focus.
	has_key := p.focused(ui, ctrl)
	for t, i in thumbs {
		if p.focused(ui, t) {
			has_key = true
			d.key = i
		}
	}

	if has_key {
		i := d.key
		v := values[i]
		// Left and Down decrease on both orientations, which is what a
		// browser's range input does.
		if p.key_pressed(ui, vertical ? p.KEY_DOWN : p.KEY_LEFT) {
			v -= SLIDER_STEP
		}
		if p.key_pressed(ui, vertical ? p.KEY_UP : p.KEY_RIGHT) {
			v += SLIDER_STEP
		}
		if p.key_pressed(ui, p.KEY_PAGE_DOWN) {
			v -= SLIDER_PAGE
		}
		if p.key_pressed(ui, p.KEY_PAGE_UP) {
			v += SLIDER_PAGE
		}
		if p.key_pressed(ui, p.KEY_HOME) {
			v = 0
		}
		if p.key_pressed(ui, p.KEY_END) {
			v = 1
		}
		v = clamp(v, 0, 1)
		if v != values[i] {
			values[i] = v
			changed = true
		}
	}
	return
}

@(private)
slider_nearest :: proc(values: []f32, t: f32) -> int {
	best, best_d := 0, max(f32)
	for v, i in values {
		dist := abs(v - t)
		if dist < best_d {
			best, best_d = i, dist
		}
	}
	return best
}
