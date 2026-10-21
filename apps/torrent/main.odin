package main

// torrent — a BitTorrent client on palmy.
//
// Modes, all of them loopback-only:
//
//   torrent                            the window
//   torrent --demo                     the window, with a local swarm staged
//   torrent --selftest [-v] [--no-e2e] every assertion, then the real transfer
//   torrent --tracker                  the tracker, on 127.0.0.1
//   torrent --engine --torrent T       a headless client, for the e2e test
//   torrent --make-torrent P --out F   build a .torrent from a file or tree
//   torrent --make-payload D          write the synthetic test payload
//
// There is no mode, and no flag, that lets any of this reach an address outside
// 127.0.0.0/8. See the header of net.odin.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import kit "kit:."

Mode :: enum {
	Ui,
	Selftest,
	Tracker,
	Engine,
	Make_Torrent,
	Make_Payload,
}

Args :: struct {
	mode:          Mode,
	verbose:       bool,
	no_e2e:        bool,
	demo:          bool,

	http_port:     int,
	udp_port:      int,
	ports_file:    string,

	torrent:       string,
	dir:           string,
	port:          int,
	status_file:   string,
	stop_file:     string,
	exit_on_done:  bool,
	run_for:       f64,
	down_limit:    int,
	up_limit:      int,
	seed_only:     bool,

	path:          string,
	out:           string,
	piece_length:  i64,
	announce:      string,
}

main :: proc() {
	// `--shots <dir>` renders the window offscreen and exits. No window is
	// opened and no socket is created. See shot.odin.
	for arg, i in os.args[1:] {
		if arg == "--shots" || arg == "-shots" {
			rest := os.args[1:]
			if i + 1 >= len(rest) {
				fmt.eprintln("torrent --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(rest[i + 1]))
		}
	}

	// The window's own flags. `--demo` stages a swarm for the window and is
	// never a command; `--dir`, `--port` and the rate limits, given first,
	// are the window's settings, as they always were.
	if ui_args_only(os.args[1:]) {
		run_ui(parse_args())
		return
	}

	// Everything else is the command line, declared in cli.odin and parsed by
	// apps/kit/cli.odin. The old spellings — --selftest, --tracker, --engine,
	// --make-torrent, --make-payload — are aliases there. With no arguments,
	// or with a bare .torrent path, there is a window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	run_ui(parse_args())
}

// ui_args_only says the command line is for the window: it carries --demo,
// or it starts with one of the window's settings rather than a command.
ui_args_only :: proc(args: []string) -> bool {
	if len(args) == 0 {
		return false
	}
	for a in args {
		if a == "--demo" {
			return true
		}
	}
	switch args[0] {
	case "--dir", "--port", "--down-limit", "--up-limit":
		return true
	}
	return false
}

parse_args :: proc() -> Args {
	a := Args {
		piece_length = 256 * 1024,
		dir          = "",
	}
	args := os.args[1:]
	i := 0
	next :: proc(args: []string, i: ^int) -> string {
		if i^ + 1 < len(args) {
			i^ += 1
			return args[i^]
		}
		return ""
	}
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "--selftest":
			a.mode = .Selftest
		case "-v", "--verbose":
			a.verbose = true
		case "--no-e2e":
			a.no_e2e = true
		case "--demo":
			a.demo = true
		case "--tracker":
			a.mode = .Tracker
		case "--engine":
			a.mode = .Engine
		case "--make-torrent":
			a.mode = .Make_Torrent
			a.path = next(args, &i)
		case "--make-payload":
			a.mode = .Make_Payload
			a.path = next(args, &i)
		case "--http-port":
			a.http_port = parse_int_default(next(args, &i), 0)
		case "--udp-port":
			a.udp_port = parse_int_default(next(args, &i), 0)
		case "--ports-file":
			a.ports_file = next(args, &i)
		case "--torrent":
			a.torrent = next(args, &i)
		case "--dir":
			a.dir = next(args, &i)
		case "--port":
			a.port = parse_int_default(next(args, &i), 0)
		case "--status-file":
			a.status_file = next(args, &i)
		case "--stop-file":
			a.stop_file = next(args, &i)
		case "--exit-on-complete":
			a.exit_on_done = true
		case "--run-for":
			v, _ := strconv.parse_f64(next(args, &i))
			a.run_for = v
		case "--down-limit":
			a.down_limit = parse_int_default(next(args, &i), 0)
		case "--up-limit":
			a.up_limit = parse_int_default(next(args, &i), 0)
		case "--seed-only":
			a.seed_only = true
		case "--out":
			a.out = next(args, &i)
		case "--piece-length":
			a.piece_length = i64(parse_int_default(next(args, &i), 256 * 1024))
		case "--announce":
			a.announce = next(args, &i)
		case "-h", "--help":
			usage()
			os.exit(0)
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintfln("torrent: unknown flag %q", arg)
				usage()
				os.exit(2)
			}
			// A bare argument is a .torrent to open.
			a.torrent = arg
		}
		i += 1
	}
	return a
}

