package shadcn

// Label, from app/components/ui/label.tsx.
//
//   flex items-center gap-2 text-sm leading-none font-medium
//
// `leading-none` is what makes the box exactly as tall as the font size (14),
// so it has to be spelled out: palmy keeps text-sm's 20px leading otherwise.

import p "palmy:."

LABEL_BASE :: "flex-row items-center gap-2 text-sm leading-none font-medium"

label :: proc(ui: ^p.Ctx, text: string, class := "") {
	p.row(ui, LABEL_BASE)
	if class != "" {
		p.apply(ui, class)
	}
	defer p.end(ui)

	p.text(ui, text, "whitespace-nowrap")
	p.style(ui).shrink = 0
}
