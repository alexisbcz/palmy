// palm-collab — the sync service for collaborative documents.
//
//	palm-collab [--port 62590] [--listen 127.0.0.1]
//
//	PALM_CLOUD_URL           the API gateway (http://127.0.0.1:54321)
//	PALM_CLOUD_ANON_KEY      the project's anon key
//	PALM_COLLAB_SERVICE_KEY  the service_role key: the log is written only here
//
// One WebSocket per open document window (cloud/collab/wire/protocol.odin).
// The server is the ordering point and the gatekeeper, not the authority on
// meaning — that is the CRDT's — and the database is the authority on who may
// do what:
//
//   * a window joins with the person's own access token, and collab_join()
//     (RLS, can_access_identity) says which role that identity holds;
//   * every update is decoded and each operation checked against the role:
//     viewers send nothing, commenters only comment threads and comment
//     ranges, suggesters only suggested insertions and suggestion marks;
//     every operation must carry the connection's own agent, so nobody can
//     write as somebody else;
//   * collab_append() re-checks the role in the database before it assigns
//     a sequence number, so a revoked grant stops writes at the next update
//     even if this process has not noticed yet;
//   * a janitor re-checks every open connection's role every few seconds and
//     closes revoked ones, so a revoked viewer also stops receiving.
//
// Each open document has one in-memory replica, which is how a joining window
// gets a snapshot in one message and how compaction happens: every
// SNAPSHOT_EVERY updates the replica's state is stored with its sequence
// number, and history is rebuilt from the nearest snapshot before a point.
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
import ck "../../../apps/cloudkit"
import crdt "../crdt"
import wire "../wire"

SNAPSHOT_EVERY :: 200
RECHECK_EVERY :: 5 * time.Second

Config :: struct {
	port:        int,
	listen:      net.IP4_Address,
	api:         ck.Url,
	anon:        string,
	service:     string,
}

cfg: Config

Room :: struct {
	id:         string,
	mu:         sync.Mutex,
	doc:        ^crdt.Doc,
	head:       u64,
	log_start:  u64, // the log below holds updates log_start+1 .. head
	log:        [dynamic][]u8,
	since_snap: int,
	conns:      [dynamic]^Peer,
	refs:       int,
	kind:       string,
	title:      string,
	owner:      string,
}

Peer :: struct {
	ws:       ^wire.Conn,
	room:     ^Room,
	id:       int,
	user:     string,
	token:    string,
	role:     string,
	identity: wire.Identity_Info,
	agent:    u64,
	agent_hex: string,
	aware:    string, // the last awareness JSON this peer sent, as relayed
	gone:     bool,
}

rooms_mu: sync.Mutex
rooms: map[string]^Room
peers: [dynamic]^Peer
next_peer := 1

logf :: proc(format: string, args: ..any) {
	t := time.now()
	h, m, s := time.clock_from_time(t)
	fmt.eprintf("[%02d:%02d:%02d] ", h, m, s)
	fmt.eprintfln(format, ..args)
}

// ---------------------------------------------------------------------------
// The database, over PostgREST
// ---------------------------------------------------------------------------

