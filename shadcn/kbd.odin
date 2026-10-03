package shadcn

// Kbd and KbdGroup, from app/components/ui/kbd.tsx.
//
// `w-fit min-w-5` makes a single-character key a 20px square and lets longer
// labels grow; palmy's shrink-to-fit plus `min-w-5` is the same thing.

import p "palmy:."

KBD_BASE ::
	"inline-flex flex-row h-5 w-fit min-w-5 shrink-0 items-center justify-center gap-1 " +
	"rounded-sm bg-muted px-1 font-sans text-xs font-medium text-muted-foreground select-none"

kbd :: proc(ui: ^p.Ctx, label: string, class := "") {
	p.div(ui, KBD_BASE)
	p.apply(ui, class)
	defer p.end(ui)

	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
}

kbd_group_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.div(ui, "inline-flex flex-row items-center gap-1")
	p.apply(ui, class)
	return idx
}

kbd_group_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
