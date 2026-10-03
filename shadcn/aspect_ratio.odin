package shadcn

// AspectRatio, from app/components/ui/aspect-ratio.tsx.
//
// `aspect-(--ratio)` has no palmy equivalent, so the height is derived from the
// width the caller gives, which is what the browser's aspect-ratio does once
// the width is definite.

import p "palmy:."

aspect_ratio :: proc(ui: ^p.Ctx, width, ratio: f32, class := "") {
	p.div(ui, "relative")
	p.apply(ui, class)
	st := p.style(ui)
	st.w = p.px(width)
	st.h = p.px(width / ratio)
	p.end(ui)
}