rpc :: proc(fn: string, body: string, bearer: string, allocator := context.temp_allocator) -> (v: json.Value, status: int, err: string) {
	headers := [?]ck.Header {
		{"apikey", cfg.anon},
		{"Authorization", fmt.tprintf("Bearer %s", bearer)},
		{"Content-Type", "application/json"},
		{"Accept", "application/json"},
	}
	resp, terr := ck.http_do(
		cfg.api,
		ck.Request{method = "POST", path = fmt.tprintf("/rest/v1/rpc/%s", fn), headers = headers[:], body = transmute([]u8)body},
		"palm-collab",
	)
	if terr != "" {
		return nil, 0, terr
	}
	defer ck.response_destroy(&resp)
	parsed, perr := json.parse_string(resp.body, json.Specification.JSON, true, allocator)
	if perr != .None {
		parsed = nil
	}
	if resp.status < 200 || resp.status >= 300 {
		msg := "request refused"
		if obj, ok := parsed.(json.Object); ok {
			if m, ok2 := obj["message"].(json.String); ok2 {
				msg = strings.clone(m, allocator)
			}
		}
		return parsed, resp.status, msg
	}
	return parsed, resp.status, ""
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
	case json.Integer:
		return fmt.tprintf("%d", x)
	case json.Float:
		return fmt.tprintf("%v", x)
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

b64 :: proc(data: []u8) -> string {
	s, _ := base64.encode(data, allocator = context.temp_allocator)
	return s
}

unb64 :: proc(s: string) -> []u8 {
	d, err := base64.decode(s, allocator = context.temp_allocator)
	if err != nil {
		return nil
	}
	return d
}

// ---------------------------------------------------------------------------
// Rooms
// ---------------------------------------------------------------------------

// room_open returns the loaded room for a document, loading it on first use.
room_open :: proc(doc_id: string) -> (^Room, string) {
	sync.lock(&rooms_mu)
	r, ok := rooms[doc_id]
	if !ok {
		r = new(Room)
		r.id = strings.clone(doc_id)
		rooms[r.id] = r
	}
	r.refs += 1
	sync.unlock(&rooms_mu)

	sync.lock(&r.mu)
	defer sync.unlock(&r.mu)
	if r.doc != nil {
		return r, ""
	}
	v, _, err := rpc("collab_load", fmt.tprintf(`{{"p_doc":"%s"}}`, doc_id), cfg.service)
	if err != "" {
		return r, err
	}
	snap := unb64(jstr(v, "snapshot"))
	if len(snap) > 0 {
		d, good := crdt.doc_load(1, snap)
		if !good {
			return r, "the stored snapshot does not load"
		}
		r.doc = d
	} else {
		r.doc = crdt.doc_make(1)
	}
	r.log_start = u64(jint(v, "snapshot_seq"))
	r.head = r.log_start
	if obj, ok2 := v.(json.Object); ok2 {
		if arr, ok3 := obj["updates"].(json.Array); ok3 {
			for u in arr {
				data := unb64(jstr(u, "data"))
				crdt.apply_update(r.doc, data)
				append(&r.log, clone(data))
				r.head = u64(jint(u, "seq"))
			}
		}
	}
	r.since_snap = int(r.head - r.log_start)
	logf("room %s loaded: head %d, snapshot %d, %d in log", short(doc_id), r.head, r.log_start, len(r.log))
	return r, ""
}

room_release :: proc(r: ^Room) {
	sync.lock(&rooms_mu)
	r.refs -= 1
	last := r.refs == 0
	if last {
		delete_key(&rooms, r.id)
	}
	sync.unlock(&rooms_mu)
	if !last {
		return
	}
	sync.lock(&r.mu)
	if r.since_snap > 0 && r.doc != nil {
		store_snapshot(r)
	}
	sync.unlock(&r.mu)
	crdt.doc_destroy(r.doc)
	for u in r.log {delete(u)}
	delete(r.log)
	delete(r.conns)
	delete(r.id)
	free(r)
}

// store_snapshot writes the replica's state at `head`. Called with r.mu held.
store_snapshot :: proc(r: ^Room) {
	snap := crdt.encode_state(r.doc)
	defer delete(snap)
	_, _, err := rpc(
		"collab_put_snapshot",
		fmt.tprintf(`{{"p_doc":"%s","p_seq":%d,"p_data":"%s"}}`, r.id, r.head, b64(snap)),
		cfg.service,
	)
	if err != "" {
		logf("room %s: snapshot at %d failed: %s", short(r.id), r.head, err)
		return
	}
	logf("room %s: snapshot at %d (%d bytes)", short(r.id), r.head, len(snap))
	r.since_snap = 0
}

clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

short :: proc(id: string) -> string {
	return len(id) > 8 ? id[:8] : id
}

// ---------------------------------------------------------------------------
// Roles and validation
// ---------------------------------------------------------------------------

rank :: proc(r: string) -> int {
	switch r {
	case "view":
		return 1
	case "comment":
		return 2
	case "suggest":
		return 3
	case "edit":
		return 4
	case "owner":
		return 5
	}
	return 0
}

role_name :: proc(k: int) -> string {
	switch k {
	case 1:
		return "view"
	case 2:
		return "comment"
	case 3:
		return "suggest"
	case 4:
		return "edit"
	}
	return "owner"
}

// required_rank says what role an update needs, or -1 when it is malformed
// or forged. The namespaces are the bindings' (cloud/docs/office.md):
// comment threads live under "cmt/" and their reply lists under "cr/";
// comment ranges are marks named "cm:<id>"; suggestions are insertions
// flagged FLAG_SUGGEST plus "si"/"sd" marks carrying the author's handle.
required_rank :: proc(p: ^Peer, data: []u8) -> int {
	dec, ok := crdt.decode_update(data)
	if !ok || len(dec.ops) == 0 {
		return -1
	}
	need := 2
	for &op in dec.ops {
		if op.id.agent != p.agent {
			return -1
		}
		k := 4
		switch op.kind {
		case .Set:
			if strings.has_prefix(op.key, "cmt/") {k = 2}
		case .Insert:
			if strings.has_prefix(op.key, "cr/") {
				k = 2
			} else if op.flags & crdt.FLAG_SUGGEST != 0 {
				k = 3
			}
		case .Mark:
			if strings.has_prefix(op.attr, "cm:") {
				k = 2
			} else if (op.attr == "si" || op.attr == "sd") && string(op.value) == p.identity.handle {
				k = 3
			}
		case .Delete, .Restore:
			own := true
			for r in op.ranges {
				if r.id.agent != p.agent {own = false}
			}
			k = own ? 2 : 4
		}
		need = max(need, k)
	}
	return need
}

// ---------------------------------------------------------------------------
// Messages out
// ---------------------------------------------------------------------------

identity_json :: proc(b: ^[dynamic]u8, i: wire.Identity_Info) {
	append(b, `{"id":`)
	wire.json_quote(b, i.id)
	append(b, `,"handle":`)
	wire.json_quote(b, i.handle)
	append(b, `,"display_name":`)
	wire.json_quote(b, i.display_name)
	append(b, `,"color":`)
	wire.json_quote(b, i.color)
	append(b, `,"kind":`)
	wire.json_quote(b, i.kind)
	append(b, "}")
}

aware_json :: proc(p: ^Peer, state: string, allocator := context.allocator) -> string {
	b := make([dynamic]u8, allocator)
	append(&b, `{"t":"aware","peer":`)
	append(&b, fmt.tprintf("%d", p.id))
	append(&b, `,"agent":`)
	wire.json_quote(&b, p.agent_hex)
	append(&b, `,"role":`)
	wire.json_quote(&b, p.role)
	append(&b, `,"identity":`)
	identity_json(&b, p.identity)
	append(&b, `,"state":`)
	append(&b, state)
	append(&b, "}")
	return string(b[:])
}

send_error :: proc(ws: ^wire.Conn, code, message: string) {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, `{"t":"error","code":`)
	wire.json_quote(&b, code)
	append(&b, `,"message":`)
	wire.json_quote(&b, message)
	append(&b, "}")
	wire.send_text(ws, string(b[:]))
}

