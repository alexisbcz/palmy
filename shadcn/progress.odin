package shadcn

// Progress, from app/components/ui/progress.tsx.
//
// The root is `flex flex-wrap gap-3`: the label and value share the first flex
// line and the full-width track wraps onto the second. That is a column of
// [label row][track] with the same 12px gap.

import "core:math"
import p "palmy:."

progress_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.col(ui, "gap-3")
	p.apply(ui, class)
	return idx
}

progress_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// progress_header is the first flex line: `text-sm font-medium` label on the
// left and an `ml-auto` value on the right.
progress_header :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full items-center justify-between")
	defer p.end(ui)

	p.text(ui, label, "text-sm font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, value, "text-sm text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// PROGRESS_SWEEP is how much of the track an indeterminate run covers, as a
// percentage, and PROGRESS_PERIOD is how long one pass takes in seconds.
PROGRESS_SWEEP :: f32(35)
PROGRESS_PERIOD :: f32(1.6)

// progress_track is `relative flex h-1 w-full items-center overflow-x-hidden
// rounded-full bg-muted` with an `h-full bg-primary` indicator.
//
// `indeterminate` is the other state the ARIA role has: work that is really
// happening but whose size is not known yet, which the browser draws as a
// short run sweeping the track rather than a bar with a position. `percent` is
// ignored then. A call that does not ask for it is untouched — this stays a
// display component, and the sweep is the only thing in it that moves.
progress_track :: proc(ui: ^p.Ctx, percent: f32, indeterminate := false) {
	p.div(ui, "relative flex-row h-1 w-full items-center overflow-hidden rounded-full bg-muted")
	defer p.end(ui)

	if indeterminate {
		// The run is positioned from both edges rather than given a width, so
		// that it grows in at the start of a pass and shrinks out at the end
		// instead of appearing and vanishing whole. smoothstep is the easing;
		// a linear sweep reads as a conveyor belt.
		t := math.mod_f32(f32(ui.now), PROGRESS_PERIOD) / PROGRESS_PERIOD
		e := t * t * (3 - 2 * t)
		left := e * (100 + PROGRESS_SWEEP) - PROGRESS_SWEEP

		p.div(ui, "absolute h-full bg-primary rounded-full")
		s := p.style(ui)
		s.inset[p.TOP] = p.px(0)
		s.inset[p.BOTTOM] = p.px(0)
		s.inset[p.LEFT] = p.pct(max(0, left))
		s.inset[p.RIGHT] = p.pct(max(0, 100 - (left + PROGRESS_SWEEP)))
		p.end(ui)

		// Without this the frame loop would sleep and the sweep would be a
		// still picture of a bar at an arbitrary place, which is worse than
		// no animation at all.
		ui.animating = true
		return
	}

	p.div(ui, "h-full bg-primary")
	p.style(ui).w = p.pct(percent)
	p.end(ui)
}
