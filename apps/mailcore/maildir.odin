package main

// A real Maildir, as specified by D. J. Bernstein (maildir(5)) with the
// Courier/Dovecot flag suffix convention and the Maildir++ folder layout.
//
// This is the engine's *only* interface to the UI: there is no shared code and
// no IPC. Anything that can read a Maildir — mutt, notmuch, Dovecot, the palmy
// mail UI — can read what this writes.
//
// LAYOUT
//
//	$XDG_DATA_HOME/palmy-mail/            (default ~/.local/share/palmy-mail)
//	  <account>/                          one directory per account
//	    cur/ new/ tmp/                    INBOX lives at the account root
//	    .Sent/{cur,new,tmp}               Maildir++ subfolders: a leading dot,
//	    .Archive/{cur,new,tmp}            IMAP hierarchy flattened with '.'
//	    .Lists.odin/{cur,new,tmp}         e.g. IMAP "Lists/odin"
//	    maildirfolder                     marker inside each subfolder
//
// DELIVERY is the maildir(5) dance, unchanged: write to tmp/, fsync, rename
// into new/ (or straight into cur/ with a flag suffix when the flags are
// already known, which is what an IMAP sync does). rename(2) within one
// filesystem is atomic, so a reader never sees a half-written message.
//
// FILENAMES are `<secs>.M<usec>P<pid>Q<seq>.<host>`, which is the modern
// unique-name recipe from maildir(5): the sequence counter makes two
// deliveries in the same microsecond distinct, and the hostname makes two
// machines writing one NFS mailbox distinct. '/' and ':' in a hostname are
// escaped as maildir(5) requires.
//
// FLAGS are the `:2,` info field. The letters must be in ASCII order, so the
// bit_set is declared in that order and rendering is a straight iteration:
//	D draft, F flagged, P passed, R replied, S seen, T trashed

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:time"

Maildir_Flag :: enum u8 {
	Draft, // D
	Flagged, // F
	Passed, // P
	Replied, // R
	Seen, // S
	Trashed, // T
}
Maildir_Flags :: bit_set[Maildir_Flag;u8]

@(private = "file", rodata)
FLAG_LETTERS := [Maildir_Flag]u8 {
	.Draft   = 'D',
	.Flagged = 'F',
	.Passed  = 'P',
	.Replied = 'R',
	.Seen    = 'S',
	.Trashed = 'T',
}

Maildir :: struct {
	root: string, // the account directory
	seq:  int, // per-process delivery counter
	host: string,
}

Maildir_Entry :: struct {
	unique: string, // the part before ':2,'
	name:   string, // the full basename on disk
	path:   string, // absolute path
	folder: string,
	flags:  Maildir_Flags,
	in_new: bool, // sitting in new/, i.e. never seen by any client
	size:   i64,
}

INBOX :: "INBOX"

// Mail is private: 0700 directories, 0600 files.
PERM_DIR :: os.Permissions{.Read_User, .Write_User, .Execute_User}
PERM_FILE :: os.Permissions{.Read_User, .Write_User}

// maildir_flags_string renders the info field letters in ASCII order.
maildir_flags_string :: proc(f: Maildir_Flags, allocator := context.allocator) -> string {
	buf := make([dynamic]u8, 0, 6, allocator)
	for flag in Maildir_Flag {
		if flag in f {
			append(&buf, FLAG_LETTERS[flag])
		}
	}
	return string(buf[:])
}

// maildir_flags_parse reads an info field. Unknown letters are ignored rather
// than rejected, because other clients add their own (Dovecot uses a-z keyword
// slots) and dropping the message would be worse than dropping the letter.
maildir_flags_parse :: proc(info: string) -> (f: Maildir_Flags) {
	s := info
	// Accept either the bare letters or the full ":2,XY".
	if strings.has_prefix(s, ":2,") {
		s = s[3:]
	} else if strings.has_prefix(s, "2,") {
		s = s[2:]
	}
	for i in 0 ..< len(s) {
		switch s[i] {
		case 'D':
			f |= {.Draft}
		case 'F':
			f |= {.Flagged}
		case 'P':
			f |= {.Passed}
		case 'R':
			f |= {.Replied}
		case 'S':
			f |= {.Seen}
		case 'T':
			f |= {.Trashed}
		}
	}
	return
}

