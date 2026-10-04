package main

// The history store and the watcher thread.
//
// palmy is a Wayland client that does not implement `wl_data_device`, so the
// selection is read through wl-clipboard. `wl-paste --list-types` is asked
// first, because the answer decides three things: whether this is an image or
// text, which mime type to request, and — the part that matters most — whether
// the owner has flagged the selection as a secret.
//
// Everything in here runs on a worker thread and is read by the frame under
// `mu`. The frame never shells out.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import p "palmy:."

// HISTORY_CAP is the number of entries kept. Pinned entries are never evicted;
// the oldest unpinned one goes when the cap is reached.
HISTORY_CAP :: 200

// Text longer than this is stored truncated. A clipboard history is not a
// place to keep a 40MB paste, and the row only ever shows a line of it.
TEXT_CAP :: 64 * 1024

// How often the selection is sampled.
POLL_SECONDS :: 0.7

// Thumbnails are generated once, at this size, and the full image stays on
// disk. 200 full-size screenshots in memory is not a clipboard manager.
THUMB_MAX_W :: 132
THUMB_MAX_H :: 84

Kind :: enum u8 {
	Text,
	Image,
}

Entry :: struct {
	id:        u64, // FNV-1a of the payload; this is what de-duplicates
	kind:      Kind,
	text:      string, // the payload, for Text
	preview:   string, // one line, for the row
	lower:     string, // preview lowercased, for search
	mime:      string,
	size:      int,
	w, h:      int,    // image dimensions
	when_:     i64,    // unix seconds
	pinned:    bool,
	blob:      string, // absolute path, for Image
	thumb:     p.Image,
	has_thumb: bool,
	truncated: bool,
}

Store :: struct {
	mu:       sync.Mutex,
	items:    [dynamic]Entry,

	// Entries removed by either thread go here instead of being freed, and the
	// frame frees them at the top of its next pass. palmy paints the tree it
	// built on the *previous* iteration, and an image node holds the pixel
	// slice by reference — so freeing a thumbnail the instant the watcher
	// evicts it would pull it out from under a frame that is still on screen.
	graveyard: [dynamic]Entry,

	// Atomics, so the frame can read them without taking the lock.
	enabled:  bool, // monitoring on
	stop:     bool,
	captured: int,  // total captures since launch
	secrets:  int,  // selections skipped because they were flagged sensitive

	// Worker-only.
	last_id:  u64,
	status:   string, // last watcher message, guarded by mu
	have_wl:  bool,
}

g: Store

// ---------------------------------------------------------------------------
// Paths
//
//   ~/.local/share/palmy-clipboard/          0700
//   ~/.local/share/palmy-clipboard/history   0600
//   ~/.local/share/palmy-clipboard/blobs/    0700
//   ~/.local/share/palmy-clipboard/blobs/*   0600
// ---------------------------------------------------------------------------

data_dir :: proc(al := context.temp_allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return fmt.aprintf("%s/.local/share/palmy-clipboard", home, allocator = al)
}

blob_dir :: proc(al := context.temp_allocator) -> string {
	d := data_dir(context.temp_allocator)
	if d == "" {
		return ""
	}
	return fmt.aprintf("%s/blobs", d, allocator = al)
}

ensure_dirs :: proc() {
	d := data_dir()
	if d == "" {
		return
	}
	_ = os.make_directory_all(d)
	_ = os.chmod(d, os.perm_number(0o700))
	b := blob_dir()
	_ = os.make_directory_all(b)
	_ = os.chmod(b, os.perm_number(0o700))
}

// ---------------------------------------------------------------------------
// Hashing and small helpers
// ---------------------------------------------------------------------------

fnv :: proc(data: []u8) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in data {
		h ~= u64(b)
		h *= 0x100000001b3
	}
	if h == 0 {
		h = 1
	}
	return h
}

now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// exec_raw runs a command and returns stdout untouched. kit.run trims, which
// would quietly corrupt a clipboard entry that is meant to have leading
// whitespace — an indented code block, most obviously.
exec_raw :: proc(argv: []string) -> (out: []u8, ok: bool) {
	state, sout, serr, err := os.process_exec({command = argv}, context.allocator)
	if err != nil {
		return nil, false
	}
	delete(serr)
	if state.exit_code != 0 {
		delete(sout)
		return nil, false
	}
	return sout, true
}

