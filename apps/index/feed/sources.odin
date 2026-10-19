// The sources: each walks one kind of data of one identity, puts what
// changed into that identity's index, and removes what disappeared.
//
// Every source decides "changed" by a signature the index stores with each
// document (Doc.sig): a Maildir file's name (its flags live in the name and
// its content never changes), a file's size and mtime, a calendar object's
// size and mtime plus the day (recurrences are expanded around today). An
// unchanged thing is skipped without being opened, which is what makes a
// rescan after an inotify event cost a directory listing.
//
// A source only ever reads its own identity's folder and only ever writes
// its own identity's index: the Writer it is handed is that identity's,
// and there is no way to name another.
package indexfeed

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import ic "../core"
import ical "../../../cloud/dav/ical"

Source_Kind :: enum {
	Mail,
	Drive,
	Notes,
	Calendar,
	Contacts,
	Browser,
	Tasks,
}

SOURCE_NAME := [Source_Kind]string {
	.Mail     = "mail",
	.Drive    = "drive",
	.Notes    = "notes",
	.Calendar = "calendar",
	.Contacts = "contacts",
	.Browser  = "browser",
	.Tasks    = "tasks",
}

// The key prefix each source owns; removal only ever looks at its own.
SOURCE_PREFIX := [Source_Kind]string {
	.Mail     = "mail:",
	.Drive    = "file:",
	.Notes    = "note:",
	.Calendar = "event:",
	.Contacts = "person:",
	.Browser  = "page:",
	.Tasks    = "task:",
}

Scan_Stats :: struct {
	seen:    int,
	added:   int, // put (new or changed)
	removed: int,
	skipped: int, // unchanged
	errors:  int,
	dirs:    [dynamic]string, // directories to watch for this source
	present: bool, // the source has a folder for this identity
}

Ctx :: struct {
	w:     ^ic.Writer,
	id:    Ident,
	paths: Paths,
	now:   i64,
	seen:  map[string]bool,
	kept:  map[string]bool, // unchanged multi-document files: their instances stay
	st:    ^Scan_Stats,
	mail:  ^Mail_Cache, // per identity, kept across scans by the daemon
	mine:  []string, // every address of this person: mail between their own identities waits on nobody
	yield: proc(), // called between files: the daemon's chance to breathe
}

@(private)
sig_of :: proc(parts: ..any) -> u64 {
	return ic.fnv64(fmt.tprint(..parts, sep = "|"))
}

@(private)
put_if_changed :: proc(c: ^Ctx, key: string, sig: u64) -> bool {
	c.seen[strings.clone(key, context.temp_allocator)] = true
	c.st.seen += 1
	if old, ok := ic.writer_sig(c.w, key); ok && old == sig {
		c.st.skipped += 1
		return false
	}
	return true
}

@(private)
put :: proc(c: ^Ctx, d: ic.Doc) {
	ic.writer_put(c.w, d)
	c.st.added += 1
	if c.yield != nil {
		c.yield()
	}
}

// sweep removes the source's documents that the scan did not see.
@(private)
sweep :: proc(c: ^Ctx, k: Source_Kind) {
	for key in ic.writer_keys(c.w, SOURCE_PREFIX[k]) {
		if hash := strings.index_byte(key, '#'); hash >= 0 && key[:hash] in c.kept {
			continue
		}
		if key not_in c.seen {
			ic.writer_remove(c.w, key)
			c.st.removed += 1
		}
	}
}

scan :: proc(w: ^ic.Writer, id: Ident, p: Paths, k: Source_Kind, mc: ^Mail_Cache = nil, yield: proc() = nil, mine: []string = nil) -> Scan_Stats {
	st: Scan_Stats
	st.dirs = make([dynamic]string)
	c := Ctx {
		w     = w,
		id    = id,
		paths = p,
		now   = time.to_unix_seconds(time.now()),
		seen  = make(map[string]bool, allocator = context.temp_allocator),
		kept  = make(map[string]bool, allocator = context.temp_allocator),
		st    = &st,
		mail  = mc,
		mine  = mine,
		yield = yield,
	}
	ok := true
	switch k {
	case .Mail:
		ok = scan_mail(&c)
	case .Drive:
		ok = scan_tree(&c, fmt.tprintf("%s/%s", p.drive, id.handle), .Drive)
	case .Notes:
		ok = scan_tree(&c, fmt.tprintf("%s/%s", p.notes, id.handle), .Notes)
	case .Calendar:
		ok = scan_dav(&c, "calendar")
	case .Contacts:
		ok = scan_dav(&c, "addressbook")
	case .Browser:
		ok = scan_browser(&c)
	case .Tasks:
		ok = scan_tasks(&c)
	}
	// A source whose folder is missing removes nothing: a folder that is
	// briefly gone (palm sync swaps the Maildir) must not empty the index.
	if ok && st.present {
		sweep(&c, k)
	}
	return st
}

