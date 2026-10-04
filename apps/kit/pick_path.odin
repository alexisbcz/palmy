package kit

// The path arithmetic the file picker is built on, kept apart from the UI so
// that `pickdemo --selftest` can assert on it without a compositor.
//
// Every one of these is pure: a string in, a string out, nothing touched on
// disk except the four explicit `pick_is_*` / `pick_exists` probes at the
// bottom. Paths arriving from a text field, a command line or a symlink are
// all untrusted, so normalisation is lexical, bounded, and never recursive.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// A path deeper than this is refused rather than followed. A symlink loop that
// is walked segment by segment grows the path without bound; a ceiling turns
// that into an error message instead of an infinite descent.
PICK_MAX_DEPTH :: 64

// ---------------------------------------------------------------------------
// Home and `~`
// ---------------------------------------------------------------------------

// pick_home is $HOME, or "/" when the environment has none.
pick_home :: proc(allocator := context.temp_allocator) -> string {
	h := os.get_env("HOME", allocator)
	if h == "" {
		return strings.clone("/", allocator)
	}
	// A HOME with a trailing slash would make every prefix test below wrong.
	for len(h) > 1 && strings.has_suffix(h, "/") {
		h = h[:len(h) - 1]
	}
	return h
}

// pick_expand replaces a leading `~` with the home directory. `~` alone,
// `~/`, and `~/sub` all expand; `~other/x` is left alone, because this picker
// does not read /etc/passwd, and a literal file called `~foo` is more likely
// than a request for another user's home.
pick_expand :: proc(path: string, home := "", allocator := context.temp_allocator) -> string {
	h := home == "" ? pick_home(allocator) : home
	switch {
	case path == "~":
		return strings.clone(h, allocator)
	case strings.has_prefix(path, "~/"):
		rest := path[2:]
		if rest == "" {
			return strings.clone(h, allocator)
		}
		return fmt.aprintf("%s/%s", h, rest, allocator = allocator)
	}
	return strings.clone(path, allocator)
}

// pick_abbreviate is the inverse, for display: $HOME becomes `~`.
pick_abbreviate :: proc(path: string, home := "", allocator := context.temp_allocator) -> string {
	h := home == "" ? pick_home(allocator) : home
	if h == "/" {
		return strings.clone(path, allocator)
	}
	if path == h {
		return strings.clone("~", allocator)
	}
	if strings.has_prefix(path, fmt.tprintf("%s/", h)) {
		return fmt.aprintf("~%s", path[len(h):], allocator = allocator)
	}
	return strings.clone(path, allocator)
}

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

