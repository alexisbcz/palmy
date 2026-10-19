// The engine protocol, Odin side. engine/proto.h is the reference and says
// what every message means; this file mirrors its numbers and gives both
// directions an encoder and a decoder, so the chrome (which writes the
// chrome->host half) and the Gecko host (which writes the host->chrome half)
// share one implementation, and the self-test can round-trip all of it.
package pb

import "core:mem"

PB_VERSION :: 1

Op :: enum u16 {
	// chrome -> host
	Hello_App       = 1,
	Create          = 2,
	Close           = 3,
	Navigate        = 4,
	History         = 5,
	Reload          = 6,
	Stop            = 7,
	Resize          = 8,
	Show            = 9,
	Focus           = 10,
	Mouse           = 11,
	Wheel           = 12,
	Key             = 13,
	Frame_Ack       = 14,
	Zoom            = 15,
	Dialog_Reply    = 16,
	Find            = 17,
	Download_Cancel = 18,
	Quit            = 19,
	Menu_Reply      = 20,
	Edit            = 21,
	Theme           = 22,
	Fill            = 23,
	// host -> chrome
	Hello           = 100,
	Buffer          = 101,
	Frame           = 102,
	Title           = 103,
	Url             = 104,
	Favicon         = 105,
	Load            = 106,
	Progress        = 107,
	Cursor          = 108,
	Open_Tab        = 109,
	Dialog          = 110,
	Download        = 111,
	Status          = 112,
	Crashed         = 113,
	Find_Result     = 114,
	Ready           = 115,
	Log             = 116,
	Closed          = 117,
	Load_Error      = 118,
	Menu            = 119,
	Selection       = 120,
	Field_Focus     = 121,
	Form_Submit     = 122,
	Fill_Result     = 123,
}

Field_Kind :: enum u8 {
	None     = 0,
	Username = 1,
	Password = 2,
	Otp      = 3,
}
Fill_Status :: enum u8 {
	Ok             = 0,
	Origin_Changed = 1,
	No_Field       = 2,
	Form_Action    = 3,
	Failed         = 4,
}

Mouse_Kind :: enum u8 {
	Move  = 0,
	Down  = 1,
	Up    = 2,
	Leave = 3,
}
Button :: enum u8 {
	Left   = 0,
	Middle = 1,
	Right  = 2,
}
Key_Kind :: enum u8 {
	Down = 0,
	Up   = 1,
	Char = 2,
}

MOD_SHIFT :: u32(1)
MOD_CTRL :: u32(2)
MOD_ALT :: u32(4)
MOD_SUPER :: u32(8)

