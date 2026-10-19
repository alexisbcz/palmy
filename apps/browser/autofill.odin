// Autofill: the browser's half of the vault's autofill protocol
// (cloud/docs/vault.md, "Autofill"), and the chrome around it.
//
//   the page          engine/autofill.js, run by each engine host where page
//                     script cannot reach it, reports a login field taking
//                     focus (PB_FIELD_FOCUS) and a form submitted with a
//                     password (PB_FORM_SUBMIT), and fills on PB_FILL.
//   the vault         apps/vault serves $XDG_RUNTIME_DIR/palm-vault/
//                     autofill.sock: hello, pair, auth, query, fill, save.
//                     This file's worker thread is the client; it is the
//                     only thing in the browser that talks to the vault.
//   the chrome        the dropdown under the field, the pairing code, the
//                     "Save this login?" bar, the key in the address bar.
//
// What the chrome never does: cache a password (a fill's values go from the
// vault's answer to the engine and are wiped), log one, or name an origin the
// engine did not report for the view's top level. The tab's identity is the
// profile's identity handle.
package browser

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import kit "kit:."
import pb "pb"
import p "palmy:."
import sc "shadcn:."

ICON_KEY :: p.Icon{name = "key", d = "M2 15.5 C2 12.462 4.462 10 7.5 10 C10.538 10 13 12.462 13 15.5 C13 18.538 10.538 21 7.5 21 C4.462 21 2 18.538 2 15.5 Z M21 2 L11.4 11.6 M15.5 7.5 L18.5 10.5 L22 7 L19 4", view = 24, stroke = 2}

// What the browser knows of the vault.
Af_Vault :: enum u8 {
	Unknown,
	Not_Running, // nothing listens on the socket
	Unpaired, // it runs, this profile has no pairing (or a stale one)
	Pairing, // a pairing is waiting for the person
	Locked,
	Unlocked,
}

Af_Candidate :: struct {
	id:       string,
	title:    string,
	username: string,
	exact:    bool,
	totp:     bool,
}

Af_Job_Kind :: enum u8 {
	Query,
	Fill,
	Save,
	Pair,
}

Af_Job :: struct {
	kind:     Af_Job_Kind,
	seq:      int,
	view:     int,
	origin:   string,
	identity: string,
	id:       string, // Fill, Save (an update)
	username: string, // Save
	password: string, // Save: wiped when the job is done
	title:    string, // Save
}

Af_Result :: struct {
	kind:       Af_Job_Kind,
	seq:        int,
	view:       int,
	origin:     string,
	ok:         bool,
	interim:    bool, // Pair: the code, while the vault asks the person
	error:      string,
	state:      Af_Vault,
	candidates: [dynamic]Af_Candidate,
	username:   string, // Fill
	password:   string, // Fill: wiped as soon as it is handed to the engine
	totp:       string, // Fill
	code:       string, // Pair
	updated:    bool, // Save
}

// The worker owns the connection; the UI thread only queues jobs and takes
// results, so a vault waiting for the person never stalls a frame.
Af_Worker :: struct {
	lock:      sync.Mutex,
	cond:      sync.Cond,
	jobs:      [dynamic]Af_Job,
	results:   [dynamic]Af_Result,
	quit:      bool,
	th:        ^thread.Thread,
	wake:      ^p.App,
	sock_path: string,
	pair_path: string,
	// the worker's own
	fd:        linux.Fd,
	connected: bool,
	authed:    bool,
	state:     Af_Vault,
	inbuf:     [dynamic]u8,
}

// The tab's last fill: which login, and an HMAC of the password under a key
// that lives only in this process, so a later submit can be recognised as
// "the same password" without the password being kept.
Af_Filled :: struct {
	view:    int,
	item:    string,
	origin:  string,
	mac:     [32]u8,
	at:      time.Tick,
}

Af_Bar :: struct {
	active:   bool,
	update:   bool,
	view:     int,
	origin:   string,
	username: string,
	password: string, // kept for the bar's life only; wiped when it closes
	item:     string,
	title:    string,
	waiting:  bool, // the vault is asking the person
	sel:      int, // 0 the main button, 1 "Not now"
	seq:      int,
}

Autofill :: struct {
	worker:     ^Af_Worker,
	vault:      Af_Vault,
	identity:   string, // the identity handle the vault knows this profile as
	seq:        int,
	// the dropdown
	open:       bool,
	armed:      bool, // a field has focus but the person has not asked yet
	from_omni:  bool, // opened from the address bar's key
	view:       int,
	origin:     string,
	kind:       pb.Field_Kind,
	rect:       [4]f32, // the field, in view coordinates
	sel:        int,
	rows:       int,
	enter:      bool,
	drop_rect:  p.Rect,
	drop_id:    u64,
	// what the vault said for `cand_origin`
	candidates: [dynamic]Af_Candidate,
	cand_origin: string,
	cand_view:  int,
	query_seq:  int,
	busy:       bool, // a fill is waiting for the vault's answer
	fill_seq:   int,
	fill_item:  string, // the login the pending fill is for
	pair_code:  string,
	pair_seq:   int,
	last_input: time.Tick, // the person's last key or click into the page
	mac_key:    [32]u8,
	filled:     [dynamic]Af_Filled,
	bar:        Af_Bar,
	note:       string,
	// for the harness: what happened, in order
	trace:      [dynamic]string,
}

// ---------------------------------------------------------------------------
// The worker: the vault protocol
// ---------------------------------------------------------------------------

af_socket_path :: proc(allocator := context.allocator) -> string {
	if s := os.get_env("PALM_VAULT_SOCKET", context.temp_allocator); s != "" {
		return strings.clone(s, allocator)
	}
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		rt = fmt.tprintf("/tmp/palm-vault-%d", linux.getuid())
	}
	return fmt.aprintf("%s/palm-vault/autofill.sock", rt, allocator = allocator)
}

// af_pair_code is the six digits both programs show: SHA-256 of a fixed
// label and the key, first four bytes big-endian, mod 10^6.
af_pair_code :: proc(key: []u8, allocator := context.allocator) -> string {
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	label := "palm-vault/autofill-pair/v1"
	hash.update(&ctx, transmute([]u8)label)
	hash.update(&ctx, key)
	h: [32]u8
	hash.final(&ctx, h[:])
	v := (u32(h[0]) << 24 | u32(h[1]) << 16 | u32(h[2]) << 8 | u32(h[3])) % 1_000_000
	return fmt.aprintf("%03d %03d", v / 1000, v % 1000, allocator = allocator)
}