// pick_normalize turns any path into an absolute one with no `.`, no `..`, no
// empty segments and no trailing slash. It is lexical: nothing is read from
// disk, so it cannot be led in circles by a symlink, and `a/../b` is `/b`
// whether or not `a` exists.
//
// A relative path is taken as relative to `base` (the directory the picker is
// showing), which is what a user typing `../sibling` into the path bar means.
// `~` is expanded first.
//
// Segments past PICK_MAX_DEPTH are dropped, so a pathological input is
// truncated rather than followed forever.
pick_normalize :: proc(
	path: string,
	base := "/",
	home := "",
	allocator := context.temp_allocator,
) -> string {
	expanded := pick_expand(path, home, context.temp_allocator)

	start := expanded
	if !strings.has_prefix(expanded, "/") {
		b := base == "" ? "/" : base
		if expanded == "" {
			start = b
		} else {
			start = fmt.tprintf("%s/%s", b, expanded)
		}
		// The base may itself be relative or hold `~`; fold it in once.
		if !strings.has_prefix(start, "/") {
			start = fmt.tprintf("/%s", start)
		}
	}

	segs := make([dynamic]string, 0, 16, context.temp_allocator)
	for seg in strings.split_iterator(&start, "/") {
		switch seg {
		case "", ".":
			continue
		case "..":
			if len(segs) > 0 {
				pop(&segs)
			}
			continue
		}
		if len(segs) >= PICK_MAX_DEPTH {
			break
		}
		append(&segs, seg)
	}

	if len(segs) == 0 {
		return strings.clone("/", allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	for s in segs {
		strings.write_byte(&b, '/')
		strings.write_string(&b, s)
	}
	return strings.clone(strings.to_string(b), allocator)
}

// pick_parent is the enclosing directory of a normalised path. The parent of
// "/" is "/", so walking up terminates.
pick_parent :: proc(path: string) -> string {
	if path == "/" || path == "" {
		return "/"
	}
	p := path
	for len(p) > 1 && strings.has_suffix(p, "/") {
		p = p[:len(p) - 1]
	}
	slash := strings.last_index_byte(p, '/')
	if slash <= 0 {
		return "/"
	}
	return p[:slash]
}

// pick_base is the last segment: the file name, or "/" for the root.
pick_base :: proc(path: string) -> string {
	if path == "/" || path == "" {
		return "/"
	}
	p := path
	for len(p) > 1 && strings.has_suffix(p, "/") {
		p = p[:len(p) - 1]
	}
	slash := strings.last_index_byte(p, '/')
	if slash < 0 {
		return p
	}
	return p[slash + 1:]
}

// pick_join appends one name to a directory, without doubling the separator.
pick_join :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if name == "" {
		return strings.clone(dir, allocator)
	}
	if dir == "" || dir == "/" {
		return fmt.aprintf("/%s", name, allocator = allocator)
	}
	d := dir
	for len(d) > 1 && strings.has_suffix(d, "/") {
		d = d[:len(d) - 1]
	}
	return fmt.aprintf("%s/%s", d, name, allocator = allocator)
}

// pick_depth is how many segments a normalised path has.
pick_depth :: proc(path: string) -> int {
	n := 0
	for c, i in path {
		if c == '/' && i + 1 < len(path) {
			n += 1
		}
	}
	return n
}

// pick_is_ancestor reports whether `dir` encloses `path` (or is it).
pick_is_ancestor :: proc(dir, path: string) -> bool {
	if dir == path {
		return true
	}
	if dir == "/" {
		return strings.has_prefix(path, "/")
	}
	return strings.has_prefix(path, fmt.tprintf("%s/", dir))
}

// ---------------------------------------------------------------------------
// Extensions
// ---------------------------------------------------------------------------

// pick_ext_offset is the byte index of the dot that begins the extension, or
// len(name) when there is none. A leading dot is a hidden file rather than an
// extension, so ".bashrc" has no extension and "archive.tar.gz" has ".gz" —
// which is what macOS and GNOME both do when they select a name for renaming.
pick_ext_offset :: proc(name: string) -> int {
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 || dot == len(name) - 1 {
		return len(name)
	}
	return dot
}

// pick_ext is the extension, lowercased, with no dot.
pick_ext :: proc(name: string, allocator := context.temp_allocator) -> string {
	off := pick_ext_offset(name)
	if off >= len(name) {
		return ""
	}
	return strings.to_lower(name[off + 1:], allocator)
}

// pick_stem is the name with its extension removed.
pick_stem :: proc(name: string) -> string {
	return name[:pick_ext_offset(name)]
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

// Pick_Filter is one entry in the filter dropdown. An empty `exts` means
// "All files"; the extensions are matched case-insensitively and written
// without the dot.
Pick_Filter :: struct {
	label: string,
	exts:  []string,
}

// Ready-made filters, so the twenty-five apps that need one agree on the set.
PICK_ALL := Pick_Filter{"All files", nil}
PICK_IMAGES := Pick_Filter {
	"Images",
	{"png", "jpg", "jpeg", "gif", "bmp", "webp", "tga", "psd", "ppm", "pgm", "hdr"},
}
PICK_VIDEO := Pick_Filter{"Video", {"mp4", "mkv", "webm", "mov", "avi", "m4v", "mpg", "mpeg"}}
PICK_AUDIO := Pick_Filter{"Audio", {"mp3", "flac", "wav", "ogg", "opus", "m4a", "aac"}}
PICK_TEXT := Pick_Filter{"Text", {"txt", "md", "markdown", "rst", "log", "org", "tex"}}
PICK_DOCS := Pick_Filter{"Documents", {"pdf", "doc", "docx", "odt", "rtf", "epub"}}
PICK_SHEETS := Pick_Filter{"Spreadsheets", {"csv", "tsv", "xlsx", "xls", "ods"}}
PICK_SLIDES := Pick_Filter{"Presentations", {"pptx", "ppt", "odp", "key"}}
PICK_ARCHIVES := Pick_Filter{"Archives", {"zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "zst", "rar"}}
PICK_SUBTITLES := Pick_Filter{"Subtitles", {"srt", "vtt", "ass", "ssa"}}

// pick_filter_accepts is whether a file name passes. Directories are never
// filtered out — you have to be able to walk through a folder to reach the
// files inside it.
pick_filter_accepts :: proc(f: Pick_Filter, name: string) -> bool {
	if len(f.exts) == 0 {
		return true
	}
	ext := pick_ext(name, context.temp_allocator)
	if ext == "" {
		return false
	}
	for e in f.exts {
		if ext == strings.to_lower(e, context.temp_allocator) {
			return true
		}
	}
	return false
}

// pick_apply_ext is the Save dialog's automatic extension: if the typed name
// already carries one the filter accepts, it is left exactly as typed;
// otherwise the filter's first extension is appended. "All files" appends
// nothing, because the user asked for no particular kind.
//
//	pick_apply_ext("report", PICK_IMAGES)        -> "report.png"
//	pick_apply_ext("report.jpg", PICK_IMAGES)    -> "report.jpg"
//	pick_apply_ext("report.", PICK_IMAGES)       -> "report.png"
//	pick_apply_ext("notes.txt", PICK_IMAGES)     -> "notes.txt.png"
pick_apply_ext :: proc(
	name: string,
	f: Pick_Filter,
	allocator := context.temp_allocator,
) -> string {
	if name == "" || len(f.exts) == 0 {
		return strings.clone(name, allocator)
	}
	if pick_filter_accepts(f, name) {
		return strings.clone(name, allocator)
	}
	trimmed := name
	for strings.has_suffix(trimmed, ".") {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	if trimmed == "" {
		return strings.clone(name, allocator)
	}
	return fmt.aprintf("%s.%s", trimmed, f.exts[0], allocator = allocator)
}

// ---------------------------------------------------------------------------
// Breadcrumbs
// ---------------------------------------------------------------------------

Pick_Crumb :: struct {
	label: string,
	path:  string,
	home:  bool, // the first crumb, which stands for Home or the filesystem
}

// pick_crumbs splits a path into clickable segments. A path inside the home
// directory starts at a single "Home" crumb rather than spelling out
// /home/<user>, which is what every file dialog does.
pick_crumbs :: proc(
	path: string,
	home := "",
	allocator := context.temp_allocator,
) -> []Pick_Crumb {
	h := home == "" ? pick_home(context.temp_allocator) : home
	out := make([dynamic]Pick_Crumb, 0, 12, allocator)

	rest := path
	if h != "/" && (path == h || strings.has_prefix(path, fmt.tprintf("%s/", h))) {
		append(&out, Pick_Crumb{strings.clone("Home", allocator), strings.clone(h, allocator), true})
		rest = path[len(h):]
	} else {
		append(&out, Pick_Crumb{strings.clone("Filesystem", allocator), strings.clone("/", allocator), true})
	}

	acc := out[0].path == "/" ? "" : out[0].path
	it := rest
	for seg in strings.split_iterator(&it, "/") {
		if seg == "" {
			continue
		}
		acc = fmt.aprintf("%s/%s", acc, seg, allocator = allocator)
		append(&out, Pick_Crumb{strings.clone(seg, allocator), acc, false})
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Type-ahead
// ---------------------------------------------------------------------------

// pick_typeahead finds the entry a few typed letters mean. Case is ignored.
// A prefix match is preferred and the search starts just after `from` so that
// typing the same letter twice walks through the matches; only when nothing in
// the list starts with the string does it fall back to a substring match.
// Returns -1 when nothing matches, and the caller leaves the selection alone.
pick_typeahead :: proc(names: []string, prefix: string, from := -1) -> int {
	if len(names) == 0 || prefix == "" {
		return -1
	}
	needle := strings.to_lower(prefix, context.temp_allocator)
	n := len(names)
	begin := from < 0 ? 0 : (from + 1) % n

	// Pass one: prefix, starting after the current selection and wrapping.
	for k in 0 ..< n {
		i := (begin + k) % n
		if strings.has_prefix(strings.to_lower(names[i], context.temp_allocator), needle) {
			return i
		}
	}
	// Pass two: substring, in list order.
	for name, i in names {
		if strings.contains(strings.to_lower(name, context.temp_allocator), needle) {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Completion, for the typed-path bar
// ---------------------------------------------------------------------------

// pick_complete extends a half-typed path as far as it is unambiguous, the way
// a shell's Tab does. The returned path is the longest common prefix of the
// matching entries; `unique` says whether exactly one entry matched, in which
// case a directory gets a trailing slash so the next Tab descends into it.
pick_complete :: proc(
	input: string,
	base := "/",
	home := "",
	allocator := context.temp_allocator,
) -> (
	out: string,
	unique: bool,
	matches: int,
) {
	if input == "" {
		return strings.clone(input, allocator), false, 0
	}
	// Splitting before normalising keeps a trailing slash meaningful: "/etc/"
	// lists /etc, while "/etc" completes the name "etc" inside "/".
	dir_part, name_part: string
	if slash := strings.last_index_byte(input, '/'); slash >= 0 {
		dir_part = input[:slash + 1]
		name_part = input[slash + 1:]
	} else {
		dir_part = ""
		name_part = input
	}
	dir := pick_normalize(dir_part == "" ? "." : dir_part, base, home, context.temp_allocator)

	names, err := pick_read_names(dir, context.temp_allocator)
	if err != "" {
		return strings.clone(input, allocator), false, 0
	}

	common := ""
	hit := ""
	count := 0
	for nm in names {
		if !strings.has_prefix(nm, name_part) {
			continue
		}
		count += 1
		hit = nm
		if count == 1 {
			common = nm
		} else {
			k := 0
			for k < len(common) && k < len(nm) && common[k] == nm[k] {
				k += 1
			}
			common = common[:k]
		}
	}
	if count == 0 {
		return strings.clone(input, allocator), false, 0
	}

	joined := fmt.tprintf("%s%s", dir_part, common)
	if count == 1 {
		full := pick_join(dir, hit, context.temp_allocator)
		if pick_is_dir(full) && !strings.has_suffix(joined, "/") {
			joined = fmt.tprintf("%s/", joined)
		}
	}
	return strings.clone(joined, allocator), count == 1, count
}

// ---------------------------------------------------------------------------
// Disk probes
// ---------------------------------------------------------------------------

pick_exists :: proc(path: string) -> bool {
	_, err := os.lstat(path, context.temp_allocator)
	return err == nil
}

// pick_is_dir follows symlinks, so a link to a folder behaves as a folder —
// which is how every other file browser treats one.
//
// The link is resolved in two steps rather than one, and that is not an
// accident. core:os's `stat` opens the path O_RDONLY, so it fails outright on
// a directory the user has no permission to read — and a dialog that cannot
// even see that `locked/` is a folder cannot show the permission error in the
// right place. `lstat` opens O_PATH, which needs no permission at all, so the
// type of the path itself is always knowable. Only when that type is a symlink
// is the target resolved, and a loop makes *that* fail, which is exactly the
// answer wanted: a symlink loop is not a directory, and nothing recurses.
pick_is_dir :: proc(path: string) -> bool {
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	if fi.type == .Directory {
		return true
	}
	if fi.type != .Symlink {
		return false
	}
	target, terr := os.stat(path, context.temp_allocator)
	if terr != nil {
		// A broken link, or one that loops. Either way, not somewhere to go.
		return false
	}
	return target.type == .Directory
}

pick_is_file :: proc(path: string) -> bool {
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	if fi.type == .Regular {
		return true
	}
	if fi.type != .Symlink {
		return false
	}
	target, terr := os.stat(path, context.temp_allocator)
	return terr == nil && target.type == .Regular
}

// pick_read_names lists a directory's entry names and nothing else, which is
// what completion and the collision check need. The error string is meant to
// be shown to a person.
pick_read_names :: proc(
	dir: string,
	allocator := context.temp_allocator,
) -> (
	names: []string,
	err: string,
) {
	f, oerr := os.open(dir)
	if oerr != nil {
		return nil, pick_open_error(oerr)
	}
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	os.close(f)
	if rerr != nil && len(infos) == 0 {
		return nil, "This folder cannot be read."
	}
	out := make([dynamic]string, 0, len(infos), allocator)
	for fi in infos {
		append(&out, strings.clone(fi.name, allocator))
	}
	return out[:], ""
}

// pick_open_error turns an errno into something worth reading. "Permission
// denied" is the one that matters: the dialog stays usable and says why this
// one folder shows nothing.
//
// The interesting cases arrive as a Platform_Error — a raw errno — rather than
// as one of core:os's own General_Error variants, so both are checked. The
// returned string is either a literal or temp-allocated; nothing here leaks.
pick_open_error :: proc(e: os.Error) -> string {
	if e == nil {
		return ""
	}
	// Linux errno values, spelled out rather than imported, so this file does
	// not depend on core:sys/linux.
	EACCES :: 13
	EPERM :: 1
	ENOENT :: 2
	ENOTDIR :: 20
	ELOOP :: 40
	ENAMETOOLONG :: 36
	EMFILE :: 24
	ENFILE :: 23
	if errno, ok := os.is_platform_error(e); ok {
		switch errno {
		case EACCES, EPERM:
			return "You do not have permission to open this folder."
		case ENOENT:
			return "This folder no longer exists."
		case ENOTDIR:
			return "That is not a folder."
		case ELOOP:
			return "This path loops back on itself."
		case ENAMETOOLONG:
			return "That path is too long."
		case EMFILE, ENFILE:
			return "Too many files are open to read this folder."
		}
	}
	if g, ok := e.(os.General_Error); ok {
		switch g {
		case .Not_Exist:
			return "This folder no longer exists."
		case .Exist:
			return "Something with that name is already here."
		case .Invalid_Dir, .Invalid_Path, .Invalid_File:
			return "That path is not valid."
		case .None,
		     .Timeout,
		     .Broken_Pipe,
		     .Invalid_Callback,
		     .Invalid_Command,
		     .Pattern_Has_Separator,
		     .Pattern_Syntax_Error,
		     .No_HOME_Variable,
		     .Env_Var_Not_Found:
		// Nothing a file dialog can say usefully; fall through.
		}
	}
	return fmt.tprintf("This folder cannot be opened (%s).", os.error_string(e))
}

// pick_existing_dir is the fallback for a remembered path that has since been
// deleted: walk up until something is a readable directory, then home, then
// the root. A picker that crashes or shows nothing because last week's folder
// is gone is a picker nobody trusts.
pick_existing_dir :: proc(path: string, allocator := context.temp_allocator) -> string {
	p := pick_normalize(path, "/", "", context.temp_allocator)
	for i := 0; i <= PICK_MAX_DEPTH; i += 1 {
		if pick_is_dir(p) {
			return strings.clone(p, allocator)
		}
		if p == "/" {
			break
		}
		p = pick_parent(p)
	}
	h := pick_home(context.temp_allocator)
	if pick_is_dir(h) {
		return strings.clone(h, allocator)
	}
	return strings.clone("/", allocator)
}

// pick_unique_name is the New Folder button's naming: "untitled folder", then
// "untitled folder 2", and so on, skipping whatever is already there. It gives
// up after a hundred tries rather than spinning.
pick_unique_name :: proc(dir, base: string, allocator := context.temp_allocator) -> string {
	if !pick_exists(pick_join(dir, base, context.temp_allocator)) {
		return strings.clone(base, allocator)
	}
	for n := 2; n < 100; n += 1 {
		cand := fmt.tprintf("%s %d", base, n)
		if !pick_exists(pick_join(dir, cand, context.temp_allocator)) {
			return strings.clone(cand, allocator)
		}
	}
	return fmt.aprintf("%s %d", base, time.now()._nsec, allocator = allocator)
}

// pick_name_ok rejects a new folder name that cannot be one. A name with a
// slash in it is not a name, and "." and ".." are already taken.
pick_name_ok :: proc(name: string) -> (ok: bool, why: string) {
	switch {
	case name == "":
		return false, "Give the folder a name."
	case strings.contains(name, "/"):
		return false, "A name cannot contain a slash."
	case name == "." || name == "..":
		return false, "That name is reserved."
	case strings.contains_rune(name, 0):
		return false, "That name is not valid."
	case len(name) > 255:
		return false, "That name is too long."
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Human formatting, matching what apps/files shows
// ---------------------------------------------------------------------------

// pick_size_text uses decimal units, one decimal place below ten, which is
// the convention the rest of this desktop follows.
pick_size_text :: proc(n: i64, allocator := context.temp_allocator) -> string {
	if n == 1 {
		return strings.clone("1 byte", allocator)
	}
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

@(private)
PICK_MONTHS :: [?]string {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

// pick_date_text reads like a Date Modified column: a clock today, a day and
// month this year, a full date before that.
pick_date_text :: proc(
	t: time.Time,
	now: time.Time,
	offset: i64,
	allocator := context.temp_allocator,
) -> string {
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
	months := PICK_MONTHS
	name := months[clamp(int(m) - 1, 0, 11)]
	if y == ny {
		return fmt.aprintf("%d %s %02d:%02d", d, name, hh, mm, allocator = allocator)
	}
	return fmt.aprintf("%d %s %d", d, name, y, allocator = allocator)
}

// pick_local_offset is the seconds east of UTC, asked of the system once.
// os.File_Info times are UTC and a date that disagrees with the wall clock is
// worse than no date at all.
pick_local_offset :: proc() -> i64 {
	out, ok := run({"date", "+%z"}, context.temp_allocator)
	if !ok || len(out) < 5 {
		return 0
	}
	sign: i64 = out[0] == '-' ? -1 : 1
	hh := i64(out[1] - '0') * 10 + i64(out[2] - '0')
	mm := i64(out[3] - '0') * 10 + i64(out[4] - '0')
	return sign * (hh * 3600 + mm * 60)
}

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

Pick_Place :: struct {
	label: string,
	path:  string,
	icon:  Pick_Icon,
	tint:  string,
}

// Pick_Icon is an indirection so that the place table is plain data the tests
// can build without a renderer; pick_place_icon maps it to a palmy icon.
Pick_Icon :: enum u8 {
	Home,
	Desktop,
	Documents,
	Downloads,
	Pictures,
	Videos,
	Music,
	Root,
	Folder,
}

@(private)
PICK_XDG_KEYS :: [?]struct {
	key:  string,
	icon: Pick_Icon,
} {
	{"XDG_DESKTOP_DIR", .Desktop},
	{"XDG_DOCUMENTS_DIR", .Documents},
	{"XDG_DOWNLOAD_DIR", .Downloads},
	{"XDG_PICTURES_DIR", .Pictures},
	{"XDG_VIDEOS_DIR", .Videos},
	{"XDG_MUSIC_DIR", .Music},
}

// pick_xdg_dirs parses ~/.config/user-dirs.dirs. The file is the only place
// the *localised* names live: a German desktop has XDG_DOCUMENTS_DIR pointing
// at "$HOME/Dokumente", and a sidebar that says "Documents" above a folder
// called Dokumente is a sidebar that lies. The label is therefore taken from
// the directory's own last segment, never from the key.
//
// `text` is the file's contents, so this is testable without a home
// directory; pick_places reads the real file.
pick_xdg_dirs :: proc(
	text: string,
	home: string,
	allocator := context.temp_allocator,
) -> []Pick_Place {
	out := make([dynamic]Pick_Place, 0, 8, allocator)
	keys := PICK_XDG_KEYS

	it := text
	for raw in strings.split_lines_iterator(&it) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		val = strings.trim(val, "\"")
		if val == "" {
			continue
		}
		// `$HOME/x` and `${HOME}/x` are the only substitutions the format
		// allows; anything else is already absolute.
		switch {
		case strings.has_prefix(val, "$HOME"):
			val = fmt.tprintf("%s%s", home, val[len("$HOME"):])
		case strings.has_prefix(val, "${HOME}"):
			val = fmt.tprintf("%s%s", home, val[len("${HOME}"):])
		}
		if !strings.has_prefix(val, "/") {
			continue
		}
		norm := pick_normalize(val, "/", home, context.temp_allocator)
		// xdg-user-dirs writes "$HOME/" for a directory the user declined;
		// that resolves to home itself and is already the first place.
		if norm == home || norm == "/" {
			continue
		}
		for k in keys {
			if k.key != key {
				continue
			}
			append(
				&out,
				Pick_Place {
					label = strings.clone(pick_base(norm), allocator),
					path = strings.clone(norm, allocator),
					icon = k.icon,
					tint = pick_place_tint(k.icon),
				},
			)
			break
		}
	}

	// Keep the dropdown in the order the brief asks for rather than the order
	// xdg-user-dirs happened to write the file in.
	slice.sort_by(out[:], proc(a, b: Pick_Place) -> bool {
		return int(a.icon) < int(b.icon)
	})
	return out[:]
}

pick_place_tint :: proc(ic: Pick_Icon) -> string {
	switch ic {
	case .Home:
		return "text-sky-500"
	case .Desktop:
		return "text-neutral-500"
	case .Documents:
		return "text-blue-500"
	case .Downloads:
		return "text-emerald-500"
	case .Pictures:
		return "text-violet-500"
	case .Videos:
		return "text-fuchsia-500"
	case .Music:
		return "text-amber-500"
	case .Root:
		return "text-neutral-500"
	case .Folder:
		return "text-sky-500"
	}
	return "text-sky-500"
}

// pick_places is the real sidebar: Home, then whatever user-dirs.dirs
// declares and actually exists, then the filesystem root. Nothing is listed
// that cannot be opened, because a dead shortcut is worse than a missing one.
pick_places :: proc(allocator := context.allocator) -> []Pick_Place {
	home := pick_home(context.temp_allocator)
	out := make([dynamic]Pick_Place, 0, 10, allocator)

	if pick_is_dir(home) {
		append(
			&out,
			Pick_Place {
				strings.clone("Home", allocator),
				strings.clone(home, allocator),
				.Home,
				pick_place_tint(.Home),
			},
		)
	}

	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {
		cfg = pick_join(home, ".config", context.temp_allocator)
	}
	text := ""
	if data, rerr := os.read_entire_file(
		pick_join(cfg, "user-dirs.dirs", context.temp_allocator),
		context.temp_allocator,
	); rerr == nil {
		text = string(data)
	}

	named := pick_xdg_dirs(text, home, context.temp_allocator)
	if len(named) == 0 {
		// No user-dirs.dirs at all — fall back to the English defaults, which
		// is what xdg-user-dirs itself would have written.
		fallbacks := [?]struct {
			name: string,
			icon: Pick_Icon,
		} {
			{"Desktop", .Desktop},
			{"Documents", .Documents},
			{"Downloads", .Downloads},
			{"Pictures", .Pictures},
			{"Videos", .Videos},
			{"Music", .Music},
		}
		tmp := make([dynamic]Pick_Place, 0, 8, context.temp_allocator)
		for f in fallbacks {
			append(
				&tmp,
				Pick_Place {
					f.name,
					pick_join(home, f.name, context.temp_allocator),
					f.icon,
					pick_place_tint(f.icon),
				},
			)
		}
		named = tmp[:]
	}
	for pl in named {
		if !pick_is_dir(pl.path) {
			continue
		}
		append(
			&out,
			Pick_Place {
				strings.clone(pl.label, allocator),
				strings.clone(pl.path, allocator),
				pl.icon,
				pl.tint,
			},
		)
	}

	append(
		&out,
		Pick_Place {
			strings.clone("Filesystem", allocator),
			strings.clone("/", allocator),
			.Root,
			pick_place_tint(.Root),
		},
	)
	return out[:]
}

pick_places_free :: proc(places: []Pick_Place, allocator := context.allocator) {
	for pl in places {
		delete(pl.label, allocator)
		delete(pl.path, allocator)
	}
	delete(places, allocator)
}
