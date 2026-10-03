package shadcn

// Separator, from app/components/ui/separator.tsx.
//
// Base UI resolves the orientation to a data attribute, so the two branches of
// `data-horizontal:` / `data-vertical:` are picked here instead. Those branches
// carry an attribute selector, so they outrank a plain `w-64` from the caller;
// hence the orientation sizing is applied *after* the caller's class.

import p "palmy:."

Separator_Orientation :: enum {
	Horizontal,
	Vertical,
}

separator :: proc(ui: ^p.Ctx, o := Separator_Orientation.Horizontal, class := "") {
	p.div(ui, "shrink-0 bg-border")
	p.apply(ui, class)
	p.apply(ui, o == .Horizontal ? "h-px w-full" : "w-px self-stretch")
	p.end(ui)
}
