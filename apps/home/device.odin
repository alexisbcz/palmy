// The device source: Home's real data, read from the local search index
// (apps/index) that palm-indexd keeps, one index per identity.
//
// Home holds no data of its own and reads no app's files: Today and search
// are queries on the index (product.md P5, "Search, Today and the assistant
// read the local index first"). The identities are the ones with an index
// on this device; with $PALM_IDENTITY set, only that one is opened, which
// is the same rule the database applies to a scoped session.
//
//	Today        events today (and the next one), people waiting on you,
//	             tasks due today or overdue (calendar VTODOs) and open
//	             tracker issues, the most recently changed files and notes
//	Search       the index, as you type: the last word is a prefix
//	Opening      the application, in the item's own identity
//	             (apps/index/feed/open.odin)
//
// The index is re-read when it changes: one stat per identity every two
// seconds, so a mail that arrives shows up without touching anything.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import ical "../../cloud/dav/ical"
import ic "../index/core"
import feed "../index/feed"
import kit "kit:."

Device :: struct {
	paths:    feed.Paths,
	scope:    string,
	idents:   [dynamic]feed.Ident,
	targets:  [dynamic]ic.Target, // parallel to idents
	zone:     ^ical.Zone,
	stamp:    i64, // sum of the indexes' generations at the last load
	day:      i64, // the local day Today was built for
	minute:   int,
	n_base:   int, // Today's items; search results follow them in Store.items
	cache_q:  string, // the query the results below answer
	cache_id: int,
	cache_r:  Results,
	daemon:   bool,
	updated:  i64, // newest status time across identities
}

device: Device

// local_offset is the local zone's UTC offset at `t`, seconds.
local_offset :: proc(t: i64) -> i64 {
	if device.zone == nil {
		return 0
	}
	return ical.offset_at(device.zone, t)
}

local_day :: proc(t: i64) -> i64 {
	l := t + local_offset(t)
	return l >= 0 ? l / 86400 : (l - 86399) / 86400
}

local_minute :: proc(t: i64) -> int {
	l := t + local_offset(t)
	return int(((l % 86400) + 86400) % 86400 / 60)
}

// owner_name is the person's name for the greeting: $PALM_OWNER_NAME, the
// account's name in /etc/passwd, else the login name.
owner_name :: proc() -> string {
	if n := os.get_env("PALM_OWNER_NAME", context.temp_allocator); n != "" {
		return strings.clone(n)
	}
	user := os.get_env("USER", context.temp_allocator)
	if data, err := os.read_entire_file_from_path("/etc/passwd", context.temp_allocator); err == nil && user != "" {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, ":", context.temp_allocator)
			if len(f) > 4 && f[0] == user {
				gecos := f[4]
				if c := strings.index_byte(gecos, ','); c >= 0 {
					gecos = gecos[:c]
				}
				if strings.trim_space(gecos) != "" {
					return strings.clone(strings.trim_space(gecos))
				}
			}
		}
	}
	if user == "" {
		return "You"
	}
	b := transmute([]u8)strings.clone(user)
	if b[0] >= 'a' && b[0] <= 'z' {
		b[0] -= 32
	}
	return string(b)
}

// policy_words is what notifications do for an identity, in words. The
// notifications service (apps/notify) owns the real policy; until it
// publishes one, Home states the kind's default from product.md and says
// that it is the default.
policy_words :: proc(kind: string) -> string {
	switch kind {
	case "work":
		return "Quiet outside working hours (default)"
	case "public":
		return "Daily digest (default)"
	}
	return ""
}

device_load :: proc() -> Store {
	s := Store {
		source = .Device,
		owner  = owner_name(),
	}
	device.paths = feed.paths_default()
	device.scope = os.get_env("PALM_IDENTITY", context.temp_allocator)
	if device.scope != "" {
		device.scope = strings.clone(device.scope)
	}
	device.zone, _ = ical.iana_zone(ical.local_zone_name(context.temp_allocator))
	device_open(&s)
	device_today(&s)
	return s
}

