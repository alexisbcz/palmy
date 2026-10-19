// org.freedesktop.Notifications, version 1.2, on the session bus.
//
// This is the door every program not written for Palmframe already knows:
// libnotify's notify-send, Firefox and Chromium (web notifications),
// Thunderbird, anything GTK or Qt. The server is the kit's D-Bus client
// (apps/kit/dbus) used the other way round: it owns a well-known name,
// receives method calls and answers them. The kit's client sends only calls,
// so replies and signals are encoded with its public `dbus_encode` and
// written to the connection's socket here.
//
// What a third-party notification gets:
//   - an identity: the hint `x-palm-identity` when the sender's own scope
//     allows it, else the sender process's PALM_IDENTITY (its pid comes from
//     the bus, GetConnectionUnixProcessID), else the window manager's view
//   - a class: the hint `x-palm-class`, else from the freedesktop category
//     (model.odin: class_for_category)
//   - a key: the hint `x-palm-key` for senders that know about "once";
//     `replaces_id` maps onto the key of the notification it replaces
//   - the same policy, dedupe and center as everything else
//
// Capabilities advertised: actions, body, persistence, sound. Not
// body-markup: a sender that would send markup then sends plain text, and
// any tag that arrives anyway is stripped rather than drawn.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "kit:dbus"

FDO_NAME :: "org.freedesktop.Notifications"
FDO_PATH :: "/org/freedesktop/Notifications"
FDO_IFACE :: "org.freedesktop.Notifications"

FDO_INTROSPECT :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
 <interface name="org.freedesktop.Notifications">
  <method name="Notify">
   <arg type="s" name="app_name" direction="in"/>
   <arg type="u" name="replaces_id" direction="in"/>
   <arg type="s" name="app_icon" direction="in"/>
   <arg type="s" name="summary" direction="in"/>
   <arg type="s" name="body" direction="in"/>
   <arg type="as" name="actions" direction="in"/>
   <arg type="a{sv}" name="hints" direction="in"/>
   <arg type="i" name="expire_timeout" direction="in"/>
   <arg type="u" name="id" direction="out"/>
  </method>
  <method name="CloseNotification"><arg type="u" name="id" direction="in"/></method>
  <method name="GetCapabilities"><arg type="as" name="capabilities" direction="out"/></method>
  <method name="GetServerInformation">
   <arg type="s" name="name" direction="out"/>
   <arg type="s" name="vendor" direction="out"/>
   <arg type="s" name="version" direction="out"/>
   <arg type="s" name="spec_version" direction="out"/>
  </method>
  <signal name="NotificationClosed"><arg type="u" name="id"/><arg type="u" name="reason"/></signal>
  <signal name="ActionInvoked"><arg type="u" name="id"/><arg type="s" name="action_key"/></signal>
 </interface>
 <interface name="org.freedesktop.DBus.Introspectable">
  <method name="Introspect"><arg type="s" name="xml" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.DBus.Peer">
  <method name="Ping"/>
 </interface>
