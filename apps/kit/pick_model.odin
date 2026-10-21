package kit

// The file picker's state: what it is showing, what is selected, and the
// handful of transitions an app's keyboard handler drives it through.
//
// Nothing here draws. `pick_draw` in pick_ui.odin is the only consumer, and
// `pickdemo --selftest` asserts on these procedures directly.
//
// The picker mutates exactly one thing on disk — it creates a folder when
// asked — and never deletes anything. There is deliberately no delete action,
// no delete key and no delete menu item: a dialog you open to choose a file is
// not a place to lose one.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// Shape
// ---------------------------------------------------------------------------

Pick_Mode :: enum {
	Open_File, // one existing file
	Open_Files, // several existing files
	Open_Folder, // one existing directory
	Save_File, // a name in a directory, which may or may not exist yet
}

Pick_Sort :: enum {
	Name,
	Size,
	Date,
	Kind,
}

// Which part of the dialog the keyboard is talking to. Tab cycles through
// whichever of these the current mode has.
Pick_Pane :: enum {
	Places,
	List,
	Name,
	Filter,
}

Pick_Entry :: struct {
	name:      string,
	path:      string,
	is_dir:    bool,
	is_link:   bool,
	hidden:    bool,
	marked:    bool, // Open_Files
	size:      i64,
	mtime:     time.Time,

	// Precomputed, so a frame of a five-thousand-entry folder does no
	// formatting and no allocation.
	kind:      string,
	size_text: string,
	date_text: string,
	icon:      p.Icon,
	tint:      string,
	lower:     string,
}

// Pick_Opts configures one appearance of the dialog. Every field has a
// sensible zero: `pick_begin(&st, .Open_File, {})` opens on the home
// directory with no filter and the standard labels.
//
// `filters` is borrowed, not copied: pass a package-level array or string
// literals, which is what every caller has. The slice must stay valid while
// the dialog is open.
Pick_Opts :: struct {
	title:       string, // "Open File", "Save As", ... defaults per mode
	dir:         string, // where to start; "" means home, or the last place
	name:        string, // Save only: the suggested file name
	filters:     []Pick_Filter,
	filter:      int, // which filter starts active
	show_hidden: bool,
	confirm:     string, // the primary button's label; defaults per mode
}

// Pick_Result is what the dialog hands back on the frame it reports done.
// The strings are freshly allocated and belong to the caller:
// `defer kit.pick_result_free(res)` or keep them.
Pick_Result :: struct {
	ok:        bool, // false when the user cancelled
	path:      string, // the chosen path, or the first of several
	paths:     []string, // Open_Files; holds exactly `path` in the other modes
	overwrite: bool, // Save: the user explicitly agreed to replace a file
}

pick_result_free :: proc(r: Pick_Result, allocator := context.allocator) {
	for s in r.paths {
		delete(s, allocator)
	}
	delete(r.paths, allocator)
	// `path` aliases paths[0] when there is one; only free it when it does not.
	if len(r.paths) == 0 {
		delete(r.path, allocator)
	}
}

Pick :: struct {
	// --- lifecycle -------------------------------------------------------
	open:          bool,
	frames:        int, // how many frames this appearance has had
	mode:          Pick_Mode,
	title:         string,
	confirm_label: string,

	// --- where we are ----------------------------------------------------
	dir:           string,
	entries:       [dynamic]Pick_Entry,
	vis:           [dynamic]int, // indices into entries, after filter and sort
	err:           string, // shown in place of the list; the rest stays usable
	note:          string, // a transient line under the list

	places:        []Pick_Place,
	place_sel:     int,

	// --- how it is shown -------------------------------------------------
	filters:       []Pick_Filter,
	filter:        int,
	filter_open:   bool,
	filter_sel:    int,
	sort:          Pick_Sort,
	desc:          bool,
	show_hidden:   bool,

	// --- selection -------------------------------------------------------
	sel:           int, // index into vis
	marks:         int, // how many entries are marked, Open_Files
	pane:          Pick_Pane,

	// --- the Save name field ---------------------------------------------
	name_buf:      [dynamic]u8,
	name_cur:      int,
	name_anchor:   int, // the other end of the selection; == cur means none

	// --- the typed-path bar (Ctrl+L) --------------------------------------
	loc_open:      bool,
	loc_buf:       [dynamic]u8,
	loc_cur:       int,
	loc_note:      string,

	// --- New Folder -------------------------------------------------------
	nf_open:       bool,
	nf_buf:        [dynamic]u8,
	nf_cur:        int,
	nf_err:        string,

	// --- the overwrite confirmation ---------------------------------------
	cf_open:       bool,
	cf_path:       string,
	cf_sel:        int, // 0 = Cancel, and it starts there on purpose

	// --- type-ahead -------------------------------------------------------
	ahead:         [dynamic]u8,
	ahead_at:      f64,

	// --- plumbing ---------------------------------------------------------
	list_id:       u64, // the scroll container, for reveal
	want_reveal:   bool,
	want_top:      bool,
	swallow:       bool, // ignore this frame's typed text
	tz:            i64,
	now:           time.Time,
	last_dir:      string, // remembered across appearances
	done:          bool,
	result:        Pick_Result,
}

// ---------------------------------------------------------------------------
// Opening and closing
// ---------------------------------------------------------------------------

pick_default_title :: proc(mode: Pick_Mode) -> string {
	switch mode {
	case .Open_File:
		return "Open File"
	case .Open_Files:
		return "Open Files"
	case .Open_Folder:
		return "Choose Folder"
	case .Save_File:
		return "Save As"
	}
	return "Open"
}

