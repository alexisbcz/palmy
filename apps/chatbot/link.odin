package main

// The chat side: an ordinary client of the palmy-chat server.
//
// The bot is a separate process holding a plain TCP connection, and that is
// the architectural decision this whole app rests on. The server keeps one
// mutex over all shared state and broadcasts *inside* the critical section,
// which is what makes the order every client sees the order the server
// committed. A generation takes seconds. Model inference anywhere near that
// lock would stall every client in the workspace for the length of a reply.
//
// As an ordinary client the bot cannot take that lock — it has no way to
// reach it — so the property is structural rather than a rule somebody has to
// remember. Everything here is a `post`, an `edit` or a `history` like any
// other client's.
//
// The socket is non-blocking and drained by the main loop. There are no
// threads in this program.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import w "../chat/wire"

// How many messages the bot keeps in view. It is a window, not a log: the
// bot never writes a message to disk, and nothing in this program opens a
// file for writing at all.
CACHE_MAX :: 400

Link :: struct {
	sock:     net.TCP_Socket,
	rd:       w.Reader,
	nick:     string,
	port:     int,
	online:   bool,
	rq:       i64,
	tag_seq:  i64,
	retry_at: f64,
	retry_in: f64,
	// Counters, for the end-to-end measurement. These count what this client
	// *caused*, not what it received.
	posts:    int,
	edits:    int,
}

link_make :: proc(nick: string, port: int) -> Link {
	return Link{nick = strings.clone(nick), port = port, retry_in = 0.4}
}

// link_dial connects to the loopback address and nothing else. There is no
// `--host`: the chat server binds 127.0.0.1 only, so a remote one could not
// be reached even if this took an address.
link_dial :: proc(l: ^Link) -> bool {
	if l.online {
		return true
	}
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = l.port})
	if err != nil {
		return false
	}
	if berr := net.set_blocking(sock, false); berr != nil {
		net.close(sock)
		return false
	}
	l.sock = sock
	l.online = true
	clear(&l.rd.buf)
	l.rd.bad = false

	e: w.Enc
	w.enc_begin(&e, "hello", context.temp_allocator)
	w.kv_str(&e, "nick", l.nick)
	w.kv_str(&e, "presence", "online")
	return link_send(l, w.enc_done(&e))
}

link_close :: proc(l: ^Link) {
	if l.online {
		net.close(l.sock)
		l.online = false
	}
}

link_send :: proc(l: ^Link, payload: string) -> bool {
	if !l.online {
		return false
	}
	if !w.send_frame(l.sock, payload) {
		link_close(l)
		return false
	}
	return true
}

link_rq :: proc(l: ^Link) -> i64 {
	l.rq += 1
	return l.rq
}

