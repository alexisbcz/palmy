// palm-drive — keeps ~/Drive/<handle>/ and the identity's cloud drive the same.
//
//     palm-drive sync            one reconciling pass per identity, then exit
//     palm-drive watch           the daemon: inotify + a poll of the server
//     palm-drive status          what a pass would do, changing nothing
//     palm-drive identities      which drives this device mirrors, and where
//
// Every identity is synced with its own token, scoped to that identity, so a
// bug here that mixed two folders up would be refused by the database rather
// than carried out. The rules are in cloud/core/sync.odin and, in prose, in
// cloud/docs/drive.md.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:time"
import dc "drive:core"
import kit "kit:."

@(private = "file")
PASS_FIELDS := []kit.Field {
	{
		name = "identities",
		kind = .Array,
		of = {
			{name = "handle", kind = .String},
			{name = "root", kind = .String},
			{name = "offline", kind = .Bool},
			{name = "passes", kind = .Int},
			{name = "uploaded", kind = .Int},
			{name = "downloaded", kind = .Int},
			{name = "deleted_local", kind = .Int},
			{name = "trashed_remote", kind = .Int},
			{name = "moved_local", kind = .Int},
			{name = "moved_remote", kind = .Int},
			{name = "folders", kind = .Int},
			{name = "conflicts", kind = .Int},
			{name = "chunks_sent", kind = .Int},
			{name = "chunks_deduped", kind = .Int},
			{name = "bytes_sent", kind = .Int},
			{name = "actions", kind = .Array, of = {{kind = .String}}},
			{name = "errors", kind = .Array, of = {{kind = .String}}},
		},
	},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "sync",
		summary = "reconcile each identity's folder with its drive, until nothing is left to do",
		effect = .Idempotent,
		flags = {{name = "passes", kind = .Int, help = "at most this many passes per identity", def = "4"}},
		out = PASS_FIELDS,
		examples = {"palm-drive sync --json", "palm-drive sync --identity alice-work --json"},
		run = cmd_sync,
	},
	{
		verb = "status",
		summary = "what a sync would do now, without doing it; offline, what is queued",
		effect = .Read,
		out = PASS_FIELDS,
		examples = {"palm-drive status --json"},
		run = cmd_status,
	},
	{
		verb = "watch",
		summary = "the daemon: sync on every local change, and poll the server",
		effect = .Mutate,
		flags = {
			{name = "poll", kind = .Int, help = "seconds between server polls", def = "15"},
			{name = "for", kind = .Int, help = "exit after this many seconds (0: run until stopped)", def = "0"},
		},
		out = {{name = "passes", kind = .Int}},
		examples = {"palm-drive watch", "palm-drive watch --poll 5 --for 60"},
		run = cmd_watch,
	},
	{
		verb = "identities",
		summary = "the drives this device mirrors, and where",
		effect = .Read,
		out = {
			{
				name = "identities",
				kind = .Array,
				of = {
					{name = "handle", kind = .String},
					{name = "id", kind = .String},
					{name = "name", kind = .String},
					{name = "kind", kind = .String},
					{name = "root", kind = .String},
				},
			},
			{name = "config", kind = .String},
			{name = "device", kind = .String},
		},
		examples = {"palm-drive identities --json"},
		run = cmd_identities,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "palm-drive",
			summary  = "two-way sync of ~/Drive/<identity> with the identity's cloud drive",
			commands = COMMANDS,
			selftest = selftest,
			notes    = `Configuration is ~/.config/palm-drive/drive.conf ($PALM_DRIVE_CONFIG): the
server, and one [identity] block per drive with a token scoped to it. The
folder for each is ~/Drive/<handle> ($PALM_DRIVE_DIR moves the parent).
State is ~/.local/state/palm-drive/<handle>.state ($PALM_DRIVE_STATE).
With $PALM_IDENTITY set, or --identity, only that identity is synced.`,
		}
	}
	return &g_surface
}

main :: proc() {
	if len(os.args) < 2 {
		os.args = {os.args[0], "--help"}
	}
	code, _ := kit.cli(surface())
	os.exit(code)
}

