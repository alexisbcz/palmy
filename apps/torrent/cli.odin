package main

// The command-line front end of Torrent, on the shared convention in
// apps/kit/cli.odin (docs/PALM-CLI.md).
//
// Nothing here is a second implementation. `info` is `metainfo_load`, the
// parse every torrent the window opens goes through; `magnet` is
// `magnet_inspect`, which the window's Add Magnet dialog calls; `make` is
// `torrent_make`, which the window's demo creates its torrent with; `engine`
// adds through `prepare_add` and `engine_add`, exactly as the Add dialog does;
// `tracker` is the same loopback tracker the demo and the end-to-end test
// start.
//
// The older spellings — --selftest, --tracker, --engine, --make-torrent,
// --make-payload — are aliases of these commands, so every script that ran
// this binary before still does. --demo, --shots and a bare .torrent path are
// the window's and are routed to it in main.
//
// Loopback only, as everything else in this program: no command here can
// reach an address outside 127.0.0.0/8, because none of them dials anything
// except through `sock_connect`, which refuses.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

// The field lists come first and are self-contained literals: package
// initialisers run in declaration order, and a command table that pointed at
// a list declared below it would capture it empty.

@(private = "file")
INFO_FIELDS := []kit.Field {
	{name = "path", kind = .String, help = "the .torrent that was read"},
	{name = "name", kind = .String, help = "the single file's name, or the top directory's"},
	{name = "info_hash", kind = .String, help = "hex, 40 characters"},
	{name = "magnet", kind = .String, help = "a magnet link for the same torrent"},
	{name = "piece_length", kind = .Int},
	{name = "pieces", kind = .Int},
	{name = "total_length", kind = .Int, help = "bytes"},
	{name = "single_file", kind = .Bool},
	{name = "private", kind = .Bool},
	{name = "comment", kind = .String},
	{name = "created_by", kind = .String},
	{name = "creation_date", kind = .Int, help = "unix seconds, 0 when absent"},
	{name = "trackers", kind = .Array, of = {{kind = .String}}},
	{
		name = "files",
		kind = .Array,
		of = {
			{name = "path", kind = .String},
			{name = "length", kind = .Int},
			{name = "first_piece", kind = .Int, help = "the first piece the file touches"},
			{name = "pieces", kind = .Int, help = "how many pieces it touches; 0 for an empty file"},
		},
	},
}

@(private = "file")
MAGNET_FIELDS := []kit.Field {
	{name = "info_hash", kind = .String},
	{name = "name", kind = .String, help = "the dn= display name, possibly empty"},
	{name = "trackers", kind = .Array, of = {{kind = .String}}},
	{name = "cached", kind = .Bool, help = "the metadata is already in the state directory"},
	{name = "cache_path", kind = .String},
}

@(private = "file")
MADE_FIELDS := []kit.Field {
	{name = "out", kind = .String, help = "where the .torrent was written (not written under --dry-run)"},
	{name = "name", kind = .String},
	{name = "info_hash", kind = .String},
	{name = "magnet", kind = .String},
	{name = "piece_length", kind = .Int},
	{name = "pieces", kind = .Int},
	{name = "files", kind = .Int},
	{name = "total_length", kind = .Int},
}

@(private = "file")
PAYLOAD_FIELDS := []kit.Field {
	{name = "dir", kind = .String, help = "the tree, <dir>/palmy-synthetic"},
	{name = "files", kind = .Int},
	{name = "total_length", kind = .Int},
	{name = "piece_length", kind = .Int, help = "the piece length the tests make it with"},
}

@(private = "file")
TRACKER_FIELDS := []kit.Field {
	{name = "http_port", kind = .Int},
	{name = "udp_port", kind = .Int},
	{name = "announce", kind = .String},
	{name = "ran_for", kind = .Float, help = "seconds"},
}

@(private = "file")
ENGINE_FIELDS := []kit.Field {
	{name = "port", kind = .Int, help = "the 127.0.0.1 port the client listened on"},
	{name = "peer_id", kind = .String},
	{name = "elapsed", kind = .Float, help = "seconds"},
	{name = "name", kind = .String, opt = true},
	{name = "state", kind = .String, opt = true},
	{name = "progress", kind = .Float, opt = true},
	{name = "info_hash", kind = .String, opt = true},
	{name = "downloaded", kind = .Int, opt = true},
	{name = "uploaded", kind = .Int, opt = true},
	{name = "pieces", kind = .Int, opt = true},
	{name = "have", kind = .Int, opt = true},
	{name = "error", kind = .String, opt = true},
}

