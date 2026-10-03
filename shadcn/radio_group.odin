package shadcn

// RadioGroup, from app/components/ui/radio-group.tsx.
//
// The group is `grid w-full gap-2`, which for a single column is a column with
// an 8px gap. Each item is `size-4 rounded-full border border-input`; checked
// swaps in `border-primary bg-primary` and centres an 8px
// `bg-primary-foreground` dot.

import p "palmy:."

RADIO_BASE :: "relative flex-row size-4 shrink-0 items-center justify-center rounded-full border border-input"

radio :: proc(ui: ^p.Ctx, checked: bool, st := State{}) {
	p.div(ui, RADIO_BASE)
	if checked {
		p.apply(ui, "border-primary bg-primary text-primary-foreground")
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "opacity-50")
	}
	defer p.end(ui)

	if checked {
		p.div(ui, "size-2 rounded-full bg-primary-foreground")
		p.style(ui).shrink = 0
		p.end(ui)
	}
}

radio_group_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-col w-full gap-2")
}

radio_group_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
