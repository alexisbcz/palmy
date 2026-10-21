package palmy

import "base:intrinsics"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// ---------------------------------------------------------------------------
// The clipboard on macOS: NSPasteboard.
//
// clipboard.odin speaks Wayland's data device and X11's ICCCM selections and
// is not built here (`#+build !darwin`). This file is its public surface again
// — the same procedure groups, the same types, the same offscreen clipboard
// the tests drive — with the general pasteboard underneath. The parts that do
// not touch a display server (the offscreen clipboard, the offer queue,
// `restore_late`) are clipboard.odin's code, copied rather than shared because
// that file cannot be split without colliding with every agent editing it. If
// a public clipboard procedure appears there, an application that uses it
// stops compiling on macOS, which is how this copy learns about it.
//
// What differs, and why:
//
//   - **No primary selection.** macOS has none. `primary_set`/`primary_get`
//     keep a per-window string, so select-then-middle-click still works
//     inside one application, and `clipboard_watch` reports .Unsupported for
//     it rather than pretending.
//   - **Watching polls.** The pasteboard posts no notification when it
//     changes; every clipboard manager on macOS polls `changeCount`. While a
//     window watches, the frame loop's wait is capped at CLIP_POLL_MS and the
//     count compared after it. Not watching costs nothing.
//   - **Types are UTIs**, so an offer lists the MIME type palmy's callers
//     ask for (text/plain;charset=utf-8, image/png, ...) for each UTI that
//     has one, followed by the UTI itself. Reading either gives the same
//     bytes.
//   - A pasteboard read never dispatches events, so input never arrives
//     mid-frame and `Late_Input` is only ever empty here.
// ---------------------------------------------------------------------------

Clip_Kind :: enum u8 {
	Clipboard,
	Primary,
}

@(private)
CLIP_TYPES := [?]string {
	"text/plain;charset=utf-8",
	"UTF8_STRING",
	"text/plain",
	"TEXT",
	"STRING",
}

// How often a watched pasteboard is compared, in milliseconds.
@(private)
CLIP_POLL_MS :: 250

@(private)
UTI_TEXT :: "public.utf8-plain-text"

@(private)
Clip_State :: struct {
	// The primary selection, which lives in this process only.
	primary:     string,
	// The thread the loop runs on: AppKit is main-thread only, and so are
	// these calls, as on the other backends.
	loop_thread: int,
	watch:       Clip_Queue,
	// The pasteboard's changeCount when last looked at, and when the held
	// offer was taken.
	seen_count:  int,
	polled:      bool,
	// The changeCount this window's own last copy produced.
	own_count:   int,
}

@(private)
Late_Input :: struct {
	keys:     [dynamic]Key_Event,
	text:     strings.Builder,
	pressed:  [Mouse_Button]bool,
	released: [Mouse_Button]bool,
	any:      bool,
}

@(private)
g_clip_app: ^App

// --- the pasteboard ---------------------------------------------------------

@(objc_class = "NSPasteboard")
@(private)
NS_Pasteboard :: struct {
	using _: NS.Object,
}

// pasteboard is the general pasteboard, or the named one PALMY_MAC_PASTEBOARD
// asks for: a test, or a demo, that must not overwrite the clipboard of the
// person whose machine it runs on.
@(private)
pasteboard :: proc() -> ^NS_Pasteboard {
	if name := os.get_env("PALMY_MAC_PASTEBOARD", context.temp_allocator); name != "" {
		return intrinsics.objc_send(^NS_Pasteboard, NS_Pasteboard, "pasteboardWithName:", ns_string(name))
	}
	return intrinsics.objc_send(^NS_Pasteboard, NS_Pasteboard, "generalPasteboard")
}

@(private)
pasteboard_count :: proc() -> int {
	NS.scoped_autoreleasepool()
	return int(intrinsics.objc_send(NS.Integer, pasteboard(), "changeCount"))
}

