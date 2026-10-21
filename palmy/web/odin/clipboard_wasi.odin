#+build wasi
package palmy

import "core:strings"

// ---------------------------------------------------------------------------
// The clipboard on the web backend: the async Clipboard API
// (navigator.clipboard.readText / writeText), reached through suspending
// imports so that `clipboard_get` keeps its synchronous signature.
//
// What a browser permits, and therefore what this does:
//
//   - Writing needs the page focused and either a user activation or the
//     clipboard-write permission. Chromium grants it to a focused page.
//   - Reading needs the clipboard-read permission, which Chromium asks the
//     person for the first time. Refused, `clipboard_get` returns false --
//     except for text this window copied itself, which is answered from
//     memory exactly as the Wayland and X11 backends answer it.
//   - There is no primary selection on the web. `primary_set` keeps the text
//     in this window and `primary_get` returns it, so select-then-middle-click
//     works inside one canvas and nowhere else.
//   - Watching the clipboard (`clipboard_watch`) is `.Unsupported`: a page is
//     told nothing when another program copies.
//
// The public API is the same as clipboard.odin's, overload for overload, and
// the offscreen clipboard (tests, scripted captures) behaves identically.
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

@(private)
CLIP_MAX :: 64 * 1024 * 1024

@(private)
Clip_Sel :: struct {
	owned: bool,
	text:  string,
}

@(private)
Clip_State :: struct {
	sel:   [Clip_Kind]Clip_Sel,
	watch: Clip_Queue,
	// The page said it could not write or read the system clipboard the last
	// time it was asked, for clipboard_available.
	denied: bool,
}

@(private)
Late_Input :: struct {
	any: bool,
}

@(private)
g_clip_app: ^App

