// `index --selftest`: the engine, the query language, updates and merges,
// extraction, every source end to end on a scratch home, and the isolation
// rule — a search scoped to one identity never opens another's files.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import ic "core"
import feed "feed"

@(private = "file")
failures := 0
@(private = "file")
passes := 0

check :: proc(ok: bool, what: string, args: ..any) {
	msg := len(args) > 0 ? fmt.tprintf(what, ..args) : what
	if ok {
		passes += 1
		fmt.printfln("ok    %s", msg)
	} else {
		failures += 1
		fmt.eprintfln("FAIL  %s", msg)
	}
}

run_selftest :: proc() -> int {
	tokenizer_checks()
	query_checks()
	root := fmt.aprintf("/tmp/palm-index-selftest-%d", linux.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	engine_checks(fmt.tprintf("%s/idx", root))
	mime_checks()
	office_checks()
	sources_checks(fmt.tprintf("%s/home", root))
	rebuild_checks(fmt.tprintf("%s/rebuild", root))
	fmt.printfln("%d passed, %d failed", passes, failures)
	return failures == 0 ? 0 : 1
}

terms_of :: proc(s: string) -> string {
	t := ic.tokenizer(s)
	b := strings.builder_make(context.temp_allocator)
	for term in ic.next_token(&t) {
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, term)
	}
	return strings.to_string(b)
}

tokenizer_checks :: proc() {
	check(terms_of("Lunch with Théo") == "lunch with theo", "accents fold: Théo is theo")
	check(terms_of("Straße ÆON") == "strasse aeon", "ß and Æ fold to two letters")
	check(terms_of("priya.shah@northwind.coop") == "priya shah northwind coop", "an address is its parts")
	check(terms_of("会議の資料") == "会 議 の 資 料", "CJK is indexed one character per term")
	check(terms_of(strings.repeat("x", 60, context.temp_allocator)) == "", "terms over 40 bytes are dropped")
	check(terms_of("Q4-roadmap v0.4") == "q4 roadmap v0 4", "punctuation separates")
}

query_checks :: proc() {
	now := i64(1792396800) // 2026-10-19
	q := ic.parse_query("roadmap in:work type:mail is:unread from:priya", now)
	check(len(q.terms) == 2 && q.terms[1].field == .Who && q.terms[1].text == "priya", "from: is a people-only term")
	check(len(q.in_words) == 1 && q.in_words[0] == "work" && .Mail in q.kinds && .Unread in q.want, "in: type: is: parse")
	q = ic.parse_query("budget foo:bar 10:30 https://x.org/a", now)
	check(len(q.unknown) == 1 && q.unknown[0] == "foo:bar", "an unknown operator is reported; a time and a URL are words")
	q = ic.parse_query("roadm", now, typing = true)
	check(len(q.terms) == 1 && q.terms[0].prefix, "while typing, the last word is a prefix")
	q = ic.parse_query("roadm ", now, typing = true)
	check(!q.terms[0].prefix, "a word followed by a space is finished")
	q = ic.parse_query("\"offline drafts\" -spam", now)
	check(len(q.phrases) == 1 && len(q.phrases[0]) == 2 && len(q.not) == 1, "phrases and exclusions")
	q = ic.parse_query("after:7d before:2026-10-01 type:meetings", now)
	check(q.after == now - now % 86400 - 7 * 86400 && q.before == 1790812800 && .Event in q.kinds, "relative and absolute dates, kind synonyms")
	q = ic.parse_query("type:wat", now)
	check(len(q.unknown) == 1, "an unknown type is reported")
}

DAY :: 86400

