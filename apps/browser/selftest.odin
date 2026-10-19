// `browser --selftest`: the parts that do not need an engine -- the protocol,
// the sync-ready bookmark model and its merge laws, history tombstones, the
// omnibox's reading of what was typed, import and export -- plus the chrome
// rendered offscreen, and, when an engine is installed, one real page.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import pb "pb"
import p "palmy:."

@(private = "file")
T :: struct {
	pass, fail: int,
}

@(private = "file")
check :: proc(t: ^T, cond: bool, what: string, args: ..any) {
	if cond {
		t.pass += 1
	} else {
		t.fail += 1
		fmt.eprintf("  FAIL ")
		fmt.eprintfln(what, ..args)
	}
}

selftest :: proc() -> int {
	t: T
	home := fmt.aprintf("/tmp/palm-browser-selftest-%d", os.get_pid()) // outlives the offscreen frames' temp resets
	os.set_env("PALM_BROWSER_HOME", home)
	defer os.remove_all(home)

	test_protocol(&t)
	test_positions(&t)
	test_merge(&t)
	test_tree_rules(&t)
	test_history(&t, home)
	test_input(&t)
	test_import_export(&t)
	test_chrome(&t)
	test_autofill(&t, home)
	if os.get_env("PALM_BROWSER_SELFTEST_ENGINE", context.temp_allocator) != "0" {
		test_engine(&t)
	}

	fmt.printfln("browser selftest: %d passed, %d failed", t.pass, t.fail)
	return t.fail == 0 ? 0 : 7
}

@(private = "file")
test_protocol :: proc(t: ^T) {
	// every request round-trips
	m := pb.req_create(7, 800, 600, 2, "https://example.com/")
	q, ok := pb.decode_request(pb.msg_bytes(&m))
	check(t, ok && q.op == .Create && q.view == 7 && q.w == 800 && q.h == 600 && q.scale == 2 && q.str == "https://example.com/", "create round-trips: %v", q)
	delete(m.b)
	m = pb.req_key(3, .Down, pb.MOD_CTRL | pb.MOD_SHIFT, 0x74, 't')
	q, ok = pb.decode_request(pb.msg_bytes(&m))
	check(t, ok && q.key == .Down && q.mods == 3 && q.keysym == 0x74 && q.codepoint == 't', "key round-trips")
	delete(m.b)
	m = pb.req_mouse(3, .Down, .Right, 2, pb.MOD_ALT, 12.5, 40)
	q, ok = pb.decode_request(pb.msg_bytes(&m))
	check(t, ok && q.mouse == .Down && q.button == .Right && q.clicks == 2 && q.x == 12.5 && q.y == 40, "mouse round-trips")
	delete(m.b)
	m = pb.req_dialog_reply(1, 99, true, "answer")
	q, ok = pb.decode_request(pb.msg_bytes(&m))
	check(t, ok && q.id == 99 && q.flag && q.str == "answer", "dialog reply round-trips")
	delete(m.b)
	m = pb.req_edit(1, .Insert, "pasted text")
	q, ok = pb.decode_request(pb.msg_bytes(&m))
	check(t, ok && q.edit == .Insert && q.str == "pasted text", "edit round-trips")
	delete(m.b)

	// and every event
	rects := []pb.Rect_I{{0, 0, 10, 10}, {5, 6, 7, 8}}
	m = pb.ev_frame(4, rects)
	raw := pb.msg_bytes(&m)
	e, eok := pb.decode_event(raw)
	check(t, eok && e.op == .Frame && e.view == 4 && len(e.rects) == 2 && e.rects[1] == rects[1], "frame round-trips")
	delete(e.rects)
	delete(m.b)
	m = pb.ev_download(2, 5, .Done, 100, 200, "https://x/y.zip", "/tmp/y.zip", "application/zip")
	raw = pb.msg_bytes(&m)
	e, eok = pb.decode_event(raw)
	check(t, eok && e.id == 5 && e.dl_state == .Done && e.received == 100 && e.total == 200 && e.path == "/tmp/y.zip" && e.mime == "application/zip", "download round-trips")
	delete(m.b)
	m = pb.ev_load(2, true, true, false)
	raw = pb.msg_bytes(&m)
	e, eok = pb.decode_event(raw)
	check(t, eok && e.loading && e.can_back && !e.can_forward, "load round-trips")
	delete(m.b)
	// a short message is refused, not read past its end
	m = pb.ev_frame(4, rects)
	raw = pb.msg_bytes(&m)
	_, eok = pb.decode_event(raw[:20])
	check(t, !eok, "a truncated frame is refused")
	delete(m.b)

	r, rok := pb.keysym_rune(0x010000e9)
	check(t, rok && r == 'é', "unicode keysyms decode")
	check(t, pb.rune_keysym('a') == 'a' && pb.rune_keysym('€') == 0x010020ac, "runes map to keysyms")
}