usage :: proc() {
	fmt.println(
		`torrent — a BitTorrent client, loopback only

  torrent [file.torrent]               open the window
  torrent --demo                       open the window with a local swarm staged
  torrent --selftest [-v] [--no-e2e]   run every assertion
  torrent --tracker [--http-port N] [--udp-port N] [--ports-file F]
  torrent --engine --torrent T --dir D [--port N] [--status-file F]
          [--stop-file F] [--exit-on-complete] [--run-for S]
          [--down-limit BYTES_PER_SEC] [--up-limit BYTES_PER_SEC] [--seed-only]
  torrent --make-torrent PATH --out F [--piece-length N] [--announce URL]
  torrent --make-payload DIR

This client connects only to 127.0.0.0/8 and resolves no names. There is no
DHT, no peer exchange and no port forwarding in it. A magnet resolves over
BEP 9 from a peer one of its own trackers named, which on this client means a
tracker on loopback and nothing else.`,
	)
}

// ---------------------------------------------------------------------------
// Making things
// ---------------------------------------------------------------------------

// torrent_make builds a .torrent for `src`, writes it to `out` (unless
// `write` is false, which is --dry-run), and parses the result back, so what
// is reported is what a client reading the file would see. `torrent make` and
// the window's demo both create torrents through here.
torrent_make :: proc(
	src, out: string,
	opts: Make_Opts,
	write := true,
	allocator := context.allocator,
) -> (
	m: Metainfo,
	data: []u8,
	err: string,
) {
	if src == "" {
		return m, nil, "a file or directory to make the torrent from is needed"
	}
	if write && out == "" {
		return m, nil, "an output path is needed"
	}
	cerr: string
	data, cerr = metainfo_create(src, opts, allocator)
	if cerr != "" {
		return m, nil, cerr
	}
	if write {
		if werr := write_file(out, data); werr != "" {
			return m, data, werr
		}
	}
	perr: string
	m, perr = metainfo_parse(clone_bytes(data, allocator), allocator)
	if perr != "" {
		return m, data, tsprint("the torrent it just made does not parse: %s", perr)
	}
	return m, data, ""
}

// PAYLOAD is the synthetic multi-file tree every test and the demo use.
//
// The sizes are chosen so that, at a 32 KiB piece length, pieces straddle file
// boundaries in every interesting way: a file shorter than a block, a file that
// is an exact multiple of the piece length, a zero-length file in the middle,
// and a last piece that is short. None of this content came from anywhere: it
// is the output of the xorshift generator in fs.odin, seeded per file, so the
// expected bytes are known exactly.
@(rodata)
PAYLOAD := []struct {
	rel:  string,
	size: i64,
	seed: u64,
} {
	{"README.txt", 743, 0x1001},
	{"video/clip-01.bin", 1_310_720, 0x2002}, // 40 pieces exactly at 32 KiB
	{"video/clip-02.bin", 983_041, 0x3003}, // one byte past a piece boundary
	{"docs/empty.bin", 0, 0x4004}, // a zero-length file in the middle
	{"docs/notes.bin", 7, 0x5005}, // shorter than a block
	{"docs/deep/nested/data.bin", 262_144, 0x6006},
	{"tail.bin", 100_003, 0x7007}, // leaves a short final piece
}