engine_checks :: proc(root: string) {
	now := i64(1792396800) + 9 * 3600
	docs_a := []ic.Doc {
		{key = "mail:1", kind = .Mail, flags = {.Unread, .Waiting}, time = now - 3600, title = "Q4 roadmap: need your sign-off", who = "Priya Shah priya@northwind.coop", body = "I've folded in the Lumen numbers. Offline drafts ship in Q4.", detail = "Inbox"},
		{key = "mail:2", kind = .Mail, time = now - 4 * DAY, title = "Lunch on Friday", who = "Jonas Weber", body = "The roadmap review moved, so lunch works.", detail = "Inbox"},
		{key = "file:Planning/Q4 Roadmap.xlsx", kind = .Doc, time = now - 2 * DAY, title = "Q4 Roadmap.xlsx", body = "quarter goals offline sync", detail = "Planning"},
		{key = "event:1", kind = .Event, time = now + 3600, dur = 45, title = "Weekly design review", who = "Priya Shah", detail = "Room 2"},
		{key = "person:1", kind = .Person, title = "Priya Shah", who = "Priya Shah priya@northwind.coop", body = "Head of product", detail = "Northwind"},
		{key = "note:1", kind = .Note, time = now - 30 * DAY, title = "Ideas", body = "an old note about the roadmap and about bicycles"},
	}
	docs_b := []ic.Doc {
		{key = "mail:1", kind = .Mail, time = now - DAY, title = "Flat viewing on Saturday?", who = "Ines Roux", body = "The agency can do 11:00. Bring the roadmap? (joke)", detail = "Inbox"},
		{key = "file:passport.pdf", kind = .File, time = now - 12 * DAY, title = "Passport scan.pdf", detail = "ID"},
	}
	for pair in ([2]struct {
			h:    string,
			docs: []ic.Doc,
		}{{"northwind", docs_a}, {"personal", docs_b}}) {
		w, err := ic.writer_open(root, pair.h)
		check(w != nil, "a writer opens for %s (%s)", pair.h, err)
		if w == nil {
			return
		}
		for d in pair.docs {
			ic.writer_put(w, d)
		}
		check(ic.writer_flush(w), "the first flush writes %s's segment", pair.h)
		w2, err2 := ic.writer_open(root, pair.h)
		check(w2 == nil && err2 != "", "a second writer on the same identity is refused")
		ic.writer_close(w)
	}

	open :: proc(root: string, hs: ..string) -> [dynamic]ic.Target {
		out := make([dynamic]ic.Target, context.temp_allocator)
		for h in hs {
			ix, ok := ic.index_open(root, h)
			if ok {
				append(&out, ic.Target{ident = {handle = h, name = h}, ix = ix})
			}
		}
		return out
	}
	run :: proc(ts: []ic.Target, text: string, now: i64, opt := ic.Options{}) -> ([dynamic]ic.Result, ic.Stats) {
		q := ic.parse_query(text, now, opt.typing)
		out := make([dynamic]ic.Result, context.temp_allocator)
		st: ic.Stats
		o := opt
		o.now = now
		o.snippets = true
		ic.search_all(ts, &q, o, &out, &st)
		return out, st
	}
	ts := open(root, "northwind", "personal")
	defer for t in ts {
		ic.index_close(t.ix)
	}
	r, st := run(ts[:], "roadmap", now)
	check(len(r) == 5, "roadmap matches five things across two identities (%d)", len(r))
	labelled := true
	both := map[string]bool{}
	defer delete(both)
	for x in r {
		if x.handle == "" {
			labelled = false
		}
		both[x.handle] = true
	}
	check(labelled && len(both) == 2, "every result carries its identity, and both identities answered")
	check(r[0].key == "mail:1" || r[0].kind == .Doc, "a title hit ranks first (%s)", r[0].title)
	title_rank, body_rank := -1, -1
	for x, i in r {
		if x.key == "file:Planning/Q4 Roadmap.xlsx" {
			title_rank = i
		}
		if x.key == "note:1" {
			body_rank = i
		}
	}
	check(title_rank >= 0 && body_rank >= 0 && title_rank < body_rank, "a title hit beats an old body hit")
	check(st.searched == 8, "searched counts every live document (%d)", st.searched)

	r, _ = run(ts[:1], "roadmap", now)
	only := true
	for x in r {
		if x.handle != "northwind" {
			only = false
		}
	}
	check(only && len(r) == 4, "one identity's index answers only for itself")

	r, _ = run(ts[:], "roadm", now, {typing = true})
	check(len(r) == 5, "as-you-type: roadm finds the roadmaps")
	r, _ = run(ts[:], "r", now, {typing = true})
	check(len(r) > 0, "as-you-type: one letter already answers")
	r, st = run(ts[:], "roadmpa", now)
	check(len(r) == 5 && len(st.corrections) > 0 && st.corrections[0].to == "roadmap", "typo tolerance: roadmpa is roadmap, and says so")
	r, _ = run(ts[:], "\"offline drafts\"", now)
	check(len(r) == 1 && r[0].key == "mail:1", "an exact phrase is required")
	r, _ = run(ts[:], "\"drafts offline\"", now)
	check(len(r) == 0, "the same words in the wrong order are not the phrase")
	r, _ = run(ts[:], "\"offline dra", now, {typing = true})
	check(len(r) == 1, "a phrase still being typed matches its prefix")
	r, _ = run(ts[:], "roadmap -lunch", now)
	check(len(r) == 4, "-word excludes")
	r, _ = run(ts[:], "roadmap type:mail", now)
	check(len(r) == 3, "type:mail (%d)", len(r))
	r, _ = run(ts[:], "is:unread", now)
	check(len(r) == 1 && r[0].key == "mail:1", "is:unread alone lists unread")
	r, _ = run(ts[:], "is:waiting", now)
	check(len(r) == 1, "is:waiting")
	r, _ = run(ts[:], "from:priya", now)
	kinds_ok := len(r) == 3
	for x in r {
		if x.kind == .Doc {
			kinds_ok = false
		}
	}
	check(kinds_ok, "from:priya looks in the people field only (%d)", len(r))
	r, _ = run(ts[:], "roadmap after:3d", now)
	check(len(r) == 3, "after:3d (%d)", len(r))
	r, _ = run(ts[:], "roadmap before:3d", now)
	check(len(r) == 2, "before:3d (%d)", len(r))
	r, _ = run(ts[:], "roadmap", now, {per_kind = 1})
	per := map[ic.Kind]int{}
	defer delete(per)
	for x in r {
		per[x.kind] += 1
	}
	check(per[.Mail] == 1 && per[.Doc] == 1, "per_kind caps each kind, so one can't bury the others")
	r, _ = run(ts[:], "type:event after:today", now, {order = .Oldest})
	check(len(r) == 1 && r[0].title == "Weekly design review", "listing upcoming events by time")
	r, _ = run(ts[:], "lumen", now)
	check(len(r) == 1 && strings.contains(r[0].snippet, "Lumen") && len(r[0].marks) == 1, "a snippet comes with its highlight")
	if len(r) == 1 && len(r[0].marks) == 1 {
		m := r[0].marks[0]
		check(r[0].snippet[m[0]:m[1]] == "Lumen", "the highlight covers the word")
	}
	r, _ = run(ts[:], "theo", now)
	r2, _ := run(ts[:], "priya shah", now)
	check(len(r2) == 3, "two words must both match (%d)", len(r2))

	// Updates: replace, add, remove, and merge, then search again.
	w, _ := ic.writer_open(root, "northwind")
	d := docs_a[1]
	d.title = "Lunch moved to Thursday"
	ic.writer_put(w, d)
	ic.writer_put(w, ic.Doc{key = "mail:9", kind = .Mail, flags = {.Unread}, time = now, title = "Zebra crossing", body = "a new mail"})
	ic.writer_remove(w, "note:1")
	check(ic.writer_flush(w), "an update flushes")
	ic.index_refresh(ts[0].ix)
	r, _ = run(ts[:1], "zebra", now)
	check(len(r) == 1, "a new document is found after its flush")
	r, _ = run(ts[:1], "lunch", now)
	check(len(r) == 1 && r[0].title == "Lunch moved to Thursday", "a replaced document appears once, as its new self")
	r, _ = run(ts[:1], "bicycles", now)
	check(len(r) == 0, "a removed document is gone")
	for i in 0 ..< 10 {
		ic.writer_put(w, ic.Doc{key = fmt.tprintf("mail:x%d", i), kind = .Mail, time = now, title = fmt.tprintf("batch %d", i)})
		ic.writer_flush(w)
	}
	segs := len(w.ix.segs)
	ic.writer_compact(w)
	check(len(w.ix.segs) < segs && len(w.ix.segs) >= 1, "compaction folds %d segments into %d", segs, len(w.ix.segs))
	ic.index_refresh(ts[0].ix)
	r, _ = run(ts[:1], "batch", now, {limit = 50})
	r3, _ := run(ts[:1], "lunch", now)
	check(len(r) == 10 && len(r3) == 1, "after merging, everything is still found exactly once")
	sig, found := ic.writer_sig(w, "mail:2")
	check(found && sig == d.sig, "the writer knows each key's signature after a merge")
	ic.writer_close(w)

	// Isolation inside the library: opening one identity reads only its files.
	paths := make([dynamic]string)
	ic.opened_paths = &paths
	ids, targets := open_targets(root, "personal")
	q := ic.parse_query("roadmap", now)
	out := make([dynamic]ic.Result, context.temp_allocator)
	st2: ic.Stats
	ic.search_all(targets[:], &q, {now = now}, &out, &st2)
	ic.opened_paths = nil
	leaked := false
	for p in paths {
		if strings.contains(p, "/northwind") {
			leaked = true
		}
	}
	check(len(paths) > 0 && !leaked, "a search scoped to personal opened %d files, none of northwind's", len(paths))
	check(len(ids) == 1 && len(out) == 1 && out[0].handle == "personal", "and found only personal's")
	for t in targets {
		ic.index_close(t.ix)
	}
}

