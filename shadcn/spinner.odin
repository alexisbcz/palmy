package shadcn

// Spinner, from app/components/ui/spinner.tsx: a lucide loader-circle at the
// text colour. `animate-spin` is disabled on the isolation route, so the arc
// sits at rotation zero.
//
// That zero is right for the parity capture and wrong for an application,
// where the loader just sat still. `turns` is how a caller drives it -- one
// turn per second, matching the Tailwind utility this mirrors, is:
//
//	sc.spinner(ui, "size-4", p.elapsed(ui))
//
// It stays a parameter rather than reading the clock here so that rendering a
// spinner is deterministic: the parity suite draws all 182 cases in one
// process, and a widget that rotated with wall time would render at a
// different angle every run.
import p "palmy:."

spinner :: proc(ui: ^p.Ctx, class := "size-4", turns: f32 = 0) {
	p.icon(ui, ICON_LOADER_CIRCLE, "size-4 shrink-0", turns)
	p.apply(ui, class)
}
