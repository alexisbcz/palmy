// Home — the unified hub of a Palmy account: Today, universal search,
// quick-create and a command palette, across every identity the person owns.
//
// It reads the local search index (apps/index, kept by palm-indexd) through
// one seam (model.odin, device.odin): Today and search are queries on it,
// and opening a result starts its application in its own identity. The
// invented fixtures (fixtures.odin) stay behind a flag, for screenshots and
// the self-test. The design is cloud/docs/product.md; search is
// cloud/docs/search.md.
//
//	home                       a window on this device's data, light
//	home --dark                the same, dark
//	home --fixtures            the invented persona instead (PALM_HOME_FIXTURES=1)
//	home --shots <dir>         render the fixtures offscreen, light and dark
//	home --shots-device <dir>  render this device's data offscreen
//	home --bench <query>       type a query a letter at a time against the
//	                           index, and report the latency per keystroke
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
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

home_init :: proc(h: ^Home, dark: bool, src := Source.Fixtures) {
	h.store = store_load(src)
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
	src := os.get_env("PALM_HOME_FIXTURES", context.temp_allocator) != "" ? Source.Fixtures : Source.Device
	for a, i in args {
		if a == "--selftest" {
			run_selftest()
			os.exit(failures == 0 ? 0 : 1)
		}
		if a == "--dark" {
			dark = true
		}
		if a == "--fixtures" {
			src = .Fixtures
		}
		if a == "--shots" || a == "--shots-device" || a == "--bench" {
			if i + 1 >= len(args) {
				fmt.eprintfln("home %s <arg>", a)
				os.exit(2)
			}
			switch a {
			case "--shots":
				os.exit(shots(args[i + 1]))
			case "--shots-device":
				os.exit(shots(args[i + 1], .Device))
			case "--bench":
				os.exit(bench(args[i + 1]))
			}
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
	home_init(&h, dark, src)
	register_identity_colors(&h.store, dark)
	nids := len(h.store.identities)

	for ui in p.frames(app) {
		if h.store.source == .Device {
			// Re-read the index every two seconds: a mail that arrives, a
			// file that changes, shows up without a key being pressed.
			if device_tick(&h.store) && len(h.store.identities) != nids {
				register_identity_colors(&h.store, dark)
				nids = len(h.store.identities)
			}
			p.wake_after(ui, 2 * time.Second)
		}
		keys(ui, &h)
		frame(ui, &h)
		if h.want_quit {
			p.quit_app(app)
		}
	}
}
