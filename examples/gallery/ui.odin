package main

import "core:fmt"
import p "../../palmy"

// The whole interface is one procedure. It runs top to bottom every frame, and
// the only state that survives between frames is what you keep yourself.
State :: struct {
	tab:        int,
	notify:     bool,
	compact:    bool,
	volume:     f32,
	density:    f32,
	name:       [dynamic]u8,
	picked:     int,
	plasma:     Plasma,
}

TABS := [?]string{"Components", "Colors", "Type"}

build :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "w-full h-full")
	defer p.end(ui)

	sidebar(ui, st)

	// Main column.
	p.col(ui, "flex-1 h-full overflow-hidden")
	{
		defer p.end(ui)
		header(ui, st)

		p.col(ui, "flex-1 overflow-scroll p-6 gap-6")
		{
			defer p.end(ui)
			switch st.tab {
			case 0:
				components_tab(ui, st)
			case 1:
				colors_tab(ui)
			case 2:
				type_tab(ui)
			}
		}
	}
}

sidebar :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-56 h-full shrink-0 bg-slate-900 border-r border-slate-800 p-4 gap-1")
	defer p.end(ui)

	p.row(ui, "items-center gap-2.5 px-2 pb-5")
	{
		defer p.end(ui)
		p.div(ui, "size-7 rounded-lg bg-gradient-to-b from-indigo-400 to-indigo-600 shadow-sm")
		p.end(ui)
		p.text(ui, "palmy", "text-lg font-bold text-white tracking-tight")
	}

	for label, i in TABS {
		p.key(ui, label)
		active := st.tab == i
		class := "flex-row items-center gap-3 px-3 py-2 rounded-lg transition text-sm hover:bg-slate-800 text-slate-400"
		if active {
			class = "flex-row items-center gap-3 px-3 py-2 rounded-lg transition text-sm bg-slate-800 text-white font-semibold"
		}
		p.div(ui, class)
		if p.clickable(ui) {
			st.tab = i
		}
		p.div(ui, "size-1.5 rounded-full bg-indigo-400")
		p.style(ui).hidden = !active
		p.end(ui)
		p.text(ui, label)
		p.end(ui)
	}

	p.spacer(ui)

	p.col(ui, "gap-1 p-3 rounded-xl bg-slate-950 border border-slate-800")
	{
		defer p.end(ui)
		p.text(ui, "Pure Odin", "text-xs font-semibold text-slate-300")
		p.text(ui, "No libwayland, no GPU, no toolkit.", "text-xs text-slate-500")
	}
}

header :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "items-center gap-4 px-6 h-16 shrink-0 border-b border-slate-800 bg-slate-900")
	defer p.end(ui)

	p.text(ui, TABS[st.tab], "text-base font-semibold text-white")
	p.spacer(ui)
	p.textf(ui, "text-xs text-slate-500 font-mono whitespace-nowrap", "%.0f fps", p.frames_per_second(ui))
	p.div(ui, "w-px h-5 bg-slate-800")
	p.end(ui)
	p.toggle(ui, &st.notify)
	p.text(ui, "Notifications", "text-sm text-slate-400")
}

