package shadcn

// Marker, from app/components/ui/marker.tsx.
//
// The separator variant's rules live in `before:`/`after:` pseudo-elements,
// which palmy has no equivalent for, so they are drawn as real children: a
// flex-1 hairline on each side of the label.

import p "palmy:."

Marker_Variant :: enum {
	Default,
	Separator,
	Border,
}

MARKER_BASE :: "relative flex-row min-h-4 items-center gap-2 text-sm text-muted-foreground"

marker_open :: proc(ui: ^p.Ctx, v := Marker_Variant.Default, class := "") -> int {
	idx := p.div(ui, MARKER_BASE)
	switch v {
	case .Default:
	case .Separator:
	case .Border:
		p.apply(ui, "border-b-1 border-border pb-2")
	}
	if class != "" {
		p.apply(ui, class)
	}
	return idx
}

marker_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// marker_line is the `before:`/`after:` hairline of the separator variant.
marker_line :: proc(ui: ^p.Ctx, class: string) {
	p.div(ui, "h-px min-w-0 flex-1 bg-border")
	p.apply(ui, class)
	p.end(ui)
}

marker_content :: proc(ui: ^p.Ctx, label: string, v := Marker_Variant.Default) {
	p.text(ui, label, v == .Separator ? "flex-none text-center" : "min-w-0")
	p.style(ui).shrink = 0
}
