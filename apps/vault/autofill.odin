package main

// The autofill socket: how the browser asks the vault for a login.
//
// The protocol is specified in cloud/docs/vault.md ("Autofill"); this is the
// vault's half and the reference client. In short:
//
//   $XDG_RUNTIME_DIR/palm-vault/autofill.sock   (directory 0700, socket 0600)
//   newline-delimited JSON, one request and one response per line
//
//   hello  → state, and a fresh 32-byte challenge for this connection
//   pair   → first contact only; the person approves it in the vault window
//            after comparing a six-digit code both programs show
//   auth   → HMAC-SHA256(pairing key, challenge): this connection is that pair
//   query  → candidates for (origin, identity): ids, titles, usernames. Never
//            a password.
//   fill   → one candidate's username and password (and current TOTP code),
//            after the person allows it -- once, or always for that site
//   save   → offer a new login seen in a form; the person decides
//
// What each check is for:
//
//   SO_PEERCRED   the peer is this user (not another account on the machine);
//                 its pid and /proc/<pid>/exe are shown in every prompt.
//   pairing       a program that never had the person's approval gets
//                 nothing but "locked" or "unpaired"; the key lives in the
//                 browser's profile and in a 0600 file here.
//   origin        the browser names the top-level origin it will fill; the
//                 vault returns only items whose URL matches it (same scheme,
//                 same host, or a subdomain of the stored host), never fills
//                 http with an https login, never a URL with credentials.
//   identity      the tab's identity must be the identity whose vault holds
//                 the item: a work tab cannot be filled from a personal vault.
//   confirmation  every fill asks, unless the person said "always" for that
//                 item on that origin with that pair.
//
// What it cannot stop, said in SECURITY.md: a program running as the same
// user can ptrace the browser, read its profile (and so its pairing key), or
// pose as the browser binary. Pairing and confirmation make that a visible
// act rather than a silent read; they are not a sandbox.

import "base:intrinsics"
import "core:crypto"
import "core:crypto/hmac"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:thread"
import "core:time"
import kit "kit:."
import p "palmy:."

AF_VERSION :: 1
AF_MAX_LINE :: 64 * 1024

Af_Conn :: struct {
	fd:        linux.Fd,
	pid:       i32,
	uid:       u32,
	exe:       string,
	inbuf:     [dynamic]u8,
	challenge: [32]byte,
	pair:      string, // the pair this connection proved it is, "" until auth
	alive:     bool,
}

Af_Pair :: struct {
	id:     string,
	name:   string,
	key:    [32]byte,
	always: [dynamic]string, // "item-id origin": fills allowed without asking
}

Af_Req :: struct {
	conn: int,
	line: string,
}

Af_Prompt_Kind :: enum u8 {
	None,
	Pair,
	Fill,
	Save,
	Update, // save with an id: a new password for a login the vault has
}

// A question for the person, raised by a request and answered in the window
// (or by the headless policy).
Af_Prompt :: struct {
	kind:     Af_Prompt_Kind,
	conn:     int,
	client:   string, // what the client calls itself
	exe:      string,
	pid:      i32,
	code:     string, // pairing: the code both sides show
	key:      [32]byte, // pairing: the key it offered
	origin:   string,
	identity: string,
	item_id:  string,
	title:    string,
	username: string,
	password: string, // save only; wiped when answered
}

Af_Decision :: enum u8 {
	Deny,
	Once,
	Always,
}

Af_Server :: struct {
	path:       string,
	listen:     linux.Fd,
	conns:      [dynamic]Af_Conn,
	queue:      [dynamic]Af_Req,
	pairs:      [dynamic]Af_Pair,
	pairs_path: string,
	prompt:     Af_Prompt,
	served:     int,
	running:    bool,

	// The watcher (af_watch): a thread asleep in epoll on the listening
	// socket and every connection, which wakes the window's frame loop when
	// any of them has something to read.
	watching:   bool,
	ep:         linux.Fd,
	ep_stop:    linux.Fd,
	watcher:    ^thread.Thread,
}

