package main

// Reading the system's application index out of freedesktop `.desktop` files.
//
// The whole index is parsed once at startup. Every string in an Entry points
// straight into the file's own bytes, which are kept for the lifetime of the
// process, so a scan of ~100 files is a handful of allocations rather than
// thousands.

import "core:os"
import "core:slice"
import "core:strings"

Category :: enum u8 {
	Other,
	Dev,
	Web,
	Media,
	Office,
	System,
	Utility,
	Game,
}

CAT_LABEL := [Category]string {
	.Other   = "Other",
	.Dev     = "Dev",
	.Web     = "Web",
	.Media   = "Media",
	.Office  = "Office",
	.System  = "System",
	.Utility = "Utility",
	.Game    = "Games",
}

// A `[Desktop Action <id>]` group: the extra verbs an application advertises,
// such as Firefox's private window or Code's empty window.
Dsk_Action :: struct {
	id:   string,
	name: string,
	exec: string,
}

Entry :: struct {
	id:       string, // "firefox.desktop" — the desktop file id
	name:     string,
	comment:  string,
	exec:     string, // Exec with the %f/%u/%F/%U field codes removed
	icon:     string,
	cats:     string, // the raw Categories= value
	keywords: string, // the raw Keywords= value
	path:     string, // absolute path of the .desktop file
	terminal: bool,
	cat:      Category,
	actions:  []Dsk_Action,
	editable: bool, // lives under $HOME, so it can be opened in an editor
	uses:     int, // launches recorded in the usage file

	// Lowercased, for matching.
	lower:    string, // the name
	lcomment: string, // the comment
	hay:      string, // name + comment + exec + categories + id
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

search_dirs :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	append(&out, "/usr/share/applications")
	append(&out, "/usr/local/share/applications")
	if home, err := os.user_home_dir(allocator); err == nil {
		append(&out, strings.concatenate({home, "/.local/share/applications"}, allocator))
	}
	return out[:]
}

// index_apps walks every search directory in increasing precedence order, so a
// user entry with the same desktop id replaces the system one.
index_apps :: proc(allocator := context.allocator) -> []Entry {
	entries := make([dynamic]Entry, allocator)
	home, _ := os.user_home_dir(context.temp_allocator)

	for dir in search_dirs(context.temp_allocator) {
		infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil {
			continue
		}
		for fi in infos {
			if !strings.has_suffix(fi.name, ".desktop") {
				continue
			}
			path := strings.concatenate({dir, "/", fi.name}, allocator)
			e, ok := parse_desktop(path, fi.name, allocator)
			if !ok {
				continue
			}
			e.editable = home != "" && strings.has_prefix(path, home)

			replaced := false
			for &old, i in entries {
				if old.id == e.id {
					entries[i] = e
					replaced = true
					break
				}
			}
			if !replaced {
				append(&entries, e)
			}
		}
	}

	out := entries[:]
	slice.sort_by(out, proc(a, b: Entry) -> bool {
		return a.lower < b.lower
	})
	return out
}

// parse_desktop reads one file. It returns ok=false for anything that should
// not appear in a launcher: a non-application, a NoDisplay or Hidden entry, or
// an entry with nothing to run.
parse_desktop :: proc(
	path, file: string,
	allocator := context.allocator,
) -> (
	e: Entry,
	ok: bool,
) {
	data, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {
		return {}, false
	}
	text := string(data)

	e.id = strings.clone(file, allocator)
	e.path = path

	in_entry := false
	type_ok := false
	raw_exec := ""
	actions_list := ""
	acts := make([dynamic]Dsk_Action, allocator)
	cur := -1 // index into acts, not a pointer: appending can move the array

	it := text
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		if l[0] == '[' {
			end := len(l)
			if l[end - 1] == ']' {
				end -= 1
			}
			g := strings.trim_space(l[1:end])
			in_entry = g == "Desktop Entry"
			cur = -1
			if strings.has_prefix(g, "Desktop Action ") {
				id := strings.trim_space(g[len("Desktop Action "):])
				append(&acts, Dsk_Action{id = id})
				cur = len(acts) - 1
			}
			continue
		}

		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		k := strings.trim_space(l[:eq])
		v := strings.trim_space(l[eq + 1:])
		// Localised keys (`Name[fr]`) are skipped: palmy draws one font and the
		// launcher is only as multilingual as that.
		if strings.index_byte(k, '[') >= 0 {
			continue
		}

		if cur >= 0 {
			switch k {
			case "Name":
				acts[cur].name = v
			case "Exec":
				acts[cur].exec = strip_field_codes(v, allocator)
			}
			continue
		}
		if !in_entry {
			continue
		}

		switch k {
		case "Type":
			type_ok = v == "Application"
		case "Name":
			e.name = v
		case "Comment":
			if e.comment == "" {
				e.comment = v
			}
		case "GenericName":
			if e.comment == "" {
				e.comment = v
			}
		case "Exec":
			raw_exec = v
		case "Icon":
			e.icon = v
		case "Categories":
			e.cats = v
		case "Keywords":
			e.keywords = v
		case "Terminal":
			e.terminal = v == "true"
		case "NoDisplay":
			if v == "true" {
				return {}, false
			}
		case "Hidden":
			if v == "true" {
				return {}, false
			}
		case "Actions":
			actions_list = v
		}
	}

	if !type_ok || e.name == "" || raw_exec == "" {
		return {}, false
	}
	e.exec = strip_field_codes(raw_exec, allocator)
	if e.exec == "" {
		return {}, false
	}

	// Keep the declared actions, in the order `Actions=` lists them, and drop
	// any group that has no name or nothing to run.
	keep := make([dynamic]Dsk_Action, allocator)
	ids := strings.split(actions_list, ";", context.temp_allocator)
	for id in ids {
		t := strings.trim_space(id)
		if t == "" {
			continue
		}
		for a in acts {
			if a.id == t && a.name != "" && a.exec != "" {
				append(&keep, a)
				break
			}
		}
	}
	e.actions = keep[:]

	e.cat = classify(e.cats, e.name)
	e.lower = strings.to_lower(e.name, allocator)
	e.lcomment = strings.to_lower(e.comment, allocator)
	e.hay = strings.to_lower(
		strings.concatenate(
			{e.name, " ", e.comment, " ", e.exec, " ", e.cats, " ", e.keywords, " ", e.id},
			allocator,
		),
		allocator,
	)
	return e, true
}

