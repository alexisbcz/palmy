package shadcn

// Select, from app/components/ui/select.tsx.
//
// The trigger's `py-2` leaves a 14px content box that a 20px line box
// overflows, and the browser centres it symmetrically. palmy grows the flex
// line to the container instead, so the padding is restated here as the value
// that puts the line box where CSS puts it: (h - 2*border - 20) / 2.

import p "palmy:."

SELECT_TRIGGER_BASE ::
	"flex-row w-full items-center justify-between gap-1.5 rounded-lg border border-input " +
	"pr-2 pl-2.5 text-sm whitespace-nowrap"

select_trigger :: proc(ui: ^p.Ctx, value: string, placeholder := "", small := false, st := State{}) {
	idx := p.div(ui, SELECT_TRIGGER_BASE)
	if small {
		// `h-7 rounded-[min(var(--radius-md),10px)]`.
		p.apply(ui, "h-7 rounded-md py-[3]", idx)
	} else {
		p.apply(ui, "h-8 py-[5]", idx)
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	defer p.end(ui)

	if value != "" {
		p.text(ui, value, "flex-1 text-left whitespace-nowrap")
	} else {
		p.text(ui, placeholder, "flex-1 text-left text-muted-foreground whitespace-nowrap")
	}
	p.icon(ui, ICON_CHEVRON_DOWN, "size-4 shrink-0 text-muted-foreground")
}

SELECT_CONTENT_BASE ::
	"flex-col rounded-lg bg-popover text-popover-foreground shadow-md ring-1 ring-foreground/10"

select_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, SELECT_CONTENT_BASE)
}

// `<SelectPrimitive.List>` has no styles of its own; `<SelectGroup>` is
// `scroll-my-1 p-1`.
select_list_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui)
}

select_group_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "p-1")
}

select_label :: proc(ui: ^p.Ctx, s: string) {
	p.div(ui, "flex-col px-1.5 py-1 text-xs text-muted-foreground")
	p.text(ui, s, "whitespace-nowrap")
	p.end(ui)
}

SELECT_ITEM_BASE ::
	"flex-row w-full items-center gap-1.5 rounded-md py-1 pr-8 pl-1.5 text-sm"

// select_item draws one row. `selected` is the item the open list has focus
// on, which shadcn paints with `focus:bg-accent focus:text-accent-foreground`.
select_item :: proc(ui: ^p.Ctx, label: string, selected := false) {
	idx := p.div(ui, SELECT_ITEM_BASE)
	if selected {
		p.apply(ui, "bg-accent text-accent-foreground", idx)
	}
	defer p.end(ui)

	// `<SelectPrimitive.ItemText className="flex flex-1 shrink-0 gap-2">`.
	p.text(ui, label, "flex-1 whitespace-nowrap")
	if selected {
		menu_indicator(ui)
	}
}