@(private = "file")
jq_into :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case 0 ..< 0x20:
			fmt.sbprintf(sb, "\\u%04x", c)
		case:
			strings.write_byte(sb, c)
		}
	}
	strings.write_byte(sb, '"')
}

// af_req builds one request line from key/value pairs.
af_req :: proc(pairs: ..string) -> strings.Builder {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{")
	for i := 0; i + 1 < len(pairs); i += 2 {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		jq_into(&sb, pairs[i])
		strings.write_string(&sb, ": ")
		jq_into(&sb, pairs[i + 1])
	}
	strings.write_string(&sb, "}\n")
	return sb
}

@(private = "file")
w_close :: proc(w: ^Af_Worker) {
	if w.connected {
		linux.close(w.fd)
	}
	w.connected = false
	w.authed = false
	pb.wipe(w.inbuf[:])
	clear(&w.inbuf)
}

@(private = "file")
w_dial :: proc(w: ^Af_Worker) -> bool {
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return false
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	if len(w.sock_path) >= len(addr.sun_path) {
		linux.close(fd)
		return false
	}
	copy(addr.sun_path[:], transmute([]u8)w.sock_path)
	if ce := linux.connect(fd, &addr); ce != .NONE {
		linux.close(fd)
		return false
	}
	w.fd = fd
	w.connected = true
	return true
}

// w_call sends one line and waits for one line back. `wait_ms` bounds the
// wait: a fill or a pairing waits for a person, a query does not.
@(private = "file")
w_call :: proc(w: ^Af_Worker, line: ^strings.Builder, wait_ms: int) -> (resp: json.Object, ok: bool) {
	defer pb.wipe(line.buf[:])
	b := line.buf[:]
	off := 0
	for off < len(b) {
		n, e := linux.send(w.fd, b[off:], {.NOSIGNAL})
		if e == .EINTR {
			continue
		}
		if e != .NONE || n <= 0 {
			w_close(w)
			return nil, false
		}
		off += n
	}
	start := time.tick_now()
	for {
		for c, i in w.inbuf {
			if c == '\n' {
				raw := strings.clone(string(w.inbuf[:i]), context.temp_allocator)
				pb.wipe(w.inbuf[:i + 1])
				remove_range(&w.inbuf, 0, i + 1)
				v, perr := json.parse_string(raw, .JSON, true, context.temp_allocator)
				pb.wipe(transmute([]u8)raw)
				if perr != .None {
					return nil, false
				}
				o, isobj := v.(json.Object)
				return o, isobj
			}
		}
		left := wait_ms - int(time.duration_milliseconds(time.tick_since(start)))
		if left <= 0 {
			w_close(w)
			return nil, false
		}
		pfd := [1]linux.Poll_Fd{{fd = w.fd, events = {.IN}}}
		n, pe := linux.poll(pfd[:], i32(min(left, 250)))
		if pe == .EINTR || n == 0 {
			sync.mutex_lock(&w.lock)
			quit := w.quit
			sync.mutex_unlock(&w.lock)
			if quit {
				w_close(w)
				return nil, false
			}
			continue
		}
		tmp: [4096]u8
		m, re := linux.read(w.fd, tmp[:])
		if re != .NONE || m <= 0 {
			w_close(w)
			return nil, false
		}
		append(&w.inbuf, ..tmp[:m])
		mem.zero_explicit(&tmp, size_of(tmp))
	}
}

@(private = "file")
jget_s :: proc(o: json.Object, k: string) -> string {
	if x, ok := o[k].(json.String); ok {
		return string(x)
	}
	return ""
}
@(private = "file")
jget_b :: proc(o: json.Object, k: string) -> bool {
	if x, ok := o[k].(json.Boolean); ok {
		return bool(x)
	}
	return false
}

Af_Pairing :: struct {
	pair_id: string,
	key:     [32]u8,
}

af_pair_load :: proc(path: string) -> (pr: Af_Pairing, ok: bool) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	defer pb.wipe(raw)
	v, perr := json.parse(raw, .JSON, true, context.temp_allocator)
	if perr != .None {
		return {}, false
	}
	o, isobj := v.(json.Object)
	if !isobj {
		return {}, false
	}
	pr.pair_id = strings.clone(jget_s(o, "pair_id"), context.temp_allocator)
	k, kerr := base64.decode(jget_s(o, "key"), allocator = context.temp_allocator)
	if kerr != nil || len(k) != 32 || pr.pair_id == "" {
		return {}, false
	}
	copy(pr.key[:], k)
	pb.wipe(k)
	return pr, true
}

