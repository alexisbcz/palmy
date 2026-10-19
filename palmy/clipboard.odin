package palmy

import "core:os"
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
	if id == 0 {
		return
	}
	c := &w.conn
	request(c, id, kind == .Clipboard ? WL_DATA_OFFER_DESTROY : PRIMARY_OFFER_DESTROY)
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
	wl_clip_offer_destroy(w, kind, old)
	if id == 0 {
		return
	}
	s.offer = id
	if list, found := w.clip.pending[id]; found {
		append(&s.types, ..list[:])
		delete(list)
		delete_key(&w.clip.pending, id)
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

	case .Data_Offer, .Primary_Offer:
		if opcode == 0 {
			mime := r_string(r)
			if list, found := &w.clip.pending[id]; found {
				append(list, strings.clone(mime))
			} else {
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
	c := &w.conn
	x := &w.x
	s := x_begin(w, X_CONVERT_SELECTION)
	xo32(c, x.window)
	xo32(c, x_sel_atom(w, kind))
	xo32(c, x.a_utf8_string)
	xo32(c, w.clip.a_prop)
	xo32(c, w.clip.x_time)
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
			return "", false
		}
		x_consume(w)
		conn_flush(c) // anything a SelectionRequest handler queued
		if w.clip.x_notified {
			break
		}
		left := time.diff(time.now(), deadline)
		if left <= 0 {
			x.in_sync -= 1
			return "", false
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		cnt, perr := linux.poll(pfd[:], i32(max(1, time.duration_milliseconds(left))))
		if perr != .NONE && perr != .EINTR {
			x.in_sync -= 1
			return "", false
		}
		if cnt > 0 && !conn_read(c) {
			x.in_sync -= 1
			return "", false
		}
	}
	x.in_sync -= 1
	if w.clip.x_notify_prop == 0 {
		return "", false // the owner could not convert it
	}

	// GetProperty, deleting it, which tells the owner we are done.
	g := x_begin(w, X_GET_PROPERTY, 1)
	xo32(c, x.window)
	xo32(c, w.clip.a_prop)
	xo32(c, 0) // AnyPropertyType
	xo32(c, 0)
	xo32(c, u32(CLIP_MAX / 4))
	seq := x_end(w, g)
	reply, ok := x_sync(w, seq)
	if !ok || len(reply) < 32 {
		return "", false
	}
	ptype := xr32(reply, 8)
	if ptype == w.clip.a_incr || ptype == 0 {
		return "", false // INCR is not implemented
	}
	format := int(xr8(reply, 1))
	n := int(xr32(reply, 16)) * max(format / 8, 1)
	if format != 8 || 32 + n > len(reply) || n == 0 {
		return "", false
	}
	return strings.clone(string(reply[32:32 + n]), allocator), true
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
				x_change_property(w, requestor, prop, XA_ATOM, 32, transmute([]u8)atoms[:])
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
