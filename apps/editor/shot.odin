// `editor --shots <dir>`: render the interface offscreen and write PNGs.
//
// No compositor and no window: the same `measure`, `keys`, `build_visible` and
// `frame` the window runs, driven through palmy's offscreen renderer with
// synthetic keys. The file it opens is written by this file immediately
// beforehand — invented Odin, under the output directory — so no source of the
// user's is ever read, and the path shown in the title bar is a fixed
// demonstration path rather than anybody's home.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1180
SHOT_H :: 780

// What the title bar shows. The fixture is read from the output directory,
// but a screenshot should not carry the path of the machine that made it.
SHOT_DIR_SHOWN :: "/srv/palmy/demo/ring"
SHOT_NAME :: "ring_buffer.odin"

// The fixture: a single-producer ring buffer, written for this screenshot and
// nothing else. Every identifier in it is invented.
SHOT_SOURCE :: `package ring

// A single-producer, single-consumer ring of fixed capacity.
//
// The two indices are free-running counters rather than wrapped positions, so
// "empty" is head == tail and "full" is head - tail == cap, and neither case
// needs a spare slot to tell them apart.

import "core:mem"

Ring :: struct($T: typeid) {
	buf:  []T,
	mask: uint, // cap - 1, so wrapping is an AND
	head: uint, // written by the producer only
	tail: uint, // written by the consumer only
}

// make_ring rounds the capacity up to a power of two, which is what makes the
// mask legal. A capacity of zero is a programming error, not a special case.
make_ring :: proc($T: typeid, capacity: uint, allocator := context.allocator) -> (r: Ring(T), err: mem.Allocator_Error) {
	assert(capacity > 0, "a ring needs room for at least one element")
	n := uint(1)
	for n < capacity {
		n <<= 1
	}
	r.buf = make([]T, n, allocator) or_return
	r.mask = n - 1
	return r, nil
}

destroy_ring :: proc(r: ^Ring($T)) {
	delete(r.buf)
	r^ = {}
}

len_ring :: proc(r: ^Ring($T)) -> uint {
	return r.head - r.tail
}

full :: proc(r: ^Ring($T)) -> bool {
	return len_ring(r) == uint(len(r.buf))
}

// push appends one element and reports whether there was room. The producer
// is the only writer of head, so no compare-and-swap is needed here.
push :: proc(r: ^Ring($T), v: T) -> bool {
	if full(r) {
		return false
	}
	r.buf[r.head & r.mask] = v
	r.head += 1
	return true
}

// pop takes the oldest element. ok is false when the ring is empty.
pop :: proc(r: ^Ring($T)) -> (v: T, ok: bool) {
	if r.head == r.tail {
		return {}, false
	}
	v = r.buf[r.tail & r.mask]
	r.tail += 1
	return v, true
}

// peek reads without consuming, which the parser uses for one token of
// lookahead.
peek :: proc(r: ^Ring($T)) -> (v: T, ok: bool) {
	if r.head == r.tail {
		return {}, false
	}
	return r.buf[r.tail & r.mask], true
}

// drain copies everything out in order and leaves the ring empty.
drain :: proc(r: ^Ring($T), allocator := context.temp_allocator) -> []T {
	n := len_ring(r)
	out := make([]T, n, allocator)
	for i in 0 ..< n {
		out[i] = r.buf[(r.tail + i) & r.mask]
	}
	r.tail = r.head
	return out
}
`