af_pair_save :: proc(path: string, pr: Af_Pairing) -> bool {
	key := pr.key
	k, _ := base64.encode(key[:], allocator = context.temp_allocator)
	text := fmt.tprintf("{{\"pair_id\": \"%s\", \"key\": \"%s\"}}\n", pr.pair_id, k)
	defer pb.wipe(transmute([]u8)text)
	// 0600 from the first byte: written beside it, then renamed
	tmp := fmt.tprintf("%s.tmp-%d", path, os.get_pid())
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if err != nil {
		return false
	}
	_, werr := os.write(f, transmute([]u8)text)
	os.close(f)
	if werr != nil || os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// w_ensure connects and authenticates with the stored pairing, and says
// where that leaves us.
@(private = "file")
w_ensure :: proc(w: ^Af_Worker) -> Af_Vault {
	if w.connected && w.authed {
		return w.state
	}
	w_close(w)
	if !w_dial(w) {
		return .Not_Running
	}
	hello := af_req("op", "hello", "client", "Palmframe Browser")
	h, ok := w_call(w, &hello, 5000)
	if !ok {
		return .Not_Running
	}
	state := jget_s(h, "state") == "unlocked" ? Af_Vault.Unlocked : Af_Vault.Locked
	challenge := jget_s(h, "challenge")
	pr, pok := af_pair_load(w.pair_path)
	if !pok {
		return .Unpaired
	}
	defer crypto.zero_explicit(&pr.key, size_of(pr.key))
	ch, cerr := base64.decode(challenge, allocator = context.temp_allocator)
	if cerr != nil {
		return .Unpaired
	}
	mac: [32]u8
	hmac.sum(.SHA256, mac[:], ch, pr.key[:])
	proof, _ := base64.encode(mac[:], allocator = context.temp_allocator)
	auth := af_req("op", "auth", "pair_id", pr.pair_id, "proof", proof)
	a, aok := w_call(w, &auth, 5000)
	if !aok {
		return .Not_Running
	}
	if !jget_b(a, "ok") {
		w_close(w)
		return .Unpaired
	}
	w.authed = true
	w.state = state
	return state
}

@(private = "file")
w_post :: proc(w: ^Af_Worker, r: Af_Result) {
	sync.mutex_lock(&w.lock)
	append(&w.results, r)
	sync.mutex_unlock(&w.lock)
	if w.wake != nil {
		p.wake(w.wake)
	}
}

@(private = "file")
w_state_of :: proc(o: json.Object) -> Af_Vault {
	return jget_s(o, "state") == "unlocked" ? .Unlocked : .Locked
}

@(private = "file")
w_run :: proc(w: ^Af_Worker, j: ^Af_Job) {
	r := Af_Result {
		kind   = j.kind,
		seq    = j.seq,
		view   = j.view,
		origin = strings.clone(j.origin),
	}
	switch j.kind {
	case .Pair:
		// a fresh connection and a fresh key; the code goes to the window
		// at once, the answer when the person gives it
		w_close(w)
		if !w_dial(w) {
			r.state = .Not_Running
			r.error = strings.clone("Passwords is not running")
			break
		}
		hello := af_req("op", "hello", "client", "Palmframe Browser")
		if _, ok := w_call(w, &hello, 5000); !ok {
			r.state = .Not_Running
			break
		}
		pr: Af_Pairing
		crypto.rand_bytes(pr.key[:])
		code := af_pair_code(pr.key[:])
		w_post(w, Af_Result{kind = .Pair, seq = j.seq, interim = true, code = code, state = .Pairing})
		k, _ := base64.encode(pr.key[:], allocator = context.temp_allocator)
		req := af_req("op", "pair", "name", "Palmframe Browser", "key", k)
		resp, ok := w_call(w, &req, 300_000)
		if !ok {
			r.state = .Unpaired
			r.error = strings.clone("Passwords did not answer")
		} else if id := jget_s(resp, "pair_id"); id != "" {
			pr.pair_id = id
			if af_pair_save(w.pair_path, pr) {
				r.ok = true
			} else {
				r.error = strings.clone("could not keep the pairing")
			}
		} else {
			r.state = .Unpaired
			r.error = strings.clone("Passwords did not pair")
		}
		crypto.zero_explicit(&pr.key, size_of(pr.key))
		w_close(w)
		if r.ok {
			r.state = w_ensure(w)
		}
	case .Query:
		r.state = w_ensure(w)
		if r.state == .Locked || r.state == .Unlocked {
			req := af_req("op", "query", "origin", j.origin, "identity", j.identity)
			resp, ok := w_call(w, &req, 10_000)
			if !ok {
				r.state = .Not_Running
				break
			}
			r.ok = jget_b(resp, "ok")
			r.state = w_state_of(resp)
			if arr, aok := resp["candidates"].(json.Array); aok {
				for x in arr {
					o, _ := x.(json.Object)
					append(&r.candidates, Af_Candidate {
						id       = strings.clone(jget_s(o, "id")),
						title    = strings.clone(jget_s(o, "title")),
						username = strings.clone(jget_s(o, "username")),
						exact    = jget_s(o, "match") == "exact",
						totp     = jget_b(o, "totp"),
					})
				}
			}
			if !r.ok {
				r.error = strings.clone(jget_s(resp, "error"))
			}
		}
	case .Fill:
		r.state = w_ensure(w)
		if r.state != .Unlocked && r.state != .Locked {
			r.error = strings.clone(r.state == .Unpaired ? "this browser is not paired with Passwords" : "Passwords is not running")
			break
		}
		req := af_req("op", "fill", "id", j.id, "origin", j.origin, "identity", j.identity)
		resp, ok := w_call(w, &req, 300_000)
		if !ok {
			r.error = strings.clone("Passwords did not answer")
			break
		}
		r.ok = jget_b(resp, "ok")
		if r.ok {
			r.username = strings.clone(jget_s(resp, "username"))
			r.password = strings.clone(jget_s(resp, "password"))
			r.totp = strings.clone(jget_s(resp, "totp"))
			r.state = .Unlocked
			// the parsed answer held them too
			if x, is := resp["password"].(json.String); is {pb.wipe(transmute([]u8)string(x))}
		} else {
			r.error = strings.clone(jget_s(resp, "error"))
			r.state = r.error == "locked" ? .Locked : w.state
		}
	case .Save:
		r.state = w_ensure(w)
		if r.state != .Unlocked {
			r.error = strings.clone(r.state == .Locked ? "Passwords is locked" : r.state == .Unpaired ? "this browser is not paired with Passwords" : "Passwords is not running")
			break
		}
		req: strings.Builder
		if j.id != "" {
			req = af_req("op", "save", "id", j.id, "origin", j.origin, "identity", j.identity, "username", j.username, "password", j.password)
		} else {
			req = af_req("op", "save", "origin", j.origin, "identity", j.identity, "username", j.username, "password", j.password, "title", j.title)
		}
		resp, ok := w_call(w, &req, 300_000)
		if !ok {
			r.error = strings.clone("Passwords did not answer")
			break
		}
		r.ok = jget_b(resp, "ok")
		r.updated = jget_b(resp, "updated")
		if !r.ok {
			r.error = strings.clone(jget_s(resp, "error"))
		}
	}
	if r.state != .Unknown && r.state != .Pairing {
		w.state = r.state
	}
	w_post(w, r)
}

@(private = "file")
worker_main :: proc(data: rawptr) {
	w := (^Af_Worker)(data)
	for {
		sync.mutex_lock(&w.lock)
		for len(w.jobs) == 0 && !w.quit {
			sync.cond_wait(&w.cond, &w.lock)
		}
		if w.quit {
			sync.mutex_unlock(&w.lock)
			break
		}
		j := pop_front(&w.jobs)
		sync.mutex_unlock(&w.lock)
		w_run(w, &j)
		job_free(&j)
		free_all(context.temp_allocator)
	}
	w_close(w)
}

job_free :: proc(j: ^Af_Job) {
	pb.wipe(transmute([]u8)j.password)
	delete(j.password)
	delete(j.origin)
	delete(j.identity)
	delete(j.id)
	delete(j.username)
	delete(j.title)
}

result_free :: proc(r: ^Af_Result) {
	for s in ([]string{r.username, r.password, r.totp}) {
		pb.wipe(transmute([]u8)s)
		delete(s)
	}
	delete(r.origin)
	delete(r.error)
	delete(r.code)
	candidates_free(&r.candidates)
}

candidates_free :: proc(c: ^[dynamic]Af_Candidate) {
	for x in c {
		delete(x.id)
		delete(x.title)
		delete(x.username)
	}
	delete(c^)
	c^ = nil
}

af_worker_start :: proc(prof: ^Profile, app: ^p.App) -> ^Af_Worker {
	w := new(Af_Worker)
	w.wake = app
	w.sock_path = af_socket_path()
	w.pair_path = profile_path(prof, "vault-pair.json", context.allocator)
	w.th = thread.create_and_start_with_data(w, worker_main)
	return w
}

af_worker_stop :: proc(w: ^Af_Worker) {
	if w == nil {
		return
	}
	sync.mutex_lock(&w.lock)
	w.quit = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.lock)
	thread.join(w.th)
	thread.destroy(w.th)
}

