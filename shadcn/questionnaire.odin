package shadcn

// Questionnaire, from app/components/ui/questionnaire.tsx.
//
// The `fieldset` / `legend` pair is the one thing that does not map onto flex:
// a legend is taken out of the fieldset's flow and pushes the content box down
// by its own height, so there is no gap between it and the description. Here
// that is a plain column holding the legend followed by a gap-4 column of
// everything else.
//
// `QuestionnairePrevious` / `QuestionnaireNext` render nothing for a one-item
// questionnaire, so the actions row is 32px of empty space in both captures.

import p "palmy:."

// questionnaire_legend is `font-heading text-base leading-snug font-medium`,
// plus `mb-4` when no description follows it.
questionnaire_legend :: proc(ui: ^p.Ctx, title: string, lonely: bool) {
	text_snapped(ui, title, "text-base leading-[22] font-medium whitespace-nowrap", 22, 1)
	p.style(ui).shrink = 0
	if lonely {
		p.style(ui).margin[p.BOTTOM] = 16
	}
}

// questionnaire_choice is one radio card: `min-h-11 items-start gap-2.5
// rounded-lg border border-input px-3 py-2.5 text-sm`, checked adding
// `border-primary/40 bg-muted`.
questionnaire_choice :: proc(ui: ^p.Ctx, label, desc: string, checked: bool, h: f32 = 0) {
	p.div(
		ui,
		"relative flex-row min-h-11 items-start gap-2.5 rounded-lg " +
		"border border-input px-3 py-2.5 text-sm",
	)
	if checked {
		p.apply(ui, "border-primary/40 bg-muted")
	}
	// The card is 62.5px tall; which whole pixel its bottom edge lands on
	// depends on where its top edge started, so the capture's snapped height
	// is passed in rather than derived.
	if h > 0 {
		p.style(ui).h = p.px(h)
	}
	defer p.end(ui)

	// indicator: size-4 rounded-full border, nudged down by `translate-y-*`.
	p.div(ui, "flex-col size-4 shrink-0 items-center justify-center rounded-full border border-input")
	// `translate-y-0.5` with a description, `translate-y-[--spacing(0.45)]`
	// without — 1.8px, which the browser then snaps to a whole pixel.
	p.style(ui).margin[p.TOP] = desc != "" ? 2 : 1
	if checked {
		p.apply(ui, "border-primary bg-primary")
		p.div(ui, "size-2 rounded-full bg-primary-foreground")
		p.end(ui)
	}
	p.end(ui)

	// content: flex-1 flex-col gap-0.5 leading-snug
	p.div(ui, "flex-col flex-1 min-w-0 gap-0.5 leading-[19.25]")
	defer p.end(ui)
	text_snapped(ui, label, "whitespace-nowrap", 19.25, 1)
	p.style(ui).shrink = 0
	if desc != "" {
		text_snapped(ui, desc, "text-muted-foreground whitespace-nowrap", 19.25, 1)
		p.style(ui).shrink = 0
	}
}

// questionnaire_actions is the trailing row: `min-h-11 sm:min-h-8`, and empty
// whenever there is only one item to step through.
questionnaire_actions :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row w-full h-8 items-center gap-2")
	p.end(ui)
}
