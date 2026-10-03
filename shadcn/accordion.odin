package shadcn

// Accordion, from app/components/ui/accordion.tsx.
//
// Captured in a settled open/closed state, so there is no animation to model:
// an open item renders its panel, a closed one does not.
//
// `**:data-[slot=accordion-trigger-icon]:ml-auto` is redundant here — the
// trigger is `justify-between` with exactly two children — and palmy does not
// support `ml-auto` anyway.

import p "palmy:."

ACCORDION_TRIGGER ::
	"relative flex-row flex-1 items-start justify-between rounded-lg " +
	"border border-transparent py-2.5 text-left text-sm font-medium"

accordion_open :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-col w-full")
}

accordion_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// accordion_item is one AccordionItem: header + trigger, then the panel when
// open. `not-last:border-b` draws the hairline on every item but the last.
accordion_item :: proc(ui: ^p.Ctx, label, body: string, open: bool, last := false) {
	p.div(ui, last ? "flex-col" : "flex-col border-b border-border")
	defer p.end(ui)

	// <AccordionPrimitive.Header className="flex">
	p.div(ui, "flex-row")
	{
		p.div(ui, ACCORDION_TRIGGER)
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
		p.icon(ui, open ? ICON_CHEVRON_UP : ICON_CHEVRON_DOWN, "size-4 shrink-0 text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	if open {
		p.div(ui, "overflow-hidden text-sm")
		p.div(ui, "pb-2.5")
		p.text(ui, body, "")
		p.end(ui)
		p.end(ui)
	}
}
