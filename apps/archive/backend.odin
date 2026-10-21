package main

// Which program does the work, and how a password reaches it.
//
// bsdtar (libarchive) was the only backend, and it covers most of what people
// meet: zip, every tar flavour, iso, deb, rpm, and it can even *read* 7z and
// RAR 4/5. What it cannot do is the reason this file exists:
//
//   * read an encrypted 7z, or a 7z whose headers are encrypted;
//   * read an encrypted RAR at all ("Encryption is not supported");
//   * write an encrypted 7z, or any RAR;
//   * say which entries of a zip are encrypted (its listing has no column).
//
// So there are four backends and a rule for each format, and the rule only
// ever picks something that is installed. When nothing installed can do the
// job, the answer is "unavailable" with the name of what would — never a
// half-done extraction.
//
//   format  read (list, extract)                     write (create)
//   zip     7z, else bsdtar                          bsdtar, or 7z with a password
//                                                    (bsdtar's AES zip when 7z is absent)
//   7z      7z, else bsdtar (no password)            7z, else bsdtar (no password)
//   rar     unrar, else 7z with its RAR codec,       rar (RARLAB's, non-free) only
//           else bsdtar (no password)
//   tar…    bsdtar                                   bsdtar; a password is refused,
//                                                    tar has no encryption
//
// 7z is preferred for reading a zip because its technical listing (`l -slt`)
// marks each encrypted entry, which is what lets the window ask for the
// password *before* an extraction rather than after it fails.
//
// **A password never goes on a command line.** Every one of these tools
// accepts `-p<password>` or `--passphrase`, and every one of them would then
// publish it in /proc/<pid>/cmdline for any local user to read while the
// extraction runs. Instead the child is started under `setsid` — a new
// session with no controlling terminal, so none of them can open /dev/tty —
// and the password is written to its stdin, which is where each of them reads
// a password when there is no terminal: 7-Zip by design, bsdtar through
// libarchive's readpassphrase fallback, unrar and rar through getpass. The
// same stdin, empty, is given to every run without a password, so a tool that
// unexpectedly wants one gets end-of-file instead of a prompt on whatever
// terminal launched the window. Without `setsid` a password is refused as
// unavailable rather than risk a prompt on a terminal nobody is watching.
//
// Nothing here logs, prints or stores a password: it lives in the Job (and the
// window's St) and is written to one pipe per child.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

Tool :: enum u8 {
	None,
	Bsdtar,
	Sevenzip,
	Unrar,
	Rar,
}

TOOL_NAMES := [Tool]string {
	.None     = "none",
	.Bsdtar   = "bsdtar",
	.Sevenzip = "7z",
	.Unrar    = "unrar",
	.Rar      = "rar",
}

// Tools is what is installed. It is probed once; the self-test replaces it to
// drive each backend on purpose.
Tools :: struct {
	probed:       bool,
	bsdtar:       bool,
	sevenzip:     string, // the 7-Zip binary on PATH: 7z, 7zz or 7za; "" when none
	sevenzip_rar: bool,   // that 7-Zip has its RAR codec (7zip-rar, p7zip-rar)
	unrar:        bool,
	rar:          bool,
	setsid:       bool,
}

g_tools: Tools

tools :: proc() -> ^Tools {
	if !g_tools.probed {
		g_tools = probe_tools()
	}
	return &g_tools
}

probe_tools :: proc() -> Tools {
	t := Tools {
		probed = true,
		bsdtar = kit.has_tool("bsdtar"),
		unrar  = kit.has_tool("unrar"),
		rar    = kit.has_tool("rar"),
		setsid = kit.has_tool("setsid"),
	}
	// 7za is the reduced build (no RAR); 7z and 7zz are the full ones.
	for exe in ([?]string{"7z", "7zz", "7za"}) {
		if kit.has_tool(exe) {
			t.sevenzip = exe
			break
		}
	}
	if t.sevenzip != "" {
		// `7z i` lists the codecs it loaded. 40305 is RAR5's method id, which
		// only the separately packaged RAR codec provides.
		out, _ := kit.run({t.sevenzip, "i"}, context.temp_allocator)
		t.sevenzip_rar = strings.contains(out, "40305")
	}
	return t
}

// ---------------------------------------------------------------------------
// Formats
// ---------------------------------------------------------------------------

Kind :: enum u8 {
	Other, // iso, deb, rpm, a lone .gz: bsdtar's
	Tar,
	Zip,
	Seven,
	Rar,
}

KIND_NAMES := [Kind]string {
	.Other = "other",
	.Tar   = "tar",
	.Zip   = "zip",
	.Seven = "7z",
	.Rar   = "rar",
}

