package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_chart_cases :: proc "contextless" () {
	add_case("chart-bar", proc(ui: ^p.Ctx) {
		sc.chart_open(ui)
		defer sc.chart_end(ui)

		// y domain [0,180] over y 5..157, recharts' five default ticks.
		sc.chart_grid(ui, 5, 375, {5, 43, 81, 119, 157})
		sc.chart_bars(
			ui,
			{
				{14.25, 55.667, 35, 101.333, "bg-chart-1"},
				{106.75, 30.333, 35, 126.667, "bg-chart-1"},
				{199.25, 81.000, 35, 76.000, "bg-chart-1"},
				{291.75, 13.444, 35, 143.556, "bg-chart-1"},
				{53.25, 89.444, 35, 67.556, "bg-chart-2"},
				{145.75, 76.778, 35, 80.222, "bg-chart-2"},
				{238.25, 97.889, 35, 59.111, "bg-chart-2"},
				{330.75, 55.667, 35, 101.333, "bg-chart-2"},
			},
		)
		CENTRES := [4]f32{51.25, 143.75, 236.25, 328.75}
		MONTHS := [4]string{"Jan", "Feb", "Mar", "Apr"}
		for m, i in MONTHS {
			sc.chart_tick(ui, m, CENTRES[i], 161.516)
		}
		sc.chart_legend_item(ui, "Desktop", "bg-chart-1", 125.734, 199)
		sc.chart_legend_item(ui, "Mobile", "bg-chart-2", 202.844, 199)
	})
	add_case("chart-line", proc(ui: ^p.Ctx) {
		sc.chart_open(ui)
		defer sc.chart_end(ui)

		// Same domain, but the plot box runs to y 185 without a legend, so
		// one unit is exactly one pixel: y = 185 - value.
		sc.chart_grid(ui, 5, 375, {5, 50, 95, 140, 185})
		sc.chart_lines(
			ui,
			{
				{
					{{5, 65}, {128.333, 35}, {251.667, 95}, {375, 15}},
					p.hex(0xd4d4d4),
				},
				{
					{{5, 105}, {128.333, 90}, {251.667, 115}, {375, 65}},
					p.hex(0x737373),
				},
			},
		)
		sc.chart_tick(ui, "Feb", 128.333, 189.516)
		sc.chart_tick(ui, "Mar", 251.890, 189.516)
		sc.chart_tick(ui, "Apr", 370.880, 189.516)
	})
}
