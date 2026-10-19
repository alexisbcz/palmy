// The seat: how a compositor that is not root gets input and the GPU.
//
// On this machine `alex` is not in the `input` group, so /dev/input/event* is
// unopenable, and /dev/dri/card1 is root:video with an ACL. Opening either
// directly is the bug this file exists to prevent. The only correct answer is
// logind: org.freedesktop.login1.Session.TakeDevice hands back an already-open
// descriptor over D-Bus, and in exchange the session manager gets to take it
// away again when the user switches VT.
//
// That exchange is the other half of the job. VT switching is not a signal on
// a tty here; it arrives as PauseDevice / ResumeDevice and a change to the
// session's Active property. "We are the foreground VT" is therefore a piece
// of state this layer owns, and both the DRM and the input layers read it
// rather than guessing.
//
// SAFETY. Every call that changes the session -- TakeControl, TakeDevice,
// ReleaseControl, Activate, SwitchTo -- is refused unless PALMY_WM_SEAT_LIVE=1
// is in the environment. Taking control of a seat that already has a
// compositor on it steals the keyboard and the screen from that compositor.
// Everything else here (listing sessions, reading properties, enumerating
// device nodes from sysfs) is read-only and always allowed, and is what the
// self-test exercises.
package wm

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "kit:dbus"

SEAT_BUS :: "org.freedesktop.login1"
SEAT_MGR_PATH :: "/org/freedesktop/login1"
SEAT_MGR_IFACE :: "org.freedesktop.login1.Manager"
SEAT_SESSION_IFACE :: "org.freedesktop.login1.Session"
SEAT_SEAT_IFACE :: "org.freedesktop.login1.Seat"
SEAT_PROPS_IFACE :: "org.freedesktop.DBus.Properties"

Seat_Dev_Kind :: enum u8 {
	Input,
	Drm_Card,
	Drm_Render,
	Other,
}

Seat_Device :: struct {
	node:   string, // "/dev/input/event3", "/dev/dri/card1"
	name:   string, // sysfs device name, best effort, "" when unknown
	kind:   Seat_Dev_Kind,
	major:  u32,
	minor:  u32,
	fd:     linux.Fd, // -1 until taken
	taken:  bool,
	paused: bool,
}

Seat :: struct {
	conn:            ^dbus.Dbus_Conn,
	ready:           bool,
	live:            bool, // PALMY_WM_SEAT_LIVE=1
	session_id:      string,
	session_path:    string,
	seat_id:         string,
	seat_path:       string,
	session_type:    string,
	session_state:   string,
	vtnr:            u32,

	// Foreground state. `active` mirrors the session's Active property, which
	// is what logind flips on a VT switch; `graphics_paused` is set the moment
	// the DRM device is paused, which happens slightly before Active goes
	// false, and cleared on resume.
	active:          bool,
	graphics_paused: bool,
	control:         bool,
	devices:         [dynamic]Seat_Device,

	// Hooks for the DRM and input layers. Called from seat_pump.
	on_pause:        proc(d: ^Seat_Device, kind: string),
	on_resume:       proc(d: ^Seat_Device),
	on_active:       proc(active: bool),

	// Counters, so a test or a log can say what actually happened.
	n_pause:         int,
	n_resume:        int,
	n_active:        int,
}

seat: Seat

seat_verbose: bool

seat_log :: proc(format: string, args: ..any) {
	if !seat_verbose {
		return
	}
	fmt.eprintf("[seat] ")
	fmt.eprintf(format, ..args)
	fmt.eprintf("\n")
}

// seat_live_enabled is the gate. It is read once at seat_open and never
// written from inside the program.
seat_live_enabled :: proc() -> bool {
	return os.get_env("PALMY_WM_SEAT_LIVE", context.temp_allocator) == "1"
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

// seat_open connects to the system bus, finds our login session and reads its
// properties. Nothing here changes any state on the session, so it is safe to
// call while another compositor owns the seat.
seat_open :: proc() -> dbus.Dbus_Error {
	if seat.ready {
		return .None
	}
	seat_verbose = os.get_env("PALMY_WM_SEAT_DEBUG", context.temp_allocator) != ""
	dbus.dbus_verbose = seat_verbose
	seat.live = seat_live_enabled()

	conn, e := dbus.dbus_connect()
	if e != .None {
		seat_log("cannot reach the system bus: %v", e)
		return e
	}
	seat.conn = conn

	if e2 := seat_find_session(); e2 != .None {
		dbus.dbus_close(seat.conn)
		seat.conn = nil
		return e2
	}

	seat.ready = true
	if e3 := seat_refresh(); e3 != .None {
		seat_log("property read failed: %v", e3)
	}
	seat_watch()
	seat_scan_devices()

	seat_log(
		"session %s at %s on %s, vt %d, type %s, state %s, active %v, live %v",
		seat.session_id,
		seat.session_path,
		seat.seat_id,
		seat.vtnr,
		seat.session_type,
		seat.session_state,
		seat.active,
		seat.live,
	)
	return .None
}

seat_close :: proc() {
	if !seat.ready {
		return
	}
	seat_unbind_backends()
	// Only give devices back if we ever took them; this cannot happen unless
	// the live gate was open.
	for &d in seat.devices {
		if d.taken {
			seat_release_device(d.major, d.minor)
		}
		if d.fd >= 0 {
			linux.close(d.fd)
			d.fd = -1
		}
	}
	if seat.control {
		seat_release_control()
	}
	seat_free_devices()
	delete(seat.devices)
	if seat.conn != nil {
		dbus.dbus_close(seat.conn)
		seat.conn = nil
	}
	delete(seat.session_id)
	delete(seat.session_path)
	delete(seat.seat_id)
	delete(seat.seat_path)
	delete(seat.session_type)
	delete(seat.session_state)
	seat = {}
}

// seat_fd is the descriptor the main loop should add to its poll set. It
// becomes readable when logind has something to say -- a pause, a resume, or a
// change of Active.
seat_fd :: proc() -> linux.Fd {
	return dbus.dbus_fd(seat.conn)
}

// seat_find_session prefers XDG_SESSION_ID, because that is the session the
// user logged into, and falls back to asking logind which session owns us.
seat_find_session :: proc() -> dbus.Dbus_Error {
	if id := os.get_env("XDG_SESSION_ID", context.temp_allocator); id != "" {
		args := [1]dbus.Dbus_Value{dbus.dbus_s(id)}
		m, e := dbus.dbus_call(
			seat.conn,
			SEAT_BUS,
			SEAT_MGR_PATH,
			SEAT_MGR_IFACE,
			"GetSession",
			"s",
			args[:],
		)
		if e == .None && len(m.args) == 1 {
			seat.session_path = strings.clone(m.args[0].str)
			seat.session_id = strings.clone(id)
			dbus.dbus_msg_free(m)
			return .None
		}
		if m != nil {
			dbus.dbus_msg_free(m)
		}
		seat_log("GetSession(%s) failed (%v), falling back to GetSessionByPID", id, e)
	}

	pid := u32(linux.getpid())
	args := [1]dbus.Dbus_Value{dbus.dbus_u(pid)}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		SEAT_MGR_PATH,
		SEAT_MGR_IFACE,
		"GetSessionByPID",
		"u",
		args[:],
	)
	if e != .None {
		if m != nil {
			dbus.dbus_msg_free(m)
		}
		return e
	}
	if len(m.args) != 1 {
		dbus.dbus_msg_free(m)
		return .Protocol
	}
	seat.session_path = strings.clone(m.args[0].str)
	dbus.dbus_msg_free(m)
	return .None
}

@(private = "file")
reset_str :: proc(dst: ^string, src: string) {
	if dst^ != "" {
		delete(dst^)
	}
	dst^ = strings.clone(src)
}