@(private = "file")
load :: proc(c: ^kit.Call) -> (cfg: dc.Config, ids: [dynamic]^dc.Identity, code: int) {
	err: string
	cfg, err = dc.load_config(dc.config_path())
	if err != "" {
		return cfg, nil, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	ids = make([dynamic]^dc.Identity)
	for &id in cfg.identities {
		if c.identity == "" || c.identity == id.handle {
			append(&ids, &id)
		}
	}
	if len(ids) == 0 {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no identity %q in %s", c.identity, cfg.path)
		return
	}
	return cfg, ids, kit.EXIT_OK
}

@(private = "file")
pass_json :: proc(id: ^dc.Identity, p: ^dc.Pass, passes: int) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "handle", id.handle)
	kit.jset_str(o, "root", id.root)
	kit.jset_bool(o, "offline", p.offline)
	kit.jset_int(o, "passes", passes)
	kit.jset_int(o, "uploaded", p.uploaded)
	kit.jset_int(o, "downloaded", p.downloaded)
	kit.jset_int(o, "deleted_local", p.deleted_local)
	kit.jset_int(o, "trashed_remote", p.trashed_remote)
	kit.jset_int(o, "moved_local", p.moved_local)
	kit.jset_int(o, "moved_remote", p.moved_remote)
	kit.jset_int(o, "folders", p.folders)
	kit.jset_int(o, "conflicts", p.conflicts)
	kit.jset_int(o, "chunks_sent", p.sent_chunks)
	kit.jset_int(o, "chunks_deduped", p.skipped_chunks)
	kit.jset_int(o, "bytes_sent", int(p.sent_bytes))
	acts := kit.jarr()
	for a in p.actions {
		kit.jpush(acts, kit.jstr(a))
	}
	kit.jset(o, "actions", acts)
	errs := kit.jarr()
	for e in p.errors {
		kit.jpush(errs, kit.jstr(e))
	}
	kit.jset(o, "errors", errs)
	return o
}

// merge folds one pass's counts into a running total.
@(private = "file")
merge :: proc(into, p: ^dc.Pass) {
	into.offline = p.offline
	into.uploaded += p.uploaded
	into.downloaded += p.downloaded
	into.deleted_local += p.deleted_local
	into.trashed_remote += p.trashed_remote
	into.moved_local += p.moved_local
	into.moved_remote += p.moved_remote
	into.folders += p.folders
	into.conflicts += p.conflicts
	into.sent_chunks += p.sent_chunks
	into.skipped_chunks += p.skipped_chunks
	into.sent_bytes += p.sent_bytes
	append(&into.actions, ..p.actions[:])
	append(&into.errors, ..p.errors[:])
}

// sync_identity runs passes until one changes nothing. A conflict, for
// instance, sets a local copy aside in one pass and uploads it in the next.
sync_identity :: proc(cfg: ^dc.Config, id: ^dc.Identity, max_passes: int) -> (total: dc.Pass, passes: int) {
	for passes < max(1, max_passes) {
		p := dc.sync_once(cfg, id)
		passes += 1
		merge(&total, p)
		if p.offline || !dc.pass_changed(p) {
			break
		}
	}
	return
}

