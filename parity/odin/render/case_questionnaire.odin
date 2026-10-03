package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_questionnaire_cases :: proc "contextless" () {
	add_case("questionnaire-input", proc(ui: ^p.Ctx) {
		p.div(ui, "flex-col w-96 min-w-0 gap-4")
		defer p.end(ui)

		// fieldset
		p.div(ui, "flex-col min-w-0")
		sc.questionnaire_legend(ui, "What is your name?", true)
		p.div(ui, "relative w-full min-w-0")
		sc.input(ui, "", "Ada Lovelace")
		p.end(ui)
		p.end(ui)

		sc.questionnaire_actions(ui)
	})
	add_case("questionnaire-choices", proc(ui: ^p.Ctx) {
		pixel_snap(ui, p.div(ui, "flex-col w-96 min-w-0 gap-4"), 0.5)
		defer p.end(ui)

		// progress: w-fit with min-w-[14ch]
		p.div(ui, "")
		p.style(ui).w = p.px(113.063)
		p.style(ui).h = p.px(16)
		p.text(ui, "Question 1 of 1", "text-xs font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)

		// fieldset
		p.div(ui, "flex-col min-w-0")
		sc.questionnaire_legend(ui, "Which plan fits best?", false)
		p.div(ui, "flex-col min-w-0 gap-4")
		p.text(ui, "You can change it later.", "text-sm text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.div(ui, "flex-col min-w-0 gap-2")
		sc.questionnaire_choice(ui, "Free", "One project", true, 62)
		sc.questionnaire_choice(ui, "Pro", "Ten projects", false, 63)
		sc.questionnaire_choice(ui, "Team", "", false, 44)
		p.end(ui)
		p.end(ui)
		p.end(ui)

		sc.questionnaire_actions(ui)
	})
}
