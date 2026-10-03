package shadcn

// Resizable, from app/components/ui/resizable.tsx (react-resizable-panels).
//
// The panel group is `flex h-full w-full`, and in the capture the `h-40 w-96`
// the case asks for never reaches the DOM, so the group is as wide as the page
// container and as tall as its content: 38px for the horizontal case, and a
// collapsed 3px for the vertical one, whose panels overflow it.

import p "palmy:."

Resizable_Orientation :: enum {
	Horizontal,
	Vertical,
}

// resizable_group is the whole widget. `sizes` are the two panel sizes in px
// along the group's main axis, and `with_handle` draws the grip.
resizable_group :: proc(
	ui: ^p.Ctx,
	orientation: Resizable_Orientation,
	labels: [2]string,
	panel: f32,
	with_handle: bool,
	group_h: f32,
) -> int {
	idx := p.div(ui, "w-full rounded-lg border border-border overflow-hidden")
	p.apply(ui, orientation == .Vertical ? "flex-col" : "flex-row")
	p.style(ui).h = p.px(group_h)
	defer p.end(ui)

	for i in 0 ..< 2 {
		// react-resizable-panels gives a panel `flex: 0 1 0` plus
		// `overflow: hidden`, so in the vertical case — where the group has
		// collapsed to 1px of content — both panels are zero-height and their
		// text overflows out of the group entirely.
		p.div(ui, "overflow-hidden shrink-0")
		if orientation == .Horizontal {
			p.style(ui).w = p.px(panel)
			p.style(ui).h = p.pct(100)
		} else {
			p.style(ui).w = p.pct(100)
			p.style(ui).h = p.px(panel)
		}
		{
			p.div(ui, "p-2 text-sm")
			p.text(ui, labels[i], "whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)

		if i == 0 {
			// handle: w-px (or h-px) bg-border, centred grip when asked for.
			p.div(ui, "relative flex-row items-center justify-center bg-border shrink-0")
			if orientation == .Horizontal {
				p.apply(ui, "w-px h-full")
			} else {
				p.apply(ui, "h-px w-full")
			}
			if with_handle {
				p.div(ui, "h-6 w-1 shrink-0 rounded-lg bg-border")
				p.end(ui)
			}
			p.end(ui)
		}
	}
	return idx
}
