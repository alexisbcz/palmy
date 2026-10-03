package shadcn

// InputGroup, from app/components/ui/input-group.tsx.
//
// The group is `h-8 ... rounded-lg border border-input`, and the control inside
// it keeps its own `h-8`, so it is two pixels *taller* than the group's content
// box and ends up flush with the border. Addons are `h-auto` with `py-1.5`, so
// they are as tall as whatever they hold plus 12.
//
// The control's horizontal padding is driven by which addons exist:
// `has-[>[data-align=inline-start]]:[&>input]:pl-1.5` and the inline-end mirror
// of it, which is why `ig_input` takes its two paddings explicitly.

import p "palmy:."

INPUT_GROUP_BASE :: "relative flex-row h-8 w-full min-w-0 items-center rounded-lg border border-input"

input_group_open :: proc(ui: ^p.Ctx, block := false, st := State{}) -> int {
	idx := p.div(ui, INPUT_GROUP_BASE)
	if block {
		// `has-[>[data-align=block-end]]:h-auto` + `flex-col`.
		p.apply(ui, "flex-col h-auto items-stretch")
	}
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.disabled {
		p.apply(ui, "bg-input/50 opacity-50")
	}
	return idx
}

input_group_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// INNER is the group's content box height: h-8 less its two borders. Children
// are taller than that, and CSS centres them against the content box so they
// overhang it. palmy instead grows the flex line to the tallest child and
// centres inside *that*, so every overhanging child carries the symmetric
// margin that makes the two models agree:  m = (INNER - own height) / 2.
INNER :: f32(30)

// ig_input is InputGroupInput: the shared Input with its border, radius and
// shadow removed, so only the padding and the 32px height survive.
ig_input :: proc(ui: ^p.Ctx, placeholder: string, pad_left, pad_right: f32) {
	p.div(ui, "h-8 flex-1 min-w-0 flex-row items-center bg-transparent py-1 text-sm cursor-text")
	s := p.style(ui)
	s.pad[p.LEFT] = pad_left
	s.pad[p.RIGHT] = pad_right
	s.margin[p.TOP] = (INNER - 32) / 2
	s.margin[p.BOTTOM] = (INNER - 32) / 2
	defer p.end(ui)

	p.text(ui, placeholder, "text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ig_textarea is InputGroupTextarea: `min-h-16 flex-1 px-2.5 py-2`.
ig_textarea :: proc(ui: ^p.Ctx, placeholder: string) {
	p.div(ui, "min-h-16 w-full flex-1 px-2.5 py-2 text-sm cursor-text")
	defer p.end(ui)

	p.text(ui, placeholder, "text-muted-foreground")
}

IG_ADDON_BASE :: "flex-row h-auto items-center gap-2 py-1.5 text-sm font-medium text-muted-foreground"

// `content_h` is the height of whatever the addon holds (16 for a bare icon,
// 20 for text, 24 for a button); py-1.5 adds 12 on top of it.
ig_addon_open :: proc(ui: ^p.Ctx, align := "inline-start", content_h := f32(16)) -> int {
	idx := p.div(ui, IG_ADDON_BASE)
	switch align {
	case "inline-start":
		p.apply(ui, "justify-center pl-2")
		ig_center(ui, content_h + 12)
	case "inline-end":
		p.apply(ui, "justify-center pr-2")
		ig_center(ui, content_h + 12)
	case "block-end":
		p.apply(ui, "w-full justify-start px-2.5 pb-2")
		p.style(ui).pad[p.TOP] = 6
	}
	return idx
}

ig_addon_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// ig_button is InputGroupButton: the ghost Button at size `xs`, overridden to
// `rounded-[calc(var(--radius)-3px)] px-1.5 text-sm`. The Button base's
// `border border-transparent` is invisible but two pixels wide, which is what
// makes the icon-only button 28 rather than 26.
IG_BUTTON_BASE ::
	"flex-row shrink-0 h-6 items-center justify-center gap-1 rounded-[7] " +
	"border border-transparent px-1.5 text-sm font-medium whitespace-nowrap"

ig_button_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, IG_BUTTON_BASE)
}

ig_button_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// ig_text is InputGroupText. It carries no weight of its own, so it inherits
// the addon's font-medium.
ig_text :: proc(ui: ^p.Ctx, text: string) {
	p.div(ui, "flex-row items-center gap-2 text-sm text-muted-foreground")
	defer p.end(ui)

	p.text(ui, text, "whitespace-nowrap")
	p.style(ui).shrink = 0
}

@(private)
ig_center :: proc(ui: ^p.Ctx, own_h: f32) {
	s := p.style(ui)
	s.margin[p.TOP] = (INNER - own_h) / 2
	s.margin[p.BOTTOM] = (INNER - own_h) / 2
}