@(private = "file")
STATUS_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "port", kind = .Int},
	{name = "elapsed", kind = .Float},
	{name = "torrents", kind = .Int},
	{name = "state", kind = .String, opt = true},
	{name = "progress", kind = .Float, opt = true},
	{name = "pieces", kind = .Int, opt = true},
	{name = "have", kind = .Int, opt = true},
	{name = "verified", kind = .Int, opt = true},
	{name = "downloaded", kind = .Int, opt = true},
	{name = "uploaded", kind = .Int, opt = true},
	{name = "wasted", kind = .Int, opt = true},
	{name = "down_rate", kind = .Float, opt = true},
	{name = "up_rate", kind = .Float, opt = true},
	{name = "peers", kind = .Int, opt = true},
	{name = "info_hash", kind = .String, opt = true},
	{name = "error", kind = .String, opt = true},
}

// The synthetic torrent the examples read, made from the payload below by
// `torrent make` and kept in the repository. Paths are from the repository
// root, which is where `palm --selftest` runs them.
EXAMPLE_TORRENT :: "apps/torrent/testdata/palmy-synthetic.torrent"
EXAMPLE_STATUS :: "apps/torrent/testdata/status.txt"

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "what a .torrent file describes: name, info-hash, pieces, files, trackers",
		effect = .Read,
		args = {{name = "torrent", kind = .Path, help = "a .torrent file", required = true}},
		out = INFO_FIELDS,
		examples = {"torrent info apps/torrent/testdata/palmy-synthetic.torrent --json"},
		run = cmd_info,
	},
	{
		verb = "magnet",
		summary = "parse a magnet link, and say whether its metadata is already cached",
		effect = .Read,
		args = {{name = "uri", kind = .String, help = "magnet:?xt=urn:btih:...", required = true}},
		out = MAGNET_FIELDS,
		examples = {
			"torrent magnet \"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=palmy-synthetic&tr=http%3A%2F%2F127.0.0.1%3A6969%2Fannounce\" --json",
		},
		run = cmd_magnet,
	},
	{
		verb = "status",
		summary = "read the status file a running headless client writes (--status-file)",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "the status file", required = true}},
		out = STATUS_FIELDS,
		examples = {"torrent status apps/torrent/testdata/status.txt --json"},
		run = cmd_status,
	},
	{
		verb = "make",
		summary = "build a .torrent from a file or a directory tree, hashing every piece",
		effect = .Mutate,
		aliases = {"--make-torrent"},
		args = {{name = "path", kind = .Path, help = "the file or directory", required = true}},
		flags = {
			{name = "out", kind = .Path, help = "where to write the .torrent", required = true},
			{name = "piece-length", kind = .Int, help = "bytes per piece", def = "262144"},
			{name = "announce", kind = .String, help = "the tracker URL to name (only loopback trackers are ever contacted)"},
			{name = "comment", kind = .String, help = "the comment field"},
			{name = "private", kind = .Bool, help = "set the private flag"},
		},
		out = MADE_FIELDS,
		examples = {
			"torrent make /tmp/torrent-demo/palmy-synthetic --out /tmp/torrent-demo/palmy-synthetic.torrent --piece-length 32768 --announce http://127.0.0.1:6969/announce --json",
			"torrent --make-torrent /tmp/torrent-demo/palmy-synthetic --out /tmp/x.torrent",
		},
		run = cmd_make,
	},
	{
		verb = "payload",
		summary = "write the synthetic multi-file payload every test and the demo use",
		effect = .Idempotent,
		aliases = {"--make-payload"},
		args = {{name = "dir", kind = .Path, help = "the directory to write palmy-synthetic/ under", required = true}},
		out = PAYLOAD_FIELDS,
		examples = {"torrent payload /tmp/torrent-demo --json", "torrent --make-payload /tmp/torrent-demo"},
		run = cmd_payload,
	},
	{
		verb = "tracker",
		summary = "run a BitTorrent tracker on 127.0.0.1 (HTTP and UDP) until --run-for elapses",
		effect = .Mutate,
		aliases = {"--tracker"},
		flags = {
			{name = "http-port", kind = .Int, help = "0 picks a free one", def = "0"},
			{name = "udp-port", kind = .Int, help = "0 picks a free one", def = "0"},
			{name = "ports-file", kind = .Path, help = "write the bound ports here once listening"},
			{name = "run-for", kind = .Float, help = "seconds; 0 runs until killed", def = "0"},
		},
		out = TRACKER_FIELDS,
		examples = {
			"torrent tracker --ports-file /tmp/torrent-demo/ports --run-for 60 --json",
			"torrent --tracker --http-port 0 --udp-port 0 --ports-file /tmp/ports --run-for 300",
		},
		run = cmd_tracker,
	},
	{
		verb = "engine",
		summary = "the client without a window: add one torrent and transfer it over loopback",
		effect = .Mutate,
		aliases = {"--engine"},
		flags = {
			{name = "torrent", kind = .Path, unless = {"magnet"}, help = "the .torrent to add"},
			{name = "magnet", kind = .String, help = "or a magnet link, resolved from its own loopback trackers"},
			{name = "dir", kind = .Path, help = "the download directory", def = "."},
			{name = "port", kind = .Int, help = "the 127.0.0.1 port to listen on; 0 picks one", def = "0"},
			{name = "status-file", kind = .Path, help = "rewrite this with the client's state five times a second"},
			{name = "stop-file", kind = .Path, help = "stop when this file appears"},
			{name = "exit-on-complete", kind = .Bool, help = "stop once every piece is verified"},
			{name = "run-for", kind = .Float, help = "stop after this many seconds; 0 is no limit", def = "0"},
			{name = "down-limit", kind = .Int, help = "bytes per second; 0 is unlimited", def = "0"},
			{name = "up-limit", kind = .Int, help = "bytes per second; 0 is unlimited", def = "0"},
			{name = "seed-only", kind = .Bool, help = "accepted for compatibility"},
		},
		out = ENGINE_FIELDS,
		examples = {
			"torrent engine --torrent /tmp/torrent-demo/palmy-synthetic.torrent --dir /tmp/torrent-demo/out --exit-on-complete --run-for 120 --json",
			"torrent --engine --torrent /tmp/x.torrent --dir /tmp/out --port 0 --status-file /tmp/status --run-for 300",
		},
		run = cmd_engine,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "torrent",
			summary    = "a BitTorrent client, loopback only",
			gui        = true,
			takes_path = true,
			takes_word = kit.cli_word_is_path, // a .torrent or a magnet opens; `torrent lsit` is a usage error
			selftest   = cli_selftest,
			commands   = COMMANDS,
			notes      = `torrent [file.torrent]   the window, with that torrent added
torrent --demo           the window, with a local swarm staged on 127.0.0.1
torrent --shots DIR      render the window offscreen to PNGs

The older spellings --tracker, --engine, --make-torrent and --make-payload are
aliases of the commands above. This client connects only to 127.0.0.0/8 and
resolves no names: there is no DHT, no peer exchange and no port forwarding.`,
		}
	}
	return &g_surface
}

