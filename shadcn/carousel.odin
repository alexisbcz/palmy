package shadcn

// Carousel, from app/components/ui/carousel.tsx (embla).
//
// The track is `flex -ml-4` and every slide is `min-w-0 shrink-0 basis-full
// pl-4`, so slide n starts one viewport width further along and the first one
// fills the 288px window exactly. Nothing is scrolled in the capture, so only
// the first card is on screen; the rest are clipped by `overflow-hidden`.

import p "palmy:."

// card_sm is `<Card size="sm">`: a `bg-card` panel with `rounded-xl`, a 1px
// `0 0 0 1px` shadow ring instead of a border, and 12px of vertical padding.
CARD_SM :: "bg-card rounded-xl py-3 text-sm ring-1 ring-foreground/10"

carousel :: proc(ui: ^p.Ctx, slides: []string, class := "") -> int {
	idx := p.div(ui, "relative overflow-hidden")
	if class != "" {
		p.apply(ui, class)
	}
	defer p.end(ui)

	// content: flex -ml-4
	p.div(ui, "flex-row")
	p.style(ui).margin[p.LEFT] = -16
	defer p.end(ui)

	for s in slides {
		// item: min-w-0 shrink-0 basis-full pl-4
		p.div(ui, "shrink-0 pl-4 w-full")
		{
			p.div(ui, CARD_SM)
			p.div(ui, "px-3")
			p.text(ui, s, "whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
			p.end(ui)
		}
		p.end(ui)
	}
	return idx
}