// kind_of names the format: from the first bytes when the file exists (a
// renamed archive is still what it is), from the extension when it does not
// yet — which is the case for every archive about to be created.
kind_of :: proc(path: string) -> Kind {
	if f, err := os.open(path); err == nil {
		head: [8]u8
		n, _ := os.read(f, head[:])
		os.close(f)
		b := head[:n]
		switch {
		case len(b) >= 6 && string(b[:6]) == "7z\xBC\xAF\x27\x1C":
			return .Seven
		case len(b) >= 6 && string(b[:6]) == "Rar!\x1A\x07":
			return .Rar
		case len(b) >= 4 && (string(b[:4]) == "PK\x03\x04" || string(b[:4]) == "PK\x05\x06"):
			return .Zip
		}
	}
	low := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(low, ".zip"), strings.has_suffix(low, ".jar"),
	     strings.has_suffix(low, ".whl"), strings.has_suffix(low, ".cbz"):
		return .Zip
	case strings.has_suffix(low, ".7z"):
		return .Seven
	case strings.has_suffix(low, ".rar"), strings.has_suffix(low, ".cbr"):
		return .Rar
	case strings.has_suffix(low, ".tar"), strings.has_suffix(low, ".tar.gz"),
	     strings.has_suffix(low, ".tgz"), strings.has_suffix(low, ".tar.bz2"),
	     strings.has_suffix(low, ".tbz2"), strings.has_suffix(low, ".tar.xz"),
	     strings.has_suffix(low, ".txz"), strings.has_suffix(low, ".tar.zst"),
	     strings.has_suffix(low, ".tzst"):
		return .Tar
	}
	return .Other
}

// can_encrypt is whether the format has encryption at all. tar has none, and
// "encrypting" one would be a lie the archive could not keep.
can_encrypt :: proc(k: Kind) -> bool {
	return k == .Zip || k == .Seven || k == .Rar
}

// reader_for picks the backend that lists and extracts an archive of this
// kind, or says what would.
reader_for :: proc(k: Kind, password: bool, t: ^Tools) -> (tool: Tool, why: string) {
	if password && !t.setsid {
		return .None, "a password is only passed through stdin under setsid (util-linux or busybox), which is not installed"
	}
	switch k {
	case .Seven:
		if t.sevenzip != "" {return .Sevenzip, ""}
		if password {return .None, "an encrypted 7z needs 7-Zip (7z, 7zz or 7za), which is not installed"}
	case .Rar:
		if t.unrar {return .Unrar, ""}
		if t.sevenzip != "" && t.sevenzip_rar {return .Sevenzip, ""}
		if password {return .None, "an encrypted RAR needs unrar, or 7-Zip with its RAR codec; neither is installed"}
	case .Zip:
		if t.sevenzip != "" {return .Sevenzip, ""}
	case .Tar, .Other:
	}
	if t.bsdtar {
		return .Bsdtar, ""
	}
	return .None, "nothing that reads this is installed: bsdtar (libarchive-tools), 7-Zip or unrar"
}

// writer_for picks the backend that creates an archive of this kind.
writer_for :: proc(k: Kind, password: bool, t: ^Tools) -> (tool: Tool, why: string) {
	if password && !t.setsid {
		return .None, "a password is only passed through stdin under setsid (util-linux or busybox), which is not installed"
	}
	switch k {
	case .Rar:
		if t.rar {return .Rar, ""}
		return .None, "creating a RAR needs RARLAB's rar, which is not installed (unrar and 7-Zip only read RAR)"
	case .Seven:
		if t.sevenzip != "" {return .Sevenzip, ""}
		if password {return .None, "an encrypted 7z needs 7-Zip (7z, 7zz or 7za), which is not installed"}
	case .Zip:
		// bsdtar writes the same zip without a password as it always has; with
		// one, 7-Zip's AES-256 zip, or libarchive's own when 7-Zip is absent.
		if password && t.sevenzip != "" {return .Sevenzip, ""}
	case .Tar, .Other:
	}
	if t.bsdtar {
		return .Bsdtar, ""
	}
	if k == .Zip && t.sevenzip != "" {
		return .Sevenzip, ""
	}
	return .None, "nothing that writes this is installed: bsdtar (libarchive-tools) or 7-Zip"
}

// ---------------------------------------------------------------------------
// Running a tool, with the password on stdin
// ---------------------------------------------------------------------------

Ran :: struct {
	out:     string,
	err:     string,
	code:    int,
	started: bool,
}

