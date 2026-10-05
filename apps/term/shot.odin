package main

import "core:fmt"
import "core:os"
import "core:time"
import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// Headless screenshots.
//
// The same tree the window builds, rendered into a buffer and written out as
// a PNG. It is how the terminal is looked at without putting anything on
// anybody's screen, and it is the thing that catches a grid that asserts
// correct and draws wrong.
//
// Every command run here is written out in this file. Nothing reads the
// person's files, their shell configuration or their history.
// ---------------------------------------------------------------------------

SHOT_SCRIPTS := [?]struct {
	name: string,
	cmd:  string,
} {
	{
		"colors",
		`printf '\033[1mpalmy-term\033[0m \033[2mthe 16 colours, 256 and true colour\033[0m\n\n'
		 for i in 0 1 2 3 4 5 6 7; do printf "\033[4%sm  \033[0m" "$i"; done; printf '  '
		 for i in 0 1 2 3 4 5 6 7; do printf "\033[10%sm  \033[0m" "$i"; done; printf '\n'
		 i=16; while [ $i -lt 124 ]; do printf "\033[48;5;%dm \033[0m" $i; i=$((i+1)); done; printf '\n'
		 r=0; while [ $r -lt 240 ]; do printf "\033[48;2;%d;80;160m \033[0m" $r; r=$((r+8)); done; printf '\n\n'
		 printf '\033[1mbold\033[0m \033[2mdim\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m \033[4:3munder curly\033[0m \033[9mstrike\033[0m \033[7mreverse\033[0m\n'
		 printf '\033[38;2;244;114;182mtrue colour text\033[0m  \033[58;2;244;114;182m\033[4:3mcoloured underline\033[0m\n\n'
		 printf 'CJK  \346\227\245\346\234\254\350\252\236 \344\270\255\346\226\207 \355\225\234\352\265\255\354\226\264\n'
		 printf 'emoji  \360\237\214\264 \360\237\232\200 \342\234\205 \360\237\216\250\n'
		 printf 'marks  e\314\201 a\314\212 o\314\210   arabic \330\247\331\204\330\271\330\261\330\250\331\212\330\251\n'
		 sleep 5`,
	},
	{
		"attrs",
		`printf 'tab stops:\ta\tb\tc\n'
		 printf '\033[4mAunderline\033[0m \033[53moverline\033[0m \033[21mdouble\033[0m\n'
		 printf 'plain line, nothing set\n'
		 printf '\033[4:1msingle\033[0m \033[4:2mdouble\033[0m \033[4:3mcurly\033[0m \033[4:4mdotted\033[0m \033[4:5mdashed\033[0m\n'
		 sleep 5`,
	},
	{
		"boxes",
		`printf '\033[1mline drawing, the way ncurses does it\033[0m\n\n'
		 printf '\033(0lqqqqqqqqqqqqqqqqqqqqqwqqqqqqqqqqqqqqqqqqqk\033(B\n'
		 printf '\033(0x\033(B \033[36m%-19s\033[0m \033(0x\033(B \033[33m%-17s\033[0m \033(0x\033(B\n' file size
		 printf '\033(0tqqqqqqqqqqqqqqqqqqqqqnqqqqqqqqqqqqqqqqqqqu\033(B\n'
		 printf '\033(0x\033(B %-19s \033(0x\033(B %-17s \033(0x\033(B\n' main.odin '12.4 kB'
		 printf '\033(0x\033(B %-19s \033(0x\033(B %-17s \033(0x\033(B\n' terminal.odin '31.0 kB'
		 printf '\033(0mqqqqqqqqqqqqqqqqqqqqqvqqqqqqqqqqqqqqqqqqqj\033(B\n\n'
		 printf 'tab stops:\ta\tb\tc\n'
		 printf '\033[4munderline\033[0m \033[53moverline\033[0m \033[21mdouble\033[0m\n'
		 sleep 5`,
	},
}

shots :: proc(dir: string, opt: Options, verbose: bool) -> (files: []string, code: int) {
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {
			return nil, 7
		}
	}
	out := make([dynamic]string)

	W :: 1000
	H :: 620

	o := p.offscreen_create(W, H, 1, "w-full h-full bg-slate-950 text-slate-200")
	defer p.offscreen_destroy(o)
	o.input.focused = true

	a := Term_App {
		font_size   = opt.font_size <= 0 ? 14 : opt.font_size,
		always_tabs = true,
		blink_on    = true,
		focused     = true,
	}
	a.rend.fonts = &o.fonts
	a.zombies = make([dynamic]^Tab)
	renderer_metrics(&a.rend, a.font_size, 1)
	session_init(&a.sess, 80, 24, 2000, opt.term, default_shell())
	defer session_destroy(&a.sess)
	if !pump_start(&a.pump, &a.sess) {
		return nil, 7
	}
	defer pump_stop(&a.pump)

	for s in SHOT_SCRIPTS {
		if _, e := tab_open(&a.sess, []string{"/bin/sh", "-c", s.cmd}); e != "" {
			return nil, 7
		}
	}

	for s, idx in SHOT_SCRIPTS {
		a.sess.active = idx
		// Let the script run and the grid fill before the picture is taken.
		deadline := time.now()
		for time.since(deadline) < 900 * time.Millisecond {
			time.sleep(10 * time.Millisecond)
		}
		a.rend.full = true
		ui := p.offscreen_begin(o)
		frame(&a, ui)
		p.offscreen_end(o)
		path := fmt.aprintf("%s/term-%s.png", dir, s.name)
		if p.offscreen_write_png(o, path) {
			append(&out, path)
			if verbose {
				fmt.printfln("wrote %s", path)
			}
		}
	}
	for t in a.sess.tabs {
		tab_request_close(t)
	}
	if len(out) != len(SHOT_SCRIPTS) {
		return out[:], 7
	}
	return out[:], 0
}

// shot_of renders one terminal's grid on its own, which the self-test and
// the manual checks use to look at a specific piece of output.
shot_of :: proc(t: ^vt.Terminal, fonts: ^p.Fonts, size: f32, path: string) -> bool {
	r := Grid_Renderer {
		fonts = fonts,
	}
	renderer_metrics(&r, size, 1)
	renderer_resize(&r, t.cols, t.rows)
	defer renderer_destroy(&r)
	renderer_draw(&r, t, {}, true, true)

	o := p.offscreen_create(r.w, r.h, 1, "w-full h-full bg-slate-950")
	defer p.offscreen_destroy(o)
	ui := p.offscreen_begin(o)
	p.pixels(ui, "w-full h-full", &r, proc(c: ^p.Canvas, rect: p.Rect, rr: ^Grid_Renderer) {
		renderer_blit(rr, c, rect)
	})
	p.offscreen_end(o)
	return p.offscreen_write_png(o, path)
}
