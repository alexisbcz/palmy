// The client half of collaborative editing: one Session per open document,
// shared by Docs, Sheets and Slides.
//
//	s := client.session_open(cfg)          // loads local state, starts syncing
//	// every frame:
//	ev := client.poll(s)                   // remote updates applied to s.doc
//	if ev.changed {rematerialise the app model from s.doc}
//	// after a local edit has been written into s.doc:
//	client.flush(s)                        // sends what the edit produced
//
// Offline first. The document lives in a local file (state + unacknowledged
// updates + the last server sequence seen), so a window opens instantly and
// keeps working with the network gone; edits queue in the outbox and go out
// when the connection comes back. A background thread owns the socket: it
// connects, says hello with `since`, resends the outbox once caught up, and
// reconnects with backoff. Everything it receives goes through a mutex-held
// inbox that `poll` drains on the UI thread, which is the only thread that
// touches the CRDT.
package client

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import crdt "../crdt"
import wire "../wire"

Status :: enum u8 {
	Offline, // never connected, or the network is gone; edits queue locally
	Connecting,
	Syncing, // connected, catching up
	Live,
	Refused, // the server said no: no access, revoked, bad token
}

Config :: struct {
	host:     string, // the sync server
	port:     int,
	doc_id:   string,
	as_id:    string, // the identity this window acts as
	token:    string, // the person's (or the identity's scoped) access token
	link:     string, // a link-share token, optional
	app:      string, // "docs", "sheets", "slides"
	dir:      string, // local state; "" means ~/.local/share/palm/collab
	offline:  bool, // do not connect at all (tests, `--offline`)
	wake:     proc(ctx: rawptr), // called from the network thread when something arrived
	wake_ctx: rawptr,
}

Peer :: struct {
	id:       int,
	agent:    string,
	role:     string,
	identity: wire.Identity_Info,
	state:    json.Value, // the app's awareness payload: caret, selection
	raw:      string, // the whole message, owned; state points into its parse
}

Event_Kind :: enum u8 {
	Welcome,
	Update,
	Snapshot,
	Ack,
	Nack,
	Synced,
	Aware,
	Leave,
	Role,
	Error,
	Down,
}

@(private)
Event :: struct {
	kind: Event_Kind,
	seq:  u64,
	ref:  u64,
	data: []u8, // owned
	text: string, // owned
}

Pending :: struct {
	ref:  u64,
	data: []u8,
}

Session :: struct {
	cfg:        Config,
	doc:        ^crdt.Doc,
	agent:      u64,
	status:     Status,
	role:       string, // as the server said; "" until welcomed
	me:         wire.Identity_Info, // who this window is, as the server verified
	doc_title:  string,
	doc_kind:   string,
	peers:      [dynamic]Peer,
	last_seq:   u64, // the last server sequence applied
	head:       u64, // the server's head when last heard
	error:      string, // the last refusal, for the interface
	nacks:      int,

	// shared with the network thread
	mu:         sync.Mutex,
	inbox:      [dynamic]Event,
	outbox:     [dynamic]Pending,
	next_ref:   u64,
	ws:         ^wire.Conn,
	live:       bool, // caught up: new outbox entries can go straight out
	stop:       bool,
	since:      u64, // what the thread says in hello
	token:      string,
	thread:     ^thread.Thread,
	aware_out:  string, // the latest awareness to (re)send

	dirty:      bool, // local state not yet written to disk
	saved_at:   time.Tick,
}

// state_dir is where this identity's local copies live: one directory per
// identity, so an identity can be removed from a device by deleting its
// directory, and two identities on one machine never share a file.
state_dir :: proc(cfg: Config, allocator := context.allocator) -> string {
	base := cfg.dir
	if base == "" {
		base = os.get_env("PALM_COLLAB_DIR", context.temp_allocator)
	}
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		base, _ = filepath.join({home, ".local/share/palm/collab"}, context.temp_allocator)
	}
	p, _ := filepath.join({base, cfg.as_id != "" ? cfg.as_id : "anonymous"}, allocator)
	return p
}

state_path :: proc(s: ^Session) -> string {
	return fmt.tprintf("%s/%s.state", state_dir(s.cfg, context.temp_allocator), s.cfg.doc_id)
}