// ---------------------------------------------------------------------------
// The controller: the UI thread's side
// ---------------------------------------------------------------------------

// identity_handle is what the vault calls this profile's identity: the
// account handle in ~/.config/palmframe/identities.json when that file names
// the profile, the profile's name otherwise (which is the handle whenever
// apps/accounts made the profile).
identity_handle :: proc(name: string, allocator := context.allocator) -> string {
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {
		cfg = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/palmframe/identities.json", cfg), context.temp_allocator)
	if err == nil {
		Entry :: struct {
			handle: string,
			name:   string,
		}
		entries: []Entry
		if json.unmarshal(data, &entries, allocator = context.temp_allocator) == nil {
			for e in entries {
				if e.handle == name {
					return strings.clone(name, allocator)
				}
			}
			for e in entries {
				if e.name == name && e.handle != "" {
					return strings.clone(e.handle, allocator)
				}
			}
		}
	}
	return strings.clone(name, allocator)
}

af_init :: proc(s: ^State) {
	if s.af.worker != nil || os.get_env("PALM_BROWSER_NO_AUTOFILL", context.temp_allocator) == "1" {
		return
	}
	s.af.identity = identity_handle(s.prof.identity)
	crypto.rand_bytes(s.af.mac_key[:])
	s.af.worker = af_worker_start(&s.prof, s.app)
	s.af.sel = -1
}

af_shutdown :: proc(s: ^State) {
	af_worker_stop(s.af.worker)
	bar_close(s)
	crypto.zero_explicit(&s.af.mac_key, size_of(s.af.mac_key))
}

af_trace :: proc(s: ^State, format: string, args: ..any) {
	append(&s.af.trace, fmt.aprintf(format, ..args))
	if os.get_env("PALM_BROWSER_AF_TRACE", context.temp_allocator) != "" {
		fmt.eprintfln("autofill: %s", s.af.trace[len(s.af.trace) - 1])
	}
}

af_queue :: proc(s: ^State, j: Af_Job) -> int {
	w := s.af.worker
	if w == nil {
		return 0
	}
	s.af.seq += 1
	j := j
	j.seq = s.af.seq
	j.identity = strings.clone(s.af.identity)
	sync.mutex_lock(&w.lock)
	append(&w.jobs, j)
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.lock)
	return j.seq
}

af_query :: proc(s: ^State, view: int, origin: string) {
	if origin == "" {
		return
	}
	s.af.query_seq = af_queue(s, {kind = .Query, view = view, origin = strings.clone(origin)})
}

af_mac :: proc(s: ^State, pw: string) -> (m: [32]u8) {
	hmac.sum(.SHA256, m[:], transmute([]u8)pw, s.af.mac_key[:])
	return
}

// af_input notes that the person just typed into or clicked the page: a
// login field that takes focus now was focused by them, and gets the
// dropdown. One focused by the page itself (autofocus) only arms it; Down
// opens it, as in every browser.
af_input :: proc(s: ^State) {
	s.af.last_input = time.tick_now()
}

af_close :: proc(s: ^State) {
	if s.af.open {
		af_trace(s, "dropdown closed")
	}
	s.af.open = false
	s.af.from_omni = false
	s.af.sel = -1
}

// af_event takes the engine's autofill events. Each names a view; the origin
// in it is the engine host's own top-level origin for that view.
af_event :: proc(s: ^State, ev: ^pb.Event) {
	t := tab_by_view(s, ev.view)
	#partial switch ev.op {
	case .Field_Focus:
		if ev.field == .None {
			if s.af.view == ev.view {
				af_close(s)
				s.af.armed = false
			}
			return
		}
		if t == nil {
			return
		}
		af_trace(s, "focus %v %s", ev.field, ev.str)
		delete(s.af.origin)
		s.af.origin = strings.clone(ev.str)
		s.af.view = ev.view
		s.af.kind = ev.field
		s.af.rect = {ev.x, ev.y, ev.fw, ev.fh}
		if s.af.worker == nil {
			return
		}
		recent := time.tick_since(s.af.last_input) < 1500 * time.Millisecond
		if s.af.open || recent {
			if !s.af.open {
				s.af.sel = -1
			}
			s.af.open = true
			s.af.from_omni = false
			s.af.armed = false
		} else {
			s.af.armed = true
		}
		af_query(s, ev.view, ev.str)
	case .Fill_Result:
		af_trace(s, "fill result %v", ev.fill)
		switch ev.fill {
		case .Ok:
		case .Origin_Changed:
			toast(s, "Not filled: the page changed before the login arrived")
		case .No_Field:
			toast(s, "Not filled: no login field on this page")
		case .Form_Action:
			toast(s, "Not filled: this form sends to another site")
		case .Failed:
			toast(s, "Not filled: the page could not be filled")
		}
	case .Form_Submit:
		af_submitted(s, ev)
	}
}

