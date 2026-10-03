package shadcn

// Textarea, from app/components/ui/textarea.tsx.
//
// `md:text-sm` wins at the 1280px capture viewport, so the text is 14px.

import p "palmy:."

TEXTAREA_BASE ::
	"min-h-16 w-full rounded-lg border border-input bg-transparent px-2.5 py-2 " +
	"text-sm cursor-text"

textarea :: proc(ui: ^p.Ctx, value: string, placeholder := "", st := State{}) {
	p.div(ui, TEXTAREA_BASE)
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "bg-input/50 opacity-50")
	}
	defer p.end(ui)

	if value != "" {
		p.text(ui, value, "text-foreground")
	} else if placeholder != "" {
		p.text(ui, placeholder, "text-muted-foreground")
	}
}