// session_open loads the local copy (or starts an empty document) and, unless
// offline, starts syncing.
session_open :: proc(cfg: Config) -> ^Session {
	s := new(Session)
	s.cfg = cfg
	s.cfg.host = strings.clone(cfg.host)
	s.cfg.doc_id = strings.clone(cfg.doc_id)
	s.cfg.as_id = strings.clone(cfg.as_id)
	s.cfg.link = strings.clone(cfg.link)
	s.cfg.app = strings.clone(cfg.app)
	s.cfg.dir = strings.clone(cfg.dir)
	s.token = strings.clone(cfg.token)
	s.next_ref = 1
	if !load_local(s) {
		s.agent = rand.uint64() | 1
		s.doc = crdt.doc_make(s.agent)
	}
	s.since = s.last_seq
	if !cfg.offline {
		s.status = .Connecting
		s.thread = thread.create_and_start_with_poly_data(s, net_thread)
	}
	return s
}

session_close :: proc(s: ^Session) {
	save_local(s)
	sync.lock(&s.mu)
	s.stop = true
	if s.ws != nil {
		wire.close_socket(s.ws)
	}
	sync.unlock(&s.mu)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
	}
	for e in s.inbox {
		delete(e.data)
		delete(e.text)
	}
	delete(s.inbox)
	for p in s.outbox {delete(p.data)}
	delete(s.outbox)
	for &p in s.peers {peer_free(&p)}
	delete(s.peers)
	crdt.doc_destroy(s.doc)
	free(s)
}

peer_free :: proc(p: ^Peer) {
	json.destroy_value(p.state)
	delete(p.raw)
	delete(p.agent)
	delete(p.role)
	delete(p.identity.id)
	delete(p.identity.handle)
	delete(p.identity.display_name)
	delete(p.identity.color)
	delete(p.identity.kind)
}

// set_token hands the session a refreshed access token.
set_token :: proc(s: ^Session, token: string) {
	sync.lock(&s.mu)
	delete(s.token)
	s.token = strings.clone(token)
	ws := s.ws
	live := s.live
	sync.unlock(&s.mu)
	if ws != nil && live {
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, `{"t":"token","token":`)
		wire.json_quote(&b, token)
		append(&b, "}")
		wire.send_text(ws, string(b[:]))
	}
}

// flush takes whatever the CRDT emitted since the last call and queues it.
// Returns whether there was anything.
flush :: proc(s: ^Session) -> bool {
	up := crdt.take_update(s.doc)
	if up == nil {
		return false
	}
	sync.lock(&s.mu)
	ref := s.next_ref
	s.next_ref += 1
	append(&s.outbox, Pending{ref, up})
	ws := s.ws
	live := s.live
	sync.unlock(&s.mu)
	if ws != nil && live {
		wire.send_binary(ws, wire.frame(wire.MSG_UPDATE_UP, {ref}, up))
	}
	s.dirty = true
	return true
}

// set_awareness publishes this window's caret and selection (any JSON
// object). It is sent now if connected and again after every reconnect.
set_awareness :: proc(s: ^Session, state_json: string) {
	sync.lock(&s.mu)
	same := s.aware_out == state_json
	if !same {
		delete(s.aware_out)
		s.aware_out = strings.clone(state_json)
	}
	ws := s.ws
	live := s.live
	sync.unlock(&s.mu)
	if !same && ws != nil && live {
		wire.send_text(ws, fmt.tprintf(`{{"t":"aware","state":%s}}`, state_json))
	}
}

Poll :: struct {
	changed:  bool, // the document changed under the app: rematerialise
	replaced: bool, // s.doc is a new object (a snapshot arrived)
	peers:    bool, // presence changed
	status:   bool, // status or role changed
}