// af_url: a view moved. The dropdown belongs to the page it was opened on.
af_url :: proc(s: ^State, t: ^Tab) {
	if s.af.view == t.id {
		af_close(s)
		s.af.armed = false
	}
	if t == active_tab(s) && t.page == .Web {
		o := pb.origin_of(t.url)
		if o != "" && o != s.af.cand_origin {
			af_query(s, t.id, o)
		}
	}
}

af_pump :: proc(s: ^State) {
	w := s.af.worker
	if w == nil {
		return
	}
	sync.mutex_lock(&w.lock)
	results := make([dynamic]Af_Result, 0, len(w.results), context.temp_allocator)
	append(&results, ..w.results[:])
	clear(&w.results)
	sync.mutex_unlock(&w.lock)
	for &r in results {
		af_result(s, &r)
		result_free(&r)
	}
}

@(private = "file")
af_result :: proc(s: ^State, r: ^Af_Result) {
	if r.state != .Unknown {
		s.af.vault = r.state
	}
	switch r.kind {
	case .Pair:
		if r.interim {
			delete(s.af.pair_code)
			s.af.pair_code = strings.clone(r.code)
			s.af.pair_seq = r.seq
			af_trace(s, "pairing: code %s", r.code)
			return
		}
		delete(s.af.pair_code)
		s.af.pair_code = ""
		af_trace(s, "pairing: %s", r.ok ? "paired" : r.error)
		if r.ok {
			toast(s, "Paired with Passwords")
			s.af.sel = -1
			if s.af.origin != "" {
				af_query(s, s.af.view, s.af.origin)
			}
		} else {
			toast(s, r.error != "" ? fmt.tprintf("Not paired: %s", r.error) : "Not paired")
		}
	case .Query:
		af_trace(s, "query %s: %v, %d candidates", r.origin, r.state, len(r.candidates))
		if r.seq == s.af.bar.seq && s.af.bar.seq != 0 {
			bar_decide(s, r)
			return
		}
		candidates_free(&s.af.candidates)
		s.af.candidates = r.candidates
		r.candidates = nil
		delete(s.af.cand_origin)
		s.af.cand_origin = strings.clone(r.origin)
		s.af.cand_view = r.view
	case .Fill:
		s.af.busy = false
		if r.seq != s.af.fill_seq {
			return
		}
		af_trace(s, "vault fill: %s", r.ok ? "allowed" : r.error)
		if !r.ok {
			toast(s, r.error == "denied" ? "Passwords did not allow the fill" : fmt.tprintf("Not filled: %s", r.error))
			return
		}
		t := tab_by_view(s, r.view)
		if t == nil || s.engine == nil {
			return
		}
		// The engine host re-checks that the view is still at r.origin
		// before anything reaches the page.
		m := pb.req_fill(r.view, r.origin, r.username, r.password, r.totp)
		if s.engine.ok {
			pb.send_secret(&s.engine.conn, &m)
		} else {
			pb.wipe(m.b[:])
			delete(m.b)
		}
		for &f, i in s.af.filled {
			if f.view == r.view {
				delete(f.item)
				delete(f.origin)
				unordered_remove(&s.af.filled, i)
				break
			}
		}
		append(&s.af.filled, Af_Filled{view = r.view, item = strings.clone(s.af.fill_item), origin = strings.clone(r.origin), mac = af_mac(s, r.password), at = time.tick_now()})
		af_close(s)
	case .Save:
		s.af.bar.waiting = false
		af_trace(s, "save: %s", r.ok ? (r.updated ? "updated" : "saved") : r.error)
		if r.ok {
			toast(s, r.updated ? "Password updated in Passwords" : "Saved to Passwords")
		} else if r.error == "denied" {
			toast(s, "Not saved")
		} else {
			toast(s, fmt.tprintf("Not saved: %s", r.error))
		}
		bar_close(s)
	}
}

// af_pick acts on dropdown row `i`: a candidate, or one of the actions after
// them.
af_pick :: proc(s: ^State, i: int) {
	rows := af_rows(s)
	if i < 0 || i >= len(rows) {
		return
	}
	row := rows[i]
	switch row.action {
	case .Fill:
		c := row.cand
		af_trace(s, "picked %s", c.title)
		delete(s.af.fill_item)
		s.af.fill_item = strings.clone(c.id)
		s.af.busy = true
		s.af.fill_seq = af_queue(s, {kind = .Fill, view = s.af.view, origin = strings.clone(s.af.origin), id = strings.clone(c.id)})
	case .Open_Vault, .Unlock:
		open_vault(s)
		af_close(s)
	case .Pair:
		s.af.vault = .Pairing
		af_queue(s, {kind = .Pair})
	case .None:
	}
}

open_vault :: proc(s: ^State) {
	bin := os.get_env("PALM_VAULT_BIN", context.temp_allocator)
	if bin == "" {
		bin = fmt.tprintf("%s/vault", exe_dir())
		if !os.exists(bin) {
			bin = find_on_path("vault")
		}
	}
	if bin == "" || !kit.launch({bin}) {
		toast(s, "Passwords is not installed")
	}
}

Af_Action :: enum u8 {
	None,
	Fill,
	Open_Vault,
	Unlock,
	Pair,
}

Af_Row :: struct {
	action: Af_Action,
	cand:   Af_Candidate,
	label:  string,
	detail: string,
}

// af_rows is what the dropdown shows, in order; the keyboard selection
// indexes it.
af_rows :: proc(s: ^State) -> []Af_Row {
	rows := make([dynamic]Af_Row, context.temp_allocator)
	switch s.af.vault {
	case .Unknown:
	case .Not_Running:
		append(&rows, Af_Row{action = .Open_Vault, label = "Open Passwords", detail = "to fill saved logins"})
	case .Unpaired:
		append(&rows, Af_Row{action = .Pair, label = "Connect to Passwords…", detail = "once, with a code"})
	case .Pairing:
	case .Locked:
		append(&rows, Af_Row{action = .Unlock, label = "Locked — unlock", detail = "Passwords"})
	case .Unlocked:
		same := s.af.cand_origin == s.af.origin
		if same {
			otp := s.af.kind == .Otp
			for c in s.af.candidates {
				if otp && !c.totp {
					continue
				}
				append(&rows, Af_Row{action = .Fill, cand = c, label = c.title, detail = c.username})
			}
		}
		append(&rows, Af_Row{action = .Open_Vault, label = "Open Passwords"})
	}
	return rows[:]
}

