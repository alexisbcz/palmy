package shadcn

// Popover, hover card and tooltip — the three plain floating panels.
// From popover.tsx, hover-card.tsx and tooltip.tsx.
//
// `shadow-md` in the browser is two gaussian layers
// (0 4px 6px -1px #0000001a, 0 2px 4px -2px #0000001a). palmy has one
// smoothstep approximation; the element screenshot clips everything outside
// the popup's own box, so the only place the difference shows is inside the
// rounded corners.

import p "palmy:."

POPOVER_CONTENT_BASE ::
	"flex-col w-72 gap-2.5 rounded-lg bg-popover p-2.5 text-sm text-popover-foreground " +
	"shadow-md ring-1 ring-foreground/10"

popover_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, POPOVER_CONTENT_BASE)
}

popover_header_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "gap-0.5 text-sm")
}

popover_title :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "font-medium")
}

popover_description :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-muted-foreground")
}

HOVER_CARD_CONTENT_BASE ::
	"flex-col w-64 rounded-lg bg-popover p-2.5 text-sm text-popover-foreground " +
	"shadow-md ring-1 ring-foreground/10"

hover_card_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, HOVER_CARD_CONTENT_BASE)
}

// avatar_fallback_sm is `<Avatar size="sm"><AvatarFallback>`: a 24px circle of
// `bg-muted` with a 1px `border-border` ring drawn by the `after:` pseudo
// element, and 12px muted initials.
avatar_fallback_sm :: proc(ui: ^p.Ctx, initials: string) {
	p.div(
		ui,
		"size-6 shrink-0 flex-row items-center justify-center rounded-full " +
		"border border-border bg-muted text-xs text-muted-foreground",
	)
	p.text(ui, initials, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

TOOLTIP_CONTENT_BASE ::
	"flex-row w-fit items-center gap-1.5 rounded-md bg-foreground px-3 py-1.5 " +
	"text-xs text-background"

tooltip_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, TOOLTIP_CONTENT_BASE)
}

// kbd inside a tooltip: `in-data-[slot=tooltip-content]` swaps the muted chip
// for a translucent one on the dark panel, and the tooltip's own
// `**:data-[slot=kbd]:rounded-sm` overrides the chip radius.
tooltip_kbd :: proc(ui: ^p.Ctx, s: string) {
	p.div(
		ui,
		"h-5 w-fit min-w-5 shrink-0 flex-row items-center justify-center gap-1 " +
		"rounded-sm bg-background/20 px-1 text-xs font-medium text-background",
	)
	p.text(ui, s, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// popover_popup_open opens a popover as a popup against `anchor`; then
// `popover_popup_close`. It grabs, so a click away dismisses it.
popover_popup_open :: proc(ui: ^p.Ctx, anchor: p.Rect, opts := p.POPUP_MENU) -> (dismissed: bool) {
	dismissed = p.popup_begin(ui, anchor, opts)
	popover_content_open(ui)
	return
}

popover_popup_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.popup_end(ui)
}

// hover_card_popup_open is a popover that does not grab: it is shown while
// the pointer is over its trigger, and the application closes it.
hover_card_popup_open :: proc(ui: ^p.Ctx, anchor: p.Rect) {
	p.popup_begin(ui, anchor, p.Popup{side = .Bottom, align = .Center, gap = 4})
	hover_card_content_open(ui)
}

hover_card_popup_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.popup_end(ui)
}

// tooltip_popup_open shows a tooltip above `anchor`, centred, flipping below
// when there is no room; it never grabs. Then `tooltip_popup_close`.
tooltip_popup_open :: proc(ui: ^p.Ctx, anchor: p.Rect) {
	p.popup_begin(ui, anchor, p.POPUP_TOOLTIP)
	tooltip_content_open(ui)
}

tooltip_popup_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.popup_end(ui)
}