// run_tool runs argv with `secret` written to its stdin (twice, for the tools
// that ask again to confirm a new password), under setsid when it is there.
// Output is in the temp allocator.
run_tool :: proc(argv: []string, secret := "", dir := "") -> (r: Ran) {
	// The kit's guard applies here as it does to kit.run: while a command
	// runs, nothing on the project's denylist may start.
	if why := kit.cli_guard_check(argv); why != "" {
		fmt.eprintfln("archive: refused to run %s: %s", argv[0], why)
		return
	}
	cmd := make([dynamic]string, context.temp_allocator)
	if tools().setsid {
		append(&cmd, "setsid")
	} else if secret != "" {
		return
	}
	append(&cmd, ..argv)

	rd, wr, perr := os.pipe()
	if perr != nil {
		return
	}
	if secret != "" {
		// A pipe holds 64 KiB; a password is far below that, so writing it
		// before the child starts cannot block.
		for _ in 0 ..< 2 {
			os.write_string(wr, secret)
			os.write_string(wr, "\n")
		}
	}
	os.close(wr)
	state, sout, serr, err := os.process_exec(
		{command = cmd[:], stdin = rd, working_dir = dir},
		context.temp_allocator,
	)
	os.close(rd)
	if err != nil {
		return
	}
	return Ran{out = string(sout), err = string(serr), code = state.exit_code, started = true}
}

// Fail says why a backend run did not work, in the terms a caller acts on.
Fail :: enum u8 {
	None,
	Need_Password,  // encrypted, and no password was given
	Wrong_Password,
	Unavailable,    // no installed tool can do it
	Failed,
}

// classify reads a failed run's output for the two password outcomes every
// backend reports in words rather than in its exit code.
classify :: proc(r: Ran, had_password: bool) -> Fail {
	text := strings.to_lower(fmt.tprintf("%s\n%s", r.out, r.err), context.temp_allocator)
	switch {
	case strings.contains(text, "wrong password"),
	     strings.contains(text, "password is incorrect"),
	     strings.contains(text, "incorrect password"),
	     strings.contains(text, "incorrect passphrase"):
		return had_password ? .Wrong_Password : .Need_Password
	case strings.contains(text, "enter password"),
	     strings.contains(text, "enter passphrase"),
	     strings.contains(text, "passphrase required"),
	     strings.contains(text, "can not open encrypted archive"),
	     strings.contains(text, "cannot open encrypted archive"),
	     strings.contains(text, "header is encrypted"),
	     strings.contains(text, "encryption is not supported"):
		return had_password ? .Wrong_Password : .Need_Password
	}
	return .Failed
}

