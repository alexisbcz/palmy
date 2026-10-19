// The non-visual half of the file browser: reading the real filesystem,
// classifying what came back, formatting it for a human, and keeping the
// navigation history.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

Entry :: struct {
	name:      string,
	path:      string,
	is_dir:    bool,
	is_link:   bool,
	hidden:    bool,
	size:      i64,
	mtime:     time.Time,

	// Precomputed for the row renderer, so a frame does no formatting.
	kind:      string,
	size_text: string,
	date_text: string,
	icon:      p.Icon,
	tint:      string,
	lower:     string, // name, folded, for the filter
}

entry_free :: proc(e: Entry) {
	delete(e.name)
	delete(e.path)
	delete(e.kind)
	delete(e.size_text)
	delete(e.date_text)
	delete(e.lower)
}

// ---------------------------------------------------------------------------
// Views and panes
// ---------------------------------------------------------------------------

View :: enum {
	List,
	Grid,
}

Pane :: enum {
	Files,
	Sidebar,
	Search,
}

Sort_Key :: enum {
	Name,
	Kind,
	Size,
	Date,
}

Place :: struct {
	label: string,
	path:  string,
	icon:  p.Icon,
	tint:  string,
	group: string,
}

State :: struct {
	cwd:        string,
	entries:    [dynamic]Entry,
	vis:        [dynamic]int, // indices into entries, after filter + sort
	err:        string,

	places:     [dynamic]Place,
	place_sel:  int,

	history:    [dynamic]string,
	hpos:       int,

	view:       View,
	pane:       Pane,
	sort:       Sort_Key,
	descending: bool,
	show_hidden:bool,

	sel:        int, // index into vis
	top:        int, // first visible row (list) or grid row
	rows:       int, // rows that fit, recomputed each frame
	cols:       int, // grid columns that fit
	pane_w:     f32, // width of the file pane, which columns respond to
	scroll_acc: f32,

	filter:     [dynamic]u8,
	swallow:    bool, // ignore this frame's typed text, it opened the field

	menu_open:  bool,
	menu_sel:   int,
	menu_at:    [2]f32,

	inspector:  bool,
	sel_rect:   p.Rect,
	toast:      string,
	toast_at:   f64,

	tz_offset:  i64, // seconds east of UTC, so dates read as local time
	now:        time.Time,

	drive:      Drive, // palm-drive's folders, badges, Share… (drive.odin)
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

extension :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 || dot == len(name) - 1 {
		return ""
	}
	return strings.to_lower(name[dot + 1:], context.temp_allocator)
}

in_set :: proc(needle: string, set: []string) -> bool {
	for s in set {
		if s == needle {
			return true
		}
	}
	return false
}

IMAGE_EXT :: []string {
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "tif", "tiff",
	"avif", "heic", "jxl", "ppm", "psd", "xcf",
}
VIDEO_EXT :: []string{"mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ogv"}
AUDIO_EXT :: []string{"mp3", "flac", "wav", "ogg", "oga", "m4a", "opus", "aac", "wma", "mid"}
ARCHIVE_EXT :: []string {
	"zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "zst", "lz4", "deb",
	"rpm", "pkg", "jar", "iso", "dmg",
}
CODE_EXT :: []string {
	"odin", "c", "h", "cc", "cpp", "hpp", "cxx", "rs", "go", "py", "js", "mjs",
	"cjs", "ts", "tsx", "jsx", "java", "rb", "php", "swift", "kt", "sh", "bash",
	"zsh", "fish", "lua", "sql", "vim", "el", "hs", "ml", "scm", "clj", "ex",
	"zig", "nim", "pl", "r", "dart", "scala", "asm", "s", "m", "mm", "css",
	"scss", "html", "htm", "vue", "svelte",
}
DATA_EXT :: []string {
	"json", "yaml", "yml", "toml", "xml", "ini", "conf", "cfg", "env", "lock",
	"plist", "properties",
}
TEXT_EXT :: []string{"txt", "md", "markdown", "rst", "log", "nfo", "text", "org", "tex"}
SHEET_EXT :: []string{"csv", "tsv", "xls", "xlsx", "ods", "numbers"}
SLIDE_EXT :: []string{"ppt", "pptx", "odp", "key"}
DOC_EXT :: []string{"doc", "docx", "odt", "rtf", "pages", "epub", "mobi"}
FONT_EXT :: []string{"ttf", "otf", "woff", "woff2", "pfb", "bdf"}
BIN_EXT :: []string{"bin", "exe", "so", "a", "o", "appimage", "dll", "dylib", "wasm", "elf"}
DB_EXT :: []string{"db", "sqlite", "sqlite3", "mdb", "parquet"}

