package shadcn

// Checkbox, from app/components/ui/checkbox.tsx.
//
// The root is `size-4 rounded-[4px] border border-input`; `data-checked` swaps
// in `border-primary bg-primary text-primary-foreground`. The indicator is a
// 14px check glyph that fills the content box exactly.
//
// `indeterminate` is not a dash here: shadcn's Indicator only ever renders
// CheckIcon, and Base UI mounts it for the indeterminate state too, while
// `data-checked` stays off. So the browser really does draw a dark check on an
// unfilled box, and that is what this reproduces.

import p "palmy:."

Checked :: enum {
	Off,
	On,
	Indeterminate,
}

CHECKBOX_BASE ::
	"relative flex-row size-4 shrink-0 items-center justify-center rounded-[4] " +
	"border border-input"

checkbox :: proc(ui: ^p.Ctx, state := Checked.Off, st := State{}) {
	p.div(ui, CHECKBOX_BASE)
	if state == .On {
		p.apply(ui, "border-primary bg-primary text-primary-foreground")
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	// `disabled:opacity-50` never fires: the root is a <span>, so the CSS
	// `:disabled` pseudo-class does not match it. checkbox-disabled is
	// therefore pixel-identical to checkbox-checked in the browser.
	defer p.end(ui)

	if state != .Off {
		p.icon(ui, ICON_CHECK, "size-3.5")
	}
}
