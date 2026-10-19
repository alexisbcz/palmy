// Home — the unified hub of a Palmframe account: Today, universal search,
// quick-create and a command palette, across every identity the person owns.
//
// A prototype. It reads invented fixtures (fixtures.odin) through the one
// seam real data will use (model.odin), and opening anything shows where it
// would open rather than opening it. The design it prototypes is in
// cloud/docs/product.md.
//
//	home                 a window, light
//	home --dark          a window, dark
//	home --shots <dir>   render the interface offscreen, light and dark
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

tfmt :: fmt.tprintf
tr :: kit.tr

Mode :: enum {
	Normal,
	Palette,
	Create,
	Carry,
	Help,
}

Create_Kind :: enum {
	Mail,
	Event,
	Task,
	Note,
	Doc,
}

CREATE_LABEL := [Create_Kind]string {
	.Mail  = "Mail",
	.Event = "Event",
	.Task  = "Task",
	.Note  = "Note",
	.Doc   = "Document",
}

Home :: struct {
	store:        Store,
	dark:         bool,
	ident:        int, // the identity the window is in; -1 = all of them
	query:        [dynamic]u8,
	sel:          int, // index into rows
	rows:         [dynamic]int, // item indices that can be selected, in order, last frame
	mode:         Mode,
	swallow:      bool,
	// palette
	pal_query:    [dynamic]u8,
	pal_sel:      int,
	// quick-create
	new_kind:     Create_Kind,
	new_ident:    int, // -1 until chosen, when the window is showing everything
	new_title:    [dynamic]u8,
	new_err:      string,
	// carry
	carry_item:   int,
	carry_to:     int,
	toast:        string,
	toast_at:     f64,
	want_quit:    bool,
}

// Palette colours for the identity colours public.identities.color may
// name. Two values each: the light theme's and the dark theme's, chosen so
// the label reads at text size on either background.
id_color :: proc(name: string) -> (light, dark: u32) {
	switch name {
	case "teal":
		return 0x0f9488, 0x2dd4bf
	case "blue":
		return 0x2563eb, 0x60a5fa
	case "amber":
		return 0xc2620a, 0xfbbf24
	case "violet":
		return 0x7c3aed, 0xa78bfa
	case "rose":
		return 0xe11d48, 0xfb7185
	case "emerald":
		return 0x059669, 0x34d399
	}
	return 0x4f46e5, 0x818cf8 // indigo, the contract's default
}

// register_identity_colors gives every identity a token, `id-0`, `id-1`, …,
// so a class string can say `text-id-1` or `bg-id-1/10`.
register_identity_colors :: proc(s: ^Store, dark: bool) {
	for id, i in s.identities {
		l, d := id_color(id.color)
		p.register_color(tfmt("id-%d", i), p.hex(dark ? d : l))
	}
	// The "now" line on the agenda.
	p.register_color("now", p.hex(dark ? 0xf87171 : 0xdc2626))
}

home_init :: proc(h: ^Home, dark: bool) {
	h.store = store_load(.Fixtures)
	h.dark = dark
	h.ident = -1
	h.new_ident = -1
	h.carry_item = -1
}

note :: proc(h: ^Home, msg: string) {
	if h.toast != "" {
		delete(h.toast)
	}
	h.toast = strings.clone(msg)
	h.toast_at = 0
}

main :: proc() {
	kit.i18n_init("home")
	args := os.args[1:]
	dark := os.get_env("PALM_THEME", context.temp_allocator) == "dark"
	for a, i in args {
		if a == "--selftest" {
			run_selftest()
			os.exit(failures == 0 ? 0 : 1)
		}
		if a == "--dark" {
			dark = true
		}
		if a == "--shots" {
			if i + 1 >= len(args) {
				fmt.eprintln("home --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(args[i + 1]))
		}
	}

	app, err := kit.start(
		{title = "Home", app_id = "palm.home", width = 1240, height = 800, min_width = 860, min_height = 560},
		dark,
	)
	if err != "" {
		fmt.eprintfln("home: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	h := Home{}
	home_init(&h, dark)
	register_identity_colors(&h.store, dark)

	for ui in p.frames(app) {
		keys(ui, &h)
		frame(ui, &h)
		if h.want_quit {
			p.quit_app(app)
		}
	}
}
