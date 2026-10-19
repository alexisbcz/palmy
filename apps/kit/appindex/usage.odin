package appindex

// The user's own state beside the index: how often and how lately each entry
// was launched, which entries are pinned (to the start menu and to the bar),
// and the files touched lately.
//
// Ranking by frecency is what makes a launcher feel like it knows you, so the
// launches are kept in the cache directory as a plain `<count> <id> [<unix
// time>]` list; the time column is new, and a file written before it existed
// still reads (its entries just have no recency). Pins are a preference, not
// a cache, so they live under $XDG_CONFIG_HOME/palmy: one desktop id per
// line, in the order they are shown.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

home_dir :: proc() -> string {
	if h := os.get_env("HOME", context.temp_allocator); h != "" {
		return h
	}
	h, err := os.user_home_dir(context.temp_allocator)
	return err == nil ? h : ""
}

config_dir :: proc(allocator := context.temp_allocator) -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/palmy", x, allocator = allocator)
	}
	h := home_dir()
	if h == "" {
		return ""
	}
	return fmt.aprintf("%s/.config/palmy", h, allocator = allocator)
}

usage_path :: proc(allocator := context.allocator) -> string {
	h := home_dir()
	if h == "" {
		return ""
	}
	return strings.concatenate({h, "/.cache/palmy-launcher/usage"}, allocator)
}

// Pin_List names one of the two pinned sets.
Pin_List :: enum u8 {
	Start, // the start menu's grid (and the launcher's "pinned to the top")
	Bar, // the bar's quick-launch buttons
}

pins_path :: proc(which: Pin_List, allocator := context.allocator) -> string {
	d := config_dir(context.temp_allocator)
	if d == "" {
		return ""
	}
	return strings.concatenate({d, which == .Start ? "/pinned" : "/pinned-bar"}, allocator)
}

// The launcher kept its pins in its cache before there was a start menu to
// share them with; they are read from there once, when the new file does not
// exist yet.
@(private)
legacy_pins_path :: proc() -> string {
	h := home_dir()
	return h == "" ? "" : strings.concatenate({h, "/.cache/palmy-launcher/pinned"}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

Usage_Line :: struct {
	id:    string,
	count: int,
	last:  i64,
}

// parse_usage reads the usage file's text. Lines that do not parse are
// skipped: the file is a cache, and a damaged one should cost history, not
// the launcher.
parse_usage :: proc(text: string, allocator := context.temp_allocator) -> []Usage_Line {
	out := make([dynamic]Usage_Line, allocator)
	it := text
	for line in strings.split_lines_iterator(&it) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			continue
		}
		n, ok := parse_uint(fields[0])
		if !ok {
			continue
		}
		u := Usage_Line{id = strings.clone(fields[1], allocator), count = n}
		if len(fields) >= 3 {
			if t, tok := parse_uint(fields[2]); tok {
				u.last = i64(t)
			}
		}
		append(&out, u)
	}
	return out[:]
}