exec_text :: proc(argv: []string, al := context.temp_allocator) -> (string, bool) {
	out, ok := exec_raw(argv)
	if !ok {
		return "", false
	}
	defer delete(out)
	return strings.clone(string(out), al), true
}

// ---------------------------------------------------------------------------
// Sensitivity
// ---------------------------------------------------------------------------

// SECRET_HINTS are the mime types password managers advertise to ask clipboard
// managers not to record a selection. KDE's is the de-facto standard and
// Bitwarden, KeePassXC and 1Password all set one of these.
SECRET_HINTS := [?]string {
	"x-kde-passwordmanagerhint",
	"password",
	"secret",
	"sensitive",
	"concealed",
	"x-nextcloud-passwords",
}

// is_sensitive decides from the advertised type list alone. The content is
// never read when this returns true, so a password never reaches this process
// at all.
is_sensitive :: proc(types: string) -> (bool, string) {
	low := strings.to_lower(types, context.temp_allocator)
	for hint in SECRET_HINTS {
		if strings.contains(low, hint) {
			return true, hint
		}
	}
	return false, ""
}

// pick_type chooses what to ask for. Images first, because a screenshot on the
// clipboard also offers a `text/html` wrapper on some apps and the picture is
// the thing worth keeping.
pick_type :: proc(types: string) -> (mime: string, kind: Kind, ok: bool) {
	lines := strings.split_lines(types, context.temp_allocator)
	want_img := [?]string{"image/png", "image/jpeg", "image/webp", "image/bmp", "image/gif"}
	for w in want_img {
		for l in lines {
			if strings.trim_space(l) == w {
				return w, .Image, true
			}
		}
	}
	want_txt := [?]string {
		"text/plain;charset=utf-8",
		"text/plain",
		"UTF8_STRING",
		"STRING",
		"TEXT",
	}
	for w in want_txt {
		for l in lines {
			if strings.trim_space(l) == w {
				return w, .Text, true
			}
		}
	}
	// Anything else that is text-ish; otherwise give up rather than store a
	// blob of an unknown binary format.
	for l in lines {
		t := strings.trim_space(l)
		if strings.has_prefix(t, "text/") {
			return t, .Text, true
		}
	}
	return "", .Text, false
}

// ---------------------------------------------------------------------------
// The watcher
// ---------------------------------------------------------------------------

watcher_start :: proc() {
	sync.atomic_store(&g.enabled, true)
	thread.create_and_start(watcher, self_cleanup = true)
}

watcher_stop :: proc() {
	sync.atomic_store(&g.stop, true)
}

@(private = "file")
watcher :: proc() {
	for !sync.atomic_load(&g.stop) {
		if sync.atomic_load(&g.enabled) {
			poll_once()
			free_all(context.temp_allocator)
		}
		time.sleep(time.Duration(POLL_SECONDS * f64(time.Second)))
	}
}

@(private = "file")
poll_once :: proc() {
	types, ok := exec_text({"wl-paste", "--list-types"}, context.temp_allocator)
	if !ok || strings.trim_space(types) == "" {
		return
	}

	if secret, hint := is_sensitive(types); secret {
		// Keyed on the advertised type list, not the content, which is never
		// read: that is the whole point. Remembering it also stops the counter
		// climbing once a second while the same password sits on the clipboard.
		id := fnv(transmute([]u8)types)
		if id != g.last_id {
			sync.atomic_add(&g.secrets, 1)
			set_status(fmt.tprintf("skipped a selection flagged %s", hint))
		}
		g.last_id = id
		return
	}

	mime, kind, good := pick_type(types)
	if !good {
		return
	}

	switch kind {
	case .Text:
		capture_text(mime)
	case .Image:
		capture_image(mime)
	}
}

