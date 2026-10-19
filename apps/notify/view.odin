// What the two surfaces draw from: the daemon's JSON, read into plain
// structs, or invented fixtures for the screenshots. Neither surface talks to
// the store directly -- they are clients like any app -- so this is the seam.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import kit "kit:."
import p "palmy:."

View_Action :: struct {
	key, label: string,
}

View_Note :: struct {
	id:         u32,
	key:        string,
	app:        string,
	app_label:  string,
	identity:   string,
	ident_name: string,
	class:      Class,
	urgency:    Urgency,
	category:   string,
	title:      string,
	body:       string,
	actions:    []View_Action,
	why:        string,
	delivery:   Delivery,
	showing:    bool,
	held:       bool,
	read:       bool,
	is_digest:  bool,
	count:      int,
	created:    i64,
	timeout_ms: int,
	spoken:     string,
}

View_Policy :: struct {
	identity:    string,
	name:        string,
	sentence:    string,
	hold:        Hold,
	hold_ends:   string,
	quiet_until: bool, // a one-off quiet is on
}

// View owns everything in an arena of its own, rebuilt on every refresh.
View :: struct {
	notes:    [dynamic]View_Note,
	policies: [dynamic]View_Policy,
	dnd:      bool,
	now:      string,
	rev:      int,
	tz:       i64,
	ok:       bool, // the daemon answered
}

view_clear :: proc(v: ^View) {
	for n in v.notes {
		delete(n.key)
		delete(n.app)
		delete(n.app_label)
		delete(n.identity)
		delete(n.ident_name)
		delete(n.category)
		delete(n.title)
		delete(n.body)
		delete(n.why)
		delete(n.spoken)
		for a in n.actions {
			delete(a.key)
			delete(a.label)
		}
		delete(n.actions)
	}
	clear(&v.notes)
	for x in v.policies {
		delete(x.identity)
		delete(x.name)
		delete(x.sentence)
		delete(x.hold_ends)
	}
	clear(&v.policies)
}

view_note_from :: proc(o: json.Object) -> View_Note {
	n := View_Note {
		id         = u32(jv_int(o, "id")),
		key        = strings.clone(jv_str(o, "key")),
		app        = strings.clone(jv_str(o, "app")),
		app_label  = strings.clone(jv_str(o, "app_label")),
		identity   = strings.clone(jv_str(o, "identity")),
		ident_name = strings.clone(jv_str(o, "identity_name")),
		category   = strings.clone(jv_str(o, "category")),
		title      = strings.clone(jv_str(o, "title")),
		body       = strings.clone(jv_str(o, "body")),
		why        = strings.clone(jv_str(o, "why")),
		spoken     = strings.clone(jv_str(o, "spoken")),
		showing    = jv_bool(o, "showing"),
		held       = jv_bool(o, "held"),
		read       = jv_bool(o, "read"),
		is_digest  = jv_bool(o, "is_digest"),
		count      = int(jv_int(o, "count")),
		created    = jv_int(o, "created"),
		timeout_ms = int(jv_int(o, "timeout_ms")),
	}
	n.class, _ = class_parse(jv_str(o, "class"))
	n.urgency, _ = urgency_parse(jv_str(o, "urgency"))
	switch jv_str(o, "delivery") {
	case "toast":
		n.delivery = .Toast
	case "digest":
		n.delivery = .Digest
	case:
		n.delivery = .Center
	}
	acts := make([dynamic]View_Action)
	if arr, has := jv_arr(o, "actions"); has {
		for a in arr {
			if ao, isobj := a.(json.Object); isobj {
				append(&acts, View_Action{strings.clone(jv_str(ao, "key")), strings.clone(jv_str(ao, "label"))})
			}
		}
	}
	n.actions = acts[:]
	return n
}

