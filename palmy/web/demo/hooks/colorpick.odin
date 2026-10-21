package main

// The replay hook for apps/colorpick: kit.start's font and theme setup, then
// main's own, then the body of its frame loop, against an Offscreen. Keep in
// step with apps/colorpick/main.odin and apps/kit/kit.odin (`start`).
//
// Run the replay with HOME pointing at an empty directory: the web build has
// no saved palette and no wm.conf, so neither may the native one. The
// external tools (wl-copy, grim, hyprctl) are absent on the web -- there is no
// subprocess -- and are set absent here too.

import "core:fmt"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

@(private = "file")
g_st: St

Replay_Hook :: struct {
	root_class: string,
	setup:      proc(o: ^p.Offscreen),
	frame:      proc(ui: ^p.Ctx),
}

replay_hook :: proc() -> Replay_Hook {
	return {
		root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		setup = proc(o: ^p.Offscreen) {
			// kit.start
			for pair in ([?]struct {
				file: string,
				wt:   p.Font_Weight,
			}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
				p.load_font(&o.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
			}
			for wt in p.Font_Weight {
				p.use_synthetic_italic(&o.fonts, .Sans, wt)
			}
			for path in ([?]string {
				"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
				"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
				"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
			}) {
				if p.load_font(&o.fonts, path, .Mono, .Regular) {
					p.load_font(&o.fonts, path, .Mono, .Medium)
					p.load_font(&o.fonts, path, .Mono, .Semibold)
					p.load_font(&o.fonts, path, .Mono, .Bold)
					break
				}
			}
			sc.register_shadcn_theme(kit.system_theme_dark())
			p.set_text_gamma(1.8)

			// main
			register_dark_theme()
			g_st = St {
				rgb     = {0x3b / 255.0, 0x82 / 255.0, 0xf6 / 255.0},
				zoom    = 12,
				palette = make([dynamic][3]u8),
			}
			for i in 0 ..< FIELD_N {
				g_st.bufs[i] = make([dynamic]u8)
			}
			resync(&g_st, .Hex)
			g_st.hex_caret = len(g_st.bufs[0])
			load_palette(&g_st)
		},
		frame = proc(ui: ^p.Ctx) {
			st := &g_st
			free_all(context.temp_allocator)
			handle_keys(ui, nil, st)
			switch st.mode {
			case .Editor:
				build_editor(ui, st)
			case .Screen:
				build_screen(ui, st)
			}
			if st.toast != "" {
				if mono() > st.toast_t {
					st.toast = ""
				} else {
					p.wake_after(ui, secs(st.toast_t - mono()))
				}
			}
		},
	}
}
