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

// handle parses one frame, then takes the lock exactly once.
handle :: proc(c: ^Conn, payload: string) {
	o, ok := w.parse_obj(payload, context.temp_allocator)

	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)

	if !ok {
		locked_err(c, 0, "bad_json", "frame was not a JSON object")
		return
	}
	locked_dispatch(c, w.ostr(o, "t"), o, w.oint(o, "rq"))
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

locked_dispatch :: proc(c: ^Conn, t: string, o: json.Object, rq: i64) {
	if t != "hello" && !c.hello {
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
		locked_err(c, rq, "too_long", "a message is at most 4000 bytes")
		return
	}

	m := w.Msg {
		id       = srv.next_id,
		ch       = strings.clone(ch),
		nick     = strings.clone(c.nick),
		text     = strings.clone(text),
		ts       = w.now_unix(),
		reply_to = w.oint(o, "reply_to"),
		reacts   = make([dynamic]w.React),
	}
	if m.reply_to != 0 {
		if _, found := srv.index[m.reply_to]; !found {
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
	if tag := w.ostr(o, "tag"); tag != "" {
		w.kv_str(&e, "tag", tag)
	}
	locked_broadcast(ch, w.enc_done(&e))
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
	note("replayed %d/%d events from %s", events, lines, path)
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
