package main

// files --selftest: the Drive integration's logic, with no window, no
// palm-drive and no server (drive.odin). JSON as palm-drive prints it, and a
// real move between temporary folders standing in for ~/Drive/<handle>.

import "core:fmt"
import "core:os"
import "core:strings"

g_checks, g_fails: int

check :: proc(ok: bool, what: string, args: ..any) {
	g_checks += 1
	if !ok {
		g_fails += 1
		fmt.printf("  FAIL  ")
		fmt.printfln(what, ..args)
	}
}

IDENTITIES_JSON :: `{"ok":true,"identities":[
 {"handle":"alice","id":"1","name":"Alice","kind":"personal","root":"/home/a/Drive/alice"},
 {"handle":"alice-work","id":"2","name":"Alice at Northwind","kind":"work","root":"/home/a/Drive/alice-work/"}
],"config":"","device":"laptop"}`

STATUS_JSON :: `{"ok":true,"identities":[
 {"handle":"alice","root":"/home/a/Drive/alice","offline":false,"actions":[
   "would Upload_Change notes/today.md",
   "would Conflict report.txt",
   "would Download photos/2026/beach.jpg"]},
 {"handle":"alice-work","root":"/home/a/Drive/alice-work","offline":true,"actions":[
   "queued: upload new file Q3/plan.md",
   "queued: upload change budget.xlsx"]}
]}`

selftest :: proc() -> int {
	fmt.println("files self-test (Drive)")
	st := new(State)

	st.drive.ids = drive_parse_identities(IDENTITIES_JSON)
	check(len(st.drive.ids) == 2, "identities: two parsed (%d)", len(st.drive.ids))
	if len(st.drive.ids) == 2 {
		check(st.drive.ids[1].root == "/home/a/Drive/alice-work", "identities: a trailing / is dropped from the root")
		check(drive_tint(st.drive.ids[0].kind) != drive_tint(st.drive.ids[1].kind), "identities: personal and work are coloured apart")
	}
	check(len(drive_parse_identities(`{"ok":false,"error":"no session"}`)) == 0, "identities: an error answer is no identities")

	id, rel, ok := drive_of(&st.drive, "/home/a/Drive/alice/notes/today.md")
	check(ok && id.handle == "alice" && rel == "notes/today.md", "drive_of: alice, notes/today.md (%v %q)", id.handle, rel)
	id, rel, ok = drive_of(&st.drive, "/home/a/Drive/alice-work/Q3")
	check(ok && id.handle == "alice-work" && rel == "Q3", "drive_of: alice-work is not taken for alice (%v)", id.handle)
	_, rel, ok = drive_of(&st.drive, "/home/a/Drive/alice")
	check(ok && rel == "", "drive_of: the root itself")
	_, _, ok = drive_of(&st.drive, "/home/a/Documents/x")
	check(!ok, "drive_of: outside every drive")

	r, b := action_path("would Upload_New a b/c d.txt")
	check(r == "a b/c d.txt" && b == .Pending, "action: names with spaces (%q)", r)
	r, b = action_path("would Conflict x.txt")
	check(r == "x.txt" && b == .Conflict, "action: a conflict")
	r, b = action_path("queued: upload new folder Q3")
	check(r == "Q3" && b == .Pending, "action: queued new folder (%q)", r)
	r, b = action_path("moved locally a -> b")
	check(b == .None, "action: a move done is no badge")

	st.drive.offline = drive_parse_status(STATUS_JSON, &st.drive.badges, &st.drive.known)
	check(st.drive.offline, "status: an offline identity is reported")
	check(drive_badge(&st.drive, "/home/a/Drive/alice/notes/today.md", "today.md") == .Pending, "badge: a pending upload")
	check(drive_badge(&st.drive, "/home/a/Drive/alice/notes", "notes") == .Pending, "badge: its folder shows it too")
	check(drive_badge(&st.drive, "/home/a/Drive/alice/report.txt", "report.txt") == .Conflict, "badge: a conflict")
	check(drive_badge(&st.drive, "/home/a/Drive/alice/photos", "photos") == .Pending, "badge: a pending download's folders")
	check(drive_badge(&st.drive, "/home/a/Drive/alice/old.txt", "old.txt") == .Synced, "badge: nothing to do is synced")
	check(drive_badge(&st.drive, "/home/a/Drive/alice/r (conflicted copy, laptop, 2026-10-19 14.03).txt", "r (conflicted copy, laptop, 2026-10-19 14.03).txt") == .Conflict, "badge: a conflicted copy by its name")
	check(drive_badge(&st.drive, "/home/a/Drive/alice-work/Q3/plan.md", "plan.md") == .Pending, "badge: queued while offline")
	check(drive_badge(&st.drive, "/home/a/Music/x.mp3", "x.mp3") == .None, "badge: none outside a drive")

	check(drive_move_refusal(&st.drive, "/home/a/Drive/alice/a.txt", "/home/a/Drive/alice-work/Q3") != "", "move: refused between two identities")
	check(drive_move_refusal(&st.drive, "/home/a/Drive/alice/a.txt", "/home/a/Drive/alice/notes") == "", "move: inside one drive is a rename")
	check(drive_move_refusal(&st.drive, "/home/a/Documents/a.txt", "/home/a/Drive/alice") == "", "move: into a drive from outside is allowed")

	// A real Cut and Paste between two temporary 'drives'.
	base := fmt.tprintf("/tmp/files-selftest-%d", os.get_pid())
	a := fmt.tprintf("%s/Drive/alice", base)
	w := fmt.tprintf("%s/Drive/alice-work", base)
	_ = os.make_directory_all(fmt.tprintf("%s/sub", a))
	_ = os.make_directory_all(w)
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", a), transmute([]u8)string("hello"))
	delete(st.drive.ids)
	st.drive.ids = make([dynamic]Drive_Id)
	append(&st.drive.ids, Drive_Id{handle = "alice", root = a}, Drive_Id{handle = "alice-work", root = w})
	st.cwd = strings.clone(a)
	st.drive.cut = strings.clone(fmt.tprintf("%s/a.txt", a))
	st.cwd = strings.clone(w)
	drive_paste(st)
	check(os.exists(fmt.tprintf("%s/a.txt", a)) && !os.exists(fmt.tprintf("%s/a.txt", w)), "paste: across identities the file stays where it was")
	check(strings.contains(st.toast, "Share"), "paste: and Files says to share it instead (%q)", st.toast)
	st.cwd = strings.clone(fmt.tprintf("%s/sub", a))
	drive_paste(st)
	check(os.exists(fmt.tprintf("%s/sub/a.txt", a)) && !os.exists(fmt.tprintf("%s/a.txt", a)), "paste: inside one drive it moves (%q)", st.toast)
	_ = os.remove_all(base)

	// The core, with no window, and the command line over it (selftest_fs.odin).
	fmt.println("files self-test (core)")
	selftest_core()
	fmt.println("files self-test (command line)")
	selftest_cli()

	fmt.printfln("%d checks, %d failed", g_checks, g_fails)
	return g_fails == 0 ? 0 : 1
}
