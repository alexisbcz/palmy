package main

// The core (fs.odin) with no window, the browser's actions over it, and the
// command line over both. Everything runs in a scratch tree under /tmp with
// $XDG_DATA_HOME and $HOME pointed into it, so neither the user's files nor
// their trash are ever read or touched.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
write :: proc(path, text: string) {
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
read :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

// scratch makes a fresh tree:
//
//	root/
//	  docs/  a.txt (5 B)  big.md (2000 B)  photo.png  .secret
//	  docs/deep/  inner.png  deeper/core.odin
//	  empty/
scratch :: proc(root: string) {
	_ = os.remove_all(root)
	_ = os.make_directory_all(fmt.tprintf("%s/docs/deep/deeper", root))
	_ = os.make_directory_all(fmt.tprintf("%s/empty", root))
	write(fmt.tprintf("%s/docs/a.txt", root), "hello")
	write(fmt.tprintf("%s/docs/big.md", root), strings.repeat("x", 2000, context.temp_allocator))
	write(fmt.tprintf("%s/docs/photo.png", root), "not really a png")
	write(fmt.tprintf("%s/docs/.secret", root), "s")
	write(fmt.tprintf("%s/docs/deep/inner.png", root), "png")
	write(fmt.tprintf("%s/docs/deep/deeper/core.odin", root), "package x")
}

selftest_core :: proc() {
	root := fmt.tprintf("/tmp/files-selftest-core-%d", os.get_pid())
	scratch(root)
	defer os.remove_all(root)
	trash := fmt.tprintf("%s/Trash", root)
	_ = os.set_env("XDG_DATA_HOME", root)
	check(trash_dir() == trash, "trash: $XDG_DATA_HOME/Trash is the default (%q)", trash_dir())
	check(trash_dir("/x/y/") == "/x/y", "trash: --trash-dir wins")

	// --- kinds -----------------------------------------------------------
	{
		_, l := kind_of("shot.PNG", false)
		check(l == "PNG image", "kind: shot.PNG is a PNG image (%q)", l)
		_, l = kind_of("Makefile", false)
		check(l == "Document", "kind: no extension is a Document")
		_, l = kind_of("README.md", false)
		check(l == "Markdown text", "kind: .md is Markdown text")
		c, _ := kind_of("x", true)
		check(c == .Folder, "kind: a folder")
		_, _, gk := classify("a.odin", false, false)
		_, ck := kind_of("a.odin", false)
		check(gk == ck, "kind: the window's Kind column is the core's label (%q)", gk)
	}

	// --- listing, sorting, filtering ---------------------------------------
	docs := fmt.tprintf("%s/docs", root)
	{
		entries, err := fs_list(docs, context.temp_allocator)
		check(err == "" && len(entries) == 5, "list: five entries in docs (%d, %q)", len(entries), err)
		fs_sort(entries[:], .Name, false)
		check(entries[0].name == "deep" && entries[0].is_dir, "list: the folder sorts first (%q)", entries[0].name)
		fs_sort(entries[:], .Size, false)
		check(entries[0].is_dir && entries[1].name == "big.md", "sort by size: folders first, then the biggest (%q)", entries[1].name)
		fs_sort(entries[:], .Name, true)
		check(entries[0].name == "deep" && entries[1].name == "photo.png", "sort reversed: folders still first, then the names backwards (%q)", entries[1].name)
		shown := 0
		for e in entries {
			if fs_shown(e, "", false) {shown += 1}
		}
		check(shown == 4, "filter: .secret is hidden unless asked (%d)", shown)
		check(fs_shown(entries[0], "", true), "filter: shown with hidden")
		hits := 0
		for e in entries {
			if fs_shown(e, "PHO", false) || fs_shown(e, "pho", false) {hits += 1}
		}
		check(hits == 1, "filter: folded substring")

		_, l_err := fs_list(fmt.tprintf("%s/nope", root), context.temp_allocator)
		check(l_err != "", "list: a missing folder says so")
	}

	// The window and the core agree on order: the browser's State, loaded the
	// way the window loads it, against the core's own listing.
	{
		st := new(State)
		st.sort = .Size
		load_dir(st, docs)
		entries, _ := fs_list(docs, context.temp_allocator)
		fs_sort(entries[:], .Size, false)
		want := make([dynamic]string, context.temp_allocator)
		for e in entries {
			if fs_shown(e, "", false) {append(&want, e.name)}
		}
		same := len(want) == len(st.vis)
		for v, i in st.vis {
			if same && st.entries[v].name != want[i] {same = false}
		}
		check(same, "the window's rows are the core's listing, in the same order")
		for e in st.entries {entry_free(e)}
	}

	// --- stat and find -----------------------------------------------------
	{
		e, ok := fs_stat(fmt.tprintf("%s/a.txt", docs))
		check(ok && e.size == 5 && e.kind == "Plain text", "stat: a.txt, 5 bytes, Plain text")
		fs_entry_free(e)
		check(fs_mode(docs)[0] == 'd', "stat: a folder's mode starts with d (%q)", fs_mode(docs))
		b, f, d := fs_tree_size(docs)
		check(f == 6 && d == 2 && b == 5 + 2000 + 16 + 1 + 3 + 9, "stat: a folder totals what is under it (%d files, %d dirs, %d B)", f, d, b)
		_, gone := fs_stat(fmt.tprintf("%s/nope", root))
		check(!gone, "stat: a missing path")
	}
	{
		found, trunc := fs_find(root, {pattern = "*.png"}, context.temp_allocator)
		check(len(found) == 2 && !trunc, "find: a glob, at any depth (%d)", len(found))
		check(len(found) == 2 && found[0].name == "photo.png", "find: shallowest first")
		found, _ = fs_find(root, {pattern = "*.png", max_depth = 2}, context.temp_allocator)
		check(len(found) == 1, "find: --depth stops the walk (%d)", len(found))
		found, _ = fs_find(root, {pattern = "CORE"}, context.temp_allocator)
		check(len(found) == 1 && found[0].name == "core.odin", "find: a folded substring")
		found, _ = fs_find(root, {kind = "image"}, context.temp_allocator)
		check(len(found) == 2, "find: by kind (%d)", len(found))
		found, _ = fs_find(root, {kind = "dir"}, context.temp_allocator)
		check(len(found) == 4, "find: folders (%d)", len(found))
		found, trunc = fs_find(root, {limit = 2}, context.temp_allocator)
		check(len(found) == 2 && trunc, "find: --limit truncates and says so")
		found, _ = fs_find(root, {pattern = "secret"}, context.temp_allocator)
		check(len(found) == 0, "find: hidden names stay hidden")
		found, _ = fs_find(root, {pattern = "secret", hidden = true}, context.temp_allocator)
		check(len(found) == 1, "find: unless asked")
		found, _ = fs_find(root, {larger_than = 100}, context.temp_allocator)
		check(len(found) == 1 && found[0].name == "big.md", "find: --larger")
	}

	// --- copy, move, rename, mkdir, duplicate -------------------------------
	{
		a := fmt.tprintf("%s/a.txt", docs)
		empty := fmt.tprintf("%s/empty", root)
		made, fail, _ := fs_copy(a, empty, true)
		check(fail == .None && made == fmt.tprintf("%s/a.txt", empty) && !os.exists(made), "copy --dry-run: names the result and writes nothing")
		made, fail, _ = fs_copy(a, empty)
		check(fail == .None && read(made) == "hello", "copy: into a folder, same name, same bytes")
		_, fail, _ = fs_copy(a, empty)
		check(fail == .Exists, "copy: never overwrites")
		_, fail, _ = fs_copy(docs, fmt.tprintf("%s/deep/again", docs))
		check(fail == .Refused, "copy: not a folder into itself")
		made, fail, _ = fs_copy(docs, fmt.tprintf("%s/docs2", root))
		check(fail == .None && read(fmt.tprintf("%s/deep/deeper/core.odin", made)) == "package x", "copy: a folder, recursively")
		check(read(fmt.tprintf("%s/.secret", made)) == "s", "copy: hidden files go too")
		_, fail, _ = fs_copy(fmt.tprintf("%s/nope", root), empty)
		check(fail == .Not_Found, "copy: a missing source")

		d2 := fmt.tprintf("%s/docs2", root)
		made, fail, _ = fs_move(fmt.tprintf("%s/a.txt", d2), fmt.tprintf("%s/b.txt", d2), true)
		check(fail == .None && os.exists(fmt.tprintf("%s/a.txt", d2)), "move --dry-run: nothing moves")
		made, fail, _ = fs_move(fmt.tprintf("%s/a.txt", d2), fmt.tprintf("%s/b.txt", d2))
		check(fail == .None && os.exists(made) && !os.exists(fmt.tprintf("%s/a.txt", d2)), "move: to a new path")
		_, fail, _ = fs_move(made, d2)
		check(fail == .Refused, "move: already here")
		_, fail, _ = fs_move(d2, fmt.tprintf("%s/deep", d2))
		check(fail == .Refused, "move: not a folder into itself")
		_, fail, _ = fs_move(fmt.tprintf("%s/big.md", d2), docs)
		check(fail == .Exists, "move: never overwrites")
		made, fail, _ = fs_move(fmt.tprintf("%s/big.md", d2), empty)
		check(fail == .None && made == fmt.tprintf("%s/big.md", empty), "move: into a folder")

		made, fail, _ = fs_rename(fmt.tprintf("%s/b.txt", d2), "c.txt")
		check(fail == .None && os.exists(made), "rename")
		_, fail, _ = fs_rename(made, "x/y")
		check(fail == .Refused, "rename: no / in a name")
		_, fail, _ = fs_rename(made, "  ")
		check(fail == .Refused, "rename: not empty")
		_, fail, _ = fs_rename(made, "photo.png")
		check(fail == .Exists, "rename: not onto another file")

		_, fail, _ = fs_mkdir(fmt.tprintf("%s/m/n", root))
		check(fail == .Not_Found, "mkdir: a missing parent without --parents")
		made, fail, _ = fs_mkdir(fmt.tprintf("%s/m/n", root), true)
		check(fail == .None && is_dir_path(made), "mkdir --parents")
		_, fail, _ = fs_mkdir(made, true)
		check(fail == .None, "mkdir --parents: already there is fine (idempotent)")
		_, fail, _ = fs_mkdir(made)
		check(fail == .Exists, "mkdir: already there is not, without it")

		made, fail, _ = fs_duplicate(fmt.tprintf("%s/c.txt", d2))
		check(fail == .None && base_of(made) == "c copy.txt", "duplicate: \"c copy.txt\" (%q)", base_of(made))
		made, fail, _ = fs_duplicate(fmt.tprintf("%s/c.txt", d2))
		check(fail == .None && base_of(made) == "c copy 2.txt", "duplicate: then \"c copy 2.txt\" (%q)", base_of(made))
		made, _, _ = fs_new_folder(d2)
		check(base_of(made) == "untitled folder", "new folder: \"untitled folder\"")
		made, _, _ = fs_new_folder(d2)
		check(base_of(made) == "untitled folder 2", "new folder: then \"untitled folder 2\" (%q)", base_of(made))

		_, fail, _ = fs_delete(fmt.tprintf("%s/deep", d2))
		check(fail == .Refused && os.exists(fmt.tprintf("%s/deep", d2)), "delete: a folder with things in it needs recursive")
		_, fail, _ = fs_delete(fmt.tprintf("%s/deep", d2), true, true)
		check(fail == .None && os.exists(fmt.tprintf("%s/deep", d2)), "delete --dry-run: still there")
		_, fail, _ = fs_delete(fmt.tprintf("%s/deep", d2), true)
		check(fail == .None && !os.exists(fmt.tprintf("%s/deep", d2)), "delete --recursive")
		_, fail, _ = fs_delete("/")
		check(fail == .Refused, "delete: never the root")
	}

	// --- the trash -------------------------------------------------------------
	{
		check(url_unescape(url_escape("/a b/ü%.txt")) == "/a b/ü%.txt", "trash: Path= escaping round-trips")
		check(url_escape("/a b") == "/a%20b", "trash: a space is %%20")

		d2 := fmt.tprintf("%s/docs2", root)
		spaced := fmt.tprintf("%s/my notes.txt", d2)
		write(spaced, "one")
		name, fail, _ := fs_trash(spaced, trash, 0, true)
		check(fail == .None && name == "my notes.txt" && os.exists(spaced) && !os.exists(trash), "trash --dry-run: names it, touches nothing")
		name, fail, _ = fs_trash(spaced, trash)
		check(fail == .None && !os.exists(spaced), "trash: gone from where it was")
		check(read(fmt.tprintf("%s/files/my notes.txt", trash)) == "one", "trash: kept under files/")
		info := read(fmt.tprintf("%s/info/my notes.txt.trashinfo", trash))
		check(strings.has_prefix(info, "[Trash Info]\n"), "trash: a .trashinfo")
		check(strings.contains(info, fmt.tprintf("Path=%s/my%%20notes.txt", d2)), "trash: Path= is the escaped original (%q)", info)
		check(strings.contains(info, "DeletionDate=20"), "trash: DeletionDate=")

		write(spaced, "two")
		name, fail, _ = fs_trash(spaced, trash)
		check(fail == .None && name == "my notes.2.txt", "trash: the same name twice is kept apart (%q)", name)

		list := fs_trash_list(trash)
		check(len(list) == 2, "trashed: two (%d)", len(list))
		check(len(list) == 2 && list[0].original == spaced, "trashed: the original path, unescaped")

		_, fail, _ = fs_trash(trash, trash)
		check(fail == .Refused, "trash: not the trash itself")

		write(spaced, "three")
		_, fail, _ = fs_restore("my notes.txt", trash)
		check(fail == .Exists && read(spaced) == "three", "restore: never over a file back in its place")
		made, rfail, _ := fs_restore("my notes.txt", trash, fmt.tprintf("%s/restored.txt", d2))
		check(rfail == .None && read(made) == "one", "restore --to: somewhere else")
		_ = os.remove(spaced)
		made, rfail, _ = fs_restore(spaced, trash)
		check(rfail == .None && read(spaced) == "two", "restore: by the path it had")
		check(!os.exists(fmt.tprintf("%s/info/my notes.2.txt.trashinfo", trash)), "restore: its .trashinfo goes too")
		_, rfail, _ = fs_restore("nothing-like-it", trash)
		check(rfail == .Not_Found, "restore: not found")

		_, _, _ = fs_trash(fmt.tprintf("%s/c.txt", d2), trash)
		_, _, _ = fs_trash(fmt.tprintf("%s/untitled folder", d2), trash)
		check(len(fs_trash_list(trash)) == 2, "trashed: a file and a folder")
		removed, efail, _ := fs_trash_empty(trash, "", true)
		check(efail == .None && len(removed) == 2 && len(fs_trash_list(trash)) == 2, "empty --dry-run: would remove two, removes none")
		removed, efail, _ = fs_trash_empty(trash, "c.txt")
		check(efail == .None && len(removed) == 1 && len(fs_trash_list(trash)) == 1, "empty <item>: only that one")
		removed, efail, _ = fs_trash_empty(trash)
		check(efail == .None && len(removed) == 1 && len(fs_trash_list(trash)) == 0, "empty: the rest")
	}

	// --- the browser's actions go through the same core ----------------------
	{
		st := new(State)
		st.cwd = strings.clone(docs)
		load_dir(st, docs)
		select_name(st, "a.txt")
		act_duplicate(st)
		check(os.exists(fmt.tprintf("%s/a copy.txt", docs)), "window Duplicate: \"a copy.txt\" (%q)", st.toast)
		e, _ := selected(st)
		check(e.name == "a copy.txt", "and the selection is on the copy")
		act_trash(st)
		check(!os.exists(fmt.tprintf("%s/a copy.txt", docs)), "window Move to Trash: gone (%q)", st.toast)
		list := fs_trash_list()
		check(len(list) == 1 && list[0].original == fmt.tprintf("%s/a copy.txt", docs), "and it is in the same trash `files trashed` reads")
		act_new_folder(st)
		check(st.ask == .New_Folder && is_dir_path(fmt.tprintf("%s/untitled folder", docs)), "window New Folder: made, and asks for a name")
		clear(&st.ask_text)
		append(&st.ask_text, ..transmute([]u8)string("Invoices"))
		ask_commit(st)
		check(is_dir_path(fmt.tprintf("%s/Invoices", docs)) && !os.exists(fmt.tprintf("%s/untitled folder", docs)), "and the name typed renames it (%q)", st.toast)
		select_name(st, "big.md")
		act_rename(st)
		clear(&st.ask_text)
		append(&st.ask_text, ..transmute([]u8)string("photo.png"))
		ask_commit(st)
		check(os.exists(fmt.tprintf("%s/big.md", docs)) && strings.contains(st.toast, "already exists"), "window Rename: refuses a taken name, as the command does (%q)", st.toast)
		for e in st.entries {entry_free(e)}
	}
}

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

// run runs this binary again with the display variables cleared, so a command
// that fell through to the window by mistake fails rather than opens one.
@(private = "file")
run :: proc(env: string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	strings.write_string(&line, env)
	strings.write_string(&line, fmt.tprintf(" %q", self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
valid :: proc(out: string, fields: []kit.Field) -> bool {
	return len(kit.cli_validate_output(out, fields, context.temp_allocator)) == 0
}

selftest_cli :: proc() {
	root := fmt.tprintf("/tmp/files-selftest-cli-%d", os.get_pid())
	scratch(root)
	defer os.remove_all(root)
	env := fmt.tprintf("PALM_AUDIT=%s/audit.jsonl XDG_DATA_HOME=%s HOME=%s", root, root, root)
	docs := fmt.tprintf("%s/docs", root)
	trash := fmt.tprintf("%s/Trash", root)

	// --- the declaration -------------------------------------------------
	sf := surface()
	check(sf.noun == "files" && sf.selftest != nil && sf.gui && sf.takes_path, "cli: the surface is files, with a window and a self-test")
	for cmd in sf.commands {
		check(cmd.run != nil && cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, "cli: %s is implemented, summarised, declares its output and ships an example", cmd.verb)
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {append(&args, w)}
			append(&args, "--parse-only")
			_, code := run(env, ..args[:])
			check(words[0] == "files" && code == 0, "cli: the example %q parses", ex)
		}
	}
	{
		out, code := run(env, "--schema")
		_, perr := json.parse(transmute([]u8)out, .JSON, true, context.temp_allocator)
		check(code == 0 && perr == nil, "cli: --schema is JSON")
	}

	// --- reads match their schema and agree with the core ------------------------
	{
		out, code := run(env, "list", docs, "--sort", "size", "--json")
		check(code == 0 && valid(out, LIST_FIELDS), "cli: list --json matches its schema")
		entries, _ := fs_list(docs, context.temp_allocator)
		fs_sort(entries[:], .Size, false)
		order := make([dynamic]string, context.temp_allocator)
		for e in entries {
			if fs_shown(e, "", false) {append(&order, fmt.tprintf("%q", e.path))}
		}
		at := 0
		in_order := true
		for q in order {
			i := strings.index(out[at:], q)
			if i < 0 {in_order = false; break}
			at += i + len(q)
		}
		check(in_order, "cli: list prints the core's order")
		check(strings.contains(out, `"count": 4`) && strings.contains(out, `"total": 5`), "cli: list hides .secret and counts it")
		out, _ = run(env, "list", docs, "--all", "--filter", "SEC", "--json")
		check(strings.contains(out, `"count": 1`), "cli: list --all --filter")
		_, code = run(env, "list", fmt.tprintf("%s/nope", root), "--json")
		check(code == kit.EXIT_NOT_FOUND, "cli: list of a missing folder exits 3")
	}
	{
		out, code := run(env, "stat", fmt.tprintf("%s/a.txt", docs), "--json")
		check(code == 0 && valid(out, STAT_FIELDS) && strings.contains(out, `"size": 5`), "cli: stat --json")
		out, code = run(env, "find", root, "*.png", "--json")
		check(code == 0 && valid(out, FIND_FIELDS) && strings.contains(out, `"count": 2`), "cli: find --json")
		_, code = run(env, "find", root, "[", "--json")
		check(code == kit.EXIT_USAGE, "cli: a broken glob is a usage error (%d)", code)
	}

	// --- changes, dry runs, refusals ------------------------------------------
	{
		a := fmt.tprintf("%s/a.txt", docs)
		out, code := run(env, "move", a, fmt.tprintf("%s/empty", root), "--dry-run", "--json")
		check(code == 0 && os.exists(a) && strings.contains(out, `"dry_run": true`), "cli: move --dry-run moves nothing")
		out, code = run(env, "copy", a, fmt.tprintf("%s/empty", root), "--json")
		check(code == 0 && valid(out, MOVED_FIELDS) && os.exists(fmt.tprintf("%s/empty/a.txt", root)), "cli: copy")
		out, code = run(env, "copy", a, fmt.tprintf("%s/empty", root), "--json")
		check(code == kit.EXIT_FAILED && strings.contains(out, `"reason": "exists"`), "cli: copy refuses to overwrite, with a reason")
		_, code = run(env, "rename", a, "b.txt", "--json")
		check(code == 0 && os.exists(fmt.tprintf("%s/b.txt", docs)), "cli: rename")
		_, code = run(env, "mkdir", fmt.tprintf("%s/x/y", root), "-p", "--json")
		check(code == 0 && is_dir_path(fmt.tprintf("%s/x/y", root)), "cli: mkdir -p")
		_, code = run(env, "rename", fmt.tprintf("%s/nope", root), "z", "--json")
		check(code == kit.EXIT_NOT_FOUND, "cli: a missing source exits 3")

		out, code = run(env, "trash", fmt.tprintf("%s/b.txt", docs), "--json")
		check(code == 0 && valid(out, TRASH_FIELDS) && os.exists(fmt.tprintf("%s/files/b.txt", trash)), "cli: trash lands in $XDG_DATA_HOME/Trash")
		out, code = run(env, "trashed", "--json")
		check(code == 0 && valid(out, TRASHED_FIELDS) && strings.contains(out, `"count": 1`), "cli: trashed")
		list := fs_trash_list(trash)
		check(len(list) == 1 && list[0].original == fmt.tprintf("%s/b.txt", docs), "cli: and the core reads what the command wrote")
		_, code = run(env, "restore", "b.txt", "--json")
		check(code == 0 && os.exists(fmt.tprintf("%s/b.txt", docs)), "cli: restore")

		victim := fmt.tprintf("%s/photo.png", docs)
		out, code = run(env, "delete", victim, "--json")
		check(code == kit.EXIT_NEEDS_YES && os.exists(victim) && strings.contains(out, `"error": "needs --yes"`), "cli: delete without --yes exits 4 and deletes nothing")
		_, code = run(env, "delete", victim, "--yes", "--json")
		check(code == 0 && !os.exists(victim), "cli: delete --yes")

		_, _ = run(env, "trash", fmt.tprintf("%s/big.md", docs), "--json")
		_, code = run(env, "empty-trash", "--json")
		check(code == kit.EXIT_NEEDS_YES && len(fs_trash_list(trash)) == 1, "cli: empty-trash without --yes exits 4")
		out, code = run(env, "empty-trash", "--yes", "--json")
		check(code == 0 && valid(out, EMPTY_FIELDS) && len(fs_trash_list(trash)) == 0, "cli: empty-trash --yes")

		out, code = run(env, "open", fmt.tprintf("%s/b.txt", docs), "--dry-run", "--json")
		check(code == 0 && strings.contains(out, `"launched": false`), "cli: open --dry-run launches nothing")

		selftest_open_for_real(env, root, docs)

		audit := read(fmt.tprintf("%s/audit.jsonl", root))
		check(strings.contains(audit, `"verb": "trash"`) && !strings.contains(audit, `"verb": "list"`), "cli: changes are audited, reads are not")
	}

	// --- the old command line still works -----------------------------------------
	{
		_, code := run(env, "--shots", fmt.tprintf("%s/shots", root), "--parse-only")
		check(code == 0, "cli: --shots <dir> is still accepted")
		_, code = run(env, "no-such-verb")
		check(code == kit.EXIT_USAGE, "cli: an unknown word is a usage error, not a window (%d)", code)
	}
}

// selftest_open_for_real runs `files open` without --dry-run, against a
// stand-in xdg-open first on PATH that writes the arguments it was given, one
// per line, to a sentinel and exits. Nothing real is opened: the stand-in is
// the only xdg-open the child can find. This is what --dry-run could never
// show: that the path reaches the opener as exactly one argument, whatever is
// in it, and that a missing opener is reported rather than ignored.
//
// These children are started from an argv, not through `sh -c` as `run`
// does: a file name with `$(...)` in it would otherwise be expanded by the
// test's own shell, and the test would be measuring itself.
@(private = "file")
selftest_open_for_real :: proc(env, root, docs: string) {
	bin := fmt.tprintf("%s/opener-bin", root)
	_ = os.make_directory_all(bin)
	sent := fmt.tprintf("%s/opener-args", root)
	script := fmt.tprintf(
		"#!/bin/sh\n: > '%s.tmp'\nfor a in \"$@\"; do printf '%%s\\n' \"$a\" >> '%s.tmp'; done\nmv '%s.tmp' '%s'\nexit ${OPENER_EXIT:-0}\n",
		sent,
		sent,
		sent,
		sent,
	)
	_ = os.write_entire_file(fmt.tprintf("%s/xdg-open", bin), transmute([]u8)script, os.Permissions_All)
	with_opener := fmt.tprintf("PATH=%s:%s", bin, os.get_env("PATH", context.temp_allocator))

	exec :: proc(env, extra: string, dir: string, args: ..string) -> (out: string, code: int) {
		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, "env", "WAYLAND_DISPLAY=", "DISPLAY=")
		for kv in strings.fields(env, context.temp_allocator) {
			append(&argv, kv)
		}
		for kv in strings.fields(extra, context.temp_allocator) {
			append(&argv, kv)
		}
		append(&argv, self_exe())
		append(&argv, ..args)
		state, sout, _, err := os.process_exec({command = argv[:], working_dir = dir}, context.temp_allocator)
		if err != nil {
			return "", -1
		}
		return string(sout), state.exit_code
	}

	// The opener is started detached, as the window's Enter does, so the
	// sentinel may land a moment after the command returns.
	await :: proc(sent: string) -> (args: []string, ok: bool) {
		for _ in 0 ..< 100 {
			if data, err := os.read_entire_file(sent, context.temp_allocator); err == nil {
				return strings.split_lines(strings.trim_suffix(string(data), "\n"), context.temp_allocator), true
			}
			time.sleep(20 * time.Millisecond)
		}
		return nil, false
	}

	for name in ([?]string{"plain.txt", "a name with spaces — ü.txt", "--help", "-n", "semi;colon $(touch pwned).txt"}) {
		target := fmt.tprintf("%s/%s", docs, name)
		_ = os.write_entire_file(target, transmute([]u8)string("x"))
		os.remove(sent)
		out, code := exec(env, with_opener, "", "open", target, "--json")
		check(code == 0 && strings.contains(out, `"launched": true`), "cli: open %q starts the opener and says so (%d)", name, code)
		check(valid(out, OPEN_FIELDS), "cli: open --json matches its schema")
		args, got := await(sent)
		check(got, "cli: open %q reached the opener on PATH", name)
		check(len(args) == 1 && args[0] == target, "cli: open %q handed it exactly one argument, the absolute path (got %v)", name, args)
		os.remove(target)
	}
	check(!os.exists(fmt.tprintf("%s/pwned", docs)) && !os.exists("pwned"), "cli: a name with shell syntax in it ran nothing")

	rel := fmt.tprintf("%s/rel.md", docs)
	_ = os.write_entire_file(rel, transmute([]u8)string("# rel"))
	defer os.remove(rel)

	// A relative path is made absolute against the caller's directory.
	{
		os.remove(sent)
		out, code := exec(env, with_opener, docs, "open", "rel.md", "--json")
		args, got := await(sent)
		check(code == 0 && strings.contains(out, `"launched": true`), "cli: open of a relative path (%d)", code)
		check(got && len(args) == 1 && args[0] == rel, "cli: reaches the opener as an absolute path (got %v)", args)
	}

	// Nothing to open: the opener is never started.
	{
		os.remove(sent)
		_, code := exec(env, with_opener, "", "open", fmt.tprintf("%s/not-there.pdf", docs), "--json")
		check(code == kit.EXIT_NOT_FOUND, "cli: open of a missing file exits 3 (%d)", code)
		time.sleep(150 * time.Millisecond)
		check(!os.exists(sent), "cli: and the opener was never started")
	}

	// No opener at all: unavailable, in the documented form, not a silent 0.
	{
		empty := fmt.tprintf("%s/no-opener-bin", root)
		_ = os.make_directory_all(empty)
		out, code := exec(env, fmt.tprintf("PATH=%s", empty), "", "open", rel, "--json")
		check(code == kit.EXIT_UNAVAILABLE && strings.contains(out, `"error": "unavailable"`), "cli: with no xdg-open, open exits 6 (%d)", code)
	}

	// The opener is fire-and-forget, as Enter is in the window: `launched`
	// means it started, not that a handler took the file. xdg-open can block
	// for as long as the application it runs stays open, so waiting on its
	// status is not an option; this pins that meaning down.
	{
		os.remove(sent)
		out, code := exec(env, fmt.tprintf("%s OPENER_EXIT=3", with_opener), "", "open", rel, "--json")
		_, got := await(sent)
		check(got && code == 0 && strings.contains(out, `"launched": true`), "cli: launched means started, even when the opener then fails")
	}
	audit := read(fmt.tprintf("%s/audit.jsonl", root))
	check(strings.contains(audit, `"verb": "open"`), "cli: a real open is audited")
}
