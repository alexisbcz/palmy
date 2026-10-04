// palmy-chat server.
//
// A real TCP server on 127.0.0.1: an accept loop on the main thread, one
// reader thread per connection, and one mutex over all shared state.
//
// ---------------------------------------------------------------------------
// Concurrency and locking
// ---------------------------------------------------------------------------
//
// There is exactly one lock, `srv.mu`, and it covers everything shared:
// the connection table, the channel table, the message log, the id counter
// and the presence map.
//
// Procedures come in two tiers and the names say which:
//
//   * `locked_*` — the lock is already held. These never lock, never unlock,
//     and never call anything outside this tier. Every write to a socket
//     happens here.
//   * everything else — runs with the lock NOT held. There are exactly four
//     places that take it: `boot` (startup), the accept loop (appending one
//     connection), `handle` (one message from one client) and `drop_conn` (a
//     connection going away). Each takes it once, at one place, and calls
//     only `locked_*` from inside.
//
// So no path can take the lock twice, because no `locked_*` procedure can
// reach a `sync.lock` call at all. Parsing and allocation happen before the
// lock is taken.
//
// Broadcast runs inside the critical section and writes straight to each
// socket. That is deliberate: the order two clients observe is then the order
// the server committed, with no per-client queue to get out of step. Sends
// carry a 2-second SO_SNDTIMEO so one wedged peer cannot hold the lock
// forever, and a failed send marks the connection dead and shuts its socket
// down, which wakes its own reader thread to do the reaping. Nothing is ever
// retried on a dead socket.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import w "../wire"

Conn :: struct {
	sock:   net.TCP_Socket,
	id:     int,
	nick:   string,
	hello:  bool,
	dead:   bool,
	joined: map[string]bool,
	staged: int, // names this connection's attachment staging files
}

Srv :: struct {
	mu:        sync.Mutex,
	conns:     [dynamic]^Conn,
	next_conn: int,
	chans:     [dynamic]w.Chan,
	msgs:      [dynamic]w.Msg,
	index:     map[i64]int,
	next_id:   i64,
	pres:      map[string]w.Presence,

	// Read cursors, flat-keyed on nick\x00channel. A cursor belongs to a
	// *person*, not to a connection, which is the whole reason it lives here
	// and is written to the log: a client that closes and reopens — or a
	// second client on another seat — must find the same unread count, not
	// zero. Unread itself is never stored; it is derived from the cursor by
	// `locked_unread`, so a count and its cursor cannot drift apart.
	reads:     map[string]i64,

	files:     string, // <dir>/files, the only place an attachment is written
	log:       ^os.File,
	have_log:  bool,
	replaying: bool,
	dir:       string,
	quiet:     bool,
}

srv: Srv

DEFAULT_CHANNELS := [?]struct {
	name, topic: string,
}{
	{"general", "Everything, and most of it off-topic"},
	{"engineering", "Builds, breakages and benchmark numbers"},
	{"design", "Pixels, spacing, and the exact wrong shade of blue"},
	{"random", "No agenda"},
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

main :: proc() {
	port := w.DEFAULT_PORT
	dir := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--port":
			if i + 1 < len(args) {
				i += 1
				if n, ok := strconv.parse_int(args[i]); ok {
					port = n
				}
			}
		case "--dir":
			if i + 1 < len(args) {
				i += 1
				dir = args[i]
			}
		case "--quiet":
			srv.quiet = true
		case "--help", "-h":
			fmt.println("palmy-chat server")
			fmt.println("  --port N    listen port on 127.0.0.1 (default 8787)")
			fmt.println("  --dir PATH  history directory (default ~/.local/share/palmy-chat)")
			fmt.println("  --quiet     no log output")
			os.exit(0)
		case:
			fmt.eprintfln("chat-server: unknown argument %q", args[i])
			os.exit(2)
		}
	}

	if dir == "" {
		dir = default_dir()
	}
	srv.dir = dir
	srv.conns = make([dynamic]^Conn)
	srv.chans = make([dynamic]w.Chan)
	srv.msgs = make([dynamic]w.Msg)
	srv.index = make(map[i64]int)
	srv.pres = make(map[string]w.Presence)
	srv.reads = make(map[string]i64)
	srv.next_id = 1

	boot()

	// Loopback only. Not configurable: this is a local system, and a chat
	// server that quietly listens on 0.0.0.0 is a different, much worse
	// program.
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		fmt.eprintfln("chat-server: cannot listen on 127.0.0.1:%d: %v", port, err)
		os.exit(1)
	}
	note("listening on 127.0.0.1:%d, %d channels, %d messages in %s", port, len(srv.chans), len(srv.msgs), srv.dir)

	for {
		client, source, aerr := net.accept_tcp(sock)
		if aerr != nil {
			if aerr == .Interrupted || aerr == .Aborted || aerr == .Would_Block {
				continue
			}
			fmt.eprintfln("chat-server: accept failed: %v", aerr)
			break
		}
		_ = source

		// A wedged client must not be able to stall a broadcast, which runs
		// under the lock.
		_ = net.set_option(client, .Send_Timeout, 2 * time.Second)

		c := new(Conn)
		c.sock = client
		c.joined = make(map[string]bool)

		sync.lock(&srv.mu)
		srv.next_conn += 1
		c.id = srv.next_conn
		append(&srv.conns, c)
		sync.unlock(&srv.mu)

		thread.create_and_start_with_poly_data(c, conn_thread, self_cleanup = true)
	}
	net.close(sock)
}

note :: proc(format: string, args: ..any) {
	if srv.quiet {
		return
	}
	fmt.printf("chat-server: ")
	fmt.printfln(format, ..args)
}

default_dir :: proc() -> string {
	home, err := os.user_home_dir(context.allocator)
	if err != nil {
		return "/tmp/palmy-chat"
	}
	return strings.concatenate({home, "/.local/share/palmy-chat"})
}

// ---------------------------------------------------------------------------
// The connection thread
// ---------------------------------------------------------------------------

conn_thread :: proc(c: ^Conn) {
	rd: w.Reader
	buf: [16 * 1024]u8
	for {
		n, err := net.recv_tcp(c.sock, buf[:])
		if err == .Interrupted {
			continue
		}
		if err != nil || n == 0 {
			break // reset, closed, or a graceful shutdown
		}
		w.reader_feed(&rd, buf[:n])
		for {
			payload, ok := w.reader_next(&rd, context.temp_allocator)
			if !ok {
				break
			}
			handle(c, payload)
			free_all(context.temp_allocator)
		}
		if rd.bad {
			break
		}
	}
	drop_conn(c)
	delete(rd.buf)
}

