package main

// `drive shots <dir>`: render the window offscreen into PNGs.
//
// Unlike most apps' shots this one is not drawn from a fabricated fixture:
// it talks to the drive the configuration points at, so what the pictures
// show is what the server answered. cloud/drive/dev/demo.sh fills the dev
// stack with the content they were taken against.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import dc "drive:core"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1240
SHOT_H :: 780

shots :: proc(dir: string) -> int {
	cfg, err := dc.load_config(dc.config_path())
	if err != "" || len(cfg.identities) == 0 {
		fmt.eprintfln("drive: %s", err)
		return -1
	}
	os.make_directory_all(dir)

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)

	st := new(State)
	st.cfg = cfg
	st.view = .List
	st.inspector = true
	st.now = time.now()

	work := 0
	for id, i in cfg.identities {
		if id.kind == "work" {
			work = i
		}
	}
	select_identity(st, work)
	if st.offline != "" {
		return -1
	}

	// Transitions run on the clock, so a picture taken two frames after a
	// change catches a colour half way. Let them finish first.
	step :: proc(off: ^p.Offscreen, st: ^State) {
		for i in 0 ..< 8 {
			if i % 2 == 1 {
				time.sleep(250 * time.Millisecond)
			}
			ui := p.offscreen_begin(off)
			measure(ui, st)
			handle_keys(ui, st, nil)
			frame(ui, st)
			p.offscreen_end(off)
		}
	}
	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.eprintfln("  %s", out)
		}
	}
	pick :: proc(st: ^State, name: string) {
		for r, i in st.rows {
			if r.item.name == name {
				st.sel = i
			}
		}
	}

	// 1. The work drive, a shared folder selected.
	pick(st, "Q3 Board pack")
	step(off, st)
	shot(off, dir, "01-drive-list", &n)

	// 2. Inside a folder of images, as a grid, with the synced copies as
	//    thumbnails.
	pick(st, "Design")
	open_row(st)
	st.view = .Grid
	pick(st, "palmframe-poster.jpg")
	step(off, st)
	shot(off, dir, "02-drive-grid", &n)

	// 3. The share dialog on the board pack.
	st.view = .List
	go_crumb(st, 0)
	pick(st, "Q3 Board pack")
	st.dialog = .Share
	st.share_role = "viewer"
	st.share_sel = -1
	clear(&st.field)
	append(&st.field, "carol")
	st.detail_id = ""
	step(off, st)
	shot(off, dir, "03-share-dialog", &n)
	st.dialog = .None

	// 4. Switching identity.
	st.dialog = .Identity
	st.ident_sel = st.ident
	step(off, st)
	shot(off, dir, "04-identity-switcher", &n)
	st.dialog = .None

	// 5. Search across the drive.
	clear(&st.query)
	append(&st.query, "budget")
	st.section = .Search
	reload(st)
	step(off, st)
	shot(off, dir, "05-search", &n)
	clear(&st.query)

	// 6. The trash.
	go_section(st, .Trash)
	step(off, st)
	shot(off, dir, "06-trash", &n)

	// 7. The personal identity: another drive, another colour.
	for id, i in cfg.identities {
		if id.kind == "personal" {
			select_identity(st, i)
			break
		}
	}
	st.view = .Grid
	step(off, st)
	shot(off, dir, "07-personal-grid", &n)

	// 8. Bob's view: what alice.northwind shared with him.
	bob := os.get_env("PALM_DRIVE_SHOT_BOB", context.temp_allocator)
	if bob != "" {
		bcfg, berr := dc.load_config(bob)
		if berr == "" && len(bcfg.identities) > 0 {
			st.cfg = bcfg
			select_identity(st, 0)
			st.view = .List
			go_section(st, .Shared)
			step(off, st)
			shot(off, dir, "08-shared-with-bob", &n)
		}
	}
	return n
}

shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
			file: string,
			wt:   p.Font_Weight,
		}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf"}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
	_ = strings.clone
}