// seat_refresh re-reads every property we care about in one GetAll.
seat_refresh :: proc() -> dbus.Dbus_Error {
	if seat.conn == nil || seat.session_path == "" {
		return .Not_Ready
	}
	dict, m, e := dbus.dbus_get_all(seat.conn, SEAT_BUS, seat.session_path, SEAT_SESSION_IFACE)
	if e != .None {
		if m != nil {
			dbus.dbus_msg_free(m)
		}
		return e
	}
	defer dbus.dbus_msg_free(m)

	if v, ok := dbus.dbus_dict_get(dict, "Id"); ok {
		reset_str(&seat.session_id, v.str)
	}
	if v, ok := dbus.dbus_dict_get(dict, "Type"); ok {
		reset_str(&seat.session_type, v.str)
	}
	if v, ok := dbus.dbus_dict_get(dict, "State"); ok {
		reset_str(&seat.session_state, v.str)
	}
	if v, ok := dbus.dbus_dict_get(dict, "VTNr"); ok {
		seat.vtnr = dbus.dbus_as_u32(v)
	}
	if v, ok := dbus.dbus_dict_get(dict, "Active"); ok {
		seat.active = dbus.dbus_as_bool(v)
	}
	// Seat is a (so): the id and the object path of the seat object.
	if v, ok := dbus.dbus_dict_get(dict, "Seat"); ok {
		if v.kind == '(' && len(v.items) == 2 {
			reset_str(&seat.seat_id, v.items[0].str)
			reset_str(&seat.seat_path, v.items[1].str)
		}
	}
	return .None
}

// seat_watch subscribes to the three things that tell us the VT moved.
seat_watch :: proc() {
	if seat.conn == nil || seat.session_path == "" {
		return
	}
	rules := [3]string {
		fmt.tprintf(
			"type='signal',sender='%s',interface='%s',member='PauseDevice',path='%s'",
			SEAT_BUS,
			SEAT_SESSION_IFACE,
			seat.session_path,
		),
		fmt.tprintf(
			"type='signal',sender='%s',interface='%s',member='ResumeDevice',path='%s'",
			SEAT_BUS,
			SEAT_SESSION_IFACE,
			seat.session_path,
		),
		fmt.tprintf(
			"type='signal',sender='%s',interface='%s',member='PropertiesChanged',path='%s'",
			SEAT_BUS,
			SEAT_PROPS_IFACE,
			seat.session_path,
		),
	}
	for r in rules {
		if e := dbus.dbus_add_match(seat.conn, r); e != .None {
			seat_log("AddMatch failed (%v) for %s", e, r)
		}
	}
}

// ---------------------------------------------------------------------------
// The event pump
// ---------------------------------------------------------------------------

// seat_pump drains whatever logind has sent. Call it whenever poll() reports
// seat_fd() readable; it never blocks.
seat_pump :: proc() {
	if seat.conn == nil {
		return
	}
	if e := dbus.dbus_dispatch(seat.conn); e != .None {
		if !dbus.dbus_alive(seat.conn) {
			seat_log("logind hung up; VT switching is no longer brokered")
		}
		return
	}
	for {
		m, ok := dbus.dbus_next(seat.conn)
		if !ok {
			break
		}
		seat_handle(m)
		dbus.dbus_msg_close_fds(m)
		dbus.dbus_msg_free(m)
	}
}

// The three state transitions are separated from the signal decoding so that
// they can be exercised without a bus and without owning the session. Each
// returns what the caller still owes logind.

// seat_mark_pause records a pause. `kind` is "pause" (logind is waiting for
// our acknowledgement before it lets the VT switch proceed), "force" (it has
// already revoked the device) or "gone" (the device was unplugged). The result
// says whether PauseDeviceComplete is owed.
seat_mark_pause :: proc(major, minor: u32, kind: string) -> (ack_owed: bool) {
	seat.n_pause += 1
	d := seat_device_by_dev(major, minor)
	if d != nil {
		d.paused = true
		if d.kind == .Drm_Card {
			// The card is revoked a moment before Active goes false, and it
			// is the one that must stop being touched first.
			seat.graphics_paused = true
		}
		if kind == "gone" {
			d.taken = false
			if d.fd >= 0 {
				linux.close(d.fd)
				d.fd = -1
			}
		}
		if seat.on_pause != nil {
			seat.on_pause(d, kind)
		}
	}
	seat_log("PauseDevice %d:%d (%s)", major, minor, kind)
	return kind == "pause"
}

// seat_mark_resume installs the replacement descriptor logind handed back. The
// old one is already dead, so it is closed.
seat_mark_resume :: proc(major, minor: u32, newfd: linux.Fd) {
	seat.n_resume += 1
	d := seat_device_by_dev(major, minor)
	if d == nil {
		if newfd >= 0 {
			linux.close(newfd)
		}
		return
	}
	if d.fd >= 0 && d.fd != newfd {
		linux.close(d.fd)
	}
	d.fd = newfd
	d.taken = newfd >= 0
	d.paused = false
	if d.kind == .Drm_Card {
		seat.graphics_paused = false
	}
	if seat.on_resume != nil {
		seat.on_resume(d)
	}
	seat_log("ResumeDevice %d:%d fd %d", major, minor, newfd)
}

seat_mark_active :: proc(active: bool) {
	if seat.active == active {
		return
	}
	seat.active = active
	seat.n_active += 1
	seat_log("session is now %s", active ? "active" : "background")
	if seat.on_active != nil {
		seat.on_active(active)
	}
}

@(private = "file")
seat_handle :: proc(m: ^dbus.Dbus_Msg) {
	if m.type != dbus.DBUS_MSG_SIGNAL {
		return
	}
	switch {
	case m.iface == SEAT_SESSION_IFACE && m.member == "PauseDevice":
		// (u major, u minor, s type)
		if len(m.args) != 3 {
			return
		}
		major := dbus.dbus_as_u32(m.args[0])
		minor := dbus.dbus_as_u32(m.args[1])
		if seat_mark_pause(major, minor, m.args[2].str) {
			// Mandatory: logind blocks the VT switch until every delegate has
			// answered or its timeout expires.
			seat_pause_complete(major, minor)
		}

	case m.iface == SEAT_SESSION_IFACE && m.member == "ResumeDevice":
		// (u major, u minor, h fd)
		if len(m.args) != 3 {
			return
		}
		newfd := m.args[2].fd
		// Take the descriptor out of the message so the pump does not close
		// it behind us.
		for &f in m.fds {
			if f == newfd {
				f = -1
			}
		}
		seat_mark_resume(dbus.dbus_as_u32(m.args[0]), dbus.dbus_as_u32(m.args[1]), newfd)

	case m.iface == SEAT_PROPS_IFACE && m.member == "PropertiesChanged":
		// (s interface, a{sv} changed, as invalidated)
		if len(m.args) < 2 || m.args[0].str != SEAT_SESSION_IFACE {
			return
		}
		if v, ok := dbus.dbus_dict_get(m.args[1], "State"); ok {
			reset_str(&seat.session_state, v.str)
		}
		if v, ok := dbus.dbus_dict_get(m.args[1], "Active"); ok {
			seat_mark_active(dbus.dbus_as_bool(v))
			return
		}
		if len(m.args) >= 3 {
			for inv in m.args[2].items {
				if inv.str == "Active" {
					// Invalidated rather than carried: ask for it.
					if now, ok := seat_read_active(); ok {
						seat_mark_active(now)
					}
				}
			}
		}
	}
}

// seat_read_active re-reads the Active property, for the case where
// PropertiesChanged invalidated it rather than carrying its new value.
@(private = "file")
seat_read_active :: proc() -> (active: bool, ok: bool) {
	v, m, e := dbus.dbus_get_property(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"Active",
	)
	// The value is a bool, so it is copied out before the message that owns
	// its storage goes away.
	if e == .None && v.kind == 'b' {
		active, ok = dbus.dbus_as_bool(v), true
	}
	if m != nil {
		dbus.dbus_msg_free(m)
	}
	return
}