</node>
`

// session_bus_address is $DBUS_SESSION_BUS_ADDRESS, or the per-user bus at
// $XDG_RUNTIME_DIR/bus that libdbus and GLib also fall back to -- which is
// where /etc/palm/session.d/45-dbus-session puts it on Palmframe.
session_bus_address :: proc() -> string {
	if a := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator); a != "" {
		return a
	}
	p := fmt.tprintf("%s/bus", runtime_dir())
	if os.exists(p) {
		return fmt.tprintf("unix:path=%s", p)
	}
	return ""
}

bus_try :: proc(d: ^Daemon) {
	d.bus_tries += 1
	// Quickly at first (the bus hook may be starting alongside us), then
	// every half minute.
	d.bus_retry_at = wall_ms() + (d.bus_tries < 12 ? 5000 : 30_000)
	addr := session_bus_address()
	if addr == "" {
		if d.bus_tries == 1 {
			fmt.eprintln("palm-notifyd: no session bus yet; native socket only (will keep looking)")
		}
		return
	}
	if d.bus != nil {
		dbus.dbus_close(d.bus)
		d.bus = nil
	}
	c, e := dbus.dbus_connect(addr)
	if e != .None {
		if d.bus_tries == 1 {
			fmt.eprintfln("palm-notifyd: session bus %s: %v", addr, e)
		}
		return
	}
	d.bus = c
	// DO_NOT_QUEUE (4), and REPLACE_EXISTING (2) only when asked: on a
	// desktop that already runs a notification server, Palmframe's does not
	// take the name from under it unless told to.
	flags := u32(4)
	if os.get_env("PALM_NOTIFY_REPLACE", context.temp_allocator) != "" {
		flags |= 2
	}
	args := [2]dbus.Dbus_Value{dbus.dbus_s(FDO_NAME), dbus.dbus_u(flags)}
	m, re := dbus.dbus_call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", args[:])
	if re != .None || m == nil || len(m.args) != 1 {
		fmt.eprintfln("palm-notifyd: RequestName failed: %v", re)
		if m != nil {
			dbus.dbus_msg_free(m)
		}
		return
	}
	res := dbus.dbus_as_u32(m.args[0])
	dbus.dbus_msg_free(m)
	d.bus_owned = res == 1 || res == 4
	if d.bus_owned {
		fmt.eprintfln("palm-notifyd: %s owned on %s", FDO_NAME, addr)
	} else {
		fmt.eprintfln("palm-notifyd: %s is held by another server on %s; native socket only", FDO_NAME, addr)
	}
	d.bus_tries = 0
	d.bus_retry_at = wall_ms() + 30_000
}

@(private = "file")
bus_write :: proc(d: ^Daemon, type: u8, dest, path, iface, member, err_name: string, reply_serial: u32, sig: string, args: []dbus.Dbus_Value) {
	if d.bus == nil || !dbus.dbus_alive(d.bus) {
		return
	}
	d.bus.serial += 1
	data, fds, ok := dbus.dbus_encode(type, 0, d.bus.serial, path, iface, member, dest, err_name, reply_serial, sig, args)
	if !ok {
		return
	}
	defer delete(data)
	defer delete(fds)
	fd := dbus.dbus_fd(d.bus)
	sent := 0
	for sent < len(data) {
		n, e := linux.send(fd, data[sent:], {.NOSIGNAL})
		if e == .EINTR || e == .EAGAIN {
			if e == .EAGAIN {
				pfd := [1]linux.Poll_Fd{{fd = fd, events = {.OUT}}}
				linux.poll(pfd[:], 100)
			}
			continue
		}
		if e != .NONE || n <= 0 {
			return
		}
		sent += n
	}
}

@(private = "file")
bus_reply :: proc(d: ^Daemon, m: ^dbus.Dbus_Msg, sig: string, args: []dbus.Dbus_Value) {
	if m.flags & dbus.DBUS_FLAG_NO_REPLY != 0 {
		return
	}
	bus_write(d, dbus.DBUS_MSG_RETURN, m.sender, "", "", "", "", m.serial, sig, args)
}

@(private = "file")
bus_error :: proc(d: ^Daemon, m: ^dbus.Dbus_Msg, name, text: string) {
	if m.flags & dbus.DBUS_FLAG_NO_REPLY != 0 {
		return
	}
	args := [1]dbus.Dbus_Value{dbus.dbus_s(text)}
	bus_write(d, dbus.DBUS_MSG_ERROR, m.sender, "", "", "", name, m.serial, "s", args[:])
}

@(private = "file")
bus_signal :: proc(d: ^Daemon, member, sig: string, args: []dbus.Dbus_Value) {
	if !d.bus_owned {
		return
	}
	bus_write(d, dbus.DBUS_MSG_SIGNAL, "", FDO_PATH, FDO_IFACE, member, "", 0, sig, args)
}

// fdo_closed tells a freedesktop sender its notification is gone: 1 expired,
// 2 dismissed by the user, 3 closed by CloseNotification, 4 undefined. A
// toast going by is *not* a close here: the server advertises persistence,
// and the notification is still in the center.
fdo_closed :: proc(d: ^Daemon, n: ^Note, reason: u32) {
	if n.source != .Fdo {
		return
	}
	args := [2]dbus.Dbus_Value{dbus.dbus_u(n.id), dbus.dbus_u(reason)}
	bus_signal(d, "NotificationClosed", "uu", args[:])
}

fdo_action :: proc(d: ^Daemon, n: ^Note, key: string) {
	if n.source != .Fdo {
		return
	}
	args := [2]dbus.Dbus_Value{dbus.dbus_u(n.id), dbus.dbus_s(key)}
	bus_signal(d, "ActionInvoked", "us", args[:])
}

fdo_pump :: proc(d: ^Daemon) {
	if d.bus == nil {
		return
	}
	if e := dbus.dbus_dispatch(d.bus); e != .None && !dbus.dbus_alive(d.bus) {
		fmt.eprintln("palm-notifyd: the session bus went away")
		dbus.dbus_close(d.bus)
		d.bus = nil
		d.bus_owned = false
		d.bus_retry_at = wall_ms() + 2000
		return
	}
	for {
		m, ok := dbus.dbus_next(d.bus)
		if !ok {
			break
		}
		if m.type == dbus.DBUS_MSG_CALL {
			fdo_call(d, m)
		}
		dbus.dbus_msg_close_fds(m)
		dbus.dbus_msg_free(m)
		if d.bus == nil {
			break
		}
	}
}

@(private = "file")
fdo_call :: proc(d: ^Daemon, m: ^dbus.Dbus_Msg) {
	switch m.iface {
	case "org.freedesktop.DBus.Introspectable":
		if m.member == "Introspect" {
			args := [1]dbus.Dbus_Value{dbus.dbus_s(FDO_INTROSPECT)}
			bus_reply(d, m, "s", args[:])
			return
		}
	case "org.freedesktop.DBus.Peer":
		if m.member == "Ping" {
			bus_reply(d, m, "", nil)
			return
		}
	case FDO_IFACE, "":
		switch m.member {
		case "GetCapabilities":
			caps := dbus.dbus_array(
				"s",
				dbus.dbus_s("actions"),
				dbus.dbus_s("body"),
				dbus.dbus_s("persistence"),
				dbus.dbus_s("sound"),
				dbus.dbus_s("x-palm-identity"),
			)
			args := [1]dbus.Dbus_Value{caps}
			bus_reply(d, m, "as", args[:])
			return
		case "GetServerInformation":
			args := [4]dbus.Dbus_Value{dbus.dbus_s("Palmframe Notifications"), dbus.dbus_s("Palmframe"), dbus.dbus_s("0.1.0"), dbus.dbus_s("1.2")}
			bus_reply(d, m, "ssss", args[:])
			return
		case "Notify":
			if m.signature != "susssasa{sv}i" || len(m.args) != 8 {
				bus_error(d, m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify takes (susssasa{sv}i)")
				return
			}
			id := fdo_notify(d, m)
			args := [1]dbus.Dbus_Value{dbus.dbus_u(id)}
			bus_reply(d, m, "u", args[:])
			return
		case "CloseNotification":
			if len(m.args) == 1 {
				id := dbus.dbus_as_u32(m.args[0])
				if n, idx := store_find_id(&d.store, id); n != nil && n.fdo_sender == m.sender {
					fdo_closed(d, n, 3)
					store_remove(&d.store, idx, now_ms(d))
				}
				bus_reply(d, m, "", nil)
				return
			}
		}
	}
	bus_error(d, m, "org.freedesktop.DBus.Error.UnknownMethod", fmt.tprintf("%s.%s is not implemented", m.iface, m.member))
}

@(private = "file")
sender_pid :: proc(d: ^Daemon, sender: string) -> i32 {
	args := [1]dbus.Dbus_Value{dbus.dbus_s(sender)}
	m, e := dbus.dbus_call(d.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", args[:], 2000)
	if m == nil {
		return 0
	}
	defer dbus.dbus_msg_free(m)
	if e != .None || len(m.args) != 1 {
		return 0
	}
	return i32(dbus.dbus_as_u32(m.args[0]))
}

// strip_markup removes the small HTML subset the spec allows (b, i, u, a,
// img) and decodes the five entities, since body-markup is not advertised
// but some senders send it anyway.
strip_markup :: proc(s: string) -> string {
	if strings.index_any(s, "<&") < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	in_tag := false
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if in_tag {
			if ch == '>' {
				in_tag = false
			}
			continue
		}
		if ch == '<' {
			in_tag = true
			continue
		}
		if ch == '&' {
			rest := s[i:]
			replaced := false
			for e in ([?]struct {
				name: string,
				ch:   u8,
			}{{"&amp;", '&'}, {"&lt;", '<'}, {"&gt;", '>'}, {"&quot;", '"'}, {"&apos;", '\''}}) {
				if strings.has_prefix(rest, e.name) {
					strings.write_byte(&sb, e.ch)
					i += len(e.name) - 1
					replaced = true
					break
				}
			}
			if replaced {
				continue
			}
		}
		strings.write_byte(&sb, ch)
	}
	return strings.to_string(sb)
}

@(private = "file")
fdo_notify :: proc(d: ^Daemon, m: ^dbus.Dbus_Msg) -> u32 {
	app_name := m.args[0].str
	replaces := dbus.dbus_as_u32(m.args[1])
	summary := m.args[3].str
	body := m.args[4].str
	actions := m.args[5]
	hints := m.args[6]
	expire := dbus.dbus_as_i32(m.args[7])

	n: Note
	n.app = app_name
	if v, ok := dbus.dbus_dict_get(hints, "desktop-entry"); ok && app_name == "" {
		n.app = v.str
	}
	if n.app == "" {
		n.app = "unknown"
	}
	n.title = strip_markup(summary)
	if n.title == "" {
		n.title = app_label(n.app)
	}
	n.body = strip_markup(body)
	n.urgency = .Normal
	if v, ok := dbus.dbus_dict_get(hints, "urgency"); ok {
		switch v.num {
		case 0:
			n.urgency = .Low
		case 2:
			n.urgency = .Critical
		}
	}
	if v, ok := dbus.dbus_dict_get(hints, "category"); ok {
		n.category = v.str
	}
	n.class = class_for_category(n.category, n.urgency)
	if v, ok := dbus.dbus_dict_get(hints, "x-palm-class"); ok {
		if c, good := class_parse(v.str); good {
			n.class = c
		}
	}
	if v, ok := dbus.dbus_dict_get(hints, "x-palm-key"); ok {
		n.key = v.str
	}
	if v, ok := dbus.dbus_dict_get(hints, "x-palm-link"); ok {
		n.link = v.str
	}
	if expire > 0 {
		n.timeout_ms = int(expire)
	}

	// The sender's scope, from its process: a work browser's notification is
	// a work notification.
	pid := sender_pid(d, m.sender)
	scope := proc_env(pid, "PALM_IDENTITY")
	fmt.eprintfln("palm-notifyd: fdo Notify from %s (pid %d%s)", m.sender, pid, scope != "" ? fmt.tprintf(", PALM_IDENTITY=%s", scope) : "")
	n.identity = sender_identity(pid, scope)
	if v, ok := dbus.dbus_dict_get(hints, "x-palm-identity"); ok && in_scope(scope, v.str) {
		n.identity = v.str
	}

	n.actions = make([dynamic]Action, context.temp_allocator)
	if actions.kind == 'a' {
		for i := 0; i + 1 < len(actions.items); i += 2 {
			append(&n.actions, Action{key = actions.items[i].str, label = actions.items[i + 1].str})
		}
	}

	if replaces != 0 {
		// Any connection may replace: notify-send -r runs as a new process
		// with a new bus name every time.
		if old, _ := store_find_id(&d.store, replaces); old != nil && old.source == .Fdo {
			n.key = old.key
		}
	}
	n.source = .Fdo
	n.fdo_sender = m.sender
	_, a := deliver(d, &n, false)
	if a.note == nil {
		// Already delivered once and put away. The spec wants an id all
		// the same; a fresh one that names nothing is the honest answer.
		id := d.store.next_id
		d.store.next_id += 1
		return id
	}
	// The id the sender gets is the stored notification's: an update keeps
	// the id it had, and the latest sender is the one told about clicks.
	set_str(&a.note.fdo_sender, m.sender)
	return a.note.id
}
