package main

// `installer --shots DIR`: every page, rendered offscreen to PNG, in English,
// French and Arabic.
//
// It runs the demo backend only — fabricated disks, no worker thread, a
// pinned clock — so nothing about the machine it runs on is read beyond
// fonts and the TZif file for the clock, and no two runs differ. The install
// page is drawn from a hand-made Worker snapshot rather than a running fake
// install, so the picture is of a known moment instead of whatever the
// thread had reached.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1280
SHOT_H :: 800

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("installer: could not create %s", dir)
		return 1
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	register_dark_theme()

	// 13 October 2026, 14:05 UTC: a Tuesday, in summer time across Europe.
	pinned_clock = time.unix(1_791_900_300, 0)

	n := 0
	langs := []string{"en_US", "fr_FR", "ar"}
	if only := os.get_env("INSTALLER_SHOT_LANG", context.allocator); only != "" {
		// One language alone, for looking at a single run's layout.
		langs = strings.split(only, ",")
	}
	for lang in langs {
		n += shots_in(off, dir, lang, "")
	}

	// Other output sizes, in English and Arabic: the smallest the installer
	// is meant for and a large one. wm --kiosk gives it whatever the output is.
	if os.get_env("INSTALLER_SHOT_LANG", context.temp_allocator) == "" {
		for size in ([?][2]int{{1024, 768}, {1920, 1200}}) {
			o2 := p.offscreen_create(size.x, size.y, 1, "w-full h-full bg-background text-foreground")
			shot_fonts(&o2.fonts)
			for lang in ([?]string{"en_US", "ar"}) {
				// Not tprintf: every offscreen frame frees the temp allocator.
				n += shots_in(o2, dir, lang, fmt.aprintf("%dx%d-", size.x, size.y))
			}
			p.offscreen_destroy(o2)
		}
	}
	fmt.printfln("installer --shots: %d PNGs in %s", n, dir)
	return unbalanced == 0 ? 0 : 1
}

@(private = "file")
frame :: proc(off: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(off)
	depth := len(ui.stack)
	draw(st, ui)
	if len(ui.stack) != depth {
		// An unbalanced open/end puts every later element in the wrong
		// parent, which renders as a page with half its content missing.
		fmt.eprintfln("installer: page %v left %d elements open", st.page, len(ui.stack) - depth)
		unbalanced += 1
	}
	p.offscreen_end(off)
}

// unbalanced counts frames whose open/end calls did not pair up.
unbalanced: int

@(private = "file")
shoot :: proc(off: ^p.Offscreen, st: ^St, dir, lang, name: string, prefix := "") -> int {
	// Three frames: the first lays out, the second acts on the focus and
	// scroll requests the first made, the third draws the settled result.
	frame(off, st)
	frame(off, st)
	frame(off, st)
	// INSTALLER_DUMP=1 prints the laid-out tree of every shot, which is how a
	// misplaced element is found without guessing at the picture.
	if os.get_env("INSTALLER_DUMP", context.temp_allocator) != "" {
		dump_nodes(&off.ctx, 0, 0)
	}
	short := lang[:2]
	out := fmt.tprintf("%s/%s-%s%s.png", dir, short, prefix, name)
	if p.offscreen_write_png(off, out) {
		fmt.printfln("  %s", out)
		return 1
	}
	return 0
}

@(private = "file")
shots_in :: proc(off: ^p.Offscreen, dir, lang, prefix: string) -> int {
	st := new(St)
	state_init(st, Backend{demo = true})
	for l, i in st.languages {
		if l.code == lang {
			pick_language(st, i)
		}
	}
	n := 0

	n += shoot(off, st, dir, lang, "1-language", prefix)

	move_to(st, .Keyboard)
	append(&st.kb_test, "Bonjour, ça va ? 123")
	n += shoot(off, st, dir, lang, "2-keyboard", prefix)

	move_to(st, .Timezone)
	n += shoot(off, st, dir, lang, "3-timezone", prefix)

	move_to(st, .Disk)
	pick_disk(st, 1)
	n += shoot(off, st, dir, lang, "4-disk", prefix)

	go_next(st) // opens the erase dialog
	n += shoot(off, st, dir, lang, "4b-disk-confirm", prefix)
	confirm_erase(st)

	// The account page twice: once half filled with live problems showing,
	// once complete.
	append(&st.full_name, "Élodie Martin")
	full_name_changed(st)
	append(&st.password, "palm")
	append(&st.confirm, "plam")
	st.touched += {.Full_Name, .Password, .Confirm}
	clear(&st.hostname)
	append(&st.hostname, "-atelier")
	st.touched += {.Hostname}
	n += shoot(off, st, dir, lang, "5-account-problems", prefix)

	clear(&st.password)
	clear(&st.confirm)
	clear(&st.hostname)
	append(&st.password, "correct horse battery")
	append(&st.confirm, "correct horse battery")
	append(&st.hostname, "atelier")
	n += shoot(off, st, dir, lang, "5b-account", prefix)

	go_next(st)
	n += shoot(off, st, dir, lang, "6-summary", prefix)

	// The install, at a fixed moment.
	st.worker = shot_worker(false)
	move_to(st, .Install)
	st.log_open = true
	n += shoot(off, st, dir, lang, "7-install", prefix)

	st.worker = shot_worker(true)
	n += shoot(off, st, dir, lang, "7b-install-failed", prefix)

	st.worker = nil
	move_to(st, .Done)
	n += shoot(off, st, dir, lang, "8-done", prefix)
	return n
}

// shot_worker is a Worker frozen partway through the packages, or failed
// there, with the log the demo install would have written up to that point.
@(private = "file")
shot_worker :: proc(failed: bool) -> ^Worker {
	w := new(Worker)
	w.backend = Backend{demo = true}
	for line in ([?]string {
		"demo: would write a fresh GPT to /dev/vda (nothing is written)",
		"demo: partition 1  EFI system  512 MiB  start 1 MiB",
		"demo: partition 2  Linux root  rest of the disk",
		"demo: would run mkfs.fat -F32 -n PALMEFI /dev/vda1",
		"demo: would run mkfs.ext4 -F -L palmroot /dev/vda2",
		"demo: would mount the root at /mnt/target and the ESP at /mnt/target/boot/efi",
		"demo: palm add filesystem (1/21)",
		"demo: palm add glibc (2/21)",
		"demo: palm add busybox (3/21)",
		"demo: palm add palm-init (4/21)",
		"demo: palm add palm (5/21)",
		"demo: palm add palm-login (6/21)",
		"demo: palm add fonts (7/21)",
		"demo: palm add xkeyboard-config (8/21)",
		"demo: palm add tzdata (9/21)",
		"demo: palm add libxkbcommon (10/21)",
	}) {
		append(&w.log, strings.clone(line))
	}
	w.progress = Progress{step = .Packages, fraction = overall_fraction(.Packages, 9.0 / 21.0), message = w.log[len(w.log) - 1]}
	if failed {
		w.finished = true
		w.ok = false
		w.err = "demo: palm exited with status 1 (simulated by --demo-fail)"
		append(&w.log, fmt.aprintf("error: %s", w.err))
	}
	return w
}

// shot_fonts loads the faces exactly as kit.start does.
shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
}

dump_nodes :: proc(ctx: ^p.Ctx, idx, depth: int) {
	if depth > 14 { return }
	n := ctx.nodes[idx]
	fmt.printfln("%*s%d %v %v %q", depth*2, "", idx, n.kind, n.rect, n.text)
	for c := n.first_child; c >= 0; c = ctx.nodes[c].next {
		dump_nodes(ctx, c, depth + 1)
	}
}