PAYLOAD_NAME :: "palmy-synthetic"
PAYLOAD_PIECE_LENGTH :: 32 * 1024

make_payload :: proc(root: string) -> (err: string) {
	base := path_join(root, PAYLOAD_NAME, allocator = context.temp_allocator)
	if e := make_dirs(base); e != "" {
		return e
	}
	for p in PAYLOAD {
		full := path_join(base, p.rel, allocator = context.temp_allocator)
		if e := write_synthetic_file(full, p.size, p.seed); e != "" {
			return e
		}
	}
	return ""
}

payload_total :: proc() -> i64 {
	total: i64 = 0
	for p in PAYLOAD {
		total += p.size
	}
	return total
}

// ---------------------------------------------------------------------------
// The headless client
// ---------------------------------------------------------------------------

Headless_Opts :: struct {
	torrent:      string,
	magnet:       string,
	dir:          string,
	port:         int,
	status_file:  string,
	stop_file:    string,
	exit_on_done: bool,
	run_for:      f64,
	down_limit:   int,
	up_limit:     int,
	verbose:      bool,
}

// Headless_Result is what the client reports when it stops.
Headless_Result :: struct {
	port:    int,
	peer_id: string,
	elapsed: f64,
	view:    Torrent_View,
	have:    bool, // a torrent was loaded
}

// run_headless is the client without a window: the same engine, added to
// through the same `engine_add` the window's Add dialog calls. Progress goes
// to stderr; the result is returned for the caller to print.
run_headless :: proc(o: Headless_Opts) -> (r: Headless_Result, code: int, err: string) {
	if o.torrent == "" && o.magnet == "" {
		return r, 2, "the client needs --torrent or --magnet"
	}
	dir := o.dir
	if dir == "" {
		dir = "."
	}
	e := new(Engine)
	seed := u64(time.to_unix_nanoseconds(time.now())) ~ u64(os.get_pid()) * 0x9e3779b9
	if ierr := engine_init(e, o.port, seed); ierr != "" {
		return r, 1, ierr
	}
	e.verbose = o.verbose
	e.down_limit = o.down_limit
	e.up_limit = o.up_limit
	r.port = e.port
	r.peer_id = peer_id_text(e.peer_id)
	fmt.eprintfln("engine: peer %s on 127.0.0.1:%d", r.peer_id, e.port)

	if o.magnet != "" {
		engine_add_magnet(e, o.magnet, dir, true)
	} else {
		engine_add(e, o.torrent, dir, true)
	}

	// The temp allocator is reset every step. Nothing above lives in it —
	// the options are the kit's (its own arena) or cloned by prepare_add and
	// engine_add — so the loop may own it.

	started := now_s()
	last_status := -1.0
	for {
		engine_step(e, 25)

		now := now_s()
		if o.status_file != "" && now - last_status > 0.2 {
			last_status = now
			write_status(e, o.status_file, now - started)
		}
		if o.stop_file != "" && path_exists(o.stop_file) {
			break
		}
		if o.run_for > 0 && now - started > o.run_for {
			break
		}
		if o.exit_on_done {
			done := false
			sync.lock(&e.mu)
			if len(e.torrents) > 0 {
				t := e.torrents[0]
				done = t.state == .Seeding && bf_complete(t.have)
				if t.state == .Error {
					fmt.eprintfln("engine: %s", t.err)
					code = 1
					err = strings.clone(t.err)
					done = true
				}
			}
			sync.unlock(&e.mu)
			if done {
				break
			}
		}
		free_all(context.temp_allocator)
	}
	r.elapsed = now_s() - started
	if o.status_file != "" {
		write_status(e, o.status_file, r.elapsed)
	}
	v := engine_snapshot(e, len(e.torrents) > 0 ? e.torrents[0].id : 0, context.allocator)
	if len(v.torrents) > 0 {
		r.view = v.torrents[0]
		r.have = true
	}
	engine_shutdown(e)
	engine_destroy(e)
	fmt.eprintfln("engine: stopped after %.2fs", r.elapsed)
	return r, code, err
}

