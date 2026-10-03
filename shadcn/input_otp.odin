package shadcn

// InputOTP, from app/components/ui/input-otp.tsx.
//
// `data-parity-root` lands on the library's hidden <input>, which is stretched
// to cover the whole slot strip, so the measured box is the strip and the
// geometry file says nothing about the slots. They are rebuilt from the TSX:
// `size-8` each, `border-y border-r border-input`, with the first slot taking
// `rounded-l-lg border-l` and the last `rounded-r-lg`.
//
// Nothing is focused in the capture, so no slot is `data-active` and there is
// no caret.

import p "palmy:."

OTP_SLOT_BASE ::
	"relative flex-row size-8 items-center justify-center " +
	"border-y border-r border-input text-sm"

// input_otp_group draws one run of joined slots. `chars` may hold empty
// strings for slots the value has not reached.
input_otp_group :: proc(ui: ^p.Ctx, chars: []string) {
	p.div(ui, "flex-row items-center rounded-lg")
	defer p.end(ui)

	for ch, i in chars {
		p.key(ui, ch == "" ? "blank" : ch)
		p.div(ui, OTP_SLOT_BASE)
		if i == 0 {
			p.apply(ui, "rounded-l-lg border-l")
		}
		if i == len(chars) - 1 {
			p.apply(ui, "rounded-r-lg")
		}
		if ch != "" {
			p.text(ui, ch, "whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
	}
}

input_otp_separator :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row items-center")
	defer p.end(ui)

	p.icon(ui, ICON_MINUS, "size-4")
}

input_otp_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, "flex-row items-center")
}

input_otp_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}
