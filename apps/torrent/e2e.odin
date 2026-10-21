package main

// The end-to-end test: a real transfer, between two instances of this binary.
//
// It does the whole thing:
//
//   1. generates a synthetic multi-file payload (seven files, including an
//      empty one and one of seven bytes, so pieces straddle boundaries),
//   2. starts the tracker on 127.0.0.1 on a port the kernel chooses,
//   3. makes a .torrent from the payload, announcing to that tracker,
//   4. starts one instance of `torrent --engine` pointed at the directory that
//      already holds the payload, which rechecks and becomes a seeder,
//   5. starts a second instance pointed at an empty directory,
//   6. waits for the second one to finish,
//   7. asserts the output is byte-for-byte the input, that every piece was
//      verified, and that the TRACKER saw both of them announce.
//
// Every address involved is 127.0.0.1 and every byte transferred was generated
// in step 1. Nothing is fetched from anywhere.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

E2E :: struct {
	bin:         string,
	root:        string,
	seed_dir:    string, // holds the complete payload
	out_dir:     string, // starts empty
	torrent:     string,
	ports_file:  string,
	stop_file:   string,
	seed_status: string,
	leech_status: string,
	seed_status2: string,
	leech_status2: string,
	tracker_log: string,
	seed_log:    string,
	leech_log:   string,

	tracker:     os.Process,
	seeder:      os.Process,
	leecher:     os.Process,
	have_tracker: bool,
	have_seeder: bool,
	have_leecher: bool,

	http_port:   int,
	udp_port:    int,
}

E2E_TIMEOUT :: 120.0

// find_self locates this binary, so the test can run two more copies of it.
// It never searches $PATH: the binary under test is the one that is running.
find_self :: proc() -> (path: string, ok: bool) {
	self := os.args[0]
	if strings.contains(self, "/") && os.exists(self) {
		return self, true
	}
	for c in ([?]string {
			"apps/torrent/torrent.bin",
			"./torrent.bin",
			"/home/alex/Work/palmy/apps/torrent/torrent.bin",
		}) {
		if os.exists(c) {
			return c, true
		}
	}
	return self, false
}

