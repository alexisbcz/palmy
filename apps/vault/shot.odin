package main

// `vault --shot <dir>`: render the screens offscreen as PNGs.
//
// Checking a layout by recording a video takes a minute; checking it this way
// takes a second, and it is the same build path the window uses. The vault it
// opens is the demo fixture, so no real entry can reach an image either.

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("vault: could not create %s", dir)
		return 1
	}
	path := strings.clone(fmt.tprintf("%s/shot.pvz", dir))
	if !make_demo_vault(path) {
		return 1
	}

	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	register_theme()

	st := St {
		path       = strings.clone(path),
		screen     = .Unlock,
		pw         = make([dynamic]u8),
		pw2        = make([dynamic]u8),
		query      = make([dynamic]u8),
		rows       = make([dynamic]int),
		mp_new     = make([dynamic]u8),
		mp_again   = make([dynamic]u8),
		gen        = GEN_DEFAULT,
		idle_limit = 300,
		clip_limit = 20,
		focus_pw   = true,
		have_clip  = true,
	}
	for f in Field {
		st.ed[f] = make([dynamic]u8)
	}
	defer shutdown(&st)

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		frame(ui, nil, st)
		p.offscreen_end(off)
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		p.offscreen_write_png(off, out)
		fmt.printfln("  %s", out)
	}

	step(off, &st)
	p.type_text(off, DEMO_PASSWORD)
	step(off, &st)
	shot(off, dir, "01-locked")

	p.press_key(off, p.KEY_RETURN)
	step(off, &st) // paints the busy state
	shot(off, dir, "02-deriving")
	step(off, &st) // performs the derivation
	step(off, &st)
	shot(off, dir, "03-open")

	// Example Forge carries the RFC 6238 seed, so the code on screen is the
	// published one and nothing private is anywhere near the picture.
	st.sel = 1
	step(off, &st)
	shot(off, dir, "03b-totp")
	st.sel = 0
	step(off, &st)

	p.press_key(off, 'f', {.Ctrl})
	step(off, &st)
	p.type_text(off, "mail")
	step(off, &st)
	step(off, &st)
	shot(off, dir, "04-search")

	clear(&st.query)
	st.sel = 0
	step(off, &st)
	p.press_key(off, 'g', {.Ctrl})
	step(off, &st)
	shot(off, dir, "05-generator")

	p.press_key(off, 'c', {.Ctrl})
	step(off, &st)
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st)
	shot(off, dir, "06-copied")

	st.reveal = true
	st.history = true
	step(off, &st)
	shot(off, dir, "07-revealed")

	st.reveal = false
	p.press_key(off, 'e', {.Ctrl})
	step(off, &st)
	shot(off, dir, "08-editor")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st)

	p.press_key(off, 'm', {.Ctrl})
	step(off, &st)
	shot(off, dir, "09-master")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, &st)

	// Leave nothing behind, including on the clipboard.
	clear_clipboard(&st, "")
	lock(&st, "Locked")
	step(off, &st)
	shot(off, dir, "10-locked-again")
	return 0
}
