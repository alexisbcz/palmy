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
	seed_only:     bool,

	path:          string,
	out:           string,
	piece_length:  i64,
	announce:      string,
}

main :: proc() {
	a := parse_args()
	switch a.mode {
	case .Selftest:
		os.exit(run_selftest(a.verbose, !a.no_e2e))
	case .Tracker:
		if err := trackerd_run(a.http_port, a.udp_port, a.ports_file, a.verbose, a.run_for);
		   err != "" {
			fmt.eprintfln("tracker: %s", err)
			os.exit(1)
		}
	case .Engine:
		os.exit(run_headless(a))
	case .Make_Torrent:
		os.exit(run_make_torrent(a))
	case .Make_Payload:
		os.exit(run_make_payload(a))
	case .Ui:
		run_ui(a)
	}
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
          [--down-limit BYTES_PER_SEC] [--seed-only]
  torrent --make-torrent PATH --out F [--piece-length N] [--announce URL]
  torrent --make-payload DIR

This client connects only to 127.0.0.0/8 and resolves no names. There is no
DHT, no peer exchange and no port forwarding in it.`,
	)
}

// ---------------------------------------------------------------------------
// Making things
// ---------------------------------------------------------------------------

run_make_torrent :: proc(a: Args) -> int {
	if a.path == "" || a.out == "" {
		fmt.eprintln("torrent: --make-torrent needs a path and --out")
		return 2
	}
	data, err := metainfo_create(
		a.path,
		Make_Opts {
			piece_length = a.piece_length,
			announce = a.announce,
			comment = "generated by palmy-torrent from synthetic data",
		},
	)
	if err != "" {
		fmt.eprintfln("torrent: %s", err)
		return 1
	}
	if werr := write_file(a.out, data); werr != "" {
		fmt.eprintfln("torrent: %s", werr)
		return 1
	}
	m, perr := metainfo_parse(data)
	if perr != "" {
		fmt.eprintfln("torrent: the torrent it just wrote does not parse: %s", perr)
		return 1
	}
	fmt.printfln(
		"wrote %s\n  name          %s\n  info-hash     %s\n  piece length  %s\n  pieces        %d\n  files         %d\n  total         %s",
		a.out,
		m.name,
		hash20_hex(m.info_hash, context.temp_allocator),
		human_size(m.piece_length, context.temp_allocator),
		len(m.pieces),
		len(m.files),
		human_size(m.total_length, context.temp_allocator),
	)
	return 0
}

run_make_payload :: proc(a: Args) -> int {
	if a.path == "" {
		fmt.eprintln("torrent: --make-payload needs a directory")
		return 2
	}
	if err := make_payload(a.path); err != "" {
		fmt.eprintfln("torrent: %s", err)
		return 1
	}
	fmt.printfln("wrote the synthetic payload under %s", a.path)
	return 0
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

run_headless :: proc(a: Args) -> int {
	if a.torrent == "" {
		fmt.eprintln("torrent: --engine needs --torrent")
		return 2
	}
	dir := a.dir
	if dir == "" {
		dir = "."
	}
	e := new(Engine)
	seed := u64(time.to_unix_nanoseconds(time.now())) ~ u64(os.get_pid()) * 0x9e3779b9
	if err := engine_init(e, a.port, seed); err != "" {
		fmt.eprintfln("torrent: %s", err)
		return 1
	}
	e.verbose = a.verbose
	e.down_limit = a.down_limit
	fmt.printfln("engine: peer %s on 127.0.0.1:%d", peer_id_text(e.peer_id, context.temp_allocator), e.port)

	engine_add(e, a.torrent, dir, true)

	started := now_s()
	last_status := -1.0
	exit_code := 0
	for {
		engine_step(e, 25)

		now := now_s()
		if a.status_file != "" && now - last_status > 0.2 {
			last_status = now
			write_status(e, a.status_file, now - started)
		}
		if a.stop_file != "" && path_exists(a.stop_file) {
			break
		}
		if a.run_for > 0 && now - started > a.run_for {
			break
		}
		if a.exit_on_done {
			done := false
			sync.lock(&e.mu)
			if len(e.torrents) > 0 {
				t := e.torrents[0]
				done = t.state == .Seeding && bf_complete(t.have)
				if t.state == .Error {
					fmt.eprintfln("engine: %s", t.err)
					exit_code = 1
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
	if a.status_file != "" {
		write_status(e, a.status_file, now_s() - started)
	}
	engine_shutdown(e)
	engine_destroy(e)
	fmt.printfln("engine: stopped after %.2fs", now_s() - started)
	return exit_code
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