// Staged is an attachment that has already been decoded and written to disk,
// before the lock was taken. See `stage_attach`.
Staged :: struct {
	present: bool, // this frame was an `attach` at all
	code:    string, // non-empty when it failed: the error code to answer with
	why:     string,
	size:    int,
	tmp:     string, // the staging path, always inside srv.files
}

// handle parses one frame, then takes the lock exactly once.
handle :: proc(c: ^Conn, payload: string) {
	o, ok := w.parse_obj(payload, context.temp_allocator)

	// An attachment is the one piece of work big enough to matter, so it is
	// done out here with the rest of the parsing: base64-decoded and written
	// to a staging file. The critical section only renames it into place,
	// which is a metadata operation. Without this a 512 KiB upload would hold
	// the one lock across a decode and a disk write, and every other client's
	// broadcast would queue behind it.
	st: Staged
	if ok && w.ostr(o, "t") == "attach" {
		st = stage_attach(c, o)
	}

	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)

	if !ok {
		locked_err(c, 0, "bad_json", "frame was not a JSON object")
		return
	}
	locked_dispatch(c, w.ostr(o, "t"), o, w.oint(o, "rq"), st)
}

// stage_attach runs with the lock NOT held. It reads `srv.files`, which is
// written once in `boot` before any connection thread exists and never again,
// and it writes a file whose name only this connection can produce: `c.id` is
// assigned once under the lock and never reused, and `c.staged` is touched by
// this thread alone.
stage_attach :: proc(c: ^Conn, o: json.Object) -> (st: Staged) {
	st.present = true
	bytes, derr := base64.decode(w.ostr(o, "data"), allocator = context.temp_allocator)
	if derr != nil || len(bytes) == 0 {
		st.code, st.why = "bad_file", "the attachment was not valid base64"
		return
	}
	if len(bytes) > w.MAX_ATTACH {
		st.code = "too_big"
		st.why = fmt.tprintf("an attachment is at most %d bytes", w.MAX_ATTACH)
		return
	}
	c.staged += 1
	st.tmp = strings.concatenate(
		{srv.files, "/", fmt.tprintf(".staging-%d-%d", c.id, c.staged)},
		context.allocator,
	)
	if werr := os.write_entire_file(st.tmp, bytes); werr != nil {
		st.code = "store_failed"
		st.why = fmt.tprintf("could not write the attachment: %v", werr)
		delete(st.tmp)
		st.tmp = ""
		return
	}
	st.size = len(bytes)
	return
}

// drop_conn unregisters a connection and, if it was that nickname's last,
// announces it offline. Lock taken once; `locked_*` only from inside.
drop_conn :: proc(c: ^Conn) {
	sync.lock(&srv.mu)
	c.dead = true
	for cc, i in srv.conns {
		if cc == c {
			ordered_remove(&srv.conns, i)
			break
		}
	}
	if c.hello && c.nick != "" {
		still := false
		for cc in srv.conns {
			if !cc.dead && cc.hello && cc.nick == c.nick {
				still = true
				break
			}
		}
		if !still {
			srv.pres[c.nick] = .Offline
			locked_broadcast_presence(c.nick, .Offline)
		}
		note("%s disconnected (%d connections left)", c.nick, len(srv.conns))
	}
	sync.unlock(&srv.mu)

	net.close(c.sock)
	delete(c.joined)
	free(c)
}

// ---------------------------------------------------------------------------
// Dispatch — everything below this line runs with srv.mu held.
// ---------------------------------------------------------------------------

locked_dispatch :: proc(c: ^Conn, t: string, o: json.Object, rq: i64, st: Staged) {
	if t != "hello" && !c.hello {
		// This is the one path that can reach a staged attachment without
		// `locked_attach` running, so it has to clean up after it.
		if st.tmp != "" {
			_ = os.remove(st.tmp)
			delete(st.tmp)
		}
		locked_err(c, rq, "no_hello", "send hello first")
		return
	}
	switch t {
	case "hello":
		locked_hello(c, o, rq)
	case "channels":
		locked_send(c, locked_channels_frame(c, rq))
	case "join":
		locked_join(c, o, rq)
	case "leave":
		locked_leave(c, o, rq)
	case "post":
		locked_post(c, o, rq)
	case "history":
		locked_history(c, o, rq)
	case "typing":
		locked_typing(c, o)
	case "edit":
		locked_edit(c, o, rq)
	case "delete":
		locked_delete(c, o, rq)
	case "react":
		locked_react(c, o, rq)
	case "presence":
		locked_presence(c, o, rq)
	case "search":
		locked_search(c, o, rq)
	case "read":
		locked_read(c, o, rq)
	case "reads":
		locked_send(c, locked_reads_frame(c, rq))
	case "thread":
		locked_thread(c, o, rq)
	case "attach":
		locked_attach(c, o, rq, st)
	case "fetch":
		locked_fetch(c, o, rq)
	case "ping":
		e: w.Enc
		w.enc_begin(&e, "pong")
		if rq != 0 {
			w.kv_int(&e, "rq", rq)
		}
		locked_send(c, w.enc_done(&e))
	case:
		locked_err(c, rq, "unknown_type", fmt.tprintf("no such message type %q", t))
	}
}

locked_send :: proc(c: ^Conn, payload: string) {
	if c.dead {
		return
	}
	if !w.send_frame(c.sock, payload) {
		c.dead = true
		// Wake its reader thread so the connection is reaped promptly.
		_ = net.shutdown(c.sock, .Both)
	}
}

locked_err :: proc(c: ^Conn, rq: i64, code, msg: string) {
	e: w.Enc
	w.enc_begin(&e, "error")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "code", code)
	w.kv_str(&e, "msg", msg)
	locked_send(c, w.enc_done(&e))
}

// locked_can_see is the whole visibility model: ordinary channels are public,
// a DM is for its two participants.
locked_can_see :: proc(c: ^Conn, ch: string) -> bool {
	k, ok := locked_chan_kind(ch)
	if !ok {
		return false
	}
	if k == .DM {
		return w.dm_has(ch, c.nick)
	}
	return true
}

