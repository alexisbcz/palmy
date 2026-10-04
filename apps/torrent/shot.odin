package main

// `torrent --shots <dir>`: render the window offscreen and write PNGs.
//
// NO NETWORK OF ANY KIND. The engine is never constructed and its thread is
// never started, so there is no listening socket, no tracker announce, no DHT
// and no peer connection. The `Engine_View` the window draws is fabricated
// below — invented torrent names, an invented info hash, and peers that are
// loopback ports, which is the only kind of peer this client ever talks to
// anyway.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1500
SHOT_H :: 900

// A neutral scratch directory: these paths are drawn in the details pane and
// in the add dialog, so they must be safe to show.
SHOT_WORK :: "/tmp/palmy-torrent-shot"
SHOT_TORRENT :: "/tmp/palmy-torrent-shot/palmy-fixture.torrent"

shot_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

// Everything below is allocated on the heap, not in the frame arena:
// `offscreen_end` resets the temp allocator after every frame, and this view is
// handed across a dozen of them.
@(private = "file")
shot_pieces :: proc(n: int, have: f32) -> []f32 {
	m := make([]f32, PIECE_MAP_BUCKETS)
	full := int(f32(PIECE_MAP_BUCKETS) * have)
	for i in 0 ..< PIECE_MAP_BUCKETS {
		switch {
		case i < full:
			m[i] = 1
		case i == full:
			m[i] = 0.5
		// A scattered handful ahead of the frontier, the way a rarest-first
		// picker actually leaves a piece map.
		case (i * 7 + 3) % 23 == 0 && i < full + 40:
			m[i] = 1
		case (i * 5 + 1) % 31 == 0:
			m[i] = 0.5
		}
	}
	return m
}

// A rate history that ramps and then wanders, the way a transfer that has
// finished its slow start actually looks. A plain sawtooth reads as a test
// pattern rather than as data.
@(private = "file")
shot_hist :: proc(peak: f32, n: int, seed: u32) -> []f32 {
	h := make([]f32, n)
	st := seed | 1
	v := f32(0.12)
	for i in 0 ..< n {
		st ~= st << 13
		st ~= st >> 17
		st ~= st << 5
		jitter := (f32(st & 0xffff) / 65535 - 0.5) * 0.14
		ramp := min(f32(1), f32(i) / f32(max(1, n / 3)))
		target := 0.18 + 0.78 * ramp
		v += (target - v) * 0.22 + jitter
		h[i] = peak * clampf(v, 0.03, 1)
	}
	return h
}

