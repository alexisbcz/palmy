package main

// `pickdemo --selftest` — headless, no compositor, no window.
//
// Three layers, in order of how much they can tell you:
//
//  1. the path arithmetic, asserted directly on `kit.pick_*` — normalisation,
//     `~`, extensions, filters, sorting, type-ahead, breadcrumbs, completion;
//  2. a real fixture tree in a temp directory, including the four things that
//     break file dialogs: a permission-denied folder, a symlink loop, five
//     thousand entries, and names that are unicode, RTL or absurdly long;
//  3. the actual dialog, driven through palmy's offscreen renderer and
//     synthetic input — keyboard navigation, the filter, typing a name, and
//     the overwrite confirmation both declined and accepted.
//
// Nothing outside the temp directory is written, and the chmod-000 fixture is
// restored before the tree is removed.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", what, got, want)
	}
}

@(private = "file")
eqi :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", what, got, want)
	}
}

@(private = "file")
section_at := 0
@(private = "file")
section_name := ""

// section closes the previous group with its assertion count, so the report
// says where the coverage actually is rather than only how much there is.
@(private = "file")
section :: proc(name: string) {
	if section_name != "" {
		fmt.printf("  %-44s %d assertions\n", section_name, checks - section_at)
	}
	section_name = name
	section_at = checks
}