@(private = "file")
seat_pause_complete :: proc(major, minor: u32) {
	if seat.conn == nil {
		return
	}
	args := [2]dbus.Dbus_Value{dbus.dbus_u(major), dbus.dbus_u(minor)}
	if e := dbus.dbus_send_noreply(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"PauseDeviceComplete",
		"uu",
		args[:],
	); e != .None {
		seat_log("PauseDeviceComplete %d:%d failed: %v", major, minor, e)
	}
}

// seat_foreground is the question the DRM and input layers actually ask: may
// we drive the hardware right now?
seat_foreground :: proc() -> bool {
	return seat.active && !seat.graphics_paused
}

// ---------------------------------------------------------------------------
// The gated half: everything that changes the session
// ---------------------------------------------------------------------------

@(private = "file")
seat_gate :: proc(what: string) -> bool {
	if seat.live {
		return true
	}
	seat_log("refusing %s: PALMY_WM_SEAT_LIVE is not set", what)
	return false
}

// seat_take_control makes us the session's device delegate. Until this
// succeeds TakeDevice will be refused by logind.
seat_take_control :: proc(force := false) -> dbus.Dbus_Error {
	if !seat.ready {
		return .Not_Ready
	}
	if !seat_gate("TakeControl") {
		return .Gated
	}
	args := [1]dbus.Dbus_Value{dbus.dbus_b(force)}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"TakeControl",
		"b",
		args[:],
	)
	if m != nil {
		dbus.dbus_msg_free(m)
	}
	if e == .None {
		seat.control = true
	}
	return e
}

seat_release_control :: proc() -> dbus.Dbus_Error {
	if !seat.ready || !seat.control {
		return .Not_Ready
	}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"ReleaseControl",
		"",
		nil,
	)
	if m != nil {
		dbus.dbus_msg_free(m)
	}
	seat.control = false
	return e
}

// seat_take_device asks logind for an open descriptor on a device node. The
// second result says whether the device arrived already paused, which happens
// when we are not the foreground VT.
seat_take_device :: proc(major, minor: u32) -> (fd: linux.Fd, paused: bool, err: dbus.Dbus_Error) {
	if !seat.ready {
		return -1, false, .Not_Ready
	}
	if !seat_gate("TakeDevice") {
		return -1, false, .Gated
	}
	args := [2]dbus.Dbus_Value{dbus.dbus_u(major), dbus.dbus_u(minor)}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"TakeDevice",
		"uu",
		args[:],
	)
	if e != .None {
		if m != nil {
			dbus.dbus_msg_close_fds(m)
			dbus.dbus_msg_free(m)
		}
		return -1, false, e
	}
	defer dbus.dbus_msg_free(m)
	if len(m.args) != 2 || m.args[0].kind != 'h' {
		dbus.dbus_msg_close_fds(m)
		return -1, false, .Protocol
	}
	fd = m.args[0].fd
	paused = dbus.dbus_as_bool(m.args[1])
	if fd < 0 {
		return -1, false, .Protocol
	}
	if d := seat_device_by_dev(major, minor); d != nil {
		d.fd = fd
		d.taken = true
		d.paused = paused
		if d.kind == .Drm_Card {
			seat.graphics_paused = paused
		}
	}
	return fd, paused, .None
}

// seat_take_node is the same thing by path: "/dev/input/event3".
seat_take_node :: proc(node: string) -> (fd: linux.Fd, paused: bool, err: dbus.Dbus_Error) {
	d := seat_device_by_node(node)
	if d == nil {
		return -1, false, .Not_Found
	}
	return seat_take_device(d.major, d.minor)
}

seat_release_device :: proc(major, minor: u32) -> dbus.Dbus_Error {
	if !seat.ready {
		return .Not_Ready
	}
	if !seat_gate("ReleaseDevice") {
		return .Gated
	}
	args := [2]dbus.Dbus_Value{dbus.dbus_u(major), dbus.dbus_u(minor)}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"ReleaseDevice",
		"uu",
		args[:],
	)
	if m != nil {
		dbus.dbus_msg_free(m)
	}
	if d := seat_device_by_dev(major, minor); d != nil {
		d.taken = false
		if d.fd >= 0 {
			linux.close(d.fd)
			d.fd = -1
		}
	}
	return e
}

// seat_activate brings our session to the foreground.
seat_activate :: proc() -> dbus.Dbus_Error {
	if !seat.ready {
		return .Not_Ready
	}
	if !seat_gate("Activate") {
		return .Gated
	}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		seat.session_path,
		SEAT_SESSION_IFACE,
		"Activate",
		"",
		nil,
	)
	if m != nil {
		dbus.dbus_msg_free(m)
	}
	return e
}

// seat_switch_to moves the seat to another VT.
seat_switch_to :: proc(vt: u32) -> dbus.Dbus_Error {
	if !seat.ready || seat.seat_path == "" {
		return .Not_Ready
	}
	if !seat_gate("SwitchTo") {
		return .Gated
	}
	args := [1]dbus.Dbus_Value{dbus.dbus_u(vt)}
	m, e := dbus.dbus_call(
		seat.conn,
		SEAT_BUS,
		seat.seat_path,
		SEAT_SEAT_IFACE,
		"SwitchTo",
		"u",
		args[:],
	)
	if m != nil {
		dbus.dbus_msg_free(m)
	}
	return e
}

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------

seat_device_by_dev :: proc(major, minor: u32) -> ^Seat_Device {
	for &d in seat.devices {
		if d.major == major && d.minor == minor {
			return &d
		}
	}
	return nil
}

seat_device_by_node :: proc(node: string) -> ^Seat_Device {
	for &d in seat.devices {
		if d.node == node {
			return &d
		}
	}
	return nil
}

seat_free_devices :: proc() {
	for d in seat.devices {
		delete(d.node)
		if d.name != "" {
			delete(d.name)
		}
	}
	clear(&seat.devices)
}

// seat_sysfs_dev reads a sysfs "dev" attribute, which is "major:minor\n". The
// device node itself is never opened -- that is the whole point of this file.
@(private = "file")
seat_sysfs_dev :: proc(path: string) -> (major, minor: u32, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	text := strings.trim_space(string(data))
	colon := strings.index_byte(text, ':')
	if colon < 0 {
		return 0, 0, false
	}
	hi, ok1 := strconv.parse_int(text[:colon])
	lo, ok2 := strconv.parse_int(text[colon + 1:])
	if !ok1 || !ok2 {
		return 0, 0, false
	}
	return u32(hi), u32(lo), true
}

@(private = "file")
seat_sysfs_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.clone(strings.trim_space(string(data)))
}

// seat_uevent_field pulls one KEY=value line out of a sysfs uevent blob.
@(private = "file")
seat_uevent_field :: proc(path, key: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	want := fmt.tprintf("%s=", key)
	rest := string(data)
	for len(rest) > 0 {
		line := rest
		if idx := strings.index_byte(rest, '\n'); idx >= 0 {
			line = rest[:idx]
			rest = rest[idx + 1:]
		} else {
			rest = ""
		}
		if strings.has_prefix(line, want) {
			return strings.clone(line[len(want):])
		}
	}
	return ""
}

