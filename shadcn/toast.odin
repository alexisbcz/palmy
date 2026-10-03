package shadcn

// Toast, from app/components/ui/toast.tsx. The captured root is the toast
// itself; the viewport that positions it is not part of the measurement.

import p "palmy:."

TOAST_BASE ::
	"flex-col w-full rounded-2xl border border-border bg-popover text-popover-foreground " +
	"shadow-lg"

toast_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, TOAST_BASE)
}

// `flex h-full items-center gap-3 overflow-hidden p-4`.
toast_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-row h-full items-center gap-3 overflow-hidden p-4")
}

toast_text_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "flex-1 min-w-0 gap-1")
}

toast_title :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-sm font-medium")
}

toast_description :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-sm text-muted-foreground")
}

// The action is `<Button variant="outline" size="sm">` with `shrink-0`.
toast_action :: proc(ui: ^p.Ctx, label: string) {
	idx := button_open(ui, .Outline, .SM, State{})
	p.apply(ui, "shrink-0", idx)
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	button_end(ui)
}

// The close is `<Button variant="ghost" size="icon-sm">` tinted
// `text-muted-foreground`.
toast_close :: proc(ui: ^p.Ctx) {
	idx := button_open(ui, .Ghost, .Icon_SM, State{})
	p.apply(ui, "shrink-0 text-muted-foreground", idx)
	p.icon(ui, ICON_X, "size-4")
	button_end(ui)
}