// classify picks the icon, the tint and the Finder-style "Kind" label from the
// name alone, which is what every file manager does for the common case.
classify :: proc(name: string, is_dir, is_link: bool) -> (icon: p.Icon, tint: string, kind: string) {
	if is_dir {
		return ICON_FOLDER, "text-sky-500", "Folder"
	}
	ext := extension(name)
	up := strings.to_upper(ext, context.temp_allocator)

	switch {
	case ext == "":
		return ICON_FILE, "text-neutral-400", "Document"
	case ext == "pdf":
		return ICON_BOOK, "text-rose-500", "PDF document"
	case in_set(ext, IMAGE_EXT):
		return ICON_IMAGE, "text-violet-500", tfmt("%s image", up)
	case in_set(ext, VIDEO_EXT):
		return ICON_FILE_PLAY, "text-fuchsia-500", tfmt("%s video", up)
	case in_set(ext, AUDIO_EXT):
		return ICON_MUSIC, "text-amber-500", tfmt("%s audio", up)
	case in_set(ext, ARCHIVE_EXT):
		return ICON_FILE_ARCHIVE, "text-orange-500", tfmt("%s archive", up)
	case in_set(ext, CODE_EXT):
		return ICON_FILE_CODE, "text-emerald-500", tfmt("%s source", up)
	case in_set(ext, DATA_EXT):
		return ICON_FILE_BRACES, "text-teal-500", tfmt("%s data", up)
	case in_set(ext, SHEET_EXT):
		return ICON_FILE_SPREADSHEET, "text-green-600", tfmt("%s spreadsheet", up)
	case in_set(ext, SLIDE_EXT):
		return ICON_PRESENTATION, "text-orange-600", tfmt("%s presentation", up)
	case in_set(ext, DOC_EXT):
		return ICON_FILE_TEXT, "text-blue-500", tfmt("%s document", up)
	case in_set(ext, TEXT_EXT):
		return ICON_FILE_TEXT, "text-neutral-500", ext == "md" ? "Markdown text" : "Plain text"
	case in_set(ext, FONT_EXT):
		return ICON_TYPE, "text-indigo-500", tfmt("%s font", up)
	case in_set(ext, DB_EXT):
		return ICON_DATABASE, "text-cyan-600", tfmt("%s database", up)
	case in_set(ext, BIN_EXT):
		return ICON_PACKAGE, "text-neutral-500", tfmt("%s binary", up)
	}
	return ICON_FILE, "text-neutral-400", tfmt("%s file", up)
}

tfmt :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

// ---------------------------------------------------------------------------
// Human formatting
// ---------------------------------------------------------------------------

// human_size follows the convention macOS uses: decimal units, one decimal
// place below 100, none above.
human_size :: proc(n: i64, allocator := context.allocator) -> string {
	if n < 1000 {
		return fmt.aprintf("%d bytes", n, allocator = allocator)
	}
	units := [?]string{"KB", "MB", "GB", "TB", "PB"}
	v := f64(n)
	u := -1
	for v >= 1000 && u < len(units) - 1 {
		v /= 1000
		u += 1
	}
	if v < 10 {
		return fmt.aprintf("%.1f %s", v, units[u], allocator = allocator)
	}
	return fmt.aprintf("%.0f %s", v, units[u], allocator = allocator)
}