@(private = "file")
section_end :: proc() {
	section("")
	section_name = ""
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("pickdemo self-test")

	test_normalize()
	test_tilde()
	test_segments()
	test_extensions()
	test_filters()
	test_typeahead()
	test_crumbs()
	test_xdg()
	test_names()
	test_format()

	root := fixture_make()
	defer fixture_remove(root)
	test_listing(root)
	test_sorting(root)
	test_hidden_and_filter(root)
	test_hostile_paths(root)
	test_many(root)
	test_newfolder(root)
	test_overwrite(root)
	test_vanishing(root)
	test_completion(root)

	test_ui(root)
	test_memory(root)

	section_end()
	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// 1. Path arithmetic
// ---------------------------------------------------------------------------

test_normalize :: proc() {
	section("normalisation")
	N :: proc(path: string, base := "/") -> string {
		return kit.pick_normalize(path, base, "/nonexistent-home")
	}

	eq(N("/"), "/", "root stays root")
	eq(N(""), "/", "an empty path is the root")
	eq(N("/usr/"), "/usr", "a trailing slash is dropped")
	eq(N("/usr///bin//"), "/usr/bin", "repeated separators collapse")
	eq(N("/usr/./bin"), "/usr/bin", "a dot segment is dropped")
	eq(N("/usr/bin/.."), "/usr", "a dot-dot pops a segment")
	eq(N("/usr/bin/../../etc"), "/etc", "two dot-dots pop two segments")
	eq(N("/.."), "/", "dot-dot cannot escape the root")
	eq(N("/../../../etc"), "/etc", "dot-dot past the root is clamped")
	eq(N("/a/b/../../../c"), "/c", "and clamped mid-path too")
	eq(N("usr/bin", "/"), "/usr/bin", "a relative path resolves against the base")
	eq(N("bin", "/usr"), "/usr/bin", "and against a deeper base")
	eq(N("../lib", "/usr/bin"), "/usr/lib", "a relative dot-dot walks up the base")
	eq(N("./x", "/tmp"), "/tmp/x", "a leading dot is harmless")
	eq(N("/a/b/", "/tmp"), "/a/b", "an absolute path ignores the base")

	// A hostile path cannot grow without bound: a symlink loop walked segment
	// by segment is exactly this input, and the ceiling turns it into a
	// truncated path instead of an endless descent.
	long := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 200 {
		strings.write_string(&long, "/loop")
	}
	deep := N(strings.to_string(long))
	check(
		kit.pick_depth(deep) <= kit.PICK_MAX_DEPTH,
		"a 200-segment path is capped at %d, got %d",
		kit.PICK_MAX_DEPTH,
		kit.pick_depth(deep),
	)
	check(strings.has_prefix(deep, "/loop/loop"), "the capped path keeps its head")

	// Normalisation is idempotent, which is what makes it safe to call on
	// every navigation.
	for input in ([?]string{"/usr/bin/", "/a/../b", "/x/./y//z/", "/"}) {
		once := N(input)
		twice := N(once)
		eq(twice, once, fmt.tprintf("normalising %q twice changes nothing", input))
	}
}

test_tilde :: proc() {
	section("tilde expansion")
	H :: "/home/tester"
	eq(kit.pick_expand("~", H), H, "a bare tilde is home")
	eq(kit.pick_expand("~/", H), H, "tilde-slash is home")
	eq(kit.pick_expand("~/Documents", H), "/home/tester/Documents", "tilde-slash-path expands")
	eq(kit.pick_expand("~/a/b", H), "/home/tester/a/b", "deeper paths expand")
	eq(kit.pick_expand("/etc/~", H), "/etc/~", "a tilde that is not leading is literal")
	eq(kit.pick_expand("~other/x", H), "~other/x", "another user's home is left alone")
	eq(kit.pick_expand("~weird", H), "~weird", "a file called ~weird is left alone")
	eq(kit.pick_normalize("~/../x", "/", H), "/home/x", "expansion happens before dot-dot")

	eq(kit.pick_abbreviate(H, H), "~", "home abbreviates to a tilde")
	eq(kit.pick_abbreviate("/home/tester/a", H), "~/a", "and so does a path inside it")
	eq(kit.pick_abbreviate("/etc", H), "/etc", "a path outside home is unchanged")
	eq(kit.pick_abbreviate("/home/tester2", H), "/home/tester2", "a sibling is not home")
}

test_segments :: proc() {
	section("parents, bases and joins")
	eq(kit.pick_parent("/usr/bin"), "/usr", "parent of /usr/bin")
	eq(kit.pick_parent("/usr"), "/", "parent of a top-level directory")
	eq(kit.pick_parent("/"), "/", "parent of the root is the root")
	eq(kit.pick_parent("/a/b/"), "/a", "a trailing slash does not confuse the parent")
	eq(kit.pick_base("/usr/bin"), "bin", "base of /usr/bin")
	eq(kit.pick_base("/x"), "x", "base of a top-level name")
	eq(kit.pick_base("/"), "/", "base of the root")
	eq(kit.pick_base("/a/b/"), "b", "a trailing slash does not confuse the base")
	eq(kit.pick_join("/", "x"), "/x", "joining onto the root")
	eq(kit.pick_join("/a", "b"), "/a/b", "an ordinary join")
	eq(kit.pick_join("/a/", "b"), "/a/b", "a join does not double the slash")
	eq(kit.pick_join("/a", ""), "/a", "joining nothing changes nothing")

	check(kit.pick_is_ancestor("/", "/anything"), "the root encloses everything")
	check(kit.pick_is_ancestor("/a", "/a"), "a directory encloses itself")
	check(kit.pick_is_ancestor("/a", "/a/b"), "a directory encloses its child")
	check(!kit.pick_is_ancestor("/a", "/ab"), "a prefix of a name is not an ancestor")
	check(!kit.pick_is_ancestor("/a/b", "/a"), "a child does not enclose its parent")
	eqi(kit.pick_depth("/"), 0, "the root has no segments")
	eqi(kit.pick_depth("/a"), 1, "one segment")
	eqi(kit.pick_depth("/a/b/c"), 3, "three segments")
}

test_extensions :: proc() {
	section("extensions")
	eqi(kit.pick_ext_offset("report.png"), 6, "the dot in report.png")
	eqi(kit.pick_ext_offset("archive.tar.gz"), 11, "the last dot wins")
	eqi(kit.pick_ext_offset("noext"), 5, "a name with no dot selects entirely")
	eqi(kit.pick_ext_offset(".bashrc"), 7, "a leading dot is not an extension")
	eqi(kit.pick_ext_offset("trailing."), 9, "a trailing dot is not an extension")
	eqi(kit.pick_ext_offset(""), 0, "an empty name")

	eq(kit.pick_ext("report.PNG"), "png", "the extension is lowercased")
	eq(kit.pick_ext("archive.tar.gz"), "gz", "only the last extension")
	eq(kit.pick_ext(".bashrc"), "", "a dotfile has no extension")
	eq(kit.pick_ext("noext"), "", "no dot, no extension")
	eq(kit.pick_stem("report.png"), "report", "the stem")
	eq(kit.pick_stem("archive.tar.gz"), "archive.tar", "the stem keeps inner dots")
	eq(kit.pick_stem(".bashrc"), ".bashrc", "a dotfile is all stem")

	// Unicode: the offset is a byte index, and it must land on a boundary or
	// slicing the name panics.
	name := "résumé.pdf"
	off := kit.pick_ext_offset(name)
	eq(name[:off], "résumé", "a unicode stem slices cleanly")
	eq(kit.pick_ext(name), "pdf", "and its extension is found")
	rtl := "ملف.txt"
	eq(kit.pick_stem(rtl), "ملف", "an RTL stem slices cleanly")
	eq(kit.pick_ext(rtl), "txt", "and its extension is found")
}

test_filters :: proc() {
	section("filters")
	imgs := kit.PICK_IMAGES
	all := kit.PICK_ALL

	check(kit.pick_filter_accepts(all, "anything.xyz"), "All files accepts anything")
	check(kit.pick_filter_accepts(all, "noext"), "All files accepts an extensionless name")
	check(kit.pick_filter_accepts(imgs, "a.png"), "Images accepts .png")
	check(kit.pick_filter_accepts(imgs, "a.PNG"), "Images accepts .PNG")
	check(kit.pick_filter_accepts(imgs, "a.JpEg"), "matching is case-insensitive")
	check(!kit.pick_filter_accepts(imgs, "a.txt"), "Images rejects .txt")
	check(!kit.pick_filter_accepts(imgs, "png"), "a name that is only the extension is rejected")
	check(!kit.pick_filter_accepts(imgs, "noext"), "Images rejects an extensionless name")
	check(!kit.pick_filter_accepts(imgs, "a.png.txt"), "only the last extension counts")

	eq(kit.pick_apply_ext("report", imgs), "report.png", "a bare name takes the first extension")
	eq(kit.pick_apply_ext("report.jpg", imgs), "report.jpg", "an accepted extension is kept as typed")
	eq(kit.pick_apply_ext("report.JPG", imgs), "report.JPG", "even in the wrong case")
	eq(kit.pick_apply_ext("report.", imgs), "report.png", "a trailing dot is replaced, not doubled")
	eq(kit.pick_apply_ext("report...", imgs), "report.png", "and so are several")
	eq(kit.pick_apply_ext("notes.txt", imgs), "notes.txt.png", "a foreign extension is appended to")
	eq(kit.pick_apply_ext("report", all), "report", "All files appends nothing")
	eq(kit.pick_apply_ext("", imgs), "", "an empty name stays empty")
	eq(kit.pick_apply_ext("résumé", imgs), "résumé.png", "unicode names take an extension")
	eq(
		kit.pick_apply_ext(kit.pick_apply_ext("x", imgs), imgs),
		"x.png",
		"appending twice appends once",
	)
}

test_typeahead :: proc() {
	section("type-ahead")
	names := [?]string{"Alpha", "apple", "Banana", "bread", "cherry", "Éclair"}
	n := names[:]

	eqi(kit.pick_typeahead(n, "b"), 2, "b finds Banana from the top")
	eqi(kit.pick_typeahead(n, "b", 2), 3, "b again walks on to bread")
	eqi(kit.pick_typeahead(n, "b", 3), 2, "and wraps back round")
	eqi(kit.pick_typeahead(n, "ba"), 2, "ba is still Banana")
	eqi(kit.pick_typeahead(n, "A"), 0, "the search ignores case")
	eqi(kit.pick_typeahead(n, "app"), 1, "app finds apple")
	eqi(kit.pick_typeahead(n, "é"), 5, "a unicode prefix matches")
	eqi(kit.pick_typeahead(n, "err"), 4, "a substring matches when no prefix does")
	eqi(kit.pick_typeahead(n, "zzz"), -1, "no match reports -1")
	eqi(kit.pick_typeahead(n, ""), -1, "an empty prefix matches nothing")
	eqi(kit.pick_typeahead(nil, "a"), -1, "an empty list matches nothing")
}

test_crumbs :: proc() {
	section("breadcrumbs")
	H :: "/home/tester"

	c := kit.pick_crumbs("/home/tester/Pictures/trip", H)
	eqi(len(c), 3, "home, Pictures, trip")
	eq(c[0].label, "Home", "the first crumb is Home")
	eq(c[0].path, H, "and it points at the home directory")
	check(c[0].home, "the first crumb is flagged")
	eq(c[1].label, "Pictures", "the second crumb")
	eq(c[1].path, "/home/tester/Pictures", "with its own path")
	eq(c[2].label, "trip", "the last crumb")
	eq(c[2].path, "/home/tester/Pictures/trip", "with the full path")

	c2 := kit.pick_crumbs(H, H)
	eqi(len(c2), 1, "home alone is one crumb")

	c3 := kit.pick_crumbs("/usr/local/bin", H)
	eqi(len(c3), 4, "filesystem, usr, local, bin")
	eq(c3[0].label, "Filesystem", "a path outside home starts at the filesystem")
	eq(c3[0].path, "/", "which is the root")
	eq(c3[1].path, "/usr", "the first real segment")
	eq(c3[3].path, "/usr/local/bin", "and the last")

	c4 := kit.pick_crumbs("/", H)
	eqi(len(c4), 1, "the root is one crumb")
	eq(c4[0].path, "/", "pointing at itself")

	// A path that merely starts with the home string is not inside it.
	c5 := kit.pick_crumbs("/home/tester2/x", H)
	eq(c5[0].label, "Filesystem", "a sibling of home is not inside home")
}

test_xdg :: proc() {
	section("user-dirs.dirs")
	// A real file, with the shapes xdg-user-dirs actually writes: comments,
	// `$HOME/`, a declined directory, and a key this picker does not use.
	text := `# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="$HOME/"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="${HOME}/Musique"
XDG_PICTURES_DIR="$HOME/Billeder"
XDG_VIDEOS_DIR="/mnt/media/film"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_PUBLICSHARE_DIR="$HOME/Public"
`
	places := kit.pick_xdg_dirs(text, "/home/tester")
	eqi(len(places), 5, "five of the keys are places the picker shows")

	find :: proc(places: []kit.Pick_Place, label: string) -> (kit.Pick_Place, bool) {
		for pl in places {
			if pl.label == label {
				return pl, true
			}
		}
		return {}, false
	}

	// The whole point: the label is the folder's own localised name, never
	// the English key. A Danish Pictures directory is called Billeder.
	danish, ok1 := find(places, "Billeder")
	check(ok1, "the localised Pictures name is used as the label")
	eq(danish.path, "/home/tester/Billeder", "and its path is resolved")
	check(danish.icon == .Pictures, "with the Pictures icon")

	french, ok2 := find(places, "Musique")
	check(ok2, "${HOME} is substituted as well as $HOME")
	eq(french.path, "/home/tester/Musique", "and resolves the same way")

	abs, ok3 := find(places, "film")
	check(ok3, "an absolute path outside home is kept")
	eq(abs.path, "/mnt/media/film", "verbatim")

	_, ok4 := find(places, "Templates")
	check(!ok4, "a key the picker has no place for is ignored")
	for pl in places {
		check(pl.path != "/home/tester", "a declined directory is not listed as home again")
	}

	// The brief's order: Desktop, Documents, Downloads, Pictures, Videos,
	// Music, whatever order the file happened to be written in.
	eqi(int(places[0].icon), int(kit.Pick_Icon.Documents), "Documents sorts first here")
	eqi(int(places[1].icon), int(kit.Pick_Icon.Downloads), "then Downloads")
	eqi(int(places[2].icon), int(kit.Pick_Icon.Pictures), "then Pictures")
	eqi(int(places[3].icon), int(kit.Pick_Icon.Videos), "then Videos")
	eqi(int(places[4].icon), int(kit.Pick_Icon.Music), "then Music")

	eqi(len(kit.pick_xdg_dirs("", "/home/tester")), 0, "an empty file yields nothing")
	eqi(len(kit.pick_xdg_dirs("garbage\n=\nx=\n", "/home/tester")), 0, "garbage yields nothing")

	// And the real machine's places, which must at least hold Home and the
	// filesystem root and must not hold a path that cannot be opened.
	real := kit.pick_places()
	defer kit.pick_places_free(real)
	check(len(real) >= 2, "the real sidebar has at least Home and Filesystem")
	eq(real[0].label, "Home", "Home comes first")
	eq(real[len(real) - 1].path, "/", "the filesystem root comes last")
	for pl in real {
		check(kit.pick_is_dir(pl.path), fmt.tprintf("the place %q is a real directory", pl.label))
	}
}

test_names :: proc() {
	section("folder names")
	ok, _ := kit.pick_name_ok("notes")
	check(ok, "an ordinary name is fine")
	ok2, _ := kit.pick_name_ok("مجلد")
	check(ok2, "an RTL name is fine")
	bad1, _ := kit.pick_name_ok("")
	check(!bad1, "an empty name is refused")
	bad2, _ := kit.pick_name_ok("a/b")
	check(!bad2, "a name with a slash is refused")
	bad3, _ := kit.pick_name_ok(".")
	check(!bad3, "dot is refused")
	bad4, _ := kit.pick_name_ok("..")
	check(!bad4, "dot-dot is refused")
	long := strings.repeat("x", 300, context.temp_allocator)
	bad5, _ := kit.pick_name_ok(long)
	check(!bad5, "a 300-byte name is refused")
	_, why := kit.pick_name_ok("a/b")
	check(why != "", "a refusal comes with a reason")
}

test_format :: proc() {
	section("human formatting")
	eq(kit.pick_size_text(0), "0 bytes", "zero")
	eq(kit.pick_size_text(1), "1 byte", "one byte is singular")
	eq(kit.pick_size_text(2), "2 bytes", "two are not")
	eq(kit.pick_size_text(999), "999 bytes", "just under a kilobyte")
	eq(kit.pick_size_text(1000), "1.0 KB", "a kilobyte")
	eq(kit.pick_size_text(1_500_000), "1.5 MB", "a megabyte and a half")
	eq(kit.pick_size_text(12_000_000), "12 MB", "no decimal above ten")
	eq(kit.pick_size_text(2_000_000_000_000), "2.0 TB", "a terabyte")

	now := time.now()
	eq(
		kit.pick_date_text(now, now, 0)[:5],
		"Today",
		"a file touched now reads as today",
	)
	yesterday := time.Time{_nsec = now._nsec - 86_400 * 1_000_000_000}
	check(
		strings.has_prefix(kit.pick_date_text(yesterday, now, 0), "Yesterday"),
		"a file from yesterday says so",
	)
	old := time.Time{_nsec = now._nsec - 800 * 86_400 * 1_000_000_000}
	d := kit.pick_date_text(old, now, 0)
	check(!strings.contains(d, ":"), "a file from two years ago shows no clock, got %q", d)
}

// ---------------------------------------------------------------------------
// 2. A real tree on disk
// ---------------------------------------------------------------------------

LONG_NAME :: "a-filename-so-long-that-no-column-could-ever-show-all-of-it-and-the-renderer-has-to-ellipsize-it-instead-of-pushing-every-other-column-off-the-end-of-the-dialog.txt"

PERM_DIR :: "locked"

fixture_make :: proc() -> string {
	root := fmt.aprintf("/tmp/palmy-pick-selftest-%d", os.get_pid())
	os.remove_all(root)
	must(os.make_directory_all(root), "make the fixture root")

	mk :: proc(path: string, size: int) {
		data := make([]u8, size, context.temp_allocator)
		for i in 0 ..< size {
			data[i] = 'x'
		}
		must(os.write_entire_file(path, data), fmt.tprintf("write %s", path))
	}
	dir :: proc(path: string) {
		must(os.make_directory_all(path), fmt.tprintf("make %s", path))
	}
	at :: proc(root: string, rest: string) -> string {
		return kit.pick_join(root, rest, context.temp_allocator)
	}

	// --- plain files, with sizes and names that sort differently ----------
	mk(at(root, "alpha.txt"), 10)
	mk(at(root, "Beta.PNG"), 5000)
	mk(at(root, "gamma.jpg"), 200)
	mk(at(root, "delta.odin"), 3000)
	mk(at(root, "notes.md"), 1)
	mk(at(root, "archive.tar.gz"), 40000)
	mk(at(root, ".hidden-config"), 7)
	mk(at(root, ".hidden.png"), 9)

	// --- names that break renderers ---------------------------------------
	mk(at(root, "résumé.pdf"), 123) // unicode, combining-friendly
	mk(at(root, "日本語のファイル.txt"), 456) // CJK
	mk(at(root, "ملف-عربي.txt"), 789) // RTL
	mk(at(root, "emoji-🎬-clip.mp4"), 1024) // astral plane
	mk(at(root, LONG_NAME), 11)

	// --- directories --------------------------------------------------------
	dir(at(root, "sub"))
	mk(at(root, "sub/inner.txt"), 20)
	dir(at(root, "sub/deeper"))
	mk(at(root, "sub/deeper/leaf.png"), 30)
	dir(at(root, "empty"))
	dir(at(root, "zzz-last"))

	// --- symlinks, including a loop ----------------------------------------
	// `link-to-sub` is a link to a real directory and must behave as one.
	_ = os.symlink(at(root, "sub"), at(root, "link-to-sub"))
	// `loop-a` -> `loop-b` -> `loop-a`. Resolving either fails with ELOOP, so
	// neither may be reported as a directory and neither may be descended.
	_ = os.symlink(at(root, "loop-b"), at(root, "loop-a"))
	_ = os.symlink(at(root, "loop-a"), at(root, "loop-b"))
	// A link that points at itself, which is the one-hop version.
	_ = os.symlink(at(root, "self-loop"), at(root, "self-loop"))
	// And a link to nothing at all.
	_ = os.symlink(at(root, "no-such-target"), at(root, "broken-link"))
	// A link to a file, which must stay a file.
	_ = os.symlink(at(root, "alpha.txt"), at(root, "link-to-file"))

	// --- a folder that cannot be opened -------------------------------------
	dir(at(root, PERM_DIR))
	mk(at(root, fmt.tprintf("%s/secret.txt", PERM_DIR)), 5)
	// chmod 000: no read, no write, no traverse. Restored in fixture_remove.
	must(os.chmod(at(root, PERM_DIR), os.Permissions{}), "lock the fixture directory")

	// --- five thousand entries ---------------------------------------------
	dir(at(root, "many"))
	for i in 0 ..< 5000 {
		must(
			os.write_entire_file(
				at(root, fmt.tprintf("many/entry-%04d.dat", i)),
				[]u8{},
			),
			"write one of five thousand",
		)
	}

	return root
}

fixture_remove :: proc(root: string) {
	// Put the permissions back before anything tries to walk the tree, so the
	// fixture leaves nothing behind that the user cannot delete.
	_ = os.chmod(
		kit.pick_join(root, PERM_DIR, context.temp_allocator),
		os.Permissions_Default_Directory,
	)
	os.remove_all(root)
	delete(root)
}

must :: proc(err: os.Error, what: string) {
	if err != nil {
		fmt.eprintfln("pickdemo selftest: could not %s: %s", what, os.error_string(err))
		os.exit(2)
	}
}

must_ok :: proc(ok: bool, what: string) {
	if !ok {
		fmt.eprintfln("pickdemo selftest: could not %s", what)
		os.exit(2)
	}
}

// pick_at builds a Pick showing a directory, without a window.
pick_at :: proc(st: ^kit.Pick, mode: kit.Pick_Mode, dir: string, filters: []kit.Pick_Filter = nil) {
	kit.pick_begin(st, mode, {dir = dir, filters = filters})
}

names_of :: proc(st: ^kit.Pick) -> []string {
	return kit.pick_visible_names(st, context.temp_allocator)
}

has_name :: proc(st: ^kit.Pick, name: string) -> bool {
	for n in names_of(st) {
		if n == name {
			return true
		}
	}
	return false
}

entry_named :: proc(st: ^kit.Pick, name: string) -> (kit.Pick_Entry, bool) {
	for i in st.vis {
		if st.entries[i].name == name {
			return st.entries[i], true
		}
	}
	return {}, false
}

test_listing :: proc(root: string) {
	section("reading a directory")
	st: kit.Pick
	defer kit.pick_destroy(&st)
	pick_at(&st, .Open_File, root)

	eq(st.dir, root, "the dialog opened where it was told to")
	eq(st.err, "", "and read the folder without error")
	check(len(st.entries) > 20, "it found the fixture's entries, got %d", len(st.entries))

	check(has_name(&st, "alpha.txt"), "a plain file is listed")
	check(has_name(&st, "sub"), "a directory is listed")
	check(has_name(&st, "empty"), "an empty directory is listed")
	check(!has_name(&st, ".hidden-config"), "a dotfile is hidden by default")
	check(has_name(&st, "résumé.pdf"), "a unicode name is listed")
	check(has_name(&st, "ملف-عربي.txt"), "an RTL name is listed")
	check(has_name(&st, "日本語のファイル.txt"), "a CJK name is listed")
	check(has_name(&st, "emoji-🎬-clip.mp4"), "an astral-plane name is listed")
	check(has_name(&st, LONG_NAME), "a 170-byte name is listed")

	// Classification: these feed the icon and the Kind column.
	if e, ok := entry_named(&st, "Beta.PNG"); ok {
		check(!e.is_dir, "Beta.PNG is a file")
		eqi(int(e.size), 5000, "with the size it was written at")
		eq(e.size_text, "5.0 KB", "formatted for a human")
		check(e.kind == "PNG image", "and classified as a PNG image, got %q", e.kind)
	} else {
		check(false, "Beta.PNG is listed")
	}
	if e, ok := entry_named(&st, "sub"); ok {
		check(e.is_dir, "sub is a directory")
		eq(e.size_text, "--", "a directory shows no size")
		eq(e.kind, "Folder", "and is classified as a folder")
	}
	if e, ok := entry_named(&st, "archive.tar.gz"); ok {
		check(e.kind == "GZ archive", "a .tar.gz is a GZ archive, got %q", e.kind)
	}

	// An empty directory is a real state, not an error.
	st2: kit.Pick
	defer kit.pick_destroy(&st2)
	pick_at(&st2, .Open_File, kit.pick_join(root, "empty", context.temp_allocator))
	eq(st2.err, "", "an empty folder is not an error")
	eqi(len(st2.entries), 0, "and holds nothing")
	eqi(len(st2.vis), 0, "so nothing is visible")
	_, sel_ok := kit.pick_selected(&st2)
	check(!sel_ok, "and nothing is selected")
	kit.pick_confirm(&st2) // must not crash
	check(st2.open, "confirming an empty folder in Open mode does nothing")
}

test_sorting :: proc(root: string) {
	section("sort orders")
	st: kit.Pick
	defer kit.pick_destroy(&st)
	pick_at(&st, .Open_File, root)

	dirs_first :: proc(st: ^kit.Pick) -> bool {
		seen_file := false
		for i in st.vis {
			if st.entries[i].is_dir {
				if seen_file {
					return false
				}
			} else {
				seen_file = true
			}
		}
		return true
	}

	// --- by name ----------------------------------------------------------
	check(st.sort == .Name, "the default sort is by name")
	check(!st.desc, "ascending")
	check(dirs_first(&st), "folders come before files, sorted by name")
	n := names_of(&st)
	prev := ""
	ascending := true
	for name in n {
		if e, ok := entry_named(&st, name); ok && !e.is_dir {
			low := strings.to_lower(name, context.temp_allocator)
			if prev != "" && low < prev {
				ascending = false
			}
			prev = low
		}
	}
	check(ascending, "the files are in ascending case-insensitive name order")
	check(
		kit.pick_typeahead(n, "Beta") >= 0,
		"case-insensitive sorting still finds Beta.PNG",
	)

	// --- reversed ---------------------------------------------------------
	kit.pick_set_sort(&st, .Name)
	check(st.desc, "clicking the active column reverses it")
	check(dirs_first(&st), "folders still come first when reversed")
	rev := names_of(&st)
	prev = ""
	descending := true
	for name in rev {
		if e, ok := entry_named(&st, name); ok && !e.is_dir {
			low := strings.to_lower(name, context.temp_allocator)
			if prev != "" && low > prev {
				descending = false
			}
			prev = low
		}
	}
	check(descending, "and the files are in descending order")

	// --- by size ----------------------------------------------------------
	kit.pick_set_sort(&st, .Size)
	check(st.sort == .Size && !st.desc, "switching column resets the direction")
	check(dirs_first(&st), "folders still come first when sorting by size")
	last := max(i64)
	big_first := true
	for i in st.vis {
		e := st.entries[i]
		if e.is_dir {
			continue
		}
		if e.size > last {
			big_first = false
		}
		last = e.size
	}
	check(big_first, "the biggest file comes first")
	// archive.tar.gz is the 40 KB entry, so it must lead the files.
	first_file := ""
	for i in st.vis {
		if !st.entries[i].is_dir {
			first_file = st.entries[i].name
			break
		}
	}
	eq(first_file, "archive.tar.gz", "the largest file leads")

	// --- by date ----------------------------------------------------------
	kit.pick_set_sort(&st, .Date)
	check(dirs_first(&st), "folders still come first when sorting by date")
	newest := max(i64)
	newest_first := true
	for i in st.vis {
		e := st.entries[i]
		if e.is_dir {
			continue
		}
		if e.mtime._nsec > newest {
			newest_first = false
		}
		newest = e.mtime._nsec
	}
	check(newest_first, "the most recently modified file comes first")

	// --- the selection survives a re-sort ---------------------------------
	kit.pick_set_sort(&st, .Name)
	st.desc = false
	kit.pick_rebuild(&st)
	kit.pick_select_name(&st, "notes.md")
	before, _ := kit.pick_selected(&st)
	kit.pick_set_sort(&st, .Size)
	after, _ := kit.pick_selected(&st)
	eq(after.name, before.name, "re-sorting keeps the cursor on the same file")
}

test_hidden_and_filter :: proc(root: string) {
	section("hidden files and filters")
	filters := [?]kit.Pick_Filter{kit.PICK_ALL, kit.PICK_IMAGES, kit.PICK_TEXT}
	st: kit.Pick
	defer kit.pick_destroy(&st)
	pick_at(&st, .Open_File, root, filters[:])

	visible_all := len(st.vis)
	check(!has_name(&st, ".hidden-config"), "a dotfile starts hidden")

	kit.pick_toggle_hidden(&st)
	check(st.show_hidden, "Ctrl+H turns hidden files on")
	check(has_name(&st, ".hidden-config"), "and the dotfile appears")
	check(len(st.vis) > visible_all, "the list got longer, %d -> %d", visible_all, len(st.vis))

	kit.pick_toggle_hidden(&st)
	check(!st.show_hidden, "and off again")
	eqi(len(st.vis), visible_all, "with the same count as before")

	// --- filters ----------------------------------------------------------
	kit.pick_set_filter(&st, 1) // Images
	check(has_name(&st, "Beta.PNG"), "the Images filter keeps a PNG")
	check(has_name(&st, "gamma.jpg"), "and a JPEG")
	check(!has_name(&st, "alpha.txt"), "and drops a text file")
	check(!has_name(&st, "notes.md"), "and a markdown file")
	check(has_name(&st, "sub"), "but never drops a folder — you have to walk through it")
	check(has_name(&st, "empty"), "including an empty one")
	check(!has_name(&st, ".hidden.png"), "a hidden image is still hidden")

	kit.pick_toggle_hidden(&st)
	check(has_name(&st, ".hidden.png"), "until hidden files are shown")
	check(!has_name(&st, ".hidden-config"), "and then the filter still applies to it")
	kit.pick_toggle_hidden(&st)

	kit.pick_set_filter(&st, 2) // Text
	check(has_name(&st, "alpha.txt"), "the Text filter keeps a .txt")
	check(has_name(&st, "notes.md"), "and a .md")
	check(has_name(&st, "ملف-عربي.txt"), "and an RTL .txt")
	check(!has_name(&st, "Beta.PNG"), "and drops a PNG")

	kit.pick_set_filter(&st, 0) // All files
	eqi(len(st.vis), visible_all, "All files restores the whole listing")

	// Out-of-range indices are clamped rather than crashing.
	kit.pick_set_filter(&st, 99)
	eqi(st.filter, 2, "a filter index past the end clamps to the last")
	kit.pick_set_filter(&st, -5)
	eqi(st.filter, 0, "and below zero clamps to the first")

	// --- folder mode hides files entirely ---------------------------------
	fd: kit.Pick
	defer kit.pick_destroy(&fd)
	pick_at(&fd, .Open_Folder, root)
	check(has_name(&fd, "sub"), "folder mode lists folders")
	check(!has_name(&fd, "alpha.txt"), "and lists no files at all")
	for i in fd.vis {
		check(fd.entries[i].is_dir, "every visible entry in folder mode is a folder")
	}
}

test_hostile_paths :: proc(root: string) {
	section("permissions, symlinks and loops")

	// --- permission denied -------------------------------------------------
	st: kit.Pick
	defer kit.pick_destroy(&st)
	locked := kit.pick_join(root, PERM_DIR, context.temp_allocator)
	pick_at(&st, .Open_File, locked)
	eq(st.dir, locked, "the dialog still shows the folder it was sent to")
	check(st.err != "", "and reports an error rather than an empty folder")
	check(
		strings.contains(st.err, "permission"),
		"the error says it is about permission, got %q",
		st.err,
	)
	eqi(len(st.entries), 0, "nothing was read")
	// And the rest of the dialog keeps working: you can walk back out.
	check(kit.pick_up(&st), "you can leave a folder you cannot read")
	eq(st.dir, root, "and you land in its parent")
	eq(st.err, "", "where the error is gone")

	// --- a link to a directory --------------------------------------------
	if e, ok := entry_named(&st, "link-to-sub"); ok {
		check(e.is_link, "link-to-sub is marked as a link")
		check(e.is_dir, "and behaves as the directory it points at")
		kit.pick_go(&st, e.path)
		check(has_name(&st, "inner.txt"), "so it can be descended into")
		kit.pick_up(&st)
	} else {
		check(false, "link-to-sub is listed")
	}

	// --- a link to a file --------------------------------------------------
	if e, ok := entry_named(&st, "link-to-file"); ok {
		check(e.is_link, "link-to-file is a link")
		check(!e.is_dir, "and is not a directory")
	}

	// --- a symlink loop ----------------------------------------------------
	// This is the case that hangs a picker that resolves links recursively.
	for name in ([?]string{"loop-a", "loop-b", "self-loop"}) {
		if e, ok := entry_named(&st, name); ok {
			check(e.is_link, fmt.tprintf("%s is a link", name))
			check(!e.is_dir, fmt.tprintf("%s is never reported as a directory", name))
			// Asking to enter it must terminate, and must not move us.
			kit.pick_go(&st, e.path)
			check(
				st.dir != e.path,
				fmt.tprintf("entering %s does not become the current directory", name),
			)
			check(kit.pick_depth(st.dir) <= kit.PICK_MAX_DEPTH, "and the path stays bounded")
			kit.pick_go(&st, root)
		} else {
			check(false, fmt.tprintf("%s is listed", name))
		}
	}
	check(!kit.pick_is_dir(kit.pick_join(root, "loop-a", context.temp_allocator)), "a loop is not a directory")
	check(!kit.pick_is_dir(kit.pick_join(root, "self-loop", context.temp_allocator)), "a self-link is not a directory")
	check(kit.pick_exists(kit.pick_join(root, "loop-a", context.temp_allocator)), "but a loop does exist as a link")

	// --- a broken link -----------------------------------------------------
	broken := kit.pick_join(root, "broken-link", context.temp_allocator)
	check(kit.pick_exists(broken), "a broken link exists as a link")
	check(!kit.pick_is_dir(broken), "and is not a directory")
	check(!kit.pick_is_file(broken), "and is not a regular file")
	if e, ok := entry_named(&st, "broken-link"); ok {
		check(e.is_link, "it is listed as a link")
		check(!e.is_dir, "and not as a folder")
	}

	// --- a path that no longer exists --------------------------------------
	gone := kit.pick_join(root, "sub/deeper/was-here/and-here", context.temp_allocator)
	eq(
		kit.pick_existing_dir(gone),
		kit.pick_join(root, "sub/deeper", context.temp_allocator),
		"a dead path falls back to its nearest surviving ancestor",
	)
	eq(kit.pick_existing_dir("/no/such/path/anywhere"), "/", "with the root as the last resort")
	st2: kit.Pick
	defer kit.pick_destroy(&st2)
	pick_at(&st2, .Open_File, gone)
	eq(st2.dir, kit.pick_join(root, "sub/deeper", context.temp_allocator), "and reopening there lands somewhere real")
	eq(st2.err, "", "with no error")
	check(has_name(&st2, "leaf.png"), "showing the folder that does exist")

	// --- trailing slashes and dot-dot from a caller -----------------------
	st3: kit.Pick
	defer kit.pick_destroy(&st3)
	pick_at(&st3, .Open_File, fmt.tprintf("%s/sub/deeper/../", root))
	eq(st3.dir, kit.pick_join(root, "sub", context.temp_allocator), "a caller's dot-dot and trailing slash are normalised")

	// --- a caller that hands over a file, not a folder --------------------
	st4: kit.Pick
	defer kit.pick_destroy(&st4)
	kit.pick_begin(
		&st4,
		.Save_File,
		{dir = kit.pick_join(root, "alpha.txt", context.temp_allocator)},
	)
	eq(st4.dir, root, "a file path opens its enclosing folder")
	eq(kit.pick_name(&st4), "alpha.txt", "with that file's name in the field")
}

test_many :: proc(root: string) {
	section("five thousand entries")
	many := kit.pick_join(root, "many", context.temp_allocator)
	st: kit.Pick
	defer kit.pick_destroy(&st)

	t0 := time.now()
	pick_at(&st, .Open_File, many)
	load_ms := time.duration_milliseconds(time.since(t0))

	eqi(len(st.entries), 5000, "all five thousand entries were read")
	eqi(len(st.vis), 5000, "and all are visible")
	check(load_ms < 4000, "reading them took %.0f ms", load_ms)

	t1 := time.now()
	kit.pick_set_sort(&st, .Size)
	kit.pick_set_sort(&st, .Date)
	kit.pick_set_sort(&st, .Name)
	sort_ms := time.duration_milliseconds(time.since(t1))
	check(sort_ms < 1500, "three re-sorts took %.0f ms", sort_ms)

	eq(st.entries[st.vis[0]].name, "entry-0000.dat", "the first entry sorts first")
	eq(st.entries[st.vis[4999]].name, "entry-4999.dat", "and the last sorts last")

	// Moving to the end is O(1) on the model; the renderer's job is to draw
	// only what fits, which test_ui asserts on node count.
	kit.pick_move(&st, 1_000_000)
	eqi(st.sel, 4999, "End clamps to the last row")
	check(st.want_reveal, "and asks the list to scroll there")
	kit.pick_move(&st, -1_000_000)
	eqi(st.sel, 0, "Home clamps to the first row")

	// Type-ahead across five thousand names has to find the right one.
	kit.pick_typeahead_push(&st, "entry-2500", 0)
	e, ok := kit.pick_selected(&st)
	check(ok && e.name == "entry-2500.dat", "type-ahead found entry-2500.dat, got %q", e.name)
}

test_newfolder :: proc(root: string) {
	section("new folder")
	stage := kit.pick_join(root, "stage", context.temp_allocator)
	must(os.make_directory_all(stage), "make the staging directory")

	// --- unique naming ----------------------------------------------------
	eq(kit.pick_unique_name(stage, "untitled folder"), "untitled folder", "the first name is plain")
	must(os.make_directory_all(kit.pick_join(stage, "untitled folder", context.temp_allocator)), "make the first")
	eq(kit.pick_unique_name(stage, "untitled folder"), "untitled folder 2", "the second is numbered")
	must(os.make_directory_all(kit.pick_join(stage, "untitled folder 2", context.temp_allocator)), "make the second")
	eq(kit.pick_unique_name(stage, "untitled folder"), "untitled folder 3", "and the third")
	// A *file* with the name collides just as a folder does.
	must(os.write_entire_file(kit.pick_join(stage, "untitled folder 3", context.temp_allocator), []u8{}), "write a colliding file")
	eq(kit.pick_unique_name(stage, "untitled folder"), "untitled folder 4", "a file collides too")

	// --- the real thing ---------------------------------------------------
	st: kit.Pick
	defer kit.pick_destroy(&st)
	pick_at(&st, .Save_File, stage)

	kit.pick_new_folder_begin(&st)
	check(st.nf_open, "the prompt opened")
	eq(string(st.nf_buf[:]), "untitled folder 4", "pre-filled with a free name")

	// A bad name is refused in place, and the prompt stays open.
	clear(&st.nf_buf)
	append(&st.nf_buf, ..transmute([]u8)string("bad/name"))
	check(!kit.pick_new_folder_commit(&st), "a name with a slash is refused")
	check(st.nf_open, "and the prompt stays open")
	check(st.nf_err != "", "with the reason shown")

	// A name that already exists is refused too.
	clear(&st.nf_buf)
	append(&st.nf_buf, ..transmute([]u8)string("untitled folder"))
	check(!kit.pick_new_folder_commit(&st), "an existing name is refused")
	check(strings.contains(st.nf_err, "already"), "and says so, got %q", st.nf_err)

	// And a good one is created, inside the folder on screen and nowhere else.
	clear(&st.nf_buf)
	append(&st.nf_buf, ..transmute([]u8)string("تقارير 2026"))
	check(kit.pick_new_folder_commit(&st), "an RTL name with a space is created")
	check(!st.nf_open, "and the prompt closes")
	made := kit.pick_join(stage, "تقارير 2026", context.temp_allocator)
	check(kit.pick_is_dir(made), "the directory is really there")
	check(has_name(&st, "تقارير 2026"), "and appears in the refreshed listing")
	sel, _ := kit.pick_selected(&st)
	eq(sel.name, "تقارير 2026", "with the cursor moved onto it")

	// Cancelling creates nothing.
	kit.pick_new_folder_begin(&st)
	clear(&st.nf_buf)
	append(&st.nf_buf, ..transmute([]u8)string("never-created"))
	kit.pick_new_folder_cancel(&st)
	check(!st.nf_open, "cancelling closes the prompt")
	check(
		!kit.pick_exists(kit.pick_join(stage, "never-created", context.temp_allocator)),
		"and creates nothing",
	)

	// New Folder is not offered where nothing is being written.
	ro: kit.Pick
	defer kit.pick_destroy(&ro)
	pick_at(&ro, .Open_File, stage)
	kit.pick_new_folder_begin(&ro)
	check(!ro.nf_open, "an Open File dialog cannot create folders")
}

test_overwrite :: proc(root: string) {
	section("overwrite confirmation")
	stage := kit.pick_join(root, "save", context.temp_allocator)
	must(os.make_directory_all(stage), "make the save directory")
	must(os.write_entire_file(kit.pick_join(stage, "taken.png", context.temp_allocator), []u8{1, 2, 3}), "write the existing file")

	filters := [?]kit.Pick_Filter{kit.PICK_IMAGES, kit.PICK_ALL}
	st: kit.Pick
	defer kit.pick_destroy(&st)
	kit.pick_begin(&st, .Save_File, {dir = stage, name = "untitled.png", filters = filters[:]})

	// --- the field starts with the basename selected, not the extension ---
	eq(kit.pick_name(&st), "untitled.png", "the suggested name is loaded")
	eqi(kit.pick_name_sel_lo(&st), 0, "the selection starts at the beginning")
	eqi(kit.pick_name_sel_hi(&st), 8, "and ends before the dot")
	check(kit.pick_name_has_sel(&st), "so there is a selection")
	eq(kit.pick_name(&st)[kit.pick_name_sel_lo(&st):kit.pick_name_sel_hi(&st)], "untitled", "which is the basename")
	eq(kit.pick_name(&st)[kit.pick_name_sel_hi(&st):], ".png", "and the extension is outside it")
	check(st.pane == .Name, "and the name field has the keyboard")

	// A name with no extension selects entirely; a dotfile does too.
	kit.pick_set_name(&st, "noext")
	eqi(kit.pick_name_sel_hi(&st), 5, "a name with no extension is selected whole")
	kit.pick_set_name(&st, ".bashrc")
	eqi(kit.pick_name_sel_hi(&st), 7, "and so is a dotfile")
	kit.pick_set_name(&st, "archive.tar.gz")
	eqi(kit.pick_name_sel_hi(&st), 11, "a double extension selects up to the last dot")
	kit.pick_set_name(&st, "résumé.pdf")
	eqi(kit.pick_name_sel_hi(&st), 8, "a unicode basename selects on a rune boundary")

	// --- the target path, extension and all -------------------------------
	kit.pick_set_name(&st, "fresh")
	eq(kit.pick_target(&st), kit.pick_join(stage, "fresh.png", context.temp_allocator), "the filter supplies the extension")
	kit.pick_set_filter(&st, 1) // All files
	eq(
		kit.pick_target(&st),
		kit.pick_join(stage, "fresh", context.temp_allocator),
		"under All files the name is taken exactly as typed",
	)
	kit.pick_set_filter(&st, 0)
	eq(
		kit.pick_target(&st),
		kit.pick_join(stage, "fresh.png", context.temp_allocator),
		"and the extension comes back with the Images filter",
	)

	// Switching filters rewrites the extension but keeps the stem.
	kit.pick_set_name(&st, "shot.png")
	text_only := [?]kit.Pick_Filter{kit.PICK_IMAGES, kit.PICK_TEXT}
	st.filters = text_only[:]
	kit.pick_set_filter(&st, 1)
	eq(kit.pick_name(&st), "shot.txt", "changing the filter re-extends the name")
	st.filters = filters[:]
	kit.pick_set_filter(&st, 0)

	// --- a free name saves straight through -------------------------------
	kit.pick_set_name(&st, "brand-new")
	kit.pick_confirm(&st)
	check(!st.cf_open, "a name nothing uses needs no confirmation")
	check(st.done, "and the dialog finished")
	res := st.result
	check(res.ok, "with a result")
	eq(res.path, kit.pick_join(stage, "brand-new.png", context.temp_allocator), "naming the file to write")
	check(!res.overwrite, "and not flagged as an overwrite")
	kit.pick_result_free(res)
	st.result = {}
	st.done = false

	// --- a taken name must be confirmed, and Cancel is the default --------
	kit.pick_begin(&st, .Save_File, {dir = stage, name = "taken.png", filters = filters[:]})
	kit.pick_confirm(&st)
	check(st.cf_open, "an existing name raises the confirmation")
	check(!st.done, "and does not finish the dialog")
	eqi(st.cf_sel, 0, "with Cancel focused, which is the whole point")
	eq(kit.pick_base(st.cf_path), "taken.png", "the dialog names the file at risk")
	eq(st.cf_path, kit.pick_join(stage, "taken.png", context.temp_allocator), "by its full path")

	kit.pick_cancel_overwrite(&st)
	check(!st.cf_open, "declining closes the confirmation")
	check(!st.done, "and leaves the dialog up")
	check(st.open, "still open")
	before, _ := os.read_entire_file(kit.pick_join(stage, "taken.png", context.temp_allocator), context.temp_allocator)
	eqi(len(before), 3, "and the file on disk is untouched")

	// Confirming it a second time, and then accepting.
	kit.pick_confirm(&st)
	check(st.cf_open, "the confirmation can be raised again")
	eqi(st.cf_sel, 0, "and it still starts on Cancel")
	st.cf_sel = 1
	kit.pick_confirm_overwrite(&st)
	check(!st.cf_open, "accepting closes it")
	check(st.done, "and finishes the dialog")
	res2 := st.result
	check(res2.ok, "with a result")
	eq(res2.path, kit.pick_join(stage, "taken.png", context.temp_allocator), "naming the file to replace")
	check(res2.overwrite, "flagged as an overwrite, so the host app knows")
	kit.pick_result_free(res2)
	st.result = {}
	st.done = false

	// Nothing was written by the picker itself: replacing is the host's job.
	after, _ := os.read_entire_file(kit.pick_join(stage, "taken.png", context.temp_allocator), context.temp_allocator)
	eqi(len(after), 3, "the picker never writes the file itself")

	// --- a name that is a folder navigates instead of saving --------------
	must(os.make_directory_all(kit.pick_join(stage, "a-folder", context.temp_allocator)), "make a folder in the way")
	kit.pick_begin(&st, .Save_File, {dir = stage, filters = filters[:]})
	kit.pick_set_name(&st, "a-folder")
	// With the Images filter the typed name becomes a-folder.png, which does
	// not exist — so navigate on the literal name instead.
	st.filters = nil
	kit.pick_set_name(&st, "a-folder")
	kit.pick_confirm(&st)
	check(!st.done, "saving onto a folder name does not finish")
	eq(st.dir, kit.pick_join(stage, "a-folder", context.temp_allocator), "it navigates into it")
	eq(kit.pick_name(&st), "", "and clears the name field")

	// --- an empty or impossible name cannot be confirmed ------------------
	kit.pick_begin(&st, .Save_File, {dir = stage, filters = filters[:]})
	kit.pick_set_name(&st, "")
	check(!kit.pick_can_confirm(&st), "an empty name cannot be saved")
	kit.pick_confirm(&st)
	check(!st.done, "and confirming it does nothing")
	check(st.err != "", "but says why")
	kit.pick_set_name(&st, "   ")
	check(!kit.pick_can_confirm(&st), "nor can whitespace")
	kit.pick_set_name(&st, "fine")
	check(kit.pick_can_confirm(&st), "a real name can")
	kit.pick_cancel(&st)
	r3 := st.result
	check(!r3.ok, "cancelling yields no result")
	eqi(len(r3.paths), 0, "and no paths")
	st.done = false
}

test_vanishing :: proc(root: string) {
	section("a file deleted underneath you")
	stage := kit.pick_join(root, "vanish", context.temp_allocator)
	must(os.make_directory_all(stage), "make the vanish directory")
	victim := kit.pick_join(stage, "here-for-now.txt", context.temp_allocator)
	must(os.write_entire_file(victim, []u8{1}), "write the victim")
	must(os.write_entire_file(kit.pick_join(stage, "survivor.txt", context.temp_allocator), []u8{1}), "write the survivor")

	st: kit.Pick
	defer kit.pick_destroy(&st)
	pick_at(&st, .Open_File, stage)
	check(kit.pick_select_name(&st, "here-for-now.txt"), "the victim is listed and selected")

	// Somebody else removes it between the listing and the keystroke.
	must(os.remove(victim), "remove the victim")

	kit.pick_confirm(&st)
	check(!st.done, "opening a file that is gone does not finish the dialog")
	check(st.open, "the dialog stays up")
	check(st.err != "", "and says what happened")
	check(strings.contains(st.err, "here-for-now.txt"), "naming the file, got %q", st.err)
	check(!has_name(&st, "here-for-now.txt"), "the listing was refreshed and it is gone")
	check(has_name(&st, "survivor.txt"), "and the rest is still there")

	// The same for a multi-selection: the marks that are gone are dropped,
	// and only a selection that is entirely gone is an error.
	must(os.write_entire_file(victim, []u8{1}), "put the victim back")
	mst: kit.Pick
	defer kit.pick_destroy(&mst)
	pick_at(&mst, .Open_Files, stage)
	kit.pick_mark_all(&mst, true)
	eqi(mst.marks, 2, "both files are marked")
	must(os.remove(victim), "remove the victim again")
	kit.pick_confirm(&mst)
	check(mst.done, "a selection with one survivor still finishes")
	r := mst.result
	check(r.ok, "with a result")
	eqi(len(r.paths), 1, "holding only the file that still exists")
	eq(kit.pick_base(r.paths[0]), "survivor.txt", "which is the survivor")
	kit.pick_result_free(r)
	mst.result = {}
	mst.done = false

	// And a whole directory that disappears while the dialog is on it.
	dst: kit.Pick
	defer kit.pick_destroy(&dst)
	doomed := kit.pick_join(stage, "doomed", context.temp_allocator)
	must(os.make_directory_all(doomed), "make the doomed directory")
	pick_at(&dst, .Open_Folder, doomed)
	eq(dst.dir, doomed, "the dialog is on it")
	must(os.remove_all(doomed), "remove the doomed directory")
	kit.pick_choose_here(&dst)
	check(!dst.done, "choosing a folder that is gone does not finish")
	check(dst.err != "", "and says so")
	eq(dst.dir, stage, "having fallen back to the parent")
	kit.pick_reload(&dst)
	check(dst.err == "", "which reads cleanly")

	// Multi-select bookkeeping.
	ms: kit.Pick
	defer kit.pick_destroy(&ms)
	pick_at(&ms, .Open_Files, root)
	eqi(ms.marks, 0, "nothing starts marked")
	kit.pick_select_name(&ms, "alpha.txt")
	kit.pick_mark_current(&ms)
	eqi(ms.marks, 1, "marking one counts one")
	kit.pick_mark_current(&ms)
	eqi(ms.marks, 0, "and unmarking it counts none")
	kit.pick_select_name(&ms, "sub")
	kit.pick_mark_current(&ms)
	eqi(ms.marks, 0, "a folder cannot be marked")
	kit.pick_mark_all(&ms, true)
	check(ms.marks > 1, "select-all marks the files, got %d", ms.marks)
	for i in ms.vis {
		if ms.entries[i].is_dir {
			check(!ms.entries[i].marked, "and never a folder")
		}
	}
	kit.pick_mark_all(&ms, false)
	eqi(ms.marks, 0, "and it can be undone")
}

test_completion :: proc(root: string) {
	section("path completion")
	// Unambiguous: one entry starts with "sur".
	stage := kit.pick_join(root, "vanish", context.temp_allocator)
	out, unique, n := kit.pick_complete(fmt.tprintf("%s/sur", stage), "/")
	eqi(n, 1, "one entry matches sur")
	check(unique, "so the completion is unique")
	eq(out, fmt.tprintf("%s/survivor.txt", stage), "and it completes the whole name")

	// A directory gains a trailing slash, so the next Tab descends.
	out2, unique2, _ := kit.pick_complete(fmt.tprintf("%s/su", root), "/")
	check(unique2, "su is unique in the fixture root")
	eq(out2, fmt.tprintf("%s/sub/", root), "and a directory completes with a slash")

	// Ambiguous: the common prefix only.
	out3, unique3, n3 := kit.pick_complete(fmt.tprintf("%s/many/entry-00", root), "/")
	check(n3 > 1, "entry-00 matches many, got %d", n3)
	check(!unique3, "so it is not unique")
	eq(out3, fmt.tprintf("%s/many/entry-00", root), "and only the common prefix is offered")
	out4, unique4, n4 := kit.pick_complete(fmt.tprintf("%s/many/entry-012", root), "/")
	eqi(n4, 10, "entry-012 matches entry-0120 through entry-0129")
	check(!unique4, "so it is not unique")
	eq(out4, fmt.tprintf("%s/many/entry-012", root), "and the common prefix is all ten agree on")
	out4b, unique4b, n4b := kit.pick_complete(fmt.tprintf("%s/many/entry-0123", root), "/")
	eqi(n4b, 1, "one more digit makes it unique")
	check(unique4b, "so the whole name is offered")
	eq(out4b, fmt.tprintf("%s/many/entry-0123.dat", root), "extension and all")

	// No match leaves the input alone.
	out5, _, n5 := kit.pick_complete(fmt.tprintf("%s/zzzzz", root), "/")
	eqi(n5, 0, "nothing matches zzzzz")
	eq(out5, fmt.tprintf("%s/zzzzz", root), "and the input is returned unchanged")

	// A folder that cannot be read completes to nothing rather than failing.
	_, _, n6 := kit.pick_complete(fmt.tprintf("%s/%s/sec", root, PERM_DIR), "/")
	eqi(n6, 0, "a locked folder offers no completions")

	// `~` is expanded before the directory is read.
	home := kit.pick_home(context.temp_allocator)
	_, _, n7 := kit.pick_complete("~/", home)
	check(n7 >= 0, "completing ~/ does not fail")

	// A relative input resolves against the directory on screen.
	out8, _, n8 := kit.pick_complete("sur", stage)
	eqi(n8, 1, "a relative input completes")
	eq(out8, "survivor.txt", "keeping it relative, as typed")
}

// ---------------------------------------------------------------------------
// 4. Memory
//
// The picker is opened and closed over and over by a long-lived application,
// and it allocates a string per entry per column. A leak here is a leak that
// grows every time somebody presses Ctrl+O, so it is asserted on rather than
// assumed.
// ---------------------------------------------------------------------------

test_memory :: proc(root: string) {
	section("memory")
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)

		st: kit.Pick
		for _ in 0 ..< 6 {
			kit.pick_begin(&st, .Open_File, {dir = root})
			kit.pick_toggle_hidden(&st)
			kit.pick_set_sort(&st, .Size)
			kit.pick_go(&st, kit.pick_join(root, "sub", context.temp_allocator))
			kit.pick_up(&st)
			kit.pick_typeahead_push(&st, "no", 0)
			kit.pick_select_name(&st, "alpha.txt")
			kit.pick_confirm(&st)
			if st.done {
				kit.pick_result_free(st.result)
				st.result = {}
				st.done = false
			}
		}
		// A result deliberately left uncollected: reopening has to reclaim it.
		kit.pick_begin(&st, .Open_File, {dir = root})
		kit.pick_select_name(&st, "alpha.txt")
		kit.pick_confirm(&st)
		kit.pick_begin(&st, .Save_File, {dir = root, name = "x.png"})
		kit.pick_cancel(&st)
		st.done = false

		kit.pick_destroy(&st)
	}

	leaked := 0
	bytes := 0
	for _, entry in track.allocation_map {
		leaked += 1
		bytes += entry.size
	}
	check(
		leaked == 0,
		"seven open-and-close cycles leaked nothing, got %d allocations / %d bytes",
		leaked,
		bytes,
	)
	check(
		len(track.bad_free_array) == 0,
		"and freed nothing twice, got %d bad frees",
		len(track.bad_free_array),
	)
	if leaked > 0 {
		shown := 0
		for _, entry in track.allocation_map {
			fmt.printf("    leak: %d bytes at %v\n", entry.size, entry.location)
			shown += 1
			if shown >= 8 {
				break
			}
		}
	}
}