// seat_scan_devices walks sysfs for evdev nodes and /dev/dri for GPU nodes, so
// callers can ask for a device by path and get its major:minor without a stat
// on the node.
seat_scan_devices :: proc() -> int {
	seat_free_devices()

	if entries, err := os.read_directory_by_path(
		"/sys/class/input",
		-1,
		context.temp_allocator,
	); err == nil {
		for e in entries {
			if !strings.has_prefix(e.name, "event") {
				continue
			}
			base := fmt.tprintf("/sys/class/input/%s", e.name)
			major, minor, ok := seat_sysfs_dev(fmt.tprintf("%s/dev", base))
			if !ok {
				continue
			}
			append(
				&seat.devices,
				Seat_Device {
					node = strings.clone(fmt.tprintf("/dev/input/%s", e.name)),
					name = seat_sysfs_text(fmt.tprintf("%s/device/name", base)),
					kind = .Input,
					major = major,
					minor = minor,
					fd = -1,
				},
			)
		}
	} else {
		seat_log("/sys/class/input is not readable: %v", err)
	}

	if entries, err := os.read_directory_by_path("/dev/dri", -1, context.temp_allocator);
	   err == nil {
		for e in entries {
			kind := Seat_Dev_Kind.Other
			if strings.has_prefix(e.name, "card") {
				kind = .Drm_Card
			} else if strings.has_prefix(e.name, "renderD") {
				kind = .Drm_Render
			} else {
				continue
			}
			major, minor, ok := seat_sysfs_dev(fmt.tprintf("/sys/class/drm/%s/dev", e.name))
			if !ok {
				continue
			}
			append(
				&seat.devices,
				Seat_Device {
					node = strings.clone(fmt.tprintf("/dev/dri/%s", e.name)),
					name = seat_uevent_field(
						fmt.tprintf("/sys/class/drm/%s/device/uevent", e.name),
						"DRIVER",
					),
					kind = kind,
					major = major,
					minor = minor,
					fd = -1,
				},
			)
		}
	} else {
		seat_log("/dev/dri is not readable: %v", err)
	}

	return len(seat.devices)
}

// seat_primary_card returns the first DRM card node found. On this machine it
// is card1, not card0, which is exactly why nothing may hardcode a number.
seat_primary_card :: proc() -> ^Seat_Device {
	for &d in seat.devices {
		if d.kind == .Drm_Card {
			return &d
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Binding the backends
//
// drm.odin and evdev.odin each declare a seam for this file and nothing more:
// hand me an fd for this node, and tell me when it is paused and when it comes
// back. Until seat_bind_backends runs, both of them open their nodes directly,
// which works only in a session that already has permission. After it runs,
// every descriptor comes from logind and every VT switch is brokered.
// ---------------------------------------------------------------------------

@(private = "file")
seat_node_open :: proc(path: string) -> (linux.Fd, bool) {
	fd, paused, e := seat_take_node(path)
	if e != .None {
		seat_log("TakeDevice(%s) refused: %v", path, e)
		return 0, false
	}
	if paused {
		seat_log("%s arrived paused; we are not the foreground VT", path)
	}
	return fd, true
}

@(private = "file")
seat_node_close :: proc(path: string, fd: linux.Fd) {
	d := seat_device_by_node(path)
	if d == nil {
		linux.close(fd)
		return
	}
	if d.fd != fd && fd >= 0 {
		linux.close(fd)
	}
	seat_release_device(d.major, d.minor)
}

@(private = "file")
seat_backend_pause :: proc(d: ^Seat_Device, kind: string) {
	switch d.kind {
	case .Drm_Card:
		drm_pause()
	case .Input:
		// Every input fd goes quiet at once, and anything held down has to be
		// released or the next session inherits a stuck modifier.
		ev_pause_all()
	case .Drm_Render, .Other:
	}
}

@(private = "file")
seat_backend_resume :: proc(d: ^Seat_Device) {
	switch d.kind {
	case .Drm_Card:
		drm_resume(d.node, d.fd)
	case .Input:
		ev_resume_all()
	case .Drm_Render, .Other:
	}
}

@(private = "file")
seat_backend_active :: proc(active: bool) {
	// Active is the authority; the per-device signals are the detail. Both
	// calls are idempotent, so this is only a backstop for the case where the
	// property moves without a matching device signal.
	if active {
		drm_resume()
		ev_resume_all()
	} else {
		drm_pause()
		ev_pause_all()
	}
}

// seat_bind_backends routes DRM and input through logind. Call it once, after
// seat_open and before drm_init.
seat_bind_backends :: proc() {
	ev_open_device = seat_node_open
	ev_close_device = seat_node_close
	drm_set_seat(
		Drm_Seat {
			open = seat_node_open,
			close = seat_node_close,
			// logind makes the session's DRM fd master itself, as part of
			// owning the VT; this file must not call SET_MASTER on top.
			seat_master = true,
			manages_vt = true,
		},
	)
	seat.on_pause = seat_backend_pause
	seat.on_resume = seat_backend_resume
	seat.on_active = seat_backend_active
}

// seat_unbind_backends puts the direct-open fallbacks back, which is what the
// nested build wants.
seat_unbind_backends :: proc() {
	ev_open_device = ev_open_direct
	ev_close_device = ev_close_direct
	drm_set_seat({})
	seat.on_pause = nil
	seat.on_resume = nil
	seat.on_active = nil
}

// ---------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------
//
// Run with:  wm --selftest-seat
//
// It is hooked in before main so that no other file has to know about it. The
// marshalling half is pure; the live half is read-only bus traffic.

@(private = "file")
st_pass: int
@(private = "file")
st_fail: int

@(private = "file")
check :: proc(cond: bool, format: string, args: ..any) {
	if cond {
		st_pass += 1
		fmt.printf("  ok   %s\n", fmt.tprintf(format, ..args))
	} else {
		st_fail += 1
		fmt.printf("  FAIL %s\n", fmt.tprintf(format, ..args))
	}
}

@(private = "file")
hexdump :: proc(b: []u8) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for v, i in b {
		if i > 0 && i % 8 == 0 {
			strings.write_byte(&sb, ' ')
		}
		strings.write_string(&sb, fmt.tprintf("%02x", v))
	}
	return strings.to_string(sb)
}

// values_equal compares two unmarshalled trees structurally.
@(private = "file")
values_equal :: proc(a, b: dbus.Dbus_Value) -> bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't':
		return a.num == b.num
	case 'd':
		return a.f == b.f
	case 's', 'o', 'g':
		return a.str == b.str
	case 'h':
		return a.num == b.num
	case 'v':
		if a.sig != b.sig {
			return false
		}
	}
	if len(a.items) != len(b.items) {
		return false
	}
	for i in 0 ..< len(a.items) {
		if !values_equal(a.items[i], b.items[i]) {
			return false
		}
	}
	return true
}

// roundtrip marshals a value, reads it back, and reports both that the bytes
// came out the expected length and that the value survived.
@(private = "file")
roundtrip :: proc(sig: string, v: dbus.Dbus_Value, want_len: int, label: string) -> []u8 {
	w: dbus.Dbus_Writer
	if !dbus.dbus_marshal(&w, sig, v) {
		check(false, "%s: marshal of %s refused", label, sig)
		return nil
	}
	bytes := w.b[:]
	if want_len >= 0 {
		check(
			len(bytes) == want_len,
			"%s: %s is %d bytes (want %d) [%s]",
			label,
			sig,
			len(bytes),
			want_len,
			hexdump(bytes),
		)
	}
	fakefds := [4]linux.Fd{70, 71, 72, 73}
	r := dbus.Dbus_Reader {
		b   = bytes,
		fds = fakefds[:],
	}
	back := dbus.dbus_unmarshal(&r, sig)
	check(!r.bad, "%s: %s unmarshals cleanly", label, sig)
	check(r.p == len(bytes), "%s: %s consumes all %d bytes (got %d)", label, sig, len(bytes), r.p)
	check(values_equal(v, back), "%s: %s round-trips", label, sig)
	return bytes
}

