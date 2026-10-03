package shadcn

// Command, from app/components/ui/command.tsx.
//
// cmdk's own wrappers (the hidden label, the list sizer) carry no paint, so
// only the boxes that produce pixels are built here.

import p "palmy:."

COMMAND_BASE :: "flex-col w-full overflow-hidden rounded-xl bg-popover p-1 text-popover-foreground"

command_open :: proc(ui: ^p.Ctx, ringed: bool) -> int {
	idx := p.div(ui, COMMAND_BASE)
	if ringed {
		p.apply(ui, "ring-1 ring-foreground/10", idx)
	}
	return idx
}

// command_input is the search field: a `p-1 pb-0` wrapper around an
// `InputGroup` whose addon holds the 16px magnifier at half opacity.
command_input :: proc(ui: ^p.Ctx, placeholder: string) {
	p.div(ui, "flex-col p-1 pb-0")
	defer p.end(ui)

	p.div(
		ui,
		"flex-row h-8 w-full items-center rounded-lg border border-input/30 bg-input/30",
	)
	defer p.end(ui)

	// `<InputGroupAddon>`: `order-first pl-2 py-1.5`, so 24x28.
	p.div(ui, "flex-row h-auto shrink-0 items-center justify-center gap-2 py-1.5 pl-2")
	ic := p.icon(ui, ICON_SEARCH, "size-4 shrink-0 text-muted-foreground")
	p.style(ui, ic).opacity = 0.5
	p.end(ui)

	// The placeholder colour is Tailwind's preflight default:
	// `color-mix(in oklab, currentcolor 50%, transparent)`.
	p.text(ui, placeholder, "flex-1 pl-1.5 text-sm text-foreground/50 whitespace-nowrap")
}

command_list_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui)
}

command_group_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "overflow-hidden p-1")
}

command_group_heading :: proc(ui: ^p.Ctx, s: string) {
	p.div(ui, "flex-col px-2 py-1.5 text-xs font-medium text-muted-foreground")
	p.text(ui, s, "whitespace-nowrap")
	p.end(ui)
}

// command_items_open is cmdk's `[cmdk-group-items]` wrapper: a bare block.
command_items_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui)
}

COMMAND_ITEM_BASE :: "flex-row items-center gap-2 rounded-sm px-2 py-1.5 text-sm"

// `in-data-[slot=dialog-content]:rounded-lg!` swaps the 6px radius for 10px
// when the palette is inside a dialog.
command_item_open :: proc(ui: ^p.Ctx, selected := false, in_dialog := false) -> int {
	idx := p.div(ui, COMMAND_ITEM_BASE)
	if in_dialog {
		p.apply(ui, "rounded-lg", idx)
	}
	if selected {
		p.apply(ui, "bg-muted text-foreground", idx)
	}
	return idx
}

command_item_text :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "flex-1 whitespace-nowrap")
}

command_shortcut :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-xs tracking-widest text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// command_separator is `-mx-1 h-px bg-border` — no vertical margin, unlike the
// menu separator.
command_separator :: proc(ui: ^p.Ctx, pad: f32 = 4) {
	idx := p.div(ui, "h-px shrink-0 bg-border")
	st := p.style(ui, idx)
	st.margin[p.LEFT] = -pad
	st.margin[p.RIGHT] = -pad
	p.end(ui)
}