@(private = "file")
test_positions :: proc(t: ^T) {
	keys := make([dynamic]string, context.temp_allocator)
	// append 200 at the end, then insert 200 at the front, then 200 between
	last := ""
	for _ in 0 ..< 200 {
		k := key_between(last, "", context.temp_allocator)
		check(t, k > last, "append key %q > %q", k, last)
		append(&keys, k)
		last = k
	}
	first := keys[0]
	for _ in 0 ..< 200 {
		k := key_between("", first, context.temp_allocator)
		check(t, k < first && k != "", "prepend key %q < %q", k, first)
		first = k
	}
	a, b := "V", "W"
	for _ in 0 ..< 200 {
		k := key_between(a, b, context.temp_allocator)
		check(t, a < k && k < b, "between %q < %q < %q", a, k, b)
		b = k
	}
	check(t, len(b) < 64, "keys stay short enough: %d", len(b))
}

@(private = "file")
fresh :: proc(device: string) -> Bookmarks {
	b := Bookmarks{}
	b.clock.device = device
	return b
}

@(private = "file")
snapshot :: proc(b: ^Bookmarks) -> string {
	sb := strings.builder_make(context.temp_allocator)
	ids := make([dynamic]string, context.temp_allocator)
	for r in b.file.items {
		append(&ids, r.id)
	}
	// order-independent: sort by id
	for i in 1 ..< len(ids) {
		for j := i; j > 0 && ids[j] < ids[j - 1]; j -= 1 {
			ids[j], ids[j - 1] = ids[j - 1], ids[j]
		}
	}
	for id in ids {
		r := find(b, id)
		fmt.sbprintf(&sb, "%s|%s|%s|%s|%s|%v;", r.id, r.title, r.url, r.parent, r.position, r.deleted)
	}
	return strings.to_string(sb)
}