af_socket_path :: proc(allocator := context.allocator) -> string {
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		rt = fmt.tprintf("/tmp/palm-vault-%d", linux.getuid())
	}
	return fmt.aprintf("%s/palm-vault/autofill.sock", rt, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Pairs on disk
// ---------------------------------------------------------------------------

af_pairs_load :: proc(s: ^Af_Server) {
	raw, err := os.read_entire_file_from_path(s.pairs_path, context.temp_allocator)
	if err != nil {
		return
	}
	defer zero_bytes(raw)
	v, perr := json.parse(raw, .JSON, true, context.temp_allocator)
	if perr != .None {
		return
	}
	arr, ok := v.(json.Array)
	if !ok {
		return
	}
	for it in arr {
		o, isobj := it.(json.Object)
		if !isobj {
			continue
		}
		p := Af_Pair{always = make([dynamic]string)}
		if x, is := o["id"].(json.String); is {
			p.id = strings.clone(string(x))
		}
		if x, is := o["name"].(json.String); is {
			p.name = strings.clone(string(x))
		}
		if x, is := o["key"].(json.String); is {
			if k, kok := unb64(string(x), context.temp_allocator); kok && len(k) == 32 {
				copy(p.key[:], k)
			}
		}
		if al, is := o["always"].(json.Array); is {
			for a in al {
				if x, s2 := a.(json.String); s2 {
					append(&p.always, strings.clone(string(x)))
				}
			}
		}
		append(&s.pairs, p)
	}
}

af_pairs_save :: proc(s: ^Af_Server) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "[")
	for &p, i in s.pairs {
		fmt.sbprintf(&sb, "%s\n  {{\"id\": ", i > 0 ? "," : "")
		json_quote(&sb, p.id)
		strings.write_string(&sb, ", \"name\": ")
		json_quote(&sb, p.name)
		fmt.sbprintf(&sb, ", \"key\": \"%s\", \"always\": [", b64(p.key[:], context.temp_allocator))
		for a, j in p.always {
			if j > 0 {
				strings.write_string(&sb, ", ")
			}
			json_quote(&sb, a)
		}
		strings.write_string(&sb, "]}")
	}
	strings.write_string(&sb, "\n]\n")
	text := strings.to_string(sb)
	err := write_atomic(s.pairs_path, transmute([]byte)text)
	zero_bytes(transmute([]byte)text)
	return err
}