// device_open (re)opens the indexes of the identities in scope.
device_open :: proc(s: ^Store) {
	for t in device.targets {
		ic.index_close(t.ix)
	}
	clear(&device.targets)
	clear(&device.idents)
	clear(&s.identities)
	ids := feed.identities_visible(device.paths.index, device.scope)
	for x in ids {
		ix, ok := ic.index_open(device.paths.index, x.handle)
		if !ok {
			continue
		}
		append(&device.idents, x)
		append(&device.targets, ic.Target{ident = x.info, ix = ix})
		kind := Identity_Kind.Personal
		switch x.kind {
		case "work":
			kind = .Work
		case "public":
			kind = .Public
		case "project":
			kind = .Project
		}
		addr := x.address
		if addr == "" {
			addr = fmt.aprintf("@%s", x.handle)
		}
		append(&s.identities, Identity{id = x.id, handle = x.handle, name = x.name, address = addr, kind = kind, color = x.color, quiet = policy_words(x.kind)})
	}
	if len(device.idents) == 0 && device.scope == "" {
		// Nothing indexed yet. The session should run palm-indexd; if it
		// does not, Home starts it, once.
		if _, running := feed.daemon_pid(device.paths.index); !running {
			kit.launch({"palm-indexd"})
		}
	}
}

// device_stamp changes whenever any index in scope does.
device_stamp :: proc() -> i64 {
	n: i64
	for t in device.targets {
		ic.index_refresh(t.ix)
		n += i64(t.ix.gen) * 1_000_003 + i64(t.ix.ndocs)
	}
	return n
}

// device_tick runs every frame: re-read what changed, rebuild Today when
// the index or the minute moved. Returns true when it rebuilt.
device_tick :: proc(s: ^Store) -> bool {
	if s.source != .Device {
		return false
	}
	now := time.to_unix_seconds(time.now())
	stamp := device_stamp()
	if local_minute(now) == device.minute && local_day(now) == device.day && stamp == device.stamp {
		return false
	}
	device_today(s)
	return true
}

// first_person is the sender out of the index's people field ("Name
// address, To…"): the name, else the address.
first_person :: proc(who: string) -> string {
	w := who
	if c := strings.index(w, ", "); c >= 0 {
		w = w[:c]
	}
	f := strings.fields(w, context.temp_allocator)
	if len(f) > 1 && strings.contains(f[len(f) - 1], "@") {
		return strings.join(f[:len(f) - 1], " ", context.temp_allocator)
	}
	return w
}

@(private = "file")
query_one :: proc(t: ic.Target, q: ic.Query, opt: ic.Options) -> [dynamic]ic.Result {
	q := q
	out := make([dynamic]ic.Result, context.temp_allocator)
	st: ic.Stats
	ts := []ic.Target{t}
	ic.search_all(ts, &q, opt, &out, &st)
	return out
}

item_from :: proc(r: ic.Result, ident: int, today: i64) -> Item {
	it := Item {
		kind   = kind_from(r.kind),
		ident  = ident,
		title  = strings.clone(r.title),
		detail = strings.clone(r.detail),
		who    = strings.clone(r.who),
		app    = strings.clone(app_label(r.app)),
		day    = int(local_day(r.time) - today),
		at     = local_minute(r.time),
		mins   = int(r.dur),
		unread = .Unread in r.flags,
		waiting = .Waiting in r.flags,
		done   = .Done in r.flags,
		key    = strings.clone(r.key),
		uri    = strings.clone(r.uri),
		raw_app = strings.clone(r.app),
		snippet = strings.clone(r.snippet),
		time   = r.time,
	}
	if len(r.marks) > 0 {
		it.mark = r.marks[0]
	} else {
		it.mark = {-1, -1}
	}
	return it
}

kind_from :: proc(k: ic.Kind) -> Kind {
	switch k {
	case .Mail:
		return .Mail
	case .Event:
		return .Event
	case .Task:
		return .Task
	case .Doc:
		return .Doc
	case .File:
		return .File
	case .Note:
		return .Note
	case .Chat:
		return .Chat
	case .Person:
		return .Person
	case .Page:
		return .Page
	case .Issue:
		return .Issue
	}
	return .File
}

