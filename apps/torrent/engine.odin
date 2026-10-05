package main

// The engine: one poll loop driving every peer of every torrent.
//
// It runs on its own thread so the UI never waits for the network, and the UI
// reads it through `engine_snapshot`, which copies a plain struct under the
// mutex. Commands go the other way through a queue. Nothing in `ui.odin`
// touches a socket, a file or a piece buffer.
//
// The loop is: drain commands, build the pollfd array, poll, read what is
// readable, act on the messages, decide what to request, flush what is
// writable, run the periodic work (announce, keep-alive, rates). Sockets are
// non-blocking throughout, so no step can stall the others — which is the
// difference between a client that handles fifty peers and one that handles
// the first.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"

MAX_PEERS_PER_TORRENT :: 50
MAX_UNCHOKED :: 8
KEEPALIVE_EVERY :: 90.0
PEER_IDLE_TIMEOUT :: 180.0
HANDSHAKE_TIMEOUT :: 15.0
OUT_BUF_HIGH_WATER :: 2 << 20
READ_PER_STEP :: 512 * 1024
RATE_WINDOW :: 1.0
RATE_HISTORY :: 180

Torrent_State :: enum u8 {
	Stopped,
	Checking,
	Downloading,
	Seeding,
	Error,
}

torrent_state_name :: proc(s: Torrent_State) -> string {
	switch s {
	case .Stopped:
		return "Paused"
	case .Checking:
		return "Checking"
	case .Downloading:
		return "Downloading"
	case .Seeding:
		return "Seeding"
	case .Error:
		return "Error"
	}
	return "?"
}

Block_Req :: struct {
	index:  int,
	begin:  int,
	length: int,
	at:     f64,
}

Peer :: struct {
	sock:            Sock,
	host:            string,
	port:            int,
	incoming:        bool,
	in_:             Framer,
	out:             [dynamic]u8,
	sent_handshake:  bool,
	handshaked:      bool,
	peer_id:         [20]u8,
	client:          string,

	// BEP 10. `peer_ext` is what the peer's reserved bytes claimed;
	// `ext_sent` stops us sending our own extension handshake twice;
	// `peer_ut_metadata` is the id THE PEER asked us to send ut_metadata on,
	// which is not the id we asked for. `peer_offered_pex` is recorded and
	// never acted on — there is no code in this program that reads a peer
	// exchange payload, and the peers tab says so.
	peer_ext:        bool,
	ext_sent:        bool,
	peer_ut_metadata: int,
	peer_offered_pex: bool,
	ext_client:      string,
	meta_served:     int, // metadata pieces handed out, for the peers tab

	// The four state bits of the protocol. Both sides start choked and
	// uninterested, and a client that assumes otherwise sends requests that are
	// silently dropped.
	am_choking:      bool,
	am_interested:   bool,
	peer_choking:    bool,
	peer_interested: bool,
	bits:            Bitfield,
	counted:         bool,
	seed:            bool, // has every piece

	inflight:        [dynamic]Block_Req,
	serving:         [dynamic]Block_Req,

	down:            i64,
	up:              i64,
	down_rate:       f64,
	up_rate:         f64,
	down_mark:       i64,
	up_mark:         i64,
	rate_at:         f64,

	born:            f64,
	last_recv:       f64,
	last_send:       f64,
	dead:            bool,
	err:             string,
}

Tracker_State :: struct {
	url:        string,
	next_at:    f64,
	interval:   int,
	last_err:   string,
	last_ok_at: f64,
	seeders:    int,
	leechers:   int,
	announces:  int,
	pending_ev: Announce_Event,
	sent_start: bool,
}

Torrent :: struct {
	id:             int,
	meta:           Metainfo,
	store:          Storage,
	have:           Bitfield,
	pk:             Picker,
	peers:          [dynamic]Peer,
	trackers:       [dynamic]Tracker_State,
	state:          Torrent_State,
	err:            string,

	torrent_path:   string,
	dir:            string,

	downloaded:     i64, // verified payload bytes this session
	uploaded:       i64,
	wasted:         i64, // bytes that failed a hash check
	down_rate:      f64,
	up_rate:        f64,
	down_mark:      i64,
	up_mark:        i64,
	rate_at:        f64,
	down_hist:      [RATE_HISTORY]f32,
	up_hist:        [RATE_HISTORY]f32,
	hist_n:         int,
	hist_at:        f64,

	pieces_verified: int, // pieces that passed SHA-1 and were written
	check_done:     int,
	check_total:    int,
	check_pos:      int, // the incremental recheck's cursor
	check_buf:      []u8,

	added_at:       f64,
	completed_at:   f64,
	announced_done: bool,

	// Download budget, in bytes, for the optional rate limit.
	budget:         f64,
	budget_at:      f64,
	// Upload budget. Separate from the download one because the two limits
	// are set independently and a seeder has no download budget to spend.
	up_budget:      f64,
	up_budget_at:   f64,
	// Blocks that were asked for and are waiting on the upload budget rather
	// than on the disk. Shown in the UI so a throttled transfer does not look
	// like a stalled one.
	up_deferred:    int,

	// The unchoke decision runs on a short cadence; the optimistic slot rotates
	// on a long one and is remembered by peer id, because peer indices move
	// when a connection is reaped.
	unchoke_at:     f64,
	optimistic_at:  f64,
	optimistic_id:  [20]u8,
}

Engine_Cmd_Kind :: enum {
	Add,
	Add_Magnet,
	Start,
	Stop,
	Recheck,
	Remove,
	Remove_With_Data,
	Set_Priority,
	Quit,
}

Engine_Cmd :: struct {
	kind:    Engine_Cmd_Kind,
	id:      int,
	path:    string, // Add: the .torrent
	dir:     string, // Add: the download directory
	file:    int,
	prio:    File_Prio,
	start:   bool,
}

Engine :: struct {
	mu:          sync.Mutex,
	torrents:    [dynamic]^Torrent,
	next_id:     int,
	listener:    Sock,
	port:        int,
	peer_id:     [20]u8,
	cmds:        [dynamic]Engine_Cmd,
	stop:        bool,
	running:     bool,
	thr:         ^thread.Thread,
	down_limit:  int, // bytes per second; 0 is unlimited
	up_limit:    int,
	verbose:     bool,
	last_error:  string,
	rng:         Xorshift,

	// Connections that have arrived but have not yet said which torrent they
	// want. See `Pending`.
	pending:     [dynamic]Pending,
	// One scratch buffer for serving blocks, rather than one per peer per step.
	serve_buf:   []u8,
}

