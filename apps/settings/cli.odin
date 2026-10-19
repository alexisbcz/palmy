package main

// `settings` on the command line (docs/PALM-CLI.md): the same keys the window
// changes, through the same `setting_set`, and the same readers behind its
// read-only pages.
//
//	settings get appearance.theme --json
//	settings set mouse.natural_scroll on
//	settings reset appearance.accent
//	settings list --json            every key, its type, values and default
//	settings show displays --json   what a read-only page shows
//	settings [page]                 the window, on that page

import "core:fmt"
import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "get",
		summary = "a setting's value and where it comes from; every setting without a key",
		effect = .Read,
		args = {{name = "key", kind = .String, help = "appearance.theme, mouse.natural_scroll, ... (settings list)"}},
		out = {
			{name = "key", kind = .String, opt = true},
			{name = "value", kind = .String, opt = true},
			{name = "default", kind = .String, opt = true},
			{name = "source", kind = .String, opt = true, help = "the file it was read from, \"default\", or \"pipewire\""},
			{name = "settings", kind = .Array, opt = true, of = {{name = "key", kind = .String}, {name = "value", kind = .String}, {name = "source", kind = .String}}},
		},
		examples = {"settings get appearance.theme --json", "settings get --json"},
		run = cmd_get,
	},
	{
		verb = "set",
		summary = "change a setting; the window manager applies it within a second",
		effect = .Idempotent,
		args = {{name = "key", kind = .String, required = true}, {name = "value", kind = .String, required = true, help = "the new value (settings reset puts back the default)"}},
		out = {
			{name = "key", kind = .String},
			{name = "value", kind = .String},
			{name = "previous", kind = .String},
			{name = "file", kind = .String, help = "what was written"},
		},
		examples = {"settings set appearance.theme light", "settings set mouse.natural_scroll on --json", "settings set datetime.timezone Europe/Paris --dry-run --json"},
		run = cmd_set,
	},
	{
		verb = "reset",
		summary = "put a setting back to its default",
		effect = .Idempotent,
		args = {{name = "key", kind = .String, required = true}},
		out = {{name = "key", kind = .String}, {name = "value", kind = .String}, {name = "previous", kind = .String}},
		examples = {"settings reset appearance.accent --json"},
		run = cmd_reset,
	},
	{
		verb = "list",
		summary = "every setting: its type, the values it takes, its default and what it does",
		effect = .Read,
		out = {
			{
				name = "keys",
				kind = .Array,
				of = {
					{name = "key", kind = .String},
					{name = "type", kind = .String},
					{name = "default", kind = .String},
					{name = "values", kind = .Array, opt = true, of = {{kind = .String}}},
					{name = "min", kind = .Float, opt = true},
					{name = "max", kind = .Float, opt = true},
					{name = "help", kind = .String},
				},
			},
		},
		examples = {"settings list --json"},
		run = cmd_list,
	},
	{
		verb = "show",
		summary = "what one page shows: displays, keyboard, sound, network, datetime, users, updates or about",
		effect = .Read,
		args = {{name = "page", kind = .Enum, required = true, values = {"displays", "keyboard", "sound", "network", "datetime", "users", "updates", "about"}}},
		out = {{name = "page", kind = .String}},
		examples = {"settings show displays --json", "settings show about --json"},
		run = cmd_show,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "settings",
			summary    = "the system's settings: appearance, displays, keyboard, mouse, sound, network, time, users, updates",
			commands   = COMMANDS,
			selftest   = selftest,
			gui        = true,
			takes_path = true,
			notes      = "With no command the window opens; `settings keyboard` opens it on that page. Changes go to ~/.config/palmy/wm.conf (and ~/.config/palmy/keyboard), which the window manager re-reads within a second.",
		}
	}
	return &g_surface
}

@(private = "file")
key_arg :: proc(c: ^kit.Call) -> (^Key, int) {
	name := kit.cli_str(c, "key")
	k, ok := find_key(name)
	if !ok {
		kit.cli_err_field(c, "key", name)
		return nil, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no setting %q (settings list shows them all)", name)
	}
	return k, kit.EXIT_OK
}