Dialog_Kind :: enum u8 {
	Alert         = 0,
	Confirm       = 1,
	Prompt        = 2,
	Before_Unload = 3,
}
Download_State :: enum u8 {
	Progress  = 0,
	Done      = 1,
	Cancelled = 2,
	Failed    = 3,
}
Menu_Kind :: enum u8 {
	Item      = 0,
	Separator = 1,
	Checked   = 2,
}
Edit_Action :: enum u8 {
	Undo       = 0,
	Redo       = 1,
	Cut        = 2,
	Copy       = 3,
	Paste      = 4,
	Select_All = 5,
	Insert     = 6,
}
Page_Cursor :: enum u8 {
	Default     = 0,
	Pointer     = 1,
	Text        = 2,
	Wait        = 3,
	Crosshair   = 4,
	Move        = 5,
	Not_Allowed = 6,
	Grab        = 7,
	EW_Resize   = 8,
	NS_Resize   = 9,
	None        = 10,
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

Msg :: struct {
	b: [dynamic]u8,
}

msg_begin :: proc(op: Op, view: int, allocator := context.allocator) -> Msg {
	m := Msg{b = make([dynamic]u8, 0, 64, allocator)}
	w_u32(&m, 0)
	w_u16(&m, u16(op))
	w_u16(&m, u16(view))
	return m
}

// msg_bytes patches the size into the header and returns the finished bytes.
msg_bytes :: proc(m: ^Msg) -> []u8 {
	n := u32(len(m.b))
	mem.copy(&m.b[0], &n, 4)
	return m.b[:]
}

w_raw :: proc(m: ^Msg, p: rawptr, n: int) {
	bytes := ([^]u8)(p)[:n]
	append(&m.b, ..bytes)
}
w_u8 :: proc(m: ^Msg, v: u8) {append(&m.b, v)}
w_u16 :: proc(m: ^Msg, v: u16) {v := v;w_raw(m, &v, 2)}
w_u32 :: proc(m: ^Msg, v: u32) {v := v;w_raw(m, &v, 4)}
w_i32 :: proc(m: ^Msg, v: i32) {v := v;w_raw(m, &v, 4)}
w_i64 :: proc(m: ^Msg, v: i64) {v := v;w_raw(m, &v, 8)}
w_f32 :: proc(m: ^Msg, v: f32) {v := v;w_raw(m, &v, 4)}
w_str :: proc(m: ^Msg, s: string) {
	w_u32(m, u32(len(s)))
	append(&m.b, ..transmute([]u8)s)
}
w_bytes :: proc(m: ^Msg, b: []u8) {
	w_u32(m, u32(len(b)))
	append(&m.b, ..b)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

Rd :: struct {
	b:   []u8,
	at:  int,
	bad: bool,
}

r_take :: proc(r: ^Rd, n: int) -> []u8 {
	if r.at + n > len(r.b) {
		r.bad = true
		r.at = len(r.b)
		return nil
	}
	s := r.b[r.at:r.at + n]
	r.at += n
	return s
}
r_u8 :: proc(r: ^Rd) -> u8 {
	s := r_take(r, 1)
	return s == nil ? 0 : s[0]
}
r_u16 :: proc(r: ^Rd) -> u16 {
	v: u16
	if s := r_take(r, 2); s != nil {mem.copy(&v, raw_data(s), 2)}
	return v
}
r_u32 :: proc(r: ^Rd) -> u32 {
	v: u32
	if s := r_take(r, 4); s != nil {mem.copy(&v, raw_data(s), 4)}
	return v
}
r_i32 :: proc(r: ^Rd) -> i32 {return i32(r_u32(r))}
r_i64 :: proc(r: ^Rd) -> i64 {
	v: i64
	if s := r_take(r, 8); s != nil {mem.copy(&v, raw_data(s), 8)}
	return v
}
r_f32 :: proc(r: ^Rd) -> f32 {
	v: f32
	if s := r_take(r, 4); s != nil {mem.copy(&v, raw_data(s), 4)}
	return v
}
// r_str borrows from the message; clone it to keep it.
r_str :: proc(r: ^Rd) -> string {
	n := int(r_u32(r))
	if n < 0 || n > len(r.b) {
		r.bad = true
		return ""
	}
	return string(r_take(r, n))
}
r_bytes :: proc(r: ^Rd) -> []u8 {
	n := int(r_u32(r))
	if n < 0 || n > len(r.b) {
		r.bad = true
		return nil
	}
	return r_take(r, n)
}

// A decoded message from the host. Strings borrow from `raw`, which the
// event owns; event_free releases it.
Rect_I :: struct {
	x, y, w, h: i32,
}

Menu_Item :: struct {
	command: i32,
	kind:    Menu_Kind,
	enabled: bool,
	label:   string,
}

Event :: struct {
	op:          Op,
	view:        int,
	raw:         []u8,
	fd:          int, // Buffer only; -1 otherwise
	// payload, by op
	str:         string, // Title Url Status Crashed Log Selection, Hello engine
	str2:        string, // Hello version, Dialog default, Load_Error url
	w, h:        i32, // Buffer w/h, Find_Result count/active
	stride:      i32,
	rects:       []Rect_I, // Frame
	loading:     bool,
	can_back:    bool,
	can_forward: bool,
	progress:    f32,
	cursor:      Page_Cursor,
	foreground:  bool,
	id:          u32, // Dialog, Download, Menu
	dialog:      Dialog_Kind,
	dl_state:    Download_State,
	received:    i64,
	total:       i64,
	path:        string,
	mime:        string,
	code:        i32,
	png:         []u8,
	x, y:        f32,
	link:        string,
	selection:   string,
	src:         string,
	editable:    bool,
	items:       []Menu_Item,
	field:       Field_Kind, // Field_Focus
	fw, fh:      f32, // Field_Focus: the field's size (x, y: its corner)
	username:    string, // Form_Submit
	password:    string, // Form_Submit; event_free wipes it
	old_password: string, // Form_Submit
	fill:        Fill_Status, // Fill_Result
}

// decode_event parses one host->chrome message. `raw` must hold exactly one
// message, header included; the event keeps it.
decode_event :: proc(raw: []u8, fd := -1, allocator := context.allocator) -> (e: Event, ok: bool) {
	if len(raw) < 8 {
		return {}, false
	}
	r := Rd{b = raw[8:]}
	e.raw = raw
	e.fd = fd
	e.op = Op(r_u16(&Rd{b = raw[4:6]}))
	e.view = int(r_u16(&Rd{b = raw[6:8]}))
	#partial switch e.op {
	case .Hello:
		e.str = r_str(&r)
		e.str2 = r_str(&r)
	case .Buffer:
		e.w = r_i32(&r)
		e.h = r_i32(&r)
		e.stride = r_i32(&r)
	case .Frame:
		n := int(r_u32(&r))
		if n < 0 || n > 4096 {
			return e, false
		}
		e.rects = make([]Rect_I, n, allocator)
		for i in 0 ..< n {
			e.rects[i] = {r_i32(&r), r_i32(&r), r_i32(&r), r_i32(&r)}
		}
	case .Title, .Url, .Status, .Crashed, .Log, .Selection:
		e.str = r_str(&r)
	case .Favicon:
		e.str = r_str(&r)
		e.png = r_bytes(&r)
	case .Load:
		e.loading = r_u8(&r) != 0
		e.can_back = r_u8(&r) != 0
		e.can_forward = r_u8(&r) != 0
	case .Progress:
		e.progress = r_f32(&r)
	case .Cursor:
		e.cursor = Page_Cursor(r_u8(&r))
	case .Open_Tab:
		e.foreground = r_u8(&r) != 0
		e.str = r_str(&r)
	case .Dialog:
		e.id = r_u32(&r)
		e.dialog = Dialog_Kind(r_u8(&r))
		e.str = r_str(&r)
		e.str2 = r_str(&r)
	case .Download:
		e.id = r_u32(&r)
		e.dl_state = Download_State(r_u8(&r))
		e.received = r_i64(&r)
		e.total = r_i64(&r)
		e.str = r_str(&r)
		e.path = r_str(&r)
		e.mime = r_str(&r)
	case .Find_Result:
		e.w = r_i32(&r)
		e.h = r_i32(&r)
	case .Load_Error:
		e.code = r_i32(&r)
		e.str = r_str(&r)
		e.str2 = r_str(&r)
	case .Menu:
		e.id = r_u32(&r)
		e.x = r_f32(&r)
		e.y = r_f32(&r)
		e.link = r_str(&r)
		e.selection = r_str(&r)
		e.src = r_str(&r)
		e.editable = r_u8(&r) != 0
		n := int(r_u32(&r))
		if n < 0 || n > 256 {
			return e, false
		}
		e.items = make([]Menu_Item, n, allocator)
		for i in 0 ..< n {
			e.items[i].command = r_i32(&r)
			e.items[i].kind = Menu_Kind(r_u8(&r))
			e.items[i].enabled = r_u8(&r) != 0
			e.items[i].label = r_str(&r)
		}
	case .Field_Focus:
		e.field = Field_Kind(r_u8(&r))
		e.x = r_f32(&r)
		e.y = r_f32(&r)
		e.fw = r_f32(&r)
		e.fh = r_f32(&r)
		e.str = r_str(&r)
	case .Form_Submit:
		e.str = r_str(&r)
		e.username = r_str(&r)
		e.password = r_str(&r)
		e.old_password = r_str(&r)
	case .Fill_Result:
		e.fill = Fill_Status(r_u8(&r))
	case .Ready, .Closed:
	}
	return e, !r.bad
}

// wipe zeroes bytes that held a secret before they are freed.
wipe :: proc(b: []u8) {
	if len(b) > 0 {
		mem.zero_explicit(raw_data(b), len(b))
	}
}

event_free :: proc(e: ^Event) {
	// a submitted form's password lives in `raw`; never hand it back to the
	// allocator readable
	if e.op == .Form_Submit || e.op == .Fill {
		wipe(e.raw)
	}
	delete(e.raw)
	delete(e.rects)
	delete(e.items)
	e^ = {}
}

// ---------------------------------------------------------------------------
// The requests a host receives, decoded. The Gecko host reads these; the
// self-test round-trips them.
// ---------------------------------------------------------------------------

Request :: struct {
	op:         Op,
	view:       int,
	w, h:       i32,
	scale:      f32,
	str:        string,
	str2:       string,
	str3:       string,
	n:          i32, // History delta, Menu_Reply command
	flag:       bool, // Reload bypass, Show visible, Focus focused, Dialog ok, Find forward
	flag2:      bool, // Find next
	mouse:      Mouse_Kind,
	button:     Button,
	clicks:     u8,
	mods:       u32,
	x, y:       f32,
	dx, dy:     f32,
	key:        Key_Kind,
	keysym:     u32,
	codepoint:  u32,
	id:         u32,
	factor:     f32,
	edit:       Edit_Action,
	version:    u32,
	str4:       string, // Fill: otp
}

decode_request :: proc(raw: []u8) -> (q: Request, ok: bool) {
	if len(raw) < 8 {
		return {}, false
	}
	q.op = Op(r_u16(&Rd{b = raw[4:6]}))
	q.view = int(r_u16(&Rd{b = raw[6:8]}))
	r := Rd{b = raw[8:]}
	#partial switch q.op {
	case .Hello_App:
		q.version = r_u32(&r)
		q.str = r_str(&r)
		q.str2 = r_str(&r)
		q.str3 = r_str(&r)
	case .Create:
		q.w = r_i32(&r)
		q.h = r_i32(&r)
		q.scale = r_f32(&r)
		q.str = r_str(&r)
	case .Navigate:
		q.str = r_str(&r)
	case .History:
		q.n = r_i32(&r)
	case .Reload:
		q.flag = r_u8(&r) != 0
	case .Resize:
		q.w = r_i32(&r)
		q.h = r_i32(&r)
		q.scale = r_f32(&r)
	case .Show, .Focus, .Theme:
		q.flag = r_u8(&r) != 0
	case .Mouse:
		q.mouse = Mouse_Kind(r_u8(&r))
		q.button = Button(r_u8(&r))
		q.clicks = r_u8(&r)
		r_u8(&r)
		q.mods = r_u32(&r)
		q.x = r_f32(&r)
		q.y = r_f32(&r)
	case .Wheel:
		q.mods = r_u32(&r)
		q.x = r_f32(&r)
		q.y = r_f32(&r)
		q.dx = r_f32(&r)
		q.dy = r_f32(&r)
	case .Key:
		q.key = Key_Kind(r_u8(&r))
		r_u8(&r);r_u8(&r);r_u8(&r)
		q.mods = r_u32(&r)
		q.keysym = r_u32(&r)
		q.codepoint = r_u32(&r)
	case .Zoom:
		q.factor = r_f32(&r)
	case .Dialog_Reply:
		q.id = r_u32(&r)
		q.flag = r_u8(&r) != 0
		q.str = r_str(&r)
	case .Find:
		q.flag = r_u8(&r) != 0
		q.flag2 = r_u8(&r) != 0
		q.str = r_str(&r)
	case .Download_Cancel:
		q.id = r_u32(&r)
	case .Menu_Reply:
		q.id = r_u32(&r)
		q.n = r_i32(&r)
	case .Edit:
		q.edit = Edit_Action(r_u8(&r))
		q.str = r_str(&r)
	case .Fill:
		q.str = r_str(&r) // origin
		q.str2 = r_str(&r) // username
		q.str3 = r_str(&r) // password
		q.str4 = r_str(&r) // otp
	case .Close, .Stop, .Frame_Ack, .Quit:
	}
	return q, !r.bad
}

