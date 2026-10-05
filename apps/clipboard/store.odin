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
import "core:slice"
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
	// A secret's hash is taken over the advertised TYPE LIST, because the
	// content is never read. It lives in its own field: writing it into
	// `last_id` meant a type list could collide with a payload and suppress a
	// real capture, and meant the first selection after a password always
	// looked new whether it was or not.
	last_secret_id: u64,
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
//
// THE RACE, AND WHY SAMPLING CANNOT WIN IT
//
// This used to be a thread that woke every 0.7 s, asked the compositor what
// was on the clipboard, and stored it if it had changed. That loses entries,
// and not occasionally: a clipboard is a single-slot register with no queue
// and no history of its own. Copy A at t=0.10 and B at t=0.35 and the sample
// at t=0.70 sees only B — A was overwritten before this process ever asked.
// Nothing in the old code "dropped" A; A simply never existed here.
//
// No poll interval fixes that. Shortening it narrows the window and spends a
// subprocess per tick doing it, and the window never closes, because the
// question "what is on the clipboard *now*" cannot answer "what was on it
// in between".
//
// So the capture is event-driven. `wl-paste --watch` is run once, as a
// long-lived child, and the compositor runs its command on every selection
// change — handing that command the content of THAT selection on stdin. One
// event, one set of bytes, no sampling. The command writes the bytes and the
// advertised type list into a spool directory and the watcher thread drains
// it. The thread's cadence now decides only how fast an entry appears, not
// whether it exists, which is the whole difference.
//
// `spool_drain` and `ingest_selection` are what the selftest drives, with the
// spool written by a fake in place of wl-paste. The reproduction is in
// `selftest.odin` under "the poll race": two selections inside one poll
// interval, sampled and then evented, with the first one missing in the
// first case and present in the second.
//
// WHAT IS STILL NOT CLOSED, AND CANNOT BE FROM HERE
//
// The type list and the bytes still come from two different calls. wl-paste
// gives a command its content on stdin but does not tell it what the offer
// advertised, so the spool command asks `wl-paste --list-types` separately.
// If the selection changes between the two, the verdict (including the
// `is_sensitive` gate) describes one selection and the bytes another. Closing
// that needs the offer itself — `wl_data_device` in palmy — which this
// application cannot add. It is reported rather than worked around.
//
// THE SPOOL AND PRIVACY
//
// The spool holds real clipboard content on disk for as long as it takes the
// thread to notice it. It is created under the application's own 0700 data
// directory, the writing shell runs under `umask 077`, every record is
// removed the moment it is ingested, and the whole directory is emptied on
// start and on stop. Nothing in here is ever logged.
// ---------------------------------------------------------------------------

// The fallback cadence, used only when `wl-paste --watch` could not be
// started. It is the old behaviour, race and all, and it is the reason the
// constant is still here.
POLL_SECONDS :: 0.7

// The event cadence. This is a `readdir` of a directory that is almost always
// empty, not a subprocess, so it can be fast without costing anything — and
// it is latency only: an event that has not been drained yet is not an event
// that was lost.
SPOOL_POLL_SECONDS :: 0.05

// Sel_Source is where a sampled observation comes from. Production reads
// wl-clipboard; the selftest swaps in a fake so the race can be reproduced
// with no compositor and no real clipboard anywhere near it. It mirrors
// `g_test`/`g_test_clip` on the write side.
Sel_Source :: struct {
	list_types: proc() -> (string, bool),
	read:       proc(mime: string) -> ([]u8, bool),
}

wl_list_types :: proc() -> (string, bool) {
	return exec_text({"wl-paste", "--list-types"}, context.temp_allocator)
}

// wl_read returns the bytes untouched, which is why it is `exec_raw` and not
// `exec_text`: an image is binary and a code block has leading whitespace that
// matters.
wl_read :: proc(mime: string) -> ([]u8, bool) {
	return exec_raw({"wl-paste", "--no-newline", "--type", mime})
}

g_source := Sel_Source {
	list_types = wl_list_types,
	read       = wl_read,
}

// Ingest says what happened to one observation, so a caller — and a test —
// can tell "already had it" from "refused it" from "never saw it".
Ingest :: enum u8 {
	Stored,
	Duplicate,
	Secret,
	Unusable,
	Failed,
}

// ---------------------------------------------------------------------------
// Ingest: the whole decision, as a function of what was observed
// ---------------------------------------------------------------------------

// ingest_selection takes one complete observation — the advertised type list
// and the bytes that came with it — and decides what to do with it.
//
// There is no subprocess, no clock and no socket in here. That is deliberate:
// it is what lets the selftest hand it two selections in a row and assert
// that both land, which is exactly what the sampled path could not do.
ingest_selection :: proc(types: string, payload: []u8) -> Ingest {
	if strings.trim_space(types) == "" {
		return .Unusable
	}
	if secret, hint := is_sensitive(types); secret {
		// Keyed on the advertised type list, not the content, which is never
		// read: that is the whole point. Remembering it also stops the counter
		// climbing once a tick while the same password sits on the clipboard.
		id := fnv(transmute([]u8)types)
		if id != g.last_secret_id {
			sync.atomic_add(&g.secrets, 1)
			set_status(fmt.tprintf("skipped a selection flagged %s", hint))
		}
		g.last_secret_id = id
		return .Secret
	}
	mime, kind, good := pick_type(types)
	if !good {
		return .Unusable
	}
	switch kind {
	case .Text:
		return store_text(mime, payload)
	case .Image:
		return store_image(mime, payload)
	}
	return .Unusable
}