// af_keys takes the dropdown's keys before the page sees them: Down and Up
// move, Enter picks, Escape closes. Everything else goes to the page, so the
// person can keep typing. Returns the keys the page should still get.
af_keys :: proc(s: ^State, keys: []p.Key_Event) -> []p.Key_Event {
	if s.af.worker == nil {
		return keys
	}
	t := active_tab(s)
	if t == nil || t.id != s.af.view {
		return keys
	}
	keep := make([dynamic]p.Key_Event, context.temp_allocator)
	for k in keys {
		if k.mods & {.Ctrl, .Alt, .Super} != {} {
			append(&keep, k)
			continue
		}
		if !s.af.open {
			if s.af.armed && (k.sym == p.KEY_DOWN) {
				s.af.open = true
				s.af.armed = false
				s.af.sel = 0
				af_trace(s, "dropdown opened from the keyboard")
				continue
			}
			append(&keep, k)
			continue
		}
		n := len(af_rows(s))
		switch k.sym {
		case p.KEY_DOWN:
			s.af.sel = n > 0 ? (s.af.sel + 1) % n : -1
		case p.KEY_UP:
			s.af.sel = n > 0 ? (s.af.sel - 1 + n) % n : -1
		case p.KEY_ESCAPE:
			af_close(s)
			s.af.armed = true
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if s.af.sel >= 0 && s.af.sel < n && !s.af.busy {
				af_pick(s, s.af.sel)
			} else {
				af_close(s)
				append(&keep, k)
			}
		case p.KEY_TAB:
			af_close(s)
			append(&keep, k)
		case:
			append(&keep, k)
		}
	}
	return keep[:]
}

// af_fill_from_omnibox opens the dropdown under the address bar, for the
// page's login fields: "Fill login" from the key or the menu.
af_fill_from_omnibox :: proc(s: ^State) {
	t := active_tab(s)
	if t == nil || t.page != .Web || s.af.worker == nil {
		return
	}
	o := pb.origin_of(t.url)
	if o == "" {
		toast(s, "Logins fill only on web pages")
		return
	}
	if s.af.view != t.id || s.af.origin != o {
		delete(s.af.origin)
		s.af.origin = strings.clone(o)
		s.af.view = t.id
		s.af.kind = .Password
	}
	s.af.open = true
	s.af.from_omni = true
	s.af.armed = false
	s.af.sel = 0
	af_query(s, t.id, o)
	set_focus(s, .Page)
}

// ---------------------------------------------------------------------------
// Saving: the bar
// ---------------------------------------------------------------------------

@(private = "file")
af_submitted :: proc(s: ^State, ev: ^pb.Event) {
	if s.af.worker == nil || ev.password == "" {
		return
	}
	t := tab_by_view(s, ev.view)
	if t == nil {
		return
	}
	// A fill of this very password on this origin, then a submit: nothing to
	// save. Only an HMAC of the filled password was kept to tell.
	for &f in s.af.filled {
		if f.view == ev.view && f.origin == ev.str {
			m := af_mac(s, ev.password)
			if crypto.compare_constant_time(m[:], f.mac[:]) == 1 {
				af_trace(s, "submit of the filled password: nothing to save")
				return
			}
		}
	}
	bar_close(s)
	b := &s.af.bar
	b.active = true
	b.view = ev.view
	b.origin = strings.clone(ev.str)
	b.username = strings.clone(ev.username)
	b.password = strings.clone(ev.password)
	b.waiting = true // until the vault says which logins it has here
	af_trace(s, "submit on %s: deciding", ev.str)
	// which logins the vault has here decides "save" or "update"
	b.seq = af_queue(s, {kind = .Query, view = ev.view, origin = strings.clone(ev.str)})
	if ev.old_password != "" {
		// a change-password form: the login it changes is the one whose
		// password was filled here, when that is what the old field held
		for &f in s.af.filled {
			if f.view == ev.view && f.origin == ev.str {
				m := af_mac(s, ev.old_password)
				if crypto.compare_constant_time(m[:], f.mac[:]) == 1 {
					b.item = strings.clone(f.item)
				}
			}
		}
	}
}

bar_decide :: proc(s: ^State, r: ^Af_Result) {
	b := &s.af.bar
	b.seq = 0
	b.waiting = false
	if !b.active {
		return
	}
	if r.state != .Unlocked {
		// Nothing can be saved into a locked (or absent) vault; the bar says
		// so and offers to open it. The password goes when the bar does.
		af_trace(s, "submit: the vault is %v", r.state)
		if t := active_tab(s); t != nil && t.id == b.view && s.focus == .Page {
			set_focus(s, .Bar)
		}
		return
	}
	match: ^Af_Candidate
	if b.item != "" {
		for &c in r.candidates {
			if c.id == b.item {match = &c}
		}
	}
	if match == nil && b.username != "" {
		for &c in r.candidates {
			if c.username == b.username && c.exact {match = &c}
		}
		if match == nil {
			for &c in r.candidates {
				if c.username == b.username {match = &c}
			}
		}
	}
	if match == nil && b.username == "" && len(r.candidates) == 1 {
		match = &r.candidates[0]
	}
	if match == nil {
		for &f in s.af.filled {
			if f.view == b.view && f.origin == b.origin {
				for &c in r.candidates {
					if c.id == f.item && (b.username == "" || b.username == c.username) {match = &c}
				}
			}
		}
	}
	if match != nil {
		b.update = true
		delete(b.item)
		b.item = strings.clone(match.id)
		b.title = strings.clone(match.title)
		if b.username == "" {
			delete(b.username)
			b.username = strings.clone(match.username)
		}
	}
	af_trace(s, "submit: offering to %s", b.update ? "update" : "save")
	// keyboard first: the bar takes the keys (Enter answers, Escape is "Not
	// now", and either gives them back to the page)
	if t := active_tab(s); t != nil && t.id == b.view && s.focus == .Page {
		set_focus(s, .Bar)
	}
}