@(private = "file")
capture_text :: proc(mime: string) {
	raw, ok := exec_raw({"wl-paste", "--no-newline", "--type", mime})
	if !ok {
		return
	}
	defer delete(raw)
	if len(raw) == 0 || len(strings.trim_space(string(raw))) == 0 {
		return
	}

	id := fnv(raw)
	if id == g.last_id {
		return
	}
	g.last_id = id

	body := raw
	truncated := false
	if len(body) > TEXT_CAP {
		body = body[:TEXT_CAP]
		truncated = true
	}

	e := Entry {
		id        = id,
		kind      = .Text,
		text      = strings.clone(string(body)),
		mime      = strings.clone(mime),
		size      = len(raw),
		when_     = now_unix(),
		truncated = truncated,
	}
	e.preview = make_preview(e.text)
	e.lower = strings.to_lower(e.text[:min(len(e.text), 4096)])
	push(e)
}

@(private = "file")
capture_image :: proc(mime: string) {
	tmp := fmt.tprintf("%s/.incoming", blob_dir(context.temp_allocator))
	if tmp == "/.incoming" {
		return
	}
	// The payload is binary, so it goes to a file rather than through a string.
	cmd := fmt.tprintf("wl-paste --no-newline --type %s > '%s'", mime, tmp)
	if _, ok := exec_text({"sh", "-c", cmd}, context.temp_allocator); !ok {
		return
	}
	data, err := os.read_entire_file_from_path(tmp, context.allocator)
	if err != nil || len(data) == 0 {
		if err == nil {delete(data)}
		return
	}
	defer delete(data)

	id := fnv(data)
	if id == g.last_id {
		_ = os.remove(tmp)
		return
	}
	g.last_id = id

	ext := ".png"
	switch mime {
	case "image/jpeg":
		ext = ".jpg"
	case "image/webp":
		ext = ".webp"
	case "image/bmp":
		ext = ".bmp"
	case "image/gif":
		ext = ".gif"
	}
	blob := fmt.aprintf("%s/%016x%s", blob_dir(context.temp_allocator), id, ext)
	if os.write_entire_file(blob, data, os.perm_number(0o600)) != nil {
		delete(blob)
		_ = os.remove(tmp)
		return
	}
	_ = os.chmod(blob, os.perm_number(0o600))
	_ = os.remove(tmp)

	e := Entry {
		kind  = .Image,
		id    = id,
		mime  = strings.clone(mime),
		size  = len(data),
		when_ = now_unix(),
		blob  = blob,
	}
	full, decoded := p.decode_image(data)
	if decoded {
		e.w, e.h = full.w, full.h
		e.thumb = shrink(full, THUMB_MAX_W, THUMB_MAX_H)
		e.has_thumb = true
		p.image_destroy(&full)
	}
	e.preview = fmt.aprintf("%s · %d × %d", mime, e.w, e.h)
	e.lower = strings.to_lower(e.preview)
	push(e)
}

// shrink box-filters an image down to a thumbnail. Bilinear sampling at a large
// reduction aliases badly — a screenshot of text turns into noise — so every
// source pixel that lands in a destination cell is averaged.
shrink :: proc(src: p.Image, max_w, max_h: int) -> p.Image {
	if src.w <= 0 || src.h <= 0 {
		return {}
	}
	s := min(f32(max_w) / f32(src.w), f32(max_h) / f32(src.h), 1)
	dw := max(1, int(f32(src.w) * s))
	dh := max(1, int(f32(src.h) * s))

	out := p.Image {
		px              = make([]u32, dw * dh),
		w               = dw,
		h               = dh,
		source_channels = src.source_channels,
	}
	for y in 0 ..< dh {
		y0 := y * src.h / dh
		y1 := max(y0 + 1, (y + 1) * src.h / dh)
		for x in 0 ..< dw {
			x0 := x * src.w / dw
			x1 := max(x0 + 1, (x + 1) * src.w / dw)
			ar, ag, ab, aa, n: u32
			for sy in y0 ..< y1 {
				row := src.px[sy * src.w:]
				for sx in x0 ..< x1 {
					v := row[sx]
					aa += (v >> 24) & 0xff
					ar += (v >> 16) & 0xff
					ag += (v >> 8) & 0xff
					ab += v & 0xff
					n += 1
				}
			}
			if n == 0 {n = 1}
			out.px[y * dw + x] = ((aa / n) << 24) | ((ar / n) << 16) | ((ag / n) << 8) | (ab / n)
		}
	}
	return out
}

