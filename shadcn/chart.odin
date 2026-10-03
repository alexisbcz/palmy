package shadcn

// Chart, from app/components/ui/chart.tsx wrapping recharts.
//
// recharts emits SVG, so there is nothing to translate class-for-class: the
// capture's own geometry is the specification. Every number below is read off
// out/web/chart-*.json, or derived from the scales those numbers imply —
// a y domain of [0, 180] over the plot box, four category bands of 92.5px, and
// recharts' default five y ticks, which is where the grid lines come from.
//
// Bars and grid lines are ordinary palmy boxes so the rasteriser handles their
// rounded corners and fractional edges; the line chart's polylines go through
// `p.pixels`, since a diagonal stroke is not a box.

import p "palmy:."

CHART_W :: f32(380)
CHART_H :: f32(220)

Chart_Bar :: struct {
	x, y, w, h: f32,
	fill:       string,
}

Chart_Poly :: struct {
	pts: [4][2]f32,
	col: p.Color,
}

Chart_Polys :: struct {
	n:     int,
	lines: [2]Chart_Poly,
}

@(private = "file")
polys: Chart_Polys

@(private = "file")
draw_polys :: proc(c: ^p.Canvas, r: p.Rect, s: ^Chart_Polys) {
	for i in 0 ..< s.n {
		l := s.lines[i]
		for j in 0 ..< 3 {
			p.draw_line(
				c,
				r.x + l.pts[j].x,
				r.y + l.pts[j].y,
				r.x + l.pts[j + 1].x,
				r.y + l.pts[j + 1].y,
				1,
				l.col,
			)
		}
	}
}

// chart_open is the `ChartContainer`: `flex aspect-video justify-center
// text-xs` at the size the case pins it to.
chart_open :: proc(ui: ^p.Ctx) -> int {
	idx := p.div(ui, "relative text-xs")
	st := p.style(ui)
	st.w = p.px(CHART_W)
	st.h = p.px(CHART_H)
	return idx
}

chart_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

@(private = "file")
abs_box :: proc(ui: ^p.Ctx, class: string, x, y, w, h: f32) -> int {
	idx := p.div(ui, class)
	st := p.style(ui)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(x)
	st.inset[p.TOP] = p.px(y)
	st.w = p.px(w)
	st.h = p.px(h)
	return idx
}

// chart_grid draws `CartesianGrid vertical={false}`: one 1px line per y tick,
// in `stroke-border/50`. An SVG line of width 1 centred on an integer sits
// half in each neighbouring row, which is what the half-pixel offset is for.
chart_grid :: proc(ui: ^p.Ctx, x0, x1: f32, ys: []f32) {
	for y in ys {
		abs_box(ui, "bg-border/50", x0, y - 0.5, x1 - x0, 1)
		p.end(ui)
	}
}

chart_bars :: proc(ui: ^p.Ctx, bars: []Chart_Bar) {
	for b in bars {
		abs_box(ui, "rounded-[4]", b.x, b.y, b.w, b.h)
		p.apply(ui, b.fill)
		p.end(ui)
	}
}

// chart_tick is one x-axis tick label. recharts centres the label on the
// category band, so the centre is what is passed in.
chart_tick :: proc(ui: ^p.Ctx, label: string, cx, y: f32) {
	abs_box(ui, "text-center", cx - 40, y, 80, 16)
	p.text(ui, label, "text-xs text-muted-foreground whitespace-nowrap w-full text-center")
	p.style(ui).shrink = 0
	p.end(ui)
}

// chart_legend_item is one `ChartLegendContent` entry: an 8px swatch with
// `rounded-[2px]`, then the series label.
chart_legend_item :: proc(ui: ^p.Ctx, label: string, swatch: string, x, y: f32) {
	abs_box(ui, "flex-row items-center gap-1.5", x, y, 80, 16)
	{
		p.div(ui, "size-2 shrink-0 rounded-[2]")
		p.apply(ui, swatch)
		p.end(ui)
		p.text(ui, label, "text-xs whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)
}

// chart_lines draws the `Line` series as polylines through `p.pixels`.
chart_lines :: proc(ui: ^p.Ctx, lines: []Chart_Poly) {
	polys.n = len(lines)
	for l, i in lines {
		polys.lines[i] = l
	}
	p.pixels(ui, "", &polys, draw_polys)
	st := p.style(ui)
	st.position = .Absolute
	st.inset[p.LEFT] = p.px(0)
	st.inset[p.TOP] = p.px(0)
	st.w = p.px(CHART_W)
	st.h = p.px(CHART_H)
}
