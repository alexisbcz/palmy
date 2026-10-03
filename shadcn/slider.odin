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

slider :: proc(ui: ^p.Ctx, values: []f32, vertical := false, st := State{}) {
	ranged := len(values) > 1
	lo := ranged ? min(values[0], values[1]) : 0
	hi := ranged ? max(values[0], values[1]) : values[0]

	// Root: the element the case sizes. `data-horizontal:w-full` /
	// `data-vertical:h-full` wins over the case's own w-72 / h-48.
	p.div(ui, vertical ? "h-full" : "w-full")
	defer p.end(ui)

	// Control.
	p.div(
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
	for v, i in values {
		p.key(ui, i == 0 ? "thumb-0" : "thumb-1")
		p.div(ui, "absolute size-3 rounded-full border border-ring bg-white")
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
}