@(private = "file")
selftest_marshal :: proc() {
	fmt.println("-- signatures")
	{
		ct, next, ok := dbus.dbus_sig_next("a{sv}s", 0)
		check(ok && ct == "a{sv}" && next == 5, "a{{sv}}s splits to a{{sv}} at 5 (got %q,%d)", ct, next)
	}
	{
		ct, next, ok := dbus.dbus_sig_next("a{sv}s", 5)
		check(ok && ct == "s" && next == 6, "...then s (got %q,%d)", ct, next)
	}
	{
		ct, _, ok := dbus.dbus_sig_next("aa(us)", 0)
		check(ok && ct == "aa(us)", "aa(us) is one complete type (got %q)", ct)
	}
	{
		_, _, ok := dbus.dbus_sig_next("a(us", 0)
		check(!ok, "an unbalanced signature is rejected")
	}
	check(dbus.dbus_sig_count("susso") == 5, "susso counts 5 types")
	check(dbus.dbus_sig_count("a(susso)") == 1, "a(susso) counts 1 type")
	check(dbus.dbus_sig_count("(us") == -1, "a broken signature counts -1")
	check(dbus.dbus_align_of('y') == 1, "y aligns to 1")
	check(dbus.dbus_align_of('u') == 4, "u aligns to 4")
	check(dbus.dbus_align_of('t') == 8, "t aligns to 8")
	check(dbus.dbus_align_of('(') == 8, "a struct aligns to 8")
	check(dbus.dbus_align_of('v') == 1, "a variant aligns to 1")

	fmt.println("-- scalars and alignment")
	roundtrip("y", dbus.dbus_y(0xab), 1, "byte")
	roundtrip("b", dbus.dbus_b(true), 4, "bool")
	roundtrip("n", dbus.dbus_n(-2), 2, "int16")
	roundtrip("q", dbus.dbus_q(513), 2, "uint16")
	roundtrip("i", dbus.dbus_i(-77), 4, "int32")
	roundtrip("u", dbus.dbus_u(0xdeadbeef), 4, "uint32")
	roundtrip("x", dbus.dbus_x(-1), 8, "int64")
	roundtrip("t", dbus.dbus_t(1 << 40), 8, "uint64")
	roundtrip("d", dbus.dbus_d(0.5), 8, "double")
	// "hello" is 5 bytes: 4 length + 5 + 1 NUL = 10.
	roundtrip("s", dbus.dbus_s("hello"), 10, "string")
	roundtrip("s", dbus.dbus_s(""), 5, "empty string")
	roundtrip("o", dbus.dbus_o("/org/freedesktop/login1"), 28, "object path")
	roundtrip("g", dbus.dbus_g("a{sv}"), 7, "signature")

	{
		// y then u: one byte, three of padding, four of value.
		w: dbus.Dbus_Writer
		dbus.dbus_marshal(&w, "y", dbus.dbus_y(1))
		dbus.dbus_marshal(&w, "u", dbus.dbus_u(0x04030201))
		b := w.b[:]
		check(len(b) == 8, "y,u pads to 8 bytes (got %d) [%s]", len(b), hexdump(b))
		check(b[1] == 0 && b[2] == 0 && b[3] == 0, "the pad bytes after y are zero")
		check(b[4] == 0x01 && b[7] == 0x04, "the u32 lands at offset 4, little-endian")
	}
	{
		// y then t: one byte, seven of padding, eight of value.
		w: dbus.Dbus_Writer
		dbus.dbus_marshal(&w, "y", dbus.dbus_y(1))
		dbus.dbus_marshal(&w, "t", dbus.dbus_t(1))
		b := w.b[:]
		check(len(b) == 16, "y,t pads to 16 bytes (got %d) [%s]", len(b), hexdump(b))
		check(b[8] == 1, "the u64 lands at offset 8")
	}
	{
		// y then a struct: the struct is forced to 8.
		w: dbus.Dbus_Writer
		dbus.dbus_marshal(&w, "y", dbus.dbus_y(0xff))
		dbus.dbus_marshal(&w, "(yy)", dbus.dbus_struct(dbus.dbus_y(1), dbus.dbus_y(2)))
		b := w.b[:]
		check(len(b) == 10, "y,(yy) pads the struct to offset 8 (got %d) [%s]", len(b), hexdump(b))
		check(b[8] == 1 && b[9] == 2, "the struct members follow the pad")
	}

	fmt.println("-- containers")
	// as of two strings: 4 len + (4+3+1) + (4+5+1) = 4 + 8 + 10 = 22.
	roundtrip("as", dbus.dbus_array("s", dbus.dbus_s("abc"), dbus.dbus_s("hello")), 22, "string array")
	// An empty array is still four bytes of length and no padding (we are
	// already 4-aligned at offset 0 and the element is 4-aligned).
	roundtrip("as", dbus.dbus_array("s"), 4, "empty string array")
	// An empty array of 8-aligned elements still writes the pad to 8.
	roundtrip("a(u)", dbus.dbus_array("(u)"), 8, "empty struct array keeps its pad")
	roundtrip("ay", dbus.dbus_array("y", dbus.dbus_y(1), dbus.dbus_y(2), dbus.dbus_y(3)), 7, "byte array")
	roundtrip("au", dbus.dbus_array("u", dbus.dbus_u(1), dbus.dbus_u(2)), 12, "uint32 array")
	roundtrip(
		"aas",
		dbus.dbus_array("as", dbus.dbus_array("s", dbus.dbus_s("a")), dbus.dbus_array("s", dbus.dbus_s("bb"))),
		4 + (4 + 6) + 2 + (4 + 7),
		"nested array",
	)
	roundtrip(
		"(susso)",
		dbus.dbus_struct(
			dbus.dbus_s("1"),
			dbus.dbus_u(1000),
			dbus.dbus_s("alex"),
			dbus.dbus_s("seat0"),
			dbus.dbus_o("/org/freedesktop/login1/session/_31"),
		),
		-1,
		"ListSessions element",
	)
	roundtrip(
		"a(susso)",
		dbus.dbus_array(
			"(susso)",
			dbus.dbus_struct(
				dbus.dbus_s("1"),
				dbus.dbus_u(1000),
				dbus.dbus_s("alex"),
				dbus.dbus_s("seat0"),
				dbus.dbus_o("/x"),
			),
		),
		-1,
		"ListSessions reply",
	)

	fmt.println("-- variants")
	roundtrip("v", dbus.dbus_variant("u", dbus.dbus_u(7)), 4 + 4, "variant of u")
	roundtrip("v", dbus.dbus_variant("s", dbus.dbus_s("tty")), 3 + 1 + 4 + 3 + 1, "variant of s")
	roundtrip(
		"v",
		dbus.dbus_variant("as", dbus.dbus_array("s", dbus.dbus_s("a"), dbus.dbus_s("b"))),
		-1,
		"variant of as",
	)
	roundtrip("v", dbus.dbus_variant("(so)", dbus.dbus_struct(dbus.dbus_s("seat0"), dbus.dbus_o("/s"))), -1, "variant of (so)")

	fmt.println("-- a{sv}")
	props := dbus.dbus_array(
		"{sv}",
		dbus.dbus_entry(dbus.dbus_s("Id"), dbus.dbus_variant("s", dbus.dbus_s("1"))),
		dbus.dbus_entry(dbus.dbus_s("Active"), dbus.dbus_variant("b", dbus.dbus_b(true))),
		dbus.dbus_entry(dbus.dbus_s("VTNr"), dbus.dbus_variant("u", dbus.dbus_u(1))),
		dbus.dbus_entry(
			dbus.dbus_s("Seat"),
			dbus.dbus_variant("(so)", dbus.dbus_struct(dbus.dbus_s("seat0"), dbus.dbus_o("/seat/seat0"))),
		),
	)
	bytes := roundtrip("a{sv}", props, -1, "property dict")
	{
		r := dbus.Dbus_Reader{b = bytes}
		back := dbus.dbus_unmarshal(&r, "a{sv}")
		check(!r.bad && len(back.items) == 4, "the dict has four entries")
		v, ok := dbus.dbus_dict_get(back, "VTNr")
		check(ok && dbus.dbus_as_u32(v) == 1, "VTNr reads back as 1")
		v2, ok2 := dbus.dbus_dict_get(back, "Active")
		check(ok2 && dbus.dbus_as_bool(v2), "Active reads back as true")
		v3, ok3 := dbus.dbus_dict_get(back, "Seat")
		check(
			ok3 && v3.kind == '(' && len(v3.items) == 2 && v3.items[0].str == "seat0",
			"Seat reads back as (so)",
		)
		_, missing := dbus.dbus_dict_get(back, "Nope")
		check(!missing, "a missing key reports missing")
	}
	{
		// Each dict entry is a struct, so the second one must start at an
		// offset that is 8-aligned relative to the message.
		small := dbus.dbus_array(
			"{sv}",
			dbus.dbus_entry(dbus.dbus_s("a"), dbus.dbus_variant("y", dbus.dbus_y(1))),
			dbus.dbus_entry(dbus.dbus_s("b"), dbus.dbus_variant("y", dbus.dbus_y(2))),
		)
		w: dbus.Dbus_Writer
		dbus.dbus_marshal(&w, "a{sv}", small)
		b := w.b[:]
		// 4 length, entry at 8 (pad 4), entry is 4+1+1 + 1+1+1 + 1 = 10 -> ends
		// at 18, second entry padded to 24, ends at 34.
		check(len(b) == 34, "two one-byte dict entries occupy 34 bytes (got %d) [%s]", len(b), hexdump(b))
	}

	fmt.println("-- descriptors")
	{
		w: dbus.Dbus_Writer
		ok := dbus.dbus_marshal(&w, "h", dbus.dbus_h(linux.Fd(9)))
		check(ok && len(w.b) == 4, "an h marshals as a 4-byte index")
		check(len(w.fds) == 1 && w.fds[0] == 9, "and puts the descriptor in the side table")
		idx := (^u32)(raw_data(w.b[:]))^
		check(idx == 0, "the first descriptor gets index 0 (got %d)", idx)
		dbus.dbus_marshal(&w, "h", dbus.dbus_h(linux.Fd(11)))
		idx2 := (^u32)(raw_data(w.b[4:]))^
		check(idx2 == 1 && len(w.fds) == 2 && w.fds[1] == 11, "the second gets index 1")

		fds := [2]linux.Fd{55, 66}
		r := dbus.Dbus_Reader {
			b   = w.b[:],
			fds = fds[:],
		}
		a := dbus.dbus_unmarshal(&r, "h")
		b := dbus.dbus_unmarshal(&r, "h")
		check(a.fd == 55 && b.fd == 66, "reading h resolves against the control message")
	}

	fmt.println("-- endianness")
	{
		// A big-endian u32 0x01020304.
		raw := [4]u8{0x01, 0x02, 0x03, 0x04}
		r := dbus.Dbus_Reader {
			b  = raw[:],
			be = true,
		}
		v := dbus.dbus_unmarshal(&r, "u")
		check(dbus.dbus_as_u32(v) == 0x01020304, "a big-endian u32 is byte-swapped (got %x)", v.num)
		r2 := dbus.Dbus_Reader {
			b = raw[:],
		}
		v2 := dbus.dbus_unmarshal(&r2, "u")
		check(dbus.dbus_as_u32(v2) == 0x04030201, "a little-endian u32 is not")
	}

	fmt.println("-- whole messages")
	{
		args := [2]dbus.Dbus_Value{dbus.dbus_s("org.freedesktop.login1.Session"), dbus.dbus_s("Active")}
		data, fds, ok := dbus.dbus_encode(
			dbus.DBUS_MSG_CALL,
			0,
			42,
			"/org/freedesktop/login1/session/_31",
			"org.freedesktop.DBus.Properties",
			"Get",
			"org.freedesktop.login1",
			"",
			0,
			"ss",
			args[:],
		)
		check(ok, "a Properties.Get encodes")
		check(len(fds) == 0, "and carries no descriptors")
		check(data[0] == 'l' && data[1] == dbus.DBUS_MSG_CALL && data[3] == 1, "the fixed header is right")
		fields_len := (^u32)(raw_data(data[12:]))^
		body_start := 16 + int((fields_len + 7) & ~u32(7))
		check(body_start % 8 == 0, "the body starts 8-aligned (at %d)", body_start)
		body_len := (^u32)(raw_data(data[4:]))^
		check(
			len(data) == body_start + int(body_len),
			"the message is header + body (%d vs %d)",
			len(data),
			body_start + int(body_len),
		)

		m, used, dok := dbus.dbus_decode(data, nil)
		check(dok && used == len(data), "it decodes, consuming the whole buffer")
		check(m.serial == 42, "the serial survives")
		check(m.member == "Get", "the member survives")
		check(m.iface == "org.freedesktop.DBus.Properties", "the interface survives")
		check(m.path == "/org/freedesktop/login1/session/_31", "the path survives")
		check(m.dest == "org.freedesktop.login1", "the destination survives")
		check(m.signature == "ss", "the signature survives")
		r := dbus.Dbus_Reader {
			b = m.body,
		}
		back := dbus.dbus_unmarshal_all(&r, m.signature)
		check(
			!r.bad && len(back) == 2 && back[1].str == "Active",
			"and the body unmarshals to the two strings",
		)
	}
	{
		// A message whose body needs a descriptor: the UNIX_FDS header field
		// has to appear.
		args := [1]dbus.Dbus_Value{dbus.dbus_h(linux.Fd(3))}
		data, fds, ok := dbus.dbus_encode(
			dbus.DBUS_MSG_RETURN,
			0,
			7,
			"",
			"",
			"",
			"",
			"",
			6,
			"h",
			args[:],
		)
		check(ok && len(fds) == 1 && fds[0] == 3, "a body with an h hands the fd to the sender")
		m, _, dok := dbus.dbus_decode(data, fds)
		check(dok && m.fd_count == 1, "and the decoded header declares one descriptor")
		check(m.reply_serial == 6, "the reply serial survives")
	}
}