// ---------------------------------------------------------------------------
// 3. The dialog itself, through palmy's offscreen renderer
// ---------------------------------------------------------------------------

FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"

load_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			break
		}
	}
}

Rig :: struct {
	off:  ^p.Offscreen,
	pick: kit.Pick,
	last: kit.Pick_Result,
	done: bool,
}

rig_make :: proc() -> ^Rig {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	r := new(Rig)
	r.off = p.offscreen_create(1100, 720, 1, "w-full h-full bg-background text-foreground")
	load_fonts(&r.off.fonts)
	return r
}

rig_free :: proc(r: ^Rig) {
	kit.pick_destroy(&r.pick)
	p.offscreen_destroy(r.off)
	free(r)
}

// step renders one frame and records a result if the dialog closed on it.
step :: proc(r: ^Rig) {
	ui := p.offscreen_begin(r.off)
	res, done := kit.pick_draw(ui, &r.pick)
	if done {
		if r.done {
			kit.pick_result_free(r.last)
		}
		r.last = res
		r.done = true
	}
	// A host application draws behind the dialog; a plain box stands in.
	p.div(ui, "w-full h-full bg-background")
	p.end(ui)
	p.offscreen_end(r.off)
}

steps :: proc(r: ^Rig, n: int) {
	for _ in 0 ..< n {
		step(r)
	}
}