bar_accept :: proc(s: ^State) {
	b := &s.af.bar
	if !b.active || b.waiting {
		return
	}
	if s.af.vault != .Unlocked {
		open_vault(s)
		return
	}
	title := b.title
	if title == "" {
		title = host_of_origin(b.origin)
	}
	af_trace(s, "bar: %s", b.update ? "update" : "save")
	b.waiting = true
	b.seq = 0
	af_queue(s, {kind = .Save, view = b.view, origin = strings.clone(b.origin), id = strings.clone(b.update ? b.item : ""), username = strings.clone(b.username), password = strings.clone(b.password), title = strings.clone(title)})
	// the job holds its own copy now
	pb.wipe(transmute([]u8)b.password)
}

bar_close :: proc(s: ^State) {
	b := &s.af.bar
	pb.wipe(transmute([]u8)b.password)
	delete(b.password)
	delete(b.origin)
	delete(b.username)
	delete(b.item)
	delete(b.title)
	b^ = {}
}

host_of_origin :: proc(o: string) -> string {
	h := o
	if i := strings.index(h, "://"); i >= 0 {
		h = h[i + 3:]
	}
	return h
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// af_dropdown draws the list under the focused field (or under the address
// bar, for "Fill login").
af_dropdown :: proc(ui: ^p.Ctx, s: ^State) {
	t := active_tab(s)
	if !s.af.open || t == nil || t.id != s.af.view || t.page != .Web || s.overlay != .None || s.dialog.active {
		s.af.drop_rect = {}
		return
	}
	rows := af_rows(s)
	win := p.size(ui)
	w: f32 = 320
	x, y: f32
	if s.af.from_omni {
		o := p.rect_of(ui, s.omni_id)
		x = o.x + o.w - w
		y = o.y + o.h + 6
	} else {
		pr := s.page_rect
		w = max(w, min(s.af.rect[2], 420))
		x = pr.x + s.af.rect[0]
		y = pr.y + s.af.rect[1] + s.af.rect[3] + 4
		// fields scrolled out of the page leave the list behind them
		if s.af.rect[1] + s.af.rect[3] < 0 || s.af.rect[1] > pr.h {
			s.af.drop_rect = {}
			return
		}
		est := f32(56 + 44 * len(rows))
		if y + est > pr.y + pr.h && pr.y + s.af.rect[1] - est - 4 > pr.y {
			y = pr.y + s.af.rect[1] - est - 4
		}
	}
	x = clamp(x, 8, max(8, win.x - w - 8))
	wrap := p.div(ui, "absolute z-30")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px(x)
	st.inset[p.TOP] = p.px(y)
	st.w = p.px(w)
	s.af.drop_id = p.node_id(ui, wrap)
	s.af.drop_rect = p.rect_of(ui, s.af.drop_id)
	box := p.col(ui, "w-full rounded-lg border border-border bg-popover text-popover-foreground shadow-xl p-1 gap-0.5")
	_ = box

	// heading: whose passwords these are
	p.row(ui, "h-7 items-center gap-2 px-2")
	dot := p.div(ui, "size-2 rounded-full shrink-0")
	p.style(ui, dot).bg = p.flat(rgb(s.prof.color))
	p.end(ui)
	p.text(ui, s.af.from_omni ? "Fill login" : "Passwords", "text-[11.5] font-medium text-muted-foreground whitespace-nowrap")
	p.text(ui, s.af.identity, "flex-1 text-[11.5] text-muted-foreground/80 truncate")
	if s.af.busy {
		p.text(ui, "Waiting for Passwords…", "text-[11] text-muted-foreground whitespace-nowrap")
	}
	p.end(ui)

	if s.af.vault == .Pairing || s.af.pair_code != "" {
		af_pairing_rows(ui, s)
	} else if s.af.vault == .Unknown {
		p.row(ui, "h-9 items-center gap-2.5 px-2")
		p.icon(ui, ICON_LOADER_CIRCLE, "size-4 text-muted-foreground")
		p.text(ui, "Asking Passwords…", "text-[13] text-muted-foreground")
		p.end(ui)
	}
	first_action := true
	any_login := false
	for row, i in rows {
		if row.action != .Fill && first_action && any_login {
			sc.menu_separator(ui)
		}
		if row.action != .Fill {
			first_action = false
		} else {
			any_login = true
		}
		selected := s.af.sel == i
		r := p.row(ui, "h-11 items-center gap-2.5 px-2 rounded-md cursor-pointer")
		if row.action != .Fill {
			p.apply(ui, "h-9")
		}
		if selected {
			p.apply(ui, "bg-accent text-accent-foreground")
		} else {
			p.apply(ui, "hover:bg-accent")
		}
		switch row.action {
		case .Fill:
			letter_tile(ui, s.af.origin, row.label, 24, 6)
			p.col(ui, "flex-1 min-w-0 gap-0")
			p.text(ui, row.label != "" ? row.label : host_of_origin(s.af.origin), "text-[13] font-medium truncate")
			p.text(ui, row.detail != "" ? row.detail : "(no username)", "text-[12] text-muted-foreground truncate")
			p.end(ui)
			if row.cand.totp && s.af.kind == .Otp {
				p.text(ui, "code", "text-[11] text-muted-foreground")
			}
		case .Unlock:
			p.icon(ui, ICON_LOCK, "size-4 text-muted-foreground")
			p.text(ui, row.label, "flex-1 text-[13] truncate")
			p.text(ui, row.detail, "text-[11.5] text-muted-foreground whitespace-nowrap")
		case .Pair:
			p.icon(ui, ICON_LINK, "size-4 text-muted-foreground")
			p.text(ui, row.label, "flex-1 text-[13] truncate")
			p.text(ui, row.detail, "text-[11.5] text-muted-foreground whitespace-nowrap")
		case .Open_Vault, .None:
			p.icon(ui, ICON_KEY, "size-4 text-muted-foreground")
			p.text(ui, row.label, "flex-1 text-[13] truncate")
			if row.detail != "" {
				p.text(ui, row.detail, "text-[11.5] text-muted-foreground whitespace-nowrap")
			}
		}
		p.end(ui)
		if p.is_hovered(ui, r) && ui.input.mouse_delta != {0, 0} {
			s.af.sel = i
		}
		if p.clickable(ui, r) && !s.af.busy {
			af_pick(s, i)
		}
	}
	if s.af.vault == .Unlocked && !any_login && s.af.cand_origin == s.af.origin {
		p.text(ui, fmt.tprintf("No saved logins for %s", host_of_origin(s.af.origin)), "px-2 pb-1 text-[11.5] text-muted-foreground truncate")
	}
	// keyboard hints
	p.row(ui, "h-6 items-center gap-3 px-2 border-t border-border mt-0.5")
	hint_pair(ui, "↓ ↑", "choose")
	hint_pair(ui, "Enter", "fill")
	hint_pair(ui, "Esc", "close")
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

@(private = "file")
af_pairing_rows :: proc(ui: ^p.Ctx, s: ^State) {
	p.col(ui, "w-full items-center gap-1.5 px-3 py-3")
	p.text(ui, "Confirm this code in Passwords", "text-[13] font-medium")
	code := s.af.pair_code != "" ? s.af.pair_code : "··· ···"
	p.row(ui, "h-12 w-full items-center justify-center rounded-md bg-muted")
	p.text(ui, code, "text-2xl font-mono font-semibold tracking-widest whitespace-nowrap")
	p.end(ui)
	p.text(ui, "Pair only if Passwords shows the same six digits. It asks once; every fill still asks.", "w-full text-[11.5] text-muted-foreground whitespace-normal text-center")
	p.end(ui)
}

// af_bar is the "Save this login?" strip across the top of the page.
af_bar :: proc(ui: ^p.Ctx, s: ^State) {
	b := &s.af.bar
	t := active_tab(s)
	if !b.active || t == nil || t.id != b.view {
		return
	}
	bar := p.row(ui, "w-full h-[46] shrink-0 items-center gap-3 px-3 bg-background border-b border-border")
	_ = bar
	p.div(ui, "size-7 rounded-md items-center justify-center bg-primary/10 shrink-0")
	p.icon(ui, ICON_KEY, "size-4 text-primary")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0")
	who := b.username != "" ? b.username : "this login"
	locked := !b.waiting && s.af.vault != .Unlocked
	switch {
	case b.waiting && b.seq != 0:
		p.text(ui, "Checking Passwords…", "text-[13] font-medium truncate")
	case locked:
		p.text(ui, "Passwords is locked — unlock it to save this login", "text-[13] font-medium truncate")
	case b.update:
		p.textf(ui, "text-[13] font-medium truncate", "Update the password for %s?", who)
	case:
		p.textf(ui, "text-[13] font-medium truncate", "Save this login to %s?", s.af.identity)
	}
	detail := host_of_origin(b.origin)
	if b.update && b.title != "" {
		detail = fmt.tprintf("%s · %s", b.title, detail)
	} else if b.username != "" {
		detail = fmt.tprintf("%s · %s", b.username, detail)
	}
	if b.waiting && b.seq == 0 {
		detail = "Passwords is asking you…"
	}
	p.text(ui, detail, "text-[12] text-muted-foreground truncate")
	p.end(ui)
	focused := s.focus == .Bar
	never := p.row(ui, "h-8 px-3 items-center rounded-md border border-border hover:bg-muted cursor-pointer shrink-0")
	if focused && b.sel == 1 {
		p.apply(ui, "ring-3 ring-ring/40 border-ring")
	}
	p.text(ui, "Not now", "text-[13] whitespace-nowrap")
	p.end(ui)
	label := locked ? "Open Passwords" : b.update ? "Update password" : "Save"
	ok := p.row(ui, "h-8 px-3 items-center gap-1.5 rounded-md bg-primary text-primary-foreground hover:bg-primary/90 cursor-pointer shrink-0")
	if b.waiting {
		p.apply(ui, "opacity-60")
	}
	if focused && b.sel == 0 {
		p.apply(ui, "ring-3 ring-ring/40")
	}
	p.text(ui, label, "text-[13] font-medium whitespace-nowrap")
	if focused && b.sel == 0 {
		p.text(ui, "Enter", "text-[11] opacity-70")
	}
	p.end(ui)
	if p.clickable(ui, never) {
		af_trace(s, "bar: not now")
		bar_close(s)
		if s.focus == .Bar {set_focus(s, .Page)}
	}
	if p.clickable(ui, ok) {
		bar_accept(s)
	}
}

// bar_keys: Enter takes the highlighted button, Tab moves between them,
// Escape is "Not now".
bar_keys :: proc(ui: ^p.Ctx, s: ^State) {
	b := &s.af.bar
	if !b.active {
		set_focus(s, .Page)
		return
	}
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_ESCAPE:
			af_trace(s, "bar: not now")
			bar_close(s)
			set_focus(s, .Page)
			return
		case p.KEY_TAB, p.KEY_LEFT, p.KEY_RIGHT:
			b.sel = 1 - b.sel
		case p.KEY_RETURN, p.KEY_KP_ENTER, ' ':
			if b.sel == 1 {
				af_trace(s, "bar: not now")
				bar_close(s)
				set_focus(s, .Page)
				return
			}
			bar_accept(s)
		}
	}
}

// af_key_button is the key in the address bar: shown when the vault has
// logins for the page (or is locked), it opens "Fill login".
af_key_button :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	if s.af.worker == nil || t == nil || t.page != .Web {
		return
	}
	o := pb.origin_of(t.url)
	show := o != "" && o == s.af.cand_origin && (len(s.af.candidates) > 0 || s.af.vault == .Locked)
	if !show {
		return
	}
	k := p.div(ui, "size-7 rounded-full items-center justify-center shrink-0 hover:bg-background cursor-pointer")
	if s.af.open && s.af.from_omni {
		p.apply(ui, "bg-background")
	}
	p.icon(ui, ICON_KEY, "size-4 text-muted-foreground")
	p.end(ui)
	if p.clickable(ui, k) {
		if s.af.open && s.af.from_omni {
			af_close(s)
		} else {
			af_fill_from_omnibox(s)
		}
	}
}