locked_chan_kind :: proc(ch: string) -> (w.Chan_Kind, bool) {
	for t in srv.chans {
		if t.name == ch {
			return t.kind, true
		}
	}
	return .Channel, false
}

// locked_broadcast sends to every live connection that can see `ch`. An empty
// `ch` means everyone. `except` skips one connection id.
locked_broadcast :: proc(ch: string, payload: string, except := -1) {
	for c in srv.conns {
		if c.dead || !c.hello || c.id == except {
			continue
		}
		if ch != "" && !locked_can_see(c, ch) {
			continue
		}
		locked_send(c, payload)
	}
}

locked_broadcast_presence :: proc(nick: string, state: w.Presence) {
	e: w.Enc
	w.enc_begin(&e, "presence")
	w.kv_str(&e, "nick", nick)
	w.kv_str(&e, "state", w.presence_name(state))
	locked_broadcast("", w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// hello, channels, users
// ---------------------------------------------------------------------------

locked_hello :: proc(c: ^Conn, o: json.Object, rq: i64) {
	if c.hello {
		locked_err(c, rq, "already_hello", "hello was already sent on this connection")
		return
	}
	nick := clean_nick(w.ostr(o, "nick"), context.temp_allocator)
	if nick == "" {
		locked_err(c, rq, "bad_nick", "a nickname of 1-24 printable characters is required")
		return
	}
	c.nick = strings.clone(nick)
	c.hello = true

	state := w.presence_of(w.ostr(o, "presence", "online"))
	if state == .Offline {
		state = .Online
	}
	locked_set_presence(c.nick, state)

	e: w.Enc
	w.enc_begin(&e, "welcome")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_int(&e, "proto", w.PROTO_VERSION)
	w.kv_str(&e, "nick", c.nick)
	w.kv_str(&e, "server", "palmy-chat")
	locked_send(c, w.enc_done(&e))

	locked_send(c, locked_channels_frame(c, 0))
	locked_send(c, locked_users_frame())
	// The reads frame is what makes unread survive a reconnect: it is sent
	// unasked, right after hello, so a client never has a window in which it
	// might decide for itself that everything is read.
	locked_seed_reads(c)
	locked_send(c, locked_reads_frame(c, 0))
	locked_broadcast_presence(c.nick, state)
	note("%s said hello (%d connections)", c.nick, len(srv.conns))
}

// locked_set_presence keeps one owned copy of each nickname as the map key.
locked_set_presence :: proc(nick: string, state: w.Presence) {
	if _, found := srv.pres[nick]; found {
		srv.pres[nick] = state
		return
	}
	srv.pres[strings.clone(nick)] = state
}

locked_channels_frame :: proc(c: ^Conn, rq: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for t in srv.chans {
		if t.kind == .DM && !w.dm_has(t.name, c.nick) {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, "{\"name\":")
		w.write_json_string(&b, t.name)
		strings.write_string(&b, ",\"kind\":")
		w.write_json_string(&b, t.kind == .DM ? "dm" : "channel")
		strings.write_string(&b, ",\"topic\":")
		w.write_json_string(&b, t.topic)
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')

	e: w.Enc
	w.enc_begin(&e, "channels")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_raw(&e, "list", strings.to_string(b))
	return w.enc_done(&e)
}

locked_users_frame :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for nick, state in srv.pres {
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, "{\"nick\":")
		w.write_json_string(&b, nick)
		strings.write_string(&b, ",\"state\":")
		w.write_json_string(&b, w.presence_name(state))
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')

	e: w.Enc
	w.enc_begin(&e, "users")
	w.kv_raw(&e, "list", strings.to_string(b))
	return w.enc_done(&e)
}

locked_push_channels :: proc() {
	for c in srv.conns {
		if c.dead || !c.hello {
			continue
		}
		locked_send(c, locked_channels_frame(c, 0))
	}
}

// ---------------------------------------------------------------------------
// join / leave
// ---------------------------------------------------------------------------

locked_join :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := strings.trim_space(w.ostr(o, "ch"))
	if ch == "" || len(ch) > 64 {
		locked_err(c, rq, "bad_channel", "channel names are 1-64 characters")
		return
	}
	is_dm := strings.index_byte(ch, '+') >= 0
	if is_dm && !w.dm_has(ch, c.nick) {
		locked_err(c, rq, "not_yours", "a DM channel must include your own nickname")
		return
	}

	created := false
	if _, found := locked_chan_kind(ch); !found {
		t := w.Chan {
			name  = strings.clone(ch),
			kind  = is_dm ? w.Chan_Kind.DM : w.Chan_Kind.Channel,
			topic = strings.clone(w.ostr(o, "topic")),
		}
		append(&srv.chans, t)
		log_chan(t)
		created = true
	}

	if _, found := c.joined[ch]; !found {
		c.joined[strings.clone(ch)] = true
	}

	e: w.Enc
	w.enc_begin(&e, "joined")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "ch", ch)
	locked_send(c, w.enc_done(&e))

	if created {
		locked_push_channels()
	}
}

locked_leave :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	delete_key(&c.joined, ch)
	e: w.Enc
	w.enc_begin(&e, "left")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "ch", ch)
	locked_send(c, w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// post / history / search
// ---------------------------------------------------------------------------

MAX_TEXT :: 4000

// A thread page, chosen so root + replies cannot approach MAX_FRAME: 120
// replies at MAX_TEXT is under half of it.
THREAD_PAGE :: 120

locked_post :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	text := w.ostr(o, "text")
	if !locked_can_see(c, ch) {
		locked_err(c, rq, "no_channel", fmt.tprintf("no channel %q", ch))
		return
	}
	if strings.trim_space(text) == "" {
		locked_err(c, rq, "empty", "a message needs some text")
		return
	}
	if len(text) > MAX_TEXT {
		locked_err(c, rq, "too_long", fmt.tprintf("a message is at most %d bytes", MAX_TEXT))
		return
	}

	// A `thread` is a root message id. It is normalised first, so "reply to a
	// reply" lands in the one thread rather than nesting, and it must name a
	// root in the same channel — otherwise a thread reply would be visible to
	// an audience its root is not.
	thread := w.oint(o, "thread")
	if thread != 0 {
		thread = locked_thread_root(thread)
		root := locked_find(thread)
		if root == nil {
			locked_err(c, rq, "no_thread", "no such thread")
			return
		}
		if root.ch != ch {
			locked_err(c, rq, "no_thread", "that thread belongs to another channel")
			return
		}
	}

	locked_commit(c, ch, text, w.oint(o, "reply_to"), thread, w.ostr(o, "tag"), {})
}