// cli_selftest is --selftest, wherever it appears, with the options it has
// always taken: -v/--verbose and --no-e2e.
cli_selftest :: proc() -> int {
	verbose, e2e := false, true
	for a in os.args[1:] {
		switch a {
		case "-v", "--verbose":
			verbose = true
		case "--no-e2e":
			e2e = false
		}
	}
	return run_selftest(verbose, e2e)
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

// metainfo_json is the object `info` prints, kept separate so the self-test
// can validate it against INFO_FIELDS without spawning anything.
metainfo_json :: proc(path: string, m: ^Metainfo) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "path", path)
	kit.jset_str(o, "name", m.name)
	kit.jset_str(o, "info_hash", hash20_hex(m.info_hash))
	kit.jset_str(o, "magnet", magnet_of(m))
	kit.jset_i64(o, "piece_length", m.piece_length)
	kit.jset_int(o, "pieces", len(m.pieces))
	kit.jset_i64(o, "total_length", m.total_length)
	kit.jset_bool(o, "single_file", m.single_file)
	kit.jset_bool(o, "private", m.private)
	kit.jset_str(o, "comment", m.comment)
	kit.jset_str(o, "created_by", m.created_by)
	kit.jset_i64(o, "creation_date", m.creation_date)
	tr := kit.jarr()
	for t in m.announce_list {
		kit.jpush(tr, kit.jstr(t))
	}
	if len(m.announce_list) == 0 && m.announce != "" {
		kit.jpush(tr, kit.jstr(m.announce))
	}
	kit.jset(o, "trackers", tr)
	files := kit.jarr()
	for f, i in m.files {
		first, last := file_pieces(m, i)
		fo := kit.jobj()
		kit.jset_str(fo, "path", f.path)
		kit.jset_i64(fo, "length", f.length)
		kit.jset_int(fo, "first_piece", first)
		kit.jset_int(fo, "pieces", last - first)
		kit.jpush(files, fo)
	}
	kit.jset(o, "files", files)
	return o
}

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "torrent")
	if !path_exists(path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	m, err := metainfo_load(path)
	if err != "" {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s: %s", path, err)
	}
	c.out = metainfo_json(path, &m)
	return kit.EXIT_OK
}

