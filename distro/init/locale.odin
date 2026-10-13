package main

// The system language, for services.
//
// Services get the language the machine is set to, from /etc/locale.conf
// (systemd's locale.conf(5): KEY=value, `#` comments, optional quotes) — the
// file the installer writes `LANG=fr_FR.UTF-8` into. palm-init exports LANG,
// and LANGUAGE and the LC_* overrides when the file sets them, to every
// service it starts; a service file's own `env = LANG=...` still wins.
// palm-login does the same for the sessions it starts (distro/login/
// locale.odin), so the greeter and the desktop agree with the services.
//
// The file is read again before each start, not once at boot: the installer
// changes it on a live system, and a service restarted afterwards should
// speak the new language. Only locale variables are taken, so the file
// cannot be used to slip PATH or LD_PRELOAD into a root service.

import "core:strings"

LOCALE_CONF :: "/etc/locale.conf"

@(private = "file")
LOCALE_KEYS := [?]string {
	"LANG",
	"LANGUAGE",
	"LC_CTYPE",
	"LC_NUMERIC",
	"LC_TIME",
	"LC_COLLATE",
	"LC_MONETARY",
	"LC_MESSAGES",
	"LC_PAPER",
	"LC_NAME",
	"LC_ADDRESS",
	"LC_TELEPHONE",
	"LC_MEASUREMENT",
	"LC_IDENTIFICATION",
}

// parse_locale_conf returns the KEY=value pairs to export, the last of a
// repeated key winning.
parse_locale_conf :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		line = strings.trim_prefix(line, "export ")
		eq := strings.index_byte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val) - 1] == val[0] {
			val = val[1:len(val) - 1]
		}
		known := false
		for k in LOCALE_KEYS {
			if k == key {known = true}
		}
		if !known || val == "" || strings.contains_any(val, " \t=\\\"'") {
			continue
		}
		entry := strings.concatenate({key, "=", val}, allocator)
		replaced := false
		for &have in out {
			if strings.has_prefix(have, key) && len(have) > len(key) && have[len(key)] == '=' {
				have = entry
				replaced = true
			}
		}
		if !replaced {append(&out, entry)}
	}
	return out[:]
}

// system_locale_env reads /etc/locale.conf now. No file, no variables: a
// service then runs in the C locale, as it did before there was a file.
system_locale_env :: proc(allocator := context.temp_allocator) -> []string {
	text, ok := read_file(LOCALE_CONF, context.temp_allocator)
	if !ok {
		return nil
	}
	return parse_locale_conf(text, allocator)
}
