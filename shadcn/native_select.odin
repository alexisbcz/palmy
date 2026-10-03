package shadcn

// Native select, from app/components/ui/native-select.tsx.
//
// `data-parity-root` lands on the <select>, not on the wrapper, so the measured
// box is the select and the chevron is a *sibling* that still shows up in the
// screenshot because it overlaps it.
//
// palmy places absolutely positioned children against the parent's content
// box, where CSS uses the padding box, so the chevron's offsets are expressed
// relative to the select's content box instead:
//
//   right: content-box right is (box right - 1 border - 32 pr), the chevron's
//          right edge is (box right - 1 border - 10), hence -23.
//   top:   content-box top is (1 border + py), and the 16px glyph is centred in
//          the 32/28px box, which works out to +3 for both sizes.

import p "palmy:."

Select_Size :: enum {
	Default,
	SM,
}

NATIVE_SELECT_BASE ::
	"relative h-8 w-full min-w-0 rounded-lg border border-input bg-transparent " +
	"py-1 pr-8 pl-2.5 text-sm flex-row items-center select-none"

native_select :: proc(ui: ^p.Ctx, value: string, size := Select_Size.Default, st := State{}) {
	p.div(ui, NATIVE_SELECT_BASE)
	if size == .SM {
		p.apply(ui, "h-7 rounded-md py-0.5")
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "opacity-50")
	}
	defer p.end(ui)

	p.text(ui, value, "whitespace-nowrap")
	p.style(ui).shrink = 0

	p.icon(ui, ICON_CHEVRON_DOWN, "absolute size-4 text-muted-foreground")
	p.style(ui).inset[p.TOP] = p.px(3)
	p.style(ui).inset[p.RIGHT] = p.px(-23)
}