// A small multipart message: QP plain part, HTML alternative, an encoded
// subject, a base64 attachment.
SAMPLE_MAIL :: "From: =?utf-8?Q?Th=C3=A9o_Martin?= <theo@example.org>\r\n" +
	"To: Camille <camille@palm.test>\r\n" +
	"Subject: =?utf-8?B?Q2Fmw6kgZGVtYWlu?= =?utf-8?Q?_matin?=\r\n" +
	"Date: Mon, 19 Oct 2026 09:14:00 +0200\r\n" +
	"Message-ID: <abc@example.org>\r\n" +
	"MIME-Version: 1.0\r\n" +
	"Content-Type: multipart/mixed; boundary=\"XX\"\r\n" +
	"\r\n" +
	"--XX\r\n" +
	"Content-Type: multipart/alternative; boundary=\"YY\"\r\n" +
	"\r\n" +
	"--YY\r\n" +
	"Content-Type: text/plain; charset=utf-8\r\n" +
	"Content-Transfer-Encoding: quoted-printable\r\n" +
	"\r\n" +
	"On se retrouve au caf=C3=A9 =\r\nde la gare?\r\n" +
	"> quoted history that should not be indexed\r\n" +
	"--YY\r\n" +
	"Content-Type: text/html\r\n" +
	"\r\n" +
	"<p>On se retrouve</p>\r\n" +
	"--YY--\r\n" +
	"--XX\r\n" +
	"Content-Type: text/plain; name=\"menu.txt\"\r\n" +
	"Content-Disposition: attachment; filename=\"menu.txt\"\r\n" +
	"Content-Transfer-Encoding: base64\r\n" +
	"\r\n" +
	"Y3JvaXNzYW50cyBldCBjYWbDqQ==\r\n" +
	"--XX--\r\n"

