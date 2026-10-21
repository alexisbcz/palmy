package main

// The command-line front end of Archive.
//
// Every command goes through the procedures the window's worker runs:
// `list` is list_archive, `extract` is stage_names and then extract_entries —
// the same staging the confirmation dialog shows, so the same entries are
// refused for the same reasons — and `create` is create_archive. Nothing here
// talks to bsdtar, 7-Zip, unrar or rar itself; backend.odin picks among the
// ones installed, and `formats` says what it would pick.
//
// A password is a `secret` parameter: the kit shows `<redacted>` for it in the
// audit log, in --json results and refusals, in --help and in the schema's
// examples. It still reaches the archiver only through a pipe (backend.odin),
// never through argv. `--password` is on *this* process's argv, though, where
// another local user can read it while the command runs; `--password-file`
// is the way that leaves no trace.
//
// The outcomes an agent acts on:
//   2  usage: a password an archive needs was not given (`reason:
//      password_required`), or given for a format with no encryption;
//   3  the archive, the source, or a named entry is not there;
//   4  --overwrite without --yes: replacing files on disk is asked for twice;
//   6  nothing installed can do it — the refusal names what would;
//   7  failed, including a wrong password (`reason: wrong_password`) and an
//      output that exists (`reason: exists`).

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

ENTRY_FIELDS :: []kit.Field {
	{name = "name", kind = .String, help = "the path inside the archive, exactly as stored; a folder ends in /"},
	{name = "dir", kind = .Bool},
	{name = "link", kind = .Bool},
	{name = "size", kind = .Int, help = "bytes, uncompressed"},
	{name = "modified", kind = .String, help = "as the archiver reports it"},
	{name = "mode", kind = .String, help = "unix mode, when the archive keeps one"},
	{name = "encrypted", kind = .Bool, help = "needs the password (7-Zip and unrar can tell; bsdtar cannot, and says false)"},
	{name = "refused", kind = .Bool, help = "the safety check will not extract it"},
	{name = "why", kind = .String, opt = true, help = "why it is refused"},
}

LIST_FIELDS :: []kit.Field {
	{name = "archive", kind = .String},
	{name = "format", kind = .String, help = "zip, 7z, rar, tar or other, from the first bytes"},
	{name = "label", kind = .String, help = "the window's badge: ZIP, TAR.GZ, 7Z, …"},
	{name = "tool", kind = .String, help = "the program that read it: bsdtar, 7z or unrar"},
	{name = "count", kind = .Int},
	{name = "files", kind = .Int},
	{name = "dirs", kind = .Int},
	{name = "total_size", kind = .Int, help = "bytes, uncompressed"},
	{name = "encrypted", kind = .Int, help = "entries that need the password"},
	{name = "refused", kind = .Int, help = "entries the safety check will not extract"},
	{name = "entries", kind = .Array, of = ENTRY_FIELDS},
}

REFUSED_FIELDS :: []kit.Field {
	{name = "name", kind = .String},
	{name = "why", kind = .String},
}

EXTRACT_FIELDS :: []kit.Field {
	{name = "archive", kind = .String},
	{name = "dest", kind = .String},
	{name = "tool", kind = .String},
	{name = "entries", kind = .Int, help = "entries staged: files and folders"},
	{name = "written", kind = .Int, help = "files written; 0 under --dry-run"},
	{name = "kept", kind = .Int, help = "files already at the destination and left alone (no --overwrite)"},
	{name = "encrypted", kind = .Int, help = "staged files that needed the password"},
	{name = "refused", kind = .Array, of = REFUSED_FIELDS},
}

CREATE_FIELDS :: []kit.Field {
	{name = "source", kind = .String},
	{name = "output", kind = .String},
	{name = "format", kind = .String},
	{name = "tool", kind = .String, help = "the program that wrote it, or would"},
	{name = "encrypted", kind = .Bool},
	{name = "bytes", kind = .Int, help = "the archive written; 0 under --dry-run"},
}

