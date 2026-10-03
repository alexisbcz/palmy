package shadcn

// Empty, from app/components/ui/empty.tsx.
//
// The outer box is `border-dashed`; palmy's border is always solid, so the
// hairline here is continuous where the browser's is broken. Everything else
// is a direct translation.

import p "palmy:."

EMPTY_BASE :: "flex-col w-full items-center justify-center gap-4 rounded-xl p-6 text-center"

empty_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.div(ui, EMPTY_BASE)
	p.apply(ui, class)
	return idx
}

empty_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// `flex max-w-sm flex-col items-center gap-2`; max-w-sm is 24rem.
empty_header_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "max-w-[384] items-center gap-2")
}

empty_header_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// EmptyMedia `variant="icon"`: `mb-2 flex size-8 items-center justify-center
// rounded-lg bg-muted text-foreground`.
empty_media_icon :: proc(ui: ^p.Ctx, ic: p.Icon) {
	p.div(ui, "mb-2 flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-muted text-foreground")
	defer p.end(ui)
	p.icon(ui, ic, "size-4 shrink-0")
}

empty_title :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "text-sm font-medium tracking-tight")
}

// `text-sm/relaxed text-muted-foreground`
empty_description :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "text-sm leading-relaxed text-muted-foreground")
}

empty_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.col(ui, "w-full max-w-[384] items-center gap-2.5 text-sm")
}

empty_content_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
