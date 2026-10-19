// palm-rtc — the chat gateway of the Palmy cloud.
//
// It speaks the palmy-chat wire protocol, version 2 (apps/chat/PROTOCOL.md),
// to clients that sign in with a Palmy account token and speak as one
// identity. State lives in Postgres (migrations/2026101970*), so the gateway
// keeps nothing a restart would lose.
//
// ---------------------------------------------------------------------------
// Who decides what
// ---------------------------------------------------------------------------
//
// The database. Every statement the gateway runs for a client runs inside a
// transaction that has switched to the `authenticated` role with that
// client's claims, *narrowed to the identity it said hello as*:
//
//	set_config('role', 'authenticated', true)
//	set_config('request.jwt.claims', '{"sub":…,"palm_identity":<identity>}', true)
//
// so the rows a reply can contain are the rows RLS gives that identity, and a
// write the identity may not make fails in Postgres. Narrowing an unscoped
// session to one identity only ever removes access (can_access_identity), so
// it is safe for the gateway to do; widening is impossible because the
// gateway takes the person from the token's `sub` and never from the client.
//
// ---------------------------------------------------------------------------
// Ordering, and where broadcasts come from
// ---------------------------------------------------------------------------
//
// A write commits in Postgres, where the channel's row lock gives it its
// place (`seq`/`rev`). Its trigger calls pg_notify, and Postgres delivers
// notifications in commit order. Every broadcast of a stored change is made
// from that stream, by the LISTEN thread, and nowhere else. So every client
// sees changes in commit order — the order the database gave them — even when
// they were written by another gateway, by PostgREST, or by a bot. The
// request that caused a change gets only its direct reply inline (an `error`,
// or an answer such as `joined`); the change itself arrives as a broadcast
// like everybody else's, carrying the `tag` the author sent.
//
// Ephemeral things — typing, presence — are not stored changes and are
// broadcast inline.
//
// ---------------------------------------------------------------------------
// Locking
// ---------------------------------------------------------------------------
//
// One mutex, `srv.mu`, over the connection table, the main database
// connection and the in-memory call table. Same discipline as
// apps/chat/server: `locked_*` procedures assume the lock and never take it;
// the lock is taken at exactly five sites — `boot`, the accept loop,
// `handle`, `drop_conn`, and `notify_batch` — once each. Work that is slow and
// needs no shared state (token verification, base64, uploading an
// attachment to Storage) happens before the lock is taken.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import w "../../apps/chat/wire"
import ck "../../apps/cloudkit"
import "pcp"

PROTO_VERSION :: 2
DEFAULT_PORT :: 8790

Ident :: struct {
	id, handle, name, color, kind: string,
}

Conn :: struct {
	sock:    net.TCP_Socket,
	id:      int,
	hello:   bool,
	dead:    bool,
	is_sfu:  bool,
	away:    bool,
	passive: bool, // a command-line session: no presence of its own

	token:   string,
	claims:  Claims,
	scope:   string, // the claims JSON every statement for this client runs under
	ident:   Ident,

	// What this identity can see, as RLS answered the last time it was asked.
	// Broadcasts consult these; a membership change re-asks.
	visible: map[string]bool, // channel ids
	spaces:  map[string]bool,
	peers:   map[string]bool, // identity ids that share a space with this one
	staged:  int,
}

Call :: struct {
	id, ch: string,
	ids:    [dynamic]string, // identity ids in the SFU room, as the SFU last said
}

Srv :: struct {
	mu:        sync.Mutex,
	conns:     [dynamic]^Conn,
	next_conn: int,
	db:        Db,
	db_url:    string,
	origin:    string, // this instance, so it can recognise its own notifications
	api:       string, // Supabase API URL (auth, storage)
	anon_key:  string,
	sfu_addr:  string, // what clients are told to dial for media
	secret:    []u8, // shared with the SFU (pcp/token.odin)
	calls:     map[string]^Call,
	online:    map[string]int, // identity id -> live connections
	quiet:     bool,
	port:      int,
	bind:      net.Address,
	ready:     bool,
}

srv: Srv