FORMAT_FIELDS :: []kit.Field {
	{name = "format", kind = .String},
	{name = "extensions", kind = .Array, of = {{kind = .String}}},
	{name = "read", kind = .String, help = "the program that would list and extract it; none when nothing installed can"},
	{name = "write", kind = .String},
	{name = "read_encrypted", kind = .String, help = "with a password; none when nothing installed can, or the format has no encryption"},
	{name = "write_encrypted", kind = .String},
	{name = "note", kind = .String, opt = true, help = "why one of them is none"},
}

FORMATS_FIELDS :: []kit.Field {
	{
		name = "installed",
		kind = .Object,
		of = {
			{name = "bsdtar", kind = .Bool},
			{name = "7z", kind = .Bool, help = "7z, 7zz or 7za"},
			{name = "7z_rar_codec", kind = .Bool},
			{name = "unrar", kind = .Bool},
			{name = "rar", kind = .Bool},
			{name = "setsid", kind = .Bool, help = "needed to hand a password over stdin"},
		},
	},
	{name = "formats", kind = .Array, of = FORMAT_FIELDS},
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "list",
		summary = "every entry of an archive, with what the safety check refuses and what is encrypted",
		effect = .Read,
		aliases = {"ls"},
		args = {{name = "archive", kind = .Path, required = true}},
		flags = {
			{name = "password", kind = .String, secret = true, help = "for a 7z or RAR whose names are encrypted (prefer --password-file)"},
			{name = "password-file", kind = .Path, help = "read the password from the first line of this file"},
			{name = "refused", kind = .Bool, help = "only the entries the safety check refuses"},
		},
		out = LIST_FIELDS,
		examples = {"archive list release.zip --json", "archive list secret.7z --password-file ~/.config/pw --json"},
		run = cmd_list,
	},
	{
		verb = "extract",
		summary = "write entries (all, or the named files and folders) under a directory; refused entries never",
		effect = .Mutate,
		aliases = {"x"},
		args = {
			{name = "archive", kind = .Path, required = true},
			{name = "entries", kind = .String, variadic = true, help = "names inside the archive; a folder takes everything under it; none means everything"},
		},
		flags = {
			{name = "to", kind = .Path, help = "the destination; ~/Downloads/<archive name> when omitted, as in the window"},
			{name = "overwrite", kind = .Bool, help = "replace files already there (needs --yes); without it they are kept"},
			{name = "password", kind = .String, secret = true, help = "for encrypted entries (prefer --password-file)"},
			{name = "password-file", kind = .Path, help = "read the password from the first line of this file"},
		},
		out = EXTRACT_FIELDS,
		examples = {
			"archive extract release.zip --to /tmp/release --json",
			"archive extract photos.7z albums/2024 --to ~/Pictures --password-file pw.txt --json",
			"archive extract release.zip --to /tmp/release --overwrite --yes --dry-run --json",
		},
		run = cmd_extract,
	},
	{
		verb = "create",
		summary = "build an archive from a file or folder; the format is the output's extension, encrypted with a password",
		effect = .Mutate,
		aliases = {"c"},
		args = {
			{name = "source", kind = .Path, required = true, help = "a file or folder"},
			{name = "output", kind = .Path, required = true, help = ".zip, .7z, .rar, .tar, .tar.gz, .tar.xz, .tar.zst, …; never overwritten"},
		},
		flags = {
			{name = "password", kind = .String, secret = true, help = "encrypt it: AES-256 for .zip and .7z (whose names are hidden too), and .rar (prefer --password-file)"},
			{name = "password-file", kind = .Path, help = "read the password from the first line of this file"},
		},
		out = CREATE_FIELDS,
		examples = {
			"archive create ~/Documents/report report.zip --json",
			"archive create ~/Documents/taxes taxes.7z --password-file pw.txt --json",
		},
		run = cmd_create,
	},
	{
		verb = "formats",
		summary = "which installed program would read and write each format, with and without a password",
		effect = .Read,
		out = FORMATS_FIELDS,
		examples = {"archive formats --json"},
		run = cmd_formats,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "archive",
			summary    = "archives: list, extract and create zip, tar, 7z and rar, with passwords",
			gui        = true,
			takes_path = true,
			takes_word = kit.cli_word_is_path,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `bsdtar reads zip, tar, iso, deb, rpm, and 7z and RAR without encryption; 7-Zip reads
and writes encrypted zip and 7z, and reads RAR with its RAR codec; unrar reads RAR;
only RARLAB's rar writes RAR. Whatever is installed is used, and an operation nothing
installed can do exits 6 naming what would. Every entry name is checked before
extraction: absolute paths, .. above the destination and symbolic links are refused.
A password never reaches an archiver's command line. A bare path opens the window.`

cli_selftest :: proc() -> int {
	return selftest() == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// password_of is --password, or the first line of --password-file. It is
// never printed: only its absence or a failure to read the file is reported.
@(private = "file")
password_of :: proc(c: ^kit.Call) -> (pw: string, code: int) {
	if kit.cli_has(c, "password-file") {
		path := kit.cli_str(c, "password-file")
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			return "", kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read the password file %s", path)
		}
		text := string(data)
		if i := strings.index_any(text, "\r\n"); i >= 0 {
			text = text[:i]
		}
		if text == "" {
			return "", kit.cli_failf(c, kit.EXIT_USAGE, "the password file %s is empty", path)
		}
		return text, kit.EXIT_OK
	}
	return kit.cli_str(c, "password"), kit.EXIT_OK
}

// fail_with maps a backend outcome onto the documented exit codes.
@(private = "file")
fail_with :: proc(c: ^kit.Call, f: Fail, msg: string) -> int {
	switch f {
	case .Need_Password:
		code := kit.cli_fail(c, kit.EXIT_USAGE, msg)
		kit.cli_err_field(c, "reason", "password_required")
		kit.cli_err_field(c, "pass", "--password-file FILE or --password PASSWORD")
		return code
	case .Wrong_Password:
		code := kit.cli_fail(c, kit.EXIT_FAILED, msg)
		kit.cli_err_field(c, "reason", "wrong_password")
		return code
	case .Unavailable:
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, msg)
	case .None, .Failed:
	}
	return kit.cli_fail(c, kit.EXIT_FAILED, msg)
}