@(private)
pasteboard_set_text :: proc(text: string) -> bool {
	NS.scoped_autoreleasepool()
	pb := pasteboard()
	intrinsics.objc_send(NS.Integer, pb, "clearContents")
	s := ns_string(text)
	return bool(intrinsics.objc_send(NS.BOOL, pb, "setString:forType:", s, ns_string(UTI_TEXT)))
}

@(private)
pasteboard_get_text :: proc(allocator := context.allocator) -> (string, bool) {
	NS.scoped_autoreleasepool()
	s := intrinsics.objc_send(^NS.String, pasteboard(), "stringForType:", ns_string(UTI_TEXT))
	if s == nil {
		return "", false
	}
	t := string(NS.String_UTF8String(s))
	if t == "" {
		return "", false
	}
	return strings.clone(t, allocator), true
}

// UTIs that have a MIME name callers already ask for.
@(private)
UTI_MIME := [?][2]string {
	{"public.utf8-plain-text", "text/plain;charset=utf-8"},
	{"public.html", "text/html"},
	{"public.rtf", "text/rtf"},
	{"public.png", "image/png"},
	{"public.tiff", "image/tiff"},
	{"public.jpeg", "image/jpeg"},
	{"public.file-url", "text/uri-list"},
	{"public.url", "text/x-moz-url"},
}

@(private)
uti_for :: proc(mime: string) -> string {
	for m in UTI_MIME {
		if m[1] == mime {
			return m[0]
		}
	}
	return mime
}

// pasteboard_types lists what the pasteboard holds now, MIME names first.
@(private)
pasteboard_types :: proc() -> []string {
	NS.scoped_autoreleasepool()
	arr := intrinsics.objc_send(^NS.Array, pasteboard(), "types")
	if arr == nil {
		return nil
	}
	utis := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< int(NS.Array_count(arr)) {
		s := (^NS.String)(NS.Array_object(arr, NS.UInteger(i)))
		append(&utis, strings.clone(string(NS.String_UTF8String(s)), context.temp_allocator))
	}
	out := make([dynamic]string)
	for u in utis {
		for m in UTI_MIME {
			if m[0] == u {
				append(&out, strings.clone(m[1]))
			}
		}
	}
	for u in utis {
		append(&out, strings.clone(u))
	}
	return out[:]
}

@(private)
pasteboard_read :: proc(mime: string, allocator := context.allocator) -> ([]u8, bool) {
	NS.scoped_autoreleasepool()
	d := intrinsics.objc_send(^NS.Data, pasteboard(), "dataForType:", ns_string(uti_for(mime)))
	if d == nil {
		return nil, false
	}
	n := int(NS.Data_length(d))
	out := make([]u8, n, allocator)
	if n > 0 {
		intrinsics.objc_send(nil, d, "getBytes:length:", raw_data(out), NS.UInteger(n))
	}
	return out, true
}

// --- public API (as clipboard.odin) ----------------------------------------

@(private)
clip_window :: proc(app: ^App) -> ^Window {
	if app == nil || !app.win.cocoa.open {
		return nil
	}
	w := &app.win
	if w.clip.loop_thread != 0 && w.clip.loop_thread != os.get_current_thread_id() {
		return nil
	}
	return w
}

@(private)
clipboard_set_app :: proc(app: ^App, text: string) -> bool {
	return clip_set(clip_window(app), .Clipboard, text)
}
@(private)
clipboard_set_ctx :: proc(ctx: ^Ctx, text: string) -> bool {
	if ctx != nil && ctx.app == nil {
		return offscreen_clip_set(.Clipboard, text)
	}
	return clip_set(clip_window(ctx != nil ? ctx.app : nil), .Clipboard, text)
}
@(private)
clipboard_set_default :: proc(text: string) -> bool {
	return clip_set(clip_window(g_clip_app), .Clipboard, text)
}

clipboard_set :: proc {
	clipboard_set_app,
	clipboard_set_ctx,
	clipboard_set_default,
}