@(private = "file")
cmd_sync :: proc(c: ^kit.Call) -> int {
	cfg, ids, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	arr := kit.jarr()
	any_offline := false
	for id in ids {
		if c.dry_run {
			p := dc.sync_once(&cfg, id, dry_run = true)
			kit.jpush(arr, pass_json(id, p, 1))
			continue
		}
		total, passes := sync_identity(&cfg, id, kit.cli_int(c, "passes", 4))
		any_offline ||= total.offline
		kit.jpush(arr, pass_json(id, &total, passes))
		kit.cli_note(
			c,
			"%s: %d up, %d down, %d moved, %d deleted, %d conflicts%s",
			id.handle,
			total.uploaded,
			total.downloaded,
			total.moved_local + total.moved_remote,
			total.deleted_local + total.trashed_remote,
			total.conflicts,
			total.offline ? " (offline: changes kept for later)" : "",
		)
	}
	kit.jset(c.out, "identities", arr)
	if any_offline {
		// Not a failure of the command: the work is queued. But a caller
		// scripting a sync wants to know it did not reach the server.
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "the server could not be reached; local changes are kept and will be sent on the next pass")
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	cfg, ids, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	arr := kit.jarr()
	for id in ids {
		p := dc.sync_once(&cfg, id, dry_run = true)
		kit.jpush(arr, pass_json(id, p, 0))
	}
	kit.jset(c.out, "identities", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_watch :: proc(c: ^kit.Call) -> int {
	cfg, ids, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	poll := max(1, kit.cli_int(c, "poll", 15))
	limit := kit.cli_int(c, "for", 0)
	started := time.now()
	w, ok := dc.watch_open()
	if !ok {
		return kit.cli_fail(c, kit.EXIT_FAILED, "inotify is not available")
	}
	defer dc.watch_close(&w)
	passes := 0
	run_all :: proc(c: ^kit.Call, cfg: ^dc.Config, ids: []^dc.Identity, w: ^dc.Watcher, passes: ^int) {
		// Each round of passes allocates into its own arena, freed at the
		// end, so a daemon that runs for weeks does not grow. The state that
		// must outlive a pass is on disk, which is the point of it.
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil {
			return
		}
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator
		for id in ids {
			total, n := sync_identity(cfg, id, 4)
			passes^ += n
			if dc.pass_changed(&total) || len(total.errors) > 0 {
				for a in total.actions {
					kit.cli_note(c, "%s: %s", id.handle, a)
				}
				for e in total.errors {
					kit.cli_note(c, "%s: ! %s", id.handle, e)
				}
			}
			dc.watch_tree(w, id.root)
		}
	}
	kit.cli_note(c, "palm-drive: watching %d identit%s, polling every %ds", len(ids), len(ids) == 1 ? "y" : "ies", poll)
	run_all(c, &cfg, ids[:], &w, &passes)
	for {
		if limit > 0 && time.duration_seconds(time.since(started)) >= f64(limit) {
			break
		}
		// A local change wakes us at once; otherwise the poll interval is
		// how long a change made elsewhere takes to arrive. Realtime (the
		// server pushing the feed) would remove that wait; see the doc.
		dc.watch_wait(&w, i32(poll * 1000))
		run_all(c, &cfg, ids[:], &w, &passes)
	}
	kit.jset_int(c.out, "passes", passes)
	return kit.EXIT_OK
}

@(private = "file")
cmd_identities :: proc(c: ^kit.Call) -> int {
	cfg, ids, code := load(c)
	if code != kit.EXIT_OK {
		return code
	}
	arr := kit.jarr()
	for id in ids {
		o := kit.jobj()
		kit.jset_str(o, "handle", id.handle)
		kit.jset_str(o, "id", id.id)
		kit.jset_str(o, "name", id.name)
		kit.jset_str(o, "kind", id.kind)
		kit.jset_str(o, "root", id.root)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "identities", arr)
	kit.jset_str(c.out, "config", cfg.path)
	kit.jset_str(c.out, "device", cfg.device)
	return kit.EXIT_OK
}

// selftest exercises what can be checked with no server: the state file
// round trip, conflict naming, and the chunker.
@(private = "file")
selftest :: proc() -> int {
	fails := 0
	check :: proc(ok: bool, what: string, fails: ^int) {
		fmt.printfln("%s %s", ok ? "ok  " : "FAIL", what)
		if !ok {
			fails^ += 1
		}
	}
	dir := "/tmp/palm-drive-selftest"
	os.remove_all(dir)
	os.make_directory_all(dir)
	st: dc.State
	st.remote = make(map[string]dc.Remote)
	st.base = make(map[string]dc.Base)
	st.cursor = 42
	st.remote["a"] = {id = "a", name = "we\tird %name", kind = "file", hash = "h", seq = 7, size = 3}
	st.base["dir/we\tird %name"] = {id = "a", kind = "file", hash = "h", size = 3, mtime = 99}
	st.base["-"] = {id = "b", kind = "folder"}
	path := fmt.tprintf("%s/x.state", dir)
	dc.save_state(path, &st)
	back := dc.load_state(path)
	check(back.cursor == 42, "state: cursor survives", &fails)
	check(back.remote["a"].name == "we\tird %name", "state: a name with a tab and a percent survives", &fails)
	check(back.base["dir/we\tird %name"].mtime == 99, "state: base survives", &fails)
	check(back.base["-"].id == "b", "state: a file literally named - survives", &fails)

	never :: proc(s: string, _: rawptr) -> bool {return false}
	n := dc.conflict_name("report.txt", "laptop", never, nil)
	check(len(n) > 0 && n[:7] == "report " && n[len(n) - 4:] == ".txt", fmt.tprintf("conflict name keeps stem and extension: %s", n), &fails)

	data := make([]u8, dc.CHUNK_SIZE + 10)
	for i in 0 ..< len(data) {
		data[i] = u8(i * 7)
	}
	fp := fmt.tprintf("%s/big.bin", dir)
	_ = os.write_entire_file(fp, data)
	h, ok := dc.hash_file(fp)
	check(ok && len(h.chunks) == 2 && h.size == i64(len(data)), "chunker: 4 MiB + 10 bytes is two chunks", &fails)
	check(h.hash == dc.sha256_hex(data), "chunker: whole-file hash is the hash of the bytes", &fails)
	_ = os.write_entire_file(fmt.tprintf("%s/empty", dir), []u8{})
	he, _ := dc.hash_file(fmt.tprintf("%s/empty", dir))
	check(len(he.chunks) == 1 && he.size == 0, "chunker: an empty file is one empty chunk", &fails)
	fmt.printfln("%d failed", fails)
	return fails == 0 ? 0 : 1
}