@(private = "file")
cmd_get :: proc(c: ^kit.Call) -> int {
	if !kit.cli_has(c, "key") {
		arr := kit.jarr()
		for &k in KEYS {
			s := setting_get(&k)
			o := kit.jobj()
			kit.jset_str(o, "key", k.name)
			kit.jset_str(o, "value", s.value)
			kit.jset_str(o, "source", s.source)
			kit.jpush(arr, o)
			if !c.json {
				fmt.printfln("%-28s %s%s", k.name, s.value == "" ? "(none)" : s.value, s.set ? "" : "  (default)")
			}
		}
		kit.jset(c.out, "settings", arr)
		return kit.EXIT_OK
	}
	k, code := key_arg(c)
	if code != kit.EXIT_OK {
		return code
	}
	s := setting_get(k)
	kit.jset_str(c.out, "key", k.name)
	kit.jset_str(c.out, "value", s.value)
	kit.jset_str(c.out, "default", k.def)
	kit.jset_str(c.out, "source", s.source)
	if !c.json {
		fmt.println(s.value)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_set :: proc(c: ^kit.Call) -> int {
	k, code := key_arg(c)
	if code != kit.EXIT_OK {
		return code
	}
	prev := setting_get(k)
	n, why, unavailable := setting_set(k, kit.cli_str(c, "value"), dry = c.dry_run)
	if why != "" {
		return kit.cli_failf(c, unavailable ? kit.EXIT_UNAVAILABLE : kit.EXIT_USAGE, "%s: %s", k.name, why)
	}
	kit.jset_str(c.out, "key", k.name)
	kit.jset_str(c.out, "value", n)
	kit.jset_str(c.out, "previous", prev.value)
	file := k.store == .Wm_Conf ? wm_conf_path() : (k.store == .Keyboard ? kbd_user_path() : "pipewire")
	kit.jset_str(c.out, "file", file)
	if !c.json {
		fmt.printfln("%s = %s%s", k.name, n == "" ? "(default)" : n, c.dry_run ? "  (dry run: nothing written)" : "")
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_reset :: proc(c: ^kit.Call) -> int {
	k, code := key_arg(c)
	if code != kit.EXIT_OK {
		return code
	}
	prev := setting_get(k)
	if !c.dry_run {
		switch k.store {
		case .Wm_Conf:
			wm_unset(k.conf)
		case .Keyboard:
			if k.conf == "layout" {
				kbd_clear_user()
			} else {
				setting_set(k, "")
			}
		case .Wpctl:
			return kit.cli_failf(c, kit.EXIT_USAGE, "%s has no default to go back to", k.name)
		}
	}
	now := setting_get(k)
	kit.jset_str(c.out, "key", k.name)
	kit.jset_str(c.out, "value", c.dry_run ? k.def : now.value)
	kit.jset_str(c.out, "previous", prev.value)
	if !c.json {
		fmt.printfln("%s = %s", k.name, now.value == "" ? "(none)" : now.value)
	}
	return kit.EXIT_OK
}

@(private = "file")
KIND_NAMES := [Key_Kind]string {
	.Bool   = "bool",
	.Enum   = "enum",
	.Color  = "color",
	.Int    = "int",
	.Float  = "float",
	.Path   = "path",
	.Zone   = "timezone",
	.Layout = "xkb-layout",
	.Text   = "string",
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	arr := kit.jarr()
	for &k in KEYS {
		o := kit.jobj()
		kit.jset_str(o, "key", k.name)
		kit.jset_str(o, "type", KIND_NAMES[k.kind])
		kit.jset_str(o, "default", k.def)
		if len(k.values) > 0 {
			va := kit.jarr()
			for v in k.values {
				kit.jpush(va, kit.jstr(v))
			}
			kit.jset(o, "values", va)
		}
		if k.kind == .Int || k.kind == .Float {
			kit.jset_num(o, "min", k.lo)
			kit.jset_num(o, "max", k.hi)
		}
		kit.jset_str(o, "help", k.help)
		kit.jpush(arr, o)
		if !c.json {
			vals := len(k.values) > 0 ? strings.join(k.values, "|", context.temp_allocator) : KIND_NAMES[k.kind]
			fmt.printfln("%-28s %-22s %s", k.name, vals, k.help)
		}
	}
	kit.jset(c.out, "keys", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	page := kit.cli_str(c, "page")
	kit.jset_str(c.out, "page", page)
	o := c.out
	switch page {
	case "displays":
		st := read_wm_state(context.temp_allocator)
		ds := st.ok ? st.displays : sysfs_displays(context.temp_allocator)
		kit.jset_str(o, "source", st.ok ? wm_state_path() : "/sys/class/drm")
		arr := kit.jarr()
		for d in ds {
			x := kit.jobj()
			kit.jset_str(x, "name", d.name)
			kit.jset_str(x, "description", d.desc)
			kit.jset_int(x, "width", d.mode_w)
			kit.jset_int(x, "height", d.mode_h)
			kit.jset_num(x, "refresh_hz", f64(d.refresh_mhz) / 1000)
			kit.jset_int(x, "scale", d.scale)
			kit.jset_int(x, "x", d.x)
			kit.jset_int(x, "y", d.y)
			kit.jpush(arr, x)
			if !c.json {
				fmt.printfln("%-12s %dx%d @ %.2f Hz  scale %d  at %d,%d  %s", d.name, d.mode_w, d.mode_h, f64(d.refresh_mhz) / 1000, d.scale, d.x, d.y, d.desc)
			}
		}
		kit.jset(o, "displays", arr)
	case "keyboard":
		st := read_wm_state(context.temp_allocator)
		l := setting_get(&KEYS[13])
		kit.jset_str(o, "layout", l.value)
		kit.jset_str(o, "source", l.source)
		kit.jset_str(o, "active", st.kbd_rmlvo)
		kit.jset_str(o, "active_from", st.kbd_from)
		if !c.json {
			fmt.printfln("layout %s (from %s); the window manager types with %s", l.value == "" ? "us" : l.value, l.source, st.ok ? st.kbd_rmlvo : "(not running)")
		}
	case "sound":
		snd := read_sound(context.temp_allocator)
		kit.jset_bool(o, "available", snd.available)
		kit.jset_bool(o, "running", snd.running)
		kit.jset_num(o, "volume", f64(snd.volume))
		kit.jset_bool(o, "muted", snd.muted)
		arr := kit.jarr()
		for s in snd.sinks {
			x := kit.jobj()
			kit.jset_int(x, "id", s.id)
			kit.jset_str(x, "name", s.name)
			kit.jset_bool(x, "default", s.def)
			kit.jpush(arr, x)
		}
		kit.jset(o, "outputs", arr)
		if !c.json {
			switch {
			case !snd.available:
				fmt.println("no sound server tools (wpctl, package wireplumber)")
			case !snd.running:
				fmt.println("PipeWire is not running")
			case:
				fmt.printfln("volume %d%%%s", int(snd.volume * 100 + 0.5), snd.muted ? " (muted)" : "")
				for s in snd.sinks {
					fmt.printfln("%s %d. %s", s.def ? "*" : " ", s.id, s.name)
				}
			}
		}
	case "network":
		arr := kit.jarr()
		for i in read_ifaces(context.temp_allocator) {
			x := kit.jobj()
			kit.jset_str(x, "name", i.name)
			kit.jset_str(x, "kind", i.kind)
			kit.jset_str(x, "state", i.state)
			kit.jset_str(x, "mac", i.mac)
			kit.jset_str(x, "ssid", i.ssid)
			aa := kit.jarr()
			for a in i.addrs {
				kit.jpush(aa, kit.jstr(a))
			}
			kit.jset(x, "addresses", aa)
			kit.jpush(arr, x)
			if !c.json {
				fmt.printfln("%-10s %-9s %-8s %s %s", i.name, i.kind, i.state, strings.join(i.addrs, " ", context.temp_allocator), i.ssid)
			}
		}
		kit.jset(o, "interfaces", arr)
	case "datetime":
		tz := setting_get(&KEYS[17])
		kit.jset_str(o, "session_zone", tz.value)
		kit.jset_str(o, "system_zone", system_zone())
		if !c.json {
			fmt.printfln("system %s, this session %s", system_zone(), tz.value == "" ? "(the system's)" : tz.value)
		}
	case "users":
		arr := kit.jarr()
		for u in read_users(context.temp_allocator) {
			x := kit.jobj()
			kit.jset_str(x, "name", u.name)
			kit.jset_str(x, "full_name", u.gecos)
			kit.jset_int(x, "uid", u.uid)
			ga := kit.jarr()
			admin := false
			for g in u.groups {
				kit.jpush(ga, kit.jstr(g))
				admin = admin || g == "wheel"
			}
			kit.jset(x, "groups", ga)
			kit.jset_bool(x, "administrator", admin)
			kit.jpush(arr, x)
			if !c.json {
				fmt.printfln("%-12s %-5d %s%s", u.name, u.uid, strings.join(u.groups, ",", context.temp_allocator), admin ? "  (administrator)" : "")
			}
		}
		kit.jset(o, "users", arr)
	case "updates":
		u := read_updates(context.temp_allocator)
		kit.jset_bool(o, "available", u.available)
		kit.jset_str(o, "system_version", u.system_ver)
		kit.jset_int(o, "installed", u.installed)
		ua := kit.jarr()
		for x in u.upgradable {
			kit.jpush(ua, kit.jstr(x))
		}
		kit.jset(o, "upgradable", ua)
		if !c.json {
			fmt.printfln("Palmframe %s, %d packages, %d upgradable", u.system_ver, u.installed, len(u.upgradable))
		}
	case "about":
		a := read_about(context.temp_allocator)
		kit.jset_str(o, "os", a.os_name)
		kit.jset_str(o, "version", a.os_version)
		kit.jset_str(o, "hostname", a.hostname)
		kit.jset_str(o, "kernel", a.kernel)
		kit.jset_str(o, "cpu", a.cpu)
		kit.jset_int(o, "cores", a.cores)
		kit.jset_int(o, "memory_kb", a.mem_total_kb)
		kit.jset_num(o, "disk_bytes", f64(a.disk_total))
		kit.jset_num(o, "disk_free_bytes", f64(a.disk_free))
		kit.jset_str(o, "graphics", a.gpu)
		if !c.json {
			fmt.printfln("%s %s on %s, kernel %s\n%s (%d cores), %s memory, %s disk (%s free), graphics %s", a.os_name, a.os_version, a.hostname, a.kernel, a.cpu, a.cores, human_bytes(u64(a.mem_total_kb) * 1024), human_bytes(a.disk_total), human_bytes(a.disk_free), a.gpu)
		}
	}
	return kit.EXIT_OK
}