@(private)
clipboard_get_app :: proc(app: ^App, allocator := context.allocator) -> (string, bool) {
	return clip_get(clip_window(app), .Clipboard, allocator)
}
@(private)
clipboard_get_ctx :: proc(ctx: ^Ctx, allocator := context.allocator) -> (string, bool) {
	if ctx != nil && ctx.app == nil {
		return offscreen_clip_get(.Clipboard, allocator)
	}
	return clip_get(clip_window(ctx != nil ? ctx.app : nil), .Clipboard, allocator)
}
@(private)
clipboard_get_default :: proc(allocator := context.allocator) -> (string, bool) {
	return clip_get(clip_window(g_clip_app), .Clipboard, allocator)
}

clipboard_get :: proc {
	clipboard_get_app,
	clipboard_get_ctx,
	clipboard_get_default,
}

@(private)
primary_set_app :: proc(app: ^App, text: string) -> bool {
	return clip_set(clip_window(app), .Primary, text)
}
@(private)
primary_set_ctx :: proc(ctx: ^Ctx, text: string) -> bool {
	if ctx != nil && ctx.app == nil {
		return offscreen_clip_set(.Primary, text)
	}
	return clip_set(clip_window(ctx != nil ? ctx.app : nil), .Primary, text)
}
@(private)
primary_set_default :: proc(text: string) -> bool {
	return clip_set(clip_window(g_clip_app), .Primary, text)
}

primary_set :: proc {
	primary_set_app,
	primary_set_ctx,
	primary_set_default,
}

@(private)
primary_get_app :: proc(app: ^App, allocator := context.allocator) -> (string, bool) {
	return clip_get(clip_window(app), .Primary, allocator)
}
@(private)
primary_get_ctx :: proc(ctx: ^Ctx, allocator := context.allocator) -> (string, bool) {
	if ctx != nil && ctx.app == nil {
		return offscreen_clip_get(.Primary, allocator)
	}
	return clip_get(clip_window(ctx != nil ? ctx.app : nil), .Primary, allocator)
}
@(private)
primary_get_default :: proc(allocator := context.allocator) -> (string, bool) {
	return clip_get(clip_window(g_clip_app), .Primary, allocator)
}

primary_get :: proc {
	primary_get_app,
	primary_get_ctx,
	primary_get_default,
}

@(private)
g_offscreen_clip: [Clip_Kind]string

@(private)
offscreen_clip_set :: proc(kind: Clip_Kind, text: string) -> bool {
	delete(g_offscreen_clip[kind])
	g_offscreen_clip[kind] = strings.clone(text)
	if kind in g_offscreen_watch.kinds {
		payloads: [len(CLIP_TYPES)]string
		for &pl in payloads {
			pl = text
		}
		offscreen_push(kind, CLIP_TYPES[:], payloads[:], true)
	}
	return true
}

@(private)
offscreen_clip_get :: proc(kind: Clip_Kind, allocator := context.allocator) -> (string, bool) {
	t := g_offscreen_clip[kind]
	if t == "" {
		return "", false
	}
	return strings.clone(t, allocator), true
}

// clipboard_available is true for any open window: the general pasteboard
// always exists.
clipboard_available :: proc(app: ^App = nil) -> bool {
	return clip_window(app != nil ? app : g_clip_app) != nil
}

@(private)
clip_attach :: proc(app: ^App) {
	app.win.clip.loop_thread = os.get_current_thread_id()
	if g_clip_app == nil {
		g_clip_app = app
	}
}

@(private)
clip_detach :: proc(app: ^App) {
	if g_clip_app == app {
		g_clip_app = nil
	}
}

@(private)
clip_destroy :: proc(w: ^Window) {
	delete(w.clip.primary)
	w.clip.primary = ""
	clip_queue_destroy(&w.clip.watch)
	delete(w.late.keys)
	strings.builder_destroy(&w.late.text)
}

@(private)
clip_set :: proc(w: ^Window, kind: Clip_Kind, text: string) -> bool {
	if w == nil || w.conn.fatal != "" {
		return false
	}
	switch kind {
	case .Clipboard:
		ok := pasteboard_set_text(text)
		w.clip.own_count = pasteboard_count()
		// A watcher sees its own copy as an offer straight away.
		clip_poll(w)
		return ok
	case .Primary:
		delete(w.clip.primary)
		w.clip.primary = strings.clone(text)
		return true
	}
	return false
}