// locked_commit is the one place a message is created, and the reason the
// ordering guarantee holds. Inside the single critical section it: assigns the
// next id, appends, writes the log, broadcasts the message, and — for a thread
// reply — updates the root's reply count and broadcasts *that*, in that order.
// So every client sees the same sequence the server committed, and none can
// ever see a reply count before the reply it counts.
locked_commit :: proc(
	c: ^Conn,
	ch, text: string,
	reply_to, thread: i64,
	tag: string,
	file: w.Attach,
) -> i64 {
	m := w.Msg {
		id       = srv.next_id,
		ch       = strings.clone(ch),
		nick     = strings.clone(c.nick),
		text     = strings.clone(text),
		ts       = w.now_unix(),
		reply_to = reply_to,
		thread   = thread,
		file     = file,
		reacts   = make([dynamic]w.React),
	}
	if m.reply_to != 0 {
		// A quoted stub must name something the same audience can see, so the
		// target has to be in this channel. Anything else is dropped rather
		// than refused: a stale quote is not worth failing a message over.
		src := locked_find(m.reply_to)
		if src == nil || src.ch != ch {
			m.reply_to = 0
		}
	}
	srv.next_id += 1
	srv.index[m.id] = len(srv.msgs)
	append(&srv.msgs, m)
	log_msg(m)

	e: w.Enc
	w.enc_begin(&e, "message")
	w.kv_raw(&e, "msg", w.msg_json(m))
	if tag != "" {
		w.kv_str(&e, "tag", tag)
	}
	locked_broadcast(ch, w.enc_done(&e))

	// The root pointer has to be taken *after* the append: growing srv.msgs
	// reallocates it, and a pointer captured before would dangle.
	if thread != 0 {
		if root := locked_find(thread); root != nil {
			root.replies += 1
			root.last_reply = m.ts
			r: w.Enc
			w.enc_begin(&r, "replies")
			w.kv_int(&r, "id", root.id)
			w.kv_str(&r, "ch", root.ch)
			w.kv_int(&r, "n", i64(root.replies))
			w.kv_int(&r, "last_reply", root.last_reply)
			w.kv_str(&r, "nick", m.nick)
			locked_broadcast(ch, w.enc_done(&r))
		}
	}
	return m.id
}

// locked_thread_root normalises a requested root. Threads are exactly one
// level deep, so asking to reply inside a reply means replying inside its own
// root. Returns 0 when there is no such message.
locked_thread_root :: proc(id: i64) -> i64 {
	// One hop is all a well-formed store ever needs, because `locked_commit`
	// normalises before it writes. The budget is there so a hand-edited or
	// corrupted log cannot turn this into an unbounded walk.
	at := id
	for _ in 0 ..< 8 {
		m := locked_find(at)
		if m == nil {
			return 0
		}
		if m.thread == 0 {
			return m.id
		}
		at = m.thread
	}
	return 0
}

// locked_thread answers with the root and every reply inside it, oldest first.
// `id` may name the root or any reply in it.
locked_thread :: proc(c: ^Conn, o: json.Object, rq: i64) {
	rid := locked_thread_root(w.oint(o, "id"))
	root := locked_find(rid)
	if root == nil {
		locked_err(c, rq, "no_message", "no such message")
		return
	}
	if !locked_can_see(c, root.ch) {
		locked_err(c, rq, "no_channel", "that thread is not visible to you")
		return
	}
	ch := strings.clone(root.ch, context.temp_allocator)
	rootj := w.msg_json(root^)

	// Capped, like history and search. A frame larger than MAX_FRAME cannot be
	// sent, and `locked_send` reaps the connection when a send fails — so an
	// uncapped thread would mean "opening a busy thread disconnects you".
	limit := int(w.oint(o, "limit", THREAD_PAGE))
	limit = clamp(limit, 1, THREAD_PAGE)
	total := 0
	for m in srv.msgs {
		if m.thread == rid {
			total += 1
		}
	}
	skip := max(0, total - limit) // keep the newest `limit` replies

	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	n, seen := 0, 0
	for m in srv.msgs {
		if m.thread != rid {
			continue
		}
		seen += 1
		if seen <= skip {
			continue
		}
		if n > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, w.msg_json(m))
		n += 1
	}
	strings.write_byte(&b, ']')

	e: w.Enc
	w.enc_begin(&e, "thread")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_int(&e, "id", rid)
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "replies", i64(total))
	w.kv_bool(&e, "more", skip > 0)
	w.kv_raw(&e, "root", rootj)
	w.kv_raw(&e, "msgs", strings.to_string(b))
	locked_send(c, w.enc_done(&e))
}

locked_history :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !locked_can_see(c, ch) {
		locked_err(c, rq, "no_channel", fmt.tprintf("no channel %q", ch))
		return
	}
	before := w.oint(o, "before")
	limit := int(w.oint(o, "limit", 50))
	limit = clamp(limit, 1, 200)

	// Walk backwards collecting matches, then emit oldest first.
	picked := make([dynamic]int, context.temp_allocator)
	older := false
	for i := len(srv.msgs) - 1; i >= 0; i -= 1 {
		m := srv.msgs[i]
		if m.ch != ch {
			continue
		}
		// A thread reply is not in the channel timeline. That is what makes a
		// thread a thread rather than a decorated reply: it is reachable only
		// through its root, which carries the count.
		if m.thread != 0 {
			continue
		}
		if before != 0 && m.id >= before {
			continue
		}
		if len(picked) >= limit {
			older = true
			break
		}
		append(&picked, i)
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for k := len(picked) - 1; k >= 0; k -= 1 {
		if k != len(picked) - 1 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, w.msg_json(srv.msgs[picked[k]]))
	}
	strings.write_byte(&b, ']')

	e: w.Enc
	w.enc_begin(&e, "history")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "ch", ch)
	w.kv_bool(&e, "more", older)
	w.kv_raw(&e, "msgs", strings.to_string(b))
	locked_send(c, w.enc_done(&e))
}