@(private = "file")
write_status :: proc(e: ^Engine, path: string, elapsed: f64) {
	v := engine_snapshot(e, len(e.torrents) > 0 ? e.torrents[0].id : 0, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "port %d", v.port)
	fmt.sbprintfln(&b, "elapsed %.3f", elapsed)
	fmt.sbprintfln(&b, "torrents %d", len(v.torrents))
	if len(v.torrents) > 0 {
		t := v.torrents[0]
		fmt.sbprintfln(&b, "state %s", t.state_text)
		fmt.sbprintfln(&b, "progress %.6f", t.progress)
		fmt.sbprintfln(&b, "pieces %d", t.piece_count)
		fmt.sbprintfln(&b, "have %d", t.have_pieces)
		fmt.sbprintfln(&b, "verified %d", t.pieces_verified)
		fmt.sbprintfln(&b, "downloaded %d", t.downloaded)
		fmt.sbprintfln(&b, "uploaded %d", t.uploaded)
		fmt.sbprintfln(&b, "wasted %d", t.wasted)
		fmt.sbprintfln(&b, "down_rate %.1f", t.down_rate)
		fmt.sbprintfln(&b, "up_rate %.1f", t.up_rate)
		fmt.sbprintfln(&b, "peers %d", t.peers_connected)
		fmt.sbprintfln(&b, "info_hash %s", t.info_hash)
		fmt.sbprintfln(&b, "error %s", t.err)
	}
	// Written whole, so a reader never sees half a file.
	tmp := tsprint("%s.tmp", path)
	if write_file_string(tmp, strings.to_string(b)) == "" {
		os.rename(tmp, path)
	}
}

// ---------------------------------------------------------------------------
// Adding, shared by the window's Add dialogs and the command line
// ---------------------------------------------------------------------------

// prepare_add checks a .torrent path and a download directory the way the
// window's Add dialog always has — `~` expanded, the file present, the
// directory created — and hands back what `engine_add` should be given.
prepare_add :: proc(path, dir: string, allocator := context.allocator) -> (full, d: string, err: string) {
	if path == "" {
		return "", "", "a .torrent path is needed"
	}
	full = expand_home(path, allocator)
	if !path_exists(full) {
		return full, "", tsprint("%s does not exist", full)
	}
	d = dir == "" ? "." : expand_home(dir, allocator)
	if derr := make_dirs(d); derr != "" {
		return full, d, derr
	}
	return full, d, ""
}

// Magnet_Info is what a magnet link says, plus whether its metadata is
// already in the state directory — which decides whether adding it is
// immediate or needs a BEP 9 exchange with a peer its own trackers name.
Magnet_Info :: struct {
	magnet:     Magnet,
	info_hash:  string,
	cache_path: string,
	cached:     bool,
}

magnet_inspect :: proc(uri: string, allocator := context.allocator) -> (mi: Magnet_Info, err: string) {
	mg, perr := magnet_parse(uri, allocator)
	if perr != "" {
		return mi, perr
	}
	mi.magnet = mg
	mi.info_hash = hash20_hex(mg.info_hash, allocator)
	mi.cache_path = path_join(state_dir(context.temp_allocator), tsprint("%s.torrent", mi.info_hash), allocator = allocator)
	mi.cached = path_exists(mi.cache_path)
	return mi, ""
}
