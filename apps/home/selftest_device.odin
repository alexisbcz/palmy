// `home --selftest`, device half: Home on a real index (a scratch one,
// written through apps/index's own writer), not the fixtures.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import ic "../index/core"
import feed "../index/feed"

device_checks :: proc() {
	root := fmt.aprintf("/tmp/palm-home-selftest-%d", linux.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	now := time.to_unix_seconds(time.now())
	device.zone = nil // UTC for the test: days and minutes are predictable
	midnight := now - now % 86400

	write_ident :: proc(root: string, i: ic.Identity) {
		os.make_directory_all(fmt.tprintf("%s/%s", root, i.handle))
		_ = os.write_entire_file(fmt.tprintf("%s/%s/identity", root, i.handle), transmute([]u8)feed.identity_json(i))
	}
	write_ident(root, {handle = "camille", name = "Personal", kind = "personal", color = "teal", address = "camille@palm.test"})
	write_ident(root, {handle = "northwind", name = "Northwind", kind = "work", color = "blue", address = "camille@northwind.coop"})
	put :: proc(root, h: string, docs: []ic.Doc) {
		w, _ := ic.writer_open(root, h)
		for d in docs {
			ic.writer_put(w, d)
		}
		ic.writer_flush(w)
		ic.writer_close(w)
	}
	put(root, "camille", {
		{key = "mail:1", kind = .Mail, flags = {.Unread, .Waiting}, time = now - 600, title = "Flat viewing on Saturday?", who = "Ines Roux ines@example.org, camille@palm.test", body = "The agency can do 11:00 or 15:30.", detail = "Inbox", app = "mail", uri = "palm://camille/mail/m1"},
		{key = "event:1", kind = .Event, time = midnight + 23 * 3600, dur = 30, title = "Late call with Théo", detail = "Phone", app = "calendar"},
		{key = "file:Home/budget.md", kind = .Doc, time = now - 3600, title = "Apartment budget.md", body = "rent deposit roadmap", detail = "Home", app = "docs", uri = "/x/budget.md"},
	})
	put(root, "northwind", {
		{key = "mail:1", kind = .Mail, flags = {.Waiting}, time = now - 7200, title = "Q4 roadmap: sign-off", who = "Priya Shah priya@northwind.coop", body = "Need your sign-off on the roadmap.", detail = "Inbox", app = "mail"},
		{key = "event:1", kind = .Event, time = midnight + 23 * 3600 + 1800, dur = 15, title = "Standup", detail = "Video link", app = "calendar"},
		{key = "event:9", kind = .Task, time = midnight - 2 * 86400, title = "Sign off the Q4 roadmap", detail = "Work", app = "calendar"},
	})

	os.set_env("PALM_INDEX_DIR", root)
	defer os.unset_env("PALM_INDEX_DIR")
	os.unset_env("PALM_IDENTITY")
	s := device_load()
	device.zone = nil
	device_today(&s)
	check(len(s.identities) == 2, "device: two identities, from their index directories")
	waiting, events, overdue := 0, 0, 0
	for it in s.items {
		if it.waiting {waiting += 1}
		if it.kind == .Event && it.day == 0 {events += 1}
		if it.kind == .Task && it.dated && it.day == -2 {overdue += 1}
	}
	check(waiting == 2 && events == 2 && overdue == 1, "device: Today has both identities' waiting mail, events and the overdue task")
	r := search(&s, "roadm", -1)
	labelled := len(r.hits) == 3
	both := [2]bool{}
	for h in r.hits {
		it := s.items[h.item]
		if it.ident < 0 || it.ident >= len(s.identities) {
			labelled = false
		} else {
			both[it.ident] = true
		}
	}
	check(labelled && both[0] && both[1], "device: as-you-type over both indexes, every result labelled with its identity")
	r = search(&s, "roadmap", 1)
	only := len(r.hits) == 2
	for h in r.hits {
		if s.items[h.item].ident != 1 {only = false}
	}
	check(only && r.per_id[0] == 1, fmt.tprintf("device: narrowed to Northwind, and the chip still counts Personal's match (%d hits, %v)", len(r.hits), r.per_id[:2]))
	r = search(&s, "roadmap in:nowhere", -1)
	check(r.unknown != "" && len(r.hits) == 0, "device: an in: naming no identity is reported, not widened")

	// A scoped Home: PALM_IDENTITY=camille opens camille's index and no other.
	paths := make([dynamic]string)
	ic.opened_paths = &paths
	os.set_env("PALM_IDENTITY", "camille")
	s2 := device_load()
	device.zone = nil
	r2 := search(&s2, "roadmap", -1)
	os.unset_env("PALM_IDENTITY")
	ic.opened_paths = nil
	leaked := false
	for p in paths {
		if strings.contains(p, "/northwind") {leaked = true}
	}
	check(len(s2.identities) == 1 && len(r2.hits) == 1 && !leaked, "device: PALM_IDENTITY=camille sees one identity and never opens northwind's files")
	for t in device.targets {
		ic.index_close(t.ix)
	}
	clear(&device.targets)
	clear(&device.idents)
}