locked_search :: proc(c: ^Conn, o: json.Object, rq: i64) {
	q := strings.to_lower(strings.trim_space(w.ostr(o, "q")), context.temp_allocator)
	limit := int(w.oint(o, "limit", 40))
	limit = clamp(limit, 1, 200)

	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	n := 0
	if q != "" {
		for i := len(srv.msgs) - 1; i >= 0 && n < limit; i -= 1 {
			m := srv.msgs[i]
			if m.deleted || !locked_can_see(c, m.ch) {
				continue
			}
			low := strings.to_lower(m.text, context.temp_allocator)
			if !strings.contains(low, q) && !strings.contains(strings.to_lower(m.nick, context.temp_allocator), q) {
				continue
			}
			if n > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, w.msg_json(m))
			n += 1
		}
	}
	strings.write_byte(&b, ']')

	e: w.Enc
	w.enc_begin(&e, "results")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "q", w.ostr(o, "q"))
	w.kv_raw(&e, "msgs", strings.to_string(b))
	locked_send(c, w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// typing / edit / delete / react / presence
// ---------------------------------------------------------------------------

locked_typing :: proc(c: ^Conn, o: json.Object) {
	ch := w.ostr(o, "ch")
	if !locked_can_see(c, ch) {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "typing")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "nick", c.nick)
	w.kv_bool(&e, "on", w.obool(o, "on", true))
	locked_broadcast(ch, w.enc_done(&e), c.id)
}

locked_find :: proc(id: i64) -> ^w.Msg {
	if i, found := srv.index[id]; found {
		return &srv.msgs[i]
	}
	return nil
}

locked_edit :: proc(c: ^Conn, o: json.Object, rq: i64) {
	id := w.oint(o, "id")
	text := w.ostr(o, "text")
	m := locked_find(id)
	if m == nil {
		locked_err(c, rq, "no_message", "no such message")
		return
	}
	if m.nick != c.nick {
		locked_err(c, rq, "not_yours", "only the author can edit a message")
		return
	}
	if m.deleted {
		locked_err(c, rq, "deleted", "that message was deleted")
		return
	}
	if strings.trim_space(text) == "" || len(text) > MAX_TEXT {
		locked_err(c, rq, "empty", "an edit needs some text")
		return
	}
	m.text = strings.clone(text)
	m.edited = w.now_unix()
	log_edit(m.id, m.text, m.edited)

	e: w.Enc
	w.enc_begin(&e, "edit")
	w.kv_int(&e, "id", m.id)
	w.kv_str(&e, "ch", m.ch)
	w.kv_str(&e, "text", m.text)
	w.kv_int(&e, "edited", m.edited)
	locked_broadcast(m.ch, w.enc_done(&e))
}

locked_delete :: proc(c: ^Conn, o: json.Object, rq: i64) {
	id := w.oint(o, "id")
	m := locked_find(id)
	if m == nil {
		locked_err(c, rq, "no_message", "no such message")
		return
	}
	if m.nick != c.nick {
		locked_err(c, rq, "not_yours", "only the author can delete a message")
		return
	}
	if m.deleted {
		return
	}
	m.deleted = true
	m.text = ""
	clear(&m.reacts)
	log_delete(m.id)

	e: w.Enc
	w.enc_begin(&e, "delete")
	w.kv_int(&e, "id", m.id)
	w.kv_str(&e, "ch", m.ch)
	locked_broadcast(m.ch, w.enc_done(&e))
}

locked_react :: proc(c: ^Conn, o: json.Object, rq: i64) {
	id := w.oint(o, "id")
	key := w.ostr(o, "key")
	on := w.obool(o, "on", true)
	if !w.reaction_valid(key) {
		locked_err(c, rq, "bad_reaction", fmt.tprintf("no such reaction %q", key))
		return
	}
	m := locked_find(id)
	if m == nil || m.deleted {
		locked_err(c, rq, "no_message", "no such message")
		return
	}
	changed := on ? w.react_add(m, key, c.nick) : w.react_remove(m, key, c.nick)
	if !changed {
		return
	}
	log_react(m.id, key, c.nick, on)

	e: w.Enc
	w.enc_begin(&e, "react")
	w.kv_int(&e, "id", m.id)
	w.kv_str(&e, "ch", m.ch)
	w.kv_str(&e, "key", key)
	w.kv_str(&e, "nick", c.nick)
	w.kv_bool(&e, "on", on)
	locked_broadcast(m.ch, w.enc_done(&e))
}

locked_presence :: proc(c: ^Conn, o: json.Object, rq: i64) {
	state := w.presence_of(w.ostr(o, "state"))
	if state == .Offline {
		locked_err(c, rq, "bad_state", "a connected client is online or away")
		return
	}
	locked_set_presence(c.nick, state)
	locked_broadcast_presence(c.nick, state)
}


// ---------------------------------------------------------------------------
// Read cursors and unread
//
// A read cursor is "the highest message id this *person* has told the server
// they have read, in this channel". It is keyed on the nickname rather than
// the connection, it is written to the log, and it is replayed at startup, so
// it follows the user between clients and across restarts.
//
// Unread is never stored. Every answer is derived from the cursor by walking
// the log, which is why a count and its cursor can never disagree: there is
// only one number, and the other is computed from it.
// ---------------------------------------------------------------------------

// read_key flattens (nick, channel) into one map key. A NUL separator cannot
// occur in either half — `clean_nick` strips control bytes and a channel name
// comes from the same JSON — so the key is unambiguous.
read_key :: proc(nick, ch: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({nick, "\x00", ch}, allocator)
}

locked_read_get :: proc(nick, ch: string) -> i64 {
	return srv.reads[read_key(nick, ch)] or_else 0
}

// locked_read_set moves a cursor forward only. A client that re-announces a
// stale position — an old tab, a replayed frame — must not resurrect messages
// the user has already read somewhere else.
locked_read_set :: proc(nick, ch: string, id: i64) -> bool {
	k := read_key(nick, ch)
	if cur, found := srv.reads[k]; found {
		if cur >= id {
			return false
		}
		srv.reads[k] = id
		return true
	}
	srv.reads[strings.clone(k)] = id
	return true
}

