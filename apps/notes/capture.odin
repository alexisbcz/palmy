// Quick capture: `notes capture`, the global "new note" the shell binds.
//
// A small window that opens, takes a thought, and goes away. It writes into
// the inbox of the identity the person is in — the scope it was started with
// ($PALM_IDENTITY, which the shell sets for the focused identity), else the
// identity the shell's switcher last chose — and shows that identity before a
// single character is typed. With neither, it does not guess: Enter does
// nothing until Tab has chosen one (product.md P3).
//
//	Enter          save into the inbox and close
//	Shift+Enter    a new line
//	Tab            another identity (unscoped only)
//	Esc            close without saving
//
// The note is a file the moment Enter is pressed; a background `notes sync`
// takes it to the other devices.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Capture :: struct {
	ids:    [dynamic]Ident,
	sel:    int, // -1: not chosen yet
	text:   [dynamic]u8,
	scoped: bool,
	dark:   bool,
	done:   bool,
	saved:  string, // where the note went, once saved
}

capture_init :: proc(c: ^Capture, dark: bool) {
	c.dark = dark
	c.ids = idents_load()
	c.scoped = os.get_env("PALM_IDENTITY", context.temp_allocator) != ""
	b := Book{ids = c.ids}
	c.sel = capture_ident(&b)
}

capture_window :: proc() -> int {
	dark := os.get_env("PALM_THEME", context.temp_allocator) == "dark"
	app, err := kit.start({title = "Quick note", width = 560, height = 300, min_width = 360, min_height = 220, root_class = "w-full h-full bg-background text-foreground"}, dark)
	if err != "" {
		fmt.eprintfln("notes capture: %s", err)
		return 1
	}
	defer p.destroy(app)
	register_colors(dark)
	c := Capture{}
	capture_init(&c, dark)
	for ui in p.frames(app) {
		capture_keys(ui, &c)
		capture_frame(ui, &c)
		if c.done {
			break
		}
	}
	p.quit_app(app)
	if c.saved != "" {
		// Off to the other devices, without keeping this window open for it.
		if c.sel >= 0 && ident_bound(c.ids[c.sel]) {
			kit.launch({self_exe(), "sync", "--identity", c.ids[c.sel].handle})
		}
		fmt.println(c.saved)
	}
	return 0
}

capture_keys :: proc(ui: ^p.Ctx, c: ^Capture) {
	if plain(ui, p.KEY_ESCAPE) {
		c.done = true
		return
	}
	if plain(ui, p.KEY_TAB) && !c.scoped && len(c.ids) > 0 {
		c.sel = (c.sel + 1) % len(c.ids)
		return
	}
	if p.shortcut(ui, p.KEY_RETURN, {.Shift}) {
		append(&c.text, '\n')
		return
	}
	if plain(ui, p.KEY_RETURN) {
		capture_save(c)
		return
	}
	field_edit(ui, &c.text, false)
}

capture_save :: proc(c: ^Capture) {
	text := strings.trim_space(string(c.text[:]))
	if text == "" || c.sel < 0 || c.sel >= len(c.ids) {
		return
	}
	first, rest := text, ""
	if nl := strings.index_byte(text, '\n'); nl >= 0 {
		first, rest = text[:nl], text[nl + 1:]
	}
	body := rest == "" ? fmt.tprintf("%s\n", first) : fmt.tprintf("%s\n\n%s\n", first, rest)
	path, ok := store_create_in(c.ids[c.sel].root, "", body)
	if ok {
		c.saved = path
		c.done = true
	}
}

capture_frame :: proc(ui: ^p.Ctx, c: ^Capture) {
	for id, i in c.ids {
		if i >= len(ID_TOKENS) {break}
		p.register_color(ID_TOKENS[i], p.hex(identity_hex(id.color, c.dark)))
	}
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)
	tok := c.sel >= 0 ? id_tok(c.sel) : "border"
	p.div(ui, tfmt("h-[3] w-full shrink-0 bg-%s", tok))
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-2.5 px-4 pt-3.5 pb-2")
	p.icon(ui, ICON_NOTEBOOK_PEN, "size-4 text-muted-foreground shrink-0")
	p.text(ui, "Quick note", "text-[14] font-semibold")
	p.spacer(ui, "flex-1")
	if c.sel >= 0 {
		p.text(ui, "into the inbox of", "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.row(ui, tfmt("h-6 shrink-0 items-center gap-1.5 pl-1 pr-2 rounded-full bg-%s/10", id_tok(c.sel)))
		p.div(ui, tfmt("flex-row size-[18] shrink-0 items-center justify-center rounded-full bg-%s/15", id_tok(c.sel)))
		p.text(ui, monogram_of(c.ids[c.sel].name), tfmt("text-[10] font-semibold text-%s", id_tok(c.sel)))
		p.end(ui)
		p.text(ui, c.ids[c.sel].name, tfmt("text-[11.5] font-medium whitespace-nowrap text-%s", id_tok(c.sel)))
		p.end(ui)
	} else {
		p.text(ui, "Choose an identity first: Tab", "text-[11.5] font-medium text-amber-600 whitespace-nowrap")
	}
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 w-full px-4 py-1 overflow-hidden")
	box := p.col(ui, "w-full h-full rounded-lg border border-ring ring-3 ring-ring/25 bg-background px-3 py-2.5 gap-0.5 overflow-hidden")
	_ = box
	t := string(c.text[:])
	lines := strings.split(t, "\n", context.temp_allocator)
	caret_on := math.mod(f64(p.elapsed(ui)), 1.06) < 0.62
	p.redraw(ui)
	if t == "" {
		p.row(ui, "w-full items-center")
		if caret_on {
			p.div(ui, "w-[2] h-[18] bg-foreground shrink-0")
			p.end(ui)
		}
		p.text(ui, "What's on your mind? The first line is the title.", "text-[14] text-muted-foreground/60 whitespace-nowrap")
		p.end(ui)
	}
	for l, i in lines {
		if t == "" {break}
		p.row(ui, "w-full items-center flex-wrap")
		p.text(ui, l == "" ? " " : l, i == 0 ? "text-[15] font-semibold" : "text-[14] text-foreground/90")
		if i == len(lines) - 1 && caret_on {
			p.div(ui, "w-[2] h-[18] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 py-2.5")
	hint(ui, "Enter", "save")
	hint(ui, "Shift Enter", "new line")
	if !c.scoped && len(c.ids) > 1 {
		hint(ui, "Tab", "identity")
	}
	hint(ui, "Esc", "discard")
	p.spacer(ui, "flex-1")
	if c.sel >= 0 {
		p.text(ui, tfmt("~/Notes/%s/", c.ids[c.sel].handle), "text-[11] font-mono text-muted-foreground/70 whitespace-nowrap")
	}
	p.end(ui)
	_ = sc.kbd
}