pick_default_confirm :: proc(mode: Pick_Mode) -> string {
	switch mode {
	case .Open_File, .Open_Files:
		return "Open"
	case .Open_Folder:
		return "Choose"
	case .Save_File:
		return "Save"
	}
	return "Open"
}

// pick_begin opens the dialog. Call it from the frame that handled Ctrl+O or
// Ctrl+S; `pick_draw` takes over from the next line of the same frame.
pick_begin :: proc(st: ^Pick, mode: Pick_Mode, opts: Pick_Opts) {
	pick_reset(st)

	st.open = true
	st.frames = 0
	st.mode = mode
	st.title = strings.clone(opts.title != "" ? opts.title : pick_default_title(mode))
	st.confirm_label = strings.clone(
		opts.confirm != "" ? opts.confirm : pick_default_confirm(mode),
	)
	st.filters = opts.filters
	st.filter = len(opts.filters) == 0 ? 0 : clamp(opts.filter, 0, len(opts.filters) - 1)
	st.filter_sel = st.filter
	st.show_hidden = opts.show_hidden
	st.sort = .Name
	st.desc = false
	st.done = false
	st.result = {}

	if st.tz == 0 {
		st.tz = pick_local_offset()
	}
	st.now = time.now()

	if len(st.places) == 0 {
		st.places = pick_places()
	}

	// Where to start: what the caller asked for, else where we were last
	// time, else home. A path that has since been deleted falls back to its
	// nearest surviving ancestor rather than failing.
	start := opts.dir
	if start == "" {
		start = st.last_dir
	}
	if start == "" {
		start = pick_home(context.temp_allocator)
	}
	// A caller that hands over a file path means the folder it lives in, with
	// that file selected — which is what "save as, over there" looks like.
	want_name := opts.name
	expanded := pick_normalize(start, "/", "", context.temp_allocator)
	if pick_is_file(expanded) {
		if want_name == "" {
			want_name = pick_base(expanded)
		}
		expanded = pick_parent(expanded)
	}

	pick_go(st, pick_existing_dir(expanded, context.temp_allocator))

	if mode == .Save_File {
		pick_set_name(st, want_name)
		st.pane = .Name
	} else {
		st.pane = .List
		// Open with the caller's file already highlighted when it is there.
		if want_name != "" {
			pick_select_name(st, want_name)
		}
	}
	st.swallow = true
}

// pick_active reports whether the dialog is up, so an app knows to route its
// keyboard to `pick_draw` and not to its own shortcuts.
pick_active :: proc(st: ^Pick) -> bool {
	return st.open
}

// pick_cancel closes with no result, which is also what Escape does.
pick_cancel :: proc(st: ^Pick) {
	st.open = false
	st.done = true
	st.result = Pick_Result{}
}

// pick_reset frees everything this appearance allocated but keeps `places`
// and `last_dir`, which are worth carrying between appearances.
@(private)
pick_reset :: proc(st: ^Pick) {
	pick_clear_entries(st)
	// A result the host never collected — it reopened the dialog instead of
	// reading what came back. It is still this component's memory until then.
	if st.result.ok {
		pick_result_free(st.result)
	}
	st.result = {}
	st.done = false
	delete(st.title)
	delete(st.confirm_label)
	delete(st.err)
	delete(st.note)
	delete(st.cf_path)
	delete(st.nf_err)
	delete(st.loc_note)
	st.title, st.confirm_label, st.err, st.note = "", "", "", ""
	st.cf_path, st.nf_err, st.loc_note = "", "", ""
	clear(&st.name_buf)
	clear(&st.loc_buf)
	clear(&st.nf_buf)
	clear(&st.ahead)
	st.name_cur, st.name_anchor = 0, 0
	st.loc_cur, st.nf_cur = 0, 0
	st.loc_open, st.nf_open, st.cf_open, st.filter_open = false, false, false, false
	st.cf_sel = 0
	st.sel, st.marks, st.place_sel = 0, 0, 0
	st.list_id = 0
	st.want_reveal, st.want_top, st.swallow = false, false, false
}

// pick_destroy releases a Pick an app is finished with. A long-lived app can
// keep one forever instead and never call this.
pick_destroy :: proc(st: ^Pick) {
	pick_reset(st)
	delete(st.entries)
	delete(st.vis)
	delete(st.name_buf)
	delete(st.loc_buf)
	delete(st.nf_buf)
	delete(st.ahead)
	delete(st.dir)
	delete(st.last_dir)
	st.dir, st.last_dir = "", ""
	if len(st.places) > 0 {
		pick_places_free(st.places)
		st.places = nil
	}
}

@(private)
pick_clear_entries :: proc(st: ^Pick) {
	for e in st.entries {
		delete(e.name)
		delete(e.path)
		delete(e.kind)
		delete(e.size_text)
		delete(e.date_text)
		delete(e.lower)
	}
	clear(&st.entries)
	clear(&st.vis)
}

@(private)
pick_note :: proc(st: ^Pick, msg: string) {
	delete(st.note)
	st.note = strings.clone(msg)
}

@(private)
pick_set_err :: proc(st: ^Pick, msg: string) {
	delete(st.err)
	st.err = strings.clone(msg)
}

// ---------------------------------------------------------------------------
// Classification — the icon, tint and Kind label, from the name alone
// ---------------------------------------------------------------------------