@(private = "file")
need_archive :: proc(c: ^kit.Call) -> (path: string, code: int) {
	path = kit.cli_str(c, "archive")
	if !os.exists(path) {
		return path, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	if os.is_directory(path) {
		return path, kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder, not an archive", path)
	}
	return path, kit.EXIT_OK
}

@(private = "file")
entry_json :: proc(it: Item) -> ^kit.Json {
	e := kit.jobj()
	kit.jset_str(e, "name", it.name)
	kit.jset_bool(e, "dir", it.dir)
	kit.jset_bool(e, "link", it.link)
	kit.jset_i64(e, "size", it.size)
	kit.jset_str(e, "modified", it.date)
	kit.jset_str(e, "mode", it.perms)
	kit.jset_bool(e, "encrypted", it.encrypted)
	kit.jset_bool(e, "refused", it.bad)
	if it.bad {
		kit.jset_str(e, "why", it.why)
	}
	return e
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	path, code := need_archive(c)
	if code != kit.EXIT_OK {
		return code
	}
	pw, pcode := password_of(c)
	if pcode != kit.EXIT_OK {
		return pcode
	}
	kind := kind_of(path)
	if pw != "" && !can_encrypt(kind) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "a %s archive has no encryption; --password means nothing to it", KIND_NAMES[kind])
	}
	items, err, fail := list_archive(path, pw)
	if err != "" {
		return fail_with(c, fail, err)
	}
	defer free_items(items)
	tool, _ := reader_for(kind, pw != "", tools())

	only_refused := kit.cli_bool(c, "refused")
	arr := kit.jarr()
	files, dirs, locked, bad := 0, 0, 0, 0
	total := i64(0)
	for it in items {
		if it.dir {dirs += 1} else {files += 1; total += it.size}
		if it.encrypted {locked += 1}
		if it.bad {bad += 1}
		if only_refused && !it.bad {
			continue
		}
		kit.jpush(arr, entry_json(it))
	}
	kit.jset_str(c.out, "archive", path)
	kit.jset_str(c.out, "format", KIND_NAMES[kind])
	kit.jset_str(c.out, "label", archive_label(path))
	kit.jset_str(c.out, "tool", TOOL_NAMES[tool])
	kit.jset_int(c.out, "count", len(items))
	kit.jset_int(c.out, "files", files)
	kit.jset_int(c.out, "dirs", dirs)
	kit.jset_i64(c.out, "total_size", total)
	kit.jset_int(c.out, "encrypted", locked)
	kit.jset_int(c.out, "refused", bad)
	kit.jset(c.out, "entries", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_extract :: proc(c: ^kit.Call) -> int {
	path, code := need_archive(c)
	if code != kit.EXIT_OK {
		return code
	}
	overwrite := kit.cli_bool(c, "overwrite")
	if overwrite && !c.yes {
		// The kit's gate is per command; this one is per flag. Keeping what is
		// on disk is the default, and replacing it is asked for twice.
		code := kit.cli_fail(c, kit.EXIT_NEEDS_YES, "--overwrite replaces files on disk")
		kit.cli_err_field(c, "pass", "--yes")
		return code
	}
	pw, pcode := password_of(c)
	if pcode != kit.EXIT_OK {
		return pcode
	}
	kind := kind_of(path)
	if pw != "" && !can_encrypt(kind) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "a %s archive has no encryption; --password means nothing to it", KIND_NAMES[kind])
	}

	dest := kit.cli_str(c, "to")
	if dest == "" {
		dest = fmt.tprintf("%s/%s", home_rel("Downloads"), strip_archive_ext(path))
	}
	if os.exists(dest) && !os.is_directory(dest) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s exists and is not a folder", dest)
	}

	items, err, fail := list_archive(path, pw)
	if err != "" {
		return fail_with(c, fail, err)
	}
	defer free_items(items)

	picks := kit.cli_rest(c)
	if one := kit.cli_str(c, "entries"); one != "" && len(picks) == 0 {
		picks = {one}
	}
	for pick in picks {
		found := false
		for it in items {
			if wanted({pick}, it.name) {
				found = true
				break
			}
		}
		if !found {
			code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s has no entry %s", path, pick)
			kit.cli_err_field(c, "entry", pick)
			return code
		}
	}

	staged := stage_names(items, picks, dest)
	defer staged_free(&staged)
	if staged.encrypted > 0 && pw == "" {
		return fail_with(
			c,
			.Need_Password,
			fmt.tprintf("%d of the files to extract are encrypted — a password is needed", staged.encrypted),
		)
	}

	refused := kit.jarr()
	for i in staged.refused {
		r := kit.jobj()
		kit.jset_str(r, "name", items[i].name)
		kit.jset_str(r, "why", items[i].why)
		kit.jpush(refused, r)
		kit.cli_note(c, "refused %s: %s", items[i].name, items[i].why)
	}
	tool, _ := reader_for(kind, pw != "", tools())
	kit.jset_str(c.out, "archive", path)
	kit.jset_str(c.out, "dest", dest)
	kit.jset_str(c.out, "tool", TOOL_NAMES[tool])
	kit.jset_int(c.out, "entries", len(staged.names))
	kit.jset_int(c.out, "encrypted", staged.encrypted)
	kit.jset(c.out, "refused", refused)

	if c.dry_run {
		kit.jset_int(c.out, "written", 0)
		kit.jset_int(c.out, "kept", overwrite ? 0 : staged.hit)
		return kit.EXIT_OK
	}
	r := extract_entries(path, dest, staged.names[:], overwrite, pw)
	defer delete(r.msg)
	kit.jset_int(c.out, "written", r.written)
	kit.jset_int(c.out, "kept", r.kept)
	if !r.ok {
		if r.written > 0 {
			kit.cli_partial(c)
		}
		return fail_with(c, r.fail, r.msg)
	}
	if r.chunk_errors > 0 {
		kit.cli_note(c, "%s reported warnings on %d chunk(s)", TOOL_NAMES[r.tool], r.chunk_errors)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_create :: proc(c: ^kit.Call) -> int {
	src := strings.trim_suffix(kit.cli_str(c, "source"), "/")
	out := kit.cli_str(c, "output")
	if !os.exists(src) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", src)
	}
	if os.exists(out) {
		code := kit.cli_failf(c, kit.EXIT_FAILED, "%s already exists — an archive is never overwritten", out)
		kit.cli_err_field(c, "reason", "exists")
		return code
	}
	pw, pcode := password_of(c)
	if pcode != kit.EXIT_OK {
		return pcode
	}
	kind := kind_of(out)
	if pw != "" && !can_encrypt(kind) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "a %s archive has no encryption — name the output .zip, .7z or .rar to use a password", KIND_NAMES[kind])
	}
	tool, why := writer_for(kind, pw != "", tools())
	if tool == .None {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, why)
	}
	kit.jset_str(c.out, "source", src)
	kit.jset_str(c.out, "output", out)
	kit.jset_str(c.out, "format", KIND_NAMES[kind])
	kit.jset_str(c.out, "tool", TOOL_NAMES[tool])
	kit.jset_bool(c.out, "encrypted", pw != "")
	if c.dry_run {
		kit.jset_int(c.out, "bytes", 0)
		return kit.EXIT_OK
	}
	r := create_archive(src, out, pw)
	defer delete(r.msg)
	if !r.ok {
		return fail_with(c, r.fail, r.msg)
	}
	kit.jset_str(c.out, "tool", TOOL_NAMES[r.tool])
	kit.jset_i64(c.out, "bytes", r.bytes)
	return kit.EXIT_OK
}

