package main

// `mail --shots <dir>`: render the real interface offscreen and write PNGs.
//
// The same `frame` and the same `handle_keys` the window runs, with synthetic
// keys in place of a compositor's. It needs no display and no recording lock.
//
// The mailbox it reads is generated here, in a scratch directory of its own:
// invented people at invented domains, written out as an ordinary Maildir and
// scanned back through the real scanner. The user's own mail store is never
// opened, and this client has no network code at all.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1500
SHOT_H :: 940

// The generated mailbox lives outside the shots directory on purpose: the raw
// header view prints the Maildir path, and a shots directory chosen by a
// caller may carry a path that has no business being in a picture.
SHOT_FIXTURE_DIR :: "/tmp/palmy-mail-shots"

@(private = "file")
Shot_Msg :: struct {
	from:    string, // "Name <local@domain>"
	to:      string,
	cc:      string,
	subject: string,
	id:      string,
	reply:   string,
	refs:    string,
	minutes: int, // how long ago it arrived
	body:    string,
	html:    bool,
	attach:  string, // attachment filename, "" for none
	flags:   Flags,
	folder:  string, // "" for the inbox
}

// The invented correspondence. One office, two crossings, a handful of people
// who do not exist at domains nobody owns.
@(private = "file")
SHOT_MAIL := [?]Shot_Msg {
	{
		from = "Mira Castellan <mira.castellan@northreach.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Tide gate: the 31 evenings, with the raw counts",
		id = "<survey-tide-01@northreach.example>",
		minutes = 46,
		body = "The count is confirmed at 31 evenings held out of 92 surveyed.\n" +
		"Median hold is 24 minutes; the worst was 51 on the 14th of August,\n" +
		"when the evening boat sailed an hour down and the last connection\n" +
		"was missed at both ends.\n\n" +
		"I have attached the per-evening table. Column four is the depth at\n" +
		"the shoal, read off the gauge rather than modelled, which is the\n" +
		"part nobody had before.\n\n" +
		"Mira",
		attach = "tide-holds-by-evening.csv",
	},
	{
		from = "Teodor Vance <t.vance@quayside-eng.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		cc = "Mira Castellan <mira.castellan@northreach.example>",
		subject = "Re: Tide gate: the 31 evenings, with the raw counts",
		id = "<survey-tide-02@quayside-eng.example>",
		reply = "<survey-tide-01@northreach.example>",
		refs = "<survey-tide-01@northreach.example>",
		minutes = 28,
		body = "Reading the same table I get 31 as well, so that number is solid.\n\n" +
		"One caution before it goes in the report: six of those evenings were\n" +
		"also weather holds. The boat would not have sailed on time anyway, so\n" +
		"attributing the whole delay to the gate overstates it. I would quote\n" +
		"31 held, 25 held by tide alone, and say so plainly.\n\n" +
		"Teodor",
	},
	{
		from = "Alina Brecht <alina@tidetable.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Draft timetable for the southern reach, version 4",
		id = "<timetable-v4@tidetable.example>",
		minutes = 95,
		body = "Version four moves the 18:40 to 19:05 on spring tides only, which\n" +
		"clears the shoal on every evening in the survey except two.\n\n" +
		"It costs the 19:30 connection at the far end twice a month. That is\n" +
		"the trade, and I do not think it can be avoided without dredging.\n\n" +
		"Alina",
		flags = {.Seen},
	},
	{
		from = "Rupert Oyelaran <rupert.o@harbourboard.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Board papers: survey findings on the agenda for the 12th",
		id = "<board-agenda-11@harbourboard.example>",
		minutes = 210,
		body = "You are item four, with twenty minutes and no slides needed.\n\n" +
		"The board will want one number for the cost of dredging the shoal\n" +
		"and one number for the cost of doing nothing. If the second is\n" +
		"larger the rest of the paper writes itself.\n\n" +
		"Rupert",
		flags = {.Seen, .Flagged},
	},
	{
		from = "Sabine Toll <s.toll@ferrycrew.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Crew view of the seven minute turn",
		id = "<crew-turn-07@ferrycrew.example>",
		minutes = 400,
		body = "Nobody on the northern reach believes the seven minute turn.\n\n" +
		"Eleven is what it takes with a full vehicle deck and one ramp, and\n" +
		"eleven is what the survey measured, so at least the timetable and\n" +
		"the crew now disagree with the same evidence in front of them.\n\n" +
		"Put thirteen in the next timetable and we will keep it every time.\n\n" +
		"Sabine",
		flags = {.Seen},
	},
	{
		from = "Dispatch Desk <dispatch@tidewater.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Overnight log, northern reach",
		id = "<dispatch-log-0914@tidewater.example>",
		minutes = 700,
		body = "Six sailings, six on time. Freight run berthed at 02:10 and cleared\n" +
		"at 02:26, which is the first night this month it has not overlapped\n" +
		"the 02:20 departure.\n\n" +
		"Gauge at the shoal read 2.4 m at low water.",
		flags = {.Seen},
	},
	{
		from = "Port Notices <notices@portauthority.example>",
		to = "Operators <operators@portauthority.example>",
		subject = "Navigation notice 44: survey buoy relocated at the shoal",
		id = "<notice-44@portauthority.example>",
		minutes = 1500,
		html = true,
		body = "<html><body style=\"font-family:sans-serif\">" +
		"<h2>Navigation notice 44</h2>" +
		"<p>The survey buoy at the southern shoal has been relocated " +
		"<b>120 metres east</b> and now marks the deepest part of the channel " +
		"rather than its centre.</p>" +
		"<p>Masters should expect the marked channel to be narrower and to " +
		"favour the eastern bank on the approach.</p>" +
		"<p><i>Issued by the harbour office. No reply is required.</i></p>" +
		"</body></html>",
		flags = {.Seen},
	},
	{
		from = "Mira Castellan <mira.castellan@northreach.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Quarterly loading figures, foot against vehicle",
		id = "<loading-q3@northreach.example>",
		minutes = 2600,
		body = "Foot passengers are up a fifth on the southern reach and flat on\n" +
		"the northern one. Vehicles are flat on both.\n\n" +
		"That matters for the turn: a foot queue clears in two minutes and a\n" +
		"vehicle deck does not, so the crossing that is growing is the one\n" +
		"whose turn time will not get worse.",
		flags = {.Seen},
	},
	{
		from = "Teodor Vance <t.vance@quayside-eng.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Berth conflict at the evening quay",
		id = "<berth-evening-02@quayside-eng.example>",
		minutes = 3400,
		body = "The evening boat cannot take the inner berth loaded, which is why\n" +
		"it waits for the freight run rather than the other way round.\n\n" +
		"Lengthening the inner berth by eighteen metres removes the conflict\n" +
		"entirely and costs a fraction of the dredging. I would put that in\n" +
		"the paper as the cheap recommendation.",
		flags = {.Seen, .Answered},
	},
	{
		from = "Alina Brecht <alina@tidetable.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Weather holds: how we should count them",
		id = "<weather-counting@tidetable.example>",
		minutes = 5000,
		body = "A hold for wind and a hold for fog are not the same thing to a\n" +
		"passenger: fog clears on a schedule nobody can publish, wind does\n" +
		"not. I have split the column in two.",
		flags = {.Seen},
	},
	{
		from = "Ferry Desk <ferry.desk@tidewater.example>",
		to = "Rupert Oyelaran <rupert.o@harbourboard.example>",
		subject = "Re: Board papers: survey findings on the agenda for the 12th",
		id = "<board-reply-01@tidewater.example>",
		reply = "<board-agenda-11@harbourboard.example>",
		minutes = 180,
		body = "Twenty minutes is plenty. Both numbers will be in the paper, and\n" +
		"the second one is larger.\n\n" +
		"Ferry Desk",
		flags = {.Seen},
		folder = ".Sent",
	},
	{
		from = "Sabine Toll <s.toll@ferrycrew.example>",
		to = "Ferry Desk <ferry.desk@tidewater.example>",
		subject = "Last season's turn times, for comparison",
		id = "<turn-last-season@ferrycrew.example>",
		minutes = 40000,
		body = "Attached as sent to the board last year. The median was twelve,\n" +
		"so this season is not worse, it is merely still wrong.",
		flags = {.Seen},
		folder = ".Archive",
	},
}