// locked_read_known says whether this nickname has ever had a cursor stored,
// which is how a first-ever hello is told apart from a reconnect.
locked_read_known :: proc(nick: string) -> bool {
	for t in srv.chans {
		if _, found := srv.reads[read_key(nick, t.name)]; found {
			return true
		}
	}
	return false
}

// locked_unread derives the three numbers a sidebar needs. A message counts as
// unread when it is newer than the cursor, not deleted, and not the reader's
// own. Thread replies are counted separately: they are not in the channel
// timeline, so putting them in the channel badge would promise a row that is
// not there.
locked_unread :: proc(nick, ch: string) -> (unread: int, mention: bool, threads: int) {
	cur := locked_read_get(nick, ch)
	me := strings.to_lower(nick, context.temp_allocator)
	for m in srv.msgs {
		if m.id <= cur || m.ch != ch || m.deleted || m.nick == nick {
			continue
		}
		if m.thread != 0 {
			threads += 1
			continue
		}
		unread += 1
		if strings.contains(strings.to_lower(m.text, context.temp_allocator), me) {
			mention = true
		}
	}
	return
}

// locked_seed_reads parks a nickname the server has never seen at the newest
// message of every channel it can see. Without it a brand-new client would
// open onto the entire history marked unread, which is not what "you have
// just arrived" means. It happens exactly once per nickname, and it is logged,
// so a reconnect is never mistaken for a first arrival.
locked_seed_reads :: proc(c: ^Conn) {
	if locked_read_known(c.nick) {
		return
	}
	for t in srv.chans {
		if t.kind == .DM && !w.dm_has(t.name, c.nick) {
			continue
		}
		newest: i64 = 0
		for m in srv.msgs {
			if m.ch == t.name && m.id > newest {
				newest = m.id
			}
		}
		if locked_read_set(c.nick, t.name, newest) {
			log_read(c.nick, t.name, newest)
		}
	}
}

locked_reads_frame :: proc(c: ^Conn, rq: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for t in srv.chans {
		if t.kind == .DM && !w.dm_has(t.name, c.nick) {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		unread, mention, threads := locked_unread(c.nick, t.name)
		strings.write_string(&b, "{\"ch\":")
		w.write_json_string(&b, t.name)
		fmt.sbprintf(
			&b,
			",\"id\":%d,\"unread\":%d,\"threads\":%d,\"mention\":%s}",
			locked_read_get(c.nick, t.name),
			unread,
			threads,
			mention ? "true" : "false",
		)
	}
	strings.write_byte(&b, ']')

	e: w.Enc
	w.enc_begin(&e, "reads")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_raw(&e, "list", strings.to_string(b))
	return w.enc_done(&e)
}

locked_read :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !locked_can_see(c, ch) {
		locked_err(c, rq, "no_channel", fmt.tprintf("no channel %q", ch))
		return
	}
	// Clamp to something that exists. The cursor is forward-only and
	// persisted, so one frame claiming `id: 2^63-1` would otherwise mark the
	// channel read for that nickname for ever, including every message not
	// yet written, with no way back.
	want := w.oint(o, "id")
	newest: i64 = 0
	for m in srv.msgs {
		if m.ch == ch && m.id > newest {
			newest = m.id
		}
	}
	if want > newest {
		want = newest
	}
	if locked_read_set(c.nick, ch, want) {
		log_read(c.nick, ch, locked_read_get(c.nick, ch))
	}
	locked_read_echo(c.nick, ch, rq, c.id)
}

// locked_read_echo tells every connection of this nickname where the cursor
// now is and what is still unread behind it — including the one that asked,
// so a client never has to compute the count itself, and a second client of
// the same person stops showing a badge for something read elsewhere.
locked_read_echo :: proc(nick, ch: string, rq: i64, asker: int) {
	unread, mention, threads := locked_unread(nick, ch)
	cur := locked_read_get(nick, ch)
	for cc in srv.conns {
		if cc.dead || !cc.hello || cc.nick != nick {
			continue
		}
		e: w.Enc
		w.enc_begin(&e, "read")
		if rq != 0 && cc.id == asker {
			w.kv_int(&e, "rq", rq)
		}
		w.kv_str(&e, "ch", ch)
		w.kv_int(&e, "id", cur)
		w.kv_int(&e, "unread", i64(unread))
		w.kv_int(&e, "threads", i64(threads))
		w.kv_bool(&e, "mention", mention)
		locked_send(cc, w.enc_done(&e))
	}
}

// ---------------------------------------------------------------------------
// Attachments
//
// The bytes travel base64'd inside one JSON frame, are written to a path the
// server builds itself, and come back only by id. A client never names a path
// and never sees one.
// ---------------------------------------------------------------------------

locked_attach :: proc(c: ^Conn, o: json.Object, rq: i64, st: Staged) {
	// Whatever happens, the staging file does not survive this call unless it
	// is renamed into place.
	keep := false
	defer if !keep && st.tmp != "" {
		_ = os.remove(st.tmp)
		delete(st.tmp)
	}

	if !st.present {
		locked_err(c, rq, "bad_file", "that frame carried no attachment")
		return
	}
	if st.code != "" {
		locked_err(c, rq, st.code, st.why)
		return
	}

	ch := w.ostr(o, "ch")
	if !locked_can_see(c, ch) {
		locked_err(c, rq, "no_channel", fmt.tprintf("no channel %q", ch))
		return
	}

	thread := w.oint(o, "thread")
	if thread != 0 {
		thread = locked_thread_root(thread)
		root := locked_find(thread)
		if root == nil || root.ch != ch {
			locked_err(c, rq, "no_thread", "no such thread in this channel")
			return
		}
	}

	// The stored name is built, never accepted: an id the server assigned, a
	// dash, and `safe_filename`'s closed character set. There is no input
	// through which a separator, a "..", or a leading dot can reach the path.
	id := srv.next_id
	base := w.safe_filename(w.ostr(o, "name"), context.temp_allocator)
	stored := fmt.tprintf("%d-%s", id, base)
	path := strings.concatenate({srv.files, "/", stored}, context.temp_allocator)
	if !safe_component(stored) {
		locked_err(c, rq, "bad_file", "that name cannot be stored")
		return
	}
	if rerr := os.rename(st.tmp, path); rerr != nil {
		locked_err(c, rq, "store_failed", fmt.tprintf("could not store the attachment: %v", rerr))
		return
	}
	keep = true
	delete(st.tmp)

	att := w.Attach {
		id   = id,
		name = strings.clone(base),
		mime = strings.clone(clean_mime(w.ostr(o, "mime", "application/octet-stream"))),
		size = st.size,
	}
	committed := locked_commit(c, ch, trim_text(w.ostr(o, "text")), 0, thread, w.ostr(o, "tag"), att)
	if committed != id {
		// Cannot happen: `srv.next_id` was read and committed inside this one
		// critical section, and `locked_commit` is the only thing that assigns
		// an id. Noted rather than ignored, because if it ever did happen the
		// attachment id and its message id would part company silently.
		note("attachment id drift: predicted %d, committed %d", id, committed)
	}
	note("%s attached %s (%d bytes) as #%d", c.nick, stored, st.size, committed)
}

