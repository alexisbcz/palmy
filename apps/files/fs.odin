// The core of Files: what it does to the filesystem, with no window.
//
// Everything here is plain procedures over paths. The browser (model.odin,
// main.odin, drive.odin) and the command line (cli.odin) both call them, so a
// folder listed by `files list` is sorted, filtered and labelled exactly the
// way the window shows it, and a file trashed from the context menu lands in
// the same place, with the same .trashinfo, as one trashed by `files trash`.
//
// Nothing in this file imports palmy. That is the test of the lift: the
// self-test exercises all of it against scratch directories with no display.
//
// It lives inside apps/files for now. Several pieces — the freedesktop trash,
// the glob walk, the kind table — would be at home in a shared package (kit),
// and moving them is a separate change.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

// Fs_Entry is one thing in a folder, as the core sees it. The browser's Entry
// (model.odin) carries one of these plus what its rows need to draw.
Fs_Entry :: struct {
	name:    string,
	path:    string,
	is_dir:  bool, // a link to a folder counts, the way it opens
	is_link: bool,
	hidden:  bool,
	size:    i64,
	mtime:   time.Time,
	kind:    string, // Finder's "Kind" column: "PNG image", "Folder", …
	lower:   string, // name, folded, for sorting and the filter
}

fs_entry_free :: proc(e: Fs_Entry, allocator := context.allocator) {
	delete(e.name, allocator)
	delete(e.path, allocator)
	delete(e.kind, allocator)
	delete(e.lower, allocator)
}

Sort_Key :: enum {
	Name,
	Kind,
	Size,
	Date,
}

SORT_NAMES :: [Sort_Key]string {
	.Name = "name",
	.Kind = "kind",
	.Size = "size",
	.Date = "date",
}

sort_key_parse :: proc(s: string) -> (Sort_Key, bool) {
	names := SORT_NAMES
	for k in Sort_Key {
		if names[k] == s {
			return k, true
		}
	}
	return .Name, false
}

// ---------------------------------------------------------------------------
// Kinds
//
// The name decides the kind, the way every file manager does it for the common
// case. The class is what the browser picks an icon and a tint from; the label
// is the words in the Kind column, and what `files list --json` reports.
// ---------------------------------------------------------------------------

Kind_Class :: enum u8 {
	Folder,
	Document, // no extension at all
	Pdf,
	Image,
	Video,
	Audio,
	Archive,
	Code,
	Data,
	Sheet,
	Slides,
	Doc,
	Text,
	Font,
	Database,
	Binary,
	Other,
}

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

// kind_of names what a file is from its name. The label is temp storage.
kind_of :: proc(name: string, is_dir: bool) -> (class: Kind_Class, label: string) {
	if is_dir {
		return .Folder, "Folder"
	}
	ext := extension(name)
	up := strings.to_upper(ext, context.temp_allocator)
	switch {
	case ext == "":
		return .Document, "Document"
	case ext == "pdf":
		return .Pdf, "PDF document"
	case in_set(ext, IMAGE_EXT):
		return .Image, tfmt("%s image", up)
	case in_set(ext, VIDEO_EXT):
		return .Video, tfmt("%s video", up)
	case in_set(ext, AUDIO_EXT):
		return .Audio, tfmt("%s audio", up)
	case in_set(ext, ARCHIVE_EXT):
		return .Archive, tfmt("%s archive", up)
	case in_set(ext, CODE_EXT):
		return .Code, tfmt("%s source", up)
	case in_set(ext, DATA_EXT):
		return .Data, tfmt("%s data", up)
	case in_set(ext, SHEET_EXT):
		return .Sheet, tfmt("%s spreadsheet", up)
	case in_set(ext, SLIDE_EXT):
		return .Slides, tfmt("%s presentation", up)
	case in_set(ext, DOC_EXT):
		return .Doc, tfmt("%s document", up)
	case in_set(ext, TEXT_EXT):
		return .Text, ext == "md" ? "Markdown text" : "Plain text"
	case in_set(ext, FONT_EXT):
		return .Font, tfmt("%s font", up)
	case in_set(ext, DB_EXT):
		return .Database, tfmt("%s database", up)
	case in_set(ext, BIN_EXT):
		return .Binary, tfmt("%s binary", up)
	}
	return .Other, tfmt("%s file", up)
}