// ---------------------------------------------------------------------------
// Builders for the chrome's requests
// ---------------------------------------------------------------------------

req_hello :: proc(profile, downloads, keymap: string) -> Msg {
	m := msg_begin(.Hello_App, 0)
	w_u32(&m, PB_VERSION)
	w_str(&m, profile)
	w_str(&m, downloads)
	w_str(&m, keymap)
	return m
}
req_create :: proc(view: int, w, h: int, scale: f32, url: string) -> Msg {
	m := msg_begin(.Create, view)
	w_i32(&m, i32(w))
	w_i32(&m, i32(h))
	w_f32(&m, scale)
	w_str(&m, url)
	return m
}
req_simple :: proc(op: Op, view: int) -> Msg {
	return msg_begin(op, view)
}
req_str :: proc(op: Op, view: int, s: string) -> Msg {
	m := msg_begin(op, view)
	w_str(&m, s)
	return m
}
req_i32 :: proc(op: Op, view: int, v: i32) -> Msg {
	m := msg_begin(op, view)
	w_i32(&m, v)
	return m
}
req_flag :: proc(op: Op, view: int, v: bool) -> Msg {
	m := msg_begin(op, view)
	w_u8(&m, v ? 1 : 0)
	return m
}
req_resize :: proc(view: int, w, h: int, scale: f32) -> Msg {
	m := msg_begin(.Resize, view)
	w_i32(&m, i32(w))
	w_i32(&m, i32(h))
	w_f32(&m, scale)
	return m
}
req_mouse :: proc(view: int, kind: Mouse_Kind, button: Button, clicks: int, mods: u32, x, y: f32) -> Msg {
	m := msg_begin(.Mouse, view)
	w_u8(&m, u8(kind))
	w_u8(&m, u8(button))
	w_u8(&m, u8(clicks))
	w_u8(&m, 0)
	w_u32(&m, mods)
	w_f32(&m, x)
	w_f32(&m, y)
	return m
}
req_wheel :: proc(view: int, mods: u32, x, y, dx, dy: f32) -> Msg {
	m := msg_begin(.Wheel, view)
	w_u32(&m, mods)
	w_f32(&m, x)
	w_f32(&m, y)
	w_f32(&m, dx)
	w_f32(&m, dy)
	return m
}
req_key :: proc(view: int, kind: Key_Kind, mods: u32, keysym: u32, codepoint: u32) -> Msg {
	m := msg_begin(.Key, view)
	w_u8(&m, u8(kind))
	w_u8(&m, 0);w_u8(&m, 0);w_u8(&m, 0)
	w_u32(&m, mods)
	w_u32(&m, keysym)
	w_u32(&m, codepoint)
	return m
}
req_zoom :: proc(view: int, factor: f32) -> Msg {
	m := msg_begin(.Zoom, view)
	w_f32(&m, factor)
	return m
}
req_dialog_reply :: proc(view: int, id: u32, ok: bool, text: string) -> Msg {
	m := msg_begin(.Dialog_Reply, view)
	w_u32(&m, id)
	w_u8(&m, ok ? 1 : 0)
	w_str(&m, text)
	return m
}
req_find :: proc(view: int, text: string, forward, next: bool) -> Msg {
	m := msg_begin(.Find, view)
	w_u8(&m, forward ? 1 : 0)
	w_u8(&m, next ? 1 : 0)
	w_str(&m, text)
	return m
}
req_menu_reply :: proc(view: int, id: u32, command: i32) -> Msg {
	m := msg_begin(.Menu_Reply, view)
	w_u32(&m, id)
	w_i32(&m, command)
	return m
}
req_edit :: proc(view: int, action: Edit_Action, text := "") -> Msg {
	m := msg_begin(.Edit, view)
	w_u8(&m, u8(action))
	w_str(&m, text)
	return m
}
// req_fill carries a password: the caller wipes the message bytes after
// sending (send_secret does).
req_fill :: proc(view: int, origin, username, password, otp: string) -> Msg {
	// sized up front, so no reallocation leaves a copy of the password behind
	m := Msg{b = make([dynamic]u8, 0, 8 + 16 + len(origin) + len(username) + len(password) + len(otp))}
	w_u32(&m, 0)
	w_u16(&m, u16(Op.Fill))
	w_u16(&m, u16(view))
	w_str(&m, origin)
	w_str(&m, username)
	w_str(&m, password)
	w_str(&m, otp)
	return m
}
req_u32 :: proc(op: Op, view: int, v: u32) -> Msg {
	m := msg_begin(op, view)
	w_u32(&m, v)
	return m
}