mime_checks :: proc() {
	m := feed.parse_message(SAMPLE_MAIL)
	check(m.subject == "Café demain matin", "RFC 2047 subject, B and Q, joined (%q)", m.subject)
	check(m.from_addr == "theo@example.org" && strings.has_prefix(m.from, "Théo Martin"), "From name and address (%q)", m.from)
	check(strings.contains(m.body, "café de la gare"), "quoted-printable with a soft break, as UTF-8")
	check(!strings.contains(m.body, "quoted history"), "quoted history is not indexed twice")
	check(len(m.attachments) == 1 && m.attachments[0] == "menu.txt", "attachment names")
	check(strings.contains(m.body, "croissants"), "a small text attachment is indexed")
	check(m.date == 1792394040, "Date with its offset (%d)", m.date)
	check(!m.machine, "a person is not a machine")
	m2 := feed.parse_message("From: GitHub <noreply@github.com>\r\nSubject: x\r\n\r\nbody")
	check(m2.machine, "noreply@ is a machine")
	m3 := feed.parse_message("From: a@b.c\r\nList-Id: <x.lists>\r\nContent-Type: text/html\r\n\r\n<html><style>p{}</style><p>Hello &amp; welcome</p></html>")
	check(m3.machine && strings.contains(m3.body, "Hello & welcome") && !strings.contains(m3.body, "p{}"), "a list is a machine; HTML is text without styles")
	check(feed.to_utf8("caf\xe9", "iso-8859-1") == "café", "Latin-1 converts")
}

// zip_stored builds a zip of stored entries, for the office test.
zip_stored :: proc(files: []struct {
		name: string,
		data: string,
	}) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	u16le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8))}
	u32le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	offs := make([dynamic]int, context.temp_allocator)
	for f in files {
		append(&offs, len(b))
		u32le(&b, 0x04034b50)
		u16le(&b, 10);u16le(&b, 0);u16le(&b, 0);u16le(&b, 0);u16le(&b, 0)
		u32le(&b, 0);u32le(&b, len(f.data));u32le(&b, len(f.data))
		u16le(&b, len(f.name));u16le(&b, 0)
		append(&b, ..transmute([]u8)f.name)
		append(&b, ..transmute([]u8)f.data)
	}
	cd := len(b)
	for f, i in files {
		u32le(&b, 0x02014b50)
		u16le(&b, 20);u16le(&b, 10);u16le(&b, 0);u16le(&b, 0);u16le(&b, 0);u16le(&b, 0)
		u32le(&b, 0);u32le(&b, len(f.data));u32le(&b, len(f.data))
		u16le(&b, len(f.name));u16le(&b, 0);u16le(&b, 0);u16le(&b, 0);u16le(&b, 0)
		u32le(&b, 0);u32le(&b, offs[i])
		append(&b, ..transmute([]u8)f.name)
	}
	end := len(b)
	u32le(&b, 0x06054b50)
	u16le(&b, 0);u16le(&b, 0);u16le(&b, len(files));u16le(&b, len(files))
	u32le(&b, end - cd);u32le(&b, cd);u16le(&b, 0)
	return b[:]
}

office_checks :: proc() {
	docx := zip_stored({{"[Content_Types].xml", "<Types/>"}, {"word/document.xml", "<w:document><w:body><w:p><w:r><w:t>Lumen </w:t></w:r><w:r><w:t>contract v7</w:t></w:r></w:p><w:p><w:r><w:t>Clause 9 &amp; annex</w:t></w:r></w:p></w:body></w:document>"}})
	t, ok := feed.office_text(docx, .Docx)
	check(ok && strings.contains(t, "Lumen contract v7") && strings.contains(t, "Clause 9 & annex"), "docx text, runs joined, entities decoded")
	pptx := zip_stored({{"ppt/slides/slide10.xml", "<p:sld><a:p><a:t>Ten</a:t></a:p></p:sld>"}, {"ppt/slides/slide2.xml", "<p:sld><a:p><a:t>Two</a:t></a:p></p:sld>"}})
	t, ok = feed.office_text(pptx, .Pptx)
	check(ok && strings.index(t, "Two") < strings.index(t, "Ten"), "pptx slides in slide order")
	odt := zip_stored({{"content.xml", "<office:document-content><text:h>Budget</text:h><text:p>for the flat</text:p></office:document-content>"}})
	t, ok = feed.office_text(odt, .Odf)
	check(ok && strings.contains(t, "Budget") && strings.contains(t, "for the flat"), "odt text")
	_, ok = feed.office_text(transmute([]u8)string("not a zip"), .Docx)
	check(!ok, "a broken file is refused, not crashed on")
}

