package main

// Headless self-test: `archive --selftest`.
//
// The interesting part is the last section. It builds a deliberately hostile
// archive in a scratch directory — bsdtar's `-s` rewrites a member's stored
// name, which is how you get `../../escape.txt` into a zip — then runs the real
// listing, staging and extraction code against it and checks that nothing was
// written outside the destination. That is the one property this application
// has to get right, and it is checked here rather than asserted in prose.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

@(private = "file")
fails: int
@(private = "file")
checks: int

@(private = "file")
ok :: proc(cond: bool, format: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.printf("FAIL  ")
		fmt.printfln(format, ..args)
	}
}

@(private = "file")
frame :: proc(o: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(o)
	handle_keys(ui, nil, st)
	rebuild_rows(st)
	build(ui, st)
	p.offscreen_end(o)
}

// settle blocks until the worker thread has finished, the way the frame loop
// does by drawing in the meantime. A busy spin would race the thread.
@(private = "file")
settle :: proc() -> bool {
	for _ in 0 ..< 6000 {
		if !job_busy() {
			return true
		}
		if _, got := job_collect(); got {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// wait_for_job pumps frames until the worker thread is finished, the way the
// real loop does — so `collect` runs and the UI reaches its Done state.
@(private = "file")
wait_for_job :: proc(o: ^p.Offscreen, st: ^St) {
	for _ in 0 ..< 6000 {
		collect(st, nil)
		frame(o, st)
		if !job_busy() {
			collect(st, nil)
			frame(o, st)
			return
		}
		time.sleep(5 * time.Millisecond)
	}
}

SCRATCH :: "/tmp/palmy-archive-selftest"

selftest :: proc() -> int {
	// -------------------------------------------------------------------
	fmt.println("-- the name check, which is the whole safety story")
	{
		for n in ([?]string {
			"project/README.md",
			"a/b/c/d.txt",
			"./x.txt",
			"a/./b.txt",
			"a/b/../c.txt", // dips down and back up, never above the root
			"weird name with spaces.md",
			"ünïcødé.txt",
		}) {
			ok(check_name(n, false) == "", "%q should be accepted, refused with %q", n, check_name(n, false))
		}
		for c in ([?]struct {
			name: string,
			why:  string,
		} {
			{"../escape.txt", "“..” escapes"},
			{"../../.ssh/authorized_keys", "“..” escapes"},
			{"a/../../b.txt", "“..” escapes"},
			{"/etc/cron.d/backdoor", "absolute"},
			{"/", "absolute"},
			{"C:/Windows/system32/evil.dll", "drive letter"},
			{"a\\b.txt", "backslash"},
			{"", "empty"},
		}) {
			why := check_name(c.name, false)
			ok(why != "", "%q must be refused (expected %s)", c.name, c.why)
		}
		ok(check_name("docs/link", true) != "", "a symlink entry must be refused whatever its name is")
		ok(
			strings.contains(check_name("docs/link", true), "link"),
			"the refusal for a symlink should say so: %q",
			check_name("docs/link", true),
		)
	}

	fmt.println("-- parsing bsdtar")
	{
		perms, size, date, good := parse_verbose(
			"-rw-r--r--  0 alex   alex    54038 Oct  4 12:17 project/src/data.txt",
		)
		ok(good, "a normal verbose line should parse")
		ok(perms == "-rw-r--r--", "perms %q", perms)
		ok(size == 54038, "size %d, expected 54038", size)
		ok(date == "Oct 4 12:17", "date %q, expected “Oct 4 12:17”", date)

		perms2, _, date2, good2 := parse_verbose(
			"drwxr-xr-x  0 1000   1000        0 Oct  4  2024 project/",
		)
		ok(good2 && perms2[0] == 'd', "a directory line should parse as a directory")
		ok(date2 == "Oct 4 2024", "an old entry shows a year: %q", date2)

		perms3, _, _, good3 := parse_verbose(
			"lrwxrwxrwx  0 0      0           0 Jan  1  1980 docs/link -> /",
		)
		ok(good3 && perms3[0] == 'l', "a symlink line should parse as a link")

		_, _, _, good4 := parse_verbose("not a listing line")
		ok(!good4, "a nonsense line should not parse")
	}

	fmt.println("-- paths, formats and sizes")
	{
		par, base := split_parent("project/src/main.odin")
		ok(par == "project/src/" && base == "main.odin", "split_parent gave %q + %q", par, base)
		par2, base2 := split_parent("project/src/")
		ok(par2 == "project/" && base2 == "src", "a trailing slash should not confuse split_parent: %q + %q", par2, base2)
		par3, base3 := split_parent("top.txt")
		ok(par3 == "" && base3 == "top.txt", "a bare name has no parent: %q + %q", par3, base3)

		for c in ([?]struct {
			path, want: string,
		} {
			{"/tmp/sample.tar.gz", "sample"},
			{"/tmp/sample.zip", "sample"},
			{"/x/y/linux-6.9.tar.xz", "linux-6.9"},
			{"noext", "noext"},
		}) {
			got := strip_archive_ext(c.path, context.temp_allocator)
			ok(got == c.want, "strip_archive_ext(%q) = %q, expected %q", c.path, got, c.want)
		}

		ok(archive_label("/a/b.zip") == "ZIP", "zip label")
		ok(archive_label("/a/b.tar.gz") == "TAR.GZ", "tar.gz label")
		ok(archive_label("/a/b.tar.zst") == "TAR.ZST", "tar.zst label")
		ok(archive_label("/a/b.7z") == "7Z", "7z label")
		ok(is_archive_path("/a/b.TGZ"), "the extension check should ignore case")
		ok(!is_archive_path("/a/b.odin"), "a source file is not an archive")

		ok(human(512) == "512 B", "512 B, got %s", human(512))
		ok(human(1536) == "1.5 KB", "1.5 KB, got %s", human(1536))
		ok(strings.has_suffix(human(3 * 1024 * 1024), "MB"), "megabytes, got %s", human(3 * 1024 * 1024))
	}

	if !kit.has_tool("bsdtar") {
		fmt.println("\nbsdtar is not installed; skipping the end-to-end checks")
		fmt.printfln("\n%s  %d checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
		return fails
	}

	// -------------------------------------------------------------------
	fmt.println("-- a hostile archive, built here and extracted for real")

	_ = os.remove_all(SCRATCH)
	_ = os.make_directory_all(fmt.tprintf("%s/in/docs", SCRATCH))
	_ = os.write_entire_file(fmt.tprintf("%s/in/docs/readme.md", SCRATCH), transmute([]u8)string("# ordinary\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/in/docs/notes.txt", SCRATCH), transmute([]u8)string("nothing to see\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/in/evil.txt", SCRATCH), transmute([]u8)string("climbs out\n"))

	hostile := fmt.tprintf("%s/hostile.zip", SCRATCH)
	// `-s` rewrites the stored name, which is the only way to get `..` into an
	// archive with a tool that is trying to stop you.
	_, made := kit.run(
		{
			"bsdtar",
			"-a",
			"-c",
			"-f",
			hostile,
			"-C",
			fmt.tprintf("%s/in", SCRATCH),
			"-s",
			"|^evil|../../evil|",
			"docs/readme.md",
			"docs/notes.txt",
			"evil.txt",
		},
		context.temp_allocator,
	)
	ok(made && os.exists(hostile), "the hostile fixture should have been created")

	items, lerr, _ := list_archive(hostile)
	ok(lerr == "", "listing the hostile archive failed: %s", lerr)
	ok(len(items) == 3, "the hostile archive should list 3 entries, got %d", len(items))

	escaped_seen := false
	for it in items {
		if strings.contains(it.name, "..") {
			escaped_seen = true
			ok(it.bad, "%q must be flagged, it is not", it.name)
			ok(strings.contains(it.why, "escapes"), "the reason should mention escaping: %q", it.why)
		} else {
			ok(!it.bad, "%q should be safe but was flagged as %q", it.name, it.why)
		}
	}
	ok(escaped_seen, "the fixture should contain an entry with “..” in it")

	// Stage and extract with the real code path.
	{
		st := St {
			rows  = make([dynamic]Row),
			owned = make([dynamic]string),
			marks = make(map[string]bool),
			stage = make([dynamic]string),
			items = items,
			dest  = strings.clone(fmt.tprintf("%s/out", SCRATCH)),
		}
		stage_extraction(&st)
		ok(st.stage_bad == 1, "exactly one entry should have been refused, got %d", st.stage_bad)
		ok(len(st.stage) == 2, "two entries should be staged, got %d", len(st.stage))
		for n in st.stage {
			ok(!strings.contains(n, ".."), "a staged name still contains “..”: %q", n)
		}

		_ = os.make_directory_all(st.dest)
		names := make([]string, len(st.stage))
		for s, i in st.stage {
			names[i] = strings.clone(s)
		}
		job_start(
			Job {
				kind = .Extract,
				archive = strings.clone(hostile),
				dest = strings.clone(st.dest),
				names = names,
			},
		)
		ok(settle(), "the extraction job did not finish")

		ok(os.exists(fmt.tprintf("%s/out/docs/readme.md", SCRATCH)), "the safe file should have been extracted")
		ok(os.exists(fmt.tprintf("%s/out/docs/notes.txt", SCRATCH)), "the second safe file should have been extracted")
		// The payoff: the escaping entry is nowhere, inside or outside.
		ok(!os.exists(fmt.tprintf("%s/evil.txt", SCRATCH)), "the escaping entry landed one level up")
		ok(!os.exists("/tmp/evil.txt"), "the escaping entry landed two levels up")
		ok(!os.exists(fmt.tprintf("%s/out/evil.txt", SCRATCH)), "the escaping entry landed inside the destination")
		ok(!os.exists(fmt.tprintf("%s/out/../../evil.txt", SCRATCH)), "the escaping entry was written somewhere")
	}

	// -------------------------------------------------------------------
	fmt.println("-- an ordinary archive: round trip, tree, marks and overwrite")
	{
		normal := fmt.tprintf("%s/normal.zip", SCRATCH)
		_ = os.make_directory_all(fmt.tprintf("%s/src/project/src", SCRATCH))
		_ = os.write_entire_file(
			fmt.tprintf("%s/src/project/README.md", SCRATCH),
			transmute([]u8)string("# sample\n"),
		)
		_ = os.write_entire_file(
			fmt.tprintf("%s/src/project/src/main.odin", SCRATCH),
			transmute([]u8)string("package main\n"),
		)
		_ = os.write_entire_file(
			fmt.tprintf("%s/src/project/src/data.txt", SCRATCH),
			transmute([]u8)string("0123456789\n"),
		)

		// Create it through the same worker the UI uses.
		job_start(
			Job {
				kind = .Create,
				src = strings.clone(fmt.tprintf("%s/src/project", SCRATCH)),
				out = strings.clone(normal),
			},
		)
		ok(settle(), "the create job did not finish")
		ok(os.exists(normal), "creating an archive from a directory should produce a file")

		ni, nerr, _ := list_archive(normal)
		ok(nerr == "", "listing the archive we just created failed: %s", nerr)
		ok(len(ni) >= 4, "the created archive should hold at least 4 entries, got %d", len(ni))
		bad := 0
		for it in ni {
			if it.bad {bad += 1}
		}
		ok(bad == 0, "an archive we made ourselves should have no refused entries, found %d", bad)

		// The tree view: the root shows one folder, which opens onto three.
		off := p.offscreen_create(1120, 720, 1, "w-full h-full flex-col bg-background text-foreground")
		defer p.offscreen_destroy(off)
		register_dark_theme()

		st := St {
			rows       = make([dynamic]Row),
			owned      = make([dynamic]string),
			marks      = make(map[string]bool),
			filter     = make([dynamic]u8),
			edit       = make([dynamic]u8),
			found      = make([dynamic]string),
			stage      = make([dynamic]string),
			have_tar   = true,
			items      = ni,
			archive    = strings.clone(normal),
			dest       = strings.clone(fmt.tprintf("%s/out2", SCRATCH)),
			mode       = .Browse,
			create_src = strings.clone(""),
			create_out = strings.clone(""),
		}
		frame(off, &st)
		ok(len(st.rows) == 1, "the archive root should show one folder, showed %d", len(st.rows))
		if len(st.rows) == 0 {
			fmt.println("   (the tree checks cannot run without a listing)")
			fmt.printfln("\n%s  %d checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
			return fails
		}
		ok(st.rows[0].dir && st.rows[0].label == "project", "the root folder should be “project”, got %q", st.rows[0].label)

		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		ok(st.cwd == "project/", "Enter should descend into project/, cwd is %q", st.cwd)
		ok(len(st.rows) == 2, "project/ should hold src/ and README.md, showed %d", len(st.rows))
		ok(st.rows[0].dir, "folders should sort before files")

		// Space marks and advances.
		p.press_key(off, p.KEY_SPACE)
		frame(off, &st)
		ok(len(st.marks) == 1, "Space should mark one row, marked %d", len(st.marks))
		ok(st.sel == 1, "Space should advance the selection, sel is %d", st.sel)

		// Marking a folder expands to everything beneath it.
		stage_extraction(&st)
		ok(len(st.stage) == 3, "marking src/ should stage the folder and its two files, staged %d", len(st.stage))

		// Backspace goes back up.
		p.press_key(off, p.KEY_BACKSPACE)
		frame(off, &st)
		ok(st.cwd == "", "Backspace should return to the root, cwd is %q", st.cwd)

		// `a` is a toggle: with something marked it clears, with nothing marked
		// it marks everything in view.
		ok(len(st.marks) == 1, "src/ should still be marked at this point, %d marked", len(st.marks))
		p.press_key(off, 'a')
		frame(off, &st)
		ok(len(st.marks) == 0, "“a” with a mark present should clear, %d left", len(st.marks))
		p.press_key(off, 'a')
		frame(off, &st)
		ok(len(st.marks) >= 1, "“a” with nothing marked should mark the rows in view")
		p.press_key(off, 'a')
		frame(off, &st)
		ok(len(st.marks) == 0, "“a” again should clear the marks, %d left", len(st.marks))

		// With nothing marked, staging takes the whole archive.
		stage_extraction(&st)
		ok(len(st.stage) == len(ni), "with no marks everything is staged: %d of %d", len(st.stage), len(ni))

		// `e` opens the confirmation and writes nothing.
		p.press_key(off, 'e')
		frame(off, &st)
		ok(st.mode == .Confirm, "“e” should open the confirmation, mode is %v", st.mode)
		ok(!os.exists(fmt.tprintf("%s/out2", SCRATCH)), "nothing may be written before the confirmation is accepted")
		p.press_key(off, p.KEY_ESCAPE)
		frame(off, &st)
		ok(st.mode == .Browse, "Escape should cancel the confirmation, mode is %v", st.mode)
		ok(!os.exists(fmt.tprintf("%s/out2", SCRATCH)), "cancelling must not write anything")

		// Accept it, and the files land under the destination.
		p.press_key(off, 'e')
		frame(off, &st)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		wait_for_job(off, &st)
		ok(
			os.exists(fmt.tprintf("%s/out2/project/src/main.odin", SCRATCH)),
			"the extraction should have written project/src/main.odin",
		)
		ok(st.mode == .Done && st.result_ok, "the result dialog should report success, mode %v ok %v", st.mode, st.result_ok)

		// Staging again now sees the files already on disk.
		stage_extraction(&st)
		ok(st.stage_hit == 3, "all three files should be reported as already present, got %d", st.stage_hit)

		// And `-k` keeps them: change one, extract again without overwrite,
		// and the change survives.
		// Heap, not the frame arena: `offscreen_end` resets the temp allocator
		// on every frame, and this path has to outlive the frames below.
		marker := strings.clone(fmt.tprintf("%s/out2/project/README.md", SCRATCH))
		defer delete(marker)
		_ = os.write_entire_file(marker, transmute([]u8)string("EDITED BY THE TEST\n"))
		names := make([]string, len(st.stage))
		for s, i in st.stage {
			names[i] = strings.clone(s)
		}
		job_start(
			Job {
				kind = .Extract,
				archive = strings.clone(normal),
				dest = strings.clone(st.dest),
				names = names,
				overwrite = false,
			},
		)
		wait_for_job(off, &st)
		if data, err := os.read_entire_file_from_path(marker, context.temp_allocator); err == nil {
			ok(
				string(data) == "EDITED BY THE TEST\n",
				"without overwrite an existing file must be kept, found %q",
				string(data),
			)
		} else {
			ok(false, "the marker file disappeared")
		}
	}

	_ = os.remove_all(SCRATCH)

	more_checks, more_fails := backend_selftest()
	checks += more_checks
	fails += more_fails

	fmt.printfln("\n%s  %d checks, %d failure(s)", fails == 0 ? "PASS" : "FAILED", checks, fails)
	return fails
}
