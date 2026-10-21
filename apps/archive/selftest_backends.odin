package main

// The self-test's second half: the backends, passwords and the command line.
//
// Everything here runs against real archivers on real archives built in a
// scratch directory, and each backend is driven on purpose by replacing the
// probed `g_tools` — so a machine with 7-Zip installed still tests the bsdtar
// path, and the other way round. A backend that is not installed is skipped
// with a line saying so, never counted as a pass.
//
// Three properties are the point:
//   * a directory handed to an archiver never carries a refused entry out
//     with it (the symlink under docs/);
//   * a password never appears on any archiver's argv — proved with shims on
//     PATH that record every argv they are started with — nor in the audit
//     log or the command line's output;
//   * the window asks for a password before it writes anything.

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
skip :: proc(what: string) {
	fmt.printfln("   skipped: %s", what)
}

@(private = "file")
S :: "/tmp/palmy-archive-selftest-b"

@(private = "file")
PW :: "Sentinel-pw-7f3a with space"

@(private = "file")
write :: proc(path, text: string) {
	_ = os.make_directory_all(dir_of(path))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i > 0 {
		return path[:i]
	}
	return "."
}

@(private = "file")
read :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "<missing>"
	}
	return string(data)
}

// is_link is lstat: a symlink to / "exists", and that is exactly what must
// not be there.
@(private = "file")
is_link :: proc(path: string) -> bool {
	fi, err := os.lstat(path, context.temp_allocator)
	return err == nil && fi.type == .Symlink
}

@(private = "file")
valid :: proc(text: string, fields: []kit.Field) -> bool {
	return len(kit.cli_validate_output(text, fields, context.temp_allocator)) == 0
}

@(private = "file")
problems :: proc(text: string, fields: []kit.Field) -> string {
	return strings.join(kit.cli_validate_output(text, fields, context.temp_allocator), "; ", context.temp_allocator)
}

@(private = "file")
cat :: proc(a, b: string) -> string {
	return fmt.tprintf("%s%s", a, b)
}

@(private = "file")
count_encrypted :: proc(items: []Item) -> (n: int) {
	for it in items {
		if it.encrypted {n += 1}
	}
	return
}

@(private = "file")
find_item :: proc(items: []Item, name: string) -> (Item, bool) {
	for it in items {
		if it.name == name {
			return it, true
		}
	}
	return {}, false
}

// force runs the checks that follow with a chosen set of backends; restore
// puts the probed set back.
@(private = "file")
Saved :: struct {
	t: Tools,
}

@(private = "file")
force :: proc(t: Tools) -> Saved {
	s := Saved{g_tools}
	g_tools = t
	g_tools.probed = true
	return s
}

@(private = "file")
restore :: proc(s: Saved) {
	g_tools = s.t
}