// ---------------------------------------------------------------------------
// Mail
// ---------------------------------------------------------------------------

// Mail_Facts are what "waiting on you" needs from every message, kept so a
// rescan does not have to open files whose name did not change.
Mail_Facts :: struct {
	message_id: string,
	replies_to: [dynamic]string, // In-Reply-To and References ids
	from_me:    bool,
	from_self:  bool, // from another of this person's identities
	to_me:      bool,
	machine:    bool,
	time:       i64,
}

Mail_Cache :: struct {
	facts: map[string]Mail_Facts, // by Maildir unique name
}

mail_cache_destroy :: proc(mc: ^Mail_Cache) {
	for _, f in mc.facts {
		delete(f.message_id)
		for r in f.replies_to {
			delete(r)
		}
		delete(f.replies_to)
	}
	delete(mc.facts)
}

@(private)
Mail_File :: struct {
	path:   string,
	name:   string,
	unique: string,
	flags:  string,
	folder: string, // "" for INBOX
	fresh:  bool, // in new/
}

@(private)
FOLDER_LABEL :: proc(f: string) -> string {
	switch f {
	case "":
		return "Inbox"
	}
	return f
}

@(private)
list_mail :: proc(root: string, out: ^[dynamic]Mail_File, st: ^Scan_Stats) {
	folders := make([dynamic]string, context.temp_allocator)
	append(&folders, "")
	entries, _ := os.read_all_directory_by_path(root, context.temp_allocator)
	for e in entries {
		if e.type == .Directory && strings.has_prefix(e.name, ".") && len(e.name) > 1 && e.name != ".." {
			append(&folders, e.name[1:])
		}
	}
	for f in folders {
		base := f == "" ? root : fmt.tprintf("%s/.%s", root, f)
		for sub in ([2]string{"cur", "new"}) {
			dir := fmt.tprintf("%s/%s", base, sub)
			files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
			if err != nil {
				continue
			}
			append(&st.dirs, strings.clone(dir))
			for fi in files {
				if fi.type != .Regular || strings.has_prefix(fi.name, ".") {
					continue
				}
				unique := fi.name
				flags := ""
				if c := strings.index(fi.name, ":2,"); c >= 0 {
					unique = fi.name[:c]
					flags = fi.name[c + 3:]
				}
				append(out, Mail_File {
					path = fi.fullpath,
					name = fi.name,
					unique = unique,
					flags = flags,
					folder = repl(f, ".", "/"),
					fresh = sub == "new",
				})
			}
		}
	}
}

// read_head reads a file's first `n` bytes: headers are all "waiting"
// needs, and most messages are small.
@(private)
read_head :: proc(path: string, n: int) -> []u8 {
	f, err := os.open(path)
	if err != nil {
		return nil
	}
	defer os.close(f)
	buf := make([]u8, n, context.temp_allocator)
	got, _ := os.read(f, buf)
	return buf[:max(got, 0)]
}

@(private)
ids_in :: proc(v: string, out: ^[dynamic]string) {
	rest := v
	for {
		a := strings.index_byte(rest, '<')
		if a < 0 {
			break
		}
		b := strings.index_byte(rest[a:], '>')
		if b < 0 {
			break
		}
		append(out, strings.clone(rest[a + 1:a + b]))
		rest = rest[a + b + 1:]
	}
}

@(private)
facts_of :: proc(m: Message, self: string, folder: string, file_time: i64) -> Mail_Facts {
	f := Mail_Facts {
		message_id = strings.clone(m.message_id),
		from_me    = self != "" && m.from_addr == self || strings.has_prefix(strings.to_lower(folder, context.temp_allocator), "sent"),
		to_me      = self == "" || strings.contains(strings.to_lower(m.to, context.temp_allocator), self),
		machine    = m.machine,
		time       = m.date != 0 ? m.date : file_time,
	}
	ids_in(m.in_reply_to, &f.replies_to)
	ids_in(m.references, &f.replies_to)
	return f
}