// poll applies everything that arrived. Call it from the UI thread.
poll :: proc(s: ^Session) -> (out: Poll) {
	sync.lock(&s.mu)
	evs := s.inbox
	s.inbox = make([dynamic]Event)
	sync.unlock(&s.mu)
	defer {
		for e in evs {
			delete(e.data)
			delete(e.text)
		}
		delete(evs)
	}
	for e in evs {
		switch e.kind {
		case .Welcome:
			v, err := json.parse_string(e.text, json.Specification.JSON, true, context.temp_allocator)
			if err == .None {
				delete(s.role)
				s.role = strings.clone(jstr(v, "role"))
				identity_set(&s.me, v, "identity")
				delete(s.doc_title)
				s.doc_title = strings.clone(jstr(v, "doc", "title"))
				delete(s.doc_kind)
				s.doc_kind = strings.clone(jstr(v, "doc", "kind"))
				s.head = u64(jint(v, "head"))
				for &p in s.peers {peer_free(&p)}
				clear(&s.peers)
				if obj, ok := v.(json.Object); ok {
					if arr, ok2 := obj["peers"].(json.Array); ok2 {
						for pv in arr {
							raw, _ := json.marshal(pv, allocator = context.temp_allocator)
							peer_upsert(s, string(raw))
						}
					}
				}
			}
			s.status = .Syncing
			s.error = ""
			out.status = true
			out.peers = true
		case .Snapshot:
			nd, ok := crdt.doc_load(s.agent, e.data)
			if !ok {
				continue
			}
			// Our own unacknowledged edits are not in it yet; put them back.
			sync.lock(&s.mu)
			for p in s.outbox {
				crdt.apply_update(nd, p.data)
			}
			sync.unlock(&s.mu)
			nd.undo = s.doc.undo
			s.doc.undo = {}
			crdt.doc_destroy(s.doc)
			s.doc = nd
			s.last_seq = e.seq
			out.changed = true
			out.replaced = true
			s.dirty = true
		case .Update:
			if e.seq <= s.last_seq {
				continue
			}
			crdt.apply_update(s.doc, e.data)
			s.last_seq = e.seq
			out.changed = true
			s.dirty = true
		case .Ack:
			sync.lock(&s.mu)
			for p, i in s.outbox {
				if p.ref == e.ref {
					delete(p.data)
					ordered_remove(&s.outbox, i)
					break
				}
			}
			sync.unlock(&s.mu)
			// The acknowledged update is ours, so applying it changes nothing;
			// what matters is that later remote updates are numbered after it.
			if e.seq == s.last_seq + 1 {
				s.last_seq = e.seq
			}
			s.dirty = true
		case .Nack:
			s.nacks += 1
			sync.lock(&s.mu)
			for p, i in s.outbox {
				if p.ref == e.ref {
					delete(p.data)
					ordered_remove(&s.outbox, i)
					break
				}
			}
			sync.unlock(&s.mu)
			delete(s.error)
			s.error = strings.clone(fmt.tprintf("an edit was refused: %s", string(e.data)))
			out.status = true
		case .Synced:
			s.status = .Live
			out.status = true
		case .Aware:
			peer_upsert(s, e.text)
			out.peers = true
		case .Leave:
			for &p, i in s.peers {
				if u64(p.id) == e.seq {
					peer_free(&p)
					ordered_remove(&s.peers, i)
					break
				}
			}
			out.peers = true
		case .Role:
			delete(s.role)
			s.role = strings.clone(e.text)
			out.status = true
		case .Error:
			s.status = .Refused
			delete(s.error)
			s.error = strings.clone(e.text)
			out.status = true
		case .Down:
			if s.status != .Refused {
				s.status = .Offline
			}
			for &p in s.peers {peer_free(&p)}
			clear(&s.peers)
			out.status = true
			out.peers = true
		}
	}
	if s.dirty && time.duration_seconds(time.tick_since(s.saved_at)) > 2 {
		save_local(s)
	}
	return
}

pending_count :: proc(s: ^Session) -> int {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	return len(s.outbox)
}

peer_upsert :: proc(s: ^Session, raw: string) {
	owned := strings.clone(raw)
	v, err := json.parse_string(owned, json.Specification.JSON, true)
	if err != .None {
		delete(owned)
		return
	}
	id := int(jint(v, "peer"))
	np := Peer {
		id    = id,
		agent = strings.clone(jstr(v, "agent")),
		role  = strings.clone(jstr(v, "role")),
		raw   = owned,
	}
	identity_set(&np.identity, v, "identity")
	if obj, ok := v.(json.Object); ok {
		np.state = obj["state"]
		obj["state"] = nil
	}
	json.destroy_value(v)
	for &p in s.peers {
		if p.id == id {
			peer_free(&p)
			p = np
			return
		}
	}
	append(&s.peers, np)
}

identity_set :: proc(dst: ^wire.Identity_Info, v: json.Value, key: string) {
	delete(dst.id)
	delete(dst.handle)
	delete(dst.display_name)
	delete(dst.color)
	delete(dst.kind)
	dst.id = strings.clone(jstr(v, key, "id"))
	dst.handle = strings.clone(jstr(v, key, "handle"))
	dst.display_name = strings.clone(jstr(v, key, "display_name"))
	dst.color = strings.clone(jstr(v, key, "color"))
	dst.kind = strings.clone(jstr(v, key, "kind"))
}