@(private)
pick_in_set :: proc(needle: string, set: []string) -> bool {
	for s in set {
		if s == needle {
			return true
		}
	}
	return false
}

@(private)
PICK_IMAGE_EXT := [?]string {
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "tif", "tiff",
	"avif", "heic", "jxl", "ppm", "pgm", "psd", "xcf", "tga", "hdr",
}
@(private)
PICK_VIDEO_EXT := [?]string {
	"mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ogv",
}
@(private)
PICK_AUDIO_EXT := [?]string {
	"mp3", "flac", "wav", "ogg", "oga", "m4a", "opus", "aac", "wma", "mid",
}
@(private)
PICK_ARCHIVE_EXT := [?]string {
	"zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "zst", "lz4", "deb",
	"rpm", "pkg", "jar", "iso", "dmg",
}
@(private)
PICK_CODE_EXT := [?]string {
	"odin", "c", "h", "cc", "cpp", "hpp", "cxx", "rs", "go", "py", "js", "mjs",
	"cjs", "ts", "tsx", "jsx", "java", "rb", "php", "swift", "kt", "sh", "bash",
	"zsh", "fish", "lua", "sql", "vim", "el", "hs", "ml", "scm", "clj", "ex",
	"zig", "nim", "pl", "r", "dart", "scala", "asm", "css", "scss", "html",
	"htm", "vue", "svelte",
}
@(private)
PICK_DATA_EXT := [?]string {
	"json", "yaml", "yml", "toml", "xml", "ini", "conf", "cfg", "env", "lock",
	"plist", "properties",
}
@(private)
PICK_TEXT_EXT := [?]string{"txt", "md", "markdown", "rst", "log", "nfo", "text", "org", "tex"}
@(private)
PICK_SHEET_EXT := [?]string{"csv", "tsv", "xls", "xlsx", "ods", "numbers"}
@(private)
PICK_SLIDE_EXT := [?]string{"ppt", "pptx", "odp", "key"}
@(private)
PICK_DOC_EXT := [?]string{"doc", "docx", "odt", "rtf", "pages", "epub", "mobi"}
@(private)
PICK_FONT_EXT := [?]string{"ttf", "otf", "woff", "woff2", "pfb", "bdf"}
@(private)
PICK_BIN_EXT := [?]string{"bin", "exe", "so", "a", "o", "appimage", "dll", "dylib", "wasm", "elf"}
@(private)
PICK_DB_EXT := [?]string{"db", "sqlite", "sqlite3", "mdb", "parquet"}
@(private)
PICK_SUB_EXT := [?]string{"srt", "vtt", "ass", "ssa", "sub"}

// pick_classify is the same mapping apps/files uses, so a file looks the same
// in the browser and in the dialog. `kind` is temp-allocated.
pick_classify :: proc(
	name: string,
	is_dir: bool,
) -> (
	icon: p.Icon,
	tint: string,
	kind: string,
) {
	if is_dir {
		return ICON_FOLDER, "text-sky-500", "Folder"
	}
	ext := pick_ext(name, context.temp_allocator)
	up := strings.to_upper(ext, context.temp_allocator)

	image_ext := PICK_IMAGE_EXT
	video_ext := PICK_VIDEO_EXT
	audio_ext := PICK_AUDIO_EXT
	archive_ext := PICK_ARCHIVE_EXT
	code_ext := PICK_CODE_EXT
	data_ext := PICK_DATA_EXT
	text_ext := PICK_TEXT_EXT
	sheet_ext := PICK_SHEET_EXT
	slide_ext := PICK_SLIDE_EXT
	doc_ext := PICK_DOC_EXT
	font_ext := PICK_FONT_EXT
	bin_ext := PICK_BIN_EXT
	db_ext := PICK_DB_EXT
	sub_ext := PICK_SUB_EXT

	switch {
	case ext == "":
		return ICON_FILE, "text-neutral-400", "Document"
	case ext == "pdf":
		return ICON_BOOK, "text-rose-500", "PDF document"
	case pick_in_set(ext, image_ext[:]):
		return ICON_IMAGE, "text-violet-500", fmt.tprintf("%s image", up)
	case pick_in_set(ext, video_ext[:]):
		return ICON_FILE_PLAY, "text-fuchsia-500", fmt.tprintf("%s video", up)
	case pick_in_set(ext, audio_ext[:]):
		return ICON_MUSIC, "text-amber-500", fmt.tprintf("%s audio", up)
	case pick_in_set(ext, archive_ext[:]):
		return ICON_FILE_ARCHIVE, "text-orange-500", fmt.tprintf("%s archive", up)
	case pick_in_set(ext, sub_ext[:]):
		return ICON_TEXT_ALIGN_START, "text-teal-500", fmt.tprintf("%s subtitles", up)
	case pick_in_set(ext, code_ext[:]):
		return ICON_FILE_CODE, "text-emerald-500", fmt.tprintf("%s source", up)
	case pick_in_set(ext, data_ext[:]):
		return ICON_FILE_BRACES, "text-teal-500", fmt.tprintf("%s data", up)
	case pick_in_set(ext, sheet_ext[:]):
		return ICON_FILE_SPREADSHEET, "text-green-600", fmt.tprintf("%s spreadsheet", up)
	case pick_in_set(ext, slide_ext[:]):
		return ICON_PRESENTATION, "text-orange-600", fmt.tprintf("%s presentation", up)
	case pick_in_set(ext, doc_ext[:]):
		return ICON_FILE_TEXT, "text-blue-500", fmt.tprintf("%s document", up)
	case pick_in_set(ext, text_ext[:]):
		return ICON_FILE_TEXT,
			"text-neutral-500",
			ext == "md" ? "Markdown text" : "Plain text"
	case pick_in_set(ext, font_ext[:]):
		return ICON_TYPE, "text-indigo-500", fmt.tprintf("%s font", up)
	case pick_in_set(ext, db_ext[:]):
		return ICON_DATABASE, "text-cyan-600", fmt.tprintf("%s database", up)
	case pick_in_set(ext, bin_ext[:]):
		return ICON_PACKAGE, "text-neutral-500", fmt.tprintf("%s binary", up)
	}
	return ICON_FILE, "text-neutral-400", fmt.tprintf("%s file", up)
}

