package shadcn

// Field and friends, from app/components/ui/field.tsx.
//
// The parts are deliberately thin: every case in case_field.odin composes them
// in the same order the TSX nests them, because the interesting numbers are the
// gaps and the line heights, not the markup.
//
// Line heights have to be spelled out, since palmy does not infer Tailwind's
// `leading-*` from a font size the way the cascade does:
//
//   FieldLabel        text-sm + leading-snug  -> 14 / 19.25
//   FieldTitle        text-sm                 -> 14 / 20
//   FieldDescription  text-sm + leading-normal-> 14 / 21
//   FieldError        text-sm                 -> 14 / 20
//   FieldLegend       text-base               -> 16 / 24

import p "palmy:."

FIELD_LABEL_CLASS :: "text-sm font-medium leading-[19.25]"
FIELD_TITLE_CLASS :: "text-sm font-medium leading-[20]"
FIELD_DESC_CLASS :: "text-sm font-normal leading-[21] text-muted-foreground"
FIELD_ERROR_CLASS :: "text-sm font-normal leading-[20] text-destructive"
FIELD_LEGEND_CLASS :: "text-base font-medium leading-[24]"

field_label :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, text, FIELD_LABEL_CLASS)
}

field_title :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, text, FIELD_TITLE_CLASS + " self-start")
}

field_description :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, text, FIELD_DESC_CLASS)
}

field_error :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, text, FIELD_ERROR_CLASS)
}

// field_open is `flex w-full gap-2`, column or row.
field_open :: proc(ui: ^p.Ctx, horizontal := false) -> int {
	if horizontal {
		// `has-[>[data-slot=field-content]]:items-start` applies whenever the
		// row holds a FieldContent, which is the only horizontal case here.
		return p.div(ui, "flex-row w-full gap-2 items-start")
	}
	return p.div(ui, "flex-col w-full gap-2")
}

field_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// field_content is `flex flex-1 flex-col gap-0.5 leading-snug`.
field_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-col flex-1 gap-0.5")
}

field_group_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-col w-full gap-5")
}

field_set_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-col w-full gap-4")
}

// field_invalid_input is the aria-invalid Input: destructive border and a 3px
// destructive/20 ring. The text colour comes from the Field root, which carries
// `data-[invalid=true]:text-destructive`.
field_invalid_input :: proc(ui: ^p.Ctx, value: string) {
	p.div(
		ui,
		"h-8 w-full min-w-0 rounded-lg border border-destructive bg-transparent " +
		"px-2.5 py-1 text-sm flex-row items-center cursor-text ring-3 ring-destructive/20",
	)
	defer p.end(ui)

	p.text(ui, value, "whitespace-nowrap")
	p.style(ui).shrink = 0
}

// field_separator is `relative -my-2 h-5` with a hairline across the middle and
// the label painted over it in the page background.
field_separator :: proc(ui: ^p.Ctx, text: string) {
	p.div(ui, "relative h-5 w-full text-sm")
	s := p.style(ui)
	s.margin[p.TOP] = -8
	s.margin[p.BOTTOM] = -8
	defer p.end(ui)

	p.div(ui, "absolute inset-0 top-1/2 h-px bg-border")
	p.end(ui)

	if text != "" {
		p.row(ui, "w-full justify-center")
		p.div(ui, "px-2 bg-background flex-row items-center")
		p.text(ui, text, "text-muted-foreground leading-[20] whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		p.end(ui)
	}
}