app_label :: proc(app: string) -> string {
	switch app {
	case "docs":
		return "Docs"
	case "sheets":
		return "Sheets"
	case "slides":
		return "Slides"
	case "reader":
		return "Reader"
	case "image":
		return "Image"
	case "video":
		return "Video"
	case "audio":
		return "Audio"
	case "editor":
		return "Editor"
	case "notes":
		return "Notes"
	case "mail":
		return "Mail"
	case "calendar":
		return "Calendar"
	case "contacts":
		return "Contacts"
	case "browser":
		return "Browser"
	case "track":
		return "Tasks"
	}
	return "Files"
}

// device_today rebuilds Today's items from the index.
device_today :: proc(s: ^Store) {
	now := time.to_unix_seconds(time.now())
	today := local_day(now)
	device.day = today
	device.minute = local_minute(now)
	device.stamp = device_stamp()
	device.cache_q = ""
	clear(&s.items)
	midnight := today * 86400 - local_offset(now)

	tm := time.unix(now + local_offset(now), 0)
	y, mo, d := time.date(tm)
	wd := time.weekday(tm)
	if s.now_day != "" {
		delete(s.now_day)
	}
	s.now_day = fmt.aprintf("%v %d %v", wd, d, mo)
	_ = y
	s.now_min = device.minute
	s.now_unix = now

	for t, i in device.targets {
		// Events from today to the end of tomorrow: the agenda is today's,
		// and Next may be tomorrow morning.
		q := ic.Query{kinds = {.Event}, after = midnight, before = midnight + 2 * 86400}
		for r in query_one(t, q, {order = .Oldest, limit = 40, now = now}) {
			append(&s.items, item_from(r, i, today))
		}
		// People waiting on you: at most five per identity (product.md §7).
		q = ic.Query{kinds = {.Mail}, want = {.Waiting}}
		for r in query_one(t, q, {order = .Newest, limit = 5, now = now, snippets = true}) {
			it := item_from(r, i, today)
			it.who = strings.clone(first_person(r.who))
			it.detail = strings.clone(one_line(r.snippet))
			append(&s.items, it)
		}
		// Tasks: dated ones due by tonight, overdue first; then open issues.
		q = ic.Query{kinds = {.Task}, unwant = {.Done}, before = midnight + 86400}
		for r in query_one(t, q, {order = .Oldest, limit = 12, now = now}) {
			it := item_from(r, i, today)
			if r.app == "track" {
				it.day = 0
				it.dated = false
			} else {
				it.dated = true
				switch {
				case it.day < -1:
					it.detail = fmt.aprintf("Overdue by %d days", -it.day)
				case it.day == -1:
					it.detail = strings.clone("Overdue since yesterday")
				case:
					it.detail = fmt.aprintf("Due today %s", clock(it.at))
				}
			}
			append(&s.items, it)
		}
		// Recently changed files, documents and notes.
		q = ic.Query{kinds = {.Doc, .File, .Note}}
		for r in query_one(t, q, {order = .Newest, limit = 5, now = now}) {
			it := item_from(r, i, today)
			it.recent = true
			append(&s.items, it)
		}
	}
	device.n_base = len(s.items)

	// What the index says about itself, for the sync line.
	_, device.daemon = feed.daemon_pid(device.paths.index)
	device.updated = 0
	docs := 0
	for t in device.targets {
		docs += t.ix.ndocs
		path := fmt.tprintf("%s/%s/status", device.paths.index, t.ident.handle)
		if fi, err := os.stat(path, context.temp_allocator); err == nil {
			device.updated = max(device.updated, time.to_unix_seconds(fi.modification_time))
		}
	}
	if s.synced != "" {
		delete(s.synced)
	}
	switch {
	case len(device.targets) == 0:
		s.synced = strings.clone("Nothing indexed yet")
	case device.updated == 0:
		s.synced = fmt.aprintf("%d items indexed", docs)
	case:
		ago := now - device.updated
		when_ := ago < 90 ? "just now" : ago < 3600 ? fmt.tprintf("%d min ago", ago / 60) : fmt.tprintf("%d h ago", ago / 3600)
		s.synced = fmt.aprintf("Indexed %s · %d items", when_, docs)
	}
	s.daemon = device.daemon
}

one_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	t = strings.trim_prefix(t, "…")
	if nl := strings.index_byte(t, '\n'); nl >= 0 {
		t = t[:nl]
	}
	return t
}

