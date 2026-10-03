package shadcn

// Alert, from app/components/ui/alert.tsx.
//
// The TSX lays the alert out as a grid: one column normally, and
// `grid-cols-[auto_1fr] gap-x-2` when a leading icon is present, with the icon
// spanning both rows. That is a flex row of [icon][title/description stack]
// here. `*:[svg]:translate-y-0.5` is a 2px paint offset in CSS; a 2px top
// margin puts the icon in the same place without changing the row's height,
// because the text stack is taller.
//
// AlertAction is `absolute top-2 right-2`, and the alert reserves room for it
// with `pr-18`. CSS anchors an absolutely positioned child at the containing
// block's *padding* box; palmy anchors at the content box, so the right inset
// is shifted by the padding that CSS would not have subtracted.

import p "palmy:."

Alert_Variant :: enum {
	Default,
	Destructive,
}

ALERT_BASE :: "relative w-full rounded-lg border border-border bg-card px-2.5 py-2 text-left text-sm"

// `has-data-[slot=alert-action]:pr-18`.
ALERT_ACTION_PAD :: f32(72)

alert_open :: proc(
	ui: ^p.Ctx,
	v := Alert_Variant.Default,
	with_icon := false,
	with_action := false,
	class := "",
) -> int {
	idx := p.div(ui, ALERT_BASE)
	p.apply(ui, v == .Destructive ? "text-destructive" : "text-card-foreground")
	p.apply(ui, with_icon ? "flex-row gap-x-2" : "flex-col gap-y-0.5")
	if with_action {
		p.apply(ui, "pr-18")
	}
	p.apply(ui, class)
	return idx
}

alert_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// alert_icon is the `*:[svg]:size-4 *:[svg]:translate-y-0.5` leading icon.
alert_icon :: proc(ui: ^p.Ctx, ic: p.Icon) {
	p.icon(ui, ic, "size-4 shrink-0 self-start mt-0.5")
}

// alert_body_open opens the `1fr` column that holds the title and description.
// Without an icon the alert is a single column and the stack is the alert.
alert_body_open :: proc(ui: ^p.Ctx, with_icon := false) {
	if with_icon {
		p.col(ui, "flex-1 gap-0.5")
	}
}

alert_body_end :: proc(ui: ^p.Ctx, with_icon := false) {
	if with_icon {
		p.end(ui)
	}
}

alert_title :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "font-medium")
}

alert_description :: proc(ui: ^p.Ctx, label: string, v := Alert_Variant.Default) {
	p.text(ui, label, "text-sm")
	p.apply(ui, v == .Destructive ? "text-destructive/90" : "text-muted-foreground")
}

// alert_action_open places the action in the reserved `pr-18` gutter.
alert_action_open :: proc(ui: ^p.Ctx) -> int {
	idx := p.div(ui, "absolute items-end")
	st := p.style(ui)
	st.inset[p.TOP] = p.px(8) // `top-2`, against the padding box as CSS does
	st.inset[p.RIGHT] = p.px(8) // `right-2`, likewise
	return idx
}

alert_action_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