magnet_json :: proc(mi: ^Magnet_Info) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "info_hash", mi.info_hash)
	kit.jset_str(o, "name", mi.magnet.name)
	tr := kit.jarr()
	for t in mi.magnet.trackers {
		kit.jpush(tr, kit.jstr(t))
	}
	kit.jset(o, "trackers", tr)
	kit.jset_bool(o, "cached", mi.cached)
	kit.jset_str(o, "cache_path", mi.cache_path)
	return o
}

@(private = "file")
cmd_magnet :: proc(c: ^kit.Call) -> int {
	mi, err := magnet_inspect(kit.cli_str(c, "uri"))
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, err)
	}
	c.out = magnet_json(&mi)
	return kit.EXIT_OK
}

// status_json turns the key-value lines `write_status` produces into an
// object with typed values.
status_json :: proc(path, text: string) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "path", path)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		sp := strings.index_byte(line, ' ')
		key, val := line, ""
		if sp >= 0 {
			key, val = line[:sp], strings.trim_space(line[sp + 1:])
		}
		switch key {
		case "port", "torrents", "pieces", "have", "verified", "downloaded", "uploaded", "wasted", "peers":
			n, _ := strconv.parse_i64(val)
			kit.jset_i64(o, key, n)
		case "elapsed", "progress", "down_rate", "up_rate":
			f, _ := strconv.parse_f64(val)
			kit.jset_num(o, key, f)
		case "state", "info_hash", "error":
			kit.jset_str(o, key, val)
		}
	}
	for k in ([?]string{"port", "torrents"}) {
		if _, has := kit.jget(o, k); !has {
			kit.jset_int(o, k, 0)
		}
	}
	if _, has := kit.jget(o, "elapsed"); !has {
		kit.jset_num(o, "elapsed", 0)
	}
	return o
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "file")
	data, ok := read_file(path)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s cannot be read", path)
	}
	c.out = status_json(path, string(data))
	return kit.EXIT_OK
}

@(private = "file")
cmd_make :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "path")
	out := kit.cli_str(c, "out")
	if !path_exists(src) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", src)
	}
	opts := Make_Opts {
		piece_length = i64(kit.cli_int(c, "piece-length", 256 * 1024)),
		announce     = kit.cli_str(c, "announce"),
		comment      = kit.cli_has(c, "comment") ? kit.cli_str(c, "comment") : "generated by palmy-torrent from synthetic data",
		private      = kit.cli_bool(c, "private"),
	}
	m, _, err := torrent_make(src, out, opts, !c.dry_run)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	o := kit.jobj()
	kit.jset_str(o, "out", out)
	kit.jset_str(o, "name", m.name)
	kit.jset_str(o, "info_hash", hash20_hex(m.info_hash))
	kit.jset_str(o, "magnet", magnet_of(&m))
	kit.jset_i64(o, "piece_length", m.piece_length)
	kit.jset_int(o, "pieces", len(m.pieces))
	kit.jset_int(o, "files", len(m.files))
	kit.jset_i64(o, "total_length", m.total_length)
	c.out = o
	kit.cli_note(c, "%s %s (%s, %d pieces)", c.dry_run ? "would write" : "wrote", out, human_size(m.total_length, context.temp_allocator), len(m.pieces))
	return kit.EXIT_OK
}