components_tab :: proc(ui: ^p.Ctx, st: ^State) {
	// Buttons.
	card(ui, "Buttons")
	{
		defer p.end(ui)
		p.row(ui, "gap-3 flex-wrap")
		{
			defer p.end(ui)
			p.button(ui, "Primary", "bg-indigo-500 hover:bg-indigo-400 active:bg-indigo-600 border-indigo-400 text-white")
			p.button(ui, "Secondary")
			p.button(ui, "Ghost", "bg-transparent border-transparent hover:bg-slate-800 text-slate-300")
			p.button(ui, "Danger", "bg-rose-500/15 hover:bg-rose-500/25 border-rose-500/40 text-rose-300")
			p.button(ui, "Disabled", "", true)
		}
	}

	// Inputs.
	card(ui, "Inputs")
	{
		defer p.end(ui)
		p.row(ui, "gap-6 items-start")
		{
			defer p.end(ui)

			p.col(ui, "flex-1 gap-3")
			{
				defer p.end(ui)
				p.text(ui, "Display name", "text-xs font-semibold text-slate-400")
				p.text_field(ui, &st.name, "Ada Lovelace")

				p.row(ui, "items-center gap-3 pt-1")
				{
					defer p.end(ui)
					p.text(ui, "Volume", "text-xs text-slate-400 w-16")
					p.slider(ui, &st.volume, 0, 100)
					p.textf(ui, "text-xs font-mono text-slate-300 w-10 text-right", "%.0f", st.volume)
				}
				p.row(ui, "items-center gap-3")
				{
					defer p.end(ui)
					p.text(ui, "Density", "text-xs text-slate-400 w-16")
					p.slider(ui, &st.density, 0, 1)
					p.textf(ui, "text-xs font-mono text-slate-300 w-10 text-right", "%.2f", st.density)
				}
			}

			p.col(ui, "w-56 gap-3")
			{
				defer p.end(ui)
				p.text(ui, "Options", "text-xs font-semibold text-slate-400")
				p.checkbox(ui, "Compact layout", &st.compact)
				p.checkbox(ui, "Send notifications", &st.notify)
				p.text(ui, "Upload", "text-xs font-semibold text-slate-400 pt-2")
				p.progress(ui, st.volume / 100)
			}
		}
	}

	// Selection list plus a live pixel panel, side by side.
	p.row(ui, "gap-6 items-stretch")
	{
		defer p.end(ui)

		p.col(ui, "flex-1 gap-4 p-5 rounded-xl bg-slate-900 border border-slate-800")
		{
			defer p.end(ui)
			p.text(ui, "Workspaces", "text-sm font-semibold text-white")
			names := [?]string{"Design", "Engineering", "Marketing", "Research"}
			counts := [?]int{12, 148, 7, 31}
			for name, i in names {
				p.key(ui, name)
				selected := st.picked == i
				class := "flex-row items-center gap-3 px-3 py-2.5 rounded-lg transition hover:bg-slate-800"
				if selected {
					class = "flex-row items-center gap-3 px-3 py-2.5 rounded-lg transition bg-indigo-500/15 border border-indigo-500/40"
				}
				p.div(ui, class)
				if p.clickable(ui) {
					st.picked = i
				}
				p.div(ui, "size-8 rounded-lg bg-slate-800 items-center justify-center shrink-0")
				p.textf(ui, "text-xs font-bold text-slate-300", "%c", name[0])
				p.end(ui)
				p.col(ui, "flex-1 gap-0.5")
				p.text(ui, name, "text-sm text-slate-100")
				p.textf(ui, "text-xs text-slate-500", "%d members", counts[i])
				p.end(ui)
				p.text(ui, "›", "text-slate-600 text-lg")
				p.end(ui)
			}
		}

		p.col(ui, "w-80 gap-3 p-5 rounded-xl bg-slate-900 border border-slate-800")
		{
			defer p.end(ui)
			p.row(ui, "items-center gap-2")
			{
				defer p.end(ui)
				p.text(ui, "Raw pixels", "text-sm font-semibold text-white")
				p.spacer(ui)
				p.text(ui, "canvas", "text-[10] font-mono px-1.5 py-0.5 rounded bg-slate-800 text-slate-400")
			}
			st.plasma.t += p.delta_time(ui)
			st.plasma.warp = st.density
			p.pixels(ui, "flex-1 min-h-[150] rounded-lg overflow-hidden", &st.plasma, draw_plasma)
			p.text(ui, "The same buffer the UI is drawn into.", "text-xs text-slate-500")
		}
	}
}

colors_tab :: proc(ui: ^p.Ctx) {
	card(ui, "The Tailwind palette, exactly")
	defer p.end(ui)

	for hue in p.HUES {
		p.key(ui, hue.name)
		p.row(ui, "items-center gap-3")
		defer p.end(ui)
		p.text(ui, hue.name, "w-20 text-xs font-mono text-slate-400 shrink-0")
		p.row(ui, "flex-1 gap-1")
		defer p.end(ui)
		for shade, i in hue.shades {
			p.key(ui, fmt.tprintf("%d", i))
			p.div(ui, "flex-1 h-8 rounded-md")
			p.style(ui).bg = p.flat(p.hex(shade))
			p.end(ui)
		}
	}
}

type_tab :: proc(ui: ^p.Ctx) {
	card(ui, "Type scale")
	{
		defer p.end(ui)
		sizes := [?]string{"text-xs", "text-sm", "text-base", "text-lg", "text-xl", "text-2xl", "text-3xl", "text-4xl"}
		for s in sizes {
			p.key(ui, s)
			p.row(ui, "items-baseline gap-4")
			defer p.end(ui)
			p.text(ui, s, "w-20 shrink-0 text-xs font-mono text-slate-500")
			p.text(ui, "Grumpy wizards make toxic brew", s)
		}
	}

	card(ui, "Paragraphs wrap")
	{
		defer p.end(ui)
		p.text(
			ui,
			"Text measures with real font metrics and breaks on word boundaries, " +
			"so a paragraph in a narrow column behaves the way you would expect " +
			"from a browser. Line height follows the Tailwind scale, and tracking, " +
			"weight and alignment are all just classes.",
			"max-w-[640] text-sm text-slate-400 leading-relaxed",
		)
		p.text(ui, "Centred, wide tracking, uppercase", "pt-2 text-xs tracking-widest uppercase text-indigo-300 text-center")
	}
}

// card opens a titled panel. The caller closes it with p.end.
card :: proc(ui: ^p.Ctx, title: string) {
	p.col(ui, "gap-4 p-5 rounded-xl bg-slate-900 border border-slate-800 shrink-0")
	p.text(ui, title, "text-sm font-semibold text-white")
}