// ---------------------------------------------------------------------------
// Exec lines
// ---------------------------------------------------------------------------

FIELD_CODES :: "fFuUickdDnNvm"

// strip_field_codes removes the `%f %F %u %U` family from an Exec line, which
// is required before handing it to exec: nothing is being opened, so the codes
// have no expansion. `%%` collapses to a literal percent.
strip_field_codes :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 1 < len(s) {
			c := s[i + 1]
			if c == '%' {
				strings.write_byte(&b, '%')
				i += 2
				continue
			}
			if strings.index_byte(FIELD_CODES, c) >= 0 {
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.trim_space(strings.to_string(b))
}

// split_exec splits an Exec value into argv, honouring the double quoting the
// desktop entry spec allows.
split_exec :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(context.temp_allocator)
	in_q := false
	i := 0
	for i <= len(s) {
		at_end := i == len(s)
		c: u8 = at_end ? ' ' : s[i]
		switch {
		case !at_end && c == '"':
			in_q = !in_q
			i += 1
		case !at_end && c == '\\' && i + 1 < len(s):
			strings.write_byte(&b, s[i + 1])
			i += 2
		case (c == ' ' || c == '\t') && !in_q:
			if strings.builder_len(b) > 0 {
				append(&out, strings.clone(strings.to_string(b), allocator))
				strings.builder_reset(&b)
			}
			i += 1
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

has_tag :: proc(cats, tag: string) -> bool {
	return strings.contains(cats, tag)
}

// classify picks the one bucket a chip filter can use. Desktop categories
// overlap freely, so the order here is the precedence: the most specific
// grouping a user would look under wins.
classify :: proc(cats, name: string) -> Category {
	c := cats
	switch {
	case has_tag(c, "Game"):
		return .Game
	case has_tag(c, "Development") || has_tag(c, "IDE") || has_tag(c, "TextEditor") ||
	     has_tag(c, "Building") || has_tag(c, "Debugger"):
		return .Dev
	case has_tag(c, "WebBrowser") || has_tag(c, "Email") || has_tag(c, "InstantMessaging") ||
	     has_tag(c, "Network") || has_tag(c, "Chat") || has_tag(c, "Feed"):
		return .Web
	case has_tag(c, "AudioVideo") || has_tag(c, "Audio") || has_tag(c, "Video") ||
	     has_tag(c, "Graphics") || has_tag(c, "Photography") || has_tag(c, "Player") ||
	     has_tag(c, "Music"):
		return .Media
	case has_tag(c, "Office") || has_tag(c, "Spreadsheet") || has_tag(c, "WordProcessor") ||
	     has_tag(c, "Presentation") || has_tag(c, "Calendar") || has_tag(c, "Finance") ||
	     has_tag(c, "Publishing"):
		return .Office
	case has_tag(c, "Settings") || has_tag(c, "System") || has_tag(c, "Monitor") ||
	     has_tag(c, "Security") || has_tag(c, "HardwareSettings") ||
	     has_tag(c, "TerminalEmulator") || has_tag(c, "FileManager"):
		return .System
	case has_tag(c, "Utility") || has_tag(c, "Accessories") || has_tag(c, "Archiving") ||
	     has_tag(c, "Viewer") || has_tag(c, "Calculator"):
		return .Utility
	}
	return .Other
}

// ---------------------------------------------------------------------------
// Usage history
//
// Ranking by frecency is what makes a launcher feel like it knows you, so the
// count of launches per desktop id is kept in the user's cache directory. The
// file is a plain `<count> <id>` list, which is also what makes the menu's
// "Clear Usage History" a real, reversible-by-use action.
// ---------------------------------------------------------------------------

usage_path :: proc(allocator := context.allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.concatenate({home, "/.cache/palmy-launcher/usage"}, allocator)
}

load_usage :: proc(entries: []Entry) {
	path := usage_path(context.temp_allocator)
	if path == "" {
		return
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		sp := strings.index_byte(line, ' ')
		if sp <= 0 {
			continue
		}
		n := 0
		for c in line[:sp] {
			if c < '0' || c > '9' {
				n = 0
				break
			}
			n = n * 10 + int(c - '0')
		}
		id := strings.trim_space(line[sp + 1:])
		for &e in entries {
			if e.id == id {
				e.uses = n
				break
			}
		}
	}
}

save_usage :: proc(entries: []Entry) {
	path := usage_path(context.temp_allocator)
	if path == "" {
		return
	}
	dir := path[:strings.last_index_byte(path, '/')]
	_ = os.make_directory_all(dir)
	b := strings.builder_make(context.temp_allocator)
	for e in entries {
		if e.uses > 0 {
			strings.write_int(&b, e.uses)
			strings.write_byte(&b, ' ')
			strings.write_string(&b, e.id)
			strings.write_byte(&b, '\n')
		}
	}
	_ = os.write_entire_file(path, transmute([]byte)strings.to_string(b))
}

clear_usage :: proc(entries: []Entry) {
	for &e in entries {
		e.uses = 0
	}
	path := usage_path(context.temp_allocator)
	if path != "" {
		_ = os.remove(path)
	}
}
