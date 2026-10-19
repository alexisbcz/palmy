package wm

// The shell's part of `wm --shots`: the start menu (home, search, all apps,
// an app's menu), the desktop menu and the power menu, in the dark look and
// the light one.
//
// Nothing on the machine is read: the applications are distro/apps/desktop
// (PALMY_APPLICATIONS_DIR), and the home directory, the launch history, the
// identity and the programs on PATH are fixtures made under /tmp for the
// run and removed after it. Nothing is launched: the pictures are of the
// menus, never of what clicking them does.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

shell_shots :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, off: ^p.Offscreen, dir: string, n: ^int) {
	saved := [?]string{"HOME", "PATH", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "PALM_CLOUD_DIR", "PALMY_APPLICATIONS_DIR", "USER"}
	old: [len(saved)]string
	for k, i in saved {
		old[i] = strings.clone(os.get_env(k, context.temp_allocator))
	}
	tmp := fmt.aprintf("/tmp/wm-shell-shots-%d", os.get_pid())
	defer {
		for k, i in saved {
			if old[i] == "" {
				os.unset_env(k)
			} else {
				os.set_env(k, old[i])
			}
		}
		os.remove_all(tmp)
	}

	// The fixtures.
	mk :: proc(path: string, text := "") {
		_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
		_ = os.write_entire_file(path, transmute([]byte)text)
	}
	home := fmt.tprintf("%s/home", tmp)
	mk(fmt.tprintf("%s/Documents/Quarterly report.md", home), "# Q3\n")
	mk(fmt.tprintf("%s/Pictures/Lake at dusk.png", home))
	mk(fmt.tprintf("%s/Documents/Budget 2026.csv", home), "a,b\n")
	now := time.time_to_unix(time.now())
	mk(fmt.tprintf("%s/.cache/palmy-launcher/usage", home), fmt.tprintf(
		"6 mail.desktop %d\n9 term.desktop %d\n3 docs.desktop %d\n2 calendar.desktop %d\n",
		now - 600, now - 7200, now - 90000, now - 300000,
	))
	mk(fmt.tprintf("%s/.config/palmframe/identities.json", home), `[{"handle":"northwind","display_name":"Northwind","color":"blue"},{"handle":"personal","display_name":"Personal","color":"teal"}]`)
	mk(fmt.tprintf("%s/cloud/current", tmp), "northwind\n")
	bin := fmt.tprintf("%s/bin", tmp)
	for prog in ([?]string{"term", "files", "launcher", "store", "settings", "accounts"}) {
		mk(fmt.tprintf("%s/%s", bin, prog), "#!/bin/sh\n")
	}
	os.set_env("HOME", home)
	os.set_env("USER", "camille")
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/.config", home))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/.local/share", home))
	os.set_env("PALM_CLOUD_DIR", fmt.tprintf("%s/cloud", tmp))
	os.set_env("PATH", bin)
	if old[5] == "" {
		os.set_env("PALMY_APPLICATIONS_DIR", "distro/apps/desktop")
	}
	start.indexed = false

	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}
	step :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
		start.opened_at = wall_now() - 1 // no drop-in: the menu where it rests
		draw(s, app, cv)
		free_all(context.temp_allocator)
	}
	type :: proc(s: ^Server, app: ^p.App, text: string) {
		for r in text {
			start_key(s, app, p.Key_Event{sym = u32(r)})
		}
	}

	for light in ([2]bool{false, true}) {
		suffix := light ? "light" : "dark"
		s.cfg.light = light
		pal_apply(light, s.cfg.accent)
		s.cfg.border_unfocus = light ? 0xd4d4d8 : 0x27272a
		s.bg_w = -1

		// The start menu as Super opens it.
		s.cur_out = 0
		start_open(s)
		step(s, app, cv)
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("10-start-%s", suffix), n)

		// Typing: apps, a settings page and a file answer "dar".
		type(s, app, "dar")
		step(s, app, cv)
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("11-start-search-%s", suffix), n)
		strings.builder_reset(&start.query)
		start.sel, start.sel_auto = -1, true

		// All apps, grouped.
		start.page = .All
		step(s, app, cv)
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("12-start-all-%s", suffix), n)
		start.page = .Home
		step(s, app, cv)

		// An app's menu: open, its pins.
		for h in start.hits {
			if h.kind == .App {
				start_context(s, h, int(h.rect.x + h.rect.w / 2), int(h.rect.y + h.rect.h / 2))
				break
			}
		}
		step(s, app, cv)
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("13-start-pin-menu-%s", suffix), n)
		menu_close(s)

		// The power button's menu.
		for h in start.hits {
			if h.kind == .Power_Btn {
				start_power_menu(s, h.rect)
			}
		}
		step(s, app, cv)
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("14-start-power-%s", suffix), n)
		menu_close(s)
		start_close(s)

		// The desktop's menu.
		menu_open_desktop(s, s.out_w / 2 + 120, s.out_h / 2 + 60)
		step(s, app, cv)
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("15-desktop-menu-%s", suffix), n)
		menu_close(s)
	}
	s.cfg.light = false
	pal_apply(false, s.cfg.accent)
	s.cfg.border_unfocus = 0x27272a
	s.bg_w = -1
	start.indexed = false
}