main :: proc() {
	srv.port = DEFAULT_PORT
	srv.bind = net.IP4_Loopback
	srv.db_url = os.get_env("RTC_DB_URL", context.allocator)
	srv.api = os.get_env("RTC_API_URL", context.allocator)
	srv.anon_key = os.get_env("RTC_ANON_KEY", context.allocator)
	srv.sfu_addr = "127.0.0.1:47900"
	jwt_secret = os.get_env("RTC_JWT_SECRET", context.allocator)
	secret_file := ""
	e2e := false

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			if i^ + 1 < len(args) {
				i^ += 1
				return args[i^]
			}
			fmt.eprintfln("palm-rtc: %s needs a value", args[i^])
			os.exit(2)
		}
		switch args[i] {
		case "--port":
			if n, ok := strconv.parse_int(next(args, &i)); ok {
				srv.port = n
			}
		case "--bind":
			a := net.parse_address(next(args, &i))
			if a == nil {
				fmt.eprintln("palm-rtc: --bind wants an IP address")
				os.exit(2)
			}
			srv.bind = a
		case "--db":
			srv.db_url = next(args, &i)
		case "--api":
			srv.api = next(args, &i)
		case "--anon-key":
			srv.anon_key = next(args, &i)
		case "--jwt-secret":
			jwt_secret = next(args, &i)
		case "--sfu":
			srv.sfu_addr = next(args, &i)
		case "--sfu-secret-file":
			secret_file = next(args, &i)
		case "--quiet":
			srv.quiet = true
		case "--e2e":
			e2e = true
		case "--help", "-h":
			fmt.print(USAGE)
			os.exit(0)
		case:
			fmt.eprintfln("palm-rtc: unknown argument %q", args[i])
			os.exit(2)
		}
	}
	if srv.anon_key == "" {
		srv.anon_key = ck.DEFAULT_ANON_KEY
	}
	if srv.db_url == "" || srv.api == "" {
		fmt.eprintln("palm-rtc: --db and --api are required (or RTC_DB_URL / RTC_API_URL)")
		os.exit(2)
	}
	if secret_file != "" {
		data, err := os.read_entire_file_from_path(secret_file, context.allocator)
		if err != nil {
			fmt.eprintfln("palm-rtc: cannot read %s: %v", secret_file, err)
			os.exit(1)
		}
		srv.secret = transmute([]u8)strings.trim_space(string(data))
	} else if s := os.get_env("RTC_SFU_SECRET", context.allocator); s != "" {
		srv.secret = transmute([]u8)s
	}
	if len(srv.secret) < 16 {
		fmt.eprintln("palm-rtc: an SFU secret of at least 16 bytes is required (--sfu-secret-file or RTC_SFU_SECRET)")
		os.exit(2)
	}

	if e2e {
		os.exit(e2e_run())
	}
	serve()
}

USAGE :: `palm-rtc — the Palmy chat gateway (wire protocol v2)

  --db URL               Postgres, as a role that may SET ROLE authenticated
  --api URL              the Supabase API gateway (auth JWKS, Storage)
  --anon-key KEY         the project's anon key (for Storage requests)
  --jwt-secret S         also accept HS256 tokens signed with S (cloud/dev)
  --sfu HOST:PORT        the SFU clients are told to dial (default 127.0.0.1:47900)
  --sfu-secret-file F    the secret shared with the SFU (or RTC_SFU_SECRET)
  --port N               listen port (default 8790)
  --bind ADDR            listen address (default 127.0.0.1; TLS is not built in)
  --quiet                no log output
  --e2e                  run the end-to-end test against the stack, then exit
`

serve :: proc() {
	boot()

	sock, err := net.listen_tcp(net.Endpoint{address = srv.bind, port = srv.port})
	if err != nil {
		fmt.eprintfln("palm-rtc: cannot listen on port %d: %v", srv.port, err)
		os.exit(1)
	}
	note("listening on %s:%d, database %s, sfu %s", net.address_to_string(srv.bind, context.temp_allocator), srv.port, redact(srv.db_url), srv.sfu_addr)
	thread.create_and_start(listen_thread, self_cleanup = true)

	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			if aerr == .Interrupted || aerr == .Aborted || aerr == .Would_Block {
				continue
			}
			fmt.eprintfln("palm-rtc: accept failed: %v", aerr)
			break
		}
		_ = net.set_option(client, .Send_Timeout, 2 * time.Second)
		// One frame is one send, and frames to one client are often back to
		// back: without this, Nagle holds the second until the client's
		// delayed ACK, which measured as ~60 ms of added latency per message.
		_ = net.set_option(client, .TCP_Nodelay, true)
		c := new(Conn)
		c.sock = client

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
	fmt.printf("palm-rtc: ")
	fmt.printfln(format, ..args)
}