@(private = "file")
test_merge :: proc(t: ^T) {
	// two devices start from the same bookmark
	a := fresh("laptop")
	a.file.items = make([dynamic]Bookmark)
	b0 := Bookmark {
		id            = "11111111-1111-4111-8111-111111111111",
		kind          = "bookmark",
		parent        = ROOT_OTHER,
		position      = "V",
		title         = "Odin",
		url           = "https://odin-lang.org/",
		content_clock = "1760000000000-0000-laptop",
		place_clock   = "1760000000000-0000-laptop",
		life_clock    = "1760000000000-0000-laptop",
	}
	append(&a.file.items, b0)
	b := fresh("phone")
	merge(&b, a.file.items[:])
	observe(&a, "1760000000000-0000-laptop")
	observe(&b, "1760000000000-0000-laptop")

	// concurrently: the laptop renames it, the phone moves it to the bar
	bookmark_edit(&a, b0.id, "Odin language", b0.url)
	b.file.items[0].parent = ROOT_TOOLBAR
	b.file.items[0].position = "k"
	b.file.items[0].place_clock = tick(&b)

	// sync both ways, in both orders
	a1 := fresh("x");merge(&a1, a.file.items[:]);merge(&a1, b.file.items[:])
	b1 := fresh("y");merge(&b1, b.file.items[:]);merge(&b1, a.file.items[:])
	check(t, snapshot(&a1) == snapshot(&b1), "merge is commutative:\n %s\n %s", snapshot(&a1), snapshot(&b1))
	r := find(&a1, b0.id)
	check(t, r.title == "Odin language" && r.parent == ROOT_TOOLBAR, "both concurrent edits survive: %v %v", r.title, r.parent)
	before := snapshot(&a1)
	merge(&a1, b.file.items[:])
	merge(&a1, a.file.items[:])
	check(t, snapshot(&a1) == before, "merge is idempotent")

	// associativity: three replicas, merged in two groupings
	c := fresh("tablet")
	merge(&c, a.file.items[:])
	bookmark_delete(&c, b0.id)
	x := fresh("p");merge(&x, a.file.items[:]);merge(&x, b.file.items[:]);merge(&x, c.file.items[:])
	y := fresh("q");merge(&y, c.file.items[:]);merge(&y, b.file.items[:]);merge(&y, a.file.items[:])
	check(t, snapshot(&x) == snapshot(&y), "merge is associative / order-free over three replicas")
	check(t, find(&x, b0.id).deleted, "the later delete wins as a tombstone")
	check(t, find(&x, b0.id).title == "Odin language", "the tombstone keeps the record's content")

	// a delete followed by an undelete elsewhere
	d := fresh("desk")
	merge(&d, x.file.items[:])
	observe(&d, find(&x, b0.id).life_clock)
	rr := find(&d, b0.id)
	rr.deleted = false
	rr.life_clock = tick(&d)
	merge(&x, d.file.items[:])
	check(t, !find(&x, b0.id).deleted, "a later undelete beats the tombstone")

	// clocks
	h, ok := hlc_parse("1760000000123-00af-dev")
	check(t, ok && h.ms == 1760000000123 && h.counter == 0xaf && h.device == "dev", "clocks parse")
	e := fresh("e")
	e.clock.ms = now_ms() + 3600_000 // a clock an hour ahead (a skewed device)
	c1 := tick(&e)
	c2 := tick(&e)
	check(t, c2 > c1, "a clock never goes backwards, even ahead of the wall clock")
}

@(private = "file")
test_tree_rules :: proc(t: ^T) {
	b := fresh("t")
	b.file.items = make([dynamic]Bookmark)
	// roots
	b.path = ""
	bm := bookmarks_open("/nonexistent/bookmarks.json", "t")
	f := bookmark_add(&bm, ROOT_OTHER, "Folder", "", "folder")
	fid := f.id
	x := bookmark_add(&bm, fid, "Inside", "https://inside/")
	xid := x.id
	check(t, len(children(&bm, fid, context.temp_allocator)) == 1, "a bookmark lives in its folder")
	bookmark_delete(&bm, fid)
	check(t, len(all_visible(&bm, context.temp_allocator)) == 0, "deleting a folder hides what is in it")
	// a move into the folder made after the folder was deleted elsewhere:
	// rescued to Other bookmarks
	y := bookmark_add(&bm, ROOT_TOOLBAR, "Moved", "https://moved/")
	yr := find(&bm, y.id)
	yr.parent = fid
	yr.place_clock = tick(&bm)
	par, ok := effective_parent(&bm, yr)
	check(t, ok && par == ROOT_OTHER, "an orphan moved after the delete is rescued: %v %v", ok, par)
	// a cycle
	f1 := bookmark_add(&bm, ROOT_OTHER, "A", "", "folder")
	f1id := f1.id
	f2 := bookmark_add(&bm, f1id, "B", "", "folder")
	f2id := f2.id
	find(&bm, f1id).parent = f2id
	_, ok1 := effective_parent(&bm, find(&bm, f1id))
	check(t, ok1, "a cycle from two concurrent moves is still shown")
	check(t, !bookmark_move(&bm, f2id, f2id, ""), "a folder cannot move into itself")
	_ = xid
}