// broadcast sends to every other live peer in the room. Called with r.mu.
broadcast :: proc(r: ^Room, from: ^Peer, text: string, bin: []u8) {
	for q in r.conns {
		if q == from || q.gone {continue}
		if bin != nil {
			wire.send_binary(q.ws, bin)
		} else {
			wire.send_text(q.ws, text)
		}
	}
}

// ---------------------------------------------------------------------------
// A connection
// ---------------------------------------------------------------------------

serve :: proc(ws: ^wire.Conn) {
	defer {
		wire.close(ws)
		free(ws)
	}
	req, ok := wire.server_handshake(ws)
	if !ok {
		return
	}
	_ = req
	first, mok := wire.read_message(ws)
	if !mok || !first.text {
		return
	}
	defer delete(first.data)
	hello: wire.Hello
	if json.unmarshal(first.data, &hello, allocator = context.temp_allocator) != nil || hello.t != "hello" {
		send_error(ws, "protocol", "the first message must be hello")
		return
	}
	agent, aok := strconv.parse_u64_of_base(hello.agent, 16)
	if !aok || agent == 0 || len(hello.agent) > 16 || len(hello.doc) != 36 || len(hello.as) != 36 {
		send_error(ws, "protocol", "hello is missing doc, as or agent")
		return
	}

	// The person's own token proves who they are and which identity they act as.
	link := hello.link != "" ? fmt.tprintf(`,"p_link":"%s"`, hello.link) : ""
	jv, status, err := rpc(
		"collab_join",
		fmt.tprintf(`{{"p_doc":"%s","p_as":"%s"%s}}`, hello.doc, hello.as, link),
		hello.token,
	)
	if err != "" {
		code := status == 401 ? "unauthorized" : "unavailable"
		send_error(ws, code, err)
		return
	}
	role := jstr(jv, "role")
	if role == "" {
		send_error(ws, "forbidden", fmt.tprintf("no access (%s)", jstr(jv, "reason")))
		logf("refused %s as %s: %s", short(hello.doc), short(hello.as), jstr(jv, "reason"))
		return
	}

	p := new(Peer)
	defer free(p)
	p.ws = ws
	p.user = strings.clone(jstr(jv, "user"))
	p.token = strings.clone(hello.token)
	p.role = strings.clone(role)
	p.agent = agent
	p.agent_hex = strings.clone(fmt.tprintf("%x", agent))
	p.identity = wire.Identity_Info {
		id           = strings.clone(jstr(jv, "identity", "id")),
		handle       = strings.clone(jstr(jv, "identity", "handle")),
		display_name = strings.clone(jstr(jv, "identity", "display_name")),
		color        = strings.clone(jstr(jv, "identity", "color")),
		kind         = strings.clone(jstr(jv, "identity", "kind")),
	}
	defer {
		delete(p.user)
		delete(p.token)
		delete(p.role)
		delete(p.agent_hex)
		delete(p.identity.id)
		delete(p.identity.handle)
		delete(p.identity.display_name)
		delete(p.identity.color)
		delete(p.identity.kind)
		delete(p.aware)
	}

	r, rerr := room_open(hello.doc)
	defer room_release(r)
	if rerr != "" {
		send_error(ws, "unavailable", rerr)
		return
	}

	// Join: welcome, catch-up, and the others are told.
	sync.lock(&r.mu)
	sync.lock(&rooms_mu)
	p.id = next_peer
	next_peer += 1
	append(&peers, p)
	sync.unlock(&rooms_mu)
	p.room = r
	p.aware = aware_json(p, "{}")
	{
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, `{"t":"welcome","role":`)
		wire.json_quote(&b, p.role)
		append(&b, fmt.tprintf(`,"peer":%d,"head":%d,"identity":`, p.id, r.head))
		identity_json(&b, p.identity)
		append(&b, `,"doc":`)
		if obj, ok2 := jv.(json.Object); ok2 {
			dj, _ := json.marshal(obj["doc"], allocator = context.temp_allocator)
			append(&b, ..dj)
		} else {
			append(&b, "{}")
		}
		append(&b, `,"peers":[`)
		first_peer := true
		for q in r.conns {
			if q.gone {continue}
			if !first_peer {append(&b, ",")}
			append(&b, q.aware)
			first_peer = false
		}
		append(&b, "]}")
		wire.send_text(ws, string(b[:]))
	}
	if hello.since < r.log_start || hello.since > r.head {
		snap := crdt.encode_state(r.doc)
		wire.send_binary(ws, wire.frame(wire.MSG_SNAPSHOT, {r.head}, snap))
		delete(snap)
	} else {
		for i := hello.since; i < r.head; i += 1 {
			wire.send_binary(ws, wire.frame(wire.MSG_UPDATE_DOWN, {i + 1}, r.log[i - r.log_start]))
		}
	}
	wire.send_text(ws, fmt.tprintf(`{{"t":"synced","head":%d}}`, r.head))
	append(&r.conns, p)
	broadcast(r, p, p.aware, nil)
	sync.unlock(&r.mu)
	logf("%s joined %s as %s (%s), agent %s", p.identity.handle, short(r.id), p.role, hello.client, p.agent_hex)

	for {
		m, good := wire.read_message(ws)
		if !good {
			break
		}
		if m.text {
			handle_text(p, m.data)
		} else {
			handle_update(p, m.data)
		}
		delete(m.data)
		free_all(context.temp_allocator)
		if p.gone {
			break
		}
	}

	sync.lock(&r.mu)
	for q, i in r.conns {
		if q == p {
			ordered_remove(&r.conns, i)
			break
		}
	}
	broadcast(r, p, fmt.tprintf(`{{"t":"leave","peer":%d}}`, p.id), nil)
	sync.unlock(&r.mu)
	sync.lock(&rooms_mu)
	for q, i in peers {
		if q == p {
			unordered_remove(&peers, i)
			break
		}
	}
	sync.unlock(&rooms_mu)
	logf("%s left %s", p.identity.handle, short(r.id))
}