MONTHS :: [?]string {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

// human_date reads like Finder's Date Modified column: a clock for today and
// yesterday, a day and month inside this year, a full date before that.
human_date :: proc(t: time.Time, now: time.Time, offset: i64, allocator := context.allocator) -> string {
	local := time.Time{_nsec = t._nsec + offset * 1_000_000_000}
	lnow := time.Time{_nsec = now._nsec + offset * 1_000_000_000}
	y, m, d := time.date(local)
	ny, nm, nd := time.date(lnow)
	hh, mm, _ := time.clock(local)

	if y == ny && m == nm && d == nd {
		return fmt.aprintf("Today %02d:%02d", hh, mm, allocator = allocator)
	}
	yd := time.Time{_nsec = lnow._nsec - 86_400 * 1_000_000_000}
	yy, ym, ydd := time.date(yd)
	if y == yy && m == ym && d == ydd {
		return fmt.aprintf("Yesterday %02d:%02d", hh, mm, allocator = allocator)
	}
	months := MONTHS
	name := months[clamp(int(m) - 1, 0, 11)]
	if y == ny {
		return fmt.aprintf("%d %s %02d:%02d", d, name, hh, mm, allocator = allocator)
	}
	return fmt.aprintf("%d %s %d", d, name, y, allocator = allocator)
}

// local_offset asks the system what the UTC offset is, so the dates in the
// list agree with the clock on the wall. os.File_Info times are UTC.
local_offset :: proc() -> i64 {
	out, ok := run_cmd({"date", "+%z"})
	if !ok || len(out) < 5 {
		return 0
	}
	sign: i64 = out[0] == '-' ? -1 : 1
	hh := i64(out[1] - '0') * 10 + i64(out[2] - '0')
	mm := i64(out[3] - '0') * 10 + i64(out[4] - '0')
	return sign * (hh * 3600 + mm * 60)
}

// ---------------------------------------------------------------------------
// Reading a directory
// ---------------------------------------------------------------------------

load_dir :: proc(st: ^State, path: string) {
	for e in st.entries {
		entry_free(e)
	}
	clear(&st.entries)
	st.err = ""
	st.now = time.now()

	f, oerr := os.open(path)
	if oerr != nil {
		st.err = "This folder cannot be opened."
		rebuild(st)
		return
	}
	infos, rerr := os.read_dir(f, -1, context.allocator)
	os.close(f)
	if rerr != nil && len(infos) == 0 {
		st.err = "This folder cannot be read."
		rebuild(st)
		return
	}

	for fi in infos {
		is_dir := fi.type == .Directory
		is_link := fi.type == .Symlink
		if is_link {
			// Follow the link once, so a link to a folder sorts and opens as
			// a folder, the way it does everywhere else.
			if target, terr := os.stat(fi.fullpath, context.temp_allocator); terr == nil {
				is_dir = target.type == .Directory
			}
		}
		icon, tint, kind := classify(fi.name, is_dir, is_link)
		e := Entry {
			name      = strings.clone(fi.name),
			path      = strings.clone(fi.fullpath),
			is_dir    = is_dir,
			is_link   = is_link,
			hidden    = len(fi.name) > 0 && fi.name[0] == '.',
			size      = fi.size,
			mtime     = fi.modification_time,
			kind      = kind,
			icon      = icon,
			tint      = tint,
			lower     = strings.to_lower(fi.name),
		}
		e.kind = strings.clone(kind) // classify returns temp storage
		e.size_text = is_dir ? strings.clone("--") : human_size(fi.size)
		e.date_text = human_date(fi.modification_time, st.now, st.tz_offset)
		append(&st.entries, e)
	}
	for fi in infos {
		os.file_info_delete(fi, context.allocator)
	}
	delete(infos)
	rebuild(st)
}

// The comparator needs the sort key, and Odin has no closures, so the key
// rides on a file-scoped variable for the duration of the sort.
@(private = "file")
sort_key: Sort_Key
@(private = "file")
sort_desc: bool

entry_less :: proc(a, b: Entry) -> bool {
	// Directories always come before files, in both directions, which is what
	// Finder and every other browser does.
	if a.is_dir != b.is_dir {
		return a.is_dir
	}
	r := false
	switch sort_key {
	case .Name:
		r = a.lower < b.lower
	case .Kind:
		if a.kind != b.kind {
			r = a.kind < b.kind
		} else {
			r = a.lower < b.lower
		}
	case .Size:
		if a.size != b.size {
			r = a.size > b.size // biggest first reads better by default
		} else {
			r = a.lower < b.lower
		}
	case .Date:
		if a.mtime._nsec != b.mtime._nsec {
			r = a.mtime._nsec > b.mtime._nsec
		} else {
			r = a.lower < b.lower
		}
	}
	return sort_desc ? !r : r
}

// rebuild applies the sort, then the filter, and clamps the selection.
rebuild :: proc(st: ^State) {
	sort_key = st.sort
	sort_desc = st.descending
	slice.sort_by(st.entries[:], entry_less)

	clear(&st.vis)
	needle := strings.to_lower(string(st.filter[:]), context.temp_allocator)
	for e, i in st.entries {
		if e.hidden && !st.show_hidden {
			continue
		}
		if needle != "" && !strings.contains(e.lower, needle) {
			continue
		}
		append(&st.vis, i)
	}
	st.sel = clamp(st.sel, 0, max(0, len(st.vis) - 1))
}

selected :: proc(st: ^State) -> (Entry, bool) {
	if st.sel < 0 || st.sel >= len(st.vis) {
		return {}, false
	}
	return st.entries[st.vis[st.sel]], true
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

go_to :: proc(st: ^State, path: string, record := true) {
	clean := strings.clone(normalize(path))
	if st.cwd == clean {
		delete(clean)
		return
	}
	if record {
		// Drop anything ahead of the cursor, the way a browser does.
		for i := len(st.history) - 1; i > st.hpos; i -= 1 {
			delete(st.history[i])
			pop(&st.history)
		}
		append(&st.history, strings.clone(clean))
		st.hpos = len(st.history) - 1
	}
	delete(st.cwd)
	st.cwd = clean
	clear(&st.filter)
	st.sel = 0
	st.top = 0
	load_dir(st, st.cwd)
	drive_refresh(st)
}

// reload re-reads the current directory and keeps the selection on the same
// name, which is what a file browser owes you after something on disk changes.
reload :: proc(st: ^State) {
	name := ""
	if e, ok := selected(st); ok {
		name = strings.clone(e.name, context.temp_allocator)
	}
	load_dir(st, st.cwd)
	drive_refresh(st)
	if name != "" {
		for v, i in st.vis {
			if st.entries[v].name == name {
				st.sel = i
				break
			}
		}
	}
}

go_back :: proc(st: ^State) -> bool {
	if st.hpos <= 0 {
		return false
	}
	st.hpos -= 1
	go_to(st, st.history[st.hpos], false)
	return true
}

go_forward :: proc(st: ^State) -> bool {
	if st.hpos >= len(st.history) - 1 {
		return false
	}
	st.hpos += 1
	go_to(st, st.history[st.hpos], false)
	return true
}

go_up :: proc(st: ^State) -> bool {
	if st.cwd == "/" {
		return false
	}
	parent := parent_of(st.cwd)
	leaving := strings.clone(base_of(st.cwd), context.temp_allocator)
	go_to(st, parent)
	// Land on the folder we just came out of, like Finder's "go up".
	for v, i in st.vis {
		if st.entries[v].name == leaving {
			st.sel = i
			break
		}
	}
	return true
}

normalize :: proc(path: string, allocator := context.temp_allocator) -> string {
	if path == "" {
		return "/"
	}
	if len(path) > 1 && strings.has_suffix(path, "/") {
		return path[:len(path) - 1]
	}
	return path
}

parent_of :: proc(path: string, allocator := context.temp_allocator) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 {
		return "/"
	}
	return path[:slash]
}

base_of :: proc(path: string) -> string {
	if path == "/" {
		return "/"
	}
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return path
	}
	return path[slash + 1:]
}