// palm_ids maps Maildir unique names to the server's ids, from the file
// `mailcore palm sync` writes. A sync replaces every file and so every
// name; the server id is what stays the same, so it is the key.
@(private)
palm_ids :: proc(root: string) -> map[string]string {
	m := make(map[string]string, allocator = context.temp_allocator)
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/.palm-ids", root), context.temp_allocator)
	if err != nil {
		return m
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) >= 2 && f[0] != "" && f[1] != "" {
			m[f[0]] = f[1]
		}
	}
	return m
}

WAITING_DAYS :: 14

@(private)
scan_mail :: proc(c: ^Ctx) -> bool {
	root := c.id.mail_dir
	if root == "" || !os.is_dir(root) {
		return true
	}
	c.st.present = true
	append(&c.st.dirs, strings.clone(root))
	self := strings.to_lower(c.id.address, context.temp_allocator)
	files := make([dynamic]Mail_File, context.temp_allocator)
	list_mail(root, &files, c.st)
	sids := palm_ids(root)

	// Pass 1: facts for every message (cached by unique name), so we know
	// which messages you have answered.
	mc := c.mail
	local: Mail_Cache
	if mc == nil {
		mc = &local
	}
	defer if mc == &local {
		mail_cache_destroy(&local)
	}
	live := make(map[string]bool, allocator = context.temp_allocator)
	for f in files {
		live[f.unique] = true
		if f.unique in mc.facts {
			continue
		}
		head := read_head(f.path, 16 * 1024)
		m := parse_headers_only(string(head))
		secs, _ := strconv.parse_i64(strings.split(f.name, ".", context.temp_allocator)[0])
		fa := facts_of(m, self, f.folder, secs)
		for a in c.mine {
			if a != "" && m.from_addr == a {
				fa.from_self = true
			}
		}
		mc.facts[strings.clone(f.unique)] = fa
		if c.yield != nil {
			c.yield()
		}
	}
	for u, fa in mc.facts {
		if u not_in live {
			delete(fa.message_id)
			for r in fa.replies_to {
				delete(r)
			}
			delete(fa.replies_to)
			delete_key(&mc.facts, u)
		}
	}
	answered := make(map[string]bool, allocator = context.temp_allocator)
	for _, fa in mc.facts {
		if fa.from_me {
			for r in fa.replies_to {
				answered[r] = true
			}
		}
	}

	// Pass 2: index what changed.
	for f in files {
		fa := mc.facts[f.unique]
		waiting := !fa.from_me && !fa.from_self && fa.to_me && !fa.machine && f.folder == "" && fa.message_id != "" &&
			fa.message_id not_in answered && c.now - fa.time < WAITING_DAYS * 86400
		id := f.unique
		if sid, ok := sids[f.unique]; ok {
			id = sid
		}
		key := fmt.tprintf("mail:%s", id)
		sig := sig_of(f.folder, f.flags, f.fresh, waiting)
		if !put_if_changed(c, key, sig) {
			continue
		}
		data, err := os.read_entire_file_from_path(f.path, context.temp_allocator)
		if err != nil {
			c.st.errors += 1
			continue
		}
		m := parse_message(string(data))
		flags: ic.Flags
		if f.fresh || !strings.contains(f.flags, "S") {
			flags += {.Unread}
		}
		if strings.contains(f.flags, "F") {
			flags += {.Flagged}
		}
		if len(m.attachments) > 0 {
			flags += {.Attachment}
		}
		if fa.from_me {
			flags += {.Sent}
			flags -= {.Unread}
		}
		if waiting {
			flags += {.Waiting}
		}
		body := m.body
		if len(m.attachments) > 0 {
			body = strings.concatenate({body, "\n", strings.join(m.attachments[:], " ", context.temp_allocator)}, context.temp_allocator)
		}
		who := m.from
		if m.to != "" {
			who = strings.concatenate({m.from, ", ", m.to}, context.temp_allocator)
		}
		mid := m.message_id != "" ? m.message_id : id
		put(c, ic.Doc {
			key = key,
			kind = .Mail,
			flags = flags,
			time = fa.time,
			sig = sig,
			title = m.subject != "" ? m.subject : "(no subject)",
			who = who,
			body = body,
			detail = FOLDER_LABEL(f.folder),
			uri = fmt.tprintf("palm://%s/mail/%s", c.id.handle, mid),
			app = "mail",
		})
	}
	return true
}

