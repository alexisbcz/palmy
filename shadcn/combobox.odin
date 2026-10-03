package shadcn

// Combobox, from app/components/ui/combobox.tsx.

import p "palmy:."

COMBOBOX_CONTENT_BASE ::
	"flex-col overflow-hidden rounded-lg bg-popover text-popover-foreground shadow-md " +
	"ring-1 ring-foreground/10"

combobox_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, COMBOBOX_CONTENT_BASE)
}

combobox_list_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "p-1")
}

COMBOBOX_ITEM_BASE ::
	"flex-row w-full items-center gap-2 rounded-md py-1 pr-8 pl-1.5 text-sm"

combobox_item :: proc(ui: ^p.Ctx, label: string, selected := false) {
	idx := p.div(ui, COMBOBOX_ITEM_BASE)
	if selected {
		p.apply(ui, "bg-accent text-accent-foreground", idx)
	}
	defer p.end(ui)

	p.text(ui, label, "flex-1 whitespace-nowrap")
	if selected {
		menu_indicator(ui)
	}
}

// combobox_empty is the "no results" row. Base UI appends a word joiner to the
// label; it is zero width in both renderers, so it is left out here.
combobox_empty :: proc(ui: ^p.Ctx, label: string) {
	p.div(ui, "flex-row w-full justify-center py-2 text-center text-sm text-muted-foreground")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// `has-data-[slot=combobox-chip]:px-1` drops the horizontal padding to 4 once
// there is a chip in the field.
COMBOBOX_CHIPS_BASE ::
	"flex-row min-h-8 flex-wrap items-center gap-1 rounded-lg border border-input px-1 py-1 text-sm"

combobox_chips_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, COMBOBOX_CHIPS_BASE)
}

// combobox_chip is a 21px pill with a 24px ghost remove button hanging out of
// it top and bottom. palmy sizes a flex line to its tallest item, where CSS
// sizes it to the container's content box, so the button's cross-axis margins
// are pulled in by the 3px it overflows: that restores both the button's own
// position and the label's centring.
combobox_chip :: proc(ui: ^p.Ctx, label: string) {
	p.div(
		ui,
		"flex-row h-[21] w-fit shrink-0 items-center justify-center gap-1 rounded-sm " +
		"bg-muted pl-1.5 text-xs font-medium text-foreground whitespace-nowrap",
	)
	defer p.end(ui)

	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0

	idx := button_open(ui, .Ghost, .Icon_XS, State{})
	st := p.style(ui, idx)
	st.margin[p.LEFT] = -4 // `-ml-1`
	st.margin[p.TOP] = -1.5
	st.margin[p.BOTTOM] = -1.5
	st.opacity = 0.5
	p.icon(ui, ICON_X, "size-3")
	button_end(ui)
}

combobox_chips_input :: proc(ui: ^p.Ctx, placeholder: string) {
	p.text(ui, placeholder, "flex-1 min-w-16 text-sm text-foreground/50 whitespace-nowrap")
}
