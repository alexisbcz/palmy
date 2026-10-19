package main

// The settings, as one table both front ends use: the window's controls call
// `setting_set`, and so does `settings set`. Each key says where it lives —
// a line of wm.conf, the keyboard file, or PipeWire — what values it takes,
// and its default, so `settings list --json` is the schema and `settings
// get` can say whether a value is the person's or the default.

import "core:fmt"
import "core:strconv"
import "core:strings"

Key_Kind :: enum u8 {
	Bool,
	Enum,
	Color,
	Int,
	Float,
	Path,
	Zone,
	Layout,
	Text,
}

Key_Store :: enum u8 {
	Wm_Conf, // a line of wm.conf, `conf` names it
	Keyboard, // the per-user keyboard file
	Wpctl, // PipeWire, through wpctl
}

Key :: struct {
	name:   string,
	kind:   Key_Kind,
	store:  Key_Store,
	conf:   string, // the wm.conf name (Wm_Conf), or the field (Keyboard)
	def:    string,
	values: []string, // Enum
	lo, hi: f64, // Int, Float
	help:   string,
}

KEYS := [?]Key {
	{"appearance.theme", .Enum, .Wm_Conf, "theme", "dark", {"dark", "light"}, 0, 0, "the look of the bar, title bars, menus and apps"},
	{"appearance.accent", .Color, .Wm_Conf, "accent", "#6366f1", nil, 0, 0, "the colour of the current workspace, focus and selections"},
	{"appearance.wallpaper", .Path, .Wm_Conf, "wallpaper", "", nil, 0, 0, "a picture for the desktop; empty for the generated gradient"},
	{"appearance.wallpaper_mode", .Enum, .Wm_Conf, "wallpaper_mode", "fill", {"fill", "fit", "center", "tile"}, 0, 0, "how the picture covers the screen"},
	{"appearance.wallpaper_color", .Color, .Wm_Conf, "wallpaper_color", "", nil, 0, 0, "a flat colour instead of a picture; empty for none"},
	{"shell.super_tap", .Enum, .Wm_Conf, "super_tap", "menu", {"menu", "overview", "off"}, 0, 0, "what a lone tap of Super opens"},
	{"shell.bar_pins", .Bool, .Wm_Conf, "bar_pins", "on", nil, 0, 0, "show the apps pinned to the bar"},
	{"shell.hot_corner", .Bool, .Wm_Conf, "hot_corner", "on", nil, 0, 0, "the top-left corner opens the overview"},
	{"shell.animations", .Enum, .Wm_Conf, "animations", "on", {"on", "reduced", "off"}, 0, 0, "window and menu motion"},
	{"mouse.natural_scroll", .Bool, .Wm_Conf, "natural_scroll", "off", nil, 0, 0, "content follows the fingers"},
	{"mouse.tap_to_click", .Bool, .Wm_Conf, "tap_to_click", "on", nil, 0, 0, "a tap on the touchpad clicks"},
	{"mouse.left_handed", .Bool, .Wm_Conf, "left_handed", "off", nil, 0, 0, "swap the primary and secondary buttons"},
	{"mouse.speed", .Float, .Wm_Conf, "pointer_speed", "0", nil, -1, 1, "pointer speed, -1 slow to 1 fast"},
	{"keyboard.layout", .Layout, .Keyboard, "layout", "", nil, 0, 0, "this account's keyboard layout; empty for the system's"},
	{"keyboard.variant", .Text, .Keyboard, "variant", "", nil, 0, 0, "a variant of the layout (\"azerty\", \"dvorak\", ...)"},
	{"keyboard.repeat_delay", .Int, .Wm_Conf, "repeat_delay", "400", nil, 150, 1000, "milliseconds before a held key repeats"},
	{"keyboard.repeat_rate", .Int, .Wm_Conf, "repeat_rate", "25", nil, 5, 60, "repeats per second"},
	{"datetime.timezone", .Zone, .Wm_Conf, "timezone", "", nil, 0, 0, "this session's time zone; empty for the system's"},
	{"sound.volume", .Int, .Wpctl, "volume", "", nil, 0, 150, "the default output's volume, in percent"},
	{"sound.mute", .Bool, .Wpctl, "mute", "", nil, 0, 0, "the default output is muted"},
}

find_key :: proc(name: string) -> (^Key, bool) {
	for &k in KEYS {
		if k.name == name {
			return &k, true
		}
	}
	return nil, false
}