// device_search answers the search box from the index. Results become
// items after Today's, so the rest of Home (rows, Enter, carry) works on
// them unchanged. Cached by (query, window identity) and index state.
device_search :: proc(s: ^Store, text: string, filter_ident: int) -> Results {
	if device.cache_q == text && device.cache_id == filter_ident && device.cache_q != "" {
		return device.cache_r
	}
	resize(&s.items, device.n_base)
	r: Results
	r.hits = make([dynamic]Hit)
	now := time.to_unix_seconds(time.now())
	today := local_day(now)
	typing := len(text) > 0 && text[len(text) - 1] != ' '
	q := ic.parse_query(text, now, typing)
	r.unknown = len(q.unknown) > 0 ? strings.clone(q.unknown[0]) : ""
	for k in q.kinds {
		append(&r.badges, fmt.aprintf("type: %s", ic.KIND_NAME[k]))
	}
	if .Unread in q.want {
		append(&r.badges, strings.clone("is: unread"))
	}
	if .Waiting in q.want {
		append(&r.badges, strings.clone("is: waiting"))
	}

	// in: picks identities among those in scope; an in: that names none of
	// them is reported, not widened.
	allowed := make([dynamic]int, context.temp_allocator)
	for t, i in device.targets {
		ok := len(q.in_words) == 0
		for w in q.in_words {
			if ident_matches(t.ident, w) {
				ok = true
			}
		}
		if ok {
			append(&allowed, i)
		}
	}
	if len(q.in_words) > 0 && len(allowed) == 0 && r.unknown == "" {
		r.unknown = fmt.aprintf("in:%s", q.in_words[0])
	}

	// Counts for the identities in scope but not shown (the chips: what
	// each would find); the shown ones are counted by the search itself.
	for i in allowed {
		if filter_ident < 0 || filter_ident == i {
			continue
		}
		st: ic.Stats
		qq := q
		out := make([dynamic]ic.Result, context.temp_allocator)
		ts := []ic.Target{device.targets[i]}
		ic.search_all(ts, &qq, {limit = 1, now = now, typing = typing}, &out, &st)
		if i < len(r.per_id) {
			r.per_id[i] = st.matched
		}
	}
	// The results themselves: one search across the identities shown, so
	// ranking is shared and each kind is capped (grouped, one kind can't
	// bury the rest).
	shown := make([dynamic]ic.Target, context.temp_allocator)
	shown_idx := make([dynamic]int, context.temp_allocator)
	for i in allowed {
		if filter_ident < 0 || filter_ident == i {
			append(&shown, device.targets[i])
			append(&shown_idx, i)
		}
	}
	out := make([dynamic]ic.Result, context.temp_allocator)
	st: ic.Stats
	qq := q
	ic.search_all(shown[:], &qq, {limit = 60, per_kind = 6, now = now, typing = typing, snippets = true}, &out, &st)
	for k in ic.Kind {
		r.per_kind[kind_from(k)] = st.per_kind[k]
	}
	for i, n in shown_idx {
		if i < len(r.per_id) {
			r.per_id[i] = st.per_target[n]
		}
	}
	r.scanned = st.searched
	for c in st.corrections {
		if r.correction == "" {
			r.correction = fmt.aprintf("%s → %s", c.from, c.to)
		}
	}
	r.took_us = st.took_us
	for res in out {
		ident := -1
		for t, i in device.targets {
			if t.ident.handle == res.handle {
				ident = i
			}
		}
		if ident < 0 {
			continue // cannot happen: every result names a searched identity
		}
		append(&r.hits, Hit{len(s.items), res.score})
		append(&s.items, item_from(res, ident, today))
	}
	// Grouped by kind, then by score (search_all returns score order).
	sort_hits(r.hits[:], s.items[:])
	if device.cache_q != "" {
		delete(device.cache_q)
	}
	device.cache_q = strings.clone(text)
	device.cache_id = filter_ident
	device.cache_r = r
	return r
}

ident_matches :: proc(i: ic.Identity, w: string) -> bool {
	lw := strings.to_lower(w, context.temp_allocator)
	return strings.has_prefix(strings.to_lower(i.name, context.temp_allocator), lw) || strings.has_prefix(i.handle, lw) || i.kind == lw
}

