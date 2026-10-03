package shadcn

// Scroll area, from app/components/ui/scroll-area.tsx (Base UI ScrollArea).
//
// The scrollbar is `p-px` with a transparent left border, so the only thing it
// actually paints is the thumb: `flex-1 rounded-full bg-border`, as tall as the
// viewport's share of the content.

import p "palmy:."

scroll_area_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.div(ui, "relative rounded-lg border border-border")
	if class != "" {
		p.apply(ui, class)
	}
	// viewport: size-full rounded-[inherit]
	p.div(ui, "w-full h-full rounded-lg overflow-hidden")
	return idx
}

// scroll_area_end closes the viewport and adds the scrollbar. `thumb_h` is the
// thumb's height, which Base UI sets from viewport/content.
scroll_area_end :: proc(ui: ^p.Ctx, thumb_h: f32) {
	p.end(ui) // viewport

	// scrollbar: data-vertical:h-full data-vertical:w-2.5, p-px,
	// border-l border-l-transparent.
	p.div(ui, "flex-col w-2.5 p-px pl-0.5")
	st := p.style(ui)
	st.position = .Absolute
	st.inset[p.RIGHT] = p.px(0)
	st.inset[p.TOP] = p.px(0)
	st.inset[p.BOTTOM] = p.px(0)
	{
		p.div(ui, "w-full rounded-full bg-border")
		p.style(ui).h = p.px(thumb_h)
		p.end(ui)
	}
	p.end(ui)

	p.end(ui) // root
}