@(private = "file")
cmd_payload :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	if !c.dry_run {
		if err := make_payload(dir); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
	}
	o := kit.jobj()
	kit.jset_str(o, "dir", path_join(dir, PAYLOAD_NAME, allocator = context.temp_allocator))
	kit.jset_int(o, "files", len(PAYLOAD))
	kit.jset_i64(o, "total_length", payload_total())
	kit.jset_int(o, "piece_length", PAYLOAD_PIECE_LENGTH)
	c.out = o
	return kit.EXIT_OK
}

@(private = "file")
cmd_tracker :: proc(c: ^kit.Call) -> int {
	if c.dry_run {
		o := kit.jobj()
		kit.jset_int(o, "http_port", kit.cli_int(c, "http-port"))
		kit.jset_int(o, "udp_port", kit.cli_int(c, "udp-port"))
		kit.jset_str(o, "announce", fmt.tprintf("http://127.0.0.1:%d/announce", kit.cli_int(c, "http-port")))
		kit.jset_num(o, "ran_for", 0)
		c.out = o
		return kit.EXIT_OK
	}
	bound: [2]int
	started := now_s()
	err := trackerd_run(
		kit.cli_int(c, "http-port"),
		kit.cli_int(c, "udp-port"),
		kit.cli_str(c, "ports-file"),
		c.verbose,
		kit.cli_f64(c, "run-for"),
		&bound,
	)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	o := kit.jobj()
	kit.jset_int(o, "http_port", bound[0])
	kit.jset_int(o, "udp_port", bound[1])
	kit.jset_str(o, "announce", fmt.tprintf("http://127.0.0.1:%d/announce", bound[0]))
	kit.jset_num(o, "ran_for", now_s() - started)
	c.out = o
	return kit.EXIT_OK
}