@(private)
clip_get :: proc(w: ^Window, kind: Clip_Kind, allocator := context.allocator) -> (string, bool) {
	if w == nil || w.conn.fatal != "" {
		return "", false
	}
	switch kind {
	case .Clipboard:
		return pasteboard_get_text(allocator)
	case .Primary:
		if w.clip.primary == "" {
			return "", false
		}
		return strings.clone(w.clip.primary, allocator), true
	}
	return "", false
}

// restore_late is app.odin's hook for input that arrived during a clipboard
// wait; see clipboard.odin. Nothing fills `late` on macOS, but the hook stays
// whole so that it keeps meaning the same thing.
@(private)
restore_late :: proc(w: ^Window) {
	l := &w.late
	if !l.any {
		return
	}
	append(&w.input.keys, ..l.keys[:])
	clear(&l.keys)
	if l.text.buf != nil {
		strings.write_string(&w.input.text, strings.to_string(l.text))
		strings.builder_reset(&l.text)
	}
	for b in Mouse_Button {
		if l.pressed[b] {
			w.input.pressed[b] = true
		}
		if l.released[b] {
			w.input.released[b] = true
		}
	}
	l.pressed, l.released = {}, {}
	l.any = false
	w.input_dirty = true
}

// --- watching (the queue is clipboard.odin's) -------------------------------

Clip_Kinds :: bit_set[Clip_Kind;u8]

Clip_Watch :: enum u8 {
	Unsupported,
	Focused,
	Always,
}

Clip_Offer :: struct {
	kind:   Clip_Kind,
	id:     u64,
	types:  []string,
	own:    bool,
	missed: int,
}

Clip_Error :: enum u8 {
	None,
	Unsupported,
	Stale,
	Not_Offered,
	Failed,
}

@(private)
CLIP_QUEUE_MAX :: 16

@(private)
Clip_Entry :: struct {
	offer:    Clip_Offer,
	// The pasteboard's changeCount when this offer was seen: a read after
	// it moved on is .Stale, as on X11.
	count:    int,
	payloads: []string,
}

@(private)
Clip_Queue :: struct {
	kinds:    Clip_Kinds,
	mode:     [Clip_Kind]Clip_Watch,
	entries:  [dynamic]Clip_Entry,
	held:     Clip_Entry,
	has_held: bool,
	next_id:  u64,
}

@(private)
clip_entry_free :: proc(e: ^Clip_Entry) {
	for t in e.offer.types {
		delete(t)
	}
	delete(e.offer.types)
	for pl in e.payloads {
		delete(pl)
	}
	delete(e.payloads)
	e^ = {}
}

@(private)
clip_entry_release :: proc(w: ^Window, e: Clip_Entry) {
	e := e
	clip_entry_free(&e)
}

@(private)
clip_queue_destroy :: proc(q: ^Clip_Queue) {
	for &e in q.entries {
		clip_entry_free(&e)
	}
	delete(q.entries)
	if q.has_held {
		clip_entry_free(&q.held)
	}
	q^ = {}
}

@(private)
clip_queue_push :: proc(q: ^Clip_Queue, e: Clip_Entry) -> (dropped: Clip_Entry, did: bool) {
	e := e
	q.next_id += 1
	e.offer.id = q.next_id
	append(&q.entries, e)
	if len(q.entries) > CLIP_QUEUE_MAX {
		dropped = q.entries[0]
		ordered_remove(&q.entries, 0)
		clip_carry_missed(q, dropped.offer)
		did = true
	}
	return
}

@(private)
clip_carry_missed :: proc(q: ^Clip_Queue, gone: Clip_Offer) {
	for &e in q.entries {
		if e.offer.kind == gone.kind {
			e.offer.missed += gone.missed + 1
			return
		}
	}
}

