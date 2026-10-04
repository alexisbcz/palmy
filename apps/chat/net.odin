package main

// The client half of the protocol.
//
// There are no threads here. The socket is non-blocking and serviced once per
// frame from the frame loop, which is both simpler than a reader thread and
// the only arrangement palmy's loop permits: it blocks in `poll` on the
// Wayland fd and exposes no way to add a second fd or to wake it from
// elsewhere, so the window asks for a frame every vsync (`always = true`) and
// drains the socket there.
//
// Reconnection is explicit and visible: `Link` is one of offline, connecting
// or online, the sidebar says which, and the composer refuses to pretend a
// message was sent when it was not.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import w "wire"

RETRY_MAX :: 5.0

net_connect :: proc(a: ^App) {
	if a.link == .Online {
		return
	}
	a.link = .Connecting
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = a.args.port})
	if err != nil {
		a.link = .Offline
		a.retry_at = a.now + a.retry_in
		a.retry_in = min(a.retry_in * 2, RETRY_MAX)
		return
	}
	if berr := net.set_blocking(sock, false); berr != nil {
		net.close(sock)
		a.link = .Offline
		a.retry_at = a.now + a.retry_in
		return
	}
	a.sock = sock
	a.link = .Online
	a.retry_in = 0.4
	clear(&a.rd.buf)
	a.rd.bad = false

	e: w.Enc
	w.enc_begin(&e, "hello")
	w.kv_str(&e, "nick", a.nick)
	w.kv_str(&e, "presence", a.away ? "away" : "online")
	net_send(a, w.enc_done(&e))
}

net_close :: proc(a: ^App) {
	if a.link != .Offline {
		net.close(a.sock)
	}
	a.link = .Offline
}

// net_drop is what every failed read or write funnels into: the link goes
// down, the model keeps whatever it had, and a retry is scheduled.
net_drop :: proc(a: ^App, why: string) {
	if a.link == .Online {
		net.close(a.sock)
	}
	a.link = .Offline
	a.err_text = why
	a.retry_at = a.now + a.retry_in
	a.retry_in = min(a.retry_in * 2, RETRY_MAX)
	a.typing_on = false
	clear(&a.typers)
	for &m in a.members {
		m.state = .Offline
	}
}

net_send :: proc(a: ^App, payload: string) -> bool {
	if a.link != .Online {
		return false
	}
	if !w.send_frame(a.sock, payload) {
		net_drop(a, "the server closed the connection")
		return false
	}
	return true
}

// net_pump drains whatever has arrived and applies it. Called once per frame.
net_pump :: proc(a: ^App) {
	if a.link == .Offline {
		if a.now >= a.retry_at {
			net_connect(a)
		}
		return
	}

	buf: [32 * 1024]u8
	for {
		n, err := net.recv_tcp(a.sock, buf[:])
		if err == .Would_Block || err == .Timeout {
			break
		}
		if err == .Interrupted {
			continue
		}
		if err != nil {
			net_drop(a, fmt.aprintf("read failed: %v", err))
			return
		}
		if n == 0 {
			net_drop(a, "the server hung up")
			return
		}
		w.reader_feed(&a.rd, buf[:n])
		if n < len(buf) {
			break
		}
	}
	if a.rd.bad {
		net_drop(a, "the server sent a frame that was too long")
		return
	}

	for {
		payload, ok := w.reader_next(&a.rd, context.temp_allocator)
		if !ok {
			break
		}
		if o, good := w.parse_obj(payload, context.temp_allocator); good {
			apply(a, o)
		}
	}
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

next_rq :: proc(a: ^App) -> i64 {
	a.rq += 1
	return a.rq
}

send_join :: proc(a: ^App, ch: string, kind := "channel") {
	e: w.Enc
	w.enc_begin(&e, "join")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "kind", kind)
	net_send(a, w.enc_done(&e))
}