@(private = "file")
load_shot_fonts :: proc(off: ^p.Offscreen) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("editor --shots: cannot create %s", dir)
		return 1
	}
	src_dir := strings.clone(fmt.tprintf("%s/.store/editor-src", dir))
	defer delete(src_dir)
	_ = os.make_directory_all(src_dir, os.perm(0o700))
	src := strings.clone(fmt.tprintf("%s/%s", src_dir, SHOT_NAME))
	defer delete(src)
	if werr := os.write_entire_file(src, transmute([]u8)string(SHOT_SOURCE)); werr != nil {
		fmt.eprintfln("editor --shots: could not write %s", src)
		return 1
	}

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	load_shot_fonts(off)

	ed := Editor {
		numbers = true,
		syntax  = true,
	}
	if !buf_load(&ed.buf, src) {
		fmt.eprintfln("editor --shots: could not read %s", src)
		return 1
	}
	// The buffer keeps the text that was really loaded; only the name it is
	// shown under is replaced, and nothing in this mode ever writes.
	delete(ed.buf.path)
	ed.buf.path = strings.clone(fmt.tprintf("%s/%s", SHOT_DIR_SHOWN, SHOT_NAME))
	relang(&ed)
	defer kit.pick_destroy(&ed.pick)

	step :: proc(off: ^p.Offscreen, ed: ^Editor) {
		ui := p.offscreen_begin(off)
		measure(ui, ed)
		keys(ui, ed, nil)
		build_visible(ed)
		frame(ui, ed)
		p.offscreen_end(off)
	}

	// Hover and hit testing run against the previous frame, so the settled
	// picture is never the first one.
	settle :: proc(off: ^p.Offscreen, ed: ^Editor, n := 3) {
		for _ in 0 ..< n {
			step(off, ed)
		}
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		path := fmt.tprintf("%s/%s", dir, name)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// The editor itself: the highlighted source, the gutter, the caret inside
	// `push`, and a selection over one expression. The line is found by what
	// is on it rather than by a number, so editing the fixture cannot aim the
	// caret off the end of a short line.
	line_with :: proc(ed: ^Editor, needle: string) -> int {
		for i in 0 ..< buf_lines(&ed.buf) {
			if strings.contains(buf_line(&ed.buf, i), needle) {
				return i
			}
		}
		return 0
	}
	// One frame first: `measure` is what gives the view its row and column
	// counts, and `ensure_visible` called before that would scroll the text
	// sideways against a zero-width viewport.
	settle(off, &ed, 2)
	at := line_with(&ed, "r.buf[r.head & r.mask]")
	ed.cur = {at, 1}
	ed.anchor = ed.cur
	ensure_visible(&ed)
	settle(off, &ed)
	// A selection, made the way a user makes one: shift-word-right.
	for _ in 0 ..< 3 {
		p.press_key(off, p.KEY_RIGHT, {.Ctrl, .Shift})
		settle(off, &ed, 2)
	}
	settle(off, &ed, 2)
	shot(off, dir, "app-editor.png", &n)

	// The command palette, filtered, which is the discoverable way in.
	p.press_key(off, p.KEY_ESCAPE)
	settle(off, &ed, 2)
	p.type_text(off, "wra")
	settle(off, &ed, 3)
	shot(off, dir, "02-editor-palette.png", &n)
	p.press_key(off, p.KEY_ESCAPE)
	settle(off, &ed, 2)

	// Find and replace, with the match count the prompt reports.
	open_prompt(&ed, .Replace)
	settle(off, &ed, 2)
	p.type_text(off, "r.mask")
	settle(off, &ed, 3)
	ed.field = .Secondary
	p.type_text(off, "r.wrap")
	settle(off, &ed, 3)
	shot(off, dir, "03-editor-replace.png", &n)
	ed.mode = .Edit
	ed.prompt = .None
	clear(&ed.find)
	clear(&ed.repl)
	settle(off, &ed, 2)

	// Several cursors at once, which is the thing worth a picture.
	ed.cur = {line_with(&ed, "r.buf = make([]T, n, allocator)"), 0}
	ed.anchor = ed.cur
	ed.has_sel = false
	carets_collapse(&ed)
	ensure_visible(&ed)
	for _ in 0 ..< 3 {
		caret_add_vert(&ed, 1)
		settle(off, &ed, 1)
	}
	settle(off, &ed, 3)
	shot(off, dir, "04-editor-multicursor.png", &n)
	carets_collapse(&ed)

	// The keyboard sheet.
	ed.mode = .Help
	settle(off, &ed)
	shot(off, dir, "05-editor-keys.png", &n)
	ed.mode = .Edit

	fmt.printfln("editor --shots: %d PNGs in %s", n, dir)
	return 0
}