@(private = "file")
shot_message_bytes :: proc(m: Shot_Msg, when_: time.Time) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "From: %s\r\n", m.from)
	fmt.sbprintf(&b, "To: %s\r\n", m.to)
	if m.cc != "" {
		fmt.sbprintf(&b, "Cc: %s\r\n", m.cc)
	}
	fmt.sbprintf(&b, "Subject: %s\r\n", m.subject)
	fmt.sbprintf(&b, "Date: %s\r\n", format_rfc5322_date(when_, context.temp_allocator))
	fmt.sbprintf(&b, "Message-ID: %s\r\n", m.id)
	if m.reply != "" {
		fmt.sbprintf(&b, "In-Reply-To: %s\r\n", m.reply)
	}
	if m.refs != "" {
		fmt.sbprintf(&b, "References: %s\r\n", m.refs)
	}
	strings.write_string(&b, "MIME-Version: 1.0\r\n")

	body := strings.builder_make(context.temp_allocator)
	rest := m.body
	for line in strings.split_lines_iterator(&rest) {
		strings.write_string(&body, line)
		strings.write_string(&body, "\r\n")
	}
	text := strings.to_string(body)

	switch {
	case m.attach != "":
		BOUND :: "----palmy-shot-boundary"
		fmt.sbprintf(&b, "Content-Type: multipart/mixed; boundary=\"%s\"\r\n\r\n", BOUND)
		fmt.sbprintf(&b, "--%s\r\n", BOUND)
		strings.write_string(&b, "Content-Type: text/plain; charset=utf-8\r\n\r\n")
		strings.write_string(&b, text)
		fmt.sbprintf(&b, "\r\n--%s\r\n", BOUND)
		fmt.sbprintf(
			&b,
			"Content-Type: text/csv; charset=utf-8\r\nContent-Disposition: attachment; filename=\"%s\"\r\n\r\n",
			m.attach,
		)
		strings.write_string(&b, "evening,held,minutes,depth_m\r\n")
		for i in 0 ..< 31 {
			fmt.sbprintf(&b, "%d,yes,%d,%d.%d\r\n", i + 1, 12 + (i * 7) % 40, 1, 4 + i % 5)
		}
		fmt.sbprintf(&b, "\r\n--%s--\r\n", BOUND)
	case m.html:
		strings.write_string(&b, "Content-Type: text/html; charset=utf-8\r\n\r\n")
		strings.write_string(&b, m.body)
		strings.write_string(&b, "\r\n")
	case:
		strings.write_string(&b, "Content-Type: text/plain; charset=utf-8\r\n\r\n")
		strings.write_string(&b, text)
	}
	return strings.to_string(b)
}