// view_refresh asks the daemon for what a surface needs. `showing` limits
// the notes to toasts on screen.
view_refresh :: proc(v: ^View, showing: bool, identity := "") {
	r := kit.jobj(context.temp_allocator)
	kit.jset_str(r, "op", "list", context.temp_allocator)
	if showing {
		kit.jset_bool(r, "showing", true, context.temp_allocator)
	}
	line, ok := kit.notify_request(kit.json_text(r, 0, context.temp_allocator))
	v.ok = ok
	if !ok {
		return
	}
	val, err := json.parse_string(line, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	root, _ := val.(json.Object)
	view_clear(v)
	v.dnd = jv_bool(root, "dnd")
	v.rev = int(jv_int(root, "rev"))
	if arr, has := jv_arr(root, "notifications"); has {
		for x in arr {
			if o, isobj := x.(json.Object); isobj {
				append(&v.notes, view_note_from(o))
			}
		}
	}
	if showing {
		return
	}
	pr := kit.jobj(context.temp_allocator)
	kit.jset_str(pr, "op", "policies", context.temp_allocator)
	pline, pok := kit.notify_request(kit.json_text(pr, 0, context.temp_allocator))
	if !pok {
		return
	}
	pval, perr := json.parse_string(pline, allocator = context.temp_allocator)
	if perr != nil {
		return
	}
	proot, _ := pval.(json.Object)
	delete(v.now)
	v.now = strings.clone(jv_str(proot, "now"))
	if arr, has := jv_arr(proot, "policies"); has {
		for x in arr {
			o, isobj := x.(json.Object)
			if !isobj {
				continue
			}
			vp := View_Policy {
				identity    = strings.clone(jv_str(o, "identity")),
				name        = strings.clone(jv_str(o, "identity_name")),
				sentence    = strings.clone(jv_str(o, "sentence")),
				hold_ends   = strings.clone(jv_str(o, "hold_ends")),
				quiet_until = jv_int(o, "quiet_until") > 0,
			}
			switch jv_str(o, "hold") {
			case "quiet":
				vp.hold = .Quiet
			case "dnd":
				vp.hold = .Dnd
			}
			append(&v.policies, vp)
		}
	}
}

// op sends a one-off request from a surface: dismiss, invoke, read...
op :: proc(name: string, id: u32, extra: ..string) -> bool {
	r := kit.jobj(context.temp_allocator)
	kit.jset_str(r, "op", name, context.temp_allocator)
	if id > 0 {
		kit.jset_int(r, "id", int(id), context.temp_allocator)
	}
	for i := 0; i + 1 < len(extra); i += 2 {
		if extra[i + 1] == "true" || extra[i + 1] == "false" {
			kit.jset_bool(r, extra[i], extra[i + 1] == "true", context.temp_allocator)
		} else {
			kit.jset_str(r, extra[i], extra[i + 1], context.temp_allocator)
		}
	}
	_, ok := kit.notify_request(kit.json_text(r, 0, context.temp_allocator))
	return ok
}

// ---------------------------------------------------------------------------
// Watching the daemon from a surface
//
// A thread blocks on the watch connection and, on every change, sets a flag
// and wakes whoever is waiting: the palmy loop through `wake` (safe from any
// thread), or the toast process's idle wait through a pipe.
// ---------------------------------------------------------------------------

Watch :: struct {
	fd:      linux.Fd,
	dirty:   bool, // atomic
	focus:   bool, // atomic: the shortcut asked for the keyboard
	center:  bool, // atomic: asked to come to the front
	gone:    bool, // atomic: the daemon hung up
	app:     ^p.App, // atomic pointer; nil while there is no window
	pipe:    [2]linux.Fd,
	th:      ^thread.Thread,
}

watch_start :: proc(w: ^Watch, role: string) -> bool {
	w.fd = kit.notify_connect()
	if w.fd < 0 {
		return false
	}
	r := kit.jobj(context.temp_allocator)
	kit.jset_str(r, "op", "watch", context.temp_allocator)
	kit.jset_str(r, "role", role, context.temp_allocator)
	if !kit.notify_send_line(w.fd, kit.json_text(r, 0, context.temp_allocator)) {
		return false
	}
	_ = linux.pipe2(&w.pipe, {.CLOEXEC, .NONBLOCK})
	sync.atomic_store(&w.dirty, true)
	w.th = thread.create_and_start_with_data(w, watch_loop)
	return true
}

@(private = "file")
watch_loop :: proc(data: rawptr) {
	w := (^Watch)(data)
	buf := make([dynamic]u8)
	for {
		line, ok := kit.notify_read_line(w.fd, &buf, -1)
		if !ok {
			sync.atomic_store(&w.gone, true)
			watch_poke(w)
			return
		}
		switch {
		case strings.contains(line, `"ev":"focus"`):
			sync.atomic_store(&w.focus, true)
		case strings.contains(line, `"ev":"center"`):
			sync.atomic_store(&w.center, true)
		}
		sync.atomic_store(&w.dirty, true)
		watch_poke(w)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
watch_poke :: proc(w: ^Watch) {
	if app := sync.atomic_load(&w.app); app != nil {
		p.wake(app)
	}
	b := [1]u8{1}
	linux.write(w.pipe[1], b[:])
}

// watch_idle blocks until the watcher pokes, for a process with no window.
watch_idle :: proc(w: ^Watch, timeout_ms: int) {
	pfd := [1]linux.Poll_Fd{{fd = w.pipe[0], events = {.IN}}}
	linux.poll(pfd[:], i32(timeout_ms))
	drain: [64]u8
	for {
		n, _ := linux.read(w.pipe[0], drain[:])
		if n <= 0 {
			break
		}
	}
}

// ---------------------------------------------------------------------------
// Shared drawing helpers
// ---------------------------------------------------------------------------

theme_dark :: proc(args: []string) -> bool {
	for a in args {
		if a == "--dark" {
			return true
		}
		if a == "--light" {
			return false
		}
	}
	t := os.get_env("PALM_THEME", context.temp_allocator)
	return t == "dark"
}

// register_view_colors gives each identity a token, `id-<handle>` would not
// parse as a class, so they are numbered in the order the view lists them:
// `bg-idc-0`, `text-idc-1`. Index -1 (no identity) is a neutral grey.
register_view_colors :: proc(handles: []string, dark: bool) {
	for h, i in handles {
		p.register_color(fmt.tprintf("idc-%d", i), p.hex(identity_color(h, dark)))
	}
	p.register_color("idc-none", p.hex(identity_color("", dark)))
}

ident_token :: proc(handles: []string, identity: string) -> string {
	for h, i in handles {
		if h == identity {
			return fmt.tprintf("idc-%d", i)
		}
	}
	return "idc-none"
}

class_icon :: proc(n: ^View_Note) -> p.Icon {
	if n.is_digest {
		return ICON_LAYERS
	}
	switch {
	case strings.has_prefix(n.category, "call."):
		return ICON_PHONE_INCOMING
	case n.app == "mail" || strings.has_prefix(n.category, "email"):
		return ICON_MAIL
	case n.app == "calendar":
		return ICON_CALENDAR_CLOCK
	case n.app == "chat" || strings.has_prefix(n.category, "im."):
		return ICON_MESSAGE_SQUARE
	case n.app == "forge":
		return ICON_GIT_PULL_REQUEST
	case n.app == "drive":
		return ICON_CLOUD
	case n.app == "vault":
		return ICON_KEY_ROUND
	case n.app == "palm" || n.app == "store":
		return ICON_PACKAGE
	case n.app == "browser" || strings.has_prefix(n.category, "transfer"):
		return ICON_DOWNLOAD
	}
	// An app this table does not know gets a bell: a person icon on a
	// browser's download would say something untrue.
	if n.class == .Time {
		return ICON_CLOCK
	}
	return ICON_BELL
}

// when_text is a notification's time as a person reads it in a list.
when_text :: proc(created, now, tz: i64) -> string {
	d := (now - created) / 1000
	switch {
	case d < 45:
		return "now"
	case d < 3600:
		return fmt.tprintf("%d min", max(d / 60, 1))
	case d < 6 * 3600 && local_day(created, tz) == local_day(now, tz):
		return fmt.tprintf("%d h", d / 3600)
	case local_day(created, tz) == local_day(now, tz):
		return hhmm(local_minute(created, tz))
	case local_day(created, tz) == local_day(now, tz) - 1:
		return "Yesterday"
	}
	return fmt.tprintf("%d days", max(local_day(now, tz) - local_day(created, tz), 1))
}

load_ui_fonts :: proc(fonts: ^p.Fonts, dark: bool) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			break
		}
	}
}