// parse_headers_only is parse_message without the body walk.
parse_headers_only :: proc(raw: string) -> Message {
	m: Message
	hs, _ := split_headers(raw)
	from := decode_words(header(hs[:], "from"))
	fname, faddr := split_address(from)
	m.from = fname
	m.from_addr = faddr
	to := decode_words(header(hs[:], "to"))
	cc := decode_words(header(hs[:], "cc"))
	m.to = strings.concatenate({to, ", ", cc}, context.temp_allocator)
	m.date, _ = parse_mail_date(header(hs[:], "date"))
	m.message_id = strings.trim(strings.trim_space(header(hs[:], "message-id")), "<>")
	m.in_reply_to = header(hs[:], "in-reply-to")
	m.references = header(hs[:], "references")
	prec := strings.to_lower(header(hs[:], "precedence"), context.temp_allocator)
	auto := strings.to_lower(header(hs[:], "auto-submitted"), context.temp_allocator)
	m.machine = header(hs[:], "list-id") != "" || header(hs[:], "list-unsubscribe") != "" ||
		prec == "bulk" || prec == "list" || prec == "junk" || (auto != "" && auto != "no") || is_machine_address(faddr)
	return m
}

// ---------------------------------------------------------------------------
// Files: ~/Drive/<handle> and ~/Notes/<handle>
// ---------------------------------------------------------------------------

// Files larger than this are indexed by name only.
MAX_FILE_READ :: 50 * 1024 * 1024

TEXT_EXT := [?]string{".md", ".markdown", ".txt", ".csv", ".tsv", ".org", ".rst", ".log", ".json", ".html", ".htm", ".eml", ".ics", ".vcf"}

ext_of :: proc(name: string) -> string {
	return strings.to_lower(filepath.ext(name), context.temp_allocator)
}

// app_for names the application a file opens in, the same mapping as
// cloud/drive/core/paths.odin's app_for.
app_for :: proc(name: string) -> string {
	switch ext_of(name) {
	case ".docx", ".odt", ".rtf", ".md", ".markdown", ".doc":
		return "docs"
	case ".xlsx", ".ods", ".csv", ".tsv", ".xls":
		return "sheets"
	case ".pptx", ".odp", ".ppt":
		return "slides"
	case ".pdf", ".epub", ".djvu":
		return "reader"
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg":
		return "image"
	case ".mp4", ".mkv", ".webm", ".mov", ".avi":
		return "video"
	case ".mp3", ".flac", ".ogg", ".wav", ".m4a", ".opus":
		return "audio"
	case ".txt", ".log", ".json", ".org", ".rst":
		return "editor"
	}
	return "files"
}

is_document :: proc(name: string) -> bool {
	switch ext_of(name) {
	case ".docx", ".odt", ".rtf", ".doc", ".xlsx", ".ods", ".xls", ".pptx", ".odp", ".ppt", ".md", ".markdown":
		return true
	}
	return false
}

// file_text extracts what is cheap to extract from a file.
file_text :: proc(path, name: string, size: i64) -> string {
	if size > MAX_FILE_READ {
		return ""
	}
	e := ext_of(name)
	if slice.contains(TEXT_EXT[:], e) {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			return ""
		}
		s := string(data[:min(len(data), ic.MAX_BODY * 2)])
		if e == ".html" || e == ".htm" {
			return html_text(to_utf8(s, ""))
		}
		return to_utf8(s, "")
	}
	if k := office_kind(name); k != .None {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			return ""
		}
		t, _ := office_text(data, k)
		return t
	}
	if e == ".pdf" {
		t, _ := pdf_text(path)
		return t
	}
	return ""
}

// note_parts splits a note's text into its front matter id, its title (the
// first non-empty line, # marks stripped) and the rest, the way apps/notes
// reads them.
note_parts :: proc(text: string) -> (id, title, body: string) {
	rest := text
	if strings.has_prefix(rest, "---\n") {
		end := strings.index(rest[4:], "\n---")
		if end >= 0 {
			front := rest[4:4 + end]
			for line in strings.split_lines(front, context.temp_allocator) {
				if strings.has_prefix(line, "id:") {
					id = strings.trim_space(line[3:])
				}
			}
			rest = rest[4 + end + 4:]
		}
	}
	t := rest
	for line in strings.split_lines_iterator(&t) {
		l := strings.trim_space(line)
		if l == "" {
			continue
		}
		title = strings.trim_space(strings.trim_left(l, "#-* "))
		body = t
		return
	}
	return id, title, ""
}