// ---------------------------------------------------------------------------
// The network thread
// ---------------------------------------------------------------------------

@(private)
push :: proc(s: ^Session, e: Event) {
	sync.lock(&s.mu)
	append(&s.inbox, e)
	sync.unlock(&s.mu)
	if s.cfg.wake != nil {
		s.cfg.wake(s.cfg.wake_ctx)
	}
}

net_thread :: proc(s: ^Session) {
	backoff := 500 * time.Millisecond
	for {
		sync.lock(&s.mu)
		stop := s.stop
		token := strings.clone(s.token, context.temp_allocator)
		since := s.since
		aware := strings.clone(s.aware_out, context.temp_allocator)
		sync.unlock(&s.mu)
		if stop {
			return
		}
		ws, err := wire.dial(s.cfg.host, s.cfg.port, "/v1/doc")
		if err != "" {
			push(s, Event{kind = .Down, text = strings.clone(err)})
			time.sleep(backoff)
			backoff = min(backoff * 2, 8 * time.Second)
			continue
		}
		sync.lock(&s.mu)
		if s.stop {
			sync.unlock(&s.mu)
			wire.close(ws)
			free(ws)
			return
		}
		s.ws = ws
		s.live = false
		sync.unlock(&s.mu)

		b := make([dynamic]u8, context.temp_allocator)
		append(&b, `{"t":"hello","doc":`)
		wire.json_quote(&b, s.cfg.doc_id)
		append(&b, `,"as":`)
		wire.json_quote(&b, s.cfg.as_id)
		append(&b, `,"token":`)
		wire.json_quote(&b, token)
		append(&b, fmt.tprintf(`,"agent":"%x","since":%d,"client":`, s.agent, since))
		wire.json_quote(&b, s.cfg.app)
		if s.cfg.link != "" {
			append(&b, `,"link":`)
			wire.json_quote(&b, s.cfg.link)
		}
		append(&b, "}")
		wire.send_text(ws, string(b[:]))

		refused := false
		for {
			m, ok := wire.read_message(ws)
			if !ok {
				break
			}
			if m.text {
				v, perr := json.parse(m.data, json.Specification.JSON, true, context.temp_allocator)
				t := perr == .None ? jstr(v, "t") : ""
				switch t {
				case "welcome":
					push(s, Event{kind = .Welcome, text = strings.clone(string(m.data))})
					backoff = 500 * time.Millisecond
				case "synced":
					head := u64(jint(v, "head"))
					// Caught up: resend everything not yet acknowledged, in order,
					// then go live and republish presence.
					sync.lock(&s.mu)
					for p in s.outbox {
						wire.send_binary(ws, wire.frame(wire.MSG_UPDATE_UP, {p.ref}, p.data))
					}
					s.live = true
					sync.unlock(&s.mu)
					if aware != "" {
						wire.send_text(ws, fmt.tprintf(`{{"t":"aware","state":%s}}`, aware))
					}
					push(s, Event{kind = .Synced, seq = head})
				case "aware":
					push(s, Event{kind = .Aware, text = strings.clone(string(m.data))})
				case "leave":
					push(s, Event{kind = .Leave, seq = u64(jint(v, "peer"))})
				case "role":
					push(s, Event{kind = .Role, text = strings.clone(jstr(v, "role"))})
				case "error":
					refused = true
					push(s, Event{kind = .Error, text = strings.clone(fmt.tprintf("%s: %s", jstr(v, "code"), jstr(v, "message")))})
				}
				delete(m.data)
			} else {
				kind, nums, rest, ok2 := wire.unframe(m.data, 1)
				if ok2 {
					switch kind {
					case wire.MSG_UPDATE_DOWN:
						sync.lock(&s.mu)
						s.since = max(s.since, nums[0])
						sync.unlock(&s.mu)
						push(s, Event{kind = .Update, seq = nums[0], data = clone(rest)})
					case wire.MSG_SNAPSHOT:
						sync.lock(&s.mu)
						s.since = max(s.since, nums[0])
						sync.unlock(&s.mu)
						push(s, Event{kind = .Snapshot, seq = nums[0], data = clone(rest)})
					case wire.MSG_ACK:
						_, n2, _, _ := wire.unframe(m.data, 2)
						sync.lock(&s.mu)
						s.since = max(s.since, n2[1])
						sync.unlock(&s.mu)
						push(s, Event{kind = .Ack, ref = n2[0], seq = n2[1]})
					case wire.MSG_NACK:
						push(s, Event{kind = .Nack, ref = nums[0], data = clone(rest)})
					}
				}
				delete(m.data)
			}
			free_all(context.temp_allocator)
		}
		sync.lock(&s.mu)
		s.ws = nil
		s.live = false
		stop = s.stop
		sync.unlock(&s.mu)
		wire.close(ws)
		free(ws)
		if stop {
			return
		}
		if refused {
			return // the server said no; do not hammer it
		}
		push(s, Event{kind = .Down})
		time.sleep(backoff)
		backoff = min(backoff * 2, 8 * time.Second)
	}
}

