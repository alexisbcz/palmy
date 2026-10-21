// The non-visual half of the file browser: reading the real filesystem,
// classifying what came back, formatting it for a human, and keeping the
// navigation history.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

// Entry is the core's Fs_Entry (fs.odin) plus what a row needs to draw.
Entry :: struct {
	using fs:  Fs_Entry,

	// Precomputed for the row renderer, so a frame does no formatting.
	size_text: string,
	date_text: string,
	icon:      p.Icon,
	tint:      string,
}

entry_free :: proc(e: Entry) {
	fs_entry_free(e.fs)
	delete(e.size_text)
	delete(e.date_text)
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

	// The name prompt for Rename… and New Folder (actions.odin).
	ask:        Ask,
	ask_path:   string,
	ask_text:   [dynamic]u8,
	ask_fresh:  bool, // the name is still the suggested one: typing replaces it
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

// classify picks the icon and the tint for the kind the core named (fs.odin's
// kind_of), so the Kind column and `files list --json` say the same thing.
classify :: proc(name: string, is_dir, is_link: bool) -> (icon: p.Icon, tint: string, kind: string) {
	class, label := kind_of(name, is_dir)
	switch class {
	case .Folder:
		return ICON_FOLDER, "text-sky-500", label
	case .Document:
		return ICON_FILE, "text-neutral-400", label
	case .Pdf:
		return ICON_BOOK, "text-rose-500", label
	case .Image:
		return ICON_IMAGE, "text-violet-500", label
	case .Video:
		return ICON_FILE_PLAY, "text-fuchsia-500", label
	case .Audio:
		return ICON_MUSIC, "text-amber-500", label
	case .Archive:
		return ICON_FILE_ARCHIVE, "text-orange-500", label
	case .Code:
		return ICON_FILE_CODE, "text-emerald-500", label
	case .Data:
		return ICON_FILE_BRACES, "text-teal-500", label
	case .Sheet:
		return ICON_FILE_SPREADSHEET, "text-green-600", label
	case .Slides:
		return ICON_PRESENTATION, "text-orange-600", label
	case .Doc:
		return ICON_FILE_TEXT, "text-blue-500", label
	case .Text:
		return ICON_FILE_TEXT, "text-neutral-500", label
	case .Font:
		return ICON_TYPE, "text-indigo-500", label
	case .Database:
		return ICON_DATABASE, "text-cyan-600", label
	case .Binary:
		return ICON_PACKAGE, "text-neutral-500", label
	case .Other:
	}
	return ICON_FILE, "text-neutral-400", label
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

// ---------------------------------------------------------------------------
// Reading a directory
// ---------------------------------------------------------------------------

// load_dir reads a folder through the core and decorates each entry for the
// row renderer.
load_dir :: proc(st: ^State, path: string) {
	for e in st.entries {
		entry_free(e)
	}
	clear(&st.entries)
	st.err = ""
	st.now = time.now()

	listed, err := fs_list(path)
	defer delete(listed)
	if err != "" {
		st.err = err
		rebuild(st)
		return
	}
	for fe in listed {
		icon, tint, _ := classify(fe.name, fe.is_dir, fe.is_link)
		append(
			&st.entries,
			Entry {
				fs = fe,
				icon = icon,
				tint = tint,
				size_text = fe.is_dir ? strings.clone("--") : human_size(fe.size),
				date_text = human_date(fe.mtime, st.now, st.tz_offset),
			},
		)
	}
	rebuild(st)
}

// rebuild applies the sort, then the filter, and clamps the selection — the
// same two rules `files list` applies (fs.odin).
rebuild :: proc(st: ^State) {
	fs_sort(st.entries[:], st.sort, st.descending)

	clear(&st.vis)
	needle := strings.to_lower(string(st.filter[:]), context.temp_allocator)
	for e, i in st.entries {
		if fs_shown(e.fs, needle, st.show_hidden) {
			append(&st.vis, i)
		}
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
