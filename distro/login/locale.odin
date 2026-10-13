package login

// The language and time zone a session starts with.
//
// There is no PAM here to run pam_env, and no systemd to read
// /etc/locale.conf, so palm-login does what those would: every session it
// starts — the greeter's and the user's — gets the system's language from
// /etc/locale.conf, read again at each start so a change (the installer
// writes the file; so might a settings app) shows on the next login screen
// without restarting anything.
//
//	/etc/locale.conf     LANG=fr_FR.UTF-8          -> LANG, and LANGUAGE and
//	                     LANGUAGE=fr:en               the LC_* overrides if set
//	/etc/localtime       TZif, a symlink into /usr/share/zoneinfo; glibc and
//	                     the greeter read it themselves, so nothing is exported
//	/etc/timezone        Europe/Paris               -> TZ=Europe/Paris, but only
//	                                                   when /etc/localtime is missing
//
// TZ is exported only in that last case because a TZ in the environment
// overrides /etc/localtime for good: a user who changed the zone later would
// keep the old one in every program started from the session.
//
// The format is systemd's locale.conf(5): KEY=value lines, `#` comments,
// values optionally in single or double quotes. Keys it does not know are
// ignored rather than exported, so a typo cannot inject PATH or LD_PRELOAD
// into a root-owned session start.

import "core:os"
import "core:strings"

// LOCALE_KEYS are the variables locale.conf may set.
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

// parse_locale_conf returns the KEY=value pairs to export, in the order the
// file gives them, the last of a repeated key winning.
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
			if k == key {
				known = true
			}
		}
		// A value with a newline or NUL cannot come from a line; a value with
		// spaces or '=' is not a locale name either.
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
		if !replaced {
			append(&out, entry)
		}
	}
	return out[:]
}

// parse_timezone_file reads /etc/timezone: one zone name, like Europe/Paris.
// Anything that is not a plausible zone name gives "".
parse_timezone_file :: proc(text: string) -> string {
	name := strings.trim_space(text)
	if nl := strings.index_byte(name, '\n'); nl >= 0 {
		name = strings.trim_space(name[:nl])
	}
	if name == "" || strings.has_prefix(name, "/") || strings.contains(name, "..") {
		return ""
	}
	for ch in name {
		ok := ch >= 'A' && ch <= 'Z' || ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' ||
			ch == '/' || ch == '_' || ch == '-' || ch == '+'
		if !ok {
			return ""
		}
	}
	return name
}

// system_locale_env is the environment every session gets from the files
// above. Missing files are not an error: base_env's LANG=C.UTF-8 stands.
system_locale_env :: proc(paths: Paths, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if paths.locale_conf != "" {
		if text, ok := read_text(paths.locale_conf); ok {
			append(&out, ..parse_locale_conf(text, allocator))
		}
	}
	// os.exists follows the symlink, so a /etc/localtime pointing at a zone
	// tzdata does not have counts as missing too — which is what glibc
	// would make of it.
	if paths.timezone != "" && paths.localtime != "" && !os.exists(paths.localtime) {
		if text, ok := read_text(paths.timezone); ok {
			if zone := parse_timezone_file(text); zone != "" {
				append(&out, strings.concatenate({"TZ=", zone}, allocator))
			}
		}
	}
	return out[:]
}