shot_view :: proc() -> Engine_View {
	v := Engine_View {
		port       = 51413,
		peer_id    = "-PY0001-4f2a9c71b0d3",
		down_limit = 0,
		last_error = "",
	}

	ts := make([]Torrent_View, 8)

	files := make([]File_View, 6)
	files[0] = {"palmy-fixture/CHECKSUMS.txt", 2_144, 1.0, .Normal, 0, 0}
	files[1] = {"palmy-fixture/README.md", 18_432, 1.0, .High, 0, 0}
	files[2] = {"palmy-fixture/payload/part-000.bin", 268_435_456, 1.0, .Normal, 1, 1023}
	files[3] = {"palmy-fixture/payload/part-001.bin", 268_435_456, 0.61, .Normal, 1024, 2047}
	files[4] = {"palmy-fixture/payload/part-002.bin", 268_435_456, 0.0, .Low, 2048, 3071}
	files[5] = {"palmy-fixture/extras/notes.tar", 9_437_184, 0.0, .Skip, 3072, 3107}

	peers := make([]Peer_View, 5)
	peers[0] = {"127.0.0.1", 6881, "palmy-seed/0.1", 1.0, 1_820_416, 0, 94_371_840, 0, "dKE", false, true, 12}
	peers[1] = {"127.0.0.1", 6882, "palmy-seed/0.1", 1.0, 1_210_368, 0, 61_865_984, 0, "dKE", false, true, 9}
	peers[2] = {"127.0.0.1", 6883, "palmy-peer/0.1", 0.47, 311_296, 204_800, 12_582_912, 8_388_608, "dKUE", true, false, 4}
	peers[3] = {"127.0.0.1", 6884, "palmy-peer/0.1", 0.22, 0, 139_264, 0, 5_242_880, "KU", true, false, 0}
	peers[4] = {"127.0.0.1", 6885, "palmy-peer/0.1", 0.08, 81_920, 0, 1_048_576, 0, "dK", false, false, 2}

	trackers := make([]Tracker_View, 2)
	trackers[0] = {"http://127.0.0.1:6969/announce", "working · 2 seeds, 3 leechers", 2, 3, 7, 842}
	trackers[1] = {"udp://127.0.0.1:6970/announce", "working", 2, 3, 6, 1_104}

	ts[0] = Torrent_View {
		id              = 1,
		name            = "palmy-fixture",
		size            = 814_792_704,
		progress        = 0.538,
		state           = .Downloading,
		state_text      = "Downloading",
		down_rate       = 3_424_000,
		up_rate         = 341_000,
		downloaded      = 438_304_768,
		uploaded        = 92_274_688,
		wasted          = 0,
		ratio           = 0.21,
		seeds           = 2,
		leeches         = 3,
		peers_connected = 3,
		seeds_connected = 2,
		piece_count     = 3108,
		have_pieces     = 1672,
		piece_length    = 262_144,
		pieces_verified = 1672,
		eta             = 108,
		info_hash       = "4f2a9c71b0d3e85a6c1472fb90dd3e118a45c207",
		magnet          = "magnet:?xt=urn:btih:4f2a9c71b0d3e85a6c1472fb90dd3e118a45c207&dn=palmy-fixture",
		dir             = "/tmp/palmy-torrent-shot/downloads",
		torrent_path    = "/tmp/palmy-torrent-shot/palmy-fixture.torrent",
		single_file     = false,
		private         = true,
		comment         = "synthetic payload, generated for the offscreen render",
		created_by      = "palmy torrent --make-torrent",
		files           = files,
		peers           = peers,
		trackers        = trackers,
		down_hist       = shot_hist(3_600_000, 120, 0x51ed270b),
		up_hist         = shot_hist(420_000, 120, 0x2545f491),
		have_map        = shot_pieces(3108, 0.538),
	}

	ts[1] = Torrent_View {
		id              = 2,
		name            = "palmy-fixture-seeded",
		size            = 134_217_728,
		progress        = 1,
		state           = .Seeding,
		state_text      = "Seeding",
		up_rate         = 912_000,
		downloaded      = 134_217_728,
		uploaded        = 402_653_184,
		ratio           = 3.0,
		seeds           = 1,
		leeches         = 2,
		peers_connected = 2,
		seeds_connected = 1,
		piece_count     = 512,
		have_pieces     = 512,
		piece_length    = 262_144,
		pieces_verified = 512,
		info_hash       = "9b71d0c4e2a8f31506bd7742ca9e01f3d8b64520",
		magnet          = "magnet:?xt=urn:btih:9b71d0c4e2a8f31506bd7742ca9e01f3d8b64520",
		dir             = "/tmp/palmy-torrent-shot/downloads",
		torrent_path    = "/tmp/palmy-torrent-shot/seeded.torrent",
		private         = true,
	}

	ts[2] = Torrent_View {
		id              = 3,
		name            = "palmy-fixture-paused",
		size            = 41_943_040,
		progress        = 0.17,
		state           = .Stopped,
		state_text      = "Paused",
		downloaded      = 7_130_316,
		ratio           = 0,
		piece_count     = 160,
		have_pieces     = 27,
		piece_length    = 262_144,
		pieces_verified = 27,
		info_hash       = "02c5e8aa1934f760bb4d2e9071c3a85d6f0e4413",
		magnet          = "magnet:?xt=urn:btih:02c5e8aa1934f760bb4d2e9071c3a85d6f0e4413",
		dir             = "/tmp/palmy-torrent-shot/downloads",
		torrent_path    = "/tmp/palmy-torrent-shot/paused.torrent",
		private         = true,
	}

	// A handful more rows, so the table reads as a client with a queue in it
	// rather than a three-line demo. Each is a fixture name; none of them is a
	// real torrent and none has ever been announced anywhere.
	extra :: proc(
		id: int,
		name: string,
		size: i64,
		progress: f32,
		state: Torrent_State,
		down, up: f64,
		seeds, leeches, conn, sconn: int,
		pieces: int,
		hash: string,
		eta: f64,
		ratio: f32,
	) -> Torrent_View {
		return Torrent_View {
			id = id,
			name = name,
			size = size,
			progress = progress,
			state = state,
			state_text = torrent_state_name(state),
			down_rate = down,
			up_rate = up,
			downloaded = i64(f32(size) * progress),
			uploaded = i64(f32(size) * ratio),
			ratio = ratio,
			seeds = seeds,
			leeches = leeches,
			peers_connected = conn,
			seeds_connected = sconn,
			piece_count = pieces,
			have_pieces = int(f32(pieces) * progress),
			piece_length = 262_144,
			pieces_verified = int(f32(pieces) * progress),
			eta = eta,
			info_hash = hash,
			magnet = "magnet:?xt=urn:btih:",
			dir = "/tmp/palmy-torrent-shot/downloads",
			torrent_path = "/tmp/palmy-torrent-shot/queued.torrent",
			private = true,
		}
	}
	ts[3] = extra(4, "palmy-fixture-lab-captures", 2_147_483_648, 0.312, .Downloading, 1_980_000, 64_000, 1, 4, 3, 1, 8192, "71ce04b9a28d36f5108cbe4471d92a30f6b5c884", 836, 0.04)
	ts[4] = extra(5, "palmy-fixture-sample-audio", 268_435_456, 1, .Seeding, 0, 206_000, 0, 1, 1, 0, 1024, "3a8d61f0427bce95d2f31a8460c7b19e05d34f77", 0, 1.42)
	ts[5] = extra(6, "palmy-fixture-rechecking", 536_870_912, 0.74, .Checking, 0, 0, 2, 0, 0, 0, 2048, "c40917be5d2a386f1b0e94d7c5a82613f09ed4b2", 0, 0.9)
	ts[6] = extra(7, "palmy-fixture-queued", 104_857_600, 0, .Stopped, 0, 0, 0, 0, 0, 0, 400, "5d2e817a06c9b34f1e0a7d6285cf3419b7e0d2a6", 0, 0)
	ts[7] = extra(8, "palmy-fixture-broken", 67_108_864, 0.09, .Error, 0, 0, 0, 0, 0, 0, 256, "e019b7c4d53a2168f0b94e7231ac6d5082f41b93", 0, 0)
	ts[7].err = "tracker refused the announce: 127.0.0.1:6969 is not listening"

	v.torrents = ts
	for t in ts {
		v.total_down += t.down_rate
		v.total_up += t.up_rate
	}
	return v
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("torrent: cannot create %s", dir)
		return 1
	}

	// A real payload tree and a real .torrent, built from it on this machine,
	// so the add dialog is looking at a file that exists. `metainfo_create`
	// reads and hashes local files; it opens no socket.
	_ = os.remove_all(SHOT_WORK)
	make_dirs(SHOT_WORK)
	make_dirs(fmt.tprintf("%s/downloads", SHOT_WORK))
	if err := make_payload(fmt.tprintf("%s/payload", SHOT_WORK)); err != "" {
		fmt.eprintfln("torrent --shots: payload: %s", err)
	} else if data, merr := metainfo_create(
		fmt.tprintf("%s/payload", SHOT_WORK),
		Make_Opts {
			piece_length = 256 * 1024,
			announce = "http://127.0.0.1:6969/announce",
			comment = "synthetic payload, generated for the offscreen render",
		},
	); merr != "" {
		fmt.eprintfln("torrent --shots: metainfo: %s", merr)
	} else {
		_ = write_file(SHOT_TORRENT, data)
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	// The window is started dark (`kit.start(..., true)`), so the shot is too.
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)

	// No engine, and no window: both pointers stay nil. Nothing in the frame
	// builder dereferences either; only the key and click handlers do, and the
	// script below never reaches one.
	u := new(Ui)
	u.detail_h = 340
	u.start = 0
	u.path_buf = make([dynamic]u8, 0, 256)
	u.dir_buf = make([dynamic]u8, 0, 256)
	u.magnet_buf = make([dynamic]u8, 0, 256)
	append(&u.dir_buf, ..transmute([]u8)string("/tmp/palmy-torrent-shot/downloads"))
	append(&u.path_buf, ..transmute([]u8)string("/tmp/palmy-torrent-shot/palmy-fixture.torrent"))
	append(
		&u.magnet_buf,
		..transmute([]u8)string("magnet:?xt=urn:btih:4f2a9c71b0d3e85a6c1472fb90dd3e118a45c207&dn=palmy-fixture"),
	)
	u.view = shot_view()
	u.sel = 0
	u.sel_id = u.view.torrents[0].id
	u.toast = strings.clone("fabricated snapshot — no tracker, no DHT, no peers were contacted")
	u.toast_at = now_s()

	step :: proc(off: ^p.Offscreen, u: ^Ui) {
		ui := p.offscreen_begin(off)
		ui_frame_offscreen(u, ui)
		p.offscreen_end(off)
	}

	shot :: proc(off: ^p.Offscreen, dir, name: string) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		p.offscreen_write_png(off, out)
		fmt.printfln("  %s", out)
	}

	u.tab = .General
	step(off, u)
	step(off, u)
	shot(off, dir, "app-torrent")

	u.tab = .Peers
	step(off, u)
	step(off, u)
	shot(off, dir, "02-torrent-peers")

	u.tab = .Files
	step(off, u)
	step(off, u)
	shot(off, dir, "03-torrent-files")

	u.tab = .Trackers
	step(off, u)
	step(off, u)
	shot(off, dir, "04-torrent-trackers")

	u.tab = .Graph
	step(off, u)
	step(off, u)
	shot(off, dir, "05-torrent-speed")

	u.tab = .General
	u.dialog = .Add_File
	u.dialog_field = 0
	step(off, u)
	step(off, u)
	shot(off, dir, "06-torrent-add")
	u.dialog = .None
	step(off, u)

	u.dialog = .Help
	step(off, u)
	step(off, u)
	shot(off, dir, "07-torrent-help")
	u.dialog = .None
	step(off, u)

	// The fixture tree and the .torrent built from it were only ever needed to
	// make the add dialog real; nothing is left behind.
	_ = os.remove_all(SHOT_WORK)
	return 0
}
