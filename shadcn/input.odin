package shadcn

// Input, from app/components/ui/input.tsx.
//
// `md:text-sm` applies at the 1280px capture viewport, so the text is 14px.

import p "palmy:."

INPUT_BASE ::
	"h-8 w-full min-w-0 rounded-lg border border-input bg-transparent px-2.5 py-1 " +
	"text-sm transition-colors outline-none flex-row items-center cursor-text"

input :: proc(ui: ^p.Ctx, value: string, placeholder := "", st := State{}) {
	p.div(ui, INPUT_BASE)
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.invalid {
		// `aria-invalid:border-destructive aria-invalid:ring-3 ring-destructive/20`
		p.apply(ui, "border-destructive ring-3 ring-destructive/20")
	}
	if st.disabled {
		p.apply(ui, "opacity-50 bg-input/50")
	}
	defer p.end(ui)

	if value != "" {
		p.text(ui, value, "text-foreground whitespace-nowrap")
	} else if placeholder != "" {
		p.text(ui, placeholder, "text-muted-foreground whitespace-nowrap")
	}
	p.style(ui).shrink = 0
}