handle_text :: proc(p: ^Peer, data: []u8) {
	v, err := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	if err != .None {
		return
	}
	obj, ok := v.(json.Object)
	if !ok {
		return
	}
	switch jstr(v, "t") {
	case "aware":
		state, _ := json.marshal(obj["state"], allocator = context.temp_allocator)
		if len(state) > 8192 {
			return
		}
		r := p.room
		sync.lock(&r.mu)
		delete(p.aware)
		p.aware = aware_json(p, string(state))
		broadcast(r, p, p.aware, nil)
		sync.unlock(&r.mu)
	case "token":
		t := jstr(v, "token")
		if t != "" {
			sync.lock(&p.room.mu)
			delete(p.token)
			p.token = strings.clone(t)
			sync.unlock(&p.room.mu)
		}
	}
}

handle_update :: proc(p: ^Peer, data: []u8) {
	kind, nums, rest, ok := wire.unframe(data, 1)
	if !ok || kind != wire.MSG_UPDATE_UP {
		return
	}
	ref := nums[0]
	need := required_rank(p, rest)
	if need < 0 || need > rank(p.role) {
		why := need < 0 ? "malformed or not your agent" : fmt.tprintf("needs %s, you have %s", role_name(need), p.role)
		wire.send_binary(p.ws, wire.frame(wire.MSG_NACK, {ref}, transmute([]u8)why))
		logf("refused an update from %s on %s: %s", p.identity.handle, short(p.room.id), why)
		return
	}
	r := p.room
	sync.lock(&r.mu)
	defer sync.unlock(&r.mu)
	v, status, err := rpc(
		"collab_append",
		fmt.tprintf(
			`{{"p_doc":"%s","p_as":"%s","p_user":"%s","p_agent":"%s","p_data":"%s","p_min_role":"%s"}}`,
			r.id,
			p.identity.id,
			p.user,
			p.agent_hex,
			b64(rest),
			role_name(need),
		),
		cfg.service,
	)
	if err != "" {
		if status == 403 || status == 401 || strings.contains(err, "not allowed") || strings.contains(err, "belongs") {
			send_error(p.ws, "revoked", err)
			p.gone = true
			logf("%s can no longer write %s: %s", p.identity.handle, short(r.id), err)
		} else {
			wire.send_binary(p.ws, wire.frame(wire.MSG_NACK, {ref}, transmute([]u8)err))
		}
		return
	}
	seq := u64(jint(v))
	if seq != r.head + 1 {
		// Someone else wrote to the log (another server process). Reload on
		// next open; this one keeps relaying in order.
		logf("room %s: expected seq %d, the log says %d", short(r.id), r.head + 1, seq)
	}
	r.head = seq
	crdt.apply_update(r.doc, rest)
	append(&r.log, clone(rest))
	r.since_snap += 1
	wire.send_binary(p.ws, wire.frame(wire.MSG_ACK, {ref, seq}, nil))
	broadcast(r, p, "", wire.frame(wire.MSG_UPDATE_DOWN, {seq}, rest))
	if r.since_snap >= SNAPSHOT_EVERY {
		store_snapshot(r)
	}
}