pick_place_glyph :: proc(ic: Pick_Icon) -> p.Icon {
	switch ic {
	case .Home:
		return ICON_HOUSE
	case .Desktop:
		return ICON_MONITOR
	case .Documents:
		return ICON_FILE_TEXT
	case .Downloads:
		return ICON_DOWNLOAD
	case .Pictures:
		return ICON_IMAGES
	case .Videos:
		return ICON_VIDEO
	case .Music:
		return ICON_MUSIC
	case .Root:
		return ICON_HARD_DRIVE
	case .Folder:
		return ICON_FOLDER
	}
	return ICON_FOLDER
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

// pick_load reads a directory into `entries`. A folder that cannot be opened
// leaves `err` set and the entry list empty: the sidebar, the path bar and
// every button stay live, so the user can go somewhere else. This is the only
// place the picker touches the filesystem for reading, and it never recurses.
pick_load :: proc(st: ^Pick, dir: string) {
	pick_clear_entries(st)
	pick_set_err(st, "")
	st.now = time.now()

	f, oerr := os.open(dir)
	if oerr != nil {
		pick_set_err(st, pick_open_error(oerr))
		pick_rebuild(st)
		return
	}
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	os.close(f)
	if rerr != nil && len(infos) == 0 {
		pick_set_err(st, "This folder cannot be read.")
		pick_rebuild(st)
		return
	}

	reserve(&st.entries, len(infos))
	for fi in infos {
		is_dir := fi.type == .Directory
		is_link := fi.type == .Symlink
		if is_link {
			// Resolve the link once, so a link to a folder sorts and opens as
			// a folder. A broken link, or one that loops, resolves to nothing
			// and stays a file — which is the safe reading, and is why the
			// link is never followed a second time.
			is_dir = pick_is_dir(fi.fullpath)
		}
		icon, tint, kind := pick_classify(fi.name, is_dir)
		e := Pick_Entry {
			name      = strings.clone(fi.name),
			path      = strings.clone(fi.fullpath),
			is_dir    = is_dir,
			is_link   = is_link,
			hidden    = len(fi.name) > 0 && fi.name[0] == '.',
			size      = fi.size,
			mtime     = fi.modification_time,
			icon      = icon,
			tint      = tint,
			kind      = strings.clone(kind),
			lower     = strings.to_lower(fi.name),
		}
		e.size_text = is_dir ? strings.clone("--") : pick_size_text(fi.size, context.allocator)
		e.date_text = pick_date_text(
			fi.modification_time,
			st.now,
			st.tz,
			context.allocator,
		)
		append(&st.entries, e)
	}
	pick_rebuild(st)
}

// The comparator needs the key and Odin has no closures, so they ride on
// file-scoped variables for the duration of the sort.
@(private = "file")
pick_sort_key: Pick_Sort
@(private = "file")
pick_sort_desc: bool

@(private = "file")
pick_entry_less :: proc(a, b: Pick_Entry) -> bool {
	// Folders before files in both directions, which is what every file
	// dialog does and what makes "sort by size" navigable at all.
	if a.is_dir != b.is_dir {
		return a.is_dir
	}
	r := false
	switch pick_sort_key {
	case .Name:
		r = a.lower < b.lower
	case .Kind:
		r = a.kind != b.kind ? a.kind < b.kind : a.lower < b.lower
	case .Size:
		r = a.size != b.size ? a.size > b.size : a.lower < b.lower
	case .Date:
		r = a.mtime._nsec != b.mtime._nsec ? a.mtime._nsec > b.mtime._nsec : a.lower < b.lower
	}
	return pick_sort_desc ? !r : r
}

// pick_rebuild re-sorts and re-filters. `vis` is the list the UI and the
// keyboard both work in; `entries` keeps everything that was read.
pick_rebuild :: proc(st: ^Pick) {
	pick_sort_key = st.sort
	pick_sort_desc = st.desc
	slice.sort_by(st.entries[:], pick_entry_less)

	clear(&st.vis)
	f := pick_active_filter(st)
	for e, i in st.entries {
		if e.hidden && !st.show_hidden {
			continue
		}
		if st.mode == .Open_Folder && !e.is_dir {
			continue // choosing a folder: files are noise
		}
		if !e.is_dir && !pick_filter_accepts(f, e.name) {
			continue
		}
		append(&st.vis, i)
	}
	st.sel = clamp(st.sel, 0, max(0, len(st.vis) - 1))
	st.marks = 0
	for i in st.vis {
		if st.entries[i].marked {
			st.marks += 1
		}
	}
}

pick_active_filter :: proc(st: ^Pick) -> Pick_Filter {
	if len(st.filters) == 0 {
		return PICK_ALL
	}
	return st.filters[clamp(st.filter, 0, len(st.filters) - 1)]
}

pick_selected :: proc(st: ^Pick) -> (Pick_Entry, bool) {
	if st.sel < 0 || st.sel >= len(st.vis) {
		return {}, false
	}
	return st.entries[st.vis[st.sel]], true
}

// pick_visible_names is what type-ahead searches, in display order.
pick_visible_names :: proc(st: ^Pick, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(st.vis), allocator)
	for i in st.vis {
		append(&out, st.entries[i].name)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

// pick_go moves to a directory, normalising first. A path that is not a
// readable directory still becomes the current directory, so the error is
// shown where the user asked for it rather than silently ignored — except
// that it must at least exist, or we fall back to its nearest ancestor.
pick_go :: proc(st: ^Pick, path: string) {
	clean := pick_normalize(path, st.dir == "" ? "/" : st.dir, "", context.temp_allocator)
	if pick_depth(clean) >= PICK_MAX_DEPTH {
		pick_note(st, "That path is nested too deeply to open.")
		return
	}
	if !pick_exists(clean) {
		clean = pick_existing_dir(clean, context.temp_allocator)
	} else if !pick_enterable(clean) {
		// It exists but is no folder: a file, a broken link, or a symlink
		// loop. Making it the current directory would leave the dialog
		// "inside" something that has no inside — New Folder would aim at it
		// and every reload would fail — so the request is refused and the
		// dialog stays where it was. The UI only offers folders, but places,
		// bookmarks and callers can hand over anything.
		pick_note(st, "That is not a folder.")
		return
	}
	delete(st.dir)
	st.dir = strings.clone(clean)
	delete(st.last_dir)
	st.last_dir = strings.clone(clean)

	st.sel = 0
	st.want_top = true
	st.want_reveal = true
	clear(&st.ahead)
	pick_load(st, st.dir)
	pick_sync_place(st)
}

// pick_enterable is pick_is_dir plus one case it cannot see: a link to a
// folder the user may not read. Resolving that link fails with EACCES, so
// pick_is_dir says no, but it is still a folder, and the dialog should open
// it to show the permission error where it was asked for — as it does for a
// locked folder reached directly.
@(private)
pick_enterable :: proc(path: string) -> bool {
	if pick_is_dir(path) {
		return true
	}
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil || fi.type != .Symlink {
		return false
	}
	_, terr := os.stat(path, context.temp_allocator)
	if terr == .Permission_Denied {
		return true
	}
	if errno, ok := os.is_platform_error(terr); ok {
		return errno == 13 || errno == 1 // EACCES, EPERM
	}
	return false
}

// pick_up is Backspace: the enclosing folder, landing on the folder just left.
pick_up :: proc(st: ^Pick) -> bool {
	if st.dir == "/" {
		return false
	}
	leaving := strings.clone(pick_base(st.dir), context.temp_allocator)
	pick_go(st, pick_parent(st.dir))
	pick_select_name(st, leaving)
	return true
}

// pick_select_name puts the cursor on a named entry, if it is showing.
pick_select_name :: proc(st: ^Pick, name: string) -> bool {
	for v, i in st.vis {
		if st.entries[v].name == name {
			st.sel = i
			st.want_reveal = true
			return true
		}
	}
	return false
}

// pick_sync_place highlights the sidebar entry that encloses where we are:
// the longest of them that is a prefix of the current directory.
pick_sync_place :: proc(st: ^Pick) {
	best, best_len := -1, -1
	for pl, i in st.places {
		if pick_is_ancestor(pl.path, st.dir) && len(pl.path) > best_len {
			best, best_len = i, len(pl.path)
		}
	}
	if best >= 0 {
		st.place_sel = best
	}
}

// pick_reload re-reads the current folder and keeps the cursor on the same
// name. Called after a New Folder, and after a chosen file turns out to be
// gone.
pick_reload :: proc(st: ^Pick) {
	name := ""
	if e, ok := pick_selected(st); ok {
		name = strings.clone(e.name, context.temp_allocator)
	}
	pick_load(st, st.dir)
	if name != "" {
		pick_select_name(st, name)
	}
}

pick_set_sort :: proc(st: ^Pick, key: Pick_Sort) {
	// Clicking the active column reverses it, which is the universal gesture.
	if st.sort == key {
		st.desc = !st.desc
	} else {
		st.sort = key
		st.desc = false
	}
	name := ""
	if e, ok := pick_selected(st); ok {
		name = strings.clone(e.name, context.temp_allocator)
	}
	pick_rebuild(st)
	if name != "" {
		pick_select_name(st, name)
	}
	st.want_reveal = true
}

pick_toggle_hidden :: proc(st: ^Pick) {
	st.show_hidden = !st.show_hidden
	name := ""
	if e, ok := pick_selected(st); ok {
		name = strings.clone(e.name, context.temp_allocator)
	}
	pick_rebuild(st)
	if name != "" && !pick_select_name(st, name) {
		st.sel = clamp(st.sel, 0, max(0, len(st.vis) - 1))
	}
	st.want_reveal = true
	pick_note(st, st.show_hidden ? "Showing hidden files" : "Hiding hidden files")
}

pick_set_filter :: proc(st: ^Pick, idx: int) {
	if len(st.filters) == 0 {
		return
	}
	st.filter = clamp(idx, 0, len(st.filters) - 1)
	st.filter_sel = st.filter
	name := ""
	if e, ok := pick_selected(st); ok {
		name = strings.clone(e.name, context.temp_allocator)
	}
	pick_rebuild(st)
	if name != "" {
		pick_select_name(st, name)
	}
	// A Save name keeps its stem but takes the new filter's extension, so
	// flipping from PNG to JPEG does not leave you saving a .png.
	if st.mode == .Save_File && len(st.name_buf) > 0 {
		cur := string(st.name_buf[:])
		f := pick_active_filter(st)
		if !pick_filter_accepts(f, cur) && len(f.exts) > 0 {
			stem := pick_stem(cur)
			if stem != "" {
				pick_set_name(st, fmt.tprintf("%s.%s", stem, f.exts[0]))
			}
		}
	}
	st.want_reveal = true
}

// ---------------------------------------------------------------------------
// The Save name field
// ---------------------------------------------------------------------------

// pick_set_name loads the filename field and selects the basename but not the
// extension — the one detail that makes renaming on save bearable, because
// typing immediately replaces "untitled" and keeps ".png".
pick_set_name :: proc(st: ^Pick, name: string) {
	clear(&st.name_buf)
	append(&st.name_buf, ..transmute([]u8)name)
	off := pick_ext_offset(name)
	st.name_anchor = 0
	st.name_cur = off
}

pick_name :: proc(st: ^Pick) -> string {
	return string(st.name_buf[:])
}

pick_name_sel_lo :: proc(st: ^Pick) -> int {
	return min(st.name_cur, st.name_anchor)
}

pick_name_sel_hi :: proc(st: ^Pick) -> int {
	return max(st.name_cur, st.name_anchor)
}

pick_name_has_sel :: proc(st: ^Pick) -> bool {
	return st.name_cur != st.name_anchor
}

// pick_target is the path a Save would write: the current directory, the
// typed name, and the active filter's extension if the name lacks one.
pick_target :: proc(st: ^Pick, allocator := context.temp_allocator) -> string {
	name := pick_apply_ext(pick_name(st), pick_active_filter(st), context.temp_allocator)
	return pick_join(st.dir, name, allocator)
}

// ---------------------------------------------------------------------------
// Choosing
// ---------------------------------------------------------------------------

// pick_can_confirm is whether the primary button does anything right now.
pick_can_confirm :: proc(st: ^Pick) -> bool {
	switch st.mode {
	case .Open_File:
		e, ok := pick_selected(st)
		return ok && (e.is_dir || true) // a folder descends, a file opens
	case .Open_Files:
		if st.marks > 0 {
			return true
		}
		_, ok := pick_selected(st)
		return ok
	case .Open_Folder:
		return true // the current directory is always a valid answer
	case .Save_File:
		ok, _ := pick_name_ok(strings.trim_space(pick_name(st)))
		return ok
	}
	return false
}

// pick_confirm is Enter and the primary button. It either descends into a
// folder, finishes with a result, or opens the overwrite confirmation —
// which is the only path to replacing a file, and it starts on Cancel.
pick_confirm :: proc(st: ^Pick) {
	switch st.mode {
	case .Open_File, .Open_Files:
		e, ok := pick_selected(st)
		if !ok {
			if st.mode == .Open_Files && st.marks > 0 {
				pick_finish_marked(st)
			}
			return
		}
		if e.is_dir {
			pick_go(st, e.path)
			return
		}
		if st.mode == .Open_Files && st.marks > 0 {
			pick_finish_marked(st)
			return
		}
		// Between the listing and this keystroke the file may have been
		// deleted. Opening a path that is gone is the host app's crash, so it
		// is caught here instead.
		if !pick_exists(e.path) {
			// Reading the folder again resets `err`, so the message goes on
			// afterwards or it is wiped out by the refresh.
			name := strings.clone(e.name, context.temp_allocator)
			pick_reload(st)
			pick_set_err(st, fmt.tprintf("\"%s\" is no longer there.", name))
			return
		}
		pick_finish_one(st, e.path, false)

	case .Open_Folder:
		// Enter on a highlighted folder descends into it; the button chooses
		// where we are. Both are what people expect, and `pick_choose_here`
		// is the explicit one.
		if e, ok := pick_selected(st); ok && e.is_dir {
			pick_go(st, e.path)
			return
		}
		pick_choose_here(st)

	case .Save_File:
		// Enter on a highlighted folder descends, so you can navigate from
		// the list without reaching for the mouse.
		if st.pane == .List {
			if e, ok := pick_selected(st); ok && e.is_dir {
				pick_go(st, e.path)
				return
			}
		}
		name := strings.trim_space(pick_name(st))
		ok, why := pick_name_ok(name)
		if !ok {
			pick_set_err(st, why)
			return
		}
		target := pick_target(st, context.temp_allocator)
		if pick_is_dir(target) {
			// A name that is already a folder is a navigation request, not a
			// save; writing over a directory is not possible anyway.
			pick_go(st, target)
			pick_set_name(st, "")
			return
		}
		if pick_exists(target) {
			pick_ask_overwrite(st, target)
			return
		}
		pick_finish_one(st, target, false)
	}
}

// pick_choose_here answers with the directory the dialog is showing, which is
// what the Choose button does in folder mode.
pick_choose_here :: proc(st: ^Pick) {
	if st.mode != .Open_Folder {
		return
	}
	if !pick_is_dir(st.dir) {
		pick_go(st, pick_existing_dir(st.dir, context.temp_allocator))
		pick_set_err(st, "That folder is no longer there.")
		return
	}
	pick_finish_one(st, st.dir, false)
}

@(private)
pick_finish_one :: proc(st: ^Pick, path: string, overwrite: bool) {
	paths := make([]string, 1)
	paths[0] = strings.clone(path)
	st.result = Pick_Result {
		ok        = true,
		path      = paths[0],
		paths     = paths,
		overwrite = overwrite,
	}
	st.open = false
	st.done = true
}

@(private)
pick_finish_marked :: proc(st: ^Pick) {
	keep := make([dynamic]string, 0, max(1, st.marks))
	for v in st.vis {
		e := st.entries[v]
		if e.marked && !e.is_dir && pick_exists(e.path) {
			append(&keep, strings.clone(e.path))
		}
	}
	if len(keep) == 0 {
		delete(keep)
		pick_reload(st)
		pick_set_err(st, "None of the marked files are still there.")
		return
	}
	st.result = Pick_Result {
		ok    = true,
		path  = keep[0],
		paths = keep[:],
	}
	st.open = false
	st.done = true
}

// pick_mark toggles the current entry's mark, for Open_Files. Folders cannot
// be marked: they are there to be walked through.
pick_mark_current :: proc(st: ^Pick) {
	if st.mode != .Open_Files || st.sel < 0 || st.sel >= len(st.vis) {
		return
	}
	e := &st.entries[st.vis[st.sel]]
	if e.is_dir {
		return
	}
	e.marked = !e.marked
	st.marks += e.marked ? 1 : -1
}

pick_mark_all :: proc(st: ^Pick, on: bool) {
	if st.mode != .Open_Files {
		return
	}
	n := 0
	for v in st.vis {
		e := &st.entries[v]
		if e.is_dir {
			continue
		}
		e.marked = on
		if on {
			n += 1
		}
	}
	st.marks = n
}

// ---------------------------------------------------------------------------
// The overwrite confirmation
// ---------------------------------------------------------------------------

// pick_ask_overwrite raises the confirmation. It cannot be skipped and it
// cannot be defaulted through: `cf_sel` starts on Cancel, Enter takes the
// focused button, and Escape cancels. Overwriting destroys data, so the
// cheapest keystroke has to be the safe one.
pick_ask_overwrite :: proc(st: ^Pick, path: string) {
	delete(st.cf_path)
	st.cf_path = strings.clone(path)
	st.cf_open = true
	st.cf_sel = 0 // Cancel
}

// pick_confirm_overwrite accepts the replacement. Only the Replace button and
// Enter-while-Replace-is-focused reach it.
pick_confirm_overwrite :: proc(st: ^Pick) {
	if !st.cf_open {
		return
	}
	path := strings.clone(st.cf_path, context.temp_allocator)
	st.cf_open = false
	// Re-check: the file may have gone away while the dialog was up, in which
	// case this is an ordinary save and not an overwrite at all.
	pick_finish_one(st, path, pick_exists(path))
}

pick_cancel_overwrite :: proc(st: ^Pick) {
	st.cf_open = false
	st.cf_sel = 0
	pick_note(st, "Nothing was replaced.")
}

// ---------------------------------------------------------------------------
// New Folder
// ---------------------------------------------------------------------------

// pick_new_folder_begin opens the naming prompt, pre-filled with a name that
// does not collide with anything already there.
pick_new_folder_begin :: proc(st: ^Pick) {
	if st.mode == .Open_File || st.mode == .Open_Files {
		return // nothing is being written, so nothing needs a folder
	}
	clear(&st.nf_buf)
	suggestion := pick_unique_name(st.dir, "untitled folder", context.temp_allocator)
	append(&st.nf_buf, ..transmute([]u8)suggestion)
	st.nf_cur = len(st.nf_buf)
	st.nf_open = true
	delete(st.nf_err)
	st.nf_err = ""
	st.swallow = true
}

// pick_new_folder_commit creates it. This is the only write the picker itself
// performs, and it happens inside the directory the user is looking at —
// never anywhere else.
pick_new_folder_commit :: proc(st: ^Pick) -> bool {
	name := strings.trim_space(string(st.nf_buf[:]))
	ok, why := pick_name_ok(name)
	if !ok {
		delete(st.nf_err)
		st.nf_err = strings.clone(why)
		return false
	}
	path := pick_join(st.dir, name, context.temp_allocator)
	if pick_exists(path) {
		delete(st.nf_err)
		st.nf_err = strings.clone("Something with that name is already here.")
		return false
	}
	if err := os.make_directory(path); err != nil {
		delete(st.nf_err)
		st.nf_err = strings.clone(pick_open_error(err))
		return false
	}
	st.nf_open = false
	clear(&st.nf_buf)
	pick_reload(st)
	pick_select_name(st, name)
	pick_note(st, fmt.tprintf("Created \"%s\"", name))
	return true
}

pick_new_folder_cancel :: proc(st: ^Pick) {
	st.nf_open = false
	clear(&st.nf_buf)
	delete(st.nf_err)
	st.nf_err = ""
}

// ---------------------------------------------------------------------------
// The typed-path bar
// ---------------------------------------------------------------------------

pick_location_begin :: proc(st: ^Pick) {
	clear(&st.loc_buf)
	shown := pick_abbreviate(st.dir, "", context.temp_allocator)
	append(&st.loc_buf, ..transmute([]u8)shown)
	if !strings.has_suffix(shown, "/") {
		append(&st.loc_buf, '/')
	}
	st.loc_cur = len(st.loc_buf)
	st.loc_open = true
	delete(st.loc_note)
	st.loc_note = ""
	st.swallow = true
}

pick_location_cancel :: proc(st: ^Pick) {
	st.loc_open = false
	clear(&st.loc_buf)
	delete(st.loc_note)
	st.loc_note = ""
}

// pick_location_complete is Tab in the path bar: extend as far as the entries
// agree, and say how many candidates there were.
pick_location_complete :: proc(st: ^Pick) {
	input := string(st.loc_buf[:])
	out, unique, n := pick_complete(input, st.dir, "", context.temp_allocator)
	delete(st.loc_note)
	switch {
	case n == 0:
		st.loc_note = strings.clone("No match")
	case unique:
		st.loc_note = strings.clone("")
	case:
		st.loc_note = fmt.aprintf("%d matches", n)
	}
	if out != input {
		clear(&st.loc_buf)
		append(&st.loc_buf, ..transmute([]u8)out)
		st.loc_cur = len(st.loc_buf)
	}
}

// pick_location_commit is Enter in the path bar. A directory is opened; a file
// is chosen outright in Open mode and loaded into the name field in Save mode,
// which is what typing a full path into a save dialog has to mean.
pick_location_commit :: proc(st: ^Pick) {
	raw := strings.trim_space(string(st.loc_buf[:]))
	if raw == "" {
		pick_location_cancel(st)
		return
	}
	path := pick_normalize(raw, st.dir, "", context.temp_allocator)
	switch {
	case pick_is_dir(path):
		st.loc_open = false
		clear(&st.loc_buf)
		pick_go(st, path)
		st.pane = .List
	case pick_exists(path):
		st.loc_open = false
		clear(&st.loc_buf)
		name := strings.clone(pick_base(path), context.temp_allocator)
		pick_go(st, pick_parent(path))
		pick_select_name(st, name)
		if st.mode == .Save_File {
			pick_set_name(st, name)
			st.pane = .Name
		} else {
			st.pane = .List
		}
	case st.mode == .Save_File && pick_is_dir(pick_parent(path)):
		// A path that does not exist yet is a perfectly good save target.
		st.loc_open = false
		clear(&st.loc_buf)
		name := strings.clone(pick_base(path), context.temp_allocator)
		pick_go(st, pick_parent(path))
		pick_set_name(st, name)
		st.pane = .Name
	case:
		delete(st.loc_note)
		st.loc_note = strings.clone("No such file or folder")
	}
}

// ---------------------------------------------------------------------------
// Type-ahead
// ---------------------------------------------------------------------------

// The typed string is forgotten after this long, so that two separate
// searches do not run together.
PICK_AHEAD_TIMEOUT :: 1.1

pick_typeahead_push :: proc(st: ^Pick, text: string, now: f64) {
	if now - st.ahead_at > PICK_AHEAD_TIMEOUT {
		clear(&st.ahead)
	}
	st.ahead_at = now
	for b in transmute([]u8)text {
		if b >= 0x20 || b >= 0x80 {
			append(&st.ahead, b)
		}
	}
	names := pick_visible_names(st, context.temp_allocator)
	// Searching from the current row makes a repeated letter walk forward;
	// a fresh search starts from the top.
	from := len(st.ahead) == len(text) ? -1 : st.sel
	if i := pick_typeahead(names, string(st.ahead[:]), from); i >= 0 {
		st.sel = i
		st.want_reveal = true
	}
}

pick_typeahead_clear :: proc(st: ^Pick) {
	clear(&st.ahead)
}

// ---------------------------------------------------------------------------
// Panes
// ---------------------------------------------------------------------------

// pick_panes is the Tab order for the current mode. The filter pane only
// exists when there is more than one filter to choose between.
pick_panes :: proc(st: ^Pick, out: []Pick_Pane) -> []Pick_Pane {
	n := 0
	add :: proc(out: []Pick_Pane, n: ^int, v: Pick_Pane) {
		if n^ < len(out) {
			out[n^] = v
			n^ += 1
		}
	}
	add(out, &n, .Places)
	add(out, &n, .List)
	if st.mode == .Save_File {
		add(out, &n, .Name)
	}
	if len(st.filters) > 1 {
		add(out, &n, .Filter)
	}
	return out[:n]
}

pick_cycle_pane :: proc(st: ^Pick, by: int) {
	buf: [4]Pick_Pane
	panes := pick_panes(st, buf[:])
	at := 0
	for v, i in panes {
		if v == st.pane {
			at = i
			break
		}
	}
	st.pane = panes[(at + by + len(panes)) % len(panes)]
	if st.pane == .Filter {
		st.filter_sel = st.filter
	}
	clear(&st.ahead)
}

// ---------------------------------------------------------------------------
// Row geometry, shared by the renderer and the keyboard
// ---------------------------------------------------------------------------

PICK_ROW_H :: f32(26)

// pick_page is how many rows a Page Up or Page Down moves, from the list's
// height as it was laid out last frame.
pick_page :: proc(st: ^Pick, view_h: f32) -> int {
	return max(1, int(view_h / PICK_ROW_H) - 1)
}

pick_move :: proc(st: ^Pick, by: int) {
	if len(st.vis) == 0 {
		return
	}
	st.sel = clamp(st.sel + by, 0, len(st.vis) - 1)
	st.want_reveal = true
	clear(&st.ahead)
}