// make_preview collapses the payload to the one line a row can show.
make_preview :: proc(s: string, al := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	space := true // swallow leading whitespace
	for i in 0 ..< len(s) {
		if n >= 200 {
			break
		}
		c := s[i]
		if c == '\n' || c == '\r' || c == '\t' || c == ' ' {
			if space {
				continue
			}
			space = true
			strings.write_byte(&b, ' ')
			n += 1
			continue
		}
		space = false
		strings.write_byte(&b, c)
		n += 1
	}
	out := strings.trim_space(strings.to_string(b))
	if out == "" {
		out = "(whitespace)"
	}
	return strings.clone(out, al)
}

// push inserts a capture at the top, folding a repeat of something already in
// the history back to the top instead of duplicating it.
push :: proc(e_in: Entry) {
	e := e_in
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)

	for &old, i in g.items {
		if old.id == e.id {
			old.when_ = e.when_
			moved := old
			ordered_remove(&g.items, i)
			inject_at(&g.items, 0, moved)
			retire(&e)
			sync.atomic_add(&g.captured, 1)
			save_locked()
			return
		}
	}

	inject_at(&g.items, 0, e)
	sync.atomic_add(&g.captured, 1)
	evict_locked()
	save_locked()
}

// evict_locked drops the oldest unpinned entry once the cap is reached. Pins
// are a promise, so they survive the cap.
evict_locked :: proc() {
	for len(g.items) > HISTORY_CAP {
		victim := -1
		for i := len(g.items) - 1; i >= 0; i -= 1 {
			if !g.items[i].pinned {
				victim = i
				break
			}
		}
		if victim < 0 {
			break // everything is pinned; keep it all rather than break a promise
		}
		drop_entry(victim)
	}
}

drop_entry :: proc(i: int) {
	if i < 0 || i >= len(g.items) {
		return
	}
	e := &g.items[i]
	if e.kind == .Image && e.blob != "" {
		_ = os.remove(e.blob)
	}
	retire(e)
	ordered_remove(&g.items, i)
}

// retire hands an entry to the graveyard. Nothing it owns is released here.
retire :: proc(e: ^Entry) {
	append(&g.graveyard, e^)
	e^ = {}
}

// reap_locked releases everything retired since the last frame. The caller is
// the frame thread, holding `mu`, before it builds anything.
reap_locked :: proc() {
	for &e in g.graveyard {
		free_entry(&e)
	}
	clear(&g.graveyard)
}

free_entry :: proc(e: ^Entry) {
	delete(e.text)
	delete(e.preview)
	delete(e.lower)
	delete(e.mime)
	delete(e.blob)
	if e.has_thumb {
		p.image_destroy(&e.thumb)
	}
	e^ = {}
}

set_status :: proc(msg: string) {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	if g.status != "" {
		delete(g.status)
	}
	g.status = strings.clone(msg)
}

// ---------------------------------------------------------------------------
// Persistence
//
// One record per line, tab separated, so the file can be read with `cut` when
// something goes wrong. Text payloads are escaped; image payloads are a file
// name under blobs/.
// ---------------------------------------------------------------------------

HISTORY_HEADER :: "# palmy-clipboard history v1 — this file records what you copied. Mode 0600."

escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_byte(b, s[i])
		}
	}
}

unescape :: proc(s: string, al := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case '\\':
				strings.write_byte(&b, '\\')
			case:
				strings.write_byte(&b, s[i + 1])
			}
			i += 2
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.clone(strings.to_string(b), al)
}

