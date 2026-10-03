package shadcn

// Progress, from app/components/ui/progress.tsx.
//
// The root is `flex flex-wrap gap-3`: the label and value share the first flex
// line and the full-width track wraps onto the second. That is a column of
// [label row][track] with the same 12px gap.

import p "palmy:."

progress_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.col(ui, "gap-3")
	p.apply(ui, class)
	return idx
}

progress_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// progress_header is the first flex line: `text-sm font-medium` label on the
// left and an `ml-auto` value on the right.
progress_header :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full items-center justify-between")
	defer p.end(ui)

	p.text(ui, label, "text-sm font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, value, "text-sm text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// progress_track is `relative flex h-1 w-full items-center overflow-x-hidden
// rounded-full bg-muted` with an `h-full bg-primary` indicator.
progress_track :: proc(ui: ^p.Ctx, percent: f32) {
	p.div(ui, "relative flex-row h-1 w-full items-center overflow-hidden rounded-full bg-muted")
	defer p.end(ui)

	p.div(ui, "h-full bg-primary")
	p.style(ui).w = p.pct(percent)
	p.end(ui)
}