@(private)
scan_tree :: proc(c: ^Ctx, root: string, k: Source_Kind) -> bool {
	if !os.is_dir(root) {
		return true
	}
	c.st.present = true
	walk :: proc(c: ^Ctx, root, dir: string, k: Source_Kind, depth: int) {
		if depth > 24 {
			return
		}
		append(&c.st.dirs, strings.clone(dir))
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			c.st.errors += 1
			return
		}
		for e in entries {
			if strings.has_prefix(e.name, ".") {
				continue // .palm-drive-* temporaries, .palm, .trash, dotfiles
			}
			if e.type == .Directory {
				if k == .Notes && e.name == "attachments" {
					continue
				}
				walk(c, root, e.fullpath, k, depth + 1)
				continue
			}
			if e.type != .Regular {
				continue
			}
			rel := e.fullpath[len(root) + 1:]
			folder := filepath.dir(rel)
			if folder == "." {
				folder = ""
			}
			mt := time.to_unix_seconds(e.modification_time)
			sig := sig_of(e.size, time.to_unix_nanoseconds(e.modification_time))
			if k == .Notes {
				if ext_of(e.name) != ".md" {
					continue
				}
				// The key is the note's front matter id when it has one,
				// which survives a rename; reading it means reading the note,
				// so an unchanged note is found by its path key first.
				pkey := fmt.tprintf("note:%s", rel)
				if old, ok := ic.writer_sig(c.w, pkey); ok && old == sig {
					c.seen[strings.clone(pkey, context.temp_allocator)] = true
					c.st.seen += 1
					c.st.skipped += 1
					continue
				}
				data, rerr := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
				if rerr != nil {
					c.st.errors += 1
					continue
				}
				_, title, body := note_parts(to_utf8(string(data), ""))
				if !put_if_changed(c, pkey, sig) {
					continue
				}
				detail := folder != "" ? folder : "Notes"
				if strings.has_prefix(folder, "Shared/") {
					detail = fmt.tprintf("Shared by %s", folder[len("Shared/"):])
				}
				put(c, ic.Doc {
					key = pkey,
					kind = .Note,
					time = mt,
					sig = sig,
					title = title != "" ? title : strings.trim_suffix(e.name, ".md"),
					body = body,
					detail = detail,
					uri = e.fullpath,
					app = "notes",
				})
				continue
			}
			key := fmt.tprintf("file:%s", rel)
			if !put_if_changed(c, key, sig) {
				continue
			}
			flags: ic.Flags
			at := time.to_unix_seconds(e.access_time)
			if at > mt && c.now - at < 7 * 86400 {
				flags += {.Opened}
			}
			put(c, ic.Doc {
				key = key,
				kind = is_document(e.name) ? .Doc : .File,
				flags = flags,
				time = mt,
				sig = sig,
				title = e.name,
				body = file_text(e.fullpath, e.name, e.size),
				detail = folder != "" ? folder : "Drive",
				uri = e.fullpath,
				app = app_for(e.name),
			})
		}
	}
	walk(c, root, root, k, 0)
	return true
}

// ---------------------------------------------------------------------------
// Calendar, tasks (VTODO) and contacts, from the DAV cache
// ---------------------------------------------------------------------------

// Recurring events are expanded into their instances inside this window,
// re-expanded every day.
RECUR_BACK :: 30 * 86400
RECUR_AHEAD :: 120 * 86400

@(private)
scan_dav :: proc(c: ^Ctx, what: string) -> bool {
	base := fmt.tprintf("%s/%s/%s", c.paths.dav, c.id.handle, what)
	if !os.is_dir(base) {
		return true
	}
	c.st.present = true
	append(&c.st.dirs, strings.clone(base))
	cols, _ := os.read_all_directory_by_path(base, context.temp_allocator)
	day := c.now / 86400
	for col in cols {
		if col.type != .Directory {
			continue
		}
		append(&c.st.dirs, strings.clone(col.fullpath))
		cal_name := col.name
		if st, err := os.read_entire_file_from_path(fmt.tprintf("%s/state", col.fullpath), context.temp_allocator); err == nil {
			t := string(st)
			for line in strings.split_lines_iterator(&t) {
				f := strings.split(line, "\t", context.temp_allocator)
				if len(f) > 2 && f[0] == "meta" && f[2] != "" {
					cal_name = f[2]
				}
			}
		}
		files, _ := os.read_all_directory_by_path(col.fullpath, context.temp_allocator)
		for f in files {
			if f.type != .Regular {
				continue
			}
			sig := sig_of(f.size, time.to_unix_nanoseconds(f.modification_time), day)
			if what == "calendar" && strings.has_suffix(f.name, ".ics") {
				index_ics(c, col.name, cal_name, f.fullpath, f.name, sig)
			} else if what == "addressbook" && strings.has_suffix(f.name, ".vcf") {
				index_vcf(c, col.name, f.fullpath, f.name, sig)
			}
		}
	}
	return true
}