save_locked :: proc() {
	dir := data_dir()
	if dir == "" {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, HISTORY_HEADER)
	strings.write_byte(&b, '\n')
	for e in g.items {
		if e.kind == .Text {
			fmt.sbprintf(&b, "T\t%d\t%d\t%s\t%d\t", e.when_, e.pinned ? 1 : 0, e.mime, e.size)
			escape(&b, e.text)
		} else {
			name := e.blob
			if slash := strings.last_index_byte(name, '/'); slash >= 0 {
				name = name[slash + 1:]
			}
			fmt.sbprintf(
				&b,
				"I\t%d\t%d\t%s\t%d\t%s\t%d\t%d",
				e.when_,
				e.pinned ? 1 : 0,
				e.mime,
				e.size,
				name,
				e.w,
				e.h,
			)
		}
		strings.write_byte(&b, '\n')
	}

	path := fmt.tprintf("%s/history", dir)
	// 0600 on creation and again afterwards: `open` masks the mode with the
	// process umask, and a clipboard log must not be group or world readable
	// whatever the umask happens to be.
	if os.write_entire_file(path, transmute([]u8)strings.to_string(b), os.perm_number(0o600)) !=
	   nil {
		return
	}
	_ = os.chmod(path, os.perm_number(0o600))
}

load :: proc() {
	dir := data_dir()
	if dir == "" {
		return
	}
	path := fmt.tprintf("%s/history", dir)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}

	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)

	images := 0
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 5 {
			continue
		}
		when_, _ := parse_i64(f[1])
		pinned := f[2] == "1"
		mime := f[3]
		size, _ := parse_i64(f[4])

		if f[0] == "T" && len(f) >= 6 {
			text := unescape(f[5])
			e := Entry {
				id      = fnv(transmute([]u8)text),
				kind    = .Text,
				text    = text,
				mime    = strings.clone(mime),
				size    = int(size),
				when_   = when_,
				pinned  = pinned,
				preview = make_preview(text),
			}
			e.lower = strings.to_lower(text[:min(len(text), 4096)])
			append(&g.items, e)
		} else if f[0] == "I" && len(f) >= 8 {
			w, _ := parse_i64(f[6])
			h, _ := parse_i64(f[7])
			blob := fmt.aprintf("%s/blobs/%s", dir, f[5])
			if !os.exists(blob) {
				delete(blob)
				continue
			}
			e := Entry {
				id     = 0,
				kind   = .Image,
				mime   = strings.clone(mime),
				size   = int(size),
				when_  = when_,
				pinned = pinned,
				blob   = blob,
				w      = int(w),
				h      = int(h),
			}
			// Thumbnails cost a decode each, so only the newest handful are
			// rebuilt at startup; the rest show a placeholder until they are
			// re-copied.
			if images < 24 {
				if full, ok := p.load_image(blob); ok {
					e.thumb = shrink(full, THUMB_MAX_W, THUMB_MAX_H)
					e.has_thumb = true
					if e.w == 0 {e.w, e.h = full.w, full.h}
					p.image_destroy(&full)
				}
			}
			images += 1
			e.preview = fmt.aprintf("%s · %d × %d", mime, e.w, e.h)
			e.lower = strings.to_lower(e.preview)
			if raw, rerr := os.read_entire_file_from_path(blob, context.temp_allocator);
			   rerr == nil {
				e.id = fnv(raw)
			}
			append(&g.items, e)
		}
	}
	if len(g.items) > 0 {
		g.last_id = g.items[0].id
	}
}

parse_i64 :: proc(s: string) -> (i64, bool) {
	v: i64
	neg := false
	t := strings.trim_space(s)
	if t == "" {
		return 0, false
	}
	i := 0
	if t[0] == '-' {neg = true; i = 1}
	for ; i < len(t); i += 1 {
		if t[i] < '0' || t[i] > '9' {
			return 0, false
		}
		v = v * 10 + i64(t[i] - '0')
	}
	return neg ? -v : v, true
}

// clear_all_locked wipes the history and every blob on disk. This is the escape
// hatch a clipboard log needs to have. The caller already holds `mu`: the frame
// holds it for its whole duration, and `sync.Mutex` is not reentrant.
clear_all_locked :: proc() -> int {
	n := len(g.items)
	for i := len(g.items) - 1; i >= 0; i -= 1 {
		drop_entry(i)
	}
	g.last_id = 0
	save_locked()
	return n
}

set_status_locked :: proc(msg: string) {
	if g.status != "" {
		delete(g.status)
	}
	g.status = strings.clone(msg)
}
