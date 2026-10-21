package main

// Drive sync badges against a real palm-drive and a real drive server.
//
// selftest.odin checks the badge logic on canned `palm-drive status` text.
// This checks the same path end to end: the identities and the status come
// from the real palm-drive, talking to the cloud/drive development stack
// (Postgres, PostgREST, Storage behind Kong, in containers on loopback), read
// through drive_refresh's own thread exactly as the window does.
//
// It runs only inside drive-e2e.sh, which starts a private stack, seeds it,
// builds palm-drive, stages the scenario below with two devices, and runs
// `files --selftest` with FILES_DRIVE_E2E set. Without it this section is
// skipped, and says so: no server is assumed.
//
// The scenario, on device A's folder for alice.northwind, after both devices
// synced once:
//
//   notes/a.md       changed on A                 -> Pending (Upload_Change)
//   new/dir/c.md     new on A, in new folders     -> Pending, and its folders
//   photos/from-b.txt  added on B and synced      -> Pending (Download), and photos/
//   report.txt       changed on both              -> Conflict
//   old.txt, notes/b.md  untouched                -> Synced

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

selftest_drive_live :: proc() {
	if os.get_env("FILES_DRIVE_E2E", context.temp_allocator) == "" {
		fmt.println("files self-test (Drive, live): skipped — run apps/files/drive-e2e.sh for the real server")
		return
	}
	fmt.println("files self-test (Drive, live, against the dev stack)")

	st := new(State)
	st.drive.ids = drive_identities()
	check(len(st.drive.ids) == 1, "live: palm-drive identities names the one identity in scope (%d)", len(st.drive.ids))
	if len(st.drive.ids) != 1 {
		return
	}
	root := st.drive.ids[0].root
	check(st.drive.ids[0].handle == "alice.northwind" && is_dir_path(root), "live: alice.northwind, with its folder on disk (%q)", root)
	at :: proc(root, rel: string) -> string {return fmt.tprintf("%s/%s", root, rel)}

	// drive_refresh is what the window calls; it reads on a thread of its
	// own. Wait for that thread the way the frame does: on `running`.
	refresh :: proc(st: ^State) -> bool {
		st.cwd = strings.clone(st.drive.ids[0].root)
		drive_refresh(st)
		for _ in 0 ..< 600 {
			sync.mutex_lock(&st.drive.mu)
			done := !st.drive.running
			sync.mutex_unlock(&st.drive.mu)
			if done {
				return true
			}
			time.sleep(50 * time.Millisecond)
		}
		return false
	}
	badge :: proc(st: ^State, path: string) -> Drive_Badge {
		name := path[strings.last_index_byte(path, '/') + 1:]
		return drive_badge(&st.drive, path, name)
	}

	// --- before a sync: what a pass would do --------------------------------
	check(refresh(st), "live: the status thread finished")
	check(!st.drive.offline, "live: the server answered")
	check(badge(st, at(root, "notes/a.md")) == .Pending, "live: a file changed here is pending upload (%v)", badge(st, at(root, "notes/a.md")))
	check(badge(st, at(root, "notes")) == .Pending, "live: and its folder shows it")
	check(badge(st, at(root, "new/dir/c.md")) == .Pending, "live: a new file in new folders is pending (%v)", badge(st, at(root, "new/dir/c.md")))
	check(badge(st, at(root, "new")) == .Pending && badge(st, at(root, "new/dir")) == .Pending, "live: and so are the new folders")
	check(badge(st, at(root, "photos/from-b.txt")) == .Pending, "live: a file another device added is pending download (%v)", badge(st, at(root, "photos/from-b.txt")))
	check(badge(st, at(root, "photos")) == .Pending, "live: and the folder it will land in shows it")
	check(badge(st, at(root, "report.txt")) == .Conflict, "live: a file changed on both devices is a conflict (%v)", badge(st, at(root, "report.txt")))
	check(badge(st, at(root, "old.txt")) == .Synced && badge(st, at(root, "notes/b.md")) == .Synced, "live: untouched files are synced")
	check(badge(st, "/tmp/elsewhere.txt") == .None, "live: a path outside the drive has no badge")

	if dir := os.get_env("FILES_DRIVE_E2E_SHOTS", context.temp_allocator); dir != "" {
		check(drive_live_shot(st, dir, "files-drive-live-pending"), "live: the folder rendered with its real badges")
	}

	// --- a real sync, then the status again ----------------------------------
	_, ok := kit.run({"palm-drive", "sync", "--json"}, context.temp_allocator)
	check(ok, "live: palm-drive sync ran")
	check(refresh(st), "live: the status thread finished again")
	for rel in ([?]string{"notes/a.md", "notes", "new/dir/c.md", "new", "photos/from-b.txt", "photos", "report.txt", "old.txt"}) {
		check(badge(st, at(root, rel)) == .Synced, "live: after the sync, %s is synced (%v)", rel, badge(st, at(root, rel)))
	}
	check(os.exists(at(root, "photos/from-b.txt")), "live: the download arrived")
	copies := 0
	if names, err := os.read_directory_by_path(root, -1, context.temp_allocator); err == nil {
		for fi in names {
			if strings.contains(fi.name, "(conflicted copy, ") {
				copies += 1
				check(badge(st, fi.fullpath) == .Conflict, "live: the conflicted copy %q is marked by its name", fi.name)
			}
		}
	}
	check(copies == 1, "live: the conflict left exactly one conflicted copy (%d)", copies)

	// --- offline: the server unreachable, a change made meanwhile -------------
	offline_conf := os.get_env("FILES_DRIVE_OFFLINE_CONFIG", context.temp_allocator)
	if offline_conf != "" {
		_ = os.write_entire_file(at(root, "written-offline.txt"), transmute([]u8)string("offline\n"))
		online_conf := strings.clone(os.get_env("PALM_DRIVE_CONFIG", context.temp_allocator), context.temp_allocator)
		_ = os.set_env("PALM_DRIVE_CONFIG", offline_conf)
		check(refresh(st), "live: the status thread finished offline")
		check(st.drive.offline, "live: an unreachable server reads as offline")
		check(badge(st, at(root, "written-offline.txt")) == .Pending, "live: a change made offline is pending, queued (%v)", badge(st, at(root, "written-offline.txt")))
		check(badge(st, at(root, "old.txt")) == .Synced, "live: and the rest stays synced")
		if dir := os.get_env("FILES_DRIVE_E2E_SHOTS", context.temp_allocator); dir != "" {
			check(drive_live_shot(st, dir, "files-drive-live-offline"), "live: the offline folder rendered")
		}
		_ = os.set_env("PALM_DRIVE_CONFIG", online_conf)
	}
}

// drive_live_shot renders the browser on the drive's folder with whatever
// badges the last refresh read, so a person can look at the real thing.
@(private = "file")
drive_live_shot :: proc(st: ^State, dir, name: string) -> bool {
	// A frame frees the temp allocator, where `dir` came from.
	out := strings.clone(fmt.tprintf("%s/%s.png", dir, name))
	defer delete(out)
	_ = os.make_directory_all(dir)
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))
	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height, app.win.scale = SHOT_W, SHOT_H, 1
	app.fonts = off.fonts

	st.tz_offset = local_offset()
	st.now = time.now()
	if len(st.places) == 0 {
		build_places(st)
		for id in st.drive.ids {
			append(&st.places, Place{id.name, id.root, ICON_CLOUD, drive_tint(id.kind), "Drive"})
		}
	}
	// Not go_to: it would start another status read, and the point is to
	// draw the badges the last one left.
	load_dir(st, st.cwd)
	sync_place(st)
	st.pane = .Files
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		measure(ui, st)
		frame(ui, st)
		p.offscreen_end(off)
	}
	return p.offscreen_write_png(off, out)
}