@(private)
clip_window :: proc(app: ^App) -> ^Window {
	if app == nil || app.win.conn.fd <= 0 {
		return nil
	}
	return &app.win
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

// clipboard_available reports whether this window can reach the system
// clipboard: true until the page has been refused.
clipboard_available :: proc(app: ^App = nil) -> bool {
	w := clip_window(app != nil ? app : g_clip_app)
	return w != nil && !w.clip.denied
}

@(private)
clip_attach :: proc(app: ^App) {
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
	for &s in w.clip.sel {
		delete(s.text)
	}
	clip_queue_destroy(&w.clip.watch)
}

@(private)
clip_set :: proc(w: ^Window, kind: Clip_Kind, text: string) -> bool {
	if w == nil || w.conn.fatal != "" {
		return false
	}
	s := &w.clip.sel[kind]
	delete(s.text)
	s.text = strings.clone(text)
	s.owned = true
	if kind == .Primary {
		return true
	}
	ok := palmy_web_clip_write(i32(kind), raw_data(text), i32(len(text))) != 0
	w.clip.denied = !ok
	if !ok {
		// Not on the system clipboard, so not ours to answer for either.
		s.owned = false
	}
	return ok
}

@(private)
clip_get :: proc(w: ^Window, kind: Clip_Kind, allocator := context.allocator) -> (string, bool) {
	if w == nil || w.conn.fatal != "" {
		return "", false
	}
	if kind == .Clipboard {
		n := palmy_web_clip_read(i32(kind))
		if n >= 0 && n <= CLIP_MAX {
			w.clip.denied = false
			if n == 0 {
				return "", false
			}
			buf := make([]u8, int(n), allocator)
			palmy_web_clip_take(raw_data(buf), n)
			// Somebody else's copy replaces ours.
			s := &w.clip.sel[kind]
			if s.owned && s.text != string(buf) {
				s.owned = false
			}
			return string(buf), true
		}
		w.clip.denied = true
	}
	// Refused, or the primary selection: what this window copied itself.
	if s := &w.clip.sel[kind]; s.owned && s.text != "" {
		return strings.clone(s.text, allocator), true
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Watching. A page cannot watch the system clipboard; the offscreen watcher
// is kept so that offscreen tests of a caller behave as they do natively.
// ---------------------------------------------------------------------------

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
		for &n in q.entries {
			if n.offer.kind == dropped.offer.kind {
				n.offer.missed += dropped.offer.missed + 1
				break
			}
		}
		did = true
	}
	return
}

@(private)
clip_queue_keep :: proc(q: ^Clip_Queue, kinds: Clip_Kinds) {
	for i := 0; i < len(q.entries); {
		if q.entries[i].offer.kind in kinds {
			i += 1
			continue
		}
		e := q.entries[i]
		ordered_remove(&q.entries, i)
		clip_entry_free(&e)
	}
	if q.has_held && q.held.offer.kind not_in kinds {
		clip_entry_free(&q.held)
		q.has_held = false
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
	return .Unsupported
}
@(private)
clipboard_watch_ctx :: proc(ctx: ^Ctx, kinds: Clip_Kinds = {.Clipboard}) -> Clip_Watch {
	if ctx != nil && ctx.app == nil {
		return offscreen_watch(kinds)
	}
	return .Unsupported
}
@(private)
clipboard_watch_default :: proc(kinds: Clip_Kinds = {.Clipboard}) -> Clip_Watch {
	return .Unsupported
}

clipboard_watch :: proc {
	clipboard_watch_app,
	clipboard_watch_ctx,
	clipboard_watch_default,
}

@(private)
clipboard_next_offer_app :: proc(app: ^App) -> (Clip_Offer, bool) {
	return {}, false
}
@(private)
clipboard_next_offer_ctx :: proc(ctx: ^Ctx) -> (Clip_Offer, bool) {
	if ctx != nil && ctx.app == nil {
		return clip_queue_next(&g_offscreen_watch)
	}
	return {}, false
}
@(private)
clipboard_next_offer_default :: proc() -> (Clip_Offer, bool) {
	return {}, false
}

clipboard_next_offer :: proc {
	clipboard_next_offer_app,
	clipboard_next_offer_ctx,
	clipboard_next_offer_default,
}

@(private)
clipboard_offer_read_app :: proc(app: ^App, offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	return nil, .Unsupported
}
@(private)
clipboard_offer_read_ctx :: proc(ctx: ^Ctx, offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	if ctx != nil && ctx.app == nil {
		return clip_queue_read(&g_offscreen_watch, offer, mime, allocator)
	}
	return nil, .Unsupported
}
@(private)
clipboard_offer_read_default :: proc(offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
	return nil, .Unsupported
}

clipboard_offer_read :: proc {
	clipboard_offer_read_app,
	clipboard_offer_read_ctx,
	clipboard_offer_read_default,
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
clip_queue_next :: proc(q: ^Clip_Queue) -> (Clip_Offer, bool) {
	if q.has_held {
		clip_entry_free(&q.held)
		q.has_held = false
	}
	if len(q.entries) > 0 {
		e := q.entries[0]
		ordered_remove(&q.entries, 0)
		q.held, q.has_held = e, true
		return e.offer, true
	}
	return {}, false
}

@(private)
clip_queue_read :: proc(q: ^Clip_Queue, offer: Clip_Offer, mime: string, allocator := context.allocator) -> ([]u8, Clip_Error) {
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
	for t, i in h.offer.types {
		if t == mime && i < len(h.payloads) {
			return transmute([]u8)strings.clone(h.payloads[i], allocator), .None
		}
	}
	return nil, .Failed
}

@(private, thread_local)
g_offscreen_watch: Clip_Queue

@(private)
offscreen_watch :: proc(kinds: Clip_Kinds) -> Clip_Watch {
	q := &g_offscreen_watch
	clip_queue_keep(q, kinds)
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
		clip_entry_free(&dropped)
	}
}

offscreen_clipboard_offer :: proc(kind: Clip_Kind, types: []string, payloads: []string) -> bool {
	if kind not_in g_offscreen_watch.kinds || len(types) != len(payloads) {
		return false
	}
	offscreen_push(kind, types, payloads, false)
	return true
}

// Nothing waits on a display server mid-frame here -- input that arrives
// while a clipboard read is suspended stays queued in the page until the next
// `window_wait` -- so there is never late input to restore.
@(private)
restore_late :: proc(w: ^Window) {}