// go_offline drops the connection, as if the network went away, and
// reconnect brings it back. Used by the demo and the tests.
go_offline :: proc(s: ^Session) {
	sync.lock(&s.mu)
	s.stop = true
	if s.ws != nil {
		wire.close_socket(s.ws)
	}
	sync.unlock(&s.mu)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	s.status = .Offline
	for &p in s.peers {peer_free(&p)}
	clear(&s.peers)
}

reconnect :: proc(s: ^Session) {
	if s.thread != nil || s.cfg.offline {
		return
	}
	sync.lock(&s.mu)
	s.stop = false
	s.since = s.last_seq
	sync.unlock(&s.mu)
	s.status = .Connecting
	s.thread = thread.create_and_start_with_poly_data(s, net_thread)
}

clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

jstr :: proc(v: json.Value, keys: ..string) -> string {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok {return ""}
		cur = obj[k]
	}
	#partial switch x in cur {
	case json.String:
		return x
	}
	return ""
}

jint :: proc(v: json.Value, keys: ..string) -> i64 {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok {return 0}
		cur = obj[k]
	}
	#partial switch x in cur {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	case json.String:
		n, _ := strconv.parse_i64(x)
		return n
	}
	return 0
}

// ---------------------------------------------------------------------------
// The local copy
// ---------------------------------------------------------------------------
//
//	"PCS1" varint last_seq varint agent varint n_out (varint len bytes) x n_out  snapshot

save_local :: proc(s: ^Session) {
	s.saved_at = time.tick_now()
	s.dirty = false
	if s.doc == nil {
		return
	}
	dir := state_dir(s.cfg, context.temp_allocator)
	_ = os.make_directory_all(dir)
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, "PCS1")
	wire.put_uv(&b, s.last_seq)
	wire.put_uv(&b, s.agent)
	sync.lock(&s.mu)
	wire.put_uv(&b, u64(len(s.outbox)))
	for p in s.outbox {
		wire.put_uv(&b, u64(len(p.data)))
		append(&b, ..p.data)
	}
	sync.unlock(&s.mu)
	snap := crdt.encode_state(s.doc, context.temp_allocator)
	append(&b, ..snap)
	path := state_path(s)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, b[:]) == nil {
		_ = os.rename(tmp, path)
	}
}

load_local :: proc(s: ^Session) -> bool {
	data, err := os.read_entire_file_from_path(state_path(s), context.temp_allocator)
	if err != nil || len(data) < 5 || string(data[:4]) != "PCS1" {
		return false
	}
	i := 4
	last, ok1 := wire.get_uv(data, &i)
	agent, ok2 := wire.get_uv(data, &i)
	n, ok3 := wire.get_uv(data, &i)
	if !ok1 || !ok2 || !ok3 || n > u64(len(data)) {
		return false
	}
	outs := make([dynamic]Pending)
	for _ in 0 ..< n {
		l, ok := wire.get_uv(data, &i)
		if !ok || l > u64(len(data) - i) {
			for p in outs {delete(p.data)}
			delete(outs)
			return false
		}
		append(&outs, Pending{s.next_ref, clone(data[i:i + int(l)])})
		s.next_ref += 1
		i += int(l)
	}
	d, ok := crdt.doc_load(agent, data[i:])
	if !ok {
		for p in outs {delete(p.data)}
		delete(outs)
		return false
	}
	s.doc = d
	s.agent = agent
	s.last_seq = last
	s.outbox = outs
	return true
}