@(private = "file")
cmd_formats :: proc(c: ^kit.Call) -> int {
	t := tools()
	inst := kit.jobj()
	kit.jset_bool(inst, "bsdtar", t.bsdtar)
	kit.jset_bool(inst, "7z", t.sevenzip != "")
	kit.jset_bool(inst, "7z_rar_codec", t.sevenzip_rar)
	kit.jset_bool(inst, "unrar", t.unrar)
	kit.jset_bool(inst, "rar", t.rar)
	kit.jset_bool(inst, "setsid", t.setsid)
	kit.jset(c.out, "installed", inst)

	Row :: struct {
		kind: Kind,
		exts: []string,
	}
	rows := [?]Row {
		{.Zip, {".zip", ".jar", ".whl", ".cbz"}},
		{.Seven, {".7z"}},
		{.Rar, {".rar", ".cbr"}},
		{.Tar, {".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".tar.zst"}},
		{.Other, {".iso", ".deb", ".rpm", ".gz", ".xz", ".bz2", ".zst"}},
	}
	arr := kit.jarr()
	for r in rows {
		f := kit.jobj()
		kit.jset_str(f, "format", KIND_NAMES[r.kind])
		exts := kit.jarr()
		for e in r.exts {kit.jpush(exts, kit.jstr(e))}
		kit.jset(f, "extensions", exts)
		rd, rwhy := reader_for(r.kind, false, t)
		wr, wwhy := writer_for(r.kind, false, t)
		kit.jset_str(f, "read", TOOL_NAMES[rd])
		kit.jset_str(f, "write", TOOL_NAMES[wr])
		note := rd == .None ? rwhy : wr == .None ? wwhy : ""
		if can_encrypt(r.kind) {
			erd, ewhy := reader_for(r.kind, true, t)
			ewr, ewwhy := writer_for(r.kind, true, t)
			kit.jset_str(f, "read_encrypted", TOOL_NAMES[erd])
			kit.jset_str(f, "write_encrypted", TOOL_NAMES[ewr])
			if note == "" {
				note = erd == .None ? ewhy : ewr == .None ? ewwhy : ""
			}
		} else {
			kit.jset_str(f, "read_encrypted", "none")
			kit.jset_str(f, "write_encrypted", "none")
			if note == "" {
				note = "no encryption in this format"
			}
		}
		if note != "" {
			kit.jset_str(f, "note", note)
		}
		kit.jpush(arr, f)
	}
	kit.jset(c.out, "formats", arr)
	return kit.EXIT_OK
}