tfmt :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

// fs_entry_from builds an entry from what the OS said, following a link once
// so a link to a folder sorts and opens as a folder.
fs_entry_from :: proc(fi: os.File_Info, allocator := context.allocator) -> Fs_Entry {
	is_dir := fi.type == .Directory
	is_link := fi.type == .Symlink
	size := fi.size
	if is_link {
		if target, terr := os.stat(fi.fullpath, context.temp_allocator); terr == nil {
			is_dir = target.type == .Directory
		}
	}
	_, kind := kind_of(fi.name, is_dir)
	return Fs_Entry {
		name = strings.clone(fi.name, allocator),
		path = strings.clone(fi.fullpath, allocator),
		is_dir = is_dir,
		is_link = is_link,
		hidden = len(fi.name) > 0 && fi.name[0] == '.',
		size = size,
		mtime = fi.modification_time,
		kind = strings.clone(kind, allocator),
		lower = strings.to_lower(fi.name, allocator),
	}
}

// fs_list reads one folder. `err` is a sentence for a person, "" on success.
fs_list :: proc(dir: string, allocator := context.allocator) -> (out: [dynamic]Fs_Entry, err: string) {
	out = make([dynamic]Fs_Entry, allocator)
	f, oerr := os.open(dir)
	if oerr != nil {
		return out, "This folder cannot be opened."
	}
	infos, rerr := os.read_dir(f, -1, context.allocator)
	os.close(f)
	defer {
		for fi in infos {
			os.file_info_delete(fi, context.allocator)
		}
		delete(infos)
	}
	if rerr != nil && len(infos) == 0 {
		return out, "This folder cannot be read."
	}
	for fi in infos {
		append(&out, fs_entry_from(fi, allocator))
	}
	return out, ""
}

// fs_stat describes one path without following a final link, so that a
// broken link is still something that exists and can be trashed.
fs_stat :: proc(path: string, allocator := context.allocator) -> (e: Fs_Entry, ok: bool) {
	fi, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	// lstat reports the name it was handed; make it the base name.
	fi.name = base_of(normalize(path))
	return fs_entry_from(fi, allocator), true
}