// maildir_parse_name splits a basename into its unique part and its flags.
// A name with no `:2,` is an unflagged (typically new/) message.
maildir_parse_name :: proc(name: string) -> (unique: string, flags: Maildir_Flags, has_info: bool) {
	// maildir(5): the info field is everything after the *last* ':'. A ':' can
	// never appear in the unique part, so the first works too; use the last so
	// that a hostname that somehow kept one does not confuse us.
	if c := strings.last_index_byte(name, ':'); c >= 0 {
		return name[:c], maildir_flags_parse(name[c:]), true
	}
	return name, {}, false
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// maildir_default_root is the ONE place mail is allowed to live.
maildir_default_root :: proc(allocator := context.allocator) -> string {
	if xdg, ok := os.lookup_env("XDG_DATA_HOME", context.temp_allocator); ok && xdg != "" {
		return strings.concatenate({xdg, "/palmy-mail"}, allocator)
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		home = os.get_env("HOME", context.temp_allocator)
	}
	if home == "" {
		home = "/tmp"
	}
	return strings.concatenate({home, "/.local/share/palmy-mail"}, allocator)
}

// escape_host applies the maildir(5) rule for hostnames.
@(private = "file")
escape_host :: proc(h: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(h) {
		switch h[i] {
		case '/':
			strings.write_string(&sb, "\\057")
		case ':':
			strings.write_string(&sb, "\\072")
		case:
			strings.write_byte(&sb, h[i])
		}
	}
	s := strings.to_string(sb)
	return s == "" ? "localhost" : s
}

@(private = "file")
read_hostname :: proc(allocator := context.allocator) -> string {
	if data, err := os.read_entire_file_from_path("/proc/sys/kernel/hostname", context.temp_allocator);
	   err == nil {
		return escape_host(strings.trim_space(string(data)), allocator)
	}
	return "localhost"
}

// maildir_folder_dir maps an IMAP-style folder name onto a Maildir++ path.
// "INBOX" (or "") is the account root; everything else becomes ".Name", with
// '/' in the folder name flattened to '.'.
maildir_folder_dir :: proc(md: ^Maildir, folder: string, allocator := context.allocator) -> string {
	f := folder
	if f == "" || strings.equal_fold(f, INBOX) {
		return strings.clone(md.root, allocator)
	}
	flat := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(f) {
		switch f[i] {
		case '/':
			strings.write_byte(&flat, '.')
		case 0 ..< 0x20, '\x7f':
		// dropped: a control character in a folder name is not a folder name
		case:
			strings.write_byte(&flat, f[i])
		}
	}
	name := strings.trim_left(strings.to_string(flat), ".")
	return strings.concatenate({md.root, "/.", name}, allocator)
}

// maildir_folder_name is the inverse: a directory basename back to the folder.
maildir_folder_name :: proc(base: string, allocator := context.allocator) -> string {
	n := strings.trim_left(base, ".")
	out := strings.builder_make(allocator)
	for i in 0 ..< len(n) {
		strings.write_byte(&out, n[i] == '.' ? '/' : n[i])
	}
	return strings.to_string(out)
}

// ---------------------------------------------------------------------------
// Opening and creating
// ---------------------------------------------------------------------------

@(private = "file")
mkdir_p :: proc(path: string) -> (err: string) {
	// Create each component in turn; EEXIST is success.
	if path == "" || path == "/" {
		return ""
	}
	parts := strings.split(path, "/", context.temp_allocator)
	acc := strings.builder_make(context.temp_allocator)
	for p, i in parts {
		if i == 0 && p == "" {
			strings.write_byte(&acc, '/')
			continue
		}
		if p == "" {
			continue
		}
		if strings.builder_len(acc) > 0 && strings.to_string(acc)[strings.builder_len(acc) - 1] != '/' {
			strings.write_byte(&acc, '/')
		}
		strings.write_string(&acc, p)
		cur := strings.to_string(acc)
		if os.exists(cur) {
			if !os.is_dir(cur) {
				return fmt.aprintf("%s exists and is not a directory", cur)
			}
			continue
		}
		if e := os.make_directory(cur, PERM_DIR); e != nil && !os.exists(cur) {
			return fmt.aprintf("mkdir %s: %v", cur, e)
		}
	}
	return ""
}

// maildir_open prepares an account directory, creating INBOX if it is new.
maildir_open :: proc(root: string, allocator := context.allocator) -> (md: Maildir, err: string) {
	md.root = strings.clone(root, allocator)
	md.host = read_hostname(allocator)
	if e := mkdir_p(md.root); e != "" {
		return md, e
	}
	return md, maildir_ensure_folder(&md, INBOX)
}

maildir_ensure_folder :: proc(md: ^Maildir, folder: string) -> (err: string) {
	dir := maildir_folder_dir(md, folder, context.temp_allocator)
	if e := mkdir_p(dir); e != "" {
		return e
	}
	for sub in ([?]string{"tmp", "new", "cur"}) {
		if e := mkdir_p(strings.concatenate({dir, "/", sub}, context.temp_allocator)); e != "" {
			return e
		}
	}
	if dir != md.root {
		// Maildir++ marker, so other tools recognise this as a folder and not
		// a stray directory.
		marker := strings.concatenate({dir, "/maildirfolder"}, context.temp_allocator)
		if !os.exists(marker) {
			_ = os.write_entire_file(marker, []u8{})
		}
	}
	return ""
}

// maildir_folders lists INBOX plus every Maildir++ subfolder, sorted.
maildir_folders :: proc(md: ^Maildir, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	append(&out, strings.clone(INBOX, allocator))
	infos, err := os.read_all_directory_by_path(md.root, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for fi in infos {
		if !(fi.type == .Directory) {
			continue
		}
		base := basename(fi.fullpath)
		if !strings.has_prefix(base, ".") || base == "." || base == ".." {
			continue
		}
		append(&out, maildir_folder_name(base, allocator))
	}
	slice.sort(out[1:])
	return out[:]
}

basename :: proc(p: string) -> string {
	if i := strings.last_index_byte(p, '/'); i >= 0 {
		return p[i + 1:]
	}
	return p
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

// maildir_unique_name builds a name that no other delivery can collide with.
maildir_unique_name :: proc(md: ^Maildir, allocator := context.allocator) -> string {
	now := time.now()
	secs := time.to_unix_seconds(now)
	usec := (time.to_unix_nanoseconds(now) % 1_000_000_000) / 1000
	md.seq += 1
	return fmt.aprintf(
		"%d.M%dP%dQ%d.%s",
		secs,
		usec,
		int(linux.getpid()),
		md.seq,
		md.host,
		allocator = allocator,
	)
}

// maildir_deliver writes one message.
//
// `flags == {}` and `to_new == true` is a fresh delivery: the message lands in
// new/ with no info field, which is how every other Maildir tool learns it is
// unread. A sync that already knows the server-side flags writes straight to
// cur/ with the info field attached, which is what `to_new = false` does.
maildir_deliver :: proc(
	md: ^Maildir,
	folder: string,
	data: []u8,
	flags: Maildir_Flags = {},
	to_new := true,
	allocator := context.allocator,
) -> (
	name: string,
	err: string,
) {
	if e := maildir_ensure_folder(md, folder); e != "" {
		return "", e
	}
	dir := maildir_folder_dir(md, folder, context.temp_allocator)
	unique := maildir_unique_name(md, context.temp_allocator)

	tmp_path := strings.concatenate({dir, "/tmp/", unique}, context.temp_allocator)
	f, oe := os.open(tmp_path, os.O_WRONLY | os.O_CREATE | os.O_EXCL, PERM_FILE)
	if oe != nil {
		return "", fmt.aprintf("open %s: %v", tmp_path, oe)
	}
	off := 0
	for off < len(data) {
		n, we := os.write(f, data[off:])
		if we != nil || n <= 0 {
			os.close(f)
			os.remove(tmp_path)
			return "", fmt.aprintf("write %s: %v", tmp_path, we)
		}
		off += n
	}
	// maildir(5) is explicit that the file must be on disk before the rename,
	// or a crash leaves a valid-looking but empty message in new/.
	os.sync(f)
	os.close(f)

	final_name: string
	dest_sub: string
	if to_new && flags == {} {
		final_name = strings.clone(unique, allocator)
		dest_sub = "/new/"
	} else {
		final_name = fmt.aprintf(
			"%s:2,%s",
			unique,
			maildir_flags_string(flags, context.temp_allocator),
			allocator = allocator,
		)
		dest_sub = "/cur/"
	}
	final_path := strings.concatenate({dir, dest_sub, final_name}, context.temp_allocator)
	if re := os.rename(tmp_path, final_path); re != nil {
		os.remove(tmp_path)
		return "", fmt.aprintf("rename %s -> %s: %v", tmp_path, final_path, re)
	}
	return final_name, ""
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

maildir_list :: proc(md: ^Maildir, folder: string, allocator := context.allocator) -> []Maildir_Entry {
	out := make([dynamic]Maildir_Entry, 0, 32, allocator)
	dir := maildir_folder_dir(md, folder, context.temp_allocator)
	for sub in ([?]string{"new", "cur"}) {
		p := strings.concatenate({dir, "/", sub}, context.temp_allocator)
		infos, err := os.read_all_directory_by_path(p, context.temp_allocator)
		if err != nil {
			continue
		}
		for fi in infos {
			if (fi.type == .Directory) {
				continue
			}
			base := basename(fi.fullpath)
			if base == "" || base[0] == '.' {
				continue // dotfiles are not messages
			}
			unique, flags, _ := maildir_parse_name(base)
			append(
				&out,
				Maildir_Entry {
					unique = strings.clone(unique, allocator),
					name = strings.clone(base, allocator),
					path = strings.clone(fi.fullpath, allocator),
					folder = strings.clone(folder, allocator),
					flags = flags,
					in_new = sub == "new",
					size = fi.size,
				},
			)
		}
	}
	slice.sort_by(out[:], proc(a, b: Maildir_Entry) -> bool {return a.unique < b.unique})
	return out[:]
}

maildir_read :: proc(e: Maildir_Entry, allocator := context.allocator) -> (data: []u8, err: string) {
	d, re := os.read_entire_file_from_path(e.path, allocator)
	if re != nil {
		return nil, fmt.aprintf("read %s: %v", e.path, re)
	}
	return d, ""
}

// maildir_set_flags renames a message to carry `flags`. A message in new/ is
// moved into cur/ as a side effect, which is exactly what "the user looked at
// it" means in Maildir terms.
maildir_set_flags :: proc(
	md: ^Maildir,
	e: ^Maildir_Entry,
	flags: Maildir_Flags,
	allocator := context.allocator,
) -> (
	err: string,
) {
	dir := maildir_folder_dir(md, e.folder, context.temp_allocator)
	new_name := fmt.aprintf(
		"%s:2,%s",
		e.unique,
		maildir_flags_string(flags, context.temp_allocator),
		allocator = allocator,
	)
	new_path := strings.concatenate({dir, "/cur/", new_name}, allocator)
	if new_path == e.path {
		e.flags = flags
		return ""
	}
	if re := os.rename(e.path, new_path); re != nil {
		return fmt.aprintf("rename %s -> %s: %v", e.path, new_path, re)
	}
	e.name = new_name
	e.path = new_path
	e.flags = flags
	e.in_new = false
	return ""
}

maildir_remove :: proc(e: Maildir_Entry) -> (err: string) {
	if re := os.remove(e.path); re != nil {
		return fmt.aprintf("remove %s: %v", e.path, re)
	}
	return ""
}

// maildir_find looks a message up by its unique part, which is what a sync
// uses to decide whether a UID has already been delivered.
maildir_find :: proc(entries: []Maildir_Entry, unique: string) -> (Maildir_Entry, bool) {
	for e in entries {
		if e.unique == unique {
			return e, true
		}
	}
	return {}, false
}