redact :: proc(url: string) -> string {
	at := strings.last_index_byte(url, '@')
	if at < 0 {
		return url
	}
	scheme := strings.index(url, "://")
	if scheme < 0 {
		return url[at + 1:]
	}
	return strings.concatenate({url[:scheme + 3], "…@", url[at + 1:]}, context.temp_allocator)
}

// boot connects, loads the signing keys, and clears presence a crashed
// gateway may have left saying "online". It takes the lock once, like every
// other entry point, although nothing else runs yet.
boot :: proc() {
	srv.calls = make(map[string]^Call)
	srv.online = make(map[string]int)
	srv.origin = new_uuid()
	db, err := db_open(srv.db_url)
	if err != "" {
		fmt.eprintfln("palm-rtc: cannot connect to the database: %s", err)
		os.exit(1)
	}
	n, jerr := jwks_load(srv.api)
	if jerr != "" {
		note("no signing keys from %s (%s); only HS256 tokens will verify", srv.api, jerr)
	} else {
		note("%d signing key(s) from %s/auth/v1/.well-known/jwks.json", n, srv.api)
	}
	if jwt_secret != "" {
		note("HS256 tokens are accepted too (--jwt-secret)")
	}

	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	srv.db = db
	locked_boot()
	srv.ready = true
}

// ---------------------------------------------------------------------------
// Connections
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
			break
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

// Pre is the work done for a frame before the lock is taken.
Pre :: struct {
	// hello / auth: the token, verified.
	claims:    Claims,
	token_err: string,
	// attach: the file, decoded and already in Storage.
	attach:    bool,
	code, why: string,
	path:      string, // the object name in the `rtc` bucket
	size:      int,
}

handle :: proc(c: ^Conn, payload: string) {
	o, ok := w.parse_obj(payload, context.temp_allocator)
	t := ok ? w.ostr(o, "t") : ""

	pre: Pre
	switch t {
	case "hello", "auth":
		pre.claims, pre.token_err = jwt_verify(w.ostr(o, "token"), srv.api)
	case "attach":
		// c.token is written only by this connection's own thread (in hello
		// and auth), so reading it here, unlocked, is reading our own field.
		pre = stage_attach(c, o)
	}

	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	if !ok {
		locked_err(c, 0, "bad_json", "frame was not a JSON object")
		return
	}
	locked_dispatch(c, t, o, w.oint(o, "rq"), &pre)
}

// stage_attach decodes the file and uploads it to Storage as the person
// (Storage's own RLS checks the channel again: rtc_objects_insert). The
// message that points at it is written under the lock; if that fails, the
// object is removed again.
stage_attach :: proc(c: ^Conn, o: json.Object) -> (p: Pre) {
	p.attach = true
	if c.token == "" {
		p.code, p.why = "no_hello", "send hello first"
		return
	}
	ch := w.ostr(o, "ch")
	if !is_uuid(ch) {
		p.code, p.why = "no_channel", "no such channel"
		return
	}
	bytes, derr := base64.decode(w.ostr(o, "data"), allocator = context.temp_allocator)
	if derr != nil || len(bytes) == 0 {
		p.code, p.why = "bad_file", "the attachment was not valid base64"
		return
	}
	if len(bytes) > w.MAX_ATTACH {
		p.code, p.why = "too_big", fmt.tprintf("an attachment is at most %d bytes", w.MAX_ATTACH)
		return
	}
	name := w.safe_filename(w.ostr(o, "name"), context.temp_allocator)
	p.path = strings.concatenate({strings.to_lower(ch, context.temp_allocator), "/", new_uuid(context.temp_allocator), "/", name})
	cl := storage_client(c.token, c.claims.exp)
	if e := ck.upload_bytes(cl, "rtc", p.path, bytes, clean_mime(w.ostr(o, "mime"))); !ck.ok(e) {
		p.code = e.kind == .Out_Of_Scope || e.status == 403 || e.status == 400 ? "forbidden" : "store_failed"
		p.why = fmt.tprintf("storage refused the upload: %s", e.message)
		delete(p.path)
		p.path = ""
		return
	}
	p.size = len(bytes)
	return
}