// first_error is the line of a tool's output worth showing a person.
first_error :: proc(r: Ran) -> string {
	for src in ([?]string{r.err, r.out}) {
		it := src
		for line in strings.split_lines_iterator(&it) {
			l := strings.trim_space(line)
			low := strings.to_lower(l, context.temp_allocator)
			if strings.contains(low, "error") || strings.contains(low, "cannot") ||
			   strings.contains(low, "can not") || strings.contains(low, "failed") ||
			   strings.contains(low, "unsupported") || strings.contains(low, "not ") {
				return l
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

// list_with lists through one backend. Every name is checked by check_name
// whichever program produced it; that check is the safety story, and it does
// not care who did the parsing.
list_with :: proc(tool: Tool, path, password: string) -> (items: []Item, err: string, fail: Fail) {
	out := make([dynamic]Item)
	switch tool {
	case .None, .Rar:
		delete(out)
		return nil, "nothing installed can read this archive", .Unavailable
	case .Bsdtar:
		names := run_tool({"bsdtar", "-tf", path}, password)
		if !names.started || names.code != 0 {
			delete(out)
			f := classify(names, password != "")
			return nil, list_error(path, names, f), f
		}
		verbose := run_tool({"bsdtar", "-tvf", path}, password)
		vlines := strings.split_lines(strings.trim_space(verbose.out), context.temp_allocator)
		nlines := strings.split_lines(strings.trim_space(names.out), context.temp_allocator)
		vi := 0
		for n in nlines {
			if n == "" {
				continue
			}
			it := Item{name = strings.clone(n), dir = strings.has_suffix(n, "/")}
			if vi < len(vlines) {
				if perms, size, date, good := parse_verbose(vlines[vi]); good {
					it.perms = strings.clone(perms)
					it.size = size
					it.date = strings.clone(date)
					it.dir = len(perms) > 0 && perms[0] == 'd'
					it.link = len(perms) > 0 && perms[0] == 'l'
				}
			}
			vi += 1
			append(&out, it)
		}
	case .Sevenzip:
		r := run_tool({tools().sevenzip, "l", "-slt", "-ba", "--", path}, password)
		if !r.started || r.code != 0 {
			delete(out)
			f := classify(r, password != "")
			return nil, list_error(path, r, f), f
		}
		parse_7z_slt(r.out, &out)
	case .Unrar:
		r := run_tool({"unrar", "lt", "--", path}, password)
		if !r.started || r.code != 0 {
			delete(out)
			f := classify(r, password != "")
			return nil, list_error(path, r, f), f
		}
		parse_unrar_lt(r.out, &out)
	}
	finish_items(out[:])
	return out[:], "", .None
}

@(private = "file")
list_error :: proc(path: string, r: Ran, f: Fail) -> string {
	switch f {
	case .Need_Password:
		return fmt.aprintf("%s is encrypted — a password is needed", path)
	case .Wrong_Password:
		return fmt.aprintf("the password for %s is wrong", path)
	case .None, .Unavailable, .Failed:
	}
	if !r.started {
		return fmt.aprintf("could not start the program that reads %s", path)
	}
	if line := first_error(r); line != "" {
		return fmt.aprintf("could not read %s: %s", path, line)
	}
	return fmt.aprintf("could not read %s", path)
}

// finish_items fills the derived fields and runs the safety check. A name
// that is a link anywhere in the archive is refused everywhere: extraction
// goes by name, and a file and a link of the same name would otherwise travel
// together.
finish_items :: proc(items: []Item) {
	links := make(map[string]bool, context.temp_allocator)
	for it in items {
		if it.link {
			links[strings.trim_suffix(it.name, "/")] = true
		}
	}
	for &it in items {
		parent, base := split_parent(it.name)
		it.parent = strings.clone(parent)
		it.base = strings.clone(base)
		why := check_name(it.name, it.link)
		if why == "" && !it.link && links[strings.trim_suffix(it.name, "/")] {
			why = "shares its name with a symbolic link — skipped"
		}
		it.why = strings.clone(why)
		it.bad = why != ""
	}
}

// parse_7z_slt reads `7z l -slt -ba`: blocks of `Key = Value`, one per
// entry, separated by blank lines. The name is the whole value of `Path`, so a
// space in it costs nothing.
parse_7z_slt :: proc(text: string, out: ^[dynamic]Item) {
	cur: Item
	have := false
	flush :: proc(out: ^[dynamic]Item, cur: ^Item, have: ^bool) {
		if have^ {
			append(out, cur^)
		}
		cur^ = {}
		have^ = false
	}
	it := text
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_right(line, "\r")
		if strings.trim_space(l) == "" {
			flush(out, &cur, &have)
			continue
		}
		eq := strings.index(l, " = ")
		key, val := "", ""
		if eq >= 0 {
			key, val = l[:eq], l[eq + 3:]
		} else if strings.has_suffix(l, " =") {
			key = l[:len(l) - 2]
		} else {
			continue
		}
		switch key {
		case "Path":
			if have {
				flush(out, &cur, &have)
			}
			cur.name = strings.clone(val)
			have = true
		case "Folder":
			cur.dir = val == "+"
		case "Size":
			if v, ok := parse_i64(val); ok {cur.size = v}
		case "Modified":
			cur.date = strings.clone(val[:min(16, len(val))])
		case "Attributes":
			// `D drwxr-xr-x`, `A -rw-r--r--`, ` lrwxrwxrwx`, or only `D....`
			// from Windows: the unix mode, when there is one, is the last word.
			f := strings.fields(val, context.temp_allocator)
			if len(f) > 0 {
				last := f[len(f) - 1]
				if len(last) == 10 && strings.index_byte("-dlcbps", last[0]) >= 0 {
					cur.perms = strings.clone(last)
					if last[0] == 'd' {cur.dir = true}
					if last[0] == 'l' {cur.link = true}
				} else if strings.has_prefix(f[0], "D") {
					cur.dir = true
				}
			}
		case "Encrypted":
			cur.encrypted = val == "+"
		case "Symbolic Link":
			if val != "" {cur.link = true}
		}
	}
	flush(out, &cur, &have)
	// 7-Zip names a directory without the trailing slash bsdtar gives it; the
	// tree is built on that slash.
	for &e in out {
		if e.dir && !strings.has_suffix(e.name, "/") {
			old := e.name
			e.name = strings.concatenate({old, "/"})
			delete(old)
		}
	}
}

// parse_unrar_lt reads `unrar lt`: indented `Key: Value` lines, one block per
// entry, each starting with `Name:`.
parse_unrar_lt :: proc(text: string, out: ^[dynamic]Item) {
	cur: Item
	have := false
	it := text
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		colon := strings.index(l, ": ")
		key, val := "", ""
		if colon > 0 {
			key, val = l[:colon], l[colon + 2:]
		} else if strings.has_suffix(l, ":") {
			key = l[:len(l) - 1]
		} else {
			continue
		}
		switch key {
		case "Name":
			if have {
				append(out, cur)
			}
			cur = Item{name = strings.clone(val)}
			have = true
		case "Type":
			low := strings.to_lower(val, context.temp_allocator)
			cur.dir = low == "directory"
			cur.link = strings.contains(low, "link")
		case "Size":
			if v, ok := parse_i64(val); ok {cur.size = v}
		case "mtime":
			cur.date = strings.clone(val[:min(16, len(val))])
		case "Attributes":
			if len(val) == 10 {
				cur.perms = strings.clone(val)
				if val[0] == 'd' {cur.dir = true}
				if val[0] == 'l' {cur.link = true}
			}
		case "Flags":
			if strings.contains(val, "encrypted") {cur.encrypted = true}
		}
	}
	if have {
		append(out, cur)
	}
	for &e in out {
		if e.dir && !strings.has_suffix(e.name, "/") {
			old := e.name
			e.name = strings.concatenate({old, "/"})
			delete(old)
		}
	}
}

// ---------------------------------------------------------------------------
// Extracting and creating, one chunk at a time
// ---------------------------------------------------------------------------

// extract_argv is one chunk's command. Only files are ever named: a directory
// named to any of these tools takes everything beneath it, a refused symlink
// included, so directories are made by the caller instead (see run_extract).
extract_argv :: proc(tool: Tool, archive, dest: string, names: []string, overwrite: bool) -> []string {
	argv := make([dynamic]string, context.temp_allocator)
	switch tool {
	case .None, .Rar:
		return nil
	case .Bsdtar:
		// -n: never recurse into a directory, should one ever be named.
		append(&argv, "bsdtar", "-x", "-n", "-f", archive, "-C", dest, "--no-same-owner")
		if !overwrite {
			// -k keeps whatever is already on disk. Overwriting is only ever
			// done when the user asked for it.
			append(&argv, "-k")
		}
	case .Sevenzip:
		// -spd: names are names, not wildcards. -aos skips what exists.
		append(&argv, tools().sevenzip, "x", "-y", "-spd", overwrite ? "-aoa" : "-aos")
		append(&argv, fmt.tprintf("-o%s", dest), "--", archive)
	case .Unrar:
		append(&argv, "unrar", "x", "-y", overwrite ? "-o+" : "-o-", "--", archive)
	}
	if tool == .Bsdtar {
		append(&argv, "--")
	}
	append(&argv, ..names)
	if tool == .Unrar {
		// unrar takes a last argument ending in / as the destination, over
		// any -op switch — so a name ending in / would have been one. The
		// destination always goes last, slash and all.
		append(&argv, strings.has_suffix(dest, "/") ? dest : fmt.tprintf("%s/", dest))
	}
	return argv[:]
}

// create_argv builds the archive at `out` (absolute) from `base`, a name in
// the working directory `parent`.
create_argv :: proc(tool: Tool, kind: Kind, out, base: string, password: bool) -> []string {
	argv := make([dynamic]string, context.temp_allocator)
	switch tool {
	case .None, .Unrar:
		return nil
	case .Bsdtar:
		// -a picks the format from the output's extension, so `out.zip` really
		// is a zip and `out.tar.gz` really is gzipped tar.
		append(&argv, "bsdtar", "-a", "-c")
		if password {
			append(&argv, "--options", "zip:encryption=aes256")
		}
		append(&argv, "-f", out, "--", base)
	case .Sevenzip:
		append(&argv, tools().sevenzip, "a", kind == .Zip ? "-tzip" : "-t7z", "-snl", "-y")
		if password {
			// `-p` with no value asks for the password, on stdin here. A 7z also
			// hides its file names (-mhe); a zip has no way to.
			append(&argv, "-p")
			append(&argv, kind == .Zip ? "-mem=AES256" : "-mhe=on")
		}
		append(&argv, "--", out, base)
	case .Rar:
		append(&argv, "rar", "a", "-ol", "-idq", "-y")
		if password {
			// -hp encrypts the headers too, as 7z's -mhe does.
			append(&argv, "-hp")
		}
		append(&argv, "--", out, base)
	}
	return argv[:]
}