// link_poll drains whatever has arrived and returns the parsed frames in
// arrival order, allocated in `allocator`. It never blocks.
link_poll :: proc(l: ^Link, allocator := context.temp_allocator) -> []json.Object {
	out := make([dynamic]json.Object, allocator)
	if !l.online {
		return out[:]
	}
	buf: [32 * 1024]u8
	for {
		n, err := net.recv_tcp(l.sock, buf[:])
		if err == .Would_Block || err == .Timeout {
			break
		}
		if err == .Interrupted {
			continue
		}
		if err != nil || n == 0 {
			link_close(l)
			return out[:]
		}
		w.reader_feed(&l.rd, buf[:n])
		if n < len(buf) {
			break
		}
	}
	if l.rd.bad {
		link_close(l)
		return out[:]
	}
	for {
		payload, ok := w.reader_next(&l.rd, allocator)
		if !ok {
			break
		}
		if o, good := w.parse_obj(payload, allocator); good {
			append(&out, o)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

link_join :: proc(l: ^Link, ch: string) {
	e: w.Enc
	w.enc_begin(&e, "join", context.temp_allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "kind", "channel")
	link_send(l, w.enc_done(&e))
}

link_history :: proc(l: ^Link, ch: string, limit := 50) {
	e: w.Enc
	w.enc_begin(&e, "history", context.temp_allocator)
	w.kv_int(&e, "rq", link_rq(l))
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "limit", i64(limit))
	link_send(l, w.enc_done(&e))
}

// link_thread asks for a thread's messages. The bot issues this before
// answering inside a thread, because a thread reply never appears in the
// channel timeline and so may be entirely absent from the window.
link_thread :: proc(l: ^Link, root: i64) -> i64 {
	rq := link_rq(l)
	e: w.Enc
	w.enc_begin(&e, "thread", context.temp_allocator)
	w.kv_int(&e, "rq", rq)
	w.kv_int(&e, "id", root)
	link_send(l, w.enc_done(&e))
	return rq
}

link_typing :: proc(l: ^Link, ch: string, on: bool) {
	e: w.Enc
	w.enc_begin(&e, "typing", context.temp_allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_bool(&e, "on", on)
	link_send(l, w.enc_done(&e))
}

// link_post posts and returns the tag it used. The server echoes `tag` back
// on the broadcast, which is how this client learns the id of its own
// message: there is no direct reply to `post`, and the broadcast is the
// authority on what was accepted.
link_post :: proc(l: ^Link, ch, text: string, thread: i64) -> string {
	l.tag_seq += 1
	tag := fmt.aprintf("bot-%d", l.tag_seq)
	e: w.Enc
	w.enc_begin(&e, "post", context.temp_allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	if thread != 0 {
		w.kv_int(&e, "thread", thread)
	}
	w.kv_str(&e, "tag", tag)
	if !link_send(l, w.enc_done(&e)) {
		delete(tag)
		return ""
	}
	l.posts += 1
	return tag
}

link_edit :: proc(l: ^Link, id: i64, text: string) -> bool {
	e: w.Enc
	w.enc_begin(&e, "edit", context.temp_allocator)
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "text", text)
	if !link_send(l, w.enc_done(&e)) {
		return false
	}
	l.edits += 1
	return true
}

// ---------------------------------------------------------------------------
// The window of messages the bot can see
// ---------------------------------------------------------------------------

Cache :: struct {
	msgs: [dynamic]w.Msg, // kept sorted by id
}

cache_make :: proc() -> Cache {
	return Cache{msgs = make([dynamic]w.Msg)}
}

// cache_put inserts or replaces by id, keeping the array sorted. History
// arrives oldest-first and may be older than anything already held, so an
// append would put the window out of order and the context would read
// backwards.
cache_put :: proc(c: ^Cache, m: w.Msg) {
	for i := len(c.msgs) - 1; i >= 0; i -= 1 {
		if c.msgs[i].id == m.id {
			c.msgs[i] = m
			return
		}
		if c.msgs[i].id < m.id {
			inject_at(&c.msgs, i + 1, m)
			cache_trim(c)
			return
		}
	}
	inject_at(&c.msgs, 0, m)
	cache_trim(c)
}

@(private = "file")
cache_trim :: proc(c: ^Cache) {
	for len(c.msgs) > CACHE_MAX {
		ordered_remove(&c.msgs, 0)
	}
}

cache_find :: proc(c: ^Cache, id: i64) -> (w.Msg, bool) {
	for m in c.msgs {
		if m.id == id {
			return m, true
		}
	}
	return {}, false
}

cache_edit :: proc(c: ^Cache, id: i64, text: string, edited: i64) {
	for &m in c.msgs {
		if m.id == id {
			m.text = strings.clone(text)
			m.edited = edited
			return
		}
	}
}

cache_delete :: proc(c: ^Cache, id: i64) {
	for &m in c.msgs {
		if m.id == id {
			m.deleted = true
			m.text = ""
			return
		}
	}
}

// cache_channel is the channel timeline: thread replies are excluded, exactly
// as the server's `history` excludes them, so the context the model sees is
// the context a person reading the channel sees.
cache_channel :: proc(c: ^Cache, ch: string, allocator := context.temp_allocator) -> []w.Msg {
	out := make([dynamic]w.Msg, allocator)
	for m in c.msgs {
		if m.ch == ch && m.thread == 0 {
			append(&out, m)
		}
	}
	return out[:]
}

// cache_thread is the root followed by its replies, which is what a person
// reading that thread sees and nothing else.
cache_thread :: proc(c: ^Cache, root: i64, allocator := context.temp_allocator) -> []w.Msg {
	out := make([dynamic]w.Msg, allocator)
	if r, ok := cache_find(c, root); ok {
		append(&out, r)
	}
	for m in c.msgs {
		if m.thread == root {
			append(&out, m)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

START := time.tick_now()

now_ms :: proc() -> i64 {
	return i64(time.duration_milliseconds(time.tick_since(START)))
}

now_s :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(START))
}
