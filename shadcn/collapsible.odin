package shadcn

// Collapsible, from app/components/ui/collapsible.tsx.
//
// The primitive adds no classes of its own; the case supplies
// `flex w-72 flex-col gap-2` and renders the trigger as an outline Button.
// Base UI puts `aria-expanded` on the trigger, and the outline variant has
// `aria-expanded:bg-muted`, so an open collapsible's trigger is grey.
//
// The panel is captured in a settled state, so the open case simply includes
// it and the closed case leaves it out.

import p "palmy:."

collapsible :: proc(ui: ^p.Ctx, label, body: string, open: bool) {
	p.div(ui, "flex-col gap-2")
	defer p.end(ui)

	button_open(ui, .Outline, .Default, State{hover = open})
	p.apply(ui, "flex-row")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	button_end(ui)

	if open {
		p.text(ui, body, "text-sm")
	}
}
