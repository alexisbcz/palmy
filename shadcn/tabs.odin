package shadcn

// Tabs, translated from app/components/ui/tabs.tsx.
//
// The TSX sizes the trigger with `h-[calc(100%-1px)]` and `flex-1`. In the
// horizontal case the list is `h-8` with `p-[3px]`, so the trigger resolves to
// 25px; in the vertical case the list is `h-fit`, the percentage is
// indefinite, and the trigger falls back to its own content height (26px).
//
// `flex-1` is deliberately NOT translated: the list is `w-fit`, so CSS sizes
// it from the triggers' max-content contributions and the automatic minimum
// size then stops `flex-basis: 0` from redistributing anything. palmy has no
// automatic minimum size, so growing here would make both tabs equally wide.

import p "palmy:."

Tabs_Variant :: enum {
	Default,
	Line,
}

// tabs_open opens the Tabs root. `data-horizontal:flex-col` means the
// horizontal orientation stacks list over panel.
tabs_open :: proc(ui: ^p.Ctx, vertical := false) {
	p.div(ui, vertical ? "flex-row gap-2" : "flex-col gap-2")
}

tabs_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// tabs_list_open opens TabsList. `self-start` stands in for `w-fit`: palmy
// stretches an auto cross size, CSS's fit-content does not.
tabs_list_open :: proc(ui: ^p.Ctx, v := Tabs_Variant.Default, vertical := false) {
	p.div(ui, "items-center justify-center rounded-lg p-[3] text-muted-foreground self-start")
	// A vertical list stretches its triggers; `w-full` in the TSX would make
	// palmy resolve a percentage against a width that is itself content-sized.
	p.apply(ui, vertical ? "flex-col items-stretch" : "flex-row h-8")
	switch v {
	case .Default:
		p.apply(ui, "bg-muted")
	case .Line:
		p.apply(ui, "gap-1 rounded-none")
	}
}

tabs_list_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

TABS_TRIGGER_BASE ::
	"relative flex-row items-center justify-center gap-1.5 rounded-md " +
	"border border-transparent px-1.5 py-0.5 text-sm font-medium whitespace-nowrap"

tabs_trigger :: proc(
	ui: ^p.Ctx,
	label: string,
	active: bool,
	v := Tabs_Variant.Default,
	vertical := false,
) {
	p.div(ui, TABS_TRIGGER_BASE)
	p.apply(ui, vertical ? "justify-start" : "h-[25]")
	if active {
		p.apply(ui, "text-foreground")
		if v == .Default {
			p.apply(ui, "bg-background shadow-sm")
		}
	} else {
		p.apply(ui, "text-foreground/60")
	}
	defer p.end(ui)

	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0

	// The `after:` underline of the line variant. It is positioned against the
	// trigger's padding box in CSS and against its content box in palmy, so
	// the insets carry the padding back out.
	if active && v == .Line {
		p.div(ui, "absolute h-0.5 bg-foreground")
		st := p.style(ui)
		if vertical {
			st.inset[p.TOP] = p.px(-2)
			st.inset[p.BOTTOM] = p.px(-2)
			st.inset[p.RIGHT] = p.px(-10.5)
			st.w = p.px(2)
			st.h = p.AUTO
		} else {
			st.inset[p.LEFT] = p.px(-6)
			st.inset[p.RIGHT] = p.px(-6)
			st.inset[p.BOTTOM] = p.px(-7.5)
		}
		p.end(ui)
	}
}

// tabs_content is TabsPrimitive.Panel: `flex-1 text-sm`.
tabs_content :: proc(ui: ^p.Ctx, body: string) {
	p.text(ui, body, "flex-1 text-sm")
}