// ---------------------------------------------------------------------------
// Builders for the host's events (used by the Gecko host and the self-test)
// ---------------------------------------------------------------------------

ev_hello :: proc(engine, version: string) -> Msg {
	m := msg_begin(.Hello, 0)
	w_str(&m, engine)
	w_str(&m, version)
	return m
}
ev_str :: proc(op: Op, view: int, s: string) -> Msg {
	return req_str(op, view, s)
}
ev_buffer :: proc(view: int, w, h, stride: int) -> Msg {
	m := msg_begin(.Buffer, view)
	w_i32(&m, i32(w))
	w_i32(&m, i32(h))
	w_i32(&m, i32(stride))
	return m
}
ev_frame :: proc(view: int, rects: []Rect_I) -> Msg {
	m := msg_begin(.Frame, view)
	w_u32(&m, u32(len(rects)))
	for r in rects {
		w_i32(&m, r.x)
		w_i32(&m, r.y)
		w_i32(&m, r.w)
		w_i32(&m, r.h)
	}
	return m
}
ev_load :: proc(view: int, loading, back, forward: bool) -> Msg {
	m := msg_begin(.Load, view)
	w_u8(&m, loading ? 1 : 0)
	w_u8(&m, back ? 1 : 0)
	w_u8(&m, forward ? 1 : 0)
	return m
}
ev_progress :: proc(view: int, p: f32) -> Msg {
	m := msg_begin(.Progress, view)
	w_f32(&m, p)
	return m
}
ev_cursor :: proc(view: int, c: Page_Cursor) -> Msg {
	m := msg_begin(.Cursor, view)
	w_u8(&m, u8(c))
	return m
}
ev_open_tab :: proc(view: int, url: string, foreground: bool) -> Msg {
	m := msg_begin(.Open_Tab, view)
	w_u8(&m, foreground ? 1 : 0)
	w_str(&m, url)
	return m
}
ev_dialog :: proc(view: int, id: u32, kind: Dialog_Kind, message, def: string) -> Msg {
	m := msg_begin(.Dialog, view)
	w_u32(&m, id)
	w_u8(&m, u8(kind))
	w_str(&m, message)
	w_str(&m, def)
	return m
}
ev_download :: proc(view: int, id: u32, state: Download_State, received, total: i64, url, path, mime: string) -> Msg {
	m := msg_begin(.Download, view)
	w_u32(&m, id)
	w_u8(&m, u8(state))
	w_i64(&m, received)
	w_i64(&m, total)
	w_str(&m, url)
	w_str(&m, path)
	w_str(&m, mime)
	return m
}
ev_favicon :: proc(view: int, url: string, png: []u8) -> Msg {
	m := msg_begin(.Favicon, view)
	w_str(&m, url)
	w_bytes(&m, png)
	return m
}
ev_load_error :: proc(view: int, code: i32, text, url: string) -> Msg {
	m := msg_begin(.Load_Error, view)
	w_i32(&m, code)
	w_str(&m, text)
	w_str(&m, url)
	return m
}
ev_field_focus :: proc(view: int, kind: Field_Kind, x, y, w, h: f32, origin: string) -> Msg {
	m := msg_begin(.Field_Focus, view)
	w_u8(&m, u8(kind))
	w_f32(&m, x)
	w_f32(&m, y)
	w_f32(&m, w)
	w_f32(&m, h)
	w_str(&m, origin)
	return m
}
ev_form_submit :: proc(view: int, origin, username, password, old_password: string) -> Msg {
	m := Msg{b = make([dynamic]u8, 0, 8 + 16 + len(origin) + len(username) + len(password) + len(old_password))}
	w_u32(&m, 0)
	w_u16(&m, u16(Op.Form_Submit))
	w_u16(&m, u16(view))
	w_str(&m, origin)
	w_str(&m, username)
	w_str(&m, password)
	w_str(&m, old_password)
	return m
}
ev_fill_result :: proc(view: int, status: Fill_Status) -> Msg {
	m := msg_begin(.Fill_Result, view)
	w_u8(&m, u8(status))
	return m
}
ev_find_result :: proc(view: int, count, active: i32) -> Msg {
	m := msg_begin(.Find_Result, view)
	w_i32(&m, count)
	w_i32(&m, active)
	return m
}

