// A live Wayland window built from the same Odin shadcn widgets the parity
// renderer measures. This is the thing the demo videos record: real hover,
// real clicks, real typing, drawn by palmy's software rasterizer and handed to
// the compositor as shared memory.
package main

import "core:fmt"
import "core:os"
import p "palmy:."
import sc "shadcn:."

App_State :: struct {
	clicks:   int,
	name:     [dynamic]u8,
	search:   [dynamic]u8,
	notify:   bool,
	dark:     bool,
	variant:  int,
	volume:   [1]f32,
}

// FONT_DIR is the parity web app's pinned fonts, found from this source file's
// own directory (`#directory` is ".../parity/odin/showcase/", resolved at
// compile time) so a binary built from a git worktree loads that worktree's
// fonts. It used to be a hardcoded /home/alex/Work/palmy/parity path, the same
// mistake odin/render/main.odin had.
@(private)
SOURCE_DIR :: #directory
FONT_DIR :: SOURCE_DIR[:len(SOURCE_DIR) - len("odin/showcase/")] + "web/public/fonts"

main :: proc() {
	app, err := p.create(
		{title = "palmy · shadcn", app_id = "palmy", width = 980, height = 720, min_width = 560},
	)
	if err != "" {
		fmt.eprintfln("palmy: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	// The same four static Geist faces the browser is pinned to.
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		path := fmt.tprintf("%s/%s", FONT_DIR, pair.file)
		p.load_font(&app.fonts, path, .Sans, pair.wt)
	}
	sc.register_shadcn_theme()
	// The same glyph-coverage calibration the parity renderer uses, measured
	// against Chromium over the whole component set.
	p.set_text_gamma(1.8)

	st := App_State{volume = {64}}
	defer delete(st.name)
	defer delete(st.search)

	for ui in p.frames(app) {
		build(ui, &st)
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.shortcut(ui, 'q', {.Ctrl}) {
			p.quit_app(app)
		}
	}
}

build :: proc(ui: ^p.Ctx, st: ^App_State) {
	p.col(ui, "w-full h-full bg-background text-foreground overflow-scroll")
	defer p.end(ui)

	p.col(ui, "w-full max-w-[860] mx-auto p-10 gap-8")
	defer p.end(ui)

	header(ui, st)
	buttons(ui, st)
	badges(ui)
	controls(ui, st)
	inputs(ui, st)
}

// Controls built by the component agents, driven live by palmy's own input.
controls :: proc(ui: ^p.Ctx, st: ^App_State) {
	section(ui, "Controls")
	defer p.end(ui)

	p.row(ui, "flex-wrap gap-6 items-center")
	defer p.end(ui)

	// Checkbox — click or press Space to toggle.
	cb := p.row(ui, "gap-2 items-center")
	p.focusable(ui)
	if p.activated(ui, cb) {
		st.notify = !st.notify
	}
	sc.checkbox(ui, st.notify ? .On : .Off, sc.State{focus = p.focused(ui, cb)})
	p.text(ui, "Notifications", "text-sm")
	p.end(ui)

	// Switch.
	sw := p.row(ui, "gap-2 items-center")
	p.focusable(ui)
	if p.activated(ui, sw) {
		st.dark = !st.dark
	}
	sc.switch_(ui, st.dark, .Default, sc.State{focus = p.focused(ui, sw)})
	p.text(ui, "Compact", "text-sm")
	p.end(ui)

	sc.avatar(ui, "AL")
	sc.kbd(ui, "Ctrl")
	sc.kbd(ui, "K")
	sc.spinner(ui)

	// The slider wants a definite width, like its CSS counterpart.
	p.div(ui, "w-[260] shrink-0")
	sc.slider(ui, st.volume[:])
	p.end(ui)
}

header :: proc(ui: ^p.Ctx, st: ^App_State) {
	p.col(ui, "gap-1.5 shrink-0")
	defer p.end(ui)
	p.text(ui, "shadcn/ui, rendered by Odin", "text-2xl font-semibold tracking-tight")
	p.textf(
		ui,
		"text-sm text-muted-foreground",
		"Software rasterizer on a Wayland surface. %d clicks so far.",
		st.clicks,
	)
}

section :: proc(ui: ^p.Ctx, title: string) {
	p.col(ui, "gap-4 p-6 rounded-xl bg-card ring-1 ring-foreground/10 shrink-0")
	p.text(ui, title, "text-sm font-medium")
}

buttons :: proc(ui: ^p.Ctx, st: ^App_State) {
	section(ui, "Buttons")
	defer p.end(ui)

	variants := [?]sc.Variant{.Default, .Secondary, .Outline, .Ghost, .Destructive, .Link}
	labels := [?]string{"Default", "Secondary", "Outline", "Ghost", "Destructive", "Link"}

	p.row(ui, "flex-wrap gap-3 items-center")
	for v, i in variants {
		p.key(ui, labels[i])
		// The live hover state comes from palmy's own hit testing, so these are
		// the same class strings the parity renderer measures.
		at := p.node_count(ui)
		hovered := p.hovered(ui, p.node_id(ui, at))
		sc.button_open(ui, v, .Default, sc.State{hover = hovered, focus = p.focused(ui)})
		p.focusable(ui)
		if p.activated(ui) {
			st.clicks += 1
			st.variant = i
		}
		p.text(ui, labels[i], "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.button_end(ui)
	}
	p.end(ui)

	p.row(ui, "gap-3 items-center pt-1")
	sizes := [?]sc.Size{.XS, .SM, .Default, .LG}
	size_labels := [?]string{"xs", "sm", "default", "lg"}
	for s, i in sizes {
		p.key(ui, size_labels[i])
		at := p.node_count(ui)
		hovered := p.hovered(ui, p.node_id(ui, at))
		sc.button_open(ui, .Secondary, s, sc.State{hover = hovered, focus = p.focused(ui)})
		p.focusable(ui)
		if p.activated(ui) {
			st.clicks += 1
		}
		p.text(ui, size_labels[i], "whitespace-nowrap")
		p.style(ui).shrink = 0
		sc.button_end(ui)
	}
	p.end(ui)
}

badges :: proc(ui: ^p.Ctx) {
	section(ui, "Badges")
	defer p.end(ui)

	p.row(ui, "flex-wrap gap-2 items-center")
	defer p.end(ui)
	sc.badge(ui, "Default")
	sc.badge(ui, "Secondary", .Secondary)
	sc.badge(ui, "Destructive", .Destructive)
	sc.badge(ui, "Outline", .Outline)
}

// palmy's text field ships a dark default; this is the shadcn skin for it.
FIELD_SKIN ::
	"h-8 w-full rounded-lg border border-input bg-background text-foreground " +
	"text-sm px-2.5 focus:border-ring focus:ring-3 focus:ring-ring/50"

inputs :: proc(ui: ^p.Ctx, st: ^App_State) {
	section(ui, "Inputs")
	defer p.end(ui)

	p.col(ui, "gap-2 w-full")
	defer p.end(ui)

	p.text(ui, "Name", "text-sm font-medium")
	// palmy's own editable field, dressed in shadcn's input classes.
	p.text_field(ui, &st.name, "Ada Lovelace", FIELD_SKIN)

	p.row(ui, "gap-2 items-center pt-2 w-full")
	defer p.end(ui)
	p.icon(ui, sc.ICON_SEARCH, "size-4 text-muted-foreground shrink-0")
	p.text_field(ui, &st.search, "Search components", FIELD_SKIN + " flex-1")
}
