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

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
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
	port := a.args.port
	if a.cloud {
		port = a.args.rtc_port != 0 ? a.args.rtc_port : DEFAULT_RTC_PORT
	}
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
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
	_ = net.set_option(sock, .TCP_Nodelay, true)

	// Cloud mode keeps what it had and asks for what it missed by rev (see
	// cloud_resync, sent once the gateway has said welcome).
	if a.cloud {
		cloud_hello(a)
		return
	}

	// Everything that arrived while the link was down is missing from every
	// channel, so nothing loaded before this connection can be trusted to be
	// complete. Marking the channels unloaded is what makes `switch_to` and
	// `apply_channels` ask again; without it a reconnecting client shows a
	// stale timeline and — now that the server owns the cursor — an unread
	// badge it can never clear, because the messages it would have to display
	// to clear it never arrive.
	for &c in a.chans {
		c.loaded = false
	}
	if cur := current(a); cur != nil {
		req_history(a, cur.name, 0)
		a.want_bottom = true
	}

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

send_post :: proc(a: ^App, ch, text: string, reply_to: i64, thread: i64 = 0) {
	e: w.Enc
	w.enc_begin(&e, "post")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	if reply_to != 0 {
		w.kv_int(&e, "reply_to", reply_to)
	}
	if thread != 0 {
		w.kv_int(&e, "thread", thread)
	}
	net_send(a, w.enc_done(&e))
}

// send_read moves this user's server-side read cursor. It is the only thing
// that makes a message read: nothing is inferred from a connection existing,
// which is exactly why the count survives one going away.
send_read :: proc(a: ^App, ch: string, id: i64) {
	e: w.Enc
	w.enc_begin(&e, "read")
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "id", id)
	net_send(a, w.enc_done(&e))
}

req_thread :: proc(a: ^App, id: i64) {
	e: w.Enc
	w.enc_begin(&e, "thread")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_int(&e, "id", id)
	net_send(a, w.enc_done(&e))
}

// send_attach uploads a file over the same socket as everything else. The
// bytes are base64'd into one frame; the server stores them under a path it
// builds itself and answers with an ordinary message carrying the metadata.
send_attach :: proc(a: ^App, ch, path: string, thread: i64) -> (ok: bool, why: string) {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return false, fmt.tprintf("cannot read %s", path)
	}
	if len(data) == 0 {
		return false, "that file is empty"
	}
	if len(data) > w.MAX_ATTACH {
		return false, fmt.tprintf("%s is larger than the %d KiB limit", pick_name(path), w.MAX_ATTACH / 1024)
	}
	b64, eerr := base64.encode(data, allocator = context.temp_allocator)
	if eerr != nil {
		return false, "could not encode the file"
	}
	e: w.Enc
	w.enc_begin(&e, "attach")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "name", w.safe_filename(pick_name(path), context.temp_allocator))
	w.kv_str(&e, "mime", mime_of(path))
	if thread != 0 {
		w.kv_int(&e, "thread", thread)
	}
	w.kv_str(&e, "data", b64)
	if !net_send(a, w.enc_done(&e)) {
		return false, "not connected"
	}
	return true, ""
}