@(private = "file")
test_history :: proc(t: ^T, home: string) {
	os.make_directory_all(home)
	path := fmt.tprintf("%s/history.jsonl", home)
	h := history_open(path, "dev")
	history_visit(&h, "https://a.example/", "A")
	history_visit(&h, "https://a.example/", "A again") // folds into one
	history_visit(&h, "https://b.example/page", "B")
	history_visit(&h, "palm://settings", "Settings") // internal pages are not history
	check(t, len(h.visits) == 2, "visits fold and skip internal pages: %d", len(h.visits))
	h2 := history_open(path, "dev")
	check(t, len(h2.visits) == 2 && h2.visits[0].title == "A again", "history survives a reopen")
	history_forget_url(&h2, "https://a.example/")
	h3 := history_open(path, "dev")
	check(t, len(h3.visits) == 1, "a forget tombstone applies on reopen")
	history_forget_all(&h3)
	h4 := history_open(path, "dev")
	check(t, len(h4.visits) == 0, "clear-all applies on reopen")
	top := history_top(&h2, 4, context.temp_allocator)
	check(t, len(top) >= 1, "top sites are computed")
}

@(private = "file")
test_input :: proc(t: ^T) {
	eng := search_engine("duckduckgo")
	cases := [?]struct {
		in_, out: string,
		search:   bool,
	}{
		{"example.com", "https://example.com", false},
		{"https://odin-lang.org/docs", "https://odin-lang.org/docs", false},
		{"localhost:8080/x", "http://localhost:8080/x", false},
		{"192.168.1.1", "http://192.168.1.1", false},
		{"palm://settings", "palm://settings", false},
		{"odin language", "https://duckduckgo.com/?q=odin+language", true},
		{"what is 2+2?", "https://duckduckgo.com/?q=what+is+2%2B2%3F", true},
		{"odin", "https://duckduckgo.com/?q=odin", true},
		{"/etc/hosts", "file:///etc/hosts", false},
	}
	for c in cases {
		url, is_search := resolve_input(c.in_, eng, context.temp_allocator)
		check(t, url == c.out && is_search == c.search, "%q -> %q (search %v), want %q", c.in_, url, is_search, c.out)
	}
	check(t, url_host("https://www.example.com:8443/a?b") == "example.com", "hosts drop www and the port")
	k, ok := page_of_url("palm://bookmarks/")
	check(t, ok && k == .Bookmarks, "internal URLs resolve")
}

@(private = "file")
test_import_export :: proc(t: ^T) {
	b := bookmarks_open("/nonexistent/bookmarks.json", "t")
	text := `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
  <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
  <DL><p>
    <DT><A HREF="https://odin-lang.org/" ADD_DATE="1">Odin &amp; friends</A>
    <DT><H3>Docs</H3>
    <DL><p>
      <DT><A HREF="https://example.com/a">A</A>
      <DT><A HREF="javascript:alert(1)">bookmarklet</A>
    </DL><p>
  </DL><p>
  <DT><A HREF="https://other.example/">Other</A>
</DL>`
	n := import_html(&b, text)
	check(t, n == 3, "import adds the three real bookmarks and refuses javascript: (%d)", n)
	bar := children(&b, ROOT_TOOLBAR, context.temp_allocator)
	check(t, len(bar) == 2 && bar[0].title == "Odin & friends", "the toolbar folder maps to the bar, entities decoded")
	out := export_html(&b, context.temp_allocator)
	b2 := bookmarks_open("/nonexistent/bookmarks.json", "t2")
	n2 := import_html(&b2, out)
	check(t, n2 == 3, "what is exported imports again (%d)", n2)
	check(t, strings.contains(out, "Odin &amp; friends"), "export escapes")
}

