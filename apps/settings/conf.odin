package main

// The files Settings changes, and only those: the window manager's
// configuration and the keyboard file beside it. The wm re-reads both within
// a second of a save, so a change made here is on screen without restarting
// anything and without a protocol between the two programs.
//
// wm.conf is a person's file as much as ours. Setting a value rewrites the
// last line that sets it and leaves every other line — comments, bindings,
// rules, blank lines — exactly as it was; a value that was never set is
// appended under a "# Settings" marker so it is clear where it came from.
// Removing a value (back to the default) deletes its lines.

import "core:fmt"
import "core:os"
import "core:strings"

config_home :: proc() -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return x
	}
	return fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
}

wm_conf_path :: proc() -> string {
	if v := os.get_env("PALMY_WM_CONFIG", context.temp_allocator); v != "" {
		return v
	}
	return fmt.tprintf("%s/palmy/wm.conf", config_home())
}

kbd_user_path :: proc() -> string {
	return fmt.tprintf("%s/palmy/keyboard", config_home())
}

KBD_SYSTEM_PATH :: "/etc/palm/keyboard"

// conf_line_key is the setting a line sets, or "" for a comment, a blank
// line or anything else.
conf_line_key :: proc(line: string) -> (key, val: string) {
	t := strings.trim_space(line)
	if t == "" || t[0] == '#' || strings.has_prefix(t, "//") {
		return "", ""
	}
	eq := strings.index_byte(t, '=')
	if eq <= 0 {
		return "", ""
	}
	key = strings.trim_space(t[:eq])
	val = strings.trim_space(t[eq + 1:])
	// An inline comment is " // ..." (the wm's rule: `#` would eat colours).
	for i in 1 ..< max(len(val) - 1, 1) {
		if val[i] == '/' && val[i + 1] == '/' && (val[i - 1] == ' ' || val[i - 1] == '\t') {
			val = strings.trim_space(val[:i])
			break
		}
	}
	return
}

// conf_get is the value the last line setting `key` gives, and whether one
// does.
conf_get :: proc(text, key: string) -> (val: string, ok: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		k, v := conf_line_key(line)
		if k == key {
			val, ok = v, true
		}
	}
	return
}

CONF_MARKER :: "# Settings"

// conf_set returns the text with `key = value`: the last line that sets it
// rewritten in place (earlier ones are left, since the last one wins), or a
// new line appended. `value == ""` with `remove` deletes every line setting
// it instead.
conf_set :: proc(text, key, value: string, remove := false, allocator := context.allocator) -> string {
	lines := strings.split_lines(text, context.temp_allocator)
	// split_lines gives a trailing "" for text ending in a newline.
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	last := -1
	for l, i in lines {
		if k, _ := conf_line_key(l); k == key {
			last = i
		}
	}
	b := strings.builder_make(allocator)
	pad := max(20, len(key) + 1)
	line_for :: proc(key, value: string, pad: int) -> string {
		return fmt.tprintf("%s%*s= %s", key, pad - len(key), "", value)
	}
	for l, i in lines {
		k, _ := conf_line_key(l)
		if k == key && remove {
			continue
		}
		if i == last && !remove {
			strings.write_string(&b, line_for(key, value, pad))
		} else {
			strings.write_string(&b, l)
		}
		strings.write_byte(&b, '\n')
	}
	if last < 0 && !remove {
		has_marker := false
		for l in lines {
			if strings.trim_space(l) == CONF_MARKER {
				has_marker = true
			}
		}
		if !has_marker {
			if len(lines) > 0 && strings.trim_space(lines[len(lines) - 1]) != "" {
				strings.write_byte(&b, '\n')
			}
			strings.write_string(&b, CONF_MARKER)
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, line_for(key, value, pad))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// write_text replaces a file through a temporary name, so the wm never reads
// half of one.
write_text :: proc(path, text: string) -> bool {
	if sl := strings.last_index_byte(path, '/'); sl > 0 {
		_ = os.make_directory_all(path[:sl])
	}
	tmp := fmt.tprintf("%s.settings-tmp", path)
	if os.write_entire_file(tmp, transmute([]byte)text) != nil {
		return false
	}
	return os.rename(tmp, path) == nil
}

wm_get :: proc(key: string) -> (string, bool) {
	text, _ := read_text(wm_conf_path())
	return conf_get(text, key)
}

wm_set :: proc(key, value: string) -> bool {
	text, _ := read_text(wm_conf_path())
	return write_text(wm_conf_path(), conf_set(text, key, value, allocator = context.temp_allocator))
}

wm_unset :: proc(key: string) -> bool {
	text, ok := read_text(wm_conf_path())
	if !ok {
		return true
	}
	return write_text(wm_conf_path(), conf_set(text, key, "", remove = true, allocator = context.temp_allocator))
}

// ---------------------------------------------------------------------------
// The keyboard file: `layout = fr`, `variant =`, `options =`
// ---------------------------------------------------------------------------

Kbd_File :: struct {
	layout, variant, options: string,
	exists:                   bool,
}

kbd_read :: proc(path: string) -> Kbd_File {
	text, ok := read_text(path)
	if !ok {
		return {}
	}
	k := Kbd_File{exists = true}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := line
		if h := strings.index_byte(l, '#'); h >= 0 {
			l = l[:h]
		}
		eq := strings.index_byte(l, '=')
		if eq <= 0 {
			continue
		}
		key := strings.to_lower(strings.trim_space(l[:eq]), context.temp_allocator)
		val := strings.trim(strings.trim_space(l[eq + 1:]), "\"'")
		switch key {
		case "layout":
			k.layout = val
		case "variant":
			k.variant = val
		case "options", "option":
			k.options = val
		}
	}
	return k
}

kbd_write_user :: proc(layout, variant, options: string) -> bool {
	text := fmt.tprintf(
		"# Written by Settings: the keyboard for this account's sessions.\n# Delete it to use the system's (%s).\nlayout  = %s\nvariant = %s\noptions = %s\n",
		KBD_SYSTEM_PATH, layout, variant, options,
	)
	return write_text(kbd_user_path(), text)
}

kbd_clear_user :: proc() -> bool {
	if !os.exists(kbd_user_path()) {
		return true
	}
	return os.remove(kbd_user_path()) == nil
}