@(private)
parse_uint :: proc(s: string) -> (n: int, ok: bool) {
	if s == "" {
		return 0, false
	}
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, true
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
	for u in parse_usage(string(data)) {
		for &e in entries {
			if e.id == u.id {
				e.uses = u.count
				e.last = u.last
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
			fmt.sbprintf(&b, "%d %s %d\n", e.uses, e.id, e.last)
		}
	}
	_ = os.write_entire_file(path, transmute([]byte)strings.to_string(b))
}

// note_launch records one launch of an entry: the count for ranking, the time
// for "recent", and the file rewritten at once, since whatever launched it
// may be about to go away.
note_launch :: proc(entries: []Entry, i: int) {
	if i < 0 || i >= len(entries) {
		return
	}
	entries[i].uses += 1
	entries[i].last = time.time_to_unix(time.now())
	save_usage(entries)
}

clear_usage :: proc(entries: []Entry) {
	for &e in entries {
		e.uses = 0
		e.last = 0
	}
	path := usage_path(context.temp_allocator)
	if path != "" {
		_ = os.remove(path)
	}
}

// recent_apps lists up to n entries by their last launch, newest first.
recent_apps :: proc(entries: []Entry, n: int, allocator := context.temp_allocator) -> []int {
	idx := make([dynamic]int, allocator)
	for e, i in entries {
		if e.last > 0 {
			append(&idx, i)
		}
	}
	ctx := entries
	context.user_ptr = &ctx
	slice.sort_by(idx[:], proc(a, b: int) -> bool {
		es := (^[]Entry)(context.user_ptr)^
		return es[a].last > es[b].last
	})
	return idx[:min(n, len(idx))]
}

// ---------------------------------------------------------------------------
// Pins
// ---------------------------------------------------------------------------

// DEFAULT_START_PINS is what a new account's start menu shows before the
// person pins anything; ids that are not installed are skipped.
DEFAULT_START_PINS := [?]string {
	"term.desktop",
	"files.desktop",
	"browser.desktop",
	"mail.desktop",
	"docs.desktop",
	"sheets.desktop",
	"calendar.desktop",
	"notes.desktop",
	"editor.desktop",
	"image.desktop",
	"store.desktop",
	"settings.desktop",
}

DEFAULT_BAR_PINS := [?]string{"term.desktop", "files.desktop", "browser.desktop"}

// load_pins reads one pinned list, in its order. `ok` is false when the
// person never saved one, and the caller shows the defaults instead.
load_pins :: proc(which: Pin_List, allocator := context.allocator) -> (ids: [dynamic]string, ok: bool) {
	ids = make([dynamic]string, allocator)
	path := pins_path(which, context.temp_allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil && which == .Start {
		data, err = os.read_entire_file_from_path(legacy_pins_path(), context.temp_allocator)
	}
	if err != nil {
		return ids, false
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		id := strings.trim_space(line)
		if id == "" || id[0] == '#' {
			continue
		}
		if !strings.has_suffix(id, ".desktop") {
			id = strings.concatenate({id, ".desktop"}, context.temp_allocator)
		}
		dup := false
		for x in ids {
			if x == id {
				dup = true
			}
		}
		if !dup {
			append(&ids, strings.clone(id, allocator))
		}
	}
	return ids, true
}

// pins_or_default is the list to show: the saved one, or the defaults that
// are installed.
pins_or_default :: proc(which: Pin_List, entries: []Entry, allocator := context.allocator) -> [dynamic]string {
	ids, ok := load_pins(which, allocator)
	if ok {
		return ids
	}
	defs := which == .Start ? DEFAULT_START_PINS[:] : DEFAULT_BAR_PINS[:]
	for id in defs {
		if find_id(entries, id) >= 0 {
			append(&ids, strings.clone(id, allocator))
		}
	}
	return ids
}

save_pins :: proc(which: Pin_List, ids: []string) -> bool {
	path := pins_path(which, context.temp_allocator)
	if path == "" {
		return false
	}
	_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	b := strings.builder_make(context.temp_allocator)
	for id in ids {
		strings.write_string(&b, id)
		strings.write_byte(&b, '\n')
	}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}

pin_index :: proc(ids: []string, id: string) -> int {
	for x, i in ids {
		if x == id {
			return i
		}
	}
	return -1
}

// toggle_pin pins an id at the end of a list, or unpins it, and saves the
// list. Returns whether it is pinned now.
toggle_pin :: proc(which: Pin_List, ids: ^[dynamic]string, id: string, allocator := context.allocator) -> bool {
	if i := pin_index(ids[:], id); i >= 0 {
		delete(ids[i], allocator)
		ordered_remove(ids, i)
		save_pins(which, ids[:])
		return false
	}
	append(ids, strings.clone(id, allocator))
	save_pins(which, ids[:])
	return true
}

// ---------------------------------------------------------------------------
// Recent files
// ---------------------------------------------------------------------------

Recent_File :: struct {
	path:  string,
	name:  string,
	mtime: i64,
	dir:   bool,
}

// RECENT_DIRS are where people keep things, relative to $HOME. Scanning them
// for the newest files is what every application here agrees on without
// having to write a shared history: whatever app saved a document, its
// modification time says so.
RECENT_DIRS :: [?]string{"", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Videos", "Notes"}

// recent_files lists the n most recently modified ordinary files under the
// places above (one level deep, hidden files left out, at most a few
// thousand looked at), newest first.
recent_files :: proc(n: int, allocator := context.allocator) -> []Recent_File {
	h := home_dir()
	out := make([dynamic]Recent_File, context.temp_allocator)
	if h == "" {
		return {}
	}
	budget := 4000
	for rel in RECENT_DIRS {
		dir := rel == "" ? h : fmt.tprintf("%s/%s", h, rel)
		infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil {
			continue
		}
		for fi in infos {
			budget -= 1
			if budget <= 0 {
				break
			}
			if len(fi.name) == 0 || fi.name[0] == '.' || fi.type != .Regular {
				continue
			}
			append(&out, Recent_File{path = fi.fullpath, name = fi.name, mtime = fi.modification_time._nsec})
		}
	}
	slice.sort_by(out[:], proc(a, b: Recent_File) -> bool {
		return a.mtime > b.mtime
	})
	res := make([]Recent_File, min(n, len(out)), allocator)
	for i in 0 ..< len(res) {
		res[i] = out[i]
		res[i].path = strings.clone(out[i].path, allocator)
		res[i].name = res[i].path[len(res[i].path) - len(out[i].name):]
	}
	return res
}

// ---------------------------------------------------------------------------
// Opening a file
// ---------------------------------------------------------------------------

// EXT_MIME is the handful of extensions this system has applications for,
// as the MimeType= values their .desktop files declare.
@(private)
EXT_MIME := [?]struct {
	ext, mime: string,
} {
	{".txt", "text/plain"},
	{".md", "text/markdown"},
	{".odin", "text/plain"},
	{".c", "text/plain"},
	{".h", "text/plain"},
	{".py", "text/plain"},
	{".sh", "text/plain"},
	{".json", "text/plain"},
	{".conf", "text/plain"},
	{".log", "text/plain"},
	{".csv", "text/csv"},
	{".png", "image/png"},
	{".jpg", "image/jpeg"},
	{".jpeg", "image/jpeg"},
	{".gif", "image/gif"},
	{".bmp", "image/bmp"},
	{".webp", "image/webp"},
	{".pdf", "application/pdf"},
	{".epub", "application/epub+zip"},
	{".mp3", "audio/mpeg"},
	{".flac", "audio/flac"},
	{".ogg", "audio/ogg"},
	{".wav", "audio/x-wav"},
	{".mp4", "video/mp4"},
	{".mkv", "video/x-matroska"},
	{".webm", "video/webm"},
	{".zip", "application/zip"},
	{".tar", "application/x-tar"},
	{".gz", "application/gzip"},
	{".zst", "application/zstd"},
	{".torrent", "application/x-bittorrent"},
}

mime_of :: proc(path: string) -> string {
	low := strings.to_lower(path, context.temp_allocator)
	for m in EXT_MIME {
		if strings.has_suffix(low, m.ext) {
			return m.mime
		}
	}
	return ""
}

// opener_for is the entry that opens a file: the first that declares the
// file's type and takes a file argument, preferring the one used most.
opener_for :: proc(entries: []Entry, path: string) -> int {
	mime := mime_of(path)
	if mime == "" {
		return -1
	}
	best := -1
	for &e, i in entries {
		if !e.takes_file || e.mime == "" {
			continue
		}
		for m in strings.split(e.mime, ";", context.temp_allocator) {
			if strings.trim_space(m) == mime {
				if best < 0 || e.uses > entries[best].uses {
					best = i
				}
				break
			}
		}
	}
	if best >= 0 {
		return best
	}
	// An entry that does not declare its types (the runtime packages' own
	// .desktop files) is still the obvious home for some: Palmy's
	// player plays what a player plays.
	for f in FALLBACK_OPENERS {
		if strings.has_prefix(mime, f.mime) {
			if i := find_program(entries, f.prog); i >= 0 {
				return i
			}
		}
	}
	return -1
}

@(private)
FALLBACK_OPENERS := [?]struct {
	mime, prog: string,
} {
	{"audio/", "audio"},
	{"video/", "video"},
	{"application/zip", "archive"},
	{"application/x-tar", "archive"},
	{"application/gzip", "archive"},
	{"application/zstd", "archive"},
	{"application/x-bittorrent", "torrent"},
	{"image/", "image"},
	{"text/", "editor"},
}