@(private)
index_ics :: proc(c: ^Ctx, seg, cal_name, path, name: string, sig: u64) {
	base_key := fmt.tprintf("event:%s/%s", seg, name)
	// One file holds one object; when its signature is unchanged, every key
	// it produced last time is still right.
	if old, ok := ic.writer_sig(c.w, base_key); ok && old == sig {
		k := strings.clone(base_key, context.temp_allocator)
		c.seen[k] = true
		c.kept[k] = true
		c.st.seen += 1
		c.st.skipped += 1
		return
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		c.st.errors += 1
		return
	}
	cal, _, ok := ical.parse_one(string(data))
	if !ok || cal == nil {
		c.st.errors += 1
		return
	}
	kind := ical.main_kind(cal)
	master, overrides := ical.masters_and_overrides(cal, kind)
	src := master
	if src == nil && len(overrides) > 0 {
		src = overrides[0]
	}
	if src == nil {
		return
	}
	uid := ical.text(src, "UID")
	title := ical.text(src, "SUMMARY")
	place := ical.text(src, "LOCATION")
	desc := ical.text(src, "DESCRIPTION")
	status := strings.to_upper(ical.value(src, "STATUS"), context.temp_allocator)
	people := strings.builder_make(context.temp_allocator)
	if op := ical.prop(src, "ORGANIZER"); op != nil {
		cn := ical.param(op, "CN")
		fmt.sbprintf(&people, "%s %s ", cn, ical.address(op.value, context.temp_allocator))
	}
	for ap in ical.props(src, "ATTENDEE") {
		fmt.sbprintf(&people, "%s %s ", ical.param(ap, "CN"), ical.address(ap.value, context.temp_allocator))
	}
	if kind == "VTODO" {
		t := c.now
		if due, dok := ical.prop_dt(ical.prop(src, "DUE")); dok {
			t = ical.instant(due, cal)
		} else if st, sok := ical.prop_dt(ical.prop(src, "DTSTART")); sok {
			t = ical.instant(st, cal)
		}
		flags: ic.Flags
		if status == "COMPLETED" || status == "CANCELLED" {
			flags += {.Done}
		}
		// Keyed under event: like the events of the same calendar, so the
		// calendar source owns it (track's tasks are task:).
		c.seen[strings.clone(base_key, context.temp_allocator)] = true
		c.st.seen += 1
		put(c, ic.Doc{key = base_key, kind = .Task, flags = flags, time = t, sig = sig, title = title, who = strings.to_string(people), body = desc, detail = cal_name, uri = fmt.tprintf("palm://%s/task/%s", c.id.handle, uid), app = "calendar"})
		return
	}
	if kind != "VEVENT" || status == "CANCELLED" {
		return
	}
	insts, _ := ical.expand(cal, kind, c.now - RECUR_BACK, c.now + RECUR_AHEAD, {limit = 400})
	c.seen[strings.clone(base_key, context.temp_allocator)] = true
	c.st.seen += 1
	if len(insts) == 0 {
		// Outside the window (an old one-off event): still findable.
		st, sok := ical.prop_dt(ical.prop(src, "DTSTART"))
		if !sok {
			return
		}
		t := ical.instant(st, cal)
		put(c, ic.Doc{key = base_key, kind = .Event, time = t, sig = sig, title = title, who = strings.to_string(people), body = desc, detail = place != "" ? place : cal_name, uri = fmt.tprintf("palm://%s/event/%s?start=%d", c.id.handle, uid, t), app = "calendar"})
		return
	}
	for inst, i in insts {
		key := i == 0 ? base_key : fmt.tprintf("%s#%d", base_key, inst.start)
		c.seen[strings.clone(key, context.temp_allocator)] = true
		comp := inst.comp != nil ? inst.comp : src
		t := ical.text(comp, "SUMMARY")
		if t == "" {
			t = title
		}
		pl := ical.text(comp, "LOCATION")
		if pl == "" {
			pl = place
		}
		put(c, ic.Doc {
			key = key,
			kind = .Event,
			time = inst.start,
			dur = i32((inst.end - inst.start) / 60),
			sig = sig,
			title = t,
			who = strings.to_string(people),
			body = desc,
			detail = pl != "" ? pl : cal_name,
			uri = fmt.tprintf("palm://%s/event/%s?start=%d", c.id.handle, uid, inst.start),
			app = "calendar",
		})
	}
}

