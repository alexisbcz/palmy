package shadcn

// Bubble, from app/components/ui/bubble.tsx.
//
// The TSX colours the content through `*:data-[slot=bubble-content]:bg-*`
// selectors on the wrapper; here the variant is simply handed to the content.

import p "palmy:."

Bubble_Variant :: enum {
	Default,
	Secondary,
	Muted,
	Outline,
	Destructive,
	Ghost,
}

BUBBLE_BASE :: "relative flex-col gap-1 min-w-0"

// bubble_open opens the wrapper. `align_end` is the `data-align=end` case,
// which pushes the bubble to the far edge of its column.
bubble_open :: proc(ui: ^p.Ctx, align_end := false, class := "") -> int {
	idx := p.div(ui, BUBBLE_BASE)
	p.apply(ui, align_end ? "self-end" : "self-start")
	if class != "" {
		p.apply(ui, class)
	}
	return idx
}

bubble_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

BUBBLE_CONTENT_BASE ::
	"max-w-full min-w-0 overflow-hidden rounded-xl border border-transparent " +
	"px-3 py-2 text-sm leading-[22.75]"

bubble_content_class :: proc(v: Bubble_Variant) -> string {
	switch v {
	case .Default:
		return "bg-primary text-primary-foreground"
	case .Secondary:
		return "bg-secondary text-secondary-foreground"
	case .Muted:
		return "bg-muted"
	case .Outline:
		return "border-border bg-background"
	case .Destructive:
		return "bg-destructive/10 text-destructive"
	case .Ghost:
		return "rounded-none p-0"
	}
	return ""
}

// bubble_content is the coloured box: `w-fit`, so it is as wide as its text.
bubble_content :: proc(
	ui: ^p.Ctx,
	body: string,
	v := Bubble_Variant.Default,
	align_end := false,
) -> int {
	idx := p.div(ui, BUBBLE_CONTENT_BASE)
	p.apply(ui, bubble_content_class(v))
	p.apply(ui, align_end ? "self-end" : "self-start")
	defer p.end(ui)

	// Every bubble in the registry is one line; `wrap-break-word` would only
	// matter past the 80% cap, and palmy's wrap hint is per-frame, so pinning
	// the run keeps the measured width stable.
	p.text(ui, body, "whitespace-nowrap")
	p.style(ui).shrink = 0
	return idx
}

// bubble_reactions is `absolute bottom-0 right-3 translate-y-3/4`: a pill that
// hangs three quarters of its own height below the bubble it belongs to.
bubble_reactions :: proc(ui: ^p.Ctx, label: string) {
	p.div(
		ui,
		"absolute flex-row items-center justify-center gap-1 rounded-full bg-muted " +
		"px-1.5 py-0.5 text-sm ring-3 ring-card z-10",
	)
	st := p.style(ui)
	st.position = .Absolute
	// bottom-0 with translate-y-3/4 on a 24px tall pill: the top sits 18px
	// below the bubble's bottom edge, minus its own height.
	st.inset[p.BOTTOM] = p.px(-18)
	st.inset[p.RIGHT] = p.px(12)
	st.h = p.px(24)
	defer p.end(ui)

	p.text(ui, label, "")
	p.style(ui).shrink = 0
}