// trim_text cuts an over-long caption on a rune boundary. Cutting on a byte
// boundary would ship a half-encoded rune inside a JSON string, which is not
// valid UTF-8 and is a far worse failure than a slightly shorter caption.
trim_text :: proc(text: string) -> string {
	if len(text) <= MAX_TEXT {
		return text
	}
	n := MAX_TEXT
	for n > 0 && text[n] & 0xc0 == 0x80 {
		n -= 1
	}
	return text[:n]
}

// clean_mime bounds the one string a client sends that nothing else caps. It
// is persisted and re-emitted inside every history frame, so an unbounded one
// would eventually push a channel's history past MAX_FRAME and disconnect
// anyone who opened it — permanently, since the log replays.
MAX_MIME :: 127

clean_mime :: proc(raw: string) -> string {
	s := strings.trim_space(raw)
	if s == "" {
		return "application/octet-stream"
	}
	if len(s) > MAX_MIME {
		s = s[:MAX_MIME]
	}
	for i in 0 ..< len(s) {
		if s[i] < 0x20 || s[i] >= 0x7f {
			return "application/octet-stream"
		}
	}
	return s
}

// locked_fetch hands an attachment back. The id is a message id; the path is
// rebuilt from the stored record, so the only files reachable are ones this
// server wrote.
locked_fetch :: proc(c: ^Conn, o: json.Object, rq: i64) {
	// The id is an *attachment* id. It equals the id of the message carrying
	// it, but looking it up by the attachment field rather than by the message
	// index means the two cannot drift apart: a fetch finds a file or it finds
	// nothing, never somebody else's message.
	id := w.oint(o, "id")
	m: ^w.Msg
	for &x in srv.msgs {
		if x.file.id == id && id != 0 {
			m = &x
			break
		}
	}
	if m == nil {
		locked_err(c, rq, "no_file", "no attachment with that id")
		return
	}
	if !locked_can_see(c, m.ch) {
		locked_err(c, rq, "no_channel", "that attachment is not visible to you")
		return
	}
	path := strings.concatenate(
		{srv.files, "/", fmt.tprintf("%d-%s", m.file.id, m.file.name)},
		context.temp_allocator,
	)
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		locked_err(c, rq, "no_file", "the attachment is no longer in the store")
		return
	}
	// Reading and encoding happen under the lock. Unlike the upload path this
	// one cannot be staged in advance — the path is only known once the
	// message has been found — but it is bounded by MAX_ATTACH, it is CPU and
	// page cache rather than a blocking write, and it is a direct reply, so
	// moving it out would mean writing to a socket outside the locked tier.
	b64, eerr := base64.encode(data, allocator = context.temp_allocator)
	if eerr != nil {
		locked_err(c, rq, "no_file", "the attachment could not be encoded")
		return
	}

	e: w.Enc
	w.enc_begin(&e, "file")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_int(&e, "id", m.file.id)
	w.kv_str(&e, "name", m.file.name)
	w.kv_str(&e, "mime", m.file.mime)
	w.kv_int(&e, "size", i64(len(data)))
	w.kv_str(&e, "data", b64)
	locked_send(c, w.enc_done(&e))
}

// safe_component is the belt to safe_filename's braces. It checks the one
// piece a client influenced — the single path component the server built from
// its name — rather than the whole path: the server's own `--dir` may
// perfectly well contain a ".." (`/tmp/../tmp/store` is a real directory), and
// a legal filename may contain a doubled dot (`report..final.pdf`). Testing
// the whole path for ".." rejects both, which is a bug in each direction.
safe_component :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	if strings.contains(name, "/") || strings.contains(name, "\\") {
		return false
	}
	// A doubled dot *inside* a component is not a traversal — `..` only means
	// "parent" when it is the whole component — and `report..final.txt` is a
	// name a person really types. Rejecting it was a bug in the other
	// direction, so the test above is the whole check.
	return true
}

// ---------------------------------------------------------------------------
// Persistence
//
// One append-only JSONL event log. Replay applies the same transitions the
// live handlers do, so a restarted server is in exactly the state it was in.
// ---------------------------------------------------------------------------

// boot opens the store, replays it and seeds the default channels. It takes
// the lock once, like every other non-`locked_*` entry point, even though no
// connection thread exists yet: one discipline, no exceptions.
boot :: proc() {
	if err := os.make_directory_all(srv.dir); err != nil && !os.exists(srv.dir) {
		fmt.eprintfln("chat-server: cannot create %s: %v", srv.dir, err)
		os.exit(1)
	}
	srv.files = strings.concatenate({srv.dir, "/files"})
	if err := os.make_directory_all(srv.files); err != nil && !os.exists(srv.files) {
		fmt.eprintfln("chat-server: cannot create %s: %v", srv.files, err)
		os.exit(1)
	}
	path := strings.concatenate({srv.dir, "/log.jsonl"})

	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)

	locked_replay(path)

	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err != nil {
		fmt.eprintfln("chat-server: cannot append to %s: %v", path, err)
		os.exit(1)
	}
	srv.log = f
	srv.have_log = true

	locked_sweep_staging()
	locked_seed()
}

locked_replay :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return
	}
	srv.replaying = true
	defer srv.replaying = false

	it := string(data)
	lines, events := 0, 0
	for line in strings.split_lines_iterator(&it) {
		if strings.trim_space(line) == "" {
			continue
		}
		lines += 1
		o, ok := w.parse_obj(line, context.temp_allocator)
		if ok && locked_apply_event(o) {
			events += 1
		}
		free_all(context.temp_allocator)
	}
	locked_recount_threads()
	note("replayed %d/%d events from %s", events, lines, path)
}

