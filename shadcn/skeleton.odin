package shadcn

// Skeleton, from app/components/ui/skeleton.tsx.
//
// `animate-pulse` is disabled on the isolation route, so the block renders at
// its resting opacity: a plain muted rectangle.

import p "palmy:."

skeleton :: proc(ui: ^p.Ctx, class := "") {
	p.div(ui, "animate-pulse rounded-md bg-muted")
	p.apply(ui, class)
	p.end(ui)
}
