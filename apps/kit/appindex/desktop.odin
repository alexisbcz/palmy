// Package appindex is the system's application index: the freedesktop
// `.desktop` files on the machine, ranked by a fuzzy matcher, with the user's
// launch history and pinned apps beside them.
//
// Two front ends share it so they can never disagree about what is installed
// or how a query ranks: the launcher (apps/launcher, a layer-shell overlay
// with its own process) and the start menu the window manager draws itself
// (apps/wm/start.odin). It used to live inside the launcher, which made the
// start menu either a copy or a client; a package both import is neither.
//
// The whole index is parsed in one pass. Every string in an Entry points
// straight into the file's own bytes, which are kept for as long as the
// index is, so a scan of ~100 files is a handful of allocations rather than
// thousands. Build an index into an arena (or a dedicated allocator) and
// drop the arena to forget it.
package appindex

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
	Demo, // X-Palmframe-Demo=true: a showcase, not a tool; listed last and marked
}

// CAT_LABEL is the short name, for chips.
CAT_LABEL := [Category]string {
	.Other   = "Other",
	.Dev     = "Dev",
	.Web     = "Web",
	.Media   = "Media",
	.Office  = "Office",
	.System  = "System",
	.Utility = "Utility",
	.Game    = "Games",
	.Demo    = "Demos",
}

// CAT_TITLE is the heading over a group in the start menu's All apps.
CAT_TITLE := [Category]string {
	.Other   = "Other",
	.Dev     = "Development",
	.Web     = "Internet",
	.Media   = "Media",
	.Office  = "Office",
	.System  = "System",
	.Utility = "Utilities",
	.Game    = "Games",
	.Demo    = "Demos",
}

// CAT_ORDER is the order groups are listed in: the work people open a
// computer for first, the plumbing after it, the demos last.
CAT_ORDER :: [?]Category{.Office, .Web, .Media, .Dev, .Utility, .System, .Game, .Other, .Demo}

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
	raw_exec: string, // Exec as written, field codes and all
	icon:     string,
	cats:     string, // the raw Categories= value
	keywords: string, // the raw Keywords= value
	mime:     string, // the raw MimeType= value
	path:     string, // absolute path of the .desktop file
	terminal: bool,
	demo:     bool, // X-Palmframe-Demo=true
	takes_file: bool, // Exec has %f/%F/%u/%U: it opens a document it is given
	cat:      Category,
	actions:  []Dsk_Action,
	editable: bool, // lives under $HOME, so it can be opened in an editor
	uses:     int, // launches recorded in the usage file
	last:     i64, // unix seconds of the last recorded launch, 0 if never

	// Lowercased, for matching.
	lower:    string, // the name
	lcomment: string, // the comment
	hay:      string, // name + comment + exec + categories + keywords + id
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

// search_dirs is where applications are looked for, lowest precedence first.
// PALMY_APPLICATIONS_DIR replaces the whole list with one directory, which is
// how the screenshots and the self-tests index distro/apps/desktop instead of
// whatever happens to be installed on the machine running them.
search_dirs :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if only := os.get_env("PALMY_APPLICATIONS_DIR", context.temp_allocator); only != "" {
		append(&out, strings.clone(only, allocator))
		return out[:]
	}
	data_dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if data_dirs == "" {
		data_dirs = "/usr/local/share:/usr/share"
	}
	// XDG_DATA_DIRS is highest precedence first; the scan wants lowest first.
	parts := strings.split(data_dirs, ":", context.temp_allocator)
	#reverse for d in parts {
		if d == "" {
			continue
		}
		append(&out, strings.concatenate({d, "/applications"}, allocator))
	}
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" {
		append(&out, strings.concatenate({x, "/applications"}, allocator))
	} else if home, err := os.user_home_dir(context.temp_allocator); err == nil {
		append(&out, strings.concatenate({home, "/.local/share/applications"}, allocator))
	}
	return out[:]
}