@(private = "file")
selftest_live :: proc() {
	fmt.println("-- system bus")
	addr := dbus.dbus_system_address(context.temp_allocator)
	path, abstract, pok := dbus.dbus_parse_address(addr)
	check(pok, "the address %q parses to %q (abstract %v)", addr, path, abstract)
	{
		ap, aabs, aok := dbus.dbus_parse_address("unix:abstract=/tmp/x,guid=ab")
		check(aok && aabs && ap == "/tmp/x", "an abstract address parses too (%q)", ap)
		bp, babs, bok := dbus.dbus_parse_address("tcp:host=localhost;unix:path=/s")
		check(bok && !babs && bp == "/s", "the first unix transport in a list wins (%q)", bp)
		_, _, cok := dbus.dbus_parse_address("tcp:host=localhost")
		check(!cok, "an address with no unix transport is rejected")
	}

	conn, e := dbus.dbus_connect()
	check(e == .None, "the EXTERNAL handshake and Hello succeed (%v)", e)
	if e != .None {
		return
	}
	defer dbus.dbus_close(conn)
	check(
		len(conn.unique) > 1 && conn.unique[0] == ':',
		"the bus gave us a unique name: %s",
		conn.unique,
	)

	{
		m, le := dbus.dbus_call(
			conn,
			SEAT_BUS,
			SEAT_MGR_PATH,
			SEAT_MGR_IFACE,
			"ListSessions",
			"",
			nil,
		)
		check(le == .None, "ListSessions returns (%v)", le)
		if le == .None {
			defer dbus.dbus_msg_free(m)
			check(m.signature == "a(susso)", "with signature a(susso), got %q", m.signature)
			check(len(m.args) == 1 && m.args[0].kind == 'a', "and one array argument")
			n := len(m.args[0].items)
			check(n >= 1, "listing %d session(s)", n)
			for s in m.args[0].items {
				if len(s.items) == 5 {
					fmt.printf(
						"       session %s uid %d user %s seat %s at %s\n",
						s.items[0].str,
						dbus.dbus_as_u32(s.items[1]),
						s.items[2].str,
						s.items[3].str,
						s.items[4].str,
					)
				}
			}
			check(
				len(m.args[0].items) > 0 &&
				len(m.args[0].items[0].items) == 5 &&
				m.args[0].items[0].items[4].kind == 'o',
				"the fifth member of each element is an object path",
			)
		}
	}

	{
		m, le := dbus.dbus_call(conn, SEAT_BUS, SEAT_MGR_PATH, SEAT_MGR_IFACE, "ListSeats", "", nil)
		check(le == .None, "ListSeats returns (%v)", le)
		if le == .None {
			defer dbus.dbus_msg_free(m)
			check(m.signature == "a(so)", "with signature a(so), got %q", m.signature)
			found := false
			for s in m.args[0].items {
				if len(s.items) == 2 {
					fmt.printf("       seat %s at %s\n", s.items[0].str, s.items[1].str)
					if s.items[0].str == "seat0" {
						found = true
					}
				}
			}
			check(found, "seat0 is listed")
		}
	}

	{
		// The bus sends NameAcquired unsolicited right after Hello, which is
		// a real signal off a real socket -- enough to prove the receive path
		// decodes traffic it did not ask for.
		dbus.dbus_dispatch(conn)
		found := false
		for {
			m, got := dbus.dbus_next(conn)
			if !got {
				break
			}
			if m.type == dbus.DBUS_MSG_SIGNAL && m.member == "NameAcquired" {
				found = true
				fmt.printf("       signal %s.%s(%s)\n", m.iface, m.member,
					len(m.args) > 0 ? m.args[0].str : "")
			}
			dbus.dbus_msg_close_fds(m)
			dbus.dbus_msg_free(m)
		}
		check(found, "the pump decoded the bus's unsolicited NameAcquired signal")
	}

	{
		rule := "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Session',member='PauseDevice'"
		check(dbus.dbus_add_match(conn, rule) == .None, "AddMatch is accepted by the bus")
		check(dbus.dbus_remove_match(conn, rule) == .None, "and RemoveMatch takes it off again")
		check(dbus.dbus_remove_match(conn, rule) == .Call_Failed, "removing it twice is an error")
	}

	{
		// An error reply has to come back as an error, not as a hang.
		m, le := dbus.dbus_call(
			conn,
			SEAT_BUS,
			SEAT_MGR_PATH,
			SEAT_MGR_IFACE,
			"GetSession",
			"s",
			[]dbus.Dbus_Value{dbus.dbus_s("no-such-session")},
		)
		check(le == .Call_Failed, "a bad GetSession comes back as an error (%v)", le)
		if m != nil {
			check(m.type == dbus.DBUS_MSG_ERROR, "the reply is an ERROR message")
			check(m.err_name != "", "named %s", m.err_name)
			dbus.dbus_msg_free(m)
		}
	}
}