// fs_mode is the permission bits as `ls` prints them, file type first.
fs_mode :: proc(path: string) -> string {
	fi, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	sb := strings.builder_make(context.temp_allocator)
	switch fi.type {
	case .Directory:
		strings.write_byte(&sb, 'd')
	case .Symlink:
		strings.write_byte(&sb, 'l')
	case .Regular, .Undetermined, .Named_Pipe, .Socket, .Block_Device, .Character_Device:
		strings.write_byte(&sb, '-')
	}
	bits := [9]os.Permission_Flag {
		.Read_User, .Write_User, .Execute_User,
		.Read_Group, .Write_Group, .Execute_Group,
		.Read_Other, .Write_Other, .Execute_Other,
	}
	letters := "rwxrwxrwx"
	for b, i in bits {
		strings.write_byte(&sb, b in fi.mode ? letters[i] : '-')
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Sorting and filtering — the order the window shows, in one place
// ---------------------------------------------------------------------------

// The comparator needs the sort key, and Odin has no closures, so the key
// rides on a file-scoped variable for the duration of the sort.
@(private = "file")
g_sort_key: Sort_Key
@(private = "file")
g_sort_desc: bool

fs_less :: proc(a, b: Fs_Entry) -> bool {
	// Directories always come before files, in both directions, which is what
	// Finder and every other browser does.
	if a.is_dir != b.is_dir {
		return a.is_dir
	}
	r := false
	switch g_sort_key {
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
	return g_sort_desc ? !r : r
}

// fs_sort orders any slice of things that carry an Fs_Entry first — the core's
// own, or the browser's Entry, which embeds one with `using`.
fs_sort :: proc(entries: []$T, key: Sort_Key, desc: bool) {
	g_sort_key = key
	g_sort_desc = desc
	slice.sort_by(entries, proc(a, b: T) -> bool {
		when T == Fs_Entry {
			return fs_less(a, b)
		} else {
			return fs_less(a.fs, b.fs)
		}
	})
}

// fs_shown is the filter: hidden files only when asked for, and a name that
// contains the typed text, folded.
fs_shown :: proc(e: Fs_Entry, needle_lower: string, show_hidden: bool) -> bool {
	if e.hidden && !show_hidden {
		return false
	}
	if needle_lower != "" && !strings.contains(e.lower, needle_lower) {
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

normalize :: proc(path: string, allocator := context.temp_allocator) -> string {
	if path == "" {
		return "/"
	}
	trimmed := strings.trim_right(path, "/")
	return trimmed == "" ? "/" : trimmed
}

parent_of :: proc(path: string, allocator := context.temp_allocator) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return "."
	}
	if slash == 0 {
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

// absolute makes a path absolute against the working directory and drops a
// trailing slash, without resolving links: the path a person typed is the
// path they mean, and a .trashinfo has to record that one.
absolute :: proc(path: string) -> string {
	p := path
	if !strings.has_prefix(p, "/") {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		p = p == "." ? cwd : join_path(cwd, strings.trim_prefix(p, "./"))
	}
	return normalize(p)
}

is_dir_path :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil && fi.type == .Directory
}

// exists_nofollow is true for a broken link too, which os.exists is not.
exists_nofollow :: proc(path: string) -> bool {
	_, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	return err == nil
}

// inside reports whether `path` is `dir` or somewhere under it.
inside :: proc(path, dir: string) -> bool {
	if path == dir {
		return true
	}
	if dir == "/" {
		return strings.has_prefix(path, "/")
	}
	return strings.has_prefix(path, dir) && len(path) > len(dir) && path[len(dir)] == '/'
}

// name_refusal is why `name` cannot be a file name here, or "".
name_refusal :: proc(name: string) -> string {
	switch {
	case strings.trim_space(name) == "":
		return "a name cannot be empty"
	case name == "." || name == "..":
		return fmt.tprintf("%q is not a name a file can have", name)
	case strings.index_byte(name, '/') >= 0:
		return "a name cannot contain /"
	case strings.index_byte(name, 0) >= 0:
		return "a name cannot contain a NUL byte"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Finding
// ---------------------------------------------------------------------------

Find_Opts :: struct {
	pattern:     string, // a glob (* ? [..]) when it has one, else a folded substring
	kind:        string, // "", "file", "dir", or a kind class such as "image"
	max_depth:   int, // 0 means no limit
	limit:       int, // 0 means no limit
	hidden:      bool, // look inside hidden folders and report hidden names
	larger_than: i64, // bytes; 0 means any
}

fs_has_glob :: proc(s: string) -> bool {
	return strings.index_any(s, "*?[") >= 0
}

fs_name_matches :: proc(name, pattern: string) -> bool {
	if pattern == "" {
		return true
	}
	if fs_has_glob(pattern) {
		ok, _ := os.match(pattern, name)
		return ok
	}
	return strings.contains(
		strings.to_lower(name, context.temp_allocator),
		strings.to_lower(pattern, context.temp_allocator),
	)
}

// fs_kind_matches answers --type: file, dir, or one of the kind classes by
// name ("image", "code", "text", …).
fs_kind_matches :: proc(e: Fs_Entry, want: string) -> bool {
	switch want {
	case "":
		return true
	case "file":
		return !e.is_dir
	case "dir", "folder":
		return e.is_dir
	case "link":
		return e.is_link
	}
	class, _ := kind_of(e.name, e.is_dir)
	name := strings.to_lower(fmt.tprint(class), context.temp_allocator)
	return name == strings.to_lower(want, context.temp_allocator)
}

// fs_find walks `root` breadth-first, so the shallow matches come first and a
// limit keeps the ones a person would look at. It never follows a link into a
// folder: a loop of links would never end, and a link out of the tree would
// leave the paths it was handed.
fs_find :: proc(root: string, o: Find_Opts, allocator := context.allocator) -> (out: [dynamic]Fs_Entry, truncated: bool) {
	out = make([dynamic]Fs_Entry, allocator)
	Level :: struct {
		dir:   string,
		depth: int,
	}
	queue := make([dynamic]Level, context.temp_allocator)
	append(&queue, Level{normalize(root), 1})
	for qi := 0; qi < len(queue); qi += 1 {
		lv := queue[qi]
		entries, err := fs_list(lv.dir, context.temp_allocator)
		if err != "" {
			continue
		}
		fs_sort(entries[:], .Name, false)
		for e in entries {
			if e.hidden && !o.hidden {
				continue
			}
			if fs_name_matches(e.name, o.pattern) &&
			   fs_kind_matches(e, o.kind) &&
			   (o.larger_than <= 0 || (!e.is_dir && e.size > o.larger_than)) {
				if o.limit > 0 && len(out) >= o.limit {
					return out, true
				}
				c := e
				c.name = strings.clone(e.name, allocator)
				c.path = strings.clone(e.path, allocator)
				c.kind = strings.clone(e.kind, allocator)
				c.lower = strings.clone(e.lower, allocator)
				append(&out, c)
			}
			if e.is_dir && !e.is_link && (o.max_depth <= 0 || lv.depth < o.max_depth) {
				append(&queue, Level{e.path, lv.depth + 1})
			}
		}
	}
	return out, false
}

// fs_tree_size totals the bytes and files under a folder, without following
// links, for `stat` on a folder.
fs_tree_size :: proc(dir: string) -> (bytes: i64, files: int, dirs: int) {
	entries, err := fs_list(dir, context.temp_allocator)
	if err != "" {
		return
	}
	for e in entries {
		if e.is_dir && !e.is_link {
			b, f, d := fs_tree_size(e.path)
			bytes += b
			files += f
			dirs += d + 1
		} else {
			bytes += e.size
			files += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Changing things
//
// Every operation returns the path it produced and a reason it refused, the
// reason a sentence a person can read in a toast and an agent can read in
// `detail`. The checks come first and nothing is touched until they pass —
// which is also what `dry` means: run every check, report the path it would
// produce, and stop there. `--dry-run` on the command line is that flag, so a
// dry run refuses exactly what the real one would.
// ---------------------------------------------------------------------------

Fs_Fail :: enum u8 {
	None,
	Not_Found, // the source is not there
	Exists, // the destination is taken
	Refused, // the request makes no sense (into itself, a bad name)
	Failed, // the OS said no
}

EXDEV :: 18 // rename(2) across filesystems

// copy_tree copies a file, a link (as a link) or a folder (recursively).
@(private = "file")
copy_tree :: proc(src, dst: string) -> os.Error {
	fi, err := os.stat_do_not_follow_links(src, context.temp_allocator)
	if err != nil {
		return err
	}
	switch fi.type {
	case .Symlink:
		target, rerr := os.read_link(src, context.temp_allocator)
		if rerr != nil {
			return rerr
		}
		return os.symlink(target, dst)
	case .Directory:
		if merr := os.make_directory(dst, fi.mode); merr != nil {
			return merr
		}
		entries, lerr := fs_list(src, context.temp_allocator)
		if lerr != "" {
			return .Invalid_Dir
		}
		for e in entries {
			if cerr := copy_tree(e.path, join_path(dst, e.name)); cerr != nil {
				return cerr
			}
		}
		return nil
	case .Regular, .Undetermined, .Named_Pipe, .Socket, .Block_Device, .Character_Device:
	}
	if cerr := os.copy_file(dst, src); cerr != nil {
		return cerr
	}
	_ = os.change_mode(dst, fi.mode)
	_ = os.change_times(dst, fi.access_time, fi.modification_time)
	return nil
}

// fs_copy copies `src` to `dst`. When `dst` is an existing folder the copy goes
// inside it, under the same name, the way `cp` and a paste both work.
fs_copy :: proc(src, dst: string, dry := false) -> (made: string, fail: Fs_Fail, why: string) {
	s := absolute(src)
	if !exists_nofollow(s) {
		return "", .Not_Found, fmt.tprintf("%s does not exist", src)
	}
	d := absolute(dst)
	if is_dir_path(d) {
		d = join_path(d, base_of(s))
	}
	if exists_nofollow(d) {
		return "", .Exists, fmt.tprintf("%s already exists", d)
	}
	if inside(d, s) {
		return "", .Refused, "a folder cannot be copied into itself"
	}
	if !is_dir_path(parent_of(d)) {
		return "", .Not_Found, fmt.tprintf("there is no folder %s", parent_of(d))
	}
	if dry {
		return d, .None, ""
	}
	if err := copy_tree(s, d); err != nil {
		_ = os.remove_all(d)
		return "", .Failed, fmt.tprintf("not copied: %v", err)
	}
	return d, .None, ""
}

// move_path renames, and falls back to copy-then-delete when the two paths are
// on different filesystems — which is the one case rename(2) cannot do.
@(private = "file")
move_path :: proc(s, d: string) -> os.Error {
	err := os.rename(s, d)
	if err == nil {
		return nil
	}
	if code, is := os.is_platform_error(err); !is || code != EXDEV {
		return err
	}
	if cerr := copy_tree(s, d); cerr != nil {
		_ = os.remove_all(d)
		return cerr
	}
	return os.remove_all(s)
}

// fs_move moves `src` to `dst`: into it when it is a folder, else to that path.
// This is what Paste does after Cut, so the browser's refusals are the
// command's refusals: already here, already taken, into itself.
fs_move :: proc(src, dst: string, dry := false) -> (made: string, fail: Fs_Fail, why: string) {
	s := absolute(src)
	if !exists_nofollow(s) {
		return "", .Not_Found, fmt.tprintf("%s does not exist", src)
	}
	d := absolute(dst)
	if is_dir_path(d) {
		d = join_path(d, base_of(s))
	}
	switch {
	case d == s:
		return "", .Refused, "it is already here"
	case exists_nofollow(d):
		return "", .Exists, fmt.tprintf("%s already exists here", base_of(d))
	case inside(d, s):
		return "", .Refused, "a folder cannot go inside itself"
	case !is_dir_path(parent_of(d)):
		return "", .Not_Found, fmt.tprintf("there is no folder %s", parent_of(d))
	}
	if dry {
		return d, .None, ""
	}
	if err := move_path(s, d); err != nil {
		return "", .Failed, fmt.tprintf("not moved: %v", err)
	}
	return d, .None, ""
}

// fs_rename gives `path` a new name in the same folder.
fs_rename :: proc(path, new_name: string, dry := false) -> (made: string, fail: Fs_Fail, why: string) {
	s := absolute(path)
	if !exists_nofollow(s) {
		return "", .Not_Found, fmt.tprintf("%s does not exist", path)
	}
	if r := name_refusal(new_name); r != "" {
		return "", .Refused, r
	}
	d := join_path(parent_of(s), new_name)
	if d == s {
		return s, .None, ""
	}
	if exists_nofollow(d) {
		return "", .Exists, fmt.tprintf("%s already exists here", new_name)
	}
	if dry {
		return d, .None, ""
	}
	if err := os.rename(s, d); err != nil {
		return "", .Failed, fmt.tprintf("not renamed: %v", err)
	}
	return d, .None, ""
}

// fs_mkdir makes a folder. With `parents` the missing folders above it are
// made too and an existing folder is not an error, like `mkdir -p`.
fs_mkdir :: proc(path: string, parents := false, dry := false) -> (made: string, fail: Fs_Fail, why: string) {
	d := absolute(path)
	if r := name_refusal(base_of(d)); r != "" && d != "/" {
		return "", .Refused, r
	}
	if exists_nofollow(d) {
		if parents && is_dir_path(d) {
			return d, .None, ""
		}
		return "", .Exists, fmt.tprintf("%s already exists", d)
	}
	if parents {
		if dry {
			return d, .None, ""
		}
		if err := os.make_directory_all(d); err != nil {
			return "", .Failed, fmt.tprintf("not made: %v", err)
		}
		return d, .None, ""
	}
	if !is_dir_path(parent_of(d)) {
		return "", .Not_Found, fmt.tprintf("there is no folder %s (pass --parents to make it)", parent_of(d))
	}
	if dry {
		return d, .None, ""
	}
	if err := os.make_directory(d); err != nil {
		return "", .Failed, fmt.tprintf("not made: %v", err)
	}
	return d, .None, ""
}

// fs_unique_name is `name` in `dir` if that is free, else Finder's sequence:
// "report copy.pdf", "report copy 2.pdf", … — or "untitled folder 2" when
// `copy_word` is "".
fs_unique_name :: proc(dir, name: string, copy_word := " copy") -> string {
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	first := fmt.tprintf("%s%s%s", stem, copy_word, ext)
	if !exists_nofollow(join_path(dir, first)) {
		return first
	}
	for n := 2; n < 10_000; n += 1 {
		cand := fmt.tprintf("%s%s %d%s", stem, copy_word, n, ext)
		if !exists_nofollow(join_path(dir, cand)) {
			return cand
		}
	}
	return fmt.tprintf("%s%s %d%s", stem, copy_word, time.now()._nsec, ext)
}

// fs_duplicate copies a file or folder next to itself under a free name.
fs_duplicate :: proc(path: string, dry := false) -> (made: string, fail: Fs_Fail, why: string) {
	s := absolute(path)
	if !exists_nofollow(s) {
		return "", .Not_Found, fmt.tprintf("%s does not exist", path)
	}
	dir := parent_of(s)
	return fs_copy(s, join_path(dir, fs_unique_name(dir, base_of(s))), dry)
}

// fs_new_folder makes "untitled folder" (or the next free one) in `dir`, which
// is what New Folder does before you type a name.
fs_new_folder :: proc(dir: string, name := "") -> (made: string, fail: Fs_Fail, why: string) {
	d := absolute(dir)
	n := name
	if n == "" {
		n = "untitled folder"
		if exists_nofollow(join_path(d, n)) {
			n = fs_unique_name(d, n, "")
		}
	}
	return fs_mkdir(join_path(d, n))
}

// fs_delete removes a path for good. A folder needs `recursive`, so deleting
// the wrong one takes two mistakes rather than one.
fs_delete :: proc(path: string, recursive := false, dry := false) -> (removed: string, fail: Fs_Fail, why: string) {
	s := absolute(path)
	if !exists_nofollow(s) {
		return "", .Not_Found, fmt.tprintf("%s does not exist", path)
	}
	if s == "/" {
		return "", .Refused, "not the root of the filesystem"
	}
	fi, _ := os.stat_do_not_follow_links(s, context.temp_allocator)
	if fi.type == .Directory {
		if !recursive {
			entries, _ := fs_list(s, context.temp_allocator)
			if len(entries) > 0 {
				return "", .Refused, "it is a folder with things in it (pass --recursive)"
			}
		}
		if dry {
			return s, .None, ""
		}
		if err := os.remove_all(s); err != nil {
			return "", .Failed, fmt.tprintf("not deleted: %v", err)
		}
		return s, .None, ""
	}
	if dry {
		return s, .None, ""
	}
	if err := os.remove(s); err != nil {
		return "", .Failed, fmt.tprintf("not deleted: %v", err)
	}
	return s, .None, ""
}

// ---------------------------------------------------------------------------
// The trash
//
// The freedesktop.org trash: $XDG_DATA_HOME/Trash (or ~/.local/share/Trash)
// holds `files/<name>` and `info/<name>.trashinfo`, the latter recording where
// it came from and when. It is the same trash every other desktop on Linux
// reads, so something trashed here can be restored from GNOME's Files and the
// other way round. Only the home trash is used; a file on another filesystem
// is moved across rather than into that filesystem's own .Trash-$uid.
// ---------------------------------------------------------------------------

// trash_dir is the trash to use: `override` when given, else the home trash.
trash_dir :: proc(override := "") -> string {
	if override != "" {
		return absolute(override)
	}
	if data := os.get_env("XDG_DATA_HOME", context.temp_allocator); data != "" {
		return join_path(normalize(data), "Trash")
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return fmt.tprintf("%s/.local/share/Trash", normalize(home))
}

Trashed :: struct {
	name:     string, // its name under files/, which is what restore takes
	original: string, // where it was
	deleted:  string, // DeletionDate, as written: local time, no zone
	is_dir:   bool,
	size:     i64,
}

// url_escape and url_unescape do the percent-encoding the spec asks of Path=.
url_escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '/', '-', '_', '.', '~':
			strings.write_byte(&sb, c)
		case:
			fmt.sbprintf(&sb, "%%%02X", c)
		}
	}
	return strings.to_string(sb)
}

url_unescape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	hex :: proc(c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9':
			return c - '0', true
		case 'a' ..= 'f':
			return c - 'a' + 10, true
		case 'A' ..= 'F':
			return c - 'A' + 10, true
		}
		return 0, false
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			h, ok1 := hex(s[i + 1])
			l, ok2 := hex(s[i + 2])
			if ok1 && ok2 {
				strings.write_byte(&sb, h << 4 | l)
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
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

// iso_local formats a time as the spec's DeletionDate: local, no zone.
iso_local :: proc(t: time.Time, offset: i64) -> string {
	local := time.Time{_nsec = t._nsec + offset * 1_000_000_000}
	y, mo, d := time.date(local)
	h, mi, s := time.clock(local)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d", y, int(mo), d, h, mi, s)
}

// iso_utc is how the command line reports a time.
iso_utc :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

// fs_trash moves `path` into the trash and records where it came from.
fs_trash :: proc(path: string, trash := "", offset: i64 = 0, dry := false) -> (name: string, fail: Fs_Fail, why: string) {
	s := absolute(path)
	if !exists_nofollow(s) {
		return "", .Not_Found, fmt.tprintf("%s does not exist", path)
	}
	t := trash_dir(trash)
	if t == "" {
		return "", .Failed, "there is no home folder to keep a trash in"
	}
	if inside(t, s) {
		return "", .Refused, "the trash cannot go in the trash"
	}
	files := join_path(t, "files")
	info := join_path(t, "info")
	if dry {
		return trash_free_name(files, info, base_of(s)), .None, ""
	}
	if err := os.make_directory_all(files, os.perm(0o700)); err != nil && !is_dir_path(files) {
		return "", .Failed, fmt.tprintf("cannot make %s: %v", files, err)
	}
	if err := os.make_directory_all(info, os.perm(0o700)); err != nil && !is_dir_path(info) {
		return "", .Failed, fmt.tprintf("cannot make %s: %v", info, err)
	}

	// Writing the info file first is the spec's way of claiming the name.
	n := trash_free_name(files, info, base_of(s))
	info_path := join_path(info, fmt.tprintf("%s.trashinfo", n))
	body := fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", url_escape(s), iso_local(time.now(), offset))
	if err := os.write_entire_file(info_path, transmute([]u8)body); err != nil {
		return "", .Failed, fmt.tprintf("cannot write %s: %v", info_path, err)
	}
	if err := move_path(s, join_path(files, n)); err != nil {
		_ = os.remove(info_path)
		return "", .Failed, fmt.tprintf("not trashed: %v", err)
	}
	return strings.clone(n, context.temp_allocator), .None, ""
}

// trash_free_name is a name in files/ whose .trashinfo is also free:
// "notes.txt", then "notes.2.txt", "notes.3.txt", …
trash_free_name :: proc(files, info, base: string) -> string {
	n := base
	for k := 2; ; k += 1 {
		if !exists_nofollow(join_path(files, n)) && !exists_nofollow(join_path(info, fmt.tprintf("%s.trashinfo", n))) {
			return n
		}
		stem, ext := base, ""
		if dot := strings.last_index_byte(base, '.'); dot > 0 {
			stem, ext = base[:dot], base[dot:]
		}
		n = fmt.tprintf("%s.%d%s", stem, k, ext)
	}
}

// fs_trash_list reads every .trashinfo, newest first.
fs_trash_list :: proc(trash := "", allocator := context.temp_allocator) -> [dynamic]Trashed {
	out := make([dynamic]Trashed, allocator)
	t := trash_dir(trash)
	if t == "" {
		return out
	}
	infos, err := fs_list(join_path(t, "info"), context.temp_allocator)
	if err != "" {
		return out
	}
	for e in infos {
		if !strings.has_suffix(e.name, ".trashinfo") {
			continue
		}
		data, rerr := os.read_entire_file_from_path(e.path, context.temp_allocator)
		if rerr != nil {
			continue
		}
		tr := Trashed {
			name = strings.clone(strings.trim_suffix(e.name, ".trashinfo"), allocator),
		}
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if v, ok := strings.substring_from(line, len("Path=")); ok && strings.has_prefix(line, "Path=") {
				tr.original = strings.clone(url_unescape(strings.trim_space(v)), allocator)
			}
			if v, ok := strings.substring_from(line, len("DeletionDate=")); ok && strings.has_prefix(line, "DeletionDate=") {
				tr.deleted = strings.clone(strings.trim_space(v), allocator)
			}
		}
		held := join_path(join_path(t, "files"), tr.name)
		if fe, ok := fs_stat(held, context.temp_allocator); ok {
			tr.is_dir = fe.is_dir
			if fe.is_dir {
				tr.size, _, _ = fs_tree_size(held)
			} else {
				tr.size = fe.size
			}
		} else {
			continue // an orphaned .trashinfo describes nothing
		}
		append(&out, tr)
	}
	slice.sort_by(out[:], proc(a, b: Trashed) -> bool {
		if a.deleted != b.deleted {
			return a.deleted > b.deleted
		}
		return a.name < b.name
	})
	return out
}

// fs_trash_find takes a name in files/ or an original path, the way a person
// would remember it. With several by the same original, the newest wins.
fs_trash_find :: proc(trash, ref: string) -> (Trashed, bool) {
	list := fs_trash_list(trash)
	for tr in list {
		if tr.name == ref {
			return tr, true
		}
	}
	want := absolute(ref)
	for tr in list {
		if tr.original == want || tr.original == ref {
			return tr, true
		}
	}
	return {}, false
}

// fs_restore puts a trashed thing back where it came from, or into `to` when
// given. It never overwrites: a file back at the original path refuses.
fs_restore :: proc(ref: string, trash := "", to := "", dry := false) -> (made: string, fail: Fs_Fail, why: string) {
	t := trash_dir(trash)
	tr, ok := fs_trash_find(t, ref)
	if !ok {
		return "", .Not_Found, fmt.tprintf("nothing called %q is in the trash", ref)
	}
	dst := tr.original
	if to != "" {
		dst = absolute(to)
		if is_dir_path(dst) {
			dst = join_path(dst, base_of(tr.original))
		}
	}
	if dst == "" {
		return "", .Failed, "the trash does not say where it came from (pass --to)"
	}
	if exists_nofollow(dst) {
		return "", .Exists, fmt.tprintf("%s is there again (pass --to somewhere else)", dst)
	}
	if !is_dir_path(parent_of(dst)) {
		return "", .Not_Found, fmt.tprintf("the folder it was in, %s, is gone (pass --to)", parent_of(dst))
	}
	if dry {
		return dst, .None, ""
	}
	if err := move_path(join_path(join_path(t, "files"), tr.name), dst); err != nil {
		return "", .Failed, fmt.tprintf("not restored: %v", err)
	}
	_ = os.remove(join_path(join_path(t, "info"), fmt.tprintf("%s.trashinfo", tr.name)))
	return dst, .None, ""
}

// fs_trash_empty deletes everything in the trash — or only `ref` — for good.
fs_trash_empty :: proc(trash := "", ref := "", dry := false) -> (removed: [dynamic]Trashed, fail: Fs_Fail, why: string) {
	removed = make([dynamic]Trashed, context.temp_allocator)
	t := trash_dir(trash)
	if t == "" {
		return removed, .Failed, "there is no home folder to keep a trash in"
	}
	targets: [dynamic]Trashed
	if ref != "" {
		tr, ok := fs_trash_find(t, ref)
		if !ok {
			return removed, .Not_Found, fmt.tprintf("nothing called %q is in the trash", ref)
		}
		targets = make([dynamic]Trashed, context.temp_allocator)
		append(&targets, tr)
	} else {
		targets = fs_trash_list(t)
	}
	for tr in targets {
		if dry {
			append(&removed, tr)
			continue
		}
		held := join_path(join_path(t, "files"), tr.name)
		if err := os.remove_all(held); err != nil {
			return removed, .Failed, fmt.tprintf("could not delete %s: %v", tr.name, err)
		}
		_ = os.remove(join_path(join_path(t, "info"), fmt.tprintf("%s.trashinfo", tr.name)))
		append(&removed, tr)
	}
	return removed, .None, ""
}
