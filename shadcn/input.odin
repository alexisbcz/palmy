package shadcn

// Input, from app/components/ui/input.tsx.
//
// `md:text-sm` applies at the 1280px capture viewport, so the text is 14px.
//
// There are two forms. Given a `string` the field is a picture of an input:
// that is what the parity cases capture and it is unchanged. Given a byte
// buffer it is `palmy.text_field` wearing these clothes — the same box, the
// same tokens, but edited. There is deliberately no second implementation of
// caret movement, bidi-aware arrow keys or horizontal scrolling here; that
// lives in palmy and this file only dresses it.

import p "palmy:."

INPUT_BASE ::
	"h-8 w-full min-w-0 rounded-lg border border-input bg-transparent px-2.5 py-1 " +
	"text-sm transition-colors outline-none flex-row items-center cursor-text"

// INPUT_EDIT is INPUT_BASE as `palmy.text_field` needs it. text_field starts
// from its own FIELD_BASE and lets the caller's classes win, and INPUT_BASE
// already overrides the height, the padding, the fill and the border. Two
// things it does not name, because the browser's input does not need to:
//
//   - FIELD_BASE's `hover:` and `focus:` border colours. shadcn's input does
//     not change on hover and draws a *ring* on focus, not a bare border, so
//     both are pinned back to `border-input` and the focus look is applied
//     below exactly as the display form applies it.
//   - `overflow-hidden`, which is not neutralised: it is what lets text_field
//     slide a long value under the caret instead of spilling out of the box.
@(private)
INPUT_EDIT :: INPUT_BASE + " hover:border-input focus:border-input"

input :: proc {
	input_value,
	input_buf,
}

// input_value draws a field holding `value`. It is display-only — this is the
// form the parity suite captures, and its output has not changed.
input_value :: proc(ui: ^p.Ctx, value: string, placeholder := "", st := State{}) {
	p.div(ui, INPUT_BASE)
	if st.focus {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if st.invalid {
		// `aria-invalid:border-destructive aria-invalid:ring-3 ring-destructive/20`
		p.apply(ui, "border-destructive ring-3 ring-destructive/20")
	}
	if st.disabled {
		p.apply(ui, "opacity-50 bg-input/50")
	}
	defer p.end(ui)

	if value != "" {
		p.text(ui, value, "text-foreground whitespace-nowrap")
	} else if placeholder != "" {
		p.text(ui, placeholder, "text-muted-foreground whitespace-nowrap")
	}
	p.style(ui).shrink = 0
}

// input_buf edits a byte buffer in place and reports whether the text changed
// this frame and whether Enter was pressed, which is `palmy.text_field`'s
// contract:
//
//	buf := p.state(ui, "email", [dynamic]u8{})
//	if changed, submitted := sc.input(ui, buf, "Email address"); submitted {
//		sign_in(string(buf[:]))
//	}
//
// `mask` replaces every rune on screen, for a password field; the buffer still
// holds the real bytes.
input_buf :: proc(
	ui: ^p.Ctx,
	buf: ^[dynamic]u8,
	placeholder := "",
	st := State{},
	mask: rune = 0,
) -> (changed: bool, submitted: bool) {
	// A disabled input is not a text field: it cannot take focus and nothing
	// can be typed into it. Drawing it through the display form is both the
	// correct behaviour and the guarantee that a disabled field is pixel-wise
	// what it always was.
	if st.disabled {
		input_value(ui, string(buf[:]), placeholder, st)
		return false, false
	}

	idx := p.node_count(ui)
	changed, submitted = p.text_field(ui, buf, placeholder, INPUT_EDIT, mask)

	// The placeholder. palmy fades the field's own text colour to half, which
	// is the right answer with no theme registered; shadcn names a separate
	// token for it and the display form above uses that token. Re-applying it
	// as a *class* rather than a colour keeps the fallback intact — palmy
	// drops a class whose colour token it cannot resolve, so a palette without
	// `muted-foreground` still gets the faded text.
	//
	// text_field pushes the field and then exactly one text node, so the text
	// is the node after the field; the kind is checked rather than assumed.
	if len(buf) == 0 && placeholder != "" && p.node_kind(ui, idx + 1) == .Text {
		p.apply(ui, "text-muted-foreground", idx + 1)
	}

	// `focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px]`.
	// `st.focus` forces it, which is how the captured focus states are drawn;
	// a field that really holds the keyboard gets it for free.
	if st.focus || p.focused(ui, idx) {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	if st.invalid {
		p.apply(ui, "border-destructive ring-3 ring-destructive/20", idx)
	}
	return
}