// vcard_lines unfolds a vCard and returns (name, params, value) per line.
@(private)
index_vcf :: proc(c: ^Ctx, seg, path, name: string, sig: u64) {
	key := fmt.tprintf("person:%s/%s", seg, name)
	if !put_if_changed(c, key, sig) {
		return
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		c.st.errors += 1
		return
	}
	text := repl(string(data), "\r\n ", "")
	text = repl(text, "\n ", "")
	fn, org, title, note, uid := "", "", "", "", ""
	emails := make([dynamic]string, context.temp_allocator)
	phones := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_right(line, "\r")
		colon := strings.index_byte(l, ':')
		if colon < 0 {
			continue
		}
		prop := strings.to_upper(l[:colon], context.temp_allocator)
		if semi := strings.index_byte(prop, ';'); semi >= 0 {
			prop = prop[:semi]
		}
		if dot := strings.index_byte(prop, '.'); dot >= 0 {
			prop = prop[dot + 1:] // item1.EMAIL
		}
		v := repl(l[colon + 1:], "\\,", ",")
		switch prop {
		case "FN":
			fn = v
		case "ORG":
			org = strings.trim(repl(v, ";", " "), " ")
		case "TITLE":
			title = v
		case "NOTE":
			note = repl(v, "\\n", "\n")
		case "UID":
			uid = v
		case "EMAIL":
			append(&emails, v)
		case "TEL":
			append(&phones, v)
		}
	}
	if fn == "" && len(emails) > 0 {
		fn = emails[0]
	}
	detail := title
	if org != "" {
		detail = title != "" ? fmt.tprintf("%s, %s", title, org) : org
	}
	if detail == "" && len(emails) > 0 {
		detail = emails[0]
	}
	put(c, ic.Doc {
		key = key,
		kind = .Person,
		sig = sig,
		title = fn,
		who = strings.concatenate({fn, " ", strings.join(emails[:], " ", context.temp_allocator)}, context.temp_allocator),
		body = strings.concatenate({org, " ", title, " ", strings.join(phones[:], " ", context.temp_allocator), " ", note}, context.temp_allocator),
		detail = detail,
		uri = fmt.tprintf("palm://%s/person/%s", c.id.handle, uid != "" ? uid : name),
		app = "contacts",
	})
}

// ---------------------------------------------------------------------------
// Browser: bookmarks and history
// ---------------------------------------------------------------------------

// HISTORY_INDEXED keeps search to the pages you went back to lately: the
// newest visit of each of the most recent this-many distinct pages.
HISTORY_INDEXED :: 5000

