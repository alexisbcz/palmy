package shadcn

// Alert dialog, from app/components/ui/alert-dialog.tsx.
//
// The header is a CSS grid. At the capture viewport the `sm:` rules apply, so:
//   - size=default: `place-items-start text-left`, one column, title then
//     description stacked with `gap-1.5`.
//   - size=sm:      `place-items-center text-center`, same stack but centred,
//     and the footer becomes `grid grid-cols-2` with equal halves.
//   - with media:   two auto columns, both stretched by `justify-content:
//     normal`, so each absorbs half the free space. That is why the title
//     starts well to the right of the 40px media box; the offset is recorded
//     from the capture rather than re-derived here.

import p "palmy:."

ALERT_DIALOG_CONTENT_BASE ::
	"flex-col w-full gap-4 rounded-xl bg-popover p-4 text-popover-foreground " +
	"ring-1 ring-foreground/10"

alert_dialog_content_open :: proc(ui: ^p.Ctx) -> int {
	return p.div(ui, ALERT_DIALOG_CONTENT_BASE)
}

alert_dialog_header_open :: proc(ui: ^p.Ctx, centered: bool) -> int {
	idx := p.col(ui, "gap-1.5")
	if centered {
		p.apply(ui, "text-center", idx)
	}
	return idx
}

alert_dialog_title :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-base font-medium")
}

alert_dialog_description :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-sm text-muted-foreground")
}

// alert_dialog_media is the 40px rounded tile holding a 24px icon.
alert_dialog_media :: proc(ui: ^p.Ctx, ic: p.Icon) {
	p.div(ui, "size-10 shrink-0 flex-row items-center justify-center rounded-md bg-muted")
	p.icon(ui, ic, "size-6")
	p.end(ui)
}
