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
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

UITEST_W :: 1500
UITEST_H :: 940

@(private = "file")
Rig :: struct {
	off:   ^p.Offscreen,
	st:    ^State,
	dir:   string,
	n:     int,

	// Filming: every rendered frame is written, numbered, so the sequence can
	// be encoded into a video. The recording harness serialises on a lock that
	// a dozen agents are queued on, and `wtype` cannot be used off it; this
	// path needs no compositor at all and renders at whatever size is asked
	// for rather than whatever the tiler decides.
	film:  bool,
	frame: int,
}

// settle renders a few frames so layout, scrolling and hover all reach a
// steady state, the way they would between two keystrokes from a human.
@(private = "file")
settle :: proc(r: ^Rig, frames := 3) {
	for _ in 0 ..< frames {
		ui := p.offscreen_begin(r.off)
		handle_keys(ui, r.st, nil)
		frame(ui, r.st)
		apply_scroll(ui, r.st)
		p.offscreen_end(r.off)
		if r.film {
			r.frame += 1
			p.offscreen_write_png(r.off, fmt.tprintf("%s/f%05d.png", r.dir, r.frame))
		}
	}
}

// hold renders the current state for a while, so a viewer has time to read it.
@(private = "file")
hold :: proc(r: ^Rig, seconds: f32) {
	if !r.film {
		return
	}
	settle(r, int(seconds * WALKTHROUGH_FPS))
}

WALKTHROUGH_FPS :: 20

@(private = "file")
shot :: proc(r: ^Rig, name: string) {
	settle(r)
	if r.film {
		hold(r, 1.6)
		r.n += 1
		return
	}
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
		hold(r, 0.22)
	}
}

// chord is `key` with a modifier held, for the two commands that have one:
// Shift+V walks the attachments backwards and Shift+D is the irreversible
// delete, which is behind a modifier precisely because it is irreversible.
@(private = "file")
chord :: proc(r: ^Rig, sym: u32, mods: p.Modifiers) {
	p.press_key(r.off, sym, mods)
	settle(r, 1)
	settle(r, 1)
	hold(r, 0.22)
}

@(private = "file")
typ :: proc(r: ^Rig, text: string) {
	if !r.film {
		p.type_text(r.off, text)
		settle(r, 2)
		return
	}
	// Filming types a character at a time, because a field that fills in one
	// frame does not read as typing.
	i := 0
	for i < len(text) {
		n := 1
		for i + n < len(text) && text[i + n] & 0xc0 == 0x80 {
			n += 1
		}
		p.type_text(r.off, text[i:i + n])
		settle(r, 1)
		settle(r, 1)
		i += n
	}
}

run_uitest :: proc(dir: string, film := false) -> int {
	os.make_directory_all(dir)

	// This run files messages, deletes them and saves an attachment, so it must
	// not touch the mailbox somebody is actually reading. Pointing the data
	// directory at a scratch tree inside the output folder makes `init_state`
	// generate its own fixtures there: the run is hermetic, repeatable, and
	// destroys nothing it did not create.
	data_dir_override = strings.clone(fmt.tprintf("%s/mailbox", dir))
	os.make_directory_all(data_dir_override)

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
		off  = off,
		st   = st,
		dir  = dir,
		film = film,
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
	if !film {
		bench(&r, "inbox, collapsed", 60)
	}

	hold(&r, 1.2)
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
	if !film {
		bench(&r, "inbox, scrolled", 60)
	}
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

	// Attachments: the reader's attachment list, and actually saving one.
	//
	// The save dialog is given a directory inside this run's output folder, so
	// a test or a recording never writes into the user's Downloads.
	st.save_dir = strings.clone(tfmt("%s/saved", dir))
	os.make_directory_all(st.save_dir)

	key(&r, '/')
	typ(&r, "Instrument trace")
	key(&r, p.KEY_DOWN)
	shot(&r, "attachments")

	// V walks the chips. The inline logo is not among them: the HTML points at
	// it with a cid: URL, so it belongs to the message, not to this list.
	key(&r, 'v')
	shot(&r, "attachment-selected")

	// W opens the shared file dialog with the attachment's own name filled in.
	key(&r, 'w')
	shot(&r, "save-dialog")
	key(&r, p.KEY_RETURN)
	shot(&r, "saved")
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

	// Filing: move a message to another folder, then put it back.
	key(&r, p.KEY_HOME)
	key(&r, 'j', 3)
	key(&r, 'm')
	shot(&r, "move-sheet")
	key(&r, 'j', 2)
	shot(&r, "move-chosen")
	key(&r, p.KEY_RETURN)
	shot(&r, "moved")
	key(&r, 'z')
	shot(&r, "move-undone")

	// Archive and delete, which are the same rename with a folder chosen for
	// you, and then the one irreversible operation — which asks first.
	key(&r, 'e')
	shot(&r, "archived")
	key(&r, 'z')
	key(&r, 'd')
	shot(&r, "trashed")
	key(&r, 'z')
	chord(&r, 'd', {.Shift})
	shot(&r, "purge-confirm")
	key(&r, p.KEY_ESCAPE)

	// The folder tree, down to the POP3 account that has only an inbox.
	key(&r, 'h')
	shot(&r, "folders")
	key(&r, 'j', 20)
	shot(&r, "pop3-inbox")

	// Raw headers, which is also a look at the Maildir filename and its flags.
	key(&r, 'l')
	key(&r, 'i')
	shot(&r, "headers")

	if film {
		fmt.printfln("mail --walkthrough: %d frames at %d fps", r.frame, int(WALKTHROUGH_FPS))
		return 0
	}

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