// send_fetch asks for an attachment's bytes back. `save_to` is where the
// reply will be written, remembered until it arrives.
send_fetch :: proc(a: ^App, id: i64, save_to: string) -> bool {
	rq := next_rq(a)
	e: w.Enc
	w.enc_begin(&e, "fetch")
	w.kv_int(&e, "rq", rq)
	w.kv_int(&e, "id", id)
	if !net_send(a, w.enc_done(&e)) {
		return false
	}
	// Only remember a destination for a request that actually went out, and
	// key it by `rq`, so an unrelated `file` frame cannot be written to it.
	if a.saving != "" {
		delete(a.saving, context.allocator)
	}
	a.saving = strings.clone(save_to, context.allocator)
	a.saving_rq = rq
	return true
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
	if a.cloud && apply_cloud(a, o) {
		return
	}
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
					name = strings.clone(w.ostr(uo, "name")),
					color = strings.clone(w.ostr(uo, "color")),
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
		m := w.msg_from(mo, context.allocator)
		note_rev(a, m.ch, m.rev)
		take_message(a, m)

	case "history":
		apply_history(a, o)

	case "reads":
		apply_reads(a, o)

	case "read":
		if i := find_chan(a, w.ostr(o, "ch")); i >= 0 {
			c := &a.chans[i]
			c.read_id = max(c.read_id, w.oint(o, "id"))
			c.unread = int(w.oint(o, "unread"))
			c.threads = int(w.oint(o, "threads"))
			c.mention = w.obool(o, "mention")
		}

	case "thread":
		apply_thread(a, o)

	case "replies":
		// The count update always follows the reply it counts, inside the one
		// order the server committed, so applying it here can never show a
		// count for a message that has not arrived.
		n := int(w.oint(o, "n"))
		note_rev(a, w.ostr(o, "ch"), w.oint(o, "rev"))
		if m := locate(a, w.ostr(o, "ch"), w.oint(o, "id")); m != nil {
			m.replies = n
			m.last_reply = w.oint(o, "last_reply")
		}
		if a.thread_root == w.oint(o, "id") {
			a.troot.replies = n
			a.troot.last_reply = w.oint(o, "last_reply")
			a.treplies = n
		}

	case "file":
		apply_file(a, o)

	case "edit":
		note_rev(a, w.ostr(o, "ch"), w.oint(o, "rev"))
		if m := locate(a, w.ostr(o, "ch"), w.oint(o, "id")); m != nil {
			m.text = strings.clone(w.ostr(o, "text"))
			m.edited = w.oint(o, "edited")
		}

	case "delete":
		note_rev(a, w.ostr(o, "ch"), w.oint(o, "rev"))
		if m := locate(a, w.ostr(o, "ch"), w.oint(o, "id")); m != nil {
			m.deleted = true
			m.text = ""
			clear(&m.reacts)
		}

	case "react":
		note_rev(a, w.ostr(o, "ch"), w.oint(o, "rev"))
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
		i := find_chan(a, name)
		if i < 0 {
			append(&a.chans, Channel{name = strings.clone(name), msgs = make([dynamic]w.Msg)})
			i = len(a.chans) - 1
			// Joining is what makes a DM visible to the other side, and it
			// is free for an ordinary channel. The gateway needs neither.
			if !a.cloud {
				send_join(a, name, kind == .DM ? "dm" : "channel")
			}
		}
		c := &a.chans[i]
		c.kind = kind
		c.topic = strings.clone(w.ostr(co, "topic"))
		if a.cloud {
			c.label = strings.clone(w.ostr(co, "label"))
			c.space = strings.clone(w.ostr(co, "space"))
			c.private = w.obool(co, "private")
			c.peer = strings.clone(w.ostr(co, "peer"))
			call := w.ostr(co, "call")
			if call == "" {
				c.call = ""
			} else if c.call != call {
				c.call = strings.clone(call)
			}
		}
		if i == a.cur && !c.loaded {
			req_history(a, name, 0)
		}
	}

	// A channel the server no longer lists is one this identity lost access
	// to (removed from the space, left it, a private channel it was taken
	// out of). It goes, with what it held.
	if a.cloud {
		cur_name := a.cur >= 0 && a.cur < len(a.chans) ? strings.clone(a.chans[a.cur].name, context.temp_allocator) : ""
		for i := len(a.chans) - 1; i >= 0; i -= 1 {
			if !seen[a.chans[i].name] {
				w.msgs_destroy(&a.chans[i].msgs)
				ordered_remove(&a.chans, i)
			}
		}
		a.cur = find_chan(a, cur_name)
		if a.cur < 0 {
			if a.cur_space == "" && len(a.chans) > 0 {
				a.cur_space = strings.clone(a.chans[0].space)
			}
			if first := nth_in_view(a, 0); first >= 0 {
				a.cur = first
				req_history(a, a.chans[first].name, 0)
				a.want_bottom = true
			}
		}
	} else if a.cur < 0 && len(a.chans) > 0 {
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

// apply_reads is the whole reconnect story. The server says where each cursor
// is and what is behind it; the client adopts that rather than deciding for
// itself. The one exception is a cursor the user moved while the link was
// down: that is pushed back up, so reading offline is not silently undone.
apply_reads :: proc(a: ^App, o: json.Object) {
	for rv in w.oarr(o, "list") {
		ro, ok := w.as_obj(rv)
		if !ok {
			continue
		}
		i := find_chan(a, w.ostr(ro, "ch"))
		if i < 0 {
			continue
		}
		c := &a.chans[i]
		server_id := w.oint(ro, "id")
		if c.read_id > server_id {
			send_read(a, c.name, c.read_id)
			continue
		}
		c.read_id = server_id
		c.unread = int(w.oint(ro, "unread"))
		c.threads = int(w.oint(ro, "threads"))
		c.mention = w.obool(ro, "mention")
	}
}

apply_thread :: proc(a: ^App, o: json.Object) {
	id := w.oint(o, "id")
	if id != a.thread_root {
		return // a stale answer for a thread the user has already left
	}
	if ro, ok := w.as_obj(o["root"] or_else nil); ok {
		w.msg_destroy(&a.troot)
		a.troot = w.msg_from(ro, context.allocator)
	}
	w.msgs_destroy(&a.tmsgs)
	for mv in w.oarr(o, "msgs") {
		mo, ok := w.as_obj(mv)
		if !ok {
			continue
		}
		append(&a.tmsgs, w.msg_from(mo, context.allocator))
	}
	// The server caps a thread page, so the count it reports is the truth and
	// `len(a.tmsgs)` may be short of it.
	a.treplies = int(w.oint(o, "replies", i64(len(a.tmsgs))))
	a.tmore = w.obool(o, "more")
	a.tloaded = true
}

apply_file :: proc(a: ^App, o: json.Object) {
	name := w.safe_filename(w.ostr(o, "name"), context.temp_allocator)
	if a.saving == "" || w.oint(o, "rq") != a.saving_rq {
		// Either nothing asked for this, or an earlier fetch already claimed
		// the destination. Writing it anyway would put one file's bytes under
		// another file's name.
		toast(a, fmt.tprintf("%s arrived with nowhere to go", name))
		return
	}
	dest := a.saving
	defer delete(dest, context.allocator)
	a.saving = ""
	a.saving_rq = 0
	data, derr := base64.decode(w.ostr(o, "data"), allocator = context.temp_allocator)
	if derr != nil {
		toast(a, "the attachment did not decode")
		return
	}
	if werr := os.write_entire_file(dest, data); werr != nil {
		toast(a, fmt.tprintf("could not write %s", dest))
		return
	}
	toast(a, fmt.tprintf("Saved %s (%d bytes) to %s", name, len(data), dest))
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
		m := w.msg_from(mo, context.allocator)
		c.rev = max(c.rev, m.rev)
		insert_sorted(c, m)
	}
	// History is the user's own doing, so reaching the newest message through
	// it moves the cursor — on the server, which is the only place that counts.
	if len(c.msgs) > 0 && i == a.cur && a.pinned {
		mark_read(a)
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

	// A thread reply is not a row in the channel. It goes to the open thread
	// if that is the one it belongs to, and otherwise only bumps the
	// channel's thread marker; the parent's count arrives separately.
	if m.thread != 0 {
		open := a.thread_root != 0 && m.thread == a.thread_root && i == a.cur
		if open {
			insert_sorted_at(&a.tmsgs, m)
		}
		if m.nick != a.nick && m.id > c.read_id && !open {
			c.threads += 1
		}
		if open && a.pinned {
			// It is on screen, so it is read. Moving the cursor past it is
			// also the only thing that can ever clear this channel's thread
			// marker: the cursor is one number, and `mark_read` otherwise
			// only ever advances it to the newest *timeline* message.
			mark_read(a)
		}
		return
	}

	if msg_at(c, m.id) != nil {
		return
	}
	insert_sorted(c, m)

	if i == a.cur && a.pinned {
		a.new_below = 0
		mark_read(a)
	} else if m.nick != a.nick && m.id > c.read_id {
		c.unread += 1
		if strings.contains(strings.to_lower(m.text, context.temp_allocator), strings.to_lower(a.nick, context.temp_allocator)) {
			c.mention = true
		}
		if i == a.cur {
			a.new_below += 1
		}
	}
}

// insert_sorted_at is insert_sorted for a bare list: the thread view.
insert_sorted_at :: proc(list: ^[dynamic]w.Msg, m: w.Msg) {
	for x, i in list {
		if x.id == m.id {
			return
		}
		if x.id > m.id {
			inject_at(list, i, m)
			return
		}
	}
	append(list, m)
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
	// Fall through rather than return: every broadcast names a channel the
	// client knows, and a thread reply is deliberately *not* in that
	// channel's timeline, so returning `msg_at`'s nil here would make the
	// edit, delete and react handlers silently skip anything shown in the
	// thread panel or in the search results.
	if i := find_chan(a, ch); i >= 0 {
		if m := msg_at(&a.chans[i], id); m != nil {
			return m
		}
	}
	// Search results and the open thread hold their own copies; keep them in
	// step too.
	for &m in a.results {
		if m.id == id {
			return &m
		}
	}
	for &m in a.tmsgs {
		if m.id == id {
			return &m
		}
	}
	if a.troot.id == id {
		return &a.troot
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
	ch := args.post_ch != "" ? args.post_ch : args.att_ch
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = args.port})
	if err != nil {
		fmt.eprintfln("chat: cannot reach 127.0.0.1:%d: %v", args.port, err)
		return 1
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 5 * time.Second)

	e: w.Enc
	w.enc_begin(&e, "hello", context.allocator)
	w.kv_str(&e, "nick", args.nick)
	if !w.send_frame(sock, w.enc_done(&e)) {
		return 1
	}

	j: w.Enc
	w.enc_begin(&j, "join", context.allocator)
	w.kv_str(&j, "ch", ch)
	w.send_frame(sock, w.enc_done(&j))

	m: w.Enc
	if args.att_ch != "" {
		data, rerr := os.read_entire_file_from_path(args.att_path, context.allocator)
		if rerr != nil {
			fmt.eprintfln("chat: cannot read %s: %v", args.att_path, rerr)
			return 1
		}
		if len(data) > w.MAX_ATTACH {
			fmt.eprintfln("chat: %s is larger than the %d byte limit", args.att_path, w.MAX_ATTACH)
			return 1
		}
		b64, eerr := base64.encode(data, allocator = context.allocator)
		if eerr != nil {
			fmt.eprintln("chat: could not encode the file")
			return 1
		}
		w.enc_begin(&m, "attach", context.allocator)
		w.kv_str(&m, "ch", ch)
		w.kv_str(&m, "name", w.safe_filename(pick_name(args.att_path), context.allocator))
		w.kv_str(&m, "mime", mime_of(args.att_path))
		w.kv_str(&m, "text", args.post_txt)
		if args.thread != 0 {
			w.kv_int(&m, "thread", args.thread)
		}
		w.kv_str(&m, "data", b64)
	} else {
		w.enc_begin(&m, "post", context.allocator)
		w.kv_str(&m, "ch", ch)
		w.kv_str(&m, "text", args.post_txt)
		if args.thread != 0 {
			w.kv_int(&m, "thread", args.thread)
		}
	}
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
						fmt.printfln("posted #%d to %s", w.oint(mo, "id"), ch)
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