@(private = "file")
cb_pause, cb_resume, cb_active: int
@(private = "file")
cb_last_kind: string
@(private = "file")
cb_last_active: bool

@(private = "file")
cb_on_pause :: proc(d: ^Seat_Device, kind: string) {
	cb_pause += 1
	cb_last_kind = kind
}

@(private = "file")
cb_on_resume :: proc(d: ^Seat_Device) {
	cb_resume += 1
}

@(private = "file")
cb_on_active :: proc(active: bool) {
	cb_active += 1
	cb_last_active = active
}

@(private = "file")
selftest_seat :: proc() {
	fmt.println("-- seat")
	e := seat_open()
	check(e == .None, "seat_open succeeds (%v)", e)
	if e != .None {
		return
	}
	defer seat_close()

	check(seat.session_path != "", "we found a session object: %s", seat.session_path)
	check(seat.session_id != "", "with id %s", seat.session_id)
	check(seat.seat_id != "", "on seat %s (%s)", seat.seat_id, seat.seat_path)
	check(seat.vtnr > 0, "on vt %d", seat.vtnr)
	check(seat.session_type != "", "of type %s", seat.session_type)
	check(seat.session_state != "", "in state %s", seat.session_state)
	check(seat.active, "and it is the active session (Active = %v)", seat.active)
	check(!seat.control, "we do NOT hold control of it")
	check(seat_fd() >= 0, "the bus fd %d is pollable", seat_fd())
	check(dbus.dbus_alive(seat.conn), "and the connection reports itself alive")
	seat_pump()
	check(dbus.dbus_alive(seat.conn), "a pump with nothing pending leaves it alive")

	// A single-property read has to agree with the GetAll.
	{
		v, m, pe := dbus.dbus_get_property(
			seat.conn,
			SEAT_BUS,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"Id",
		)
		check(pe == .None, "Properties.Get(Id) succeeds (%v)", pe)
		check(v.kind == 's' && v.str == seat.session_id, "and agrees with GetAll: %q", v.str)
		if m != nil {
			dbus.dbus_msg_free(m)
		}
	}
	{
		v, m, pe := dbus.dbus_get_property(
			seat.conn,
			SEAT_BUS,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"VTNr",
		)
		check(pe == .None && v.kind == 'u' && dbus.dbus_as_u32(v) == seat.vtnr, "VTNr agrees: %d", v.num)
		if m != nil {
			dbus.dbus_msg_free(m)
		}
	}
	{
		v, m, pe := dbus.dbus_get_property(
			seat.conn,
			SEAT_BUS,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"Seat",
		)
		check(
			pe == .None && v.kind == '(' && len(v.items) == 2 && v.items[0].str == seat.seat_id,
			"Seat reads back as a (so) naming %s",
			seat.seat_id,
		)
		if m != nil {
			dbus.dbus_msg_free(m)
		}
	}

	fmt.println("-- devices")
	n := seat_scan_devices()
	check(n > 0, "sysfs enumeration found %d device node(s)", n)
	inputs, cards, renders := 0, 0, 0
	for d in seat.devices {
		switch d.kind {
		case .Input:
			inputs += 1
		case .Drm_Card:
			cards += 1
		case .Drm_Render:
			renders += 1
		case .Other:
		}
	}
	check(inputs > 0, "%d evdev node(s)", inputs)
	check(cards > 0, "%d DRM card(s)", cards)
	check(renders >= 0, "%d render node(s)", renders)
	card := seat_primary_card()
	check(card != nil, "there is a primary card")
	if card != nil {
		fmt.printf("       primary card %s is %d:%d\n", card.node, card.major, card.minor)
		check(card.major == 226, "DRM nodes use major 226 (got %d)", card.major)
	}
	for d in seat.devices {
		if d.kind == .Input {
			fmt.printf("       %s %d:%d %s\n", d.node, d.major, d.minor, d.name)
		}
	}
	if card != nil {
		check(seat_device_by_node(card.node) == card, "lookup by node path finds the same device")
		check(
			seat_device_by_dev(card.major, card.minor) == card,
			"lookup by major:minor finds the same device",
		)
	}
	check(seat_device_by_node("/dev/nope") == nil, "an unknown node is not found")
	{
		all_closed := true
		for d in seat.devices {
			if d.fd != -1 || d.taken {
				all_closed = false
			}
		}
		check(all_closed, "no device node has been opened")
	}

	// The VT-switch state machine, driven directly. This is the only way to
	// exercise it without taking control of the live session: the transitions
	// are separated from the signal decoding precisely so that they can be
	// called here with no bus traffic at all.
	fmt.println("-- VT switching (simulated, nothing is sent)")
	if card != nil {
		seat.on_pause = cb_on_pause
		seat.on_resume = cb_on_resume
		seat.on_active = cb_on_active
		cb_pause, cb_resume, cb_active = 0, 0, 0
		kbd := seat_device_by_dev(13, 64)

		check(seat_foreground(), "we start in the foreground")
		check(seat_mark_pause(card.major, card.minor, "pause"), "a 'pause' owes an ack")
		check(seat.graphics_paused, "the card pause sets graphics_paused")
		check(!seat_foreground(), "so we are no longer in the foreground")
		check(cb_pause == 1 && cb_last_kind == "pause", "the pause hook fired once")
		check(card.paused, "and the card is marked paused")
		if kbd != nil {
			check(!seat_mark_pause(13, 64, "force"), "a 'force' pause owes no ack")
			check(kbd.paused, "and the evdev node is marked paused")
			check(cb_pause == 2, "the hook fired for it too")
		}

		seat_mark_active(false)
		check(!seat.active && cb_active == 1 && !cb_last_active, "Active=false is reported once")
		seat_mark_active(false)
		check(cb_active == 1, "a repeat of the same value is not reported again")

		seat_mark_resume(card.major, card.minor, linux.Fd(4242))
		check(card.fd == 4242 && card.taken, "resume installs the replacement descriptor")
		check(!card.paused && !seat.graphics_paused, "and the card is live again")
		check(cb_resume == 1, "the resume hook fired")
		seat_mark_active(true)
		check(seat.active && cb_active == 2, "Active=true is reported")
		check(seat_foreground(), "and we are in the foreground again")

		if kbd != nil {
			check(!seat_mark_pause(13, 64, "gone"), "a 'gone' pause owes no ack")
			check(!kbd.taken, "and drops the device")
		}

		// 4242 was never a real descriptor; put the card back as it was so
		// that seat_close does not close something that is not ours.
		card.fd = -1
		card.taken = false
		card.paused = false
		if kbd != nil {
			kbd.paused = false
		}
		seat.on_pause = nil
		seat.on_resume = nil
		seat.on_active = nil
	}

	// The calls that only a controlling session may make are built and
	// decoded here but deliberately never sent.
	fmt.println("-- messages built but not sent")
	{
		args := [2]dbus.Dbus_Value{dbus.dbus_u(226), dbus.dbus_u(1)}
		data, fds, ok := dbus.dbus_encode(
			dbus.DBUS_MSG_CALL,
			0,
			11,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"TakeDevice",
			SEAT_BUS,
			"",
			0,
			"uu",
			args[:],
		)
		check(ok && len(fds) == 0, "TakeDevice encodes")
		m, _, dok := dbus.dbus_decode(data, nil)
		check(
			dok && m.member == "TakeDevice" && m.signature == "uu" && m.path == seat.session_path,
			"with the header logind expects",
		)
		r := dbus.Dbus_Reader {
			b = m.body,
		}
		a := dbus.dbus_unmarshal_all(&r, "uu")
		check(
			!r.bad && len(a) == 2 && dbus.dbus_as_u32(a[0]) == 226 && dbus.dbus_as_u32(a[1]) == 1,
			"and a body of 226:1 -- which is NOT put on the wire",
		)
	}
	{
		args := [2]dbus.Dbus_Value{dbus.dbus_u(226), dbus.dbus_u(1)}
		data, _, ok := dbus.dbus_encode(
			dbus.DBUS_MSG_CALL,
			dbus.DBUS_FLAG_NO_REPLY,
			12,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"PauseDeviceComplete",
			SEAT_BUS,
			"",
			0,
			"uu",
			args[:],
		)
		check(ok, "PauseDeviceComplete encodes")
		m, _, dok := dbus.dbus_decode(data, nil)
		check(dok && m.member == "PauseDeviceComplete", "with the right member")
		check(m.flags & dbus.DBUS_FLAG_NO_REPLY != 0, "and the no-reply flag set")
	}
	{
		args := [3]dbus.Dbus_Value{dbus.dbus_u(226), dbus.dbus_u(1), dbus.dbus_s("pause")}
		data, _, _ := dbus.dbus_encode(
			dbus.DBUS_MSG_SIGNAL,
			0,
			5,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"PauseDevice",
			"",
			"",
			0,
			"uus",
			args[:],
		)
		m, _, dok := dbus.dbus_decode(data, nil)
		check(
			dok && m.type == dbus.DBUS_MSG_SIGNAL && m.member == "PauseDevice",
			"a PauseDevice signal decodes as a signal",
		)
		r := dbus.Dbus_Reader {
			b = m.body,
		}
		a := dbus.dbus_unmarshal_all(&r, "uus")
		check(
			!r.bad && dbus.dbus_as_u32(a[0]) == 226 && dbus.dbus_as_u32(a[1]) == 1 && a[2].str == "pause",
			"carrying 226:1 pause",
		)
	}
	{
		args := [3]dbus.Dbus_Value{dbus.dbus_u(226), dbus.dbus_u(1), dbus.dbus_h(linux.Fd(31))}
		data, fds, _ := dbus.dbus_encode(
			dbus.DBUS_MSG_SIGNAL,
			0,
			6,
			seat.session_path,
			SEAT_SESSION_IFACE,
			"ResumeDevice",
			"",
			"",
			0,
			"uuh",
			args[:],
		)
		check(len(fds) == 1 && fds[0] == 31, "a ResumeDevice signal hands its fd out of band")
		m, _, dok := dbus.dbus_decode(data, fds)
		check(dok && m.fd_count == 1, "and declares UNIX_FDS = 1 in the header")
		r := dbus.Dbus_Reader {
			b   = m.body,
			fds = fds,
		}
		a := dbus.dbus_unmarshal_all(&r, "uuh")
		check(
			!r.bad && a[2].kind == 'h' && a[2].fd == 31,
			"the h resolves against the control message",
		)
	}
	{
		args := [2]dbus.Dbus_Value{dbus.dbus_h(linux.Fd(17)), dbus.dbus_b(true)}
		data, fds, _ := dbus.dbus_encode(
			dbus.DBUS_MSG_RETURN,
			0,
			13,
			"",
			"",
			"",
			"",
			"",
			11,
			"hb",
			args[:],
		)
		m, _, _ := dbus.dbus_decode(data, fds)
		r := dbus.Dbus_Reader {
			b   = m.body,
			fds = fds,
		}
		a := dbus.dbus_unmarshal_all(&r, "hb")
		check(
			!r.bad && a[0].fd == 17 && dbus.dbus_as_bool(a[1]),
			"a TakeDevice reply yields (fd, inactive=true)",
		)
	}

	fmt.println("-- the safety gate")
	if seat.live {
		fmt.println(
			"  !!   PALMY_WM_SEAT_LIVE is set; skipping the gate assertions and\n" +
			"  !!   refusing to call TakeControl from the self-test.",
		)
		return
	}
	check(!seat.live, "PALMY_WM_SEAT_LIVE is not set")
	check(seat_take_control() == .Gated, "TakeControl is refused")
	check(seat_take_control(true) == .Gated, "TakeControl(force) is refused")
	{
		_, _, de := seat_take_device(226, 1)
		check(de == .Gated, "TakeDevice is refused")
	}
	if card != nil {
		_, _, te := seat_take_node(card.node)
		check(te == .Gated, "TakeDevice by node is refused")
	}
	check(seat_release_device(226, 1) == .Gated, "ReleaseDevice is refused")
	check(seat_activate() == .Gated, "Activate is refused")
	check(seat_switch_to(2) == .Gated, "SwitchTo is refused")
	{
		_, _, ne := seat_take_node("/dev/nope")
		check(ne == .Not_Found, "an unknown node is not found")
	}
	check(!seat.control, "and we still hold no control")
}

seat_selftest :: proc() -> int {
	st_pass, st_fail = 0, 0
	fmt.println("wm seat/dbus self-test")
	selftest_marshal()
	selftest_live()
	selftest_seat()
	fmt.printf("\n%d passed, %d failed\n", st_pass, st_fail)
	return st_fail == 0 ? 0 : 1
}

// The flag is picked up here rather than in main.odin so that this file is
// self-contained. /proc/self/cmdline is read instead of os.args because an
// @(init) proc runs before main and must not assume the runtime has already
// populated them; for the same reason it is contextless and makes its own
// context only once it has decided to run.
@(init)
seat_selftest_hook :: proc "contextless" () {
	buf: [4096]u8
	fd, err := linux.open("/proc/self/cmdline", {})
	if err != .NONE {
		return
	}
	n, rerr := linux.read(fd, buf[:])
	linux.close(fd)
	if rerr != .NONE || n <= 0 {
		return
	}
	start := 0
	for i in 0 ..< n {
		if buf[i] == 0 {
			if string(buf[start:i]) == "--selftest-seat" {
				context = runtime.default_context()
				os.exit(seat_selftest())
			}
			start = i + 1
		}
	}
}