// janitor re-checks every connection's role, so revoking a grant also stops
// a viewer that never writes.
janitor :: proc() {
	for {
		time.sleep(RECHECK_EVERY)
		sync.lock(&rooms_mu)
		snapshot := make([dynamic]^Peer, 0, len(peers), context.temp_allocator)
		append(&snapshot, ..peers[:])
		sync.unlock(&rooms_mu)
		for p in snapshot {
			sync.lock(&rooms_mu)
			alive := false
			for q in peers {
				if q == p {alive = true}
			}
			if !alive {
				sync.unlock(&rooms_mu)
				continue
			}
			doc := strings.clone(p.room.id, context.temp_allocator)
			who := strings.clone(p.identity.id, context.temp_allocator)
			user := strings.clone(p.user, context.temp_allocator)
			sync.unlock(&rooms_mu)
			v, _, err := rpc(
				"collab_server_role",
				fmt.tprintf(`{{"p_doc":"%s","p_as":"%s","p_user":"%s"}}`, doc, who, user),
				cfg.service,
			)
			if err != "" {
				continue
			}
			now := ""
			if s, ok := v.(json.String); ok {
				now = s
			}
			sync.lock(&rooms_mu)
			still := false
			for q in peers {
				if q == p {still = true}
			}
			if still {
				if now == "" {
					send_error(p.ws, "revoked", "your access to this document was revoked")
					p.gone = true
					net.shutdown(p.ws.sock, .Both)
					logf("revoked %s on %s", p.identity.handle, short(doc))
				} else if now != p.role {
					wire.send_text(p.ws, fmt.tprintf(`{{"t":"role","role":"%s"}}`, now))
					logf("%s on %s: role %s -> %s", p.identity.handle, short(doc), p.role, now)
					delete(p.role)
					p.role = strings.clone(now)
				}
			}
			sync.unlock(&rooms_mu)
		}
		free_all(context.temp_allocator)
	}
}