@(private)
clip_queue_keep :: proc(w: ^Window, q: ^Clip_Queue, kinds: Clip_Kinds) {
	for i := 0; i < len(q.entries); {
		if q.entries[i].offer.kind in kinds {
			i += 1
			continue
		}
		e := q.entries[i]
		ordered_remove(&q.entries, i)
		clip_entry_release(w, e)
	}
	if q.has_held && q.held.offer.kind not_in kinds {
		e := q.held
		q.held, q.has_held = {}, false
		clip_entry_release(w, e)
	}
}

@(private)
clip_clone_types :: proc(types: []string) -> []string {
	if len(types) == 0 {
		return nil
	}
	out := make([]string, len(types))
	for t, i in types {
		out[i] = strings.clone(t)
	}
	return out
}

clipboard_offer_has :: proc(offer: Clip_Offer, mime: string) -> bool {
	for t in offer.types {
		if t == mime {
			return true
		}
	}
	return false
}

@(private)
clipboard_watch_app :: proc(app: ^App, kinds: Clip_Kinds = {.Clipboard}) -> Clip_Watch {
	return clip_watch(clip_window(app), kinds)
}
@(private)
clipboard_watch_ctx :: proc(ctx: ^Ctx, kinds: Clip_Kinds = {.Clipboard}) -> Clip_Watch {
	if ctx != nil && ctx.app == nil {
		return offscreen_watch(kinds)
	}
	return clip_watch(clip_window(ctx != nil ? ctx.app : nil), kinds)
}
@(private)
clipboard_watch_default :: proc(kinds: Clip_Kinds = {.Clipboard}) -> Clip_Watch {
	return clip_watch(clip_window(g_clip_app), kinds)
}

clipboard_watch :: proc {
	clipboard_watch_app,
	clipboard_watch_ctx,
	clipboard_watch_default,
}

@(private)
clipboard_next_offer_app :: proc(app: ^App) -> (Clip_Offer, bool) {
	w := clip_window(app)
	if w == nil {
		return {}, false
	}
	return clip_queue_next(w, &w.clip.watch)
}
@(private)
clipboard_next_offer_ctx :: proc(ctx: ^Ctx) -> (Clip_Offer, bool) {
	if ctx != nil && ctx.app == nil {
		return clip_queue_next(nil, &g_offscreen_watch)
	}
	return clipboard_next_offer_app(ctx != nil ? ctx.app : nil)
}
@(private)
clipboard_next_offer_default :: proc() -> (Clip_Offer, bool) {
	return clipboard_next_offer_app(g_clip_app)
}

clipboard_next_offer :: proc {
	clipboard_next_offer_app,
	clipboard_next_offer_ctx,
	clipboard_next_offer_default,
}

@(private)
clipboard_offer_read_app :: proc(app: ^App, offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	w := clip_window(app)
	if w == nil {
		return nil, .Unsupported
	}
	return clip_queue_read(w, &w.clip.watch, offer, mime, allocator)
}
@(private)
clipboard_offer_read_ctx :: proc(ctx: ^Ctx, offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	if ctx != nil && ctx.app == nil {
		return clip_queue_read(nil, &g_offscreen_watch, offer, mime, allocator)
	}
	return clipboard_offer_read_app(ctx != nil ? ctx.app : nil, offer, mime, allocator)
}
@(private)
clipboard_offer_read_default :: proc(offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	return clipboard_offer_read_app(g_clip_app, offer, mime, allocator)
}

clipboard_offer_read :: proc {
	clipboard_offer_read_app,
	clipboard_offer_read_ctx,
	clipboard_offer_read_default,
}

@(private)
clip_watch :: proc(w: ^Window, kinds: Clip_Kinds) -> Clip_Watch {
	if w == nil || w.conn.fatal != "" {
		return .Unsupported
	}
	q := &w.clip.watch
	clip_queue_keep(w, q, kinds)
	was := .Clipboard in q.kinds
	q.kinds = kinds
	q.mode[.Clipboard] = .Clipboard in kinds ? .Always : .Unsupported
	q.mode[.Primary] = .Unsupported
	if .Clipboard in kinds && !was {
		// The first offer is whatever is on the pasteboard already, as a
		// data-control watcher on Wayland is shown.
		w.clip.polled = false
		clip_poll(w)
	}
	return clip_weakest(q, kinds)
}