// normalise checks a value against its key and spells it the one way the
// files expect: "on"/"off" for booleans, "#rrggbb" for colours. "" is
// returned with a reason for a value that does not fit.
normalise :: proc(k: ^Key, v_in: string) -> (out: string, why: string) {
	v := strings.trim_space(v_in)
	switch k.kind {
	case .Bool:
		switch strings.to_lower(v, context.temp_allocator) {
		case "on", "true", "yes", "1", "enable", "enabled":
			return "on", ""
		case "off", "false", "no", "0", "disable", "disabled":
			return "off", ""
		}
		return "", "expected on or off"
	case .Enum:
		low := strings.to_lower(v, context.temp_allocator)
		for e in k.values {
			if e == low {
				return e, ""
			}
		}
		return "", fmt.tprintf("expected one of %s", strings.join(k.values, ", ", context.temp_allocator))
	case .Color:
		if v == "" {
			return "", ""
		}
		h := strings.trim_prefix(v, "#")
		if len(h) != 6 {
			return "", "expected a colour as #rrggbb"
		}
		for c in h {
			if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
				return "", "expected a colour as #rrggbb"
			}
		}
		return fmt.tprintf("#%s", strings.to_lower(h, context.temp_allocator)), ""
	case .Int:
		n, ok := strconv.parse_int(v)
		if !ok {
			return "", "expected a whole number"
		}
		if f64(n) < k.lo || f64(n) > k.hi {
			return "", fmt.tprintf("expected %d to %d", int(k.lo), int(k.hi))
		}
		return fmt.tprintf("%d", n), ""
	case .Float:
		f, ok := strconv.parse_f64(v)
		if !ok {
			return "", "expected a number"
		}
		if f < k.lo || f > k.hi {
			return "", fmt.tprintf("expected %v to %v", k.lo, k.hi)
		}
		return fmt.tprintf("%.2f", f), ""
	case .Path, .Text:
		if strings.contains_any(v, "\n\r") {
			return "", "one line only"
		}
		return v, ""
	case .Zone:
		if v == "" || v == "UTC" {
			return v, ""
		}
		if strings.contains(v, "..") || !zone_exists(v) {
			return "", fmt.tprintf("%q is not a time zone in %s", v, ZONEINFO)
		}
		return v, ""
	case .Layout:
		if v == "" {
			return "", ""
		}
		for c in v {
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ',' || c == '_' || c == '-') {
				return "", "expected an XKB layout code such as us, fr or de"
			}
		}
		return v, ""
	}
	return v, ""
}

zone_exists :: proc(z: string) -> bool {
	_, ok := read_text(fmt.tprintf("%s/%s", ZONEINFO, z))
	return ok
}

// Setting is one key's value and where it came from.
Setting :: struct {
	key:    ^Key,
	value:  string,
	source: string, // the file, "default", or "pipewire"
	set:    bool, // the person's, not the default
}

// setting_get reads a key from where it lives.
setting_get :: proc(k: ^Key) -> Setting {
	s := Setting{key = k, value = k.def, source = "default"}
	switch k.store {
	case .Wm_Conf:
		if v, ok := wm_get(k.conf); ok {
			s.value, s.source, s.set = v, wm_conf_path(), true
			if k.kind == .Bool {
				n, _ := normalise(k, v)
				if n != "" {
					s.value = n
				}
			}
			if k.name == "shell.super_tap" {
				switch strings.to_lower(v, context.temp_allocator) {
				case "on", "true", "yes", "1", "start":
					s.value = "menu"
				case "no", "false", "0":
					s.value = "off"
				}
			}
		}
	case .Keyboard:
		u := kbd_read(kbd_user_path())
		if u.exists {
			s.source, s.set = kbd_user_path(), true
			s.value = k.conf == "layout" ? u.layout : u.variant
		} else {
			sys := kbd_read(KBD_SYSTEM_PATH)
			s.value = k.conf == "layout" ? sys.layout : sys.variant
			if sys.exists {
				s.source = KBD_SYSTEM_PATH
			}
		}
	case .Wpctl:
		snd := read_sound(context.temp_allocator)
		if snd.running {
			s.source = "pipewire"
			if k.conf == "volume" {
				s.value = fmt.tprintf("%d", int(snd.volume * 100 + 0.5))
			} else {
				s.value = snd.muted ? "on" : "off"
			}
		} else {
			s.source = "unavailable"
		}
	}
	return s
}

// setting_set writes a key. `dry` checks and reports without writing.
// Returns the normalised value, or a reason it was refused (and whether that
// is because the thing it needs is missing).
setting_set :: proc(k: ^Key, value: string, dry := false) -> (norm: string, why: string, unavailable: bool) {
	n, bad := normalise(k, value)
	if bad != "" {
		return "", bad, false
	}
	if dry {
		return n, "", false
	}
	switch k.store {
	case .Wm_Conf:
		ok: bool
		if n == "" {
			ok = wm_unset(k.conf)
		} else {
			ok = wm_set(k.conf, n)
			// A flat colour and a picture are one choice: setting one clears
			// the other, so the desktop shows what was just picked.
			if ok && k.conf == "wallpaper_color" {
				wm_unset("wallpaper")
			}
			if ok && k.conf == "wallpaper" {
				wm_unset("wallpaper_color")
			}
		}
		if !ok {
			return "", fmt.tprintf("could not write %s", wm_conf_path()), false
		}
	case .Keyboard:
		u := kbd_read(kbd_user_path())
		layout, variant, options := u.layout, u.variant, u.options
		if !u.exists {
			sys := kbd_read(KBD_SYSTEM_PATH)
			layout, variant, options = sys.layout, sys.variant, sys.options
		}
		if k.conf == "layout" {
			if n == "" {
				if !kbd_clear_user() {
					return "", fmt.tprintf("could not remove %s", kbd_user_path()), false
				}
				return n, "", false
			}
			if n != layout {
				variant = "" // a variant belongs to the layout it was chosen for
			}
			layout = n
		} else {
			variant = n
		}
		if layout == "" {
			layout = "us"
		}
		if !kbd_write_user(layout, variant, options) {
			return "", fmt.tprintf("could not write %s", kbd_user_path()), false
		}
	case .Wpctl:
		if !which("wpctl") {
			return "", "wpctl is not installed (package wireplumber)", true
		}
		argv: []string
		if k.conf == "volume" {
			argv = {"wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", fmt.tprintf("%d%%", strconv_atoi(n))}
		} else {
			argv = {"wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", n == "on" ? "1" : "0"}
		}
		if _, ok := run_text(argv); !ok {
			return "", "PipeWire did not answer (is the sound server running?)", true
		}
	}
	return n, "", false
}

strconv_atoi :: proc(s: string) -> int {
	n, _ := strconv.parse_int(s)
	return n
}
