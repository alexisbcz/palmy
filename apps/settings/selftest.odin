package main

// `settings --selftest`: the parsers against fixtures, wm.conf editing, and
// the command line end to end against a scratch $XDG_CONFIG_HOME. Nothing
// outside a temporary directory is written; wpctl is never run.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

selftest :: proc() -> int {
	pass, fail := 0, 0
	check :: proc(pass, fail: ^int, ok: bool, what: string) {
		if ok {
			pass^ += 1
		} else {
			fail^ += 1
			fmt.eprintfln("  FAIL %s", what)
		}
	}

	// --- editing wm.conf ----------------------------------------------------
	{
		orig := "# my config\nbind = $mod, Return, spawn term\ntheme = dark // the old look\ngaps_in = 4\n"
		t := conf_set(orig, "theme", "light", allocator = context.temp_allocator)
		v, ok := conf_get(t, "theme")
		check(&pass, &fail, ok && v == "light", "set rewrites the line in place")
		check(&pass, &fail, strings.has_prefix(t, "# my config\nbind = $mod, Return, spawn term\n"), "every other line is kept as it was")
		check(&pass, &fail, strings.count(t, "theme") == 1, "no second theme line")
		t2 := conf_set(t, "natural_scroll", "on", allocator = context.temp_allocator)
		check(&pass, &fail, strings.contains(t2, "\n# Settings\nnatural_scroll") && strings.has_suffix(t2, "= on\n"), "a new value goes under the marker")
		t3 := conf_set(t2, "accent", "#14b8a6", allocator = context.temp_allocator)
		check(&pass, &fail, strings.count(t3, CONF_MARKER) == 1, "one marker however many values are added")
		av, _ := conf_get(t3, "accent")
		check(&pass, &fail, av == "#14b8a6", "a colour survives (# is not a comment mid-line)")
		t4 := conf_set(t3, "theme", "", remove = true, allocator = context.temp_allocator)
		_, has := conf_get(t4, "theme")
		check(&pass, &fail, !has && strings.contains(t4, "gaps_in = 4"), "remove deletes the setting and nothing else")
		dup := conf_set("theme = dark\ntheme = light\n", "theme", "dark", allocator = context.temp_allocator)
		check(&pass, &fail, dup == "theme = dark\ntheme               = dark\n", "the last of several lines is the one rewritten")
	}

	// --- values -----------------------------------------------------------
	{
		k, _ := find_key("mouse.natural_scroll")
		v, why := normalise(k, "Yes")
		check(&pass, &fail, v == "on" && why == "", "booleans are spelled on/off")
		_, why = normalise(k, "maybe")
		check(&pass, &fail, why != "", "a non-boolean is refused")
		a, _ := find_key("appearance.accent")
		v, why = normalise(a, "14B8A6")
		check(&pass, &fail, v == "#14b8a6", "a colour gets its # and lower case")
		_, why = normalise(a, "#12345")
		check(&pass, &fail, why != "", "a short colour is refused")
		r, _ := find_key("keyboard.repeat_rate")
		_, why = normalise(r, "500")
		check(&pass, &fail, why != "", "a rate out of range is refused")
		th, _ := find_key("appearance.theme")
		_, why = normalise(th, "blue")
		check(&pass, &fail, why != "", "an unknown theme is refused")
		l, _ := find_key("keyboard.layout")
		_, why = normalise(l, "fr;rm -rf")
		check(&pass, &fail, why != "", "a layout is a code, not a command")
		if os.exists(ZONEINFO + "/Europe/Paris") {
			z, _ := find_key("datetime.timezone")
			v, why = normalise(z, "Europe/Paris")
			check(&pass, &fail, v == "Europe/Paris", "a real zone is accepted")
			_, why = normalise(z, "../../etc/passwd")
			check(&pass, &fail, why != "", "a path is not a zone")
		}
	}

	// --- parsers --------------------------------------------------------------
	{
		lst := "! model\n  pc105           Generic 105-key PC\n\n! layout\n  us              English (US)\n  fr              French\n  de              German\n\n! variant\n  azerty          fr: French (AZERTY)\n"
		ls := parse_layouts(lst, context.temp_allocator)
		check(&pass, &fail, len(ls) == 3 && ls[0].code == "us" && ls[1].name == "French", "layouts from the ! layout section, by name")

		status := "PipeWire 'pipewire-0' [1.4.2]\n └─ Clients:\n\nAudio\n ├─ Devices:\n │      44. Built-in Audio                      [alsa]\n │  \n ├─ Sinks:\n │  *   46. Built-in Audio Analog Stereo        [vol: 0.40]\n │      51. USB Headset                         [vol: 1.00 MUTED]\n │  \n ├─ Sources:\n │  *   47. Built-in Audio Analog Stereo        [vol: 1.00]\n │  \n └─ Streams:\n\nVideo\n ├─ Sinks:\n │      90. Not audio\n"
		sinks, sources := parse_wpctl_status(status, context.temp_allocator)
		check(&pass, &fail, len(sinks) == 2 && sinks[0].def && sinks[0].id == 46 && sinks[0].volume == 0.40, "wpctl sinks, the default starred")
		check(&pass, &fail, len(sinks) == 2 && sinks[1].name == "USB Headset" && !sinks[1].def, "sink names lose the volume tag")
		check(&pass, &fail, len(sources) == 1 && sources[0].id == 47, "wpctl sources; Video is not audio")
		vol, muted, vok := parse_wpctl_volume("Volume: 0.62 [MUTED]\n")
		check(&pass, &fail, vok && muted && vol > 0.61 && vol < 0.63, "wpctl get-volume, muted")

		addrs := parse_ip_addr("1: lo    inet 127.0.0.1/8 scope host lo\n2: eth0    inet 10.0.2.15/24 brd 10.0.2.255 scope global eth0\n2: eth0    inet6 fe80::1/64 scope link\n2: eth0    inet6 2001:db8::5/64 scope global\n", "eth0", context.temp_allocator)
		check(&pass, &fail, len(addrs) == 2 && addrs[0] == "10.0.2.15/24" && addrs[1] == "2001:db8::5/64", "ip -o addr, link-local left out")

		zones := parse_zone_tab("# comment\nFR\t+4852+00220\tEurope/Paris\nJP\t+353916+1394441\tAsia/Tokyo\n", context.temp_allocator)
		check(&pass, &fail, len(zones) == 3 && zones[0] == "Asia/Tokyo" && zones[2] == "UTC", "zone1970.tab, sorted, UTC added")

		users := parse_passwd("root:x:0:0::/root:/bin/sh\ncamille:x:1000:1000:Camille Roux,,,:/home/camille:/bin/sh\nnobody:x:65534:65534::/:/bin/false\n", "wheel:x:10:root,camille\ncamille:x:1000:\naudio:x:63:camille\n", context.temp_allocator)
		check(&pass, &fail, len(users) == 1 && users[0].gecos == "Camille Roux" && len(users[0].groups) == 3, "people, not system accounts, with their groups")

		name, ver, from, pok := parse_palm_line("libfoo-0.9.1-r1 [upgradable from: 0.9.1-r0]")
		check(&pass, &fail, pok && name == "libfoo" && ver == "0.9.1-r1" && from == "0.9.1-r0", "palm list lines")
		name, ver, _, pok = parse_palm_line("palm-browser-cef-120.1.0-r0 [installed]")
		check(&pass, &fail, pok && name == "palm-browser-cef" && ver == "120.1.0-r0", "names with dashes")

		on, ov := parse_os_release("NAME=\"Palmframe\"\nVERSION_ID=0.1.0\n")
		check(&pass, &fail, on == "Palmframe" && ov == "0.1.0", "os-release")
		cm, cc := parse_cpuinfo("processor\t: 0\nmodel name\t: Test CPU\nprocessor\t: 1\nmodel name\t: Test CPU\n")
		check(&pass, &fail, cm == "Test CPU" && cc == 2, "cpuinfo")
		check(&pass, &fail, parse_meminfo_total("MemTotal:       16384000 kB\nMemFree: 1 kB\n") == 16384000, "meminfo")

		st := parse_wm_state(`{"pid": 3, "display": "wayland-1", "bare": true, "config": "/c", "keyboard": {"layout": "fr", "rmlvo": "evdev/pc105/fr", "from": "/etc/palm/keyboard", "file": "/etc/palm/keyboard", "fell_back": false}, "outputs": [{"name": "Virtual-1", "description": "QEMU", "make": "", "model": "", "x": 0, "y": 0, "width": 1280, "height": 800, "mode_width": 1280, "mode_height": 800, "refresh_mhz": 60000, "scale": 1, "physical_mm": [0, 0], "fallback": false}]}`, context.temp_allocator)
		check(&pass, &fail, st.ok && st.bare && len(st.displays) == 1 && st.displays[0].w == 1280 && st.kbd_layout == "fr", "the wm's state file")
	}

	// --- the command line, end to end in a scratch config home ------------
	{
		tmp := fmt.tprintf("/tmp/settings-selftest-%d", os.get_pid())
		_ = os.make_directory_all(tmp)
		defer os.remove_all(tmp)
		old := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
		os.set_env("XDG_CONFIG_HOME", tmp)
		defer {
			if old == "" {
				os.unset_env("XDG_CONFIG_HOME")
			} else {
				os.set_env("XDG_CONFIG_HOME", old)
			}
		}
		run :: proc(args: ..string) -> int {
			code, _ := kit.cli_args(surface(), args)
			return code
		}
		check(&pass, &fail, run("set", "appearance.theme", "light", "--json") == 0, "settings set appearance.theme light")
		v, _ := wm_get("theme")
		check(&pass, &fail, v == "light", "it lands in wm.conf")
		check(&pass, &fail, run("set", "mouse.natural_scroll", "yes") == 0 && setting_get(&KEYS[9]).value == "on", "a boolean, normalised")
		check(&pass, &fail, run("set", "appearance.theme", "plaid") == kit.EXIT_USAGE, "a bad value exits 2")
		check(&pass, &fail, run("get", "no.such.key") == kit.EXIT_NOT_FOUND, "an unknown key exits 3")
		check(&pass, &fail, run("set", "appearance.accent", "#14b8a6", "--dry-run", "--json") == 0, "dry run")
		_, has := wm_get("accent")
		check(&pass, &fail, !has, "a dry run writes nothing")
		check(&pass, &fail, run("reset", "appearance.theme") == 0, "reset")
		_, has = wm_get("theme")
		check(&pass, &fail, !has && setting_get(&KEYS[0]).value == "dark", "reset removes the line; the default shows")
		check(&pass, &fail, run("set", "appearance.wallpaper_color", "#134e4a") == 0, "a wallpaper colour")
		check(&pass, &fail, run("set", "appearance.wallpaper", "/tmp/x.png") == 0, "a wallpaper picture")
		_, has = wm_get("wallpaper_color")
		check(&pass, &fail, !has, "a picture replaces a colour")
		check(&pass, &fail, run("set", "keyboard.layout", "de") == 0, "a keyboard layout")
		kf := kbd_read(kbd_user_path())
		check(&pass, &fail, kf.exists && kf.layout == "de", "it lands in the user's keyboard file")
		check(&pass, &fail, run("reset", "keyboard.layout") == 0 && !os.exists(kbd_user_path()), "reset gives back the system layout")
		check(&pass, &fail, run("list", "--json") == 0, "settings list")
		check(&pass, &fail, run("get", "--json") == 0, "settings get (all)")
		check(&pass, &fail, run("show", "about", "--json") == 0, "settings show about")
	}

	fmt.printfln("settings --selftest: %d passed, %d failed", pass, fail)
	return fail == 0 ? 0 : 1
}