// shot_fixtures writes the invented mailbox. Nothing here resembles anybody's
// real mail, and every domain is under `.example`, which cannot be registered.
@(private = "file")
shot_fixtures :: proc(data_dir: string) -> int {
	root := fmt.tprintf("%s/harbour", data_dir)
	maildir_make(root)
	for f in ([?]string{".Sent", ".Drafts", ".Archive", ".Trash"}) {
		maildir_make(fmt.tprintf("%s/%s", root, f))
	}

	conf := fmt.tprintf(
		"# palmy-mail accounts, generated by `mail --shots`.\n" +
		"#\n" +
		"# Loopback only. This client reads the Maildir below and never opens\n" +
		"# a socket; host and port are recorded so the sidebar has something\n" +
		"# true to show.\n\n" +
		"[account]\nname = Harbour Office\nprotocol = imap\n" +
		"address = ferry.desk@tidewater.example\nhost = 127.0.0.1\nport = 10143\npath = harbour\n",
	)
	write_file(fmt.tprintf("%s/accounts.conf", data_dir), transmute([]u8)conf)

	now := time.now()
	n := 0
	for m, i in SHOT_MAIL {
		when_ := time.Time{_nsec = now._nsec - i64(m.minutes) * 60 * 1_000_000_000}
		folder := m.folder == "" ? root : fmt.tprintf("%s/%s", root, m.folder)
		base := fmt.tprintf("%d.M%06dP%d.palmy-shot", when_._nsec / 1_000_000_000, i + 1, os.get_pid())
		path: string
		if m.flags == {} {
			path = fmt.tprintf("%s/new/%s", folder, base)
		} else {
			path = fmt.tprintf(
				"%s/cur/%s",
				folder,
				maildir_name_with_flags(base, m.flags, context.temp_allocator),
			)
		}
		if write_file(path, transmute([]u8)shot_message_bytes(m, when_)) {
			n += 1
		}
	}
	return n
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("mail --shots: cannot create %s", dir)
		return 1
	}

	// Every read and every write this run makes stays inside its own scratch
	// tree. The user's mail store is never opened.
	data_dir := strings.clone(SHOT_FIXTURE_DIR)
	// `remove_tree` refuses to act outside the data directory, so the override
	// has to be in place before anything is cleared. Without it a second run
	// would scan the first run's messages as well as its own.
	data_dir_override = data_dir
	os.make_directory_all(data_dir)
	remove_tree(fmt.tprintf("%s/harbour", data_dir))
	os.remove(fmt.tprintf("%s/accounts.conf", data_dir))
	for i in 0 ..< 8 {
		os.remove(fmt.tprintf("%s/local-flags-%d.tsv", data_dir, i))
	}
	written := shot_fixtures(data_dir)

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)

	// The same faces and the same calibration the windowed app gets from the
	// kit; the offscreen renderer has its own font table.
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_FONTS {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))

	st := new(State)
	init_state(st)
	st.save_dir = strings.clone(fmt.tprintf("%s/saved", data_dir))
	os.make_directory_all(st.save_dir)

	fmt.printfln(
		"mail --shots: %d files written, %d messages, %d folders, %d accounts",
		written,
		len(st.messages),
		len(st.folders),
		len(st.accounts),
	)
	if len(st.messages) == 0 {
		fmt.eprintfln("mail --shots: the generated mailbox is empty")
		return 1
	}

	step :: proc(off: ^p.Offscreen, st: ^State) {
		ui := p.offscreen_begin(off)
		st.now = time.now()
		handle_keys(ui, st, nil)
		frame(ui, st)
		apply_scroll(ui, st)
		p.offscreen_end(off)
	}

	// Hover, hit testing and scrolling all run against the previous frame, so
	// the settled picture is a few frames in.
	shot :: proc(off: ^p.Offscreen, st: ^State, dir, name: string) {
		for _ in 0 ..< 3 {
			step(off, st)
		}
		path := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, path) {
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	key :: proc(off: ^p.Offscreen, st: ^State, sym: u32, times := 1) {
		for _ in 0 ..< times {
			p.press_key(off, sym)
			step(off, st)
			step(off, st)
		}
	}

	// The representative frame: the inbox with the top conversation expanded,
	// which is the two-message thread that also carries the attachment.
	key(off, st, p.KEY_HOME)
	key(off, st, p.KEY_RETURN)
	shot(off, st, dir, "app-mail")

	// The attachment list, and a chip chosen.
	key(off, st, 'v')
	shot(off, st, dir, "02-mail-attachment")

	// Search.
	key(off, st, p.KEY_ESCAPE)
	key(off, st, '/')
	p.type_text(off, "tide")
	step(off, st)
	shot(off, st, dir, "03-mail-search")
	key(off, st, p.KEY_DOWN)
	shot(off, st, dir, "04-mail-search-hit")
	key(off, st, p.KEY_ESCAPE)

	// The composer, with a reply typed into it.
	key(off, st, 'r')
	p.type_text(
		off,
		"Agreed on 31 held and 25 by tide alone. I will quote both and say which is which.",
	)
	step(off, st)
	shot(off, st, dir, "05-mail-composer")
	key(off, st, p.KEY_ESCAPE)

	// The folder tree.
	key(off, st, 'h')
	shot(off, st, dir, "06-mail-folders")

	fmt.printfln("mail --shots: wrote PNGs to %s", dir)
	return 0
}