storage_client :: proc(token: string, exp: i64) -> ^ck.Client {
	cl := new(ck.Client, context.temp_allocator)
	cl.url, _ = ck.parse_url(srv.api)
	cl.url_text = srv.api
	cl.anon_key = srv.anon_key
	cl.has_session = true
	cl.session.access_token = token
	// cloudkit counts a session as signed in only with a refresh token. The
	// gateway holds the person's access token, never their refresh token, and
	// expires_at is set so cloudkit never tries to refresh; this placeholder
	// is never sent anywhere. (A cloudkit constructor for a borrowed bearer
	// token would remove the need for it.)
	cl.session.refresh_token = "not-held-by-the-gateway"
	cl.session.expires_at = max(exp, time.time_to_unix(time.now()) + 3600)
	cl.user_agent = "palm-rtc"
	return cl
}

drop_conn :: proc(c: ^Conn) {
	sync.lock(&srv.mu)
	c.dead = true
	for cc, i in srv.conns {
		if cc == c {
			ordered_remove(&srv.conns, i)
			break
		}
	}
	locked_gone(c)
	sync.unlock(&srv.mu)

	net.close(c.sock)
	delete(c.visible)
	delete(c.spaces)
	delete(c.peers)
	free(c)
}

// ---------------------------------------------------------------------------
// The notification stream
// ---------------------------------------------------------------------------

// listen_thread holds its own database connection, LISTENs on `rtc`, and
// hands each batch of notifications to `notify_batch` in the order Postgres
// delivered them, which is commit order.
listen_thread :: proc() {
	first := true
	for {
		ldb, err := db_open(srv.db_url)
		if err != "" {
			note("listen: cannot connect (%s), retrying", strings.trim_space(err))
			time.sleep(time.Second)
			continue
		}
		if !db_simple(&ldb, "listen rtc") {
			PQfinish(ldb.conn)
			time.sleep(time.Second)
			continue
		}
		if !first {
			// Anything committed while we were not listening was never
			// broadcast. Clients hold a rev per channel and ask for what
			// they missed.
			notify_batch({"{\"k\":\"resync\"}"})
		}
		first = false
		fd := posix.FD(PQsocket(ldb.conn))
		for {
			pfd := [1]posix.pollfd{{fd = fd, events = {.IN}}}
			r := posix.poll(&pfd[0], 1, 1000)
			if r < 0 {
				continue
			}
			if PQconsumeInput(ldb.conn) == 0 {
				break
			}
			batch := make([dynamic]string, context.temp_allocator)
			for {
				n := PQnotifies(ldb.conn)
				if n == nil {
					break
				}
				append(&batch, strings.clone(string(n.extra), context.temp_allocator))
				PQfreemem(n)
			}
			if len(batch) > 0 {
				notify_batch(batch[:])
			}
			free_all(context.temp_allocator)
		}
		note("listen: connection lost, reconnecting")
		PQfinish(ldb.conn)
	}
}

notify_batch :: proc(batch: []string) {
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	for payload in batch {
		o, ok := w.parse_obj(payload, context.temp_allocator)
		if ok {
			locked_event(o)
		}
	}
}

// ---------------------------------------------------------------------------
// Small things
// ---------------------------------------------------------------------------

new_uuid :: proc(allocator := context.allocator) -> string {
	b: [16]u8
	rand_bytes(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.aprintf(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
		allocator = allocator,
	)
}

MAX_MIME :: 127

clean_mime :: proc(raw: string) -> string {
	s := strings.trim_space(raw)
	if s == "" || len(s) > MAX_MIME {
		return "application/octet-stream"
	}
	for i in 0 ..< len(s) {
		if s[i] < 0x20 || s[i] >= 0x7f {
			return "application/octet-stream"
		}
	}
	return s
}

_ :: pcp.Join

net_shutdown :: proc(c: ^Conn) -> net.Network_Error {
	return net.shutdown(c.sock, .Both)
}
