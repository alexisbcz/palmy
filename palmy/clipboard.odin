package palmy

import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// The clipboard, spoken natively on both backends.
//
//	palmy.clipboard_set(ui, "text")            Ctrl+C
//	text, ok := palmy.clipboard_get(ui)        Ctrl+V
//	palmy.primary_set(ui, "text")              what a selection becomes
//	text, ok := palmy.primary_get(ui)          middle-click paste
//
// On Wayland this is `wl_data_device_manager` for the clipboard and
// `zwp_primary_selection_device_manager_v1` for the primary selection, hand
// rolled like the rest of the wire: the client offers a data *source* with a
// list of MIME types and writes its bytes into whatever pipe the compositor
// hands it in `send`; to paste, it is told about each new selection as an
// *offer* with the types it advertises, picks one, and reads the bytes out of
// a pipe it creates and passes over in `receive`.
//
// On X11 it is the ICCCM selection protocol: CLIPBOARD and PRIMARY are owned
// with SetSelectionOwner and served by answering SelectionRequest with a
// property on the requestor and a SelectionNotify; pasting is
// ConvertSelection into a property on our own window and reading it back.
// The INCR protocol for transfers larger than one request is not
// implemented: a selection bigger than the server's maximum request is
// refused when serving and reported as unreadable when pasting.
//
// Both: the text is served for as long as this window lives and nobody else
// takes the selection. There is no daemon to hand it to when the program
// exits, which is what every GUI toolkit does.
//
// Watching the selection -- what a clipboard manager needs -- is the offer
// itself rather than its text: which types it advertises, and the bytes of one
// of them, read from that same offer. See "Watching" below.
//
//	palmy.clipboard_watch(app)                   once; says how well it can
//	for offer in palmy.clipboard_next_offer(app) every change, in order
//	data, err := palmy.clipboard_offer_read(app, offer, mime)
//
// Call these from the thread that runs the frame loop; the display connection
// is not shared. From any other thread they return false, which is also what
// they return when there is no window at all (a command line path), so a
// caller that falls back to `wl-copy` on false does the right thing in every
// case.
// ---------------------------------------------------------------------------

// Clip_Kind is which of the two selections: the clipboard proper (Ctrl+C,
// Ctrl+V) or the primary selection (select, middle-click).
Clip_Kind :: enum u8 {
	Clipboard,
	Primary,
}

// The types offered and accepted for text, best first. text/plain;charset=utf-8
// is what Wayland clients use; UTF8_STRING is the X11 name, which XWayland
// and older toolkits offer on Wayland too.
@(private)
CLIP_TYPES := [?]string {
	"text/plain;charset=utf-8",
	"UTF8_STRING",
	"text/plain",
	"TEXT",
	"STRING",
}

// The biggest paste accepted, and how long a paste waits for the source.
@(private)
CLIP_MAX :: 64 * 1024 * 1024
@(private)
CLIP_TIMEOUT :: 2 * time.Second

@(private)
Clip_Sel :: struct {
	// What this window serves, when it owns the selection.
	owned:  bool,
	text:   string,
	source: u32, // Wayland data source

	// What is on offer (Wayland): the current selection's offer object and
	// the types it advertised.
	offer:  u32,
	types:  [dynamic]string,
}

@(private)
Clip_State :: struct {
	sel:          [Clip_Kind]Clip_Sel,

	// Wayland globals and devices.
	ddm:          u32,
	ddm_ver:      u32,
	device:       u32,
	pdm:          u32,
	pdevice:      u32,
	// The serial of the last input event, which `set_selection` must carry.
	serial:       u32,
	// Types announced for offers not yet named as a selection; the offer
	// events arrive before the selection event that says what they are for.
	pending:      map[u32][dynamic]string,
	dnd_offer:    u32,

	// X11.
	x_ready:      bool,
	x_time:       u32, // the timestamp of the last input event
	a_clipboard:  u32,
	a_targets:    u32,
	a_text:       u32,
	a_mime_utf8:  u32,
	a_mime_plain: u32,
	a_incr:       u32,
	a_prop:       u32,
	x_waiting:    bool,
	x_notified:   bool,
	x_notify_prop: u32,

	// The thread the loop runs on; see the note above.
	loop_thread:  int,

	// Watching: the queue of selections not yet handed to the caller.
	watch:        Clip_Queue,
	// Wayland data control: the global, remembered from the registry and
	// bound only when somebody watches.
	ctl_name:     u32,
	ctl_ver:      u32,
	ctl_ext:      bool, // ext_data_control_v1 rather than zwlr_data_control_v1
	ctl_mgr:      u32,
	ctl_dev:      u32,
	// X11: XFIXES, which reports every change of selection owner, and the
	// generation of each selection, bumped on every such change.
	xf_major:     u8,
	xf_first_event: u8,
	xf_ready:     bool,
	xf_tried:     bool,
	x_gen:        [Clip_Kind]u64,
	atom_names:   map[u32]string,
}

// Input that arrived while a clipboard call was waiting on the display
// server mid-frame. It is handed to the next frame instead of being cleared
// with this one's edges. See `hold_input`.
@(private)
Late_Input :: struct {
	keys:     [dynamic]Key_Event,
	text:     strings.Builder,
	pressed:  [Mouse_Button]bool,
	released: [Mouse_Button]bool,
	any:      bool,
}

// The App the default-window overloads use: the first one opened and still
// open. A process almost always has exactly one.
@(private)
g_clip_app: ^App

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