// is_printable_keysym reports a keysym that types a character, and which one.
keysym_rune :: proc(sym: u32) -> (r: rune, ok: bool) {
	switch {
	case sym >= 0x20 && sym <= 0x7e, sym >= 0xa0 && sym <= 0xff:
		return rune(sym), true
	case sym >= 0x01000020 && sym <= 0x0110ffff:
		return rune(sym - 0x01000000), true
	}
	return 0, false
}

// rune_keysym is the inverse: the keysym that types `r`.
rune_keysym :: proc(r: rune) -> u32 {
	if (r >= 0x20 && r <= 0x7e) || (r >= 0xa0 && r <= 0xff) {
		return u32(r)
	}
	switch r {
	case '\n', '\r':
		return 0xff0d
	case '\t':
		return 0xff09
	case '\b':
		return 0xff08
	}
	return 0x01000000 + u32(r)
}

// origin_of is the origin of an http(s) URL as a page's location.origin
// spells it -- scheme://host[:port], lowercase, no default port -- and ""
// for anything else: autofill exists only for http and https pages, and
// never for a URL carrying credentials. The Gecko host and the chrome use
// this one function; the CEF host's origin_of (host.c) is its C twin.
origin_of :: proc(url: string, allocator := context.temp_allocator) -> string {
	rest: string
	https := false
	switch {
	case len(url) >= 8 && ascii_lower_eq(url[:8], "https://"):
		rest = url[8:]
		https = true
	case len(url) >= 7 && ascii_lower_eq(url[:7], "http://"):
		rest = url[7:]
	case:
		return ""
	}
	n := len(rest)
	for i in 0 ..< len(rest) {
		c := rest[i]
		if c == '/' || c == '?' || c == '#' {
			n = i
			break
		}
	}
	host := rest[:n]
	if host == "" || len(host) > 500 {
		return ""
	}
	for i in 0 ..< len(host) {
		if host[i] == '@' {
			return ""
		}
	}
	if https && len(host) > 4 && host[len(host) - 4:] == ":443" {
		host = host[:len(host) - 4]
	} else if !https && len(host) > 3 && host[len(host) - 3:] == ":80" {
		host = host[:len(host) - 3]
	}
	pre := https ? "https://" : "http://"
	out := make([]u8, len(pre) + len(host), allocator)
	copy(out, pre)
	for i in 0 ..< len(host) {
		c := host[i]
		out[len(pre) + i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return string(out)
}

ascii_lower_eq :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		c := a[i]
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		if c != b[i] {
			return false
		}
	}
	return true
}