req_history :: proc(a: ^App, ch: string, before: i64) {
	e: w.Enc
	w.enc_begin(&e, "history")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "before", before)
	w.kv_int(&e, "limit", 60)
	net_send(a, w.enc_done(&e))
}

send_post :: proc(a: ^App, ch, text: string, reply_to: i64) {
	e: w.Enc
	w.enc_begin(&e, "post")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	if reply_to != 0 {
		w.kv_int(&e, "reply_to", reply_to)
	}
	net_send(a, w.enc_done(&e))
}

send_edit :: proc(a: ^App, id: i64, text: string) {
	e: w.Enc
	w.enc_begin(&e, "edit")
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "text", text)
	net_send(a, w.enc_done(&e))
}

send_delete :: proc(a: ^App, id: i64) {
	e: w.Enc
	w.enc_begin(&e, "delete")
	w.kv_int(&e, "id", id)
	net_send(a, w.enc_done(&e))
}

send_react :: proc(a: ^App, id: i64, key: string, on: bool) {
	e: w.Enc
	w.enc_begin(&e, "react")
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "key", key)
	w.kv_bool(&e, "on", on)
	net_send(a, w.enc_done(&e))
}

send_typing :: proc(a: ^App, ch: string, on: bool) {
	e: w.Enc
	w.enc_begin(&e, "typing")
	w.kv_str(&e, "ch", ch)
	w.kv_bool(&e, "on", on)
	net_send(a, w.enc_done(&e))
}

send_presence :: proc(a: ^App, state: w.Presence) {
	e: w.Enc
	w.enc_begin(&e, "presence")
	w.kv_str(&e, "state", w.presence_name(state))
	net_send(a, w.enc_done(&e))
}