@(private = "file")
test_chrome :: proc(t: ^T) {
	prof, _ := profile_open("selftest")
	profile_ensure(&prof)
	s := new(State)
	g_state = s
	state_init(s, prof)
	s.headless = true
	off := p.offscreen_create(1200, 760, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, false)
	b := bookmark_add(&s.bookmarks, ROOT_TOOLBAR, "Odin", "https://odin-lang.org/")
	_ = b
	new_tab(s, PAGE_URLS[.New_Tab])
	for k in Page_Kind {
		if k == .Web {continue}
		navigate(s, active_tab(s), PAGE_URLS[k])
		for _ in 0 ..< 3 {
			ui := p.offscreen_begin(off)
			frame(ui, s)
			p.offscreen_end(off)
		}
		check(t, active_tab(s).page == k, "palm page %v renders", k)
	}
	// the omnibox finds the bookmark
	focus_omnibox(s, false)
	edit_set(&s.omni, "odin")
	build_suggestions(s)
	found := false
	for sg in s.suggestions {
		if sg.kind == .Bookmark && sg.url == "https://odin-lang.org/" {found = true}
	}
	check(t, found, "the omnibox suggests a matching bookmark")
	check(t, len(s.suggestions) > 0 && s.suggestions[0].kind == .Search, "the first suggestion is the search")
	// tab bookkeeping
	n := len(s.tabs)
	new_tab(s, PAGE_URLS[.Settings])
	new_tab(s, PAGE_URLS[.History], 0)
	check(t, len(s.tabs) == n + 2 && active_tab(s).page == .History && s.active == 0, "tabs open where asked")
	close_tab(s, 0)
	check(t, len(s.tabs) == n + 1, "a tab closes")
	reopen_closed(s)
	check(t, len(s.tabs) == n + 2 && active_tab(s).page == .History, "a closed tab reopens")
}

@(private = "file")
test_engine :: proc(t: ^T) {
	for k in Engine_Kind {
		info := engine_info(k)
		if !info.available {
			fmt.eprintfln("  (skipping %s: %s)", engine_name(k), info.detail)
			continue
		}
		prof, _ := profile_open(fmt.tprintf("engine-%s", engine_name(k)))
		out := fmt.aprintf("%s/%s.png", browser_home(context.temp_allocator), engine_name(k))
		page := "data:text/html,<title>palm selftest</title><body style='background:%23123456'><h1>hello</h1>"
		res := shot(&prof, {out = out, url = page, width = 900, height = 600, wait = 0.3, engine = k, engine_set = true})
		check(t, res.error == "" && res.frames > 0, "%s renders a real page (%v)", engine_name(k), res.error)
		if res.error == "" {
			img, ok := p.load_image(out)
			if ok {
				// the page's background colour must appear in the content area
				found := false
				for px in img.px {
					if px & 0xffffff == 0x123456 {found = true;break}
				}
				check(t, found, "%s's pixels reach the window", engine_name(k))
				p.image_destroy(&img)
			}
		}
	}
}