@(private)
scan_browser :: proc(c: ^Ctx) -> bool {
	dir := fmt.tprintf("%s/%s", c.paths.browser, c.id.handle)
	if !os.is_dir(dir) {
		return true
	}
	c.st.present = true
	append(&c.st.dirs, strings.clone(dir))
	if data, err := os.read_entire_file_from_path(fmt.tprintf("%s/bookmarks.json", dir), context.temp_allocator); err == nil {
		B :: struct {
			id:      string,
			kind:    string,
			title:   string,
			url:     string,
			created: i64,
			deleted: bool,
		}
		F :: struct {
			items: []B,
		}
		f: F
		if json.unmarshal(data, &f, allocator = context.temp_allocator) == nil {
			for b in f.items {
				if b.deleted || b.kind != "bookmark" || b.url == "" {
					continue
				}
				key := fmt.tprintf("page:bm:%s", b.id)
				sig := sig_of(b.title, b.url)
				if !put_if_changed(c, key, sig) {
					continue
				}
				put(c, ic.Doc{key = key, kind = .Page, flags = {.Flagged}, time = b.created / 1000, sig = sig, title = b.title != "" ? b.title : b.url, body = b.url, detail = host_of(b.url), uri = b.url, app = "browser"})
			}
		}
	}
	if data, err := os.read_entire_file_from_path(fmt.tprintf("%s/history.jsonl", dir), context.temp_allocator); err == nil {
		V :: struct {
			url:           string,
			title:         string,
			at:            i64,
			forget_before: i64,
			forget_url:    string,
		}
		latest := make(map[string]V, allocator = context.temp_allocator)
		forget_before: i64
		forget := make(map[string]i64, allocator = context.temp_allocator)
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.trim_space(line) == "" {
				continue
			}
			v: V
			if json.unmarshal(transmute([]u8)line, &v, allocator = context.temp_allocator) != nil {
				continue
			}
			if v.forget_before > 0 {
				forget_before = max(forget_before, v.forget_before)
				continue
			}
			if v.forget_url != "" {
				forget[v.forget_url] = max(forget[v.forget_url], v.at)
				continue
			}
			if old, ok := latest[v.url]; !ok || v.at >= old.at {
				if v.title == "" && ok {
					v.title = old.title
				}
				latest[v.url] = v
			}
		}
		// What the person asked the browser to forget, the index forgets.
		list := make([dynamic]V, context.temp_allocator)
		for _, v in latest {
			if v.at <= forget_before {
				continue
			}
			if t, ok := forget[v.url]; ok && v.at <= t {
				continue
			}
			append(&list, v)
		}
		slice.sort_by(list[:], proc(a, b: V) -> bool {return a.at > b.at})
		for v in list[:min(len(list), HISTORY_INDEXED)] {
			key := fmt.tprintf("page:h:%s", v.url)
			sig := sig_of(v.title, v.at)
			if !put_if_changed(c, key, sig) {
				continue
			}
			put(c, ic.Doc{key = key, kind = .Page, time = v.at / 1000, sig = sig, title = v.title != "" ? v.title : v.url, body = v.url, detail = host_of(v.url), uri = v.url, app = "browser"})
		}
	}
	return true
}

host_of :: proc(url: string) -> string {
	u := url
	if i := strings.index(u, "://"); i >= 0 {
		u = u[i + 3:]
	}
	if i := strings.index_byte(u, '/'); i >= 0 {
		u = u[:i]
	}
	return u
}

// ---------------------------------------------------------------------------
// Tasks: track's per-identity issues
// ---------------------------------------------------------------------------

@(private)
scan_tasks :: proc(c: ^Ctx) -> bool {
	dir := fmt.tprintf("%s/%s", c.paths.track, c.id.handle)
	if !os.is_dir(dir) {
		return true
	}
	c.st.present = true
	append(&c.st.dirs, strings.clone(dir))
	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for f in files {
		if f.type != .Regular || ext_of(f.name) != ".md" {
			continue
		}
		key := fmt.tprintf("task:track/%s", f.name)
		sig := sig_of(f.size, time.to_unix_nanoseconds(f.modification_time))
		if !put_if_changed(c, key, sig) {
			continue
		}
		data, err := os.read_entire_file_from_path(f.fullpath, context.temp_allocator)
		if err != nil {
			c.st.errors += 1
			continue
		}
		text := to_utf8(string(data), "")
		id, title, state, project, assignee, body := "", "", "", "", "", text
		if strings.has_prefix(text, "---\n") {
			if end := strings.index(text[4:], "\n---"); end >= 0 {
				for line in strings.split_lines(text[4:4 + end], context.temp_allocator) {
					colon := strings.index_byte(line, ':')
					if colon < 0 {
						continue
					}
					k, v := strings.trim_space(line[:colon]), strings.trim_space(line[colon + 1:])
					switch k {
					case "id":
						id = v
					case "title":
						title = v
					case "state":
						state = v
					case "project":
						project = v
					case "assignee":
						assignee = v
					}
				}
				body = text[4 + end + 4:]
			}
		}
		flags: ic.Flags
		switch strings.to_lower(state, context.temp_allocator) {
		case "done", "closed", "wontfix", "cancelled":
			flags += {.Done}
		}
		detail := project != "" ? fmt.tprintf("%s · %s", project, state) : state
		put(c, ic.Doc {
			key = key,
			kind = .Task,
			flags = flags,
			time = time.to_unix_seconds(f.modification_time),
			sig = sig,
			title = title != "" ? fmt.tprintf("%s %s", id, title) : f.name,
			who = assignee,
			body = body,
			detail = detail,
			uri = fmt.tprintf("palm://%s/task/track/%s", c.id.handle, id != "" ? id : f.name),
			app = "track",
		})
	}
	return true
}

@(private)
_unused :: proc() {
	_ = utf8.valid_string
}

@(private)
repl :: proc(s, old, new: string) -> string {
	r, _ := strings.replace_all(s, old, new, context.temp_allocator)
	return r
}
