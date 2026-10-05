package main

// The snapshot the UI reads.
//
// The engine owns every piece of mutable state and runs on another thread, so
// the UI never reads it directly. Once a frame it calls `engine_snapshot`,
// which copies plain values into the frame's temporary arena under the mutex
// and releases it. That keeps the lock held for microseconds, means a frame can
// never see a half-updated peer list, and means nothing in `ui.odin` can
// accidentally mutate the engine.

import "core:strings"
import "core:sync"

Peer_View :: struct {
	host:      string,
	port:      int,
	client:    string,
	progress:  f32,
	down_rate: f64,
	up_rate:   f64,
	downloaded: i64,
	uploaded:  i64,
	flags:     string,
	incoming:  bool,
	seed:      bool,
	requests:  int,
}

File_View :: struct {
	path:     string,
	length:   i64,
	progress: f32,
	prio:     File_Prio,
	first:    int,
	last:     int,
}

Tracker_View :: struct {
	url:       string,
	status:    string,
	seeders:   int,
	leechers:  int,
	announces: int,
	next_in:   f64,
}

Torrent_View :: struct {
	id:              int,
	name:            string,
	size:            i64,
	progress:        f32,
	state:           Torrent_State,
	state_text:      string,
	down_rate:       f64,
	up_rate:         f64,
	downloaded:      i64,
	uploaded:        i64,
	wasted:          i64,
	ratio:           f32,
	seeds:           int,
	leeches:         int,
	peers_connected: int,
	seeds_connected: int,
	piece_count:     int,
	have_pieces:     int,
	piece_length:    i64,
	pieces_verified: int,
	eta:             f64,
	info_hash:       string,
	magnet:          string,
	dir:             string,
	torrent_path:    string,
	single_file:     bool,
	private:         bool,
	comment:         string,
	created_by:      string,
	check_done:      int,
	check_total:     int,
	err:             string,
	added_at:        f64,
	completed_at:    f64,

	files:           []File_View,
	peers:           []Peer_View,
	trackers:        []Tracker_View,
	down_hist:       []f32, // oldest first
	up_hist:         []f32,
	have_map:        []f32, // coverage per bucket, for the piece bar
}

Engine_View :: struct {
	port:       int,
	peer_id:    string,
	torrents:   []Torrent_View,
	last_error: string,
	down_limit: int,
	up_limit:   int,
	total_down: f64,
	total_up:   f64,
}

PIECE_MAP_BUCKETS :: 220

// engine_snapshot copies everything the UI needs. `detail_id` gets the
// expensive parts (per-peer, per-file, the piece map); the rest get the row.
engine_snapshot :: proc(
	e: ^Engine,
	detail_id: int,
	allocator := context.temp_allocator,
) -> Engine_View {
	sync.lock(&e.mu)
	defer sync.unlock(&e.mu)

	v := Engine_View {
		port       = e.port,
		peer_id    = peer_id_text(e.peer_id, allocator),
		down_limit = e.down_limit,
		up_limit   = e.up_limit,
		last_error = strings.clone(e.last_error, allocator),
	}
	out := make([dynamic]Torrent_View, 0, len(e.torrents), allocator)
	for t in e.torrents {
		tv := torrent_view(t, t.id == detail_id, allocator)
		v.total_down += tv.down_rate
		v.total_up += tv.up_rate
		append(&out, tv)
	}
	v.torrents = out[:]
	return v
}