join_path :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if dir == "/" {
		return fmt.tprintf("/%s", name)
	}
	return fmt.tprintf("%s/%s", dir, name)
}

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

build_places :: proc(st: ^State) {
	home := os.get_env("HOME", context.allocator)
	if home == "" {
		home = strings.clone("/")
	}

	add :: proc(st: ^State, label, path: string, icon: p.Icon, tint, group: string) {
		if !is_dir_path(path) {
			return
		}
		append(&st.places, Place{label, strings.clone(path), icon, tint, group})
	}

	add(st, "Home", home, ICON_HOUSE, "text-sky-500", "Favourites")
	for name, i in ([?]string{"Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos"}) {
		icons := [?]p.Icon {
			ICON_MONITOR,
			ICON_FILE_TEXT,
			ICON_DOWNLOAD,
			ICON_IMAGES,
			ICON_MUSIC,
			ICON_VIDEO,
		}
		tints := [?]string {
			"text-neutral-500",
			"text-blue-500",
			"text-emerald-500",
			"text-violet-500",
			"text-amber-500",
			"text-fuchsia-500",
		}
		add(st, name, join_path(home, name), icons[i], tints[i], "Favourites")
	}
	// Whatever else the home directory holds that is worth a shortcut.
	for name, i in ([?]string{"Projects", "Work"}) {
		tints := [?]string{"text-teal-500", "text-indigo-500"}
		add(st, name, join_path(home, name), ICON_FOLDERS, tints[i], "Favourites")
	}
	add(st, "Filesystem", "/", ICON_HARD_DRIVE, "text-neutral-500", "Locations")
	delete(home)
}

is_dir_path :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil && fi.type == .Directory
}