backend_selftest :: proc() -> (n_checks, n_fails: int) {
	_ = os.remove_all(S)
	_ = os.make_directory_all(S)
	os.set_env("PALM_AUDIT", S + "/audit.jsonl")
	real := tools()^

	// -------------------------------------------------------------------
	fmt.println("-- formats and which backend each one gets")
	{
		ok(kind_of("/x/a.7z") == .Seven, "a .7z is 7z")
		ok(kind_of("/x/a.RAR") == .Rar, "the extension check ignores case")
		ok(kind_of("/x/a.tar.zst") == .Tar, "a .tar.zst is tar")
		ok(kind_of("/x/a.cbz") == .Zip, "a comic book zip is a zip")
		ok(kind_of("/x/a.iso") == .Other, "an iso is bsdtar's")
		write(S + "/renamed.bin", string(RAR_HOSTILE[:]))
		ok(kind_of(S + "/renamed.bin") == .Rar, "a RAR is a RAR whatever it is called (magic bytes)")
		write(S + "/zip.dat", "PK\x03\x04rest")
		ok(kind_of(S + "/zip.dat") == .Zip, "a zip is found by its first bytes")
		ok(!can_encrypt(.Tar) && can_encrypt(.Zip) && can_encrypt(.Seven) && can_encrypt(.Rar), "only zip, 7z and rar have encryption")

		only_tar := Tools{probed = true, bsdtar = true, setsid = true}
		t, why := reader_for(.Seven, false, &only_tar)
		ok(t == .Bsdtar, "bsdtar reads a plain 7z when 7-Zip is absent, got %v", t)
		t, why = reader_for(.Seven, true, &only_tar)
		ok(t == .None && strings.contains(why, "7-Zip"), "an encrypted 7z without 7-Zip is unavailable and says what would do it: %q", why)
		t, why = reader_for(.Rar, true, &only_tar)
		ok(t == .None && strings.contains(why, "unrar"), "an encrypted RAR without unrar names unrar: %q", why)
		t, _ = reader_for(.Rar, false, &only_tar)
		ok(t == .Bsdtar, "libarchive reads a plain RAR")
		t, why = writer_for(.Rar, false, &only_tar)
		ok(t == .None && strings.contains(why, "rar"), "creating a RAR without rar is unavailable: %q", why)
		t, _ = writer_for(.Zip, true, &only_tar)
		ok(t == .Bsdtar, "an encrypted zip falls back to libarchive's AES when 7-Zip is absent")
		t, _ = writer_for(.Seven, true, &only_tar)
		ok(t == .None, "an encrypted 7z cannot be written without 7-Zip")

		full := Tools{probed = true, bsdtar = true, sevenzip = "7z", sevenzip_rar = true, unrar = true, rar = true, setsid = true}
		t, _ = reader_for(.Zip, false, &full)
		ok(t == .Sevenzip, "7-Zip reads a zip when it is there: it can say which entries are encrypted")
		t, _ = reader_for(.Rar, true, &full)
		ok(t == .Unrar, "unrar reads RAR first")
		t, _ = reader_for(.Tar, false, &full)
		ok(t == .Bsdtar, "tar is always bsdtar's")
		t, _ = writer_for(.Zip, false, &full)
		ok(t == .Bsdtar, "a plain zip is written as it always was, by bsdtar")
		t, _ = writer_for(.Zip, true, &full)
		ok(t == .Sevenzip, "an encrypted zip is 7-Zip's AES-256")
		t, _ = writer_for(.Rar, true, &full)
		ok(t == .Rar, "a RAR is written by rar when it is there")

		no_codec := Tools{probed = true, bsdtar = true, sevenzip = "7za", setsid = true}
		t, _ = reader_for(.Rar, true, &no_codec)
		ok(t == .None, "7za without the RAR codec cannot read an encrypted RAR")
		no_setsid := full
		no_setsid.setsid = false
		t, why = reader_for(.Zip, true, &no_setsid)
		ok(t == .None && strings.contains(why, "setsid"), "without setsid a password is refused, not risked on a terminal: %q", why)
		nothing := Tools{probed = true}
		t, _ = reader_for(.Zip, false, &nothing)
		ok(t == .None, "with nothing installed nothing is chosen")
	}

	fmt.println("-- parsing 7-Zip and unrar listings")
	{
		slt := "Path = docs\nSize = 0\nModified = 2026-01-02 03:04:05.1234\nAttributes = D drwxr-xr-x\nEncrypted = -\n\n" +
			"Path = a = b.txt\nSize = 12\nModified = 2026-01-02 03:04:05\nAttributes = A -rw-r--r--\nEncrypted = +\n\n" +
			"Path = docs/link\nSize = 1\nAttributes = A lrwxrwxrwx\nEncrypted = -\n\n" +
			"Path = WINDIR\nFolder = +\nSize = 0\nAttributes = D....\n\n" +
			"Path = ../../evil.txt\nSize = 2\nAttributes = A -rw-r--r--\nEncrypted = -\n"
		items := make([dynamic]Item)
		parse_7z_slt(slt, &items)
		finish_items(items[:])
		ok(len(items) == 5, "five 7-Zip entries, got %d", len(items))
		if len(items) == 5 {
			ok(items[0].name == "docs/" && items[0].dir, "a 7-Zip folder gains its trailing slash: %q", items[0].name)
			ok(items[1].name == "a = b.txt" && items[1].size == 12 && items[1].encrypted, "a name with \" = \" in it survives, with its size and its lock: %q", items[1].name)
			ok(items[1].date == "2026-01-02 03:04", "the date is cut to the minute: %q", items[1].date)
			ok(items[2].link && items[2].bad, "a link from its unix mode is refused")
			ok(items[3].dir && items[3].name == "WINDIR/", "a Windows folder (Folder = +) is a folder")
			ok(items[4].bad && strings.contains(items[4].why, "escapes"), "../../ from 7-Zip is refused like any other")
		}
		free_items(items[:])

		lt := "\nUNRAR 7.00 freeware\n\nArchive: x.rar\nDetails: RAR 5\n\n        Name: docs/readme.md\n        Type: File\n        Size: 11\n       mtime: 2026-01-02 03:04:05,000\n  Attributes: -rw-r--r--\n       Flags: encrypted \n\n" +
			"        Name: docs/link\n        Type: Unix symbolic link\n      Target: /\n        Size: 1\n  Attributes: lrwxrwxrwx\n\n        Name: docs\n        Type: Directory\n  Attributes: drwxr-xr-x\n"
		ui := make([dynamic]Item)
		parse_unrar_lt(lt, &ui)
		finish_items(ui[:])
		ok(len(ui) == 3, "three unrar entries, got %d", len(ui))
		if len(ui) == 3 {
			ok(ui[0].encrypted && ui[0].size == 11 && !ui[0].bad, "unrar's encrypted flag and size are read")
			ok(ui[1].link && ui[1].bad, "unrar's symbolic link is refused")
			ok(ui[2].dir && ui[2].name == "docs/", "unrar's directory gains its slash: %q", ui[2].name)
		}
		free_items(ui[:])

		twin := make([dynamic]Item)
		append(&twin, Item{name = strings.clone("x/same"), link = true}, Item{name = strings.clone("x/same")})
		finish_items(twin[:])
		ok(twin[1].bad, "a file that shares its name with a link is refused too: extraction goes by name")
		free_items(twin[:])

		ok(classify(Ran{out = "ERROR: Wrong password : a.txt"}, true) == .Wrong_Password, "7-Zip's wrong password")
		ok(classify(Ran{err = "Enter password (will not be echoed):"}, false) == .Need_Password, "a prompt with no password given is a password needed")
		ok(classify(Ran{err = "The specified password is incorrect."}, true) == .Wrong_Password, "unrar's wrong password")
		ok(classify(Ran{err = "No files to extract"}, false) == .Failed, "anything else is a failure")
		ua := extract_argv(.Unrar, "/a.rar", "/out", {"x/y.txt"}, false)
		ok(len(ua) > 0 && ua[len(ua) - 1] == "/out/", "unrar's destination is its last argument, with the slash that makes it one: %v", ua)
		ok(dots("pässwd") == "••••••", "a password field shows one dot per character: %q", dots("pässwd"))
	}

	// -------------------------------------------------------------------
	fmt.println("-- a folder never carries a refused link out with it")
	{
		// docs/ holds an ordinary file and a symlink to /. Before, extracting
		// everything handed bsdtar `docs/`, and a directory name takes all
		// beneath it — the refused link included.
		_ = os.make_directory_all(S + "/lk/docs")
		write(S + "/lk/docs/readme.md", "# ordinary\n")
		_ = os.symlink("/", S + "/lk/docs/link")
		zip := S + "/linked.zip"
		r := run_tool({"bsdtar", "-a", "-cf", zip, "-C", S + "/lk", "docs"})
		ok(r.started && r.code == 0, "the linked fixture is built")

		Pass :: struct {
			name:  string,
			tools: Tools,
			have:  bool,
		}
		passes := [?]Pass {
			{"bsdtar", Tools{probed = true, bsdtar = true, setsid = real.setsid}, real.bsdtar},
			{"7z", Tools{probed = true, bsdtar = real.bsdtar, sevenzip = real.sevenzip, setsid = real.setsid}, real.sevenzip != ""},
		}
		for ps in passes {
			if !ps.have {
				skip(fmt.tprintf("the %s pass: not installed", ps.name))
				continue
			}
			sv := force(ps.tools)
			items, err, _ := list_archive(zip)
			ok(err == "", "[%s] the linked zip lists: %s", ps.name, err)
			link, has := find_item(items, "docs/link")
			ok(has && link.bad, "[%s] the link is listed and refused", ps.name)
			staged := stage_names(items, nil, cat(S + "/lk-out-", ps.name))
			has_dir := false
			for n in staged.names {
				if n == "docs/" {has_dir = true}
			}
			ok(has_dir, "[%s] the folder itself is staged", ps.name)
			dest := fmt.tprintf("%s/lk-out-%s", S, ps.name)
			res := extract_entries(zip, dest, staged.names[:], false, "")
			ok(res.ok, "[%s] extraction succeeds: %s", ps.name, res.msg)
			ok(read(cat(dest, "/docs/readme.md")) == "# ordinary\n", "[%s] the file is written", ps.name)
			ok(!is_link(cat(dest, "/docs/link")) && !os.exists(cat(dest, "/docs/link")), "[%s] the refused link was carried out by its folder", ps.name)
			for argv_name in staged.names {
				if strings.has_suffix(argv_name, "/") {
					a := extract_argv(ps.tools.sevenzip != "" ? .Sevenzip : .Bsdtar, zip, dest, {"docs/readme.md"}, false)
					for w in a {
						ok(!strings.has_suffix(w, "/") || strings.has_prefix(w, "-") || w == dest || w == zip, "[%s] no directory name reaches the archiver: %q", ps.name, w)
					}
					break
				}
			}
			staged_free(&staged)
			free_items(items)
			delete(res.msg)
			restore(sv)
		}
	}

	// -------------------------------------------------------------------
	fmt.println("-- RAR, read by every backend that can")
	{
		hostile := S + "/hostile.rar"
		locked := S + "/locked.rar"
		filelocked := S + "/filelocked.rar"
		write(hostile, string(RAR_HOSTILE[:]))
		write(locked, string(RAR_LOCKED[:]))
		write(filelocked, string(RAR_FILELOCKED[:]))

		Pass :: struct {
			name:      string,
			tools:     Tools,
			have:      bool,
			passwords: bool,
		}
		passes := [?]Pass {
			{"unrar", Tools{probed = true, unrar = true, setsid = real.setsid}, real.unrar, true},
			{"7z", Tools{probed = true, sevenzip = real.sevenzip, sevenzip_rar = true, setsid = real.setsid}, real.sevenzip != "" && real.sevenzip_rar, true},
			{"bsdtar", Tools{probed = true, bsdtar = true, setsid = real.setsid}, real.bsdtar, false},
		}
		for ps in passes {
			if !ps.have {
				skip(fmt.tprintf("RAR through %s: not installed", ps.name))
				continue
			}
			sv := force(ps.tools)
			items, err, _ := list_archive(hostile)
			ok(err == "", "[%s] the hostile RAR lists: %s", ps.name, err)
			evil, has_evil := find_item(items, "../../evil.txt")
			ok(has_evil && evil.bad, "[%s] ../../evil.txt is listed raw and refused", ps.name)
			link, has_link := find_item(items, "docs/link")
			ok(has_link && link.bad, "[%s] the RAR's symlink is refused", ps.name)
			dest := fmt.tprintf("%s/rar-out-%s/a/b", S, ps.name)
			staged := stage_names(items, nil, dest)
			res := extract_entries(hostile, dest, staged.names[:], false, "")
			ok(res.ok, "[%s] the safe part extracts: %s", ps.name, res.msg)
			ok(read(cat(dest, "/docs/readme.md")) == "# ordinary\n", "[%s] docs/readme.md is written, found %q", ps.name, read(cat(dest, "/docs/readme.md")))
			ok(!os.exists(fmt.tprintf("%s/rar-out-%s/evil.txt", S, ps.name)) && !os.exists(cat(dest, "/evil.txt")), "[%s] evil.txt went nowhere", ps.name)
			ok(!is_link(cat(dest, "/docs/link")), "[%s] no link was made", ps.name)
			staged_free(&staged)
			free_items(items)
			delete(res.msg)

			if !ps.passwords {
				_, err2, f2 := list_archive(locked)
				ok(err2 != "" && f2 == .Need_Password, "[%s] a RAR with encrypted names cannot be read without a password (%v)", ps.name, f2)
				_, err3, f3 := list_archive(locked, "rar-pass")
				ok(err3 != "" && f3 == .Unavailable, "[%s] with a password it is unavailable, not attempted (%v: %s)", ps.name, f3, err3)
				restore(sv)
				continue
			}
			_, e1, f1 := list_archive(locked)
			ok(e1 != "" && f1 == .Need_Password, "[%s] encrypted names need the password: %v %s", ps.name, f1, e1)
			_, e2, f2 := list_archive(locked, "not-it")
			ok(e2 != "" && f2 == .Wrong_Password, "[%s] a wrong password is called wrong: %v %s", ps.name, f2, e2)
			li, e3, _ := list_archive(locked, "rar-pass")
			ok(e3 == "" && len(li) == 1 && count_encrypted(li) == 1, "[%s] the right password lists secret.txt as encrypted: %s (%d)", ps.name, e3, len(li))
			ldest := fmt.tprintf("%s/rar-locked-%s", S, ps.name)
			st2 := stage_names(li, nil, ldest)
			bad := extract_entries(locked, ldest, st2.names[:], false, "")
			ok(!bad.ok && bad.fail == .Need_Password, "[%s] extracting without the password stops: %v", ps.name, bad.fail)
			wrong := extract_entries(locked, ldest, st2.names[:], false, "not-it")
			ok(!wrong.ok && wrong.fail == .Wrong_Password, "[%s] extracting with a wrong one stops: %v %s", ps.name, wrong.fail, wrong.msg)
			good := extract_entries(locked, ldest, st2.names[:], false, "rar-pass")
			ok(good.ok && read(cat(ldest, "/secret.txt")) == "classified\n", "[%s] the right password extracts it: %s %q", ps.name, good.msg, read(cat(ldest, "/secret.txt")))
			staged_free(&st2)
			free_items(li)

			fi, fe, _ := list_archive(filelocked)
			ok(fe == "" && count_encrypted(fi) == 2, "[%s] visible names with encrypted data: listed without a password, both marked (%d)", ps.name, count_encrypted(fi))
			free_items(fi)
			restore(sv)
		}
	}

	// -------------------------------------------------------------------
	fmt.println("-- passwords: zip and 7z, made and read")
	{
		write(S + "/src/docs/a.txt", "alpha\n")
		write(S + "/src/b c.txt", "bravo\n")

		if real.sevenzip != "" {
			sv := force(real)
			z := create_archive(S + "/src", S + "/enc.zip", PW)
			ok(z.ok && z.tool == .Sevenzip && z.encrypted, "an encrypted zip is made by 7-Zip: %s", z.msg)
			delete(z.msg)
			items, err, _ := list_archive(S + "/enc.zip")
			ok(err == "" && count_encrypted(items) == 2, "a zip's names are readable and both files are marked encrypted (%d)", count_encrypted(items))
			staged := stage_names(items, nil, S + "/ez")
			ok(staged.encrypted == 2, "staging counts the encrypted files: %d", staged.encrypted)
			r1 := extract_entries(S + "/enc.zip", S + "/ez", staged.names[:], false, "")
			ok(!r1.ok && r1.fail == .Need_Password, "without the password: needed (%v)", r1.fail)
			r2 := extract_entries(S + "/enc.zip", S + "/ez", staged.names[:], false, "wrong")
			ok(!r2.ok && r2.fail == .Wrong_Password, "with a wrong one: wrong (%v)", r2.fail)
			_ = os.remove_all(S + "/ez")
			r3 := extract_entries(S + "/enc.zip", S + "/ez", staged.names[:], false, PW)
			ok(r3.ok && read(S + "/ez/src/b c.txt") == "bravo\n", "with the right one: written (%s)", r3.msg)
			staged_free(&staged)
			free_items(items)

			s7 := create_archive(S + "/src", S + "/enc.7z", PW)
			ok(s7.ok && s7.tool == .Sevenzip, "an encrypted 7z is made: %s", s7.msg)
			delete(s7.msg)
			_, e1, f1 := list_archive(S + "/enc.7z")
			ok(f1 == .Need_Password, "a 7z hides its names: listing needs the password (%v %s)", f1, e1)
			_, _, f2 := list_archive(S + "/enc.7z", "wrong")
			ok(f2 == .Wrong_Password, "and a wrong one is wrong (%v)", f2)
			li, e3, _ := list_archive(S + "/enc.7z", PW)
			ok(e3 == "" && len(li) == 4 && count_encrypted(li) == 2, "the right one lists 4 entries, 2 encrypted: %s %d %d", e3, len(li), count_encrypted(li))
			free_items(li)
			restore(sv)
		} else {
			skip("7-Zip passes: 7z is not installed")
		}

		if real.bsdtar && real.setsid {
			// libarchive's own AES zip, as used when 7-Zip is absent.
			sv := force(Tools{probed = true, bsdtar = true, setsid = true})
			z := create_archive(S + "/src", S + "/bsd-enc.zip", PW)
			ok(z.ok && z.tool == .Bsdtar, "without 7-Zip an encrypted zip is bsdtar's: %s", z.msg)
			delete(z.msg)
			items, _, _ := list_archive(S + "/bsd-enc.zip")
			staged := stage_names(items, nil, S + "/bz")
			bad := extract_entries(S + "/bsd-enc.zip", S + "/bz", staged.names[:], false, "wrong")
			ok(!bad.ok && bad.fail == .Wrong_Password, "bsdtar with a wrong password stops and says so (%v: %s)", bad.fail, bad.msg)
			good := extract_entries(S + "/bsd-enc.zip", S + "/bz2", staged.names[:], false, PW)
			ok(good.ok && read(S + "/bz2/src/docs/a.txt") == "alpha\n", "bsdtar extracts it with the password: %s", good.msg)
			staged_free(&staged)
			free_items(items)
			restore(sv)
			if real.sevenzip != "" {
				// Proof the option took: 7-Zip, which can tell, sees AES.
				sv2 := force(real)
				li, _, _ := list_archive(S + "/bsd-enc.zip")
				ok(count_encrypted(li) == 2, "7-Zip confirms bsdtar's zip is really encrypted (%d entries)", count_encrypted(li))
				free_items(li)
				restore(sv2)
			}
		}

		tz := create_archive(S + "/src", S + "/x.tar.gz", PW)
		ok(!tz.ok && strings.contains(tz.msg, "no encryption") && !os.exists(S + "/x.tar.gz"), "a tar with a password is refused, not made unencrypted: %s", tz.msg)
		if real.rar {
			r := create_archive(S + "/src", S + "/made.rar", PW)
			ok(r.ok && r.tool == .Rar, "rar makes an encrypted RAR: %s", r.msg)
			li, e, _ := list_archive(S + "/made.rar", PW)
			ok(e == "" && count_encrypted(li) == 2, "and it reads back encrypted: %s %d", e, count_encrypted(li))
			free_items(li)
		} else {
			r := create_archive(S + "/src", S + "/made.rar", "")
			ok(!r.ok && r.fail == .Unavailable && !os.exists(S + "/made.rar"), "without rar, creating a RAR is unavailable: %s", r.msg)
			skip("creating a RAR for real: rar is not installed")
		}
	}

	// -------------------------------------------------------------------
	fmt.println("-- the password is never on an archiver's command line")
	{
		shim :: S + "/shim"
		_ = os.make_directory_all(shim)
		log :: shim + "/argv.log"
		made := 0
		for exe in ([?]string{"7z", "bsdtar", "unrar", "rar"}) {
			at, found := kit.run({"sh", "-c", fmt.tprintf("command -v %s", exe)}, context.temp_allocator)
			if !found || at == "" {
				continue
			}
			script := fmt.tprintf("#!/bin/sh\nprintf '%%s\\n' \"%s $*\" >> %s\nexec %s \"$@\"\n", exe, log, at)
			write(cat(shim + "/", exe), script)
			_ = os.chmod(cat(shim + "/", exe), os.perm_number(0o755))
			made += 1
		}
		old_path := os.get_env("PATH", context.temp_allocator)
		os.set_env("PATH", fmt.tprintf("%s:%s", shim, old_path))
		g_tools = {}
		_ = tools()

		_ = create_archive(S + "/src", S + "/shim.zip", PW)
		_ = create_archive(S + "/src", S + "/shim.7z", PW)
		for a in ([?]string{S + "/shim.zip", S + "/shim.7z", S + "/locked.rar"}) {
			pw := strings.has_suffix(a, ".rar") ? "rar-pass" : PW
			items, _, _ := list_archive(a, pw)
			staged := stage_names(items, nil, S + "/shim-out")
			_ = extract_entries(a, S + "/shim-out", staged.names[:], true, pw)
			staged_free(&staged)
			free_items(items)
		}
		sv := force(Tools{probed = true, bsdtar = true, setsid = true})
		_ = create_archive(S + "/src", S + "/shim-bsd.zip", PW)
		bi, _, _ := list_archive(S + "/shim-bsd.zip")
		bs := stage_names(bi, nil, S + "/shim-out2")
		_ = extract_entries(S + "/shim-bsd.zip", S + "/shim-out2", bs.names[:], true, PW)
		staged_free(&bs)
		free_items(bi)
		restore(sv)

		os.set_env("PATH", old_path)
		g_tools = real

		logged := read(log)
		lines := strings.count(logged, "\n")
		ok(made > 0 && lines >= 6, "the shims saw the archivers start (%d shims, %d runs)", made, lines)
		ok(!strings.contains(logged, "Sentinel-pw") && !strings.contains(logged, "rar-pass"), "no archiver was ever given the password on its argv")
		ok(read(S + "/shim-out/src/docs/a.txt") == "alpha\n" && read(S + "/shim-out2/src/docs/a.txt") == "alpha\n", "and the extractions through the shims still worked")
	}

	// -------------------------------------------------------------------
	fmt.println("-- the command line")
	{
		s := surface()
		code, doc, text := kit.cli_capture_json(s, {"formats"}, context.temp_allocator)
		ok(code == 0, "formats answers: %d", code)
		ok(valid(text, FORMATS_FIELDS), "formats matches its declaration: %s", problems(text, FORMATS_FIELDS))
		_ = doc

		code, _, _ = kit.cli_capture_json(s, {"list", S + "/nope.zip"}, context.temp_allocator)
		ok(code == kit.EXIT_NOT_FOUND, "a missing archive is 3, got %d", code)
		code, _, _ = kit.cli_capture_json(s, {"list", S}, context.temp_allocator)
		ok(code == kit.EXIT_USAGE, "a folder is not an archive: 2, got %d", code)

		code, _, text = kit.cli_capture_json(s, {"create", S + "/src", S + "/cli.zip"}, context.temp_allocator)
		ok(code == 0 && valid(text, CREATE_FIELDS), "create a plain zip: %d %s", code, text)
		code, _, text = kit.cli_capture_json(s, {"create", S + "/src", S + "/cli.zip"}, context.temp_allocator)
		ok(code == kit.EXIT_FAILED && strings.contains(text, "\"exists\""), "an existing output is never overwritten: %d %s", code, text)
		code, _, _ = kit.cli_capture_json(s, {"create", S + "/src", S + "/cli.tar.gz", "--password", PW}, context.temp_allocator)
		ok(code == kit.EXIT_USAGE && !os.exists(S + "/cli.tar.gz"), "a password on a tar is a usage error and writes nothing: %d", code)
		code, _, text = kit.cli_capture_json(s, {"create", S + "/src", S + "/cli-dry.7z", "--password", PW, "--dry-run"}, context.temp_allocator)
		ok(code == 0 && !os.exists(S + "/cli-dry.7z") && strings.contains(text, "\"dry_run\": true"), "a dry run creates nothing: %d", code)
		if !real.rar {
			code, _, _ = kit.cli_capture_json(s, {"create", S + "/src", S + "/cli.rar"}, context.temp_allocator)
			ok(code == kit.EXIT_UNAVAILABLE, "a RAR without rar is 6, got %d", code)
		}

		write(S + "/pw.txt", PW + "\n")
		if real.sevenzip != "" {
			code, _, text = kit.cli_capture_json(s, {"create", S + "/src", S + "/cli.7z", "--password", PW}, context.temp_allocator)
			ok(code == 0 && strings.contains(text, "\"encrypted\": true"), "create an encrypted 7z: %d %s", code, text)
			ok(!strings.contains(text, "Sentinel"), "the result does not repeat the password")

			code, _, text = kit.cli_capture_json(s, {"list", S + "/cli.7z"}, context.temp_allocator)
			ok(code == kit.EXIT_USAGE && strings.contains(text, "password_required"), "listing hidden names without the password is 2, password_required: %d %s", code, text)
			code, _, text = kit.cli_capture_json(s, {"list", S + "/cli.7z", "--password", "wrong one"}, context.temp_allocator)
			ok(code == kit.EXIT_FAILED && strings.contains(text, "wrong_password") && !strings.contains(text, "wrong one"), "a wrong password is 7, wrong_password, and not echoed: %d %s", code, text)
			code, _, text = kit.cli_capture_json(s, {"list", S + "/cli.7z", "--password-file", S + "/pw.txt"}, context.temp_allocator)
			ok(code == 0 && valid(text, LIST_FIELDS) && strings.contains(text, "\"encrypted\": 2"), "--password-file lists it: %d %s", code, problems(text, LIST_FIELDS))

			code, _, text = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "--to", S + "/cx"}, context.temp_allocator)
			ok(code == kit.EXIT_USAGE && !os.exists(S + "/cx"), "extracting without the password is refused before anything is written: %d", code)
			code, _, text = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "--to", S + "/cx", "--password-file", S + "/pw.txt", "--dry-run"}, context.temp_allocator)
			ok(code == 0 && !os.exists(S + "/cx"), "a dry run extracts nothing: %d", code)
			code, _, text = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "--to", S + "/cx", "--password-file", S + "/pw.txt"}, context.temp_allocator)
			ok(code == 0 && valid(text, EXTRACT_FIELDS) && strings.contains(text, "\"written\": 2"), "extract with the password: %d %s", code, text)
			ok(read(S + "/cx/src/docs/a.txt") == "alpha\n", "and the file is there")
			write(S + "/cx/src/docs/a.txt", "EDITED\n")
			code, _, text = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "--to", S + "/cx", "--password-file", S + "/pw.txt"}, context.temp_allocator)
			ok(code == 0 && strings.contains(text, "\"kept\": 2") && read(S + "/cx/src/docs/a.txt") == "EDITED\n", "again: what is there is kept: %d %s", code, text)
			code, _, _ = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "--to", S + "/cx", "--password-file", S + "/pw.txt", "--overwrite"}, context.temp_allocator)
			ok(code == kit.EXIT_NEEDS_YES && read(S + "/cx/src/docs/a.txt") == "EDITED\n", "--overwrite without --yes is 4 and changes nothing: %d", code)
			code, _, _ = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "--to", S + "/cx", "--password-file", S + "/pw.txt", "--overwrite", "--yes"}, context.temp_allocator)
			ok(code == 0 && read(S + "/cx/src/docs/a.txt") == "alpha\n", "--overwrite --yes replaces it: %d", code)
			code, _, text = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "src/docs", "--to", S + "/cy", "--password", PW}, context.temp_allocator)
			ok(code == 0 && os.exists(S + "/cy/src/docs/a.txt") && !os.exists(S + "/cy/src/b c.txt"), "a named folder takes only what is under it: %d", code)
			code, _, text = kit.cli_capture_json(s, {"extract", S + "/cli.7z", "src/nothing", "--to", S + "/cz", "--password", PW}, context.temp_allocator)
			ok(code == kit.EXIT_NOT_FOUND && strings.contains(text, "src/nothing"), "a named entry that is not there is 3: %d", code)
		}

		hostile := S + "/hostile.rar"
		if os.exists(hostile) && (real.unrar || real.bsdtar || real.sevenzip_rar) {
			code, _, text = kit.cli_capture_json(s, {"extract", hostile, "--to", S + "/ch/a/b"}, context.temp_allocator)
			ok(code == 0 && strings.contains(text, "../../evil.txt") && strings.contains(text, "docs/link"), "the refused entries are reported by name: %d", code)
			ok(!os.exists(S + "/ch/evil.txt") && !is_link(S + "/ch/a/b/docs/link"), "and neither is written")
			code, _, text = kit.cli_capture_json(s, {"list", hostile, "--refused"}, context.temp_allocator)
			ok(code == 0 && strings.count(text, "\"refused\": true") == 2, "list --refused shows just the two: %s", text)
		}

		// A mistyped verb is a usage error, not a window; a path opens one.
		handled: bool
		code, handled = kit.cli_args(s, {"lsit"})
		ok(handled && code == kit.EXIT_USAGE, "a mistyped verb is 2, not a window: %d %v", code, handled)
		_, handled = kit.cli_args(s, {S + "/cli.zip"})
		ok(!handled, "an archive on disk is left for the window to open")

		audit := read(S + "/audit.jsonl")
		ok(strings.contains(audit, "\"archive\""), "the commands were audited, privately")
		ok(!strings.contains(audit, "Sentinel") && !strings.contains(audit, "wrong one"), "the audit log never holds a password")
		ok(strings.contains(audit, "<redacted>"), "it records that one was given")
	}

	// -------------------------------------------------------------------
	fmt.println("-- the window asks for the password before it writes")
	if real.sevenzip != "" {
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
			create_src = strings.clone(""),
			create_out = strings.clone(""),
		}
		open_archive(&st, S + "/enc.7z")
		pump(off, &st)
		ok(st.mode == .Password && st.pw_for == .List, "an archive with hidden names asks for its password: mode %v", st.mode)

		p.type_text(off, "not it")
		frame(off, &st)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		pump(off, &st)
		ok(st.mode == .Password && strings.contains(st.pw_note, "wrong"), "a wrong password asks again, saying so: %v %q", st.mode, st.pw_note)

		p.type_text(off, PW)
		frame(off, &st)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		pump(off, &st)
		ok(st.mode == .Browse && len(st.items) == 4, "the right one lists it: mode %v, %d items", st.mode, len(st.items))

		delete(st.dest)
		st.dest = strings.clone(S + "/gui-7z")
		p.press_key(off, 'e')
		frame(off, &st)
		ok(st.mode == .Confirm && st.stage_locked == 2, "the confirmation counts 2 encrypted files: %v %d", st.mode, st.stage_locked)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		pump(off, &st)
		ok(st.mode == .Done && st.result_ok && read(S + "/gui-7z/src/b c.txt") == "bravo\n", "the password typed for listing extracts too: %v %v", st.mode, st.result_ok)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)

		// A zip lists without its password; the window asks at extraction,
		// before writing anything.
		open_archive(&st, S + "/enc.zip")
		pump(off, &st)
		ok(st.mode == .Browse && st.password == "", "a zip opens without asking, and the 7z's password is forgotten: %v", st.mode)
		delete(st.dest)
		st.dest = strings.clone(S + "/gui-zip")
		p.press_key(off, 'e')
		frame(off, &st)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		ok(st.mode == .Password && st.pw_for == .Extract, "extracting encrypted entries asks first: %v", st.mode)
		ok(!os.exists(S + "/gui-zip"), "and nothing has been written while it asks")
		p.type_text(off, PW)
		frame(off, &st)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		pump(off, &st)
		ok(st.mode == .Done && st.result_ok && read(S + "/gui-zip/src/docs/a.txt") == "alpha\n", "then extracts with it: %v %v %q", st.mode, st.result_ok, st.result)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)

		// Creating: the third field is the password, drawn as dots.
		p.press_key(off, 'n')
		frame(off, &st)
		clear(&st.edit)
		p.type_text(off, S + "/src")
		frame(off, &st)
		p.press_key(off, p.KEY_TAB)
		frame(off, &st)
		clear(&st.edit)
		p.type_text(off, S + "/gui-made.7z")
		frame(off, &st)
		p.press_key(off, p.KEY_TAB)
		frame(off, &st)
		p.type_text(off, PW)
		frame(off, &st)
		ok(st.edit_which == 2 && string(st.edit[:]) == PW, "Tab reaches the password field: field %d", st.edit_which)
		p.press_key(off, p.KEY_RETURN)
		frame(off, &st)
		pump(off, &st)
		ok(st.mode == .Done && st.result_ok && st.create_pw == "", "the archive is made and its password not kept: %v %q", st.mode, st.result)
		sv := force(real)
		_, _, f := list_archive(S + "/gui-made.7z")
		ok(f == .Need_Password, "and it really is encrypted: %v", f)
		restore(sv)
	} else {
		skip("the window's password flow: it is tested on 7z archives, and 7z is not installed")
	}

	_ = os.remove_all(S)
	return checks, fails
}

@(private = "file")
frame :: proc(o: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(o)
	handle_keys(ui, nil, st)
	rebuild_rows(st)
	build(ui, st)
	p.offscreen_end(o)
}

// pump draws frames until the worker is idle and its result collected.
@(private = "file")
pump :: proc(o: ^p.Offscreen, st: ^St) {
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
