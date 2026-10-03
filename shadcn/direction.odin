package shadcn

// Direction provider, from app/components/ui/direction.tsx, wrapping a Slider.
//
// The provider itself paints nothing: the only observable effect of `rtl` is
// where the track fill and the thumb end up. Base UI uses `thumbAlignment
// "edge"`, so at 30% the fill reaches 367.19px and the thumb's near edge — not
// its centre — sits at the end of the fill.

import p "palmy:."

// slider_rtl draws the captured rtl slider: `w` is the control width, `fill`
// the indicator width and `thumb_x` the thumb's left edge.
slider_rtl :: proc(ui: ^p.Ctx, w, fill, thumb_x: f32) -> int {
	idx := p.div(ui, "relative w-full")
	p.style(ui).h = p.px(4)
	defer p.end(ui)

	// control
	p.div(ui, "relative flex-row w-full h-full items-center")
	defer p.end(ui)

	// track: grow overflow-hidden rounded-full bg-muted, h-1
	p.div(ui, "relative w-full h-1 overflow-hidden rounded-full bg-muted")
	{
		p.div(ui, "h-full bg-primary")
		p.style(ui).w = p.px(fill)
		p.end(ui)
	}
	p.end(ui)

	// thumb: size-3 rounded-full border border-ring bg-background, centred on
	// the track, so it overhangs the 4px control by 4px top and bottom.
	p.div(ui, "size-3 rounded-full border border-ring bg-background")
	st := p.style(ui)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(thumb_x)
	st.inset[p.TOP] = p.px(-4)
	p.end(ui)

	return idx
}