// locked_recount_threads rebuilds every root's reply count from the messages
// themselves. The counts are derived, not logged: one fewer thing the log can
// be inconsistent about, and a replayed server agrees with a live one by
// construction.
locked_recount_threads :: proc() {
	for &m in srv.msgs {
		m.replies = 0
		m.last_reply = 0
	}
	for m in srv.msgs {
		if m.thread == 0 {
			continue
		}
		if r := locked_find(m.thread); r != nil {
			r.replies += 1
			if m.ts > r.last_reply {
				r.last_reply = m.ts
			}
		}
	}
}

locked_apply_event :: proc(o: json.Object) -> bool {
	switch w.ostr(o, "e") {
	case "chan":
		name := w.ostr(o, "name")
		if name == "" {
			return false
		}
		if _, found := locked_chan_kind(name); found {
			return true
		}
		append(
			&srv.chans,
			w.Chan {
				name = strings.clone(name),
				kind = w.ostr(o, "kind") == "dm" ? w.Chan_Kind.DM : w.Chan_Kind.Channel,
				topic = strings.clone(w.ostr(o, "topic")),
			},
		)
		return true

	case "msg":
		m := w.msg_from(o, context.allocator)
		if m.id == 0 {
			return false
		}
		if _, found := srv.index[m.id]; found {
			return false
		}
		srv.index[m.id] = len(srv.msgs)
		append(&srv.msgs, m)
		if m.id >= srv.next_id {
			srv.next_id = m.id + 1
		}
		return true

	case "edit":
		m := locked_find(w.oint(o, "id"))
		if m == nil {
			return false
		}
		m.text = strings.clone(w.ostr(o, "text"))
		m.edited = w.oint(o, "at")
		return true

	case "del":
		m := locked_find(w.oint(o, "id"))
		if m == nil {
			return false
		}
		m.deleted = true
		m.text = ""
		clear(&m.reacts)
		return true

	case "read":
		nick, ch := w.ostr(o, "nick"), w.ostr(o, "ch")
		if nick == "" || ch == "" {
			return false
		}
		k := read_key(nick, ch)
		if _, found := srv.reads[k]; found {
			srv.reads[k] = w.oint(o, "id")
		} else {
			srv.reads[strings.clone(k)] = w.oint(o, "id")
		}
		return true

	case "react":
		m := locked_find(w.oint(o, "id"))
		if m == nil {
			return false
		}
		key, nick := w.ostr(o, "key"), w.ostr(o, "nick")
		if w.obool(o, "on") {
			w.react_add(m, key, nick)
		} else {
			w.react_remove(m, key, nick)
		}
		return true
	}
	return false
}

log_line :: proc(line: string) {
	if !srv.have_log || srv.replaying {
		return
	}
	os.write_string(srv.log, line)
	os.write_string(srv.log, "\n")
	os.flush(srv.log)
}

log_chan :: proc(t: w.Chan) {
	e: w.Enc
	w.enc_open(&e)
	w.kv_str(&e, "e", "chan")
	w.kv_str(&e, "name", t.name)
	w.kv_str(&e, "kind", t.kind == .DM ? "dm" : "channel")
	w.kv_str(&e, "topic", t.topic)
	log_line(w.enc_done(&e))
}

log_msg :: proc(m: w.Msg) {
	// `msg_json` always emits "id" first, so splicing the event tag in front
	// of its body keeps one encoder for the wire and the log.
	body := w.msg_json(m)
	log_line(strings.concatenate({"{\"e\":\"msg\",", body[1:]}, context.temp_allocator))
}

log_edit :: proc(id: i64, text: string, at: i64) {
	e: w.Enc
	w.enc_open(&e)
	w.kv_str(&e, "e", "edit")
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "text", text)
	w.kv_int(&e, "at", at)
	log_line(w.enc_done(&e))
}

log_delete :: proc(id: i64) {
	e: w.Enc
	w.enc_open(&e)
	w.kv_str(&e, "e", "del")
	w.kv_int(&e, "id", id)
	log_line(w.enc_done(&e))
}

// log_read records a cursor move. Replay sets rather than maxes, because the
// last line for a (nick, channel) pair is by definition the newest cursor.
log_read :: proc(nick, ch: string, id: i64) {
	e: w.Enc
	w.enc_open(&e)
	w.kv_str(&e, "e", "read")
	w.kv_str(&e, "nick", nick)
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "id", id)
	log_line(w.enc_done(&e))
}

log_react :: proc(id: i64, key, nick: string, on: bool) {
	e: w.Enc
	w.enc_open(&e)
	w.kv_str(&e, "e", "react")
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "key", key)
	w.kv_str(&e, "nick", nick)
	w.kv_bool(&e, "on", on)
	log_line(w.enc_done(&e))
}

// locked_sweep_staging removes attachment staging files left behind by a
// server that was killed mid-upload. They are hidden, they are never
// referenced by a message, and leaving them would be a slow leak on disk.
locked_sweep_staging :: proc() {
	d, derr := os.open(srv.files)
	if derr != nil {
		return
	}
	defer os.close(d)
	names, nerr := os.read_dir(d, -1, context.temp_allocator)
	if nerr != nil {
		return
	}
	n := 0
	for f in names {
		if !strings.has_prefix(f.name, ".staging-") {
			continue
		}
		if os.remove(strings.concatenate({srv.files, "/", f.name}, context.temp_allocator)) == nil {
			n += 1
		}
	}
	if n > 0 {
		note("swept %d abandoned attachment staging files", n)
	}
}

// locked_seed creates the default channels the first time a store is used.
locked_seed :: proc() {
	if len(srv.chans) > 0 {
		return
	}
	for d in DEFAULT_CHANNELS {
		t := w.Chan {
			name  = strings.clone(d.name),
			kind  = .Channel,
			topic = strings.clone(d.topic),
		}
		append(&srv.chans, t)
		log_chan(t)
	}
}

clean_nick :: proc(raw: string, allocator := context.allocator) -> string {
	s := strings.trim_space(raw)
	if s == "" || len(s) > 24 {
		return ""
	}
	b := strings.builder_make(allocator)
	for r in s {
		if r == '+' || r < 0x20 {
			continue
		}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}
