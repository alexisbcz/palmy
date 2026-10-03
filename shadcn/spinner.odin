package shadcn

// Spinner, from app/components/ui/spinner.tsx: a lucide loader-circle at the
// text colour. `animate-spin` is disabled on the isolation route, so the arc
// sits at rotation zero.

import p "palmy:."

spinner :: proc(ui: ^p.Ctx, class := "size-4") {
	p.icon(ui, ICON_LOADER_CIRCLE, "size-4 shrink-0")
	p.apply(ui, class)
}