// Pending is an incoming connection whose handshake has not arrived yet.
//
// A peer that dials us does not say which torrent it wants until its handshake,
// so the connection cannot be attached to one before then. Parking it on
// whichever torrent happens to be first and hoping is how a client with two
// torrents drops half its inbound peers.
Pending :: struct {
	sock: Sock,
	host: string,
	port: int,
	in_:  Framer,
	born: f64,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

engine_init :: proc(e: ^Engine, port: int, seed: u64) -> (err: string) {
	e.torrents = make([dynamic]^Torrent, 0, 4)
	e.cmds = make([dynamic]Engine_Cmd, 0, 8)
	e.pending = make([dynamic]Pending, 0, 4)
	e.serve_buf = make([]u8, MAX_MESSAGE)
	e.peer_id = peer_id_new(seed)
	e.rng = xs_init(seed ~ 0xA5A5)
	l, bound, lerr := sock_listen("127.0.0.1", port)
	if lerr != "" {
		return lerr
	}
	e.listener = l
	e.port = bound
	return ""
}

engine_destroy :: proc(e: ^Engine) {
	for t in e.torrents {
		torrent_destroy(t)
		free(t)
	}
	delete(e.torrents)
	delete(e.cmds)
	for &pd in e.pending {
		pending_close(&pd)
	}
	delete(e.pending)
	delete(e.serve_buf)
	sock_close(e.listener)
}

// pending_close releases the connection and marks the slot dead by setting the
// socket to SOCK_INVALID.
//
// It must NOT zero the struct. `Sock` is a file descriptor and its zero value
// is 0, which is a perfectly good descriptor — stdin, at first. A slot zeroed
// here looked "closed" to nobody and was closed a second time by the sweep,
// which closed fd 0; the next socket the process opened was handed fd 0 and
// was then closed by the *next* sweep. The symptom was a peer connection that
// vanished some seconds after an unrelated connection had been dropped, with
// nothing in any log.
@(private = "file")
pending_close :: proc(pd: ^Pending) {
	if pd.sock != SOCK_INVALID {
		sock_close(pd.sock)
		pd.sock = SOCK_INVALID
	}
	framer_destroy(&pd.in_)
	delete(pd.host)
	pd.host = ""
}

engine_start_thread :: proc(e: ^Engine) {
	e.running = true
	e.thr = thread.create_and_start_with_data(rawptr(e), proc(data: rawptr) {
		en := cast(^Engine)data
		for {
			sync.lock(&en.mu)
			stop := en.stop
			sync.unlock(&en.mu)
			if stop {
				break
			}
			engine_step(en, 50)
			free_all(context.temp_allocator)
		}
		sync.lock(&en.mu)
		en.running = false
		sync.unlock(&en.mu)
	})
}

engine_request_quit :: proc(e: ^Engine) {
	sync.lock(&e.mu)
	e.stop = true
	sync.unlock(&e.mu)
}

// engine_shutdown announces `stopped` to every tracker and closes every socket.
// Doing this is what keeps a tracker's swarm list honest, and it is the step
// most clients skip.
engine_shutdown :: proc(e: ^Engine) {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	for t in e.torrents {
		if t.state == .Stopped || t.state == .Error {
			continue
		}
		torrent_announce_all(e, t, .Stopped)
	}
	for t in e.torrents {
		for i := len(t.peers) - 1; i >= 0; i -= 1 {
			peer_kill(t, i, "shutting down")
		}
	}
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

engine_post :: proc(e: ^Engine, cmd: Engine_Cmd) {
	sync.lock(&e.mu)
	append(&e.cmds, cmd)
	sync.unlock(&e.mu)
}

@(private = "file")
engine_drain_cmds :: proc(e: ^Engine) {
	if len(e.cmds) == 0 {
		return
	}
	cmds := make([]Engine_Cmd, len(e.cmds), context.temp_allocator)
	copy(cmds, e.cmds[:])
	clear(&e.cmds)
	for c in cmds {
		switch c.kind {
		case .Add:
			if _, err := engine_add_locked(e, c.path, c.dir, c.start); err != "" {
				e.last_error = strings.clone(err)
				fmt.eprintfln("torrent: %s", err)
			}
			delete(c.path)
			delete(c.dir)
		case .Add_Magnet:
			// This runs on the engine thread, not the UI's, for the same
			// reason the announce does: it talks to a socket and the window
			// must not wait for it. The engine's own step is allowed to
			// block, because every address it can reach is on loopback.
			if err := engine_add_magnet_locked(e, c.path, c.dir, c.start); err != "" {
				e.last_error = strings.clone(err)
				fmt.eprintfln("torrent: %s", err)
			}
			delete(c.path)
			delete(c.dir)
		case .Start:
			if t := engine_find(e, c.id); t != nil && t.state == .Stopped {
				torrent_start(e, t)
			}
		case .Stop:
			if t := engine_find(e, c.id); t != nil {
				torrent_stop(e, t)
			}
		case .Recheck:
			if t := engine_find(e, c.id); t != nil {
				torrent_begin_check(e, t)
			}
		case .Remove, .Remove_With_Data:
			engine_remove_locked(e, c.id, c.kind == .Remove_With_Data)
		case .Set_Priority:
			if t := engine_find(e, c.id); t != nil {
				if c.file >= 0 && c.file < len(t.store.prio) {
					t.store.prio[c.file] = c.prio
				}
			}
		case .Quit:
			e.stop = true
		}
	}
}

// engine_set_error replaces the last error, freeing the previous one. The UI
// reads it through the snapshot, which clones it into the frame arena.
engine_set_error :: proc(e: ^Engine, msg: string) {
	if e.last_error != "" {
		delete(e.last_error)
	}
	e.last_error = strings.clone(msg)
}

engine_find :: proc(e: ^Engine, id: int) -> ^Torrent {
	for t in e.torrents {
		if t.id == id {
			return t
		}
	}
	return nil
}

engine_add_magnet :: proc(e: ^Engine, uri, dir: string, start := true) {
	engine_post(
		e,
		Engine_Cmd {
			kind = .Add_Magnet,
			path = strings.clone(uri),
			dir = strings.clone(dir),
			start = start,
		},
	)
}

engine_add :: proc(e: ^Engine, torrent_path, dir: string, start := true) {
	engine_post(
		e,
		Engine_Cmd {
			kind = .Add,
			path = strings.clone(torrent_path),
			dir = strings.clone(dir),
			start = start,
		},
	)
}

@(private = "file")
engine_add_locked :: proc(
	e: ^Engine,
	torrent_path, dir: string,
	start: bool,
) -> (
	t: ^Torrent,
	err: string,
) {
	m, merr := metainfo_load(torrent_path)
	if merr != "" {
		return nil, merr
	}
	for existing in e.torrents {
		if hash20_eq(existing.meta.info_hash, m.info_hash) {
			mm := m
			metainfo_destroy(&mm)
			return nil, tsprint("%s is already in the list", m.name)
		}
	}
	nt := new(Torrent)
	e.next_id += 1
	nt.id = e.next_id
	nt.meta = m
	nt.torrent_path = strings.clone(torrent_path)
	nt.dir = strings.clone(dir)
	nt.peers = make([dynamic]Peer, 0, 8)
	nt.trackers = make([dynamic]Tracker_State, 0, 2)
	nt.have = bf_make(piece_count(&nt.meta))
	nt.added_at = now_s()
	picker_init(&nt.pk, &nt.meta)

	if serr := storage_open(&nt.store, &nt.meta, dir); serr != "" {
		nt.state = .Error
		nt.err = strings.clone(serr)
	} else if cerr := storage_create_files(&nt.store); cerr != "" {
		nt.state = .Error
		nt.err = strings.clone(cerr)
	}
	for url in nt.meta.announce_list {
		// A tracker URL this client is not allowed to reach is recorded with
		// its refusal rather than quietly dropped, so the UI can show why.
		append(&nt.trackers, Tracker_State{url = strings.clone(url), next_at = now_s()})
	}
	append(&e.torrents, nt)

	if nt.state != .Error {
		torrent_begin_check(e, nt)
		if !start {
			nt.state = .Stopped
			nt.check_total = 0
		}
	}
	return nt, ""
}

// engine_add_magnet_locked resolves a magnet and then adds it as an ordinary
// torrent.
//
// The order matters. A .torrent already in the state directory wins, because
// it costs nothing and is already verified; only when there is none does this
// go to the wire, and even then the bytes are not believed until SHA-1 over
// them matches the hash the user's own link carried. The resolved metadata is
// written back into the state directory, so the same magnet resolves locally
// ever after.
@(private = "file")
engine_add_magnet_locked :: proc(e: ^Engine, uri, dir: string, start: bool) -> (err: string) {
	mg, perr := magnet_parse(uri, context.temp_allocator)
	if perr != "" {
		return perr
	}
	hex := hash20_hex(mg.info_hash, context.temp_allocator)
	cached := path_join(
		state_dir(context.temp_allocator),
		tsprint("%s.torrent", hex),
		allocator = context.temp_allocator,
	)
	if path_exists(cached) {
		_, aerr := engine_add_locked(e, cached, dir, start)
		return aerr
	}
	res, rerr := magnet_resolve(mg, e.peer_id, e.port, METAFETCH_TIMEOUT_MS, context.temp_allocator)
	if rerr != "" {
		detail := ""
		if len(res.notes) > 0 {
			detail = tsprint(" (%s)", res.notes[0])
		}
		return tsprint("cannot resolve %s: %s%s", hex[:12], rerr, detail)
	}
	if werr := write_file(cached, res.torrent); werr != "" {
		return werr
	}
	if e.verbose {
		fmt.eprintfln(
			"torrent: resolved %s over BEP 9 from %s:%d, %d bytes of metadata, verified against the magnet's own hash",
			hex[:12],
			res.from_host,
			res.from_port,
			len(res.torrent),
		)
	}
	_, aerr := engine_add_locked(e, cached, dir, start)
	return aerr
}

@(private = "file")
engine_remove_locked :: proc(e: ^Engine, id: int, with_data: bool) {
	for i in 0 ..< len(e.torrents) {
		t := e.torrents[i]
		if t.id != id {
			continue
		}
		torrent_announce_all(e, t, .Stopped)
		for j := len(t.peers) - 1; j >= 0; j -= 1 {
			peer_kill(t, j, "removed")
		}
		if with_data {
			// The only call site. The UI only reaches it through a
			// confirmation that names the paths.
			if derr := storage_delete_data(&t.store); derr != "" {
				engine_set_error(e, derr)
			}
		}
		torrent_destroy(t)
		free(t)
		ordered_remove(&e.torrents, i)
		return
	}
}

torrent_destroy :: proc(t: ^Torrent) {
	for i := len(t.peers) - 1; i >= 0; i -= 1 {
		peer_kill(t, i, "")
	}
	delete(t.peers)
	for &tr in t.trackers {
		delete(tr.url)
		delete(tr.last_err)
	}
	delete(t.trackers)
	picker_destroy(&t.pk)
	storage_destroy(&t.store)
	bf_destroy(&t.have)
	metainfo_destroy(&t.meta)
	delete(t.torrent_path)
	delete(t.dir)
	delete(t.err)
	if t.check_buf != nil {
		delete(t.check_buf)
	}
}

// ---------------------------------------------------------------------------
// Torrent state transitions
// ---------------------------------------------------------------------------

torrent_begin_check :: proc(e: ^Engine, t: ^Torrent) {
	if t.state == .Error {
		return
	}
	for i := len(t.peers) - 1; i >= 0; i -= 1 {
		peer_kill(t, i, "rechecking")
	}
	for i in 0 ..< len(t.pk.avail) {
		t.pk.avail[i] = 0
	}
	for i := len(t.pk.active) - 1; i >= 0; i -= 1 {
		picker_drop(&t.pk, t.pk.active[i].index)
	}
	t.state = .Checking
	t.check_pos = 0
	t.check_done = 0
	t.check_total = piece_count(&t.meta)
	if t.check_buf == nil {
		t.check_buf = make([]u8, int(t.meta.piece_length))
	}
	for i in 0 ..< t.have.n {
		bf_set(&t.have, i, false)
	}
}

// torrent_check_slice hashes a few pieces per engine step, so a recheck of a
// large torrent does not freeze the loop — and so the UI's progress bar moves.
@(private = "file")
torrent_check_slice :: proc(e: ^Engine, t: ^Torrent, budget: int) {
	n := piece_count(&t.meta)
	done := 0
	for t.check_pos < n && done < budget {
		ok := storage_verify_piece(&t.store, t.check_pos, t.check_buf)
		bf_set(&t.have, t.check_pos, ok)
		t.check_pos += 1
		t.check_done = t.check_pos
		done += 1
	}
	if t.check_pos >= n {
		t.check_total = 0
		t.pieces_verified = bf_count(t.have)
		torrent_start(e, t)
	}
}

torrent_start :: proc(e: ^Engine, t: ^Torrent) {
	if t.state == .Error {
		return
	}
	complete := bf_complete(t.have)
	t.state = complete ? .Seeding : .Downloading
	if complete && t.completed_at == 0 {
		t.completed_at = now_s()
	}
	now := now_s()
	for &tr in t.trackers {
		tr.next_at = now
		if !tr.sent_start {
			tr.pending_ev = .Started
		}
	}
}

torrent_stop :: proc(e: ^Engine, t: ^Torrent) {
	torrent_announce_all(e, t, .Stopped)
	for i := len(t.peers) - 1; i >= 0; i -= 1 {
		peer_kill(t, i, "paused")
	}
	for &tr in t.trackers {
		tr.sent_start = false
	}
	t.state = .Stopped
	t.check_total = 0
}

torrent_live_peers :: proc(t: ^Torrent) -> int {
	n := 0
	for &pr in t.peers {
		if !pr.dead && pr.handshaked {
			n += 1
		}
	}
	return n
}

torrent_left :: proc(t: ^Torrent) -> i64 {
	left: i64 = 0
	for i in 0 ..< piece_count(&t.meta) {
		if !bf_get(t.have, i) && piece_wanted(&t.store, i) {
			left += piece_size(&t.meta, i)
		}
	}
	return left
}

torrent_progress :: proc(t: ^Torrent) -> f32 {
	n := piece_count(&t.meta)
	if n == 0 {
		return 0
	}
	// Progress counts only the pieces that are wanted, so a torrent with a file
	// set to "don't download" can reach 100%.
	want, got := 0, 0
	for i in 0 ..< n {
		if !piece_wanted(&t.store, i) {
			continue
		}
		want += 1
		if bf_get(t.have, i) {
			got += 1
		}
	}
	if want == 0 {
		return 1
	}
	return f32(got) / f32(want)
}

// ---------------------------------------------------------------------------
// The step
// ---------------------------------------------------------------------------

engine_step :: proc(e: ^Engine, timeout_ms: i32) {
	// The pollfd array is built under the lock, polled without it (so the UI is
	// never blocked for the length of a timeout), and the results are applied
	// under the lock again.
	sync.lock(&e.mu)
	engine_drain_cmds(e)
	if e.stop {
		sync.unlock(&e.mu)
		return
	}

	Slot :: struct {
		t:    int,
		p:    int,
	}
	fds := make([dynamic]linux.Poll_Fd, 0, 16, context.temp_allocator)
	slots := make([dynamic]Slot, 0, 16, context.temp_allocator)
	append(&fds, linux.Poll_Fd{fd = linux.Fd(e.listener), events = {.IN}})
	append(&slots, Slot{t = -1, p = -1})
	npending := len(e.pending)
	for &pd in e.pending {
		append(&fds, linux.Poll_Fd{fd = linux.Fd(pd.sock), events = {.IN}})
		append(&slots, Slot{t = -2, p = -1})
	}
	for t, ti in e.torrents {
		for &pr, pi in t.peers {
			if pr.dead {
				continue
			}
			ev: linux.Fd_Poll_Events = {.IN}
			if len(pr.out) > 0 {
				ev += {.OUT}
			}
			append(&fds, linux.Poll_Fd{fd = linux.Fd(pr.sock), events = ev})
			append(&slots, Slot{t = ti, p = pi})
		}
	}
	sync.unlock(&e.mu)

	poll_wait(fds[:], timeout_ms)

	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)
	now := now_s()

	// Incoming connections. A peer that dials us does not yet say which torrent
	// it wants, so its handshake decides: the info-hash in it selects the
	// torrent, and no match means the connection is dropped.
	if .IN in fds[0].revents {
		for {
			s, host, port, ok := sock_accept(e.listener)
			if !ok {
				break
			}
			if len(e.pending) >= 16 {
				sock_close(s)
				continue
			}
			pd := Pending {
				sock = s,
				host = strings.clone(host),
				port = port,
				born = now,
			}
			framer_init(&pd.in_)
			append(&e.pending, pd)
		}
	}

	// Pending connections, in the slots between the listener and the peers.
	for pi in 0 ..< npending {
		if pi >= len(e.pending) {
			break
		}
		rev := fds[1 + pi].revents
		if .IN in rev {
			engine_pending_read(e, pi)
		} else if .HUP in rev || .ERR in rev {
			pending_close(&e.pending[pi])
		}
	}
	for i := len(e.pending) - 1; i >= 0; i -= 1 {
		pd := &e.pending[i]
		if pd.sock == SOCK_INVALID {
			unordered_remove(&e.pending, i) // closed, or adopted by a torrent
		} else if now - pd.born > HANDSHAKE_TIMEOUT {
			pending_close(pd)
			unordered_remove(&e.pending, i)
		}
	}

	for sl, i in slots {
		if sl.t < 0 {
			continue
		}
		if sl.t >= len(e.torrents) {
			continue
		}
		t := e.torrents[sl.t]
		if sl.p >= len(t.peers) {
			continue
		}
		pr := &t.peers[sl.p]
		if pr.dead {
			continue
		}
		rev := fds[i].revents
		if .OUT in rev {
			peer_flush(pr)
		}
		if .IN in rev {
			peer_pump_read(e, t, sl.p)
		} else if (.HUP in rev || .ERR in rev) && len(pr.out) == 0 {
			peer_set_dead(pr, "the peer closed the connection")
		}
	}

	for t in e.torrents {
		torrent_tick(e, t, now)
	}
	engine_reap(e)
}

@(private = "file")
engine_reap :: proc(e: ^Engine) {
	for t in e.torrents {
		for i := len(t.peers) - 1; i >= 0; i -= 1 {
			if t.peers[i].dead {
				peer_kill(t, i, "")
			}
		}
	}
}

// engine_pending_read waits for an incoming connection's handshake and then
// attaches it to the torrent its info-hash names — or closes it, if we are not
// serving that torrent.
@(private = "file")
engine_pending_read :: proc(e: ^Engine, pi: int) {
	pd := &e.pending[pi]
	buf: [8192]u8
	for {
		n, st := sock_read(pd.sock, buf[:])
		if st == .Ok {
			framer_feed(&pd.in_, buf[:n])
			if framer_buffered(&pd.in_) > 4 * HANDSHAKE_LEN {
				pending_close(pd)
				return
			}
			continue
		}
		if st == .Again {
			break
		}
		pending_close(pd)
		return
	}

	want: Hash20 // unused: the handshake decides
	h, st := framer_take_handshake(&pd.in_, want, false)
	if st == .Incomplete {
		return
	}
	if st == .Bad {
		pending_close(pd)
		return
	}
	// Which torrent did it ask for?
	target: ^Torrent
	for t in e.torrents {
		if hash20_eq(t.meta.info_hash, h.info_hash) {
			target = t
			break
		}
	}
	if target == nil ||
	   (target.state != .Downloading && target.state != .Seeding) ||
	   len(target.peers) >= MAX_PEERS_PER_TORRENT ||
	   h.peer_id == e.peer_id {
		pending_close(pd)
		return
	}
	for &other in target.peers {
		if !other.dead && other.handshaked && other.peer_id == h.peer_id {
			// Already talking to this peer on another socket; see
			// `peer_id_less` for which of the two survives.
			if peer_id_less(e.peer_id, h.peer_id) {
				pending_close(pd)
				return
			}
			peer_set_dead(&other, "a duplicate connection to the same peer")
		}
	}

	// Move the framer across, so whatever arrived after the handshake in the
	// same read is not lost.
	pr := Peer {
		sock           = pd.sock,
		host           = pd.host,
		port           = pd.port,
		incoming       = true,
		in_            = pd.in_,
		handshaked     = true,
		peer_id        = h.peer_id,
		client         = peer_client_name(h.peer_id),
		am_choking     = true,
		peer_choking   = true,
		born           = now_s(),
		last_recv      = now_s(),
		out            = make([dynamic]u8, 0, 4096),
		inflight       = make([dynamic]Block_Req, 0, PIPELINE_DEPTH),
		serving        = make([dynamic]Block_Req, 0, 8),
	}
	pr.bits = bf_make(piece_count(&target.meta))
	pr.peer_ext = reserved_has_extensions(h.reserved)
	hs := handshake_encode(target.meta.info_hash, e.peer_id, context.temp_allocator, extended = true)
	append(&pr.out, ..hs)
	pr.sent_handshake = true
	peer_send_ext_handshake(target, &pr)
	if bf_count(target.have) > 0 {
		msg_bitfield(&pr.out, target.have)
	}
	pr.last_send = now_s()
	append(&target.peers, pr)
	peer_flush(&target.peers[len(target.peers) - 1])

	// Adopted. The socket, the framer and the host string now belong to the
	// Peer, so the slot is marked dead WITHOUT closing or freeing any of them;
	// the sweep below removes it.
	pd.sock = SOCK_INVALID
	pd.in_ = {}
	pd.host = ""
}

// ---------------------------------------------------------------------------
// Per-torrent periodic work
// ---------------------------------------------------------------------------

@(private = "file")
torrent_tick :: proc(e: ^Engine, t: ^Torrent, now: f64) {
	if t.state == .Checking {
		torrent_check_slice(e, t, 24)
		return
	}
	if t.state == .Stopped || t.state == .Error {
		return
	}

	// Rates, measured over a window rather than per frame, so the number on
	// screen is steady enough to read.
	if t.rate_at == 0 {
		t.rate_at = now
		t.down_mark = t.downloaded
		t.up_mark = t.uploaded
	} else if now - t.rate_at >= RATE_WINDOW {
		dt := now - t.rate_at
		t.down_rate = f64(t.downloaded - t.down_mark) / dt
		t.up_rate = f64(t.uploaded - t.up_mark) / dt
		t.down_mark = t.downloaded
		t.up_mark = t.uploaded
		t.rate_at = now
		for &pr in t.peers {
			pdt := now - pr.rate_at
			if pr.rate_at > 0 && pdt > 0 {
				pr.down_rate = f64(pr.down - pr.down_mark) / pdt
				pr.up_rate = f64(pr.up - pr.up_mark) / pdt
			}
			pr.down_mark = pr.down
			pr.up_mark = pr.up
			pr.rate_at = now
		}
	}
	if now - t.hist_at >= 1.0 {
		t.hist_at = now
		idx := t.hist_n % RATE_HISTORY
		t.down_hist[idx] = f32(t.down_rate)
		t.up_hist[idx] = f32(t.up_rate)
		t.hist_n += 1
	}

	// The download budget: a token bucket refilled from the wall clock, not
	// from an assumed step length, because a step takes however long it takes.
	// Requests are withheld when it runs dry — the loop is never slept, so the
	// limit shapes the transfer rather than freezing the client.
	if e.down_limit > 0 {
		if t.budget_at == 0 {
			t.budget_at = now
		}
		dt := now - t.budget_at
		t.budget_at = now
		burst := f64(e.down_limit) * 1.0
		t.budget = min(t.budget + f64(e.down_limit) * dt, burst)
	}

	// The upload budget, the same shape and for the same reason. The
	// asymmetry worth knowing: withholding a REQUEST shapes the download,
	// because the peer sends only what we asked for. Withholding a PIECE
	// shapes the upload, because the peer already asked and the request sits
	// in `serving` until there is budget to answer it. Neither sleeps the
	// loop, so one throttled torrent does not slow the others down.
	if e.up_limit > 0 {
		if t.up_budget_at == 0 {
			t.up_budget_at = now
			// Start with one second of credit rather than zero, so the first
			// block out does not wait for a refill that has not happened yet.
			t.up_budget = f64(e.up_limit)
		}
		dt := now - t.up_budget_at
		t.up_budget_at = now
		burst := f64(e.up_limit) * 1.0
		t.up_budget = min(t.up_budget + f64(e.up_limit) * dt, burst)
	} else {
		t.up_budget_at = 0
		t.up_deferred = 0
	}

	torrent_tracker_tick(e, t, now)
	picker_release_timed_out(&t.pk, now)
	picker_update_endgame(&t.pk, t.have)
	torrent_unchoke_tick(e, t, now)

	for &pr, i in t.peers {
		if pr.dead {
			continue
		}
		if !pr.handshaked {
			if now - pr.born > HANDSHAKE_TIMEOUT {
				peer_set_dead(&pr, "no handshake within 15s")
			}
			continue
		}
		if now - pr.last_recv > PEER_IDLE_TIMEOUT {
			peer_set_dead(&pr, "idle for three minutes")
			continue
		}
		if now - pr.last_send > KEEPALIVE_EVERY {
			msg_keep_alive(&pr.out)
			pr.last_send = now
		}
		peer_update_interest(t, &pr)
		peer_serve_requests(e, t, &pr)
		if t.state == .Downloading {
			peer_fill_pipeline(e, t, &pr, now)
		}
		peer_flush(&pr)
		_ = i
	}
}

@(private = "file")
torrent_tracker_tick :: proc(e: ^Engine, t: ^Torrent, now: f64) {
	for &tr in t.trackers {
		if now < tr.next_at {
			continue
		}
		ev := tr.pending_ev
		if ev == .Started && tr.sent_start {
			ev = .None
		}
		req := Announce_Req {
			info_hash  = t.meta.info_hash,
			peer_id    = e.peer_id,
			port       = e.port,
			uploaded   = t.uploaded,
			downloaded = t.downloaded,
			left       = torrent_left(t),
			event      = ev,
			numwant    = 50,
			key        = u32(xs_next(&e.rng)),
		}
		// Announcing blocks this step for as long as the tracker takes. On
		// loopback that is sub-millisecond; against anything slower this would
		// have to move to its own thread, and the honest note is that it has
		// not, because it cannot reach anything slower.
		resp, aerr := tracker_announce(tr.url, req, 3000, context.temp_allocator)
		tr.announces += 1
		if aerr != "" {
			delete(tr.last_err)
			tr.last_err = strings.clone(aerr)
			tr.next_at = now + 30
			continue
		}
		if resp.failure != "" {
			delete(tr.last_err)
			tr.last_err = strings.clone(resp.failure)
			tr.next_at = now + 30
			continue
		}
		delete(tr.last_err)
		tr.last_err = ""
		tr.last_ok_at = now
		tr.interval = resp.interval
		tr.seeders = resp.complete
		tr.leechers = resp.incomplete
		if ev == .Started {
			tr.sent_start = true
		}
		tr.pending_ev = .None
		// `interval` is honoured, not ignored — except that a tracker's
		// `min interval` exists precisely so a client with no peers can ask
		// again sooner, and a leecher with nobody to talk to should.
		wait := f64(max(resp.interval, 1))
		if t.state == .Downloading && torrent_live_peers(t) == 0 && resp.min_interval > 0 {
			wait = f64(resp.min_interval)
		}
		tr.next_at = now + wait

		for pa in resp.peers {
			torrent_note_peer(e, t, pa.host, pa.port)
		}
	}
}

// torrent_note_peer dials a candidate the tracker named, through the gate in
// `sock_connect` — which is where a routable address from a compact peer list
// dies.
@(private = "file")
torrent_note_peer :: proc(e: ^Engine, t: ^Torrent, host: string, port: int) {
	if port == e.port && host == "127.0.0.1" {
		return // ourselves
	}
	for &pr in t.peers {
		if pr.host == host && pr.port == port {
			return
		}
	}
	if len(t.peers) >= MAX_PEERS_PER_TORRENT {
		return
	}
	peer_connect(e, t, host, port)
}

// torrent_unchoke_tick decides who may ask us for data.
//
// The real algorithm ranks peers by how fast they upload to us and rotates an
// optimistic slot every thirty seconds. This one keeps the rotation and ranks
// by upload rate, which is enough to be fair and is honestly simpler than
// libtorrent's.
@(private = "file")
torrent_unchoke_tick :: proc(e: ^Engine, t: ^Torrent, now: f64) {
	// Once a second. This used to be once every ten, and the cost was exactly
	// what you would predict: a leecher connected, said `interested`, and then
	// sat choked for up to ten seconds before the seeder next looked. A
	// transfer that takes two seconds spent eighty per cent of its life idle.
	if t.unchoke_at != 0 && now - t.unchoke_at < 1.0 {
		return
	}
	t.unchoke_at = now

	Cand :: struct {
		idx:  int,
		rate: f64,
	}
	cands := make([dynamic]Cand, 0, len(t.peers), context.temp_allocator)
	for &pr, i in t.peers {
		if pr.dead || !pr.handshaked || !pr.peer_interested {
			continue
		}
		append(&cands, Cand{idx = i, rate = pr.down_rate})
	}
	// Highest contributor first; a tie keeps the earlier connection. An
	// insertion sort, because this list is at most a few dozen long and runs
	// every second.
	for i in 1 ..< len(cands) {
		j := i
		for j > 0 && cands[j].rate > cands[j - 1].rate {
			cands[j], cands[j - 1] = cands[j - 1], cands[j]
			j -= 1
		}
	}

	allowed := make(map[int]bool, MAX_UNCHOKED, context.temp_allocator)
	for k in 0 ..< min(MAX_UNCHOKED - 1, len(cands)) {
		allowed[cands[k].idx] = true
	}
	// The optimistic slot: one peer chosen at random and kept for twenty
	// seconds, which is how a peer that has never had a chance to prove itself
	// gets one. It is remembered by peer id rather than by index.
	if len(cands) > MAX_UNCHOKED - 1 {
		still_there := -1
		for c in cands {
			if t.peers[c.idx].peer_id == t.optimistic_id {
				still_there = c.idx
				break
			}
		}
		if still_there < 0 || now - t.optimistic_at > 20 {
			pick := cands[int(xs_next(&e.rng) % u64(len(cands)))]
			t.optimistic_id = t.peers[pick.idx].peer_id
			t.optimistic_at = now
			still_there = pick.idx
		}
		allowed[still_there] = true
	}

	for &pr, i in t.peers {
		if pr.dead || !pr.handshaked {
			continue
		}
		want_unchoked := i in allowed
		if want_unchoked && pr.am_choking {
			msg_simple(&pr.out, .Unchoke)
			pr.am_choking = false
			pr.last_send = now
		} else if !want_unchoked && !pr.am_choking && pr.peer_interested {
			msg_simple(&pr.out, .Choke)
			pr.am_choking = true
			pr.last_send = now
			clear(&pr.serving)
		}
	}
}

// ---------------------------------------------------------------------------
// Peers
// ---------------------------------------------------------------------------

peer_connect :: proc(e: ^Engine, t: ^Torrent, host: string, port: int) {
	// The gate. A routable address from a compact peer list dies here.
	s, cerr := sock_connect(host, port)
	if cerr != "" {
		if e.verbose {
			fmt.eprintfln("torrent: %s", cerr)
		}
		return
	}
	pr := Peer {
		sock         = s,
		host         = strings.clone(host),
		port         = port,
		am_choking   = true,
		peer_choking = true,
		born         = now_s(),
		last_recv    = now_s(),
		out          = make([dynamic]u8, 0, 4096),
		inflight     = make([dynamic]Block_Req, 0, PIPELINE_DEPTH),
		serving      = make([dynamic]Block_Req, 0, 8),
	}
	framer_init(&pr.in_)
	pr.bits = bf_make(piece_count(&t.meta))
	hs := handshake_encode(t.meta.info_hash, e.peer_id, context.temp_allocator, extended = true)
	append(&pr.out, ..hs)
	pr.sent_handshake = true
	pr.last_send = now_s()
	append(&t.peers, pr)
	peer_flush(&t.peers[len(t.peers) - 1])
}

// peer_id_less orders two peer ids by raw bytes, so both ends of a duplicated
// connection pick the same one to keep without having to negotiate.
peer_id_less :: proc(a, b: [20]u8) -> bool {
	for i in 0 ..< 20 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

peer_set_dead :: proc(pr: ^Peer, why: string) {
	if pr.dead {
		return
	}
	pr.dead = true
	if pr.err == "" && why != "" {
		pr.err = strings.clone(why)
	}
}

peer_kill :: proc(t: ^Torrent, i: int, why: string) {
	if i < 0 || i >= len(t.peers) {
		return
	}
	pr := &t.peers[i]
	if pr.counted {
		picker_remove_bitfield(&t.pk, pr.bits)
		pr.counted = false
	}
	// Give back whatever it was fetching, so another peer can.
	for req in pr.inflight {
		if a := picker_find(&t.pk, req.index); a != nil {
			bi := req.begin / BLOCK_SIZE
			if bi >= 0 && bi < len(a.blocks) && a.blocks[bi] == .Requested {
				a.blocks[bi] = .Missing
			}
		}
	}
	sock_close(pr.sock)
	framer_destroy(&pr.in_)
	delete(pr.out)
	delete(pr.inflight)
	delete(pr.serving)
	bf_destroy(&pr.bits)
	delete(pr.host)
	delete(pr.err)
	delete(pr.client)
	delete(pr.ext_client)
	_ = why
	unordered_remove(&t.peers, i)
}

peer_flush :: proc(pr: ^Peer) {
	for len(pr.out) > 0 {
		n, st := sock_write(pr.sock, pr.out[:])
		if st == .Ok {
			remove_range(&pr.out, 0, n)
			continue
		}
		if st == .Again {
			return
		}
		peer_set_dead(pr, "the connection failed while writing")
		return
	}
}

// peer_pump_read reads whatever is available and drains every complete message
// out of it. The loop here is the whole point of `Framer`: one `read` may have
// delivered nothing useful, part of a message, or eight messages.
@(private = "file")
peer_pump_read :: proc(e: ^Engine, t: ^Torrent, pi: int) {
	pr := &t.peers[pi]
	buf: [64 * 1024]u8
	total := 0
	for total < READ_PER_STEP {
		n, st := sock_read(pr.sock, buf[:])
		if st == .Again {
			break
		}
		if st == .Closed {
			peer_set_dead(pr, "the peer closed the connection")
			break
		}
		if st == .Error {
			peer_set_dead(pr, "the connection failed while reading")
			break
		}
		framer_feed(&pr.in_, buf[:n])
		total += n
		if n < len(buf) {
			break
		}
	}
	if total > 0 {
		pr.last_recv = now_s()
	}

	if !pr.handshaked {
		h, st := framer_take_handshake(&pr.in_, t.meta.info_hash)
		switch st {
		case .Incomplete:
			framer_compact(&pr.in_)
			return
		case .Bad:
			peer_set_dead(pr, pr.in_.err)
			return
		case .Ready:
			pr.handshaked = true
			pr.peer_id = h.peer_id
			pr.client = peer_client_name(h.peer_id)
			pr.peer_ext = reserved_has_extensions(h.reserved)
			if pr.peer_id == e.peer_id {
				peer_set_dead(pr, "that is our own peer id; we dialled ourselves")
				return
			}
			// Two clients that both learn of each other from the tracker dial
			// each other at the same moment and end up with two connections to
			// the same peer. Keep one. Whoever has the lower peer id keeps its
			// outgoing connection, which both sides agree on without talking.
			for &other, oi in t.peers {
				if oi == pi || other.dead || !other.handshaked {
					continue
				}
				if other.peer_id != pr.peer_id {
					continue
				}
				mine_lower := peer_id_less(e.peer_id, pr.peer_id)
				drop_this := pr.incoming == mine_lower
				if drop_this {
					peer_set_dead(pr, "a duplicate connection to the same peer")
					return
				}
				peer_set_dead(&other, "a duplicate connection to the same peer")
			}
			if !pr.sent_handshake {
				hs := handshake_encode(
					t.meta.info_hash,
					e.peer_id,
					context.temp_allocator,
					extended = true,
				)
				append(&pr.out, ..hs)
				pr.sent_handshake = true
			}
			// BEP 10 says the extension handshake goes first, before any
			// other extended message, and only to a peer that advertised it.
			peer_send_ext_handshake(t, pr)
			// The bitfield is optional and goes first if it goes at all. An
			// empty one is not sent: there is nothing to say.
			if bf_count(t.have) > 0 {
				msg_bitfield(&pr.out, t.have)
			}
			pr.last_send = now_s()
		}
	}

	for {
		m, st := framer_next(&pr.in_)
		if st == .Incomplete {
			break
		}
		if st == .Bad {
			peer_set_dead(pr, pr.in_.err)
			break
		}
		peer_handle(e, t, pr, m)
		if pr.dead {
			break
		}
	}
	framer_compact(&pr.in_)
}

@(private = "file")
peer_handle :: proc(e: ^Engine, t: ^Torrent, pr: ^Peer, m: Msg) {
	now := now_s()
	switch m.id {
	case .Keep_Alive:
	// nothing to do; `last_recv` was already bumped

	case .Choke:
		pr.peer_choking = true
		// Everything we had asked this peer for is now never coming. Put the
		// blocks back on the list rather than waiting for the timeout.
		for req in pr.inflight {
			if a := picker_find(&t.pk, req.index); a != nil {
				bi := req.begin / BLOCK_SIZE
				if bi >= 0 && bi < len(a.blocks) && a.blocks[bi] == .Requested {
					a.blocks[bi] = .Missing
				}
			}
		}
		clear(&pr.inflight)

	case .Unchoke:
		pr.peer_choking = false

	case .Interested:
		pr.peer_interested = true

	case .Not_Interested:
		pr.peer_interested = false

	case .Have:
		idx := int(m.index)
		if idx < 0 || idx >= piece_count(&t.meta) {
			peer_set_dead(pr, tsprint("have for piece %d, which does not exist", idx))
			return
		}
		if !bf_get(pr.bits, idx) {
			bf_set(&pr.bits, idx, true)
			if pr.counted {
				picker_add_have(&t.pk, idx)
			}
		}
		pr.seed = bf_complete(pr.bits)

	case .Bitfield:
		nb, ok := bf_from_wire(m.payload, piece_count(&t.meta), context.allocator)
		if !ok {
			// Either the wrong length, or spare bits set in the final byte.
			peer_set_dead(
				pr,
				tsprint(
					"bitfield of %d bytes is wrong for %d pieces, or its spare bits are set",
					len(m.payload),
					piece_count(&t.meta),
				),
			)
			return
		}
		if pr.counted {
			picker_remove_bitfield(&t.pk, pr.bits)
		}
		bf_destroy(&pr.bits)
		pr.bits = nb
		picker_add_bitfield(&t.pk, pr.bits)
		pr.counted = true
		pr.seed = bf_complete(pr.bits)

	case .Request:
		if pr.am_choking {
			return // a choked peer's requests are dropped, per the spec
		}
		if len(pr.serving) > 64 || len(pr.out) > OUT_BUF_HIGH_WATER {
			return
		}
		append(
			&pr.serving,
			Block_Req {
				index = int(m.index),
				begin = int(m.begin),
				length = int(m.length),
				at = now,
			},
		)

	case .Cancel:
		for i := len(pr.serving) - 1; i >= 0; i -= 1 {
			s := pr.serving[i]
			if s.index == int(m.index) && s.begin == int(m.begin) && s.length == int(m.length) {
				unordered_remove(&pr.serving, i)
			}
		}

	case .Piece:
		peer_got_block(e, t, pr, m)

	case .Port:
	// A DHT port. Noted and discarded: there is no DHT in this client, and
	// the address it points at would not be allowed anyway.

	case .Extended:
		peer_handle_extended(e, t, pr, m)
	}
}

// peer_send_ext_handshake offers exactly one extension: ut_metadata.
//
// It is sent only to a peer whose reserved bytes said it speaks BEP 10, and
// only once. `metadata_size` is the length of the info dictionary — the same
// byte range the info-hash was taken over — because a peer resolving a magnet
// cannot ask for pieces of something whose size it does not know.
@(private = "file")
peer_send_ext_handshake :: proc(t: ^Torrent, pr: ^Peer) {
	if pr.ext_sent || !pr.peer_ext {
		return
	}
	size := t.meta.info_span[1] - t.meta.info_span[0]
	msg_extended(
		&pr.out,
		EXT_HANDSHAKE_ID,
		ext_handshake_payload(size, context.temp_allocator),
	)
	pr.ext_sent = true
	pr.last_send = now_s()
}

// peer_handle_extended is the serving half of BEP 9.
//
// A peer that has only a magnet link asks us for the info dictionary in 16 KiB
// pieces. We have it — it is `t.meta.raw[info_span]`, the exact bytes the
// info-hash was computed over, which is the only slice that can possibly hash
// back to the right value. Nothing is re-encoded.
//
// Everything else that arrives on this message id is dropped. In particular an
// extended id we never registered is dropped by `ext_known_id`, which is where
// a peer pushing peer exchange at us lands: there is no branch below that
// reads an address.
@(private = "file")
peer_handle_extended :: proc(e: ^Engine, t: ^Torrent, pr: ^Peer, m: Msg) {
	if len(m.payload) < 1 {
		peer_set_dead(pr, "an extended message with no extended id")
		return
	}
	ext_id := m.payload[0]
	body := m.payload[1:]

	if ext_id == EXT_HANDSHAKE_ID {
		h, herr := ext_parse_handshake(body, context.allocator)
		if herr != "" {
			peer_set_dead(pr, herr)
			return
		}
		defer {
			hh := h
			hh.client = ""
			ext_handshake_destroy(&hh)
		}
		pr.peer_ut_metadata = h.ut_metadata
		pr.peer_offered_pex = h.offered_pex
		delete(pr.ext_client)
		pr.ext_client = h.client
		// A peer may send its handshake before ours; answer now if we have
		// not already.
		peer_send_ext_handshake(t, pr)
		return
	}
	if !ext_known_id(ext_id) {
		// An id this client never registered. There is nothing it could be
		// but a peer guessing, and guessing is not negotiation.
		return
	}

	// ut_metadata, on the id we published.
	um, uerr := ut_metadata_parse(body)
	if uerr != "" {
		peer_set_dead(pr, uerr)
		return
	}
	switch um.type {
	case .Request:
		if pr.peer_ut_metadata == 0 {
			return // it never told us where to send the answer
		}
		size := t.meta.info_span[1] - t.meta.info_span[0]
		lo, hi, ok := metadata_piece_span(size, um.piece)
		if !ok || len(t.meta.raw) < t.meta.info_span[1] {
			msg_extended(
				&pr.out,
				u8(pr.peer_ut_metadata),
				ut_metadata_reject_payload(um.piece, context.temp_allocator),
			)
			return
		}
		base := t.meta.info_span[0]
		msg_extended(
			&pr.out,
			u8(pr.peer_ut_metadata),
			ut_metadata_data_payload(
				um.piece,
				size,
				t.meta.raw[base + lo:base + hi],
				context.temp_allocator,
			),
		)
		pr.meta_served += 1
		pr.last_send = now_s()
	case .Data:
		// This engine only ever runs with the metadata already in hand — a
		// magnet is resolved by `magnet_resolve` before a torrent exists — so
		// unsolicited metadata is dropped rather than believed.
	case .Reject:
	// Nothing was asked for, so nothing was refused.
	}
	_ = e
}

@(private = "file")
peer_got_block :: proc(e: ^Engine, t: ^Torrent, pr: ^Peer, m: Msg) {
	idx := int(m.index)
	begin := int(m.begin)
	if idx < 0 || idx >= piece_count(&t.meta) {
		peer_set_dead(pr, tsprint("a piece message for piece %d, which does not exist", idx))
		return
	}
	pr.down += i64(len(m.payload))
	if e.down_limit > 0 {
		t.budget -= f64(len(m.payload))
	}

	// Drop it from the in-flight list whether or not we still want it.
	for i := len(pr.inflight) - 1; i >= 0; i -= 1 {
		if pr.inflight[i].index == idx && pr.inflight[i].begin == begin {
			unordered_remove(&pr.inflight, i)
		}
	}
	if bf_get(t.have, idx) {
		t.wasted += i64(len(m.payload))
		return
	}
	a := picker_find(&t.pk, idx)
	if a == nil {
		t.wasted += i64(len(m.payload))
		return
	}
	fresh, complete, serr := picker_store_block(&t.pk, a, begin, m.payload)
	if serr != "" {
		peer_set_dead(pr, serr)
		return
	}
	if !fresh {
		t.wasted += i64(len(m.payload))
	}
	if !complete {
		return
	}

	// The piece is assembled. Verify-then-write: `storage_write_piece` hashes
	// it and refuses to put it on disk if it does not match.
	if werr := storage_write_piece(&t.store, idx, a.buf); werr != "" {
		// A failed hash means somebody sent bad data. The piece is discarded
		// and refetched; the bytes are counted as wasted, not as downloaded.
		t.wasted += piece_size(&t.meta, idx)
		picker_drop(&t.pk, idx)
		if e.verbose {
			fmt.eprintfln("torrent: %s", werr)
		}
		return
	}
	bf_set(&t.have, idx, true)
	t.downloaded += piece_size(&t.meta, idx)
	t.pieces_verified += 1
	picker_drop(&t.pk, idx)

	// Tell everybody.
	for &other in t.peers {
		if other.dead || !other.handshaked {
			continue
		}
		msg_have(&other.out, idx)
		other.last_send = now_s()
	}

	if bf_complete(t.have) || torrent_left(t) == 0 {
		if !t.announced_done {
			t.announced_done = true
			t.completed_at = now_s()
			for &tr in t.trackers {
				tr.pending_ev = .Completed
				tr.next_at = now_s()
			}
		}
		if bf_complete(t.have) {
			t.state = .Seeding
		}
	}
}

// peer_update_interest keeps the interested/not-interested bit honest. A client
// that stays interested forever keeps a seeder's unchoke slot it is not using.
@(private = "file")
peer_update_interest :: proc(t: ^Torrent, pr: ^Peer) {
	want := false
	if t.state == .Downloading {
		for i in 0 ..< piece_count(&t.meta) {
			if !bf_get(t.have, i) && bf_get(pr.bits, i) && piece_wanted(&t.store, i) {
				want = true
				break
			}
		}
	}
	if want && !pr.am_interested {
		msg_simple(&pr.out, .Interested)
		pr.am_interested = true
		pr.last_send = now_s()
	} else if !want && pr.am_interested {
		msg_simple(&pr.out, .Not_Interested)
		pr.am_interested = false
		pr.last_send = now_s()
	}
}

// peer_fill_pipeline issues requests up to the pipeline depth, choosing pieces
// rarest-first and blocks in order within a piece.
@(private = "file")
peer_fill_pipeline :: proc(e: ^Engine, t: ^Torrent, pr: ^Peer, now: f64) {
	if pr.peer_choking || !pr.am_interested {
		return
	}
	if len(pr.out) > OUT_BUF_HIGH_WATER {
		return
	}
	// Under a rate limit the pipeline is as deep as the budget can pay for.
	// Issuing the full depth and then waiting for the bucket to refill makes the
	// transfer a square wave — a burst of 24 blocks arrives at once, then
	// nothing for three seconds — which is both ugly on the graph and a worse
	// approximation of the limit than it looks.
	depth := PIPELINE_DEPTH
	if e.down_limit > 0 {
		depth = clamp(int(t.budget) / BLOCK_SIZE, 0, PIPELINE_DEPTH)
		if depth == 0 {
			return
		}
	}

	// Blocks of pieces already in progress first — finishing a piece is worth
	// more than starting one, because an unfinished piece cannot be shared.
	for len(pr.inflight) < depth {
		issued := false
		for &a in t.pk.active {
			if !bf_get(pr.bits, a.index) {
				continue
			}
			if !piece_wanted(&t.store, a.index) {
				continue
			}
			bi, ok := picker_next_block(&t.pk, &a, t.pk.endgame)
			if !ok {
				continue
			}
			if peer_already_asked(pr, a.index, bi) {
				continue
			}
			length := block_size_at(&t.meta, a.index, bi)
			msg_request(&pr.out, a.index, bi * BLOCK_SIZE, length)
			append(
				&pr.inflight,
				Block_Req {
					index = a.index,
					begin = bi * BLOCK_SIZE,
					length = length,
					at = now,
				},
			)
			picker_mark_requested(&a, bi, now)
			pr.last_send = now
			issued = true
			break
		}
		if issued {
			continue
		}
		// Nothing left in the active pieces for this peer: start another one.
		order := picker_order(t.pk.avail, t.have, pr.bits, context.temp_allocator)
		started := false
		for idx in order {
			if !piece_wanted(&t.store, idx) {
				continue
			}
			if picker_find(&t.pk, idx) != nil {
				continue
			}
			picker_begin(&t.pk, idx)
			started = true
			break
		}
		if !started {
			break
		}
	}
}

@(private = "file")
peer_already_asked :: proc(pr: ^Peer, index, block: int) -> bool {
	begin := block * BLOCK_SIZE
	for r in pr.inflight {
		if r.index == index && r.begin == begin {
			return true
		}
	}
	return false
}

// peer_serve_requests answers whatever this peer asked for, a few per step so
// one greedy peer cannot monopolise the loop.
@(private = "file")
peer_serve_requests :: proc(e: ^Engine, t: ^Torrent, pr: ^Peer) {
	buf := e.serve_buf
	served := 0
	for len(pr.serving) > 0 && served < 16 && len(pr.out) < OUT_BUF_HIGH_WATER {
		req := pr.serving[0]
		// The upload limit. The request is LEFT on the queue when there is no
		// budget for it, rather than dropped: a peer that asked once should
		// not have to ask again because we were busy being polite. The next
		// tick refills the bucket and the same request is answered then.
		if e.up_limit > 0 && t.up_budget < f64(req.length) {
			t.up_deferred = len(pr.serving)
			break
		}
		ordered_remove(&pr.serving, 0)
		if !bf_get(t.have, req.index) {
			continue // we do not have it; silently skip, as clients do
		}
		block, rerr := storage_read_block(&t.store, req.index, req.begin, req.length, buf)
		if rerr != "" {
			peer_set_dead(pr, rerr)
			return
		}
		msg_piece(&pr.out, req.index, req.begin, block)
		pr.up += i64(len(block))
		t.uploaded += i64(len(block))
		if e.up_limit > 0 {
			t.up_budget -= f64(len(block))
		}
		pr.last_send = now_s()
		served += 1
	}
	if len(pr.serving) == 0 {
		t.up_deferred = 0
	}
}

// ---------------------------------------------------------------------------
// Announcing
// ---------------------------------------------------------------------------

torrent_announce_all :: proc(e: ^Engine, t: ^Torrent, ev: Announce_Event) {
	for &tr in t.trackers {
		if ev == .Stopped && !tr.sent_start {
			continue
		}
		req := Announce_Req {
			info_hash  = t.meta.info_hash,
			peer_id    = e.peer_id,
			port       = e.port,
			uploaded   = t.uploaded,
			downloaded = t.downloaded,
			left       = torrent_left(t),
			event      = ev,
			numwant    = 0,
			key        = u32(xs_next(&e.rng)),
		}
		resp, aerr := tracker_announce(tr.url, req, 2000, context.temp_allocator)
		_ = resp
		if aerr != "" {
			delete(tr.last_err)
			tr.last_err = strings.clone(aerr)
		}
		tr.announces += 1
		if ev == .Stopped {
			tr.sent_start = false
		}
	}
}
