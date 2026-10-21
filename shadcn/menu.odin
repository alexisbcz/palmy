package shadcn

// The menu family: dropdown-menu.tsx and context-menu.tsx share every part
// except the popup's minimum width, so they share this file. select.tsx reuses
// the item geometry too, which is why `menu_indicator` lives here.

import p "palmy:."

MENU_CONTENT_BASE ::
	"flex-col rounded-lg bg-popover p-1 text-popover-foreground shadow-md " +
	"ring-1 ring-foreground/10"

menu_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, MENU_CONTENT_BASE)
}

// A `<MenuPrimitive.Group>` is a plain block: it stacks its children with no
// gap and no box of its own.
menu_group_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui)
}

menu_label :: proc(ui: ^p.Ctx, s: string) {
	p.div(ui, "flex-col px-1.5 py-1 text-xs font-medium text-muted-foreground")
	p.text(ui, s, "whitespace-nowrap")
	p.end(ui)
}

MENU_ITEM_BASE :: "flex-row items-center gap-1.5 rounded-md px-1.5 py-1 text-sm"

// `py-1 pr-8 pl-1.5` on the checkbox and radio items, which reserve the right
// gutter for the absolutely positioned tick.
MENU_CHECK_ITEM_BASE :: "flex-row items-center gap-1.5 rounded-md py-1 pr-8 pl-1.5 text-sm"

menu_item_open :: proc(ui: ^p.Ctx, destructive := false) -> int {
	idx := p.div(ui, MENU_ITEM_BASE)
	if destructive {
		p.apply(ui, "text-destructive", idx)
	}
	return idx
}

menu_check_item_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, MENU_CHECK_ITEM_BASE)
}

// menu_item_text is the item's own label. `flex-1` stands in for the
// `ml-auto` on the shortcut, which palmy's class parser does not model.
menu_item_text :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "flex-1 whitespace-nowrap")
}

menu_shortcut :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-xs tracking-widest text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// menu_indicator is the tick in a checkbox, radio or select item: a `size-4`
// icon pinned `right-2` inside the item's padding box and centred on the
// 20px line box. Both offsets are measured from the content box here, so the
// `pr-8` gutter and the 2px of leading slack come back off.
menu_indicator :: proc(ui: ^p.Ctx) {
	idx := p.icon(ui, ICON_CHECK, "size-4")
	st := p.style(ui, idx)
	st.position = .Absolute
	// `right-2`. palmy resolves absolute insets against the padding box now,
	// like CSS, so this is the literal value rather than one compensated for
	// the item's own padding.
	st.inset[p.RIGHT] = p.px(8)
	st.inset[p.TOP] = p.px(2)
}

// menu_separator is `-mx-1 my-1 h-px bg-border`: a hairline that bleeds through
// the popup's own padding.
menu_separator :: proc(ui: ^p.Ctx, pad: f32 = 4) {
	idx := p.div(ui, "h-px shrink-0 bg-border")
	st := p.style(ui, idx)
	st.margin[p.LEFT] = -pad
	st.margin[p.RIGHT] = -pad
	st.margin[p.TOP] = 4
	st.margin[p.BOTTOM] = 4
	p.end(ui)
}

// menu_popup_open opens a dropdown or context menu as a popup anchored to
// `anchor` (the trigger's rect, or a 1x1 rect at the pointer for a context
// menu), with its content box open: build the items, then `menu_popup_close`.
// On Wayland it is a real xdg_popup that may extend past the window; elsewhere
// it is drawn on top of the window. Returns true when it was dismissed by a
// press elsewhere; stop opening it then.
menu_popup_open :: proc(ui: ^p.Ctx, anchor: p.Rect, opts := p.POPUP_MENU) -> (dismissed: bool) {
	dismissed = p.popup_begin(ui, anchor, opts)
	menu_content_open(ui)
	return
}

menu_popup_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.popup_end(ui)
}
