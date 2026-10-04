// `mail --uitest <dir>`: drive the real interface through palmy's offscreen
// renderer and write a PNG at each step.
//
// This is the same `frame` and the same `handle_keys` the window runs, with
// synthetic keys in place of a compositor's. It needs no display, no recording
// lock and no `wtype`, so the whole interaction path — selection, expanding a
// thread, scrolling, search, the composer, the send confirmation — can be
// checked at any time and by anyone, which is more than a video can claim.
package main

import "core:fmt"
import "core:os"
import "core:time"
import p "palmy:."
import sc "shadcn:."

UITEST_W :: 1500
UITEST_H :: 940

@(private = "file")
Rig :: struct {
	off: ^p.Offscreen,
	st:  ^State,
	dir: string,
	n:   int,
}

// settle renders a few frames so layout, scrolling and hover all reach a
// steady state, the way they would between two keystrokes from a human.
@(private = "file")
settle :: proc(r: ^Rig, frames := 3) {
	for _ in 0 ..< frames {
		ui := p.offscreen_begin(r.off)
		r.st.now = r.st.now
		handle_keys(ui, r.st, nil)
		frame(ui, r.st)
		apply_scroll(ui, r.st)
		p.offscreen_end(r.off)
	}
}

@(private = "file")
shot :: proc(r: ^Rig, name: string) {
	settle(r)
	r.n += 1
	path := fmt.tprintf("%s/%02d-%s.png", r.dir, r.n, name)
	if p.offscreen_write_png(r.off, path) {
		fmt.printfln("  %s", path)
	} else {
		fmt.eprintfln("  could not write %s", path)
	}
}

@(private = "file")
key :: proc(r: ^Rig, sym: u32, times := 1) {
	for _ in 0 ..< times {
		p.press_key(r.off, sym)
		settle(r, 1)
		settle(r, 1)
	}
}

@(private = "file")
typ :: proc(r: ^Rig, text: string) {
	p.type_text(r.off, text)
	settle(r, 2)
}

run_uitest :: proc(dir: string) -> int {
	os.make_directory_all(dir)

	off := p.offscreen_create(UITEST_W, UITEST_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)

	// The same faces and the same calibration the windowed app gets from the
	// kit; the offscreen renderer has its own font table, so they are loaded
	// into it here rather than reaching into the kit's.
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_FONTS {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))

	st := new(State)
	init_state(st)

	r := Rig {
		off = off,
		st  = st,
		dir = dir,
	}

	fmt.printfln("mail --uitest: %d messages, %d folders, %d accounts", len(st.messages), len(st.folders), len(st.accounts))

	// What a frame of the busiest view actually costs. The list is virtualised
	// — only the rows inside the viewport are built — so this should not grow
	// with the size of the folder, and that is the claim being measured.
	bench :: proc(r: ^Rig, label: string, n: int) {
		start := time.now()
		settle(r, n)
		ms := f64(time.diff(start, time.now())) / 1e6
		fmt.printfln(
			"  %-22s %5.2f ms/frame over %d rows (%.0f fps)",
			label,
			ms / f64(n),
			len(r.st.rows),
			1000.0 / max(ms / f64(n), 0.0001),
		)
	}
	bench(&r, "inbox, collapsed", 60)

	shot(&r, "inbox")

	// Walk the conversation list.
	key(&r, 'j', 5)
	shot(&r, "browse")

	// Open a conversation and step into its messages.
	key(&r, p.KEY_RETURN)
	key(&r, 'j', 2)
	shot(&r, "thread-expanded")

	// Escape collapses the conversation and leaves the keyboard where it was.
	key(&r, p.KEY_ESCAPE)

	// Scroll a few hundred conversations.
	key(&r, p.KEY_PAGE_DOWN, 8)
	shot(&r, "scrolled")
	bench(&r, "inbox, scrolled", 60)
	key(&r, p.KEY_HOME)

	// Search.
	key(&r, '/')
	typ(&r, "quarterly")
	shot(&r, "search")
	key(&r, p.KEY_DOWN)
	shot(&r, "search-hit")
	key(&r, p.KEY_ESCAPE)

	// The HTML fallback.
	key(&r, '/')
	typ(&r, "digest")
	key(&r, p.KEY_DOWN)
	shot(&r, "html-fallback")
	key(&r, p.KEY_ESCAPE)

	// Attachments: the reader's attachment list.
	key(&r, '/')
	typ(&r, "has:attachment")
	key(&r, p.KEY_DOWN)
	shot(&r, "attachments")
	key(&r, p.KEY_ESCAPE)

	// Reply, with typed text.
	key(&r, 'r')
	typ(&r, "Thursday works for me. I will have the revised forecast ready by Wednesday evening.")
	shot(&r, "composer")

	key(&r, p.KEY_TAB)
	key(&r, p.KEY_RETURN)
	shot(&r, "send-confirm")

	key(&r, p.KEY_RETURN)
	shot(&r, "queued")

	// The folder tree, down to the POP3 account that has only an inbox.
	key(&r, 'h')
	shot(&r, "folders")
	key(&r, 'j', 20)
	shot(&r, "pop3-inbox")

	// Raw headers, which is also a look at the Maildir filename and its flags.
	key(&r, 'l')
	key(&r, 'i')
	shot(&r, "headers")

	// The same interface at the width this compositor actually tiles to. Three
	// fixed panes do not fit there, so the folder list becomes a drawer; that
	// is a different layout and it needs looking at, not assuming.
	narrow := p.offscreen_create(941, 1030, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(narrow)
	copy_faces(narrow, off)
	r.off = narrow
	st.pane = .List
	shot(&r, "narrow-list")
	key(&r, 'h')
	shot(&r, "narrow-drawer")
	key(&r, p.KEY_ESCAPE)

	fmt.printfln("mail --uitest: wrote %d frames", r.n)
	return 0
}

// copy_faces loads the same font files into a second offscreen renderer; each
// one owns its own font table.
@(private = "file")
copy_faces :: proc(dst, src: ^p.Offscreen) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&dst.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_FONTS {
		if p.load_font(&dst.fonts, path, .Mono, .Regular) {
			break
		}
	}
}