// clip_poll queues an offer when the pasteboard changed since it last looked.
// window_darwin.odin calls it after every wait while somebody watches.
@(private)
clip_poll :: proc(w: ^Window) {
	q := &w.clip.watch
	if .Clipboard not_in q.kinds {
		return
	}
	n := pasteboard_count()
	if w.clip.polled && n == w.clip.seen_count {
		return
	}
	w.clip.polled = true
	w.clip.seen_count = n
	types := pasteboard_types()
	e := Clip_Entry {
		offer = {kind = .Clipboard, types = types, own = n == w.clip.own_count},
		count = n,
	}
	if dropped, did := clip_queue_push(q, e); did {
		clip_entry_release(w, dropped)
	}
	w.input_dirty = true
}

@(private)
clip_weakest :: proc(q: ^Clip_Queue, kinds: Clip_Kinds) -> Clip_Watch {
	if kinds == {} {
		return .Unsupported
	}
	m := Clip_Watch.Always
	for k in kinds {
		m = min(m, q.mode[k])
	}
	return m
}

@(private)
clip_queue_next :: proc(w: ^Window, q: ^Clip_Queue) -> (Clip_Offer, bool) {
	if q.has_held {
		e := q.held
		q.held, q.has_held = {}, false
		clip_entry_release(w, e)
	}
	for len(q.entries) > 0 {
		e := q.entries[0]
		ordered_remove(&q.entries, 0)
		q.held, q.has_held = e, true
		return e.offer, true
	}
	return {}, false
}

@(private)
clip_queue_read :: proc(w: ^Window, q: ^Clip_Queue, offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	if q.kinds == {} {
		return nil, .Unsupported
	}
	if !q.has_held || offer.id == 0 || offer.id != q.held.offer.id || offer.kind != q.held.offer.kind {
		return nil, .Stale
	}
	h := q.held
	if !clipboard_offer_has(h.offer, mime) {
		return nil, .Not_Offered
	}
	if w == nil {
		for t, i in h.offer.types {
			if t == mime && i < len(h.payloads) {
				return transmute([]u8)strings.clone(h.payloads[i], allocator), .None
			}
		}
		return nil, .Failed
	}
	if w.conn.fatal != "" {
		return nil, .Failed
	}
	if pasteboard_count() != h.count {
		return nil, .Stale
	}
	data, ok := pasteboard_read(mime, allocator)
	return data, ok ? .None : .Failed
}

// --- offscreen (as clipboard.odin) -----------------------------------------

@(private, thread_local)
g_offscreen_watch: Clip_Queue

@(private)
offscreen_watch :: proc(kinds: Clip_Kinds) -> Clip_Watch {
	q := &g_offscreen_watch
	clip_queue_keep(nil, q, kinds)
	q.kinds = kinds
	for k in Clip_Kind {
		q.mode[k] = k in kinds ? .Always : .Unsupported
	}
	if kinds == {} {
		clip_queue_destroy(q)
	}
	return clip_weakest(q, kinds)
}

@(private)
offscreen_push :: proc(kind: Clip_Kind, types: []string, payloads: []string, own: bool) {
	e := Clip_Entry {
		offer = {kind = kind, types = clip_clone_types(types), own = own},
		payloads = clip_clone_types(payloads),
	}
	if dropped, did := clip_queue_push(&g_offscreen_watch, e); did {
		clip_entry_release(nil, dropped)
	}
}

offscreen_clipboard_offer :: proc(kind: Clip_Kind, types: []string, payloads: []string) -> bool {
	if kind not_in g_offscreen_watch.kinds || len(types) != len(payloads) {
		return false
	}
	offscreen_push(kind, types, payloads, false)
	return true
}