// index_mtime is the newest modification time of the search directories,
// so a long-lived index (the window manager's) knows when `palm add` put a
// new application in and it is time to scan again.
index_mtime :: proc() -> i64 {
	newest: i64
	for dir in search_dirs(context.temp_allocator) {
		fi, err := os.stat(dir, context.temp_allocator)
		if err != nil {
			continue
		}
		t := fi.modification_time._nsec
		if t > newest {
			newest = t
		}
	}
	return newest
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
				// A user's NoDisplay/Hidden copy of a system entry hides it.
				for old, i in entries {
					if old.id == fi.name {
						ordered_remove(&entries, i)
						break
					}
				}
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
	return parse_desktop_text(string(data), path, file, allocator)
}

// parse_desktop_text is parse_desktop on text already in memory, which is
// what the self-tests feed it.
parse_desktop_text :: proc(
	text, path, file: string,
	allocator := context.allocator,
) -> (
	e: Entry,
	ok: bool,
) {
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
		// index is only as multilingual as that.
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
		case "MimeType":
			e.mime = v
		case "Terminal":
			e.terminal = v == "true"
		case "X-Palmframe-Demo":
			e.demo = v == "true"
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
	e.raw_exec = raw_exec
	e.exec = strip_field_codes(raw_exec, allocator)
	if e.exec == "" {
		return {}, false
	}
	for code in ([?]string{"%f", "%F", "%u", "%U"}) {
		if strings.contains(raw_exec, code) {
			e.takes_file = true
		}
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

	e.cat = e.demo ? .Demo : classify(e.cats, e.name)
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
// Finding entries
// ---------------------------------------------------------------------------

// exec_name is the program an entry runs, without its directory: "files"
// for `Exec=/usr/bin/files %U`.
exec_name :: proc(e: ^Entry) -> string {
	s := e.exec
	if sp := strings.index_any(s, " \t"); sp >= 0 {
		s = s[:sp]
	}
	s = strings.trim(s, "\"")
	if sl := strings.last_index_byte(s, '/'); sl >= 0 {
		s = s[sl + 1:]
	}
	return s
}

// find_id is the entry with that desktop id ("files.desktop", or "files").
find_id :: proc(entries: []Entry, id: string) -> int {
	for &e, i in entries {
		if e.id == id {
			return i
		}
	}
	if !strings.has_suffix(id, ".desktop") {
		for &e, i in entries {
			if len(e.id) == len(id) + 8 && strings.has_prefix(e.id, id) && strings.has_suffix(e.id, ".desktop") {
				return i
			}
		}
	}
	return -1
}

// find_program is the entry that runs `prog` (a binary name, or a path to
// one), which is how a running window is traced back to its application:
// from the client's pid, through /proc/<pid>/exe, to the entry whose Exec
// starts that program. The bare entry is preferred over one that runs it
// with arguments (`term` over `term -e htop`).
find_program :: proc(entries: []Entry, prog: string) -> int {
	name := prog
	if sl := strings.last_index_byte(name, '/'); sl >= 0 {
		name = name[sl + 1:]
	}
	if name == "" {
		return -1
	}
	best := -1
	for &e, i in entries {
		if exec_name(&e) != name {
			continue
		}
		if !strings.contains_any(strings.trim_space(e.exec), " \t") {
			return i
		}
		if best < 0 {
			best = i
		}
	}
	return best
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

// exec_with_file is the argv that opens `file` with an entry: the field code
// in the raw Exec line replaced by the path, or the path appended when the
// entry takes files but its Exec forgot to say where.
exec_with_file :: proc(e: ^Entry, file: string, allocator := context.allocator) -> []string {
	parts := split_exec(e.raw_exec, context.temp_allocator)
	out := make([dynamic]string, allocator)
	placed := false
	for a in parts {
		switch a {
		case "%f", "%F", "%u", "%U":
			if !placed {
				append(&out, strings.clone(file, allocator))
				placed = true
			}
		case:
			stripped := strip_field_codes(a, context.temp_allocator)
			if stripped != "" {
				append(&out, strings.clone(stripped, allocator))
			}
		}
	}
	if !placed && file != "" {
		append(&out, strings.clone(file, allocator))
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

has_tag :: proc(cats, tag: string) -> bool {
	return strings.contains(cats, tag)
}

// classify picks the one bucket a chip filter or a start-menu group can use.
// Desktop categories overlap freely, so the order here is the precedence: the
// most specific grouping a user would look under wins.
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
	     has_tag(c, "Publishing") || has_tag(c, "ContactManagement"):
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
