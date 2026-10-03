package shadcn

// Dialog, from app/components/ui/dialog.tsx.
//
// The captured cases put `data-parity-root` on the popup itself, so only the
// panel is drawn here: no trigger, no backdrop. `max-w-sm` resolves to 384 at
// the 1280px capture viewport, which is also the width the harness hands the
// component, so `w-full` is enough.

import p "palmy:."

DIALOG_CONTENT_BASE ::
	"flex-col w-full gap-4 rounded-xl bg-popover p-4 text-sm text-popover-foreground " +
	"ring-1 ring-foreground/10"

dialog_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, DIALOG_CONTENT_BASE)
}

// dialog_close_button is the ghost icon button pinned to the panel's corner.
// palmy resolves absolute insets against the padding box, as CSS does, so
// `absolute top-2 right-2` is written literally.
dialog_close_button :: proc(ui: ^p.Ctx, inset, pad: f32, muted := false) {
	idx := button_open(ui, .Ghost, .Icon_SM, State{})
	st := p.style(ui, idx)
	st.position = .Absolute
	_ = pad
	st.inset[p.TOP] = p.px(inset)
	st.inset[p.RIGHT] = p.px(inset)
	if muted {
		p.apply(ui, "text-muted-foreground", idx)
	}
	p.icon(ui, ICON_X, "size-4")
	button_end(ui)
}

// dialog_header is `flex flex-col gap-2`.
dialog_header_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "gap-2")
}

dialog_title :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-base font-medium leading-none")
}

dialog_description :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-sm text-muted-foreground")
}

// dialog_footer bleeds out of the panel's padding (`-mx-4 -mb-4`) and carries
// the muted strip with the top hairline.
DIALOG_FOOTER_BASE ::
	"flex-row justify-end gap-2 rounded-b-xl border-t border-border bg-muted/50 p-4"

dialog_footer_open :: proc(ui: ^p.Ctx, pad: f32 = 16) -> int {
	idx := p.div(ui, DIALOG_FOOTER_BASE)
	st := p.style(ui, idx)
	st.margin[p.LEFT] = -pad
	st.margin[p.RIGHT] = -pad
	st.margin[p.BOTTOM] = -pad
	return idx
}

// shadcn's Button is `bg-clip-padding` over a 1px transparent border, so the
// browser paints the fill one pixel inside the border box and lets the
// container's own colour show through. palmy has no `background-clip`, but
// stroking that border in the container's colour produces the same pixels.
// Only the filled variants need it; `outline` already paints a real border and
// a focused button paints `border-ring`.
filled_button :: proc(
	ui: ^p.Ctx,
	label: string,
	surround: string,
	v := Variant.Default,
	s := Size.Default,
	st := State{},
) {
	idx := button_open(ui, v, s, st)
	if !st.focus {
		p.apply(ui, surround, idx)
	}
	if label != "" {
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	button_end(ui)
}