// key queues a keysym and renders the frame that sees it.
key :: proc(r: ^Rig, sym: u32, mods: p.Modifiers = {}) {
	p.press_key(r.off, sym, mods)
	step(r)
}

typ :: proc(r: ^Rig, text: string) {
	p.type_text(r.off, text)
	step(r)
}

// click is a full press-and-release at a point, which palmy resolves on the
// frame the button comes back up.
click :: proc(r: ^Rig, x, y: f32) {
	p.move_pointer(r.off, x, y)
	step(r)
	p.press(r.off)
	step(r)
	p.release(r.off)
	step(r)
}

// keep clones a path into the ordinary allocator. Every rendered frame ends
// with `free_all(context.temp_allocator)`, so a temp-allocated path used after
// a `step` is a dangling slice — which is exactly the sort of bug a test rig
// hides until it compares against garbage.
keep :: proc(s: string) -> string {
	return strings.clone(s)
}

test_ui :: proc(root: string) {
	section("driving the real dialog")
	r := rig_make()
	defer rig_free(r)

	sub := keep(kit.pick_join(root, "sub", context.temp_allocator))
	locked := keep(kit.pick_join(root, PERM_DIR, context.temp_allocator))
	many := keep(kit.pick_join(root, "many", context.temp_allocator))
	stage := keep(kit.pick_join(root, "save", context.temp_allocator))
	nfdir := keep(kit.pick_join(root, "ui-newfolder", context.temp_allocator))
	alpha := keep(kit.pick_join(root, "alpha.txt", context.temp_allocator))
	taken := keep(kit.pick_join(stage, "taken.png", context.temp_allocator))
	defer {
		delete(sub)
		delete(locked)
		delete(many)
		delete(stage)
		delete(nfdir)
		delete(alpha)
		delete(taken)
	}

	// ---------------------------------------------------------------------
	// Open mode: navigate entirely from the keyboard.
	// ---------------------------------------------------------------------
	filters := [?]kit.Pick_Filter{kit.PICK_ALL, kit.PICK_IMAGES, kit.PICK_TEXT}
	kit.pick_begin(&r.pick, .Open_File, {dir = root, filters = filters[:]})
	steps(r, 3)
	check(kit.pick_active(&r.pick), "the dialog is up")
	check(!r.done, "and has not reported anything")
	check(r.pick.list_id != 0, "the list laid itself out")
	check(r.pick.pane == .List, "with the list holding the keyboard")

	// The whole panel is on screen: its scrim covers the window and it draws
	// a bounded number of nodes even though the fixture has many entries.
	nodes_small := p.node_count(&r.off.ctx)
	check(nodes_small > 100, "the dialog built a real tree, %d nodes", nodes_small)

	// --- Down/Up, and j/k -------------------------------------------------
	first, _ := kit.pick_selected(&r.pick)
	key(r, p.KEY_DOWN)
	second, _ := kit.pick_selected(&r.pick)
	check(second.name != first.name, "Down moved the cursor")
	eqi(r.pick.sel, 1, "to the second row")
	key(r, p.KEY_UP)
	eqi(r.pick.sel, 0, "and Up moved it back")
	typ(r, "j")
	eqi(r.pick.sel, 1, "j moves down")
	typ(r, "j")
	eqi(r.pick.sel, 2, "and again")
	typ(r, "k")
	eqi(r.pick.sel, 1, "k moves up")
	eqi(len(r.pick.ahead), 0, "and neither started a type-ahead search")

	// --- type-ahead -------------------------------------------------------
	typ(r, "sub")
	e, _ := kit.pick_selected(&r.pick)
	eq(e.name, "sub", "typing sub jumped to the sub folder")
	eq(string(r.pick.ahead[:]), "sub", "and the search string is shown")
	// Once a search is running, j and k are letters again.
	kit.pick_typeahead_clear(&r.pick)
	typ(r, "r")
	e2, _ := kit.pick_selected(&r.pick)
	check(
		strings.has_prefix(strings.to_lower(e2.name, context.temp_allocator), "r"),
		"typing r jumped to something starting with r, got %q",
		e2.name,
	)

	// --- Enter descends, Backspace comes back -----------------------------
	kit.pick_typeahead_clear(&r.pick)
	check(kit.pick_select_name(&r.pick, "sub"), "select the sub folder")
	step(r)
	key(r, p.KEY_RETURN)
	eq(r.pick.dir, sub, "Enter descended into it")
	check(!r.done, "without reporting a result")
	steps(r, 2)
	check(has_name(&r.pick, "inner.txt"), "and the new listing is there")
	key(r, p.KEY_BACKSPACE)
	eq(r.pick.dir, root, "Backspace went back up")
	sel, _ := kit.pick_selected(&r.pick)
	eq(sel.name, "sub", "landing on the folder just left")

	// Right descends and Left comes back out, which is the other idiom.
	key(r, p.KEY_RIGHT)
	eq(r.pick.dir, sub, "Right descended")
	key(r, p.KEY_LEFT)
	eq(r.pick.dir, root, "Left came back")

	// --- Tab cycles the panes ---------------------------------------------
	panes: [4]kit.Pick_Pane
	order := kit.pick_panes(&r.pick, panes[:])
	eqi(len(order), 3, "Open mode with filters has three panes")
	start := r.pick.pane
	key(r, p.KEY_TAB)
	check(r.pick.pane != start, "Tab moved to another pane")
	key(r, p.KEY_TAB)
	key(r, p.KEY_TAB)
	check(r.pick.pane == start, "and three Tabs came back round")

	// --- the sidebar from the keyboard ------------------------------------
	for r.pick.pane != .Places {
		key(r, p.KEY_TAB)
	}
	before_dir := keep(r.pick.dir)
	key(r, p.KEY_DOWN)
	check(r.pick.dir != before_dir, "Down in the sidebar navigated")
	delete(before_dir)
	check(kit.pick_is_dir(r.pick.dir), "to a real directory")
	key(r, p.KEY_RETURN)
	check(r.pick.pane == .List, "and Enter handed the keyboard to the list")

	// --- Ctrl+H ------------------------------------------------------------
	kit.pick_go(&r.pick, root)
	steps(r, 2)
	check(!r.pick.show_hidden, "hidden files start hidden")
	key(r, 'h', {.Ctrl})
	check(r.pick.show_hidden, "Ctrl+H showed them")
	check(has_name(&r.pick, ".hidden-config"), "and the listing has them")
	key(r, 'h', {.Ctrl})
	check(!r.pick.show_hidden, "Ctrl+H hid them again")

	// --- sort from the keyboard -------------------------------------------
	key(r, '2', {.Ctrl})
	check(r.pick.sort == .Size, "Ctrl+2 sorted by size")
	key(r, '3', {.Ctrl})
	check(r.pick.sort == .Date, "Ctrl+3 sorted by date")
	key(r, '1', {.Ctrl})
	check(r.pick.sort == .Name, "Ctrl+1 sorted by name")

	// --- the filter dropdown ----------------------------------------------
	for r.pick.pane != .Filter {
		key(r, p.KEY_TAB)
	}
	key(r, p.KEY_RETURN)
	check(r.pick.filter_open, "Enter opened the filter list")
	key(r, p.KEY_DOWN)
	eqi(r.pick.filter_sel, 1, "Down moved to Images")
	key(r, p.KEY_RETURN)
	check(!r.pick.filter_open, "Enter closed it")
	eqi(r.pick.filter, 1, "with Images active")
	steps(r, 2)
	check(!has_name(&r.pick, "alpha.txt"), "and text files are filtered out")
	check(has_name(&r.pick, "Beta.PNG"), "while images stay")
	check(has_name(&r.pick, "sub"), "and folders are never filtered")
	key(r, p.KEY_ESCAPE)
	check(!kit.pick_active(&r.pick), "Escape closed the dialog")
	check(r.done, "which reported done")
	check(!r.last.ok, "with no choice")

	// ---------------------------------------------------------------------
	// Ctrl+L: type a literal path, complete it, open it.
	// ---------------------------------------------------------------------
	r.done = false
	kit.pick_begin(&r.pick, .Open_File, {dir = root})
	steps(r, 2)
	key(r, 'l', {.Ctrl})
	check(r.pick.loc_open, "Ctrl+L opened the path bar")
	check(strings.has_suffix(string(r.pick.loc_buf[:]), "/"), "pre-filled with the current folder")
	// Typing a `/` anywhere also opens it, which is the other habit.
	key(r, p.KEY_ESCAPE)
	check(!r.pick.loc_open, "Escape closed the path bar")
	check(kit.pick_active(&r.pick), "without closing the dialog")
	typ(r, "/")
	check(r.pick.loc_open, "typing a slash opened the path bar")

	// Clear it and type a path by hand.
	key(r, 'u', {.Ctrl})
	eqi(len(r.pick.loc_buf), 0, "Ctrl+U emptied it")
	typ(r, fmt.tprintf("%s/su", root))
	key(r, p.KEY_TAB)
	eq(string(r.pick.loc_buf[:]), fmt.tprintf("%s/", sub), "Tab completed the directory")
	key(r, p.KEY_RETURN)
	check(!r.pick.loc_open, "Enter closed the path bar")
	eq(r.pick.dir, sub, "and opened the folder")
	check(kit.pick_active(&r.pick), "the dialog is still up")

	// A path that does not exist says so, and leaves the bar open.
	key(r, 'l', {.Ctrl})
	key(r, 'u', {.Ctrl})
	typ(r, "/no/such/place/at/all")
	key(r, p.KEY_RETURN)
	check(r.pick.loc_open, "a bad path leaves the bar open")
	check(r.pick.loc_note != "", "with a note, got %q", r.pick.loc_note)
	key(r, p.KEY_ESCAPE)

	// Choosing a file for real.
	key(r, 'l', {.Ctrl})
	key(r, 'u', {.Ctrl})
	typ(r, fmt.tprintf("%s/alpha.txt", root))
	key(r, p.KEY_RETURN)
	steps(r, 2)
	sel2, ok2 := kit.pick_selected(&r.pick)
	check(ok2 && sel2.name == "alpha.txt", "the typed file is selected, got %q", sel2.name)
	key(r, p.KEY_RETURN)
	check(r.done, "Enter chose it")
	check(r.last.ok, "with a result")
	eq(r.last.path, alpha, "naming the file")
	eqi(len(r.last.paths), 1, "as a single path")

	// ---------------------------------------------------------------------
	// Open_Files: mark several with Space.
	// ---------------------------------------------------------------------
	kit.pick_result_free(r.last)
	r.last = {}
	r.done = false
	kit.pick_begin(&r.pick, .Open_Files, {dir = root})
	steps(r, 2)
	kit.pick_select_name(&r.pick, "alpha.txt")
	step(r)
	key(r, p.KEY_SPACE)
	eqi(r.pick.marks, 1, "Space marked one file")
	kit.pick_select_name(&r.pick, "notes.md")
	step(r)
	key(r, p.KEY_SPACE)
	eqi(r.pick.marks, 2, "and a second")
	key(r, p.KEY_SPACE)
	eqi(r.pick.marks, 1, "Space again unmarked it")
	key(r, p.KEY_SPACE)
	eqi(r.pick.marks, 2, "and marked it back")
	key(r, p.KEY_RETURN)
	check(r.done, "Enter finished with the marked set")
	check(r.last.ok, "with a result")
	eqi(len(r.last.paths), 2, "holding both files")

	// ---------------------------------------------------------------------
	// Save mode: the name field, then the overwrite confirmation, declined
	// and then accepted.
	// ---------------------------------------------------------------------
	kit.pick_result_free(r.last)
	r.last = {}
	r.done = false
	sfilters := [?]kit.Pick_Filter{kit.PICK_IMAGES, kit.PICK_ALL}
	kit.pick_begin(
		&r.pick,
		.Save_File,
		{dir = stage, name = "untitled.png", filters = sfilters[:]},
	)
	steps(r, 2)
	check(r.pick.pane == .Name, "the name field has the keyboard on open")
	eq(kit.pick_name(&r.pick), "untitled.png", "with the suggested name")

	// Typing replaces the selected basename and keeps the extension. This is
	// the detail the whole field exists for.
	typ(r, "holiday")
	eq(kit.pick_name(&r.pick), "holiday.png", "typing replaced the basename and kept .png")
	check(!kit.pick_name_has_sel(&r.pick), "and collapsed the selection")
	eqi(r.pick.name_cur, 7, "with the caret after what was typed")

	// Backspace edits the basename, not the extension.
	key(r, p.KEY_BACKSPACE)
	eq(kit.pick_name(&r.pick), "holida.png", "Backspace removed one character of the basename")
	typ(r, "y")
	eq(kit.pick_name(&r.pick), "holiday.png", "and it can be typed back")

	// End, Home and the arrows behave.
	key(r, p.KEY_END)
	eqi(r.pick.name_cur, 11, "End goes to the end")
	key(r, p.KEY_HOME)
	eqi(r.pick.name_cur, 0, "Home goes to the start")
	key(r, p.KEY_RIGHT)
	eqi(r.pick.name_cur, 1, "Right moves one")
	key(r, 'a', {.Ctrl})
	check(kit.pick_name_has_sel(&r.pick), "Ctrl+A selects everything")
	eqi(kit.pick_name_sel_hi(&r.pick), 11, "all eleven bytes")

	// A unicode name is edited a rune at a time, not a byte at a time.
	kit.pick_set_name(&r.pick, "été.png")
	r.pick.name_anchor = len("été.png")
	r.pick.name_cur = len("été.png")
	step(r)
	key(r, p.KEY_BACKSPACE)
	eq(kit.pick_name(&r.pick), "été.pn", "Backspace over ASCII")
	for _ in 0 ..< 3 {
		key(r, p.KEY_BACKSPACE)
	}
	eq(kit.pick_name(&r.pick), "été", "and down to the stem")
	key(r, p.KEY_BACKSPACE)
	eq(kit.pick_name(&r.pick), "ét", "a two-byte rune goes in one keystroke")
	key(r, p.KEY_BACKSPACE)
	eq(kit.pick_name(&r.pick), "é", "and so does the next")
	key(r, p.KEY_BACKSPACE)
	eq(kit.pick_name(&r.pick), "", "leaving the field empty")
	check(!kit.pick_can_confirm(&r.pick), "which cannot be confirmed")

	// Now the overwrite path, with the file that already exists.
	kit.pick_set_name(&r.pick, "taken.png")
	step(r)
	key(r, p.KEY_RETURN)
	check(r.pick.cf_open, "Enter on an existing name raised the confirmation")
	check(!r.done, "and did not finish")
	eqi(r.pick.cf_sel, 0, "with Cancel focused")

	// Enter, the cheapest keystroke, declines.
	key(r, p.KEY_RETURN)
	check(!r.pick.cf_open, "Enter took the focused button, which was Cancel")
	check(!r.done, "so nothing was reported")
	check(kit.pick_active(&r.pick), "and the dialog is still up")

	// Escape declines too.
	key(r, p.KEY_RETURN)
	check(r.pick.cf_open, "the confirmation is back")
	key(r, p.KEY_ESCAPE)
	check(!r.pick.cf_open, "Escape declined it")
	check(kit.pick_active(&r.pick), "without closing the dialog")

	// Only a deliberate move onto Replace goes through.
	key(r, p.KEY_RETURN)
	check(r.pick.cf_open, "raise it once more")
	key(r, p.KEY_RIGHT)
	eqi(r.pick.cf_sel, 1, "Right moved onto Replace")
	key(r, p.KEY_LEFT)
	eqi(r.pick.cf_sel, 0, "and Left moved back to Cancel")
	key(r, p.KEY_TAB)
	eqi(r.pick.cf_sel, 1, "Tab also reaches Replace")
	key(r, p.KEY_RETURN)
	check(!r.pick.cf_open, "Enter on Replace accepted")
	check(r.done, "and finished the dialog")
	check(r.last.ok, "with a result")
	eq(r.last.path, taken, "naming the file to replace")
	check(r.last.overwrite, "flagged as an overwrite")

	// ---------------------------------------------------------------------
	// New Folder, from the keyboard, in the real dialog.
	// ---------------------------------------------------------------------
	kit.pick_result_free(r.last)
	r.last = {}
	r.done = false
	must(os.make_directory_all(nfdir), "make the new-folder directory")
	kit.pick_begin(&r.pick, .Save_File, {dir = nfdir, name = "x.txt"})
	steps(r, 2)
	key(r, 'n', {.Ctrl})
	check(r.pick.nf_open, "Ctrl+N opened the New Folder prompt")
	key(r, 'u', {.Ctrl})
	typ(r, "Reports")
	eq(string(r.pick.nf_buf[:]), "Reports", "the typed name")
	key(r, p.KEY_RETURN)
	check(!r.pick.nf_open, "Enter created it and closed the prompt")
	check(
		kit.pick_is_dir(kit.pick_join(nfdir, "Reports", context.temp_allocator)),
		"the folder is really on disk",
	)
	check(has_name(&r.pick, "Reports"), "and shows in the listing")
	// The Save name survived the detour.
	eq(kit.pick_name(&r.pick), "x.txt", "and the name being saved is untouched")

	// The prompt can be cancelled with Escape and writes nothing.
	key(r, 'n', {.Ctrl})
	key(r, 'u', {.Ctrl})
	typ(r, "Nope")
	key(r, p.KEY_ESCAPE)
	check(!r.pick.nf_open, "Escape closed the prompt")
	check(kit.pick_active(&r.pick), "without closing the dialog")
	check(
		!kit.pick_exists(kit.pick_join(nfdir, "Nope", context.temp_allocator)),
		"and created nothing",
	)
	key(r, p.KEY_ESCAPE)
	check(!kit.pick_active(&r.pick), "and then Escape closes the dialog")

	// ---------------------------------------------------------------------
	// A folder with five thousand entries: the tree stays small and the
	// scroll offset follows the selection.
	// ---------------------------------------------------------------------
	r.done = false
	kit.pick_begin(&r.pick, .Open_File, {dir = many})
	steps(r, 4)
	eqi(len(r.pick.vis), 5000, "all five thousand are in the model")
	nodes_many := p.node_count(&r.off.ctx)
	check(
		nodes_many < nodes_small * 2,
		"five thousand entries draw %d nodes, against %d for twenty-odd",
		nodes_many,
		nodes_small,
	)
	check(nodes_many < 900, "which is a bounded tree, %d nodes", nodes_many)

	// Scrolling to the end and back, through palmy's own scroll container.
	key(r, p.KEY_END)
	steps(r, 4)
	eqi(r.pick.sel, 4999, "End selected the last row")
	off_end := p.scroll_of(&r.off.ctx, r.pick.list_id).y
	check(off_end > 1000, "and the list scrolled a long way down, %.0f px", off_end)
	check(!r.pick.want_reveal, "with the reveal satisfied")
	nodes_end := p.node_count(&r.off.ctx)
	check(nodes_end < 900, "still a bounded tree at the end, %d nodes", nodes_end)

	key(r, p.KEY_HOME)
	steps(r, 3)
	off_home := p.scroll_of(&r.off.ctx, r.pick.list_id).y
	check(off_home < 1, "Home scrolled back to the top, %.0f px", off_home)

	// Page Down moves by a screenful, not by one row.
	key(r, p.KEY_PAGE_DOWN)
	steps(r, 2)
	check(r.pick.sel > 10, "Page Down moved a screenful, to row %d", r.pick.sel)
	page := r.pick.sel
	key(r, p.KEY_PAGE_UP)
	steps(r, 2)
	eqi(r.pick.sel, 0, "and Page Up came back")
	check(page > 1, "a page is more than one row")

	// The wheel scrolls it too, through the same container. palmy routes a
	// wheel event to the innermost scrollable region *under the pointer*, so
	// the pointer has to be in the list first — which is also the only way a
	// real wheel event ever arrives.
	list_rect := p.rect_of(&r.off.ctx, r.pick.list_id)
	check(list_rect.h > 100, "the list is a real rectangle, %.0f px tall", list_rect.h)
	p.move_pointer(r.off, list_rect.x + list_rect.w / 2, list_rect.y + list_rect.h / 2)
	step(r)
	p.scroll_by(r.off, 0, 40)
	steps(r, 2)
	off_wheel := p.scroll_of(&r.off.ctx, r.pick.list_id).y
	check(off_wheel > 0, "the wheel scrolled the list, %.0f px", off_wheel)

	key(r, p.KEY_ESCAPE)
	check(!kit.pick_active(&r.pick), "and Escape closes it")

	// ---------------------------------------------------------------------
	// A locked folder, drawn: the error is in place and the dialog is usable.
	// ---------------------------------------------------------------------
	r.done = false
	kit.pick_begin(&r.pick, .Open_File, {dir = locked})
	steps(r, 3)
	check(r.pick.err != "", "the locked folder reports its error")
	check(p.node_count(&r.off.ctx) > 50, "and the dialog still drew itself")
	key(r, p.KEY_BACKSPACE)
	steps(r, 2)
	eq(r.pick.dir, root, "Backspace still works out of it")
	eq(r.pick.err, "", "and the error is cleared")

	// Long and RTL names are drawn without overflowing: the row is exactly
	// PICK_ROW_H tall whatever is in it.
	check(kit.pick_select_name(&r.pick, LONG_NAME), "the very long name is selectable")
	steps(r, 3)
	check(kit.pick_select_name(&r.pick, "ملف-عربي.txt"), "and so is the RTL one")
	steps(r, 3)
	check(p.node_count(&r.off.ctx) < 900, "with the tree still bounded")
	key(r, p.KEY_ESCAPE)

	// ---------------------------------------------------------------------
	// Closing with the pointer. A click is resolved while the panel is being
	// built, which is *after* the keyboard pass — so the dialog can finish at
	// a different point in the frame than Escape does, and the result has to
	// come back on that frame all the same.
	// ---------------------------------------------------------------------
	kit.pick_result_free(r.last)
	r.last = {}
	r.done = false
	kit.pick_begin(&r.pick, .Open_File, {dir = root})
	steps(r, 4)
	check(kit.pick_select_name(&r.pick, "alpha.txt"), "put the cursor on a file")
	steps(r, 2)
	// Row 0 of the visible list, which is where the cursor was scrolled to.
	lr := p.rect_of(&r.off.ctx, r.pick.list_id)
	row_y := lr.y + f32(r.pick.sel) * kit.PICK_ROW_H - p.scroll_of(&r.off.ctx, r.pick.list_id).y
	click(r, lr.x + 120, row_y + kit.PICK_ROW_H / 2)
	check(r.done, "a second click on the selected row finished the dialog")
	check(r.last.ok, "with a result")
	eq(r.last.path, alpha, "naming the file that was clicked")

	// And the scrim, which cancels.
	kit.pick_result_free(r.last)
	r.last = {}
	r.done = false
	kit.pick_begin(&r.pick, .Open_File, {dir = root})
	steps(r, 4)
	click(r, 20, 20) // outside the panel, on the scrim
	check(r.done, "clicking outside the panel finished the dialog")
	check(!r.last.ok, "with no choice")
	check(!kit.pick_active(&r.pick), "and it is closed")

	// Screenshots of the states worth looking at with human eyes. The
	// assertions above decide whether the test passes; these are for the
	// author, and for whoever reviews a change to the drawing.
	shot :: proc(r: ^Rig, name: string) {
		path := fmt.tprintf("/tmp/pickdemo-%s.png", name)
		if p.offscreen_write_png(r.off, path) {
			fmt.printf("  shot: %s\n", path)
		}
	}

	r.done = false
	kit.pick_begin(&r.pick, .Save_File, {dir = root, name = "untitled.png", filters = sfilters[:]})
	steps(r, 4)
	shot(r, "save")
	key(r, p.KEY_RETURN) // untitled.png does not exist here, so this finishes
	if r.done {
		kit.pick_result_free(r.last)
		r.last = {}
		r.done = false
	}

	kit.pick_begin(&r.pick, .Save_File, {dir = stage, name = "taken.png", filters = sfilters[:]})
	steps(r, 3)
	key(r, p.KEY_RETURN)
	steps(r, 2)
	check(r.pick.cf_open, "the confirmation is up for the screenshot")
	shot(r, "overwrite")
	key(r, p.KEY_ESCAPE)
	key(r, p.KEY_ESCAPE)
	r.done = false

	kit.pick_begin(&r.pick, .Open_File, {dir = many})
	steps(r, 4)
	key(r, p.KEY_PAGE_DOWN)
	key(r, p.KEY_PAGE_DOWN)
	steps(r, 4)
	bar_off := p.scroll_of(&r.off.ctx, r.pick.list_id).y
	check(bar_off > 0, "the five-thousand-entry list is scrolled for the screenshot")
	shot(r, "many")
	key(r, p.KEY_ESCAPE)
	r.done = false

	kit.pick_begin(&r.pick, .Open_Files, {dir = root, filters = filters[:]})
	steps(r, 3)
	kit.pick_select_name(&r.pick, "alpha.txt")
	step(r)
	key(r, p.KEY_SPACE)
	kit.pick_select_name(&r.pick, "notes.md")
	step(r)
	key(r, p.KEY_SPACE)
	kit.pick_select_name(&r.pick, LONG_NAME)
	steps(r, 3)
	shot(r, "multi")
	key(r, p.KEY_ESCAPE)
	r.done = false

	kit.pick_begin(&r.pick, .Open_Folder, {dir = root})
	steps(r, 3)
	key(r, 'n', {.Ctrl})
	steps(r, 3)
	check(r.pick.nf_open, "the New Folder prompt is up for the screenshot")
	shot(r, "newfolder")
	key(r, p.KEY_ESCAPE)
	key(r, p.KEY_ESCAPE)
	if r.done {
		kit.pick_result_free(r.last)
		r.last = {}
		r.done = false
	}
}