main :: proc() {
	cfg.port = 8790
	cfg.listen = net.IP4_Loopback
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--port":
			if i + 1 < len(args) {
				cfg.port, _ = strconv.parse_int(args[i + 1])
				i += 1
			}
		case "--listen":
			if i + 1 < len(args) {
				if a, ok := net.parse_ip4_address(args[i + 1]); ok {
					cfg.listen = a
				}
				i += 1
			}
		case "--help", "-h":
			fmt.println("palm-collab [--port N] [--listen ADDR]   (env: PALM_CLOUD_URL, PALM_CLOUD_ANON_KEY, PALM_COLLAB_SERVICE_KEY)")
			return
		}
	}
	url := os.get_env("PALM_CLOUD_URL", context.allocator)
	if url == "" {
		url = ck.DEFAULT_URL
	}
	u, uok := ck.parse_url(url)
	if !uok {
		fmt.eprintln("palm-collab: bad PALM_CLOUD_URL")
		os.exit(2)
	}
	cfg.api = u
	cfg.anon = os.get_env("PALM_CLOUD_ANON_KEY", context.allocator)
	if cfg.anon == "" {
		cfg.anon = ck.DEFAULT_ANON_KEY
	}
	cfg.service = os.get_env("PALM_COLLAB_SERVICE_KEY", context.allocator)
	if cfg.service == "" {
		fmt.eprintln("palm-collab: PALM_COLLAB_SERVICE_KEY is required: the log is written only by this server")
		os.exit(2)
	}
	rooms = make(map[string]^Room)

	sock, err := net.listen_tcp(net.Endpoint{address = cfg.listen, port = cfg.port})
	if err != nil {
		fmt.eprintfln("palm-collab: cannot listen on port %d: %v", cfg.port, err)
		os.exit(1)
	}
	logf("palm-collab listening on %v:%d, database at %s", cfg.listen, cfg.port, url)
	thread.create_and_start(janitor, self_cleanup = true)
	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			continue
		}
		_ = net.set_option(client, .Send_Timeout, 10 * time.Second)
		ws := new(wire.Conn)
		ws.sock = client
		thread.create_and_start_with_poly_data(ws, serve, self_cleanup = true)
	}
}