send_search :: proc(a: ^App, q: string) {
	e: w.Enc
	w.enc_begin(&e, "search")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_str(&e, "q", q)
	net_send(a, w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// Applying server events
// ---------------------------------------------------------------------------

apply :: proc(a: ^App, o: json.Object) {
	switch w.ostr(o, "t") {
	case "welcome":
		a.err_text = ""

	case "channels":
		apply_channels(a, o)

	case "users":
		clear(&a.members)
		for uv in w.oarr(o, "list") {
			uo, ok := w.as_obj(uv)
			if !ok {
				continue
			}
			append(
				&a.members,
				Member {
					nick = strings.clone(w.ostr(uo, "nick")),
					state = w.presence_of(w.ostr(uo, "state")),
				},
			)
		}
		sort_members(a)

	case "presence":
		nick := w.ostr(o, "nick")
		state := w.presence_of(w.ostr(o, "state"))
		found := false
		for &m in a.members {
			if m.nick == nick {
				m.state = state
				found = true
				break
			}
		}
		if !found {
			append(&a.members, Member{nick = strings.clone(nick), state = state})
		}
		if state == .Offline {
			for i := len(a.typers) - 1; i >= 0; i -= 1 {
				if a.typers[i].nick == nick {
					ordered_remove(&a.typers, i)
				}
			}
		}
		sort_members(a)

	case "message":
		mo, ok := w.as_obj(o["msg"] or_else nil)
		if !ok {
			return
		}
		take_message(a, w.msg_from(mo, context.allocator))

	case "history":
		apply_history(a, o)

	case "edit":
		if m := locate(a, w.ostr(o, "ch"), w.oint(o, "id")); m != nil {
			m.text = strings.clone(w.ostr(o, "text"))
			m.edited = w.oint(o, "edited")
		}

	case "delete":
		if m := locate(a, w.ostr(o, "ch"), w.oint(o, "id")); m != nil {
			m.deleted = true
			m.text = ""
			clear(&m.reacts)
		}

	case "react":
		if m := locate(a, w.ostr(o, "ch"), w.oint(o, "id")); m != nil {
			key, nick := w.ostr(o, "key"), w.ostr(o, "nick")
			if w.obool(o, "on") {
				w.react_add(m, key, nick)
			} else {
				w.react_remove(m, key, nick)
			}
		}

	case "typing":
		apply_typing(a, o)

	case "results":
		clear(&a.results)
		for mv in w.oarr(o, "msgs") {
			mo, ok := w.as_obj(mv)
			if !ok {
				continue
			}
			append(&a.results, w.msg_from(mo, context.allocator))
		}
		a.searched = true
		a.sel_result = 0

	case "error":
		code := w.ostr(o, "code")
		toast(a, fmt.tprintf("%s: %s", code, w.ostr(o, "msg")))

	case "joined", "left", "pong":
		// Nothing to show: the channel list and the history say what happened.
	}
}

apply_channels :: proc(a: ^App, o: json.Object) {
	seen := make(map[string]bool, context.temp_allocator)
	for cv in w.oarr(o, "list") {
		co, ok := w.as_obj(cv)
		if !ok {
			continue
		}
		name := w.ostr(co, "name")
		seen[name] = true
		kind := w.ostr(co, "kind") == "dm" ? w.Chan_Kind.DM : w.Chan_Kind.Channel
		if i := find_chan(a, name); i >= 0 {
			a.chans[i].kind = kind
			a.chans[i].topic = strings.clone(w.ostr(co, "topic"))
			continue
		}
		append(
			&a.chans,
			Channel {
				name = strings.clone(name),
				kind = kind,
				topic = strings.clone(w.ostr(co, "topic")),
				msgs = make([dynamic]w.Msg),
			},
		)
		// Joining is what makes a DM visible to the other side, and it is
		// free for an ordinary channel.
		send_join(a, name, kind == .DM ? "dm" : "channel")
	}

	if a.cur < 0 && len(a.chans) > 0 {
		a.cur = 0
		req_history(a, a.chans[0].name, 0)
		a.want_bottom = true
	}
	// A DM the user just asked for becomes the active channel, which is what
	// asking for it meant.
	if a.pending_dm != "" && seen[a.pending_dm] {
		if i := find_chan(a, a.pending_dm); i >= 0 {
			switch_to(a, i)
			a.pending_dm = ""
		}
	}
}

apply_history :: proc(a: ^App, o: json.Object) {
	name := w.ostr(o, "ch")
	i := find_chan(a, name)
	if i < 0 {
		return
	}
	c := &a.chans[i]
	c.loaded = true
	c.more = w.obool(o, "more")
	for mv in w.oarr(o, "msgs") {
		mo, ok := w.as_obj(mv)
		if !ok {
			continue
		}
		insert_sorted(c, w.msg_from(mo, context.allocator))
	}
	// History is the user's own doing, so it never counts as unread.
	if len(c.msgs) > 0 && i == a.cur && a.pinned {
		c.seen = c.msgs[len(c.msgs) - 1].id
		c.unread = 0
	}
}

apply_typing :: proc(a: ^App, o: json.Object) {
	nick := w.ostr(o, "nick")
	ch := w.ostr(o, "ch")
	on := w.obool(o, "on", true)
	for i := len(a.typers) - 1; i >= 0; i -= 1 {
		if a.typers[i].nick == nick && a.typers[i].ch == ch {
			ordered_remove(&a.typers, i)
		}
	}
	if on && nick != a.nick {
		append(&a.typers, Typer{nick = strings.clone(nick), ch = strings.clone(ch), at = a.now})
	}
}

// take_message files a broadcast message and updates unread state.
take_message :: proc(a: ^App, m: w.Msg) {
	i := find_chan(a, m.ch)
	if i < 0 {
		// A channel we have not been told about yet; ask.
		e: w.Enc
		w.enc_begin(&e, "channels")
		net_send(a, w.enc_done(&e))
		return
	}
	c := &a.chans[i]
	if msg_at(c, m.id) != nil {
		return
	}
	insert_sorted(c, m)

	if i == a.cur && a.pinned {
		c.seen = m.id
		c.unread = 0
		a.new_below = 0
	} else if m.nick != a.nick {
		c.unread += 1
		if strings.contains(strings.to_lower(m.text, context.temp_allocator), strings.to_lower(a.nick, context.temp_allocator)) {
			c.mention = true
		}
		if i == a.cur {
			a.new_below += 1
		}
	}
}

insert_sorted :: proc(c: ^Channel, m: w.Msg) {
	if len(c.msgs) == 0 || c.msgs[len(c.msgs) - 1].id < m.id {
		append(&c.msgs, m)
		return
	}
	for i in 0 ..< len(c.msgs) {
		if c.msgs[i].id == m.id {
			return
		}
		if c.msgs[i].id > m.id {
			inject_at(&c.msgs, i, m)
			return
		}
	}
	append(&c.msgs, m)
}

locate :: proc(a: ^App, ch: string, id: i64) -> ^w.Msg {
	if i := find_chan(a, ch); i >= 0 {
		return msg_at(&a.chans[i], id)
	}
	// Search results hold their own copies; keep them in step too.
	for &m in a.results {
		if m.id == id {
			return &m
		}
	}
	return nil
}

// sort_members puts the people who are here first, then away, then offline,
// and alphabetically inside each band — which is the order a member list is
// actually read in.
sort_members :: proc(a: ^App) {
	for i in 1 ..< len(a.members) {
		j := i
		for j > 0 && member_before(a.members[j], a.members[j - 1]) {
			a.members[j], a.members[j - 1] = a.members[j - 1], a.members[j]
			j -= 1
		}
	}
	a.sel_member = clamp(a.sel_member, 0, max(0, len(a.members) - 1))
}

member_before :: proc(x, y: Member) -> bool {
	if x.state != y.state {
		return int(x.state) > int(y.state)
	}
	return x.nick < y.nick
}

// ---------------------------------------------------------------------------
// One-shot post, for scripts and for the demo's multi-line markdown (the
// recorder cannot synthesise Shift+Enter).
// ---------------------------------------------------------------------------

post_once :: proc(args: Args) -> int {
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = args.port})
	if err != nil {
		fmt.eprintfln("chat: cannot reach 127.0.0.1:%d: %v", args.port, err)
		return 1
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 3 * time.Second)

	e: w.Enc
	w.enc_begin(&e, "hello", context.allocator)
	w.kv_str(&e, "nick", args.nick)
	if !w.send_frame(sock, w.enc_done(&e)) {
		return 1
	}

	j: w.Enc
	w.enc_begin(&j, "join", context.allocator)
	w.kv_str(&j, "ch", args.post_ch)
	w.send_frame(sock, w.enc_done(&j))

	m: w.Enc
	w.enc_begin(&m, "post", context.allocator)
	w.kv_str(&m, "ch", args.post_ch)
	w.kv_str(&m, "text", args.post_txt)
	if !w.send_frame(sock, w.enc_done(&m)) {
		return 1
	}

	// Wait for the broadcast to come back, so "posted" means the server took
	// it rather than that a write succeeded.
	rd: w.Reader
	buf: [8192]u8
	for _ in 0 ..< 200 {
		n, rerr := net.recv_tcp(sock, buf[:])
		if rerr != nil || n == 0 {
			break
		}
		w.reader_feed(&rd, buf[:n])
		for {
			payload, ok := w.reader_next(&rd, context.temp_allocator)
			if !ok {
				break
			}
			o, good := w.parse_obj(payload, context.temp_allocator)
			if !good {
				continue
			}
			if w.ostr(o, "t") == "message" {
				if mo, is := w.as_obj(o["msg"] or_else nil); is {
					if w.ostr(mo, "nick") == args.nick {
						fmt.printfln("posted #%d to %s", w.oint(mo, "id"), args.post_ch)
						return 0
					}
				}
			}
			if w.ostr(o, "t") == "error" {
				fmt.eprintfln("chat: %s: %s", w.ostr(o, "code"), w.ostr(o, "msg"))
				return 1
			}
		}
	}
	return 1
}