@(private = "file")
torrent_view :: proc(t: ^Torrent, detail: bool, allocator: runtime_allocator) -> Torrent_View {
	tv := Torrent_View {
		id              = t.id,
		name            = strings.clone(t.meta.name, allocator),
		size            = t.meta.total_length,
		progress        = torrent_progress(t),
		state           = t.state,
		state_text      = torrent_state_name(t.state),
		down_rate       = t.down_rate,
		up_rate         = t.up_rate,
		downloaded      = t.downloaded,
		uploaded        = t.uploaded,
		wasted          = t.wasted,
		piece_count     = piece_count(&t.meta),
		have_pieces     = bf_count(t.have),
		piece_length    = t.meta.piece_length,
		pieces_verified = t.pieces_verified,
		info_hash       = hash20_hex(t.meta.info_hash, allocator),
		dir             = strings.clone(t.dir, allocator),
		torrent_path    = strings.clone(t.torrent_path, allocator),
		single_file     = t.meta.single_file,
		private         = t.meta.private,
		comment         = strings.clone(t.meta.comment, allocator),
		created_by      = strings.clone(t.meta.created_by, allocator),
		check_done      = t.check_done,
		check_total     = t.check_total,
		err             = strings.clone(t.err, allocator),
		added_at        = t.added_at,
		completed_at    = t.completed_at,
	}
	if t.downloaded > 0 {
		tv.ratio = f32(f64(t.uploaded) / f64(t.downloaded))
	} else if t.uploaded > 0 {
		tv.ratio = -1 // uploaded without downloading: the "∞" case
	}
	for &pr in t.peers {
		if pr.dead || !pr.handshaked {
			continue
		}
		tv.peers_connected += 1
		if pr.seed {
			tv.seeds_connected += 1
		}
	}
	for &tr in t.trackers {
		tv.seeds = max(tv.seeds, tr.seeders)
		tv.leeches = max(tv.leeches, tr.leechers)
	}
	left := torrent_left(t)
	if left > 0 && t.down_rate > 1 {
		tv.eta = f64(left) / t.down_rate
	}

	if !detail {
		return tv
	}

	tv.magnet = magnet_of(&t.meta, allocator)

	files := make([]File_View, len(t.meta.files), allocator)
	for f, i in t.meta.files {
		first, last := file_pieces(&t.meta, i)
		files[i] = File_View {
			path     = strings.clone(f.path, allocator),
			length   = f.length,
			progress = file_progress(&t.meta, t.have, i),
			prio     = t.store.prio[i],
			first    = first,
			last     = last,
		}
	}
	tv.files = files

	peers := make([dynamic]Peer_View, 0, len(t.peers), allocator)
	for &pr in t.peers {
		if pr.dead {
			continue
		}
		prog: f32 = 0
		if pr.bits.n > 0 {
			prog = f32(bf_count(pr.bits)) / f32(pr.bits.n)
		}
		append(
			&peers,
			Peer_View {
				host = strings.clone(pr.host, allocator),
				port = pr.port,
				client = pr.client == "" ? strings.clone("…", allocator) : strings.clone(pr.client, allocator),
				progress = prog,
				down_rate = pr.down_rate,
				up_rate = pr.up_rate,
				downloaded = pr.down,
				uploaded = pr.up,
				flags = peer_flag_text(&pr, allocator),
				incoming = pr.incoming,
				seed = pr.seed,
				requests = len(pr.inflight),
			},
		)
	}
	tv.peers = peers[:]

	trs := make([]Tracker_View, len(t.trackers), allocator)
	for &tr, i in t.trackers {
		status := "working"
		if tr.last_err != "" {
			status = strings.clone(tr.last_err, allocator)
		} else if tr.announces == 0 {
			status = "not contacted yet"
		}
		trs[i] = Tracker_View {
			url       = strings.clone(tr.url, allocator),
			status    = status,
			seeders   = tr.seeders,
			leechers  = tr.leechers,
			announces = tr.announces,
			next_in   = max(0, tr.next_at - now_s()),
		}
	}
	tv.trackers = trs

	// The rate history is a ring; hand it over oldest first so the graph can
	// just walk it.
	n := min(t.hist_n, RATE_HISTORY)
	dh := make([]f32, n, allocator)
	uh := make([]f32, n, allocator)
	for i in 0 ..< n {
		src := (t.hist_n - n + i) % RATE_HISTORY
		dh[i] = t.down_hist[src]
		uh[i] = t.up_hist[src]
	}
	tv.down_hist = dh
	tv.up_hist = uh

	// The piece map, bucketed down to something a 220px bar can show.
	np := piece_count(&t.meta)
	buckets := min(PIECE_MAP_BUCKETS, max(1, np))
	hm := make([]f32, buckets, allocator)
	for b in 0 ..< buckets {
		lo := np * b / buckets
		hi := max(lo + 1, np * (b + 1) / buckets)
		got := 0
		for i in lo ..< min(hi, np) {
			if bf_get(t.have, i) {
				got += 1
			}
		}
		span := min(hi, np) - lo
		hm[b] = span > 0 ? f32(got) / f32(span) : 0
	}
	tv.have_map = hm
	return tv
}

@(private = "file")
peer_flag_text :: proc(pr: ^Peer, allocator: runtime_allocator) -> string {
	b := strings.builder_make(allocator)
	// The same letters qBittorrent and Transmission use, so the column is
	// readable to anyone who has seen one of those.
	strings.write_string(&b, pr.incoming ? "I" : "O")
	strings.write_string(&b, pr.am_interested ? "i" : "·")
	strings.write_string(&b, pr.peer_choking ? "C" : "·")
	strings.write_string(&b, pr.peer_interested ? "r" : "·")
	strings.write_string(&b, pr.am_choking ? "c" : "u")
	// `E` is BEP 10, the extension protocol — the same letter qBittorrent
	// uses. `M` next to it means the peer registered ut_metadata, so a magnet
	// could be resolved from it. There is no letter for peer exchange because
	// there is no peer exchange.
	if pr.peer_ext {
		strings.write_string(&b, "E")
		if pr.peer_ut_metadata > 0 {
			strings.write_string(&b, "M")
		}
	}
	if pr.seed {
		strings.write_string(&b, "S")
	}
	return strings.to_string(b)
}