run_e2e :: proc(t: ^T) -> bool {
	tsection(t, "end-to-end: a real transfer between two of our own clients")

	e := E2E{}
	bin, found := find_self()
	if !tcheck(t, "the binary under test was found", found, bin) {
		return false
	}
	e.bin = bin

	stamp := time.to_unix_nanoseconds(time.now())
	e.root = asprint("/tmp/palmy-torrent-e2e-%d", stamp)
	e.seed_dir = path_join(e.root, "seed")
	e.out_dir = path_join(e.root, "out")
	e.torrent = path_join(e.root, "payload.torrent")
	e.ports_file = path_join(e.root, "ports")
	e.stop_file = path_join(e.root, "stop")
	e.seed_status = path_join(e.root, "seed.status")
	e.leech_status = path_join(e.root, "leech.status")
	e.seed_status2 = path_join(e.root, "seed2.status")
	e.leech_status2 = path_join(e.root, "leech2.status")
	e.tracker_log = path_join(e.root, "tracker.log")
	e.seed_log = path_join(e.root, "seeder.log")
	e.leech_log = path_join(e.root, "leecher.log")
	defer e2e_cleanup(&e)

	if !tcheck(t, "the test directory is created", make_dirs(e.seed_dir) == "" && make_dirs(e.out_dir) == "") {
		return false
	}
	fmt.printfln("  working in %s", e.root)

	// 1. The payload. Generated here, from a deterministic generator.
	if !tcheck(t, "the synthetic payload is generated", make_payload(e.seed_dir) == "") {
		return false
	}
	total := payload_total()
	fmt.printfln(
		"  payload: %d files, %s, generated from a seeded xorshift (nothing was downloaded)",
		len(PAYLOAD),
		human_size(total, context.temp_allocator),
	)
	teq_i64(t, "the payload is the expected size", total, 2_656_658)

	// 2. The tracker.
	if !tcheck(t, "the tracker starts on loopback", e2e_start_tracker(&e) == "") {
		e2e_dump(e.tracker_log, "tracker")
		return false
	}
	tcheck(t, "...and reported its HTTP port", e.http_port > 0, asprint("%d", e.http_port))
	tcheck(t, "...and its UDP port", e.udp_port > 0, asprint("%d", e.udp_port))
	announce := asprint("http://127.0.0.1:%d/announce", e.http_port)
	fmt.printfln("  tracker: %s", announce)

	// 3. The torrent, made from the payload we just generated.
	data, cerr := metainfo_create(
		path_join(e.seed_dir, PAYLOAD_NAME, allocator = context.temp_allocator),
		Make_Opts {
			piece_length = PAYLOAD_PIECE_LENGTH,
			announce = announce,
			comment = "synthetic payload, generated locally",
		},
		context.temp_allocator,
	)
	if !tcheck(t, "a .torrent is made from the payload", cerr == "", cerr) {
		return false
	}
	if !tcheck(t, "...and written to disk", write_file(e.torrent, data) == "") {
		return false
	}
	m, merr := metainfo_parse(clone_bytes(data, context.temp_allocator), context.temp_allocator)
	if !tcheck(t, "...and parses back", merr == "", merr) {
		return false
	}
	npieces := piece_count(&m)
	fmt.printfln(
		"  torrent: %s, %d pieces of %s, info-hash %s",
		m.name,
		npieces,
		human_size(m.piece_length, context.temp_allocator),
		hash20_hex(m.info_hash, context.temp_allocator),
	)
	teq_i64(t, "the torrent's total length is the payload's", m.total_length, total)
	teq_int(t, "...over seven files", len(m.files), 7)
	teq_int(t, "...in 82 pieces of 32 KiB", npieces, 82)

	// 4 and 5. Two clients. The seeder's download directory already contains
	// the payload, so its startup recheck finds every piece.
	if !tcheck(t, "the seeder starts", e2e_start_seeder(&e) == "") {
		e2e_dump(e.seed_log, "seeder")
		return false
	}
	if !tcheck(t, "the leecher starts", e2e_start_leecher(&e) == "") {
		e2e_dump(e.leech_log, "leecher")
		return false
	}

	// The seeder must reach 100% from its recheck alone, before anything is
	// transferred — otherwise the test would be measuring the wrong thing.
	seed_ready := false
	for i in 0 ..< 400 {
		st := read_status(e.seed_status, context.temp_allocator)
		if st.ok && st.state == "Seeding" && st.have == npieces {
			seed_ready = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	if !tcheck(
		t,
		"the seeder rechecked the payload and holds all 82 pieces",
		seed_ready,
		"the seeder never reached 100% from its own files",
	) {
		e2e_dump(e.seed_log, "seeder")
		e2e_dump(e.tracker_log, "tracker")
		return false
	}
	sst := read_status(e.seed_status, context.temp_allocator)
	teq_int(t, "...and it downloaded nothing to get there", int(sst.downloaded), 0)

	// 6. The transfer.
	fmt.println("  transferring…")
	start := now_s()
	finished := false
	last_print := 0.0
	peers_seen := 0
	for now_s() - start < E2E_TIMEOUT {
		st := read_status(e.leech_status, context.temp_allocator)
		if st.ok {
			peers_seen = max(peers_seen, st.peers)
			if now_s() - last_print > 1.0 {
				last_print = now_s()
				fmt.printfln(
					"    %.1f%%  %d/%d pieces  %s  %d peer(s)",
					st.progress * 100,
					st.have,
					npieces,
					human_rate(st.down_rate, context.temp_allocator),
					st.peers,
				)
			}
			if st.error != "" {
				tcheck(t, "the leecher reported no error", false, st.error)
				break
			}
			if st.have == npieces && st.state == "Seeding" {
				finished = true
				break
			}
		}
		time.sleep(100 * time.Millisecond)
	}
	elapsed := now_s() - start
	done_at := time.now()

	if !tcheck(
		t,
		asprint("the transfer completed in under %.0fs", E2E_TIMEOUT),
		finished,
		asprint("it did not finish; %.1fs elapsed", elapsed),
	) {
		e2e_dump(e.leech_log, "leecher")
		e2e_dump(e.seed_log, "seeder")
		e2e_dump(e.tracker_log, "tracker")
		fmt.printfln("  last leecher status:\n%s", read_file_text(e.leech_status))
		return false
	}
	fmt.printfln(
		"  transfer finished in %.2fs (%s average)",
		elapsed,
		human_rate(f64(total) / max(elapsed, 0.001), context.temp_allocator),
	)

	lst := read_status(e.leech_status, context.temp_allocator)
	teq_int(t, "the leecher holds every piece", lst.have, npieces)
	teq_int(t, "every piece it holds passed SHA-1 before being written", lst.verified, npieces)
	teq_i64(t, "it downloaded exactly the payload's worth of verified bytes", lst.downloaded, total)
	teq_f32(t, "its progress is 100%", f32(lst.progress), 1.0, 0.0001)
	teq(t, "its state is Seeding", lst.state, "Seeding")
	tcheck(t, "it was connected to at least one peer", peers_seen >= 1, asprint("%d", peers_seen))
	teq(t, "the leecher's info-hash is the torrent's", lst.info_hash, hash20_hex(m.info_hash, context.temp_allocator))

	// The seeder's side of the story. Its status file is rewritten every
	// 0.2 s of its own loop, so the copy on disk when the leecher finished
	// can predate the last blocks it sent: read one written after that.
	sst2, fresh2 := read_status_after(e.seed_status, done_at, STATUS_FRESH_LIMIT, context.temp_allocator)
	tcheck(t, "the seeder wrote its status after the leecher finished", fresh2)
	tcheck(
		t,
		"the seeder uploaded at least the payload",
		sst2.uploaded >= total,
		asprint("it uploaded %d of %d", sst2.uploaded, total),
	)

	// 7a. The tracker's own account of the exchange.
	stats, serr := e2e_tracker_stats(&e)
	if tcheck(t, "the tracker's /stats is readable", serr == "", serr) {
		tcheck(t, "the tracker knows about one swarm", strings.contains(stats, "swarms 1"), stats)
		tcheck(
			t,
			"...for our info-hash",
			strings.contains(stats, hash20_hex(m.info_hash, context.temp_allocator)),
			stats,
		)
		announces := strings.count(stats, "\nannounce ")
		tcheck(
			t,
			"...having seen at least two announces",
			announces >= 2,
			asprint("it logged %d", announces),
		)
		// Both clients, identified by their distinct peer ids.
		ids := make(map[string]bool, 4, context.temp_allocator)
		lines := strings.split_lines(stats, context.temp_allocator)
		for line in lines {
			if !strings.has_prefix(line, "announce ") {
				continue
			}
			f := strings.fields(line, context.temp_allocator)
			if len(f) >= 3 {
				ids[f[2]] = true
			}
		}
		tcheck(
			t,
			"...from two distinct peers — the seeder and the leecher",
			len(ids) >= 2,
			asprint("it saw %d distinct peer id(s): %v", len(ids), ids),
		)
		tcheck(t, "...and recorded at least two `started` events", strings.contains(stats, "started 2") || strings.contains(stats, "started 3") || strings.contains(stats, "started 4"), stats)
		if t.verbose {
			fmt.printfln("  tracker /stats:\n%s", stats)
		}
	}

	// 7b. THE VERDICT: byte for byte.
	fmt.println("  comparing the leecher's output with the source, byte for byte…")
	all_same := true
	compared := 0
	bytes_compared: i64 = 0
	for f in m.files {
		src := path_join(e.seed_dir, PAYLOAD_NAME, f.path, allocator = context.temp_allocator)
		dst := path_join(e.out_dir, PAYLOAD_NAME, f.path, allocator = context.temp_allocator)
		same, detail := files_identical(src, dst)
		if !tcheck(t, asprint("%s is byte-for-byte identical", f.path), same, detail) {
			all_same = false
		}
		compared += 1
		bytes_compared += f.length
	}
	teq_int(t, "every file in the torrent was compared", compared, 7)
	teq_i64(t, "...totalling the whole payload", bytes_compared, total)
	tcheck(
		t,
		"THE LEECHER'S OUTPUT IS BYTE-FOR-BYTE THE SOURCE",
		all_same,
		"at least one file differs",
	)

	// And an independent check: re-hash the leecher's output against the
	// torrent's piece hashes, from this process, using neither client.
	out_store: Storage
	if tcheck(t, "a storage over the leecher's output opens", storage_open(&out_store, &m, e.out_dir) == "") {
		defer storage_destroy(&out_store)
		have := bf_make(npieces, context.temp_allocator)
		verified := storage_check_all(&out_store, &have)
		teq_int(t, "every one of the 82 pieces re-hashes correctly", verified, npieces)
		tcheck(t, "...so the output is complete", bf_complete(have))
	}

	// 7c. The scrape, against the tracker this test started. A scrape is a
	// read: it asks how big the swarm is and does NOT join it, which is the
	// whole reason it is a separate message.
	{
		bogus, _ := hash20_from_hex("00112233445566778899aabbccddeeff00112233")
		uurl := asprint("udp://127.0.0.1:%d/announce", e.udp_port)
		su, suerr := tracker_scrape_udp(
			uurl,
			{m.info_hash, bogus},
			3000,
			context.temp_allocator,
		)
		if tcheck(t, "a UDP scrape round-trips against the loopback tracker", suerr == "", suerr) {
			teq_int(t, "...answering about both info-hashes asked, in order", len(su), 2)
			if len(su) == 2 {
				tcheck(
					t,
					"...the first entry is OUR torrent",
					hash20_eq(su[0].info_hash, m.info_hash),
				)
				tcheck(
					t,
					"...with at least one seeder in it",
					su[0].complete >= 1,
					asprint("complete %d / downloaded %d / incomplete %d", su[0].complete, su[0].downloaded, su[0].incomplete),
				)
				tcheck(
					t,
					"...and the tracker counted at least one completion",
					su[0].downloaded >= 1,
					asprint("downloaded %d", su[0].downloaded),
				)
				tcheck(
					t,
					"...while a torrent it never heard of comes back all zeros",
					su[1].complete == 0 && su[1].downloaded == 0 && su[1].incomplete == 0,
					asprint("%v", su[1]),
				)
			}
		}
		sh, sherr := tracker_scrape_http(announce, {m.info_hash}, 3000, context.temp_allocator)
		if tcheck(t, "an HTTP scrape round-trips too", sherr == "", sherr) {
			teq_int(t, "...about one torrent", len(sh), 1)
			if len(sh) == 1 {
				tcheck(t, "...ours", hash20_eq(sh[0].info_hash, m.info_hash))
				tcheck(
					t,
					"...and HTTP and UDP agree on the seeder count",
					len(su) == 2 && sh[0].complete == su[0].complete,
					asprint("http %d, udp %d", sh[0].complete, len(su) == 2 ? su[0].complete : -1),
				)
			}
		}
	}

	// 7d. BEP 9: resolve a magnet for this torrent against the SEEDER that is
	// still running, with no .torrent anywhere in the picture.
	//
	// The magnet carries the info-hash and the tracker URL and nothing else.
	// The address of the peer to ask comes from that tracker; the metadata
	// comes from the peer; and the bytes are not believed until SHA-1 over
	// them is the hash the magnet carried. No DHT is involved and none could
	// be: there is no DHT in this program.
	{
		mg_uri := asprint(
			"magnet:?xt=urn:btih:%s&dn=%s&tr=%s",
			hash20_hex(m.info_hash, context.temp_allocator),
			url_encode(m.name, context.temp_allocator),
			url_encode(announce, context.temp_allocator),
		)
		mg, mgerr := magnet_parse(mg_uri, context.temp_allocator)
		if tcheck(t, "the magnet for this torrent parses", mgerr == "", mgerr) {
			probe_id := peer_id_new(0xBEE9)
			res, rerr := magnet_resolve(mg, probe_id, 0, 5000, context.temp_allocator)
			if tcheck(
				t,
				"A MAGNET RESOLVES OVER BEP 9 WITH NO LOCAL .torrent",
				rerr == "",
				rerr == "" ? "" : asprint("%s; notes: %v", rerr, res.notes),
			) {
				tcheck(
					t,
					"...from a peer the magnet's own tracker named",
					res.from_host == "127.0.0.1" && res.from_port > 0,
					asprint("%s:%d of %d peer(s) seen", res.from_host, res.from_port, res.peers_seen),
				)
				rm, rmerr := metainfo_parse(
					clone_bytes(res.torrent, context.temp_allocator),
					context.temp_allocator,
				)
				if tcheck(t, "...the resolved .torrent parses", rmerr == "", rmerr) {
					tcheck(
						t,
						"...and ITS INFO-HASH IS THE ONE IN THE MAGNET",
						hash20_eq(rm.info_hash, m.info_hash),
						hash20_hex(rm.info_hash, context.temp_allocator),
					)
					teq(t, "...the name came across", rm.name, m.name)
					teq_int(t, "...all 82 piece hashes came across", piece_count(&rm), npieces)
					teq_i64(t, "...and the total length", rm.total_length, m.total_length)
					same_pieces := true
					for i in 0 ..< min(piece_count(&rm), npieces) {
						if !hash20_eq(rm.pieces[i], m.pieces[i]) {same_pieces = false}
					}
					tcheck(
						t,
						"...every piece hash is identical to the original torrent's",
						same_pieces,
					)
					tcheck(
						t,
						"...and the info bytes were spliced, not re-encoded",
						slice.equal(
							rm.raw[rm.info_span[0]:rm.info_span[1]],
							m.raw[m.info_span[0]:m.info_span[1]],
						),
					)
				}
			}
			magnet_resolution_destroy(&res, context.temp_allocator)
		}
	}

	// 7e. The upload limit, MEASURED.
	//
	// The same payload, the same two programs, the same loopback — the only
	// difference is `--up-limit` on the seeder. If the limit does nothing the
	// second transfer takes about as long as the first; if it works, it
	// cannot finish faster than the payload divided by the limit.
	up_elapsed := 0.0
	{
		UP_LIMIT :: 700_000
		floor := f64(total) / f64(UP_LIMIT)
		_ = os.process_kill(e.leecher)
		_, _ = os.process_wait(e.leecher)
		e.have_leecher = false
		_ = os.process_kill(e.seeder)
		_, _ = os.process_wait(e.seeder)
		e.have_seeder = false
		rm_rf(path_join(e.out_dir, PAYLOAD_NAME, allocator = context.temp_allocator))

		fmt.printfln(
			"  measuring the upload limit: %s of payload at %s should take at least %.1fs",
			human_size(total, context.temp_allocator),
			human_rate(UP_LIMIT, context.temp_allocator),
			floor,
		)
		if tcheck(
			t,
			"a rate-limited seeder starts",
			e2e_start_seeder(&e, e.seed_status2, {"--up-limit", "700000"}) == "",
		) &&
		   tcheck(t, "...and a fresh leecher", e2e_start_leecher(&e, e.leech_status2) == "") {
			ustart := now_s()
			udone := false
			for now_s() - ustart < 60.0 {
				st := read_status(e.leech_status2, context.temp_allocator)
				if st.ok && st.error != "" {
					tcheck(t, "the rate-limited leecher reported no error", false, st.error)
					break
				}
				if st.ok && st.have == npieces && st.state == "Seeding" {
					udone = true
					break
				}
				time.sleep(50 * time.Millisecond)
			}
			up_elapsed = now_s() - ustart
			udone_at := time.now()
			rate := f64(total) / max(up_elapsed, 0.001)
			fmt.printfln(
				"  rate-limited transfer finished in %.2fs (%s average) against an unlimited %.2fs (%s)",
				up_elapsed,
				human_rate(rate, context.temp_allocator),
				elapsed,
				human_rate(f64(total) / max(elapsed, 0.001), context.temp_allocator),
			)
			if tcheck(t, "the rate-limited transfer still completed", udone, asprint("%.1fs", up_elapsed)) {
				tcheck(
					t,
					"THE UPLOAD LIMIT IS HONOURED: it could not go faster than the budget allows",
					up_elapsed >= floor * 0.7,
					asprint("it took %.2fs; the floor at %d B/s is %.2fs", up_elapsed, UP_LIMIT, floor),
				)
				tcheck(
					t,
					"...and the measured rate is within 60% of the limit, not an order out",
					rate <= f64(UP_LIMIT) * 1.6,
					asprint("%s against a %s limit", human_rate(rate, context.temp_allocator), human_rate(UP_LIMIT, context.temp_allocator)),
				)
				tcheck(
					t,
					"...and it is strictly slower than the same transfer unlimited",
					up_elapsed > elapsed,
					asprint("%.2fs limited against %.2fs unlimited", up_elapsed, elapsed),
				)
				// The same race as above, and the one that failed about one
				// run in six under load: read a status written after the
				// leecher finished, not whatever was on disk then.
				ust, ufresh := read_status_after(e.seed_status2, udone_at, STATUS_FRESH_LIMIT, context.temp_allocator)
				tcheck(t, "...the seeder wrote its status after the leecher finished", ufresh)
				tcheck(
					t,
					"...while the seeder still uploaded the whole payload",
					ust.uploaded >= total,
					asprint("%d of %d", ust.uploaded, total),
				)
				same2, detail2 := files_identical(
					path_join(e.seed_dir, PAYLOAD_NAME, PAYLOAD[1].rel, allocator = context.temp_allocator),
					path_join(e.out_dir, PAYLOAD_NAME, PAYLOAD[1].rel, allocator = context.temp_allocator),
				)
				tcheck(t, "...and throttling corrupted nothing", same2, detail2)
			}
		}
	}

	// 8. Shut the children down cleanly, so the seeder announces `stopped`.
	write_file_string(e.stop_file, "stop\n")
	e2e_wait(&e, 10)
	stats2, _ := e2e_tracker_stats(&e)
	_ = stats2

	fmt.printfln(
		"\n  RESULT: %d files / %s transferred between two local clients in %.2fs, every piece verified, output identical to source.",
		len(m.files),
		human_size(total, context.temp_allocator),
		elapsed,
	)
	return all_same && finished
}

// ---------------------------------------------------------------------------
// Child processes
// ---------------------------------------------------------------------------

@(private = "file")
spawn :: proc(bin: string, args: []string, log_path: string) -> (p: os.Process, err: string) {
	logf, lerr := os.open(log_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if lerr != nil {
		return {}, tsprint("cannot open %s: %v", log_path, lerr)
	}
	defer os.close(logf)
	cmd := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&cmd, bin)
	append(&cmd, ..args)
	proc_, perr := os.process_start(
		os.Process_Desc{command = cmd[:], stdout = logf, stderr = logf},
	)
	if perr != nil {
		return {}, tsprint("cannot start %s: %v", bin, perr)
	}
	return proc_, ""
}

@(private = "file")
e2e_start_tracker :: proc(e: ^E2E) -> (err: string) {
	os.remove(e.ports_file)
	p, serr := spawn(
		e.bin,
		{
			"--tracker",
			"--http-port",
			"0",
			"--udp-port",
			"0",
			"--ports-file",
			e.ports_file,
			"--run-for",
			"300",
		},
		e.tracker_log,
	)
	if serr != "" {
		return serr
	}
	e.tracker = p
	e.have_tracker = true
	// The ports file is written only once both listeners are bound, so its
	// appearance is the readiness signal.
	for i in 0 ..< 200 {
		if data, ok := read_file(e.ports_file, context.temp_allocator); ok && len(data) > 0 {
			for line in strings.split_lines(string(data), context.temp_allocator) {
				f := strings.fields(line, context.temp_allocator)
				if len(f) < 2 {
					continue
				}
				n, _ := strconv.parse_int(f[1], 10)
				switch f[0] {
				case "http":
					e.http_port = n
				case "udp":
					e.udp_port = n
				}
			}
			if e.http_port > 0 && e.udp_port > 0 {
				return ""
			}
		}
		time.sleep(25 * time.Millisecond)
	}
	return tsprint("the tracker never reported its ports; see %s", e.tracker_log)
}

@(private = "file")
e2e_start_seeder :: proc(e: ^E2E, status := "", extra: []string = nil) -> (err: string) {
	args := make([dynamic]string, 0, 16, context.temp_allocator)
	append(
		&args,
		"--engine",
		"--torrent",
		e.torrent,
		"--dir",
		e.seed_dir,
		"--port",
		"0",
		"--status-file",
		status == "" ? e.seed_status : status,
		"--stop-file",
		e.stop_file,
		"--run-for",
		"300",
	)
	append(&args, ..extra)
	p, serr := spawn(e.bin, args[:], e.seed_log)
	if serr != "" {
		return serr
	}
	e.seeder = p
	e.have_seeder = true
	return ""
}

@(private = "file")
e2e_start_leecher :: proc(e: ^E2E, status := "") -> (err: string) {
	p, serr := spawn(
		e.bin,
		{
			"--engine",
			"--torrent",
			e.torrent,
			"--dir",
			e.out_dir,
			"--port",
			"0",
			"--status-file",
			status == "" ? e.leech_status : status,
			"--stop-file",
			e.stop_file,
			"--run-for",
			"300",
		},
		e.leech_log,
	)
	if serr != "" {
		return serr
	}
	e.leecher = p
	e.have_leecher = true
	return ""
}

@(private = "file")
e2e_wait :: proc(e: ^E2E, seconds: f64) {
	deadline := now_s() + seconds
	for now_s() < deadline {
		alive := false
		if e.have_leecher {
			if st, err := os.process_wait(e.leecher, 0); err != nil || !st.exited {
				alive = true
			} else {
				e.have_leecher = false
			}
		}
		if e.have_seeder {
			if st, err := os.process_wait(e.seeder, 0); err != nil || !st.exited {
				alive = true
			} else {
				e.have_seeder = false
			}
		}
		if !alive {
			return
		}
		time.sleep(100 * time.Millisecond)
	}
}

// e2e_cleanup leaves nothing listening and nothing on disk. It runs whether the
// test passed or failed.
@(private = "file")
e2e_cleanup :: proc(e: ^E2E) {
	if e.have_leecher {
		_ = os.process_kill(e.leecher)
		_, _ = os.process_wait(e.leecher)
		e.have_leecher = false
	}
	if e.have_seeder {
		_ = os.process_kill(e.seeder)
		_, _ = os.process_wait(e.seeder)
		e.have_seeder = false
	}
	if e.have_tracker {
		_ = os.process_kill(e.tracker)
		_, _ = os.process_wait(e.tracker)
		e.have_tracker = false
	}
	rm_rf(e.root)
}

@(private = "file")
e2e_tracker_stats :: proc(e: ^E2E) -> (text: string, err: string) {
	status, body, gerr := http_get("127.0.0.1", e.http_port, "/stats", 3000, context.temp_allocator)
	if gerr != "" {
		return "", gerr
	}
	if status != 200 {
		return "", tsprint("the tracker answered HTTP %d for /stats", status)
	}
	return string(body), ""
}

@(private = "file")
e2e_dump :: proc(path, label: string) {
	data, ok := read_file(path, context.temp_allocator)
	if !ok {
		fmt.printfln("  (no %s log at %s)", label, path)
		return
	}
	fmt.printfln("  ---- %s log ----", label)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.trim_space(line) == "" {
			continue
		}
		fmt.printfln("  | %s", line)
	}
	fmt.printfln("  ---- end %s log ----", label)
}

// ---------------------------------------------------------------------------
// Reading a client's status file
// ---------------------------------------------------------------------------

Status :: struct {
	ok:         bool,
	port:       int,
	state:      string,
	progress:   f64,
	pieces:     int,
	have:       int,
	verified:   int,
	downloaded: i64,
	uploaded:   i64,
	wasted:     i64,
	down_rate:  f64,
	up_rate:    f64,
	peers:      int,
	info_hash:  string,
	error:      string,
	elapsed:    f64,
}

// A client rewrites its status file every 0.2 s of its own loop; five
// seconds is twenty-five of those, on a machine loaded enough to stretch them.
STATUS_FRESH_LIMIT :: 5 * time.Second

// read_status_after waits for a status file written after `since` and reads
// that one. A status file is a periodic snapshot, so the copy on disk at any
// moment may be up to one period (plus a loaded scheduler's delay) old: a
// counter checked against an event the test has just observed elsewhere must
// come from a snapshot taken after that event, or the check races the writer.
// `fresh` is false if no such snapshot appeared within `limit`; the stale one
// is returned then, so the failure shows what it held.
read_status_after :: proc(
	path: string,
	since: time.Time,
	limit: time.Duration,
	allocator := context.allocator,
) -> (
	s: Status,
	fresh: bool,
) {
	deadline := time.tick_add(time.tick_now(), limit)
	for {
		if fi, err := os.stat(path, context.temp_allocator); err == nil {
			if time.diff(since, fi.modification_time) > 0 {
				return read_status(path, allocator), true
			}
		}
		if time.tick_since(deadline) >= 0 {
			return read_status(path, allocator), false
		}
		time.sleep(25 * time.Millisecond)
	}
}

read_status :: proc(path: string, allocator := context.allocator) -> (s: Status) {
	data, ok := read_file(path, context.temp_allocator)
	if !ok {
		return s
	}
	s.ok = true
	for line in strings.split_lines(string(data), context.temp_allocator) {
		sp := strings.index_byte(line, ' ')
		if sp < 0 {
			continue
		}
		k := line[:sp]
		v := strings.trim_space(line[sp + 1:])
		switch k {
		case "port":
			s.port = parse_int_default(v, 0)
		case "state":
			s.state = strings.clone(v, allocator)
		case "progress":
			f, _ := strconv.parse_f64(v)
			s.progress = f
		case "pieces":
			s.pieces = parse_int_default(v, 0)
		case "have":
			s.have = parse_int_default(v, 0)
		case "verified":
			s.verified = parse_int_default(v, 0)
		case "downloaded":
			s.downloaded = i64(parse_int_default(v, 0))
		case "uploaded":
			s.uploaded = i64(parse_int_default(v, 0))
		case "wasted":
			s.wasted = i64(parse_int_default(v, 0))
		case "down_rate":
			f, _ := strconv.parse_f64(v)
			s.down_rate = f
		case "up_rate":
			f, _ := strconv.parse_f64(v)
			s.up_rate = f
		case "peers":
			s.peers = parse_int_default(v, 0)
		case "info_hash":
			s.info_hash = strings.clone(v, allocator)
		case "error":
			s.error = strings.clone(v, allocator)
		case "elapsed":
			f, _ := strconv.parse_f64(v)
			s.elapsed = f
		}
	}
	return s
}

read_file_text :: proc(path: string) -> string {
	data, ok := read_file(path, context.temp_allocator)
	if !ok {
		return "(no such file)"
	}
	return string(data)
}