@(private)
clip_window :: proc(app: ^App) -> ^Window {
	if app == nil || app.win.conn.fd <= 0 {
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

// clipboard_set puts text on the clipboard. It returns false when there is no
// window, the display server has no clipboard protocol, it refused, or this is
// not the frame loop's thread.
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

// clipboard_get reads the clipboard as UTF-8 text. `ok` is false when there
// is nothing on it that is text, or it could not be read; an empty clipboard
// is ("", false).
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

// primary_set makes text the primary selection, what a middle click pastes.
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

// primary_get reads the primary selection.
primary_get :: proc {
	primary_get_app,
	primary_get_ctx,
	primary_get_default,
}

// An offscreen frame (tests, scripted captures) has no display server, so a
// copy or paste made through its Ctx goes to a clipboard local to the
// process. That is what lets the text widgets' Ctrl+C / Ctrl+V be tested
// headlessly. It is never used for a real window, nor for the default-window
// overloads, so a command line path still gets false and falls back.
@(private)
g_offscreen_clip: [Clip_Kind]string

@(private)
offscreen_clip_set :: proc(kind: Clip_Kind, text: string) -> bool {
	delete(g_offscreen_clip[kind])
	g_offscreen_clip[kind] = strings.clone(text)
	// A watcher sees the copy as an offer of its own, the way a compositor
	// would show it one.
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

// clipboard_available reports whether this window can reach a clipboard
// natively: Wayland with wl_data_device_manager, or any X11 server.
clipboard_available :: proc(app: ^App = nil) -> bool {
	w := clip_window(app != nil ? app : g_clip_app)
	if w == nil {
		return false
	}
	switch w.backend {
	case .Wayland:
		return w.clip.device != 0
	case .X11:
		return w.clip.x_ready
	}
	return false
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

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
	for &s in w.clip.sel {
		delete(s.text)
		for t in s.types {
			delete(t)
		}
		delete(s.types)
	}
	for _, list in w.clip.pending {
		for t in list {
			delete(t)
		}
		delete(list)
	}
	delete(w.clip.pending)
	clip_queue_destroy(&w.clip.watch)
	for _, name in w.clip.atom_names {
		delete(name)
	}
	delete(w.clip.atom_names)
	delete(w.late.keys)
	strings.builder_destroy(&w.late.text)
}

@(private)
clip_set :: proc(w: ^Window, kind: Clip_Kind, text: string) -> bool {
	if w == nil || w.conn.fatal != "" {
		return false
	}
	switch w.backend {
	case .Wayland:
		return wl_clip_set(w, kind, text)
	case .X11:
		return x_clip_set(w, kind, text)
	}
	return false
}

@(private)
clip_get :: proc(w: ^Window, kind: Clip_Kind, allocator := context.allocator) -> (string, bool) {
	if w == nil || w.conn.fatal != "" {
		return "", false
	}
	// What this window is serving is answered from memory. Asking the
	// server would make it ask us, and we would be blocked reading the pipe
	// we are supposed to be writing.
	if s := &w.clip.sel[kind]; s.owned {
		if s.text == "" {
			return "", false
		}
		return strings.clone(s.text, allocator), true
	}
	switch w.backend {
	case .Wayland:
		return wl_clip_get(w, kind, allocator)
	case .X11:
		return x_clip_get(w, kind, allocator)
	}
	return "", false
}

@(private)
clip_own :: proc(s: ^Clip_Sel, text: string) {
	delete(s.text)
	s.text = strings.clone(text)
	s.owned = true
}

@(private)
clip_disown :: proc(s: ^Clip_Sel) {
	s.owned = false
	delete(s.text)
	s.text = ""
}

// hold_input brackets a wait on the display server made from inside a frame.
// Waiting means dispatching, and dispatching delivers input: a key pressed
// during the wait would land in this frame's input after the widgets that
// could see it had already been built, and be cleared with the frame. So
// whatever arrives is moved aside and handed to the next frame instead.
@(private)
Input_Mark :: struct {
	keys:     int,
	text:     int,
	pressed:  [Mouse_Button]bool,
	released: [Mouse_Button]bool,
}

@(private)
hold_input :: proc(w: ^Window) -> Input_Mark {
	return {
		keys = len(w.input.keys),
		text = strings.builder_len(w.input.text),
		pressed = w.input.pressed,
		released = w.input.released,
	}
}

@(private)
release_input :: proc(w: ^Window, m: Input_Mark) {
	in_ := &w.input
	l := &w.late
	if len(in_.keys) > m.keys {
		append(&l.keys, ..in_.keys[m.keys:])
		resize(&in_.keys, m.keys)
		l.any = true
	}
	if n := strings.builder_len(in_.text); n > m.text {
		if l.text.buf == nil {
			l.text = strings.builder_make()
		}
		strings.write_string(&l.text, strings.to_string(in_.text)[m.text:])
		resize(&in_.text.buf, m.text)
		l.any = true
	}
	for b in Mouse_Button {
		if in_.pressed[b] && !m.pressed[b] {
			l.pressed[b] = true
			in_.pressed[b] = m.pressed[b]
			l.any = true
		}
		if in_.released[b] && !m.released[b] {
			l.released[b] = true
			in_.released[b] = m.released[b]
			l.any = true
		}
	}
}

// restore_late puts held input back after a frame's edges were cleared, and
// asks for the frame that will see it.
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

// write_all_fd writes a whole buffer to a pipe, waiting at most `limit` for
// a slow reader. Pipes from other clients are blocking; that is fine on a
// worker thread and bounded here by poll on the loop's.
@(private)
write_all_fd :: proc(fd: linux.Fd, data: []u8, limit: time.Duration) {
	deadline := time.time_add(time.now(), limit)
	off := 0
	for off < len(data) {
		pfd := [1]linux.Poll_Fd{{fd = fd, events = {.OUT}}}
		left := time.diff(time.now(), deadline)
		if left <= 0 {
			return
		}
		n, perr := linux.poll(pfd[:], i32(max(1, time.duration_milliseconds(left))))
		if perr == .EINTR {
			continue
		}
		if perr != .NONE || n <= 0 || .ERR in pfd[0].revents || .HUP in pfd[0].revents {
			return
		}
		chunk := min(len(data) - off, 64 * 1024)
		wrote, werr := linux.write(fd, data[off:off + chunk])
		if werr == .EINTR || werr == .EAGAIN {
			continue
		}
		if werr != .NONE || wrote <= 0 {
			return
		}
		off += wrote
	}
}

// serve_fd hands `text` to the client reading the other end of `fd`, and
// closes it. Up to a pipe's capacity that is one write on this thread; beyond
// it a short-lived thread does the writing, so a slow paste into another
// program cannot stall this window.
@(private)
serve_fd :: proc(fd: linux.Fd, text: string) {
	if len(text) <= 32 * 1024 {
		write_all_fd(fd, transmute([]u8)text, 500 * time.Millisecond)
		linux.close(fd)
		return
	}
	Job :: struct {
		fd:   linux.Fd,
		data: []u8,
	}
	job := new(Job)
	job.fd = fd
	job.data = transmute([]u8)strings.clone(text)
	t := thread.create_and_start_with_data(job, proc(p: rawptr) {
		j := (^Job)(p)
		write_all_fd(j.fd, j.data, 10 * time.Second)
		linux.close(j.fd)
		delete(j.data)
		free(j)
	}, self_cleanup = true)
	if t == nil {
		write_all_fd(fd, job.data, 500 * time.Millisecond)
		linux.close(fd)
		delete(job.data)
		free(job)
	}
}

// read_all_fd reads a pipe to EOF, giving up after CLIP_TIMEOUT.
@(private)
read_all_fd :: proc(fd: linux.Fd, allocator := context.allocator) -> (string, bool) {
	out := make([dynamic]u8, 0, 4096, allocator)
	deadline := time.time_add(time.now(), CLIP_TIMEOUT)
	buf: [16 * 1024]u8
	for {
		left := time.diff(time.now(), deadline)
		if left <= 0 {
			delete(out)
			return "", false
		}
		pfd := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, perr := linux.poll(pfd[:], i32(max(1, time.duration_milliseconds(left))))
		if perr == .EINTR {
			continue
		}
		if perr != .NONE {
			delete(out)
			return "", false
		}
		if n == 0 {
			continue
		}
		got, rerr := linux.read(fd, buf[:])
		if rerr == .EINTR || rerr == .EAGAIN {
			continue
		}
		if rerr != .NONE {
			delete(out)
			return "", false
		}
		if got == 0 {
			break
		}
		if len(out) + got > CLIP_MAX {
			delete(out)
			return "", false
		}
		append(&out, ..buf[:got])
	}
	return string(out[:]), true
}

@(private)
pick_type :: proc(types: []string) -> string {
	for want in CLIP_TYPES {
		for t in types {
			if t == want {
				return want
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Wayland
// ---------------------------------------------------------------------------

@(private)
WL_DDM_CREATE_DATA_SOURCE :: 0
@(private)
WL_DDM_GET_DATA_DEVICE :: 1
@(private)
WL_DATA_SOURCE_OFFER :: 0
@(private)
WL_DATA_SOURCE_DESTROY :: 1
@(private)
WL_DATA_DEVICE_SET_SELECTION :: 1
@(private)
WL_DATA_OFFER_RECEIVE :: 1
@(private)
WL_DATA_OFFER_DESTROY :: 2
@(private)
PRIMARY_MANAGER_CREATE_SOURCE :: 0
@(private)
PRIMARY_MANAGER_GET_DEVICE :: 1
@(private)
PRIMARY_DEVICE_SET_SELECTION :: 0
@(private)
PRIMARY_OFFER_RECEIVE :: 0
@(private)
PRIMARY_OFFER_DESTROY :: 1
@(private)
PRIMARY_SOURCE_OFFER :: 0
@(private)
PRIMARY_SOURCE_DESTROY :: 1

// wl_clip_bind is called from the registry handler for the two globals.
@(private)
wl_clip_bind :: proc(w: ^Window, name: u32, iface: string, version: u32) {
	switch iface {
	case "wl_data_device_manager":
		w.clip.ddm_ver = min(version, 3)
		w.clip.ddm = bind_global(w, name, iface, w.clip.ddm_ver, .Data_Device_Manager)
	case "zwp_primary_selection_device_manager_v1":
		w.clip.pdm = bind_global(w, name, iface, 1, .Primary_Manager)
	case "ext_data_control_manager_v1":
		// The standard one wins over wlroots' original wherever both exist.
		// PALMY_NO_DATA_CONTROL hides both, which is how the wl_data_device
		// fallback (.Focused) gets tested on a compositor that has them.
		if os.get_env("PALMY_NO_DATA_CONTROL", context.temp_allocator) == "" {
			w.clip.ctl_name, w.clip.ctl_ver, w.clip.ctl_ext = name, 1, true
		}
	case "zwlr_data_control_manager_v1":
		if !w.clip.ctl_ext && os.get_env("PALMY_NO_DATA_CONTROL", context.temp_allocator) == "" {
			w.clip.ctl_name, w.clip.ctl_ver = name, min(version, 2)
		}
	}
}

// wl_clip_init creates the per-seat devices once the globals are known. The
// selection is then announced to us each time we gain keyboard focus.
@(private)
wl_clip_init :: proc(w: ^Window) {
	c := &w.conn
	if w.wl.seat == 0 {
		return
	}
	if w.clip.ddm != 0 && w.clip.device == 0 {
		w.clip.device = new_id(c, .Data_Device)
		request(c, w.clip.ddm, WL_DDM_GET_DATA_DEVICE, Obj(w.clip.device), Obj(w.wl.seat))
	}
	if w.clip.pdm != 0 && w.clip.pdevice == 0 {
		w.clip.pdevice = new_id(c, .Primary_Device)
		request(c, w.clip.pdm, PRIMARY_MANAGER_GET_DEVICE, Obj(w.clip.pdevice), Obj(w.wl.seat))
	}
}

@(private)
wl_clip_offer_destroy :: proc(w: ^Window, kind: Clip_Kind, id: u32) {
	wl_offer_destroy(w, kind == .Clipboard ? .Data_Offer : .Primary_Offer, id)
}

// wl_offer_destroy destroys an offer of any of the three protocols.
@(private)
wl_offer_destroy :: proc(w: ^Window, hkind: Obj_Kind, id: u32) {
	if id == 0 {
		return
	}
	c := &w.conn
	// wl_data_offer.destroy is 2; the primary and data control offers' is 1.
	request(c, id, hkind == .Data_Offer ? WL_DATA_OFFER_DESTROY : PRIMARY_OFFER_DESTROY)
	forget_server_id(c, id)
	if list, found := w.clip.pending[id]; found {
		for t in list {
			delete(t)
		}
		delete(list)
		delete_key(&w.clip.pending, id)
	}
}

// wl_clip_selection makes `id` the current offer for a selection.
@(private)
wl_clip_selection :: proc(w: ^Window, kind: Clip_Kind, id: u32) {
	s := &w.clip.sel[kind]
	if s.offer == id {
		return
	}
	old := s.offer
	s.offer = 0
	for t in s.types {
		delete(t)
	}
	clear(&s.types)
	hkind: Obj_Kind = kind == .Clipboard ? .Data_Offer : .Primary_Offer
	// A watcher may still hold the old offer; it is destroyed when they let
	// go of it instead.
	wl_offer_release(w, hkind, old)
	if id != 0 {
		s.offer = id
		if list, found := w.clip.pending[id]; found {
			append(&s.types, ..list[:])
			delete(list)
			delete_key(&w.clip.pending, id)
		}
	}
	if kind in w.clip.watch.kinds && w.clip.watch.mode[kind] == .Focused {
		wl_watch_push(w, kind, hkind, id, s.types[:])
	}
}

@(private)
wl_clip_source_done :: proc(w: ^Window, kind: Clip_Kind, id: u32) {
	c := &w.conn
	s := &w.clip.sel[kind]
	request(c, id, kind == .Clipboard ? WL_DATA_SOURCE_DESTROY : PRIMARY_SOURCE_DESTROY)
	retire_id(c, id)
	if s.source == id {
		s.source = 0
		clip_disown(s)
	}
}

// wl_clip_event handles every event on a clipboard object.
@(private)
wl_clip_event :: proc(w: ^Window, kind: Obj_Kind, id: u32, opcode: u16, r: ^Reader) {
	c := &w.conn
	#partial switch kind {
	case .Data_Device:
		switch opcode {
		case 0:
			// data_offer(new_id): a new offer, its types to follow.
			oid := r_u32(r)
			server_id(c, oid, .Data_Offer)
			w.clip.pending[oid] = make([dynamic]string)
		case 1:
			// enter(serial, surface, x, y, offer): drag and drop, which
			// palmy does not take. The offer is released on leave.
			r_u32(r)
			r_u32(r)
			r_u32(r)
			r_u32(r)
			oid := r_u32(r)
			if w.clip.dnd_offer != 0 && w.clip.dnd_offer != oid {
				wl_clip_offer_destroy(w, .Clipboard, w.clip.dnd_offer)
			}
			w.clip.dnd_offer = oid
		case 2, 4:
			// leave, drop
			if w.clip.dnd_offer != 0 {
				wl_clip_offer_destroy(w, .Clipboard, w.clip.dnd_offer)
				w.clip.dnd_offer = 0
			}
		case 5:
			wl_clip_selection(w, .Clipboard, r_u32(r))
		}

	case .Primary_Device:
		switch opcode {
		case 0:
			oid := r_u32(r)
			server_id(c, oid, .Primary_Offer)
			w.clip.pending[oid] = make([dynamic]string)
		case 1:
			wl_clip_selection(w, .Primary, r_u32(r))
		}

	case .Control_Device:
		switch opcode {
		case 0:
			// data_offer(new_id)
			oid := r_u32(r)
			server_id(c, oid, .Control_Offer)
			w.clip.pending[oid] = make([dynamic]string)
		case 1:
			// selection(offer or null)
			wl_ctl_selection(w, .Clipboard, r_u32(r))
		case 2:
			// finished: the device is dead, and watching drops back to
			// what wl_data_device can see.
			request(c, id, CTL_DEVICE_DESTROY)
			retire_id(c, id)
			if w.clip.ctl_dev == id {
				w.clip.ctl_dev = 0
				wl_watch_modes(w)
			}
		case 3:
			// primary_selection(offer or null)
			wl_ctl_selection(w, .Primary, r_u32(r))
		}

	case .Data_Offer, .Primary_Offer, .Control_Offer:
		if opcode == 0 {
			mime := r_string(r)
			if list, found := &w.clip.pending[id]; found {
				append(list, strings.clone(mime))
			} else if kind != .Control_Offer {
				ck := kind == .Data_Offer ? Clip_Kind.Clipboard : Clip_Kind.Primary
				if w.clip.sel[ck].offer == id {
					append(&w.clip.sel[ck].types, strings.clone(mime))
				}
			}
		}

	case .Data_Source, .Primary_Source:
		ck := kind == .Data_Source ? Clip_Kind.Clipboard : Clip_Kind.Primary
		send_op: u16 = kind == .Data_Source ? 1 : 0
		cancel_op: u16 = kind == .Data_Source ? 2 : 1
		switch opcode {
		case send_op:
			// send(mime_type, fd): write the text and close.
			r_string(r)
			if fd, ok := take_fd(c); ok {
				s := &w.clip.sel[ck]
				if s.source == id && s.owned {
					serve_fd(fd, s.text)
				} else {
					linux.close(fd)
				}
			}
		case cancel_op:
			// Somebody else took the selection.
			wl_clip_source_done(w, ck, id)
		}
	}
}

@(private)
wl_clip_set :: proc(w: ^Window, kind: Clip_Kind, text: string) -> bool {
	c := &w.conn
	dev := kind == .Clipboard ? w.clip.device : w.clip.pdevice
	if dev == 0 {
		return false
	}
	// set_selection must carry the serial of an input event this client
	// received. With none -- no key or click has reached the window yet --
	// wlroots drops the request without a `cancelled`, so the roundtrip
	// below could not tell; say no now and let the caller fall back.
	if w.clip.serial == 0 {
		return false
	}
	s := &w.clip.sel[kind]

	// One source per selection: a new copy replaces it.
	if s.source != 0 {
		old := s.source
		s.source = 0
		request(c, old, kind == .Clipboard ? WL_DATA_SOURCE_DESTROY : PRIMARY_SOURCE_DESTROY)
		retire_id(c, old)
	}

	src: u32
	if kind == .Clipboard {
		src = new_id(c, .Data_Source)
		request(c, w.clip.ddm, WL_DDM_CREATE_DATA_SOURCE, Obj(src))
		for t in CLIP_TYPES {
			request(c, src, WL_DATA_SOURCE_OFFER, t)
		}
		request(c, dev, WL_DATA_DEVICE_SET_SELECTION, Obj(src), w.clip.serial)
	} else {
		src = new_id(c, .Primary_Source)
		request(c, w.clip.pdm, PRIMARY_MANAGER_CREATE_SOURCE, Obj(src))
		for t in CLIP_TYPES {
			request(c, src, PRIMARY_SOURCE_OFFER, t)
		}
		request(c, dev, PRIMARY_DEVICE_SET_SELECTION, Obj(src), w.clip.serial)
	}
	s.source = src
	clip_own(s, text)

	// A compositor that refuses the request -- a stale serial, no keyboard
	// focus -- answers with `cancelled`, so one roundtrip tells the caller
	// whether the copy took, and a false lets it fall back.
	mark := hold_input(w)
	roundtrip(w)
	release_input(w, mark)
	return s.source == src && s.owned
}

@(private)
wl_clip_get :: proc(w: ^Window, kind: Clip_Kind, allocator := context.allocator) -> (string, bool) {
	c := &w.conn
	s := &w.clip.sel[kind]
	if s.offer == 0 {
		return "", false
	}
	mime := pick_type(s.types[:])
	if mime == "" {
		return "", false
	}
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE {
		return "", false
	}
	// The write end goes to the source over the socket, and `request`
	// flushes it at once and closes our copy -- which matters, because the
	// read below only sees EOF once every write end is closed.
	request(
		c,
		s.offer,
		kind == .Clipboard ? WL_DATA_OFFER_RECEIVE : PRIMARY_OFFER_RECEIVE,
		mime,
		Fd(fds[1]),
	)
	conn_flush(c)
	text, ok := read_all_fd(fds[0], allocator)
	linux.close(fds[0])
	if ok && text == "" {
		return "", false
	}
	return text, ok
}

// ---------------------------------------------------------------------------
// X11
// ---------------------------------------------------------------------------

@(private)
X_SET_SELECTION_OWNER :: 22
@(private)
X_GET_SELECTION_OWNER :: 23
@(private)
X_CONVERT_SELECTION :: 24
@(private)
X_DELETE_PROPERTY :: 19
@(private)
X_SELECTION_CLEAR :: 29
@(private)
X_SELECTION_REQUEST :: 30
@(private)
X_SELECTION_NOTIFY :: 31
@(private)
XA_PRIMARY :: u32(1)

@(private)
x_clip_init :: proc(w: ^Window) {
	x := &w.x
	w.clip.a_clipboard = x_intern(w, "CLIPBOARD")
	w.clip.a_targets = x_intern(w, "TARGETS")
	w.clip.a_text = x_intern(w, "TEXT")
	w.clip.a_mime_utf8 = x_intern(w, "text/plain;charset=utf-8")
	w.clip.a_mime_plain = x_intern(w, "text/plain")
	w.clip.a_incr = x_intern(w, "INCR")
	w.clip.a_prop = x_intern(w, "PALMY_SELECTION")
	w.clip.x_ready = w.clip.a_clipboard != 0 && w.clip.a_targets != 0 && w.clip.a_prop != 0 && x.a_utf8_string != 0
}

@(private)
x_sel_atom :: proc(w: ^Window, kind: Clip_Kind) -> u32 {
	return kind == .Clipboard ? w.clip.a_clipboard : XA_PRIMARY
}

@(private)
x_change_property :: proc(w: ^Window, window, prop, type: u32, format: u8, data: []u8) {
	c := &w.conn
	s := x_begin(w, X_CHANGE_PROPERTY, 0)
	xo32(c, window)
	xo32(c, prop)
	xo32(c, type)
	xo8(c, format)
	xopad(c, 3)
	units := len(data)
	switch format {
	case 16:
		units /= 2
	case 32:
		units /= 4
	}
	xo32(c, u32(units))
	append(&c.out, ..data)
	x_end(w, s)
}

@(private)
x_clip_set :: proc(w: ^Window, kind: Clip_Kind, text: string) -> bool {
	if !w.clip.x_ready || w.x.window == 0 {
		return false
	}
	c := &w.conn
	sel := x_sel_atom(w, kind)
	s := x_begin(w, X_SET_SELECTION_OWNER)
	xo32(c, w.x.window)
	xo32(c, sel)
	xo32(c, w.clip.x_time)
	x_end(w, s)
	clip_own(&w.clip.sel[kind], text)

	// SetSelectionOwner has no reply and fails silently when the timestamp
	// is older than the current owner's, so ask who owns it now.
	s2 := x_begin(w, X_GET_SELECTION_OWNER)
	xo32(c, sel)
	seq := x_end(w, s2)
	mark := hold_input(w)
	reply, ok := x_sync(w, seq)
	release_input(w, mark)
	if !ok || xr32(reply, 8) != w.x.window {
		clip_disown(&w.clip.sel[kind])
		return false
	}
	return true
}

@(private)
x_clip_get :: proc(w: ^Window, kind: Clip_Kind, allocator := context.allocator) -> (string, bool) {
	if !w.clip.x_ready || w.x.window == 0 {
		return "", false
	}
	data, ptype, format, ok := x_clip_convert(w, kind, w.x.a_utf8_string, w.clip.x_time, allocator)
	if !ok {
		return "", false
	}
	if ptype == w.clip.a_incr || ptype == 0 || format != 8 || len(data) == 0 {
		delete(data, allocator)
		return "", false // INCR is not implemented
	}
	return string(data), true
}

// x_clip_convert asks the owner of a selection for one target at a given
// time, waits for its answer and reads the property back: the bytes, the
// property's type and its format. Without an answer `ok` is false.
@(private)
x_clip_convert :: proc(
	w: ^Window,
	kind: Clip_Kind,
	target: u32,
	at_time: u32,
	allocator := context.allocator,
) -> (
	data: []u8,
	ptype: u32,
	format: int,
	ok: bool,
) {
	if !w.clip.x_ready || w.x.window == 0 || target == 0 {
		return
	}
	c := &w.conn
	x := &w.x
	s := x_begin(w, X_CONVERT_SELECTION)
	xo32(c, x.window)
	xo32(c, x_sel_atom(w, kind))
	xo32(c, target)
	xo32(c, w.clip.a_prop)
	xo32(c, at_time)
	x_end(w, s)

	// Wait for the SelectionNotify, dispatching whatever else arrives.
	mark := hold_input(w)
	defer release_input(w, mark)
	w.clip.x_waiting = true
	w.clip.x_notified = false
	defer w.clip.x_waiting = false
	conn_flush(c)
	deadline := time.time_add(time.now(), CLIP_TIMEOUT)
	x.in_sync += 1
	for !w.clip.x_notified {
		if c.fatal != "" {
			x.in_sync -= 1
			return
		}
		x_consume(w)
		conn_flush(c) // anything a SelectionRequest handler queued
		if w.clip.x_notified {
			break
		}
		left := time.diff(time.now(), deadline)
		if left <= 0 {
			x.in_sync -= 1
			return
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		cnt, perr := linux.poll(pfd[:], i32(max(1, time.duration_milliseconds(left))))
		if perr != .NONE && perr != .EINTR {
			x.in_sync -= 1
			return
		}
		if cnt > 0 && !conn_read(c) {
			x.in_sync -= 1
			return
		}
	}
	x.in_sync -= 1
	if w.clip.x_notify_prop == 0 {
		return // the owner could not convert it
	}

	// GetProperty, deleting it, which tells the owner we are done.
	g := x_begin(w, X_GET_PROPERTY, 1)
	xo32(c, x.window)
	xo32(c, w.clip.a_prop)
	xo32(c, 0) // AnyPropertyType
	xo32(c, 0)
	xo32(c, u32(CLIP_MAX / 4))
	seq := x_end(w, g)
	reply, rok := x_sync(w, seq)
	if !rok || len(reply) < 32 {
		return
	}
	ptype = xr32(reply, 8)
	format = int(xr8(reply, 1))
	n := int(xr32(reply, 16)) * max(format / 8, 1)
	if 32 + n > len(reply) {
		return
	}
	data = make([]u8, n, allocator)
	copy(data, reply[32:32 + n])
	return data, ptype, format, true
}

// x_clip_event handles SelectionClear, SelectionRequest and SelectionNotify.
@(private)
x_clip_event :: proc(w: ^Window, rec: []u8) {
	c := &w.conn
	x := &w.x
	switch int(rec[0] & 0x7f) {
	case X_SELECTION_CLEAR:
		sel := xr32(rec, 12)
		for k in Clip_Kind {
			if sel == x_sel_atom(w, k) {
				clip_disown(&w.clip.sel[k])
			}
		}

	case X_SELECTION_NOTIFY:
		if w.clip.x_waiting && xr32(rec, 8) == x.window {
			w.clip.x_notified = true
			w.clip.x_notify_prop = xr32(rec, 20)
		}

	case X_SELECTION_REQUEST:
		when_ := xr32(rec, 4)
		requestor := xr32(rec, 12)
		sel := xr32(rec, 16)
		target := xr32(rec, 20)
		prop := xr32(rec, 24)
		if prop == 0 {
			prop = target // an obsolete client, per ICCCM 2.2
		}
		kind: Clip_Kind = sel == XA_PRIMARY ? .Primary : .Clipboard
		s := &w.clip.sel[kind]
		answered := u32(0)
		if s.owned && (sel == w.clip.a_clipboard || sel == XA_PRIMARY) {
			switch target {
			case w.clip.a_targets:
				atoms := [?]u32 {
					w.clip.a_targets,
					x.a_utf8_string,
					w.clip.a_mime_utf8,
					w.clip.a_mime_plain,
					w.clip.a_text,
					XA_STRING,
				}
				// slice.to_bytes, not transmute: a transmuted []u32 keeps its
				// element count as the byte length, which sent a quarter of
				// the list and a request the server refused as BadLength.
				x_change_property(w, requestor, prop, XA_ATOM, 32, slice.to_bytes(atoms[:]))
				answered = prop
			case x.a_utf8_string, w.clip.a_mime_utf8, w.clip.a_mime_plain, w.clip.a_text, XA_STRING:
				// One request carries it, or it is refused: INCR is not
				// implemented.
				if len(s.text) + 64 <= x.max_request {
					type := target == w.clip.a_text ? x.a_utf8_string : target
					x_change_property(w, requestor, prop, type, 8, transmute([]u8)s.text)
					answered = prop
				}
			}
		}
		// SelectionNotify, sent to the requestor, with the property or None.
		ev: [32]u8
		ev[0] = X_SELECTION_NOTIFY
		put := proc(b: []u8, o: int, v: u32) {
			bs := transmute([4]u8)v
			copy(b[o:o + 4], bs[:])
		}
		put(ev[:], 4, when_)
		put(ev[:], 8, requestor)
		put(ev[:], 12, sel)
		put(ev[:], 16, target)
		put(ev[:], 20, answered)
		se := x_begin(w, X_SEND_EVENT, 0)
		xo32(c, requestor)
		xo32(c, 0) // no event mask: to the client that created the window
		append(&c.out, ..ev[:])
		x_end(w, se)
		conn_flush(c)
	}
}

// ---------------------------------------------------------------------------
// Watching: the offer, its types, and a read from that same offer
//
//	palmy.clipboard_watch(app)                   once; says how well it can
//	for offer in palmy.clipboard_next_offer(app) {
//		if is_secret(offer.types) { continue }   decided on THIS offer
//		data, err := palmy.clipboard_offer_read(app, offer, "text/plain")
//	}
//
// A selection is announced as an *offer*: an object standing for one owner's
// one copy, with the list of types that copy can be had in. The list and the
// bytes come from the same object, so a caller that looks at an offer's
// types (for a password manager's `x-kde-passwordManagerHint`, say) and then
// reads it is reading the copy it looked at, never the next one. Asking "what
// types are on the clipboard" and then "give me the clipboard" as two
// questions cannot promise that; the selection can change in between.
//
// Every change is queued, in order, as it arrives, and the frame loop is
// woken for it, so two copies made between two frames are two offers, not
// one. `clipboard_next_offer` hands them out one at a time. The offer it
// returned last is *held*: it stays readable, and its `types` stay valid,
// until the next call to `clipboard_next_offer` (or `clipboard_watch` with
// a set that leaves its kind out). A read of anything else is `.Stale`.
//
// How much a window sees depends on the display server, and
// `clipboard_watch` says which:
//
//   .Always       Wayland with ext_data_control_v1 or zwlr_data_control_v1
//                 (sway, Hyprland, KDE, niri, labwc, ...), or X11 with the
//                 XFIXES extension: every change, focused or not. The first
//                 offer is whatever was already on the clipboard.
//   .Focused      Wayland with only wl_data_device (GNOME, for one): a
//                 compositor tells a client about the selection only while it
//                 has keyboard focus. An offer arrives each time the window
//                 gains focus, whether or not the selection changed then.
//   .Unsupported  no window, not the frame loop's thread, or no protocol.
//
// On Wayland, an offer that a newer selection replaced is still a real object
// and a read still goes to its owner; but most owners stop serving once they
// lose the selection (wl-copy exits), and such a read comes back empty. On
// X11 a selection has no object, only an owner, so an offer superseded before
// it was handed out is skipped and counted in the next one's `missed`, and a
// read that the selection changed under is `.Stale` rather than the new
// owner's bytes. X11 reads are one property (INCR is not implemented, as for
// `clipboard_get`), and the type list leaves out the ICCCM meta-targets
// (TARGETS, MULTIPLE, TIMESTAMP, ...), which are not types of the data.
// ---------------------------------------------------------------------------

// Clip_Kinds is a set of selections to watch.
Clip_Kinds :: bit_set[Clip_Kind;u8]

// Clip_Watch is how much of the selection's history a window can see.
Clip_Watch :: enum u8 {
	Unsupported,
	Focused,
	Always,
}

// Clip_Offer is one selection, as `clipboard_next_offer` hands it out.
Clip_Offer :: struct {
	kind:   Clip_Kind,
	// Which offer this is: increasing, never reused by a window. Zero is no
	// offer.
	id:     u64,
	// The types the owner advertised, in its order. Empty when the selection
	// was cleared, or (X11) the owner would not list them. Owned by palmy;
	// valid while this is the held offer.
	types:  []string,
	// The copy is this window's own.
	own:    bool,
	// Selections between the previous offer of this kind and this one that
	// were never handed out: the queue overflowed, or (X11) they were
	// replaced before anybody asked.
	missed: int,
}

// Clip_Error says why `clipboard_offer_read` returned nothing.
Clip_Error :: enum u8 {
	None,
	// No window, not the frame loop's thread, or not watching.
	Unsupported,
	// Not the offer `clipboard_next_offer` returned last, or (X11) the
	// selection changed before its owner answered.
	Stale,
	// The offer does not advertise that type. Nothing was asked of anyone.
	Not_Offered,
	// The owner did not answer in time, or the answer was too big.
	Failed,
}

// The most offers kept waiting; past it the oldest is dropped and counted in
// the next one's `missed`.
@(private)
CLIP_QUEUE_MAX :: 16

@(private)
CTL_MANAGER_GET_DATA_DEVICE :: 1
@(private)
CTL_DEVICE_DESTROY :: 1
@(private)
CTL_OFFER_RECEIVE :: 0

@(private)
Clip_Entry :: struct {
	offer:      Clip_Offer,
	// Wayland: the offer object and which protocol it belongs to.
	handle:     u32,
	hkind:      Obj_Kind,
	// X11: the owner, the time it took the selection, and the selection's
	// generation when it did.
	x_owner:    u32,
	x_time:     u32,
	x_gen:      u64,
	x_want_types: bool,
	// Offscreen: the bytes for each type.
	payloads:   []string,
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

// clip_entry_release frees an entry that has left the queue, and destroys
// its Wayland offer unless something else still refers to it.
@(private)
clip_entry_release :: proc(w: ^Window, e: Clip_Entry) {
	e := e
	handle, hkind := e.handle, e.hkind
	clip_entry_free(&e)
	if w != nil && w.backend == .Wayland {
		wl_offer_release(w, hkind, handle)
	}
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

// clip_queue_push queues an entry, giving it the next id. When the queue is
// full the oldest entry is taken out and returned for the caller to release.
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

// clip_carry_missed counts a selection that is never handed out against the
// next queued one of its kind.
@(private)
clip_carry_missed :: proc(q: ^Clip_Queue, gone: Clip_Offer) {
	for &e in q.entries {
		if e.offer.kind == gone.kind {
			e.offer.missed += gone.missed + 1
			return
		}
	}
}

// clip_queue_keep drops everything of a kind no longer watched, the held
// offer included.
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

// clipboard_offer_has reports whether an offer advertises exactly `mime`.
clipboard_offer_has :: proc(offer: Clip_Offer, mime: string) -> bool {
	for t in offer.types {
		if t == mime {
			return true
		}
	}
	return false
}

// --- public entry points ---------------------------------------------------

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

// clipboard_watch starts queueing every change of the selections in `kinds`
// (the clipboard alone by default) as offers for `clipboard_next_offer`, and
// says how much the display server lets this window see: the weakest of the
// kinds asked for. Calling it again changes the set; `{}` stops watching and
// drops whatever was queued.
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

// clipboard_next_offer hands out the oldest selection change not yet handed
// out, and makes it the held offer: the one `clipboard_offer_read` reads.
// The previously held offer is let go of. With nothing queued it returns
// false, and nothing is held.
//
//	for offer in palmy.clipboard_next_offer(app) { ... }
clipboard_next_offer :: proc {
	clipboard_next_offer_app,
	clipboard_next_offer_ctx,
	clipboard_next_offer_default,
}

@(private)
clipboard_offer_read_app :: proc(
	app: ^App,
	offer: Clip_Offer,
	mime: string,
	allocator := context.allocator,
) -> (
	[]u8,
	Clip_Error,
) {
	w := clip_window(app)
	if w == nil {
		return nil, .Unsupported
	}
	return clip_queue_read(w, &w.clip.watch, offer, mime, allocator)
}
@(private)
clipboard_offer_read_ctx :: proc(
	ctx: ^Ctx,
	offer: Clip_Offer,
	mime: string,
	allocator := context.allocator,
) -> (
	[]u8,
	Clip_Error,
) {
	if ctx != nil && ctx.app == nil {
		return clip_queue_read(nil, &g_offscreen_watch, offer, mime, allocator)
	}
	return clipboard_offer_read_app(ctx != nil ? ctx.app : nil, offer, mime, allocator)
}
@(private)
clipboard_offer_read_default :: proc(
	offer: Clip_Offer,
	mime: string,
	allocator := context.allocator,
) -> (
	[]u8,
	Clip_Error,
) {
	return clipboard_offer_read_app(g_clip_app, offer, mime, allocator)
}

// clipboard_offer_read reads one type of the held offer, untouched: binary
// stays binary and no newline is added or removed. `mime` must be one of the
// offer's `types`. The bytes are the caller's. An empty result with `.None`
// is an owner that sent nothing, which is also what an owner that has gone
// away sends.
clipboard_offer_read :: proc {
	clipboard_offer_read_app,
	clipboard_offer_read_ctx,
	clipboard_offer_read_default,
}

// --- shared --------------------------------------------------------------

@(private)
clip_watch :: proc(w: ^Window, kinds: Clip_Kinds) -> Clip_Watch {
	if w == nil || w.conn.fatal != "" {
		return .Unsupported
	}
	switch w.backend {
	case .Wayland:
		wl_watch_start(w, kinds)
	case .X11:
		x_watch_start(w, kinds)
	}
	return clip_weakest(&w.clip.watch, kinds)
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
		if w != nil && w.backend == .X11 {
			k := e.offer.kind
			if w.clip.x_gen[k] == e.x_gen && e.x_want_types {
				x_fetch_targets(w, &e)
			}
			// Replaced, before or while its types were asked for: what its
			// owner would answer now belongs to the next one.
			if w.clip.x_gen[k] != e.x_gen {
				clip_carry_missed(q, e.offer)
				clip_entry_release(w, e)
				continue
			}
		}
		q.held, q.has_held = e, true
		return e.offer, true
	}
	return {}, false
}

@(private)
clip_queue_read :: proc(
	w: ^Window,
	q: ^Clip_Queue,
	offer: Clip_Offer,
	mime: string,
	allocator := context.allocator,
) -> (
	[]u8,
	Clip_Error,
) {
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
	switch w.backend {
	case .Wayland:
		data, ok := wl_offer_read(w, h.hkind, h.handle, mime, allocator)
		return data, ok ? .None : .Failed
	case .X11:
		target := x_intern(w, mime)
		data, ptype, _, ok := x_clip_convert(w, h.offer.kind, target, h.x_time, allocator)
		if !ok || ptype == w.clip.a_incr {
			delete(data, allocator)
			return nil, .Failed
		}
		if w.clip.x_gen[h.offer.kind] != h.x_gen {
			delete(data, allocator)
			return nil, .Stale
		}
		return data, .None
	}
	return nil, .Unsupported
}

// --- offscreen -------------------------------------------------------------

// An offscreen frame's clipboard can be watched too, so that a caller's
// handling of offers can be tested with no display server. It is per thread,
// because tests run in parallel and each wants its own.
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

// offscreen_clipboard_offer plays another program's copy to an offscreen
// watcher: a selection of `kind` advertising `types`, which serves
// `payloads[i]` for `types[i]`. No types is a cleared selection. False when
// the calling thread is not watching that kind offscreen, or the two lists
// differ in length.
offscreen_clipboard_offer :: proc(kind: Clip_Kind, types: []string, payloads: []string) -> bool {
	if kind not_in g_offscreen_watch.kinds || len(types) != len(payloads) {
		return false
	}
	offscreen_push(kind, types, payloads, false)
	return true
}

// --- Wayland ---------------------------------------------------------------

@(private)
wl_watch_start :: proc(w: ^Window, kinds: Clip_Kinds) {
	c := &w.conn
	q := &w.clip.watch
	added := kinds - q.kinds
	clip_queue_keep(w, q, kinds)
	q.kinds = kinds

	bound := false
	if kinds != {} && w.clip.ctl_name != 0 && w.clip.ctl_dev == 0 && w.wl.seat != 0 {
		if w.clip.ctl_mgr == 0 {
			iface := w.clip.ctl_ext ? "ext_data_control_manager_v1" : "zwlr_data_control_manager_v1"
			w.clip.ctl_mgr = bind_global(w, w.clip.ctl_name, iface, w.clip.ctl_ver, .Control_Manager)
		}
		w.clip.ctl_dev = new_id(c, .Control_Device)
		request(c, w.clip.ctl_mgr, CTL_MANAGER_GET_DATA_DEVICE, Obj(w.clip.ctl_dev), Obj(w.wl.seat))
		bound = true
	}
	wl_watch_modes(w)

	// Data control announces the current selection on its own as soon as
	// the device exists. wl_data_device announced it at the last focus, so
	// a newly watched kind it feeds starts from that.
	for k in added {
		if q.mode[k] == .Focused && w.clip.sel[k].offer != 0 {
			hkind: Obj_Kind = k == .Clipboard ? .Data_Offer : .Primary_Offer
			wl_watch_push(w, k, hkind, w.clip.sel[k].offer, w.clip.sel[k].types[:])
		}
	}
	if bound {
		mark := hold_input(w)
		roundtrip(w)
		release_input(w, mark)
	}
}

// wl_watch_modes works out, per kind, which protocol feeds the queue.
@(private)
wl_watch_modes :: proc(w: ^Window) {
	q := &w.clip.watch
	for k in Clip_Kind {
		m := Clip_Watch.Unsupported
		if k in q.kinds {
			switch k {
			case .Clipboard:
				if w.clip.ctl_dev != 0 {
					m = .Always
				} else if w.clip.device != 0 {
					m = .Focused
				}
			case .Primary:
				// zwlr_data_control_v1 has the primary selection from v2.
				if w.clip.ctl_dev != 0 && (w.clip.ctl_ext || w.clip.ctl_ver >= 2) {
					m = .Always
				} else if w.clip.pdevice != 0 {
					m = .Focused
				}
			}
		}
		q.mode[k] = m
	}
}

// wl_ctl_selection is data control's selection event: queued when watched,
// destroyed at once otherwise.
@(private)
wl_ctl_selection :: proc(w: ^Window, kind: Clip_Kind, id: u32) {
	q := &w.clip.watch
	if kind in q.kinds && q.mode[kind] == .Always {
		types: []string
		if list, found := w.clip.pending[id]; found {
			types = list[:]
		}
		wl_watch_push(w, kind, .Control_Offer, id, types)
		if list, found := w.clip.pending[id]; found {
			for t in list {
				delete(t)
			}
			delete(list)
			delete_key(&w.clip.pending, id)
		}
		return
	}
	wl_offer_release(w, .Control_Offer, id)
}

@(private)
wl_watch_push :: proc(w: ^Window, kind: Clip_Kind, hkind: Obj_Kind, id: u32, types: []string) {
	s := &w.clip.sel[kind]
	e := Clip_Entry {
		offer = {kind = kind, types = clip_clone_types(types), own = s.owned && s.source != 0},
		handle = id,
		hkind = hkind,
	}
	if dropped, did := clip_queue_push(&w.clip.watch, e); did {
		clip_entry_release(w, dropped)
	}
	// A frame, so that the caller hears of it now and not at the next key.
	w.input_dirty = true
}

// wl_offer_release destroys an offer nobody refers to any more: not the
// current selection `clipboard_get` reads, and not a watcher's.
@(private)
wl_offer_release :: proc(w: ^Window, hkind: Obj_Kind, id: u32) {
	if id == 0 {
		return
	}
	if hkind == .Data_Offer && w.clip.sel[.Clipboard].offer == id {
		return
	}
	if hkind == .Primary_Offer && w.clip.sel[.Primary].offer == id {
		return
	}
	q := &w.clip.watch
	for e in q.entries {
		if e.handle == id {
			return
		}
	}
	if q.has_held && q.held.handle == id {
		return
	}
	wl_offer_destroy(w, hkind, id)
}

// wl_offer_read asks an offer for one type and reads the pipe to its end.
// Events keep being dispatched while it waits, because the owner may be this
// very window: its `send` has to be answered for the read to finish.
@(private)
wl_offer_read :: proc(
	w: ^Window,
	hkind: Obj_Kind,
	id: u32,
	mime: string,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	c := &w.conn
	if id == 0 {
		return nil, false
	}
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE {
		return nil, false
	}
	op: u16 = hkind == .Data_Offer ? WL_DATA_OFFER_RECEIVE : CTL_OFFER_RECEIVE // primary's is 0 too
	request(c, id, op, mime, Fd(fds[1]))
	conn_flush(c)
	defer linux.close(fds[0])

	mark := hold_input(w)
	defer release_input(w, mark)

	out := make([dynamic]u8, 0, 4096, allocator)
	deadline := time.time_add(time.now(), CLIP_TIMEOUT)
	buf: [16 * 1024]u8
	for {
		left := time.diff(time.now(), deadline)
		if left <= 0 || c.fatal != "" {
			delete(out)
			return nil, false
		}
		pfd := [2]linux.Poll_Fd{{fd = fds[0], events = {.IN}}, {fd = c.fd, events = {.IN}}}
		n, perr := linux.poll(pfd[:], i32(max(1, time.duration_milliseconds(left))))
		if perr == .EINTR {
			continue
		}
		if perr != .NONE {
			delete(out)
			return nil, false
		}
		if n == 0 {
			continue
		}
		if .IN in pfd[1].revents {
			if !conn_read(c) {
				delete(out)
				return nil, false
			}
			wl_dispatch_pending(c, w)
			conn_flush(c)
		}
		if pfd[0].revents == {} {
			continue
		}
		got, rerr := linux.read(fds[0], buf[:])
		if rerr == .EINTR || rerr == .EAGAIN {
			continue
		}
		if rerr != .NONE {
			delete(out)
			return nil, false
		}
		if got == 0 {
			break
		}
		if len(out) + got > CLIP_MAX {
			delete(out)
			return nil, false
		}
		append(&out, ..buf[:got])
	}
	return out[:], true
}

// --- X11 -------------------------------------------------------------------

@(private)
XFIXES_QUERY_VERSION :: 0
@(private)
XFIXES_SELECT_SELECTION_INPUT :: 2
@(private)
X_GET_ATOM_NAME :: 17

@(private)
x_watch_start :: proc(w: ^Window, kinds: Clip_Kinds) {
	c := &w.conn
	q := &w.clip.watch
	if !w.clip.xf_tried && w.clip.x_ready && w.x.window != 0 {
		w.clip.xf_tried = true
		s := x_begin(w, X_QUERY_EXTENSION, 0)
		name := "XFIXES"
		xo16(c, u16(len(name)))
		xo16(c, 0)
		append(&c.out, name)
		seq := x_end(w, s)
		if reply, ok := x_sync(w, seq); ok && xr8(reply, 8) != 0 {
			major, first := xr8(reply, 9), xr8(reply, 10)
			// The version must be negotiated before any other request.
			s2 := x_begin(w, major, XFIXES_QUERY_VERSION)
			xo32(c, 5)
			xo32(c, 0)
			seq2 := x_end(w, s2)
			if _, vok := x_sync(w, seq2); vok {
				w.clip.xf_major, w.clip.xf_first_event = major, first
				w.clip.xf_ready = true
			}
		}
	}

	added := kinds - q.kinds
	clip_queue_keep(w, q, kinds)
	q.kinds = kinds
	for k in Clip_Kind {
		q.mode[k] = k in kinds && w.clip.xf_ready ? .Always : .Unsupported
	}
	if !w.clip.xf_ready {
		return
	}
	for k in Clip_Kind {
		// SetSelectionOwner, SelectionWindowDestroy, SelectionClientClose.
		s := x_begin(w, w.clip.xf_major, XFIXES_SELECT_SELECTION_INPUT)
		xo32(c, w.x.window)
		xo32(c, x_sel_atom(w, k))
		xo32(c, k in kinds ? 7 : 0)
		x_end(w, s)
	}
	// XFIXES says nothing about the selection already there, so a newly
	// watched kind starts from its current owner -- unless the owner changed
	// while we asked, which queued a fresher offer already.
	for k in added {
		gen := w.clip.x_gen[k]
		s := x_begin(w, X_GET_SELECTION_OWNER)
		xo32(c, x_sel_atom(w, k))
		seq := x_end(w, s)
		mark := hold_input(w)
		reply, ok := x_sync(w, seq)
		release_input(w, mark)
		if !ok || w.clip.x_gen[k] != gen {
			continue
		}
		w.clip.x_gen[k] += 1
		x_watch_push(w, k, xr32(reply, 8), 0)
	}
}

@(private)
x_watch_push :: proc(w: ^Window, kind: Clip_Kind, owner, at_time: u32) {
	e := Clip_Entry {
		offer = {kind = kind, own = owner != 0 && owner == w.x.window},
		x_owner = owner,
		x_time = at_time,
		x_gen = w.clip.x_gen[kind],
		x_want_types = owner != 0,
	}
	if dropped, did := clip_queue_push(&w.clip.watch, e); did {
		clip_entry_release(w, dropped)
	}
	w.input_dirty = true
}

// x_clip_xfixes_event takes XFixesSelectionNotify; false for anything else.
@(private)
x_clip_xfixes_event :: proc(w: ^Window, rec: []u8) -> bool {
	if !w.clip.xf_ready || rec[0] & 0x7f != w.clip.xf_first_event {
		return false
	}
	sel := xr32(rec, 12)
	for k in Clip_Kind {
		if sel != x_sel_atom(w, k) {
			continue
		}
		w.clip.x_gen[k] += 1
		q := &w.clip.watch
		if k in q.kinds && q.mode[k] == .Always {
			// owner at 8, selection_timestamp at 20: the time the owner
			// took it, which the conversions are then made at.
			x_watch_push(w, k, xr32(rec, 8), xr32(rec, 20))
		}
	}
	return true
}

// x_fetch_targets fills an entry's types from its owner's TARGETS.
@(private)
x_fetch_targets :: proc(w: ^Window, e: ^Clip_Entry) {
	e.x_want_types = false
	data, ptype, format, ok := x_clip_convert(w, e.offer.kind, w.clip.a_targets, e.x_time)
	defer delete(data)
	x_debug(w, "TARGETS of %v at time %d: ok=%v type=%d format=%d, %d bytes", e.offer.kind, e.x_time, ok, ptype, format, len(data))
	if !ok || ptype != XA_ATOM || format != 32 {
		return
	}
	list := make([dynamic]string, 0, len(data) / 4)
	for i := 0; i + 4 <= len(data); i += 4 {
		name := x_atom_name(w, xr32(data, i))
		switch name {
		case "", "TARGETS", "MULTIPLE", "TIMESTAMP", "SAVE_TARGETS", "DELETE", "INSERT_SELECTION", "INSERT_PROPERTY":
			continue
		}
		dup := false
		for t in list {
			if t == name {
				dup = true
			}
		}
		if !dup {
			append(&list, strings.clone(name))
		}
	}
	if len(list) == 0 {
		delete(list)
		return
	}
	e.offer.types = list[:]
}

// x_atom_name is GetAtomName, remembered: the same few dozen atoms come back
// on every copy.
@(private)
x_atom_name :: proc(w: ^Window, atom: u32) -> string {
	if atom == 0 {
		return ""
	}
	if name, found := w.clip.atom_names[atom]; found {
		return name
	}
	c := &w.conn
	s := x_begin(w, X_GET_ATOM_NAME)
	xo32(c, atom)
	seq := x_end(w, s)
	reply, ok := x_sync(w, seq)
	if !ok || len(reply) < 32 {
		return ""
	}
	n := int(xr16(reply, 8))
	if 32 + n > len(reply) {
		return ""
	}
	name := strings.clone(string(reply[32:32 + n]))
	w.clip.atom_names[atom] = name
	return name
}