// Autofill without an engine or a vault: the new messages, origins, the
// pairing code and file, the identity handle, and the controller -- the
// dropdown, its keys, the fill it queues, and save-or-update after a submit.
// autofill-test.sh runs the same with both engines and a real vault.
@(private = "file")
test_autofill :: proc(t: ^T, home: string) {
	// the messages
	m := pb.req_fill(3, "https://bank.example", "alice", "s3cret pass", "123456")
	q, ok := pb.decode_request(pb.msg_bytes(&m))
	check(t, ok && q.op == .Fill && q.view == 3 && q.str == "https://bank.example" && q.str2 == "alice" && q.str3 == "s3cret pass" && q.str4 == "123456", "fill round-trips: %v", q)
	check(t, len(m.b) == cap(m.b), "a fill message is built without reallocating (no stray copy of the password)")
	delete(m.b)
	m = pb.ev_field_focus(4, .Password, 10, 20.5, 300, 36, "https://bank.example")
	e, eok := pb.decode_event(pb.msg_bytes(&m))
	check(t, eok && e.op == .Field_Focus && e.field == .Password && e.x == 10 && e.y == 20.5 && e.fw == 300 && e.fh == 36 && e.str == "https://bank.example", "field focus round-trips")
	delete(m.b)
	m = pb.ev_form_submit(4, "https://bank.example", "alice", "new-pass", "old-pass")
	raw := make([]u8, len(pb.msg_bytes(&m)))
	copy(raw, pb.msg_bytes(&m))
	delete(m.b)
	e, eok = pb.decode_event(raw)
	check(t, eok && e.op == .Form_Submit && e.username == "alice" && e.password == "new-pass" && e.old_password == "old-pass", "form submit round-trips")
	// (event_free zeroes a submit's buffer before freeing it: see pb.event_free)
	pb.event_free(&e)
	m = pb.ev_fill_result(4, .Form_Action)
	e, eok = pb.decode_event(pb.msg_bytes(&m))
	check(t, eok && e.op == .Fill_Result && e.fill == .Form_Action, "fill result round-trips")
	delete(m.b)
	m = pb.ev_form_submit(4, "https://bank.example", "alice", "new-pass", "old-pass")
	_, eok = pb.decode_event(pb.msg_bytes(&m)[:30])
	check(t, !eok, "a truncated submit is refused")
	delete(m.b)

	// origins, as location.origin spells them (and the CEF host's twin)
	origins := [?][2]string {
		{"https://Bank.Example/login?x=1", "https://bank.example"},
		{"https://bank.example:443/", "https://bank.example"},
		{"https://bank.example:8443/a#b", "https://bank.example:8443"},
		{"http://bank.example:80/", "http://bank.example"},
		{"HTTP://bank.example", "http://bank.example"},
		{"https://user:pw@bank.example/", ""},
		{"file:///etc/passwd", ""},
		{"data:text/html,<form>", ""},
		{"javascript:alert(1)", ""},
		{"about:blank", ""},
		{"https://", ""},
	}
	for c in origins {
		check(t, pb.origin_of(c[0]) == c[1], "origin of %q is %q, not %q", c[0], c[1], pb.origin_of(c[0]))
	}

	// the pairing code, against the vault's definition (vector from Python's
	// hashlib for the key 00 01 .. 1f)
	key: [32]u8
	for i in 0 ..< 32 {key[i] = u8(i)}
	check(t, af_pair_code(key[:], context.temp_allocator) == "894 258", "the pairing code matches the vault's")
	pr := Af_Pairing{pair_id = "11111111-2222-3333-4444-555555555555", key = key}
	path := fmt.tprintf("%s/vault-pair.json", home)
	os.make_directory_all(home)
	check(t, af_pair_save(path, pr), "the pairing is written")
	back, bok := af_pair_load(path)
	check(t, bok && back.pair_id == pr.pair_id && back.key == key, "the pairing reads back")
	st: linux.Stat
	if linux.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .NONE {
		check(t, transmute(u32)st.mode & 0o077 == 0, "the pairing file is 0600 (%o)", transmute(u32)st.mode & 0o777)
	}

	// the identity handle: from identities.json when it names the profile
	cfg := fmt.tprintf("%s/config", home)
	os.make_directory_all(fmt.tprintf("%s/palmframe", cfg))
	_ = os.write_entire_file(fmt.tprintf("%s/palmframe/identities.json", cfg), transmute([]u8)string(`[{"handle": "alice-w", "name": "work", "color": "#d97706"}, {"handle": "alice"}]`))
	saved := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", cfg)
	check(t, identity_handle("work", context.temp_allocator) == "alice-w", "a profile named for an identity uses its handle")
	check(t, identity_handle("alice", context.temp_allocator) == "alice", "a profile named by its handle keeps it")
	check(t, identity_handle("personal", context.temp_allocator) == "personal", "an unknown profile is its own handle")
	os.set_env("XDG_CONFIG_HOME", saved)

	// the controller, with a worker that is never started: jobs queue up
	prof, _ := profile_open("af-selftest")
	profile_ensure(&prof)
	s := new(State)
	g_state = s
	state_init(s, prof)
	s.headless = true
	w := new(Af_Worker)
	s.af.worker = w
	s.af.identity = strings.clone("alice")
	s.af.sel = -1
	tab := new_tab(s, "https://bank.example/login")
	tab.url = strings.clone("https://bank.example/login")
	tab.has_view = true
	focus := proc(s: ^State, view: int, kind: pb.Field_Kind, origin: string) {
		m := pb.ev_field_focus(view, kind, 40, 120, 280, 36, origin)
		raw := make([]u8, len(pb.msg_bytes(&m)))
		copy(raw, pb.msg_bytes(&m))
		delete(m.b)
		ev, _ := pb.decode_event(raw)
		handle_event(s, &ev)
		pb.event_free(&ev)
	}
	jobs := proc(w: ^Af_Worker) -> int {return len(w.jobs)}
	focus(s, tab.id, .Username, "https://bank.example")
	check(t, !s.af.open && s.af.armed, "a field the page focused by itself arms the dropdown, it does not open it")
	check(t, jobs(w) == 1 && w.jobs[0].kind == .Query && w.jobs[0].origin == "https://bank.example" && w.jobs[0].identity == "alice", "focus asks the vault for this origin and identity")
	af_input(s)
	focus(s, tab.id, .Password, "https://bank.example")
	check(t, s.af.open, "a field the person focused opens the dropdown")
	// the vault's answer
	s.af.vault = .Unlocked
	delete(s.af.cand_origin)
	s.af.cand_origin = strings.clone("https://bank.example")
	append(&s.af.candidates, Af_Candidate{id = strings.clone("id-1"), title = strings.clone("Bank"), username = strings.clone("alice"), exact = true})
	append(&s.af.candidates, Af_Candidate{id = strings.clone("id-2"), title = strings.clone("Bank (joint)"), username = strings.clone("alice+bob"), exact = true})
	rows := af_rows(s)
	check(t, len(rows) == 3 && rows[0].action == .Fill && rows[2].action == .Open_Vault, "two logins and Open Passwords")
	kept := af_keys(s, {{sym = p.KEY_DOWN}, {sym = p.KEY_DOWN}, {sym = 'x'}})
	check(t, s.af.sel == 1 && len(kept) == 1 && kept[0].sym == 'x', "Down moves the selection; other keys go to the page")
	n := jobs(w)
	af_keys(s, {{sym = p.KEY_RETURN}})
	check(t, jobs(w) == n + 1 && w.jobs[n].kind == .Fill && w.jobs[n].id == "id-2" && w.jobs[n].origin == "https://bank.example", "Enter asks the vault to fill the selected login, for this origin")
	check(t, s.af.busy, "the dropdown waits for the vault")
	s.af.busy = false
	kept = af_keys(s, {{sym = p.KEY_ESCAPE}})
	check(t, !s.af.open && len(kept) == 0, "Escape closes the dropdown and stays with the chrome")
	kept = af_keys(s, {{sym = p.KEY_RETURN}})
	check(t, len(kept) == 1, "with the dropdown closed, Enter goes to the page")
	// a field report from another origin than the dropdown's must not reuse
	// its candidates
	focus(s, tab.id, .Username, "https://bank.example.evil.example")
	any_fill := false
	for r in af_rows(s) {if r.action == .Fill {any_fill = true}}
	check(t, !any_fill, "candidates of one origin are never offered on another")
	// the URL moving closes the dropdown
	s.af.open = true
	ue := pb.Event{op = .Url, view = tab.id, str = "https://elsewhere.example/"}
	handle_event(s, &ue)
	check(t, !s.af.open, "navigating closes the dropdown")
	// locked, unpaired, absent
	s.af.vault = .Locked
	rows = af_rows(s)
	check(t, len(rows) == 1 && rows[0].action == .Unlock, "locked: only \"Locked — unlock\"")
	s.af.vault = .Unpaired
	rows = af_rows(s)
	check(t, len(rows) == 1 && rows[0].action == .Pair, "unpaired: only \"Connect to Passwords\"")
	s.af.vault = .Not_Running
	rows = af_rows(s)
	check(t, len(rows) == 1 && rows[0].action == .Open_Vault, "no vault: only \"Open Passwords\"")

	// submits: the filled password is recognised without being kept
	s.af.vault = .Unlocked
	append(&s.af.filled, Af_Filled{view = tab.id, item = strings.clone("id-1"), origin = strings.clone("https://bank.example"), mac = af_mac(s, "filled-pass")})
	submit := proc(s: ^State, view: int, user, pass, old: string) {
		m := pb.ev_form_submit(view, "https://bank.example", user, pass, old)
		raw := make([]u8, len(pb.msg_bytes(&m)))
		copy(raw, pb.msg_bytes(&m))
		delete(m.b)
		ev, _ := pb.decode_event(raw)
		handle_event(s, &ev)
		pb.event_free(&ev)
	}
	n = jobs(w)
	submit(s, tab.id, "alice", "filled-pass", "")
	check(t, !s.af.bar.active && jobs(w) == n, "submitting the password just filled offers nothing")
	submit(s, tab.id, "", "brand-new-pass", "filled-pass")
	check(t, s.af.bar.active && s.af.bar.item == "id-1" && jobs(w) == n + 1 && w.jobs[n].kind == .Query, "a change-password form names the login that was filled")
	res := Af_Result{kind = .Query, seq = s.af.bar.seq, state = .Unlocked}
	append(&res.candidates, Af_Candidate{id = strings.clone("id-1"), title = strings.clone("Bank"), username = strings.clone("alice"), exact = true})
	bar_decide(s, &res)
	check(t, s.af.bar.update && s.af.bar.username == "alice" && !s.af.bar.waiting, "... and the bar offers to update it")
	bar_accept(s)
	last := w.jobs[len(w.jobs) - 1]
	check(t, last.kind == .Save && last.id == "id-1" && last.password == "brand-new-pass" && last.identity == "alice", "accepting sends the update to the vault")
	check(t, !strings.contains(string(transmute([]u8)s.af.bar.password), "brand"), "the bar wiped its copy of the password")
	bar_close(s)
	submit(s, tab.id, "carol", "carol-pass", "")
	res2 := Af_Result{kind = .Query, seq = s.af.bar.seq, state = .Unlocked}
	append(&res2.candidates, Af_Candidate{id = strings.clone("id-1"), title = strings.clone("Bank"), username = strings.clone("alice"), exact = true})
	bar_decide(s, &res2)
	check(t, s.af.bar.active && !s.af.bar.update, "a username the vault lacks: save, not update")
	bar_close(s)
	candidates_free(&res.candidates)
	candidates_free(&res2.candidates)

	// the dropdown and the bar draw
	off := p.offscreen_create(1100, 700, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, false)
	submit(s, tab.id, "dave", "dave-pass", "")
	s.af.bar.waiting = false
	s.af.bar.seq = 0
	s.af.open = true
	delete(s.af.origin)
	s.af.origin = strings.clone("https://bank.example")
	s.af.view = tab.id
	tab.page = .Web
	s.page_rect = {0, 90, 1100, 600}
	for _ in 0 ..< 3 {
		ui := p.offscreen_begin(off)
		frame(ui, s)
		p.offscreen_end(off)
	}
	check(t, s.af.drop_rect.w >= 300, "the dropdown is laid out (%v)", s.af.drop_rect)
	bar_close(s)
	for &j in w.jobs {job_free(&j)}
	delete(w.jobs)
	s.af.worker = nil
	free(w)
}