write :: proc(path, text: string) {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')], os.perm_number(0o700))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

mail_file :: proc(from, to, subject, mid, body: string, extra := "") -> string {
	return fmt.tprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s>\r\n%s\r\n%s\r\n", from, to, subject, "Mon, 19 Oct 2026 08:00:00 +0000", mid, extra, body)
}

sources_checks :: proc(home: string) {
	p := feed.Paths {
		index   = fmt.aprintf("%s/index", home),
		mail    = fmt.aprintf("%s/mail", home),
		drive   = fmt.aprintf("%s/Drive", home),
		notes   = fmt.aprintf("%s/Notes", home),
		dav     = fmt.aprintf("%s/dav", home),
		browser = fmt.aprintf("%s/browser", home),
		track   = fmt.aprintf("%s/track", home),
	}
	write(fmt.tprintf("%s/palmy.conf", p.mail), "[identity]\nid = 1\nhandle = camille\nname = Personal\nkind = personal\ncolor = teal\naddress = camille@palm.test\npath = camille@palm.test\n\n[identity]\nid = 2\nhandle = northwind\nname = Northwind\nkind = work\ncolor = blue\naddress = camille@northwind.coop\npath = camille@northwind.coop\n")
	mb := fmt.tprintf("%s/camille@palm.test", p.mail)
	// Fixed recent dates so "waiting" (14 days) holds whenever this runs.
	now := time.to_unix_seconds(time.now())
	date := fmt.tprintf("%d", now)
	_ = date
	write(fmt.tprintf("%s/cur/100.M1P1.host:2,", mb), strings.concatenate({"Date-Unix: x\r\n", mail_file("Ines Roux <ines@example.org>", "camille@palm.test", "Flat viewing on Saturday?", "m1@x", "The agency can do 11:00.")}, context.temp_allocator))
	write(fmt.tprintf("%s/cur/101.M1P1.host:2,S", mb), mail_file("Newsletter <news@shop.example>", "camille@palm.test", "Autumn sale", "m2@x", "Everything must go", "List-Id: <sale.shop>\r\n"))
	write(fmt.tprintf("%s/new/102.M1P1.host", mb), mail_file("Théo <theo@example.org>", "camille@palm.test", "Café demain?", "m3@x", "On se retrouve au café de la gare."))
	nb := fmt.tprintf("%s/camille@northwind.coop", p.mail)
	write(fmt.tprintf("%s/cur/200.M1P1.host:2,S", nb), mail_file("Priya Shah <priya@northwind.coop>", "camille@northwind.coop", "Q4 roadmap: sign-off", "n1@x", "Need your sign-off on the roadmap by Wednesday."))
	write(fmt.tprintf("%s/Drive/camille/Home/Apartment budget.md", home), "# Apartment budget\n\nRent, deposit and the moving van.\n")
	write(fmt.tprintf("%s/Drive/camille/.palm-drive-tmp123", home), "temporary")
	write(fmt.tprintf("%s/Drive/northwind/Planning/Q4 Roadmap.csv", home), "goal,owner\noffline drafts,priya\n")
	write(fmt.tprintf("%s/Notes/camille/Travel/Lisbon.md", home), "---\nid: n-1\ntags: [travel]\n---\n# Lisbon\n\nPastéis at Belém, the tram 28.\n")
	write(fmt.tprintf("%s/Notes/local/stray.md", home), "# A note with no identity\n")
	ics := "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:ev-1\r\nDTSTAMP:20261019T080000Z\r\nDTSTART:%s\r\nDURATION:PT45M\r\nSUMMARY:Weekly design review\r\nLOCATION:Room 2\r\nORGANIZER;CN=Priya Shah:mailto:priya@northwind.coop\r\nRRULE:FREQ=WEEKLY;COUNT=4\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
	start := time.unix(now + 2 * 3600, 0)
	y, mo, dd := time.date(start)
	hh, mi, _ := time.clock(start)
	dt := fmt.tprintf("%04d%02d%02dT%02d%02d00Z", y, int(mo), dd, hh, mi)
	write(fmt.tprintf("%s/northwind/calendar/work/ev-1.ics", p.dav), fmt.tprintf(ics, dt))
	write(fmt.tprintf("%s/northwind/calendar/work/td-1.ics", p.dav), "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:td-1\r\nDTSTAMP:20261019T080000Z\r\nSUMMARY:Sign off the Q4 roadmap\r\nDUE:20261019T170000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
	write(fmt.tprintf("%s/northwind/addressbook/contacts/p1.vcf", p.dav), "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:p1\r\nFN:Priya Shah\r\nORG:Northwind\r\nTITLE:Head of product\r\nEMAIL:priya@northwind.coop\r\nEND:VCARD\r\n")
	write(fmt.tprintf("%s/camille/history.jsonl", p.browser), "{\"id\":\"1\",\"url\":\"https://www.sncf-connect.com/trains\",\"title\":\"Train tickets Paris Lyon\",\"at\":1792390000000}\n{\"forget_url\":\"https://secret.example/\",\"at\":1792390000001}\n{\"id\":\"2\",\"url\":\"https://secret.example/\",\"title\":\"Secret page\",\"at\":1792390000000}\n")
	write(fmt.tprintf("%s/camille/T1.md", p.track), "---\nid: T1\ntitle: Renew passport\nstate: todo\n---\nBring two photos.\n")

	d: feed.Daemon
	err := feed.daemon_init(&d, p)
	check(err == "", "the daemon starts on a scratch home (%s)", err)
	check(len(d.ids) == 2, "two identities from palmy.conf; the local notebook is not one (%d)", len(d.ids))
	d.once = true
	d.battery_at = feed.now_ms()
	feed.daemon_run(&d)

	ts := make([dynamic]ic.Target, context.temp_allocator)
	for h in ([?]string{"camille", "northwind"}) {
		ix, ok := ic.index_open(p.index, h)
		if ok {
			append(&ts, ic.Target{ident = {handle = h}, ix = ix})
		}
	}
	defer for t in ts {
		ic.index_close(t.ix)
	}
	find :: proc(ts: []ic.Target, text: string) -> [dynamic]ic.Result {
		q := ic.parse_query(text, time.to_unix_seconds(time.now()))
		out := make([dynamic]ic.Result, context.temp_allocator)
		st: ic.Stats
		ic.search_all(ts, &q, {snippets = true, limit = 50}, &out, &st)
		return out
	}
	for t in ts {
		ic.index_refresh(t.ix)
	}
	r := find(ts[:], "flat viewing")
	check(len(r) == 1 && r[0].handle == "camille" && .Unread in r[0].flags && .Waiting in r[0].flags, "mail: unread, and a person waiting on you")
	r = find(ts[:], "autumn sale")
	check(len(r) == 1 && .Waiting not_in r[0].flags && .Unread not_in r[0].flags, "a newsletter is never waiting; S means read")
	r = find(ts[:], "cafe")
	check(len(r) == 1 && r[0].title == "Café demain?" && .Unread in r[0].flags, "a mail in new/ is unread; accents fold")
	r = find(ts[:], "apartment budget")
	check(len(r) == 1 && r[0].kind == .Doc && r[0].app == "docs", "drive: a Markdown file is a document, in docs")
	r = find(ts[:], "temporary")
	check(len(r) == 0, "drive's temporaries are skipped")
	r = find(ts[:], "offline drafts")
	check(len(r) == 1 && r[0].handle == "northwind", "a CSV's contents, in its own identity")
	r = find(ts[:], "pasteis")
	check(len(r) == 1 && r[0].kind == .Note && r[0].title == "Lisbon", "notes: title from the first line, front matter skipped")
	r = find(ts[:], "stray")
	check(len(r) == 0, "a notebook that names no identity is not indexed")
	r = find(ts[:], "design review")
	check(len(r) == 4 && r[0].kind == .Event, "calendar: a weekly event is its four instances (%d)", len(r))
	r = find(ts[:], "sign off type:task")
	check(len(r) == 1 && r[0].handle == "northwind", "calendar: a VTODO is a task")
	r = find(ts[:], "type:person priya")
	check(len(r) == 1 && r[0].detail == "Head of product, Northwind", "contacts: a vCard is a person")
	r = find(ts[:], "train tickets")
	check(len(r) == 1 && r[0].kind == .Page, "browser history")
	r = find(ts[:], "secret")
	check(len(r) == 0, "a page the browser was told to forget is not indexed")
	r = find(ts[:], "renew passport")
	check(len(r) == 1 && r[0].kind == .Task && r[0].app == "track", "track: an issue is a task")

	// A new mail arrives; a reply makes the first one no longer waiting; a
	// file changes; a note is deleted. Then one rescan of each.
	write(fmt.tprintf("%s/new/103.M1P1.host", mb), mail_file("Ines Roux <ines@example.org>", "camille@palm.test", "Keys for the flat", "m4@x", "I left the keys with the concierge."))
	write(fmt.tprintf("%s/.Sent/cur/104.M1P1.host:2,S", mb), mail_file("Camille <camille@palm.test>", "ines@example.org", "Re: Flat viewing on Saturday?", "m5@x", "15:30 works.", "In-Reply-To: <m1@x>\r\n"))
	write(fmt.tprintf("%s/Drive/camille/Home/Apartment budget.md", home), "# Apartment budget\n\nRent, deposit, the moving van and the piano movers.\n")
	os.remove(fmt.tprintf("%s/Notes/camille/Travel/Lisbon.md", home))
	d.once = true
	d.quit = false
	for x, i in d.ids {
		for k in feed.Source_Kind {
			d.due[feed.Job{i, k}] = 0
		}
		_ = x
	}
	feed.daemon_run(&d)
	for t in ts {
		ic.index_refresh(t.ix)
	}
	r = find(ts[:], "concierge")
	check(len(r) == 1, "a mail that arrives is found after one rescan")
	r = find(ts[:], "flat viewing -re")
	check(len(r) == 1 && .Waiting not_in r[0].flags, "replying takes it off Waiting on you")
	r = find(ts[:], "piano")
	check(len(r) == 1, "a file edit is reflected")
	r = find(ts[:], "pasteis")
	check(len(r) == 0, "a deleted note is removed")
	r = find(ts[:], "type:mail in:camille")
	n_before := len(r)
	st := d.states["camille"]
	check(st[.Mail].last.skipped >= 2, "unchanged mail is skipped by signature, not reread (%d skipped)", st[.Mail].last.skipped)
	_ = n_before

	// Status, written by the daemon.
	data, serr := os.read_entire_file_from_path(fmt.tprintf("%s/camille/status", p.index), context.temp_allocator)
	check(serr == nil && strings.contains(string(data), "\"sources\""), "the daemon writes a status per identity")
	feed.daemon_close(&d)

	// Kernel-level isolation: watch northwind's index directory with
	// inotify for any open or read while searching camille's.
	isolation_checks(p, ts[:])
}

isolation_checks :: proc(p: feed.Paths, ts: []ic.Target) {
	fd, e := linux.inotify_init1({.NONBLOCK})
	if e != .NONE {
		check(false, "inotify for the isolation test")
		return
	}
	defer linux.close(fd)
	target := strings.clone_to_cstring(fmt.tprintf("%s/northwind", p.index), context.temp_allocator)
	linux.inotify_add_watch(fd, target, {.OPEN, .ACCESS})
	// Also every file inside: inotify on a directory reports opens of the
	// files in it.
	ids, targets := open_targets(p.index, "camille")
	q := ic.parse_query("roadmap flat priya", time.to_unix_seconds(time.now()))
	out := make([dynamic]ic.Result, context.temp_allocator)
	st: ic.Stats
	ic.search_all(targets[:], &q, {snippets = true}, &out, &st)
	for t in targets {
		ic.index_close(t.ix)
	}
	buf: [4096]u8
	n, _ := linux.read(fd, buf[:])
	check(n <= 0 && len(ids) == 1, "a search scoped to camille: the kernel saw no open of northwind's index files")

	// The same with the real binary, as the assistant runs it.
	self := os.args[0]
	env := []string{fmt.tprintf("PALM_INDEX_DIR=%s", p.index), "PALM_IDENTITY=camille", fmt.tprintf("HOME=%s", p.index), "PATH=/usr/bin:/bin"}
	state, sout, _, perr := os.process_exec({command = {self, "search", "roadmap", "flat", "--json"}, env = env}, context.temp_allocator)
	n, _ = linux.read(fd, buf[:])
	check(perr == nil && state.exit_code == 0 && strings.contains(string(sout), "\"scope\": \"camille\"") && n <= 0, "PALM_IDENTITY=camille index search: exit 0, and no open of northwind's files")
	state, sout, _, perr = os.process_exec({command = {self, "search", "roadmap", "--identity", "northwind", "--json"}, env = env}, context.temp_allocator)
	check(perr == nil && state.exit_code == 5 && strings.contains(string(sout), "out of scope"), "--identity northwind from inside camille is refused, exit 5")
	n, _ = linux.read(fd, buf[:])
	check(n <= 0, "and the refusal opened nothing of northwind's either")
	env2 := []string{fmt.tprintf("PALM_INDEX_DIR=%s", p.index), fmt.tprintf("HOME=%s", p.index), "PATH=/usr/bin:/bin"}
	state, sout, _, perr = os.process_exec({command = {self, "search", "roadmap", "--json"}, env = env2}, context.temp_allocator)
	check(perr == nil && state.exit_code == 0 && strings.contains(string(sout), "\"identity\": \"northwind\"") && !strings.contains(string(sout), "\"identity\": \"\""), "unscoped, the All view: every result carries its identity")
}

// rebuild_checks: two identities whose handles share a prefix and one of
// which has a dot, on a device with no account (local-only mode). Each is
// rebuilt alone, the way the assistant runs `index rebuild` scoped to its
// identity; neither may hide the other, and a rebuild scoped to one never
// opens or writes anything in the other's index directory.
rebuild_checks :: proc(home: string) {
	write(fmt.tprintf("%s/Drive/camille/Home/Flat.md", home), "# Flat\n\nThe viewing is on Saturday.\n")
	write(fmt.tprintf("%s/Drive/camille.roux/Plans/Roadmap.md", home), "# Roadmap\n\nThe Q4 roadmap needs sign-off.\n")
	write(fmt.tprintf("%s/Notes/camille.roux/Standup.md", home), "# Standup\n\nPriya owns the migration.\n")
	index := fmt.tprintf("%s/index", home)
	env :: proc(home, index, scope: string) -> []string {
		e := make([dynamic]string, context.temp_allocator)
		append(&e, fmt.tprintf("HOME=%s", home), fmt.tprintf("XDG_DATA_HOME=%s/.local/share", home),
			fmt.tprintf("PALM_INDEX_DIR=%s", index), fmt.tprintf("PALM_MAIL_DIR=%s/mail", home),
			"PALM_INDEX_NO_CLOUD=1", "PATH=/usr/bin:/bin")
		if scope != "" {append(&e, fmt.tprintf("PALM_IDENTITY=%s", scope))}
		return e[:]
	}
	run :: proc(home, index, scope: string, args: ..string) -> (int, string) {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, os.args[0])
		append(&cmd, ..args)
		append(&cmd, "--json")
		state, sout, _, err := os.process_exec({command = cmd[:], env = env(home, index, scope)}, context.temp_allocator)
		if err != nil {return -1, ""}
		return state.exit_code, string(sout)
	}
	// Watches one identity's index directory for any open, read or write.
	watch :: proc(index, handle: string) -> linux.Fd {
		fd, e := linux.inotify_init1({.NONBLOCK})
		if e != .NONE {return -1}
		t := strings.clone_to_cstring(fmt.tprintf("%s/%s", index, handle), context.temp_allocator)
		linux.inotify_add_watch(fd, t, {.OPEN, .ACCESS, .MODIFY, .CREATE, .DELETE, .MOVED_TO, .ATTRIB})
		return fd
	}
	quiet :: proc(fd: linux.Fd) -> bool {
		buf: [4096]u8
		n, _ := linux.read(fd, buf[:])
		linux.close(fd)
		return n <= 0
	}

	code, out := run(home, index, "", "rebuild", "--identity", "camille")
	check(code == 0 && strings.contains(out, "\"docs\": 1"), "rebuild --identity camille, on a device with no account (exit %d)", code)

	w := watch(index, "camille")
	code, out = run(home, index, "camille.roux", "rebuild", "--identity", "camille.roux")
	check(code == 0 && strings.contains(out, "\"identity\": \"camille.roux\"") && strings.contains(out, "\"docs\": 2"),
		"then PALM_IDENTITY=camille.roux rebuild --identity camille.roux: its own two documents (exit %d)", code)
	check(w >= 0 && quiet(w), "and the kernel saw no open, read or write in camille's index")

	w = watch(index, "camille.roux")
	code, out = run(home, index, "camille", "rebuild", "--identity", "camille")
	check(code == 0 && strings.contains(out, "\"docs\": 1"), "the other way round: PALM_IDENTITY=camille rebuild still works (exit %d)", code)
	check(w >= 0 && quiet(w), "and touched nothing of camille.roux's")

	c1, o1 := run(home, index, "camille.roux", "search", "roadmap")
	c2, o2 := run(home, index, "camille.roux", "search", "viewing")
	check(c1 == 0 && c2 == 0 && strings.contains(o1, "Roadmap") && !strings.contains(o2, "Flat"), "camille.roux's search finds its roadmap and not camille's flat")
	c1, o1 = run(home, index, "camille", "search", "viewing")
	c2, o2 = run(home, index, "camille", "search", "roadmap")
	check(c1 == 0 && c2 == 0 && strings.contains(o1, "Flat") && !strings.contains(o2, "Roadmap"), "camille's finds the flat and not camille.roux's roadmap")
	code, _ = run(home, index, "camille", "rebuild", "--identity", "camille.roux")
	check(code == 5, "--identity camille.roux from inside camille is refused, exit 5 (%d)", code)

	p := feed.Paths {
		index = index, mail = fmt.tprintf("%s/mail", home), drive = fmt.tprintf("%s/Drive", home),
		notes = fmt.tprintf("%s/Notes", home), dav = fmt.tprintf("%s/dav", home),
		browser = fmt.tprintf("%s/browser", home), track = fmt.tprintf("%s/track", home),
	}
	ids := feed.discover(p)
	check(len(ids) == 2, "with both indexed, discovery still finds both local identities (%d)", len(ids))
	one := feed.discover(p, "camille.roux")
	check(len(one) == 1 && one[0].handle == "camille.roux", "scoped, exactly the one, not its prefix's (%d)", len(one))

	// With an account the rule stands: a folder naming none of its
	// identities is not one.
	write(fmt.tprintf("%s/palmy.conf", p.mail), "[identity]\nid = 1\nhandle = camille\nname = Personal\n")
	os.remove_all(fmt.tprintf("%s/camille.roux", index))
	code, _ = run(home, index, "", "rebuild", "--identity", "camille.roux")
	check(code == 3, "once an account lists only camille, camille.roux's folder names no identity (exit %d)", code)
}