// device_open_item opens a result or a Today item where it lives, in its
// own identity.
device_open_item :: proc(h: ^Home, i: int) {
	it := h.store.items[i]
	if it.ident < 0 || it.ident >= len(device.idents) {
		return
	}
	x := device.idents[it.ident]
	r := ic.Result {
		handle = x.handle,
		kind   = kind_to_ic(it.kind),
		uri    = it.uri,
		app    = it.raw_app,
		key    = it.key,
	}
	o := feed.open_command(r, x, device.paths)
	if kit.launch(o.argv) {
		where_ := o.exact ? "" : tr(" (it opens near it: the app can't be told which item yet)")
		note(h, tfmt(tr("Opening “%s” in %s as %s%s"), it.title, it.app, x.name, where_))
	} else {
		note(h, tfmt(tr("Could not start %s"), o.argv[2] if len(o.argv) > 2 else "the app"))
	}
}

kind_to_ic :: proc(k: Kind) -> ic.Kind {
	switch k {
	case .Mail:
		return .Mail
	case .Event:
		return .Event
	case .Task:
		return .Task
	case .Doc:
		return .Doc
	case .File:
		return .File
	case .Note:
		return .Note
	case .Chat:
		return .Chat
	case .Person:
		return .Person
	case .Page:
		return .Page
	case .Issue:
		return .Issue
	}
	return .File
}

// device_create makes the thing quick-create asked for, as the chosen
// identity, through that application's own command. Returns what to say.
device_create :: proc(h: ^Home, kind: Create_Kind, ident: int, title: string) -> string {
	if ident < 0 || ident >= len(device.idents) {
		return tr("Choose who this is from first.")
	}
	x := device.idents[ident]
	env := fmt.tprintf("PALM_IDENTITY=%s", x.handle)
	t := title == "" ? tr("Untitled") : title
	run :: proc(argv: []string) -> bool {
		_, ok := kit.run(argv, context.temp_allocator)
		return ok
	}
	switch kind {
	case .Task:
		if run({"env", env, "track", "new", t}) {
			return tfmt(tr("Task “%s” created in %s"), t, x.name)
		}
	case .Event:
		now := time.to_unix_seconds(time.now())
		l := now + local_offset(now)
		start := (l / 3600 + 1) * 3600 // the next whole hour, local
		tm := time.unix(start, 0)
		yy, mm, dd := time.date(tm)
		hh, _, _ := time.clock(tm)
		if run({"env", env, "calendar", "add", t, "--identity", x.handle, "--date", tfmt("%04d-%02d-%02d", yy, int(mm), dd), "--time", tfmt("%02d:00", hh)}) {
			return tfmt(tr("Event “%s” at %02d:00 created in %s"), t, hh, x.name)
		}
	case .Note:
		if run({"env", env, "notes", "new", t}) {
			return tfmt(tr("Note “%s” created in %s"), t, x.name)
		}
	case .Doc:
		dir := fmt.tprintf("%s/%s", device.paths.drive, x.handle)
		os.make_directory_all(dir, os.perm_number(0o700))
		path := fmt.tprintf("%s/%s.md", dir, t)
		if !os.exists(path) {
			_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("# %s\n\n", t))
		}
		if kit.launch({"env", env, "docs", path}) {
			return tfmt(tr("Document “%s” created in %s's Drive"), t, x.name)
		}
	case .Mail:
		// Mail can't be told to start a draft from outside yet; open it as
		// the identity, which is where the From card will be right.
		args := []string{"env", env, "mail"}
		if x.mail_dir != "" {
			args = {"env", env, "mail", fmt.tprintf("--maildir=%s", x.mail_dir)}
		}
		if kit.launch(args) {
			return tfmt(tr("Mail opened as %s. Press C there to write “%s”."), x.name, t)
		}
	}
	return tfmt(tr("Could not create it in %s: the application did not answer."), x.name)
}

// device_launch starts an application as one identity, or (ident < 0)
// with no identity: the application then shows All identities if it can.
device_launch :: proc(app: string, ident: int) -> bool {
	if ident >= 0 && ident < len(device.idents) {
		return kit.launch({"env", tfmt("PALM_IDENTITY=%s", device.idents[ident].handle), app})
	}
	return kit.launch({app})
}

device_handle :: proc(ident: int) -> string {
	if ident >= 0 && ident < len(device.idents) {
		return device.idents[ident].handle
	}
	return ""
}