@(private = "file")
cmd_engine :: proc(c: ^kit.Call) -> int {
	o := Headless_Opts {
		magnet       = kit.cli_str(c, "magnet"),
		port         = kit.cli_int(c, "port"),
		status_file  = kit.cli_str(c, "status-file"),
		stop_file    = kit.cli_str(c, "stop-file"),
		exit_on_done = kit.cli_bool(c, "exit-on-complete"),
		run_for      = kit.cli_f64(c, "run-for"),
		down_limit   = kit.cli_int(c, "down-limit"),
		up_limit     = kit.cli_int(c, "up-limit"),
		verbose      = c.verbose,
		dir          = kit.cli_str(c, "dir"),
	}
	if t := kit.cli_str(c, "torrent"); t != "" {
		// The same check-and-prepare the window's Add dialog does.
		full, d, err := prepare_add(t, o.dir)
		if err != "" {
			return kit.cli_fail(c, path_exists(full) ? kit.EXIT_FAILED : kit.EXIT_NOT_FOUND, err)
		}
		o.torrent, o.dir = full, d
	} else {
		// The kit has refused a line with neither, and counts `--magnet ""`
		// as not given, so there is a magnet here.
		if _, err := magnet_inspect(o.magnet); err != "" {
			return kit.cli_fail(c, kit.EXIT_USAGE, err)
		}
	}
	if c.dry_run {
		out := kit.jobj()
		kit.jset_int(out, "port", o.port)
		kit.jset_str(out, "peer_id", "")
		kit.jset_num(out, "elapsed", 0)
		c.out = out
		return kit.EXIT_OK
	}
	r, code, err := run_headless(o)
	out := kit.jobj()
	kit.jset_int(out, "port", r.port)
	kit.jset_str(out, "peer_id", r.peer_id)
	kit.jset_num(out, "elapsed", r.elapsed)
	if r.have {
		v := r.view
		kit.jset_str(out, "name", v.name)
		kit.jset_str(out, "state", v.state_text)
		kit.jset_num(out, "progress", f64(v.progress))
		kit.jset_str(out, "info_hash", v.info_hash)
		kit.jset_i64(out, "downloaded", v.downloaded)
		kit.jset_i64(out, "uploaded", v.uploaded)
		kit.jset_int(out, "pieces", v.piece_count)
		kit.jset_int(out, "have", v.have_pieces)
		if v.err != "" {
			kit.jset_str(out, "error", v.err)
		}
	}
	c.out = out
	if code != 0 {
		return kit.cli_fail(c, code == 2 ? kit.EXIT_USAGE : kit.EXIT_FAILED, err)
	}
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// The self-test of the command line. No socket is opened here: `tracker` and
// `engine` are checked by binding their command lines, and the transfer they
// perform is what the end-to-end phase runs, through these same aliases.
// ---------------------------------------------------------------------------

@(private = "file")
STATUS_SAMPLE :: "port 40211\nelapsed 2.002\ntorrents 1\nstate Seeding\nprogress 1.000000\npieces 82\nhave 82\nverified 82\ndownloaded 0\nuploaded 0\nwasted 0\ndown_rate 0.0\nup_rate 0.0\npeers 0\ninfo_hash 6fed858fd9a7ac0233be66b3878f14e96c9741a9\nerror \n"

test_cli :: proc(t: ^T) {
	tsection(t, "the command line, on the palm convention")

	s := surface()
	teq(t, "the noun is torrent", s.noun, "torrent")
	tcheck(t, "it declares commands", len(s.commands) >= 7)
	tcheck(t, "it has a window, and a bare path still opens in it", s.gui && s.takes_path)
	tcheck(t, "and a self-test", s.selftest != nil)

	examples := 0
	for &cmd in s.commands {
		tcheck(t, asprint("%s has a summary", cmd.verb), cmd.summary != "")
		tcheck(t, asprint("%s declares what it prints", cmd.verb), len(cmd.out) > 0)
		tcheck(t, asprint("%s ships an example", cmd.verb), len(cmd.examples) > 0)
		tcheck(t, asprint("%s has a body", cmd.verb), cmd.run != nil)
		for ex in cmd.examples {
			words := kit.cli_split_example(ex)
			if !tcheck(t, asprint("the example %q starts with the binary's name", ex), len(words) > 0 && words[0] == "torrent") {
				continue
			}
			_, code := kit.cli_bind(s, words[1:])
			teq_int(t, asprint("the example %q parses", ex), code, kit.EXIT_OK)
			examples += 1
		}
		// Loopback only: no command is allowed to be anything a caller could
		// mistake for reaching the outside world, and none is destructive.
		tcheck(t, asprint("%s is not destructive", cmd.verb), cmd.effect != .Destructive)
	}
	tcheck(t, asprint("there are examples to check (%d)", examples), examples >= 10)

	// Every old spelling is still accepted, in the order scripts wrote it.
	for legacy in ([?]string{"--tracker", "--engine", "--make-torrent", "--make-payload"}) {
		found := false
		for cmd in s.commands {
			for a in cmd.aliases {
				if a == legacy {found = true}
			}
		}
		tcheck(t, asprint("the old spelling %s is still a command", legacy), found)
	}
	for argv in ([][]string {
		{"--engine", "--torrent", "x.torrent", "--dir", "d", "--port", "0", "--status-file", "s", "--stop-file", "f", "--run-for", "300", "--exit-on-complete", "--down-limit", "5", "--up-limit", "5", "--seed-only", "-v"},
		{"--tracker", "--http-port", "0", "--udp-port", "0", "--ports-file", "p", "--run-for", "1800", "-v"},
		{"--make-torrent", "P", "--out", "F", "--piece-length", "32768", "--announce", "http://127.0.0.1:1/announce"},
		{"--make-payload", "D"},
	}) {
		_, code := kit.cli_bind(s, argv)
		teq_int(t, asprint("the old command line %q still parses", strings.join(argv, " ", context.temp_allocator)), code, kit.EXIT_OK)
	}
	tcheck(t, "--demo is the window's, not a command", ui_args_only({"--demo"}) && ui_args_only({"x.torrent", "--demo"}))
	tcheck(t, "--dir first is the window's, as it always was", ui_args_only({"--dir", "/tmp"}))
	tcheck(t, "a command is not mistaken for the window", !ui_args_only({"info", "x.torrent"}) && !ui_args_only({"--engine", "--dir", "d"}))
	{
		_, code := kit.cli_bind(s, {"--frobnicate"})
		teq_int(t, "an unknown flag is a usage error, not a window", code, kit.EXIT_USAGE)
	}
	{
		_, code := kit.cli_bind(s, {"make", "/tmp/x"})
		teq_int(t, "make without --out is a usage error", code, kit.EXIT_USAGE)
	}

	// The results match their declarations, on synthetic data made here.
	root := asprint("/tmp/palmy-torrent-cli-%d", os.get_pid())
	rm_rf(root)
	defer rm_rf(root)
	teq(t, "the payload is written", make_payload(root), "")
	src := path_join(root, PAYLOAD_NAME, allocator = context.temp_allocator)
	out := path_join(root, "x.torrent", allocator = context.temp_allocator)

	{
		_, _, err := torrent_make(src, out, Make_Opts{piece_length = PAYLOAD_PIECE_LENGTH}, false, context.temp_allocator)
		teq(t, "make --dry-run hashes the tree", err, "")
		tcheck(t, "and writes nothing", !path_exists(out))
	}
	m, _, merr := torrent_make(
		src,
		out,
		Make_Opts{piece_length = PAYLOAD_PIECE_LENGTH, announce = "http://127.0.0.1:6969/announce"},
		true,
		context.temp_allocator,
	)
	teq(t, "make writes a torrent", merr, "")
	tcheck(t, "which is on disk", path_exists(out))
	teq_i64(t, "covering the whole payload", m.total_length, payload_total())

	{
		lm, lerr := metainfo_load(out, context.temp_allocator)
		teq(t, "info reads it back", lerr, "")
		text := kit.json_text(metainfo_json(out, &lm), 2, context.temp_allocator)
		bad := kit.cli_validate_output(text, INFO_FIELDS, context.temp_allocator)
		tcheck(t, "info's result matches its declaration", len(bad) == 0, len(bad) > 0 ? bad[0] : "")
		teq(t, "info names the info-hash the maker computed", hash20_hex(lm.info_hash, context.temp_allocator), hash20_hex(m.info_hash, context.temp_allocator))
	}
	{
		mi, err := magnet_inspect(magnet_of(&m, context.temp_allocator), context.temp_allocator)
		teq(t, "magnet parses the link the maker printed", err, "")
		teq(t, "and finds the same info-hash", mi.info_hash, hash20_hex(m.info_hash, context.temp_allocator))
		bad := kit.cli_validate_output(kit.json_text(magnet_json(&mi), 2, context.temp_allocator), MAGNET_FIELDS, context.temp_allocator)
		tcheck(t, "magnet's result matches its declaration", len(bad) == 0, len(bad) > 0 ? bad[0] : "")
		_, berr := magnet_inspect("magnet:?dn=nothing", context.temp_allocator)
		tcheck(t, "a magnet with no info-hash is refused", berr != "")
	}
	{
		o := status_json("status.txt", STATUS_SAMPLE)
		bad := kit.cli_validate_output(kit.json_text(o, 2, context.temp_allocator), STATUS_FIELDS, context.temp_allocator)
		tcheck(t, "status's result matches its declaration", len(bad) == 0, len(bad) > 0 ? bad[0] : "")
		st, _ := kit.jget(o, "state")
		teq(t, "and carries the state through", kit.json_scalar(st), "Seeding")
		empty := status_json("empty", "")
		bad = kit.cli_validate_output(kit.json_text(empty, 2, context.temp_allocator), STATUS_FIELDS, context.temp_allocator)
		tcheck(t, "an empty status file still answers in the declared shape", len(bad) == 0, len(bad) > 0 ? bad[0] : "")
	}
	{
		full, d, err := prepare_add(out, path_join(root, "dl", allocator = context.temp_allocator), context.temp_allocator)
		teq(t, "the Add dialog's check accepts the torrent", err, "")
		tcheck(t, "and creates the download directory", os.is_dir(d))
		teq(t, "and hands back the file", full, out)
		_, _, merr2 := prepare_add(path_join(root, "nope.torrent", allocator = context.temp_allocator), "", context.temp_allocator)
		tcheck(t, "a missing .torrent is refused before the engine sees it", merr2 != "")
	}
}
