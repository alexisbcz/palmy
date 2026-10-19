package wm

// The shell's checks in wm --selftest: the start menu, the shell palette and
// the settings wm.conf carries for Settings (theme, accent, pointer, time
// zone), and the shared application index (kit:appindex).

import "core:fmt"
import "core:os"
import "core:strings"
import ai "kit:appindex"
import p "palmy:."

start_selftest :: proc(s: ^Server) {
	// --- the shared index ---------------------------------------------------
	{
		pass, fail := ai.selftest()
		ws_test_pass += pass
		ws_test_fail += fail
	}

	// --- wm.conf: the settings Settings writes -----------------------------
	{
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, CFG_DEFAULT, "<built-in>")
		cfg_apply_shell(&c)
		ws_check(!c.light && pal.dark && c.accent == ACCENT_DEFAULT, "the default look is dark with the indigo accent")
		ws_check(c.super_tap && c.super_menu, "a Super tap opens the start menu by default")
		ws_check(c.border_focus == c.accent, "the focus ring follows the accent")

		cfg_parse(&c, "theme = light\naccent = #0ea5e9\nnatural_scroll = on\ntap_to_click = off\nleft_handed = yes\npointer_speed = 0.5\nrepeat_rate = 40\nrepeat_delay = 250\nsuper_tap = overview\nbar_pins = off\n", "test")
		cfg_apply_shell(&c)
		ws_check(c.light && !pal.dark && pal.accent == 0x0ea5e9 && ACCENT == 0x0ea5e9, "theme and accent reach the palette")
		ws_check(c.border_focus == 0x0ea5e9 && c.border_unfocus == 0xd4d4d8, "the frame colours follow the look unless the file sets them")
		ws_check(ev_cfg.natural_scroll && !ev_cfg.tap_to_click && ev_cfg.left_handed, "pointer settings reach evdev")
		ws_check(ev_cfg.accel_speed == 0.5 && ev_cfg.repeat_rate == 40 && ev_cfg.repeat_delay == 250, "speed and key repeat reach evdev")
		ws_check(c.super_tap && !c.super_menu && !c.bar_pins, "super_tap = overview and bar_pins = off")
		ws_check(pal.on_accent == 0xffffff && pal.accent_wash != pal.accent, "derived accent colours")

		cfg_parse(&c, "border_focus = #ff0000\ntheme = sideways\n", "test")
		cfg_apply_shell(&c)
		ws_check(c.border_focus == 0xff0000, "a border_focus in the file wins over the accent")
		ws_check(len(c.errors) == 1 && strings.contains(c.errors[0], "theme"), "an unknown theme is reported, not applied")

		// Back to the defaults, so later checks see the dark shell and stock
		// pointer settings.
		cfg_free(&c)
		cfg_scalars(&c)
		cfg_parse(&c, CFG_DEFAULT, "<built-in>")
		cfg_apply_shell(&c)
		ws_check(!ev_cfg.natural_scroll && ev_cfg.tap_to_click && pal.dark, "the defaults restore the stock pointer and look")
		cfg_free(&c)
	}

	// --- the time zone -------------------------------------------------------
	if os.exists("/usr/share/zoneinfo/Asia/Tokyo") {
		before := strings.clone(os.get_env("TZ", context.temp_allocator), context.temp_allocator)
		cfg_apply_timezone("Asia/Tokyo")
		ws_check(os.get_env("TZ", context.temp_allocator) == ":Asia/Tokyo", "timezone = sets TZ for what the wm starts")
		cfg_apply_timezone("Nowhere/Atlantis")
		ws_check(os.get_env("TZ", context.temp_allocator) == before, "an unknown zone gives back the session's TZ")
		cfg_apply_timezone("")
	}

	// --- typing into the start menu ----------------------------------------
	{
		r, ok := key_rune('a')
		ws_check(ok && r == 'a', "a letter keysym types its letter")
		r, ok = key_rune(0xe9)
		ws_check(ok && r == 'é', "a Latin-1 keysym types its character")
		r, ok = key_rune(0x010003b1)
		ws_check(ok && r == 'α', "a Unicode keysym types its character")
		_, ok = key_rune(p.KEY_RETURN)
		ws_check(!ok, "Return types nothing")
	}

	// --- searching: apps, then the settings page a word names ---------------
	{
		old_dir := strings.clone(os.get_env("PALMY_APPLICATIONS_DIR", context.temp_allocator), context.temp_allocator)
		old_path := strings.clone(os.get_env("PATH", context.temp_allocator), context.temp_allocator)
		tmp := fmt.tprintf("/tmp/wm-start-selftest-%d", os.get_pid())
		_ = os.make_directory_all(fmt.tprintf("%s/apps", tmp))
		_ = os.make_directory_all(fmt.tprintf("%s/bin", tmp))
		defer os.remove_all(tmp)
		write :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]byte)text)}
		write(fmt.tprintf("%s/apps/calendar.desktop", tmp), "[Desktop Entry]\nType=Application\nName=Calendar\nExec=calendar\nCategories=Office;Calendar;\n")
		write(fmt.tprintf("%s/apps/term.desktop", tmp), "[Desktop Entry]\nType=Application\nName=Terminal\nExec=term\nIcon=square-terminal\nCategories=System;TerminalEmulator;\n")
		write(fmt.tprintf("%s/apps/darktable.desktop", tmp), "[Desktop Entry]\nType=Application\nName=Darktable\nExec=darktable\nCategories=Graphics;\n")
		write(fmt.tprintf("%s/bin/settings", tmp), "#!/bin/sh\n")
		os.set_env("PALMY_APPLICATIONS_DIR", fmt.tprintf("%s/apps", tmp))
		os.set_env("PATH", fmt.tprintf("%s/bin", tmp))
		defer {
			if old_dir == "" {
				os.unset_env("PALMY_APPLICATIONS_DIR")
			} else {
				os.set_env("PALMY_APPLICATIONS_DIR", old_dir)
			}
			os.set_env("PATH", old_path)
			start.indexed = false
		}
		start.indexed = false
		start_index_ensure(fresh = true)
		ws_check(len(start.entries) == 3, "the index reads the applications directory")

		search :: proc(q: string) {
			strings.builder_reset(&start.query)
			strings.write_string(&start.query, q)
			start_search()
		}
		search("term")
		ws_check(len(start.res_apps) >= 1 && start.entries[start.res_apps[0]].name == "Terminal" && !start.best_set, "a name prefix is the best match")
		search("dark")
		ws_check(len(start.res_apps) >= 1 && start.entries[start.res_apps[0]].name == "Darktable" && !start.best_set, "an app named by the word beats the settings page")
		search("wifi")
		ws_check(len(start.res_set) >= 1 && SETTINGS_PAGES[start.res_set[0]].page == "network" && start.best_set, "a word on a settings page finds it")
		search("nat scr")
		ws_check(len(start.res_set) >= 1 && SETTINGS_PAGES[start.res_set[0]].page == "mouse", "every word of the query starts a word on the page")
		search("zzzz")
		ws_check(len(start.res_apps) == 0 && len(start.res_set) == 0, "nothing matches nonsense")
		strings.builder_reset(&start.query)

		// Arrow keys move through the grid by geometry.
		clear(&start.hits)
		for row in 0 ..< 2 {
			for col in 0 ..< 3 {
				append(&start.hits, Start_Hit{kind = .App, rect = {f32(col) * 100, f32(row) * 90, 96, 86}, idx = row * 3 + col, nav = true})
			}
		}
		start.sel = 1
		start_move(0, 1)
		ws_check(start.sel == 4, "Down goes to the item below")
		start_move(1, 0)
		ws_check(start.sel == 5, "Right goes to the next item")
		start_move(0, -1)
		ws_check(start.sel == 2, "Up goes to the item above")
		start_move(0, -1)
		ws_check(start.sel == 2, "Up from the top row stays")
		clear(&start.hits)
	}

	// --- opening and closing -------------------------------------------------
	{
		was := s.cfg.super_menu
		s.cfg.super_menu = true
		super_tap_fire(s)
		ws_check(start.open && !ov.open, "a Super tap opens the start menu")
		super_tap_fire(s)
		ws_check(!start.open, "a second tap closes it")
		s.cfg.super_menu = false
		super_tap_fire(s)
		ws_check(ov.open && !start.open, "super_tap = overview opens the overview")
		super_tap_fire(s)
		ws_check(!ov.open, "and a tap closes it")
		s.cfg.super_menu = was
		start_open(s)
		overview_toggle(s)
		ws_check(!start.open && ov.open, "opening the overview closes the start menu")
		overview_toggle(s)
	}
}