af_pair :: proc(s: ^Af_Server, id: string) -> ^Af_Pair {
	for &p in s.pairs {
		if p.id == id {
			return &p
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// The socket
// ---------------------------------------------------------------------------

af_start :: proc(s: ^Af_Server, path := "") -> string {
	s.path = strings.clone(path != "" ? path : af_socket_path(context.temp_allocator))
	if s.pairs_path == "" {
		s.pairs_path = strings.clone(fmt.tprintf("%s/autofill-pairs.json", data_dir(context.temp_allocator)))
	}
	// A vault opened from --vault-file elsewhere may never have created the
	// data directory; without it a pairing would be approved and then lost.
	if pdir := s.pairs_path[:max(strings.last_index_byte(s.pairs_path, '/'), 0)]; pdir != "" && !os.exists(pdir) {
		os.make_directory_all(pdir, os.perm(0o700))
	}
	af_pairs_load(s)
	dir := s.path[:strings.last_index_byte(s.path, '/')]
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		return fmt.tprintf("could not create %s", dir)
	}
	linux.chmod(strings.clone_to_cstring(dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	if len(s.path) >= 108 {
		return "the socket path is too long"
	}
	cpath := strings.clone_to_cstring(s.path, context.temp_allocator)
	linux.unlink(cpath)
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if e != .NONE {
		return fmt.tprintf("socket: %v", e)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)s.path)
	if be := linux.bind(fd, &addr); be != .NONE {
		linux.close(fd)
		return fmt.tprintf("bind %s: %v", s.path, be)
	}
	linux.chmod(cpath, {.IRUSR, .IWUSR})
	if le := linux.listen(fd, 8); le != .NONE {
		linux.close(fd)
		return fmt.tprintf("listen: %v", le)
	}
	s.listen = fd
	s.running = true
	return ""
}

af_stop :: proc(s: ^Af_Server) {
	af_unwatch(s)
	if s.running {
		linux.close(s.listen)
		linux.unlink(strings.clone_to_cstring(s.path, context.temp_allocator))
	}
	for &c in s.conns {
		if c.alive {
			linux.close(c.fd)
		}
		delete(c.inbuf)
		delete(c.exe)
	}
	delete(s.conns)
	for r in s.queue {
		delete(r.line)
	}
	delete(s.queue)
	for &p in s.pairs {
		crypto.zero_explicit(&p.key, size_of(p.key))
		delete(p.id)
		delete(p.name)
		for a in p.always {
			delete(a)
		}
		delete(p.always)
	}
	delete(s.pairs)
	af_prompt_clear(&s.prompt)
	delete(s.path)
	delete(s.pairs_path)
	s^ = {}
}

Peer_Cred :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

peer_cred :: proc(fd: linux.Fd) -> (p: Peer_Cred, ok: bool) {
	SOL_SOCKET :: 1
	SO_PEERCRED :: 17
	size := u32(size_of(Peer_Cred))
	ret := intrinsics.syscall(linux.SYS_getsockopt, uintptr(fd), SOL_SOCKET, SO_PEERCRED, uintptr(&p), uintptr(&size))
	return p, int(ret) == 0 && size == size_of(Peer_Cred)
}

proc_exe :: proc(pid: i32, allocator := context.allocator) -> string {
	buf: [4096]u8
	n, e := linux.readlink(strings.clone_to_cstring(fmt.tprintf("/proc/%d/exe", pid), context.temp_allocator), buf[:])
	if e != .NONE || n <= 0 {
		return strings.clone("?", allocator)
	}
	return strings.clone(string(buf[:n]), allocator)
}

// af_service accepts connections and reads whole lines into the queue. It
// never blocks longer than `timeout_ms` (0: not at all), so the window can
// call it every frame.
af_service :: proc(s: ^Af_Server, timeout_ms: i32 = 0) {
	if !s.running {
		return
	}
	fds := make([dynamic]linux.Poll_Fd, context.temp_allocator)
	append(&fds, linux.Poll_Fd{fd = s.listen, events = {.IN}})
	for &c in s.conns {
		if c.alive {
			append(&fds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
		}
	}
	n, _ := p.poll_fds(fds[:], int(timeout_ms)) // -1 is forever on arm64 too
	if n <= 0 {
		return
	}
	if .IN in fds[0].revents {
		for {
			cfd, ae := linux.accept(s.listen, (^linux.Sock_Addr_Un)(nil), {.CLOEXEC, .NONBLOCK})
			if ae != .NONE {
				break
			}
			cred, ok := peer_cred(cfd)
			if !ok || cred.uid != u32(linux.getuid()) {
				// Another account on this machine: no conversation at all.
				linux.close(cfd)
				continue
			}
			c := Af_Conn{fd = cfd, pid = cred.pid, uid = cred.uid, exe = proc_exe(cred.pid), alive = true}
			af_watch_fd(s, cfd)
			c.inbuf = make([dynamic]u8)
			crypto.rand_bytes(c.challenge[:])
			append(&s.conns, c)
		}
	}
	for &c, ci in s.conns {
		if !c.alive {
			continue
		}
		buf: [4096]u8
		for {
			m, re := linux.read(c.fd, buf[:])
			if re == .EAGAIN {
				break
			}
			if re != .NONE || m <= 0 {
				c.alive = false
				linux.close(c.fd)
				break
			}
			append(&c.inbuf, ..buf[:m])
			if len(c.inbuf) > AF_MAX_LINE {
				c.alive = false
				linux.close(c.fd)
				break
			}
		}
		for {
			nl := -1
			for b, i in c.inbuf {
				if b == '\n' {
					nl = i
					break
				}
			}
			if nl < 0 {
				break
			}
			append(&s.queue, Af_Req{conn = ci, line = strings.clone(string(c.inbuf[:nl]))})
			zero_bytes(c.inbuf[:nl + 1])
			remove_range(&c.inbuf, 0, nl + 1)
		}
	}
}

// af_watch starts the watcher, so the window can sleep while the socket is
// quiet and still answer a client the moment it writes.
//
// The descriptors are registered edge-triggered, and that is what keeps the
// watcher from spinning: a level-triggered descriptor would report "readable"
// again and again until the frame it woke had read it. An edge is reported
// once per arrival, and `af_service` always reads to EAGAIN (accepts to
// EAGAIN on the listener), so anything that arrives after that read is a new
// edge and a new wake. A wake for data the frame already read costs one
// frame, nothing more.
//
// Closing a connection's descriptor takes it out of the epoll set by itself.
af_watch :: proc(s: ^Af_Server, app: ^p.App) {
	if s.watching || !s.running {
		return
	}
	ep, e := linux.epoll_create1({.FDCLOEXEC})
	if e != .NONE {
		return
	}
	stop, e2 := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if e2 != .NONE {
		linux.close(ep)
		return
	}
	s.ep = ep
	s.ep_stop = stop
	s.watching = true
	ev := linux.EPoll_Event {
		events = {.IN},
		data = {fd = stop},
	}
	linux.epoll_ctl(ep, .ADD, stop, &ev)
	af_watch_fd(s, s.listen)
	for c in s.conns {
		if c.alive {
			af_watch_fd(s, c.fd)
		}
	}
	s.watcher = thread.create_and_start_with_poly_data3(ep, stop, app, proc(ep, stop: linux.Fd, app: ^p.App) {
		evs: [16]linux.EPoll_Event
		for {
			// epoll_pwait with no signal mask, not linux.epoll_wait: on arm64
			// and riscv64 that one passes a pointer to a timespec where the
			// kernel reads milliseconds, so the wait lasted however long the
			// low half of a stack address said rather than forever.
			n, err := linux.epoll_pwait(ep, &evs[0], len(evs), -1, nil)
			if err == .EINTR {
				continue
			}
			if err != .NONE {
				return
			}
			for ev in evs[:n] {
				if ev.data.fd == stop {
					return
				}
			}
			if n > 0 {
				p.wake(app)
			}
		}
	})
}

af_watch_fd :: proc(s: ^Af_Server, fd: linux.Fd) {
	if !s.watching {
		return
	}
	ev := linux.EPoll_Event {
		events = {.IN, .RDHUP, .ET},
		data = {fd = fd},
	}
	linux.epoll_ctl(s.ep, .ADD, fd, &ev)
}

af_unwatch :: proc(s: ^Af_Server) {
	if !s.watching {
		return
	}
	one := u64(1)
	linux.write(s.ep_stop, (cast([^]u8)&one)[:8])
	thread.join(s.watcher)
	thread.destroy(s.watcher)
	linux.close(s.ep)
	linux.close(s.ep_stop)
	s.watcher = nil
	s.watching = false
}

af_send :: proc(s: ^Af_Server, conn: int, text: string) {
	if conn < 0 || conn >= len(s.conns) || !s.conns[conn].alive {
		return
	}
	c := &s.conns[conn]
	line := strings.concatenate({text, "\n"}, context.temp_allocator)
	off := 0
	b := transmute([]u8)line
	tries := 0
	for off < len(b) && tries < 1000 {
		n, e := linux.write(c.fd, b[off:])
		if e == .EAGAIN {
			tries += 1
			pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.OUT}}}
			linux.poll(pfd[:], 50)
			continue
		}
		if e != .NONE || n <= 0 {
			c.alive = false
			linux.close(c.fd)
			return
		}
		off += n
	}
	zero_bytes(b)
}

// ---------------------------------------------------------------------------
// Origins
// ---------------------------------------------------------------------------

Origin_Parts :: struct {
	scheme: string,
	host:   string,
	port:   string,
	creds:  bool, // user:pass@ in it
}

origin_parse :: proc(u: string) -> (o: Origin_Parts, ok: bool) {
	s := strings.trim_space(u)
	i := strings.index(s, "://")
	if i <= 0 {
		// A bare host as people type it into a password manager.
		if s == "" || strings.contains_any(s, " /") && !strings.contains(s, ".") {
			return {}, false
		}
		s = strings.concatenate({"https://", s}, context.temp_allocator)
		i = 5
	}
	o.scheme = strings.to_lower(s[:i], context.temp_allocator)
	rest := s[i + 3:]
	if j := strings.index_any(rest, "/?#"); j >= 0 {
		rest = rest[:j]
	}
	if at := strings.last_index_byte(rest, '@'); at >= 0 {
		o.creds = true
		rest = rest[at + 1:]
	}
	if c := strings.last_index_byte(rest, ':'); c >= 0 && !strings.has_suffix(rest, "]") {
		o.port = rest[c + 1:]
		rest = rest[:c]
	}
	o.host = strings.to_lower(strings.trim_suffix(rest, "."), context.temp_allocator)
	if o.port == "443" && o.scheme == "https" || o.port == "80" && o.scheme == "http" {
		o.port = ""
	}
	return o, o.host != ""
}

// Suffixes under which a "subdomain" match would cross between unrelated
// registrants. Not the Public Suffix List -- a short list of the common
// two-label ones, so github.co.uk never matches anything.co.uk. Matching
// a subdomain is only ever allowed when the stored host has at least two
// labels and is not one of these.
@(private = "file")
SHARED_SUFFIXES := [?]string {
	"co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "co.nz",
	"com.br", "com.cn", "com.mx", "co.in", "co.za", "com.tr", "github.io", "gitlab.io", "pages.dev",
	"vercel.app", "netlify.app", "herokuapp.com", "blogspot.com", "appspot.com", "web.app", "firebaseapp.com",
}

// origin_match says whether a stored URL may be filled on the origin the
// browser names, and how closely.
origin_match :: proc(origin: string, stored: string) -> (kind: string, ok: bool) {
	o, ook := origin_parse(origin)
	t, tok := origin_parse(stored)
	if !ook || !tok || o.creds || t.creds {
		return "", false
	}
	if o.scheme != "https" && o.scheme != "http" {
		return "", false
	}
	// Never downgrade: an https login is not offered to an http page, and an
	// http login only to the exact http origin it was saved for.
	if o.scheme != t.scheme {
		return "", false
	}
	if o.port != t.port {
		return "", false
	}
	if o.host == t.host {
		return "exact", true
	}
	if strings.count(t.host, ".") >= 1 && strings.has_suffix(o.host, strings.concatenate({".", t.host}, context.temp_allocator)) {
		for suf in SHARED_SUFFIXES {
			if t.host == suf {
				return "", false
			}
		}
		return "subdomain", true
	}
	return "", false
}

entry_origin_match :: proc(e: ^Entry, origin: string) -> (string, bool) {
	if e.kind == .Note || e.kind == .Card || e.kind == .Document {
		return "", false
	}
	best := ""
	if k, ok := origin_match(origin, e.url); ok {
		best = k
	}
	for u in e.urls {
		if k, ok := origin_match(origin, u); ok && (best == "" || k == "exact") {
			best = k
		}
	}
	return best, best != ""
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

@(private = "file")
js :: proc(o: json.Object, k: string) -> string {
	if x, ok := o[k].(json.String); ok {
		return string(x)
	}
	return ""
}

af_err :: proc(msg: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{\"ok\": false, \"error\": ")
	json_quote(&sb, msg)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

af_prompt_clear :: proc(p: ^Af_Prompt) {
	wipe_string(p.password)
	crypto.zero_explicit(&p.key, size_of(p.key))
	delete(p.client)
	delete(p.exe)
	delete(p.code)
	delete(p.origin)
	delete(p.identity)
	delete(p.item_id)
	delete(p.title)
	delete(p.username)
	p^ = {}
}

pair_code :: proc(key: []byte) -> string {
	h := sha256_tagged("palm-vault/autofill-pair/v1", key)
	v := (u32(h[0]) << 24 | u32(h[1]) << 16 | u32(h[2]) << 8 | u32(h[3])) % 1_000_000
	return fmt.aprintf("%03d %03d", v / 1000, v % 1000)
}

// af_identity_ok says whether entry `e` belongs to the identity the tab is in.
af_identity_ok :: proc(b: ^Book, e: ^Entry, identity: string) -> bool {
	if b.mode == .Local {
		// The local file belongs to whoever unlocked it; it has no identities.
		return true
	}
	h, _ := book_label(b, e)
	return h == identity
}

// af_handle answers one request. A request that needs the person's answer
// raises s.prompt and returns ""; af_decide sends the answer later.
af_handle :: proc(s: ^Af_Server, b: ^Book, r: Af_Req) -> string {
	c := &s.conns[r.conn]
	v, perr := json.parse_string(r.line, .JSON, true, context.temp_allocator)
	if perr != .None {
		return af_err("not JSON")
	}
	o, isobj := v.(json.Object)
	if !isobj {
		return af_err("not an object")
	}
	op := js(o, "op")
	unlocked := book_is_open(b)
	sb := strings.builder_make(context.temp_allocator)
	switch op {
	case "hello":
		fmt.sbprintf(&sb, "{{\"ok\": true, \"vault\": \"palm-vault\", \"version\": %d, \"state\": \"%s\", \"challenge\": \"%s\"}}",
			AF_VERSION, unlocked ? "unlocked" : "locked", b64(c.challenge[:], context.temp_allocator))
		return strings.to_string(sb)
	case "pair":
		key, ok := unb64(js(o, "key"), context.temp_allocator)
		if !ok || len(key) != 32 {
			return af_err("a pairing key is 32 bytes, base64")
		}
		if s.prompt.kind != .None {
			return af_err("busy: another request is waiting for an answer")
		}
		af_prompt_clear(&s.prompt)
		s.prompt = Af_Prompt {
			kind   = .Pair,
			conn   = r.conn,
			client = strings.clone(js(o, "name")),
			exe    = strings.clone(c.exe),
			pid    = c.pid,
			code   = pair_code(key),
		}
		copy(s.prompt.key[:], key)
		return ""
	case "auth":
		p := af_pair(s, js(o, "pair_id"))
		proof, ok := unb64(js(o, "proof"), context.temp_allocator)
		if p == nil || !ok || len(proof) != 32 {
			return af_err("unpaired")
		}
		want: [32]byte
		hmac.sum(.SHA256, want[:], c.challenge[:], p.key[:])
		if crypto.compare_constant_time(want[:], proof) != 1 {
			return af_err("unpaired")
		}
		c.pair = p.id
		// A challenge answers once: a replayed proof on this connection, or
		// any other, is worth nothing.
		crypto.rand_bytes(c.challenge[:])
		return "{\"ok\": true}"
	}

	if c.pair == "" {
		return af_err("unpaired")
	}
	origin := js(o, "origin")
	identity := js(o, "identity")
	if _, ook := origin_parse(origin); !ook && op != "state" {
		return af_err("no origin")
	}
	switch op {
	case "state":
		fmt.sbprintf(&sb, "{{\"ok\": true, \"state\": \"%s\"}}", unlocked ? "unlocked" : "locked")
		return strings.to_string(sb)
	case "query":
		fmt.sbprintf(&sb, "{{\"ok\": true, \"state\": \"%s\", \"candidates\": [", unlocked ? "unlocked" : "locked")
		n := 0
		if unlocked {
			for &e in b.v.entries {
				kind, ok := entry_origin_match(&e, origin)
				if !ok || !af_identity_ok(b, &e, identity) {
					continue
				}
				strings.write_string(&sb, n > 0 ? ", " : "")
				strings.write_string(&sb, "{\"id\": ")
				json_quote(&sb, e.id)
				strings.write_string(&sb, ", \"title\": ")
				json_quote(&sb, e.title)
				strings.write_string(&sb, ", \"username\": ")
				json_quote(&sb, e.username)
				fmt.sbprintf(&sb, ", \"match\": \"%s\", \"totp\": %v}}", kind, e.totp != "")
				n += 1
			}
		}
		strings.write_string(&sb, "]}")
		return strings.to_string(sb)
	case "fill":
		if !unlocked {
			return af_err("locked")
		}
		id := js(o, "id")
		for &e in b.v.entries {
			if e.id != id {
				continue
			}
			if _, ok := entry_origin_match(&e, origin); !ok {
				return af_err("that login is not for this origin")
			}
			if !af_identity_ok(b, &e, identity) {
				return af_err("that login belongs to another identity")
			}
			p := af_pair(s, c.pair)
			key := fmt.tprintf("%s %s", e.id, origin)
			for a in p.always {
				if a == key {
					return af_fill_answer(s, &e)
				}
			}
			if s.prompt.kind != .None {
				return af_err("busy: another request is waiting for an answer")
			}
			s.prompt = Af_Prompt {
				kind     = .Fill,
				conn     = r.conn,
				client   = strings.clone(p.name),
				exe      = strings.clone(c.exe),
				pid      = c.pid,
				origin   = strings.clone(origin),
				identity = strings.clone(identity),
				item_id  = strings.clone(e.id),
				title    = strings.clone(e.title),
				username = strings.clone(e.username),
			}
			return ""
		}
		return af_err("no such login")
	case "save":
		if !unlocked {
			return af_err("locked")
		}
		if s.prompt.kind != .None {
			return af_err("busy: another request is waiting for an answer")
		}
		p := af_pair(s, c.pair)
		if id := js(o, "id"); id != "" {
			// An update: the browser saw a new password submitted for a login
			// it filled or matched. The same bindings as a fill -- the item's
			// origin and identity -- and the person decides.
			for &e in b.v.entries {
				if e.id != id {
					continue
				}
				if _, ok := entry_origin_match(&e, origin); !ok {
					return af_err("that login is not for this origin")
				}
				if !af_identity_ok(b, &e, identity) {
					return af_err("that login belongs to another identity")
				}
				if js(o, "password") == "" {
					return af_err("no password")
				}
				user := js(o, "username")
				s.prompt = Af_Prompt {
					kind     = .Update,
					conn     = r.conn,
					client   = strings.clone(p.name),
					exe      = strings.clone(c.exe),
					pid      = c.pid,
					origin   = strings.clone(origin),
					identity = strings.clone(identity),
					item_id  = strings.clone(e.id),
					title    = strings.clone(e.title),
					username = strings.clone(user != "" ? user : e.username),
					password = strings.clone(js(o, "password")),
				}
				return ""
			}
			return af_err("no such login")
		}
		s.prompt = Af_Prompt {
			kind     = .Save,
			conn     = r.conn,
			client   = strings.clone(p.name),
			exe      = strings.clone(c.exe),
			pid      = c.pid,
			origin   = strings.clone(origin),
			identity = strings.clone(identity),
			title    = strings.clone(js(o, "title") != "" ? js(o, "title") : host_of(origin)),
			username = strings.clone(js(o, "username")),
			password = strings.clone(js(o, "password")),
		}
		return ""
	}
	return af_err("unknown op")
}

af_fill_answer :: proc(s: ^Af_Server, e: ^Entry) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{\"ok\": true, \"username\": ")
	json_quote(&sb, e.username)
	strings.write_string(&sb, ", \"password\": ")
	json_quote(&sb, e.password)
	if code, ok := totp_code(e.totp, now_unix(), e.totp_period, int(e.totp_digits), e.totp_algo); ok {
		fmt.sbprintf(&sb, ", \"totp\": \"%s\"", code)
	}
	strings.write_string(&sb, "}")
	s.served += 1
	return strings.to_string(sb)
}

// af_decide answers the pending prompt.
af_decide :: proc(s: ^Af_Server, b: ^Book, d: Af_Decision) {
	pr := &s.prompt
	defer af_prompt_clear(pr)
	resp := af_err("denied")
	switch pr.kind {
	case .None:
		return
	case .Pair:
		if d != .Deny {
			p := Af_Pair{id = new_uuid(), name = strings.clone(pr.client != "" ? pr.client : "a program"), always = make([dynamic]string)}
			p.key = pr.key
			append(&s.pairs, p)
			if err := af_pairs_save(s); err != "" {
				fmt.eprintfln("vault: the pairing holds until this process exits; it could not be kept: %s", err)
			}
			resp = fmt.tprintf("{{\"ok\": true, \"pair_id\": \"%s\"}}", p.id)
		}
	case .Fill:
		if d != .Deny {
			for &e in b.v.entries {
				if e.id == pr.item_id {
					if d == .Always {
						if c := pr.conn; c >= 0 && c < len(s.conns) {
							if p := af_pair(s, s.conns[c].pair); p != nil {
								append(&p.always, fmt.aprintf("%s %s", e.id, pr.origin))
								af_pairs_save(s)
							}
						}
					}
					resp = af_fill_answer(s, &e)
				}
			}
		}
	case .Save:
		if d != .Deny {
			e := entry_new(pr.title)
			replace_string(&e.username, pr.username)
			replace_string(&e.url, pr.origin)
			entry_set_password(&e, pr.password)
			target := -1
			if b.mode == .Account {
				for src, i in b.acct.sources {
					if src.kind == .Own && handle_of(b.acct, src.viewer) == pr.identity {
						target = i
						break
					}
				}
			}
			if _, err := book_add(b, e, target); err == "" {
				resp = "{\"ok\": true, \"saved\": true}"
			} else {
				resp = af_err(err)
			}
		}
	case .Update:
		if d != .Deny {
			resp = af_err("no such login")
			for &e, i in b.v.entries {
				if e.id != pr.item_id {
					continue
				}
				entry_set_password(&e, pr.password)
				if pr.username != "" && pr.username != e.username {
					replace_string(&e.username, pr.username)
				}
				if err := book_commit(b, i); err == "" {
					resp = "{\"ok\": true, \"saved\": true, \"updated\": true}"
				} else {
					resp = af_err(err)
				}
				break
			}
		}
	}
	af_send(s, pr.conn, resp)
}

// af_pump is one turn of the headless server: read, answer, and settle any
// prompt by `policy` (Deny, or Once for tests and scripted demos).
af_pump :: proc(s: ^Af_Server, b: ^Book, policy: Af_Decision, timeout_ms: i32 = 100) {
	af_service(s, timeout_ms)
	for len(s.queue) > 0 {
		r := pop_front(&s.queue)
		resp := af_handle(s, b, r)
		zero_bytes(transmute([]u8)r.line)
		delete(r.line)
		if resp != "" {
			af_send(s, r.conn, resp)
		} else if s.prompt.kind != .None {
			af_decide(s, b, policy)
		}
	}
}

// ---------------------------------------------------------------------------
// The reference client: what the browser does
// ---------------------------------------------------------------------------

Af_Client :: struct {
	fd:  linux.Fd,
	buf: [dynamic]u8,
}

af_dial :: proc(path: string) -> (c: Af_Client, err: string) {
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return {}, fmt.tprintf("socket: %v", e)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)
	if ce := linux.connect(fd, &addr); ce != .NONE {
		linux.close(fd)
		return {}, fmt.tprintf("the vault is not running (connect %s: %v)", path, ce)
	}
	return Af_Client{fd = fd, buf = make([dynamic]u8)}, ""
}

af_close :: proc(c: ^Af_Client) {
	linux.close(c.fd)
	zero_bytes(c.buf[:])
	delete(c.buf)
}

// af_call sends one line and waits for one line back.
af_call :: proc(c: ^Af_Client, req: string, pump: proc(rawptr) = nil, pump_data: rawptr = nil) -> (resp: json.Object, raw: string, err: string) {
	line := strings.concatenate({req, "\n"}, context.temp_allocator)
	if _, e := linux.write(c.fd, transmute([]u8)line); e != .NONE {
		return nil, "", "the vault closed the connection"
	}
	for {
		for b, i in c.buf {
			if b == '\n' {
				raw = strings.clone(string(c.buf[:i]), context.temp_allocator)
				zero_bytes(c.buf[:i + 1])
				remove_range(&c.buf, 0, i + 1)
				v, perr := json.parse_string(raw, .JSON, true, context.temp_allocator)
				if perr != .None {
					return nil, raw, "the vault answered something that is not JSON"
				}
				o, _ := v.(json.Object)
				return o, raw, ""
			}
		}
		if pump != nil {
			// In-process tests run the server between reads.
			pump(pump_data)
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		n, _ := linux.poll(pfd[:], pump != nil ? 10 : 120_000)
		if n <= 0 {
			if pump != nil {
				continue
			}
			return nil, "", "the vault did not answer"
		}
		tmp: [4096]u8
		m, e := linux.read(c.fd, tmp[:])
		if e != .NONE || m <= 0 {
			return nil, "", "the vault closed the connection"
		}
		append(&c.buf, ..tmp[:m])
	}
}

af_req :: proc(pairs: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{")
	for i := 0; i + 1 < len(pairs); i += 2 {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		json_quote(&sb, pairs[i])
		strings.write_string(&sb, ": ")
		json_quote(&sb, pairs[i + 1])
	}
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

af_proof :: proc(key: []byte, challenge_b64: string) -> string {
	ch, ok := unb64(challenge_b64, context.temp_allocator)
	if !ok {
		return ""
	}
	mac: [32]byte
	hmac.sum(.SHA256, mac[:], ch, key)
	return b64(mac[:], context.temp_allocator)
}

// ---------------------------------------------------------------------------
// The CLI verbs
// ---------------------------------------------------------------------------

cmd_autofill :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	// --locked serves a vault nobody has unlocked: what the browser sees
	// while the window sits at its lock screen.
	locked := kit.cli_bool(c, "locked")
	if code := open_book(c, &b, !locked); code != kit.EXIT_OK {
		return code
	}
	policy := kit.cli_str(c, "allow") == "once" ? Af_Decision.Once : Af_Decision.Deny
	if policy == .Once {
		kit.cli_note(c, "vault: --allow once answers every pairing and fill with yes, with nobody asked. For tests and demos only.")
	}
	// --delay holds each question open that long before answering, the way a
	// person takes a moment: the browser's waiting states can be seen.
	delay_ms := kit.cli_int(c, "delay", 0)
	s: Af_Server
	if err := af_start(&s, kit.cli_str(c, "socket")); err != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	defer af_stop(&s)
	kit.cli_note(c, "vault: autofill listening on %s", s.path)
	limit := kit.cli_int(c, "max-requests", 0)
	handled := 0
	asked: time.Tick
	offline := kit.cli_bool(c, "offline")
	// what was saved or updated goes to the server at once, as the window does
	decide :: proc(s: ^Af_Server, b: ^Book, policy: Af_Decision, offline: bool) {
		saving := s.prompt.kind == .Save || s.prompt.kind == .Update
		af_decide(s, b, policy)
		if saving && policy != .Deny && b.mode == .Account && !offline {
			if _, err := book_sync(b); err != "" {
				fmt.eprintfln("vault: saved on this device; not yet synced (%s)", err)
			}
		}
	}
	for limit == 0 || handled < limit || s.prompt.kind != .None {
		af_service(&s, s.prompt.kind != .None ? 20 : 200)
		if s.prompt.kind != .None && time.duration_milliseconds(time.tick_since(asked)) >= f64(delay_ms) {
			decide(&s, &b, policy, offline)
		}
		for len(s.queue) > 0 && s.prompt.kind == .None {
			r := pop_front(&s.queue)
			resp := af_handle(&s, &b, r)
			zero_bytes(transmute([]u8)r.line)
			delete(r.line)
			if resp != "" {
				af_send(&s, r.conn, resp)
			} else if s.prompt.kind != .None {
				asked = time.tick_now()
				if delay_ms <= 0 {
					decide(&s, &b, policy, offline)
				}
			}
			handled += 1
		}
		free_all(context.temp_allocator)
	}
	kit.jset_int(c.out, "served", s.served)
	return kit.EXIT_OK
}

cmd_autofill_client :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "socket")
	if path == "" {
		path = af_socket_path(context.temp_allocator)
	}
	pair_file := kit.cli_str(c, "pair-file")
	if pair_file == "" {
		pair_file = fmt.tprintf("%s/autofill-client.json", data_dir(context.temp_allocator))
	}
	cl, err := af_dial(path)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	defer af_close(&cl)
	hello, _, herr := af_call(&cl, af_req("op", "hello", "client", "vault autofill-client"))
	if herr != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, herr)
	}
	challenge := ""
	if x, ok := hello["challenge"].(json.String); ok {
		challenge = string(x)
	}

	// Pairing: the first time, generate a key, ask, and keep the answer.
	pair_id := ""
	key: [32]byte
	if raw, rerr := os.read_entire_file_from_path(pair_file, context.temp_allocator); rerr == nil {
		if v, perr := json.parse(raw, .JSON, true, context.temp_allocator); perr == .None {
			if o, ok := v.(json.Object); ok {
				if x, is := o["pair_id"].(json.String); is {
					pair_id = string(x)
				}
				if x, is := o["key"].(json.String); is {
					if k, kok := unb64(string(x), context.temp_allocator); kok && len(k) == 32 {
						copy(key[:], k)
					}
				}
			}
		}
	}
	if pair_id == "" {
		crypto.rand_bytes(key[:])
		kit.cli_note(c, "vault autofill-client: asking the vault to pair; the code is %s", pair_code(key[:]))
		resp, _, perr := af_call(&cl, af_req("op", "pair", "name", "vault autofill-client", "key", b64(key[:], context.temp_allocator)))
		if perr != "" {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, perr)
		}
		if x, ok := resp["pair_id"].(json.String); ok {
			pair_id = strings.clone(string(x), context.temp_allocator)
		} else {
			return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "the vault did not approve pairing")
		}
		text := fmt.tprintf("{{\"pair_id\": \"%s\", \"key\": \"%s\"}}\n", pair_id, b64(key[:], context.temp_allocator))
		write_atomic(pair_file, transmute([]byte)text)
	}
	resp, _, aerr := af_call(&cl, af_req("op", "auth", "pair_id", pair_id, "proof", af_proof(key[:], challenge)))
	if aerr != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, aerr)
	}
	if ok, _ := resp["ok"].(json.Boolean); !ok {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "the vault refused the pairing key")
	}
	origin := kit.cli_str(c, "origin")
	ident := kit.cli_str(c, "identity-of-tab")
	q, _, qerr := af_call(&cl, af_req("op", "query", "origin", origin, "identity", ident))
	if qerr != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, qerr)
	}
	state := ""
	if x, ok := q["state"].(json.String); ok {
		state = string(x)
	}
	kit.jset_str(c.out, "state", state)
	arr := kit.jarr()
	if cands, ok := q["candidates"].(json.Array); ok {
		for x in cands {
			o, _ := x.(json.Object)
			j := kit.jobj()
			for k in ([?]string{"id", "title", "username", "match"}) {
				if s, is := o[k].(json.String); is {
					kit.jset_str(j, k, string(s))
				}
			}
			kit.jpush(arr, j)
		}
	}
	kit.jset(c.out, "candidates", arr)
	if id := kit.cli_str(c, "fill"); id != "" {
		f, _, ferr := af_call(&cl, af_req("op", "fill", "id", id, "origin", origin, "identity", ident))
		if ferr != "" {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, ferr)
		}
		ok, _ := f["ok"].(json.Boolean)
		kit.jset_bool(c.out, "filled", bool(ok))
		if ok {
			// What a browser would type into the focused fields. The test
			// client says that it got them and how long they are; it does not
			// print them.
			pw := ""
			if x, is := f["password"].(json.String); is {
				pw = string(x)
			}
			kit.cli_note(c, "vault autofill-client: received a %d-character password for this origin", len(pw))
		} else if x, is := f["error"].(json.String); is {
			kit.cli_note(c, "vault autofill-client: %s", string(x))
		}
	}
	crypto.zero_explicit(&key, size_of(key))
	return kit.EXIT_OK
}