store_text :: proc(mime: string, raw: []u8) -> Ingest {
	if len(raw) == 0 || len(strings.trim_space(string(raw))) == 0 {
		return .Unusable
	}

	id := fnv(raw)
	if id == g.last_id {
		return .Duplicate
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
	return .Stored
}

store_image :: proc(mime: string, data: []u8) -> Ingest {
	if len(data) == 0 {
		return .Unusable
	}
	id := fnv(data)
	if id == g.last_id {
		return .Duplicate
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
	dir := blob_dir(context.temp_allocator)
	if dir == "" {
		return .Failed
	}
	blob := fmt.aprintf("%s/%016x%s", dir, id, ext)
	if os.write_entire_file(blob, data, os.perm_number(0o600)) != nil {
		delete(blob)
		return .Failed
	}
	_ = os.chmod(blob, os.perm_number(0o600))

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
	return .Stored
}

// ---------------------------------------------------------------------------
// The sampled path — kept as the fallback, and as the thing being measured
// against
// ---------------------------------------------------------------------------

// sample_once asks what is on the clipboard NOW. It is the old behaviour and
// it is still what runs when `wl-paste --watch` is unavailable; a narrow
// window is better than no clipboard history. It is also what the
// reproduction drives, so the race has something to be a race against.
sample_once :: proc() -> Ingest {
	types, ok := g_source.list_types()
	if !ok {
		return .Failed
	}
	if strings.trim_space(types) == "" {
		return .Unusable
	}
	if secret, _ := is_sensitive(types); secret {
		// The content is never asked for.
		return ingest_selection(types, nil)
	}
	mime, _, good := pick_type(types)
	if !good {
		return .Unusable
	}
	payload, pok := g_source.read(mime)
	if !pok {
		return .Failed
	}
	defer delete(payload)
	return ingest_selection(types, payload)
}

// ---------------------------------------------------------------------------
// The spool: one record per selection, written at event time
// ---------------------------------------------------------------------------

// A record is two files, `<stamp>.types` and `<stamp>.blob`. The `.blob` is
// written as `.part` and renamed, so its appearance is the commit: a drain
// that runs while the writer is mid-write sees nothing rather than half a
// selection. `<stamp>` is nanoseconds since the epoch, which is both unique
// and sortable, and sortable matters — two copies in the same second must
// still come back in the order they were made.
SPOOL_SUFFIX_BLOB :: ".blob"
SPOOL_SUFFIX_TYPES :: ".types"
SPOOL_SUFFIX_PART :: ".part"

spool_dir :: proc(al := context.temp_allocator) -> string {
	d := data_dir(context.temp_allocator)
	if d == "" {
		return ""
	}
	return fmt.aprintf("%s/spool", d, allocator = al)
}

spool_ensure :: proc() -> string {
	d := spool_dir(context.temp_allocator)
	if d == "" {
		return ""
	}
	_ = os.make_directory_all(d)
	_ = os.chmod(d, os.perm_number(0o700))
	return d
}

// spool_clear empties the directory. Called on start, so a crash cannot leave
// yesterday's clipboard lying around, and on stop, so a clean exit does not
// either.
spool_clear :: proc() {
	d := spool_dir(context.temp_allocator)
	if d == "" {
		return
	}
	infos, err := os.read_directory_by_path(d, -1, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		if info.type != .Regular {
			continue
		}
		_ = os.remove(fmt.tprintf("%s/%s", d, info.name))
	}
}

// spool_write is the record format, written from Odin. The `--watch` child
// writes exactly these two files from the shell; this is the same thing, and
// it is what the selftest uses to stand in for a compositor.
spool_write :: proc(stamp: string, types: string, payload: []u8) -> bool {
	d := spool_ensure()
	if d == "" {
		return false
	}
	tp := fmt.tprintf("%s/%s%s", d, stamp, SPOOL_SUFFIX_TYPES)
	if os.write_entire_file(tp, transmute([]u8)types, os.perm_number(0o600)) != nil {
		return false
	}
	_ = os.chmod(tp, os.perm_number(0o600))
	part := fmt.tprintf("%s/%s%s", d, stamp, SPOOL_SUFFIX_PART)
	if os.write_entire_file(part, payload, os.perm_number(0o600)) != nil {
		return false
	}
	_ = os.chmod(part, os.perm_number(0o600))
	// The rename is the commit.
	return os.rename(part, fmt.tprintf("%s/%s%s", d, stamp, SPOOL_SUFFIX_BLOB)) == nil
}

// spool_drain ingests every committed record, oldest first, and removes each
// one as it goes. It returns how many were stored.
spool_drain :: proc() -> (stored: int, seen: int) {
	d := spool_dir(context.temp_allocator)
	if d == "" {
		return 0, 0
	}
	infos, err := os.read_directory_by_path(d, -1, context.temp_allocator)
	if err != nil {
		return 0, 0
	}
	stamps := make([dynamic]string, 0, 8, context.temp_allocator)
	for info in infos {
		if info.type != .Regular || !strings.has_suffix(info.name, SPOOL_SUFFIX_BLOB) {
			continue
		}
		append(&stamps, info.name[:len(info.name) - len(SPOOL_SUFFIX_BLOB)])
	}
	// Oldest first. The stamps are fixed-width nanosecond counts, so sorting
	// them as strings is sorting them in time.
	slice.sort(stamps[:])
	for st in stamps {
		seen += 1
		types_path := fmt.tprintf("%s/%s%s", d, st, SPOOL_SUFFIX_TYPES)
		blob_path := fmt.tprintf("%s/%s%s", d, st, SPOOL_SUFFIX_BLOB)
		types, terr := os.read_entire_file_from_path(types_path, context.temp_allocator)
		payload, perr := os.read_entire_file_from_path(blob_path, context.temp_allocator)
		if perr == nil && terr == nil {
			if ingest_selection(string(types), payload) == .Stored {
				stored += 1
			}
		}
		_ = os.remove(types_path)
		_ = os.remove(blob_path)
	}
	return stored, seen
}

// ---------------------------------------------------------------------------
// The `wl-paste --watch` child
// ---------------------------------------------------------------------------

@(private = "file")
g_watch_proc: os.Process
@(private = "file")
g_watch_live: bool

// SPOOL_SH is the command `wl-paste --watch` runs on every selection change.
//
//   umask 077   — the shell creates the files, not us, so the mode has to be
//                 set before the redirect rather than chmodded after it
//   cat         — FIRST, because wl-paste is writing into a pipe and will
//                 block once it fills; asking it anything before draining
//                 that pipe deadlocks on a selection bigger than 64 KB
//   list-types  — a second wl-paste, which is the seam that is still not
//                 atomic; see the note at the top of this section
//   mv          — the commit
SPOOL_SH ::
	`umask 077; n=$(date +%s%N); cat > "$D/$n.part"; wl-paste --list-types > "$D/$n.types" 2>/dev/null; mv "$D/$n.part" "$D/$n.blob"`

watch_start :: proc() -> bool {
	d := spool_ensure()
	if d == "" {
		return false
	}
	spool_clear()
	script := fmt.tprintf("D=%q; %s", d, SPOOL_SH)
	pr, err := os.process_start(
		os.Process_Desc{command = {"wl-paste", "--watch", "sh", "-c", script}},
	)
	if err != nil {
		return false
	}
	g_watch_proc = pr
	sync.atomic_store(&g_watch_live, true)
	return true
}

// watch_stop is called from two places — the watcher thread's own `defer` and
// `watcher_stop` on the way out of `main` — so it has to be safe to run twice
// and from either thread. The compare-and-swap is what makes it so.
//
// It is called from `main` as well as from the thread deliberately: the thread
// notices `g.stop` only on its next tick, and a clipboard manager that leaves
// an orphaned `wl-paste --watch` behind leaves something writing the user's
// selections into a spool directory with nobody draining it.
watch_stop :: proc() {
	if _, had := sync.atomic_compare_exchange_strong(&g_watch_live, true, false); had {
		_ = os.process_kill(g_watch_proc)
		_, _ = os.process_wait(g_watch_proc)
	}
	spool_clear()
}

// ---------------------------------------------------------------------------
// The thread
// ---------------------------------------------------------------------------

watcher_start :: proc() {
	sync.atomic_store(&g.enabled, true)
	thread.create_and_start(watcher, self_cleanup = true)
}

watcher_stop :: proc() {
	sync.atomic_store(&g.stop, true)
	// Not left to the thread: see `watch_stop`.
	watch_stop()
}

@(private = "file")
watcher :: proc() {
	evented := watch_start()
	defer watch_stop()
	if evented {
		set_status("watching the selection (event-driven)")
	} else {
		set_status("sampling the selection every 0.7s — wl-paste --watch is unavailable")
	}
	// `--watch` fires on the NEXT change, so whatever is already on the
	// clipboard when the window opens would otherwise be invisible until
	// something else is copied.
	sample_once()
	free_all(context.temp_allocator)

	period := evented ? SPOOL_POLL_SECONDS : POLL_SECONDS
	for !sync.atomic_load(&g.stop) {
		if sync.atomic_load(&g.enabled) {
			if evented {
				spool_drain()
			} else {
				sample_once()
			}
			free_all(context.temp_allocator)
		}
		time.sleep(time.Duration(period * f64(time.Second)))
	}
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
	g.last_secret_id = 0
	save_locked()
	return n
}

set_status_locked :: proc(msg: string) {
	if g.status != "" {
		delete(g.status)
	}
	g.status = strings.clone(msg)
}
